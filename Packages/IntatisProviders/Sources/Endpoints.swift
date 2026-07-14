import Foundation
import IntatisCore
import IntatisProtocol

/// The wire dialect an endpoint speaks. v0.1 ships only `.openai`; adding a
/// dialect later is a new case + a new adapter, with no change to the registry,
/// kernel, or UI (ARCHITECTURE.md §9.2).
public enum WireFormat: String, Codable, Sendable {
    case openai
    // case anthropic, gemini, …  (later)
}

/// A reference to a secret. `keychain` is retained as a legacy wire value, but
/// app resolvers may map it to configuration files. New GUI provider configs use
/// env vars, files, or auth JSON entries instead of OS credential stores.
public enum SecretRefSource: String, Codable, Sendable {
    case keychain
    case environment
    case file
    case authFile
    case providerConfig
}

public struct KeychainRef: Codable, Equatable, Sendable {
    public var service: String
    public var account: String
    public var source: SecretRefSource

    public init(service: String, account: String) {
        self.service = service
        self.account = account
        self.source = .keychain
    }

    public static func environment(_ name: String) -> KeychainRef {
        KeychainRef(source: .environment, service: "environment", account: name)
    }

    public static func file(_ path: String) -> KeychainRef {
        KeychainRef(source: .file, service: "file", account: path)
    }

    public static func authFile(providerID: String) -> KeychainRef {
        KeychainRef(source: .authFile, service: "auth-file", account: providerID)
    }

    public static func providerConfig(path: String, providerID: String) -> KeychainRef {
        KeychainRef(source: .providerConfig, service: path, account: providerID)
    }

    private init(source: SecretRefSource, service: String, account: String) {
        self.service = service
        self.account = account
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case account
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.service = try container.decode(String.self, forKey: .service)
        self.account = try container.decode(String.self, forKey: .account)
        self.source = try container.decodeIfPresent(SecretRefSource.self, forKey: .source) ?? .keychain
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
    public var chatEndpoint: URL?
    public var apiKeyRef: KeychainRef
    public var wire: WireFormat
    /// Arbitrary model-scoped request body options from the user's provider
    /// configuration. Wire adapters merge the selected model's object into the
    /// outgoing request without enumerating provider-specific keys.
    public var modelRequestOptions: [String: [String: JSONValue]]

    public init(id: String, baseURL: URL, chatEndpoint: URL? = nil,
                apiKeyRef: KeychainRef, wire: WireFormat,
                modelRequestOptions: [String: [String: JSONValue]] = [:]) {
        self.id = id
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
        self.apiKeyRef = apiKeyRef
        self.wire = wire
        self.modelRequestOptions = modelRequestOptions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseURL
        case chatEndpoint
        case apiKeyRef
        case wire
        case modelRequestOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.baseURL = try container.decode(URL.self, forKey: .baseURL)
        self.chatEndpoint = try container.decodeIfPresent(URL.self, forKey: .chatEndpoint)
        self.apiKeyRef = try container.decode(KeychainRef.self, forKey: .apiKeyRef)
        self.wire = try container.decode(WireFormat.self, forKey: .wire)
        self.modelRequestOptions = try container.decodeIfPresent(
            [String: [String: JSONValue]].self,
            forKey: .modelRequestOptions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(chatEndpoint, forKey: .chatEndpoint)
        try container.encode(apiKeyRef, forKey: .apiKeyRef)
        try container.encode(wire, forKey: .wire)
        if !modelRequestOptions.isEmpty {
            try container.encode(modelRequestOptions, forKey: .modelRequestOptions)
        }
    }

    public var chatCompletionsURL: URL {
        chatEndpoint ?? baseURL.appendingPathComponent("chat/completions")
    }

    public func requestOptions(for model: ModelID) -> [String: JSONValue] {
        modelRequestOptions[model.rawValue] ?? [:]
    }
}

extension ProviderEndpoint {
    func validatedChatCompletionsURL(operation: String) throws -> URL {
        let field = chatEndpoint == nil ? "Base URL" : "Chat endpoint"
        return try Self.validatedHTTPURL(chatCompletionsURL,
                                         endpointID: id,
                                         field: field,
                                         operation: operation)
    }

    func validatedBaseURLAppendingPathComponent(_ pathComponent: String,
                                                operation: String) throws -> URL {
        try Self.validatedHTTPURL(baseURL.appendingPathComponent(pathComponent),
                                  endpointID: id,
                                  field: "Base URL",
                                  operation: operation)
    }

    private static func validatedHTTPURL(_ url: URL,
                                         endpointID: String,
                                         field: String,
                                         operation: String) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw IntatisError.config(
                "invalid provider endpoint '\(endpointID)' for \(operation): \(field) is missing a URL scheme. Use an http:// or https:// URL with a host.")
        }
        guard scheme == "http" || scheme == "https" else {
            throw IntatisError.config(
                "invalid provider endpoint '\(endpointID)' for \(operation): \(field) scheme '\(scheme)' is not supported. Use an http:// or https:// URL with a host.")
        }
        guard let host = url.host, !host.isEmpty else {
            throw IntatisError.config(
                "invalid provider endpoint '\(endpointID)' for \(operation): \(field) host is missing. Check the Base URL or Chat endpoint.")
        }
        return url
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
