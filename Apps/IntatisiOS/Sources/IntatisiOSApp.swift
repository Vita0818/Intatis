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
    let registry: ProviderRegistry
    let log: EventLog
    let viewModel: ChatViewModel
    let multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let keychain: KeychainStore

    init() {
        PlatformProfile.current = .iOS   // chat-only, no workspace, no shell

        self.keychain = KeychainStore(service: IOSConfig.keychainService)
        self.registry = ProviderRegistry(config: IOSConfig.providerConfig(), resolver: KeychainSecretResolver())
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
        self.viewModel = ChatViewModel(log: log, registry: registry)
        self.needsAPIKey = (try? keychain.get(account: IOSConfig.keychainAccount)) == nil

        let reg = registry
        let mm = multimodal
        viewModel.onGenerateImage = { prompt in
            Task { @MainActor in
                guard let provider = try? await reg.defaultImageProvider(),
                      let model = await reg.imageModel() else { return }
                _ = try? await mm.generateImage(using: provider, model: model, prompt: prompt)
            }
        }
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? keychain.set(trimmed, account: IOSConfig.keychainAccount)
        needsAPIKey = false
    }
}

struct IOSRootView: View {
    @EnvironmentObject var env: IOSAppEnvironment
    @State private var showSettings = false
    @State private var keyInput = ""
    @State private var baseURLInput = IOSConfig.baseURL
    @State private var modelInput = IOSConfig.chatModelName

    var body: some View {
        // PlatformProfile.iOS makes the shared sidebar chat-only; Code/Cowork are
        // never shown and their packages are not even linked.
        ThreeColumnShell(model: env.viewModel)
            .toolbar {
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
                Section("Endpoint") {
                    TextField(IOSConfig.defaultBaseURL, text: $baseURLInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(IOSConfig.defaultModel, text: $modelInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("API key") {
                    SecureField("sk-… (any non-empty for local)", text: $keyInput)
                }
                Section {
                    Text("Works with any OpenAI-compatible API. Key is stored in the device keychain; "
                         + "endpoint/model changes take effect on relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSettings = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        IOSConfig.baseURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        IOSConfig.chatModelName = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !keyInput.isEmpty { env.saveAPIKey(keyInput) }
                        keyInput = ""
                        showSettings = false
                    }
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
