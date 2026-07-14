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
    private let log: EventLog
    private var registry: ProviderRegistry
    private var subscription: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?

    init(sessionID: SessionID, workspaceRoot: URL, log: EventLog, registry: ProviderRegistry) {
        self.sessionID = sessionID
        self.workspaceRoot = workspaceRoot
        self.workspaceName = workspaceRoot.lastPathComponent
        self.log = log
        self.registry = registry
    }

    deinit {
        subscription?.cancel()
    }

    func updateProviderRegistry(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    func start() {
        guard subscription == nil else { return }
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
        subscription?.cancel()
        subscription = nil
        if let continuation = permissionContinuation {
            continuation.resume(returning: .deny)
            permissionContinuation = nil
        }
        if var pending = pendingPermission, pending.state.isActionable {
            pending.state = .expired
            pendingPermission = pending
        }
        isWorking = false
    }

    func send() {
        guard !isWorking else { return }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            var didEnterAgentLoop = false
            do {
                let provider = try await self.registry.defaultAgentProvider()
                let model = await self.registry.agentModel()
                let agent = Agent(name: AgentID(rawValue: "Coder"),
                                  workspaceRoot: self.workspaceRoot,
                                  model: model,
                                  profile: .reviewed)
                let runtime = AgentRuntime.code(
                    allowsShell: PlatformProfile.current.allowsShell)
                let loop = runtime.makeLoop(
                    log: self.log,
                    provider: provider,
                    responder: self,
                    agent: agent,
                    imageGenerator: ProviderImageGenerationToolService(registry: self.registry))
                didEnterAgentLoop = true
                try await loop.send(parsed.text, userMessage: parsed.userMessagePayload)
            } catch {
                let message = error.localizedDescription
                self.composerError = message
                if !didEnterAgentLoop {
                    try? await self.log.append(.error(
                        RuntimeErrorPresentation.payload(for: error, fallbackCode: "agent")))
                }
            }
            self.isWorking = false
        }
    }

    // MARK: PermissionResponder

    nonisolated func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionDecision, Never>) in
            Task { @MainActor in
                self.pendingPermission = PendingPermission(request: request, state: .livePending, requestedSeq: -1)
                self.permissionContinuation = continuation
            }
        }
    }

    func resolvePermission(_ decision: PermissionDecision) {
        guard pendingPermission?.state.isActionable == true else { return }
        guard let continuation = permissionContinuation else {
            if pendingPermission?.state == .needsRerun {
                return
            }
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
        continuation.resume(returning: decision)
        permissionContinuation = nil
    }
}
#endif
