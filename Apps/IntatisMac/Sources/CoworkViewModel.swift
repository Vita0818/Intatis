#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisCowork
import IntatisSharedUI

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
    private var continuation: CheckedContinuation<PermissionDecision, Never>?
    private var resolution: PermissionDecision?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolution == nil
    }

    func install(_ continuation: CheckedContinuation<PermissionDecision, Never>) {
        let decision: PermissionDecision?
        lock.lock()
        if let resolution {
            decision = resolution
        } else {
            self.continuation = continuation
            decision = nil
        }
        lock.unlock()
        if let decision {
            continuation.resume(returning: decision)
        }
    }

    @discardableResult
    func resolve(_ decision: PermissionDecision) -> Bool {
        let continuation: CheckedContinuation<PermissionDecision, Never>?
        lock.lock()
        guard resolution == nil else {
            lock.unlock()
            return false
        }
        resolution = decision
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: decision)
        return true
    }
}

struct CoworkGoalEditDraft: Equatable {
    var objective: String
    var successCriteria: String
    var constraints: String
    var tokenBudget: String
}

/// Drives a Cowork project session: user input defaults to the project `Main`
/// agent, while the orchestrator and scheduler handle sub-agent work behind it.
/// The view model folds the shared event log into the visible thread, project
/// summary, and agent roster.
@MainActor
final class CoworkViewModel: ObservableObject, PermissionResponder {
    @Published private(set) var items: [CodeItem] = []
    @Published private(set) var agents: [CoworkAgentInfo] = []
    @Published private(set) var summary = CoworkStatusSummary()
    @Published private(set) var project = CoworkProjectInfo()
    @Published private(set) var goal: CoworkGoalCardInfo?
    @Published private(set) var workTasks = CoworkWorkTaskSummary()
    @Published private(set) var projectSettings: CoworkProjectSettings
    @Published var input: String = ""
    @Published private(set) var isWorking = false
    @Published private(set) var isGoalContinuing = false
    @Published private(set) var isGoalRuntimeReady = false
    @Published var pendingPermission: PendingPermission?
    @Published private(set) var permissionNotice: PermissionResolutionNotice?
    @Published private(set) var latestTurnStats: TurnStatsSnapshot?
    @Published private(set) var composerError: String?
    @Published private(set) var projectionError: String?
    @Published private(set) var addAgentStatus: CoworkAddAgentStatus = .idle
    @Published private(set) var permissionReviewerStatus: CoworkPermissionReviewerStatus = .disabled
    @Published private(set) var inferenceProfileOptions: [AppInferenceProfileOption]
    @Published private(set) var inferenceResolutionFailures: [String: String] = [:]

    var isAutomaticPermissionReviewReady: Bool {
        switch permissionReviewerStatus {
        case .enabled, .degraded:
            return true
        case .disabled, .enabling, .fallback, .failed:
            return false
        }
    }

    var isMainInferenceReady: Bool {
        agents.first(where: { $0.name == projectSettings.mainAgentName })?
            .inferenceResolution == .resolved
    }

    var mainInferenceDisplayLabel: String {
        guard let main = agents.first(where: { $0.name == projectSettings.mainAgentName }) else {
            return "@\(projectSettings.mainAgentName) inference not attached"
        }
        return main.inferenceDisplayLabel ?? "@\(main.name) inference unavailable"
    }

    var inferenceComposerError: String? {
        guard agents.contains(where: { $0.name == projectSettings.mainAgentName }),
              !isMainInferenceReady else {
            return nil
        }
        return "@\(projectSettings.mainAgentName) needs an explicit, resolvable inference profile rebind before Cowork can run."
    }

    private let log: EventLog
    private let registryBox: ProviderRegistryBox
    private var orchestrator: Orchestrator?
    private var goalRuntime: GoalRuntimeController?
    private var subscription: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var permissionWaiters: [RequestID: CoworkPermissionWaiter] = [:]
    private var permissionQueue: [PendingPermission] = []
    private var suppressedPermissionRequestIDs: Set<RequestID> = []
    private var activeOperations: [UUID: Task<Void, Never>] = [:]
    private var retryableTasks: [String: CoworkTaskView] = [:]
    private var latestCoworkProjection = CoworkProjection()
    private var didRequestMainAgentAttach = false
    private var steadyPermissionReviewerStatus: CoworkPermissionReviewerStatus = .disabled
    let sessionID: SessionID

    init(sessionID: SessionID,
         log: EventLog,
         registry: ProviderRegistry,
         inferenceProfileOptions: [AppInferenceProfileOption],
         projectSettings: CoworkProjectSettings) {
        self.sessionID = sessionID
        self.log = log
        self.registryBox = ProviderRegistryBox(
            registry,
            controlPlaneBinding: nil)
        self.inferenceProfileOptions = inferenceProfileOptions
        self.projectSettings = projectSettings
        self.project = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: projectSettings,
            projection: CoworkProjection())
    }

    deinit {
        subscription?.cancel()
    }

    func updateProviderRegistry(
        _ registry: ProviderRegistry,
        inferenceProfileOptions: [AppInferenceProfileOption]? = nil
    ) {
        if let inferenceProfileOptions {
            self.inferenceProfileOptions = inferenceProfileOptions
        }
        let bindings = (inferenceProfileOptions ?? self.inferenceProfileOptions).map(\.binding)
        Task {
            await registryBox.update(registry)
            await orchestrator?.updateAvailableInferenceProfiles(
                bindings,
                hostAuthorized: true)
            await refreshInferenceResolutionState()
        }
    }

    func start() {
        guard orchestrator == nil, shutdownTask == nil else { return }
        setPermissionReviewerStatus(.enabling)
        let registryBox = registryBox
        do {
            let runtime = try Orchestrator.runtime(
                log: log,
                allowsShell: PlatformProfile.current.allowsShell,
                responder: self,
                executionPolicy: CoworkExecutionPolicy(tokenBudget: projectSettings.tokenBudget),
                availableInferenceProfiles: inferenceProfileOptions.map(\.binding),
                requiresInferenceBindings: true,
                imageGeneratorFor: { _ in await registryBox.imageToolService() },
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
            projectionError = "Cowork session could not start: \(message)"
            setPermissionReviewerStatus(.failed(message))
            return
        }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let replayed = await self.log.replay()
            var codeProjection = CodeProjection.build(from: replayed)
            var coworkProjection = CoworkProjection.build(from: replayed)
            var permissions = PermissionProjection.build(from: replayed, markNeedsRerun: true)
            var turnStats = TurnStatsProjection.build(from: replayed)
            self.restoreWorkspaceAccess(for: coworkProjection)
            await self.orchestrator?.restore(from: coworkProjection)
            await self.refreshInferenceResolutionState()

            // Restore may durably reconcile stale control-plane state. Rebuild
            // every projection from that authoritative tail before starting
            // bootstrap, then register the stream first so bootstrap admission
            // events cannot remain invisible while another startup step waits.
            let restored = await self.log.replay()
            codeProjection = CodeProjection.build(from: restored)
            coworkProjection = CoworkProjection.build(from: restored)
            permissions = PermissionProjection.build(from: restored, markNeedsRerun: true)
            turnStats = TurnStatsProjection.build(from: restored)
            self.items = codeProjection.items
            self.pendingPermission = self.presentedPermission(projected: permissions.latest)
            self.permissionNotice = permissions.latestResolved
            self.latestTurnStats = turnStats.latest
            self.applyCoworkProjection(coworkProjection)
            let stream = await self.log.stream(from: (restored.last?.seq ?? -1) + 1)

            if restored.isEmpty {
                // Choosing the primary workspace is the explicit authorization
                // for the fixed @main bootstrap. Do not ask a model to approve
                // that same user choice a second time.
                await self.bootstrapMainAgentIfNeeded(
                    existingProjection: coworkProjection,
                    allowsInitialSessionBootstrap: true)
                await self.ensureAutomaticPermissionReview(existingProjection: coworkProjection)
            } else {
                // Recovery is not a fresh-session trust boundary. Re-enable the
                // reviewer first, then keep ordinary attach semantics if a
                // historical session is unexpectedly missing @main.
                await self.ensureAutomaticPermissionReview(existingProjection: coworkProjection)
                await self.bootstrapMainAgentIfNeeded(
                    existingProjection: coworkProjection,
                    allowsInitialSessionBootstrap: false)
            }
            // Data-plane recovery is authorized only after both @main and the
            // automatic reviewer are actually ready. Goal recovery runs first
            // so a paused legacy run can be cancelled before pending scheduler
            // work is allowed to resume.
            await self.resumeRuntimeIfReady()
            for await envelope in stream {
                codeProjection.apply(envelope)
                coworkProjection.apply(envelope)
                permissions.apply(envelope)
                turnStats.apply(envelope)
                if case .permissionResolved(let payload) = envelope.event,
                   let requestID = payload.requestId {
                    self.suppressedPermissionRequestIDs.remove(requestID)
                }
                self.items = codeProjection.items
                self.pendingPermission = self.presentedPermission(projected: permissions.latest)
                self.permissionNotice = permissions.latestResolved
                self.latestTurnStats = turnStats.latest
                self.applyCoworkProjection(coworkProjection)
            }
        }
    }

    func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let runningSubscription = subscription
        runningSubscription?.cancel()
        subscription = nil
        let runningOrchestrator = orchestrator
        let runningGoalRuntime = goalRuntime
        orchestrator = nil
        goalRuntime = nil
        for operation in activeOperations.values { operation.cancel() }
        activeOperations.removeAll()
        for (requestID, waiter) in permissionWaiters {
            suppressedPermissionRequestIDs.insert(requestID)
            waiter.resolve(.deny)
        }
        permissionWaiters.removeAll()
        permissionQueue.removeAll()
        if var pending = pendingPermission, pending.state.isActionable {
            pending.state = .expired
            pendingPermission = pending
        }
        isWorking = false
        isGoalContinuing = false
        isGoalRuntimeReady = false
        goal = Self.goalPresentation(
            from: latestCoworkProjection,
            controlsEnabled: false)
        addAgentStatus = .idle
        setPermissionReviewerStatus(.disabled)
        let task = Task<Void, Never> {
            // Let the cancelled startup/stream task observe cancellation before
            // teardown touches the captured runtime. This prevents a stale
            // startup continuation from releasing the restore scheduler gate.
            if let runningSubscription { await runningSubscription.value }
            if let runningGoalRuntime {
                await runningGoalRuntime.shutdown()
            }
            if let runningOrchestrator {
                await runningOrchestrator.cancelAll(reason: "cowork view stopped")
            }
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func applyCoworkProjection(_ projection: CoworkProjection) {
        latestCoworkProjection = projection
        goal = Self.goalPresentation(
            from: projection,
            controlsEnabled: isGoalRuntimeReady)
        workTasks = Self.workTaskPresentation(from: projection)
        if let currentGoalID = projection.currentGoalID,
           projection.goals[currentGoalID]?.status == .active {
            isGoalContinuing = projection.continuationRuns.values.contains {
                $0.goalID == currentGoalID && !$0.status.isTerminal
            }
        } else {
            isGoalContinuing = false
        }
        agents = agentPresentation(from: projection)

        summary = CoworkStatusSummary(
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
        project = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: projectSettings,
            projection: projection)
        let retryable = projection.failedTasks + projection.cancelledTasks
        retryableTasks = Dictionary(uniqueKeysWithValues: retryable.map { ($0.id.rawValue, $0) })
        projectionError = nil
    }

    private func agentPresentation(from projection: CoworkProjection) -> [CoworkAgentInfo] {
        projection.agentRoster.values
            .sorted { $0.agent.rawValue < $1.agent.rawValue }
            .map { payload in
                let mailbox = projection.mailboxes[payload.agent] ?? CoworkMailboxView()
                let capabilityLeases = projection.capabilityLeaseAgents
                    .filter { $0.value == payload.agent }
                    .compactMap { projection.capabilityLeases[$0.key] }
                let workspaceLeaseCount = projection.workspaceLeaseAgents.values.filter { $0 == payload.agent }.count
                let capabilityLeaseCount = capabilityLeases.count
                let isMain = payload.agent.rawValue == projectSettings.mainAgentName
                let binding = payload.agentInferenceBinding
                let inferenceOption = binding.flatMap { binding in
                    inferenceProfileOptions.first(where: { $0.binding == binding })
                }
                let inferenceResolution: CoworkInferenceResolution
                if binding == nil {
                    inferenceResolution = .legacy
                } else if inferenceResolutionFailures[payload.agent.rawValue] != nil {
                    inferenceResolution = .unresolved
                } else {
                    inferenceResolution = .resolved
                }
                return CoworkAgentInfo(
                    id: payload.agent.rawValue,
                    name: payload.agent.rawValue,
                    workspace: payload.path,
                    model: payload.model.rawValue,
                    permissionProfile: payload.profile,
                    inferenceProfileLabel: inferenceOption?.title,
                    inferenceProfileRef: binding?.inferenceProfileRef,
                    inferenceConnectionLabel: binding?.safeRouteLabel,
                    inferenceVariant: inferenceOption?.variantTitle ?? binding?.variantID,
                    inferenceResolution: inferenceResolution,
                    status: agentStatus(for: payload.agent, in: projection),
                    role: isMain ? "main" : Self.role(for: capabilityLeases),
                    pendingTasks: mailbox.pendingTasks.count,
                    pendingMessages: mailbox.pendingMessages.count,
                    completedTasks: mailbox.completedTasks.count,
                    workspaceLease: workspaceLeaseCount > 0 ? "\(workspaceLeaseCount) workspace lease" : nil,
                    capabilityLease: capabilityLeaseCount > 0 ? "\(capabilityLeaseCount) capability lease" : nil,
                    canRemove: !isMain && payload.agent != Orchestrator.automaticPermissionReviewerID)
            }
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
                parts.append("Remaining: " + audit.remainingWork.joined(separator: "; "))
            }
            if let blocker = audit.blocker, !blocker.isEmpty {
                parts.append("Blocker: \(blocker)")
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

    private func agentStatus(for agent: AgentID, in projection: CoworkProjection) -> String {
        if projection.runningTasks.contains(where: { $0.assignee == agent }) {
            return "running"
        }
        if let state = projection.agentStatuses[agent] {
            return state.rawValue
        }
        let mailbox = projection.mailboxes[agent]
        if mailbox?.pendingTasks.isEmpty == false {
            return "queued"
        }
        if mailbox?.pendingMessages.isEmpty == false {
            return "mailbox"
        }
        if projection.failedTasks.contains(where: { $0.assignee == agent }) {
            return "failed"
        }
        return "idle"
    }

    private func taskLine(_ task: CoworkTaskView) -> CoworkTaskLine {
        let assignee = task.assignee.map { "@\($0.rawValue)" } ?? "Unassigned"
        let title = task.contract.map { "\(assignee) · \($0.roleHint)" } ?? assignee
        let detail = task.contract?.objective ?? task.report?.summary ?? task.error ?? task.result ?? ""
        return CoworkTaskLine(id: task.id.rawValue, title: title, detail: detail, status: task.status.rawValue)
    }

    private func restoreWorkspaceAccess(for projection: CoworkProjection) {
        for workspace in projectSettings.workspaces {
            WorkspaceAccess.restoreAccess(forPath: workspace.path)
        }
        for payload in projection.agentRoster.values {
            WorkspaceAccess.restoreAccess(forPath: payload.path)
        }
    }

    private func ensureAutomaticPermissionReview(existingProjection projection: CoworkProjection) async {
        guard let orchestrator else {
            setPermissionReviewerStatus(.failed("Cowork session is not ready."))
            return
        }
        setPermissionReviewerStatus(.enabling)
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        let workspaceURL: URL
        guard let mainAgent = await orchestrator.agentList().first(where: {
            $0.name == mainID
        }), let mainBinding = mainAgent.agentInferenceBinding else {
            setPermissionReviewerStatus(.failed(
                "@\(mainID.rawValue) has no resolved inference profile for the control plane."))
            return
        }
        guard let controlPlaneBinding = await registryBox
            .freezeResolvableControlPlaneBinding(mainBinding) else {
            setPermissionReviewerStatus(.failed(
                "@\(mainID.rawValue) exact inference profile revision is unavailable or incompatible."))
            return
        }

        if let main = projection.agentRoster[mainID] {
            workspaceURL = WorkspaceAccess.restoreAccess(forPath: main.path)
                ?? URL(fileURLWithPath: main.path)
        } else if let workspace = projectSettings.primaryWorkspace {
            workspaceURL = WorkspaceAccess.restoreAccess(forPath: workspace.path)
                ?? URL(fileURLWithPath: workspace.path)
        } else {
            setPermissionReviewerStatus(.failed(
                "No primary workspace is available for @\(Orchestrator.automaticPermissionReviewerID.rawValue)."))
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
        guard let orchestrator else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
        }
        activeOperations[operationID] = operation
    }

    func retryAutomaticPermissionReview() {
        guard permissionReviewerStatus.canRetry, orchestrator != nil else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await self.ensureAutomaticPermissionReview(existingProjection: self.latestCoworkProjection)
            await self.resumeRuntimeIfReady()
        }
        activeOperations[operationID] = operation
    }

    private func resumeRuntimeIfReady() async {
        guard isAutomaticPermissionReviewReady,
              let orchestrator,
              let goalRuntime else { return }
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard await orchestrator.agentList().contains(where: { $0.name == mainID }) else {
            return
        }
        await refreshInferenceResolutionState()
        guard inferenceResolutionFailures[mainID.rawValue] == nil else {
            projectionError = "@\(mainID.rawValue) has an unresolved inference profile. Rebind it before resuming Cowork."
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
            let message = "Goal recovery could not be completed safely. Pending Cowork work remains stopped; retry after resolving the persistence or cancellation error."
            projectionError = message
            setPermissionReviewerStatus(.failed(message))
            return
        }
        let resumedPendingTasks = await orchestrator.resumePendingTasks()
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
    }

    private func bootstrapMainAgentIfNeeded(existingProjection projection: CoworkProjection,
                                            allowsInitialSessionBootstrap: Bool) async {
        guard !didRequestMainAgentAttach else { return }
        guard let orchestrator else { return }
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard projection.agentRoster[mainID] == nil else { return }
        guard let workspace = projectSettings.primaryWorkspace else { return }
        didRequestMainAgentAttach = true
        let url = WorkspaceAccess.restoreAccess(forPath: workspace.path)
            ?? URL(fileURLWithPath: workspace.path)
        guard let binding = projectSettings.defaultInferenceProfileBinding else {
            composerError = "Choose a default inference profile before attaching @\(mainID.rawValue)."
            return
        }
        let main = Agent(
            name: mainID,
            workspaceRoot: url,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: projectSettings.defaultProfile,
            coordinationDepth: Agent.defaultCoordinationDepth)
        let attached: Bool
        if allowsInitialSessionBootstrap {
            switch await orchestrator.bootstrapMainAgent(main) {
            case .attached, .alreadyAttached:
                attached = true
            case .failed(let message):
                attached = false
                composerError = message
            }
        } else {
            attached = await orchestrator.attach(main)
            await synchronizePermissionReviewerHealth(using: orchestrator)
            if !attached {
                composerError = "@\(mainID.rawValue) could not be attached to the primary workspace."
            }
        }
        if attached {
            composerError = nil
            rememberWorkspace(url, agentName: mainID.rawValue, isPrimary: true)
        }
    }

    @discardableResult
    func prepareAddAgent(name rawName: String) -> Bool {
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
        if addAgentStatus == .validating {
            addAgentStatus = .idle
        }
    }

    func resetAddAgentStatus() {
        addAgentStatus = .idle
    }

    func updateProjectSettings(_ settings: CoworkProjectSettings) {
        var normalized = settings
        normalized.sessionID = sessionID
        let trimmedMainAgentName = normalized.mainAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.mainAgentName = trimmedMainAgentName.isEmpty ? "main" : trimmedMainAgentName
        projectSettings = normalized
        Task {
            await orchestrator?.updateExecutionPolicy(
                CoworkExecutionPolicy(tokenBudget: normalized.tokenBudget))
        }
        CoworkProjectSettingsStore.save(normalized)
        project = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: normalized,
            projection: latestCoworkProjection)
    }

    func removeAgent(name rawName: String) {
        guard !isWorking, let orchestrator else { return }
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else { return }
        guard name != projectSettings.mainAgentName else {
            composerError = "Cannot remove @\(projectSettings.mainAgentName)."
            return
        }
        guard AgentID(rawValue: name) != Orchestrator.automaticPermissionReviewerID else {
            composerError = "@\(Orchestrator.automaticPermissionReviewerID.rawValue) is reserved."
            return
        }
        isWorking = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let detached = await orchestrator.detach(AgentID(rawValue: name))
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            guard detached else {
                self.composerError = "@\(name) could not be removed; it may still have active tasks."
                self.isWorking = false
                return
            }
            var settings = self.projectSettings
            settings.removeWorkspaces(forAgent: name)
            self.projectSettings = settings
            CoworkProjectSettingsStore.save(settings)
            self.project = Self.makeProjectInfo(
                sessionID: self.sessionID,
                settings: settings,
                projection: self.latestCoworkProjection)
            self.isWorking = false
        }
        activeOperations[operationID] = operation
    }

    func agentInferenceBinding(name rawName: String) -> AgentInferenceBinding? {
        let name = Self.normalizedAgentName(rawName)
        return latestCoworkProjection.agentRoster[AgentID(rawValue: name)]?
            .agentInferenceBinding
    }

    func rebindAgentInferenceProfile(
        name rawName: String,
        binding: AgentInferenceBinding
    ) {
        guard !isWorking, let orchestrator else { return }
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
        var settings = projectSettings
        settings.removeWorkspace(path: path)
        updateProjectSettings(settings)
    }

    func addProjectWorkspace(_ workspace: URL) {
        WorkspaceAccess.remember(workspace, for: nil)
        var settings = projectSettings
        settings.upsertWorkspace(
            path: workspace.standardizedFileURL.path,
            agentName: nil,
            isPrimary: false)
        updateProjectSettings(settings)
    }

    func addAgent(name rawName: String, workspace: URL) {
        guard let orchestrator else {
            addAgentStatus = .failed("Cowork session is not ready.")
            return
        }
        let normalizedName: String
        switch validateNewAgentName(rawName) {
        case .success(let name):
            normalizedName = name
        case .failure(let message):
            addAgentStatus = .failed(message)
            return
        }
        addAgentStatus = .attaching(normalizedName)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let replayed = await self.log.replay()
            let startSeq = replayed.last?.seq ?? -1
            guard let binding = self.projectSettings.defaultInferenceProfileBinding else {
                self.addAgentStatus = .failed("Choose a default inference profile for new agents.")
                return
            }
            let attached = await orchestrator.attach(Agent(name: AgentID(rawValue: normalizedName), workspaceRoot: workspace,
                                            model: binding.modelID,
                                            agentInferenceBinding: binding,
                                            profile: self.projectSettings.defaultProfile,
                                            coordinationDepth: 0))
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            if attached {
                self.rememberWorkspace(workspace, agentName: normalizedName, isPrimary: false)
                self.addAgentStatus = .attached(normalizedName)
                return
            }
            let events = await self.log.replay(from: startSeq + 1)
            self.addAgentStatus = self.attachFailureStatus(agentName: normalizedName, events: events)
        }
    }

    func send() {
        guard !isWorking, let orchestrator, let goalRuntime else { return }
        guard isAutomaticPermissionReviewReady else {
            composerError = "Automatic permission review must be ready before Cowork can run a task. Retry the reviewer."
            return
        }
        guard isGoalRuntimeReady else {
            composerError = "Goal recovery must finish before Cowork can run a task. Retry session recovery."
            return
        }
        let originalInput = input
        let initialParsed: ParsedUserInput
        switch GoalInputParser.parse(originalInput) {
        case .success(let value):
            initialParsed = value
        case .failure(.empty):
            composerError = CoworkMentionRouteError.emptyMessage.message
            return
        case .failure(let error):
            composerError = error.message
            return
        }
        let routeInput = initialParsed.isGoal ? initialParsed.text : originalInput
        let route = routeProjectInput(routeInput)
        switch route.outcome {
        case .blocked(let error):
            composerError = error.message
            return
        case .send(let text, let target):
            let finalParsed: ParsedUserInput
            switch GoalInputParser.parse(text) {
            case .success(let parsed) where parsed.isGoal:
                finalParsed = parsed
            case .failure(.missingGoal):
                composerError = GoalInputParseError.missingGoal.message
                return
            default:
                finalParsed = initialParsed.isGoal
                    ? ParsedUserInput(text: text, goal: text, tags: [ParsedUserInput.goalTag])
                    : ParsedUserInput(text: text)
            }
            let payload = UserMessagePayload(
                text: finalParsed.text,
                to: target,
                tags: finalParsed.tags.isEmpty ? nil : finalParsed.tags,
                goal: finalParsed.goal)
            input = ""
            composerError = nil
            isWorking = true
            let operationID = UUID()
            let operation = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.activeOperations.removeValue(forKey: operationID) }
                if finalParsed.isGoal {
                    let baseObjective = finalParsed.goal ?? finalParsed.text
                    let objective: String
                    if target != Orchestrator.mainAgentID {
                        objective = "@\(target.rawValue): \(baseObjective)"
                    } else {
                        objective = baseObjective
                    }
                    do {
                        _ = try await goalRuntime.createGoal(objective: objective)
                    } catch {
                        self.composerError = error.localizedDescription
                    }
                    await self.synchronizePermissionReviewerHealth(using: orchestrator)
                    self.isWorking = false
                    return
                }
                let explicitGoalIntent = ExplicitGoalIntentClassifier
                    .classify(finalParsed.text)
                    .isExplicit
                let result = await goalRuntime.sendUserTurn(
                    finalParsed.text,
                    to: target,
                    userMessage: payload,
                    explicitGoalIntent: explicitGoalIntent)
                await self.synchronizePermissionReviewerHealth(using: orchestrator)
                if let message = result.errorMessage {
                    self.composerError = message
                }
                self.isWorking = false
            }
            activeOperations[operationID] = operation
        }
    }

    func cancelCurrentTask() {
        guard isWorking, let orchestrator else { return }
        composerError = "Cancelling the current Cowork task…"
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await orchestrator.cancelActiveTasks(reason: "cancelled by user")
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            self.composerError = nil
            self.isWorking = false
        }
        activeOperations[operationID] = operation
    }

    func pauseGoal() {
        guard isGoalRuntimeReady, let goalRuntime else { return }
        performGoalAction {
            _ = try await goalRuntime.pauseCurrentGoal()
        }
    }

    func resumeGoal() {
        guard isGoalRuntimeReady, let goalRuntime else { return }
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
        guard !objective.isEmpty else { return "A Goal objective is required." }

        let budgetText = tokenBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedBudget: Int?
        if budgetText.isEmpty {
            parsedBudget = nil
        } else if let value = Int(budgetText), value > 0 {
            parsedBudget = value
        } else {
            return "Token budget must be a positive whole number, or left empty for no budget."
        }

        guard isGoalRuntimeReady,
              let goalRuntime,
              latestCoworkProjection.currentGoal != nil else {
            return "Goal recovery must finish before the durable Goal can be edited."
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
        guard isGoalRuntimeReady, let goalRuntime else { return }
        performGoalAction {
            try await goalRuntime.clearCurrentGoal(reason: "cleared by user from Cowork Goal card")
        }
    }

    private func performGoalAction(
        _ action: @escaping @MainActor @Sendable () async throws -> Void
    ) {
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
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.emptyMessage))
        }

        let attached = agents.map { AgentID(rawValue: $0.name) }
        if trimmed.hasPrefix("@") {
            return CoworkMentionRouter.route(input: trimmed, attachedAgents: attached)
        }

        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard attached.contains(mainID) else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.unknownMention(mainID.rawValue)))
        }
        return CoworkMentionRoute(originalInput: input, outcome: .send(text: trimmed, target: mainID))
    }

    func retryFailedTask(id: String) {
        guard !isWorking, let orchestrator else { return }
        guard let task = retryableTasks[id] else {
            composerError = "This failed task is no longer retryable."
            return
        }
        composerError = nil
        isWorking = true
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
        }
        activeOperations[operationID] = operation
    }

    // MARK: PermissionResponder

    nonisolated func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        let waiter = CoworkPermissionWaiter()
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled {
                waiter.resolve(.deny)
            }
            return await withCheckedContinuation { continuation in
                waiter.install(continuation)
                Task { @MainActor [weak self] in
                    guard let self else {
                        waiter.resolve(.deny)
                        return
                    }
                    self.registerPermission(request, waiter: waiter)
                }
            }
        }, onCancel: {
            waiter.resolve(.deny)
            Task { @MainActor [weak self] in
                self?.cancelPermission(request.requestId, waiter: waiter)
            }
        })
    }

    func resolvePermission(_ decision: PermissionDecision) {
        guard pendingPermission?.state.isActionable == true else { return }
        guard let requestID = pendingPermission?.request.requestId,
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
        waiter.resolve(decision)
        permissionQueue.removeAll { $0.request.requestId == requestID }
        pendingPermission = permissionQueue.first
        restoreSteadyPermissionReviewerStatusIfPossible()
    }

    private func registerPermission(_ request: PermissionRequestPayload,
                                    waiter: CoworkPermissionWaiter) {
        guard waiter.isPending else { return }
        let requestID = request.requestId
        if let previous = permissionWaiters.removeValue(forKey: requestID), previous !== waiter {
            previous.resolve(.deny)
        }
        permissionQueue.removeAll { $0.request.requestId == requestID }
        guard waiter.isPending else { return }

        suppressedPermissionRequestIDs.remove(requestID)
        permissionWaiters[requestID] = waiter
        permissionQueue.append(PendingPermission(
            request: request,
            state: .livePending,
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
            return "Automatic review unexpectedly left the automatic path; Cowork input is locked."
        case .failed(let reason):
            return "Automatic review is unavailable (\(reason)); retry before running Cowork tasks."
        case .disabled:
            return "Automatic review is disabled; Cowork input is locked."
        case .enabling:
            return "Automatic review is still starting; Cowork input remains locked."
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
            return .failure("Enter an agent name.")
        }
        guard name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .failure("Agent names cannot contain spaces.")
        }
        let existing = agents.map(\.name)
        if existing.contains(name) {
            return .failure("@\(name) is already attached.")
        }
        if existing.contains(where: { $0.lowercased() == name.lowercased() }) {
            return .failure("@\(name) conflicts with an attached agent name.")
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
        return .failed("Could not attach @\(agentName).")
    }

    private func rememberWorkspace(_ url: URL, agentName: String, isPrimary: Bool) {
        WorkspaceAccess.remember(url, for: isPrimary ? sessionID : nil)
        var settings = projectSettings
        settings.upsertWorkspace(
            path: url.standardizedFileURL.path,
            agentName: agentName,
            isPrimary: isPrimary)
        projectSettings = settings
        CoworkProjectSettingsStore.save(settings)
        project = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: settings,
            projection: latestCoworkProjection)
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
                canRemove: !(isPrimary && workspace.agentName == mainName))
        }

        for payload in projection.agentRoster.values {
            let path = URL(fileURLWithPath: payload.path).standardizedFileURL.path
            let existing = workspacesByPath[path]
            let isPrimary = existing?.isPrimary == true || payload.agent.rawValue == mainName
            workspacesByPath[path] = CoworkWorkspaceInfo(
                path: path,
                displayName: displayName(forPath: path),
                agentName: payload.agent.rawValue,
                isPrimary: isPrimary,
                access: accessDescription(for: payload.agent, in: projection),
                canRemove: payload.agent.rawValue != mainName
                    && payload.agent != Orchestrator.automaticPermissionReviewerID)
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
            tokenBudget: settings.tokenBudget.map { "\(formatNumber($0)) tok" },
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
        guard let model, !model.isEmpty else { return "current model" }
        if let provider = settings.defaultProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return "\(provider)/\(model)"
        }
        return model
    }

    private static func permissionDescription(_ rawValue: String) -> String {
        switch PermissionProfile(rawValue: rawValue) {
        case .some(.manual): return "manual"
        case .some(.reviewed): return "reviewed"
        case .some(.autopilot): return "autopilot"
        case .some(.readOnly): return "read only"
        case .some(.locked): return "locked"
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
            return "Validating agent…"
        case .attaching(let name):
            return "Attaching @\(name)…"
        case .attached(let name):
            return "@\(name) attached."
        case .denied(let reason):
            return "Permission denied: \(reason)"
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
