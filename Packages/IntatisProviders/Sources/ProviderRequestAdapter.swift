import Foundation
import IntatisCore

/// The provider SDK package whose option semantics a route was configured for.
///
/// Intatis remains Swift-native and does not execute npm packages. The package
/// name selects a reviewed Swift lowering that mirrors the corresponding
/// OpenCode/AI SDK boundary. Unknown package names are retained for lossless
/// configuration and durable identity, but fail closed before network I/O.
public struct ProviderRequestAdapter:
    RawRepresentable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let openAICompatible = ProviderRequestAdapter(
        rawValue: "@ai-sdk/openai-compatible")
    public static let openRouter = ProviderRequestAdapter(
        rawValue: "@openrouter/ai-sdk-provider")
    public static let openAI = ProviderRequestAdapter(
        rawValue: "@ai-sdk/openai")

    /// Missing adapter fields in previously persisted Intatis values decode to
    /// the pre-adapter request behavior. New OpenCode-shaped configuration must
    /// always freeze an explicit package instead.
    public static let legacyOpenAIWire = ProviderRequestAdapter(
        rawValue: "intatis:legacy-openai-wire")

    public let rawValue: String

    public init(rawValue: String) {
        // Package identity is configuration data, not a display label.
        // Preserve it byte-for-byte; an empty or whitespace-only explicit
        // value is unsupported and must fail closed instead of being fixed up.
        self.rawValue = rawValue
    }

    /// OpenCode's default for a custom provider when no provider/model npm
    /// package is configured.
    public static func configuredProvider(
        _ rawValue: String?
    ) -> ProviderRequestAdapter {
        guard let rawValue else {
            return .openAICompatible
        }
        // OpenCode uses nullish selection, not an empty-string fallback.
        // Preserve an explicitly empty value so it fails closed as an
        // unsupported package instead of silently changing adapter semantics.
        return ProviderRequestAdapter(rawValue: rawValue)
    }

    /// A model-level package is an override whenever the field is present.
    /// Only a missing (`nil`) field leaves the provider-level adapter in force.
    public static func configuredModelOverride(
        _ rawValue: String?
    ) -> ProviderRequestAdapter? {
        guard let rawValue else {
            return nil
        }
        // As above, an explicitly empty model package remains an exact
        // override and is rejected at the request boundary.
        return ProviderRequestAdapter(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ProviderChatCompletionsAdapter: Equatable {
    case legacyOpenAIWire
    case openAICompatible
    case openRouter
}

extension ProviderRequestAdapter {
    /// Resolves only adapters whose Chat Completions behavior is implemented by
    /// the native runtime. No package-name or endpoint-name fallback is used.
    func chatCompletionsAdapter()
        throws -> ProviderChatCompletionsAdapter
    {
        switch self {
        case .legacyOpenAIWire:
            return .legacyOpenAIWire
        case .openAICompatible:
            return .openAICompatible
        case .openRouter:
            return .openRouter
        case .openAI:
            throw IntatisError.config(
                "the selected @ai-sdk/openai package adapter is not implemented by the native request runtime")
        default:
            throw IntatisError.config(
                "the selected provider npm adapter is not supported by the native runtime")
        }
    }
}
