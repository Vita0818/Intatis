import Foundation

/// What a model/endpoint can do. Intatis is capability-based, not "chat
/// completion shaped" (ARCHITECTURE.md §3.3, §9.2). v0.1 only exercises `.chat`,
/// but the vocabulary is fixed so multimodal providers slot in later without
/// reshaping the registry.
public enum Capability: String, Codable, Sendable, CaseIterable {
    case chat
    case toolCalling = "tool_calling"
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
