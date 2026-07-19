import Foundation
import IntatisCore
import IntatisProviders

enum Mode: String { case chat, code, cowork }

/// Persistent config at `~/.config/intatis/config.json` (all values are strings).
/// `intatis settings` writes it; env vars override it; both override defaults.
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/intatis/config.json")
    }

    static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        return obj
    }

    static func write(_ dict: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Connect to ANY OpenAI-compatible endpoint. Resolution precedence per field:
/// environment variable → config file → built-in default.
struct CLIConfig {
    let baseURL: URL
    let apiKey: String
    let model: String
    let wire: WireFormat
    let reasoningEffort: ReasoningEffort?
    let mode: Mode
    let includeUsage: Bool
    let maxSteps: Int
    /// Every host-configured route eligible for this CLI process. Chat/Code
    /// continue to use the selected route while Cowork compiles all routes into
    /// exact, versioned inference profiles.
    let providerRoutes: [CLIProviderRoute]
    let selectedProviderID: String
    let selectedVariantID: String?
    /// The explicitly selected Intatis config is retained only so a lazy
    /// `providerConfig` credential reference can be revalidated. It is never
    /// copied into EventLog/profile bindings or printed by the CLI.
    let configurationFileURL: URL?

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    init(baseURL: URL,
         apiKey: String,
         model: String,
         wire: WireFormat,
         reasoningEffort: ReasoningEffort?,
         mode: Mode,
         includeUsage: Bool,
         maxSteps: Int,
         providerRoutes: [CLIProviderRoute]? = nil,
         selectedProviderID: String? = nil,
         selectedVariantID: String? = nil,
         configurationFileURL: URL? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.wire = wire
        self.reasoningEffort = reasoningEffort
        self.mode = mode
        self.includeUsage = includeUsage
        self.maxSteps = maxSteps
        let legacy = CLIProviderRoute.legacy(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            wire: wire)
        self.providerRoutes = providerRoutes?.isEmpty == false ? providerRoutes! : [legacy]
        self.selectedProviderID = selectedProviderID ?? legacy.id
        self.selectedVariantID = selectedVariantID
        self.configurationFileURL = configurationFileURL
    }

    static func load() throws -> CLIConfig {
        let env = ProcessInfo.processInfo.environment
        if let modernURL = CLIModernProviderConfig.existingURL(environment: env) {
            return try load(configurationFileURL: modernURL, environment: env)
        }
        let file = ConfigFile.read()
        func value(_ envKey: String, _ fileKey: String, fallback: String?) -> String? {
            if let e = env[envKey], !e.isEmpty { return e }
            if let f = file[fileKey], !f.isEmpty { return f }
            return fallback
        }

        let baseString = value("INTATIS_BASE_URL", "baseURL", fallback: defaultBaseURL)!
        guard let baseURL = CLIProviderRoute.validHTTPURL(baseString) else {
            throw IntatisError.config("invalid CLI provider endpoint")
        }
        guard let apiKey = value("INTATIS_API_KEY", "apiKey", fallback: nil), !apiKey.isEmpty else {
            throw IntatisError.config("no API key — run `intatis settings`, or set INTATIS_API_KEY")
        }
        let model = value("INTATIS_MODEL", "model", fallback: defaultModel)!
        let rawReasoning = value("INTATIS_REASONING", "reasoning", fallback: nil)
        let reasoning = try parsedReasoningEffort(rawReasoning)
        let mode = Mode(rawValue: value("INTATIS_MODE", "mode", fallback: "chat")!.lowercased()) ?? .chat
        // Ask the endpoint for token usage (default on). Set INTATIS_USAGE=0 if an
        // endpoint rejects the stream_options field.
        let usageStr = value("INTATIS_USAGE", "usage", fallback: "1")!.lowercased()
        let includeUsage = !(usageStr == "0" || usageStr == "false" || usageStr == "off")
        // How many tool round-trips one turn may take before giving up. Long
        // agentic tasks need plenty; override with INTATIS_MAX_STEPS.
        let maxSteps = max(1, Int(value("INTATIS_MAX_STEPS", "maxSteps", fallback: "50")!) ?? 50)

        return CLIConfig(baseURL: baseURL, apiKey: apiKey, model: model, wire: .openai,
                         reasoningEffort: reasoning, mode: mode, includeUsage: includeUsage,
                         maxSteps: maxSteps,
                         selectedVariantID: reasoning.map { "reasoning-\($0.rawValue)" })
    }

    /// Deterministic seam used by the offline self-test and by `INTATIS_CONFIG`.
    /// The schema is the same Intatis/OpenCode-compatible provider map used by
    /// the macOS app; no CLI-only provider format is introduced.
    static func load(configurationFileURL: URL,
                     environment: [String: String]) throws -> CLIConfig {
        let document = try CLIModernProviderConfig.load(
            from: configurationFileURL,
            environment: environment)
        func value(_ envKey: String, fallback: String?) -> String? {
            if let e = environment[envKey], !e.isEmpty { return e }
            return fallback
        }

        let requestedModel = value(
            "INTATIS_MODEL",
            fallback: document.selectedModelID) ?? document.selectedModelID
        var selectedProviderID = document.selectedProviderID
        var selectedModelID = requestedModel
        if let split = try document.providerQualifiedModel(requestedModel) {
            selectedProviderID = split.providerID
            selectedModelID = split.modelID
        } else {
            // An unqualified host override may name a model that exists on one
            // configured route other than the document default. Preserve that
            // exact route instead of silently inventing the model on the
            // current provider. Ambiguous IDs stay on the explicitly selected
            // provider when possible; otherwise the host must qualify them.
            let matchingRoutes = document.routes.filter { route in
                route.models.contains(where: { $0.id == requestedModel })
            }
            if matchingRoutes.count == 1, let only = matchingRoutes.first {
                selectedProviderID = only.id
            } else if matchingRoutes.count > 1,
                      !matchingRoutes.contains(where: { $0.id == selectedProviderID }) {
                throw IntatisError.config(
                    "ambiguous CLI model override; qualify it with a provider ID")
            }
        }

        guard var selectedRoute = document.routes.first(where: {
            $0.id == selectedProviderID
        }) ?? document.routes.first else {
            throw IntatisError.config("no usable CLI provider routes")
        }
        if !selectedRoute.models.contains(where: { $0.id == selectedModelID }) {
            selectedRoute.models.append(CLIProviderModel(
                id: selectedModelID,
                displayName: selectedModelID))
        }

        var routes = document.routes
        if let baseOverride = environment["INTATIS_BASE_URL"], !baseOverride.isEmpty {
            guard let url = CLIProviderRoute.validHTTPURL(baseOverride) else {
                throw IntatisError.config("invalid CLI provider endpoint")
            }
            selectedRoute.baseURL = url
            selectedRoute.chatEndpoint = nil
        }
        let selectedInlineKey = environment["INTATIS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedInlineKey, !selectedInlineKey.isEmpty {
            selectedRoute.credentialRef = CLIInferenceRouteIdentity.inlineCredentialRef(
                routeID: selectedRoute.id,
                baseURL: selectedRoute.baseURL,
                wire: selectedRoute.wire)
            selectedRoute.inlineSecret = selectedInlineKey
        }
        if let index = routes.firstIndex(where: { $0.id == selectedRoute.id }) {
            routes[index] = selectedRoute
        }

        let rawReasoning = value("INTATIS_REASONING", fallback: nil)
        let reasoning = try parsedReasoningEffort(rawReasoning)
        let mode = Mode(rawValue: value("INTATIS_MODE", fallback: "chat")!.lowercased()) ?? .chat
        let usageStr = value("INTATIS_USAGE", fallback: "1")!.lowercased()
        let includeUsage = !(usageStr == "0" || usageStr == "false" || usageStr == "off")
        let maxSteps = max(1, Int(value("INTATIS_MAX_STEPS", fallback: "50")!) ?? 50)
        let selectedVariantID = try document.selectedVariantID(
            providerID: selectedRoute.id,
            modelID: selectedModelID,
            reasoningEffort: reasoning)
        if let reasoning,
           selectedVariantID == nil,
           !document.baseModel(
                providerID: selectedRoute.id,
                modelID: selectedModelID,
                hasReasoningEffort: reasoning) {
            throw IntatisError.config(
                "selected CLI reasoning effort has no configured variant for the selected model")
        }

        return CLIConfig(
            baseURL: selectedRoute.baseURL,
            apiKey: selectedRoute.inlineSecret ?? "",
            model: selectedModelID,
            wire: selectedRoute.wire,
            reasoningEffort: reasoning,
            mode: mode,
            includeUsage: includeUsage,
            maxSteps: maxSteps,
            providerRoutes: routes,
            selectedProviderID: selectedRoute.id,
            selectedVariantID: selectedVariantID,
            configurationFileURL: configurationFileURL.standardizedFileURL)
    }

    private static func parsedReasoningEffort(_ raw: String?) throws -> ReasoningEffort? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard let effort = ReasoningEffort(rawValue: normalized) else {
            throw IntatisError.config("invalid CLI reasoning effort")
        }
        return effort
    }

    func providerConfig() -> ProviderConfig {
        let endpoints = providerRoutes.map { route in
            ProviderEndpoint(
                id: CLIInferenceRouteIdentity.endpointID(route: route),
                baseURL: route.baseURL,
                chatEndpoint: route.chatEndpoint,
                apiKeyRef: route.credentialRef,
                wire: route.wire,
                modelRequestOptions: Dictionary(uniqueKeysWithValues: route.models.map {
                    ($0.id, $0.requestOptions)
                }))
        }
        let selectedRoute = providerRoutes.first { $0.id == selectedProviderID }
            ?? providerRoutes[0]
        let ref = ModelRef(
            endpoint: CLIInferenceRouteIdentity.endpointID(route: selectedRoute),
            model: ModelID(rawValue: model))
        return ProviderConfig(endpoints: endpoints, models: ResolvedModels(chat: ref, agent: ref))
    }

    var selectedRouteLabel: String {
        let route = providerRoutes.first { $0.id == selectedProviderID } ?? providerRoutes[0]
        return route.safeDisplayName
    }

    var hasConfiguredCredential: Bool {
        let route = providerRoutes.first { $0.id == selectedProviderID } ?? providerRoutes[0]
        return route.inlineSecret?.isEmpty == false || route.credentialRef.source != .keychain
    }
}
