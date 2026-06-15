import XCTest
import IntatisCore
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

private struct StaticSecret: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}

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

    func testOpenAIStreamingParsesUsage() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"hi"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}}

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
        XCTAssertEqual(usage?.completionTokens, 3)
        XCTAssertEqual(usage?.totalTokens, 14)
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
}
