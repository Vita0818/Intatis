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

// The shell now lives in IntatisMacRootView (gold sidebar + NavigationSplitView);
// settings moved into IntatisSettingsPanel. CodeContainer / CoworkContainer below
// are reused by the new root for the Code / Cowork tabs.

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
                    summary: vm.summary,
                    composerError: vm.composerError,
                    isWorking: vm.isWorking,
                    input: $vm.input,
                    onSend: { vm.send() },
                    onResolve: { vm.resolvePermission($0) },
                    onAddAgent: {
                        agentName = ""
                        vm.resetAddAgentStatus()
                        showAdd = true
                    })
            .task { vm.start() }
            .sheet(isPresented: $showAdd) { addAgentSheet }
    }

    private var addAgentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add agent").font(.headline)
            TextField("Name (e.g. Rokurics)", text: $agentName)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.addAgentStatus.isBusy)
            if let message = vm.addAgentStatus.message {
                HStack(spacing: 8) {
                    if vm.addAgentStatus.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(addAgentMessageColor)
                }
            }
            if case .attaching = vm.addAgentStatus,
               let pending = vm.pendingPermission,
               pending.request.tool == "agent.attach" {
                PermissionCard(permission: pending, onResolve: { vm.resolvePermission($0) })
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    vm.resetAddAgentStatus()
                    showAdd = false
                }
                .disabled(vm.addAgentStatus.isBusy)
                Button("Choose Folder & Add") {
                    let name = agentName.trimmingCharacters(in: .whitespaces)
                    guard vm.prepareAddAgent(name: name) else { return }
                    if let url = WorkspaceAccess.choose() {
                        vm.addAgent(name: name, workspace: url)
                    } else {
                        vm.cancelAddAgentSelection()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.addAgentStatus.isBusy || agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: vm.addAgentStatus) { status in
            if case .attached = status {
                agentName = ""
                showAdd = false
                vm.resetAddAgentStatus()
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var addAgentMessageColor: Color {
        switch vm.addAgentStatus {
        case .denied, .failed:
            return .red
        case .attached:
            return .green
        case .idle, .validating, .attaching:
            return .secondary
        }
    }
}

@main
struct IntatisMacApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            IntatisMacRootView().environmentObject(env)
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
