import Foundation
import IntatisCore

/// Resolves a `ModelRef` to a concrete provider for a capability. v0.1 only
/// resolves `.chat`; the `switch endpoint.wire` is where new dialects plug in
/// (ARCHITECTURE.md §3.3, §9.2). Secrets are fetched lazily via the injected
/// `SecretResolver`, never stored in the config.
public actor ProviderRegistry {
    private let config: ProviderConfig
    private let resolver: SecretResolver
    private let http: HTTPByteStreaming
    private let dataClient: HTTPDataClient

    public init(config: ProviderConfig,
                resolver: SecretResolver,
                http: HTTPByteStreaming = URLSessionStreamingClient(),
                dataClient: HTTPDataClient = URLSessionDataClient()) {
        self.config = config
        self.resolver = resolver
        self.http = http
        self.dataClient = dataClient
    }

    public func chatProvider(for ref: ModelRef) async throws -> ChatProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAIWireProvider(endpoint: endpoint, apiKey: apiKey, http: http)
        }
    }

    /// Convenience: the default chat provider from `models.chat`.
    public func defaultChatProvider() async throws -> ChatProvider {
        try await chatProvider(for: config.models.chat)
    }

    /// The model id bound to the chat role.
    public func chatModel() -> ModelID {
        config.models.chat.model
    }

    /// The resolved model bindings (chat/agent/reviewer/…).
    public func models() -> ResolvedModels {
        config.models
    }

    // MARK: Tool-calling (v0.2)

    public func agentProvider(for ref: ModelRef) async throws -> ToolCallingProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAIWireProvider(endpoint: endpoint, apiKey: apiKey, http: http)
        }
    }

    /// The default agent provider, from `models.agent` (falling back to `models.chat`).
    public func defaultAgentProvider() async throws -> ToolCallingProvider {
        try await agentProvider(for: config.models.agent ?? config.models.chat)
    }

    public func agentModel() -> ModelID {
        (config.models.agent ?? config.models.chat).model
    }

    // MARK: Multimodal (v0.4)

    public func imageProvider(for ref: ModelRef) async throws -> ImageGenerationProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAIImageProvider(endpoint: endpoint, apiKey: apiKey, http: dataClient)
        }
    }

    public func transcriptionProvider(for ref: ModelRef) async throws -> TranscriptionProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAITranscriptionProvider(endpoint: endpoint, apiKey: apiKey, http: dataClient)
        }
    }

    /// nil when no image model is configured (`models.imageGen`).
    public func defaultImageProvider() async throws -> ImageGenerationProvider? {
        guard let ref = config.models.imageGen else { return nil }
        return try await imageProvider(for: ref)
    }

    public func defaultTranscriptionProvider() async throws -> TranscriptionProvider? {
        guard let ref = config.models.transcription else { return nil }
        return try await transcriptionProvider(for: ref)
    }

    public func imageModel() -> ModelID? { config.models.imageGen?.model }
    public func transcriptionModel() -> ModelID? { config.models.transcription?.model }
}
