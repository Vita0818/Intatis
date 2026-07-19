import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Non-streaming request/response transport (for image generation, transcription,
/// and video job polling). Streaming chat uses `HTTPByteStreaming` instead. Tests
/// inject a fake; the real client is `URLSessionDataClient`.
public struct HTTPDataResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]

    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }

    static func headers(from response: HTTPURLResponse) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            values[String(describing: key).lowercased()] = String(describing: value)
        }
        return values
    }
}

public protocol HTTPDataClient: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse
}

public extension HTTPDataClient {
    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        let response = try await send(request)
        return HTTPDataResponse(data: response.data, status: response.status)
    }
}

public struct URLSessionDataClient: HTTPDataClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }

    public func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        #if canImport(Darwin)
        let (data, response) = try await ProviderURLSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return HTTPDataResponse(data: data, status: 0)
        }
        return HTTPDataResponse(data: data,
                                status: http.statusCode,
                                headers: HTTPDataResponse.headers(from: http))
        #else
        throw IntatisError.provider("HTTP data client is unavailable on this platform")
        #endif
    }
}
