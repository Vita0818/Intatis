import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private struct FakeHTTP: HTTPByteStreaming {
    let chunks: [Data]
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct DelayedHTTP: HTTPByteStreaming {
    let delayNanoseconds: UInt64
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StreamAttempt {
    var chunks: [Data]
    var error: Error?
}

private final class SequencedHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.sequenced-http")
    private var index = 0
    private let attempts: [StreamAttempt]

    init(attempts: [StreamAttempt]) {
        self.attempts = attempts
    }

    var attemptCount: Int {
        queue.sync { index }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let attempt = queue.sync { () -> StreamAttempt in
            let value = attempts[min(index, attempts.count - 1)]
            index += 1
            return value
        }
        return AsyncThrowingStream { continuation in
            for chunk in attempt.chunks {
                continuation.yield(chunk)
            }
            if let error = attempt.error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

private final class CapturingHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.capturing-http")
    private let chunks: [Data]
    private var requests: [URLRequest] = []
    private var requestBodies: [Data] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    var lastBody: Data? {
        queue.sync { requestBodies.last }
    }

    var lastRequest: URLRequest? {
        queue.sync { requests.last }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        queue.sync {
            requests.append(request)
            requestBodies.append(request.httpBody ?? Data())
        }
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private struct StaticSecret: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}

private let openAIEndpoint = ProviderEndpoint(id: "e",
                                              baseURL: URL(string: "https://example.test/v1")!,
                                              apiKeyRef: KeychainRef(service: "s", account: "a"),
                                              wire: .openai)

private let nonHTTPChatEndpoint = ProviderEndpoint(id: "bad-chat",
                                                   baseURL: URL(string: "https://example.test/v1")!,
                                                   chatEndpoint: URL(fileURLWithPath: "/tmp/intatis-chat"),
                                                   apiKeyRef: KeychainRef(service: "s", account: "a"),
                                                   wire: .openai)

final class IntatisProvidersTests: XCTestCase {

    func testSSEParserReassemblesAcrossArbitraryChunks() {
        let parser = SSEParser()
        let raw = "data: {\"a\":1}\n\ndata: [DONE]\n\n"
        let bytes = Array(raw.utf8)
        var events: [String] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 3, bytes.count)
            events += parser.consume(Data(bytes[i..<end]))
            i = end
        }
        events += parser.flush()
        XCTAssertEqual(events, ["{\"a\":1}", "[DONE]"])
    }

    func testOpenAIStreamingYieldsDeltasThenDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"He"}}]}

        data: {"choices":[{"delta":{"content":"llo"}}]}

        data: [DONE]

        """
        // Fragment into tiny chunks to prove cross-chunk buffering is correct.
        let bytes = Array(sse.utf8)
        var chunks: [Data] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 5, bytes.count)
            chunks.append(Data(bytes[i..<end]))
            i = end
        }
        let endpoint = ProviderEndpoint(id: "e",
                                        baseURL: URL(string: "https://example.test/v1")!,
                                        apiKeyRef: KeychainRef(service: "s", account: "a"),
                                        wire: .openai)
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP(chunks: chunks))
        var text = ""
        var sawDone = false
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "gpt-x"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            switch chunk {
            case .delta(let d): text += d
            case .usage: break
            case .done: sawDone = true
            }
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(sawDone)
    }

    func testOpenAIStreamingNormalizesBearerAPIKeyInAuthorizationHeader() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: " \"Bearer valid-token\" ",
                                          http: http)

        for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                       messages: [ChatMessage(role: .user, content: "hi")])) {}

        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer valid-token")
        XCTAssertEqual(ProviderAuthorization.bearerHeaderValue(apiKey: "'Bearer valid-token'"),
                       "Bearer valid-token")
    }

    func testOpenAIStreamingParsesUsage() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"hi"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14,"prompt_tokens_details":{"cached_tokens":4}}}

        data: [DONE]

        """
        let bytes = Array(sse.utf8)
        var chunks: [Data] = []
        var i = 0
        while i < bytes.count { let e = min(i + 9, bytes.count); chunks.append(Data(bytes[i..<e])); i = e }
        let endpoint = ProviderEndpoint(id: "e", baseURL: URL(string: "https://example.test/v1")!,
                                        apiKeyRef: KeychainRef(service: "s", account: "a"), wire: .openai)
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP(chunks: chunks))
        var usage: Usage?
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")],
                                                           includeUsage: true)) {
            if case .usage(let u) = chunk { usage = u }
        }
        XCTAssertEqual(usage?.promptTokens, 11)
        XCTAssertEqual(usage?.cachedPromptTokens, 4)
        XCTAssertEqual(usage?.completionTokens, 3)
        XCTAssertEqual(usage?.totalTokens, 14)
    }

    func testOpenAIStreamingTreatsFinishReasonAsDoneWithoutDoneMarker() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var text = ""
        var doneCount = 0
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            switch chunk {
            case .delta(let value):
                text += value
            case .usage:
                break
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(text, "OK")
        XCTAssertEqual(doneCount, 1)
    }

    func testOpenAIStreamingReadsContentAndFinishFromNonFirstChoice() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{}},{"index":1,"delta":{"content":"OK"},"finish_reason":"stop"}]}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var text = ""
        var doneCount = 0
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            switch chunk {
            case .delta(let value):
                text += value
            case .usage:
                break
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(text, "OK")
        XCTAssertEqual(doneCount, 1)
    }

    func testOpenAIStreamingKeepsUsageAfterFinishReasonAndDoesNotDuplicateDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}

        data: [DONE]

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var usage: Usage?
        var doneCount = 0
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")],
                                                           includeUsage: true)) {
            switch chunk {
            case .delta:
                break
            case .usage(let value):
                usage = value
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(doneCount, 1)
        XCTAssertEqual(usage?.promptTokens, 5)
        XCTAssertEqual(usage?.completionTokens, 1)
        XCTAssertEqual(usage?.totalTokens, 6)
    }

    func testOpenAIStreamingThrowsWhenCompletionMarkerMissing() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var text = ""
        do {
            for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                               messages: [ChatMessage(role: .user, content: "hi")])) {
                switch chunk {
                case .delta(let value):
                    text += value
                case .usage:
                    break
                case .done:
                    XCTFail("unexpected done for incomplete stream")
                }
            }
            XCTFail("expected incomplete stream error")
        } catch {
            XCTAssertEqual(text, "partial")
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }
    }

    func testOpenAIStreamingRejectsNonHTTPChatEndpointBeforeTransport() async {
        let provider = OpenAIWireProvider(
            endpoint: nonHTTPChatEndpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: [Data("data: [DONE]\n\n".utf8)]))

        do {
            for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {}
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-chat'"))
            XCTAssertTrue(error.localizedDescription.contains("Chat endpoint scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("http:// or https://"))
        }
    }

    func testProviderHTTPErrorIncludesStatusGuidanceAndProviderMessage() {
        let body = Data(#"{"error":{"message":"bad API key","type":"auth","code":"invalid_key"}}"#.utf8)
        let error = ProviderErrorFormatting.httpStatus(401, body: body, operation: "streaming request")

        XCTAssertTrue(error.localizedDescription.contains("HTTP 401 Unauthorized"))
        XCTAssertTrue(error.localizedDescription.contains("Check the API key"))
        XCTAssertTrue(error.localizedDescription.contains("bad API key"))
        XCTAssertTrue(error.localizedDescription.contains("code=invalid_key"))
    }

    func testProviderDiagnosticsRedactEchoedAuthorizationBeforePersistence() {
        let secret = "opaque-credential-that-must-not-survive"
        let body = Data(
            #"{"error":{"message":"Authorization: Bearer \#(secret)","type":"auth"}}"#.utf8)
        let httpError = ProviderErrorFormatting.httpStatus(
            401,
            body: body,
            operation: "streaming request")
        let streamError = ProviderErrorFormatting.streamErrorPayload(body)
        let usageError = ProviderUsageLimitError(
            signal: "insufficient_quota",
            providerMessage: "api_key=\(secret)")

        for message in [
            httpError.localizedDescription,
            streamError?.localizedDescription ?? "",
            usageError.localizedDescription,
        ] {
            XCTAssertFalse(message.contains(secret))
            XCTAssertTrue(message.contains("REDACTED"))
        }
    }

    func testProviderDiagnosticsRedactPrivateURLsFromStructuredMessageAndDetail() throws {
        let nestedURL = "http://10.24.8.9:8080/private/v1/chat/completions"
        let nestedBody = Data(
            #"{"error":{"message":"upstream \#(nestedURL) failed","type":"gateway","code":"upstream_502"}}"#.utf8)
        let detailURL = "https://internal-gateway.example.test/provider/v1?token=opaque-token"
        let detailBody = Data(#"{"detail":"proxy could not reach \#(detailURL)"}"#.utf8)

        let httpMessage = ProviderErrorFormatting.httpStatus(
            502,
            body: nestedBody,
            operation: "streaming request").localizedDescription
        let streamMessage = try XCTUnwrap(
            ProviderErrorFormatting.streamErrorPayload(detailBody)).localizedDescription
        let transportedMessage = ProviderErrorFormatting.transport(
            IntatisError.provider(
                "custom runtime could not reach \(nestedURL); status=502")).localizedDescription

        for message in [httpMessage, streamMessage, transportedMessage] {
            XCTAssertTrue(message.contains("[REDACTED_URL]"))
            XCTAssertFalse(message.contains("http://"))
            XCTAssertFalse(message.contains("https://"))
            XCTAssertFalse(message.contains("10.24.8.9"))
            XCTAssertFalse(message.contains("internal-gateway"))
            XCTAssertFalse(message.contains("opaque-token"))
        }
        XCTAssertTrue(httpMessage.contains("HTTP 502 Bad Gateway"))
        XCTAssertTrue(httpMessage.contains("type=gateway"))
        XCTAssertTrue(httpMessage.contains("code=upstream_502"))
        XCTAssertTrue(streamMessage.contains("Provider rejected the streaming request"))
        XCTAssertTrue(transportedMessage.contains("status=502"))
    }

    func testProviderTransportRejectsHTTPRedirectBeforeFollowingRoute() throws {
        let original = try XCTUnwrap(URL(string: "https://approved.example/v1/chat/completions"))
        let redirected = try XCTUnwrap(URL(string: "https://unreviewed.example/collect"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.absoluteString]))
        let session = ProviderURLSession.makeNoRedirectSession()
        let task = session.dataTask(with: URLRequest(url: original))
        var redirectDecision: URLRequest? = URLRequest(url: redirected)

        ProviderNoRedirectURLSessionDelegate.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirected)) { request in
                redirectDecision = request
            }

        XCTAssertNil(redirectDecision)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCache)
        session.invalidateAndCancel()
    }

    func testProviderHTTPErrorUsesPreviewForUnstructuredBody() {
        let body = Data(#"<html><body>gateway generated an HTML error page</body></html>"#.utf8)
        let error = ProviderErrorFormatting.httpStatus(502, body: body, operation: "streaming request")

        XCTAssertTrue(error.localizedDescription.contains("HTTP 502 Bad Gateway"))
        XCTAssertTrue(error.localizedDescription.contains("upstream gateway failed"))
        XCTAssertTrue(error.localizedDescription.contains("Preview: <html><body>gateway generated an HTML error page"))
        XCTAssertFalse(error.localizedDescription.contains("Provider said:"))
    }

    func testProviderHTTPErrorIncludesRetryAfterHeaderGuidance() {
        let error = ProviderErrorFormatting.httpStatus(
            429,
            body: Data(#"{"error":{"message":"rate limited"}}"#.utf8),
            headers: ["Retry-After": "2"],
            operation: "streaming request")

        XCTAssertTrue(error.localizedDescription.contains("HTTP 429 Too Many Requests"))
        XCTAssertTrue(error.localizedDescription.contains("retry after about 2s"))
        XCTAssertTrue(error.localizedDescription.contains("retry-after"))
        XCTAssertTrue(error.localizedDescription.contains("rate limited"))
    }

    func testProviderUsageLimitTypeSurvivesRuntimeNormalizationAndExhaustion() throws {
        let original = ProviderUsageLimitError(
            signal: "insufficient_quota",
            providerMessage: "Account credits are exhausted.",
            statusCode: 429,
            operation: "streaming request")
        let policy = ProviderRuntimePolicy(maxAttempts: 3)

        let transported = try XCTUnwrap(
            ProviderErrorFormatting.transport(original) as? ProviderUsageLimitError)
        let exhausted = try XCTUnwrap(
            ProviderRuntime.exhausted(
                original,
                attempts: 3,
                operation: "streaming request") as? ProviderUsageLimitError)

        XCTAssertEqual(transported, original)
        XCTAssertEqual(exhausted, original)
        XCTAssertFalse(ProviderRuntime.shouldRetry(
            error: original,
            attempt: 1,
            policy: policy))
    }

    func testRetryAfterHeaderControlsRuntimeDelayAndCapsLongValues() {
        let hint = ProviderErrorFormatting.retryHint(headers: ["Retry-After": "3"])
        XCTAssertEqual(hint?.delaySeconds, 3)

        let policy = ProviderRuntimePolicy(maxAttempts: 2,
                                           requestTimeoutSeconds: 1,
                                           initialRetryDelaySeconds: 0.1,
                                           maxRetryDelaySeconds: 0.5,
                                           maxRetryAfterDelaySeconds: 5)
        XCTAssertEqual(ProviderRuntime.retryDelayNanoseconds(forNextAttempt: 2,
                                                             policy: policy,
                                                             retryHint: hint),
                       3_000_000_000)

        let cappedPolicy = ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0.1,
                                                 maxRetryDelaySeconds: 0.5,
                                                 maxRetryAfterDelaySeconds: 1)
        XCTAssertEqual(ProviderRuntime.retryDelayNanoseconds(forNextAttempt: 2,
                                                             policy: cappedPolicy,
                                                             retryHint: hint),
                       1_000_000_000)
    }

    func testRetryHintHandlesCaseDuplicateHeadersAndHTTPDates() {
        let duplicateCaseHint = ProviderErrorFormatting.retryHint(headers: [
            "Retry-After": "2",
            "retry-after": "3",
        ])
        XCTAssertTrue([2, 3].contains(Int(duplicateCaseHint?.delaySeconds ?? -1)))
        XCTAssertEqual(duplicateCaseHint?.source, "retry-after")

        let now = Date(timeIntervalSince1970: 1_445_412_470)
        let dateHint = ProviderErrorFormatting.retryHint(
            headers: ["x-ratelimit-reset": "Wed, 21 Oct 2015 07:28:00 GMT"],
            now: now)
        XCTAssertEqual(dateHint?.delaySeconds, 10)
        XCTAssertEqual(dateHint?.source, "x-ratelimit-reset")
    }

    func testRetryHintParsesDurationStyleRateLimitHeaders() {
        let millisecondHint = ProviderErrorFormatting.retryHint(headers: [
            "x-ratelimit-reset-tokens": "750ms",
        ])
        XCTAssertEqual(millisecondHint?.delaySeconds, 0.75)
        XCTAssertEqual(millisecondHint?.source, "x-ratelimit-reset-tokens")

        let combinedHint = ProviderErrorFormatting.retryHint(headers: [
            "x-ratelimit-reset-requests": "1m30s",
        ])
        XCTAssertEqual(combinedHint?.delaySeconds, 90)
        XCTAssertEqual(combinedHint?.source, "x-ratelimit-reset-requests")

        let spacedHint = ProviderErrorFormatting.retryHint(headers: [
            "ratelimit-reset": "2 s",
        ])
        XCTAssertEqual(spacedHint?.delaySeconds, 2)
        XCTAssertEqual(spacedHint?.source, "ratelimit-reset")
    }

    func testOpenAIStreamingThrowsProviderErrorPayload() async throws {
        let sse = """
        data: {"error":{"message":"model not found","type":"invalid_request_error","code":"model_not_found"}}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint, apiKey: "k", http: FakeHTTP(chunks: [Data(sse.utf8)]))

        do {
            for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "missing"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {}
            XCTFail("expected provider error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("model not found"))
            XCTAssertTrue(error.localizedDescription.contains("model_not_found"))
        }
    }

    func testOpenAIStreamingThrowsOnMalformedSSEPayload() async throws {
        let sse = """
        data: not-json

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint, apiKey: "k", http: FakeHTTP(chunks: [Data(sse.utf8)]))

        do {
            for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {}
            XCTFail("expected decoding error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("non-JSON SSE data"))
            XCTAssertTrue(error.localizedDescription.contains("not-json"))
        }
    }

    func testOpenAIStreamingRetriesRetryableHTTPBeforeResponseBytes() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: [DONE]

        """
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [],
                error: ProviderErrorFormatting.httpStatus(
                    503,
                    body: Data(#"{"error":{"message":"upstream overloaded"}}"#.utf8),
                    operation: "streaming request")),
            StreamAttempt(chunks: [Data(sse.utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: openAIEndpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        var text = ""
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            if case .delta(let value) = chunk {
                text += value
            }
        }

        XCTAssertEqual(text, "OK")
        XCTAssertEqual(http.attemptCount, 2)
    }

    func testOpenAIStreamingDoesNotRetryAfterResponseBytes() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [Data(sse.utf8)],
                error: ProviderErrorFormatting.httpStatus(
                    503,
                    body: Data(#"{"error":{"message":"upstream failed mid-stream"}}"#.utf8),
                    operation: "streaming request")),
            StreamAttempt(chunks: [Data("data: [DONE]\n\n".utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: openAIEndpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        do {
            for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                               messages: [ChatMessage(role: .user, content: "hi")])) {
                if case .delta = chunk {
                    // The important invariant is that a stream that has already
                    // yielded response bytes is not retried, because that can
                    // duplicate text or tool calls.
                }
            }
            XCTFail("expected mid-stream provider error")
        } catch {
            XCTAssertEqual(http.attemptCount, 1)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 503"))
        }
    }

    func testRegistryResolvesOpenAIProvider() async throws {
        let endpoint = ProviderEndpoint(id: "default",
                                        baseURL: URL(string: "https://example.test/v1")!,
                                        apiKeyRef: KeychainRef(service: "s", account: "a"),
                                        wire: .openai)
        let config = ProviderConfig(
            endpoints: [endpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "default", model: ModelID(rawValue: "gpt-x"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: []))
        let provider = try await registry.defaultChatProvider()
        XCTAssertTrue(provider is OpenAIWireProvider)
    }

    func testRegistryUnknownEndpointThrows() async {
        let config = ProviderConfig(
            endpoints: [],
            models: ResolvedModels(chat: ModelRef(endpoint: "missing", model: ModelID(rawValue: "x"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: []))
        do {
            _ = try await registry.defaultChatProvider()
            XCTFail("expected unknown-endpoint error")
        } catch {
            // expected
        }
    }

    func testHealthCheckReportsOKForCompletedChatStream() async {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}

        data: [DONE]

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: [Data(sse.utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.role, .chat)
        XCTAssertEqual(report.endpointID, "e")
        XCTAssertEqual(report.model.rawValue, "gpt-health")
        XCTAssertEqual(report.wire, .openai)
        XCTAssertEqual(report.totalTokens, 3)
        XCTAssertEqual(report.responsePreview, "OK")
        XCTAssertNil(report.code)
    }

    func testHealthCheckReportsPartialStreamWhenDoneMarkerMissing() async {
        let sse = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: [Data(sse.utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "provider.partial_stream")
        XCTAssertEqual(report.responsePreview, "partial")
        XCTAssertTrue(report.message.contains("completion marker"))
    }

    func testHealthCheckAcceptsFinishReasonWhenDoneMarkerMissing() async {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(config: config,
                                        resolver: StaticSecret(key: "k"),
                                        http: FakeHTTP(chunks: [Data(sse.utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.code, nil)
        XCTAssertEqual(report.responsePreview, "OK")
    }

    func testHealthCheckReportsTimeout() async {
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(
            config: config,
            resolver: StaticSecret(key: "k"),
            http: DelayedHTTP(delayNanoseconds: 2_000_000_000))

        let report = await registry.healthCheck(options: ProviderHealthCheckOptions(timeoutSeconds: 0.01))

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "provider.timeout")
        XCTAssertTrue(report.message.contains("timed out"))
    }

    func testHealthCheckReportsUnknownEndpointWithoutThrowing() async {
        let config = ProviderConfig(
            endpoints: [],
            models: ResolvedModels(chat: ModelRef(endpoint: "missing", model: ModelID(rawValue: "x"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: []))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "config")
        XCTAssertEqual(report.endpointID, "missing")
        XCTAssertTrue(report.message.contains("unknown endpoint"))
    }

    func testHealthCheckReportsInvalidProviderURLAsConfigError() async {
        let config = ProviderConfig(
            endpoints: [nonHTTPChatEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "bad-chat", model: ModelID(rawValue: "x"))))
        let registry = ProviderRegistry(
            config: config,
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: [Data("data: [DONE]\n\n".utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "config")
        XCTAssertEqual(report.endpointID, "bad-chat")
        XCTAssertTrue(report.message.contains("invalid provider endpoint 'bad-chat'"))
        XCTAssertTrue(report.message.contains("Chat endpoint scheme 'file' is not supported"))
    }

    func testHealthCheckCanUseAgentRole() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(
                chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-chat")),
                agent: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-agent"))))
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: http)

        let report = await registry.healthCheck(role: .agent)

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.role, .agent)
        XCTAssertEqual(report.model.rawValue, "gpt-agent")
        XCTAssertEqual(report.totalTokens, 3)
        XCTAssertEqual(report.responsePreview, "OK")

        let body = try XCTUnwrap(http.lastBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let streamOptions = try XCTUnwrap(root["stream_options"] as? [String: Any])
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)
    }

    func testConfiguredModelOptionsPassThroughChatBodyWithoutOverridingRuntimeStructure() throws {
        let endpoint = ProviderEndpoint(
            id: "generic",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            modelRequestOptions: [
                "vendor/model": [
                    "provider": .object([
                        "only": .array([.string("vendor-a")]),
                        "allow_fallbacks": .bool(false),
                    ]),
                    "vendor_extension": .object([
                        "mode": .string("exact"),
                        "threshold": .number(0.75),
                    ]),
                    "temperature": .number(0.9),
                    "model": .string("must-not-win"),
                    "messages": .array([]),
                    "tools": .array([]),
                    "stream": .bool(false),
                    "stream_options": .object(["include_usage": .bool(true)]),
                    "n": .number(8),
                    "best_of": .number(8),
                    "num_return_sequences": .number(8),
                    "candidate_count": .number(8),
                ],
            ])
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP(chunks: []))
        let request = try provider.buildRequest(ChatRequest(
            model: ModelID(rawValue: "vendor/model"),
            messages: [ChatMessage(role: .user, content: "hello")],
            temperature: 0.2))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        guard case .object(let body) = decoded else { return XCTFail("request body is not an object") }

        XCTAssertEqual(body["provider"], JSONValue.object([
            "only": .array([.string("vendor-a")]),
            "allow_fallbacks": .bool(false),
        ]))
        XCTAssertEqual(body["vendor_extension"], JSONValue.object([
            "mode": .string("exact"),
            "threshold": .number(0.75),
        ]))
        XCTAssertEqual(body["temperature"], JSONValue.number(0.2))
        XCTAssertEqual(body["model"], JSONValue.string("vendor/model"))
        XCTAssertEqual(body["stream"], JSONValue.bool(true))
        XCTAssertEqual(body["n"], JSONValue.number(1))
        XCTAssertNil(body["best_of"])
        XCTAssertNil(body["num_return_sequences"])
        XCTAssertNil(body["candidate_count"])
        XCTAssertNil(body["stream_options"])
        guard let messageValue = body["messages"],
              case .array(let messages) = messageValue else {
            return XCTFail("runtime messages were not encoded")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(body["tools"])
    }

    func testProviderEndpointModelOptionsAreCodableAndLegacyEndpointsDefaultEmpty() throws {
        let endpoint = ProviderEndpoint(
            id: "generic",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            modelRequestOptions: ["m": ["top_k": .number(7)]])
        let roundTrip = try JSONDecoder().decode(
            ProviderEndpoint.self,
            from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(roundTrip, endpoint)

        let legacy = #"{"id":"legacy","baseURL":"https:\/\/example.test\/v1","apiKeyRef":{"service":"s","account":"a"},"wire":"openai"}"#
        let decoded = try JSONDecoder().decode(ProviderEndpoint.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.modelRequestOptions.isEmpty)
    }

    func testModelConfigurationPresentationReadsReasoningLabelsWithoutRewritingOptions() {
        let cases: [([String: JSONValue], String)] = [
            (["reasoning_effort": .string("max")], "max"),
            (["reasoningEffort": .string("xhigh")], "xhigh"),
            (["reasoning": .object(["effort": .string("high")])], "high"),
            (["output_config": .object(["effort": .string("medium")])], "medium"),
            (["thinking": .object(["budgetTokens": .number(16_000)])], "16000 tokens"),
            (["reasoning": .object(["max_tokens": .number(2_000)])], "2000 tokens"),
        ]

        for (options, expected) in cases {
            let original = options
            let presentation = ModelConfigurationPresentation(requestOptions: options)
            XCTAssertEqual(presentation.reasoningLabel, expected)
            XCTAssertEqual(options, original)
        }
    }

    func testModelConfigurationPresentationDoesNotPretendAnUnselectedVariantIsActive() {
        let presentation = ModelConfigurationPresentation(
            modelMetadata: [
                "variants": .object([
                    "high": .object(["reasoningEffort": .string("high")]),
                    "low": .object(["reasoningEffort": .string("low")]),
                ]),
                "capabilities": .object(["effort": .string("unrelated")]),
            ],
            requestOptions: [:])

        XCTAssertNil(presentation.reasoningLabel)
    }

    func testModelConfigurationPresentationCanReadDirectModelMetadata() {
        let presentation = ModelConfigurationPresentation(
            modelMetadata: ["reasoningEffort": .string("max")],
            requestOptions: [:])

        XCTAssertEqual(presentation.reasoningLabel, "max")
    }
}
