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
    case toolSearchOutput = "tool_search_output"
    case reasoning
}

public enum ModelHistoryMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public enum ModelHistoryCallKind: String, Codable, Equatable, Sendable {
    case function
    case toolSearch = "tool_search"
}

public struct ModelHistoryFunctionCall: Codable, Equatable, Sendable {
    public var callID: String
    public var name: String
    /// The JSON argument string that may be sent back to the provider.
    /// Sensitive calls use a fixed valid placeholder instead of raw input.
    public var arguments: String
    public var argumentsRedacted: Bool
    /// Provider-native call kind. Missing values in v1 history decode as the
    /// historical function-call shape.
    public var kind: ModelHistoryCallKind
    /// Responses namespace for a deferred function. The execution registry
    /// continues to use `name` as its exact flat routing key.
    public var namespace: String?
    public var status: String?
    public var execution: String?

    public init(
        callID: String,
        name: String,
        arguments: String,
        argumentsRedacted: Bool = false,
        kind: ModelHistoryCallKind = .function,
        namespace: String? = nil,
        status: String? = nil,
        execution: String? = nil
    ) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.argumentsRedacted = argumentsRedacted
        self.kind = kind
        self.namespace = namespace
        self.status = status
        self.execution = execution
    }

    private enum CodingKeys: String, CodingKey {
        case callID
        case name
        case arguments
        case argumentsRedacted
        case kind
        case namespace
        case status
        case execution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(String.self, forKey: .callID)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decode(String.self, forKey: .arguments)
        argumentsRedacted = try container.decodeIfPresent(
            Bool.self,
            forKey: .argumentsRedacted) ?? false
        kind = try container.decodeIfPresent(
            ModelHistoryCallKind.self,
            forKey: .kind) ?? .function
        namespace = try container.decodeIfPresent(
            String.self,
            forKey: .namespace)
        status = try container.decodeIfPresent(
            String.self,
            forKey: .status)
        execution = try container.decodeIfPresent(
            String.self,
            forKey: .execution)
    }
}

/// Provider-neutral payload for a Responses `tool_search_output` input item.
///
/// The returned deferred tool definitions belong to history, not the next
/// request's top-level `tools` array. This is the contract used by Codex to
/// make searched tools callable without widening subsequent tool exposure.
public struct ModelToolSearchOutput: Codable, Equatable, Sendable {
    public var status: String
    public var execution: String
    public var tools: [JSONValue]

    public init(
        status: String = "completed",
        execution: String = "client",
        tools: [JSONValue]
    ) {
        self.status = status
        self.execution = execution
        self.tools = tools
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
    public var toolSearchOutput: ModelToolSearchOutput?
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
        toolSearchOutput: ModelToolSearchOutput? = nil,
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
        self.toolSearchOutput = toolSearchOutput
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

    public static func toolSearchOutput(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        callID: String,
        status: String = "completed",
        execution: String = "client",
        tools: [JSONValue]
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .toolSearchOutput,
            callID: callID,
            toolSearchOutput: ModelToolSearchOutput(
                status: status,
                execution: execution,
                tools: tools))
    }
}
