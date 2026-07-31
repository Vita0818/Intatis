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

/// Distinguishes durable user-role items that look identical on the provider
/// wire but have different compaction lifecycles.
///
/// Legacy `model_history_item` records omit this field. A projector may treat a
/// missing classification on a user message as `realUser`; keeping the wire
/// field optional preserves exact decoding of those records.
public enum ModelHistoryMessageClassification: String, Codable, Equatable, Sendable {
    case realUser = "real_user"
    case contextual
    case compactionSummary = "compaction_summary"
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
    public var messageClassification: ModelHistoryMessageClassification?
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
        messageClassification: ModelHistoryMessageClassification? = nil,
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
        self.messageClassification = messageClassification
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
        attachmentIDs: [ArtifactID]? = nil,
        messageClassification: ModelHistoryMessageClassification? = nil
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
            messageClassification: messageClassification,
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

/// One provider-history item inside a full replacement-history checkpoint.
///
/// Unlike `ModelHistoryItemPayload`, this value deliberately has no durable
/// turn, task, agent, or attempt correlation. Compaction creates a synthetic
/// provider history whose user summary cannot truthfully inherit one earlier
/// invocation's task identity. The containing checkpoint scopes the array to
/// one agent.
public struct ModelHistoryReplacementItem: Codable, Equatable, Sendable {
    /// Stable item identity assigned before the checkpoint is persisted.
    public var itemID: String
    /// Optional provenance for retained real-user messages. Synthetic context
    /// and compaction summaries normally leave this nil.
    public var sourceSubmissionID: SubmissionID?
    public var kind: ModelHistoryItemKind

    public var role: ModelHistoryMessageRole?
    public var messageClassification: ModelHistoryMessageClassification?
    public var content: String?
    /// True only when compaction retained a UTF-8-safe newest suffix of one
    /// real user message. Nil/false means the content must exactly match its
    /// accepted durable submission.
    public var contentTruncated: Bool?
    public var attachmentIDs: [ArtifactID]?
    public var functionCalls: [ModelHistoryFunctionCall]?
    public var callID: String?
    public var output: String?
    public var toolSearchOutput: ModelToolSearchOutput?
    public var reasoningSummary: [String]?
    public var reasoningContent: String?
    public var encryptedReasoningContent: String?

    public init(
        itemID: String,
        sourceSubmissionID: SubmissionID? = nil,
        kind: ModelHistoryItemKind,
        role: ModelHistoryMessageRole? = nil,
        messageClassification: ModelHistoryMessageClassification? = nil,
        content: String? = nil,
        contentTruncated: Bool? = nil,
        attachmentIDs: [ArtifactID]? = nil,
        functionCalls: [ModelHistoryFunctionCall]? = nil,
        callID: String? = nil,
        output: String? = nil,
        toolSearchOutput: ModelToolSearchOutput? = nil,
        reasoningSummary: [String]? = nil,
        reasoningContent: String? = nil,
        encryptedReasoningContent: String? = nil
    ) {
        self.itemID = itemID
        self.sourceSubmissionID = sourceSubmissionID
        self.kind = kind
        self.role = role
        self.messageClassification = messageClassification
        self.content = content
        self.contentTruncated = contentTruncated
        self.attachmentIDs = attachmentIDs
        self.functionCalls = functionCalls
        self.callID = callID
        self.output = output
        self.toolSearchOutput = toolSearchOutput
        self.reasoningSummary = reasoningSummary
        self.reasoningContent = reasoningContent
        self.encryptedReasoningContent = encryptedReasoningContent
    }
}

public enum ModelHistoryCompactedPayloadValidationError:
    Error, Equatable, Sendable
{
    case unsupportedSchemaVersion(Int)
    case emptySummary
    case emptyReplacementHistory
    case unsupportedReplacementItemShape(index: Int)
    case invalidReplacementItemClassification(index: Int)
    case invalidRealUserProvenance(index: Int)
    case finalSummaryMismatch
    case nonCanonicalWindowID(field: String)
    case nonUUIDv7WindowID(field: String)
    case invalidInitialWindow
    case emptyReplacementItemID(index: Int)
    case duplicateReplacementItemID(itemID: String)
}

/// Durable full replacement-history checkpoint, mirroring Codex's compacted
/// rollout item while adding the agent identity required by Intatis's shared
/// multi-agent EventLog.
public struct ModelHistoryCompactedPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var agent: AgentID
    public var message: String
    public var replacementHistory: [ModelHistoryReplacementItem]
    public var windowNumber: UInt64
    public var firstWindowID: String
    public var previousWindowID: String
    public var windowID: String

    public init(
        schemaVersion: Int = ModelHistoryCompactedPayload.currentSchemaVersion,
        agent: AgentID,
        message: String,
        replacementHistory: [ModelHistoryReplacementItem],
        windowNumber: UInt64,
        firstWindowID: String,
        previousWindowID: String,
        windowID: String
    ) {
        self.schemaVersion = schemaVersion
        self.agent = agent
        self.message = message
        self.replacementHistory = replacementHistory
        self.windowNumber = windowNumber
        self.firstWindowID = firstWindowID
        self.previousWindowID = previousWindowID
        self.windowID = windowID
    }

    /// Validates the complete v1 checkpoint shape before it can become
    /// canonical history.
    ///
    /// A v1 replacement contains only user-role messages: retained real-user
    /// text, optional turn-scoped context, and one exact final compaction
    /// summary. Future replacement item shapes require a new schema version
    /// instead of being silently accepted by an older projector.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ModelHistoryCompactedPayloadValidationError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard !message.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            throw ModelHistoryCompactedPayloadValidationError.emptySummary
        }
        guard !replacementHistory.isEmpty else {
            throw ModelHistoryCompactedPayloadValidationError
                .emptyReplacementHistory
        }

        for (field, value) in [
            ("firstWindowID", firstWindowID),
            ("previousWindowID", previousWindowID),
            ("windowID", windowID),
        ] {
            guard let uuid = UUID(uuidString: value),
                  uuid.uuidString.lowercased() == value else {
                throw ModelHistoryCompactedPayloadValidationError
                    .nonCanonicalWindowID(field: field)
            }
            var raw = uuid.uuid
            let isUUIDv7 = withUnsafeBytes(of: &raw) {
                ($0[6] >> 4) == 0x7
                    && ($0[8] & 0b1100_0000) == 0b1000_0000
            }
            guard isUUIDv7 else {
                throw ModelHistoryCompactedPayloadValidationError
                    .nonUUIDv7WindowID(field: field)
            }
        }
        guard windowNumber > 0 else {
            throw ModelHistoryCompactedPayloadValidationError
                .invalidInitialWindow
        }
        if windowNumber == 1 {
            guard previousWindowID == firstWindowID,
                  windowID != firstWindowID else {
                throw ModelHistoryCompactedPayloadValidationError
                    .invalidInitialWindow
            }
        }

        var seenItemIDs: Set<String> = []
        for (index, item) in replacementHistory.enumerated() {
            guard !item.itemID.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
                throw ModelHistoryCompactedPayloadValidationError
                    .emptyReplacementItemID(index: index)
            }
            guard seenItemIDs.insert(item.itemID).inserted else {
                throw ModelHistoryCompactedPayloadValidationError
                    .duplicateReplacementItemID(itemID: item.itemID)
            }
            guard item.kind == .message,
                  item.role == .user,
                  item.content != nil,
                  item.functionCalls == nil,
                  item.callID == nil,
                  item.output == nil,
                  item.toolSearchOutput == nil,
                  item.reasoningSummary == nil,
                  item.reasoningContent == nil,
                  item.encryptedReasoningContent == nil else {
                throw ModelHistoryCompactedPayloadValidationError
                    .unsupportedReplacementItemShape(index: index)
            }

            let isFinal = index == replacementHistory.count - 1
            if isFinal {
                guard item.messageClassification == .compactionSummary,
                      item.content == message,
                      item.sourceSubmissionID == nil,
                      item.contentTruncated != true else {
                    throw ModelHistoryCompactedPayloadValidationError
                        .finalSummaryMismatch
                }
            } else {
                switch item.messageClassification {
                case .realUser:
                    guard let sourceSubmissionID =
                            item.sourceSubmissionID,
                          !sourceSubmissionID.rawValue
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty else {
                        throw ModelHistoryCompactedPayloadValidationError
                            .invalidRealUserProvenance(index: index)
                    }
                case .contextual:
                    guard item.sourceSubmissionID == nil,
                          item.contentTruncated != true else {
                        throw ModelHistoryCompactedPayloadValidationError
                            .invalidReplacementItemClassification(
                                index: index)
                    }
                case .compactionSummary, nil:
                    throw ModelHistoryCompactedPayloadValidationError
                        .invalidReplacementItemClassification(index: index)
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case agent
        case message
        case replacementHistory
        case windowNumber
        case firstWindowID
        case previousWindowID
        case windowID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        agent = try container.decode(AgentID.self, forKey: .agent)
        message = try container.decode(String.self, forKey: .message)
        replacementHistory = try container.decode(
            [ModelHistoryReplacementItem].self,
            forKey: .replacementHistory)
        windowNumber = try container.decode(UInt64.self, forKey: .windowNumber)
        firstWindowID = try container.decode(String.self, forKey: .firstWindowID)
        previousWindowID = try container.decode(
            String.self,
            forKey: .previousWindowID)
        windowID = try container.decode(String.self, forKey: .windowID)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .windowID,
                in: container,
                debugDescription:
                    "model history compaction payload is invalid")
        }
    }

    public func encode(to encoder: Encoder) throws {
        do {
            try validate()
        } catch {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "model history compaction payload is invalid"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(agent, forKey: .agent)
        try container.encode(message, forKey: .message)
        try container.encode(replacementHistory, forKey: .replacementHistory)
        try container.encode(windowNumber, forKey: .windowNumber)
        try container.encode(firstWindowID, forKey: .firstWindowID)
        try container.encode(previousWindowID, forKey: .previousWindowID)
        try container.encode(windowID, forKey: .windowID)
    }
}
