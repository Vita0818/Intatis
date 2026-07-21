import Foundation
import IntatisCore
import IntatisProtocol

/// A tool the model may call. `parameters` is a JSON-Schema object.
public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A fully-assembled tool call from the model.
public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String   // raw JSON string
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum AgentRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// A message in the tool-calling conversation. Assistant messages may carry
/// `toolCalls`; tool messages carry `toolCallId` + the observation as `content`.
public struct AgentMessage: Equatable, Sendable {
    public var role: AgentRole
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var images: [ImageAttachment]

    public init(role: AgentRole, content: String? = nil,
                toolCalls: [ToolCall]? = nil, toolCallId: String? = nil,
                images: [ImageAttachment] = []) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.images = images
    }

    public static func system(_ text: String) -> AgentMessage { .init(role: .system, content: text) }
    public static func user(_ text: String, images: [ImageAttachment] = []) -> AgentMessage {
        .init(role: .user, content: text, images: images)
    }
    public static func assistant(_ text: String) -> AgentMessage { .init(role: .assistant, content: text) }
    public static func assistant(toolCalls: [ToolCall], content: String? = nil) -> AgentMessage {
        .init(role: .assistant, content: content, toolCalls: toolCalls)
    }
    public static func tool(id: String, content: String) -> AgentMessage {
        .init(role: .tool, content: content, toolCallId: id)
    }
}

public struct AgentRequest: Sendable {
    public var model: ModelID
    public var messages: [AgentMessage]
    public var tools: [ToolSpec]
    public var temperature: Double?
    public var reasoningEffort: ReasoningEffort?
    public var includeUsage: Bool
    /// Best-effort provider-side output ceiling. OpenAI-compatible providers map
    /// this to `max_tokens`; providers that do not support a ceiling may ignore it,
    /// so callers must still account the reported/estimated total after the stream.
    public var maxOutputTokens: Int?
    public init(model: ModelID, messages: [AgentMessage], tools: [ToolSpec],
                temperature: Double? = nil,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxOutputTokens: Int? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxOutputTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// One piece of a streaming tool-calling response.
public enum AgentChunk: Equatable, Sendable {
    case textDelta(String)
    case toolCalls([ToolCall])
    case usage(Usage)
    case done(finishReason: String?)
}

/// A model that supports tool/function calling (`Capability.tool_calling`).
public protocol ToolCallingProvider: Sendable {
    /// Must return a request-owned stream promptly. Implementations perform
    /// network/blocking work in the stream producer, keep continuations scoped
    /// to this request, and propagate consumer termination to that producer.
    /// Synchronously blocking this method is outside the provider contract.
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error>
}
