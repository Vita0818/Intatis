import XCTest
import IntatisCore
@testable import IntatisProviders

private struct FakeDataClient: HTTPDataClient {
    let response: Data
    let status: Int
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) { (response, status) }
}

private struct FixedSecret: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}

private let ep = ProviderEndpoint(id: "e", baseURL: URL(string: "https://example.test/v1")!,
                                  apiKeyRef: KeychainRef(service: "s", account: "a"), wire: .openai)

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
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: Data(), status: 500))
        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("HTTP 500 should throw")
        } catch {}
    }

    func testTranscriptionParsesText() async throws {
        let json = Data(#"{"text":"hello world"}"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: json, status: 200))
        let text = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"), audio: Data([1, 2, 3])))
        XCTAssertEqual(text, "hello world")
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
