import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Non-streaming request/response transport (for image generation, transcription,
/// and video job polling). Streaming chat uses `HTTPByteStreaming` instead. Tests
/// inject a fake; the real client is `URLSessionDataClient`.
public protocol HTTPDataClient: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

public struct URLSessionDataClient: HTTPDataClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        #if canImport(Darwin)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
        #else
        throw IntatisError.provider("HTTP data client is unavailable on this platform")
        #endif
    }
}
