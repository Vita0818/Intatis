import Foundation
import IntatisCore

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: ChatRole
    public var content: String
    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Equatable, Sendable {
    public var model: ModelID
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var stream: Bool
    public init(model: ModelID, messages: [ChatMessage], temperature: Double? = nil, stream: Bool = true) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.stream = stream
    }
}

/// One piece of a streaming chat response.
public enum ChatChunk: Equatable, Sendable {
    case delta(String)
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
