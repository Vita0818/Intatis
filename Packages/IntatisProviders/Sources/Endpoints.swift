import Foundation
import IntatisCore

/// The wire dialect an endpoint speaks. v0.1 ships only `.openai`; adding a
/// dialect later is a new case + a new adapter, with no change to the registry,
/// kernel, or UI (ARCHITECTURE.md §9.2).
public enum WireFormat: String, Codable, Sendable {
    case openai
    // case anthropic, gemini, …  (later)
}

/// A reference to a secret in the OS keychain — never the secret itself. The
/// app supplies a `SecretResolver`; the secret is fetched lazily at call time.
public struct KeychainRef: Codable, Equatable, Sendable {
    public var service: String
    public var account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public protocol SecretResolver: Sendable {
    func secret(for ref: KeychainRef) async throws -> String
}

/// A named provider endpoint. `chat` and `reviewer` can point at different
/// endpoints with different base URLs / keys / wire formats (ARCHITECTURE.md §9.3).
public struct ProviderEndpoint: Codable, Equatable, Sendable {
    public var id: String
    public var baseURL: URL
    public var apiKeyRef: KeychainRef
    public var wire: WireFormat
    public init(id: String, baseURL: URL, apiKeyRef: KeychainRef, wire: WireFormat) {
        self.id = id
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.wire = wire
    }
}

/// A role binding: which endpoint + which model.
public struct ModelRef: Codable, Equatable, Sendable {
    public var endpoint: String
    public var model: ModelID
    public init(endpoint: String, model: ModelID) {
        self.endpoint = endpoint
        self.model = model
    }
}

/// Default model per role. v0.1 only requires `chat`; the rest are forward slots.
public struct ResolvedModels: Codable, Equatable, Sendable {
    public var chat: ModelRef
    public var agent: ModelRef?
    public var reviewer: ModelRef?
    public var vision: ModelRef?
    public var transcription: ModelRef?
    public var imageGen: ModelRef?
    public var videoGen: ModelRef?
    public init(chat: ModelRef,
                agent: ModelRef? = nil,
                reviewer: ModelRef? = nil,
                vision: ModelRef? = nil,
                transcription: ModelRef? = nil,
                imageGen: ModelRef? = nil,
                videoGen: ModelRef? = nil) {
        self.chat = chat
        self.agent = agent
        self.reviewer = reviewer
        self.vision = vision
        self.transcription = transcription
        self.imageGen = imageGen
        self.videoGen = videoGen
    }
}

/// The full provider configuration: a set of named endpoints + role bindings.
public struct ProviderConfig: Codable, Equatable, Sendable {
    public var endpoints: [ProviderEndpoint]
    public var models: ResolvedModels
    public init(endpoints: [ProviderEndpoint], models: ResolvedModels) {
        self.endpoints = endpoints
        self.models = models
    }

    public func endpoint(id: String) -> ProviderEndpoint? {
        endpoints.first { $0.id == id }
    }
}
