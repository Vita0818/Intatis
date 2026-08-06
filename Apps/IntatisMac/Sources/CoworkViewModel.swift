#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisArtifacts
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisCowork
import IntatisSkills
import IntatisMCP
import IntatisTools
import IntatisSharedUI
import UniformTypeIdentifiers

private actor ProviderRegistryBox {
    private var registry: ProviderRegistry
    private var controlPlaneBinding: AgentInferenceBinding?

    init(_ registry: ProviderRegistry,
         controlPlaneBinding: AgentInferenceBinding?) {
        self.registry = registry
        self.controlPlaneBinding = controlPlaneBinding
    }

    func update(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    func freezeControlPlaneBinding(
        _ binding: AgentInferenceBinding
    ) -> AgentInferenceBinding {
        if let controlPlaneBinding { return controlPlaneBinding }
        controlPlaneBinding = binding
        return binding
    }

    /// Resolves the exact revision before it is allowed to become the sticky
    /// control-plane route. A legacy/corrupt roster binding must remain
    /// replaceable by a later explicit rebind instead of poisoning the
    /// reviewer for the rest of the process lifetime.
    func freezeResolvableControlPlaneBinding(
        _ binding: AgentInferenceBinding
    ) async -> AgentInferenceBinding? {
        if let controlPlaneBinding {
            guard (try? await registry.agentInference(for: controlPlaneBinding)) != nil else {
                return nil
            }
            return controlPlaneBinding
        }
        guard (try? await registry.agentInference(for: binding)) != nil else {
            return nil
        }
        controlPlaneBinding = binding
        return binding
    }

    func resolvedInference(for agent: Agent) async throws -> ResolvedInferenceProfile {
        guard let binding = agent.agentInferenceBinding else {
            throw IntatisError.config(
                "configurationUnresolved: agent has no exact inference profile binding")
        }
        return try await registry.agentInference(for: binding)
    }

    func provider(for binding: AgentInferenceBinding) async throws -> ToolCallingProvider {
        try await registry.agentInference(for: binding).provider
    }

    func controlPlaneProvider() async throws -> ToolCallingProvider {
        guard let controlPlaneBinding else {
            throw IntatisError.config(
                "configurationUnresolved: control-plane inference profile is not frozen")
        }
        return try await provider(for: controlPlaneBinding)
    }

    func controlPlaneModel(fallback: ModelID) -> ModelID {
        controlPlaneBinding?.modelID ?? fallback
    }

    func exactBindingIsResolvable(_ binding: AgentInferenceBinding) async -> Bool {
        (try? await registry.agentInference(for: binding)) != nil
    }

    func imageToolService() async -> ProviderImageGenerationToolService {
        ProviderImageGenerationToolService(registry: registry)
    }

}

/// Bridges a nonisolated permission request into the MainActor UI without
/// leaving a continuation behind when the requesting task is cancelled before
/// registration finishes. Resolution is lock-protected because cancellation
/// may race the MainActor approval action.
private final class CoworkPermissionWaiter: @unchecked Sendable {
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
        if let completed {
            continuation.resume(returning: completed)
        }
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

struct CoworkGoalEditDraft: Equatable {
    var objective: String
    var successCriteria: String
    var constraints: String
    var tokenBudget: String
}

struct CoworkDraftAttachment: Identifiable, Equatable {
    var id: ArtifactID
    var name: String
    var mime: String
}

enum CoworkSessionLaunchMode: Sendable {
    case fresh
    case restored
}

/// Cowork's GUI runs in automatic-review mode. If that control plane is not
/// available, an ask-class tool must fail only that permission request; it must
/// never silently fall back to a manual sheet or prevent ordinary submission.
private struct CoworkUnavailableAutomaticPermissionResponder: PermissionResponder {
    var approvalMode: PermissionApprovalMode { .automaticReviewer }

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        .deny
    }

    func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: .deny,
            reason: "Automatic permission review is unavailable; this tool request was denied without changing the submission.",
            risk: request.risk,
            source: .automaticReviewerFailure,
            failureKind: .controlPlaneShutdown,
            failureSource: .reviewerFailed)
    }
}

private enum CoworkSubmissionAttachmentError: LocalizedError {
    case missing(ArtifactID)
    case unsupported(ArtifactID, String)
    case unreadable(ArtifactID, String)

    var errorDescription: String? {
        switch self {
        case .missing(let id):
            return "Attachment \(id.rawValue) is no longer available in this session."
        case .unsupported(let id, let mime):
            return "Attachment \(id.rawValue) uses \(mime), but Cowork remote execution currently accepts image attachments only. The submitted file remains preserved locally."
        case .unreadable(let id, let message):
            return "Attachment \(id.rawValue) could not be read: \(message)"
        }
    }

    var code: String {
        switch self {
        case .missing: return "attachment_missing"
        case .unsupported: return "attachment_type_unsupported"
        case .unreadable: return "attachment_unreadable"
        }
    }

    var retryable: Bool {
        switch self {
        case .missing, .unsupported: return false
        case .unreadable: return true
        }
    }
}

/// MainActor-owned latest-only fanout. It is intentionally not ObservableObject:
/// non-selected agents must not invalidate a window's transcript subtree.
@MainActor
private final class CoworkAgentThreadUpdateHub {
    private struct Subscription {
        let agentID: AgentID
        let continuation: AsyncStream<CoworkAgentThreadUpdate>.Continuation
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private var revisions: [AgentID: UInt64] = [:]
    private var throughSeqByAgent: [AgentID: Int] = [:]

    func stream(for agentID: AgentID) -> AsyncStream<CoworkAgentThreadUpdate> {
        let id = UUID()
        let pair = AsyncStream<CoworkAgentThreadUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        subscriptions[id] = Subscription(
            agentID: agentID,
            continuation: pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.subscriptions.removeValue(forKey: id)
            }
        }
        return pair.stream
    }

    func publish(agentIDs: [AgentID], throughSeq: Int) {
        for agentID in Set(agentIDs) {
            revisions[agentID, default: 0] &+= 1
            throughSeqByAgent[agentID] = max(
                throughSeqByAgent[agentID] ?? -1,
                throughSeq)
            let update = CoworkAgentThreadUpdate(
                agentID: agentID,
                throughSeq: throughSeqByAgent[agentID] ?? throughSeq,
                revision: revisions[agentID] ?? 0)
            for subscription in subscriptions.values
                where subscription.agentID == agentID {
                subscription.continuation.yield(update)
            }
        }
    }
}

/// Drives a Cowork project session: user input defaults to the project `Main`
/// agent, while the orchestrator and scheduler handle sub-agent work behind it.
/// The view model folds the shared event log into the visible thread, project
/// summary, and agent roster.
@MainActor
final class CoworkViewModel: ObservableObject, PermissionResponder {
    @Published private(set) var agents: [CoworkAgentInfo] = []
    @Published private(set) var summary = CoworkStatusSummary()
    @Published private(set) var project = CoworkProjectInfo()
    @Published private(set) var goal: CoworkGoalCardInfo?
    @Published private(set) var workTasks = CoworkWorkTaskSummary()
    @Published private(set) var projectSettings: CoworkProjectSettings
    @Published var input: String = ""
    @Published private(set) var draftAttachments: [CoworkDraftAttachment] = []
    @Published private(set) var pendingMCPExternalContextCount = 0
    @Published private(set) var isAcceptingSubmission = false
    @Published private(set) var isWorking = false {
        didSet { refreshRuntimeBusy() }
    }
    @Published private(set) var isAgentWorkActive = false {
        didSet { refreshRuntimeBusy() }
    }
    @Published private(set) var isGoalContinuing = false {
        didSet { refreshRuntimeBusy() }
    }
    @Published private(set) var runtimeBusy = false
    @Published private(set) var isGoalRuntimeReady = false
    @Published var pendingPermission: PendingPermission?
    @Published private(set) var permissionNotice: PermissionResolutionNotice?
    @Published private(set) var latestTurnStats: TurnStatsSnapshot?
    @Published private(set) var composerError: String?
    @Published private(set) var projectionError: String?
    @Published private(set) var sessionStorageWarning: String?
    @Published private(set) var needsPrimaryWorkspaceAuthorization = false
    @Published private(set) var addAgentStatus: CoworkAddAgentStatus = .idle
    @Published private(set) var permissionReviewerStatus: CoworkPermissionReviewerStatus = .disabled
    @Published private(set) var inferenceProfileOptions: [AppInferenceProfileOption]
    @Published private(set) var inferenceResolutionFailures: [String: String] = [:]
    @Published private var nextMainInferenceOption: AppInferenceProfileOption?

    #if canImport(AVFoundation)
    let voiceInput: ComposerVoiceInputController
    private var voiceInputObservation: AnyCancellable?
    #endif

    var isAutomaticPermissionReviewReady: Bool {
        switch permissionReviewerStatus {
        case .enabled, .degraded:
            return true
        case .disabled, .enabling, .fallback, .failed:
            return false
        }
    }

    var isMainInferenceReady: Bool {
        liveAgentInfo(named: projectSettings.mainAgentName)?
            .inferenceResolution == .resolved
    }

    var mainInferenceDisplayLabel: String {
        guard let main = liveAgentInfo(named: projectSettings.mainAgentName) else {
            return IntatisLocalization.format(
                "@%@ inference not attached",
                projectSettings.mainAgentName)
        }
        return main.inferenceDisplayLabel ?? IntatisLocalization.format(
            "@%@ inference unavailable",
            main.name)
    }

    /// Composer selection for the next submission hosted by `@main`.
    /// This intentionally does not mutate the live agent binding until the
    /// frozen submission reaches its FIFO execution boundary.
    var nextMainInferenceBinding: AgentInferenceBinding? {
        if let staged = nextMainInferenceOption,
           inferenceProfileOptions.contains(where: { $0.binding == staged.binding }) {
            return staged.binding
        }
        guard let live = agentInferenceBinding(name: projectSettings.mainAgentName),
              inferenceProfileOptions.contains(where: { $0.binding == live }) else {
            return nil
        }
        return live
    }

    var nextMainInferenceDisplayLabel: String {
        nextMainInferenceOption?.title ?? mainInferenceDisplayLabel
    }

    /// Project/roster mutations cannot cross an active invocation or Goal.
    /// The composer selector is intentionally independent from this fence.
    var isRuntimeMutationBlocked: Bool {
        isWorking || isGoalContinuing
    }

    var inferenceComposerError: String? {
        guard liveAgentInfo(named: projectSettings.mainAgentName) != nil,
              !isMainInferenceReady else {
            return nil
        }
        return IntatisLocalization.format(
            "@%@ needs an explicit, resolvable inference profile rebind before Cowork can run.",
            projectSettings.mainAgentName)
    }

    private let log: EventLog
    var mcpEventLog: EventLog { log }
    var mcpWorkspacePaths: [String] {
        projectSettings.workspaces.map(\.path)
    }
    var mcpArtifactStore: ArtifactStore {
        artifactStore
    }
    private let sessionNaming: SessionNamingService
    private let artifactStore: ArtifactStore
    private let submittedIntentStore: SubmittedIntentStore
    private let registryBox: ProviderRegistryBox
    private let mcpSnapshots:
        (@MainActor @Sendable () async throws
            -> MCPAgentRequestToolSnapshotSource)?
    private var orchestrator: Orchestrator?
    private var goalRuntime: GoalRuntimeController?
    private var subscription: Task<Void, Never>?
    private var projectionPump:
        SessionProjectionPump<
            CoworkSessionProjectionState,
            ContinuousClock>?
    private var projectionCommitFence:
        SessionProjectionCommitFence?
    private var shutdownTask: Task<Void, Never>? {
        didSet { refreshRuntimeBusy() }
    }
    private var didStop = false
    private var isCancellingCurrentActivity = false
    private var permissionWaiters: [RequestID: CoworkPermissionWaiter] = [:]
    private var permissionQueue: [PendingPermission] = []
    private var suppressedPermissionRequestIDs: Set<RequestID> = []
    private var activeOperations: [UUID: Task<Void, Never>] = [:] {
        didSet { refreshRuntimeBusy() }
    }
    private var directOperationIDs: Set<UUID> = [] {
        didSet { refreshRuntimeBusy() }
    }
    private var directOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let agentThreadUpdateHub = CoworkAgentThreadUpdateHub()
    private var submissionQueue: [SubmissionID] = []
    private var submittedPayloads: [SubmissionID: UserMessagePayload] = [:]
    private var canonicalSubmissionIDs: Set<SubmissionID> = []
    private var submissionAttempts: [SubmissionID: Int] = [:]
    private var submissionRetryTasks: [SubmissionID: CoworkTaskView] = [:]
    private var restoredSubmissionIDs: Set<SubmissionID> = []
    private var outboxEntries: [SubmissionID: SubmittedIntentOutboxEntry] = [:]
    private var outboxThreadItemsByAgent: [AgentID: [CodeItem]] = [:]
    private var pendingMCPExternalContexts:
        [UntrustedExternalContext] = []
    private var pendingMCPExternalContextAgentID:
        AgentID?
    private var submissionDrainRunning = false
    private var retryableTasks: [String: CoworkTaskView] = [:]
    private var latestCoworkProjection = CoworkProjection()
    private var didRequestMainAgentAttach = false
    private var workspaceAccessLeases: [String: WorkspaceAccessLease] = [:]
    private var steadyPermissionReviewerStatus: CoworkPermissionReviewerStatus = .disabled
    private let launchMode: CoworkSessionLaunchMode
    let sessionID: SessionID

    init(sessionID: SessionID,
         log: EventLog,
         artifactStore: ArtifactStore,
         sessionNaming: SessionNamingService,
         registry: ProviderRegistry,
         inferenceProfileOptions: [AppInferenceProfileOption],
         projectSettings: CoworkProjectSettings,
         launchMode: CoworkSessionLaunchMode = .restored,
         sessionStorageWarning: String? = nil,
         initialWorkspaceAccess: WorkspaceAccessLease? = nil,
         mcpSnapshots:
            (@MainActor @Sendable () async throws
                -> MCPAgentRequestToolSnapshotSource)?
                = nil) {
        self.sessionID = sessionID
        self.log = log
        self.sessionNaming = sessionNaming
        self.artifactStore = artifactStore
        self.submittedIntentStore = SubmittedIntentStore(log: log)
        self.registryBox = ProviderRegistryBox(
            registry,
            controlPlaneBinding: nil)
        #if canImport(AVFoundation)
        self.voiceInput = ComposerVoiceInputController(registry: registry)
        #endif
        self.mcpSnapshots = mcpSnapshots
        self.inferenceProfileOptions = inferenceProfileOptions
        self.nextMainInferenceOption = nil
        self.projectSettings = projectSettings
        self.launchMode = launchMode
        self.sessionStorageWarning = sessionStorageWarning
        if let initialWorkspaceAccess {
            self.workspaceAccessLeases[initialWorkspaceAccess.canonicalPath] = initialWorkspaceAccess
        }
        self.project = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: projectSettings,
            projection: CoworkProjection())
        #if canImport(AVFoundation)
        observeVoiceInput()
        #endif
    }

    deinit {
        subscription?.cancel()
    }

    var hasActiveWork: Bool {
        isWorking
            || isAgentWorkActive
            || isGoalContinuing
            || !activeOperations.isEmpty
            || !directOperationIDs.isEmpty
            || shutdownTask != nil
    }

    private func refreshRuntimeBusy() {
        let nextValue = hasActiveWork
        guard runtimeBusy != nextValue else { return }
        runtimeBusy = nextValue
    }

    private var acceptsNewOperations: Bool {
        !didStop && shutdownTask == nil
    }

    private func beginDirectOperation() -> UUID? {
        guard acceptsNewOperations else { return nil }
        let operationID = UUID()
        directOperationIDs.insert(operationID)
        return operationID
    }

    private func finishDirectOperation(_ operationID: UUID) {
        guard directOperationIDs.remove(operationID) != nil,
              directOperationIDs.isEmpty else { return }
        let waiters = directOperationDrainWaiters
        directOperationDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForDirectOperationsToDrain() async {
        guard !directOperationIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            directOperationDrainWaiters.append(continuation)
        }
    }

    func updateProviderRegistry(
        _ registry: ProviderRegistry,
        inferenceProfileOptions: [AppInferenceProfileOption]? = nil
    ) {
        guard acceptsNewOperations else { return }
        #if canImport(AVFoundation)
        voiceInput.updateProviderRegistry(registry)
        #endif
        let refreshedOptions = inferenceProfileOptions
        let approvedOptions = refreshedOptions ?? self.inferenceProfileOptions
        let bindings = approvedOptions.map(\.binding)
        let routingMetadata = approvedOptions.map {
            InferenceProfileRoutingMetadata(
                inferenceProfileID: $0.binding.inferenceProfileID,
                declaredCapabilities: $0.declaredCapabilities)
        }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await self.registryBox.update(registry)
            await self.orchestrator?.updateAvailableInferenceProfiles(
                bindings,
                routingMetadata: routingMetadata,
                hostAuthorized: true)
            // Publish new menu entries only after Orchestrator has accepted the
            // same host-approved snapshot, so a newly visible choice cannot
            // race a stale admission catalog.
            if let refreshedOptions {
                if let staged = self.nextMainInferenceOption {
                    self.nextMainInferenceOption = refreshedOptions.first(where: {
                        $0.binding == staged.binding
                    })
                }
                self.inferenceProfileOptions = refreshedOptions
            }
            await self.refreshInferenceResolutionState()
        }
        activeOperations[operationID] = operation
    }

    func start() {
        guard !didStop, orchestrator == nil, shutdownTask == nil else { return }
        let projectionIdentity =
            SessionProjectionIdentity(
                sessionID: sessionID)
        let projectionPump =
            SessionProjectionPump<
                CoworkSessionProjectionState,
                ContinuousClock>(
                    identity: projectionIdentity,
                    clock: ContinuousClock())
        projectionCommitFence =
            SessionProjectionCommitFence(
                identity:
                    projectionIdentity)
        self.projectionPump =
            projectionPump
        setPermissionReviewerStatus(.enabling)
        let registryBox = registryBox
        let makeMCPSnapshots = mcpSnapshots
        let mcpLog = log
        let toolSnapshotProvider:
            Orchestrator.ToolSnapshotProvider?
        if let makeSource = makeMCPSnapshots {
            toolSnapshotProvider = {
                agent,
                capabilityLease,
                workspaceLease,
                baseRegistry,
                isResume,
                providerCapabilities,
                outputBudget in
                let state =
                    try await MCPDurableSessionState
                        .load(from: mcpLog)
                guard !state.attachments.isEmpty else {
                    return nil
                }
                guard let workspaceLease else {
                    throw IntatisError.config(
                        "MCP dispatch requires an exact workspace lease")
                }
                let source =
                    try await makeSource()
                return try await source.snapshot(
                    for: MCPAgentDispatchInput(
                        agentID: agent.name,
                        capabilityLease:
                            capabilityLease,
                        workspaceLease:
                            workspaceLease,
                        baseRegistry:
                            baseRegistry,
                        activationReason:
                            isResume
                                ? .resume
                                : .send),
                    providerCapabilities:
                        providerCapabilities,
                    turnResultBudget:
                        outputBudget)
            }
        } else {
            toolSnapshotProvider = nil
        }
        do {
            let runtime = try Orchestrator.runtime(
                log: log,
                allowsShell: PlatformProfile.current.allowsShell,
                responder: CoworkUnavailableAutomaticPermissionResponder(),
                executionPolicy: CoworkExecutionPolicy(tokenBudget: projectSettings.tokenBudget),
                skillRootAccess: AppConfig.skillRootAccess,
                availableInferenceProfiles: inferenceProfileOptions.map(\.binding),
                inferenceProfileRoutingMetadata: inferenceProfileOptions.map {
                    InferenceProfileRoutingMetadata(
                        inferenceProfileID: $0.binding.inferenceProfileID,
                        declaredCapabilities: $0.declaredCapabilities)
                },
                requiresInferenceBindings: true,
                imageGeneratorFor: { _ in await registryBox.imageToolService() },
                toolSnapshotProvider:
                    toolSnapshotProvider,
                sessionNaming: sessionNaming,
                resolvedInferenceFor: { agent in
                    try await registryBox.resolvedInference(for: agent)
                })
            orchestrator = runtime
            let verifierFallbackModel = projectSettings.defaultInferenceProfileBinding?.modelID
                ?? inferenceProfileOptions.first?.binding.modelID
                ?? ModelID(rawValue: AppConfig.defaultModel)
            goalRuntime = GoalRuntimeController(
                sessionID: sessionID,
                log: log,
                orchestrator: runtime,
                verifierProvider: { try await registryBox.controlPlaneProvider() },
                verifierModel: {
                    await registryBox.controlPlaneModel(fallback: verifierFallbackModel)
                })
        } catch {
            let message = RuntimeErrorPresentation.message(for: error)
            projectionError = IntatisLocalization.format(
                "Cowork session could not start: %@",
                message)
            setPermissionReviewerStatus(.failed(message))
            return
        }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replayed = await self.log.replay()
                let preRestore =
                    try await projectionPump
                        .loadInitialReplay(
                            replayed)
                let replayedCowork =
                    preRestore.cowork
                        ?? CoworkProjection()
                self.restoreWorkspaceAccess(
                    for: replayedCowork)
                await self.orchestrator?.restore(
                    from: replayedCowork)
                await self.refreshInferenceResolutionState()

                // Restore may durably reconcile stale control-plane state.
                // Build every projection on the non-MainActor pump from that
                // authoritative tail, then register the stream before
                // bootstrap can append additional admission events.
                let restored =
                    await self.log.replay()
                let initial =
                    try await projectionPump
                        .synchronize(
                            with: restored,
                            markRestoredPermissionsNeedsRerun:
                                true)
                if let restoredProjection =
                        initial.cowork {
                    self.restoreSubmittedIntentState(
                        from: restoredProjection,
                        marksUnfinishedAsInterrupted:
                            true)
                }
                await self.restoreSubmittedIntentOutbox()
                self.commitProjectionSnapshot(initial)
                let stream = await self.log.stream(
                    from:
                        (restored.last?.seq ?? -1)
                            + 1)
                let publications =
                    try await projectionPump
                        .publications(
                            consuming: stream)
                let initialCoworkProjection =
                    initial.cowork
                        ?? replayedCowork

                if self.launchMode == .fresh {
                    // Choosing the primary workspace is the explicit
                    // authorization for the fixed @main bootstrap. Do not ask
                    // a model to approve that same user choice a second time.
                    await self.bootstrapMainAgentIfNeeded(
                        existingProjection:
                            initialCoworkProjection,
                        allowsInitialSessionBootstrap:
                            true)
                    if let orchestrator =
                            self.orchestrator {
                        await self
                            .synchronizePermissionReviewerHealth(
                                using: orchestrator)
                    }
                } else {
                    // Restore @main from canonical settings and the
                    // session-owned bookmark before starting the reviewer.
                    await self.bootstrapMainAgentIfNeeded(
                        existingProjection:
                            initialCoworkProjection,
                        allowsInitialSessionBootstrap:
                            false)
                    // Data-plane/Goal recovery is independent from permission
                    // reviewer readiness. Until the reviewer is live, the
                    // fail-closed responder above denies only ask-class tools.
                    await self.resumeRuntimeIfReady()
                    await self.ensureAutomaticPermissionReview(
                        existingProjection:
                            self.latestCoworkProjection)
                }
                // Fresh-session registration may already include a healthy
                // reviewer, but data-plane readiness does not depend on it.
                await self.resumeRuntimeIfReady()
                for await output in publications {
                    guard !Task.isCancelled else {
                        break
                    }
                    switch output {
                    case .snapshot(let snapshot):
                        self.commitProjectionSnapshot(
                            snapshot)
                    case .failed(let failure):
                        guard self.projectionCommitFence?
                                .identity
                                == projectionIdentity else {
                            continue
                        }
                        self.projectionError =
                            failure.localizedDescription
                    }
                }
            } catch {
                guard self.projectionCommitFence?
                        .identity
                        == projectionIdentity,
                      !Task.isCancelled else {
                    return
                }
                self.projectionError =
                    error.localizedDescription
            }
        }
    }

    private func commitProjectionSnapshot(
        _ snapshot:
            CoworkSessionProjectionSnapshot
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

        if let barrier =
                snapshot.barrierEnvelope {
            observeProjectionBarrier(barrier)
        }
        let changedThreadAgents = IntatisExecutionTracePresentation.isEnabled
            ? snapshot.threadAgentIDs
            : snapshot.visibleThreadAgentIDs
        if !changedThreadAgents.isEmpty {
            agentThreadUpdateHub.publish(
                agentIDs: changedThreadAgents,
                throughSeq: snapshot.throughSeq)
        }
        if let permission =
                snapshot.permission {
            let nextPending =
                presentedPermission(
                    projected:
                        permission.latest)
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
           turnStats.latest
                != latestTurnStats {
            latestTurnStats =
                turnStats.latest
        }
        if let coworkProjection =
                snapshot.cowork,
           coworkProjection
                != latestCoworkProjection {
            applyCoworkProjection(
                coworkProjection)
        }
    }

    /// Reattaching a process-owned Cowork session to a window performs one
    /// idempotent latest-snapshot flush. The normal subscription remains live
    /// while the session is off-screen; this only closes the bounded trailing
    /// publication race and cannot overwrite a newer generation/sequence.
    func flushProjectionForPresentation() async {
        guard !didStop,
              let projectionPump,
              let snapshot =
                await projectionPump.flushNow() else {
            return
        }
        commitProjectionSnapshot(snapshot)
    }

    private func observeProjectionBarrier(
        _ envelope: Envelope
    ) {
        if case .permissionResolved(let payload) =
                envelope.event,
           let requestID = payload.requestId {
            suppressedPermissionRequestIDs
                .remove(requestID)
        }
        observeSubmittedIntentEvent(envelope)
    }

    func mcpProjectAgents()
        async throws -> [MCPProductAgentDescriptor]
    {
        let projection = latestCoworkProjection
        let main = AgentID(
            rawValue: projectSettings.mainAgentName)
        return projection.capabilityLeaseAgents
            .compactMap { leaseID, agentID in
                guard let lease =
                        projection.capabilityLeases[
                            leaseID],
                      projection.agentRoster[
                        agentID] != nil else {
                    return nil
                }
                let reviewer =
                    MCPReservedControlPlaneIdentity
                        .deniesMCP(agentID)
                let taskSuffix = lease.taskID.map {
                    " · task \($0.rawValue)"
                } ?? ""
                return MCPProductAgentDescriptor(
                    agentID: agentID,
                    displayName:
                        "\(agentID.rawValue)\(taskSuffix)",
                    parentAgentID:
                        projection.agentOwners[
                            agentID],
                    isWorker:
                        agentID != main,
                    isPermissionReviewer:
                        reviewer,
                    capabilityLeaseID:
                        lease.id,
                    taskID: lease.taskID,
                    mcpCapabilityCeiling:
                        reviewer
                            ? []
                            : Set(
                                MCPServerEditorCapabilities
                                    .all))
            }
            .sorted {
                if $0.agentID != $1.agentID {
                    return $0.agentID.rawValue
                        < $1.agentID.rawValue
                }
                return $0.capabilityLeaseID.rawValue
                    < $1.capabilityLeaseID.rawValue
            }
    }

    func mcpDispatchInput(
        for descriptor:
            MCPProductAgentDescriptor,
        reason: MCPRuntimeActivationReason
    ) async throws -> MCPAgentDispatchInput {
        let projection = latestCoworkProjection
        guard !didStop,
              !descriptor.isPermissionReviewer,
              !MCPReservedControlPlaneIdentity
                .deniesMCP(
                    descriptor.agentID),
              projection.capabilityLeaseAgents[
                descriptor.capabilityLeaseID]
                == descriptor.agentID,
              var capabilityLease =
                projection.capabilityLeases[
                    descriptor.capabilityLeaseID],
              capabilityLease.taskID
                == descriptor.taskID else {
            throw IntatisError.permissionDenied(
                "The selected Cowork Agent capability lease is no longer active.")
        }
        let workspaceCandidates =
            projection.workspaceLeaseAgents
                .compactMap {
                    leaseID, agentID
                    -> WorkspaceLease? in
                    guard agentID
                            == descriptor.agentID,
                          let lease =
                            projection.workspaceLeases[
                                leaseID],
                          lease.taskID
                            == descriptor.taskID
                    else {
                        return nil
                    }
                    return lease
                }
        guard workspaceCandidates.count == 1,
              let workspaceLease =
                workspaceCandidates.first,
              workspaceLease.rootIdentity?
                .matchesCurrentDirectory(
                    rootPath:
                        workspaceLease.rootPath)
                == true else {
            throw IntatisError.permissionDenied(
                "The selected Cowork Agent does not have one exact live workspace lease.")
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
        let workspaceRoot =
            URL(fileURLWithPath:
                    workspaceLease.rootPath)
                .standardizedFileURL
        let allowsShell =
            PlatformProfile.current.allowsShell
        let skillSnapshot =
            try await SkillCatalogService.shared.snapshot(
                configuration: .standard(
                    workspaceRoot: workspaceRoot,
                    access: AppConfig.skillRootAccess))
        return MCPAgentDispatchInput(
            agentID: descriptor.agentID,
            capabilityLease:
                capabilityLease,
            workspaceLease: workspaceLease,
            baseRegistry: skillSnapshot.augmenting(
                ToolRegistry.standard(
                    includesTerminal:
                        allowsShell)),
            activationReason: reason)
    }

    func stop(reason: String = "Cowork session stopped") async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !didStop else { return }
        didStop = true
        if let projectionPump,
           let finalSnapshot =
                await projectionPump.finishAndFlush()
        {
            commitProjectionSnapshot(
                finalSnapshot)
        }
        let runningSubscription = subscription
        runningSubscription?.cancel()
        subscription = nil
        let runningOrchestrator = orchestrator
        let runningGoalRuntime = goalRuntime
        let runningOperations = Array(activeOperations.values)
        orchestrator = nil
        goalRuntime = nil
        for operation in runningOperations { operation.cancel() }
        isWorking = false
        isAgentWorkActive = false
        isGoalContinuing = false
        isGoalRuntimeReady = false
        goal = Self.goalPresentation(
            from: latestCoworkProjection,
            controlsEnabled: false)
        addAgentStatus = .idle
        setPermissionReviewerStatus(.disabled)
        let task = Task<Void, Never> {
            #if canImport(AVFoundation)
            await self.voiceInput.shutdown()
            #endif
            // Let the cancelled startup/stream task observe cancellation before
            // teardown touches the captured runtime. This prevents a stale
            // startup continuation from releasing the restore scheduler gate.
            if let runningSubscription { await runningSubscription.value }
            if let runningGoalRuntime {
                await runningGoalRuntime.shutdown()
            }
            if let runningOrchestrator {
                await runningOrchestrator.cancelAll(reason: reason)
            }
            for operation in runningOperations { await operation.value }
            await self.waitForDirectOperationsToDrain()
        }
        shutdownTask = task
        await task.value
        activeOperations.removeAll()
        // Execution owns permission waits. Release any UI-only waiters only
        // after every data-plane task has observed cancellation and exited.
        for (requestID, waiter) in permissionWaiters {
            suppressedPermissionRequestIDs.insert(requestID)
            waiter.resolve(Self.cancelledPermissionResolution(
                reason: reason))
        }
        permissionWaiters.removeAll()
        permissionQueue.removeAll()
        if var pending = pendingPermission, pending.state.isActionable {
            pending.state = .expired
            pendingPermission = pending
        }
        for lease in workspaceAccessLeases.values { lease.release() }
        workspaceAccessLeases.removeAll()
        projectionPump = nil
        projectionCommitFence = nil
        shutdownTask = nil
    }

    private func restoreSubmittedIntentState(
        from projection: CoworkProjection,
        marksUnfinishedAsInterrupted: Bool
    ) {
        for intent in projection.submittedIntents {
            submittedPayloads[intent.id] = intent.payload
            canonicalSubmissionIDs.insert(intent.id)
            if let attempt = intent.attempt {
                submissionAttempts[intent.id] = attempt
            }
            if marksUnfinishedAsInterrupted,
               intent.status == .queued || intent.status == .running {
                restoredSubmissionIDs.insert(intent.id)
            }
        }
    }

    private func restoreSubmittedIntentOutbox() async {
        do {
            let document = try await submittedIntentStore.loadOutbox()
            outboxEntries = Dictionary(
                uniqueKeysWithValues: document.entries.compactMap { entry in
                    guard let id = entry.payload.submissionID else { return nil }
                    return (id, entry)
                })
            rebuildOutboxThreadItems(publishesChanges: true)
        } catch {
            composerError = IntatisLocalization.format(
                "The local submission outbox could not be read: %@",
                error.localizedDescription)
        }
    }

    private func observeSubmittedIntentEvent(_ envelope: Envelope) {
        switch envelope.event {
        case .userMessage(let payload):
            guard let id = payload.submissionID else { return }
            canonicalSubmissionIDs.insert(id)
            guard submittedPayloads[id] == nil else {
                rebuildOutboxThreadItems(publishesChanges: false)
                return
            }
            submittedPayloads[id] = payload
            // A canonical user row supersedes an owner-only outbox overlay.
            // The same snapshot already publishes the typed target agent.
            rebuildOutboxThreadItems(publishesChanges: false)
        case .submissionStatusChanged(let payload):
            submissionAttempts[payload.submissionID] = max(
                submissionAttempts[payload.submissionID] ?? 0,
                payload.attempt)
            if payload.status == .completed || payload.status == .cancelled {
                submissionQueue.removeAll { $0 == payload.submissionID }
            }
        default:
            break
        }
    }

    func agentThreadUpdates(
        for agentID: AgentID
    ) -> AsyncStream<CoworkAgentThreadUpdate> {
        agentThreadUpdateHub.stream(for: agentID)
    }

    func agentThreadPage(
        agentID: AgentID,
        requestedUpperBound: Int?
    ) async -> CoworkAgentThreadPage {
        let additionalItems = outboxThreadItemsByAgent[agentID] ?? []
        guard let projectionPump else {
            return CodeProjection().coworkAgentThreadPage(
                agentID: agentID,
                requestedUpperBound: requestedUpperBound,
                showsExecutionTrace:
                    IntatisExecutionTracePresentation.isEnabled,
                additionalItems: additionalItems,
                projectedThroughSeq: -1,
                projectionGeneration: UUID(),
                isAgentWorking: false)
        }
        let projected = await projectionPump.coworkAgentThreadPage(
            agentID: agentID,
            requestedUpperBound: requestedUpperBound,
            showsExecutionTrace: IntatisExecutionTracePresentation.isEnabled,
            additionalItems: additionalItems)
        let interruptedFailure = SubmissionFailure(
            code: "interrupted",
            message: IntatisLocalization.string(
                "This submission was queued or running when the previous runtime stopped. Retry explicitly to run it again."),
            retryable: true)
        let items = projected.items.map { item -> CodeItem in
            guard item.kind == .user,
                  let submissionID = item.submissionID,
                  restoredSubmissionIDs.contains(submissionID) else {
                return item
            }
            var interrupted = item
            interrupted.submissionStatus = .failed
            interrupted.submissionFailure = interruptedFailure
            interrupted.isFailure = true
            return interrupted
        }
        return CoworkAgentThreadPage(
            agentID: projected.agentID,
            items: items,
            lowerBound: projected.lowerBound,
            upperBound: projected.upperBound,
            totalCount: projected.totalCount,
            capacity: projected.capacity,
            projectedThroughSeq: projected.projectedThroughSeq,
            projectionGeneration: projected.projectionGeneration,
            isAgentWorking: projected.isAgentWorking)
    }

    private func rebuildOutboxThreadItems(
        publishesChanges: Bool
    ) {
        let previous = outboxThreadItemsByAgent
        var next: [AgentID: [CodeItem]] = [:]
        for entry in outboxEntries.values.sorted(by: {
            $0.createdAt < $1.createdAt
        }) {
            guard let id = entry.payload.submissionID,
                  !canonicalSubmissionIDs.contains(id) else { continue }
            let failure = SubmissionFailure(
                code: "event_log_unavailable",
                message: entry.lastCanonicalError
                    ?? IntatisLocalization.string(
                        "The submission is safe in the local outbox but has not entered the session EventLog."),
                retryable: true)
            let item = CodeItem(
                id: id.rawValue,
                kind: .user,
                title: IntatisLocalization.string("You"),
                body: entry.payload.text,
                tags: entry.payload.tags ?? [],
                goal: entry.payload.goal,
                attachments: entry.payload.attachments ?? [],
                isFailure: true,
                submissionID: id,
                submissionStatus: .failed,
                submissionAttempt: nil,
                submissionFailure: failure)
            let agentID = entry.payload.to
                ?? AgentID(rawValue: projectSettings.mainAgentName)
            next[agentID, default: []].append(item)
        }
        guard next != previous else { return }
        outboxThreadItemsByAgent = next
        guard publishesChanges else { return }
        agentThreadUpdateHub.publish(
            agentIDs: Array(Set(previous.keys).union(next.keys)),
            throughSeq: projectionCommitFence?.throughSeq ?? -1)
    }

    private func publishSubmissionThreadChange(_ submissionID: SubmissionID) {
        guard let payload = submittedPayloads[submissionID]
                ?? outboxEntries[submissionID]?.payload else {
            return
        }
        let agentID = payload.to
            ?? AgentID(rawValue: projectSettings.mainAgentName)
        agentThreadUpdateHub.publish(
            agentIDs: [agentID],
            throughSeq: projectionCommitFence?.throughSeq ?? -1)
    }

    private func applyCoworkProjection(_ projection: CoworkProjection) {
        latestCoworkProjection = projection
        if let canonical = projection.sessionSettings?.cowork,
           canonical.sessionID == sessionID,
           canonical != projectSettings {
            projectSettings = canonical
        }
        let nextGoal = Self.goalPresentation(
            from: projection,
            controlsEnabled: isGoalRuntimeReady)
        if nextGoal != goal {
            goal = nextGoal
        }
        let nextWorkTasks =
            Self.workTaskPresentation(
                from: projection)
        if nextWorkTasks != workTasks {
            workTasks = nextWorkTasks
        }
        let nextIsGoalContinuing: Bool
        if let currentGoalID =
                projection.currentGoalID,
           projection.goals[currentGoalID]?
                .status == .active {
            // A single continuation task may advance through several durable
            // runs. Between run N settling and run N+1 being created, the
            // projection briefly contains no non-terminal run even though the
            // Goal still owns the data plane. Keep later submitted intents in
            // FIFO order until the Goal leaves `.active` explicitly.
            nextIsGoalContinuing = true
        } else {
            nextIsGoalContinuing = false
        }
        if nextIsGoalContinuing
            != isGoalContinuing {
            isGoalContinuing =
                nextIsGoalContinuing
        }
        let nextAgents =
            agentPresentation(
                from: projection)
        if nextAgents != agents {
            agents = nextAgents
        }

        let nextSummary = CoworkStatusSummary(
            activeCount: projection.activeTasks.count,
            runningCount: projection.runningTasks.count,
            completedCount: projection.completedTasks.count,
            failedCount: projection.failedTasks.count,
            pendingMailboxCount: projection.mailboxes.values.reduce(0) {
                $0 + $1.pendingMessages.count + $1.pendingTasks.count
            },
            completedMailboxCount: projection.mailboxes.values.reduce(0) {
                $0 + $1.completedTasks.count
            },
            workspaceLeaseCount: projection.workspaceLeases.count,
            capabilityLeaseCount: projection.capabilityLeases.count,
            runningTasks: projection.runningTasks.map(taskLine),
            failedTasks: projection.failedTasks.map(taskLine),
            recentCompletedTasks: projection.completedTasks.map(taskLine))
        if nextSummary != summary {
            summary = nextSummary
        }
        let nextProject = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: projectSettings,
            projection: projection)
        if nextProject != project {
            project = nextProject
        }
        let retryable = projection.failedTasks + projection.cancelledTasks
        let nextRetryableTasks =
            Dictionary(
                uniqueKeysWithValues:
                    retryable.map {
                        ($0.id.rawValue, $0)
                    })
        if nextRetryableTasks != retryableTasks {
            retryableTasks =
                nextRetryableTasks
        }
        scheduleSubmissionDrain()
    }

    private func agentPresentation(from projection: CoworkProjection) -> [CoworkAgentInfo] {
        let liveAgentIDs = Set(projection.agentRoster.keys)
        let runningAgentIDs = Set(projection.tasks.values.compactMap { task in
            task.status == .running ? task.assignee : nil
        })
        let failedAgentIDs = Set(projection.tasks.values.compactMap { task in
            task.status == .failed ? task.assignee : nil
        })
        var workspaceLeaseCounts: [AgentID: Int] = [:]
        for agentID in projection.workspaceLeaseAgents.values {
            workspaceLeaseCounts[agentID, default: 0] += 1
        }
        var capabilityLeasesByAgent: [AgentID: [CapabilityLease]] = [:]
        for (leaseID, agentID) in projection.capabilityLeaseAgents {
            guard let lease = projection.capabilityLeases[leaseID] else { continue }
            capabilityLeasesByAgent[agentID, default: []].append(lease)
        }
        var inferenceOptionsByBinding: [AgentInferenceBinding: AppInferenceProfileOption] = [:]
        for option in inferenceProfileOptions where inferenceOptionsByBinding[option.binding] == nil {
            inferenceOptionsByBinding[option.binding] = option
        }

        return projection.historicalAgentsInCreationOrder
            .map { payload in
                let mailbox = projection.mailboxes[payload.agent] ?? CoworkMailboxView()
                let capabilityLeases = capabilityLeasesByAgent[payload.agent] ?? []
                let workspaceLeaseCount = workspaceLeaseCounts[payload.agent] ?? 0
                let capabilityLeaseCount = capabilityLeases.count
                let isMain = payload.agent.rawValue == projectSettings.mainAgentName
                let isReviewer = payload.agent == Orchestrator.automaticPermissionReviewerID
                let isAttached = liveAgentIDs.contains(payload.agent)
                let binding = payload.agentInferenceBinding
                let inferenceOption = binding.flatMap { inferenceOptionsByBinding[$0] }
                let inferenceResolution: CoworkInferenceResolution
                if binding == nil {
                    inferenceResolution = .legacy
                } else if inferenceResolutionFailures[payload.agent.rawValue] != nil {
                    inferenceResolution = .unresolved
                } else {
                    inferenceResolution = .resolved
                }
                let status: String
                if !isAttached {
                    status = "detached"
                } else if runningAgentIDs.contains(payload.agent) {
                    status = "running"
                } else if let state = projection.agentStatuses[payload.agent] {
                    status = state.rawValue
                } else if !mailbox.pendingTasks.isEmpty {
                    status = "queued"
                } else if !mailbox.pendingMessages.isEmpty {
                    status = "mailbox"
                } else if failedAgentIDs.contains(payload.agent) {
                    status = "failed"
                } else {
                    status = "idle"
                }
                return CoworkAgentInfo(
                    id: payload.agent.rawValue,
                    name: payload.agent.rawValue,
                    workspace: payload.path,
                    model: payload.model.rawValue,
                    permissionProfile: Self.permissionDescription(payload.profile),
                    inferenceProfileLabel: inferenceOption?.title,
                    inferenceProfileRef: binding?.inferenceProfileRef,
                    inferenceConnectionLabel: binding?.safeRouteLabel,
                    inferenceVariant: inferenceOption?.variantTitle ?? binding?.variantID,
                    inferenceResolution: inferenceResolution,
                    status: status,
                    role: isMain ? "main" : isReviewer ? "reviewer" : Self.role(for: capabilityLeases),
                    pendingTasks: mailbox.pendingTasks.count,
                    pendingMessages: mailbox.pendingMessages.count,
                    completedTasks: mailbox.completedTasks.count,
                    workspaceLease: workspaceLeaseCount > 0
                        ? IntatisLocalization.format(
                            "%lld workspace lease",
                            Int64(workspaceLeaseCount))
                        : nil,
                    capabilityLease: capabilityLeaseCount > 0
                        ? IntatisLocalization.format(
                            "%lld capability lease",
                            Int64(capabilityLeaseCount))
                        : nil,
                    isAttached: isAttached,
                    canRemove: isAttached && !isMain && !isReviewer,
                    isConversationSelectable: !isReviewer)
            }
    }

    /// UI history and runtime routing deliberately use different membership
    /// tests. A detached identity remains in `agents` for transcript browsing,
    /// but every operational caller must pass through the live roster first.
    private func liveAgentInfo(named name: String) -> CoworkAgentInfo? {
        let agentID = AgentID(rawValue: name)
        guard latestCoworkProjection.agentRoster[agentID] != nil else {
            return nil
        }
        return agents.first(where: { $0.id == agentID.rawValue })
    }

    private func refreshInferenceResolutionState() async {
        guard let orchestrator else {
            inferenceResolutionFailures = [:]
            return
        }
        let failures = await orchestrator.inferenceResolutionFailures()
        inferenceResolutionFailures = Dictionary(uniqueKeysWithValues: failures.map {
            ($0.key.rawValue, $0.value)
        })
        agents = agentPresentation(from: latestCoworkProjection)
        scheduleSubmissionDrain()
    }

    private static func goalPresentation(
        from projection: CoworkProjection,
        controlsEnabled: Bool
    ) -> CoworkGoalCardInfo? {
        guard let goal = projection.currentGoal else { return nil }
        let audit = goal.latestAudit
        let proven = audit?.requirements.filter { $0.status == .proven }.count
        let auditSummary: String?
        if let audit {
            var parts = [audit.verdict.rawValue]
            if !audit.remainingWork.isEmpty {
                parts.append(IntatisLocalization.format(
                    "Remaining: %@",
                    audit.remainingWork.joined(separator: "; ")))
            }
            if let blocker = audit.blocker, !blocker.isEmpty {
                parts.append(IntatisLocalization.format("Blocker: %@", blocker))
            }
            auditSummary = parts.joined(separator: " · ")
        } else {
            auditSummary = nil
        }
        let runOrdinal = projection.continuationRuns.values
            .filter { $0.goalID == goal.id }
            .map(\.ordinal)
            .max()
        let canResume: Bool
        switch goal.status {
        case .paused, .blocked, .budgetLimited, .usageLimited:
            canResume = true
        case .active:
            canResume = goal.noProgressRuns >= 2
        case .completed:
            canResume = false
        }
        return CoworkGoalCardInfo(
            id: goal.id.rawValue,
            objective: goal.objective,
            status: goal.status.rawValue,
            activeElapsedSeconds: goal.activeElapsedSeconds,
            activeSince: goal.status == .active ? goal.updatedAt : nil,
            tokensUsed: goal.tokensUsed,
            tokenBudget: goal.tokenBudget,
            auditProvenCount: proven,
            auditRequirementCount: audit?.requirements.count,
            latestAuditSummary: auditSummary,
            currentRunOrdinal: runOrdinal,
            revision: goal.revision,
            canPause: controlsEnabled && goal.status == .active,
            canResume: controlsEnabled && canResume,
            canEdit: controlsEnabled && goal.status != .completed,
            canClear: controlsEnabled)
    }

    private static func workTaskPresentation(from projection: CoworkProjection) -> CoworkWorkTaskSummary {
        let selected: [WorkTask]
        if let goalID = projection.currentGoalID {
            selected = projection.workTasks.values.filter { $0.goalID == goalID }
        } else if let run = projection.continuationRuns.values
            .filter({ $0.goalID == nil })
            .max(by: { $0.startedAt < $1.startedAt }) {
            selected = projection.workTasks.values.filter { $0.runID == run.id }
        } else {
            selected = []
        }
        let ordered = selected.sorted { lhs, rhs in
            let lhsRun = projection.continuationRuns[lhs.runID]?.ordinal ?? 0
            let rhsRun = projection.continuationRuns[rhs.runID]?.ordinal ?? 0
            if lhsRun != rhsRun { return lhsRun < rhsRun }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        let lines = ordered.enumerated().map { index, task in
            let dependencies = task.dependsOn.map { dependencyID -> String in
                let status = projection.workTasks[dependencyID]?.status.rawValue ?? "missing"
                return "\(dependencyID.rawValue) [\(status)]"
            }
            let evidence = task.evidence.map {
                "\($0.kind) · \($0.reference) — \($0.summary)"
            }
            return CoworkWorkTaskLine(
                id: task.id.rawValue,
                ordinal: index + 1,
                title: task.title,
                detail: task.description,
                status: task.status.rawValue,
                owner: task.owner.map { "@\($0.rawValue)" },
                dependencySummary: dependencies.isEmpty
                    ? nil : dependencies.joined(separator: ", "),
                statusReason: task.progressNote,
                acceptanceCriteria: task.acceptanceCriteria,
                result: task.result,
                evidence: evidence,
                linkedInvocationIDs: task.latestInvocationIDs.map(\.rawValue))
        }
        return CoworkWorkTaskSummary(tasks: lines)
    }

    private func taskLine(_ task: CoworkTaskView) -> CoworkTaskLine {
        let assignee = task.assignee.map { "@\($0.rawValue)" }
            ?? IntatisLocalization.string("Unassigned")
        let title = task.contract.map { "\(assignee) · \($0.roleHint)" } ?? assignee
        let detail = task.contract?.objective ?? task.report?.summary ?? task.error ?? task.result ?? ""
        return CoworkTaskLine(id: task.id.rawValue, title: title, detail: detail, status: task.status.rawValue)
    }

    private func restoreWorkspaceAccess(for projection: CoworkProjection) {
        for workspace in projectSettings.workspaces {
            _ = retainWorkspaceAccess(forPath: workspace.path)
        }
        for payload in projection.agentRoster.values {
            _ = retainWorkspaceAccess(forPath: payload.path)
        }
    }

    private func retainWorkspaceAccess(forPath path: String) -> URL? {
        let key = URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
        if let existing = workspaceAccessLeases[key] {
            return existing.canonicalURL
        }
        do {
            guard let lease = try WorkspaceAccess.restoreAccess(
                forPath: path,
                in: sessionID) else { return nil }
            if let existing = workspaceAccessLeases[lease.canonicalPath] {
                lease.release()
                return existing.canonicalURL
            }
            workspaceAccessLeases[lease.canonicalPath] = lease
            return lease.canonicalURL
        } catch {
            sessionStorageWarning = IntatisLocalization.format(
                "Workspace access could not be read safely: %@",
                error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    private func adoptWorkspaceAccess(_ lease: WorkspaceAccessLease) -> URL {
        if let existing = workspaceAccessLeases[lease.canonicalPath] {
            lease.release()
            return existing.canonicalURL
        }
        workspaceAccessLeases[lease.canonicalPath] = lease
        return lease.canonicalURL
    }

    private func releaseWorkspaceAccess(forPath path: String) {
        let key = URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
        workspaceAccessLeases.removeValue(forKey: key)?.release()
    }

    /// Resolves the UI candidate back to the current durable settings before
    /// any mutation. Exact stored-path matches are preferred; alias matching
    /// requires one unambiguous canonical identity. Callers must still check
    /// `isPrimary` and must not trust a stale `CoworkWorkspaceInfo.canRemove`.
    private func configuredWorkspace(
        matching candidate: String
    ) -> CoworkProjectWorkspace? {
        let storedCandidate = URL(fileURLWithPath: candidate)
            .standardizedFileURL
            .path
        if let exact = projectSettings.workspaces.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == storedCandidate
        }) {
            return exact
        }
        guard let candidateIdentity = canonicalWorkspaceIdentity(candidate) else {
            return nil
        }
        var match: CoworkProjectWorkspace?
        for workspace in projectSettings.workspaces {
            guard let identity = canonicalWorkspaceIdentity(workspace.path) else {
                return nil
            }
            guard identity == candidateIdentity else { continue }
            guard match == nil else { return nil }
            match = workspace
        }
        return match
    }

    /// Returns the canonical bookmark key only when no remaining settings or
    /// roster entry refers to the candidate directory. Any identity that
    /// cannot be proven is retained (fail closed).
    private func removableWorkspaceAccessPath(
        candidate: String,
        settings: CoworkProjectSettings,
        remainingAgents: [Agent]
    ) -> String? {
        guard let candidateIdentity = canonicalWorkspaceIdentity(candidate) else {
            return nil
        }
        let candidateStored = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let remainingPaths = settings.workspaces.map(\.path)
            + remainingAgents.map { $0.workspaceRoot.path }
        for path in remainingPaths {
            if URL(fileURLWithPath: path).standardizedFileURL.path == candidateStored {
                return nil
            }
            guard let identity = canonicalWorkspaceIdentity(path) else {
                return nil
            }
            if identity == candidateIdentity { return nil }
        }
        return candidateIdentity
    }

    private func canonicalWorkspaceIdentity(_ path: String) -> String? {
        let stored = URL(fileURLWithPath: path).standardizedFileURL.path
        if let lease = workspaceAccessLeases[stored] {
            return lease.canonicalPath
        }
        return try? PathConfinement.canonicalExistingDirectory(
            URL(fileURLWithPath: path)).path
    }

    private func ensureAutomaticPermissionReview(existingProjection projection: CoworkProjection) async {
        guard let orchestrator else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.string("Cowork session is not ready.")))
            return
        }
        setPermissionReviewerStatus(.enabling)
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        let workspaceURL: URL
        guard let mainAgent = await orchestrator.agentList().first(where: {
            $0.name == mainID
        }), let mainBinding = mainAgent.agentInferenceBinding else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.format(
                    "@%@ has no resolved inference profile for the control plane.",
                    mainID.rawValue)))
            return
        }
        guard let controlPlaneBinding = await registryBox
            .freezeResolvableControlPlaneBinding(mainBinding) else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.format(
                    "@%@ exact inference profile revision is unavailable or incompatible.",
                    mainID.rawValue)))
            return
        }

        if let main = projection.agentRoster[mainID] {
            guard let restored = retainWorkspaceAccess(forPath: main.path) else {
                needsPrimaryWorkspaceAuthorization = true
                setPermissionReviewerStatus(.failed(
                    IntatisLocalization.string(
                        "Primary workspace access must be authorized again before automatic review can start.")))
                return
            }
            workspaceURL = restored
        } else if let workspace = projectSettings.primaryWorkspace {
            guard let restored = retainWorkspaceAccess(forPath: workspace.path) else {
                needsPrimaryWorkspaceAuthorization = true
                setPermissionReviewerStatus(.failed(
                    IntatisLocalization.string(
                        "Primary workspace access must be authorized again before automatic review can start.")))
                return
            }
            workspaceURL = restored
        } else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.format(
                    "No primary workspace is available for @%@.",
                    Orchestrator.automaticPermissionReviewerID.rawValue)))
            return
        }

        let result = await orchestrator.enableAutomaticPermissionReview(
            model: controlPlaneBinding.modelID,
            agentInferenceBinding: controlPlaneBinding,
            workspaceRoot: workspaceURL)
        guard !Task.isCancelled, self.orchestrator != nil else {
            setPermissionReviewerStatus(.disabled)
            return
        }
        switch result {
        case .enabled(let reviewer), .alreadyEnabled(let reviewer):
            needsPrimaryWorkspaceAuthorization = false
            await synchronizePermissionReviewerHealth(
                using: orchestrator,
                reviewer: reviewer)
        case .failed(let message):
            setPermissionReviewerStatus(.failed(message))
        }
    }

    private func synchronizePermissionReviewerHealth(
        using orchestrator: Orchestrator,
        reviewer: AgentID = Orchestrator.automaticPermissionReviewerID
    ) async {
        guard self.orchestrator != nil else { return }
        guard let health = await orchestrator.automaticPermissionReviewHealth() else {
            setPermissionReviewerStatus(.disabled)
            return
        }
        switch health {
        case .healthy:
            setPermissionReviewerStatus(.enabled(reviewer))
        case .degraded(let reason):
            setPermissionReviewerStatus(.degraded(reason))
        case .shuttingDown:
            setPermissionReviewerStatus(.disabled)
        }
    }

    private func schedulePermissionReviewerHealthRefresh() {
        guard acceptsNewOperations, let orchestrator else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
        }
        activeOperations[operationID] = operation
    }

    func retryAutomaticPermissionReview() {
        guard acceptsNewOperations,
              permissionReviewerStatus.canRetry,
              orchestrator != nil else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let mainID = AgentID(rawValue: self.projectSettings.mainAgentName)
            if !self.latestCoworkProjection.agentRoster.keys.contains(mainID) {
                await self.bootstrapMainAgentIfNeeded(
                    existingProjection: self.latestCoworkProjection,
                    allowsInitialSessionBootstrap: self.launchMode == .fresh)
            }
            let mainRegistered = await self.orchestrator?.agentList().contains {
                $0.name == mainID
            } ?? false
            guard self.latestCoworkProjection.agentRoster.keys.contains(mainID)
                    || mainRegistered else {
                return
            }
            await self.ensureAutomaticPermissionReview(existingProjection: self.latestCoworkProjection)
            await self.resumeRuntimeIfReady()
        }
        activeOperations[operationID] = operation
    }

    private func resumeRuntimeIfReady() async {
        guard let orchestrator,
              let goalRuntime else { return }
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard await orchestrator.agentList().contains(where: { $0.name == mainID }) else {
            return
        }
        await refreshInferenceResolutionState()
        guard inferenceResolutionFailures[mainID.rawValue] == nil else {
            projectionError = IntatisLocalization.format(
                "@%@ has an unresolved inference profile. Rebind it before resuming Cowork.",
                mainID.rawValue)
            return
        }
        isGoalRuntimeReady = false
        goal = Self.goalPresentation(
            from: latestCoworkProjection,
            controlsEnabled: false)
        let recoverySafe = await goalRuntime.start()
        guard !Task.isCancelled,
              self.orchestrator === orchestrator,
              self.goalRuntime === goalRuntime else {
            return
        }
        guard recoverySafe else {
            let message = IntatisLocalization.string(
                "Goal recovery could not be completed safely. Pending Cowork work remains stopped; retry after resolving the persistence or cancellation error.")
            projectionError = message
            setPermissionReviewerStatus(.failed(message))
            return
        }
        // Goal startup may append a recovery checkpoint, audit, and the final
        // Phase-L pause before the already-created stream loop receives those
        // events. Synchronize the same projection actor with the durable tail
        // so the UI never exposes a stale active/Pause state after cold
        // recovery and no second projection truth is introduced.
        let postRecoveryReplay =
            await log.replay()
        if let projectionPump {
            do {
                let previouslyCommitted =
                    projectionCommitFence?
                        .throughSeq
                        ?? Int.min
                let snapshot =
                    try await projectionPump
                        .synchronize(
                            with:
                                postRecoveryReplay)
                for envelope in
                    postRecoveryReplay
                    where envelope.seq
                        > previouslyCommitted {
                    observeProjectionBarrier(
                        envelope)
                }
                commitProjectionSnapshot(
                    snapshot)
            } catch {
                projectionError =
                    error.localizedDescription
                return
            }
        }
        let resumedPendingTasks = await orchestrator.startNewTasksKeepingRestoredTasksPaused()
        guard resumedPendingTasks,
              !Task.isCancelled,
              self.orchestrator === orchestrator,
              self.goalRuntime === goalRuntime else {
            return
        }
        isGoalRuntimeReady = true
        projectionError = nil
        goal = Self.goalPresentation(
            from: latestCoworkProjection,
            controlsEnabled: true)
        scheduleSubmissionDrain()
    }

    private func bootstrapMainAgentIfNeeded(existingProjection projection: CoworkProjection,
                                            allowsInitialSessionBootstrap: Bool) async {
        guard !didRequestMainAgentAttach else { return }
        guard let orchestrator else { return }
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard projection.agentRoster[mainID] == nil else { return }
        guard let workspace = projectSettings.primaryWorkspace else { return }
        guard let url = retainWorkspaceAccess(forPath: workspace.path) else {
            needsPrimaryWorkspaceAuthorization = true
            composerError = IntatisLocalization.format(
                "Primary workspace access must be authorized again before @%@ can be registered.",
                mainID.rawValue)
            setPermissionReviewerStatus(.failed(
                composerError ?? IntatisLocalization.string("Workspace access unavailable.")))
            return
        }
        guard let binding = projectSettings.defaultInferenceProfileBinding else {
            composerError = IntatisLocalization.format(
                "Choose a default inference profile before attaching @%@.",
                mainID.rawValue)
            return
        }
        didRequestMainAgentAttach = true
        let main = Agent(
            name: mainID,
            workspaceRoot: url,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: projectSettings.defaultProfile,
            coordinationDepth: Agent.defaultCoordinationDepth)
        let attached: Bool
        if allowsInitialSessionBootstrap {
            switch await orchestrator.bootstrapFreshSession(
                main: main,
                settings: projectSettings) {
            case .attached, .alreadyAttached:
                attached = true
            case .failed(let message):
                attached = false
                composerError = message
                setPermissionReviewerStatus(.failed(message))
            }
        } else {
            switch await orchestrator.restoreHistoricalMainAgent(
                main,
                settings: projectSettings,
                hostAuthorized: true) {
            case .attached, .alreadyAttached:
                attached = true
            case .failed(let message):
                attached = false
                composerError = message
            }
        }
        if attached {
            needsPrimaryWorkspaceAuthorization = false
            composerError = nil
        } else {
            // A transient persistence/profile failure must remain retryable.
            didRequestMainAgentAttach = false
        }
    }

    /// Re-establishes only the local security-scoped capability for the
    /// primary workspace. The selected folder must resolve to the exact path
    /// already recorded in canonical session settings; no prompt is sent to a
    /// model as part of this recovery.
    func reauthorizePrimaryWorkspace() {
        guard acceptsNewOperations,
              let primary = projectSettings.primaryWorkspace,
              let selected = WorkspaceAccess.choose(
                prompt: IntatisLocalization.string("Reauthorize Primary Workspace")) else {
            return
        }
        guard WorkspaceAccess.selectedLease(selected, matchesStoredPath: primary.path) else {
            composerError = IntatisLocalization.format(
                "Choose the original primary workspace at %@.",
                primary.path)
            needsPrimaryWorkspaceAuthorization = true
            selected.release()
            return
        }
        do {
            try WorkspaceAccess.remember(selected.scopedURL, for: sessionID, isPrimary: true)
        } catch {
            composerError = IntatisLocalization.format(
                "Primary workspace authorization could not be saved: %@",
                error.localizedDescription)
            needsPrimaryWorkspaceAuthorization = true
            selected.release()
            return
        }
        _ = adoptWorkspaceAccess(selected)
        var canonicalSettings = projectSettings
        let legacyPath = URL(fileURLWithPath: primary.path).standardizedFileURL.path
        canonicalSettings.applyValidatedWorkspacePathMappings([
            legacyPath: selected.canonicalPath
        ])
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            if canonicalSettings != self.projectSettings {
                guard await self.persistProjectSettings(canonicalSettings) else {
                    self.needsPrimaryWorkspaceAuthorization = true
                    return
                }
            }
            self.needsPrimaryWorkspaceAuthorization = false
            self.didRequestMainAgentAttach = false
            self.composerError = nil
            await self.bootstrapMainAgentIfNeeded(
                existingProjection: self.latestCoworkProjection,
                allowsInitialSessionBootstrap: self.launchMode == .fresh)
            await self.ensureAutomaticPermissionReview(
                existingProjection: self.latestCoworkProjection)
            if self.isAutomaticPermissionReviewReady {
                self.sessionStorageWarning = nil
            }
            await self.resumeRuntimeIfReady()
        }
        activeOperations[operationID] = operation
    }

    @discardableResult
    func prepareAddAgent(name rawName: String) -> Bool {
        guard acceptsNewOperations else { return false }
        addAgentStatus = .validating
        switch validateNewAgentName(rawName) {
        case .success:
            return true
        case .failure(let message):
            addAgentStatus = .failed(message)
            return false
        }
    }

    func cancelAddAgentSelection() {
        guard acceptsNewOperations else { return }
        if addAgentStatus == .validating {
            addAgentStatus = .idle
        }
    }

    func resetAddAgentStatus() {
        guard acceptsNewOperations else { return }
        addAgentStatus = .idle
    }

    @discardableResult
    func updateProjectSettings(_ settings: CoworkProjectSettings) async -> Bool {
        guard let operationID = beginDirectOperation() else {
            composerError = IntatisLocalization.string(
                "The Cowork session is stopping and cannot change project settings.")
            return false
        }
        defer { finishDirectOperation(operationID) }
        return await persistProjectSettings(settings)
    }

    @discardableResult
    private func persistProjectSettings(_ settings: CoworkProjectSettings) async -> Bool {
        if case .fresh = launchMode {
            let mainID = AgentID(rawValue: projectSettings.mainAgentName)
            let hasDurableBaseline = await orchestrator?.agentList().contains {
                $0.name == mainID
            } ?? false
            guard hasDurableBaseline else {
                composerError = IntatisLocalization.string(
                    "Retry the initial @main registration before changing project settings; the seven-event session baseline must remain atomic.")
                return false
            }
        }
        var normalized = settings
        normalized.schemaVersion = CoworkSessionSettings.currentSchemaVersion
        normalized.sessionID = sessionID
        let trimmedMainAgentName = normalized.mainAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.mainAgentName = trimmedMainAgentName.isEmpty ? "main" : trimmedMainAgentName
        do {
            let document = try await SessionProjectionStore.updateSettings(
                in: log,
                kind: .cowork,
                coworkSettings: normalized,
                changeKind: .updated)
            guard let canonical = document.coworkSettings else {
                composerError = IntatisLocalization.string(
                    "Session settings were persisted without a readable Cowork snapshot.")
                return false
            }
            projectSettings = canonical
            await orchestrator?.updateExecutionPolicy(
                CoworkExecutionPolicy(tokenBudget: canonical.tokenBudget))
            project = Self.makeProjectInfo(
                sessionID: sessionID,
                settings: canonical,
                projection: latestCoworkProjection)
            composerError = nil
            return true
        } catch {
            composerError = IntatisLocalization.format(
                "Session settings could not be saved: %@",
                error.localizedDescription)
            return false
        }
    }

    func removeAgent(name rawName: String) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked, let orchestrator else { return }
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else { return }
        guard name != projectSettings.mainAgentName else {
            composerError = IntatisLocalization.format(
                "Cannot remove @%@.",
                projectSettings.mainAgentName)
            return
        }
        guard AgentID(rawValue: name) != Orchestrator.automaticPermissionReviewerID else {
            composerError = IntatisLocalization.format(
                "@%@ is reserved.",
                Orchestrator.automaticPermissionReviewerID.rawValue)
            return
        }
        isWorking = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let projectedRosterPath = self.latestCoworkProjection
                .agentRoster[AgentID(rawValue: name)]?.path
            let wasAttached = await orchestrator.agentList().contains {
                $0.name == AgentID(rawValue: name)
            }
            let detached: Bool
            if wasAttached {
                detached = await orchestrator.detach(AgentID(rawValue: name))
            } else {
                detached = true
            }
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            guard detached else {
                self.composerError = IntatisLocalization.format(
                    "@%@ could not be removed; it may still have active tasks.",
                    name)
                self.isWorking = false
                return
            }
            // `agentList()` is read after the durable detach so it is the
            // authoritative live roster for capability reference checks.
            let remainingAgents = await orchestrator.agentList()
            let remainingRosterPaths = Set(remainingAgents.map {
                $0.workspaceRoot.standardizedFileURL.path
            })
            var settings = self.projectSettings
            var removedPaths = settings.workspaces
                .filter { $0.agentName == name && !$0.isPrimary }
                .map(\.path)
            if let rosterPath = projectedRosterPath,
               !removedPaths.contains(rosterPath) {
                removedPaths.append(rosterPath)
            }
            settings.removeWorkspaces(
                forAgent: name,
                retainingPaths: remainingRosterPaths)
            guard await self.persistProjectSettings(settings) else {
                // Detach is already durable. Retaining the capability is the
                // safe rollback when the settings transaction cannot advance.
                self.isWorking = false
                return
            }
            do {
                for path in removedPaths {
                    guard let removablePath = self.removableWorkspaceAccessPath(
                        candidate: path,
                        settings: settings,
                        remainingAgents: remainingAgents) else { continue }
                    try WorkspaceAccess.forget(path: removablePath, in: self.sessionID)
                    self.releaseWorkspaceAccess(forPath: removablePath)
                }
            } catch {
                self.composerError = IntatisLocalization.format(
                    "@%@ is detached, but its unreferenced workspace capability was retained because cleanup failed: %@",
                    name,
                    error.localizedDescription)
                self.isWorking = false
                return
            }
            self.isWorking = false
        }
        activeOperations[operationID] = operation
    }

    func agentInferenceBinding(name rawName: String) -> AgentInferenceBinding? {
        let name = Self.normalizedAgentName(rawName)
        return latestCoworkProjection.agentRoster[AgentID(rawValue: name)]?
            .agentInferenceBinding
    }

    func selectMainInferenceProfileForNextSubmission(
        _ binding: AgentInferenceBinding
    ) {
        guard acceptsNewOperations,
              let option = inferenceProfileOptions.first(where: {
                  $0.binding == binding
              }) else { return }
        nextMainInferenceOption = option
    }

    func rebindAgentInferenceProfile(
        name rawName: String,
        binding: AgentInferenceBinding
    ) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked, let orchestrator else { return }
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else { return }
        isWorking = true
        composerError = nil
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let result = await orchestrator.rebindAgentInferenceProfile(
                agentID: AgentID(rawValue: name),
                binding: binding,
                hostAuthorized: true)
            switch result {
            case .rebound, .unchanged:
                await self.refreshInferenceResolutionState()
                if name == self.projectSettings.mainAgentName,
                   !self.isAutomaticPermissionReviewReady {
                    await self.ensureAutomaticPermissionReview(
                        existingProjection: self.latestCoworkProjection)
                }
                await self.resumeRuntimeIfReady()
            case .failed(let message):
                self.composerError = message
            }
            self.isWorking = false
        }
        activeOperations[operationID] = operation
    }

    func removeWorkspace(path: String) {
        guard acceptsNewOperations else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            guard let configuredWorkspace = self.configuredWorkspace(matching: path) else {
                self.composerError = IntatisLocalization.string(
                    "This workspace could not be matched safely to session settings.")
                return
            }
            guard !configuredWorkspace.isPrimary else {
                self.composerError = IntatisLocalization.string(
                    "The primary workspace cannot be removed.")
                return
            }
            let remainingAgents = await self.orchestrator?.agentList() ?? []
            var settings = self.projectSettings
            settings.removeWorkspace(path: configuredWorkspace.path)
            guard let removablePath = self.removableWorkspaceAccessPath(
                candidate: configuredWorkspace.path,
                settings: settings,
                remainingAgents: remainingAgents) else {
                self.composerError = IntatisLocalization.string(
                    "This workspace is still referenced by session settings or an attached agent.")
                return
            }
            guard await self.updateProjectSettings(settings) else { return }
            do {
                try WorkspaceAccess.forget(path: removablePath, in: self.sessionID)
                self.releaseWorkspaceAccess(forPath: removablePath)
            } catch {
                self.composerError = IntatisLocalization.format(
                    "The workspace metadata was removed, but its capability was retained because cleanup failed: %@",
                    error.localizedDescription)
                return
            }
        }
        activeOperations[operationID] = operation
    }

    func addProjectWorkspace(_ authorization: WorkspaceAccessLease) {
        guard acceptsNewOperations else {
            authorization.release()
            return
        }
        let path = authorization.canonicalPath
        let hadRememberedAccess: Bool
        do {
            hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
                forPath: path,
                in: sessionID)
            try WorkspaceAccess.remember(authorization.scopedURL, for: sessionID)
        } catch {
            composerError = IntatisLocalization.format(
                "Workspace access could not be saved: %@",
                error.localizedDescription)
            authorization.release()
            return
        }
        var settings = projectSettings
        settings.upsertWorkspace(
            path: path,
            agentName: nil,
            isPrimary: false)
        let owningSessionID = sessionID
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(path: path, in: owningSessionID)
                }
                authorization.release()
                return
            }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            guard await self.updateProjectSettings(settings) else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(path: path, in: self.sessionID)
                }
                authorization.release()
                return
            }
            _ = self.adoptWorkspaceAccess(authorization)
        }
        activeOperations[operationID] = operation
    }

    func addAgent(name rawName: String, workspace authorization: WorkspaceAccessLease) {
        guard acceptsNewOperations, let orchestrator else {
            addAgentStatus = .failed(
                IntatisLocalization.string("Cowork session is not ready."))
            authorization.release()
            return
        }
        let normalizedName: String
        switch validateNewAgentName(rawName) {
        case .success(let name):
            normalizedName = name
        case .failure(let message):
            addAgentStatus = .failed(message)
            authorization.release()
            return
        }
        guard let binding = projectSettings.defaultInferenceProfileBinding else {
            addAgentStatus = .failed(IntatisLocalization.string(
                "Choose a default inference profile for new agents."))
            authorization.release()
            return
        }
        let workspace = authorization.canonicalURL
        let workspacePath = authorization.canonicalPath
        let hadRememberedAccess: Bool
        do {
            hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
                forPath: workspacePath,
                in: sessionID)
            try WorkspaceAccess.remember(authorization.scopedURL, for: sessionID)
        } catch {
            addAgentStatus = .failed(IntatisLocalization.format(
                "Workspace access could not be saved: %@",
                error.localizedDescription))
            authorization.release()
            return
        }
        addAgentStatus = .attaching(normalizedName)
        let owningSessionID = sessionID
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(path: workspacePath, in: owningSessionID)
                }
                authorization.release()
                return
            }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let replayed = await self.log.replay()
            let startSeq = replayed.last?.seq ?? -1
            let attached = await orchestrator.attach(Agent(name: AgentID(rawValue: normalizedName), workspaceRoot: workspace,
                                            model: binding.modelID,
                                            agentInferenceBinding: binding,
                                            profile: self.projectSettings.defaultProfile,
                                            coordinationDepth: 0))
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            if attached {
                var settings = self.projectSettings
                settings.upsertWorkspace(
                    path: workspacePath,
                    agentName: normalizedName,
                    isPrimary: false)
                if await self.persistProjectSettings(settings) {
                    _ = self.adoptWorkspaceAccess(authorization)
                    self.addAgentStatus = .attached(normalizedName)
                } else {
                    // The roster keeps this path visible and removable. Do not
                    // hide or revoke the capability behind a false success.
                    _ = self.adoptWorkspaceAccess(authorization)
                    self.addAgentStatus = .failed(
                        IntatisLocalization.format(
                            "@%@ was attached, but its project settings could not be saved; remove it or retry settings before continuing.",
                            normalizedName))
                }
                return
            }
            let events = await self.log.replay(from: startSeq + 1)
            self.addAgentStatus = self.attachFailureStatus(agentName: normalizedName, events: events)
            if !hadRememberedAccess {
                try? WorkspaceAccess.forget(path: workspacePath, in: self.sessionID)
            }
            authorization.release()
        }
        activeOperations[operationID] = operation
    }

    func importDraftAttachments(_ urls: [URL]) {
        guard acceptsNewOperations, !urls.isEmpty else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let type = UTType(filenameExtension: url.pathExtension)
                    let mime = type?.preferredMIMEType ?? "application/octet-stream"
                    let ref = try await self.artifactStore.addAttachment(
                        name: url.lastPathComponent,
                        data: data,
                        mime: mime)
                    // Admission may retain only ArtifactID references, so
                    // verify the blob/index pair before exposing the draft.
                    let verifiedRef = await self.artifactStore.ref(for: ref.id)
                    let verifiedData = try await self.artifactStore.data(for: ref.id)
                    guard verifiedRef == ref,
                          verifiedData.count == data.count else {
                        throw IntatisError.io("attachment read-back verification failed")
                    }
                    self.draftAttachments.append(CoworkDraftAttachment(
                        id: ref.id,
                        name: url.lastPathComponent,
                        mime: mime))
                } catch {
                    self.composerError = IntatisLocalization.format(
                        "Attachment %@ could not be preserved: %@",
                        url.lastPathComponent,
                        error.localizedDescription)
                }
            }
        }
        activeOperations[operationID] = operation
    }

    func removeDraftAttachment(_ id: ArtifactID) {
        guard acceptsNewOperations else { return }
        draftAttachments.removeAll { $0.id == id }
    }

    /// Records one confirmed server-prompt selection and stages its typed
    /// untrusted content for the next submission to that exact Agent.
    func acceptMCPPromptInsertion(
        _ insertion: MCPPromptInsertion
    ) async throws {
        guard acceptsNewOperations else {
            throw IntatisError.config(
                "The Cowork session is stopping.")
        }
        let selectedAgentID =
            insertion.event.selectedByAgentID
        if let existing =
                pendingMCPExternalContextAgentID,
           let selectedAgentID,
           existing != selectedAgentID {
            throw IntatisError.permissionDenied(
                "External MCP context for different agents cannot be combined in one submission.")
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
            pendingMCPExternalContextAgentID
                ?? selectedAgentID
        pendingMCPExternalContextCount = candidate.count
    }

    /// Stages another explicit MCP selection (for example server
    /// instructions) through the same one-shot user-context boundary.
    func stageMCPExternalContexts(
        _ contexts: [MCPUntrustedExternalContext],
        selectedByAgentID: AgentID? = nil
    ) throws {
        if let existing =
                pendingMCPExternalContextAgentID,
           let selectedByAgentID,
           existing != selectedByAgentID {
            throw IntatisError.permissionDenied(
                "External MCP context for different agents cannot be combined in one submission.")
        }
        let candidate =
            pendingMCPExternalContexts
                + contexts.map {
                    $0.providerNeutralContext()
                }
        try Self.validateMCPExternalContexts(candidate)
        pendingMCPExternalContexts = candidate
        pendingMCPExternalContextAgentID =
            pendingMCPExternalContextAgentID
                ?? selectedByAgentID
        pendingMCPExternalContextCount = candidate.count
    }

    func cancelPendingMCPExternalContexts() {
        pendingMCPExternalContexts.removeAll()
        pendingMCPExternalContextAgentID = nil
        pendingMCPExternalContextCount = 0
    }

    func reportAttachmentImportFailure(_ error: Error) {
        guard acceptsNewOperations else { return }
        composerError = IntatisLocalization.format(
            "Attachments could not be selected: %@",
            error.localizedDescription)
    }

    func send() {
        guard acceptsNewOperations, !isAcceptingSubmission else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
        let originalInput = input
        let originalAttachments = draftAttachments
        let frozenExternalContexts =
            pendingMCPExternalContexts
        let frozenExternalContextAgentID =
            pendingMCPExternalContextAgentID
        let initialParsed: ParsedUserInput
        if originalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !originalAttachments.isEmpty
                || !frozenExternalContexts.isEmpty {
            initialParsed = ParsedUserInput(text: "")
        } else {
            switch GoalInputParser.parse(originalInput) {
            case .success(let value):
                initialParsed = value
            case .failure(.empty):
                composerError = Self.presentationMessage(
                    for: CoworkMentionRouteError.emptyMessage)
                return
            case .failure(let error):
                composerError = Self.presentationMessage(for: error)
                return
            }
        }
        let routeInput = initialParsed.isGoal ? initialParsed.text : originalInput
        let route = routeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CoworkMentionRoute(
                originalInput: routeInput,
                outcome: .send(
                    text: "",
                    target: AgentID(rawValue: projectSettings.mainAgentName)))
            : routeProjectInput(routeInput)
        switch route.outcome {
        case .blocked(let error):
            composerError = Self.presentationMessage(for: error)
            return
        case .send(let text, let target):
            if let frozenExternalContextAgentID,
               frozenExternalContextAgentID != target {
                composerError = IntatisLocalization.format(
                    "The selected MCP context belongs to @%@, but this message targets @%@.",
                    frozenExternalContextAgentID.rawValue,
                    target.rawValue)
                return
            }
            let finalParsed: ParsedUserInput
            switch GoalInputParser.parse(text) {
            case .success(let parsed) where parsed.isGoal:
                finalParsed = parsed
            case .failure(.missingGoal):
                composerError = Self.presentationMessage(
                    for: GoalInputParseError.missingGoal)
                return
            default:
                finalParsed = initialParsed.isGoal
                    ? ParsedUserInput(text: text, goal: text, tags: [ParsedUserInput.goalTag])
                    : ParsedUserInput(text: text)
            }
            let mainAgentID = AgentID(rawValue: projectSettings.mainAgentName)
            let isMainHostedSubmission = target == mainAgentID || finalParsed.goal != nil
            let frozenMainInferenceBinding: AgentInferenceBinding?
            if isMainHostedSubmission {
                guard let exactBinding = nextMainInferenceBinding else {
                    composerError = IntatisLocalization.format(
                        "Choose a resolvable model for the next @%@ message before sending.",
                        mainAgentID.rawValue)
                    return
                }
                frozenMainInferenceBinding = exactBinding
            } else {
                frozenMainInferenceBinding = nil
            }
            let payload = UserMessagePayload(
                text: finalParsed.text,
                attachments: originalAttachments.map(\.id),
                to: target,
                tags: finalParsed.tags.isEmpty ? nil : finalParsed.tags,
                goal: finalParsed.goal,
                submissionID: SubmissionID.new(),
                mainAgentInferenceBinding: frozenMainInferenceBinding,
                turnID: TurnID.new(),
                untrustedExternalContexts:
                    frozenExternalContexts.isEmpty
                        ? nil
                        : frozenExternalContexts)
            isAcceptingSubmission = true
            let operationID = UUID()
            let operation = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isAcceptingSubmission = false
                    self.activeOperations.removeValue(forKey: operationID)
                }
                do {
                    let acceptance = try await self.submittedIntentStore.accept(payload: payload)
                    self.consumeMCPExternalContexts(
                        frozenExternalContexts)
                    guard let submissionID = payload.submissionID else { return }
                    // Clear only the exact draft that was frozen. Any text the
                    // user typed while persistence ran belongs to the next
                    // draft and must remain untouched.
                    if self.input == originalInput {
                        self.input = ""
                    }
                    if self.draftAttachments.map(\.id) == originalAttachments.map(\.id) {
                        self.draftAttachments = []
                    }
                    self.submittedPayloads[submissionID] = payload
                    self.submissionAttempts[submissionID] = 1
                    switch acceptance {
                    case .canonical(_, let cleanupWarning):
                        self.canonicalSubmissionIDs.insert(submissionID)
                        self.outboxEntries.removeValue(forKey: submissionID)
                        if !self.submissionQueue.contains(submissionID) {
                            self.submissionQueue.append(submissionID)
                        }
                        self.composerError = nil
                        if let cleanupWarning {
                            self.sessionStorageWarning = cleanupWarning
                        }
                        self.scheduleSubmissionDrain()
                    case .outbox(let entry, let canonicalError):
                        self.outboxEntries[submissionID] = entry
                        self.composerError = IntatisLocalization.format(
                            "Submission saved in the local outbox. Retry when the session EventLog is writable: %@",
                            canonicalError)
                        self.rebuildOutboxThreadItems(
                            publishesChanges: true)
                    }
                } catch {
                    // Neither canonical EventLog nor the owner-only outbox
                    // accepted the intent. Keep the original draft verbatim.
                    self.composerError = IntatisLocalization.format(
                        "The submission could not be preserved, so the draft was not cleared: %@",
                        error.localizedDescription)
                }
            }
            activeOperations[operationID] = operation
        }
    }

    #if canImport(AVFoundation)
    func toggleVoiceInput() {
        guard acceptsNewOperations else { return }
        if !voiceInput.isRecording {
            guard !isAcceptingSubmission else { return }
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

    private func scheduleSubmissionDrain() {
        guard acceptsNewOperations,
              !submissionDrainRunning,
              !submissionQueue.isEmpty,
              orchestrator != nil,
              goalRuntime != nil else { return }
        submissionDrainRunning = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.submissionDrainRunning = false
                self.activeOperations.removeValue(forKey: operationID)
            }
            await self.drainSubmittedIntents()
        }
        activeOperations[operationID] = operation
    }

    private func drainSubmittedIntents() async {
        while !Task.isCancelled,
              !didStop,
              !submissionQueue.isEmpty {
            guard !isWorking,
                  !isGoalContinuing,
                  let orchestrator,
                  let goalRuntime else { return }
            let submissionID = submissionQueue[0]
            guard let payload = submittedPayloads[submissionID] else {
                submissionQueue.removeFirst()
                continue
            }
            let attempt = max(1, submissionAttempts[submissionID] ?? 1)
            let target = payload.to ?? AgentID(rawValue: projectSettings.mainAgentName)
            let mainAgentID = AgentID(rawValue: projectSettings.mainAgentName)
            let isMainHostedSubmission = target == mainAgentID || payload.goal != nil
            if payload.mainAgentInferenceBinding != nil, !isMainHostedSubmission {
                await settleSubmissionFailure(
                    submissionID: submissionID,
                    attempt: attempt,
                    code: "invalid_main_model_target",
                    message: "The composer model selection can only be applied to @\(mainAgentID.rawValue). Direct agent messages keep their own configured model.",
                    retryable: false)
                submissionQueue.removeFirst()
                continue
            }
            let frozenBindingCanRepairMain = target == mainAgentID
                && payload.mainAgentInferenceBinding != nil
            guard let targetAgent = liveAgentInfo(named: target.rawValue),
                  targetAgent.inferenceResolution == .resolved
                    || frozenBindingCanRepairMain else {
                await settleSubmissionFailure(
                    submissionID: submissionID,
                    attempt: attempt,
                    code: "route_unavailable",
                    message: "@\(target.rawValue) is not registered with a resolvable inference profile. Rebind or register it, then retry.",
                    retryable: true)
                submissionQueue.removeFirst()
                continue
            }
            // Runtime reconstruction may still be in progress, but route
            // failures are already knowable locally and should become an
            // actionable submission state instead of an indefinite spinner.
            guard isGoalRuntimeReady else {
                return
            }

            do {
                try await submittedIntentStore.appendStatus(
                    SubmissionStatusChangedPayload(
                        submissionID: submissionID,
                        status: .running,
                        attempt: attempt))
            } catch {
                composerError = IntatisLocalization.format(
                    "Submission %@ remains queued because its running state could not be persisted: %@",
                    submissionID.rawValue,
                    error.localizedDescription)
                return
            }

            isWorking = true
            isAgentWorkActive = true
            var didStartGoalContinuation = false
            let executionFailure: SubmissionFailure?
            if payload.goal != nil {
                if payload.attachments?.isEmpty == false {
                    executionFailure = SubmissionFailure(
                        code: "goal_attachments_unsupported",
                        message: "Goal submissions do not yet pass attachments to the Goal runtime. The submitted attachments remain preserved locally.",
                        retryable: false)
                } else {
                    let baseObjective = payload.goal ?? payload.text
                    let mainID = AgentID(rawValue: projectSettings.mainAgentName)
                    let objective = target == mainID
                        ? baseObjective
                        : "@\(target.rawValue): \(baseObjective)"
                    do {
                        _ = try await goalRuntime.createGoal(
                            objective: objective,
                            userMessage: payload)
                        // `createGoal` launches its continuation asynchronously.
                        // Close the FIFO gate immediately instead of waiting for
                        // the streamed projection to report the active run.
                        isGoalContinuing = true
                        didStartGoalContinuation = true
                        executionFailure = nil
                    } catch {
                        executionFailure = SubmissionFailure(
                            code: "goal_create_failed",
                            message: error.localizedDescription,
                            retryable: true)
                    }
                }
            } else {
                let explicitGoalIntent = ExplicitGoalIntentClassifier
                    .classify(payload.text)
                    .isExplicit
                do {
                    let images = try await submissionImages(for: payload)
                    let result: OrchestratorSendResult
                    if let retryTask = submissionRetryTasks[submissionID] {
                        result = await orchestrator.retry(
                            retryTask,
                            images: images,
                            userMessage: payload,
                            recordUserMessage: false,
                            explicitGoalIntent: explicitGoalIntent)
                        submissionRetryTasks.removeValue(forKey: submissionID)
                    } else {
                        result = await goalRuntime.sendUserTurn(
                            payload.text,
                            to: target,
                            images: images,
                            userMessage: payload,
                            recordUserMessage: false,
                            explicitGoalIntent: explicitGoalIntent)
                    }
                    if let message = result.errorMessage {
                        executionFailure = await submissionExecutionFailure(
                            submissionID: submissionID,
                            message: message)
                    } else {
                        executionFailure = nil
                    }
                } catch let error as CoworkSubmissionAttachmentError {
                    executionFailure = SubmissionFailure(
                        code: error.code,
                        message: error.localizedDescription,
                        retryable: error.retryable)
                } catch {
                    executionFailure = SubmissionFailure(
                        code: "attachment_unreadable",
                        message: "Attachment recovery failed: \(error.localizedDescription)",
                        retryable: true)
                }
            }
            await synchronizePermissionReviewerHealth(using: orchestrator)

            if let executionFailure {
                await settleSubmissionFailure(
                    submissionID: submissionID,
                    attempt: attempt,
                    code: executionFailure.code,
                    message: executionFailure.message,
                    retryable: executionFailure.retryable)
            } else {
                do {
                    try await submittedIntentStore.appendStatus(
                        SubmissionStatusChangedPayload(
                            submissionID: submissionID,
                            status: .completed,
                            attempt: attempt))
                    composerError = nil
                } catch {
                    // Remote work may already have completed. Never retry it
                    // automatically when the terminal status could not be
                    // persisted; the restored UI will require an explicit
                    // reconciliation/retry decision.
                    composerError = IntatisLocalization.format(
                        "Submission %@ finished, but completion could not be persisted: %@",
                        submissionID.rawValue,
                        error.localizedDescription)
                }
            }
            isWorking = false
            isAgentWorkActive = false
            if submissionQueue.first == submissionID {
                submissionQueue.removeFirst()
            } else {
                submissionQueue.removeAll { $0 == submissionID }
            }
            if didStartGoalContinuation { return }
        }
    }

    private func submissionImages(
        for payload: UserMessagePayload
    ) async throws -> [ImageAttachment] {
        var result: [ImageAttachment] = []
        for id in payload.attachments ?? [] {
            guard let ref = await artifactStore.ref(for: id) else {
                throw CoworkSubmissionAttachmentError.missing(id)
            }
            guard ref.mime.hasPrefix("image/") else {
                throw CoworkSubmissionAttachmentError.unsupported(id, ref.mime)
            }
            let data: Data
            do {
                data = try await artifactStore.data(for: id)
            } catch {
                throw CoworkSubmissionAttachmentError.unreadable(
                    id,
                    error.localizedDescription)
            }
            result.append(.base64(mime: ref.mime, base64: data.base64EncodedString()))
        }
        return result
    }

    private func settleSubmissionFailure(
        submissionID: SubmissionID,
        attempt: Int,
        code: String,
        message: String,
        retryable: Bool
    ) async {
        let safeMessage = String(message.prefix(1_200))
        do {
            try await submittedIntentStore.appendStatus(
                SubmissionStatusChangedPayload(
                    submissionID: submissionID,
                    status: .failed,
                    attempt: attempt,
                    failure: SubmissionFailure(
                        code: code,
                        message: safeMessage,
                        retryable: retryable)))
            composerError = safeMessage
        } catch {
            composerError = IntatisLocalization.format(
                "Submission failed, and its retry state could not be persisted: %@",
                error.localizedDescription)
        }
    }

    func retrySubmission(_ submissionID: SubmissionID) {
        guard acceptsNewOperations, !isAcceptingSubmission else { return }
        isAcceptingSubmission = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isAcceptingSubmission = false
                self.activeOperations.removeValue(forKey: operationID)
            }
            do {
                if self.outboxEntries[submissionID] != nil {
                    let acceptance = try await self.submittedIntentStore.retryOutbox(id: submissionID)
                    switch acceptance {
                    case .canonical(let entry, let cleanupWarning):
                        self.canonicalSubmissionIDs.insert(submissionID)
                        self.outboxEntries.removeValue(forKey: submissionID)
                        self.submittedPayloads[submissionID] = entry.payload
                        self.submissionAttempts[submissionID] = 1
                        if !self.submissionQueue.contains(submissionID) {
                            self.submissionQueue.append(submissionID)
                        }
                        self.composerError = nil
                        if let cleanupWarning {
                            self.sessionStorageWarning = cleanupWarning
                        }
                        self.rebuildOutboxThreadItems(
                            publishesChanges: true)
                        self.scheduleSubmissionDrain()
                    case .outbox(let entry, let canonicalError):
                        self.outboxEntries[submissionID] = entry
                        self.composerError = IntatisLocalization.format(
                            "The submission is still safe in the local outbox: %@",
                            canonicalError)
                        self.rebuildOutboxThreadItems(
                            publishesChanges: true)
                    }
                    return
                }

                guard let payload = self.submittedPayloads[submissionID] else {
                    self.composerError = IntatisLocalization.string(
                        "This submission payload is no longer available for retry.")
                    return
                }
                if let task = try await self.canonicalSubmissionTask(for: submissionID) {
                    if task.status == .completed {
                        let currentAttempt = max(
                            1,
                            self.submissionAttempts[submissionID] ?? 1)
                        try await self.submittedIntentStore.appendStatus(
                            SubmissionStatusChangedPayload(
                                submissionID: submissionID,
                                status: .completed,
                                attempt: currentAttempt))
                        self.restoredSubmissionIDs.remove(submissionID)
                        self.composerError = nil
                        self.publishSubmissionThreadChange(submissionID)
                        return
                    }
                    if task.status == .queued
                        || task.status == .running
                        || task.status == .failed
                        || task.status == .cancelled {
                        self.submissionRetryTasks[submissionID] = task
                    }
                }
                let nextAttempt = max(1, self.submissionAttempts[submissionID] ?? 1) + 1
                try await self.submittedIntentStore.appendStatus(
                    SubmissionStatusChangedPayload(
                        submissionID: submissionID,
                        status: .queued,
                        attempt: nextAttempt))
                self.submissionAttempts[submissionID] = nextAttempt
                self.restoredSubmissionIDs.remove(submissionID)
                self.submittedPayloads[submissionID] = payload
                if !self.submissionQueue.contains(submissionID) {
                    self.submissionQueue.append(submissionID)
                }
                self.composerError = nil
                self.publishSubmissionThreadChange(submissionID)
                self.scheduleSubmissionDrain()
            } catch {
                self.composerError = IntatisLocalization.format(
                    "The submission could not be queued for retry: %@",
                    error.localizedDescription)
            }
        }
        activeOperations[operationID] = operation
    }

    private func canonicalSubmissionTask(
        for submissionID: SubmissionID
    ) async throws -> CoworkTaskView? {
        let projection = CoworkProjection.build(from: try await log.replayChecked())
        let matches = projection.tasks.values
            .filter {
                $0.contract?.kind == .root
                    && $0.contract?.submissionID == submissionID
            }
        guard matches.count <= 1 else {
            throw IntatisError.decoding(
                "submission \(submissionID.rawValue) is correlated with multiple root tasks")
        }
        return matches.first
    }

    private func submissionExecutionFailure(
        submissionID: SubmissionID,
        message: String
    ) async -> SubmissionFailure {
        do {
            if let task = try await canonicalSubmissionTask(for: submissionID),
               let maxAttempts = task.contract?.maxAttempts,
               task.attempt >= maxAttempts {
                return SubmissionFailure(
                    code: "execution_attempts_exhausted",
                    message: message,
                    retryable: false)
            }
            return SubmissionFailure(
                code: "execution_failed",
                message: message,
                retryable: true)
        } catch {
            return SubmissionFailure(
                code: "submission_task_correlation_invalid",
                message: "\(message) Retry is disabled because the durable task correlation is ambiguous: \(error.localizedDescription)",
                retryable: false)
        }
    }

    func cancelCurrentActivity() {
        guard acceptsNewOperations,
              !isCancellingCurrentActivity,
              isAgentWorkActive || isGoalContinuing else {
            return
        }
        isCancellingCurrentActivity = true
        composerError = IntatisLocalization.string(
            "Cancelling the current Cowork task…")
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCancellingCurrentActivity = false
                self.activeOperations.removeValue(forKey: operationID)
            }

            let hasActiveGoal = self.isGoalContinuing
                || self.goal?.normalizedStatus == "active"
            if hasActiveGoal {
                guard let goalRuntime = self.goalRuntime else {
                    self.composerError = IntatisLocalization.string(
                        "Cowork session is not ready.")
                    return
                }
                do {
                    _ = try await goalRuntime.pauseCurrentGoal()
                    self.composerError = nil
                } catch {
                    self.composerError = error.localizedDescription
                }
                return
            }

            guard let orchestrator = self.orchestrator else {
                self.composerError = IntatisLocalization.string(
                    "Cowork session is not ready.")
                return
            }
            await orchestrator.cancelActiveTasks(reason: "cancelled by user")
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            self.composerError = nil
        }
        activeOperations[operationID] = operation
    }

    func pauseGoal() {
        guard acceptsNewOperations, isGoalRuntimeReady, let goalRuntime else { return }
        performGoalAction {
            _ = try await goalRuntime.pauseCurrentGoal()
        }
    }

    func resumeGoal() {
        guard acceptsNewOperations, isGoalRuntimeReady, let goalRuntime else { return }
        performGoalAction {
            _ = try await goalRuntime.resumeCurrentGoal()
        }
    }

    func currentGoalEditDraft() -> CoworkGoalEditDraft? {
        guard let durableGoal = latestCoworkProjection.currentGoal else { return nil }
        return CoworkGoalEditDraft(
            objective: durableGoal.objective,
            successCriteria: durableGoal.successCriteria.joined(separator: "\n"),
            constraints: durableGoal.constraints.joined(separator: "\n"),
            tokenBudget: durableGoal.tokenBudget.map(String.init) ?? "")
    }

    @discardableResult
    func editGoal(objective: String,
                  successCriteria: String,
                  constraints: String,
                  tokenBudget: String) -> String? {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            return IntatisLocalization.string("A Goal objective is required.")
        }

        let budgetText = tokenBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedBudget: Int?
        if budgetText.isEmpty {
            parsedBudget = nil
        } else if let value = Int(budgetText), value > 0 {
            parsedBudget = value
        } else {
            return IntatisLocalization.string(
                "Token budget must be a positive whole number, or left empty for no budget.")
        }

        guard isGoalRuntimeReady,
              acceptsNewOperations,
              let goalRuntime,
              latestCoworkProjection.currentGoal != nil else {
            return IntatisLocalization.string(
                "Goal recovery must finish before the durable Goal can be edited.")
        }
        let parsedCriteria = Self.goalEditLines(successCriteria)
        let parsedConstraints = Self.goalEditLines(constraints)
        performGoalAction {
            _ = try await goalRuntime.editCurrentGoal(
                objective: objective,
                successCriteria: parsedCriteria,
                constraints: parsedConstraints,
                tokenBudget: parsedBudget)
        }
        return nil
    }

    func clearGoal() {
        guard acceptsNewOperations, isGoalRuntimeReady, let goalRuntime else { return }
        performGoalAction {
            try await goalRuntime.clearCurrentGoal(reason: "cleared by user from Cowork Goal card")
        }
    }

    private func performGoalAction(
        _ action: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        guard acceptsNewOperations else { return }
        composerError = nil
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            do {
                try await action()
            } catch {
                self.composerError = error.localizedDescription
            }
        }
        activeOperations[operationID] = operation
    }

    private static func goalEditLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func routeProjectInput(_ input: String) -> CoworkMentionRoute {
        CoworkMentionRouter.routeSubmittedIntent(
            input: input,
            defaultTarget: AgentID(rawValue: projectSettings.mainAgentName))
    }

    private static func presentationMessage(
        for error: GoalInputParseError
    ) -> String {
        switch error {
        case .empty:
            return IntatisLocalization.string("Enter a message.")
        case .missingGoal:
            return IntatisLocalization.string("Enter a goal after /goal.")
        }
    }

    private static func presentationMessage(
        for error: CoworkMentionRouteError
    ) -> String {
        switch error {
        case .noAgents:
            return IntatisLocalization.string(
                "Add an agent before sending a Cowork message.")
        case .emptyMessage:
            return IntatisLocalization.string("Enter a message before sending.")
        case .emptyMention:
            return IntatisLocalization.string("Type an agent name after @.")
        case .unknownMention(let name):
            return IntatisLocalization.format(
                "No attached agent matches @%@.",
                name)
        case .invalidMention(let name):
            return IntatisLocalization.format(
                "@%@ is not a valid agent name. Use ASCII letters, digits, '-' or '_'.",
                name)
        case .ambiguousMention(let name, let agents):
            return IntatisLocalization.format(
                "Ambiguous @%@: %@",
                name,
                agents.map { "@\($0.rawValue)" }.joined(separator: ", "))
        case .ambiguousDefault(let agents):
            return IntatisLocalization.format(
                "Use @Name to choose an agent: %@",
                agents.map { "@\($0.rawValue)" }.joined(separator: ", "))
        }
    }

    func retryFailedTask(id: String) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked, let orchestrator else { return }
        guard let task = retryableTasks[id] else {
            composerError = IntatisLocalization.string(
                "This failed task is no longer retryable.")
            return
        }
        if let submissionID = task.contract?.submissionID {
            retrySubmission(submissionID)
            return
        }
        composerError = nil
        isWorking = true
        isAgentWorkActive = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let result = await orchestrator.retry(task)
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            if let message = result.errorMessage {
                self.composerError = message
            }
            self.isWorking = false
            self.isAgentWorkActive = false
        }
        activeOperations[operationID] = operation
    }

    // MARK: PermissionResponder

    nonisolated func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await requestResolution(request).decision
    }

    nonisolated func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        let waiter = CoworkPermissionWaiter()
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled {
                waiter.resolve(Self.cancelledPermissionResolution(
                    reason: "Cowork turn cancelled before permission presentation"))
            }
            return await withCheckedContinuation { continuation in
                waiter.install(continuation)
                Task { @MainActor [weak self] in
                    guard let self else {
                        waiter.resolve(Self.cancelledPermissionResolution(
                            reason: "Cowork permission presenter is unavailable"))
                        return
                    }
                    self.registerPermission(request, waiter: waiter)
                }
            }
        }, onCancel: {
            waiter.resolve(Self.cancelledPermissionResolution(
                reason: "Cowork turn cancelled while awaiting permission"))
            Task { @MainActor [weak self] in
                self?.cancelPermission(request.requestId, waiter: waiter)
            }
        })
    }

    func resolvePermission(_ action: PermissionResponseAction) {
        guard acceptsNewOperations,
              let presented = pendingPermission,
              presented.state.isActionable else { return }
        let request = presented.request
        let requestID = request.requestId
        guard
              let waiter = permissionWaiters.removeValue(forKey: requestID) else {
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
        suppressedPermissionRequestIDs.insert(requestID)
        waiter.resolve(Self.userPermissionResolution(action, request: request))
        permissionQueue.removeAll { $0.request.requestId == requestID }
        pendingPermission = permissionQueue.first
        restoreSteadyPermissionReviewerStatusIfPossible()
    }

    private func registerPermission(_ request: PermissionRequestPayload,
                                    waiter: CoworkPermissionWaiter) {
        guard acceptsNewOperations else {
            waiter.resolve(Self.cancelledPermissionResolution(
                reason: "Cowork session is stopping"))
            return
        }
        guard waiter.isPending else { return }
        let requestID = request.requestId
        if let previous = permissionWaiters.removeValue(forKey: requestID), previous !== waiter {
            previous.resolve(Self.cancelledPermissionResolution(
                reason: "Permission request identity was replaced"))
        }
        permissionQueue.removeAll { $0.request.requestId == requestID }
        guard waiter.isPending else { return }

        suppressedPermissionRequestIDs.remove(requestID)
        permissionWaiters[requestID] = waiter
        permissionQueue.append(PendingPermission(
            request: request,
            state: request.effectiveApprovalMode == .automaticReviewer
                ? .resolving
                : .livePending,
            requestedSeq: -1))
        permissionReviewerStatus = .fallback(permissionFallbackReason)
        schedulePermissionReviewerHealthRefresh()

        // Cancellation can resolve the waiter from a non-MainActor thread
        // between the first guard and registration. Remove it immediately if so;
        // the scheduled cancellation cleanup remains an idempotent fallback.
        guard waiter.isPending else {
            cancelPermission(requestID, waiter: waiter)
            return
        }
        pendingPermission = permissionQueue.first
    }

    private func cancelPermission(_ requestID: RequestID,
                                  waiter: CoworkPermissionWaiter) {
        suppressedPermissionRequestIDs.insert(requestID)
        if permissionWaiters[requestID] === waiter {
            permissionWaiters.removeValue(forKey: requestID)
        }
        permissionQueue.removeAll { $0.request.requestId == requestID }
        pendingPermission = permissionQueue.first
        restoreSteadyPermissionReviewerStatusIfPossible()
    }

    private nonisolated static func userPermissionResolution(
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

    private nonisolated static func cancelledPermissionResolution(
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

    private func presentedPermission(projected: PendingPermission?) -> PendingPermission? {
        if let queued = permissionQueue.first {
            return queued
        }
        guard let projected,
              !suppressedPermissionRequestIDs.contains(projected.request.requestId) else {
            return nil
        }
        return projected
    }

    private func setPermissionReviewerStatus(_ status: CoworkPermissionReviewerStatus) {
        steadyPermissionReviewerStatus = status
        if permissionQueue.isEmpty {
            permissionReviewerStatus = status
        }
    }

    private var permissionFallbackReason: String {
        switch steadyPermissionReviewerStatus {
        case .enabled:
            return IntatisLocalization.string(
                "Automatic review unexpectedly left the automatic path; ask-class tools fail closed until it recovers.")
        case .failed(let reason):
            return IntatisLocalization.format(
                "Automatic review is unavailable (%@); ordinary submissions remain available, but ask-class tools fail closed.",
                reason)
        case .disabled:
            return IntatisLocalization.string(
                "Automatic review is disabled; ordinary submissions remain available, but ask-class tools fail closed.")
        case .enabling:
            return IntatisLocalization.string(
                "Automatic review is still starting; ordinary submissions remain available.")
        case .degraded(let reason):
            return reason
        case .fallback(let reason):
            return reason
        }
    }

    private func restoreSteadyPermissionReviewerStatusIfPossible() {
        guard permissionQueue.isEmpty else { return }
        permissionReviewerStatus = steadyPermissionReviewerStatus
    }

    private func validateNewAgentName(_ rawName: String) -> AgentNameValidation {
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else {
            return .failure(IntatisLocalization.string("Enter an agent name."))
        }
        guard name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .failure(IntatisLocalization.string(
                "Agent names cannot contain spaces."))
        }
        let existing = latestCoworkProjection.agentRoster.keys.map(\.rawValue)
        if existing.contains(name) {
            return .failure(IntatisLocalization.format(
                "@%@ is already attached.",
                name))
        }
        if existing.contains(where: { $0.lowercased() == name.lowercased() }) {
            return .failure(IntatisLocalization.format(
                "@%@ conflicts with an attached agent name.",
                name))
        }
        return .success(name)
    }

    private static func normalizedAgentName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private func attachFailureStatus(agentName: String, events: [Envelope]) -> CoworkAddAgentStatus {
        if let denied = events.compactMap({ envelope -> WorkspaceLeaseDeniedPayload? in
            if case .workspaceLeaseDenied(let payload) = envelope.event, payload.agent?.rawValue == agentName {
                return payload
            }
            return nil
        }).last {
            return .denied(denied.reason)
        }
        if let denied = events.compactMap({ envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "agent.attach",
               payload.decision == .deny {
                return payload
            }
            return nil
        }).last {
            return .denied(denied.reason)
        }
        if let error = events.compactMap({ envelope -> ErrorPayload? in
            if case .error(let payload) = envelope.event {
                return payload
            }
            return nil
        }).last {
            return .failed(error.message)
        }
        return .failed(IntatisLocalization.format(
            "Could not attach @%@.",
            agentName))
    }

    private static func makeProjectInfo(sessionID: SessionID,
                                        settings: CoworkProjectSettings,
                                        projection: CoworkProjection) -> CoworkProjectInfo {
        var workspacesByPath: [String: CoworkWorkspaceInfo] = [:]
        let mainName = settings.mainAgentName

        for workspace in settings.workspaces {
            let isPrimary = workspace.isPrimary || workspace.agentName == mainName
            workspacesByPath[workspace.path] = CoworkWorkspaceInfo(
                path: workspace.path,
                displayName: displayName(forPath: workspace.path),
                agentName: workspace.agentName,
                isPrimary: isPrimary,
                access: "configured",
                canRemove: !isPrimary)
        }

        let rosterByPath = Dictionary(grouping: projection.agentRoster.values) {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        for (path, payloads) in rosterByPath {
            let existing = workspacesByPath[path]
            let ordinaryPayloads = payloads
                .filter { $0.agent != Orchestrator.automaticPermissionReviewerID }
                .sorted { $0.agent.rawValue < $1.agent.rawValue }
            let isPrimary = existing?.isPrimary == true
                || ordinaryPayloads.contains { $0.agent.rawValue == mainName }
            let isShared = ordinaryPayloads.count > 1
            let solePayload = ordinaryPayloads.count == 1 ? ordinaryPayloads[0] : nil
            let agentName: String?
            if isShared {
                agentName = nil
            } else if let configuredOwner = existing?.agentName,
                      ordinaryPayloads.contains(where: {
                          $0.agent.rawValue == configuredOwner
                      }) {
                agentName = configuredOwner
            } else if existing == nil {
                agentName = solePayload?.agent.rawValue
            } else {
                // A project-level/shared settings entry must not acquire an
                // owner merely because one roster payload was projected last.
                agentName = nil
            }
            let access: String
            if isShared {
                access = "shared"
            } else if let payload = solePayload {
                access = accessDescription(for: payload.agent, in: projection)
            } else {
                access = existing?.access ?? "configured"
            }
            workspacesByPath[path] = CoworkWorkspaceInfo(
                path: path,
                displayName: displayName(forPath: path),
                agentName: agentName,
                isPrimary: isPrimary,
                access: access,
                canRemove: !isPrimary
                    && !isShared
                    && (agentName != nil || ordinaryPayloads.isEmpty))
        }

        let workspaces = workspacesByPath.values.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary && !$1.isPrimary }
            return $0.path < $1.path
        }

        return CoworkProjectInfo(
            sessionID: sessionID.rawValue,
            mainAgentName: mainName,
            defaultModel: defaultModelDescription(settings),
            defaultPermission: permissionDescription(settings.defaultPermissionProfile),
            tokenBudget: settings.tokenBudget.map {
                IntatisLocalization.format("%@ tok", formatNumber($0))
            },
            workspaces: workspaces)
    }

    private static func role(for leases: [CapabilityLease]) -> String {
        if leases.isEmpty { return "worker" }
        if leases.contains(where: { $0.tools.isEmpty }) {
            return "reviewer"
        }
        if leases.contains(where: { $0.tools.contains(.delegateTask) || $0.tools.contains(.attachWorkspace) }) {
            return "coordinator"
        }
        return "worker"
    }

    private static func accessDescription(for agent: AgentID, in projection: CoworkProjection) -> String {
        let access = projection.workspaceLeaseAgents
            .filter { $0.value == agent }
            .compactMap { projection.workspaceLeases[$0.key]?.access.rawValue }
            .sorted()
        return access.first ?? "configured"
    }

    private static func defaultModelDescription(_ settings: CoworkProjectSettings) -> String {
        let model = settings.defaultModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else {
            return IntatisLocalization.string("current model")
        }
        if let provider = settings.defaultProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return "\(provider)/\(model)"
        }
        return model
    }

    private static func permissionDescription(_ rawValue: String) -> String {
        switch PermissionProfile(rawValue: rawValue) {
        case .some(.manual): return IntatisLocalization.string("manual")
        case .some(.reviewed): return IntatisLocalization.string("reviewed")
        case .some(.autopilot): return IntatisLocalization.string("autopilot")
        case .some(.readOnly): return IntatisLocalization.string("read only")
        case .some(.locked): return IntatisLocalization.string("locked")
        case .none: return rawValue
        }
    }

    private static func displayName(forPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

enum CoworkPermissionReviewerStatus: Equatable {
    case disabled
    case enabling
    case enabled(AgentID)
    case fallback(String)
    case degraded(String)
    case failed(String)

    var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum CoworkAddAgentStatus: Equatable {
    case idle
    case validating
    case attaching(String)
    case attached(String)
    case denied(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .validating, .attaching:
            return true
        case .idle, .attached, .denied, .failed:
            return false
        }
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .validating:
            return IntatisLocalization.string("Validating agent…")
        case .attaching(let name):
            return IntatisLocalization.format("Attaching @%@…", name)
        case .attached(let name):
            return IntatisLocalization.format("@%@ attached.", name)
        case .denied(let reason):
            return IntatisLocalization.format("Permission denied: %@", reason)
        case .failed(let message):
            return message
        }
    }
}

private enum AgentNameValidation {
    case success(String)
    case failure(String)
}
#endif
