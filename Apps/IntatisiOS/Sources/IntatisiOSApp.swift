#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisArtifacts
import IntatisMultimodal
import IntatisSharedUI

/// iOS app environment — the chat-only subset. It links Core / Providers /
/// Conversation / Artifacts / Multimodal / SharedUI and *cannot* reach Tools,
/// Permission, AgentKernel, or Cowork: those packages are simply not linked, so
/// there is no code path to a local workspace (ARCHITECTURE.md §4.1).
@MainActor
final class IOSAppEnvironment: ObservableObject {
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: IOSProviderCatalog
    let log: EventLog
    let viewModel: ChatViewModel
    let multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let keychain: KeychainStore
    private let secrets: KeychainSecretResolver

    init() {
        PlatformProfile.current = .iOS   // chat-only, no workspace, no shell

        self.keychain = KeychainStore(service: IOSConfig.keychainService)
        self.secrets = KeychainSecretResolver()
        self.providerCatalog = IOSConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(resolver: secrets)
        self.registry = initialRegistry
        do {
            self.log = try EventLog(session: IOSConfig.defaultSession, fileURL: IOSConfig.sessionFile())
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        let store: ArtifactStore
        do {
            store = try ArtifactStore(root: IOSConfig.artifactsDir())
        } catch {
            fatalError("Failed to open artifact store: \(error)")
        }
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = ChatViewModel(log: log, registry: initialRegistry)
        self.needsAPIKey = !Self.hasAPIKey(ref: IOSConfig.selectedAPIKeyRef,
                                           keychain: keychain)

        wireImageGeneration()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let account = IOSConfig.selectedAPIKeyAccount
        try? keychain.set(trimmed, account: account)
        secrets.cache(trimmed, for: KeychainRef(service: IOSConfig.keychainService, account: account))
        needsAPIKey = false
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(account: account, keychain: keychain)
    }

    func hasAPIKey(for provider: IOSProviderSettings) -> Bool {
        Self.hasAPIKey(ref: IOSConfig.apiKeyRef(for: provider), keychain: keychain)
    }

    func saveSettings(catalog rawCatalog: IOSProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = IOSConfig.normalizedCatalog(rawCatalog)
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                try keychain.set(key, account: provider.apiKeyAccount)
                secrets.cache(key, for: KeychainRef(service: IOSConfig.keychainService,
                                                    account: provider.apiKeyAccount))
                catalog.providers[index].apiKeySource = nil
            }
        }
        IOSConfig.providerCatalog = catalog
        providerCatalog = IOSConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                                      ?? KeychainRef(service: IOSConfig.keychainService,
                                                     account: IOSConfig.keychainAccount),
                                      keychain: keychain)

        refreshProviderRegistry()
    }

    func selectProviderModel(providerID: String, modelID: String) {
        let catalog = IOSConfig.selectProviderModel(providerID: providerID, modelID: modelID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                                      ?? KeychainRef(service: IOSConfig.keychainService,
                                                     account: IOSConfig.keychainAccount),
                                      keychain: keychain)
        refreshProviderRegistry()
    }

    private static func makeProviderRegistry(resolver: KeychainSecretResolver) -> ProviderRegistry {
        ProviderRegistry(config: IOSConfig.providerConfig(), resolver: resolver)
    }

    private func refreshProviderRegistry() {
        let updated = Self.makeProviderRegistry(resolver: secrets)
        registry = updated
        viewModel.updateProviderRegistry(updated)
        wireImageGeneration()
    }

    private static func hasAPIKey(account: String, keychain: KeychainStore) -> Bool {
        keychain.exists(account: account)
    }

    private static func hasAPIKey(ref: KeychainRef, keychain: KeychainStore) -> Bool {
        KeychainSecretResolver.exists(ref, keychain: keychain)
    }

    private func wireImageGeneration() {
        viewModel.onGenerateImage = { [weak self] prompt in
            guard let self else { throw IntatisError.cancelled }
            guard let provider = try await self.registry.defaultImageProvider(),
                  let model = await self.registry.imageModel() else {
                throw IntatisError.config("image generation is not configured")
            }
            _ = try await self.multimodal.generateImage(using: provider, model: model, prompt: prompt)
        }
    }
}

struct IOSRootView: View {
    @EnvironmentObject var env: IOSAppEnvironment
    @State private var showSettings = false
    @State private var catalog = IOSConfig.providerCatalog
    @State private var apiKeysByProviderID: [String: String] = [:]
    @State private var settingsError: String?

    var body: some View {
        // PlatformProfile.iOS makes the shared sidebar chat-only; Code/Cowork are
        // never shown and their packages are not even linked.
        ThreeColumnShell(model: env.viewModel)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    IOSChatModelMenu(
                        catalog: env.providerCatalog,
                        isBusy: env.viewModel.isBusy,
                        onSelect: env.selectProviderModel(providerID:modelID:))
                }
                ToolbarItem {
                    Button { showSettings = true } label: { Image(systemName: "key") }
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .task { if env.needsAPIKey { showSettings = true } }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                if let providerIndex = selectedProviderIndex {
                    Section("Provider") {
                        Picker("Active provider", selection: $catalog.selectedProviderID) {
                            ForEach(catalog.providers) { provider in
                                Text(provider.title).tag(provider.id)
                            }
                        }
                        .onChange(of: catalog.selectedProviderID) { _ in
                            ensureSelectedModel()
                        }

                        TextField("Provider name", text: providerFieldBinding(providerIndex, \.displayName))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Base URL", text: baseURLBinding(providerIndex))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Chat endpoint", text: chatEndpointBinding(providerIndex))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(apiKeyPlaceholder(for: catalog.providers[providerIndex]),
                                    text: apiKeyBinding(for: catalog.providers[providerIndex].id))

                        Button("Add Provider") { addProvider() }
                        Button("Delete Provider", role: .destructive) { removeProvider(providerIndex) }
                            .disabled(catalog.providers.count == 1)
                    }

                    Section("Models") {
                        Picker("Active model", selection: $catalog.selectedModelID) {
                            ForEach(catalog.providers[providerIndex].models) { model in
                                Text(model.title).tag(model.id)
                            }
                        }

                        ForEach(Array(catalog.providers[providerIndex].models.indices), id: \.self) { modelIndex in
                            TextField("Model ID",
                                      text: modelFieldBinding(providerIndex: providerIndex,
                                                              modelIndex: modelIndex,
                                                              keyPath: \.id))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Display name",
                                      text: modelFieldBinding(providerIndex: providerIndex,
                                                              modelIndex: modelIndex,
                                                              keyPath: \.displayName))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Delete Model", role: .destructive) {
                                removeModel(providerIndex: providerIndex, modelIndex: modelIndex)
                            }
                            .disabled(catalog.providers[providerIndex].models.count == 1)
                        }

                        Button("Add Model") { addModel(providerIndex: providerIndex) }
                    }
                }

                Section {
                    Text("Provider metadata is stored in settings. API keys stay in the device keychain. The selected model applies to new requests immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let settingsError {
                    Section {
                        Text(settingsError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSettings = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
                            catalog = IOSConfig.providerCatalog
                            apiKeysByProviderID = [:]
                            settingsError = nil
                            showSettings = false
                        } catch {
                            settingsError = "Could not save settings: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private var selectedProviderIndex: Int? {
        catalog.providers.firstIndex { $0.id == catalog.selectedProviderID } ?? catalog.providers.indices.first
    }

    private func ensureSelectedModel() {
        guard let providerIndex = selectedProviderIndex else { return }
        let provider = catalog.providers[providerIndex]
        if !provider.models.contains(where: { $0.id == catalog.selectedModelID }) {
            catalog.selectedModelID = provider.models.first?.id ?? IOSConfig.defaultModel
        }
    }

    private func addProvider() {
        let provider = IOSConfig.newProvider()
        catalog.providers.append(provider)
        catalog.selectedProviderID = provider.id
        catalog.selectedModelID = provider.models.first?.id ?? IOSConfig.defaultModel
    }

    private func removeProvider(_ index: Int) {
        guard catalog.providers.count > 1, catalog.providers.indices.contains(index) else { return }
        let removedID = catalog.providers[index].id
        catalog.providers.remove(at: index)
        apiKeysByProviderID[removedID] = nil
        if catalog.selectedProviderID == removedID {
            let provider = catalog.providers[min(index, catalog.providers.count - 1)]
            catalog.selectedProviderID = provider.id
            catalog.selectedModelID = provider.models.first?.id ?? IOSConfig.defaultModel
        }
    }

    private func addModel(providerIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex) else { return }
        let existing = Set(catalog.providers[providerIndex].models.map(\.id))
        let modelID = existing.contains(IOSConfig.defaultModel) ? "model-id" : IOSConfig.defaultModel
        catalog.providers[providerIndex].models.append(IOSProviderModel(id: modelID, displayName: modelID))
        catalog.selectedModelID = modelID
    }

    private func removeModel(providerIndex: Int, modelIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex),
              catalog.providers[providerIndex].models.count > 1,
              catalog.providers[providerIndex].models.indices.contains(modelIndex) else { return }
        let removedID = catalog.providers[providerIndex].models[modelIndex].id
        catalog.providers[providerIndex].models.remove(at: modelIndex)
        if catalog.selectedModelID == removedID {
            catalog.selectedModelID = catalog.providers[providerIndex].models[0].id
        }
    }

    private func providerFieldBinding(_ providerIndex: Int,
                                      _ keyPath: WritableKeyPath<IOSProviderSettings, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex][keyPath: keyPath] },
            set: { catalog.providers[providerIndex][keyPath: keyPath] = $0 })
    }

    private func baseURLBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].baseURL },
            set: {
                let baseURL = IOSConfig.baseURL(fromChatEndpoint: $0)
                catalog.providers[providerIndex].baseURL = baseURL
                catalog.providers[providerIndex].chatEndpoint = IOSConfig.chatEndpoint(forBaseURL: baseURL)
            })
    }

    private func chatEndpointBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].chatEndpoint },
            set: {
                let endpoint = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                catalog.providers[providerIndex].chatEndpoint = endpoint
                catalog.providers[providerIndex].baseURL = IOSConfig.baseURL(fromChatEndpoint: endpoint)
            })
    }

    private func modelFieldBinding(providerIndex: Int,
                                   modelIndex: Int,
                                   keyPath: WritableKeyPath<IOSProviderModel, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] },
            set: {
                let oldID = catalog.providers[providerIndex].models[modelIndex].id
                catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] = $0
                if keyPath == \IOSProviderModel.id, catalog.selectedModelID == oldID {
                    catalog.selectedModelID = $0
                }
            })
    }

    private func apiKeyBinding(for providerID: String) -> Binding<String> {
        Binding(
            get: { apiKeysByProviderID[providerID] ?? "" },
            set: { apiKeysByProviderID[providerID] = $0 })
    }

    private func apiKeyPlaceholder(for provider: IOSProviderSettings) -> String {
        env.hasAPIKey(for: provider) ? "••••••••••••••••" : "Enter API key"
    }
}

private struct IOSChatModelMenu: View {
    let catalog: IOSProviderCatalog
    let isBusy: Bool
    let onSelect: (String, String) -> Void

    private var selectedProvider: IOSProviderSettings? { catalog.selectedProvider }
    private var selectedModel: IOSProviderModel? { catalog.selectedModel }

    var body: some View {
        Menu {
            ForEach(catalog.providers) { provider in
                Section(provider.title) {
                    ForEach(provider.models) { model in
                        Button {
                            onSelect(provider.id, model.id)
                        } label: {
                            Label(model.title,
                                  systemImage: isSelected(providerID: provider.id, modelID: model.id)
                                  ? "checkmark"
                                  : "circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(selectedModel?.title ?? IOSConfig.defaultDisplayName(for: IOSConfig.defaultModel))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(selectedProvider?.title ?? "OpenAI")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .disabled(isBusy)
    }

    private func isSelected(providerID: String, modelID: String) -> Bool {
        catalog.selectedProviderID == providerID && catalog.selectedModelID == modelID
    }
}

@main
struct IntatisiOSApp: App {
    @StateObject private var env = IOSAppEnvironment()

    var body: some Scene {
        WindowGroup {
            IOSRootView().environmentObject(env)
        }
    }
}
#else
// Non-Apple platforms: trivial entry point so the executable target still links.
@main
struct IntatisiOSApp {
    static func main() {
        print("IntatisiOS is an iOS SwiftUI app and only runs on iOS.")
    }
}
#endif
