#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders

struct AppSessionSummary: Identifiable, Equatable {
    let id: SessionID
    let kind: SessionKind
    let updatedAt: Date
    let eventCount: Int
}

struct AppProviderModel: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }
}

struct AppProviderAPIKeySource: Codable, Equatable {
    var type: String
    var value: String

    static func environment(_ name: String) -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "env", value: name)
    }

    static func file(_ path: String) -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "file", value: path)
    }

    static func authFile() -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "authFile", value: "")
    }

    private var normalizedType: String {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "env", "environment":
            return "env"
        case "file", "path":
            return "file"
        case "authfile", "auth_file", "auth-json", "authjson", "json":
            return "authFile"
        default:
            return "keychain"
        }
    }

    func ref(defaultRef: KeychainRef, providerID: String) -> KeychainRef {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedType {
        case "env":
            return trimmed.isEmpty ? defaultRef : .environment(trimmed)
        case "file":
            return trimmed.isEmpty ? defaultRef : .file(trimmed)
        case "authFile":
            return .authFile(providerID: providerID)
        default:
            return defaultRef
        }
    }

    var isKeychain: Bool { normalizedType == "keychain" }

    var openCodeAPIKeyValue: String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch normalizedType {
        case "env":
            return "{env:\(trimmed)}"
        case "file":
            return "{file:\(trimmed)}"
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case value
        case name
        case path
    }

    init(type: String, value: String) {
        self.type = type
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self.type = type
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .path)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(value, forKey: .value)
    }
}

struct AppProviderSettings: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    var baseURL: String
    var chatEndpoint: String
    var apiKeyAccount: String
    var apiKeySource: AppProviderAPIKeySource?
    var models: [AppProviderModel]

    init(id: String,
         displayName: String,
         baseURL: String,
         chatEndpoint: String? = nil,
         apiKeyAccount: String,
         apiKeySource: AppProviderAPIKeySource? = nil,
         models: [AppProviderModel]) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint ?? AppConfig.chatEndpoint(forBaseURL: baseURL)
        self.apiKeyAccount = apiKeyAccount
        self.apiKeySource = apiKeySource
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case chatEndpoint
        case apiKeyAccount
        case apiKeySource
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try container.decode(String.self, forKey: .baseURL)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.baseURL = baseURL
        self.chatEndpoint = try container.decodeIfPresent(String.self, forKey: .chatEndpoint)
            ?? AppConfig.chatEndpoint(forBaseURL: baseURL)
        self.apiKeyAccount = try container.decodeIfPresent(String.self, forKey: .apiKeyAccount)
            ?? (self.id == "default" ? AppConfig.keychainAccount : "provider-\(self.id)")
        self.apiKeySource = try container.decodeIfPresent(AppProviderAPIKeySource.self, forKey: .apiKeySource)
        self.models = try container.decode([AppProviderModel].self, forKey: .models)
    }

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: baseURL)?.host ?? id
    }
}

struct AppProviderCatalog: Codable, Equatable {
    var selectedProviderID: String
    var selectedModelID: String
    var providers: [AppProviderSettings]

    var selectedProvider: AppProviderSettings? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
    }

    var selectedModel: AppProviderModel? {
        guard let provider = selectedProvider else { return nil }
        return provider.models.first { $0.id == selectedModelID } ?? provider.models.first
    }
}

private struct AppProviderSelection: Codable, Equatable {
    var providerID: String
    var modelID: String
}

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
    private static let providerCatalogKey = "intatis.providerCatalog.v1"
    private static let providerSelectionKey = "intatis.providerSelection.v1"
    private static let configEnvKey = "INTATIS_CONFIG"
    private static let defaultProviderID = "default"
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultChatEndpoint = "https://api.openai.com/v1/chat/completions"
    static let defaultModel = "gpt-4o-mini"

    static var baseURL: String {
        get { providerCatalog.selectedProvider?.baseURL ?? defaultBaseURL }
        set {
            var catalog = providerCatalog
            guard let providerID = catalog.selectedProvider?.id,
                  let index = catalog.providers.firstIndex(where: { $0.id == providerID }) else {
                let normalizedBase = baseURL(fromChatEndpoint: newValue)
                UserDefaults.standard.set(normalizedBase, forKey: baseURLKey)
                return
            }
            let normalizedBase = baseURL(fromChatEndpoint: newValue)
            catalog.providers[index].baseURL = normalizedBase
            catalog.providers[index].chatEndpoint = chatEndpoint(forBaseURL: normalizedBase)
            providerCatalog = catalog
            UserDefaults.standard.set(normalizedBase, forKey: baseURLKey)
        }
    }
    static var chatModelName: String {
        get { providerCatalog.selectedModel?.id ?? defaultModel }
        set {
            var catalog = providerCatalog
            guard let providerID = catalog.selectedProvider?.id,
                  let providerIndex = catalog.providers.firstIndex(where: { $0.id == providerID }) else {
                UserDefaults.standard.set(newValue, forKey: modelKey)
                return
            }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = trimmed.isEmpty ? defaultModel : trimmed
            if !catalog.providers[providerIndex].models.contains(where: { $0.id == modelID }) {
                catalog.providers[providerIndex].models.append(
                    AppProviderModel(id: modelID, displayName: defaultDisplayName(for: modelID)))
            }
            catalog.selectedModelID = modelID
            providerCatalog = catalog
            UserDefaults.standard.set(modelID, forKey: modelKey)
        }
    }

    static var chatModelDisplayName: String {
        providerCatalog.selectedModel?.title ?? defaultDisplayName(for: defaultModel)
    }

    static var selectedProviderName: String {
        providerCatalog.selectedProvider?.title ?? "OpenAI"
    }

    static var selectedAPIKeyAccount: String {
        providerCatalog.selectedProvider?.apiKeyAccount ?? keychainAccount
    }

    static var selectedAPIKeyRef: KeychainRef {
        guard let provider = providerCatalog.selectedProvider else {
            return KeychainRef(service: keychainService, account: keychainAccount)
        }
        return apiKeyRef(for: provider)
    }

    static var providerCatalog: AppProviderCatalog {
        get {
            let catalog: AppProviderCatalog
            if let fileCatalog = fileProviderCatalog() {
                catalog = normalizedCatalog(fileCatalog)
            } else if let data = UserDefaults.standard.data(forKey: providerCatalogKey),
                      let decoded = try? JSONDecoder().decode(AppProviderCatalog.self, from: data) {
                catalog = normalizedCatalog(decoded)
            } else {
                catalog = normalizedCatalog(legacyProviderCatalog())
            }
            return applyingStoredSelection(to: catalog)
        }
        set {
            let normalized = normalizedCatalog(newValue)
            if let data = try? JSONEncoder().encode(normalized) {
                UserDefaults.standard.set(data, forKey: providerCatalogKey)
            }
            storeSelection(from: normalized)
            if let provider = normalized.selectedProvider {
                UserDefaults.standard.set(provider.baseURL, forKey: baseURLKey)
            }
            if let model = normalized.selectedModel {
                UserDefaults.standard.set(model.id, forKey: modelKey)
            }
        }
    }

    @discardableResult
    static func selectProviderModel(providerID: String, modelID: String) -> AppProviderCatalog {
        var catalog = providerCatalog
        guard let provider = catalog.providers.first(where: { $0.id == providerID }) else {
            return catalog
        }
        let selectedModelID = provider.models.first { $0.id == modelID }?.id
            ?? provider.models.first?.id
            ?? defaultModel
        catalog.selectedProviderID = provider.id
        catalog.selectedModelID = selectedModelID
        providerCatalog = catalog
        return providerCatalog
    }

    static var externalConfigDescription: String? {
        guard let url = existingConfigFileURL() else { return nil }
        return url.path
    }

    static var editableConfigDescription: String {
        if let existing = existingConfigFileURL(),
           configOverridePath() != nil || isModernConfigFile(existing) {
            return existing.path
        }
        return preferredConfigFileURL().path
    }

    static func prepareEditableConfigFile() throws -> URL {
        if let existing = existingConfigFileURL() {
            if configOverridePath() != nil || isModernConfigFile(existing) {
                return existing
            }
        }

        let preferred = preferredConfigFileURL()
        do {
            try writeConfigTemplate(to: preferred)
            return preferred
        } catch {
            if configOverridePath() != nil {
                throw error
            }
            let fallback = appSupportDir().appendingPathComponent("opencode.json")
            try writeConfigTemplate(to: fallback)
            return fallback
        }
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

    static func recentSessions(kind: SessionKind) -> [AppSessionSummary] {
        let prefix: String
        switch kind {
        case .chat:
            prefix = "sess_"
        case .code:
            prefix = "code_"
        case .cowork:
            prefix = "cowork_"
        }

        let root = appSupportDir()
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return sessions.compactMap { url -> AppSessionSummary? in
            let raw = url.lastPathComponent
            guard raw.hasPrefix(prefix) else { return nil }
            let events = url.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: events.path) else { return nil }
            let values = try? events.resourceValues(forKeys: [.contentModificationDateKey])
            return AppSessionSummary(
                id: SessionID(rawValue: raw),
                kind: kind,
                updatedAt: values?.contentModificationDate ?? .distantPast,
                eventCount: eventCount(in: events))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func providerConfig() -> ProviderConfig {
        let catalog = providerCatalog
        let selectedProvider = catalog.selectedProvider ?? defaultProvider()
        let selectedModel = catalog.selectedModel ?? selectedProvider.models.first
            ?? AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))

        let endpoints = catalog.providers.map { provider in
            ProviderEndpoint(
                id: provider.id,
                baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
                chatEndpoint: URL(string: provider.chatEndpoint),
                apiKeyRef: apiKeyRef(for: provider),
                wire: .openai)
        }
        let chat = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: selectedModel.id))
        var models = ResolvedModels(chat: chat, agent: chat)
        // image + transcription default to the selected endpoint until dedicated
        // role-specific model settings exist.
        models.imageGen = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: "dall-e-3"))
        models.transcription = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: "whisper-1"))
        return ProviderConfig(endpoints: endpoints.isEmpty ? [endpoint(for: selectedProvider)] : endpoints,
                              models: models)
    }

    static func newProvider() -> AppProviderSettings {
        let id = IDGen.random(prefix: "provider")
        return AppProviderSettings(
            id: id,
            displayName: "New Provider",
            baseURL: defaultBaseURL,
            apiKeyAccount: keychainAccount(forProviderID: id),
            models: [AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    static func normalizedCatalog(_ catalog: AppProviderCatalog) -> AppProviderCatalog {
        var seenProviders = Set<String>()
        var providers = catalog.providers.compactMap { provider -> AppProviderSettings? in
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenProviders.contains(id) else { return nil }
            seenProviders.insert(id)

            let baseURL = baseURL(fromChatEndpoint: provider.baseURL)
            let rawChatEndpoint = provider.chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatEndpoint = rawChatEndpoint.isEmpty
                ? chatEndpoint(forBaseURL: baseURL)
                : rawChatEndpoint
            var seenModels = Set<String>()
            let models = provider.models.compactMap { model -> AppProviderModel? in
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelID.isEmpty, !seenModels.contains(modelID) else { return nil }
                seenModels.insert(modelID)
                return AppProviderModel(
                    id: modelID,
                    displayName: model.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !baseURL.isEmpty else { return nil }
            return AppProviderSettings(
                id: id,
                displayName: provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKeyAccount: provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? keychainAccount(forProviderID: id)
                    : provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKeySource: provider.apiKeySource,
                models: models.isEmpty
                    ? [AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))]
                    : models)
        }

        if providers.isEmpty {
            providers = [defaultProvider()]
        }

        let selectedProviderID = providers.first { $0.id == catalog.selectedProviderID }?.id
            ?? providers.first {
                normalizedProviderID($0.id) == normalizedProviderID(catalog.selectedProviderID)
            }?.id
            ?? providers[0].id
        let selectedProvider = providers.first { $0.id == selectedProviderID } ?? providers[0]
        let selectedModelID = selectedProvider.models.contains { $0.id == catalog.selectedModelID }
            ? catalog.selectedModelID
            : selectedProvider.models[0].id

        return AppProviderCatalog(
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            providers: providers)
    }

    private static func legacyProviderCatalog() -> AppProviderCatalog {
        let baseURL = baseURL(fromChatEndpoint: UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL)
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        let provider = AppProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: baseURL,
            chatEndpoint: chatEndpoint(forBaseURL: baseURL),
            apiKeyAccount: keychainAccount,
            models: [AppProviderModel(id: model, displayName: defaultDisplayName(for: model))])
        return AppProviderCatalog(selectedProviderID: provider.id,
                                  selectedModelID: model,
                                  providers: [provider])
    }

    private static func applyingStoredSelection(to catalog: AppProviderCatalog) -> AppProviderCatalog {
        guard let selection = storedSelection(),
              let provider = catalog.providers.first(where: { $0.id == selection.providerID }),
              provider.models.contains(where: { $0.id == selection.modelID }) else {
            return catalog
        }
        var selected = catalog
        selected.selectedProviderID = selection.providerID
        selected.selectedModelID = selection.modelID
        return selected
    }

    private static func storedSelection() -> AppProviderSelection? {
        guard let data = UserDefaults.standard.data(forKey: providerSelectionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AppProviderSelection.self, from: data)
    }

    private static func storeSelection(from catalog: AppProviderCatalog) {
        let selection = AppProviderSelection(providerID: catalog.selectedProviderID,
                                             modelID: catalog.selectedModelID)
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: providerSelectionKey)
        }
    }

    private static func defaultProvider() -> AppProviderSettings {
        AppProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: defaultBaseURL,
            apiKeyAccount: keychainAccount,
            models: [AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    private static func endpoint(for provider: AppProviderSettings) -> ProviderEndpoint {
        ProviderEndpoint(
            id: provider.id,
            baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
            chatEndpoint: URL(string: provider.chatEndpoint),
            apiKeyRef: apiKeyRef(for: provider),
            wire: .openai)
    }

    static func apiKeyRef(for provider: AppProviderSettings) -> KeychainRef {
        let keychainRef = KeychainRef(service: keychainService, account: provider.apiKeyAccount)
        return provider.apiKeySource?.ref(defaultRef: keychainRef, providerID: provider.id) ?? keychainRef
    }

    static func chatEndpoint(forBaseURL baseURL: String) -> String {
        let base = Self.baseURL(fromChatEndpoint: baseURL)
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            return base
        }
        return "\(trimTrailingPathSeparators(base))/chat/completions"
    }

    static func baseURL(fromChatEndpoint endpoint: String) -> String {
        let trimmed = trimTrailingPathSeparators(endpoint)
        let suffix = "/chat/completions"
        if trimmed.lowercased().hasSuffix(suffix) {
            return trimTrailingPathSeparators(String(trimmed.dropLast(suffix.count)))
        }
        return trimmed
    }

    static func defaultBaseURL(forProviderID providerID: String) -> String? {
        switch normalizedProviderID(providerID) {
        case "openai":
            return defaultBaseURL
        case "openrouter":
            return "https://openrouter.ai/api/v1"
        case "deepseek":
            return "https://api.deepseek.com/v1"
        case "ollama":
            return "http://localhost:11434/v1"
        case "lmstudio", "lm-studio":
            return "http://localhost:1234/v1"
        case "groq":
            return "https://api.groq.com/openai/v1"
        case "xai":
            return "https://api.x.ai/v1"
        case "together":
            return "https://api.together.xyz/v1"
        case "fireworks":
            return "https://api.fireworks.ai/inference/v1"
        case "cerebras":
            return "https://api.cerebras.ai/v1"
        case "moonshot":
            return "https://api.moonshot.ai/v1"
        default:
            return nil
        }
    }

    static func defaultProviderDisplayName(forProviderID providerID: String) -> String {
        switch normalizedProviderID(providerID) {
        case "openai":
            return "OpenAI"
        case "openrouter":
            return "OpenRouter"
        case "deepseek":
            return "DeepSeek"
        case "ollama":
            return "Ollama"
        case "lmstudio", "lm-studio":
            return "LM Studio"
        case "groq":
            return "Groq"
        case "xai":
            return "xAI"
        case "together":
            return "Together AI"
        case "fireworks":
            return "Fireworks AI"
        case "cerebras":
            return "Cerebras"
        case "moonshot":
            return "Moonshot AI"
        default:
            return providerID
        }
    }

    private static func trimTrailingPathSeparators(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") && !result.hasSuffix("://") {
            result.removeLast()
        }
        return result
    }

    private static func keychainAccount(forProviderID providerID: String) -> String {
        providerID == defaultProviderID ? keychainAccount : "provider-\(providerID)"
    }

    static func defaultDisplayName(for modelID: String) -> String {
        switch modelID {
        case "gpt-4o-mini":
            return "GPT-4o mini"
        case "gpt-4o":
            return "GPT-4o"
        default:
            return modelID
        }
    }

    private static func fileProviderCatalog() -> AppProviderCatalog? {
        guard let url = existingConfigFileURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let configData = jsonCompatibleData(from: data)
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(AppProviderCatalog.self, from: configData) {
            return direct
        }
        return try? decoder.decode(AppProviderConfigFile.self, from: configData)
            .catalog(configDirectory: url.deletingLastPathComponent())
    }

    private static func existingConfigFileURL() -> URL? {
        for url in configFileCandidates() where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func configFileCandidates() -> [URL] {
        if configOverridePath() != nil {
            return [preferredConfigFileURL()]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userConfigDir = home
            .appendingPathComponent(".config/intatis", isDirectory: true)
        let openCodeConfigDir = home
            .appendingPathComponent(".config/opencode", isDirectory: true)
        return [
            userConfigDir.appendingPathComponent("opencode.json"),
            userConfigDir.appendingPathComponent("opencode.jsonc"),
            userConfigDir.appendingPathComponent("intatis.json"),
            userConfigDir.appendingPathComponent("intatis.jsonc"),
            openCodeConfigDir.appendingPathComponent("opencode.json"),
            openCodeConfigDir.appendingPathComponent("opencode.jsonc"),
            appSupportDir().appendingPathComponent("opencode.json"),
            appSupportDir().appendingPathComponent("opencode.jsonc"),
            appSupportDir().appendingPathComponent("intatis.json"),
            appSupportDir().appendingPathComponent("intatis.jsonc"),
            userConfigDir.appendingPathComponent("config.json"),
            userConfigDir.appendingPathComponent("config.jsonc"),
            appSupportDir().appendingPathComponent("config.json"),
            appSupportDir().appendingPathComponent("config.jsonc"),
        ]
    }

    private static func preferredConfigFileURL() -> URL {
        if let override = configOverridePath() {
            return URL(fileURLWithPath: expandedPath(override))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/intatis/opencode.json")
    }

    private static func isModernConfigFile(_ url: URL) -> Bool {
        switch url.lastPathComponent {
        case "opencode.json", "opencode.jsonc", "intatis.json", "intatis.jsonc":
            return true
        default:
            return false
        }
    }

    private static func configOverridePath() -> String? {
        let trimmed = ProcessInfo.processInfo.environment[configEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeConfigTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(AppProviderConfigTemplate(catalog: normalizedCatalog(providerCatalog)))
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func jsonCompatibleData(from data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let stripped = stripTrailingCommas(from: stripJSONComments(from: text))
        return Data(stripped.utf8)
    }

    private static func stripJSONComments(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = next
                continue
            }

            if character == "/", next < text.endIndex {
                let nextCharacter = text[next]
                if nextCharacter == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    if index < text.endIndex {
                        output.append("\n")
                        index = text.index(after: index)
                    }
                    continue
                }
                if nextCharacter == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let current = text[index]
                        let lookahead = text.index(after: index)
                        if current == "\n" { output.append("\n") }
                        if current == "*", lookahead < text.endIndex, text[lookahead] == "/" {
                            index = text.index(after: lookahead)
                            break
                        }
                        index = lookahead
                    }
                    continue
                }
            }

            output.append(character)
            index = next
        }
        return output
    }

    private static func stripTrailingCommas(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "," {
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex, text[lookahead].isWhitespace {
                    lookahead = text.index(after: lookahead)
                }
                if lookahead < text.endIndex,
                   text[lookahead] == "}" || text[lookahead] == "]" {
                    index = text.index(after: index)
                    continue
                }
            }

            output.append(character)
            index = text.index(after: index)
        }
        return output
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == "~" { return home }
        return home + String(trimmed.dropFirst())
    }

    private static func eventCount(in fileURL: URL) -> Int {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return 0 }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }
}

private struct AppProviderConfigTemplate: Encodable {
    var schema = "https://opencode.ai/config.json"
    var enabledProviders: [String]
    var model: String
    var provider: [String: AppProviderConfigTemplateProvider]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case enabledProviders = "enabled_providers"
        case model
        case provider
    }

    init(catalog: AppProviderCatalog) {
        self.enabledProviders = catalog.providers.map(\.id)
        let selectedProvider = catalog.providers.first { $0.id == catalog.selectedProviderID }
            ?? catalog.providers.first
        if let selectedProvider {
            let selectedModel = selectedProvider.models.first { $0.id == catalog.selectedModelID }
                ?? selectedProvider.models.first
            let modelID = selectedModel?.id ?? AppConfig.defaultModel
            self.model = "\(selectedProvider.id)/\(modelID)"
        } else {
            self.model = AppConfig.defaultModel
        }

        self.provider = Dictionary(uniqueKeysWithValues: catalog.providers.map { provider in
            (provider.id, AppProviderConfigTemplateProvider(provider: provider))
        })
    }
}

private struct AppProviderConfigTemplateProvider: Encodable {
    var npm = "@ai-sdk/openai-compatible"
    var name: String
    var options: AppProviderConfigTemplateOptions
    var models: [String: AppProviderConfigTemplateModel]

    init(provider: AppProviderSettings) {
        self.name = provider.title
        self.options = AppProviderConfigTemplateOptions(provider: provider)
        self.models = Dictionary(uniqueKeysWithValues: provider.models.map { model in
            (model.id, AppProviderConfigTemplateModel(name: model.title))
        })
    }
}

private struct AppProviderConfigTemplateOptions: Encodable {
    var baseURL: String
    var apiKey: String?

    init(provider: AppProviderSettings) {
        self.baseURL = provider.baseURL
        self.apiKey = provider.apiKeySource?.openCodeAPIKeyValue
    }
}

private struct AppProviderConfigTemplateModel: Encodable {
    var name: String
}

private struct AppProviderConfigFile: Decodable {
    var selectedProviderID: String?
    var selectedModelID: String?
    var model: String?
    var smallModel: String?
    var small_model: String?
    var enabledProviders: [String]?
    var enabled_providers: [String]?
    var disabledProviders: [String]?
    var disabled_providers: [String]?
    var providers: [AppProviderSettings]?
    var provider: [String: AppProviderConfigFileProvider]?

    func catalog(configDirectory: URL?) -> AppProviderCatalog? {
        var entries = providers ?? []
        let enabled = enabledProviders ?? enabled_providers
        let disabled = disabledProviders ?? disabled_providers
        let split = splitModel(resolvedConfigValue(model ?? smallModel ?? small_model,
                                                   configDirectory: configDirectory))
        if !entries.isEmpty {
            entries = entries.filter {
                shouldIncludeProvider(id: $0.id, enabled: enabled, disabled: disabled)
            }
        }
        if entries.isEmpty, let provider {
            entries = provider.keys.sorted().compactMap { id in
                guard shouldIncludeProvider(id: id, enabled: enabled, disabled: disabled) else {
                    return nil
                }
                return provider[id]?.settings(
                    id: id,
                    selectedModelID: providerIDsMatch(split.providerID, id) ? split.modelID : nil,
                    configDirectory: configDirectory)
            }
        }
        if entries.isEmpty,
           let providerID = split.providerID,
           let modelID = split.modelID,
           shouldIncludeProvider(id: providerID, enabled: enabled, disabled: disabled),
           let fallback = fallbackProviderSettings(id: providerID, modelID: modelID) {
            entries = [fallback]
        }
        guard !entries.isEmpty else { return nil }

        if let providerID = split.providerID,
           let modelID = split.modelID,
           let actualProviderID = actualProviderID(matching: providerID, in: entries),
           let index = entries.firstIndex(where: { $0.id == actualProviderID }),
           !entries[index].models.contains(where: { $0.id == modelID }) {
            entries[index].models.append(
                AppProviderModel(id: modelID,
                                 displayName: AppConfig.defaultDisplayName(for: modelID)))
        }
        let selectedProvider = actualProviderID(matching: selectedProviderID, in: entries)
            ?? actualProviderID(matching: split.providerID, in: entries)
            ?? entries[0].id
        let selectedModel = selectedModelID
            ?? split.modelID
            ?? entries.first(where: { $0.id == selectedProvider })?.models.first?.id
            ?? entries[0].models.first?.id
            ?? AppConfig.defaultModel

        return AppProviderCatalog(selectedProviderID: selectedProvider,
                                  selectedModelID: selectedModel,
                                  providers: entries)
    }

    private func fallbackProviderSettings(id: String, modelID: String) -> AppProviderSettings? {
        guard let baseURL = AppConfig.defaultBaseURL(forProviderID: id) else { return nil }
        return AppProviderSettings(
            id: id,
            displayName: AppConfig.defaultProviderDisplayName(forProviderID: id),
            baseURL: baseURL,
            apiKeyAccount: id == "default" ? AppConfig.keychainAccount : "provider-\(id)",
            models: [AppProviderModel(id: modelID,
                                      displayName: AppConfig.defaultDisplayName(for: modelID))])
    }

    private func splitModel(_ raw: String?) -> (providerID: String?, modelID: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return (nil, nil)
        }
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return (nil, raw)
        }
        return (String(parts[0]), String(parts[1]))
    }

    private func shouldIncludeProvider(id: String,
                                       enabled: [String]?,
                                       disabled: [String]?) -> Bool {
        let normalizedID = normalizedProviderID(id)
        let disabledIDs = Set((disabled ?? []).map(normalizedProviderID))
        if disabledIDs.contains(normalizedID) { return false }

        let enabledIDs = Set((enabled ?? []).map(normalizedProviderID))
        if enabledIDs.isEmpty { return true }
        return enabledIDs.contains(normalizedID)
    }

    private func providerIDsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return normalizedProviderID(lhs) == normalizedProviderID(rhs)
    }

    private func actualProviderID(matching candidate: String?, in entries: [AppProviderSettings]) -> String? {
        guard let candidate else { return nil }
        if let exact = entries.first(where: { $0.id == candidate })?.id {
            return exact
        }
        let normalizedCandidate = normalizedProviderID(candidate)
        return entries.first { normalizedProviderID($0.id) == normalizedCandidate }?.id
    }

    private func normalizedProviderID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct AppProviderConfigFileProvider: Decodable {
    var api: String?
    var env: [String]?
    var npm: String?
    var name: String?
    var displayName: String?
    var baseURL: String?
    var chatEndpoint: String?
    var apiKey: String?
    var apiKeyAccount: String?
    var apiKeySource: AppProviderAPIKeySource?
    var apiKeyEnv: String?
    var apiKeyFile: String?
    var options: AppProviderConfigFileOptions?
    var models: [String: AppProviderConfigFileModel]?

    func settings(id: String, selectedModelID: String?, configDirectory: URL?) -> AppProviderSettings? {
        let base = options?.baseURL ?? baseURL ?? AppConfig.defaultBaseURL(forProviderID: id)
        guard let base, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var source: AppProviderAPIKeySource?
        source = source ?? apiKeySource
        source = source ?? options?.apiKeySource
        source = source ?? parsedAPIKeySource(from: options?.apiKey, configDirectory: configDirectory)
        source = source ?? parsedAPIKeySource(from: apiKey, configDirectory: configDirectory)
        if source == nil, let apiKeyEnv {
            source = AppProviderAPIKeySource.environment(apiKeyEnv)
        }
        if source == nil, let optionAPIKeyEnv = options?.apiKeyEnv {
            source = AppProviderAPIKeySource.environment(optionAPIKeyEnv)
        }
        if source == nil, let firstEnv = env?.first {
            source = AppProviderAPIKeySource.environment(firstEnv)
        }
        if source == nil, let apiKeyFile {
            source = AppProviderAPIKeySource.file(apiKeyFile)
        }
        if source == nil, let optionAPIKeyFile = options?.apiKeyFile {
            source = AppProviderAPIKeySource.file(optionAPIKeyFile)
        }
        var modelList = models?.keys.sorted().compactMap { modelID -> AppProviderModel? in
            guard let model = models?[modelID] else { return nil }
            return AppProviderModel(id: model.id ?? modelID,
                                    displayName: model.displayName ?? model.name ?? modelID)
        } ?? []
        if let selectedModelID,
           !modelList.contains(where: { $0.id == selectedModelID }) {
            modelList.append(AppProviderModel(
                id: selectedModelID,
                displayName: AppConfig.defaultDisplayName(for: selectedModelID)))
        }
        return AppProviderSettings(
            id: id,
            displayName: displayName ?? name ?? AppConfig.defaultProviderDisplayName(forProviderID: id),
            baseURL: base,
            chatEndpoint: options?.chatEndpoint ?? chatEndpoint,
            apiKeyAccount: apiKeyAccount ?? (id == "default" ? AppConfig.keychainAccount : "provider-\(id)"),
            apiKeySource: source?.isKeychain == true ? nil : source,
            models: modelList.isEmpty
                ? [AppProviderModel(id: AppConfig.defaultModel, displayName: AppConfig.defaultModel)]
                : modelList)
    }
}

private struct AppProviderConfigFileOptions: Decodable {
    var apiKey: String?
    var baseURL: String?
    var chatEndpoint: String?
    var apiKeySource: AppProviderAPIKeySource?
    var apiKeyEnv: String?
    var apiKeyFile: String?
}

private struct AppProviderConfigFileModel: Decodable {
    var id: String?
    var name: String?
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self.id = nil
            self.name = value
            self.displayName = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }
}

private func resolvedConfigValue(_ raw: String?, configDirectory: URL?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else {
        return nil
    }
    guard let variable = configVariable(in: raw) else { return raw }
    switch variable.kind {
    case "env":
        return ProcessInfo.processInfo.environment[variable.value]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    case "file":
        let path = resolvedConfigFilePath(variable.value, configDirectory: configDirectory)
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    default:
        return raw
    }
}

private func parsedAPIKeySource(from raw: String?, configDirectory: URL?) -> AppProviderAPIKeySource? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let variable = configVariable(in: raw) else {
        return nil
    }
    switch variable.kind {
    case "env":
        return AppProviderAPIKeySource.environment(variable.value)
    case "file":
        return AppProviderAPIKeySource.file(
            resolvedConfigFilePath(variable.value, configDirectory: configDirectory))
    default:
        return nil
    }
}

private func configVariable(in raw: String) -> (kind: String, value: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
    let body = trimmed.dropFirst().dropLast()
    guard let separator = body.firstIndex(of: ":") else { return nil }
    let kind = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kind.isEmpty, !value.isEmpty else { return nil }
    return (kind, value)
}

private func resolvedConfigFilePath(_ path: String, configDirectory: URL?) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed == "~" || trimmed.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return trimmed == "~" ? home : home + String(trimmed.dropFirst())
    }
    if trimmed.hasPrefix("/") { return trimmed }
    guard let configDirectory else { return trimmed }
    return configDirectory.appendingPathComponent(trimmed).path
}
#endif
