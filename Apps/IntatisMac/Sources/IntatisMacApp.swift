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
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: AppProviderCatalog
    let log: EventLog
    let viewModel: ChatViewModel
    let multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let keychain: KeychainStore
    private let secrets: KeychainSecretResolver

    init() {
        PlatformProfile.current = AppConfig.platformProfile

        self.keychain = KeychainStore(service: AppConfig.keychainService)
        self.secrets = KeychainSecretResolver()
        self.providerCatalog = AppConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(resolver: secrets)
        self.registry = initialRegistry
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
        self.viewModel = ChatViewModel(log: log, registry: initialRegistry)
        self.needsAPIKey = !Self.hasAPIKey(ref: AppConfig.selectedAPIKeyRef,
                                           keychain: keychain)

        wireImageGeneration()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let account = AppConfig.selectedAPIKeyAccount
        try? keychain.set(trimmed, account: account)
        secrets.cache(trimmed, for: KeychainRef(service: AppConfig.keychainService, account: account))
        needsAPIKey = false
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(account: account, keychain: keychain)
    }

    func hasAPIKey(for provider: AppProviderSettings) -> Bool {
        Self.hasAPIKey(ref: AppConfig.apiKeyRef(for: provider), keychain: keychain)
    }

    func saveSettings(catalog rawCatalog: AppProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = AppConfig.normalizedCatalog(rawCatalog)
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                try keychain.set(key, account: provider.apiKeyAccount)
                secrets.cache(key, for: KeychainRef(service: AppConfig.keychainService,
                                                    account: provider.apiKeyAccount))
                catalog.providers[index].apiKeySource = nil
            }
        }
        AppConfig.providerCatalog = catalog
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? KeychainRef(service: AppConfig.keychainService,
                                                     account: AppConfig.keychainAccount),
                                      keychain: keychain)

        refreshProviderRegistry()
    }

    func selectProviderModel(providerID: String, modelID: String) {
        let catalog = AppConfig.selectProviderModel(providerID: providerID, modelID: modelID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? KeychainRef(service: AppConfig.keychainService,
                                                     account: AppConfig.keychainAccount),
                                      keychain: keychain)
        refreshProviderRegistry()
    }

    /// Build a fresh Code session bound to the chosen workspace folder.
    func makeCodeViewModel(workspace: URL) throws -> CodeViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        WorkspaceAccess.remember(workspace, for: session)
        return try makeCodeViewModel(session: session, workspace: workspace)
    }

    func makeCodeViewModel(session: SessionID, workspace: URL) throws -> CodeViewModel {
        WorkspaceAccess.remember(workspace, for: session)
        let codeLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        return CodeViewModel(workspaceRoot: workspace, log: codeLog, registry: registry)
    }

    /// Build a fresh multi-agent Cowork session.
    func makeCoworkViewModel() throws -> CoworkViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        return try makeCoworkViewModel(session: session)
    }

    func makeCoworkViewModel(session: SessionID) throws -> CoworkViewModel {
        let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        return CoworkViewModel(log: coworkLog, registry: registry)
    }

    func recentCodeSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .code)
    }

    func recentCoworkSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .cowork)
    }

    private static func makeProviderRegistry(resolver: KeychainSecretResolver) -> ProviderRegistry {
        ProviderRegistry(config: AppConfig.providerConfig(), resolver: resolver)
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

// The shell now lives in IntatisMacRootView (gold sidebar + NavigationSplitView);
// settings moved into IntatisSettingsPanel. CodeContainer / CoworkContainer below
// are reused by the new root for the Code / Cowork tabs.

struct CodeContainer: View {
    @ObservedObject var env: AppEnvironment
    @State private var codeVM: CodeViewModel?
    @State private var sessionError: String?
    @State private var recentSessions: [AppSessionSummary] = []

    var body: some View {
        if let vm = codeVM {
            CodeSessionView(vm: vm)
                .onReceive(env.$registry) { registry in
                    vm.updateProviderRegistry(registry)
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                Text("Open a folder to start a Code session").font(.headline)
                if let sessionError {
                    Text(sessionError).font(.caption).foregroundStyle(.red)
                }
                Button("Choose Workspace…") {
                    if let url = WorkspaceAccess.choose() {
                        do {
                            codeVM = try env.makeCodeViewModel(workspace: url)
                            sessionError = nil
                        } catch {
                            sessionError = "Could not start Code session: \(error.localizedDescription)"
                        }
                    }
                }
                .keyboardShortcut("o")
                if !recentSessions.isEmpty {
                    RecentSessionList(
                        title: "Recent Code Sessions",
                        sessions: Array(recentSessions.prefix(5)),
                        workspacePath: { WorkspaceAccess.workspacePath(for: $0) },
                        actionTitle: "Resume",
                        onAction: resumeCodeSession)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { recentSessions = env.recentCodeSessions() }
        }
    }

    private func resumeCodeSession(_ session: AppSessionSummary) {
        guard let workspace = WorkspaceAccess.restoredWorkspace(for: session.id) ?? WorkspaceAccess.choose() else {
            return
        }
        do {
            codeVM = try env.makeCodeViewModel(session: session.id, workspace: workspace)
            sessionError = nil
        } catch {
            sessionError = "Could not resume Code session: \(error.localizedDescription)"
        }
    }
}

private struct RecentSessionList: View {
    let title: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let actionTitle: String
    let onAction: (AppSessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.id.rawValue)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(metadata(for: session))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(actionTitle) { onAction(session) }
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(.top, 8)
    }

    private func metadata(for session: AppSessionSummary) -> String {
        let timestamp = session.updatedAt == .distantPast
            ? "Unknown date"
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let workspace = workspacePath(session.id).map { " · \($0)" } ?? ""
        return "\(session.eventCount) events · \(timestamp)\(workspace)"
    }
}

struct CodeSessionView: View {
    @ObservedObject var vm: CodeViewModel

    var body: some View {
        CodeShell(items: vm.items,
                  pending: vm.pendingPermission,
                  permissionNotice: vm.permissionNotice,
                  isWorking: vm.isWorking,
                  workspaceName: vm.workspaceName,
                  agentState: vm.agentState,
                  composerError: vm.composerError,
                  input: $vm.input,
                  onSend: { vm.send() },
                  onResolve: { vm.resolvePermission($0) })
            .task { vm.start() }
    }
}

struct CoworkContainer: View {
    @ObservedObject var env: AppEnvironment
    @State private var coworkVM: CoworkViewModel?
    @State private var sessionError: String?
    @State private var recentSessions: [AppSessionSummary] = []

    var body: some View {
        if let vm = coworkVM {
            CoworkSessionView(vm: vm)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.2").font(.largeTitle).foregroundStyle(.secondary)
                Text("Start a Cowork session").font(.headline)
                if let sessionError {
                    Text(sessionError).font(.caption).foregroundStyle(.red)
                }
                Button("New Cowork Session") {
                    do {
                        coworkVM = try env.makeCoworkViewModel()
                        sessionError = nil
                    } catch {
                        sessionError = "Could not start Cowork session: \(error.localizedDescription)"
                    }
                }
                    .keyboardShortcut("n")
                if !recentSessions.isEmpty {
                    RecentSessionList(
                        title: "Recent Cowork Sessions",
                        sessions: Array(recentSessions.prefix(5)),
                        workspacePath: { _ in nil },
                        actionTitle: "Resume",
                        onAction: resumeCoworkSession)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { recentSessions = env.recentCoworkSessions() }
        }
    }

    private func resumeCoworkSession(_ session: AppSessionSummary) {
        do {
            coworkVM = try env.makeCoworkViewModel(session: session.id)
            sessionError = nil
        } catch {
            sessionError = "Could not resume Cowork session: \(error.localizedDescription)"
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
                    permissionNotice: vm.permissionNotice,
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
                    },
                    onRetryTask: { vm.retryFailedTask(id: $0) })
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
