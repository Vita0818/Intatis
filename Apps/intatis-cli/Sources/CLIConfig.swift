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

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    static func load() throws -> CLIConfig {
        let env = ProcessInfo.processInfo.environment
        let file = ConfigFile.read()
        func value(_ envKey: String, _ fileKey: String, fallback: String?) -> String? {
            if let e = env[envKey], !e.isEmpty { return e }
            if let f = file[fileKey], !f.isEmpty { return f }
            return fallback
        }

        let baseString = value("INTATIS_BASE_URL", "baseURL", fallback: defaultBaseURL)!
        guard let baseURL = URL(string: baseString) else {
            throw IntatisError.config("invalid base URL: \(baseString)")
        }
        guard let apiKey = value("INTATIS_API_KEY", "apiKey", fallback: nil), !apiKey.isEmpty else {
            throw IntatisError.config("no API key — run `intatis settings`, or set INTATIS_API_KEY")
        }
        let model = value("INTATIS_MODEL", "model", fallback: defaultModel)!
        let reasoning = value("INTATIS_REASONING", "reasoning", fallback: nil)
            .flatMap { ReasoningEffort(rawValue: $0.lowercased()) }
        let mode = Mode(rawValue: value("INTATIS_MODE", "mode", fallback: "chat")!.lowercased()) ?? .chat

        return CLIConfig(baseURL: baseURL, apiKey: apiKey, model: model, wire: .openai,
                         reasoningEffort: reasoning, mode: mode)
    }

    func providerConfig() -> ProviderConfig {
        let endpoint = ProviderEndpoint(
            id: "cli", baseURL: baseURL,
            apiKeyRef: KeychainRef(service: "intatis-cli", account: "cli"), wire: wire)
        let ref = ModelRef(endpoint: "cli", model: ModelID(rawValue: model))
        return ProviderConfig(endpoints: [endpoint], models: ResolvedModels(chat: ref, agent: ref))
    }
}

struct StaticSecretResolver: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}
