import Foundation
import IntatisCore
import IntatisProtocol

/// One exact Responses API route prepared for an external, process-hosted
/// runtime. The credential exists only in memory and is deliberately redacted
/// from every textual representation.
public struct ResponsesRuntimeRoute: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let endpointID: String
    public let model: ModelID
    public let baseURL: URL
    public let queryParameters: [String: String]
    public let bearerToken: String
    public let reasoningEffort: String?
    public let providerOptions: [String: JSONValue]?

    public init(
        endpointID: String,
        model: ModelID,
        baseURL: URL,
        queryParameters: [String: String] = [:],
        bearerToken: String,
        reasoningEffort: String? = nil,
        providerOptions: [String: JSONValue]? = nil
    ) {
        self.endpointID = endpointID
        self.model = model
        self.baseURL = baseURL
        self.queryParameters = queryParameters
        self.bearerToken = bearerToken
        self.reasoningEffort = reasoningEffort
        self.providerOptions = providerOptions
    }

    public var description: String {
        "ResponsesRuntimeRoute(endpoint: \(endpointID), model: \(model.rawValue), baseURL: <configured>, credential: <redacted>)"
    }

    public var debugDescription: String { description }
}

public extension ProviderRegistry {
    /// Resolves one exact durable Cowork inference binding onto the same
    /// immutable connection/profile revision used by Intatis. The catalog
    /// connection stores an API base URL, so Codex appends `/responses`
    /// directly and no endpoint adapter is introduced.
    func responsesRuntimeRoute(for binding: AgentInferenceBinding)
        async throws -> ResponsesRuntimeRoute
    {
        guard let inferenceCatalogSnapshot else {
            throw InferenceCatalogError.unresolvedProfile
        }
        let resolution = try inferenceCatalogSnapshot.resolve(binding)
        guard resolution.binding == binding,
              resolution.connection.wire == WireFormat.openai else {
            throw InferenceCatalogError.bindingMismatch
        }
        guard var components = URLComponents(
            url: resolution.connection.baseURL,
            resolvingAgainstBaseURL: false),
              (components.scheme?.lowercased() == "http"
                || components.scheme?.lowercased() == "https"),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw InferenceCatalogError.invalidConnection
        }
        var queryParameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value,
                  item.name.lowercased() == "api-version",
                  queryParameters[item.name] == nil else {
                throw InferenceCatalogError.invalidConnection
            }
            queryParameters[item.name] = value
        }
        components.query = nil
        guard let baseURL = components.url else {
            throw InferenceCatalogError.invalidConnection
        }
        let projectedOptions = try codexRequestOptions(
            from: resolution.profile.effectiveRequestOptions,
            requestAdapter: resolution.profile.requestAdapter)
        let rawCredential = try await resolver.secret(
            for: resolution.connection.credentialRef)
        let bearerToken = ProviderAuthorization.bearerToken(
            from: rawCredential)
        guard !bearerToken.isEmpty else {
            throw InferenceCatalogError.invalidConnection
        }
        return ResponsesRuntimeRoute(
            endpointID: resolution.connection.connectionRef
                .inferenceConnectionID.rawValue,
            model: resolution.profile.modelID,
            baseURL: baseURL,
            queryParameters: queryParameters,
            bearerToken: bearerToken,
            reasoningEffort: projectedOptions.reasoningEffort,
            providerOptions: projectedOptions.providerOptions)
    }

    /// Resolves the currently selected agent route for a native Responses API
    /// consumer. No Chat Completions translation is attempted: an explicitly
    /// configured Responses URL must end in `/responses`, and an omitted URL
    /// uses the endpoint's normal `baseURL/responses` convention.
    func responsesRuntimeRoute(model overrideModel: ModelID? = nil)
        async throws -> ResponsesRuntimeRoute
    {
        let selected = config.models.agent ?? config.models.chat
        return try await responsesRuntimeRoute(for: ModelRef(
            endpoint: selected.endpoint,
            model: overrideModel ?? selected.model))
    }

    /// Resolves an exact provider/model pair without consulting a UI default.
    func responsesRuntimeRoute(for ref: ModelRef)
        async throws -> ResponsesRuntimeRoute
    {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config(
                "unknown endpoint '\(ref.endpoint)'")
        }
        guard endpoint.wire == .openai else {
            throw IntatisError.config(
                "endpoint '\(endpoint.id)' does not expose an OpenAI Responses wire")
        }

        let responsesURL = try endpoint.validatedResponsesURL(
            operation: "Codex Runtime")
        let baseURL: URL
        if endpoint.responsesEndpoint != nil {
            let component = responsesURL.lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard component == "responses" else {
                throw IntatisError.config(
                    "endpoint '\(endpoint.id)' has a custom Responses URL that does not end in /responses; Codex App Server accepts a Responses API base URL and performs no protocol translation")
            }
            baseURL = responsesURL.deletingLastPathComponent()
        } else {
            baseURL = endpoint.baseURL
        }

        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http"
                || components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw IntatisError.config(
                "endpoint '\(endpoint.id)' has an invalid Responses API base URL")
        }

        var queryParameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value,
                  item.name.lowercased() == "api-version",
                  queryParameters[item.name] == nil else {
                throw IntatisError.config(
                    "endpoint '\(endpoint.id)' has unsupported Responses query parameters; only a non-secret api-version parameter is accepted")
            }
            queryParameters[item.name] = value
        }
        components.query = nil
        guard let normalizedBaseURL = components.url else {
            throw IntatisError.config(
                "endpoint '\(endpoint.id)' has an invalid Responses API base URL")
        }

        let projectedOptions = try codexRequestOptions(
            from: endpoint.requestOptions(for: ref.model),
            requestAdapter: endpoint.requestAdapter(for: ref.model))
        let rawCredential = try await resolver.secret(for: endpoint.apiKeyRef)
        let bearerToken = ProviderAuthorization.bearerToken(
            from: rawCredential)
        guard !bearerToken.isEmpty else {
            throw IntatisError.config(
                "endpoint '\(endpoint.id)' has an empty Responses API credential")
        }

        return ResponsesRuntimeRoute(
            endpointID: endpoint.id,
            model: ref.model,
            baseURL: normalizedBaseURL,
            queryParameters: queryParameters,
            bearerToken: bearerToken,
            reasoningEffort: projectedOptions.reasoningEffort,
            providerOptions: projectedOptions.providerOptions)
    }
}

private struct CodexRequestOptions {
    let reasoningEffort: String?
    let providerOptions: [String: JSONValue]?
}

private func codexRequestOptions(
    from options: [String: JSONValue],
    requestAdapter: ProviderRequestAdapter
) throws -> CodexRequestOptions {
    var remaining = options
    var candidates: [String] = []
    for key in ["reasoningEffort", "reasoning_effort"] {
        if let value = remaining.removeValue(forKey: key) {
            guard case .string(let effort) = value else {
                throw IntatisError.config(
                    "Codex Runtime reasoning effort must be a string")
            }
            candidates.append(effort)
        }
    }
    if let reasoning = remaining.removeValue(forKey: "reasoning") {
        guard case .object(let object) = reasoning,
              object.count == 1,
              case .string(let effort)? = object["effort"] else {
            throw IntatisError.config(
                "Codex Runtime supports only reasoning.effort from model request options")
        }
        candidates.append(effort)
    }
    var providerOptions: [String: JSONValue]?
    if let provider = remaining.removeValue(forKey: "provider") {
        guard requestAdapter == .openRouter,
              case .object(let object) = provider else {
            throw IntatisError.config(
                "Codex Runtime can project provider options only for an exact OpenRouter adapter and JSON object")
        }
        try InferenceRequestOptionValidation
            .validateProviderPassthrough(object)
        providerOptions = object
    }
    guard remaining.isEmpty else {
        throw IntatisError.config(
            "The selected model has non-provider request options that Codex Runtime 0.145.0-intatis.2 cannot project")
    }
    let normalized = candidates.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    guard Set(normalized).count <= 1 else {
        throw IntatisError.config(
            "The selected model has conflicting Codex reasoning effort options")
    }
    if let effort = normalized.first {
        guard [
            "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
        ].contains(effort) else {
            throw IntatisError.config(
                "The selected model has an unsupported Codex reasoning effort")
        }
    }
    return CodexRequestOptions(
        reasoningEffort: normalized.first,
        providerOptions: providerOptions)
}
