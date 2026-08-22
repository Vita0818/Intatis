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
import IntatisSkills
import IntatisArtifacts
import IntatisMCP
import IntatisSharedUI
import IntatisCodexRuntime

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
    @Published private(set) var pendingMCPExternalContextCount = 0
    @Published private(set) var draftAttachments:
        [IntatisComposerDraftAttachment] = []

    #if canImport(AVFoundation)
    let voiceInput: ComposerVoiceInputController
    private var voiceInputObservation: AnyCancellable?
    #endif

    let sessionID: SessionID
    let workspaceName: String
    var mcpEventLog: EventLog { log }
    var mcpWorkspacePaths: [String] {
        [workspaceRoot.path]
    }
    var mcpArtifactStore: ArtifactStore {
        artifactStore
    }

    private let workspaceRoot: URL
    private var workspaceAccess: WorkspaceAccessLease?
    private let log: EventLog
    private let artifactStore: ArtifactStore
    private let composerAttachmentStore:
        IntatisComposerAttachmentStore
    private let sessionNaming: SessionNamingService
    private let terminal = ProcessTerminalSessionManager()
    private var registry: ProviderRegistry
    private var subscription: Task<Void, Never>?
    private var projectionPump:
        SessionProjectionPump<
            CodeSessionProjectionState,
            ContinuousClock>?
    private var projectionCommitFence:
        SessionProjectionCommitFence?
    private var permissionWaiters: [RequestID: CodePermissionWaiter] = [:]
    private var permissionQueue: [PendingPermission] = []
    private var runningOperation: Task<Void, Never>?
    private var attachmentImportOperations:
        [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var isShutdown = false
    private var pendingMCPExternalContexts:
        [UntrustedExternalContext] = []
    private var pendingMCPExternalContextAgentID:
        AgentID?
    private let mcpSnapshots:
        (@MainActor @Sendable () async throws
            -> MCPAgentRequestToolSnapshotSource)?
    /// Optional host-owned internal tools. The default is nil; product UI and
    /// ordinary Code sessions therefore retain their existing registry.
    private let internalToolRegistryAugmenter:
        HostToolRegistryAugmenter?
    private var mcpInternalToolRegistryLease:
        HostToolRegistryAugmentationLease?
    private var codexRuntime: CodexAppServerSession?
    private var codexStartupTask:
        Task<CodexAppServerSession, Error>?
    private var codexEventTask: Task<Void, Never>?
    private var codexApprovalIDs:
        [RequestID: CodexRuntimeRequestID] = [:]
    private var codexApprovalActions:
        [RequestID: PermissionResponseAction] = [:]
    private var codexAllowsThreadCreation = false
    private var codexWriterLease: EventLogWriterLease?
    private var codexProjectionFailed = false

    init(sessionID: SessionID,
         workspaceAccess: WorkspaceAccessLease,
         log: EventLog,
         artifactStore: ArtifactStore,
         sessionNaming: SessionNamingService,
         registry: ProviderRegistry,
         mcpSnapshots:
            (@MainActor @Sendable () async throws
                -> MCPAgentRequestToolSnapshotSource)?
                = nil,
         internalToolRegistryAugmenter:
            HostToolRegistryAugmenter? = nil,
         initialConfigurationNotice: String? = nil) {
        self.sessionID = sessionID
        self.workspaceAccess = workspaceAccess
        self.workspaceRoot = workspaceAccess.canonicalURL
        self.workspaceName = workspaceAccess.canonicalURL.lastPathComponent
        self.log = log
        self.artifactStore = artifactStore
        self.composerAttachmentStore =
            IntatisComposerAttachmentStore(
                store: artifactStore)
        self.sessionNaming = sessionNaming
        self.registry = registry
        #if canImport(AVFoundation)
        self.voiceInput = ComposerVoiceInputController(registry: registry)
        #endif
        self.mcpSnapshots = mcpSnapshots
        self.internalToolRegistryAugmenter =
            internalToolRegistryAugmenter
        self.composerError = initialConfigurationNotice
        #if canImport(AVFoundation)
        observeVoiceInput()
        #endif
    }

    deinit {
        subscription?.cancel()
        runningOperation?.cancel()
        codexStartupTask?.cancel()
        codexEventTask?.cancel()
        for operation in attachmentImportOperations.values {
            operation.cancel()
        }
        workspaceAccess?.release()
    }

    func updateProviderRegistry(_ registry: ProviderRegistry) {
        self.registry = registry
        #if canImport(AVFoundation)
        voiceInput.updateProviderRegistry(registry)
        #endif
        let runtime = codexRuntime
        codexRuntime = nil
        codexStartupTask?.cancel()
        codexStartupTask = nil
        codexEventTask?.cancel()
        codexEventTask = nil
        if let runtime {
            Task { await runtime.shutdown() }
        }
    }

    func start() {
        guard !isShutdown, subscription == nil else { return }
        let identity = SessionProjectionIdentity(
            sessionID: sessionID)
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ContinuousClock>(
                identity: identity,
                clock: ContinuousClock())
        projectionCommitFence =
            SessionProjectionCommitFence(
                identity: identity)
        projectionPump = pump
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replayed = await self.log.replay()
                self.codexAllowsThreadCreation =
                    !Self.containsAgentHistory(replayed)
                let initial = try await pump.loadInitialReplay(
                    replayed)
                self.commitProjectionSnapshot(initial)
                let stream = await self.log.stream(
                    from: (replayed.last?.seq ?? -1) + 1)
                let publications =
                    try await pump.publications(
                        consuming: stream)
                for await output in publications {
                    guard !Task.isCancelled else { break }
                    switch output {
                    case .snapshot(let snapshot):
                        self.commitProjectionSnapshot(
                            snapshot)
                    case .failed(let failure):
                        guard self.projectionCommitFence?
                                .identity == identity else {
                            continue
                        }
                        self.composerError =
                            failure.localizedDescription
                    }
                }
            } catch {
                guard self.projectionCommitFence?
                        .identity == identity,
                      !Task.isCancelled else {
                    return
                }
                self.composerError =
                    error.localizedDescription
            }
        }
    }

    private func commitProjectionSnapshot(
        _ snapshot: CodeSessionProjectionSnapshot
    ) {
        let commitStart =
            DispatchTime.now().uptimeNanoseconds
        var published = false
        defer {
            let commitEnd =
                DispatchTime.now()
                    .uptimeNanoseconds
            snapshot.projectionBatch?.finish(
                commitDurationNanoseconds:
                    commitEnd >= commitStart
                    ? commitEnd - commitStart
                    : 0,
                published: published)
        }
        guard projectionCommitFence?
                .accept(
                    identity:
                        snapshot.identity,
                    throughSeq:
                        snapshot.throughSeq)
                == true else {
            return
        }
        published = true

        if let nextItems = snapshot.items,
           nextItems != items {
            items = nextItems
        }
        if let permission = snapshot.permission {
            let nextPending = permission.latest
            if nextPending != pendingPermission {
                pendingPermission = nextPending
            }
            let nextNotice =
                permission.latestResolved
            if nextNotice != permissionNotice {
                permissionNotice = nextNotice
            }
        }
        if let turnStats = snapshot.turnStats,
           turnStats.latest != latestTurnStats {
            latestTurnStats = turnStats.latest
        }
        if let nextAgentState = snapshot.agentState,
           nextAgentState != agentState {
            agentState = nextAgentState
        }
    }

    /// Reattaching a process-owned session to a window must present the
    /// pump's latest exact snapshot immediately. Continuous subscription
    /// normally keeps this view model current; this idempotent flush closes
    /// the race where the window returns while a trailing delta publication is
    /// still pending. The commit fence rejects stale or duplicate snapshots.
    func flushProjectionForPresentation() async {
        guard !isShutdown,
              let projectionPump,
              let snapshot = await projectionPump.flushNow() else {
            return
        }
        commitProjectionSnapshot(snapshot)
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
        if let codexRuntime {
            Task { try? await codexRuntime.interruptCurrentTurn() }
        }
    }

    /// Records one confirmed server-prompt selection, then stages its typed
    /// untrusted contexts for exactly the next Code submission.
    func acceptMCPPromptInsertion(
        _ insertion: MCPPromptInsertion
    ) async throws {
        let codeAgentID =
            AgentID(rawValue: "Coder")
        guard insertion.event.selectedByAgentID == nil
                || insertion.event.selectedByAgentID
                    == codeAgentID else {
            throw IntatisError.permissionDenied(
                "The selected MCP prompt belongs to a different agent.")
        }
        let candidate =
            pendingMCPExternalContexts
                + insertion.externalContexts.map {
                    $0.providerNeutralContext()
                }
        try Self.validateMCPExternalContexts(candidate)
        try await log.append(
            .mcpPromptInserted(insertion.event))
        pendingMCPExternalContexts = candidate
        pendingMCPExternalContextAgentID =
            codeAgentID
        pendingMCPExternalContextCount = candidate.count
    }

    /// Used by other explicit user selections, including server instructions.
    /// The context remains data-only and is consumed only after the next user
    /// message has been durably appended.
    func stageMCPExternalContexts(
        _ contexts: [MCPUntrustedExternalContext]
    ) throws {
        let candidate =
            pendingMCPExternalContexts
                + contexts.map {
                    $0.providerNeutralContext()
                }
        try Self.validateMCPExternalContexts(candidate)
        pendingMCPExternalContexts = candidate
        pendingMCPExternalContextAgentID =
            AgentID(rawValue: "Coder")
        pendingMCPExternalContextCount = candidate.count
    }

    func cancelPendingMCPExternalContexts() {
        pendingMCPExternalContexts.removeAll()
        pendingMCPExternalContextAgentID = nil
        pendingMCPExternalContextCount = 0
    }

    func importDraftAttachments(_ urls: [URL]) {
        guard !isShutdown, !urls.isEmpty else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.attachmentImportOperations
                    .removeValue(forKey: operationID)
            }
            for url in urls {
                guard !Task.isCancelled,
                      !self.isShutdown else {
                    return
                }
                do {
                    let file = try IntatisComposerAttachmentFileReader
                        .read(url)
                    let attachment = try await self
                        .composerAttachmentStore
                        .preserve(file)
                    self.draftAttachments.append(attachment)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.composerError = IntatisLocalization.format(
                        "Attachment %@ could not be preserved: %@",
                        url.lastPathComponent,
                        error.localizedDescription)
                }
            }
        }
        attachmentImportOperations[operationID] = operation
    }

    func removeDraftAttachment(_ id: ArtifactID) {
        guard !isShutdown else { return }
        draftAttachments.removeAll { $0.id == id }
    }

    func reportAttachmentImportFailure(_ error: Error) {
        guard !isShutdown else { return }
        composerError = IntatisLocalization.format(
            "Attachments could not be selected: %@",
            error.localizedDescription)
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
        if let projectionPump,
           let finalSnapshot =
                await projectionPump.finishAndFlush()
        {
            commitProjectionSnapshot(finalSnapshot)
        }
        subscription?.cancel()
        let runningSubscription = subscription
        subscription = nil
        let operation = runningOperation
        operation?.cancel()
        let codexStartupTask = codexStartupTask
        codexStartupTask?.cancel()
        let codexRuntime = codexRuntime
        let codexEventTask = codexEventTask
        codexEventTask?.cancel()
        let attachmentOperations =
            Array(attachmentImportOperations.values)
        for attachmentOperation in attachmentOperations {
            attachmentOperation.cancel()
        }
        let task = Task { @MainActor [weak self] in
            if let self {
                #if canImport(AVFoundation)
                await self.voiceInput.shutdown()
                #endif
                await codexRuntime?.shutdown()
            }
            _ = try? await codexStartupTask?.value
            if let codexEventTask { await codexEventTask.value }
            if let operation { await operation.value }
            for attachmentOperation in attachmentOperations {
                await attachmentOperation.value
            }
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
            self.codexStartupTask = nil
            self.codexRuntime = nil
            self.codexEventTask = nil
            self.codexApprovalIDs.removeAll()
            self.codexApprovalActions.removeAll()
            self.codexWriterLease?.release()
            self.codexWriterLease = nil
            self.attachmentImportOperations.removeAll()
            self.isWorking = false
            self.projectionPump = nil
            self.projectionCommitFence = nil
            let internalLease =
                self.mcpInternalToolRegistryLease
            self.mcpInternalToolRegistryLease = nil
            if let internalLease {
                do {
                    try await internalLease.closeRequiringDrain()
                } catch {
                    self.composerError = error.localizedDescription
                    _ = try? await self.log.append(.error(
                        RuntimeErrorPresentation.payload(
                            for: error,
                            fallbackCode: "internal_tool_drain")))
                }
            }
            self.workspaceAccess?.release()
            self.workspaceAccess = nil
        }
        shutdownTask = task
        await task.value
    }

    func send() {
        guard !isShutdown, !isWorking else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
        guard pendingMCPExternalContexts.isEmpty else {
            composerError = IntatisLocalization.string(
                "This first Codex Runtime version does not import staged Intatis MCP context. Attach MCP servers through the Codex runtime before sending, or cancel the staged context.")
            return
        }
        let originalInput = input
        let originalAttachments = draftAttachments
        let parsed: ParsedUserInput
        if originalInput.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty,
           !originalAttachments.isEmpty {
            parsed = ParsedUserInput(text: "")
        } else {
            switch GoalInputParser.parse(originalInput) {
            case .success(let value):
                parsed = value
            case .failure(.empty):
                return
            case .failure(let error):
                composerError = error.message
                return
            }
        }

        var durableUserMessage = parsed.userMessagePayload
        durableUserMessage.submissionID = SubmissionID.new()
        durableUserMessage.turnID = TurnID.new()
        durableUserMessage.attachments = originalAttachments.isEmpty
            ? nil
            : originalAttachments.map(\.id)
        isWorking = true
        agentState = "starting Codex Runtime"
        composerError = nil
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let runtime = try await self.codexSession()
                let imageURLs = try await self.codexImageURLs(
                    for: originalAttachments)
                try await self.log.append(.userMessage(
                    durableUserMessage))
                self.codexAllowsThreadCreation = false
                if self.input == originalInput {
                    self.input = ""
                }
                if self.draftAttachments.map(\.id)
                    == originalAttachments.map(\.id) {
                    self.draftAttachments = []
                }
                self.agentState = "Codex working"
                _ = try await runtime.runTurn(
                    text: parsed.text,
                    localImageURLs: imageURLs)
                self.composerError = nil
            } catch {
                let cancelled = Task.isCancelled
                let message = error.localizedDescription
                self.composerError = cancelled ? nil : message
                if !cancelled {
                    _ = try? await self.log.append(.error(
                        RuntimeErrorPresentation.payload(
                            for: error,
                            fallbackCode: "codex_runtime")))
                }
            }
            self.isWorking = false
            self.agentState = "idle"
            self.runningOperation = nil
        }
        runningOperation = operation
    }

    /// Retained temporarily only so a source-level/manual rollback can recover
    /// pre-migration behavior. No production path can call it.
    @available(*, unavailable, message: "Code uses Codex App Server")
    private func retainedLegacyAgentLoopSend() {
        guard !isShutdown, !isWorking else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
        let originalInput = input
        let originalAttachments = draftAttachments
        let frozenExternalContexts =
            pendingMCPExternalContexts
        let parsed: ParsedUserInput
        if originalInput
            .trimmingCharacters(
                in: .whitespacesAndNewlines)
            .isEmpty,
           !originalAttachments.isEmpty
                || !frozenExternalContexts.isEmpty {
            parsed = ParsedUserInput(text: "")
        } else {
            switch GoalInputParser.parse(originalInput) {
        case .success(let value):
            parsed = value
        case .failure(.empty):
            return
        case .failure(let error):
            composerError = error.message
            return
            }
        }
        var durableUserMessage =
            parsed.userMessagePayload
        durableUserMessage.submissionID =
            SubmissionID.new()
        durableUserMessage.turnID = TurnID.new()
        durableUserMessage.attachments =
            originalAttachments.isEmpty
                ? nil
                : originalAttachments.map(\.id)
        durableUserMessage.untrustedExternalContexts =
            frozenExternalContexts.isEmpty
                ? nil
                : frozenExternalContexts
        input = ""
        isWorking = true
        composerError = nil
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var didEnterAgentLoop = false
            var internalToolLease:
                HostToolRegistryAugmentationLease?
            do {
                let route =
                    try await self.registry.defaultAgentRuntimeRoute()
                let agent = Agent(name: AgentID(rawValue: "Coder"),
                                  workspaceRoot: self.workspaceRoot,
                                  model: route.model,
                                  profile: .reviewed)
                var capabilityLease =
                    CapabilityLease.coordinator(
                        workspaceAccess: .readWrite)
                capabilityLease.id = CapabilityLeaseID(
                    rawValue:
                        "clease_code_\(self.sessionID.rawValue)")
                capabilityLease.expiresAtTaskCompletion =
                    false
                if let augmenter =
                    self.internalToolRegistryAugmenter {
                    capabilityLease.tools.formUnion(
                        augmenter.additionalCapabilities)
                }
                let durableMCP =
                    try await MCPDurableSessionState.load(
                        from: self.log)
                capabilityLease.mcpGrants =
                    durableMCP.grants(
                        agentID: agent.name,
                        capabilityLeaseID:
                            capabilityLease.id)
                let workspaceLease = WorkspaceLease(
                    id: WorkspaceLeaseID(
                        rawValue:
                            "wlease_code_\(self.sessionID.rawValue)"),
                    workspaceID: WorkspaceID(
                        rawValue:
                            "workspace_code_\(self.sessionID.rawValue)"),
                    rootPath: self.workspaceRoot.path,
                    access: .readWrite)
                let allowsShell = PlatformProfile.current.allowsShell
                let skillSnapshot =
                    try await SkillCatalogService.shared.snapshot(
                        configuration: .standard(
                            workspaceRoot: self.workspaceRoot,
                            access: AppConfig.skillRootAccess),
                        catalogBudget:
                            route.modelContextPolicy
                                .skillCatalogMetadataBudget)
                let hostedWebSearch = capabilityLease.tools.contains(
                    .hostedWebSearch)
                    ? route.hostedWebSearch.map {
                        ProviderHostedWebSearchToolService(route: $0)
                    }
                    : nil
                let unaugmentedRegistry = skillSnapshot.augmenting(
                    ToolRegistry.standard(
                        includesTerminal: allowsShell,
                        hostedWebSearch: hostedWebSearch))
                let baseRegistry: ToolRegistry
                if let augmenter =
                    self.internalToolRegistryAugmenter {
                    let lease = try await augmenter.augment(
                        HostToolRegistryAugmentationInput(
                            sessionID: self.sessionID,
                            agentID: agent.name,
                            taskID: nil,
                            capabilityLease: capabilityLease,
                            workspaceLease: workspaceLease,
                            baseRegistry: unaugmentedRegistry))
                    internalToolLease = lease
                    baseRegistry = lease.registry
                } else {
                    baseRegistry = unaugmentedRegistry
                }
                let runtime = AgentRuntime.code(
                    registry: baseRegistry,
                    allowsShell: allowsShell,
                    modelContextPolicy:
                        route.modelContextPolicy)
                let mcpSource:
                    MCPAgentRequestToolSnapshotSource?
                if durableMCP.attachments.isEmpty {
                    mcpSource = nil
                } else {
                    guard let makeSource =
                            self.mcpSnapshots else {
                        throw IntatisError.config(
                            "This Code session has MCP attachments, but its process-owned MCP runtime is unavailable.")
                    }
                    mcpSource = try await makeSource()
                }
                let dispatchCapabilityLease = capabilityLease
                let toolSnapshotProvider:
                    AgentRequestToolSnapshotProvider?
                if let source = mcpSource {
                    toolSnapshotProvider = {
                        providerCapabilities,
                        outputBudget in
                        try await source.snapshot(
                            for: MCPAgentDispatchInput(
                                agentID:
                                    agent.name,
                                capabilityLease:
                                    dispatchCapabilityLease,
                                workspaceLease:
                                    workspaceLease,
                                baseRegistry:
                                    baseRegistry,
                                activationReason:
                                    .send),
                            providerCapabilities:
                                providerCapabilities,
                            turnResultBudget:
                                outputBudget)
                    }
                } else {
                    toolSnapshotProvider = nil
                }
                let loop = runtime.makeLoop(
                    log: self.log,
                    provider: route.provider,
                    responder: self,
                    agent: agent,
                    context: ContextBuilder(
                        skillSnapshot: skillSnapshot,
                        runtimeEnvironment: .code),
                    terminal: self.terminal,
                    imageGenerator: ProviderImageGenerationToolService(registry: self.registry),
                    imageResolver: AgentImageResolution.resolver(
                        store: self.artifactStore),
                    sessionNaming: self.sessionNaming,
                    capabilityLease: capabilityLease,
                    workspaceLease: workspaceLease,
                    toolSnapshotProvider:
                        toolSnapshotProvider)
                try await self.log.append(
                    .userMessage(durableUserMessage))
                if self.draftAttachments.map(\.id)
                    == originalAttachments.map(\.id) {
                    self.draftAttachments = []
                }
                self.consumeMCPExternalContexts(
                    frozenExternalContexts)
                didEnterAgentLoop = true
                try await loop.send(
                    parsed.text,
                    userMessage: durableUserMessage,
                    recordUserMessage: false,
                    submissionID:
                        durableUserMessage.submissionID)
                if let lease = internalToolLease {
                    try await lease.closeRequiringDrain()
                    internalToolLease = nil
                }
            } catch let runError {
                var effectiveError: Error = runError
                var drainFailed = false
                if let lease = internalToolLease {
                    do {
                        try await lease.closeRequiringDrain()
                    } catch {
                        effectiveError = error
                        drainFailed = true
                    }
                    internalToolLease = nil
                }
                let isInterruption = effectiveError is AgentTurnInterruptedError
                    || IntatisCancellation.isCurrentTaskCancellation(
                        effectiveError)
                let message = effectiveError.localizedDescription
                self.composerError = isInterruption ? nil : message
                if !didEnterAgentLoop || drainFailed {
                    try? await self.log.append(.error(
                        RuntimeErrorPresentation.payload(
                            for: effectiveError,
                            fallbackCode: drainFailed
                                ? "internal_tool_drain"
                                : "agent")))
                }
            }
            self.isWorking = false
            self.runningOperation = nil
        }
        runningOperation = operation
    }

    private func codexSession() async throws -> CodexAppServerSession {
        if let codexRuntime { return codexRuntime }
        if let codexStartupTask {
            return try await codexStartupTask.value
        }
        if !codexAllowsThreadCreation {
            codexAllowsThreadCreation = !Self.containsAgentHistory(
                await log.replay())
        }
        if codexWriterLease == nil {
            codexWriterLease = try log.acquireWriterLease()
        }
        let registry = registry
        let route = try await registry.responsesRuntimeRoute()
        let configuration = CodexRuntimeConfiguration(
            sessionID: sessionID,
            mode: .code,
            workspaceURL: workspaceRoot,
            runtimeRootURL: log.sessionDirectoryURL
                .appendingPathComponent(
                    "codex-runtime",
                    isDirectory: true),
            route: route,
            approvalReviewer: .automatic,
            reasoningEffort: route.reasoningEffort,
            allowsThreadCreation: codexAllowsThreadCreation)
        let task = Task { @MainActor [weak self] () throws
            -> CodexAppServerSession in
            guard let self else { throw CancellationError() }
            let runtime = CodexAppServerSession(
                configuration: configuration)
            self.codexProjectionFailed = false
            let events = await runtime.events()
            let eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handleCodexEvent(event)
                }
            }
            self.codexEventTask = eventTask
            do {
                _ = try await runtime.start()
                try Task.checkCancellation()
                return runtime
            } catch {
                eventTask.cancel()
                await runtime.shutdown()
                throw error
            }
        }
        codexStartupTask = task
        do {
            let runtime = try await task.value
            codexRuntime = runtime
            codexStartupTask = nil
            return runtime
        } catch {
            codexStartupTask = nil
            codexEventTask = nil
            throw error
        }
    }

    private func codexImageURLs(
        for attachments: [IntatisComposerDraftAttachment]
    ) async throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(attachments.count)
        for attachment in attachments {
            guard attachment.mime.hasPrefix("image/") else {
                throw IntatisComposerAttachmentResolutionError.unsupported(
                    attachment.id,
                    mime: attachment.mime,
                    surface: "Codex Runtime")
            }
            guard let ref = await artifactStore.ref(
                for: attachment.id) else {
                throw IntatisComposerAttachmentResolutionError.missing(
                    attachment.id)
            }
            urls.append(artifactStore.absoluteURL(for: ref))
        }
        return urls
    }

    private func handleCodexEvent(
        _ event: CodexRuntimeEvent
    ) async {
        let coder = AgentID(rawValue: "Coder")
        switch event {
        case .ready(let identity):
            if !isWorking {
                agentState = "Codex \(identity.runtimeVersion) ready"
            }
        case .turnStarted:
            isWorking = true
            agentState = "Codex working"
        case .assistantDelta(let itemID, let text):
            _ = await appendCodexProjectionEvent(.messageDelta(
                MessageDeltaPayload(
                    messageId: MessageID(
                        rawValue: "codex:\(itemID)"),
                    role: .assistant,
                    agent: coder,
                    textDelta: text)))
        case .assistantCompleted(let itemID, let text):
            _ = await appendCodexProjectionEvent(.messageCompleted(
                MessageCompletedPayload(
                    messageId: MessageID(
                        rawValue: "codex:\(itemID)"),
                    role: .assistant,
                    agent: coder,
                    text: text)))
        case .reasoningDelta:
            agentState = "Codex reasoning"
        case .itemStarted(let item):
            _ = await appendCodexProjectionEvent(.toolCall(ToolCallPayload(
                toolCallId: "codex:\(item.id)",
                agent: coder,
                name: item.title,
                args: item.detail)))
            agentState = item.kind == .collaboration
                ? "Codex coordinating"
                : "Codex using tools"
        case .itemCompleted(let item):
            let observation = [item.status, item.detail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            _ = await appendCodexProjectionEvent(.toolResult(ToolResultPayload(
                toolCallId: "codex:\(item.id)",
                observation: observation.isEmpty
                    ? "completed"
                    : observation,
                outcome: item.isFailure ? .failed : .succeeded,
                failureSource: item.isFailure ? .runtimeFailed : nil)))
            agentState = "Codex working"
        case .approvalRequested(let request):
            let localID = RequestID.new()
            codexApprovalIDs[localID] = request.requestID
            let payload = PermissionRequestPayload(
                requestId: localID,
                agent: coder,
                tool: request.title,
                args: "",
                risk: .high,
                reason: request.summary,
                approvalMode: .manual)
            permissionQueue.append(PendingPermission(
                request: payload,
                requestedSeq: -1))
            pendingPermission = permissionQueue.first
            agentState = "waiting for permission"
        case .approvalResolved(let runtimeID):
            guard let localID = codexApprovalIDs.first(where: {
                $0.value == runtimeID
            })?.key else { return }
            codexApprovalIDs.removeValue(forKey: localID)
            let action = codexApprovalActions.removeValue(forKey: localID)
            permissionQueue.removeAll { $0.id == localID }
            pendingPermission = permissionQueue.first
            if let action {
                let approved = action == .approve
                    || action == .approveAndRemember
                permissionNotice = PermissionResolutionNotice(
                    id: "codex:\(runtimeID.description)",
                    requestId: localID,
                    tool: "Codex Runtime",
                    decision: approved ? .allow : .deny,
                    risk: .high,
                    reason: approved
                        ? "Codex Runtime request approved by user"
                        : "Codex Runtime request declined by user",
                    source: .user,
                    action: action,
                    resolvedSeq: -1)
            }
        case .turnCompleted(let result):
            let outcome: TurnOutcome
            let failureSource: ExecutionFailureSource?
            switch result.status {
            case "completed":
                outcome = .completed
                failureSource = nil
            case "interrupted":
                outcome = .interrupted
                failureSource = .turnCancelled
            default:
                outcome = .failed
                failureSource = .runtimeFailed
            }
            _ = await appendCodexProjectionEvent(.turnOutcome(
                TurnOutcomePayload(
                    turnID: TurnID(
                        rawValue: "codex:\(result.turnID)"),
                    outcome: outcome,
                    failureSource: failureSource,
                    reason: result.succeeded
                        ? nil
                        : "Codex Runtime turn ended with status \(result.status).",
                    agentID: coder)))
            isWorking = false
            agentState = result.succeeded
                ? "idle"
                : result.status
        case .runtimeError(let code, let message, let fatal):
            composerError = message
            _ = await appendCodexProjectionEvent(.error(ErrorPayload(
                code: code,
                message: fatal
                    ? "Codex Runtime became unavailable."
                    : "Codex Runtime reported a request failure.",
                fatal: fatal)))
            if fatal {
                isWorking = false
                agentState = "runtime unavailable"
                codexRuntime = nil
                codexStartupTask = nil
                codexEventTask = nil
            }
        }
    }

    @discardableResult
    private func appendCodexProjectionEvent(
        _ event: Event
    ) async -> Bool {
        guard !codexProjectionFailed else { return false }
        do {
            _ = try await log.append(event)
            return true
        } catch {
            codexProjectionFailed = true
            composerError = IntatisLocalization.format(
                "Codex Runtime stopped because its Intatis projection could not be persisted: %@",
                error.localizedDescription)
            isWorking = false
            agentState = "projection unavailable"
            let runtime = codexRuntime
            codexRuntime = nil
            codexStartupTask = nil
            codexEventTask = nil
            await runtime?.shutdown()
            return false
        }
    }

    #if canImport(AVFoundation)
    func toggleVoiceInput() {
        guard !isShutdown else { return }
        if !voiceInput.isRecording {
            guard !isWorking else { return }
        }
        voiceInput.toggle { [weak self] transcript in
            guard let self else { return }
            self.input = ComposerVoiceDraft.appending(
                transcript: transcript,
                to: self.input)
        }
    }

    private func observeVoiceInput() {
        voiceInputObservation = voiceInput.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
    #endif

    private func consumeMCPExternalContexts(
        _ frozen: [UntrustedExternalContext]
    ) {
        guard !frozen.isEmpty,
              pendingMCPExternalContexts
                .starts(with: frozen) else {
            return
        }
        pendingMCPExternalContexts.removeFirst(
            frozen.count)
        if pendingMCPExternalContexts.isEmpty {
            pendingMCPExternalContextAgentID = nil
        }
        pendingMCPExternalContextCount =
            pendingMCPExternalContexts.count
    }

    private static func containsAgentHistory(
        _ envelopes: [Envelope]
    ) -> Bool {
        envelopes.contains { envelope in
            switch envelope.event {
            case .userMessage, .messageDelta, .messageCompleted,
                 .toolCall, .toolResult, .patchProposed, .turnOutcome:
                return true
            default:
                return false
            }
        }
    }

    private static func validateMCPExternalContexts(
        _ contexts: [UntrustedExternalContext]
    ) throws {
        guard contexts.count <= 16 else {
            throw IntatisError.config(
                "A submission can include at most 16 external MCP context items.")
        }
        let encoded = try JSONEncoder().encode(contexts)
        guard encoded.count <= 512 * 1_024 else {
            throw IntatisError.config(
                "External MCP context exceeds the 512 KiB submission limit.")
        }
    }

    func mcpProjectAgents()
        async throws -> [MCPProductAgentDescriptor]
    {
        let agentID = AgentID(rawValue: "Coder")
        return [
            MCPProductAgentDescriptor(
                agentID: agentID,
                displayName: "Coder",
                isWorker: false,
                capabilityLeaseID:
                    CapabilityLeaseID(
                        rawValue:
                            "clease_code_\(sessionID.rawValue)"),
                mcpCapabilityCeiling:
                    Set(
                        MCPServerEditorCapabilities
                            .all)),
        ]
    }

    func mcpDispatchInput(
        for descriptor:
            MCPProductAgentDescriptor,
        reason: MCPRuntimeActivationReason
    ) async throws -> MCPAgentDispatchInput {
        guard descriptor.agentID
                == AgentID(rawValue: "Coder"),
              descriptor.capabilityLeaseID
                == CapabilityLeaseID(
                    rawValue:
                        "clease_code_\(sessionID.rawValue)"),
              descriptor.taskID == nil,
              workspaceAccess != nil,
              !isShutdown else {
            throw IntatisError.permissionDenied(
                "The Code MCP Agent or workspace lease is no longer active.")
        }
        var capabilityLease =
            CapabilityLease.coordinator(
                workspaceAccess: .readWrite)
        capabilityLease.id =
            descriptor.capabilityLeaseID
        capabilityLease.expiresAtTaskCompletion =
            false
        if let augmenter =
            internalToolRegistryAugmenter {
            capabilityLease.tools.formUnion(
                augmenter.additionalCapabilities)
        }
        let durable =
            try await MCPDurableSessionState.load(
                from: log)
        capabilityLease.mcpGrants =
            durable.grants(
                agentID: descriptor.agentID,
                capabilityLeaseID:
                    descriptor
                        .capabilityLeaseID,
                taskID: descriptor.taskID)
        let workspaceLease = WorkspaceLease(
            id: WorkspaceLeaseID(
                rawValue:
                    "wlease_code_\(sessionID.rawValue)"),
            workspaceID: WorkspaceID(
                rawValue:
                    "workspace_code_\(sessionID.rawValue)"),
            rootPath: workspaceRoot.path,
            access: .readWrite)
        let allowsShell =
            PlatformProfile.current.allowsShell
        let route =
            try await registry.defaultAgentRuntimeRoute()
        let skillSnapshot =
            try await SkillCatalogService.shared.snapshot(
                configuration: .standard(
                    workspaceRoot: workspaceRoot,
                    access: AppConfig.skillRootAccess),
                catalogBudget:
                    route.modelContextPolicy
                        .skillCatalogMetadataBudget)
        let hostedWebSearch = capabilityLease.tools.contains(
            .hostedWebSearch)
            ? route.hostedWebSearch.map {
                ProviderHostedWebSearchToolService(route: $0)
            }
            : nil
        let unaugmentedRegistry = skillSnapshot.augmenting(
            ToolRegistry.standard(
                includesTerminal:
                    allowsShell,
                hostedWebSearch: hostedWebSearch))
        if let previous = mcpInternalToolRegistryLease {
            mcpInternalToolRegistryLease = nil
            try await previous.closeRequiringDrain()
        }
        let baseRegistry: ToolRegistry
        if let augmenter = internalToolRegistryAugmenter {
            let lease = try await augmenter.augment(
                HostToolRegistryAugmentationInput(
                    sessionID: sessionID,
                    agentID: descriptor.agentID,
                    taskID: descriptor.taskID,
                    capabilityLease: capabilityLease,
                    workspaceLease: workspaceLease,
                    baseRegistry: unaugmentedRegistry))
            mcpInternalToolRegistryLease = lease
            baseRegistry = lease.registry
        } else {
            baseRegistry = unaugmentedRegistry
        }
        return MCPAgentDispatchInput(
            agentID: descriptor.agentID,
            capabilityLease:
                capabilityLease,
            workspaceLease: workspaceLease,
            baseRegistry: baseRegistry,
            activationReason: reason)
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
        if let runtimeRequestID = codexApprovalIDs[request.requestId],
           let codexRuntime {
            if var pending = pendingPermission {
                pending.state = .resolving
                pendingPermission = pending
            }
            codexApprovalActions[request.requestId] = action
            let decision: CodexRuntimeApprovalDecision
            switch action {
            case .approve:
                decision = .accept
            case .approveAndRemember:
                decision = .acceptForSession
            case .decline:
                decision = .decline
            case .cancelTurn:
                decision = .cancel
            }
            Task { @MainActor [weak self] in
                do {
                    try await codexRuntime.resolveApproval(
                        requestID: runtimeRequestID,
                        decision: decision)
                } catch {
                    guard let self else { return }
                    self.codexApprovalActions.removeValue(
                        forKey: request.requestId)
                    if var pending = self.pendingPermission,
                       pending.id == request.requestId {
                        pending.state = .livePending
                        self.pendingPermission = pending
                    }
                    self.composerError = error.localizedDescription
                }
            }
            return
        }
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
        case .approve, .approveAndRemember:
            return PermissionApprovalResolution(
                decision: .allow,
                action: action,
                reason:
                    action == .approveAndRemember
                        ? "Permission approved and exact MCP tool approval remembered by user"
                        : "Permission approved by user",
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
