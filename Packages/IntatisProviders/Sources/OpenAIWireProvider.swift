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
        let finish_reason: String?
    }
    struct UsageDTO: Decodable {
        struct PromptTokensDetailsDTO: Decodable {
            let cached_tokens: Int?
        }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: PromptTokensDetailsDTO?

        var usage: Usage {
            Usage(promptTokens: prompt_tokens,
                  cachedPromptTokens: prompt_tokens_details?.cached_tokens,
                  completionTokens: completion_tokens,
                  totalTokens: total_tokens)
        }
    }
    let choices: [Choice]?
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
    let runtimePolicy: ProviderRuntimePolicy

    public init(endpoint: ProviderEndpoint,
                apiKey: String,
                http: HTTPByteStreaming,
                runtimePolicy: ProviderRuntimePolicy = .streaming) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
        self.runtimePolicy = runtimePolicy
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)
                    var attempt = 1
                    while true {
                        let parser = SSEParser()
                        var receivedResponseBytes = false
                        var sawCompletion = false
                        do {
                            for try await chunk in http.stream(urlRequest) {
                                receivedResponseBytes = true
                                for payload in parser.consume(chunk) {
                                    if try emit(payload, to: continuation, sawCompletion: &sawCompletion) {
                                        return
                                    }
                                }
                            }
                            for payload in parser.flush() {
                                if try emit(payload, to: continuation, sawCompletion: &sawCompletion) {
                                    return
                                }
                            }
                            guard sawCompletion else {
                                continuation.finish(throwing: ProviderErrorFormatting.incompleteStream(
                                    operation: "streaming request"))
                                return
                            }
                            continuation.finish()
                            return
                        } catch {
                            if ProviderRuntime.shouldRetry(error: error,
                                                           attempt: attempt,
                                                           policy: runtimePolicy,
                                                           receivedResponseBytes: receivedResponseBytes) {
                                attempt += 1
                                try await ProviderRuntime.sleepBeforeRetry(
                                    nextAttempt: attempt,
                                    policy: runtimePolicy,
                                    retryHint: ProviderErrorFormatting.retryHint(from: error))
                                continue
                            }
                            continuation.finish(throwing: ProviderRuntime.exhausted(
                                error,
                                attempts: attempt,
                                operation: "streaming request"))
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: ProviderErrorFormatting.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns true if the stream is finished (saw `[DONE]`).
    private func emit(_ payload: String,
                      to continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation,
                      sawCompletion: inout Bool) throws -> Bool {
        if payload == "[DONE]" {
            if !sawCompletion {
                continuation.yield(.done)
                sawCompletion = true
            }
            continuation.finish()
            return true
        }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }
        if let providerError = ProviderErrorFormatting.streamErrorPayload(data) {
            throw providerError
        }
        let chunk: OpenAIStreamChunk
        do {
            chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
        } catch {
            throw ProviderErrorFormatting.invalidStreamPayload(trimmed, underlying: error)
        }
        if let choices = chunk.choices {
            for choice in choices {
                if let content = choice.delta?.content, !content.isEmpty {
                    continuation.yield(.delta(content))
                }
            }
            if choices.contains(where: { $0.finish_reason != nil }), !sawCompletion {
                continuation.yield(.done)
                sawCompletion = true
            }
        }
        if let u = chunk.usage {
            continuation.yield(.usage(u.usage))
        }
        return false
    }

    func buildRequest(_ request: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: try endpoint.validatedChatCompletionsURL(operation: "streaming request"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        var root = Self.configuredRequestBody(endpoint: endpoint, model: request.model)
        root["model"] = .string(request.model.rawValue)
        root["messages"] = .array(request.messages.map(Self.chatMessageJSON))
        root["stream"] = .bool(true)
        root["n"] = .number(1)
        if let t = request.temperature { root["temperature"] = .number(t) }
        if let reasoning = request.reasoningEffort { root["reasoning_effort"] = .string(reasoning.rawValue) }
        if request.includeUsage { root["stream_options"] = .object(["include_usage": .bool(true)]) }
        r.httpBody = try JSONEncoder().encode(JSONValue.object(root))
        return r
    }

    /// Model options are an open JSON extension point. Intatis protects only
    /// the structural fields that must match the actual runtime request; every
    /// other key is preserved verbatim for the selected wire endpoint.
    static func configuredRequestBody(endpoint: ProviderEndpoint,
                                      model: ModelID) -> [String: JSONValue] {
        var body = endpoint.requestOptions(for: model)
        for key in [
            "model", "messages", "tools", "stream", "stream_options",
            "n", "best_of", "num_return_sequences", "candidate_count",
        ] {
            body.removeValue(forKey: key)
        }
        return body
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
                    let (bytes, response) = try await ProviderURLSession.noRedirect.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let body = try await ProviderErrorFormatting.cappedBody(from: bytes)
                        continuation.finish(throwing: ProviderErrorFormatting.httpStatus(
                            http.statusCode,
                            body: body,
                            headers: HTTPDataResponse.headers(from: http),
                            operation: "streaming request"))
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
