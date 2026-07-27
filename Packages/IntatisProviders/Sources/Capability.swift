import Foundation
import IntatisProtocol

/// What a model/endpoint can do. Intatis is capability-based, not "chat
/// completion shaped" (ARCHITECTURE.md §3.3, §9.2). v0.1 only exercises `.chat`,
/// but the vocabulary is fixed so multimodal providers slot in later without
/// reshaping the registry.
public enum Capability:
    String, Codable, Sendable, CaseIterable, Hashable {
    case chat
    case toolCalling = "tool_calling"
    /// The exact model/provider route supports the Responses `tool_search`
    /// contract, including namespaced deferred tool definitions.
    case toolSearch = "tool_search"
    case visionInput = "vision_input"
    case realtimeTranscription = "realtime_transcription"
    case audioInput = "audio_input"
    case audioOutput = "audio_output"
    case imageGeneration = "image_generation"
    case imageEditing = "image_editing"
    case videoGeneration = "video_generation"
    case videoEditing = "video_editing"
    case embedding
}

/// Parses only explicit, non-secret model metadata. `supports_search_tool`
/// matches Codex model metadata naming; the optional `capabilities` array uses
/// Intatis `Capability.rawValue` values. An explicit false value wins over the
/// array so contradictory configuration fails closed.
public enum ModelCapabilityMetadata {
    public static func declaredCapabilities(
        in metadata: [String: JSONValue],
        defaults: [Capability] = [
            .chat,
            .toolCalling,
        ]
    ) -> [Capability] {
        var capabilities = Set(defaults)
        if case .array(let values) =
            metadata["capabilities"] {
            for value in values {
                guard case .string(let raw) = value,
                      let capability = Capability(
                        rawValue: raw) else {
                    continue
                }
                capabilities.insert(capability)
            }
        }
        if case .bool(let supportsSearch) =
            metadata["supports_search_tool"] {
            if supportsSearch {
                capabilities.insert(.toolSearch)
            } else {
                capabilities.remove(.toolSearch)
            }
        }
        return Capability.allCases.filter(
            capabilities.contains)
    }
}
