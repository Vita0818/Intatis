import Foundation
import IntatisCore
import IntatisProtocol

public struct CoworkTaskView: Codable, Equatable, Sendable, Identifiable {
    public var id: TaskID
    public var contract: TaskContract?
    public var status: TaskStatus
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var issuer: AgentID?
    public var assignee: AgentID?
    public var result: String?
    public var error: String?
    public var report: TaskReportPayload?

    public init(id: TaskID,
                contract: TaskContract? = nil,
                status: TaskStatus,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID? = nil,
                result: String? = nil,
                error: String? = nil,
                report: TaskReportPayload? = nil) {
        self.id = id
        self.contract = contract
        self.status = status
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.result = result
        self.error = error
        self.report = report
    }
}

public struct CoworkMailboxView: Codable, Equatable, Sendable {
    public var pendingMessages: [MessageID]
    public var pendingTasks: [TaskID]
    public var completedTasks: [TaskID]

    public init(pendingMessages: [MessageID] = [],
                pendingTasks: [TaskID] = [],
                completedTasks: [TaskID] = []) {
        self.pendingMessages = pendingMessages
        self.pendingTasks = pendingTasks
        self.completedTasks = completedTasks
    }
}

public struct CoworkProjection: Equatable, Sendable {
    public private(set) var tasks: [TaskID: CoworkTaskView] = [:]
    public private(set) var agentRoster: [AgentID: AgentAttachedPayload] = [:]
    public private(set) var mailboxes: [AgentID: CoworkMailboxView] = [:]
    public private(set) var pendingDelegations: [RequestID: DelegationRequestedPayload] = [:]
    public private(set) var rejectedDelegations: [DelegationRejectedPayload] = []
    public private(set) var workspaceLeases: [WorkspaceLeaseID: WorkspaceLease] = [:]
    public private(set) var capabilityLeases: [CapabilityLeaseID: CapabilityLease] = [:]
    public private(set) var workspaceLeaseAgents: [WorkspaceLeaseID: AgentID] = [:]
    public private(set) var capabilityLeaseAgents: [CapabilityLeaseID: AgentID] = [:]
    public private(set) var agentMessages: [AgentMessagePayload] = []
    public private(set) var agentStatuses: [AgentID: AgentState] = [:]
    public private(set) var agentOwners: [AgentID: AgentID] = [:]

    public init() {}

    public var activeTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .created || $0.status == .assigned || $0.status == .queued || $0.status == .running }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var queuedTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .queued }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var runningTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .running }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var completedTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .completed }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var failedTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .failed }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .agentAttached(let payload):
            agentRoster[payload.agent] = payload
        case .agentSpawned(let payload):
            agentRoster[payload.agent] = AgentAttachedPayload(
                agent: payload.agent,
                path: payload.path,
                model: payload.model,
                profile: "reviewed",
                metadata: payload.metadata)
            if let requestedBy = payload.requestedBy ?? payload.metadata?.sender {
                agentOwners[payload.agent] = requestedBy
            }
        case .agentDetached(let payload):
            agentRoster.removeValue(forKey: payload.agent)
            agentStatuses.removeValue(forKey: payload.agent)
            agentOwners.removeValue(forKey: payload.agent)
        case .agentStatus(let payload):
            if let agent = payload.agent {
                agentStatuses[agent] = payload.state
            }
        case .agentMessage(let payload):
            agentMessages.append(payload)
            if let to = payload.to {
                mailboxes[to, default: CoworkMailboxView()].pendingMessages.append(payload.messageId)
            }
        case .informationRequested(let payload):
            mailboxes[payload.to, default: CoworkMailboxView()].pendingMessages.append(payload.requestID)
        case .informationReplied(let payload):
            mailboxes[payload.to, default: CoworkMailboxView()].pendingMessages.append(payload.replyID)
        case .delegationRequested(let payload):
            pendingDelegations[payload.requestID] = payload
        case .delegationApproved(let payload):
            if let requestID = payload.requestID {
                pendingDelegations.removeValue(forKey: requestID)
            }
            upsertTask(payload.contract, status: .assigned)
        case .delegationRejected(let payload):
            if let requestID = payload.requestID {
                pendingDelegations.removeValue(forKey: requestID)
            }
            rejectedDelegations.append(payload)
        case .taskCreated(let payload):
            upsertTask(payload.contract, status: .created)
        case .taskAssigned(let payload):
            upsertTask(payload.contract, status: .assigned)
        case .taskDelegated(let payload):
            upsertTask(payload.contract, status: tasks[payload.contract.id]?.status ?? .assigned)
        case .taskQueued(let payload):
            upsertTask(payload.contract, status: .queued,
                       rootTaskID: payload.rootTaskID,
                       parentTaskID: payload.parentTaskID,
                       issuer: payload.issuer,
                       assignee: payload.assignee)
            mailboxes[payload.assignee, default: CoworkMailboxView()].pendingTasks.append(payload.contract.id)
        case .taskStarted(let payload):
            updateTask(payload.taskID, status: .running, assignee: payload.agent)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskCompleted(let payload):
            updateTask(payload.taskID, status: .completed, assignee: payload.agent, result: payload.result, report: payload.report)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
            mailboxes[payload.agent, default: CoworkMailboxView()].completedTasks.append(payload.taskID)
        case .taskFailed(let payload):
            updateTask(payload.taskID, status: .failed, assignee: payload.agent, error: payload.error, report: payload.report)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskRejected(let payload):
            if let contract = payload.contract {
                upsertTask(contract, status: .failed,
                           rootTaskID: payload.metadata?.rootTaskID,
                           parentTaskID: payload.metadata?.parentTaskID,
                           issuer: payload.metadata?.issuer,
                           assignee: payload.assignee,
                           error: payload.reason)
            }
        case .workspaceLeaseGranted(let payload):
            workspaceLeases[payload.lease.id] = payload.lease
            if let agent = payload.agent {
                workspaceLeaseAgents[payload.lease.id] = agent
            }
        case .capabilityLeaseCreated(let payload):
            capabilityLeases[payload.lease.id] = payload.lease
            if let agent = payload.agent {
                capabilityLeaseAgents[payload.lease.id] = agent
            }
        case .capabilityLeaseRevoked(let payload):
            capabilityLeases.removeValue(forKey: payload.leaseID)
            capabilityLeaseAgents.removeValue(forKey: payload.leaseID)
        case .userMessage, .messageDelta, .messageCompleted, .error,
             .toolCall, .toolResult, .permissionRequest, .permissionResolved,
             .patchProposed, .agentAttachRequested,
             .agentSpawnRequested, .agentToAgentMessage, .workspaceLeaseRequested,
             .workspaceLeaseDenied, .permissionReview, .artifactAdded,
             .artifactProgress, .turnStats:
            break
        }
    }

    public static func build(from envelopes: [Envelope]) -> CoworkProjection {
        var projection = CoworkProjection()
        for envelope in envelopes {
            projection.apply(envelope)
        }
        return projection
    }

    private mutating func upsertTask(_ contract: TaskContract,
                                     status: TaskStatus,
                                     rootTaskID: TaskID? = nil,
                                     parentTaskID: TaskID? = nil,
                                     issuer: AgentID? = nil,
                                     assignee: AgentID? = nil,
                                     result: String? = nil,
                                     error: String? = nil,
                                     report: TaskReportPayload? = nil) {
        var view = tasks[contract.id] ?? CoworkTaskView(
            id: contract.id,
            contract: contract,
            status: status,
            rootTaskID: rootTaskID,
            parentTaskID: parentTaskID ?? contract.parentTaskID,
            issuer: issuer ?? contract.issuer,
            assignee: assignee ?? contract.assignee)
        view.contract = contract
        view.status = status
        view.rootTaskID = rootTaskID ?? view.rootTaskID
        view.parentTaskID = parentTaskID ?? view.parentTaskID ?? contract.parentTaskID
        view.issuer = issuer ?? view.issuer ?? contract.issuer
        view.assignee = assignee ?? view.assignee ?? contract.assignee
        view.result = result ?? view.result
        view.error = error ?? view.error
        view.report = report ?? view.report
        tasks[contract.id] = view
    }

    private mutating func updateTask(_ taskID: TaskID,
                                     status: TaskStatus,
                                     assignee: AgentID? = nil,
                                     result: String? = nil,
                                     error: String? = nil,
                                     report: TaskReportPayload? = nil) {
        var view = tasks[taskID] ?? CoworkTaskView(id: taskID, status: status, assignee: assignee)
        view.status = status
        view.assignee = assignee ?? view.assignee
        view.result = result ?? view.result
        view.error = error ?? view.error
        view.report = report ?? view.report
        tasks[taskID] = view
    }
}
