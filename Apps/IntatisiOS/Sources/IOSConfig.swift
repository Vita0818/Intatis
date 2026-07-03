#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders

struct IOSProviderModel: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }
}

struct IOSProviderAPIKeySource: Codable, Equatable {
    var type: String
    var value: String

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

struct IOSProviderSettings: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    var baseURL: String
    var chatEndpoint: String
    var apiKeyAccount: String
    var apiKeySource: IOSProviderAPIKeySource?
    var models: [IOSProviderModel]

    init(id: String,
         displayName: String,
         baseURL: String,
         chatEndpoint: String? = nil,
         apiKeyAccount: String,
         apiKeySource: IOSProviderAPIKeySource? = nil,
         models: [IOSProviderModel]) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint ?? IOSConfig.chatEndpoint(forBaseURL: baseURL)
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
            ?? IOSConfig.chatEndpoint(forBaseURL: baseURL)
        self.apiKeyAccount = try container.decodeIfPresent(String.self, forKey: .apiKeyAccount)
            ?? (self.id == "default" ? IOSConfig.keychainAccount : "provider-\(self.id)")
        self.apiKeySource = try container.decodeIfPresent(IOSProviderAPIKeySource.self, forKey: .apiKeySource)
        self.models = try container.decode([IOSProviderModel].self, forKey: .models)
    }

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: baseURL)?.host ?? id
    }
}

struct IOSProviderCatalog: Codable, Equatable {
    var selectedProviderID: String
    var selectedModelID: String
    var providers: [IOSProviderSettings]

    var selectedProvider: IOSProviderSettings? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
    }

    var selectedModel: IOSProviderModel? {
        guard let provider = selectedProvider else { return nil }
        return provider.models.first { $0.id == selectedModelID } ?? provider.models.first
    }
}

private struct IOSProviderSelection: Codable, Equatable {
    var providerID: String
    var modelID: String
}

/// iOS app configuration. Mirrors the macOS chat config; there is deliberately no
/// workspace/shell/agent setup — iOS is the chat-only subset (ARCHITECTURE.md §4).
enum IOSConfig {
    static let keychainService = "com.intatis.ios"
    static let keychainAccount = "default-openai"
    static let defaultSession = SessionID(rawValue: "sess_ios")

    // User-configurable endpoint + model (persisted in UserDefaults).
    private static let baseURLKey = "intatis.baseURL"
    private static let modelKey = "intatis.model"
    private static let providerCatalogKey = "intatis.providerCatalog.v1"
    private static let providerSelectionKey = "intatis.providerSelection.v1"
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
                    IOSProviderModel(id: modelID, displayName: defaultDisplayName(for: modelID)))
            }
            catalog.selectedModelID = modelID
            providerCatalog = catalog
            UserDefaults.standard.set(modelID, forKey: modelKey)
        }
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

    static var providerCatalog: IOSProviderCatalog {
        get {
            let catalog: IOSProviderCatalog
            if let data = UserDefaults.standard.data(forKey: providerCatalogKey),
               let decoded = try? JSONDecoder().decode(IOSProviderCatalog.self, from: data) {
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
    static func selectProviderModel(providerID: String, modelID: String) -> IOSProviderCatalog {
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
        let catalog = providerCatalog
        let selectedProvider = catalog.selectedProvider ?? defaultProvider()
        let selectedModel = catalog.selectedModel ?? selectedProvider.models.first
            ?? IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))

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
        models.imageGen = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: "dall-e-3"))
        models.transcription = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: "whisper-1"))
        return ProviderConfig(endpoints: endpoints.isEmpty ? [endpoint(for: selectedProvider)] : endpoints,
                              models: models)
    }

    static func newProvider() -> IOSProviderSettings {
        let id = IDGen.random(prefix: "provider")
        return IOSProviderSettings(
            id: id,
            displayName: "New Provider",
            baseURL: defaultBaseURL,
            apiKeyAccount: keychainAccount(forProviderID: id),
            models: [IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    static func normalizedCatalog(_ catalog: IOSProviderCatalog) -> IOSProviderCatalog {
        var seenProviders = Set<String>()
        var providers = catalog.providers.compactMap { provider -> IOSProviderSettings? in
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenProviders.contains(id) else { return nil }
            seenProviders.insert(id)

            let baseURL = baseURL(fromChatEndpoint: provider.baseURL)
            let rawChatEndpoint = provider.chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatEndpoint = rawChatEndpoint.isEmpty
                ? chatEndpoint(forBaseURL: baseURL)
                : rawChatEndpoint
            var seenModels = Set<String>()
            let models = provider.models.compactMap { model -> IOSProviderModel? in
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelID.isEmpty, !seenModels.contains(modelID) else { return nil }
                seenModels.insert(modelID)
                return IOSProviderModel(
                    id: modelID,
                    displayName: model.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !baseURL.isEmpty else { return nil }
            return IOSProviderSettings(
                id: id,
            displayName: provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKeyAccount: provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? keychainAccount(forProviderID: id)
                : provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKeySource: provider.apiKeySource,
            models: models.isEmpty
                ? [IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))]
                : models)
        }

        if providers.isEmpty {
            providers = [defaultProvider()]
        }

        let selectedProviderID = providers.contains { $0.id == catalog.selectedProviderID }
            ? catalog.selectedProviderID
            : providers[0].id
        let selectedProvider = providers.first { $0.id == selectedProviderID } ?? providers[0]
        let selectedModelID = selectedProvider.models.contains { $0.id == catalog.selectedModelID }
            ? catalog.selectedModelID
            : selectedProvider.models[0].id

        return IOSProviderCatalog(
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            providers: providers)
    }

    private static func legacyProviderCatalog() -> IOSProviderCatalog {
        let baseURL = baseURL(fromChatEndpoint: UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL)
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        let provider = IOSProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: baseURL,
            chatEndpoint: chatEndpoint(forBaseURL: baseURL),
            apiKeyAccount: keychainAccount,
            models: [IOSProviderModel(id: model, displayName: defaultDisplayName(for: model))])
        return IOSProviderCatalog(selectedProviderID: provider.id,
                                  selectedModelID: model,
                                  providers: [provider])
    }

    private static func applyingStoredSelection(to catalog: IOSProviderCatalog) -> IOSProviderCatalog {
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

    private static func storedSelection() -> IOSProviderSelection? {
        guard let data = UserDefaults.standard.data(forKey: providerSelectionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(IOSProviderSelection.self, from: data)
    }

    private static func storeSelection(from catalog: IOSProviderCatalog) {
        let selection = IOSProviderSelection(providerID: catalog.selectedProviderID,
                                             modelID: catalog.selectedModelID)
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: providerSelectionKey)
        }
    }

    private static func defaultProvider() -> IOSProviderSettings {
        IOSProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: defaultBaseURL,
            apiKeyAccount: keychainAccount,
            models: [IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    private static func endpoint(for provider: IOSProviderSettings) -> ProviderEndpoint {
        ProviderEndpoint(
            id: provider.id,
            baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
            chatEndpoint: URL(string: provider.chatEndpoint),
            apiKeyRef: apiKeyRef(for: provider),
            wire: .openai)
    }

    static func apiKeyRef(for provider: IOSProviderSettings) -> KeychainRef {
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

    private static func defaultDisplayName(for modelID: String) -> String {
        switch modelID {
        case "gpt-4o-mini":
            return "GPT-4o mini"
        case "gpt-4o":
            return "GPT-4o"
        default:
            return modelID
        }
    }
}
#endif
