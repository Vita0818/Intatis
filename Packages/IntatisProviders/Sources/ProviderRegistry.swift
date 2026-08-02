import Foundation
import IntatisCore
import IntatisProtocol

/// One atomically resolved tool-calling route. Provider, model, and durable
/// binding always originate from the same exact catalog snapshot revision.
public struct ResolvedInferenceProfile: Sendable {
    public let binding: AgentInferenceBinding
    public let model: ModelID
    public let provider: ToolCallingProvider
    public let modelContextPolicy: AgentModelContextPolicy

    public init(binding: AgentInferenceBinding,
                model: ModelID,
                provider: ToolCallingProvider,
                modelContextPolicy: AgentModelContextPolicy = .unspecified) {
        self.binding = binding
        self.model = model
        self.provider = provider
        self.modelContextPolicy = modelContextPolicy
    }
}

/// Runtime route for visible Code sessions. When the selected legacy model
/// maps unambiguously to one current base profile, provider/model/context
/// metadata come from that same immutable resolution. Otherwise the legacy
/// provider remains usable and compaction metadata stays unspecified.
public struct ResolvedAgentRuntimeRoute: Sendable {
    public let provider: ToolCallingProvider
    public let model: ModelID
    public let modelContextPolicy: AgentModelContextPolicy

    public init(
        provider: ToolCallingProvider,
        model: ModelID,
        modelContextPolicy: AgentModelContextPolicy
    ) {
        self.provider = provider
        self.model = model
        self.modelContextPolicy = modelContextPolicy
    }
}

/// One atomically resolved Chat route. Provider-hosted search may use a
/// separately configured endpoint/model, while ordinary turns keep using the
/// visible Chat selection.
public struct ResolvedChatRuntimeRoute: Sendable {
    public let provider: ChatProvider
    public let model: ModelID

    public init(provider: ChatProvider, model: ModelID) {
        self.provider = provider
        self.model = model
    }
}

/// Resolves a `ModelRef` to a concrete provider for a capability. v0.1 only
/// resolves `.chat`; the `switch endpoint.wire` is where new dialects plug in
/// (ARCHITECTURE.md §3.3, §9.2). Secrets are fetched lazily via the injected
/// `SecretResolver`, never stored in the config.
public actor ProviderRegistry {
    private let config: ProviderConfig
    private let resolver: SecretResolver
    private let http: HTTPByteStreaming
    private let dataClient: HTTPDataClient
    private let inferenceCatalogSnapshot: InferenceCatalogSnapshot?

    public init(config: ProviderConfig,
                resolver: SecretResolver,
                http: HTTPByteStreaming = URLSessionStreamingClient(),
                dataClient: HTTPDataClient = URLSessionDataClient(),
                inferenceCatalogSnapshot: InferenceCatalogSnapshot? = nil) {
        self.config = config
        self.resolver = resolver
        self.http = http
        self.dataClient = dataClient
        self.inferenceCatalogSnapshot = inferenceCatalogSnapshot
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

    /// Resolves the transparent hosted-search provider and model as one
    /// actor-isolated operation. A missing search binding deliberately falls
    /// back to the ordinary Chat route; an invalid configured binding fails
    /// instead of silently changing providers.
    public func hostedSearchChatRuntimeRoute() async throws
        -> ResolvedChatRuntimeRoute
    {
        let ref = config.models.webSearch ?? config.models.chat
        return ResolvedChatRuntimeRoute(
            provider: try await chatProvider(for: ref),
            model: ref.model)
    }

    /// Runs a minimal model-backed request and returns a user-facing diagnostic
    /// without exposing secrets. This is intended for Settings/CLI health checks,
    /// not for normal chat history.
    public func healthCheck(role: ProviderHealthRole = .chat,
                            options: ProviderHealthCheckOptions = ProviderHealthCheckOptions()) async -> ProviderHealthReport {
        let start = Date()
        let ref = role == .agent ? (config.models.agent ?? config.models.chat) : config.models.chat
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            return ProviderHealthChecker.failed(
                role: role,
                endpointID: ref.endpoint,
                model: ref.model,
                wire: nil,
                code: "config",
                message: "unknown endpoint '\(ref.endpoint)'",
                startedAt: start)
        }

        do {
            let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
            switch endpoint.wire {
            case .openai:
                let runtimePolicy: ProviderRuntimePolicy = role == .agent
                    ? .agentStreaming
                    : .streaming
                let provider = OpenAIWireProvider(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    http: http,
                    runtimePolicy: runtimePolicy,
                    toolCallingCapabilities:
                        toolCallingCapabilities(
                            endpoint: endpoint,
                            model: ref.model))
                switch role {
                case .chat:
                    var report = await ProviderHealthChecker.checkChat(
                        provider: provider,
                        endpoint: endpoint,
                        model: ref.model,
                        options: options,
                        startedAt: start)
                    report.endpointID = endpoint.id
                    report.wire = endpoint.wire
                    return report
                case .agent:
                    var report = await ProviderHealthChecker.checkAgent(
                        provider: provider,
                        endpoint: endpoint,
                        model: ref.model,
                        options: options,
                        startedAt: start)
                    report.endpointID = endpoint.id
                    report.wire = endpoint.wire
                    return report
                }
            }
        } catch {
            return ProviderHealthChecker.failed(
                role: role,
                endpoint: endpoint,
                model: ref.model,
                error: error,
                startedAt: start)
        }
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
            return OpenAIWireProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                http: http,
                runtimePolicy: .agentStreaming,
                toolCallingCapabilities:
                    toolCallingCapabilities(
                        endpoint: endpoint,
                        model: ref.model))
        }
    }

    /// Resolves an exact immutable profile revision. No current/default profile
    /// is consulted, and credentials are requested only after exact resolution
    /// and capability validation succeed.
    public func agentInference(for ref: InferenceProfileRef) async throws -> ResolvedInferenceProfile {
        guard let inferenceCatalogSnapshot else {
            throw InferenceCatalogError.unresolvedProfile
        }
        let resolution = try inferenceCatalogSnapshot.resolve(ref)
        return try await makeAgentInference(from: resolution)
    }

    /// Recovery path that additionally revalidates every durable binding field
    /// and its immutable-definition fingerprint before resolving a credential.
    public func agentInference(for binding: AgentInferenceBinding) async throws -> ResolvedInferenceProfile {
        guard let inferenceCatalogSnapshot else {
            throw InferenceCatalogError.unresolvedProfile
        }
        let resolution = try inferenceCatalogSnapshot.resolve(binding)
        return try await makeAgentInference(from: resolution)
    }

    /// The default agent provider, from `models.agent` (falling back to `models.chat`).
    public func defaultAgentProvider() async throws -> ToolCallingProvider {
        try await agentProvider(for: config.models.agent ?? config.models.chat)
    }

    public func defaultAgentRuntimeRoute() async throws
        -> ResolvedAgentRuntimeRoute
    {
        let legacyRef = config.models.agent ?? config.models.chat
        return try await agentRuntimeRoute(for: legacyRef)
    }

    /// Resolves the provider, exact selected model, and optional context
    /// metadata as one route. This overload preserves CLI `/model` switching:
    /// the endpoint remains the configured agent endpoint while catalog
    /// metadata is attached only for one unambiguous matching base profile.
    public func agentRuntimeRoute(model: ModelID) async throws
        -> ResolvedAgentRuntimeRoute
    {
        let configured = config.models.agent ?? config.models.chat
        return try await agentRuntimeRoute(
            for: ModelRef(
                endpoint: configured.endpoint,
                model: model))
    }

    public func agentRuntimeRoute(for legacyRef: ModelRef) async throws
        -> ResolvedAgentRuntimeRoute
    {
        if let inferenceCatalogSnapshot {
            let candidates = inferenceCatalogSnapshot.catalog
                .currentProfileRefs.compactMap { profileRef
                    -> InferenceProfileRef? in
                    guard let profile = try? inferenceCatalogSnapshot
                            .profile(for: profileRef),
                          profile.modelID == legacyRef.model,
                          profile.variantID == nil,
                          profile.connectionRef
                            .inferenceConnectionID.rawValue
                            == legacyRef.endpoint else {
                        return nil
                    }
                    return profileRef
                }
            if candidates.count == 1,
               let profileRef = candidates.first {
                let resolved = try await agentInference(
                    for: profileRef)
                return ResolvedAgentRuntimeRoute(
                    provider: resolved.provider,
                    model: resolved.model,
                    modelContextPolicy:
                        resolved.modelContextPolicy)
            }
        }
        return ResolvedAgentRuntimeRoute(
            provider: try await agentProvider(for: legacyRef),
            model: legacyRef.model,
            modelContextPolicy: .unspecified)
    }

    public func agentModel() -> ModelID {
        (config.models.agent ?? config.models.chat).model
    }

    private func makeAgentInference(
        from resolution: InferenceProfileResolution
    ) async throws -> ResolvedInferenceProfile {
        let profile = resolution.profile
        if !profile.declaredCapabilities.isEmpty,
           !profile.declaredCapabilities.contains(where: { $0 == .toolCalling }) {
            throw InferenceCatalogError.incompatibleProfileCapability
        }

        let connection = resolution.connection
        let apiKey = try await resolver.secret(for: connection.credentialRef)
        let endpoint = ProviderEndpoint(
            id: connection.connectionRef.inferenceConnectionID.rawValue,
            baseURL: connection.baseURL,
            chatEndpoint: connection.chatEndpoint,
            apiKeyRef: connection.credentialRef,
            wire: connection.wire,
            requestAdapter:
                profile.requestAdapter,
            modelRequestOptions: [
                profile.modelID.rawValue:
                    profile.effectiveRequestOptions,
            ],
            modelCapabilities: [
                profile.modelID.rawValue:
                    profile.declaredCapabilities,
            ])
        let provider: ToolCallingProvider
        switch connection.wire {
        case .openai:
            provider = OpenAIWireProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                http: http,
                runtimePolicy: .agentStreaming,
                toolCallingCapabilities:
                    toolCallingCapabilities(
                        endpoint: endpoint,
                        model: profile.modelID))
        }
        return ResolvedInferenceProfile(
            binding: resolution.binding,
            model: profile.modelID,
            provider: provider,
            modelContextPolicy: profile.modelContextPolicy)
    }

    private func toolCallingCapabilities(
        endpoint: ProviderEndpoint,
        model: ModelID
    ) -> ToolCallingProviderCapabilities {
        ToolCallingProviderCapabilities(
            supportsToolSearch:
                endpoint.capabilities(for: model)
                    .contains(.toolSearch))
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
