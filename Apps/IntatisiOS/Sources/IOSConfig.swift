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

    // User-configurable endpoint + model (persisted in UserDefaults).
    private static let baseURLKey = "intatis.baseURL"
    private static let modelKey = "intatis.model"
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }
    static var chatModelName: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

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
            baseURL: URL(string: baseURL) ?? URL(string: defaultBaseURL)!,
            apiKeyRef: KeychainRef(service: keychainService, account: keychainAccount),
            wire: .openai
        )
        let chat = ModelRef(endpoint: "default", model: ModelID(rawValue: chatModelName))
        var models = ResolvedModels(chat: chat, agent: chat)
        models.imageGen = ModelRef(endpoint: "default", model: ModelID(rawValue: "dall-e-3"))
        models.transcription = ModelRef(endpoint: "default", model: ModelID(rawValue: "whisper-1"))
        return ProviderConfig(endpoints: [endpoint], models: models)
    }
}
#endif
