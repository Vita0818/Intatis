import Foundation
import IntatisCore

/// Who produced a message.
public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case agent
    case system
}

// MARK: - Event payloads (v0.1 chat scope)

public struct UserMessagePayload: Codable, Equatable, Sendable {
    public var text: String
    public var attachments: [ArtifactID]?
    public var to: AgentID?
    public var tags: [String]?
    public var goal: String?
    public init(text: String,
                attachments: [ArtifactID]? = nil,
                to: AgentID? = nil,
                tags: [String]? = nil,
                goal: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.to = to
        self.tags = tags
        self.goal = goal
    }
}

public struct MessageDeltaPayload: Codable, Equatable, Sendable {
    public var messageId: MessageID
    public var role: MessageRole
    public var agent: AgentID?
    public var textDelta: String
    public init(messageId: MessageID, role: MessageRole, agent: AgentID? = nil, textDelta: String) {
        self.messageId = messageId
        self.role = role
        self.agent = agent
        self.textDelta = textDelta
    }
}

public struct MessageCompletedPayload: Codable, Equatable, Sendable {
    public var messageId: MessageID
    public var role: MessageRole
    public var agent: AgentID?
    public var text: String
    public init(messageId: MessageID, role: MessageRole, agent: AgentID? = nil, text: String) {
        self.messageId = messageId
        self.role = role
        self.agent = agent
        self.text = text
    }
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var fatal: Bool
    public init(code: String, message: String, fatal: Bool = false) {
        self.code = code
        self.message = message
        self.fatal = fatal
    }
}

// MARK: - Event payloads (v0.2: tools, permission, agent status)

public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high
}

public enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
    case askUser = "ask_user"
}

public enum AgentState: String, Codable, Sendable {
    case idle, thinking, tool, blocked
}

/// The model proposed a tool call (emitted before the permission check).
public struct ToolCallPayload: Codable, Equatable, Sendable {
    public var toolCallId: String
    public var agent: AgentID?
    public var name: String
    public var args: String   // raw JSON arguments string
    public init(toolCallId: String, agent: AgentID? = nil, name: String, args: String) {
        self.toolCallId = toolCallId
        self.agent = agent
        self.name = name
        self.args = args
    }
}

public struct ToolResultPayload: Codable, Equatable, Sendable {
    public var toolCallId: String
    public var observation: String
    public var truncated: Bool?
    public init(toolCallId: String, observation: String, truncated: Bool? = nil) {
        self.toolCallId = toolCallId
        self.observation = observation
        self.truncated = truncated
    }
}

/// Surfaced to the client only when the decision is `ask_user`.
public struct PermissionRequestPayload: Codable, Equatable, Sendable {
    public var requestId: RequestID
    public var agent: AgentID?
    public var tool: String
    public var args: String
    public var risk: RiskLevel
    public var reason: String
    public init(requestId: RequestID, agent: AgentID? = nil, tool: String, args: String,
                risk: RiskLevel, reason: String) {
        self.requestId = requestId
        self.agent = agent
        self.tool = tool
        self.args = args
        self.risk = risk
        self.reason = reason
    }
}

/// Audit record of how a permission decision was settled (gate or user).
public struct PermissionResolvedPayload: Codable, Equatable, Sendable {
    public var requestId: RequestID?
    public var tool: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var reason: String
    public init(requestId: RequestID? = nil, tool: String, decision: PermissionDecision,
                risk: RiskLevel, reason: String) {
        self.requestId = requestId
        self.tool = tool
        self.decision = decision
        self.risk = risk
        self.reason = reason
    }
}

public struct PatchProposedPayload: Codable, Equatable, Sendable {
    public var patchId: String
    public var agent: AgentID?
    public var files: [String]
    public var diff: String
    public init(patchId: String, agent: AgentID? = nil, files: [String], diff: String) {
        self.patchId = patchId
        self.agent = agent
        self.files = files
        self.diff = diff
    }
}

public struct AgentStatusPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var state: AgentState
    public var task: String?
    public init(agent: AgentID? = nil, state: AgentState, task: String? = nil) {
        self.agent = agent
        self.state = state
        self.task = task
    }
}

// MARK: - Event payloads (v0.10: task contracts)

public struct TaskCreatedPayload: Codable, Equatable, Sendable {
    public var contract: TaskContract
    public var metadata: CoworkEventMetadata?
    public init(contract: TaskContract, metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.metadata = metadata
    }
}

public struct TaskAssignedPayload: Codable, Equatable, Sendable {
    public var contract: TaskContract
    public var metadata: CoworkEventMetadata?
    public init(contract: TaskContract, metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.metadata = metadata
    }
}

public struct TaskQueuedPayload: Codable, Equatable, Sendable {
    public var contract: TaskContract
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var issuer: AgentID?
    public var assignee: AgentID
    public var causalParentID: TaskID?
    public var hopCount: Int
    public var visitedAgents: [AgentID]
    public var metadata: CoworkEventMetadata?

    public init(contract: TaskContract,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID,
                causalParentID: TaskID? = nil,
                hopCount: Int,
                visitedAgents: [AgentID],
                metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.causalParentID = causalParentID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
        self.metadata = metadata
    }
}

public struct TaskStartedPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID, agent: AgentID, metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.metadata = metadata
    }
}

public struct TaskReportPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var status: TaskStatus
    public var objective: String
    public var expectedDeliverable: String
    public var summary: String
    public var detail: String?
    public var error: String?
    public var reportedAt: Date

    public init(taskID: TaskID,
                agent: AgentID,
                status: TaskStatus,
                objective: String,
                expectedDeliverable: String,
                summary: String,
                detail: String? = nil,
                error: String? = nil,
                reportedAt: Date = Date()) {
        self.taskID = taskID
        self.agent = agent
        self.status = status
        self.objective = objective
        self.expectedDeliverable = expectedDeliverable
        self.summary = summary
        self.detail = detail
        self.error = error
        self.reportedAt = reportedAt
    }
}

public struct TaskCompletedPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var result: String
    public var report: TaskReportPayload?
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID,
                agent: AgentID,
                result: String,
                report: TaskReportPayload? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.result = result
        self.report = report
        self.metadata = metadata
    }
}

public struct TaskFailedPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var error: String
    public var report: TaskReportPayload?
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID,
                agent: AgentID,
                error: String,
                report: TaskReportPayload? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.error = error
        self.report = report
        self.metadata = metadata
    }
}

public struct TaskRejectedPayload: Codable, Equatable, Sendable {
    public var contract: TaskContract?
    public var requester: AgentID?
    public var assignee: AgentID?
    public var objective: String
    public var reason: String
    public var violationKind: String?
    public var metadata: CoworkEventMetadata?

    public init(contract: TaskContract? = nil,
                requester: AgentID? = nil,
                assignee: AgentID? = nil,
                objective: String,
                reason: String,
                violationKind: String? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.requester = requester
        self.assignee = assignee
        self.objective = objective
        self.reason = reason
        self.violationKind = violationKind
        self.metadata = metadata
    }
}

// MARK: - Event

/// A single entry in the append-only conversation event log. This is *both* the
/// persistence record and the kernel→client notification (ARCHITECTURE.md §5.1,
/// principle A). Adding cases is additive — older clients skip unknown types.
public enum Event: Equatable, Sendable {
    case userMessage(UserMessagePayload)
    case messageDelta(MessageDeltaPayload)
    case messageCompleted(MessageCompletedPayload)
    case error(ErrorPayload)
    // v0.2
    case toolCall(ToolCallPayload)
    case toolResult(ToolResultPayload)
    case permissionRequest(PermissionRequestPayload)
    case permissionResolved(PermissionResolvedPayload)
    case patchProposed(PatchProposedPayload)
    case agentStatus(AgentStatusPayload)
    // v0.3 (Cowork)
    case agentAttached(AgentAttachedPayload)
    case agentAttachRequested(AgentAttachRequestedPayload)
    case agentDetached(AgentDetachedPayload)
    case agentSpawnRequested(AgentSpawnRequestedPayload)
    case agentSpawned(AgentSpawnedPayload)
    case agentMessage(AgentMessagePayload)
    case agentToAgentMessage(AgentToAgentMessagePayload)
    case informationRequested(InformationRequestedPayload)
    case informationReplied(InformationRepliedPayload)
    case delegationRequested(DelegationRequestedPayload)
    case delegationApproved(DelegationApprovedPayload)
    case delegationRejected(DelegationRejectedPayload)
    case taskDelegated(TaskDelegatedPayload)
    case workspaceLeaseRequested(WorkspaceLeaseRequestedPayload)
    case workspaceLeaseGranted(WorkspaceLeaseGrantedPayload)
    case workspaceLeaseDenied(WorkspaceLeaseDeniedPayload)
    case capabilityLeaseCreated(CapabilityLeaseCreatedPayload)
    case capabilityLeaseRevoked(CapabilityLeaseRevokedPayload)
    case permissionReview(PermissionReviewPayload)
    // v0.10 (Cowork task contracts)
    case taskCreated(TaskCreatedPayload)
    case taskAssigned(TaskAssignedPayload)
    case taskQueued(TaskQueuedPayload)
    case taskStarted(TaskStartedPayload)
    case taskCompleted(TaskCompletedPayload)
    case taskFailed(TaskFailedPayload)
    case taskRejected(TaskRejectedPayload)
    // v0.4 (Multimodal)
    case artifactAdded(ArtifactAddedPayload)
    case artifactProgress(ArtifactProgressPayload)
    // stats
    case turnStats(TurnStatsPayload)

    /// Stable wire discriminator (snake_case) used in the `type` field.
    public enum TypeTag: String, Codable, Sendable {
        case userMessage = "user_message"
        case messageDelta = "message_delta"
        case messageCompleted = "message_completed"
        case error = "error"
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case permissionRequest = "permission_request"
        case permissionResolved = "permission_resolved"
        case patchProposed = "patch_proposed"
        case agentStatus = "agent_status"
        case agentAttached = "agent_attached"
        case agentAttachRequested = "agent_attach_requested"
        case agentDetached = "agent_detached"
        case agentSpawnRequested = "agent_spawn_requested"
        case agentSpawned = "agent_spawned"
        case agentMessage = "agent_message"
        case agentToAgentMessage = "agent_to_agent_message"
        case informationRequested = "information_requested"
        case informationReplied = "information_replied"
        case delegationRequested = "delegation_requested"
        case delegationApproved = "delegation_approved"
        case delegationRejected = "delegation_rejected"
        case taskDelegated = "task_delegated"
        case workspaceLeaseRequested = "workspace_lease_requested"
        case workspaceLeaseGranted = "workspace_lease_granted"
        case workspaceLeaseDenied = "workspace_lease_denied"
        case capabilityLeaseCreated = "capability_lease_created"
        case capabilityLeaseRevoked = "capability_lease_revoked"
        case permissionReview = "permission_review"
        case taskCreated = "task_created"
        case taskAssigned = "task_assigned"
        case taskQueued = "task_queued"
        case taskStarted = "task_started"
        case taskCompleted = "task_completed"
        case taskFailed = "task_failed"
        case taskRejected = "task_rejected"
        case artifactAdded = "artifact_added"
        case artifactProgress = "artifact_progress"
        case turnStats = "turn_stats"
    }

    public var type: TypeTag {
        switch self {
        case .userMessage:        return .userMessage
        case .messageDelta:       return .messageDelta
        case .messageCompleted:   return .messageCompleted
        case .error:              return .error
        case .toolCall:           return .toolCall
        case .toolResult:         return .toolResult
        case .permissionRequest:  return .permissionRequest
        case .permissionResolved: return .permissionResolved
        case .patchProposed:      return .patchProposed
        case .agentStatus:        return .agentStatus
        case .agentAttached:       return .agentAttached
        case .agentAttachRequested: return .agentAttachRequested
        case .agentDetached:       return .agentDetached
        case .agentSpawnRequested: return .agentSpawnRequested
        case .agentSpawned:        return .agentSpawned
        case .agentMessage:        return .agentMessage
        case .agentToAgentMessage: return .agentToAgentMessage
        case .informationRequested: return .informationRequested
        case .informationReplied:   return .informationReplied
        case .delegationRequested:  return .delegationRequested
        case .delegationApproved:   return .delegationApproved
        case .delegationRejected:   return .delegationRejected
        case .taskDelegated:        return .taskDelegated
        case .workspaceLeaseRequested: return .workspaceLeaseRequested
        case .workspaceLeaseGranted:   return .workspaceLeaseGranted
        case .workspaceLeaseDenied:    return .workspaceLeaseDenied
        case .capabilityLeaseCreated:  return .capabilityLeaseCreated
        case .capabilityLeaseRevoked:  return .capabilityLeaseRevoked
        case .permissionReview:    return .permissionReview
        case .taskCreated:         return .taskCreated
        case .taskAssigned:        return .taskAssigned
        case .taskQueued:          return .taskQueued
        case .taskStarted:         return .taskStarted
        case .taskCompleted:       return .taskCompleted
        case .taskFailed:          return .taskFailed
        case .taskRejected:        return .taskRejected
        case .artifactAdded:       return .artifactAdded
        case .artifactProgress:    return .artifactProgress
        case .turnStats:           return .turnStats
        }
    }
}
