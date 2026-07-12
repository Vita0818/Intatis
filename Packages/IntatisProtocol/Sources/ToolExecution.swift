import Foundation
import IntatisCore

/// Recovery contract for a tool execution that was prepared durably before the
/// executor was invoked. The default is deliberately conservative: only
/// read-only tools are replayable, and collaboration/lifecycle tools require
/// reconciliation even when an older descriptor classified them as read-only.
public enum ToolExecutionReplayPolicy: String, Codable, Equatable, Sendable {
    case safeToReplay = "safe_to_replay"
    case requiresManualReconciliation = "requires_manual_reconciliation"

    public static func conservative(for sideEffect: SideEffect,
                                    tool: String) -> ToolExecutionReplayPolicy {
        guard sideEffect == .readOnly,
              !manualReconciliationToolNames.contains(tool) else {
            return .requiresManualReconciliation
        }
        return .safeToReplay
    }

    private static let manualReconciliationToolNames: Set<String> = [
        "ask_agent",
        "send_message",
        "request_information",
        "reply_message",
        "request_delegation",
        "delegate_task",
        "spawn_agent",
        "remove_agent",
    ]
}

public enum ToolExecutionOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case denied
}

/// Written immediately before invoking a tool executor. A prepared event with
/// no matching settled event is evidence that a crash may have interrupted an
/// execution. Callers must consult `replayPolicy` before retrying the task.
public struct ToolExecutionPreparedPayload: Codable, Equatable, Sendable {
    public var executionID: String
    public var taskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String
    public var agent: AgentID?
    public var tool: String
    public var sideEffect: SideEffect
    public var replayPolicy: ToolExecutionReplayPolicy

    public init(executionID: String,
                taskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String,
                agent: AgentID? = nil,
                tool: String,
                sideEffect: SideEffect,
                replayPolicy: ToolExecutionReplayPolicy? = nil) {
        self.executionID = executionID
        self.taskID = taskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.agent = agent
        self.tool = tool
        self.sideEffect = sideEffect
        self.replayPolicy = replayPolicy ?? .conservative(for: sideEffect, tool: tool)
    }

    /// A durable prepare record is the point after which the executor may have
    /// run. Replaying the *whole task* would therefore repeat this call even
    /// when a later settled record proves that the call succeeded. Only tools
    /// explicitly classified as safe-to-replay may be crossed by task replay.
    public var requiresTaskReplayReconciliation: Bool {
        replayPolicy == .requiresManualReconciliation
    }
}

/// Written after the tool result has been made durable. Metadata is repeated so
/// a replay remains diagnosable even if a damaged log is missing the prepare
/// record; normal logs still pair records by `executionID`.
public struct ToolExecutionSettledPayload: Codable, Equatable, Sendable {
    public var executionID: String
    public var taskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String
    public var agent: AgentID?
    public var tool: String
    public var sideEffect: SideEffect
    public var replayPolicy: ToolExecutionReplayPolicy
    public var outcome: ToolExecutionOutcome
    public var reason: String?

    public init(executionID: String,
                taskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String,
                agent: AgentID? = nil,
                tool: String,
                sideEffect: SideEffect,
                replayPolicy: ToolExecutionReplayPolicy? = nil,
                outcome: ToolExecutionOutcome,
                reason: String? = nil) {
        self.executionID = executionID
        self.taskID = taskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.agent = agent
        self.tool = tool
        self.sideEffect = sideEffect
        self.replayPolicy = replayPolicy ?? .conservative(for: sideEffect, tool: tool)
        self.outcome = outcome
        self.reason = reason
    }

    public init(prepared: ToolExecutionPreparedPayload,
                outcome: ToolExecutionOutcome,
                reason: String? = nil) {
        self.init(
            executionID: prepared.executionID,
            taskID: prepared.taskID,
            attempt: prepared.attempt,
            toolCallID: prepared.toolCallID,
            agent: prepared.agent,
            tool: prepared.tool,
            sideEffect: prepared.sideEffect,
            replayPolicy: prepared.replayPolicy,
            outcome: outcome,
            reason: reason)
    }

    public var prepared: ToolExecutionPreparedPayload {
        ToolExecutionPreparedPayload(
            executionID: executionID,
            taskID: taskID,
            attempt: attempt,
            toolCallID: toolCallID,
            agent: agent,
            tool: tool,
            sideEffect: sideEffect,
            replayPolicy: replayPolicy)
    }
}
