import Foundation
import IntatisCore

// MARK: - WorkTask events

/// WorkTask events carry the latest full snapshot. This keeps EventLog replay
/// deterministic while the distinct event types retain the semantic audit trail.
public struct WorkTaskCreatedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public init(task: WorkTask) { self.task = task }
}

public struct WorkTaskUpdatedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var previousRevision: Int?
    public init(task: WorkTask, previousRevision: Int? = nil) {
        self.task = task
        self.previousRevision = previousRevision
    }
}

public struct WorkTaskOwnerChangedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var previousOwner: AgentID?
    public init(task: WorkTask, previousOwner: AgentID? = nil) {
        self.task = task
        self.previousOwner = previousOwner
    }
}

public struct WorkTaskDependencyChangedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var previousDependencies: [WorkTaskID]
    public init(task: WorkTask, previousDependencies: [WorkTaskID] = []) {
        self.task = task
        self.previousDependencies = previousDependencies
    }
}

public struct WorkTaskReadyPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public init(task: WorkTask) { self.task = task }
}

public struct WorkTaskStartedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public init(task: WorkTask) { self.task = task }
}

public struct WorkTaskProgressedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public init(task: WorkTask) { self.task = task }
}

public struct WorkTaskBlockedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var blocker: String
    public init(task: WorkTask, blocker: String) {
        self.task = task
        self.blocker = blocker
    }
}

public struct WorkTaskCompletedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public init(task: WorkTask) { self.task = task }
}

public struct WorkTaskFailedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var error: String
    public init(task: WorkTask, error: String) {
        self.task = task
        self.error = error
    }
}

public struct WorkTaskCancelledPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var reason: String
    public init(task: WorkTask, reason: String) {
        self.task = task
        self.reason = reason
    }
}

public struct WorkTaskInvocationLinkedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var invocationID: TaskID
    public init(task: WorkTask, invocationID: TaskID) {
        self.task = task
        self.invocationID = invocationID
    }
}

public struct WorkTaskEvidenceAddedPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var evidence: TaskEvidence
    public init(task: WorkTask, evidence: TaskEvidence) {
        self.task = task
        self.evidence = evidence
    }
}

public struct WorkTaskCarriedForwardPayload: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var sourceTaskID: WorkTaskID
    public var sourceRunID: ContinuationRunID
    public init(task: WorkTask,
                sourceTaskID: WorkTaskID,
                sourceRunID: ContinuationRunID) {
        self.task = task
        self.sourceTaskID = sourceTaskID
        self.sourceRunID = sourceRunID
    }
}

// MARK: - Goal events

public struct GoalCreatedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public init(goal: Goal) { self.goal = goal }
}

public struct GoalEditedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var previousRevision: Int?
    public init(goal: Goal, previousRevision: Int? = nil) {
        self.goal = goal
        self.previousRevision = previousRevision
    }
}

public struct GoalPausedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public init(goal: Goal) { self.goal = goal }
}

public struct GoalResumedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public init(goal: Goal) { self.goal = goal }
}

public struct GoalAuditCompletedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var audit: GoalAuditSummary
    public var runID: ContinuationRunID
    public init(goal: Goal,
                audit: GoalAuditSummary,
                runID: ContinuationRunID) {
        self.goal = goal
        self.audit = audit
        self.runID = runID
    }
}

public struct GoalContinuationScheduledPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var runID: ContinuationRunID
    public init(goal: Goal, runID: ContinuationRunID) {
        self.goal = goal
        self.runID = runID
    }
}

public struct GoalProgressedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var runID: ContinuationRunID?
    public var progressSummary: String?
    public init(goal: Goal,
                runID: ContinuationRunID? = nil,
                progressSummary: String? = nil) {
        self.goal = goal
        self.runID = runID
        self.progressSummary = progressSummary
    }
}

public struct GoalBlockedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var blocker: String
    public init(goal: Goal, blocker: String) {
        self.goal = goal
        self.blocker = blocker
    }
}

public struct GoalBudgetLimitedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public init(goal: Goal) { self.goal = goal }
}

public struct GoalUsageLimitedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var reason: String?
    public init(goal: Goal, reason: String? = nil) {
        self.goal = goal
        self.reason = reason
    }
}

public struct GoalCompletedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var audit: GoalAuditSummary?
    public init(goal: Goal, audit: GoalAuditSummary? = nil) {
        self.goal = goal
        self.audit = audit
    }
}

/// `clear` removes the current-goal pointer; the supplied snapshot remains an
/// immutable audit fact and is retained in historical projections.
public struct GoalClearedPayload: Codable, Equatable, Sendable {
    public var goal: Goal
    public var reason: String?
    public init(goal: Goal, reason: String? = nil) {
        self.goal = goal
        self.reason = reason
    }
}

// MARK: - ContinuationRun events

public struct ContinuationRunCreatedPayload: Codable, Equatable, Sendable {
    public var run: ContinuationRun
    public init(run: ContinuationRun) { self.run = run }
}

public struct ContinuationRunStartedPayload: Codable, Equatable, Sendable {
    public var run: ContinuationRun
    public init(run: ContinuationRun) { self.run = run }
}

public struct ContinuationRunCheckpointedPayload: Codable, Equatable, Sendable {
    public var run: ContinuationRun
    public init(run: ContinuationRun) { self.run = run }
}

public struct ContinuationRunCompletedPayload: Codable, Equatable, Sendable {
    public var run: ContinuationRun
    public init(run: ContinuationRun) { self.run = run }
}

public struct ContinuationRunCancelledPayload: Codable, Equatable, Sendable {
    public var run: ContinuationRun
    public var reason: String
    public init(run: ContinuationRun, reason: String) {
        self.run = run
        self.reason = reason
    }
}

public struct ContinuationRunRecoveredPayload: Codable, Equatable, Sendable {
    public var run: ContinuationRun
    public var recoveredAt: Date
    public init(run: ContinuationRun, recoveredAt: Date = Date()) {
        self.run = run
        self.recoveredAt = recoveredAt
    }
}
