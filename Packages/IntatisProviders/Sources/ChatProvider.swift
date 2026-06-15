import Foundation
import IntatisCore

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// An image attached to a message (vision input). `url` is either a remote URL
/// or a `data:<mime>;base64,...` URL for a local file.
public struct ImageAttachment: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
    public static func base64(mime: String, base64: String) -> ImageAttachment {
        ImageAttachment(url: "data:\(mime);base64,\(base64)")
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: ChatRole
    public var content: String
    public var images: [ImageAttachment]
    public init(role: ChatRole, content: String, images: [ImageAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// Reasoning/thinking effort for reasoning models (OpenAI o-series / gpt-5 style
/// `reasoning_effort`). Sent on the wire only when set, so non-reasoning models
/// and endpoints that don't support it are unaffected.
public enum ReasoningEffort: String, Codable, Sendable {
    case minimal, low, medium, high
}

/// Token usage reported by the endpoint (when available).
public struct Usage: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct ChatRequest: Equatable, Sendable {
    public var model: ModelID
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var reasoningEffort: ReasoningEffort?
    /// Ask the endpoint to report token usage (OpenAI `stream_options.include_usage`).
    public var includeUsage: Bool
    public var stream: Bool
    public init(model: ModelID, messages: [ChatMessage], temperature: Double? = nil,
                reasoningEffort: ReasoningEffort? = nil, includeUsage: Bool = false, stream: Bool = true) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.stream = stream
    }
}

/// One piece of a streaming chat response.
public enum ChatChunk: Equatable, Sendable {
    case delta(String)
    case usage(Usage)
    case done
}

/// A model that can stream a chat completion. The only `Capability.chat` surface
/// v0.1 needs. Concrete adapters (e.g. `OpenAIWireProvider`) conform per wire.
public protocol ChatProvider: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
}

/// Transport seam so adapters are testable without a network. The real
/// implementation (`URLSessionStreamingClient`) lives in OpenAIWireProvider.swift;
/// tests inject a fake that replays canned bytes.
public protocol HTTPByteStreaming: Sendable {
    /// Performs `request` and yields the response body as it arrives. Each yielded
    /// `Data` is an arbitrary slice of the body — the SSE parser re-frames lines.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}
