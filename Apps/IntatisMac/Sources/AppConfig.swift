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
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKeyRef: KeychainRef(service: keychainService, account: keychainAccount),
            wire: .openai
        )
        let models = ResolvedModels(
            chat: ModelRef(endpoint: "default", model: ModelID(rawValue: "gpt-4o-mini"))
        )
        return ProviderConfig(endpoints: [endpoint], models: models)
    }
}
#endif
