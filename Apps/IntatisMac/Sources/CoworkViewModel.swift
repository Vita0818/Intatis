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

    init(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    func update(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    func defaultAgentProvider() async throws -> ToolCallingProvider {
        try await registry.defaultAgentProvider()
    }

    func agentModel() async -> ModelID {
        await registry.agentModel()
    }
}

/// Drives a Cowork session: owns the `Orchestrator`, folds the shared event log
/// into items + an agent roster, parses `@mention` routing, and serves as the
/// `PermissionResponder` for whichever agent is currently acting.
@MainActor
final class CoworkViewModel: ObservableObject, PermissionResponder {
    @Published private(set) var items: [CodeItem] = []
    @Published private(set) var agents: [CoworkAgentInfo] = []
    @Published private(set) var summary = CoworkStatusSummary()
    @Published var input: String = ""
    @Published private(set) var isWorking = false
    @Published var pendingPermission: PendingPermission?
    @Published private(set) var permissionNotice: PermissionResolutionNotice?
    @Published private(set) var latestTurnStats: TurnStatsSnapshot?
    @Published private(set) var composerError: String?
    @Published private(set) var projectionError: String?
    @Published private(set) var addAgentStatus: CoworkAddAgentStatus = .idle

    private let log: EventLog
    private let registryBox: ProviderRegistryBox
    private var orchestrator: Orchestrator?
    private var subscription: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?
    private var retryableTasks: [String: CoworkTaskView] = [:]
    let sessionID: SessionID

    init(sessionID: SessionID, log: EventLog, registry: ProviderRegistry) {
        self.sessionID = sessionID
        self.log = log
        self.registryBox = ProviderRegistryBox(registry)
    }

    deinit {
        subscription?.cancel()
    }

    func updateProviderRegistry(_ registry: ProviderRegistry) {
        Task { await registryBox.update(registry) }
    }

    func start() {
        guard orchestrator == nil else { return }
        let registryBox = registryBox
        orchestrator = Orchestrator(log: log, allowsShell: PlatformProfile.current.allowsShell, responder: self) { _ in
            try await registryBox.defaultAgentProvider()
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
            self.items = codeProjection.items
            self.pendingPermission = permissions.latest
            self.permissionNotice = permissions.latestResolved
            self.latestTurnStats = turnStats.latest
            self.applyCoworkProjection(coworkProjection)
            let stream = await self.log.stream(from: (replayed.last?.seq ?? -1) + 1)
            for await envelope in stream {
                codeProjection.apply(envelope)
                coworkProjection.apply(envelope)
                permissions.apply(envelope)
                turnStats.apply(envelope)
                self.items = codeProjection.items
                self.pendingPermission = permissions.latest
                self.permissionNotice = permissions.latestResolved
                self.latestTurnStats = turnStats.latest
                self.applyCoworkProjection(coworkProjection)
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
        orchestrator = nil
        isWorking = false
        addAgentStatus = .idle
    }

    private func applyCoworkProjection(_ projection: CoworkProjection) {
        agents = projection.agentRoster.values
            .sorted { $0.agent.rawValue < $1.agent.rawValue }
            .map { payload in
                let mailbox = projection.mailboxes[payload.agent] ?? CoworkMailboxView()
                let workspaceLeaseCount = projection.workspaceLeaseAgents.values.filter { $0 == payload.agent }.count
                let capabilityLeaseCount = projection.capabilityLeaseAgents.values.filter { $0 == payload.agent }.count
                return CoworkAgentInfo(
                    id: payload.agent.rawValue,
                    name: payload.agent.rawValue,
                    workspace: payload.path,
                    model: payload.model.rawValue,
                    profile: payload.profile,
                    status: agentStatus(for: payload.agent, in: projection),
                    pendingTasks: mailbox.pendingTasks.count,
                    pendingMessages: mailbox.pendingMessages.count,
                    completedTasks: mailbox.completedTasks.count,
                    workspaceLease: workspaceLeaseCount > 0 ? "\(workspaceLeaseCount) workspace lease" : nil,
                    capabilityLease: capabilityLeaseCount > 0 ? "\(capabilityLeaseCount) capability lease" : nil)
            }

        summary = CoworkStatusSummary(
            activeCount: projection.activeTasks.count,
            runningCount: projection.runningTasks.count,
            completedCount: projection.completedTasks.count,
            failedCount: projection.failedTasks.count,
            pendingMailboxCount: projection.mailboxes.values.reduce(0) { $0 + $1.pendingMessages.count + $1.pendingTasks.count },
            completedMailboxCount: projection.mailboxes.values.reduce(0) { $0 + $1.completedTasks.count },
            workspaceLeaseCount: projection.workspaceLeases.count,
            capabilityLeaseCount: projection.capabilityLeases.count,
            runningTasks: projection.runningTasks.map(taskLine),
            failedTasks: projection.failedTasks.map(taskLine),
            recentCompletedTasks: Array(projection.completedTasks.suffix(3)).map(taskLine))
        retryableTasks = Dictionary(uniqueKeysWithValues: projection.failedTasks.map { ($0.id.rawValue, $0) })
        projectionError = nil
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
        let detail = task.error ?? task.result ?? task.contract?.objective ?? ""
        return CoworkTaskLine(id: task.id.rawValue, title: title, detail: detail, status: task.status.rawValue)
    }

    private func restoreWorkspaceAccess(for projection: CoworkProjection) {
        for payload in projection.agentRoster.values {
            WorkspaceAccess.restoreAccess(forPath: payload.path)
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
            let model = await self.registryBox.agentModel()
            let attached = await orchestrator.attach(Agent(name: AgentID(rawValue: normalizedName), workspaceRoot: workspace,
                                            model: model, profile: .reviewed,
                                            coordinationDepth: Agent.defaultCoordinationDepth))
            if attached {
                self.addAgentStatus = .attached(normalizedName)
                return
            }
            let events = await self.log.replay(from: startSeq + 1)
            self.addAgentStatus = self.attachFailureStatus(agentName: normalizedName, events: events)
        }
    }

    func send() {
        guard !isWorking, let orchestrator else { return }
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
        let route = CoworkMentionRouter.route(
            input: routeInput,
            attachedAgents: agents.map { AgentID(rawValue: $0.name) })
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await orchestrator.send(finalParsed.text, to: target, userMessage: payload)
                if let message = result.errorMessage {
                    self.composerError = message
                    if self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.input = originalInput
                    }
                }
                self.isWorking = false
            }
        }
    }

    func retryFailedTask(id: String) {
        guard !isWorking, let orchestrator else { return }
        guard let task = retryableTasks[id] else {
            composerError = "This failed task is no longer retryable."
            return
        }
        composerError = nil
        isWorking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await orchestrator.retry(task)
            if let message = result.errorMessage {
                self.composerError = message
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
