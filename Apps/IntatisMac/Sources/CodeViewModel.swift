#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel

private final class CodePermissionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PermissionApprovalResolution, Never>?
    private var resolution: PermissionApprovalResolution?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolution == nil
    }

    func install(_ continuation: CheckedContinuation<PermissionApprovalResolution, Never>) {
        let completed: PermissionApprovalResolution?
        lock.lock()
        if let resolution {
            completed = resolution
        } else {
            self.continuation = continuation
            completed = nil
        }
        lock.unlock()
        if let completed { continuation.resume(returning: completed) }
    }

    @discardableResult
    func resolve(_ resolution: PermissionApprovalResolution) -> Bool {
        let continuation: CheckedContinuation<PermissionApprovalResolution, Never>?
        lock.lock()
        guard self.resolution == nil else {
            lock.unlock()
            return false
        }
        self.resolution = resolution
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: resolution)
        return true
    }
}

/// Drives a single-workspace Code session: subscribes to the event log, folds it
/// into `CodeItem`s, runs the `AgentLoop`, and acts as the `PermissionResponder`
/// (bridging `ask_user` to the on-screen permission card).
@MainActor
final class CodeViewModel: ObservableObject, PermissionResponder {
    @Published private(set) var items: [CodeItem] = []
    @Published var input: String = ""
    @Published private(set) var isWorking = false
    @Published private(set) var agentState: String = "idle"
    @Published var pendingPermission: PendingPermission?
    @Published private(set) var permissionNotice: PermissionResolutionNotice?
    @Published private(set) var latestTurnStats: TurnStatsSnapshot?
    @Published private(set) var composerError: String?

    let sessionID: SessionID
    let workspaceName: String

    private let workspaceRoot: URL
    private var workspaceAccess: WorkspaceAccessLease?
    private let log: EventLog
    private let sessionNaming: SessionNamingService
    private let terminal = ProcessTerminalSessionManager()
    private var registry: ProviderRegistry
    private var subscription: Task<Void, Never>?
    private var permissionWaiters: [RequestID: CodePermissionWaiter] = [:]
    private var permissionQueue: [PendingPermission] = []
    private var runningOperation: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isShutdown = false

    init(sessionID: SessionID,
         workspaceAccess: WorkspaceAccessLease,
         log: EventLog,
         sessionNaming: SessionNamingService,
         registry: ProviderRegistry) {
        self.sessionID = sessionID
        self.workspaceAccess = workspaceAccess
        self.workspaceRoot = workspaceAccess.canonicalURL
        self.workspaceName = workspaceAccess.canonicalURL.lastPathComponent
        self.log = log
        self.sessionNaming = sessionNaming
        self.registry = registry
    }

    deinit {
        subscription?.cancel()
        runningOperation?.cancel()
        workspaceAccess?.release()
    }

    func updateProviderRegistry(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    func start() {
        guard !isShutdown, subscription == nil else { return }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let replayed = await self.log.replay()
            var projection = CodeProjection.build(from: replayed)
            var permissions = PermissionProjection.build(from: replayed, markNeedsRerun: true)
            var turnStats = TurnStatsProjection.build(from: replayed)
            self.items = projection.items
            self.pendingPermission = permissions.latest
            self.permissionNotice = permissions.latestResolved
            self.latestTurnStats = turnStats.latest
            let stream = await self.log.stream(from: (replayed.last?.seq ?? -1) + 1)
            for await envelope in stream {
                projection.apply(envelope)
                permissions.apply(envelope)
                turnStats.apply(envelope)
                self.items = projection.items
                self.pendingPermission = permissions.latest
                self.permissionNotice = permissions.latestResolved
                self.latestTurnStats = turnStats.latest
                if case .agentStatus(let p) = envelope.event { self.agentState = p.state.rawValue }
            }
        }
    }

    func stop() {
        Task { @MainActor [weak self] in
            await self?.shutdown(reason: "Code session stopped")
        }
    }

    /// Cancels the current model/tool turn without tearing down the session
    /// runtime or its projection subscription.
    func cancelCurrentTurn() {
        guard !isShutdown, isWorking else { return }
        runningOperation?.cancel()
        Task { await terminal.terminateAll(reason: "Code turn cancelled") }
    }

    /// Permanently stops this session runtime and waits until the active turn,
    /// permission waiters, projection subscription, and workspace scope have
    /// all settled. Page/session switching must never call this method.
    func shutdown(reason: String) async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShutdown = true
        subscription?.cancel()
        let runningSubscription = subscription
        subscription = nil
        let operation = runningOperation
        operation?.cancel()
        let task = Task { @MainActor [weak self] in
            if let self {
                await self.terminal.shutdown(reason: reason)
            }
            if let operation { await operation.value }
            if let runningSubscription { await runningSubscription.value }
            guard let self else { return }
            for (requestID, waiter) in self.permissionWaiters {
                waiter.resolve(Self.cancelledResolution(
                    requestID: requestID,
                    reason: reason))
            }
            self.permissionWaiters.removeAll()
            self.permissionQueue.removeAll()
            if var pending = self.pendingPermission, pending.state.isActionable {
                pending.state = .expired
                self.pendingPermission = pending
            }
            self.runningOperation = nil
            self.isWorking = false
            self.workspaceAccess?.release()
            self.workspaceAccess = nil
        }
        shutdownTask = task
        await task.value
    }

    func send() {
        guard !isShutdown, !isWorking else { return }
        let originalInput = input
        let parsed: ParsedUserInput
        switch GoalInputParser.parse(originalInput) {
        case .success(let value):
            parsed = value
        case .failure(.empty):
            return
        case .failure(let error):
            composerError = error.message
            return
        }
        input = ""
        isWorking = true
        composerError = nil
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var didEnterAgentLoop = false
            do {
                let provider = try await self.registry.defaultAgentProvider()
                let model = await self.registry.agentModel()
                let agent = Agent(name: AgentID(rawValue: "Coder"),
                                  workspaceRoot: self.workspaceRoot,
                                  model: model,
                                  profile: .reviewed)
                let workspaceLease = WorkspaceLease(
                    rootPath: self.workspaceRoot.path,
                    access: .readWrite)
                let allowsShell = PlatformProfile.current.allowsShell
                let runtime = AgentRuntime.code(
                    registry: .standard(includesTerminal: allowsShell),
                    allowsShell: allowsShell)
                let loop = runtime.makeLoop(
                    log: self.log,
                    provider: provider,
                    responder: self,
                    agent: agent,
                    terminal: self.terminal,
                    imageGenerator: ProviderImageGenerationToolService(registry: self.registry),
                    sessionNaming: self.sessionNaming,
                    workspaceLease: workspaceLease)
                didEnterAgentLoop = true
                try await loop.send(parsed.text, userMessage: parsed.userMessagePayload)
            } catch {
                let isInterruption = error is AgentTurnInterruptedError
                    || IntatisCancellation.isCurrentTaskCancellation(error)
                let message = error.localizedDescription
                self.composerError = isInterruption ? nil : message
                if !didEnterAgentLoop {
                    try? await self.log.append(.error(
                        RuntimeErrorPresentation.payload(for: error, fallbackCode: "agent")))
                }
            }
            self.isWorking = false
            self.runningOperation = nil
        }
        runningOperation = operation
    }

    // MARK: PermissionResponder

    nonisolated func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await requestResolution(request).decision
    }

    nonisolated func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        let waiter = CodePermissionWaiter()
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled {
                waiter.resolve(Self.cancelledResolution(
                    requestID: request.requestId,
                    reason: "Code turn cancelled before permission presentation"))
            }
            return await withCheckedContinuation { continuation in
                waiter.install(continuation)
                Task { @MainActor [weak self] in
                    guard let self else {
                        waiter.resolve(Self.cancelledResolution(
                            requestID: request.requestId,
                            reason: "Code permission presenter is unavailable"))
                        return
                    }
                    self.registerPermission(request, waiter: waiter)
                }
            }
        }, onCancel: {
            waiter.resolve(Self.cancelledResolution(
                requestID: request.requestId,
                reason: "Code turn cancelled while awaiting permission"))
            Task { @MainActor [weak self] in
                self?.cancelPermission(request.requestId, waiter: waiter)
            }
        })
    }

    func resolvePermission(_ action: PermissionResponseAction) {
        guard pendingPermission?.state.isActionable == true,
              let request = pendingPermission?.request else { return }
        guard let waiter = permissionWaiters.removeValue(forKey: request.requestId) else {
            if pendingPermission?.state == .needsRerun { return }
            if var pending = pendingPermission {
                pending.state = .expired
                pendingPermission = pending
            }
            return
        }
        if var pending = pendingPermission {
            pending.state = .resolving
            pendingPermission = pending
        }
        waiter.resolve(Self.userResolution(action, request: request))
        permissionQueue.removeAll { $0.request.requestId == request.requestId }
        pendingPermission = permissionQueue.first
    }

    private func registerPermission(
        _ request: PermissionRequestPayload,
        waiter: CodePermissionWaiter
    ) {
        guard waiter.isPending else { return }
        if let existing = permissionWaiters[request.requestId], existing !== waiter {
            // RequestID is immutable. A duplicate live presenter joins neither
            // identity nor order; fail the newer conflicting waiter closed.
            waiter.resolve(Self.cancelledResolution(
                requestID: request.requestId,
                reason: "Duplicate permission request identity"))
            return
        }
        permissionWaiters[request.requestId] = waiter
        if !permissionQueue.contains(where: { $0.request.requestId == request.requestId }) {
            permissionQueue.append(PendingPermission(
                request: request,
                state: request.effectiveApprovalMode == .automaticReviewer
                    ? .resolving
                    : .livePending,
                requestedSeq: -1))
        }
        pendingPermission = permissionQueue.first
    }

    private func cancelPermission(
        _ requestID: RequestID,
        waiter: CodePermissionWaiter
    ) {
        if permissionWaiters[requestID] === waiter {
            permissionWaiters.removeValue(forKey: requestID)
        }
        permissionQueue.removeAll { $0.request.requestId == requestID }
        pendingPermission = permissionQueue.first
    }

    private nonisolated static func userResolution(
        _ action: PermissionResponseAction,
        request: PermissionRequestPayload
    ) -> PermissionApprovalResolution {
        switch action {
        case .approve:
            return PermissionApprovalResolution(
                decision: .allow,
                action: .approve,
                reason: "Permission approved by user",
                risk: request.risk,
                source: .user)
        case .decline:
            return PermissionApprovalResolution(
                decision: .deny,
                action: .decline,
                reason: "Permission declined by user",
                risk: request.risk,
                source: .user,
                failureSource: .userDenied)
        case .cancelTurn:
            return PermissionApprovalResolution(
                decision: .deny,
                action: .cancelTurn,
                reason: "Turn cancelled by user",
                risk: request.risk,
                source: .user,
                failureSource: .userCancelled)
        }
    }

    private nonisolated static func cancelledResolution(
        requestID _: RequestID,
        reason: String
    ) -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: .deny,
            reason: reason,
            source: .callerCancellation,
            reviewStatus: .cancelled,
            failureKind: .callerCancelled,
            failureSource: .turnCancelled)
    }
}
#endif
