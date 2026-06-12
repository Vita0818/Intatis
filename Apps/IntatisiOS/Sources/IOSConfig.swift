#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders

/// iOS app configuration. Mirrors the macOS chat config; there is deliberately no
/// workspace/shell/agent setup — iOS is the chat-only subset (ARCHITECTURE.md §4).
enum IOSConfig {
    static let keychainService = "com.intatis.ios"
    static let keychainAccount = "default-openai"
    static let defaultSession = SessionID(rawValue: "sess_ios")

    static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Intatis", isDirectory: true)
    }

    static func sessionFile() -> URL {
        appSupportDir().appendingPathComponent(defaultSession.rawValue, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    static func artifactsDir() -> URL {
        appSupportDir().appendingPathComponent(defaultSession.rawValue, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    static func providerConfig() -> ProviderConfig {
        let endpoint = ProviderEndpoint(
            id: "default",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKeyRef: KeychainRef(service: keychainService, account: keychainAccount),
            wire: .openai
        )
        var models = ResolvedModels(chat: ModelRef(endpoint: "default", model: ModelID(rawValue: "gpt-4o-mini")))
        models.imageGen = ModelRef(endpoint: "default", model: ModelID(rawValue: "dall-e-3"))
        models.transcription = ModelRef(endpoint: "default", model: ModelID(rawValue: "whisper-1"))
        return ProviderConfig(endpoints: [endpoint], models: models)
    }
}
#endif
