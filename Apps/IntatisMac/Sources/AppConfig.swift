#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders

/// v0.1 app configuration. Defaults to an OpenAI endpoint; the API key lives in
/// the keychain (entered on first launch). The macOS build runs as the
/// sandboxed App Store profile by default (no shell) — see ARCHITECTURE.md §9.1.
enum AppConfig {
    static let keychainService = "com.intatis.app"
    static let keychainAccount = "default-openai"

    /// Switch to `.macDeveloperID` for the notarized, shell-enabled build.
    static let platformProfile: PlatformProfile = .macAppStore

    static let defaultSession = SessionID(rawValue: "sess_default")

    // User-configurable endpoint + model (persisted in UserDefaults). This is what
    // makes the GUI vendor-agnostic — point baseURL at any OpenAI-compatible server.
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
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Intatis", isDirectory: true)
    }

    static func sessionFile(_ session: SessionID) -> URL {
        appSupportDir()
            .appendingPathComponent(session.rawValue, isDirectory: true)
            .appendingPathComponent("events.jsonl")
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
        // image + transcription default to the same endpoint.
        models.imageGen = ModelRef(endpoint: "default", model: ModelID(rawValue: "dall-e-3"))
        models.transcription = ModelRef(endpoint: "default", model: ModelID(rawValue: "whisper-1"))
        return ProviderConfig(endpoints: [endpoint], models: models)
    }
}
#endif
