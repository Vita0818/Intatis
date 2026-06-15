#if canImport(SwiftUI)
import SwiftUI
import Combine
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisArtifacts
import IntatisMultimodal
import IntatisSharedUI

/// Wires the v0.1 stack: keychain-backed provider registry + per-session event
/// log + chat view model. Held by the App as a `@StateObject`.
@MainActor
final class AppEnvironment: ObservableObject {
    let registry: ProviderRegistry
    let log: EventLog
    let viewModel: ChatViewModel
    let multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let keychain: KeychainStore

    init() {
        PlatformProfile.current = AppConfig.platformProfile

        self.keychain = KeychainStore(service: AppConfig.keychainService)
        self.registry = ProviderRegistry(
            config: AppConfig.providerConfig(),
            resolver: KeychainSecretResolver()
        )
        do {
            self.log = try EventLog(session: AppConfig.defaultSession,
                                    fileURL: AppConfig.sessionFile(AppConfig.defaultSession))
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        let store: ArtifactStore
        do {
            store = try ArtifactStore(root: AppConfig.appSupportDir()
                .appendingPathComponent(AppConfig.defaultSession.rawValue, isDirectory: true)
                .appendingPathComponent("artifacts", isDirectory: true))
        } catch {
            fatalError("Failed to open artifact store: \(error)")
        }
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = ChatViewModel(log: log, registry: registry)
        self.needsAPIKey = (try? keychain.get(account: AppConfig.keychainAccount)) == nil

        // Wire image generation: prompt → MultimodalService → artifact_added → UI.
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
        try? keychain.set(trimmed, account: AppConfig.keychainAccount)
        needsAPIKey = false
    }

    /// Build a fresh Code session bound to the chosen workspace folder.
    func makeCodeViewModel(workspace: URL) -> CodeViewModel? {
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        guard let codeLog = try? EventLog(session: session, fileURL: AppConfig.sessionFile(session)) else {
            return nil
        }
        return CodeViewModel(workspaceRoot: workspace, log: codeLog, registry: registry)
    }

    /// Build a fresh multi-agent Cowork session.
    func makeCoworkViewModel() -> CoworkViewModel? {
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        guard let coworkLog = try? EventLog(session: session, fileURL: AppConfig.sessionFile(session)) else {
            return nil
        }
        return CoworkViewModel(log: coworkLog, registry: registry)
    }
}

enum AppMode: Hashable { case chat, code, cowork }

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var showSettings = false
    @State private var keyInput = ""
    @State private var baseURLInput = AppConfig.baseURL
    @State private var modelInput = AppConfig.chatModelName
    @State private var mode: AppMode = .chat

    var body: some View {
        Group {
            switch mode {
            case .chat: ThreeColumnShell(model: env.viewModel)
            case .code: CodeContainer(env: env)
            case .cowork: CoworkContainer(env: env)
            }
        }
        .toolbar {
            if PlatformProfile.current.supports(.code) || PlatformProfile.current.supports(.cowork) {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Text("Chat").tag(AppMode.chat)
                        if PlatformProfile.current.supports(.code) { Text("Code").tag(AppMode.code) }
                        if PlatformProfile.current.supports(.cowork) { Text("Cowork").tag(AppMode.cowork) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            ToolbarItem {
                Button { showSettings = true } label: { Image(systemName: "key") }
                    .help("API key")
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .task { if env.needsAPIKey { showSettings = true } }
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Endpoint & model").font(.headline)
            Text("Works with any OpenAI-compatible API — OpenAI, Ollama, vLLM, OpenRouter, DeepSeek, …")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Base URL") {
                TextField(AppConfig.defaultBaseURL, text: $baseURLInput).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Model") {
                TextField(AppConfig.defaultModel, text: $modelInput).textFieldStyle(.roundedBorder)
            }
            LabeledContent("API key") {
                SecureField("sk-… (any non-empty for local servers)", text: $keyInput).textFieldStyle(.roundedBorder)
            }
            Text("Key is stored in your macOS keychain. Endpoint/model changes take effect on relaunch.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showSettings = false }
                Button("Save") {
                    AppConfig.baseURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    AppConfig.chatModelName = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !keyInput.isEmpty { env.saveAPIKey(keyInput) }
                    keyInput = ""
                    showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct CodeContainer: View {
    @ObservedObject var env: AppEnvironment
    @State private var codeVM: CodeViewModel?

    var body: some View {
        if let vm = codeVM {
            CodeSessionView(vm: vm)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                Text("Open a folder to start a Code session").font(.headline)
                Button("Choose Workspace…") {
                    if let url = WorkspaceAccess.choose() {
                        codeVM = env.makeCodeViewModel(workspace: url)
                    }
                }
                .keyboardShortcut("o")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CodeSessionView: View {
    @ObservedObject var vm: CodeViewModel

    var body: some View {
        CodeShell(items: vm.items,
                  pending: vm.pendingPermission,
                  isWorking: vm.isWorking,
                  workspaceName: vm.workspaceName,
                  agentState: vm.agentState,
                  input: $vm.input,
                  onSend: { vm.send() },
                  onResolve: { vm.resolvePermission($0) })
            .task { vm.start() }
    }
}

struct CoworkContainer: View {
    @ObservedObject var env: AppEnvironment
    @State private var coworkVM: CoworkViewModel?

    var body: some View {
        if let vm = coworkVM {
            CoworkSessionView(vm: vm)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.2").font(.largeTitle).foregroundStyle(.secondary)
                Text("Start a Cowork session").font(.headline)
                Button("New Cowork Session") { coworkVM = env.makeCoworkViewModel() }
                    .keyboardShortcut("n")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CoworkSessionView: View {
    @ObservedObject var vm: CoworkViewModel
    @State private var showAdd = false
    @State private var agentName = ""

    var body: some View {
        CoworkShell(items: vm.items,
                    agents: vm.agents,
                    pending: vm.pendingPermission,
                    isWorking: vm.isWorking,
                    input: $vm.input,
                    onSend: { vm.send() },
                    onResolve: { vm.resolvePermission($0) },
                    onAddAgent: { showAdd = true })
            .task { vm.start() }
            .sheet(isPresented: $showAdd) { addAgentSheet }
    }

    private var addAgentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add agent").font(.headline)
            TextField("Name (e.g. Rokurics)", text: $agentName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }
                Button("Choose Folder & Add") {
                    let name = agentName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let url = WorkspaceAccess.choose() {
                        vm.addAgent(name: name, workspace: url)
                    }
                    agentName = ""
                    showAdd = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

@main
struct IntatisMacApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(env)
        }
    }
}
#else
// Non-Apple platforms (e.g. Linux CI building the whole package): provide a
// trivial entry point so the executable target still links.
@main
struct IntatisMacApp {
    static func main() {
        print("IntatisMac is a macOS SwiftUI app and only runs on macOS.")
    }
}
#endif
