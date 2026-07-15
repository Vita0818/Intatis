import XCTest
import IntatisCore
@testable import IntatisProviders

private struct FakeDataClient: HTTPDataClient {
    let response: Data
    let status: Int
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) { (response, status) }
}

private final class SequencedDataClient: HTTPDataClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.sequenced-data")
    private var index = 0
    private let responses: [HTTPDataResponse]

    init(responses: [(data: Data, status: Int)]) {
        self.responses = responses.map { HTTPDataResponse(data: $0.data, status: $0.status) }
    }

    init(responses: [HTTPDataResponse]) {
        self.responses = responses
    }

    var attemptCount: Int {
        queue.sync { index }
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let response = next()
        return (response.data, response.status)
    }

    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        next()
    }

    private func next() -> HTTPDataResponse {
        queue.sync {
            let value = responses[min(index, responses.count - 1)]
            index += 1
            return value
        }
    }
}

private struct DelayedDataClient: HTTPDataClient {
    let delayNanoseconds: UInt64

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return (Data(#"{"text":"late"}"#.utf8), 200)
    }
}

private struct FixedSecret: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}

private let ep = ProviderEndpoint(id: "e", baseURL: URL(string: "https://example.test/v1")!,
                                  apiKeyRef: KeychainRef(service: "s", account: "a"), wire: .openai)
private let nonHTTPBaseEndpoint = ProviderEndpoint(id: "bad-base",
                                                   baseURL: URL(fileURLWithPath: "/tmp/intatis-provider"),
                                                   apiKeyRef: KeychainRef(service: "s", account: "a"),
                                                   wire: .openai)

final class IntatisProvidersMultimodalTests: XCTestCase {

    func testImageGenParsesBase64() async throws {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let json = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: json, status: 200))
        let images = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].data, Data("PNGDATA".utf8))
        XCTAssertEqual(images[0].mime, "image/png")
    }

    func testImageGenHTTPErrorThrows() async {
        let body = Data(#"{"error":{"message":"temporary upstream failure","code":"server_error"}}"#.utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: body, status: 500))
        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("HTTP 500 should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 500 Internal Server Error"))
            XCTAssertTrue(error.localizedDescription.contains("retry later"))
            XCTAssertTrue(error.localizedDescription.contains("temporary upstream failure"))
        }
    }

    func testImageGenUnexpectedSuccessPayloadThrowsActionableError() async {
        let body = Data(#"{"error":{"message":"image model does not support b64_json","code":"bad_response_format"}}"#.utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("unexpected successful payload should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("image generation returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("data[].b64_json"))
            XCTAssertTrue(error.localizedDescription.contains("Provider said: image model does not support b64_json"))
            XCTAssertTrue(error.localizedDescription.contains("bad_response_format"))
        }
    }

    func testImageGenMissingBase64UsesPreviewNotProviderSaid() async {
        let body = Data(#"{"data":[{"url":"https://cdn.example/image.png"}]}"#.utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("missing b64_json should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("image generation returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("data[].b64_json"))
            XCTAssertTrue(error.localizedDescription.contains("Preview:"))
            XCTAssertTrue(error.localizedDescription.contains(#""url":"#))
            XCTAssertFalse(error.localizedDescription.contains("Provider said:"))
        }
    }

    func testImageGenRejectsNonHTTPBaseURLBeforeTransport() async {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let json = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let provider = OpenAIImageProvider(endpoint: nonHTTPBaseEndpoint,
                                           apiKey: "k",
                                           http: FakeDataClient(response: json, status: 200))

        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "x"))
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-base'"))
            XCTAssertTrue(error.localizedDescription.contains("Base URL scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("image generation"))
        }
    }

    func testImageGenRetriesTransientHTTPStatusThenParsesBase64() async throws {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let success = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let client = SequencedDataClient(responses: [
            (Data(#"{"error":{"message":"busy"}}"#.utf8), 503),
            (success, 200),
        ])
        let provider = OpenAIImageProvider(
            endpoint: ep,
            apiKey: "k",
            http: client,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        let images = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))

        XCTAssertEqual(images.first?.data, Data("PNGDATA".utf8))
        XCTAssertEqual(client.attemptCount, 2)
    }

    func testImageGenUsesRetryAfterHeaderFromDataResponse() async throws {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let success = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let client = SequencedDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"error":{"message":"request rate exceeded","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#.utf8),
                status: 429,
                headers: ["retry-after": "0"]),
            HTTPDataResponse(data: success, status: 200),
        ])
        let provider = OpenAIImageProvider(
            endpoint: ep,
            apiKey: "k",
            http: client,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0.25,
                                                 maxRetryDelaySeconds: 2,
                                                 maxRetryAfterDelaySeconds: 1))

        let images = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))

        XCTAssertEqual(images.first?.data, Data("PNGDATA".utf8))
        XCTAssertEqual(client.attemptCount, 2)
    }

    func testImageGenHardUsageLimitDoesNotRetryAndPreservesTypedError() async {
        let client = SequencedDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"error":{"message":"No credits remain.","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8),
                status: 429),
            HTTPDataResponse(data: Data(#"{"data":[]}"#.utf8), status: 200),
        ])
        let provider = OpenAIImageProvider(
            endpoint: ep,
            apiKey: "k",
            http: client,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        do {
            _ = try await provider.generate(
                ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))
            XCTFail("expected hard provider usage limit")
        } catch let error as ProviderUsageLimitError {
            XCTAssertEqual(error.signal, "insufficient_quota")
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertTrue(error.localizedDescription.contains("hard usage limit"))
            XCTAssertEqual(client.attemptCount, 1)
        } catch {
            XCTFail("expected ProviderUsageLimitError, got \(type(of: error)): \(error)")
        }
    }

    func testTranscriptionParsesText() async throws {
        let json = Data(#"{"text":"hello world"}"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: json, status: 200))
        let text = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"), audio: Data([1, 2, 3])))
        XCTAssertEqual(text, "hello world")
    }

    func testTranscriptionTimeoutHasActionableMessage() async {
        let provider = OpenAITranscriptionProvider(
            endpoint: ep,
            apiKey: "k",
            http: DelayedDataClient(delayNanoseconds: 2_000_000_000),
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 1,
                                                 requestTimeoutSeconds: 0.01,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"), audio: Data([1, 2, 3])))
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("transcription timed out"))
            XCTAssertTrue(error.localizedDescription.contains("endpoint"))
        }
    }

    func testTranscriptionUnexpectedSuccessPayloadThrowsActionableError() async {
        let body = Data(#"{"error":{"message":"audio format unsupported","code":"bad_audio"}}"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep,
                                                   apiKey: "k",
                                                   http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"),
                                                                   audio: Data([1, 2, 3])))
            XCTFail("unexpected successful payload should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("transcription returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("transcription JSON with text"))
            XCTAssertTrue(error.localizedDescription.contains("Provider said: audio format unsupported"))
            XCTAssertTrue(error.localizedDescription.contains("bad_audio"))
        }
    }

    func testTranscriptionHTMLSuccessPayloadUsesPreviewNotProviderSaid() async {
        let body = Data(#"<html><body>upstream proxy returned HTML</body></html>"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep,
                                                   apiKey: "k",
                                                   http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"),
                                                                   audio: Data([1, 2, 3])))
            XCTFail("HTML success payload should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("transcription returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("transcription JSON with text"))
            XCTAssertTrue(error.localizedDescription.contains("Preview: <html><body>upstream proxy returned HTML"))
            XCTAssertFalse(error.localizedDescription.contains("Provider said:"))
        }
    }

    func testTranscriptionRejectsNonHTTPBaseURLBeforeTransport() async {
        let provider = OpenAITranscriptionProvider(
            endpoint: nonHTTPBaseEndpoint,
            apiKey: "k",
            http: FakeDataClient(response: Data(#"{"text":"hello"}"#.utf8), status: 200))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"),
                                                                   audio: Data([1, 2, 3])))
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-base'"))
            XCTAssertTrue(error.localizedDescription.contains("Base URL scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("transcription"))
        }
    }

    func testRegistryResolvesImageProvider() async throws {
        var models = ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "c")))
        models.imageGen = ModelRef(endpoint: "e", model: ModelID(rawValue: "image-model"))
        let registry = ProviderRegistry(config: ProviderConfig(endpoints: [ep], models: models),
                                        resolver: FixedSecret(key: "k"),
                                        dataClient: FakeDataClient(response: Data(), status: 200))
        let provider = try await registry.defaultImageProvider()
        XCTAssertNotNil(provider)
    }

    func testRegistryNilWhenNoImageModelConfigured() async throws {
        let models = ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "c")))
        let registry = ProviderRegistry(config: ProviderConfig(endpoints: [ep], models: models),
                                        resolver: FixedSecret(key: "k"))
        let provider = try await registry.defaultImageProvider()
        XCTAssertNil(provider)
    }
}
