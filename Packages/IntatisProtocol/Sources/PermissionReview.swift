import Foundation
import IntatisCore

/// Identifier for a control-plane permission review. Review tasks deliberately
/// do not enter the ordinary Cowork TaskGraph or consume an AgentScheduler slot.
public struct PermissionReviewTaskID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> PermissionReviewTaskID {
        PermissionReviewTaskID(rawValue: IDGen.random(prefix: "review"))
    }
}

/// The deterministic layer-A result that caused (or rejected) a review.
public enum PermissionReviewGateDecision: String, Codable, Equatable, Sendable {
    case deny
    case ask
    case allow
    case pass
}

public struct PermissionReviewGateSnapshot: Codable, Equatable, Sendable {
    public var decision: PermissionReviewGateDecision
    public var risk: RiskLevel
    public var reason: String

    public init(decision: PermissionReviewGateDecision,
                risk: RiskLevel,
                reason: String) {
        self.decision = decision
        self.risk = risk
        self.reason = reason
    }
}

/// Bounded causal evidence attached to the current execution. The sequence
/// numbers refer back to the append-only EventLog instead of duplicating raw
/// transcript or tool output in the review task.
public struct PermissionReviewCausalContext: Codable, Equatable, Sendable {
    public var userGoal: String?
    public var issuer: AgentID?
    public var assignee: AgentID?
    public var taskLineage: [TaskID]
    public var relatedAgents: [AgentID]
    public var eventSequenceNumbers: [Int]

    public init(userGoal: String? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID? = nil,
                taskLineage: [TaskID] = [],
                relatedAgents: [AgentID] = [],
                eventSequenceNumbers: [Int] = []) {
        self.userGoal = userGoal
        self.issuer = issuer
        self.assignee = assignee
        self.taskLineage = taskLineage
        self.relatedAgents = relatedAgents
        self.eventSequenceNumbers = eventSequenceNumbers
    }
}

/// Optional execution facts supplied by AgentKernel to a PermissionResponder.
/// Every field is additive/optional so old JSONL and non-Cowork responders keep
/// decoding and constructing PermissionRequestPayload exactly as before.
public struct PermissionRequestContext: Codable, Equatable, Sendable {
    public var taskID: TaskID?
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String?
    public var normalizedArgs: String?
    public var touchedPaths: [String]
    public var risksNetwork: Bool?
    public var sideEffect: SideEffect?
    public var gate: PermissionReviewGateSnapshot?
    public var capabilityLease: CapabilityLease?
    public var workspaceLease: WorkspaceLease?
    public var taskContract: TaskContract?
    public var causalContext: PermissionReviewCausalContext?
    /// Reserved for crash-reconciliation/idempotency integration.
    public var executionID: String?
    /// Forward-compatible policy label such as `safe_replay` or
    /// `requires_reconciliation`; interpretation remains in AgentKernel.
    public var replayPolicy: String?

    public init(taskID: TaskID? = nil,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String? = nil,
                normalizedArgs: String? = nil,
                touchedPaths: [String] = [],
                risksNetwork: Bool? = nil,
                sideEffect: SideEffect? = nil,
                gate: PermissionReviewGateSnapshot? = nil,
                capabilityLease: CapabilityLease? = nil,
                workspaceLease: WorkspaceLease? = nil,
                taskContract: TaskContract? = nil,
                causalContext: PermissionReviewCausalContext? = nil,
                executionID: String? = nil,
                replayPolicy: String? = nil) {
        self.taskID = taskID
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.normalizedArgs = normalizedArgs
        self.touchedPaths = touchedPaths
        self.risksNetwork = risksNetwork
        self.sideEffect = sideEffect
        self.gate = gate
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.taskContract = taskContract
        self.causalContext = causalContext
        self.executionID = executionID
        self.replayPolicy = replayPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case taskID, rootTaskID, parentTaskID, attempt, toolCallID, normalizedArgs
        case touchedPaths, risksNetwork, sideEffect, gate, capabilityLease
        case workspaceLease, taskContract, causalContext, executionID, replayPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decodeIfPresent(TaskID.self, forKey: .taskID)
        rootTaskID = try container.decodeIfPresent(TaskID.self, forKey: .rootTaskID)
        parentTaskID = try container.decodeIfPresent(TaskID.self, forKey: .parentTaskID)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        normalizedArgs = try container.decodeIfPresent(String.self, forKey: .normalizedArgs)
        touchedPaths = try container.decodeIfPresent([String].self, forKey: .touchedPaths) ?? []
        risksNetwork = try container.decodeIfPresent(Bool.self, forKey: .risksNetwork)
        sideEffect = try container.decodeIfPresent(SideEffect.self, forKey: .sideEffect)
        gate = try container.decodeIfPresent(PermissionReviewGateSnapshot.self, forKey: .gate)
        capabilityLease = try container.decodeIfPresent(CapabilityLease.self, forKey: .capabilityLease)
        workspaceLease = try container.decodeIfPresent(WorkspaceLease.self, forKey: .workspaceLease)
        taskContract = try container.decodeIfPresent(TaskContract.self, forKey: .taskContract)
        causalContext = try container.decodeIfPresent(PermissionReviewCausalContext.self, forKey: .causalContext)
        executionID = try container.decodeIfPresent(String.self, forKey: .executionID)
        replayPolicy = try container.decodeIfPresent(String.self, forKey: .replayPolicy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encodeIfPresent(rootTaskID, forKey: .rootTaskID)
        try container.encodeIfPresent(parentTaskID, forKey: .parentTaskID)
        try container.encodeIfPresent(attempt, forKey: .attempt)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(normalizedArgs, forKey: .normalizedArgs)
        if !touchedPaths.isEmpty { try container.encode(touchedPaths, forKey: .touchedPaths) }
        try container.encodeIfPresent(risksNetwork, forKey: .risksNetwork)
        try container.encodeIfPresent(sideEffect, forKey: .sideEffect)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encodeIfPresent(capabilityLease, forKey: .capabilityLease)
        try container.encodeIfPresent(workspaceLease, forKey: .workspaceLease)
        try container.encodeIfPresent(taskContract, forKey: .taskContract)
        try container.encodeIfPresent(causalContext, forKey: .causalContext)
        try container.encodeIfPresent(executionID, forKey: .executionID)
        try container.encodeIfPresent(replayPolicy, forKey: .replayPolicy)
    }
}

/// A durable, structured control-plane job. This is intentionally separate
/// from TaskContract: the reviewer must not recursively enter an AgentLoop or
/// occupy a data-plane scheduler slot while the requesting task is blocked.
public struct PermissionReviewTask: Codable, Equatable, Sendable {
    public var id: PermissionReviewTaskID
    public var sessionID: SessionID
    public var requestID: RequestID
    public var requestingAgent: AgentID?
    public var reviewerAgent: AgentID
    public var taskID: TaskID?
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String?
    public var tool: String
    public var normalizedArgs: String
    public var touchedPaths: [String]
    public var risksNetwork: Bool
    public var sideEffect: SideEffect?
    public var gate: PermissionReviewGateSnapshot
    public var capabilityLease: CapabilityLease?
    public var workspaceLease: WorkspaceLease?
    public var taskContract: TaskContract?
    public var causalContext: PermissionReviewCausalContext
    public var executionID: String?
    public var replayPolicy: String?
    public var createdAt: Date
    public var deadline: Date

    public init(id: PermissionReviewTaskID = .new(),
                sessionID: SessionID,
                requestID: RequestID,
                requestingAgent: AgentID?,
                reviewerAgent: AgentID,
                taskID: TaskID? = nil,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String? = nil,
                tool: String,
                normalizedArgs: String,
                touchedPaths: [String] = [],
                risksNetwork: Bool = false,
                sideEffect: SideEffect? = nil,
                gate: PermissionReviewGateSnapshot,
                capabilityLease: CapabilityLease? = nil,
                workspaceLease: WorkspaceLease? = nil,
                taskContract: TaskContract? = nil,
                causalContext: PermissionReviewCausalContext = .init(),
                executionID: String? = nil,
                replayPolicy: String? = nil,
                createdAt: Date = Date(),
                deadline: Date) {
        self.id = id
        self.sessionID = sessionID
        self.requestID = requestID
        self.requestingAgent = requestingAgent
        self.reviewerAgent = reviewerAgent
        self.taskID = taskID
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.tool = tool
        self.normalizedArgs = normalizedArgs
        self.touchedPaths = touchedPaths
        self.risksNetwork = risksNetwork
        self.sideEffect = sideEffect
        self.gate = gate
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.taskContract = taskContract
        self.causalContext = causalContext
        self.executionID = executionID
        self.replayPolicy = replayPolicy
        self.createdAt = createdAt
        self.deadline = deadline
    }
}

public struct PermissionReviewRequestedPayload: Codable, Equatable, Sendable {
    public var task: PermissionReviewTask

    public init(task: PermissionReviewTask) {
        self.task = task
    }
}

public enum PermissionReviewStatus: String, Codable, Equatable, Sendable {
    case allowed
    case denied
    case awaitingUser = "awaiting_user"
    case failed
    case timedOut = "timed_out"
    case cancelled
    case budgetExceeded = "budget_exceeded"
}

public struct PermissionReviewUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var estimated: Bool

    public init(promptTokens: Int? = nil,
                completionTokens: Int? = nil,
                totalTokens: Int? = nil,
                estimated: Bool = false) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.estimated = estimated
    }
}

public struct PermissionReviewSettledPayload: Codable, Equatable, Sendable {
    public var reviewTaskID: PermissionReviewTaskID
    public var requestID: RequestID
    public var requestingAgent: AgentID?
    public var reviewerAgent: AgentID
    public var reviewerModel: ModelID
    public var tool: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var status: PermissionReviewStatus
    public var reason: String
    public var usage: PermissionReviewUsage?
    public var cumulativeTokens: Int?
    public var durationMillis: Int
    public var settledAt: Date

    public init(reviewTaskID: PermissionReviewTaskID,
                requestID: RequestID,
                requestingAgent: AgentID?,
                reviewerAgent: AgentID,
                reviewerModel: ModelID,
                tool: String,
                decision: PermissionDecision,
                risk: RiskLevel,
                status: PermissionReviewStatus,
                reason: String,
                usage: PermissionReviewUsage? = nil,
                cumulativeTokens: Int? = nil,
                durationMillis: Int,
                settledAt: Date = Date()) {
        self.reviewTaskID = reviewTaskID
        self.requestID = requestID
        self.requestingAgent = requestingAgent
        self.reviewerAgent = reviewerAgent
        self.reviewerModel = reviewerModel
        self.tool = tool
        self.decision = decision
        self.risk = risk
        self.status = status
        self.reason = reason
        self.usage = usage
        self.cumulativeTokens = cumulativeTokens
        self.durationMillis = durationMillis
        self.settledAt = settledAt
    }
}
