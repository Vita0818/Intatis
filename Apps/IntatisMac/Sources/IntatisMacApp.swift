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

    func deleteChatSession(_ session: SessionID) throws {
        if session == chatSessionID {
            guard !viewModel.isBusy else {
                throw IntatisError.io("Wait for the current Chat response to finish before deleting this session.")
            }
            let replacement = recentChatSessions()
                .first(where: { $0.id != session })?.id
                ?? SessionID.new()
            try switchChatSession(to: replacement)
        }
        try SessionHistoryStore.deleteSession(
            root: AppConfig.appSupportDir(),
            session: session)
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

    func selectProviderModel(providerID: String, modelID: String, variantID: String?) {
        let catalog = AppConfig.selectProviderModel(
            providerID: providerID,
            modelID: modelID,
            variantID: variantID)
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
            ? "Unknown date"
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let workspace = workspacePath(session.id).map { " · \($0)" } ?? ""
        return "\(session.eventCount) events · \(timestamp)\(workspace)"
    }
}

struct CodeSessionView: View {
    @ObservedObject var vm: CodeViewModel
    let catalog: AppProviderCatalog
    let onSelectModel: (String, String, String?) -> Void
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
    let onSelectModel: (String, String, String?) -> Void
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    let onSessionDidBecomeReady: () -> Void
    @State private var showProjectSettings = false
    @State private var showGoalEditor = false
    @State private var showGoalClearConfirmation = false
    @State private var goalObjectiveDraft = ""
    @State private var goalSuccessCriteriaDraft = ""
    @State private var goalConstraintsDraft = ""
    @State private var goalTokenBudgetDraft = ""
    @State private var goalEditorSubmissionError: String?
    @Environment(\.colorScheme) private var scheme

    private var hasMainAgent: Bool {
        vm.agents.contains { $0.name == vm.project.mainAgentName }
    }

    private var isCoworkBusy: Bool {
        vm.isWorking || vm.isGoalContinuing
    }

    var body: some View {
        VStack(spacing: 0) {
            permissionReviewerBanner
            CoworkShell(items: vm.items,
                        agents: vm.agents,
                        pending: vm.pendingPermission,
                        permissionNotice: vm.permissionNotice,
                        latestTurnStats: vm.latestTurnStats,
                        summary: vm.summary,
                        project: vm.project,
                        goal: vm.goal,
                        workTasks: vm.workTasks,
                        composerError: vm.composerError ?? vm.projectionError,
                        isWorking: isCoworkBusy,
                        isComposerAvailable: vm.isAutomaticPermissionReviewReady
                            && vm.isGoalRuntimeReady,
                        threadStyle: .intatisMac(scheme),
                        onShowSessions: onShowSessions,
                        onNewSession: onNewSession,
                        onShowProjectSettings: { showProjectSettings = true },
                        composerAccessory: AnyView(IntatisComposerAccessory(
                            catalog: catalog,
                            isBusy: isCoworkBusy,
                            latestTurnStats: vm.latestTurnStats,
                            contextLabel: contextLabel,
                            onSelectModel: onSelectModel)),
                        input: $vm.input,
                        onSend: { vm.send() },
                        onCancelCurrent: vm.isWorking ? { vm.cancelCurrentTask() } : nil,
                        onResolve: { vm.resolvePermission($0) },
                        onRemoveAgent: { vm.removeAgent(name: $0) },
                        onRetryTask: { vm.retryFailedTask(id: $0) },
                        onPauseGoal: { vm.pauseGoal() },
                        onResumeGoal: { vm.resumeGoal() },
                        onEditGoal: { presentGoalEditor() },
                        onClearGoal: { showGoalClearConfirmation = true })
        }
        // SwiftUI preserves this view's structural identity when one Cowork
        // session replaces another. Key startup to the durable session ID so
        // the new view model cannot inherit the completed task of the old one.
        .task(id: vm.sessionID.rawValue) { vm.start() }
        .onChange(of: hasMainAgent) { isReady in
            guard isReady else { return }
            // The first @main projection also means events.jsonl now exists,
            // so a history rescan can expose the new session in the sidebar.
            onSessionDidBecomeReady()
        }
        .sheet(isPresented: $showProjectSettings) { projectSettingsSheet }
        .sheet(isPresented: $showGoalEditor) { goalEditorSheet }
        .alert("Clear this Goal?", isPresented: $showGoalClearConfirmation) {
            Button("Clear", role: .destructive) { vm.clearGoal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Goal card will be cleared without marking the Goal completed. Its durable history remains in the session log.")
        }
    }

    private var permissionReviewerBanner: some View {
        let presentation = permissionReviewerPresentation
        return HStack(spacing: 9) {
            if presentation.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Starting permission reviewer")
            } else {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(presentation.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(presentation.title)
                .font(.caption.bold())
                .foregroundStyle(presentation.tint)
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if vm.permissionReviewerStatus.canRetry {
                Button("Retry") { vm.retryAutomaticPermissionReview() }
                    .buttonStyle(.borderless)
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .help("\(presentation.title): \(presentation.detail)")
    }

    private var permissionReviewerPresentation: (
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        isBusy: Bool
    ) {
        switch vm.permissionReviewerStatus {
        case .disabled:
            return (
                "Permission reviewer disabled",
                "Cowork input stays unavailable until automatic review is active.",
                "shield.slash",
                .secondary,
                false)
        case .enabling:
            return (
                "Starting permission reviewer…",
                "Automatic review is not active until startup succeeds.",
                "shield",
                .secondary,
                true)
        case .enabled(let reviewer):
            return (
                "@\(reviewer.rawValue) enabled",
                "Eligible requests are reviewed automatically; hard policy denials remain final.",
                "checkmark.shield.fill",
                .green,
                false)
        case .fallback(let reason):
            return (
                "Permission reviewer unavailable",
                reason,
                "person.crop.circle.badge.questionmark",
                .orange,
                false)
        case .degraded(let reason):
            return (
                "Permission reviewer degraded",
                reason,
                "exclamationmark.shield.fill",
                .orange,
                false)
        case .failed(let reason):
            return (
                "Permission reviewer failed",
                "\(reason) Cowork input is locked until automatic review starts.",
                "exclamationmark.shield.fill",
                .red,
                false)
        }
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

    private var goalEditorValidationMessage: String? {
        if let goalEditorSubmissionError { return goalEditorSubmissionError }
        if goalObjectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A Goal objective is required."
        }
        let budget = goalTokenBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty, Int(budget).map({ $0 > 0 }) != true {
            return "Token budget must be a positive whole number, or left empty for no budget."
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
            onAddWorkspace: {
                if let url = WorkspaceAccess.choose(prompt: "Choose Project Workspace") {
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

@main
struct IntatisMacApp: App {
    private var launchAppearance: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-IntatisAppearanceDark") { return .dark }
        if arguments.contains("-IntatisAppearanceLight") { return .light }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
                RendererFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else {
                IntatisProductionRootView(launchAppearance: launchAppearance)
            }
            #else
            IntatisProductionRootView(launchAppearance: launchAppearance)
            #endif
        }
        .defaultSize(width: 1100, height: 760)
    }
}

private struct IntatisProductionRootView: View {
    @StateObject private var env = AppEnvironment()
    let launchAppearance: ColorScheme?

    var body: some View {
        IntatisMacRootView()
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
