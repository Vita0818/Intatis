import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OpenAI wire DTOs (internal)

private struct OpenAIChatBody: Encodable {
    struct Msg: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Msg]
    let stream: Bool
    let temperature: Double?
    let reasoning_effort: String?
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
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
        if let delta = Self.parseDelta(payload), !delta.isEmpty {
            continuation.yield(.delta(delta))
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
        let body = OpenAIChatBody(
            model: request.model.rawValue,
            messages: request.messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: true,
            temperature: request.temperature,
            reasoning_effort: request.reasoningEffort?.rawValue
        )
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }

    static func parseDelta(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
            return nil
        }
        return chunk.choices.first?.delta.content
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
