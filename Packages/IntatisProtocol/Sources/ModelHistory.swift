import Foundation
import IntatisCore

/// Durable model-facing history, separate in meaning from UI/audit events.
///
/// These records preserve the ordered items needed to build a later provider
/// request. Display events may remain bounded or redacted independently.
public enum ModelHistoryItemKind: String, Codable, Equatable, Sendable {
    case message
    case functionCallBatch = "function_call_batch"
    case functionCallOutput = "function_call_output"
    case reasoning
}

public enum ModelHistoryMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public struct ModelHistoryFunctionCall: Codable, Equatable, Sendable {
    public var callID: String
    public var name: String
    /// The JSON argument string that may be sent back to the provider.
    /// Sensitive calls use a fixed valid placeholder instead of raw input.
    public var arguments: String
    public var argumentsRedacted: Bool

    public init(
        callID: String,
        name: String,
        arguments: String,
        argumentsRedacted: Bool = false
    ) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.argumentsRedacted = argumentsRedacted
    }
}

public struct ModelHistoryItemPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var itemID: String
    public var turnID: TurnID
    public var agent: AgentID
    public var taskID: TaskID?
    public var submissionID: SubmissionID?
    public var taskAttempt: Int?
    public var kind: ModelHistoryItemKind

    public var role: ModelHistoryMessageRole?
    public var content: String?
    public var attachmentIDs: [ArtifactID]?
    public var functionCalls: [ModelHistoryFunctionCall]?
    public var callID: String?
    public var output: String?
    public var reasoningSummary: [String]?
    public var reasoningContent: String?
    public var encryptedReasoningContent: String?

    public init(
        schemaVersion: Int = ModelHistoryItemPayload.currentSchemaVersion,
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID? = nil,
        submissionID: SubmissionID? = nil,
        taskAttempt: Int? = nil,
        kind: ModelHistoryItemKind,
        role: ModelHistoryMessageRole? = nil,
        content: String? = nil,
        attachmentIDs: [ArtifactID]? = nil,
        functionCalls: [ModelHistoryFunctionCall]? = nil,
        callID: String? = nil,
        output: String? = nil,
        reasoningSummary: [String]? = nil,
        reasoningContent: String? = nil,
        encryptedReasoningContent: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.turnID = turnID
        self.agent = agent
        self.taskID = taskID
        self.submissionID = submissionID
        self.taskAttempt = taskAttempt
        self.kind = kind
        self.role = role
        self.content = content
        self.attachmentIDs = attachmentIDs
        self.functionCalls = functionCalls
        self.callID = callID
        self.output = output
        self.reasoningSummary = reasoningSummary
        self.reasoningContent = reasoningContent
        self.encryptedReasoningContent = encryptedReasoningContent
    }

    public static func message(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        role: ModelHistoryMessageRole,
        content: String,
        attachmentIDs: [ArtifactID]? = nil
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .message,
            role: role,
            content: content,
            attachmentIDs: attachmentIDs)
    }

    public static func functionCallBatch(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        content: String?,
        calls: [ModelHistoryFunctionCall]
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .functionCallBatch,
            content: content,
            functionCalls: calls)
    }

    public static func functionCallOutput(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        callID: String,
        output: String
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .functionCallOutput,
            callID: callID,
            output: output)
    }
}
