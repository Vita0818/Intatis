#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisAgentKernel
import IntatisArtifacts
import IntatisMultimodal
import IntatisSharedUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Wires process-wide provider configuration to the application-owned session
/// runtime registry. Window views only select which retained runtime to show.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: AppProviderCatalog
    @Published private(set) var inferenceProfileOptions: [AppInferenceProfileOption]
    @Published private(set) var inferenceCatalogError: String?
    @Published private(set) var chatSessionID: SessionID
    @Published private(set) var viewModel: ChatViewModel
    @Published private(set) var chatSessionError: String?
    @Published var needsAPIKey: Bool

    let runtimeManager: AppSessionRuntimeManager
    private var chatRuntime: AppChatSessionRuntime
    private let secrets: ConfigSecretResolver
    private let inferenceCatalogStore: InferenceCatalogStore
    private var inferenceCatalogSnapshot: InferenceCatalogSnapshot?

    init(runtimeManager: AppSessionRuntimeManager) {
        PlatformProfile.current = AppConfig.platformProfile

        self.runtimeManager = runtimeManager
        self.secrets = ConfigSecretResolver()
        self.inferenceCatalogStore = InferenceCatalogStore(
            fileURL: AppConfig.appSupportDir()
                .appendingPathComponent("inference-catalog-v1.json"))
        self.inferenceCatalogSnapshot = nil
        self.inferenceProfileOptions = []
        self.inferenceCatalogError = nil
        self.providerCatalog = AppConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(
            resolver: secrets,
            inferenceCatalogSnapshot: nil)
        self.registry = initialRegistry
        let initialSession = AppConfig.recentSessions(kind: .chat).first?.id ?? AppConfig.defaultSession
        self.chatSessionID = initialSession
        let initialChatRuntime: AppChatSessionRuntime
        do {
            initialChatRuntime = try runtimeManager.chatRuntime(
                sessionID: initialSession,
                registry: initialRegistry)
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        self.chatRuntime = initialChatRuntime
        self.viewModel = initialChatRuntime.viewModel
        self.needsAPIKey = !Self.hasAPIKey(ref: AppConfig.selectedAPIKeyRef)

        Task { [weak self] in
            guard let self else { return }
            _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                in: self.chatRuntime.log,
                kind: .chat)
            await self.refreshInferenceCatalog()
        }
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

    func resumeChatSession(_ session: AppSessionSummary) {
        do {
            try switchChatSession(to: session.id)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not resume chat session: %@",
                error.localizedDescription)
        }
    }

    func recentChatSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .chat)
    }

    func deleteChatSession(_ session: SessionID) async throws {
        guard !runtimeManager.isBusy(kind: .chat, sessionID: session) else {
            throw IntatisError.io(IntatisLocalization.string(
                "Wait for the Chat response to finish before deleting this session."))
        }
        if session == chatSessionID {
            let replacement = recentChatSessions()
                .first(where: { $0.id != session })?.id
                ?? SessionID.new()
            try switchChatSession(to: replacement)
        }
        try await runtimeManager.removeSession(
            kind: .chat,
            sessionID: session,
            reason: "Chat session deleted by user"
        ) {
            try SessionHistoryStore.deleteSession(
                root: AppConfig.appSupportDir(),
                session: session)
        }
    }

    func handleRemovedChatRuntime(sessionID: SessionID) {
        guard chatSessionID == sessionID else { return }
        let replacement = recentChatSessions()
            .first(where: { $0.id != sessionID })?.id
            ?? SessionID.new()
        do {
            try switchChatSession(to: replacement)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "The removed Chat session could not be replaced: %@",
                error.localizedDescription)
        }
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
        scheduleInferenceCatalogRefresh()
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
        scheduleInferenceCatalogRefresh()
    }

    func selectProviderModel(providerID: String, modelID: String, variantID: String?) {
        let catalog = AppConfig.selectProviderModel(
            providerID: providerID,
            modelID: modelID,
            variantID: variantID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
        if inferenceCatalogSnapshot == nil {
            scheduleInferenceCatalogRefresh()
        }
    }

    func healthCheckSelectedProvider() async -> [ProviderHealthReport] {
        let options = ProviderHealthCheckOptions(timeoutSeconds: 15)
        let chat = await registry.healthCheck(role: .chat, options: options)
        let agent = await registry.healthCheck(role: .agent, options: options)
        return [chat, agent]
    }

    /// Build a fresh Code session bound to the chosen workspace folder.
    func makeCodeViewModel(workspace: WorkspaceAccessLease) throws -> CodeViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        return try makeCodeViewModel(session: session, workspace: workspace)
    }

    func makeCodeViewModel(session: SessionID,
                           workspace: WorkspaceAccessLease) throws -> CodeViewModel {
        if let existing = runtimeManager.cachedCodeRuntime(sessionID: session) {
            workspace.release()
            return existing
        }
        let hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
            forPath: workspace.canonicalPath,
            in: session)
        do {
            try WorkspaceAccess.remember(
                workspace.scopedURL,
                for: session,
                isPrimary: true)
            let codeLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
            Task {
                _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                    in: codeLog,
                    kind: .code)
            }
            let runtime = CodeViewModel(
                sessionID: session,
                workspaceAccess: workspace,
                log: codeLog,
                sessionNaming: makeSessionNamingService(log: codeLog, kind: .code),
                registry: registry)
            return try runtimeManager.registerCodeRuntime(runtime)
        } catch {
            if !hadRememberedAccess {
                try? WorkspaceAccess.forget(
                    path: workspace.canonicalPath,
                    in: session,
                    allowPrimaryRemoval: true)
            }
            workspace.release()
            throw error
        }
    }

    /// Build a fresh multi-agent Cowork project session bound to a primary workspace.
    func makeCoworkViewModel(primaryWorkspace: WorkspaceAccessLease) async throws -> CoworkViewModel {
        guard let inferenceCatalogSnapshot else {
            primaryWorkspace.release()
            throw IntatisError.config(
                inferenceCatalogError ?? IntatisLocalization.string(
                    "Inference profiles are still loading. Try again in a moment."))
        }
        guard let selectedBinding = AppInferenceCatalogCompiler.selectedBinding(
            catalog: providerCatalog,
            snapshot: inferenceCatalogSnapshot) else {
            primaryWorkspace.release()
            throw IntatisError.config(IntatisLocalization.string(
                "Choose a resolvable default inference profile before creating Cowork."))
        }
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        do {
            try WorkspaceAccess.remember(
                primaryWorkspace.scopedURL,
                for: session,
                isPrimary: true)
            let settings = CoworkProjectSettings.fresh(
                sessionID: session,
                primaryWorkspace: primaryWorkspace.canonicalURL,
                catalog: providerCatalog,
                defaultInferenceProfileBinding: selectedBinding)
            let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
            return try await runtimeManager.coworkRuntime(sessionID: session) { [self] in
                try makeCoworkViewModel(
                    session: session,
                    log: coworkLog,
                    projectSettings: settings,
                    launchMode: .fresh,
                    initialWorkspaceAccess: primaryWorkspace)
            }
        } catch {
            try? WorkspaceAccess.forget(
                path: primaryWorkspace.canonicalPath,
                in: session,
                allowPrimaryRemoval: true)
            primaryWorkspace.release()
            throw error
        }
    }

    func makeCoworkViewModel(session: SessionID) async throws -> CoworkViewModel {
        guard let inferenceCatalogSnapshot else {
            throw IntatisError.config(
                inferenceCatalogError ?? IntatisLocalization.string(
                    "Inference profiles are still loading. Try again in a moment."))
        }
        return try await runtimeManager.coworkRuntime(sessionID: session) { [self] in
        let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        let legacyOwnedWorkspacePaths = CoworkProjectSettingsStore
            .legacyOwnedWorkspacePaths(sessionID: session)
        let loaded = await CoworkProjectSettingsStore.loadAndMigrate(
            sessionID: session,
            log: coworkLog,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        var projectSettings = loaded.settings
        var warning = loaded.warning
        do {
            let projection = try await SessionProjectionStore.rebuild(from: coworkLog)
            let migrationAlreadyCompleted = projection.completedMigrations.contains {
                $0.migrationID == SessionProjectionStore.legacyWorkspaceAccessMigrationID
            }
            if migrationAlreadyCompleted {
                // Older/interrupted Phase S builds could have persisted a
                // symbolic-link spelling in EventLog while correctly keying
                // the capability plist by the canonical directory. Repair
                // only aliases proven through a live session bookmark.
                let mappings = try WorkspaceAccess.validatedCanonicalPathMappings(
                    for: projectSettings.workspaces.map(\.path),
                    in: session)
                projectSettings = try await persistValidatedWorkspacePathMappings(
                    mappings,
                    settings: projectSettings,
                    log: coworkLog)
                // The marker is appended only after the session-owned file was
                // read back successfully. Retrying cleanup here closes the
                // crash window between that durable marker and UserDefaults
                // deletion without ever re-importing shared capabilities.
                WorkspaceAccess.clearLegacySessionStorage(for: session)
                if loaded.legacySettingsCleanupEligible {
                    CoworkProjectSettingsStore.clearLegacyStorage(sessionID: session)
                }
            } else {
                let migration = try WorkspaceAccess.migrateLegacyBookmarks(
                    for: session,
                    workspacePaths: projectSettings.workspaces.map(\.path),
                    primaryPath: projectSettings.primaryWorkspace?.path,
                    sharedLegacyPaths: legacyOwnedWorkspacePaths)
                if migration.didMigrate {
                    projectSettings = try await persistValidatedWorkspacePathMappings(
                        migration.canonicalPathsByStoredPath,
                        settings: projectSettings,
                        log: coworkLog)
                    _ = try await SessionProjectionStore.recordMigration(
                        in: coworkLog,
                        migrationID: SessionProjectionStore.legacyWorkspaceAccessMigrationID,
                        source: .legacyWorkspaceUserDefaults)
                    WorkspaceAccess.clearLegacySessionStorage(for: session)
                    if loaded.legacySettingsCleanupEligible {
                        CoworkProjectSettingsStore.clearLegacyStorage(sessionID: session)
                    }
                }
            }
        } catch {
            let message = IntatisLocalization.format(
                "Legacy workspace access remains in compatibility mode: %@",
                error.localizedDescription)
            warning = warning.map { "\($0) \(message)" } ?? message
        }
        return try makeCoworkViewModel(
            session: session,
            log: coworkLog,
            projectSettings: projectSettings,
            launchMode: .restored,
            sessionStorageWarning: warning)
        }
    }

    private func persistValidatedWorkspacePathMappings(
        _ mappings: [String: String],
        settings: CoworkProjectSettings,
        log: EventLog
    ) async throws -> CoworkProjectSettings {
        guard !mappings.isEmpty else { return settings }
        var canonical = settings
        canonical.applyValidatedWorkspacePathMappings(mappings)
        guard canonical != settings else { return settings }
        let document = try await SessionProjectionStore.updateSettings(
            in: log,
            kind: .cowork,
            coworkSettings: canonical,
            changeKind: .migrated)
        guard let persisted = document.coworkSettings else {
            throw IntatisError.io(
                "Canonical workspace aliases were not persisted in session settings.")
        }
        return persisted
    }

    private func makeCoworkViewModel(
        session: SessionID,
        log coworkLog: EventLog,
        projectSettings: CoworkProjectSettings,
        launchMode: CoworkSessionLaunchMode,
        sessionStorageWarning: String? = nil,
        initialWorkspaceAccess: WorkspaceAccessLease? = nil
    ) throws -> CoworkViewModel {
        let artifactStore = try ArtifactStore(root: AppConfig.artifactsDir(session))
        return CoworkViewModel(
            sessionID: session,
            log: coworkLog,
            artifactStore: artifactStore,
            sessionNaming: makeSessionNamingService(log: coworkLog, kind: .cowork),
            registry: registry,
            inferenceProfileOptions: inferenceProfileOptions,
            projectSettings: projectSettings,
            launchMode: launchMode,
            sessionStorageWarning: sessionStorageWarning,
            initialWorkspaceAccess: initialWorkspaceAccess)
    }

    private func makeSessionNamingService(
        log: EventLog,
        kind: SessionKind
    ) -> EventLogSessionNamingService {
        let manager = runtimeManager
        return EventLogSessionNamingService(log: log, kind: kind) { commit in
            await manager.publishSessionDisplayNameChange(AppSessionDisplayNameChange(
                key: AppSessionRuntimeKey(
                    kind: commit.kind,
                    sessionID: commit.sessionID),
                displayName: commit.displayName,
                settingsRevision: commit.settingsRevision,
                projectedThroughSeq: commit.projectedThroughSeq))
        }
    }

    func recentCodeSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .code)
    }

    func recentCoworkSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .cowork)
    }

    private func switchChatSession(to session: SessionID) throws {
        let runtime = try runtimeManager.chatRuntime(
            sessionID: session,
            registry: registry)
        self.chatRuntime = runtime
        self.viewModel = runtime.viewModel
        self.chatSessionID = session
        self.chatSessionError = nil
        Task {
            _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                in: runtime.log,
                kind: .chat)
        }
    }

    private static func makeProviderRegistry(
        resolver: ConfigSecretResolver,
        inferenceCatalogSnapshot: InferenceCatalogSnapshot?
    ) -> ProviderRegistry {
        ProviderRegistry(
            config: AppConfig.providerConfig(),
            resolver: resolver,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
    }

    private func refreshProviderRegistry() {
        secrets.clearCache()
        let updated = Self.makeProviderRegistry(
            resolver: secrets,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        registry = updated
        runtimeManager.updateProviderRegistry(
            updated,
            inferenceProfileOptions: inferenceProfileOptions)
    }

    private func scheduleInferenceCatalogRefresh() {
        Task { [weak self] in
            await self?.refreshInferenceCatalog()
        }
    }

    private func refreshInferenceCatalog() async {
        let sourceCatalog = providerCatalog
        do {
            let draft = try AppInferenceCatalogCompiler.compile(catalog: sourceCatalog)
            let snapshot = try await inferenceCatalogStore.reconcile(draft)
            guard sourceCatalog == providerCatalog else {
                scheduleInferenceCatalogRefresh()
                return
            }
            inferenceCatalogSnapshot = snapshot
            inferenceProfileOptions = AppInferenceCatalogCompiler.options(
                catalog: sourceCatalog,
                snapshot: snapshot)
            inferenceCatalogError = nil
            refreshProviderRegistry()
        } catch {
            // Keep a previously valid snapshot/registry alive for exact
            // bindings. Initial startup remains fail-closed until a valid
            // durable catalog can be loaded or reconciled.
            inferenceCatalogError = IntatisLocalization.format(
                "Versioned inference profiles are unavailable: %@",
                error.localizedDescription)
        }
    }

    private static func hasAPIKey(ref: KeychainRef) -> Bool {
        ConfigSecretResolver.exists(ref)
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
                            .foregroundStyle(IntatisTheme.accent(scheme))
                            .frame(width: 64, height: 64)
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
                    .intatisCard(cornerRadius: 22)

                    if !sessions.isEmpty {
                        RecentSessionList(
                            title: sessionsTitle,
                            sessions: sessions,
                            workspacePath: workspacePath,
                            actionTitle: IntatisLocalization.string("Resume"),
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
                .foregroundStyle(.primary)
        }
        .controlSize(.large)
        .intatisGlassButton(prominent: true)

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
                        .controlSize(.small)
                        .intatisGlassButton()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func metadata(for session: AppSessionSummary) -> String {
        let timestamp = session.updatedAt == .distantPast
            ? IntatisLocalization.string("Unknown date")
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let workspace = workspacePath(session.id).map { " · \($0)" } ?? ""
        let count = session.eventCount == 1
            ? IntatisLocalization.string("1 event")
            : IntatisLocalization.format("%lld events", Int64(session.eventCount))
        return "\(count) · \(timestamp)\(workspace)"
    }
}

struct CodeSessionView: View {
    @ObservedObject var vm: CodeViewModel
    let sessionTitle: String
    let catalog: AppProviderCatalog
    let onSelectModel: (String, String, String?) -> Void
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    @Binding var showsInspector: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
            CodeShell(items: vm.items,
                      presentationScope: IntatisThreadPresentationScope(
                        kind: .code,
                        sessionID: vm.sessionID),
                      sessionTitle: sessionTitle,
                      thinkingScopeID: vm.sessionID.rawValue,
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
                  composerAccessory: AnyView(IntatisComposerModelControl(
                    catalog: catalog,
                    isBusy: vm.isWorking,
                    onSelectModel: onSelectModel)),
                  showsInspector: $showsInspector,
                  input: $vm.input,
                  onSend: { vm.send() },
                  onCancelCurrent: { vm.cancelCurrentTurn() },
                  onResolve: { vm.resolvePermission($0) })
    }

}

struct CoworkSessionView: View {
    @ObservedObject var vm: CoworkViewModel
    let sessionTitle: String
    let catalog: AppProviderCatalog
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    let onSessionDidBecomeReady: () -> Void
    @Binding var showsInspector: Bool
    @State private var showProjectSettings = false
    @State private var showGoalEditor = false
    @State private var showGoalClearConfirmation = false
    @State private var goalObjectiveDraft = ""
    @State private var goalSuccessCriteriaDraft = ""
    @State private var goalConstraintsDraft = ""
    @State private var goalTokenBudgetDraft = ""
    @State private var goalEditorSubmissionError: String?
    @State private var showAttachmentImporter = false
    @Environment(\.colorScheme) private var scheme

    private var hasMainAgent: Bool {
        vm.agents.contains { $0.name == vm.project.mainAgentName }
    }

    private var isCoworkBusy: Bool {
        vm.isAgentWorkActive || vm.isGoalContinuing
    }

    var body: some View {
        VStack(spacing: 0) {
            CoworkShell(items: vm.items,
                        presentationScope: IntatisThreadPresentationScope(
                            kind: .cowork,
                            sessionID: vm.sessionID),
                        sessionTitle: sessionTitle,
                        thinkingScopeID: vm.sessionID.rawValue,
                        agents: vm.agents,
                        pending: vm.pendingPermission,
                        permissionNotice: vm.permissionNotice,
                        latestTurnStats: vm.latestTurnStats,
                        summary: vm.summary,
                        project: vm.project,
                        goal: vm.goal,
                        workTasks: vm.workTasks,
                        composerError: vm.composerError
                            ?? vm.inferenceComposerError
                            ?? vm.projectionError
                            ?? vm.sessionStorageWarning,
                        isWorking: isCoworkBusy,
                        isAcceptingSubmission: vm.isAcceptingSubmission,
                        hasDraftAttachments: !vm.draftAttachments.isEmpty,
                        threadStyle: .intatisMac(scheme),
                        onShowSessions: onShowSessions,
                        onNewSession: onNewSession,
                        onShowProjectSettings: { showProjectSettings = true },
                        composerAccessory: AnyView(CoworkInferenceAccessory(
                            options: vm.inferenceProfileOptions,
                            selectedBinding: vm.nextMainInferenceBinding,
                            isDisabled: !hasMainAgent,
                            onSelect: { binding in
                                vm.selectMainInferenceProfileForNextSubmission(binding)
                            })),
                        composerInputAccessory: AnyView(HStack(
                            alignment: .center,
                            spacing: IntatisComposerControlMetrics.rowSpacing
                        ) {
                            Button {
                                showAttachmentImporter = true
                            } label: {
                                Label(
                                    IntatisLocalization.string("Attach files"),
                                    systemImage: "paperclip")
                                    .intatisComposerIconLabel()
                            }
                            .intatisCompactIconButton()
                            .help(IntatisLocalization.string("Attach files"))
                            .accessibilityLabel(IntatisLocalization.string("Attach files"))
                            .accessibilityIdentifier("cowork.composer.attach")
                            if !vm.draftAttachments.isEmpty {
                                Menu(IntatisLocalization.format(
                                    "%lld attached",
                                    Int64(vm.draftAttachments.count))) {
                                    ForEach(vm.draftAttachments) { attachment in
                                        Button(IntatisLocalization.format(
                                            "Remove %@",
                                            attachment.name)) {
                                            vm.removeDraftAttachment(attachment.id)
                                        }
                                    }
                                }
                                .controlSize(.regular)
                                .menuStyle(.borderlessButton)
                                .accessibilityIdentifier("cowork.composer.attachments")
                            }
                        }
                        .frame(
                            minHeight: IntatisComposerControlMetrics.controlHeight,
                            alignment: .center)),
                        showsInspector: $showsInspector,
                        input: $vm.input,
                        onSend: { vm.send() },
                        onCancelCurrent: isCoworkBusy
                            ? { vm.cancelCurrentActivity() }
                            : nil,
                        onResolve: { vm.resolvePermission($0) },
                        onRemoveAgent: { vm.removeAgent(name: $0) },
                        onRetryTask: { vm.retryFailedTask(id: $0) },
                        onRetrySubmission: { vm.retrySubmission($0) },
                        onPauseGoal: { vm.pauseGoal() },
                        onResumeGoal: { vm.resumeGoal() },
                        onEditGoal: { presentGoalEditor() },
                        onClearGoal: { showGoalClearConfirmation = true })
        }
        // SwiftUI preserves this view's structural identity when one Cowork
        // session replaces another. Key startup to the durable session ID so
        // the new view model cannot inherit the completed task of the old one.
        .onChange(of: hasMainAgent) { isReady in
            guard isReady else { return }
            // The first @main projection also means events.jsonl now exists,
            // so a history rescan can expose the new session in the sidebar.
            onSessionDidBecomeReady()
        }
        .sheet(isPresented: $showProjectSettings) { projectSettingsSheet }
        .sheet(isPresented: $showGoalEditor) { goalEditorSheet }
        .fileImporter(
            isPresented: $showAttachmentImporter,
            allowedContentTypes: [.data, .content],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                vm.importDraftAttachments(urls)
            case .failure(let error):
                vm.reportAttachmentImportFailure(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            vm.importDraftAttachments(urls)
            return true
        }
        .alert("Clear this Goal?", isPresented: $showGoalClearConfirmation) {
            Button("Clear", role: .destructive) { vm.clearGoal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Goal card will be cleared without marking the Goal completed. Its durable history remains in the session log.")
        }
    }

    private var goalEditorValidationMessage: String? {
        if let goalEditorSubmissionError { return goalEditorSubmissionError }
        if goalObjectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return IntatisLocalization.string("A Goal objective is required.")
        }
        let budget = goalTokenBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty, Int(budget).map({ $0 > 0 }) != true {
            return IntatisLocalization.string(
                "Token budget must be a positive whole number, or left empty for no budget.")
        }
        return nil
    }

    private func presentGoalEditor() {
        guard let draft = vm.currentGoalEditDraft() else { return }
        goalObjectiveDraft = draft.objective
        goalSuccessCriteriaDraft = draft.successCriteria
        goalConstraintsDraft = draft.constraints
        goalTokenBudgetDraft = draft.tokenBudget
        goalEditorSubmissionError = nil
        showGoalEditor = true
    }

    private var projectSettingsSheet: some View {
        CoworkProjectSettingsSheet(
            vm: vm,
            catalog: catalog,
            inferenceProfileOptions: vm.inferenceProfileOptions,
            onAddWorkspace: {
                if let url = WorkspaceAccess.choose(
                    prompt: IntatisLocalization.string("Choose Project Workspace")) {
                    vm.addProjectWorkspace(url)
                }
            })
    }

    private var goalEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Goal")
                .font(.title2.bold())
            Text("Edit the durable objective and its requirements. Enter one success criterion or constraint per line. Leaving token budget empty means no Goal budget. A paused Goal remains paused.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Objective")
                    .font(.caption.bold())
                TextEditor(text: $goalObjectiveDraft)
                    .font(.body)
                    .frame(minWidth: 500, minHeight: 90)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                    .accessibilityLabel("Goal objective")
                    .accessibilityIdentifier("cowork.goal.editor.objective")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Success criteria")
                        .font(.caption.bold())
                    Spacer()
                    Text("One per line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $goalSuccessCriteriaDraft)
                    .font(.body)
                    .frame(minHeight: 82)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                    .accessibilityLabel("Goal success criteria, one per line")
                    .accessibilityIdentifier("cowork.goal.editor.success_criteria")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Constraints")
                        .font(.caption.bold())
                    Spacer()
                    Text("One per line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $goalConstraintsDraft)
                    .font(.body)
                    .frame(minHeight: 82)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                    .accessibilityLabel("Goal constraints, one per line")
                    .accessibilityIdentifier("cowork.goal.editor.constraints")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Token budget (optional)")
                    .font(.caption.bold())
                TextField("No budget", text: $goalTokenBudgetDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Optional positive Goal token budget")
                    .accessibilityIdentifier("cowork.goal.editor.token_budget")
            }

            if let validationMessage = goalEditorValidationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cowork.goal.editor.validation")
            }

            HStack {
                Spacer()
                Button("Cancel") { showGoalEditor = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cowork.goal.editor.cancel")
                Button("Save") {
                    if let error = vm.editGoal(
                        objective: goalObjectiveDraft,
                        successCriteria: goalSuccessCriteriaDraft,
                        constraints: goalConstraintsDraft,
                        tokenBudget: goalTokenBudgetDraft) {
                        goalEditorSubmissionError = error
                        return
                    }
                    showGoalEditor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(goalEditorValidationMessage != nil)
                .accessibilityIdentifier("cowork.goal.editor.save")
            }
        }
        .padding(22)
        .frame(width: 580)
        .accessibilityIdentifier("cowork.goal.editor")
        .onChange(of: goalObjectiveDraft) { _ in goalEditorSubmissionError = nil }
        .onChange(of: goalSuccessCriteriaDraft) { _ in goalEditorSubmissionError = nil }
        .onChange(of: goalConstraintsDraft) { _ in goalEditorSubmissionError = nil }
        .onChange(of: goalTokenBudgetDraft) { _ in goalEditorSubmissionError = nil }
    }
}

private struct CoworkInferenceAccessory: View {
    let options: [AppInferenceProfileOption]
    let selectedBinding: AgentInferenceBinding?
    let isDisabled: Bool
    let onSelect: (AgentInferenceBinding) -> Void
    @Environment(\.colorScheme) private var scheme

    private var selectedOption: AppInferenceProfileOption? {
        guard let selectedBinding else { return nil }
        return options.first { $0.binding == selectedBinding }
    }

    private var modelLabel: String {
        selectedOption?.modelTitle ?? IntatisLocalization.string("Inference unavailable")
    }

    private var menuProviders: [ProviderModelMenuProvider] {
        Dictionary(grouping: options, by: \.providerID)
            .compactMap { providerID, providerOptions in
                guard let first = providerOptions.first else { return nil }
                return ProviderModelMenuProvider(
                    id: providerID,
                    title: first.providerTitle,
                    models: providerOptions.map { option in
                        ProviderModelMenuModel(
                            id: option.id,
                            modelID: option.modelID,
                            variantID: option.variantID,
                            title: option.modelTitle,
                            detail: option.variantTitle)
                    })
            }
            .sorted { lhs, rhs in
                [lhs.title, lhs.id].lexicographicallyPrecedes([rhs.title, rhs.id])
            }
    }

    var body: some View {
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID: selectedOption?.providerID ?? "",
            selectedModelID: selectedOption?.modelID ?? "",
            selectedVariantID: selectedOption?.variantID,
            isBusy: isDisabled || options.isEmpty,
            onSelect: { providerID, modelID, variantID in
                guard let option = options.first(where: {
                    $0.providerID == providerID
                        && $0.modelID == modelID
                        && $0.variantID == variantID
                }) else { return }
                onSelect(option.binding)
            }) {
                HStack(spacing: 8) {
                    Text(modelLabel)
                        .font(IntatisType.body(13, .semibold))
                        .foregroundStyle(IntatisTheme.deepText(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IntatisTheme.tertiaryText(scheme))
                        .accessibilityHidden(true)
                }
                .intatisComposerSelectionLabel()
        }
        .intatisComposerSelectionMenu()
        .help(helpText)
        .accessibilityLabel(Text(IntatisLocalization.format(
            "Next @main model: %@",
            modelLabel)))
        .accessibilityIdentifier("cowork.main.inference-profile")
    }

    private var helpText: String {
        if options.isEmpty {
            return IntatisLocalization.string("No configured inference profiles are available")
        }
        if isDisabled {
            return IntatisLocalization.string(
                "@main must be attached before selecting its next model")
        }
        return IntatisLocalization.string(
            "Model for the next @main message. Current work and other agents keep their existing models.")
    }
}

#if canImport(AppKit)
@MainActor
final class IntatisApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if INTATIS_RENDERER_VALIDATION
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-IntatisRendererFixture"),
              let rawSeconds = Self.argumentValue(
                  after: "-IntatisRendererFixtureAutoExitSeconds"),
              let seconds = Double(rawSeconds),
              (1...300).contains(seconds)
        else { return }

        // Keep watchdog auto-exit independent of SwiftUI view-task lifetime.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApplication.shared.terminate(nil)
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if INTATIS_RENDERER_VALIDATION
        // The offline renderer fixture never creates AppEnvironment or session runtimes.
        // Let its watchdog-owned auto-exit complete inside the containment window
        // instead of paying the production runtime-drain deadline.
        if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
            return .terminateNow
        }
        #endif
        let manager = AppSessionRuntimeManager.shared
        if manager.state == .stopped {
            return .terminateNow
        }
        guard terminationTask == nil else { return .terminateLater }
        let deadline: SessionRuntimeShutdownDeadline
        #if DEBUG
        if let raw = Self.argumentValue(after: "-IntatisShutdownDeadlineMilliseconds"),
           let milliseconds = Int64(raw), milliseconds >= 0 {
            deadline = .after(.milliseconds(milliseconds))
        } else {
            deadline = .after(.seconds(8))
        }
        #else
        deadline = .after(.seconds(8))
        #endif
        terminationTask = Task { @MainActor [weak self] in
            _ = await manager.shutdownAll(
                reason: "Application quit requested",
                deadline: deadline)
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif

@main
struct IntatisMacApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(IntatisApplicationDelegate.self)
    private var applicationDelegate
    #endif

    private var launchAppearance: ColorScheme? {
        #if DEBUG || INTATIS_RENDERER_VALIDATION
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-IntatisAppearanceDark") { return .dark }
        if arguments.contains("-IntatisAppearanceLight") { return .light }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG || INTATIS_RENDERER_VALIDATION
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-IntatisPhaseLLifecycleFixture") {
                PhaseLSessionLifecycleFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if ProcessInfo.processInfo.arguments.contains("-IntatisPhaseCPermissionFixture") {
                PhaseCPermissionFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
                RendererFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else {
                IntatisProductionRootView(launchAppearance: launchAppearance)
            }
            #else
            if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
                RendererFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else {
                IntatisProductionRootView(launchAppearance: launchAppearance)
            }
            #endif
            #else
            IntatisProductionRootView(launchAppearance: launchAppearance)
            #endif
        }
        .defaultSize(width: 1100, height: 760)
    }
}

@MainActor
private struct IntatisProductionRootView: View {
    @StateObject private var env: AppEnvironment
    let launchAppearance: ColorScheme?

    init(launchAppearance: ColorScheme?) {
        self.launchAppearance = launchAppearance
        _env = StateObject(wrappedValue: AppEnvironment(runtimeManager: .shared))
    }

    var body: some View {
        IntatisMacRootView(runtimeManager: env.runtimeManager)
            .environmentObject(env)
            .preferredColorScheme(launchAppearance)
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
