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

    public init(endpoint: ProviderEndpoint, apiKey: String, http: HTTPDataClient) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
    }

    private struct Response: Decodable {
        struct Item: Decodable { let b64_json: String? }
        let data: [Item]
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        var r = URLRequest(url: endpoint.baseURL.appendingPathComponent("images/generations"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": request.model.rawValue,
            "prompt": request.prompt,
            "size": request.size,
            "n": request.n,
            "response_format": "b64_json",
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, status) = try await http.send(r)
        guard (200..<300).contains(status) else {
            throw IntatisError.provider("image generation HTTP \(status)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return try decoded.data.map { item in
            guard let b64 = item.b64_json, let bytes = Data(base64Encoded: b64) else {
                throw IntatisError.provider("image response missing b64_json")
            }
            return GeneratedImage(data: bytes, mime: "image/png")
        }
    }
}
