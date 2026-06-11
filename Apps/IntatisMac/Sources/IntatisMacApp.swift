#if canImport(SwiftUI)
import SwiftUI
import Combine
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisSharedUI

/// Wires the v0.1 stack: keychain-backed provider registry + per-session event
/// log + chat view model. Held by the App as a `@StateObject`.
@MainActor
final class AppEnvironment: ObservableObject {
    let registry: ProviderRegistry
    let log: EventLog
    let viewModel: ChatViewModel
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
        self.viewModel = ChatViewModel(log: log, registry: registry)
        self.needsAPIKey = (try? keychain.get(account: AppConfig.keychainAccount)) == nil
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
}

enum AppMode: Hashable { case chat, code }

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var showSettings = false
    @State private var keyInput = ""
    @State private var mode: AppMode = .chat

    var body: some View {
        Group {
            switch mode {
            case .chat: ThreeColumnShell(model: env.viewModel)
            case .code: CodeContainer(env: env)
            }
        }
        .toolbar {
            if PlatformProfile.current.supports(.code) {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Text("Chat").tag(AppMode.chat)
                        Text("Code").tag(AppMode.code)
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
            Text("OpenAI-compatible API key").font(.headline)
            Text("Stored in your macOS keychain. Never sent anywhere except your configured endpoint.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("sk-…", text: $keyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSettings = false }
                Button("Save") {
                    env.saveAPIKey(keyInput)
                    keyInput = ""
                    showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
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
