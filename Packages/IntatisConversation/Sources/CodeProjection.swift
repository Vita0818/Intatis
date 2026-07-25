import Foundation
import IntatisCore
import IntatisProtocol

/// A renderable item in a Code/Cowork thread — the fold of tool, permission, and
/// patch events (v0.2) plus messages. Pure and testable; SharedUI renders it.
public struct CodeItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user, agent, toolCall, toolResult, patch, note, error, agentToAgent
    }

    /// Presentation-only provenance. This is not part of the EventLog wire
    /// schema; it lets SharedUI distinguish a real model message from a
    /// scheduler lifecycle row that mirrors the same completed invocation.
    public enum PresentationSource: String, Sendable {
        case conversation
        case executionTrace
    }

    public let id: String
    public var kind: Kind
    public var presentationSource: PresentationSource
    public var title: String
    public var body: String
    public var complete: Bool
    public var files: [String]
    public var tags: [String]
    public var goal: String?
    public var attachments: [ArtifactID]
    public var isFailure: Bool
    public var recoveryAdvice: RuntimeRecoveryAdvice?
    public var submissionID: SubmissionID?
    public var submissionStatus: SubmissionStatus?
    public var submissionAttempt: Int?
    public var submissionFailure: SubmissionFailure?
    public var timestamp: Date?

    public init(id: String, kind: Kind, title: String, body: String,
                presentationSource: PresentationSource = .conversation,
                complete: Bool = true,
                files: [String] = [],
                tags: [String] = [],
                goal: String? = nil,
                attachments: [ArtifactID] = [],
                isFailure: Bool = false,
                recoveryAdvice: RuntimeRecoveryAdvice? = nil,
                submissionID: SubmissionID? = nil,
                submissionStatus: SubmissionStatus? = nil,
                submissionAttempt: Int? = nil,
                submissionFailure: SubmissionFailure? = nil,
                timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.presentationSource = presentationSource
        self.title = title
        self.body = body
        self.complete = complete
        self.files = files
        self.tags = tags
        self.goal = goal
        self.attachments = attachments
        self.isFailure = isFailure
        self.recoveryAdvice = recoveryAdvice
        self.submissionID = submissionID
        self.submissionStatus = submissionStatus
        self.submissionAttempt = submissionAttempt
        self.submissionFailure = submissionFailure
        self.timestamp = timestamp
    }
}

public struct ArtifactProgressSnapshot: Identifiable, Equatable, Sendable {
    public var id: ArtifactID
    public var progress: Double
    public var state: String
    public var seq: Int

    public init(id: ArtifactID, progress: Double, state: String, seq: Int) {
        self.id = id
        self.progress = progress
        self.state = state
        self.seq = seq
    }
}

public struct ArtifactProgressProjection: Equatable, Sendable {
    public private(set) var progressByID: [ArtifactID: ArtifactProgressSnapshot] = [:]

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .artifactProgress(let payload):
            progressByID[payload.artifactId] = ArtifactProgressSnapshot(
                id: payload.artifactId,
                progress: payload.progress,
                state: payload.state,
                seq: envelope.seq)
        case .artifactAdded(let payload):
            progressByID.removeValue(forKey: payload.artifactId)
        default:
            break
        }
    }

    public var active: [ArtifactProgressSnapshot] {
        progressByID.values.sorted { $0.seq < $1.seq }
    }

    public static func build(from envelopes: [Envelope]) -> ArtifactProgressProjection {
        var p = ArtifactProgressProjection()
        for e in envelopes { p.apply(e) }
        return p
    }
}

public struct TurnStatsSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var contextWindowTokens: Int?
    public var ttftMillis: Int?
    public var totalMillis: Int?
    public var model: String?
    public var agentID: AgentID?
    public var agentInferenceBinding: AgentInferenceBinding?

    public init(id: String, payload: TurnStatsPayload) {
        self.id = id
        self.promptTokens = payload.promptTokens
        self.cachedPromptTokens = payload.cachedPromptTokens
        self.completionTokens = payload.completionTokens
        self.totalTokens = payload.totalTokens
        self.contextWindowTokens = payload.contextWindowTokens
        self.ttftMillis = payload.ttftMillis
        self.totalMillis = payload.totalMillis
        self.model = payload.model
        self.agentID = payload.agentID
        self.agentInferenceBinding = payload.agentInferenceBinding
    }

    public var hasDisplayableMetrics: Bool {
        promptTokens != nil
            || cachedPromptTokens != nil
            || completionTokens != nil
            || totalTokens != nil
            || contextWindowTokens != nil
            || ttftMillis != nil
            || totalMillis != nil
    }
}

public struct TurnStatsProjection: Equatable, Sendable {
    public private(set) var latest: TurnStatsSnapshot?

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        guard case .turnStats(let payload) = envelope.event else { return }
        let snapshot = TurnStatsSnapshot(
            id: "\(envelope.session.rawValue):\(envelope.seq):turn_stats",
            payload: payload)
        latest = snapshot.hasDisplayableMetrics ? snapshot : nil
    }

    public static func build(from envelopes: [Envelope]) -> TurnStatsProjection {
        var projection = TurnStatsProjection()
        for envelope in envelopes {
            projection.apply(envelope)
        }
        return projection
    }
}

/// Folds the event stream into `[CodeItem]`. `permission_request` is intentionally
/// not folded here — the pending request is surfaced separately as an actionable
/// card (the gate runs before execution).
public struct CodeProjection: Equatable, Sendable {
    private struct TaskAttemptKey: Hashable, Sendable {
        var taskID: TaskID
        var attempt: Int?
    }

    private struct CompletedMessageReference: Equatable, Sendable {
        var agent: AgentID
        var itemIndex: Int
    }

    public private(set) var items: [CodeItem] = []
    private var activeTaskByAgent: [AgentID: TaskAttemptKey] = [:]
    private var latestCompletedMessageByTaskAttempt: [TaskAttemptKey: CompletedMessageReference] = [:]

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .userMessage(let p):
            if let submissionID = p.submissionID,
               items.contains(where: { $0.kind == .user && $0.submissionID == submissionID }) {
                // The first accepted payload is immutable. A retry reuses its
                // submission identity and must not create or overwrite a user
                // message.
                break
            }
            items.append(CodeItem(id: p.submissionID?.rawValue ?? stableID(envelope, "user"),
                                  kind: .user,
                                  title: "You",
                                  body: p.text,
                                  tags: p.tags ?? [],
                                  goal: p.goal,
                                  attachments: p.attachments ?? [],
                                  submissionID: p.submissionID))

        case .submissionStatusChanged(let p):
            guard let index = items.firstIndex(where: {
                $0.kind == .user && $0.submissionID == p.submissionID
            }), SubmissionStatusFold.accepts(
                currentStatus: items[index].submissionStatus,
                currentAttempt: items[index].submissionAttempt,
                next: p)
            else { break }
            items[index].submissionStatus = p.status
            items[index].submissionAttempt = p.attempt
            items[index].submissionFailure = p.failure
            items[index].isFailure = p.status == .failed || p.status == .cancelled

        case .messageDelta(let p):
            if let i = agentIndex(p.messageId.rawValue) {
                items[i].body += p.textDelta
                if items[i].timestamp == nil {
                    items[i].timestamp = envelope.ts
                }
            } else {
                items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                      title: p.agent?.rawValue ?? "Agent", body: p.textDelta, complete: false,
                                      submissionID: p.submissionID,
                                      timestamp: envelope.ts))
            }

        case .messageCompleted(let p):
            if let i = agentIndex(p.messageId.rawValue) {
                items[i].body = p.text
                items[i].complete = true
                if items[i].timestamp == nil {
                    items[i].timestamp = envelope.ts
                }
                recordCompletedMessage(at: i, from: p.agent)
            } else {
                items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                      title: p.agent?.rawValue ?? "Agent", body: p.text,
                                      submissionID: p.submissionID,
                                      timestamp: envelope.ts))
                recordCompletedMessage(at: items.count - 1, from: p.agent)
            }

        case .toolCall(let p):
            items.append(CodeItem(id: p.toolCallId, kind: .toolCall, title: p.name, body: p.args))

        case .toolResult(let p):
            let toolName = toolName(for: p.toolCallId)
            let title = toolName.map { "result · \($0)" } ?? "result"
            // Current logs carry a typed call outcome. Keep the text
            // classifier only as an old-JSONL compatibility fallback; new
            // runtime/sandbox failures must never depend on presentation
            // wording, and successful output that happens to resemble an
            // error prefix must remain successful.
            let isFailure = p.outcome.map { $0 != .succeeded }
                ?? Self.isFailureObservation(p.observation)
            items.append(CodeItem(id: p.toolCallId + ":result", kind: .toolResult,
                                  title: title, body: p.observation,
                                  isFailure: isFailure,
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(forToolObservation: p.observation)))

        case .patchProposed(let p):
            items.append(CodeItem(id: p.patchId, kind: .patch, title: "patch", body: p.diff, files: p.files))

        case .permissionResolved(let p):
            items.append(CodeItem(id: stableID(envelope, "permission_resolved"), kind: .note, title: "permission",
                                  body: "\(p.decision.rawValue): \(p.tool) — \(p.reason)"))

        case .error(let p):
            markCurrentPartialAgentStopped(with: p)
            items.append(CodeItem(id: stableID(envelope, "error"),
                                  kind: .error,
                                  title: "error · \(p.code)",
                                  body: p.message,
                                  isFailure: true,
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(for: p),
                                  submissionID: p.submissionID))

        // v0.3 (Cowork)
        case .agentAttached(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_attached"), kind: .note, title: "agent",
                                  body: "+ @\(p.agent.rawValue) attached (\(p.path))"))

        case .agentAttachRequested(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_attach_requested"), kind: .note, title: "agent attach requested",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentDetached(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_detached"), kind: .note, title: "agent",
                                  body: "− @\(p.agent.rawValue) detached"))

        case .agentSpawnRequested(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_spawn_requested"), kind: .note, title: "agent spawn requested",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentSpawned(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_spawned"), kind: .note, title: "agent spawned",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentMessage(let p):
            let title = p.from.flatMap { from in p.to.map { "\(from.rawValue) -> \($0.rawValue)" } }
                ?? p.agent.rawValue
            items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                  title: title, body: p.content,
                                  timestamp: envelope.ts))

        case .agentMessageConsumed, .agentMessageDiscarded:
            break

        case .agentToAgentMessage(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_to_agent"), kind: .agentToAgent,
                                  title: "\(p.from.rawValue) → \(p.to.rawValue)", body: p.content))

        case .informationRequested(let p):
            items.append(CodeItem(id: p.requestID.rawValue, kind: .agentToAgent,
                                  title: "info \(p.from.rawValue) -> \(p.to.rawValue)", body: p.question))

        case .informationReplied(let p):
            items.append(CodeItem(id: p.replyID.rawValue, kind: .agentToAgent,
                                  title: "reply \(p.from.rawValue) -> \(p.to.rawValue)", body: p.content))

        case .delegationRequested(let p):
            items.append(CodeItem(id: p.requestID.rawValue, kind: .note, title: "delegation requested",
                                  body: "\(p.requester.rawValue): \(p.objective) — \(p.reason)"))

        case .delegationApproved(let p):
            items.append(CodeItem(id: stableID(envelope, "delegation_approved"), kind: .note, title: "delegation approved",
                                  body: "@\(p.contract.assignee.rawValue): \(p.contract.objective)"))

        case .delegationRejected(let p):
            items.append(CodeItem(id: stableID(envelope, "delegation_rejected"), kind: .error, title: "delegation rejected",
                                  body: "\(p.objective) — \(p.reason)",
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "delegation_rejected",
                                    message: p.reason)))

        case .taskDelegated(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":delegated", kind: .note, title: "task delegated",
                                  body: "@\(p.assignee.rawValue): \(p.contract.objective)"))

        case .workspaceLeaseRequested(let p):
            items.append(CodeItem(id: stableID(envelope, "workspace_lease_requested"), kind: .note, title: "workspace lease requested",
                                  body: "\(p.access.rawValue): \(p.rootPath)"))

        case .workspaceLeaseGranted(let p):
            items.append(CodeItem(id: p.lease.id.rawValue, kind: .note, title: "workspace lease",
                                  body: "\(p.lease.access.rawValue): \(p.lease.rootPath)"))

        case .workspaceLeaseDenied(let p):
            items.append(CodeItem(id: stableID(envelope, "workspace_lease_denied"), kind: .error, title: "workspace lease denied",
                                  body: "\(p.rootPath) — \(p.reason)",
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "permission_denied",
                                    message: p.reason)))

        case .workspaceLeaseRevoked(let p):
            items.append(CodeItem(id: p.leaseID.rawValue + ":revoked", kind: .note,
                                  title: "workspace lease revoked", body: p.reason))

        case .capabilityLeaseCreated(let p):
            items.append(CodeItem(id: p.lease.id.rawValue, kind: .note, title: "capability lease",
                                  body: p.lease.tools.map(\.rawValue).sorted().joined(separator: ", ")))

        case .capabilityLeaseRevoked(let p):
            items.append(CodeItem(id: p.leaseID.rawValue + ":revoked", kind: .note, title: "capability lease revoked",
                                  body: p.reason))

        case .permissionReview(let p):
            items.append(CodeItem(id: stableID(envelope, "permission_review"), kind: .note, title: "review",
                                  body: "reviewer(\(p.reviewerModel)): \(p.decision.rawValue) \(p.tool) — \(p.reason)"))

        case .taskCreated(let p):
            items.append(CodeItem(id: p.contract.id.rawValue, kind: .note, title: "task",
                                  body: "created \(p.contract.roleHint): \(p.contract.objective)"))

        case .taskAssigned(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":assigned", kind: .note, title: "task",
                                  body: "assigned @\(p.contract.assignee.rawValue): \(p.contract.expectedDeliverable)"))

        case .taskQueued(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":queued", kind: .note, title: "task",
                                  body: "queued @\(p.assignee.rawValue): \(p.contract.objective)"))

        case .taskStarted(let p):
            beginTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)
            items.append(CodeItem(id: p.taskID.rawValue + ":started", kind: .note, title: "task",
                                  body: "started @\(p.agent.rawValue)"))

        case .taskCompleted(let p):
            let presentationSource: CodeItem.PresentationSource = completedTaskMirrorsMessage(p)
                ? .executionTrace
                : .conversation
            items.append(CodeItem(id: p.taskID.rawValue + ":completed", kind: .agent,
                                  title: p.agent.rawValue, body: p.result,
                                  presentationSource: presentationSource,
                                  timestamp: envelope.ts))
            finishTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)

        case .taskFailed(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":failed", kind: .error,
                                  title: p.agent.rawValue,
                                  body: p.error,
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "task_failed",
                                    message: p.error)))
            finishTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)

        case .taskCancelled(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":cancelled", kind: .note,
                                  title: "task cancelled · (p.agent.rawValue)", body: p.reason))
            finishTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)

        case .taskRejected(let p):
            items.append(CodeItem(id: p.contract?.id.rawValue ?? stableID(envelope, "task_rejected"), kind: .error,
                                  title: "task rejected",
                                  body: "\(p.objective) — \(p.reason)",
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "task_rejected",
                                    message: p.reason)))
        case .artifactAdded(let p):
            items.append(CodeItem(id: p.artifactId.rawValue, kind: .note, title: "artifact",
                                  body: "📎 \(p.kind)" + (p.prompt.map { ": \($0)" } ?? "")))

        case .sessionSettingsUpdated, .sessionStorageMigrated, .modelHistoryItem,
             .toolExecutionPrepared, .toolExecutionSettled,
             .permissionRequest, .permissionReviewRequested, .permissionReviewSettled,
             .agentStatus,
             .workTaskCreated, .workTaskUpdated, .workTaskOwnerChanged, .workTaskDependencyChanged,
             .workTaskReady, .workTaskStarted, .workTaskProgressed, .workTaskBlocked,
             .workTaskCompleted, .workTaskFailed, .workTaskCancelled,
             .workTaskInvocationLinked, .workTaskEvidenceAdded, .workTaskCarriedForward,
             .goalCreated, .goalEdited, .goalPaused, .goalResumed, .goalAuditCompleted,
             .goalContinuationScheduled, .goalProgressed, .goalBlocked,
             .goalBudgetLimited, .goalUsageLimited, .goalCompleted, .goalCleared,
             .continuationRunCreated, .continuationRunStarted, .continuationRunCheckpointed,
             .continuationRunCompleted, .continuationRunCancelled, .continuationRunRecovered,
             .artifactProgress, .turnStats, .turnOutcome:
            break
        }
    }

    public static func build(from envelopes: [Envelope]) -> CodeProjection {
        var p = CodeProjection()
        for e in envelopes { p.apply(e) }
        return p
    }

    private func agentIndex(_ id: String) -> Int? {
        items.firstIndex { $0.id == id && $0.kind == .agent }
    }

    private func toolName(for toolCallId: String) -> String? {
        items.first { $0.id == toolCallId && $0.kind == .toolCall }?.title
    }

    private mutating func beginTaskTracking(taskID: TaskID, agent: AgentID, attempt: Int?) {
        let key = TaskAttemptKey(taskID: taskID, attempt: attempt)
        activeTaskByAgent[agent] = key
        // A duplicate start for this exact invocation must not inherit an old
        // completed message. References for other attempts remain available
        // so a late terminal cannot consume the currently active attempt.
        latestCompletedMessageByTaskAttempt.removeValue(forKey: key)
    }

    private mutating func recordCompletedMessage(at index: Int, from agent: AgentID?) {
        guard let agent, let key = activeTaskByAgent[agent] else { return }
        latestCompletedMessageByTaskAttempt[key] = CompletedMessageReference(
            agent: agent,
            itemIndex: index)
    }

    private func completedTaskMirrorsMessage(_ payload: TaskCompletedPayload) -> Bool {
        let key = TaskAttemptKey(taskID: payload.taskID, attempt: payload.attempt)
        guard let reference = latestCompletedMessageByTaskAttempt[key],
              reference.agent == payload.agent,
              items.indices.contains(reference.itemIndex)
        else { return false }

        let message = items[reference.itemIndex]
        return message.kind == .agent
            && message.complete
            && message.body == payload.result
    }

    private mutating func finishTaskTracking(taskID: TaskID, agent: AgentID, attempt: Int?) {
        let key = TaskAttemptKey(taskID: taskID, attempt: attempt)
        if activeTaskByAgent[agent] == key {
            activeTaskByAgent.removeValue(forKey: agent)
        }
        latestCompletedMessageByTaskAttempt.removeValue(forKey: key)
    }

    private mutating func markCurrentPartialAgentStopped(with payload: ErrorPayload) {
        guard let index = items.indices.last else { return }
        guard items[index].kind == .agent, !items[index].complete else { return }
        items[index].isFailure = true
        items[index].recoveryAdvice = RuntimeErrorPresentation.partialResponseAdvice(for: payload)
    }

    private static func isFailureObservation(_ observation: String) -> Bool {
        let lower = observation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("tool error:")
            || lower.hasPrefix("permission denied:")
            || lower.hasPrefix("unknown tool:")
            || lower.hasPrefix("invalid tool input:")
    }

    private func stableID(_ envelope: Envelope, _ suffix: String) -> String {
        "\(envelope.session.rawValue):\(envelope.seq):\(suffix)"
    }
}

public enum PendingPermissionState: String, Equatable, Sendable {
    case livePending = "live_pending"
    case resolving
    case approved
    case rejected
    case expired
    case needsRerun = "needs_rerun"

    public var isActionable: Bool {
        self == .livePending
    }
}

public struct PendingPermission: Identifiable, Equatable, Sendable {
    public var id: RequestID { request.requestId }
    public var request: PermissionRequestPayload
    public var state: PendingPermissionState
    public var requestedSeq: Int
    public var hasIdentityConflict: Bool

    public init(request: PermissionRequestPayload,
                state: PendingPermissionState = .livePending,
                requestedSeq: Int,
                hasIdentityConflict: Bool = false) {
        self.request = request
        self.state = state
        self.requestedSeq = requestedSeq
        self.hasIdentityConflict = hasIdentityConflict
    }
}

public struct PermissionResolutionNotice: Identifiable, Equatable, Sendable {
    public var id: String
    public var requestId: RequestID?
    public var tool: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var reason: String
    public var authorization: ResolvedToolAuthorization?
    public var source: PermissionApprovalSource?
    public var reviewTaskID: PermissionReviewTaskID?
    public var reviewStatus: PermissionReviewStatus?
    public var failureKind: PermissionApprovalFailureKind?
    public var failureSource: ExecutionFailureSource?
    public var action: PermissionResponseAction?
    public var resolvedSeq: Int

    public init(id: String,
                requestId: RequestID?,
                tool: String,
                decision: PermissionDecision,
                risk: RiskLevel,
                reason: String,
                authorization: ResolvedToolAuthorization? = nil,
                source: PermissionApprovalSource? = nil,
                reviewTaskID: PermissionReviewTaskID? = nil,
                reviewStatus: PermissionReviewStatus? = nil,
                failureKind: PermissionApprovalFailureKind? = nil,
                failureSource: ExecutionFailureSource? = nil,
                action: PermissionResponseAction? = nil,
                resolvedSeq: Int) {
        self.id = id
        self.requestId = requestId
        self.tool = tool
        self.decision = decision
        self.risk = risk
        self.reason = reason
        self.authorization = authorization
        self.source = source
        self.reviewTaskID = reviewTaskID
        self.reviewStatus = reviewStatus
        self.failureKind = failureKind
        self.failureSource = failureSource
        self.action = action
        self.resolvedSeq = resolvedSeq
    }
}

/// Folds permission request/resolution events into recoverable pending state.
/// A replayed pending request may no longer have a live async tool continuation;
/// callers can mark it `needs_rerun` while still showing it in the UI.
public struct PermissionProjection: Equatable, Sendable {
    public private(set) var pending: [PendingPermission] = []
    public private(set) var resolved: [PermissionResolutionNotice] = []
    private var automaticReviewRequestIDs: Set<RequestID> = []

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .permissionRequest(let request):
            register(request, requestedSeq: envelope.seq)
        case .permissionReviewRequested(let review):
            let requestID = review.task.requestID
            automaticReviewRequestIDs.insert(requestID)
            if let index = pending.firstIndex(where: { $0.id == requestID }),
               pending[index].state == .livePending {
                pending[index].state = .resolving
            }
        case .permissionResolved(let resolved):
            if let requestID = resolved.requestId {
                // A permission request has one terminal result. Replayed,
                // duplicate, or conflicting late settlements cannot replace
                // the first durable terminal event.
                guard !self.resolved.contains(where: { $0.requestId == requestID }) else {
                    break
                }
                pending.removeAll { $0.request.requestId == requestID }
            }
            self.resolved.append(PermissionResolutionNotice(
                id: stableResolvedID(envelope, requestID: resolved.requestId),
                requestId: resolved.requestId,
                tool: resolved.tool,
                decision: resolved.decision,
                risk: resolved.risk,
                reason: resolved.reason,
                authorization: resolved.authorization,
                source: resolved.source,
                reviewTaskID: resolved.reviewTaskID,
                reviewStatus: resolved.reviewStatus,
                failureKind: resolved.failureKind,
                failureSource: resolved.failureSource,
                action: resolved.action,
                resolvedSeq: envelope.seq))
        default:
            break
        }
    }

    public mutating func markNeedsRerun() {
        pending = pending.map {
            var item = $0
            item.state = .needsRerun
            return item
        }
    }

    public var latest: PendingPermission? {
        // Kept under the historical `latest` API name for compatibility. The
        // presentation contract is FIFO: always surface the oldest unresolved
        // request, including a non-actionable automatic review ahead of later
        // requests.
        pending.min { lhs, rhs in
            if lhs.requestedSeq == rhs.requestedSeq {
                return lhs.id.rawValue < rhs.id.rawValue
            }
            return lhs.requestedSeq < rhs.requestedSeq
        }
    }

    public var latestResolved: PermissionResolutionNotice? {
        resolved.sorted { $0.resolvedSeq < $1.resolvedSeq }.last
    }

    public static func build(from envelopes: [Envelope], markNeedsRerun: Bool = false) -> PermissionProjection {
        var p = PermissionProjection()
        for e in envelopes { p.apply(e) }
        if markNeedsRerun { p.markNeedsRerun() }
        return p
    }

    private mutating func register(_ request: PermissionRequestPayload, requestedSeq: Int) {
        let requestID = request.requestId

        // A late request event must not reopen an identity which already has a
        // terminal result.
        guard !resolved.contains(where: { $0.requestId == requestID }) else { return }

        if let index = pending.firstIndex(where: { $0.id == requestID }) {
            // Exact duplicates are replay/idempotency noise. Preserve the
            // original position and state. A different payload reusing the
            // identity is ambiguous, so retain the first payload and fail
            // closed instead of exposing either version as actionable.
            if !requestsAreEquivalent(pending[index].request, request) {
                pending[index].state = .expired
                pending[index].hasIdentityConflict = true
            }
            return
        }

        let state: PendingPermissionState = request.effectiveApprovalMode == .automaticReviewer
            || automaticReviewRequestIDs.contains(requestID)
            ? .resolving
            : .livePending
        pending.append(PendingPermission(
            request: request,
            state: state,
            requestedSeq: requestedSeq))
    }

    private func requestsAreEquivalent(_ lhs: PermissionRequestPayload,
                                       _ rhs: PermissionRequestPayload) -> Bool {
        var normalizedLHS = lhs
        var normalizedRHS = rhs
        normalizedLHS.approvalMode = lhs.effectiveApprovalMode
        normalizedRHS.approvalMode = rhs.effectiveApprovalMode
        return normalizedLHS == normalizedRHS
    }

    private func stableResolvedID(_ envelope: Envelope, requestID: RequestID?) -> String {
        if let requestID {
            return "permission:\(requestID.rawValue):resolved"
        }
        return "\(envelope.session.rawValue):\(envelope.seq):permission_resolved"
    }
}
