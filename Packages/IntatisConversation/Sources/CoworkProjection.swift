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
    public var attempt: Int
    public var statusReason: String?

    public init(id: TaskID,
                contract: TaskContract? = nil,
                status: TaskStatus,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID? = nil,
                result: String? = nil,
                error: String? = nil,
                report: TaskReportPayload? = nil,
                attempt: Int = 0,
                statusReason: String? = nil) {
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
        self.attempt = attempt
        self.statusReason = statusReason
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

/// Durable prepare/settle fold used by crash recovery. `settled == nil` means
/// the log cannot prove whether the executor completed before interruption.
public struct CoworkToolExecutionView: Identifiable, Equatable, Sendable {
    public var id: String { prepared.executionID }
    public var prepared: ToolExecutionPreparedPayload
    public var preparedSeq: Int
    public var settled: ToolExecutionSettledPayload?
    public var settledSeq: Int?

    public init(prepared: ToolExecutionPreparedPayload,
                preparedSeq: Int,
                settled: ToolExecutionSettledPayload? = nil,
                settledSeq: Int? = nil) {
        self.prepared = prepared
        self.preparedSeq = preparedSeq
        self.settled = settled
        self.settledSeq = settledSeq
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
    public private(set) var toolExecutions: [String: CoworkToolExecutionView] = [:]

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

    public var cancelledTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .cancelled }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var unresolvedToolExecutions: [CoworkToolExecutionView] {
        toolExecutions.values
            .filter { $0.settled == nil }
            .sorted {
                if $0.preparedSeq == $1.preparedSeq { return $0.id < $1.id }
                return $0.preparedSeq < $1.preparedSeq
            }
    }

    public var unresolvedNonReplayableToolExecutions: [CoworkToolExecutionView] {
        unresolvedToolExecutions.filter {
            $0.prepared.requiresTaskReplayReconciliation
        }
    }

    /// Every non-replayable executor boundary that was reached, including
    /// calls whose settled record says `succeeded`. A settled success proves
    /// the side effect happened; it does not make replaying the enclosing task
    /// safe because the task starts again from its first model/tool step.
    public var startedNonReplayableToolExecutions: [CoworkToolExecutionView] {
        toolExecutions.values
            .filter { $0.prepared.requiresTaskReplayReconciliation }
            .sorted {
                if $0.preparedSeq == $1.preparedSeq { return $0.id < $1.id }
                return $0.preparedSeq < $1.preparedSeq
            }
    }

    public func startedNonReplayableToolExecutions(taskID: TaskID,
                                                    attempt: Int) -> [CoworkToolExecutionView] {
        startedNonReplayableToolExecutions.filter { execution in
            execution.prepared.taskID == taskID
                && (execution.prepared.attempt == nil || execution.prepared.attempt == attempt)
        }
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
                var mailbox = mailboxes[to, default: CoworkMailboxView()]
                Self.appendUnique(payload.messageId, to: &mailbox.pendingMessages)
                mailboxes[to] = mailbox
            }
        case .agentMessageConsumed(let payload):
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingMessages.removeAll { $0 == payload.messageID }
        case .informationRequested(let payload):
            var mailbox = mailboxes[payload.to, default: CoworkMailboxView()]
            Self.appendUnique(payload.requestID, to: &mailbox.pendingMessages)
            mailboxes[payload.to] = mailbox
        case .informationReplied(let payload):
            var mailbox = mailboxes[payload.to, default: CoworkMailboxView()]
            Self.appendUnique(payload.replyID, to: &mailbox.pendingMessages)
            mailboxes[payload.to] = mailbox
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
                       assignee: payload.assignee,
                       attempt: payload.attempt,
                       statusReason: payload.reason,
                       clearOutcome: true)
            var mailbox = mailboxes[payload.assignee, default: CoworkMailboxView()]
            Self.appendUnique(payload.contract.id, to: &mailbox.pendingTasks)
            mailboxes[payload.assignee] = mailbox
        case .taskStarted(let payload):
            updateTask(payload.taskID, status: .running, assignee: payload.agent, attempt: payload.attempt)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskCompleted(let payload):
            updateTask(payload.taskID, status: .completed, assignee: payload.agent,
                       result: payload.result, report: payload.report, attempt: payload.attempt)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
            var mailbox = mailboxes[payload.agent, default: CoworkMailboxView()]
            Self.appendUnique(payload.taskID, to: &mailbox.completedTasks)
            mailboxes[payload.agent] = mailbox
        case .taskFailed(let payload):
            updateTask(payload.taskID, status: .failed, assignee: payload.agent,
                       error: payload.error, report: payload.report, attempt: payload.attempt,
                       statusReason: payload.error)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskCancelled(let payload):
            updateTask(payload.taskID, status: .cancelled, assignee: payload.agent,
                       error: payload.reason, report: payload.report, attempt: payload.attempt,
                       statusReason: payload.reason)
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
        case .workspaceLeaseRevoked(let payload):
            workspaceLeases.removeValue(forKey: payload.leaseID)
            workspaceLeaseAgents.removeValue(forKey: payload.leaseID)
        case .capabilityLeaseCreated(let payload):
            capabilityLeases[payload.lease.id] = payload.lease
            if let agent = payload.agent {
                capabilityLeaseAgents[payload.lease.id] = agent
            }
        case .capabilityLeaseRevoked(let payload):
            capabilityLeases.removeValue(forKey: payload.leaseID)
            capabilityLeaseAgents.removeValue(forKey: payload.leaseID)
        case .toolExecutionPrepared(let payload):
            if var existing = toolExecutions[payload.executionID] {
                existing.prepared = payload
                existing.preparedSeq = envelope.seq
                toolExecutions[payload.executionID] = existing
            } else {
                toolExecutions[payload.executionID] = CoworkToolExecutionView(
                    prepared: payload,
                    preparedSeq: envelope.seq)
            }
        case .toolExecutionSettled(let payload):
            var execution = toolExecutions[payload.executionID]
                ?? CoworkToolExecutionView(
                    prepared: payload.prepared,
                    preparedSeq: envelope.seq)
            execution.settled = payload
            execution.settledSeq = envelope.seq
            toolExecutions[payload.executionID] = execution
        case .userMessage, .messageDelta, .messageCompleted, .error,
             .toolCall, .toolResult, .permissionRequest, .permissionResolved,
             .patchProposed, .agentAttachRequested,
             .agentSpawnRequested, .agentToAgentMessage, .workspaceLeaseRequested,
             .workspaceLeaseDenied, .permissionReview, .permissionReviewRequested,
             .permissionReviewSettled, .artifactAdded,
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
                                     report: TaskReportPayload? = nil,
                                     attempt: Int? = nil,
                                     statusReason: String? = nil,
                                     clearOutcome: Bool = false) {
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
        if clearOutcome {
            view.result = nil
            view.error = nil
            view.report = nil
        } else {
            view.result = result ?? view.result
            view.error = error ?? view.error
            view.report = report ?? view.report
        }
        view.attempt = attempt ?? view.attempt
        view.statusReason = statusReason ?? (clearOutcome ? nil : view.statusReason)
        tasks[contract.id] = view
    }

    private mutating func updateTask(_ taskID: TaskID,
                                     status: TaskStatus,
                                     assignee: AgentID? = nil,
                                     result: String? = nil,
                                     error: String? = nil,
                                     report: TaskReportPayload? = nil,
                                     attempt: Int? = nil,
                                     statusReason: String? = nil) {
        var view = tasks[taskID] ?? CoworkTaskView(id: taskID, status: status, assignee: assignee)
        view.status = status
        view.assignee = assignee ?? view.assignee
        view.result = result ?? view.result
        view.error = error ?? view.error
        view.report = report ?? view.report
        view.attempt = attempt ?? view.attempt
        view.statusReason = statusReason ?? view.statusReason
        tasks[taskID] = view
    }

    private static func appendUnique<T: Equatable>(_ value: T, to values: inout [T]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}
