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
    public let toolCallingCapabilities:
        ToolCallingProviderCapabilities

    public init(endpoint: ProviderEndpoint,
                apiKey: String,
                http: HTTPByteStreaming,
                runtimePolicy: ProviderRuntimePolicy = .streaming,
                toolCallingCapabilities:
                    ToolCallingProviderCapabilities =
                        .chatCompletionsOnly) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
        self.runtimePolicy = runtimePolicy
        self.toolCallingCapabilities =
            toolCallingCapabilities
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
        let requestAdapter =
            endpoint.requestAdapter(for: request.model)
        var root = try Self.configuredRequestBody(
            endpoint: endpoint,
            model: request.model)
        root["model"] = .string(request.model.rawValue)
        root["messages"] = .array(request.messages.map(Self.chatMessageJSON))
        root["stream"] = .bool(true)
        try Self.applyChatCompletionsInvocationControls(
            to: &root,
            requestAdapter: requestAdapter)
        if let t = request.temperature { root["temperature"] = .number(t) }
        Self.applyChatCompletionsReasoningOptions(
            to: &root,
            runtimeEffort: request.reasoningEffort,
            requestAdapter: requestAdapter)
        if request.includeUsage { root["stream_options"] = .object(["include_usage": .bool(true)]) }
        r.httpBody = try Self.encodeRequestBody(root)
        return r
    }

    /// Model options are an open JSON extension point. Intatis protects only
    /// the structural fields that must match the actual runtime request.
    /// Unknown keys remain verbatim. Known provider SDK options are lowered by
    /// the exact package adapter frozen for the selected model.
    static func configuredRequestBody(endpoint: ProviderEndpoint,
                                      model: ModelID)
        throws -> [String: JSONValue]
    {
        var body = endpoint.requestOptions(for: model)
        for key in [
            "model", "messages", "tools", "stream",
            "stream_options",
            "n", "best_of", "num_return_sequences", "candidate_count",
        ] {
            body.removeValue(forKey: key)
        }
        try applyConfiguredChatCompletionsOptions(
            to: &body,
            requestAdapter:
                endpoint.requestAdapter(for: model))
        return body
    }

    /// Applies only controls that the selected package adapter would synthesize
    /// for this invocation. The pinned OpenCode adapters do not send `n`, and
    /// neither turns parallel-safe tool metadata into `parallel_tool_calls`.
    /// Historical Intatis endpoints retain their previous wire behavior.
    static func applyChatCompletionsInvocationControls(
        to body: inout [String: JSONValue],
        requestAdapter: ProviderRequestAdapter,
        parallelToolCalls: Bool? = nil
    ) throws {
        switch try requestAdapter
            .chatCompletionsAdapter()
        {
        case .legacyOpenAIWire:
            body["n"] = .number(1)
            if let parallelToolCalls {
                body["parallel_tool_calls"] =
                    .bool(parallelToolCalls)
            }

        case .openAICompatible,
             .openRouter:
            // @ai-sdk/openai-compatible@2.0.41 omits both fields.
            // @openrouter/ai-sdk-provider@2.9.0 also omits `n` and
            // emits parallel_tool_calls only from explicit model settings,
            // not from call-level tool metadata. Any explicitly configured
            // wire option has already been lowered into `body` above.
            return
        }
    }

    /// Mirrors the package-specific option boundary used by OpenCode. The
    /// configuration remains untouched; only this request-owned body is
    /// lowered. This is deliberately not a global camel/snake normalizer.
    private static func applyConfiguredChatCompletionsOptions(
        to body: inout [String: JSONValue],
        requestAdapter: ProviderRequestAdapter
    ) throws {
        switch try requestAdapter
            .chatCompletionsAdapter()
        {
        case .legacyOpenAIWire:
            return

        case .openAICompatible:
            // @ai-sdk/openai-compatible@2.0.41 treats these camelCase names as
            // SDK options. The explicit wire properties are written after its
            // unknown-option spread, so an absent camelCase value also removes
            // a same-named raw-wire alias from the final JSON.
            let reasoningEffort =
                body.removeValue(
                    forKey: "reasoningEffort")
            body.removeValue(
                forKey: "reasoning_effort")
            if let reasoningEffort {
                guard case .string = reasoningEffort else {
                    throw IntatisError.config(
                        "reasoningEffort must be a string for the selected provider adapter")
                }
                body["reasoning_effort"] =
                    reasoningEffort
            }

            let textVerbosity =
                body.removeValue(
                    forKey: "textVerbosity")
            body.removeValue(forKey: "verbosity")
            if let textVerbosity {
                guard case .string = textVerbosity else {
                    throw IntatisError.config(
                        "textVerbosity must be a string for the selected provider adapter")
                }
                body["verbosity"] = textVerbosity
            }

            if let strictJSONSchema =
                body.removeValue(
                    forKey: "strictJsonSchema") {
                guard case .bool = strictJSONSchema else {
                    throw IntatisError.config(
                        "strictJsonSchema must be a boolean for the selected provider adapter")
                }
                // This option controls SDK-side response-format construction;
                // it is never itself a wire field.
            }

            if let user = body["user"],
               case .string = user {
                // Recognized by the SDK and emitted with the same wire name.
            } else if body["user"] != nil {
                throw IntatisError.config(
                    "user must be a string for the selected provider adapter")
            }

        case .openRouter:
            // The OpenRouter SDK spreads provider options without translating
            // reasoningEffort. Its one compatibility alias in this boundary is
            // cacheControl -> cache_control.
            if let cacheControl =
                body.removeValue(
                    forKey: "cacheControl"),
               cacheControl != .null,
               body["cache_control"] == nil {
                body["cache_control"] =
                    cacheControl
            }
        }
    }

    /// Runtime reasoning remains host-owned, but its wire shape is chosen by
    /// the frozen package adapter instead of by endpoint-name heuristics.
    static func applyChatCompletionsReasoningOptions(
        to body: inout [String: JSONValue],
        runtimeEffort: ReasoningEffort?,
        requestAdapter: ProviderRequestAdapter
    ) {
        guard let runtimeEffort else {
            return
        }
        switch try? requestAdapter
            .chatCompletionsAdapter()
        {
        case .openRouter:
            var reasoning: [String: JSONValue] = [:]
            if case .object(let configured)? =
                body["reasoning"] {
                reasoning = configured
            }
            reasoning["effort"] =
                .string(runtimeEffort.rawValue)
            body["reasoning"] = .object(reasoning)

        case .legacyOpenAIWire,
             .openAICompatible:
            body["reasoning_effort"] =
                .string(runtimeEffort.rawValue)

        case nil:
            // Unsupported adapters were rejected while lowering configured
            // options, before this host overlay is reached.
            return
        }
    }

    /// Responses uses the nested `reasoning.effort` shape. Normalize both the
    /// Chat Completions shorthand and the SDK-only camelCase alias at this wire
    /// boundary while preserving unrelated nested reasoning options.
    static func applyResponsesReasoningOptions(
        to body: inout [String: JSONValue],
        runtimeEffort: ReasoningEffort?
    ) {
        let sdkAlias =
            body.removeValue(forKey: "reasoningEffort")
        let chatCompletionsAlias =
            body.removeValue(forKey: "reasoning_effort")

        if let runtimeEffort {
            var reasoning: [String: JSONValue] = [:]
            if case .object(let configured)? =
                body["reasoning"] {
                reasoning = configured
            }
            reasoning["effort"] =
                .string(runtimeEffort.rawValue)
            body["reasoning"] = .object(reasoning)
            return
        }

        let compatibleEffort =
            chatCompletionsAlias ?? sdkAlias
        guard let compatibleEffort else { return }

        if case .object(var reasoning)? =
            body["reasoning"] {
            if reasoning["effort"] == nil {
                reasoning["effort"] = compatibleEffort
                body["reasoning"] = .object(reasoning)
            }
        } else if body["reasoning"] == nil {
            body["reasoning"] = .object([
                "effort": compatibleEffort,
            ])
        }
    }

    /// Provider request bodies are compared, cached, and audited as bytes in
    /// addition to being interpreted as JSON. Sorting every keyed container
    /// makes equivalent request bodies deterministic without narrowing the
    /// open provider-options extension point.
    static func encodeRequestBody(
        _ body: [String: JSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(body))
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
