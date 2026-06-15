import Foundation
import IntatisCore
import IntatisProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OpenAI wire DTOs (internal)

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    struct UsageDTO: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
    let choices: [Choice]
    let usage: UsageDTO?
}

// MARK: - Adapter

/// Maps Intatis chat requests onto the OpenAI-compatible `/chat/completions`
/// streaming wire. One conforming adapter for `WireFormat.openai`.
public struct OpenAIWireProvider: ChatProvider {
    // internal (not private) so the ToolCallingProvider conformance in
    // OpenAIToolCalling.swift can reuse endpoint/apiKey/http.
    let endpoint: ProviderEndpoint
    let apiKey: String
    let http: HTTPByteStreaming

    public init(endpoint: ProviderEndpoint, apiKey: String, http: HTTPByteStreaming) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)
                    let parser = SSEParser()
                    for try await chunk in http.stream(urlRequest) {
                        for payload in parser.consume(chunk) {
                            if emit(payload, to: continuation) { return }
                        }
                    }
                    for payload in parser.flush() {
                        if emit(payload, to: continuation) { return }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns true if the stream is finished (saw `[DONE]`).
    private func emit(_ payload: String, to continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) -> Bool {
        if payload == "[DONE]" {
            continuation.yield(.done)
            continuation.finish()
            return true
        }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
            return false
        }
        if let content = chunk.choices.first?.delta?.content, !content.isEmpty {
            continuation.yield(.delta(content))
        }
        if let u = chunk.usage {
            continuation.yield(.usage(Usage(promptTokens: u.prompt_tokens,
                                            completionTokens: u.completion_tokens,
                                            totalTokens: u.total_tokens)))
        }
        return false
    }

    func buildRequest(_ request: ChatRequest) throws -> URLRequest {
        let url = endpoint.baseURL.appendingPathComponent("chat/completions")
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var root: [String: JSONValue] = [
            "model": .string(request.model.rawValue),
            "messages": .array(request.messages.map(Self.chatMessageJSON)),
            "stream": .bool(true),
        ]
        if let t = request.temperature { root["temperature"] = .number(t) }
        if let reasoning = request.reasoningEffort { root["reasoning_effort"] = .string(reasoning.rawValue) }
        if request.includeUsage { root["stream_options"] = .object(["include_usage": .bool(true)]) }
        r.httpBody = try JSONEncoder().encode(JSONValue.object(root))
        return r
    }

    /// Encodes a message as a plain string, or as a content-parts array when it
    /// carries images (OpenAI vision format).
    static func chatMessageJSON(_ m: ChatMessage) -> JSONValue {
        if m.images.isEmpty {
            return .object(["role": .string(m.role.rawValue), "content": .string(m.content)])
        }
        var parts: [JSONValue] = []
        if !m.content.isEmpty {
            parts.append(.object(["type": .string("text"), "text": .string(m.content)]))
        }
        for image in m.images {
            parts.append(.object(["type": .string("image_url"),
                                  "image_url": .object(["url": .string(image.url)])]))
        }
        return .object(["role": .string(m.role.rawValue), "content": .array(parts)])
    }
}

// MARK: - Real transport (Apple platforms)

/// URLSession-backed byte streaming. Used at runtime on macOS; on Linux (where
/// `URLSession.bytes(for:)` is unavailable) it reports unsupported — tests never
/// hit it because they inject a fake `HTTPByteStreaming`.
public struct URLSessionStreamingClient: HTTPByteStreaming {
    public init() {}

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(Darwin)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: IntatisError.provider("HTTP \(http.statusCode)"))
                        return
                    }
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: IntatisError.provider("Streaming HTTP is unavailable on this platform"))
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
