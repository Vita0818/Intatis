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
    @Published private(set) var chatSessionID: SessionID
    @Published private(set) var viewModel: ChatViewModel
    @Published private(set) var chatSessionError: String?
    private(set) var log: EventLog
    private(set) var multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let secrets: ConfigSecretResolver

    init() {
        PlatformProfile.current = .iOS   // chat-only, no workspace, no shell

        self.secrets = ConfigSecretResolver()
        self.providerCatalog = IOSConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(resolver: secrets)
        self.registry = initialRegistry
        let initialSession = IOSConfig.recentSessions().first?.id ?? IOSConfig.defaultSession
        self.chatSessionID = initialSession
        do {
            self.log = try EventLog(session: initialSession, fileURL: IOSConfig.sessionFile(initialSession))
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        let store: ArtifactStore
        do {
            store = try ArtifactStore(root: IOSConfig.artifactsDir(initialSession))
        } catch {
            fatalError("Failed to open artifact store: \(error)")
        }
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = ChatViewModel(log: log, registry: initialRegistry)
        self.needsAPIKey = !Self.hasAPIKey(ref: IOSConfig.selectedAPIKeyRef)

        wireImageGeneration()
    }

    func startNewChatSession() {
        do {
            try switchChatSession(to: SessionID.new())
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not start chat session: %@",
                error.localizedDescription)
        }
    }

    func resumeChatSession(_ session: IOSSessionSummary) {
        do {
            try switchChatSession(to: session.id)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not resume chat session: %@",
                error.localizedDescription)
        }
    }

    func recentChatSessions() -> [IOSSessionSummary] {
        IOSConfig.recentSessions()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerID = providerCatalog.selectedProvider?.id ?? "default"
        try? ConfigSecretResolver.writeSecrets([providerID: trimmed])
        secrets.cache(trimmed, for: .authFile(providerID: providerID))
        needsAPIKey = false
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(ref: .authFile(providerID: account))
    }

    func hasAPIKey(for provider: IOSProviderSettings) -> Bool {
        Self.hasAPIKey(ref: IOSConfig.apiKeyRef(for: provider))
    }

    func saveSettings(catalog rawCatalog: IOSProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = IOSConfig.normalizedCatalog(rawCatalog)
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }
            try ConfigSecretResolver.writeSecrets([provider.id: key])
            catalog.providers[index].apiKeySource = IOSProviderAPIKeySource(type: "authFile", value: "")
            secrets.cache(key, for: IOSConfig.apiKeyRef(for: catalog.providers[index]))
        }
        IOSConfig.providerCatalog = catalog
        providerCatalog = IOSConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))

        refreshProviderRegistry()
    }

    func selectProviderModel(providerID: String, modelID: String) {
        let catalog = IOSConfig.selectProviderModel(providerID: providerID, modelID: modelID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
    }

    func healthCheckSelectedProvider() async -> ProviderHealthReport {
        await registry.healthCheck(role: .chat, options: ProviderHealthCheckOptions(timeoutSeconds: 15))
    }

    private static func makeProviderRegistry(resolver: ConfigSecretResolver) -> ProviderRegistry {
        ProviderRegistry(config: IOSConfig.providerConfig(), resolver: resolver)
    }

    private func refreshProviderRegistry() {
        secrets.clearCache()
        let updated = Self.makeProviderRegistry(resolver: secrets)
        registry = updated
        viewModel.updateProviderRegistry(updated)
        wireImageGeneration()
    }

    private func switchChatSession(to session: SessionID) throws {
        viewModel.stop()
        let log = try EventLog(session: session, fileURL: IOSConfig.sessionFile(session))
        let store = try ArtifactStore(root: IOSConfig.artifactsDir(session))
        let model = ChatViewModel(log: log, registry: registry)
        self.log = log
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = model
        self.chatSessionID = session
        self.chatSessionError = nil
        wireImageGeneration()
        model.start()
    }

    private static func hasAPIKey(ref: KeychainRef) -> Bool {
        ConfigSecretResolver.exists(ref)
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
    @State private var isTestingProvider = false
    @State private var providerHealthReport: ProviderHealthReport?
    @State private var recentSessions: [IOSSessionSummary] = []
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var rendererModeRawValue = IntatisMessageRendererMode.microsoft.rawValue

    var body: some View {
        // iOS uses the shared chat thread in single-column mode; Code/Cowork are
        // not linked, so no local workspace execution is reachable.
        ThreeColumnShell(model: env.viewModel, layout: .iOSChat)
            .id(env.chatSessionID.rawValue)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    sessionHistoryMenu
                }
                ToolbarItem(placement: .principal) {
                    IOSChatModelMenu(
                        catalog: env.providerCatalog,
                        isBusy: env.viewModel.isBusy,
                        onSelect: env.selectProviderModel(providerID:modelID:))
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        env.startNewChatSession()
                        refreshSessions()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(env.viewModel.isBusy)

                    Button { showSettings = true } label: { Image(systemName: "key") }
                }
            }
            .overlay(alignment: .top) {
                sessionErrorBanner
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .task(id: env.chatSessionID.rawValue) {
                refreshSessions()
                if env.needsAPIKey { showSettings = true }
            }
            .onReceive(
                Publishers.CombineLatest(
                    env.viewModel.$isStreaming,
                    env.viewModel.$imageGenerationState)
                    .map { isStreaming, generationState in
                        isStreaming || generationState.isRunning
                    }
                    .removeDuplicates()
            ) { isBusy in
                if !isBusy {
                    refreshSessions()
                }
            }
    }

    private var sessionHistoryMenu: some View {
        Menu {
            Button {
                env.startNewChatSession()
                refreshSessions()
            } label: {
                Label("New Chat", systemImage: "plus")
            }
            .disabled(env.viewModel.isBusy)

            Section("Recent") {
                if recentSessions.isEmpty {
                    Text("No chat sessions")
                } else {
                    ForEach(Array(recentSessions.prefix(12))) { session in
                        Button {
                            env.resumeChatSession(session)
                            refreshSessions()
                        } label: {
                            Label(sessionMenuTitle(session),
                                  systemImage: session.id == env.chatSessionID
                                  ? "checkmark.circle.fill"
                                  : "clock")
                        }
                        .disabled(env.viewModel.isBusy || session.id == env.chatSessionID)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .disabled(env.viewModel.isBusy && recentSessions.isEmpty)
    }

    @ViewBuilder private var sessionErrorBanner: some View {
        if let error = env.chatSessionError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay {
                    Capsule().stroke(Color.red.opacity(0.45), lineWidth: 1)
                }
                .padding(.top, 8)
        }
    }

    private func refreshSessions() {
        recentSessions = env.recentChatSessions()
    }

    private func sessionMenuTitle(_ session: IOSSessionSummary) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let count = session.eventCount == 1
            ? IntatisLocalization.string("1 event")
            : IntatisLocalization.format("%lld events", Int64(session.eventCount))
        return "\(formatter.string(from: session.updatedAt)) · \(count)"
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

                    Section("Health Check") {
                        Button {
                            testProvider()
                        } label: {
                            Label(isTestingProvider
                                    ? IntatisLocalization.string("Testing Provider")
                                    : IntatisLocalization.string("Test Provider"),
                                  systemImage: isTestingProvider ? "hourglass" : "checkmark.seal")
                        }
                        .disabled(isTestingProvider)

                        if isTestingProvider {
                            ProgressView("Testing provider...")
                        } else if let report = providerHealthReport {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(IntatisLocalization.string(report.displayTitle),
                                      systemImage: report.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(report.isOK ? .green : .red)
                                Text(IntatisLocalization.providerHealthSummary(report))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(IntatisLocalization.providerHealthDetail(report))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Message Rendering") {
                    Picker("Message rendering", selection: rendererModeSelection) {
                        Text("Rich Markdown").tag(IntatisMessageRendererMode.microsoft.rawValue)
                        Text("Plain text safe mode").tag(IntatisMessageRendererMode.plainSafe.rawValue)
                    }
                    Text(messageRendererHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Open Source") {
                    NavigationLink("Third-party notices") {
                        IntatisThirdPartyNoticesView()
                            .navigationTitle("Open-source notices")
                            .navigationBarTitleDisplayMode(.inline)
                    }
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
                            providerHealthReport = nil
                            showSettings = false
                        } catch {
                            settingsError = IntatisLocalization.format(
                                "Could not save settings: %@",
                                error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    private var messageRendererHelpText: String {
        if let launchOverride = IntatisMessageRendererMode.launchOverride() {
            let label = launchOverride == .plainSafe
                ? IntatisLocalization.string("Plain text safe mode")
                : IntatisLocalization.string("Rich Markdown")
            return IntatisLocalization.format(
                "Current launch is forced to %@. This picker is saved immediately for the next launch without an override; Cancel only discards provider edits.",
                label)
        }
        return IntatisLocalization.string(
            "This choice is saved and applied immediately; Cancel only discards provider edits. Rich Markdown uses the audited upstream renderer with images, math typesetting, and syntax highlighting disabled for the first release. Plain text safe mode bypasses Markdown entirely without changing session data.")
    }

    private var rendererModeSelection: Binding<String> {
        Binding(
            get: {
                IntatisMessageRendererMode.resolve(
                    persistedRawValue: rendererModeRawValue,
                    arguments: []).rawValue
            },
            set: { rendererModeRawValue = $0 })
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
        env.hasAPIKey(for: provider)
            ? "••••••••••••••••"
            : IntatisLocalization.string("Enter API key")
    }

    private func testProvider() {
        guard !isTestingProvider else { return }
        isTestingProvider = true
        settingsError = nil
        providerHealthReport = nil
        Task { @MainActor in
            defer { isTestingProvider = false }
            do {
                try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
                catalog = IOSConfig.providerCatalog
                apiKeysByProviderID = [:]
                providerHealthReport = await env.healthCheckSelectedProvider()
            } catch {
                settingsError = IntatisLocalization.format(
                    "Could not test provider: %@",
                    error.localizedDescription)
            }
        }
    }
}

private struct IOSChatModelMenu: View {
    let catalog: IOSProviderCatalog
    let isBusy: Bool
    let onSelect: (String, String) -> Void

    private var selectedProvider: IOSProviderSettings? { catalog.selectedProvider }
    private var selectedModel: IOSProviderModel? { catalog.selectedModel }
    private var menuProviders: [ProviderModelMenuProvider] {
        catalog.providers.map { provider in
            ProviderModelMenuProvider(
                id: provider.id,
                title: provider.title,
                models: provider.models.map { ProviderModelMenuModel(id: $0.id, title: $0.title) })
        }
    }

    var body: some View {
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID: catalog.selectedProviderID,
            selectedModelID: catalog.selectedModelID,
            isBusy: isBusy,
            onSelect: onSelect) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(selectedModel?.title ?? IOSConfig.defaultModel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(selectedProvider?.title ?? "OpenAI")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(selectedModel?.title ?? IOSConfig.defaultModel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
        }
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
