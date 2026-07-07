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

/// Wires provider config + per-session event log + chat view model. Held by
/// the App as a `@StateObject`.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: AppProviderCatalog
    @Published private(set) var chatSessionID: SessionID
    @Published private(set) var viewModel: ChatViewModel
    @Published private(set) var chatSessionError: String?
    private(set) var log: EventLog
    private(set) var multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let secrets: ConfigSecretResolver

    init() {
        PlatformProfile.current = AppConfig.platformProfile

        self.secrets = ConfigSecretResolver()
        self.providerCatalog = AppConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(resolver: secrets)
        self.registry = initialRegistry
        let initialSession = AppConfig.recentSessions(kind: .chat).first?.id ?? AppConfig.defaultSession
        self.chatSessionID = initialSession
        do {
            self.log = try EventLog(session: initialSession,
                                    fileURL: AppConfig.sessionFile(initialSession))
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        let store: ArtifactStore
        do {
            store = try ArtifactStore(root: AppConfig.artifactsDir(initialSession))
        } catch {
            fatalError("Failed to open artifact store: \(error)")
        }
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = ChatViewModel(log: log, registry: initialRegistry)
        self.needsAPIKey = !Self.hasAPIKey(ref: AppConfig.selectedAPIKeyRef)

        wireImageGeneration()
    }

    func startNewChatSession() {
        do {
            try switchChatSession(to: SessionID.new())
        } catch {
            chatSessionError = "Could not start chat session: \(error.localizedDescription)"
        }
    }

    func resumeChatSession(_ session: AppSessionSummary) {
        do {
            try switchChatSession(to: session.id)
        } catch {
            chatSessionError = "Could not resume chat session: \(error.localizedDescription)"
        }
    }

    func recentChatSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .chat)
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerID = providerCatalog.selectedProvider?.id ?? "default"
        do {
            try AppConfig.writeEditableProviderConfig(
                catalog: providerCatalog,
                apiKeysByProviderID: [providerID: trimmed])
        } catch {
            return
        }
        secrets.cache(trimmed, for: .authFile(providerID: providerID))
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = false
        refreshProviderRegistry()
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(ref: .authFile(providerID: account))
    }

    func hasAPIKey(for provider: AppProviderSettings) -> Bool {
        Self.hasAPIKey(ref: AppConfig.apiKeyRef(for: provider))
    }

    func saveSettings(catalog rawCatalog: AppProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = AppConfig.normalizedCatalog(rawCatalog)
        var enteredAPIKeys: [String: String] = [:]
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }
            enteredAPIKeys[provider.id] = key
            catalog.providers[index].apiKeySource = nil
        }
        if !enteredAPIKeys.isEmpty {
            try AppConfig.writeEditableProviderConfig(
                catalog: catalog,
                apiKeysByProviderID: enteredAPIKeys)
            for (providerID, key) in enteredAPIKeys {
                secrets.cache(key, for: .authFile(providerID: providerID))
            }
        }
        AppConfig.providerCatalog = catalog
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))

        refreshProviderRegistry()
    }

    func selectProviderModel(providerID: String, modelID: String) {
        let catalog = AppConfig.selectProviderModel(providerID: providerID, modelID: modelID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
    }

    func healthCheckSelectedProvider() async -> [ProviderHealthReport] {
        let options = ProviderHealthCheckOptions(timeoutSeconds: 15)
        let chat = await registry.healthCheck(role: .chat, options: options)
        let agent = await registry.healthCheck(role: .agent, options: options)
        return [chat, agent]
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
        return CodeViewModel(sessionID: session, workspaceRoot: workspace, log: codeLog, registry: registry)
    }

    /// Build a fresh multi-agent Cowork project session bound to a primary workspace.
    func makeCoworkViewModel(primaryWorkspace: URL) throws -> CoworkViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        WorkspaceAccess.remember(primaryWorkspace, for: session)
        let settings = CoworkProjectSettings.fresh(
            sessionID: session,
            primaryWorkspace: primaryWorkspace,
            catalog: providerCatalog)
        CoworkProjectSettingsStore.save(settings)
        return try makeCoworkViewModel(session: session, projectSettings: settings)
    }

    func makeCoworkViewModel(session: SessionID) throws -> CoworkViewModel {
        let settings = CoworkProjectSettingsStore.load(sessionID: session, catalog: providerCatalog)
        return try makeCoworkViewModel(session: session, projectSettings: settings)
    }

    private func makeCoworkViewModel(session: SessionID,
                                     projectSettings: CoworkProjectSettings) throws -> CoworkViewModel {
        let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        return CoworkViewModel(
            sessionID: session,
            log: coworkLog,
            registry: registry,
            projectSettings: projectSettings)
    }

    func recentCodeSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .code)
    }

    func recentCoworkSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .cowork)
    }

    private func switchChatSession(to session: SessionID) throws {
        viewModel.stop()
        let log = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        let store = try ArtifactStore(root: AppConfig.artifactsDir(session))
        let model = ChatViewModel(log: log, registry: registry)
        self.log = log
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = model
        self.chatSessionID = session
        self.chatSessionError = nil
        wireImageGeneration()
        model.start()
    }

    private static func makeProviderRegistry(resolver: ConfigSecretResolver) -> ProviderRegistry {
        ProviderRegistry(config: AppConfig.providerConfig(), resolver: resolver)
    }

    private func refreshProviderRegistry() {
        secrets.clearCache()
        let updated = Self.makeProviderRegistry(resolver: secrets)
        registry = updated
        viewModel.updateProviderRegistry(updated)
        wireImageGeneration()
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

// The shell lives in IntatisMacRootView; root-owned session state feeds the
// reusable workspace home and session views below.

struct WorkspaceSessionHome: View {
    let title: String
    let subtitle: String
    let icon: String
    let primaryTitle: String
    let primarySystemImage: String
    let primaryShortcut: KeyEquivalent?
    let error: String?
    let sessionsTitle: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let onPrimary: () -> Void
    let onResume: (AppSessionSummary) -> Void
    @Environment(\.colorScheme) private var scheme

    init(title: String,
         subtitle: String,
         icon: String,
         primaryTitle: String,
         primarySystemImage: String,
         primaryShortcut: KeyEquivalent? = nil,
         error: String?,
         sessionsTitle: String,
         sessions: [AppSessionSummary],
         workspacePath: @escaping (SessionID) -> String?,
         onPrimary: @escaping () -> Void,
         onResume: @escaping (AppSessionSummary) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.primaryTitle = primaryTitle
        self.primarySystemImage = primarySystemImage
        self.primaryShortcut = primaryShortcut
        self.error = error
        self.sessionsTitle = sessionsTitle
        self.sessions = sessions
        self.workspacePath = workspacePath
        self.onPrimary = onPrimary
        self.onResume = onResume
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = IntatisMacScreenLayout(rawWidth: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    IntatisPageHeader(title: title, subtitle: subtitle)

                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(IntatisTheme.goldDeep)
                            .frame(width: 64, height: 64)
                            .background(IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.22 : 0.34),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text(primaryTitle)
                            .font(IntatisType.title(20))
                            .foregroundStyle(IntatisTheme.deepText(scheme))
                        primaryButton
                        if let error {
                            Text(error)
                                .font(IntatisType.caption(12))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 620, alignment: .leading)
                    .intatisGlassCard(cornerRadius: 22)

                    if !sessions.isEmpty {
                        RecentSessionList(
                            title: sessionsTitle,
                            sessions: sessions,
                            workspacePath: workspacePath,
                            actionTitle: "Resume",
                            onAction: onResume)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: layout.settingsMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let button = Button(action: onPrimary) {
            Label(primaryTitle, systemImage: primarySystemImage)
                .font(IntatisType.body(14, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(IntatisTheme.accentGradient, in: Capsule())
        }
        .buttonStyle(.plain)

        if let primaryShortcut {
            button.keyboardShortcut(primaryShortcut)
        } else {
            button
        }
    }
}

private struct RecentSessionList: View {
    let title: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let actionTitle: String
    let onAction: (AppSessionSummary) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.id.rawValue)
                            .font(IntatisType.caption(12, .semibold))
                            .foregroundStyle(IntatisTheme.deepText(scheme))
                            .lineLimit(1)
                        Text(metadata(for: session))
                            .font(IntatisType.caption(11, .regular))
                            .foregroundStyle(IntatisTheme.softText(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(actionTitle) { onAction(session) }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.25 : 0.62),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(IntatisTheme.glassStroke(scheme).opacity(scheme == .dark ? 0.36 : 0.70), lineWidth: 1)
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 760, alignment: .leading)
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
    let catalog: AppProviderCatalog
    let onSelectModel: (String, String) -> Void
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CodeShell(items: vm.items,
                  pending: vm.pendingPermission,
                  permissionNotice: vm.permissionNotice,
                  latestTurnStats: vm.latestTurnStats,
                  isWorking: vm.isWorking,
                  workspaceName: vm.workspaceName,
                  agentState: vm.agentState,
                  composerError: vm.composerError,
                  threadStyle: .intatisMac(scheme),
                  onShowSessions: onShowSessions,
                  onNewSession: onNewSession,
                  composerAccessory: AnyView(IntatisComposerAccessory(
                    catalog: catalog,
                    isBusy: vm.isWorking,
                    latestTurnStats: vm.latestTurnStats,
                    contextLabel: contextLabel,
                    onSelectModel: onSelectModel)),
                  input: $vm.input,
                  onSend: { vm.send() },
                  onResolve: { vm.resolvePermission($0) })
            .task { vm.start() }
    }

    private var contextLabel: String? {
        guard let promptTokens = vm.latestTurnStats?.promptTokens else { return nil }
        let formatted = Self.numberFormatter.string(from: NSNumber(value: promptTokens)) ?? "\(promptTokens)"
        return "Context \(formatted) tok"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

struct CoworkSessionView: View {
    @ObservedObject var vm: CoworkViewModel
    let catalog: AppProviderCatalog
    let onSelectModel: (String, String) -> Void
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    @State private var showProjectSettings = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CoworkShell(items: vm.items,
                    agents: vm.agents,
                    pending: vm.pendingPermission,
                    permissionNotice: vm.permissionNotice,
                    latestTurnStats: vm.latestTurnStats,
                    summary: vm.summary,
                    project: vm.project,
                    composerError: vm.composerError,
                    isWorking: vm.isWorking,
                    threadStyle: .intatisMac(scheme),
                    onShowSessions: onShowSessions,
                    onNewSession: onNewSession,
                    onShowProjectSettings: { showProjectSettings = true },
                    composerAccessory: AnyView(IntatisComposerAccessory(
                        catalog: catalog,
                        isBusy: vm.isWorking,
                        latestTurnStats: vm.latestTurnStats,
                        contextLabel: contextLabel,
                        onSelectModel: onSelectModel)),
                    input: $vm.input,
                    onSend: { vm.send() },
                    onResolve: { vm.resolvePermission($0) },
                    onRemoveAgent: { vm.removeAgent(name: $0) },
                    onRetryTask: { vm.retryFailedTask(id: $0) })
            .task { vm.start() }
            .sheet(isPresented: $showProjectSettings) { projectSettingsSheet }
    }

    private var contextLabel: String? {
        guard let promptTokens = vm.latestTurnStats?.promptTokens else { return nil }
        let formatted = Self.numberFormatter.string(from: NSNumber(value: promptTokens)) ?? "\(promptTokens)"
        return "Context \(formatted) tok"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private var projectSettingsSheet: some View {
        CoworkProjectSettingsSheet(
            vm: vm,
            catalog: catalog,
            onAddWorkspace: {
                if let url = WorkspaceAccess.choose(prompt: "Choose Project Workspace") {
                    vm.addProjectWorkspace(url)
                }
            })
    }
}

@main
struct IntatisMacApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            IntatisMacRootView().environmentObject(env)
        }
        .defaultSize(width: 1100, height: 760)
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
