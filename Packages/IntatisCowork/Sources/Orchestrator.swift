import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel

public enum OrchestratorSendResult: Equatable, Sendable {
    case sent
    case failed(String)

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum AutomaticPermissionReviewResult: Equatable, Sendable {
    case enabled(AgentID)
    case alreadyEnabled(AgentID)
    case failed(String)
}

/// Coordinates multiple agents over one shared event log (ARCHITECTURE.md §7).
/// Routes `@mentioned` user messages to the right agent, and mediates every
/// agent-to-agent exchange through the Message Bus. An `actor`, so concurrent /
/// reentrant agent runs serialize safely.
public actor Orchestrator {
    public static let mainAgentID = AgentID(rawValue: "main")
    public static let automaticPermissionReviewerID = AgentID(rawValue: "permission-reviewer")

    private let log: EventLog
    private var registry: AgentRegistry
    private let bus: MessageBus
    private let engine: PermissionEngine
    private let allowsShell: Bool
    private let responder: PermissionResponder
    private var automaticPermissionResponder: AgentPermissionResponder?
    private var automaticPermissionReviewerAgentID: AgentID?
    private var capabilityLeases: [CapabilityLeaseID: CapabilityLease]
    private var workspaceLeases: [WorkspaceLeaseID: WorkspaceLease]
    private var defaultCapabilityLeaseIDs: [AgentID: CapabilityLeaseID]
    private var defaultWorkspaceLeaseIDs: [AgentID: WorkspaceLeaseID]
    private var scheduler: AgentScheduler
    private var taskGraph: TaskGraph
    private var scheduledReplyTargets: [TaskID: AgentID]
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let maxSteps: Int
    private let providerFor: @Sendable (Agent) async throws -> ToolCallingProvider

    public init(log: EventLog,
                mediator: Mediator = Mediator(),
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                responder: PermissionResponder,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxSteps: Int = 50,
                taskGraphPolicy: TaskGraphPolicy = .default,
                providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider) {
        self.log = log
        self.registry = AgentRegistry()
        self.bus = MessageBus(log: log, mediator: mediator)
        self.engine = engine
        self.allowsShell = allowsShell
        self.responder = responder
        self.automaticPermissionResponder = nil
        self.automaticPermissionReviewerAgentID = nil
        self.capabilityLeases = [:]
        self.workspaceLeases = [:]
        self.defaultCapabilityLeaseIDs = [:]
        self.defaultWorkspaceLeaseIDs = [:]
        self.scheduler = AgentScheduler()
        self.taskGraph = TaskGraph(policy: taskGraphPolicy)
        self.scheduledReplyTargets = [:]
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxSteps = maxSteps
        self.providerFor = providerFor
    }

    @discardableResult
    public func attach(_ agent: Agent) async -> Bool {
        let id = agent.name
        guard id != Self.automaticPermissionReviewerID else {
            try? await log.append(.error(ErrorPayload(
                code: "reserved_agent",
                message: "@\(id.rawValue) is reserved for automatic permission review")))
            return false
        }
        guard registry.agent(id) == nil else {
            try? await log.append(.error(ErrorPayload(code: "agent_exists",
                                                       message: "agent @\(id.rawValue) already exists")))
            return false
        }

        let assessment = assessWorkspaceAttach(agent.workspaceRoot)
        let requestID = RequestID.new()
        let request = PermissionRequestPayload(
            requestId: requestID,
            agent: agent.name,
            tool: "agent.attach",
            args: attachArgs(agent: agent, canonicalPath: assessment.canonical?.path ?? agent.workspaceRoot.path),
            risk: assessment.risk,
            reason: assessment.reason)
        try? await log.append(.agentAttachRequested(AgentAttachRequestedPayload(
            agent: agent.name,
            path: assessment.canonical?.path ?? agent.workspaceRoot.path,
            model: agent.model,
            profile: agent.profile.rawValue,
            metadata: CoworkEventMetadata(agentID: agent.name, scope: .agent))))
        try? await log.append(.workspaceLeaseRequested(WorkspaceLeaseRequestedPayload(
            agent: agent.name,
            rootPath: assessment.canonical?.path ?? agent.workspaceRoot.path,
            access: .readWrite,
            reason: assessment.reason,
            metadata: CoworkEventMetadata(agentID: agent.name, scope: .workspace))))
        try? await log.append(.permissionRequest(request))

        guard assessment.canAskUser else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: assessment.risk, reason: assessment.reason)))
            try? await log.append(.workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                agent: agent.name,
                rootPath: assessment.canonical?.path ?? agent.workspaceRoot.path,
                reason: assessment.reason,
                metadata: CoworkEventMetadata(agentID: agent.name, scope: .workspace))))
            return false
        }

        let decision = await activePermissionResponder().requestApproval(request)
        guard decision == .allow else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: assessment.risk, reason: "user denied workspace attach")))
            try? await log.append(.workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                agent: agent.name,
                rootPath: assessment.canonical?.path ?? agent.workspaceRoot.path,
                reason: "user denied workspace attach",
                metadata: CoworkEventMetadata(agentID: agent.name, scope: .workspace))))
            return false
        }
        guard registry.agent(id) == nil else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: .medium, reason: "agent already exists")))
            return false
        }

        var approved = agent
        if let canonical = assessment.canonical { approved.workspaceRoot = canonical }
        registry.add(approved)
        let leases = createDefaultLeases(for: approved)
        try? await log.append(.permissionResolved(PermissionResolvedPayload(
            requestId: requestID, tool: "agent.attach", decision: .allow,
            risk: assessment.risk, reason: "user approved workspace attach")))
        try? await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: approved.name,
            lease: leases.workspace,
            metadata: CoworkEventMetadata(
                agentID: approved.name,
                workspaceID: leases.workspace.workspaceID,
                workspaceLeaseID: leases.workspace.id,
                scope: .workspace))))
        try? await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: approved.name,
            lease: leases.capability,
            metadata: CoworkEventMetadata(
                agentID: approved.name,
                capabilityLeaseID: leases.capability.id,
                scope: .capability))))
        try? await log.append(.agentAttached(AgentAttachedPayload(
            agent: approved.name, path: approved.workspaceRoot.path, model: approved.model,
            profile: approved.profile.rawValue,
            metadata: CoworkEventMetadata(agentID: approved.name, scope: .agent))))
        return true
    }

    public func detach(_ name: AgentID) async {
        if name == automaticPermissionReviewerAgentID {
            automaticPermissionResponder = nil
            automaticPermissionReviewerAgentID = nil
        }
        registry.remove(name)
        if let capabilityLeaseID = defaultCapabilityLeaseIDs.removeValue(forKey: name) {
            capabilityLeases.removeValue(forKey: capabilityLeaseID)
            try? await log.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: name,
                leaseID: capabilityLeaseID,
                reason: "agent detached",
                metadata: CoworkEventMetadata(agentID: name, capabilityLeaseID: capabilityLeaseID, scope: .capability))))
        }
        if let workspaceLeaseID = defaultWorkspaceLeaseIDs.removeValue(forKey: name) {
            workspaceLeases.removeValue(forKey: workspaceLeaseID)
        }
        try? await log.append(.agentDetached(AgentDetachedPayload(
            agent: name,
            metadata: CoworkEventMetadata(agentID: name, scope: .agent))))
    }

    public func agentNames() -> [AgentID] { registry.names }
    public func agentList() -> [Agent] { registry.all() }
    public func automaticPermissionReviewEnabled() -> Bool { automaticPermissionResponder != nil }
    func capabilityLeaseList() -> [CapabilityLease] { Array(capabilityLeases.values) }
    func workspaceLeaseList() -> [WorkspaceLease] { Array(workspaceLeases.values) }
    func capabilityLease(id: CapabilityLeaseID) -> CapabilityLease? { capabilityLeases[id] }
    func workspaceLease(id: WorkspaceLeaseID) -> WorkspaceLease? { workspaceLeases[id] }
    func queuedTasks() -> [ScheduledTask] { scheduler.queuedTasks() }
    func executionRecord(taskID: TaskID) -> ExecutionRecord? { scheduler.record(for: taskID) }
    func mailbox(for agent: AgentID) -> AgentMailbox { scheduler.mailbox(for: agent) }
    func taskGraphSnapshot() -> TaskGraph { taskGraph }
    func taskGraphNode(_ taskID: TaskID) -> TaskNode? { taskGraph.node(taskID) }

    @discardableResult
    public func enableAutomaticPermissionReview(model: ModelID,
                                                 workspaceRoot: URL,
                                                 name: AgentID = Orchestrator.automaticPermissionReviewerID) async -> AutomaticPermissionReviewResult {
        guard automaticPermissionResponder == nil else {
            return .alreadyEnabled(automaticPermissionReviewerAgentID ?? name)
        }
        guard name == Self.automaticPermissionReviewerID else {
            return .failed("automatic permission reviewer must use @\(Self.automaticPermissionReviewerID.rawValue)")
        }
        guard registry.agent(name) == nil else {
            return .failed("@\(name.rawValue) already exists; the automatic reviewer identity is reserved")
        }

        let assessment = assessWorkspaceAttach(workspaceRoot)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return .failed(assessment.reason)
        }

        let reviewer = Agent(
            name: name,
            workspaceRoot: canonical,
            model: model,
            profile: .readOnly,
            coordinationDepth: 0)

        let provider: ToolCallingProvider
        do {
            provider = try await providerFor(reviewer)
        } catch {
            return .failed(error.localizedDescription)
        }

        let workspaceLease = WorkspaceLease(rootPath: reviewer.workspaceRoot.path, access: .readOnly)
        let capabilityLease = CapabilityLease(
            tools: [],
            communication: .none,
            delegation: .none,
            expiresAtTaskCompletion: false)

        registry.add(reviewer)
        workspaceLeases[workspaceLease.id] = workspaceLease
        capabilityLeases[capabilityLease.id] = capabilityLease
        defaultWorkspaceLeaseIDs[reviewer.name] = workspaceLease.id
        defaultCapabilityLeaseIDs[reviewer.name] = capabilityLease.id
        automaticPermissionReviewerAgentID = reviewer.name
        automaticPermissionResponder = AgentPermissionResponder(
            log: log,
            reviewerAgent: reviewer,
            provider: provider,
            fallback: responder)

        try? await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: reviewer.name,
            lease: workspaceLease,
            metadata: CoworkEventMetadata(
                agentID: reviewer.name,
                workspaceID: workspaceLease.workspaceID,
                workspaceLeaseID: workspaceLease.id,
                scope: .workspace))))
        try? await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: reviewer.name,
            lease: capabilityLease,
            metadata: CoworkEventMetadata(
                agentID: reviewer.name,
                capabilityLeaseID: capabilityLease.id,
                scope: .capability))))
        try? await log.append(.agentAttached(AgentAttachedPayload(
            agent: reviewer.name,
            path: reviewer.workspaceRoot.path,
            model: reviewer.model,
            profile: reviewer.profile.rawValue,
            metadata: CoworkEventMetadata(agentID: reviewer.name, scope: .agent))))
        return .enabled(reviewer.name)
    }

    @discardableResult
    public func disableAutomaticPermissionReview() async -> Bool {
        guard let reviewerID = automaticPermissionReviewerAgentID else {
            return false
        }

        automaticPermissionResponder = nil
        automaticPermissionReviewerAgentID = nil
        registry.remove(reviewerID)
        if let capabilityLeaseID = defaultCapabilityLeaseIDs.removeValue(forKey: reviewerID) {
            capabilityLeases.removeValue(forKey: capabilityLeaseID)
            try? await log.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: reviewerID,
                leaseID: capabilityLeaseID,
                reason: "automatic permission review disabled",
                metadata: CoworkEventMetadata(
                    agentID: reviewerID,
                    capabilityLeaseID: capabilityLeaseID,
                    scope: .capability))))
        }
        if let workspaceLeaseID = defaultWorkspaceLeaseIDs.removeValue(forKey: reviewerID) {
            workspaceLeases.removeValue(forKey: workspaceLeaseID)
        }
        try? await log.append(.agentDetached(AgentDetachedPayload(
            agent: reviewerID,
            metadata: CoworkEventMetadata(agentID: reviewerID, scope: .agent))))
        return true
    }

    public func restore(from projection: CoworkProjection) {
        for payload in projection.agentRoster.values {
            guard payload.agent != Self.automaticPermissionReviewerID else { continue }
            let profile = PermissionProfile(rawValue: payload.profile) ?? .reviewed
            registry.add(Agent(
                name: payload.agent,
                workspaceRoot: URL(fileURLWithPath: payload.path),
                model: payload.model,
                profile: profile,
                coordinationDepth: Agent.defaultCoordinationDepth))
        }
        workspaceLeases = projection.workspaceLeases
        capabilityLeases = projection.capabilityLeases
        defaultWorkspaceLeaseIDs = reverseLeaseAgents(projection.workspaceLeaseAgents)
        defaultCapabilityLeaseIDs = reverseLeaseAgents(projection.capabilityLeaseAgents)
    }

    /// Route a user message to the explicit target, or to the first attached agent
    /// only when the caller did not specify a target.
    @discardableResult
    public func send(_ text: String,
                     to: AgentID? = nil,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil) async -> OrchestratorSendResult {
        let agent: Agent
        if let to {
            guard to != Self.automaticPermissionReviewerID else {
                let message = "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review."
                try? await log.append(.error(ErrorPayload(code: "reserved_agent", message: message)))
                return .failed(message)
            }
            guard let explicitTarget = registry.agent(to) else {
                try? await log.append(.error(ErrorPayload(
                    code: "no_such_agent",
                    message: "no attached agent named @\(to.rawValue)")))
                return .failed("No attached agent named @\(to.rawValue).")
            }
            agent = explicitTarget
        } else {
            let defaultTarget = registry.agent(Self.mainAgentID)
                ?? registry.all().first(where: { $0.name != Self.automaticPermissionReviewerID })
            guard let defaultTarget else {
                try? await log.append(.error(ErrorPayload(code: "no_agent", message: "no agent attached")))
                return .failed("No agent attached.")
            }
            agent = defaultTarget
        }
        // AgentLoop appends the user message itself — don't double-log it here.
        do {
            _ = try await run(agent, input: text, images: images, userMessage: userMessage)
        } catch {
            let message = error.localizedDescription
            try? await log.append(.error(ErrorPayload(code: "agent", message: message)))
            return .failed(message)
        }
        await runSchedulerUntilIdle()
        return .sent
    }

    @discardableResult
    public func retry(_ task: CoworkTaskView) async -> OrchestratorSendResult {
        guard let contract = task.contract else {
            return .failed("This task cannot be retried because its contract is missing.")
        }
        let assignee = task.assignee ?? contract.assignee
        guard assignee != Self.automaticPermissionReviewerID else {
            return .failed("@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review.")
        }
        guard registry.agent(assignee) != nil else {
            let message = "No attached agent named @\(assignee.rawValue)."
            try? await log.append(.error(ErrorPayload(code: "no_such_agent", message: message)))
            return .failed(message)
        }

        let rootTaskID = task.rootTaskID ?? contract.parentTaskID ?? contract.id
        let parentTaskID = task.parentTaskID ?? contract.parentTaskID
        let issuer = task.issuer ?? contract.issuer
        let visitedAgents = Self.uniqueAgents([issuer, assignee].compactMap { $0 })
        let scheduled = ScheduledTask(
            contract: contract,
            input: contract.objective,
            rootTaskID: rootTaskID,
            parentTaskID: parentTaskID,
            issuer: issuer,
            assignee: assignee,
            causalParentID: parentTaskID,
            hopCount: max(0, visitedAgents.count - 1),
            visitedAgents: visitedAgents)
        scheduler.enqueue(scheduled)
        taskGraph.updateStatus(taskID: contract.id, status: .queued)
        try? await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: scheduled.rootTaskID,
            parentTaskID: scheduled.parentTaskID,
            issuer: scheduled.issuer,
            assignee: scheduled.assignee,
            causalParentID: scheduled.causalParentID,
            hopCount: scheduled.hopCount,
            visitedAgents: scheduled.visitedAgents,
            metadata: taskMetadata(
                contract: contract,
                rootTaskID: scheduled.rootTaskID,
                parentTaskID: scheduled.parentTaskID,
                sender: scheduled.issuer,
                recipient: scheduled.assignee))))
        await runSchedulerUntilIdle()
        return .sent
    }

    /// Called by `BusMessenger` when `from` asks the agent named `toName`.
    func ask(from: AgentID, to toName: String, question: String) async -> String {
        let queued = await enqueueAsk(from: from, to: toName, question: question, parentTaskID: nil)
        guard let taskID = queued.taskID else { return queued.message }
        return await awaitSchedulerResult(taskID) ?? queued.message
    }

    func enqueueAsk(from: AgentID, to toName: String, question: String, parentTaskID: TaskID?) async -> (taskID: TaskID?, message: String) {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else {
            try? await log.append(.error(ErrorPayload(code: "agent_self_call",
                                                       message: "agent cannot ask itself")))
            return (nil, "error: agent cannot ask itself")
        }
        guard to != Self.automaticPermissionReviewerID else {
            return (nil, "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review")
        }
        guard registry.agent(to) != nil else { return (nil, "no such agent: \(toName)") }
        guard let forwardedQuestion = await bus.deliver(from: from, to: to, content: question) else {
            return (nil, "your message was blocked by the mediator")
        }
        let queued = await enqueueDelegatedTask(
            from: from,
            to: to.rawValue,
            objective: forwardedQuestion,
            roleHint: nil,
            expectedDeliverable: nil,
            parentTaskID: parentTaskID)
        if let taskID = queued.taskID {
            scheduledReplyTargets[taskID] = from
        }
        return queued
    }

    func sendMessage(from: AgentID, to toName: String, content: String, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot message itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        guard await bus.sendMessage(from: from, to: to, content: content, taskID: taskID) != nil else {
            return "your message was blocked by the mediator"
        }
        return "sent message to @\(to.rawValue)"
    }

    func requestInformation(from: AgentID, to toName: String, question: String, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot request information from itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        guard await bus.requestInformation(from: from, to: to, question: question, taskID: taskID) != nil else {
            return "your information request was blocked by the mediator"
        }
        return "requested information from @\(to.rawValue)"
    }

    func replyMessage(from: AgentID, to toName: String, content: String, inReplyTo: String?, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot reply to itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        let replyID = inReplyTo.map { MessageID(rawValue: $0) }
        guard await bus.replyMessage(from: from, to: to, content: content, inReplyTo: replyID, taskID: taskID) != nil else {
            return "your reply was blocked by the mediator"
        }
        return "replied to @\(to.rawValue)"
    }

    func requestDelegation(from: AgentID, objective: String, reason: String, parentTaskID: TaskID? = nil) async -> String {
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await log.append(.delegationRequested(DelegationRequestedPayload(
            requester: from,
            objective: trimmedObjective.isEmpty ? "Additional help requested." : trimmedObjective,
            reason: trimmedReason.isEmpty ? "No reason supplied." : trimmedReason,
            parentTaskID: parentTaskID,
            metadata: CoworkEventMetadata(
                taskID: parentTaskID,
                parentTaskID: parentTaskID,
                sender: from,
                agentID: from,
                scope: .task,
                visibility: .task))))
        return "delegation request recorded"
    }

    func createRootTask(assignee: AgentID,
                        objective: String,
                        roleHint: String = "root task coordinator",
                        expectedDeliverable: String = "Coordinate assigned subtasks and synthesize the result.") async -> TaskID? {
        guard assignee != Self.automaticPermissionReviewerID else { return nil }
        guard let agent = registry.agent(assignee) else { return nil }
        let workspaceLeaseID = defaultWorkspaceLeaseIDs[agent.name]
        let workspaceID = workspaceLeaseID.flatMap { workspaceLeases[$0]?.workspaceID }
        let contract = TaskContract(
            kind: .root,
            issuer: nil,
            assignee: agent.name,
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Coordinate the cowork task.",
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            workspaceID: workspaceID,
            workspaceLeaseID: workspaceLeaseID,
            capabilityLeaseID: defaultCapabilityLeaseIDs[agent.name],
            relatedAgents: agentVisibleNames(excluding: agent.name))
        switch taskGraph.addRootTask(contract) {
        case .success:
            let metadata = taskMetadata(
                contract: contract,
                rootTaskID: contract.id,
                parentTaskID: nil,
                sender: contract.issuer,
                recipient: contract.assignee)
            try? await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
            try? await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
            taskGraph.updateStatus(taskID: contract.id, status: .assigned)
            return contract.id
        case .failure(let violation):
            try? await log.append(.error(ErrorPayload(
                code: "task_graph_rejected",
                message: violation.message)))
            try? await log.append(.taskRejected(TaskRejectedPayload(
                contract: contract,
                requester: contract.issuer,
                assignee: contract.assignee,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(contract: contract, rootTaskID: contract.id))))
            return nil
        }
    }

    func delegateTask(from: AgentID,
                      to toName: String,
                      objective: String,
                      roleHint: String? = nil,
                      expectedDeliverable: String? = nil,
                      parentTaskID: TaskID? = nil) async -> String {
        let queued = await enqueueDelegatedTask(
            from: from,
            to: toName,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: parentTaskID)
        guard let taskID = queued.taskID else { return queued.message }
        return await awaitSchedulerResult(taskID) ?? queued.message
    }

    func enqueueDelegatedTask(from: AgentID,
                              to toName: String,
                              objective: String,
                              roleHint: String? = nil,
                              expectedDeliverable: String? = nil,
                              parentTaskID: TaskID? = nil) async -> (taskID: TaskID?, message: String) {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != Self.automaticPermissionReviewerID else {
            return (nil, "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review")
        }
        guard let toAgent = registry.agent(to) else { return (nil, "no such agent: \(toName)") }

        let prepared = prepareDelegatedTask(
            issuer: from,
            assignee: toAgent,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: parentTaskID)
        let contract = prepared.contract

        let admission: TaskGraphAdmission
        switch taskGraph.addTask(contract) {
        case .success(let accepted):
            admission = accepted
        case .failure(let violation):
            try? await log.append(.error(ErrorPayload(
                code: "task_graph_rejected",
                message: violation.message)))
            try? await log.append(.delegationRejected(DelegationRejectedPayload(
                requester: from,
                assignee: toAgent.name,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(
                    contract: contract,
                    rootTaskID: parentTaskID ?? contract.id,
                    parentTaskID: parentTaskID,
                    sender: from,
                    recipient: toAgent.name))))
            try? await log.append(.taskRejected(TaskRejectedPayload(
                contract: contract,
                requester: from,
                assignee: toAgent.name,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(
                    contract: contract,
                    rootTaskID: parentTaskID ?? contract.id,
                    parentTaskID: parentTaskID,
                    sender: from,
                    recipient: toAgent.name))))
            return (nil, Self.delegationRejectionMessage(for: violation))
        }

        capabilityLeases[prepared.capabilityLease.id] = prepared.capabilityLease
        workspaceLeases[prepared.workspaceLease.id] = prepared.workspaceLease
        let metadata = taskMetadata(
            contract: contract,
            rootTaskID: admission.rootTaskID,
            parentTaskID: parentTaskID,
            sender: from,
            recipient: toAgent.name)
        try? await log.append(.delegationApproved(DelegationApprovedPayload(
            contract: contract,
            metadata: metadata)))
        try? await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: toAgent.name,
            lease: prepared.capabilityLease,
            metadata: metadata)))
        try? await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: toAgent.name,
            lease: prepared.workspaceLease,
            metadata: metadata)))
        try? await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try? await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try? await log.append(.taskDelegated(TaskDelegatedPayload(contract: contract, metadata: metadata)))
        taskGraph.updateStatus(taskID: contract.id, status: .assigned)

        let scheduled = ScheduledTask(
            contract: contract,
            input: contract.objective,
            rootTaskID: admission.rootTaskID,
            parentTaskID: parentTaskID,
            issuer: from,
            assignee: toAgent.name,
            causalParentID: parentTaskID,
            hopCount: admission.hopCount,
            visitedAgents: admission.visitedAgents)
        scheduler.enqueue(scheduled)
        taskGraph.updateStatus(taskID: contract.id, status: .queued)
        try? await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: scheduled.rootTaskID,
            parentTaskID: scheduled.parentTaskID,
            issuer: scheduled.issuer,
            assignee: scheduled.assignee,
            causalParentID: scheduled.causalParentID,
            hopCount: scheduled.hopCount,
            visitedAgents: scheduled.visitedAgents,
            metadata: metadata)))
        return (contract.id, "task queued: \(contract.id.rawValue)")
    }

    // MARK: - Coordinator tools (a lead agent spawns / lists / removes sub-agents)

    /// Create and attach a new sub-agent bound to `path`. Returns a status line
    /// the calling (coordinator) agent can read back.
    func spawnFromTool(name: String, path: String, model: String, canCoordinate: Bool = false) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "error: an agent name is required" }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "error: not a folder: \(url.path)"
        }
        let id = AgentID(rawValue: trimmed)
        guard id != Self.automaticPermissionReviewerID else {
            return "error: @\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        if registry.agent(id) != nil { return "error: an agent named @\(trimmed) already exists" }
        try? await log.append(.agentSpawnRequested(AgentSpawnRequestedPayload(
            agent: id,
            path: url.path,
            model: ModelID(rawValue: model),
            metadata: CoworkEventMetadata(agentID: id, scope: .agent))))
        let coordinationDepth = canCoordinate ? Agent.defaultCoordinationDepth : 0
        let attached = await attach(Agent(name: id, workspaceRoot: url,
                                          model: ModelID(rawValue: model), profile: .reviewed,
                                          coordinationDepth: coordinationDepth))
        if attached {
            try? await log.append(.agentSpawned(AgentSpawnedPayload(
                agent: id,
                path: url.path,
                model: ModelID(rawValue: model),
                metadata: CoworkEventMetadata(agentID: id, scope: .agent))))
        }
        return attached
            ? "spawned @\(trimmed) · model \(model) · \(canCoordinate ? "coordinator" : "worker") · \(url.path)"
            : "permission denied: workspace attach for @\(trimmed)"
    }

    /// One line per active agent, for the coordinator to read.
    func listForTool() -> String {
        let all = registry.all().filter { $0.name != Self.automaticPermissionReviewerID }
        guard !all.isEmpty else { return "(no agents)" }
        return all.map { "@\($0.name.rawValue) · \($0.model.rawValue) · \($0.workspaceRoot.path)" }
            .joined(separator: "\n")
    }

    /// Detach a sub-agent. `@main` is protected so the user always keeps a coordinator.
    func removeFromTool(name: String) async -> String {
        let id = AgentID(rawValue: name)
        guard registry.agent(id) != nil else { return "error: no agent named @\(name)" }
        if name == "main" { return "error: cannot remove @main" }
        if id == Self.automaticPermissionReviewerID {
            return "error: @\(Self.automaticPermissionReviewerID.rawValue) is controlled by /default"
        }
        await detach(id)
        return "removed @\(name)"
    }

    private func run(_ agent: Agent,
                     input: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil,
                     taskContract: TaskContract? = nil) async throws -> String {
        let provider = try await providerFor(agent)
        let messenger = BusMessenger(from: agent.name, currentTaskID: taskContract?.id, orchestrator: self)
        let manager = OrchestratorManager(orchestrator: self, defaultModel: agent.model.rawValue)
        let capabilityLease = capabilityLease(for: agent, taskContract: taskContract)
        let toolRegistry = Self.toolRegistry(for: capabilityLease)
        let allowedToolNames = toolRegistry.descriptors().map(\.name).sorted()
        let canCoordinate = Self.canCoordinate(capabilityLease)
        // Give the agent a prompt that matches its current task lease. A numeric
        // depth may still exist on old agents, but the lease decides tool exposure.
        let systemPrompt = ContextBuilder.coworkSystemPrompt(
            name: agent.name.rawValue, folder: agent.workspaceRoot.path,
            coordinationDepth: agent.coordinationDepth,
            canCoordinate: canCoordinate)
        let contextBundle = ContextProjector().project(
            agentID: agent.name,
            taskContract: taskContract,
            events: await log.replay(),
            allowedToolNames: allowedToolNames,
            workspaceRoot: agent.workspaceRoot)
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: toolRegistry,
            engine: engine,
            responder: activePermissionResponder(),
            agent: agent,
            context: ContextBuilder(systemPrompt: systemPrompt,
                                    taskContract: taskContract,
                                    contextBundle: contextBundle),
            allowsShell: allowsShell,
            messenger: messenger,
            agentManager: manager,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxSteps
        )
        return try await loop.send(input, images: images, userMessage: userMessage)
    }

    private static func normalizedAgentName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private func reverseLeaseAgents<ID: Hashable>(_ leaseAgents: [ID: AgentID]) -> [AgentID: ID] {
        var result: [AgentID: ID] = [:]
        for (leaseID, agent) in leaseAgents where result[agent] == nil {
            guard agent != Self.automaticPermissionReviewerID else { continue }
            result[agent] = leaseID
        }
        return result
    }

    private func activePermissionResponder() -> PermissionResponder {
        automaticPermissionResponder ?? responder
    }

    private func agentVisibleNames(excluding excluded: AgentID) -> [AgentID] {
        registry.names.filter {
            $0 != excluded && $0 != Self.automaticPermissionReviewerID
        }
    }

    private func prepareDelegatedTask(issuer: AgentID,
                                      assignee: Agent,
                                      objective: String,
                                      roleHint: String? = nil,
                                      expectedDeliverable: String? = nil,
                                      parentTaskID: TaskID? = nil) -> PreparedDelegatedTask {
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let relatedAgents = agentVisibleNames(excluding: assignee.name)
        let taskID = TaskID.new()
        let capabilityLease = CapabilityLease.worker(taskID: taskID)
        let workspaceLease = workspaceLeaseForTask(agent: assignee, access: .readOnly, store: false)
        let contract = TaskContract(
            id: taskID,
            issuer: issuer,
            assignee: assignee.name,
            parentTaskID: parentTaskID,
            objective: trimmedObjective.isEmpty ? "Answer the assigned task." : trimmedObjective,
            roleHint: roleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? Self.defaultRoleHint(for: assignee.name, objective: trimmedObjective),
            expectedDeliverable: expectedDeliverable?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Answer the assigned task clearly and concisely.",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            relatedAgents: relatedAgents,
            relatedTasks: [],
            constraints: Self.defaultWorkerConstraints)
        return PreparedDelegatedTask(
            contract: contract,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
    }

    @discardableResult
    private func createDefaultLeases(for agent: Agent) -> (capability: CapabilityLease, workspace: WorkspaceLease) {
        let workspaceLease = WorkspaceLease(rootPath: agent.workspaceRoot.path, access: .readWrite)
        workspaceLeases[workspaceLease.id] = workspaceLease
        defaultWorkspaceLeaseIDs[agent.name] = workspaceLease.id

        let capabilityLease: CapabilityLease = agent.coordinationDepth > 0
            ? .coordinator()
            : .worker()
        capabilityLeases[capabilityLease.id] = capabilityLease
        defaultCapabilityLeaseIDs[agent.name] = capabilityLease.id
        return (capabilityLease, workspaceLease)
    }

    private func workspaceLeaseForTask(agent: Agent, access: WorkspaceAccess, store: Bool = true) -> WorkspaceLease {
        if let leaseID = defaultWorkspaceLeaseIDs[agent.name],
           let defaultLease = workspaceLeases[leaseID] {
            let taskLease = WorkspaceLease(
                workspaceID: defaultLease.workspaceID,
                rootPath: defaultLease.rootPath,
                access: access,
                allowedPathRules: defaultLease.allowedPathRules,
                deniedPatterns: defaultLease.deniedPatterns)
            if store {
                workspaceLeases[taskLease.id] = taskLease
            }
            return taskLease
        }

        let taskLease = WorkspaceLease(rootPath: agent.workspaceRoot.path, access: access)
        if store {
            workspaceLeases[taskLease.id] = taskLease
        }
        return taskLease
    }

    private func capabilityLease(for agent: Agent, taskContract: TaskContract?) -> CapabilityLease {
        if let leaseID = taskContract?.capabilityLeaseID,
           let lease = capabilityLeases[leaseID] {
            return lease
        }
        if let leaseID = defaultCapabilityLeaseIDs[agent.name],
           let lease = capabilityLeases[leaseID] {
            return lease
        }
        let lease = CapabilityLease.worker()
        capabilityLeases[lease.id] = lease
        defaultCapabilityLeaseIDs[agent.name] = lease.id
        return lease
    }

    private func taskMetadata(contract: TaskContract,
                              rootTaskID: TaskID? = nil,
                              parentTaskID: TaskID? = nil,
                              sender: AgentID? = nil,
                              recipient: AgentID? = nil,
                              scope: CoworkEventScope = .task,
                              visibility: CoworkEventVisibility = .task) -> CoworkEventMetadata {
        CoworkEventMetadata(
            taskID: contract.id,
            rootTaskID: rootTaskID,
            parentTaskID: parentTaskID ?? contract.parentTaskID,
            sender: sender,
            recipient: recipient,
            agentID: contract.assignee,
            issuer: contract.issuer,
            assignee: contract.assignee,
            workspaceID: contract.workspaceID,
            workspaceLeaseID: contract.workspaceLeaseID,
            capabilityLeaseID: contract.capabilityLeaseID,
            causalParentID: parentTaskID ?? contract.parentTaskID,
            scope: scope,
            visibility: visibility)
    }

    @discardableResult
    func runNextScheduledTask() async -> Bool {
        guard let task = scheduler.runNext() else { return false }
        scheduler.recordStarted(task: task)
        taskGraph.updateStatus(taskID: task.contract.id, status: .running)
        let metadata = taskMetadata(
            contract: task.contract,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            sender: task.issuer,
            recipient: task.assignee)
        try? await log.append(.taskStarted(TaskStartedPayload(
            taskID: task.contract.id,
            agent: task.assignee,
            metadata: metadata)))

        guard let agent = registry.agent(task.assignee) else {
            let message = "scheduled task assignee is not attached: @\(task.assignee.rawValue)"
            scheduler.recordFailed(task: task, error: message)
            taskGraph.updateStatus(taskID: task.contract.id, status: .failed)
            try? await log.append(.taskFailed(TaskFailedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                error: message,
                metadata: metadata)))
            return true
        }

        do {
            let result = try await run(agent, input: task.input, taskContract: task.contract)
            scheduler.recordCompleted(task: task, result: result)
            taskGraph.updateStatus(taskID: task.contract.id, status: .completed)
            try? await log.append(.taskCompleted(TaskCompletedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                result: result,
                metadata: metadata)))
            if let replyTarget = scheduledReplyTargets.removeValue(forKey: task.contract.id) {
                _ = await bus.deliver(from: task.assignee, to: replyTarget, content: result)
            }
        } catch {
            let message = error.localizedDescription
            scheduledReplyTargets.removeValue(forKey: task.contract.id)
            scheduler.recordFailed(task: task, error: message)
            taskGraph.updateStatus(taskID: task.contract.id, status: .failed)
            try? await log.append(.taskFailed(TaskFailedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                error: message,
                metadata: metadata)))
        }
        return true
    }

    func runSchedulerUntilIdle() async {
        while await runNextScheduledTask() {}
    }

    func awaitSchedulerResult(_ taskID: TaskID) async -> String? {
        while true {
            if let record = scheduler.record(for: taskID) {
                switch record.status {
                case .completed:
                    return record.result
                case .failed:
                    return record.error.map { "error: \($0)" }
                case .created, .assigned, .queued, .running, .cancelled:
                    break
                }
            }
            guard await runNextScheduledTask() else {
                return scheduler.record(for: taskID)?.result
            }
        }
    }

    private func causalMetadata(issuer: AgentID,
                                assignee: AgentID,
                                parentTaskID: TaskID?) -> (rootTaskID: TaskID?, hopCount: Int, visitedAgents: [AgentID], rejected: Bool) {
        guard let parentTaskID,
              let parent = scheduler.record(for: parentTaskID) else {
            return (nil, 1, Self.uniqueAgents([issuer, assignee]), false)
        }
        if parent.visitedAgents.contains(assignee) {
            return (parent.rootTaskID ?? parentTaskID, parent.hopCount + 1, parent.visitedAgents, true)
        }
        var visited = parent.visitedAgents
        visited.append(assignee)
        return (parent.rootTaskID ?? parentTaskID, parent.hopCount + 1, Self.uniqueAgents(visited), false)
    }

    private static func uniqueAgents(_ agents: [AgentID]) -> [AgentID] {
        var seen = Set<AgentID>()
        var result: [AgentID] = []
        for agent in agents where !seen.contains(agent) {
            seen.insert(agent)
            result.append(agent)
        }
        return result
    }

    private static func delegationRejectionMessage(for violation: TaskGraphViolation) -> String {
        switch violation.kind {
        case .selfDelegation:
            return "error: agent cannot delegate to itself"
        case .cycleDetected:
            return "error: delegation cycle rejected"
        case .duplicateTask:
            return violation.existingTaskID.map { "error: duplicate task rejected: \($0.rawValue)" }
                ?? "error: duplicate task rejected"
        case .maxDepthExceeded:
            return "error: task depth limit exceeded"
        case .maxDelegationHopsExceeded:
            return "error: delegation hop limit exceeded"
        case .maxTasksPerRootExceeded:
            return "error: task limit exceeded"
        case .maxActiveAgentsExceeded:
            return "error: active agent limit exceeded"
        case .missingParentTask:
            return "error: parent task not found"
        case .duplicateTaskID:
            return "error: duplicate task id"
        }
    }

    static func toolRegistry(for lease: CapabilityLease) -> ToolRegistry {
        var tools: [any Tool] = []
        if lease.tools.contains(.readWorkspace) {
            tools.append(ReadFileTool())
        }
        if lease.tools.contains(.listWorkspace) {
            tools.append(ListFilesTool())
        }
        if lease.tools.contains(.searchWorkspace) {
            tools.append(SearchTextTool())
        }
        if lease.tools.contains(.applyPatch) {
            tools.append(WriteFileTool())
            tools.append(ApplyPatchTool())
        }
        if lease.tools.contains(.runShell) {
            tools.append(RunShellTool())
            tools.append(GitStatusTool())
            tools.append(GitDiffTool())
        }
        if lease.tools.contains(.requestInformation) || lease.tools.contains(.delegateTask) {
            tools.append(RequestInformationTool())
            tools.append(AskAgentTool())
        }
        if lease.tools.contains(.sendMessage) {
            tools.append(SendMessageTool())
        }
        if lease.tools.contains(.replyMessage) {
            tools.append(ReplyMessageTool())
        }
        if lease.tools.contains(.requestDelegation) {
            tools.append(RequestDelegationTool())
        }
        if lease.tools.contains(.delegateTask) {
            tools.append(DelegateTaskTool())
        }
        if lease.tools.contains(.delegateTask) || lease.tools.contains(.attachWorkspace) {
            tools.append(SpawnAgentTool())
        }
        if lease.tools.contains(.delegateTask) {
            tools.append(ListAgentsTool())
            tools.append(RemoveAgentTool())
        }
        return ToolRegistry(tools)
    }

    private static func canCoordinate(_ lease: CapabilityLease) -> Bool {
        lease.tools.contains(.delegateTask)
            || lease.tools.contains(.attachWorkspace)
            || lease.tools.contains(.requestInformation)
    }

    private static let defaultWorkerConstraints: [String] = [
        "Complete only the assigned task.",
        "Do not re-run the global task decomposition.",
        "Do not create, remove, or coordinate other agents.",
        "If you need help, report the need to the assigning agent or user.",
    ]

    private static func defaultRoleHint(for assignee: AgentID, objective: String) -> String {
        let name = assignee.rawValue.lowercased()
        let lowerObjective = objective.lowercased()
        if name.contains("macos"), name.contains("counter"), lowerObjective.contains("swift") {
            return "macOS Swift file counter"
        }
        if name.contains("ios"), name.contains("counter"), lowerObjective.contains("swift") {
            return "iOS Swift file counter"
        }
        let parts = assignee.rawValue
            .split { "-_ .".contains($0) }
            .map { displayRoleToken(String($0)) }
        return parts.isEmpty ? "assigned task worker" : parts.joined(separator: " ")
    }

    private static func displayRoleToken(_ token: String) -> String {
        switch token.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "swift": return "Swift"
        default: return token
        }
    }
}

private struct PreparedDelegatedTask: Sendable {
    var contract: TaskContract
    var capabilityLease: CapabilityLease
    var workspaceLease: WorkspaceLease
}

private struct WorkspaceAttachAssessment: Sendable {
    var canonical: URL?
    var canAskUser: Bool
    var risk: RiskLevel
    var reason: String
}

private func assessWorkspaceAttach(_ url: URL) -> WorkspaceAttachAssessment {
    do {
        let canonical = try PathConfinement.canonicalExistingDirectory(url)
        if isDeniedWorkspaceRoot(canonical) {
            return WorkspaceAttachAssessment(
                canonical: canonical,
                canAskUser: false,
                risk: .high,
                reason: "workspace path is too broad or system-sensitive: \(canonical.path)")
        }
        return WorkspaceAttachAssessment(
            canonical: canonical,
            canAskUser: true,
            risk: .medium,
            reason: "attach new agent workspace: \(canonical.path)")
    } catch {
        return WorkspaceAttachAssessment(
            canonical: nil,
            canAskUser: false,
            risk: .high,
            reason: error.localizedDescription)
    }
}

private func isDeniedWorkspaceRoot(_ url: URL) -> Bool {
    let path = url.path
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
    if path == "/" || path == "/Users" || path == "/var" || path == "/private/var" || path == home {
        return true
    }
    let deniedPrefixes = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/private/etc",
        "/var/db", "/var/root", "/private/var/db", "/private/var/root",
        home + "/.ssh", home + "/Library/Keychains",
    ]
    return deniedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
}

private func attachArgs(agent: Agent, canonicalPath: String) -> String {
    let object: [String: String] = [
        "agent": agent.name.rawValue,
        "path": canonicalPath,
        "model": agent.model.rawValue,
        "profile": agent.profile.rawValue,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// Per-agent messenger handed to each agent's loop; binds `from` and routes
/// through the orchestrator (and thus the mediated bus).
struct BusMessenger: AgentMessenger {
    let from: AgentID
    let currentTaskID: TaskID?
    let orchestrator: Orchestrator

    func ask(to agent: String, question: String) async -> String {
        await orchestrator.enqueueAsk(from: from, to: agent, question: question, parentTaskID: currentTaskID).message
    }

    func sendMessage(to agent: String, content: String) async -> String {
        await orchestrator.sendMessage(from: from, to: agent, content: content, taskID: currentTaskID)
    }

    func requestInformation(to agent: String, question: String) async -> String {
        await orchestrator.requestInformation(from: from, to: agent, question: question, taskID: currentTaskID)
    }

    func replyMessage(to agent: String, content: String, inReplyTo: String?) async -> String {
        await orchestrator.replyMessage(from: from, to: agent, content: content, inReplyTo: inReplyTo, taskID: currentTaskID)
    }

    func requestDelegation(objective: String, reason: String) async -> String {
        await orchestrator.requestDelegation(from: from, objective: objective, reason: reason, parentTaskID: currentTaskID)
    }

    func delegateTask(to agent: String,
                      objective: String,
                      roleHint: String?,
                      expectedDeliverable: String?) async -> String {
        await orchestrator.enqueueDelegatedTask(
            from: from,
            to: agent,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: currentTaskID).message
    }
}

/// Coordinator seam handed to each agent's loop; routes lifecycle calls through
/// the orchestrator actor (and thus its registry + event log). `defaultModel` is
/// the spawning agent's model, used when the tool call omits one.
struct OrchestratorManager: AgentManager {
    let orchestrator: Orchestrator
    let defaultModel: String

    func spawnAgent(name: String, path: String, model: String?, canCoordinate: Bool) async -> String {
        await orchestrator.spawnFromTool(
            name: name,
            path: path,
            model: model ?? defaultModel,
            canCoordinate: canCoordinate)
    }
    func listAgents() async -> String { await orchestrator.listForTool() }
    func removeAgent(name: String) async -> String { await orchestrator.removeFromTool(name: name) }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
