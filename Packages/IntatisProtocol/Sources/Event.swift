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
    /// Stable identity of an accepted user intent. `nil` denotes a legacy
    /// message that predates durable submission admission.
    public var submissionID: SubmissionID?
    /// Exact, secret-free `@main` inference binding selected at the Cowork
    /// composer Send boundary. It is immutable with the submitted intent so a
    /// queued or retried submission cannot drift when the user changes the
    /// selector again. `nil` covers Chat, legacy Cowork messages, and direct
    /// messages to ordinary agents.
    public var mainAgentInferenceBinding: AgentInferenceBinding?
    public init(text: String,
                attachments: [ArtifactID]? = nil,
                to: AgentID? = nil,
                tags: [String]? = nil,
                goal: String? = nil,
                submissionID: SubmissionID? = nil,
                mainAgentInferenceBinding: AgentInferenceBinding? = nil) {
        self.text = text
        self.attachments = attachments
        self.to = to
        self.tags = tags
        self.goal = goal
        self.submissionID = submissionID
        self.mainAgentInferenceBinding = mainAgentInferenceBinding
    }
}

public struct MessageDeltaPayload: Codable, Equatable, Sendable {
    public var messageId: MessageID
    public var role: MessageRole
    public var agent: AgentID?
    public var textDelta: String
    public var submissionID: SubmissionID?
    public init(messageId: MessageID,
                role: MessageRole,
                agent: AgentID? = nil,
                textDelta: String,
                submissionID: SubmissionID? = nil) {
        self.messageId = messageId
        self.role = role
        self.agent = agent
        self.textDelta = textDelta
        self.submissionID = submissionID
    }
}

public struct MessageCompletedPayload: Codable, Equatable, Sendable {
    public var messageId: MessageID
    public var role: MessageRole
    public var agent: AgentID?
    public var text: String
    public var submissionID: SubmissionID?
    public init(messageId: MessageID,
                role: MessageRole,
                agent: AgentID? = nil,
                text: String,
                submissionID: SubmissionID? = nil) {
        self.messageId = messageId
        self.role = role
        self.agent = agent
        self.text = text
        self.submissionID = submissionID
    }
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var fatal: Bool
    public var submissionID: SubmissionID?
    public init(code: String,
                message: String,
                fatal: Bool = false,
                submissionID: SubmissionID? = nil) {
        self.code = code
        self.message = message
        self.fatal = fatal
        self.submissionID = submissionID
    }
}

// MARK: - Durable submitted-intent admission

/// User-visible lifecycle of one accepted submission attempt.
public enum SubmissionStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// Bounded failure presentation retained with a failed submission. Provider
/// response bodies and secrets must be scrubbed before constructing this value.
public struct SubmissionFailure: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// Additive status record for an immutable `user_message` carrying the same
/// `submissionID`. Attempt numbers are one-based and monotonic per submission.
public struct SubmissionStatusChangedPayload: Codable, Equatable, Sendable {
    public var submissionID: SubmissionID
    public var status: SubmissionStatus
    public var attempt: Int
    public var failure: SubmissionFailure?

    public init(submissionID: SubmissionID,
                status: SubmissionStatus,
                attempt: Int,
                failure: SubmissionFailure? = nil) {
        self.submissionID = submissionID
        self.status = status
        self.attempt = attempt
        self.failure = failure
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

/// Who is expected to settle an `ask_user` permission request. Legacy requests
/// omit this field and remain manual for compatibility.
public enum PermissionApprovalMode: String, Codable, Equatable, Sendable {
    case manual
    case automaticReviewer = "automatic_reviewer"
}

public enum AgentState: String, Codable, Sendable {
    case idle, thinking, tool, blocked
}

/// The model proposed a tool call (emitted before the permission check).
public struct ToolCallPayload: Codable, Equatable, Sendable {
    public var toolCallId: String
    public var agent: AgentID?
    public var name: String
    /// Bounded, secret-scrubbed display arguments. Older events may contain
    /// raw JSON here; new writers may keep the identity of already validated,
    /// non-redacted arguments in the optional digest. Rejected, sensitive, and
    /// inference-control arguments deliberately carry no raw-value digest.
    public var args: String
    public var argsDigest: String?
    public var argsCharacterCount: Int?
    public var argsRedacted: Bool?

    public init(toolCallId: String,
                agent: AgentID? = nil,
                name: String,
                args: String,
                argsDigest: String? = nil,
                argsCharacterCount: Int? = nil,
                argsRedacted: Bool? = nil) {
        self.toolCallId = toolCallId
        self.agent = agent
        self.name = name
        self.args = args
        self.argsDigest = argsDigest
        self.argsCharacterCount = argsCharacterCount
        self.argsRedacted = argsRedacted
    }
}

public struct ToolResultPayload: Codable, Equatable, Sendable {
    public var toolCallId: String
    public var observation: String
    public var truncated: Bool?
    public var outcome: ToolCallOutcome?
    public var failureSource: ExecutionFailureSource?
    public var turnID: TurnID?
    public var permissionRequestID: RequestID?
    public init(toolCallId: String,
                observation: String,
                truncated: Bool? = nil,
                outcome: ToolCallOutcome? = nil,
                failureSource: ExecutionFailureSource? = nil,
                turnID: TurnID? = nil,
                permissionRequestID: RequestID? = nil) {
        self.toolCallId = toolCallId
        self.observation = observation
        self.truncated = truncated
        self.outcome = outcome
        self.failureSource = failureSource
        self.turnID = turnID
        self.permissionRequestID = permissionRequestID
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
    public var context: PermissionRequestContext?
    public var approvalMode: PermissionApprovalMode?
    public init(requestId: RequestID, agent: AgentID? = nil, tool: String, args: String,
                risk: RiskLevel, reason: String, context: PermissionRequestContext? = nil,
                approvalMode: PermissionApprovalMode? = nil) {
        self.requestId = requestId
        self.agent = agent
        self.tool = tool
        self.args = args
        self.risk = risk
        self.reason = reason
        self.context = context
        self.approvalMode = approvalMode
    }

    public var effectiveApprovalMode: PermissionApprovalMode {
        approvalMode ?? .manual
    }
}

/// Audit record of how a permission decision was settled (gate or user).
public struct PermissionResolvedPayload: Codable, Equatable, Sendable {
    public var requestId: RequestID?
    public var turnID: TurnID?
    public var toolCallID: String?
    public var tool: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var reason: String
    public var intent: PermissionIntent?
    public var authorization: ResolvedToolAuthorization?
    public var source: PermissionApprovalSource?
    public var reviewTaskID: PermissionReviewTaskID?
    public var reviewStatus: PermissionReviewStatus?
    public var failureKind: PermissionApprovalFailureKind?
    public var failureSource: ExecutionFailureSource?
    public var action: PermissionResponseAction?
    public init(requestId: RequestID? = nil,
                turnID: TurnID? = nil,
                toolCallID: String? = nil,
                tool: String, decision: PermissionDecision,
                risk: RiskLevel, reason: String, intent: PermissionIntent? = nil,
                authorization: ResolvedToolAuthorization? = nil,
                source: PermissionApprovalSource? = nil,
                reviewTaskID: PermissionReviewTaskID? = nil,
                reviewStatus: PermissionReviewStatus? = nil,
                failureKind: PermissionApprovalFailureKind? = nil,
                failureSource: ExecutionFailureSource? = nil,
                action: PermissionResponseAction? = nil) {
        self.requestId = requestId
        self.turnID = turnID
        self.toolCallID = toolCallID
        self.tool = tool
        self.decision = decision
        self.risk = risk
        self.reason = reason
        self.intent = intent
        self.authorization = authorization
        self.source = source
        self.reviewTaskID = reviewTaskID
        self.reviewStatus = reviewStatus
        self.failureKind = failureKind
        self.failureSource = failureSource
        self.action = action
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
    public var attempt: Int?
    public var reason: String?
    public var metadata: CoworkEventMetadata?

    public init(contract: TaskContract,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID,
                causalParentID: TaskID? = nil,
                hopCount: Int,
                visitedAgents: [AgentID],
                attempt: Int? = nil,
                reason: String? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.causalParentID = causalParentID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
        self.attempt = attempt
        self.reason = reason
        self.metadata = metadata
    }
}

public struct TaskStartedPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var attempt: Int?
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID,
                agent: AgentID,
                attempt: Int? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.attempt = attempt
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
    public var attempt: Int?
    public var reportedAt: Date

    public init(taskID: TaskID,
                agent: AgentID,
                status: TaskStatus,
                objective: String,
                expectedDeliverable: String,
                summary: String,
                detail: String? = nil,
                error: String? = nil,
                attempt: Int? = nil,
                reportedAt: Date = Date()) {
        self.taskID = taskID
        self.agent = agent
        self.status = status
        self.objective = objective
        self.expectedDeliverable = expectedDeliverable
        self.summary = summary
        self.detail = detail
        self.error = error
        self.attempt = attempt
        self.reportedAt = reportedAt
    }
}

public struct TaskCompletedPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var result: String
    public var report: TaskReportPayload?
    public var attempt: Int?
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID,
                agent: AgentID,
                result: String,
                report: TaskReportPayload? = nil,
                attempt: Int? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.result = result
        self.report = report
        self.attempt = attempt
        self.metadata = metadata
    }
}

public enum TaskFailureCode: String, Codable, Equatable, Sendable {
    case providerUsageLimit = "provider_usage_limit"
}

public struct TaskFailedPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var error: String
    public var failureCode: TaskFailureCode?
    public var report: TaskReportPayload?
    public var attempt: Int?
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID,
                agent: AgentID,
                error: String,
                failureCode: TaskFailureCode? = nil,
                report: TaskReportPayload? = nil,
                attempt: Int? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.error = error
        self.failureCode = failureCode
        self.report = report
        self.attempt = attempt
        self.metadata = metadata
    }
}

public struct TaskCancelledPayload: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var agent: AgentID
    public var reason: String
    public var report: TaskReportPayload?
    public var attempt: Int?
    public var metadata: CoworkEventMetadata?

    public init(taskID: TaskID,
                agent: AgentID,
                reason: String,
                report: TaskReportPayload? = nil,
                attempt: Int? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.taskID = taskID
        self.agent = agent
        self.reason = reason
        self.report = report
        self.attempt = attempt
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
    // versioned session/project metadata (derived into session.json)
    case sessionSettingsUpdated(SessionSettingsUpdatedPayload)
    case sessionStorageMigrated(SessionStorageMigratedPayload)
    case userMessage(UserMessagePayload)
    case submissionStatusChanged(SubmissionStatusChangedPayload)
    case messageDelta(MessageDeltaPayload)
    case messageCompleted(MessageCompletedPayload)
    case modelHistoryItem(ModelHistoryItemPayload)
    case error(ErrorPayload)
    // v0.2
    case toolCall(ToolCallPayload)
    case toolResult(ToolResultPayload)
    case toolExecutionPrepared(ToolExecutionPreparedPayload)
    case toolExecutionSettled(ToolExecutionSettledPayload)
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
    case agentMessageConsumed(AgentMessageConsumedPayload)
    case agentMessageDiscarded(AgentMessageDiscardedPayload)
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
    case workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload)
    case capabilityLeaseCreated(CapabilityLeaseCreatedPayload)
    case capabilityLeaseRevoked(CapabilityLeaseRevokedPayload)
    case permissionReview(PermissionReviewPayload)
    case permissionReviewRequested(PermissionReviewRequestedPayload)
    case permissionReviewSettled(PermissionReviewSettledPayload)
    // v0.10 (Cowork task contracts)
    case taskCreated(TaskCreatedPayload)
    case taskAssigned(TaskAssignedPayload)
    case taskQueued(TaskQueuedPayload)
    case taskStarted(TaskStartedPayload)
    case taskCompleted(TaskCompletedPayload)
    case taskFailed(TaskFailedPayload)
    case taskCancelled(TaskCancelledPayload)
    case taskRejected(TaskRejectedPayload)
    // durable user-visible WorkTask plan
    case workTaskCreated(WorkTaskCreatedPayload)
    case workTaskUpdated(WorkTaskUpdatedPayload)
    case workTaskOwnerChanged(WorkTaskOwnerChangedPayload)
    case workTaskDependencyChanged(WorkTaskDependencyChangedPayload)
    case workTaskReady(WorkTaskReadyPayload)
    case workTaskStarted(WorkTaskStartedPayload)
    case workTaskProgressed(WorkTaskProgressedPayload)
    case workTaskBlocked(WorkTaskBlockedPayload)
    case workTaskCompleted(WorkTaskCompletedPayload)
    case workTaskFailed(WorkTaskFailedPayload)
    case workTaskCancelled(WorkTaskCancelledPayload)
    case workTaskInvocationLinked(WorkTaskInvocationLinkedPayload)
    case workTaskEvidenceAdded(WorkTaskEvidenceAddedPayload)
    case workTaskCarriedForward(WorkTaskCarriedForwardPayload)
    // durable Goal lifecycle
    case goalCreated(GoalCreatedPayload)
    case goalEdited(GoalEditedPayload)
    case goalPaused(GoalPausedPayload)
    case goalResumed(GoalResumedPayload)
    case goalAuditCompleted(GoalAuditCompletedPayload)
    case goalContinuationScheduled(GoalContinuationScheduledPayload)
    case goalProgressed(GoalProgressedPayload)
    case goalBlocked(GoalBlockedPayload)
    case goalBudgetLimited(GoalBudgetLimitedPayload)
    case goalUsageLimited(GoalUsageLimitedPayload)
    case goalCompleted(GoalCompletedPayload)
    case goalCleared(GoalClearedPayload)
    // ordinary turn / Goal continuation lifecycle
    case continuationRunCreated(ContinuationRunCreatedPayload)
    case continuationRunStarted(ContinuationRunStartedPayload)
    case continuationRunCheckpointed(ContinuationRunCheckpointedPayload)
    case continuationRunCompleted(ContinuationRunCompletedPayload)
    case continuationRunCancelled(ContinuationRunCancelledPayload)
    case continuationRunRecovered(ContinuationRunRecoveredPayload)
    // v0.4 (Multimodal)
    case artifactAdded(ArtifactAddedPayload)
    case artifactProgress(ArtifactProgressPayload)
    // stats
    case turnStats(TurnStatsPayload)
    // typed terminal turn lifecycle (Phase C)
    case turnOutcome(TurnOutcomePayload)

    /// Stable wire discriminator (snake_case) used in the `type` field.
    public enum TypeTag: String, Codable, Sendable {
        case sessionSettingsUpdated = "session_settings_updated"
        case sessionStorageMigrated = "session_storage_migrated"
        case userMessage = "user_message"
        case submissionStatusChanged = "submission_status_changed"
        case messageDelta = "message_delta"
        case messageCompleted = "message_completed"
        case modelHistoryItem = "model_history_item"
        case error = "error"
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case toolExecutionPrepared = "tool_execution_prepared"
        case toolExecutionSettled = "tool_execution_settled"
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
        case agentMessageConsumed = "agent_message_consumed"
        case agentMessageDiscarded = "agent_message_discarded"
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
        case workspaceLeaseRevoked = "workspace_lease_revoked"
        case capabilityLeaseCreated = "capability_lease_created"
        case capabilityLeaseRevoked = "capability_lease_revoked"
        case permissionReview = "permission_review"
        case permissionReviewRequested = "permission_review_requested"
        case permissionReviewSettled = "permission_review_settled"
        case taskCreated = "task_created"
        case taskAssigned = "task_assigned"
        case taskQueued = "task_queued"
        case taskStarted = "task_started"
        case taskCompleted = "task_completed"
        case taskFailed = "task_failed"
        case taskCancelled = "task_cancelled"
        case taskRejected = "task_rejected"
        case workTaskCreated = "work_task_created"
        case workTaskUpdated = "work_task_updated"
        case workTaskOwnerChanged = "work_task_owner_changed"
        case workTaskDependencyChanged = "work_task_dependency_changed"
        case workTaskReady = "work_task_ready"
        case workTaskStarted = "work_task_started"
        case workTaskProgressed = "work_task_progressed"
        case workTaskBlocked = "work_task_blocked"
        case workTaskCompleted = "work_task_completed"
        case workTaskFailed = "work_task_failed"
        case workTaskCancelled = "work_task_cancelled"
        case workTaskInvocationLinked = "work_task_invocation_linked"
        case workTaskEvidenceAdded = "work_task_evidence_added"
        case workTaskCarriedForward = "work_task_carried_forward"
        case goalCreated = "goal_created"
        case goalEdited = "goal_edited"
        case goalPaused = "goal_paused"
        case goalResumed = "goal_resumed"
        case goalAuditCompleted = "goal_audit_completed"
        case goalContinuationScheduled = "goal_continuation_scheduled"
        case goalProgressed = "goal_progressed"
        case goalBlocked = "goal_blocked"
        case goalBudgetLimited = "goal_budget_limited"
        case goalUsageLimited = "goal_usage_limited"
        case goalCompleted = "goal_completed"
        case goalCleared = "goal_cleared"
        case continuationRunCreated = "continuation_run_created"
        case continuationRunStarted = "continuation_run_started"
        case continuationRunCheckpointed = "continuation_run_checkpointed"
        case continuationRunCompleted = "continuation_run_completed"
        case continuationRunCancelled = "continuation_run_cancelled"
        case continuationRunRecovered = "continuation_run_recovered"
        case artifactAdded = "artifact_added"
        case artifactProgress = "artifact_progress"
        case turnStats = "turn_stats"
        case turnOutcome = "turn_outcome"
    }

    public var type: TypeTag {
        switch self {
        case .sessionSettingsUpdated: return .sessionSettingsUpdated
        case .sessionStorageMigrated: return .sessionStorageMigrated
        case .userMessage:        return .userMessage
        case .submissionStatusChanged: return .submissionStatusChanged
        case .messageDelta:       return .messageDelta
        case .messageCompleted:   return .messageCompleted
        case .modelHistoryItem:   return .modelHistoryItem
        case .error:              return .error
        case .toolCall:           return .toolCall
        case .toolResult:         return .toolResult
        case .toolExecutionPrepared: return .toolExecutionPrepared
        case .toolExecutionSettled: return .toolExecutionSettled
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
        case .agentMessageConsumed: return .agentMessageConsumed
        case .agentMessageDiscarded: return .agentMessageDiscarded
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
        case .workspaceLeaseRevoked:   return .workspaceLeaseRevoked
        case .capabilityLeaseCreated:  return .capabilityLeaseCreated
        case .capabilityLeaseRevoked:  return .capabilityLeaseRevoked
        case .permissionReview:    return .permissionReview
        case .permissionReviewRequested: return .permissionReviewRequested
        case .permissionReviewSettled: return .permissionReviewSettled
        case .taskCreated:         return .taskCreated
        case .taskAssigned:        return .taskAssigned
        case .taskQueued:          return .taskQueued
        case .taskStarted:         return .taskStarted
        case .taskCompleted:       return .taskCompleted
        case .taskFailed:          return .taskFailed
        case .taskCancelled:       return .taskCancelled
        case .taskRejected:        return .taskRejected
        case .workTaskCreated:     return .workTaskCreated
        case .workTaskUpdated:     return .workTaskUpdated
        case .workTaskOwnerChanged: return .workTaskOwnerChanged
        case .workTaskDependencyChanged: return .workTaskDependencyChanged
        case .workTaskReady:       return .workTaskReady
        case .workTaskStarted:     return .workTaskStarted
        case .workTaskProgressed:  return .workTaskProgressed
        case .workTaskBlocked:     return .workTaskBlocked
        case .workTaskCompleted:   return .workTaskCompleted
        case .workTaskFailed:      return .workTaskFailed
        case .workTaskCancelled:   return .workTaskCancelled
        case .workTaskInvocationLinked: return .workTaskInvocationLinked
        case .workTaskEvidenceAdded: return .workTaskEvidenceAdded
        case .workTaskCarriedForward: return .workTaskCarriedForward
        case .goalCreated:         return .goalCreated
        case .goalEdited:          return .goalEdited
        case .goalPaused:          return .goalPaused
        case .goalResumed:         return .goalResumed
        case .goalAuditCompleted:  return .goalAuditCompleted
        case .goalContinuationScheduled: return .goalContinuationScheduled
        case .goalProgressed:      return .goalProgressed
        case .goalBlocked:         return .goalBlocked
        case .goalBudgetLimited:   return .goalBudgetLimited
        case .goalUsageLimited:    return .goalUsageLimited
        case .goalCompleted:       return .goalCompleted
        case .goalCleared:         return .goalCleared
        case .continuationRunCreated: return .continuationRunCreated
        case .continuationRunStarted: return .continuationRunStarted
        case .continuationRunCheckpointed: return .continuationRunCheckpointed
        case .continuationRunCompleted: return .continuationRunCompleted
        case .continuationRunCancelled: return .continuationRunCancelled
        case .continuationRunRecovered: return .continuationRunRecovered
        case .artifactAdded:       return .artifactAdded
        case .artifactProgress:    return .artifactProgress
        case .turnStats:           return .turnStats
        case .turnOutcome:         return .turnOutcome
        }
    }
}
