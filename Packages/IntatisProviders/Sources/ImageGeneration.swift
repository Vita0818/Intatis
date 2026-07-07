import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ImageRequest: Sendable {
    public var model: ModelID
    public var prompt: String
    public var size: String
    public var n: Int
    public init(model: ModelID, prompt: String, size: String = "1024x1024", n: Int = 1) {
        self.model = model
        self.prompt = prompt
        self.size = size
        self.n = n
    }
}

public struct GeneratedImage: Equatable, Sendable {
    public var data: Data
    public var mime: String
    public init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
    }
}

/// `Capability.image_generation`.
public protocol ImageGenerationProvider: Sendable {
    func generate(_ request: ImageRequest) async throws -> [GeneratedImage]
}

/// OpenAI-compatible `/images/generations` (b64 response).
public struct OpenAIImageProvider: ImageGenerationProvider {
    private let endpoint: ProviderEndpoint
    private let apiKey: String
    private let http: HTTPDataClient
    private let runtimePolicy: ProviderRuntimePolicy

    public init(endpoint: ProviderEndpoint,
                apiKey: String,
                http: HTTPDataClient,
                runtimePolicy: ProviderRuntimePolicy = .nonStreaming) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
        self.runtimePolicy = runtimePolicy
    }

    private struct Response: Decodable {
        struct Item: Decodable { let b64_json: String? }
        let data: [Item]
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        var r = URLRequest(url: try endpoint.validatedBaseURLAppendingPathComponent("images/generations",
                                                                                    operation: "image generation"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": request.model.rawValue,
            "prompt": request.prompt,
            "size": request.size,
            "n": request.n,
            "response_format": "b64_json",
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await ProviderRuntime.sendData(r,
                                                      via: http,
                                                      policy: runtimePolicy,
                                                      operation: "image generation")
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderErrorFormatting.invalidResponsePayload(
                data,
                operation: "image generation",
                expected: "OpenAI-compatible image JSON with data[].b64_json",
                underlying: error)
        }
        guard !decoded.data.isEmpty else {
            throw ProviderErrorFormatting.invalidResponsePayload(
                data,
                operation: "image generation",
                expected: "OpenAI-compatible image JSON with data[].b64_json")
        }
        return try decoded.data.map { item in
            guard let b64 = item.b64_json, let bytes = Data(base64Encoded: b64) else {
                throw ProviderErrorFormatting.invalidResponsePayload(
                    data,
                    operation: "image generation",
                    expected: "OpenAI-compatible image JSON with data[].b64_json")
            }
            return GeneratedImage(data: bytes, mime: "image/png")
        }
    }
}
