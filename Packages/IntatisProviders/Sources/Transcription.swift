import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TranscriptionRequest: Sendable {
    public var model: ModelID
    public var audio: Data
    public var filename: String
    public var mime: String
    public init(model: ModelID, audio: Data, filename: String = "audio.m4a", mime: String = "audio/m4a") {
        self.model = model
        self.audio = audio
        self.filename = filename
        self.mime = mime
    }
}

/// `Capability.realtime_transcription` (v0.4 ships batch transcription; a realtime
/// websocket session can adopt the same protocol later).
public protocol TranscriptionProvider: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> String
}

private extension Data {
    mutating func appendString(_ s: String) { append(Data(s.utf8)) }
}

/// OpenAI-compatible `/audio/transcriptions` (multipart/form-data, Whisper-style).
public struct OpenAITranscriptionProvider: TranscriptionProvider {
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

    private struct Response: Decodable { let text: String }

    public func transcribe(_ request: TranscriptionRequest) async throws -> String {
        let boundary = "intatis-\(UUID().uuidString)"
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("\(request.model.rawValue)\r\n")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(request.filename)\"\r\n")
        body.appendString("Content-Type: \(request.mime)\r\n\r\n")
        body.append(request.audio)
        body.appendString("\r\n--\(boundary)--\r\n")

        var r = URLRequest(url: try endpoint.validatedBaseURLAppendingPathComponent("audio/transcriptions",
                                                                                    operation: "transcription"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        r.httpBody = body

        let data = try await ProviderRuntime.sendData(r,
                                                      via: http,
                                                      policy: runtimePolicy,
                                                      operation: "transcription")
        do {
            return try JSONDecoder().decode(Response.self, from: data).text
        } catch {
            throw ProviderErrorFormatting.invalidResponsePayload(
                data,
                operation: "transcription",
                expected: "OpenAI-compatible transcription JSON with text",
                underlying: error)
        }
    }
}
