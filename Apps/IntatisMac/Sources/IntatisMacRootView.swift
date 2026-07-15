//
//  IntatisMacRootView.swift
//  IntatisMac
//
//  macOS workbench shell: mode + session history live in the sidebar, the center
//  stays focused on the thread, and Code/Cowork reserve the right side for status.
//

#if canImport(SwiftUI)
import SwiftUI
import IntatisCore
import IntatisSharedUI

enum IntatisNavItem: String, CaseIterable, Identifiable, Hashable {
    case chat, code, cowork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .code: return "Code"
        case .cowork: return "Cowork"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "person.2"
        }
    }

    var sessionKind: SessionKind {
        switch self {
        case .chat: return .chat
        case .code: return .code
        case .cowork: return .cowork
        }
    }

    var newSessionTitle: String {
        switch self {
        case .chat: return "New chat"
        case .code: return "New code session"
        case .cowork: return "New cowork session"
        }
    }

    var emptyHistoryTitle: String {
        switch self {
        case .chat: return "No chat sessions yet."
        case .code: return "No code sessions yet."
        case .cowork: return "No cowork sessions yet."
        }
    }
}

private struct SessionActionTarget: Identifiable {
    let sessionID: SessionID
    let kind: SessionKind
    let title: String

    var id: String { "\(kind.rawValue):\(sessionID.rawValue)" }
}

struct IntatisMacRootView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @State private var selection: IntatisNavItem = .chat
    @State private var isSettings = false
    @State private var didInit = false
    @State private var recentChatSessions: [AppSessionSummary] = []
    @State private var recentCodeSessions: [AppSessionSummary] = []
    @State private var recentCoworkSessions: [AppSessionSummary] = []
    @State private var codeVM: CodeViewModel?
    @State private var coworkVM: CoworkViewModel?
    @State private var coworkTransitionID: UUID?
    @State private var codeSessionError: String?
    @State private var coworkSessionError: String?
    @State private var renameTarget: SessionActionTarget?
    @State private var deleteTarget: SessionActionTarget?
    @State private var sessionActionError: String?

    private var items: [IntatisNavItem] {
        IntatisNavItem.allCases.filter { item in
            switch item {
            case .chat: return true
            case .code: return PlatformProfile.current.supports(.code)
            case .cowork: return PlatformProfile.current.supports(.cowork)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            IntatisSidebar(
                items: items,
                selection: $selection,
                isSettings: $isSettings,
                historyItems: historyItems,
                historyTitle: "\(selection.title) Sessions",
                emptyHistoryTitle: selection.emptyHistoryTitle,
                newSessionTitle: selection.newSessionTitle,
                isNewDisabled: newSessionDisabled,
                onNewSession: startNewSelectedSession,
                onSelectSession: resumeSelectedSession,
                onRenameSession: beginRenameSession,
                onDeleteSession: beginDeleteSession)
                .navigationSplitViewColumnWidth(
                    min: IntatisSplitColumnLayout.chatInspector.sidebarMin,
                    ideal: 236)
        } detail: {
            ZStack {
                IntatisSystemCanvas().ignoresSafeArea()
                detail
            }
        }
        .navigationTitle("")
        .task {
            guard !didInit else { return }
            didInit = true
            refreshAllSessions()
            if env.needsAPIKey { isSettings = true }
        }
        .onChange(of: selection) { _ in refreshAllSessions() }
        .onChange(of: env.chatSessionID.rawValue) { _ in refreshChatSessions() }
        .onReceive(env.$registry) { registry in
            codeVM?.updateProviderRegistry(registry)
            coworkVM?.updateProviderRegistry(registry)
        }
        .sheet(item: $renameTarget) { target in
            SessionRenameSheet(initialName: target.title) { newName in
                try renameSession(target, to: newName)
            }
        }
        .alert("Delete Session?", isPresented: deleteAlertPresented, presenting: deleteTarget) { target in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSession(target)
            }
        } message: { target in
            Text("\"\(target.title)\" and its Intatis event history and artifacts will be permanently deleted. Files in the linked workspace will not be changed.")
        }
        .alert("Session Action Failed", isPresented: sessionErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionActionError ?? "The session action failed.")
        }
    }

    @ViewBuilder private var detail: some View {
        if isSettings {
            IntatisSettingsPanel()
        } else {
            switch selection {
            case .chat:
                IntatisChatScreen(env: env)
            case .code:
                codeDetail
            case .cowork:
                coworkDetail
            }
        }
    }

    @ViewBuilder private var codeDetail: some View {
        if let vm = codeVM {
            CodeSessionView(
                vm: vm,
                catalog: env.providerCatalog,
                onSelectModel: env.selectProviderModel(providerID:modelID:variantID:),
                onShowSessions: showCodeSessions,
                onNewSession: startNewCodeSession)
        } else {
            WorkspaceSessionHome(
                title: "Code",
                subtitle: "Local workspace agent session",
                icon: "folder.badge.plus",
                primaryTitle: "Choose Workspace",
                primarySystemImage: "folder",
                primaryShortcut: "o",
                error: codeSessionError,
                sessionsTitle: "Recent Code Sessions",
                sessions: [],
                workspacePath: { WorkspaceAccess.workspacePath(for: $0) },
                onPrimary: startNewCodeSession,
                onResume: { resumeCodeSession($0.id) })
        }
    }

    @ViewBuilder private var coworkDetail: some View {
        if let vm = coworkVM {
            CoworkSessionView(
                vm: vm,
                catalog: env.providerCatalog,
                onSelectModel: env.selectProviderModel(providerID:modelID:variantID:),
                onShowSessions: showCoworkSessions,
                onNewSession: startNewCoworkSession,
                onSessionDidBecomeReady: refreshCoworkSessions)
        } else {
            WorkspaceSessionHome(
                title: "Cowork",
                subtitle: "Multi-agent workspace session",
                icon: "person.2",
                primaryTitle: "New Cowork Session",
                primarySystemImage: "plus",
                primaryShortcut: "n",
                error: coworkSessionError,
                sessionsTitle: "Recent Cowork Sessions",
                sessions: [],
                workspacePath: { _ in String?.none },
                onPrimary: startNewCoworkSession,
                onResume: { resumeCoworkSession($0.id) })
        }
    }

    private var historyItems: [IntatisSessionHistoryItem] {
        switch selection {
        case .chat:
            return recentChatSessions.map {
                historyItem($0, icon: selection.icon, selected: $0.id == env.chatSessionID)
            }
        case .code:
            return recentCodeSessions.map {
                historyItem($0, icon: selection.icon, selected: $0.id == codeVM?.sessionID)
            }
        case .cowork:
            return recentCoworkSessions.map {
                historyItem($0, icon: selection.icon, selected: $0.id == coworkVM?.sessionID)
            }
        }
    }

    private var newSessionDisabled: Bool {
        switch selection {
        case .chat:
            return env.viewModel.isBusy
        case .code:
            return codeVM?.isWorking == true
        case .cowork:
            return coworkVM?.isWorking == true
        }
    }

    private func historyItem(_ session: AppSessionSummary,
                             icon: String,
                             selected: Bool) -> IntatisSessionHistoryItem {
        IntatisSessionHistoryItem(
            id: session.id,
            title: session.displayName ?? session.id.rawValue,
            detail: sessionDetail(session),
            systemImage: icon,
            isSelected: selected,
            isDeleteDisabled: isDeleteDisabled(session))
    }

    private func isDeleteDisabled(_ session: AppSessionSummary) -> Bool {
        switch session.kind {
        case .chat:
            return session.id == env.chatSessionID && env.viewModel.isBusy
        case .code:
            return session.id == codeVM?.sessionID && codeVM?.isWorking == true
        case .cowork:
            return session.id == coworkVM?.sessionID && coworkVM?.isWorking == true
        }
    }

    private func sessionDetail(_ session: AppSessionSummary) -> String {
        let timestamp = session.updatedAt == .distantPast
            ? "Unknown date"
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let count = session.eventCount == 1 ? "1 event" : "\(session.eventCount) events"
        let workspace: String
        switch selection {
        case .code:
            workspace = WorkspaceAccess.workspacePath(for: session.id).map { " · \($0)" } ?? ""
        case .cowork:
            workspace = CoworkProjectSettingsStore.primaryWorkspacePath(sessionID: session.id).map { " · \($0)" } ?? ""
        case .chat:
            workspace = ""
        }
        return "\(count) · \(timestamp)\(workspace)"
    }

    private func refreshAllSessions() {
        refreshChatSessions()
        refreshCodeSessions()
        refreshCoworkSessions()
    }

    private func refreshChatSessions() {
        recentChatSessions = env.recentChatSessions()
    }

    private func refreshCodeSessions() {
        recentCodeSessions = env.recentCodeSessions()
    }

    private func refreshCoworkSessions() {
        recentCoworkSessions = env.recentCoworkSessions()
    }

    private func startNewSelectedSession() {
        isSettings = false
        switch selection {
        case .chat:
            env.startNewChatSession()
            refreshChatSessions()
        case .code:
            startNewCodeSession()
        case .cowork:
            startNewCoworkSession()
        }
    }

    private func resumeSelectedSession(_ sessionID: SessionID) {
        isSettings = false
        switch selection {
        case .chat:
            guard let session = recentChatSessions.first(where: { $0.id == sessionID }) else { return }
            env.resumeChatSession(session)
            refreshChatSessions()
        case .code:
            resumeCodeSession(sessionID)
        case .cowork:
            resumeCoworkSession(sessionID)
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } })
    }

    private var sessionErrorPresented: Binding<Bool> {
        Binding(
            get: { sessionActionError != nil },
            set: { if !$0 { sessionActionError = nil } })
    }

    private func beginRenameSession(_ sessionID: SessionID) {
        guard let session = sessions(for: selection.sessionKind)
            .first(where: { $0.id == sessionID }) else { return }
        renameTarget = SessionActionTarget(
            sessionID: session.id,
            kind: session.kind,
            title: session.displayName ?? session.id.rawValue)
    }

    private func beginDeleteSession(_ sessionID: SessionID) {
        guard let session = sessions(for: selection.sessionKind)
            .first(where: { $0.id == sessionID }) else { return }
        deleteTarget = SessionActionTarget(
            sessionID: session.id,
            kind: session.kind,
            title: session.displayName ?? session.id.rawValue)
    }

    private func sessions(for kind: SessionKind) -> [AppSessionSummary] {
        switch kind {
        case .chat: return recentChatSessions
        case .code: return recentCodeSessions
        case .cowork: return recentCoworkSessions
        }
    }

    private func renameSession(_ target: SessionActionTarget, to newName: String) throws {
        try SessionHistoryStore.setDisplayName(
            newName,
            root: AppConfig.appSupportDir(),
            session: target.sessionID)
        refreshAllSessions()
    }

    private func deleteSession(_ target: SessionActionTarget) {
        Task { @MainActor in
            do {
                switch target.kind {
                case .chat:
                    try env.deleteChatSession(target.sessionID)
                case .code:
                    if let active = codeVM, active.sessionID == target.sessionID {
                        guard !active.isWorking else {
                            throw IntatisError.io("Wait for the current Code task to finish before deleting this session.")
                        }
                        active.stop()
                        codeVM = nil
                    }
                    try SessionHistoryStore.deleteSession(
                        root: AppConfig.appSupportDir(),
                        session: target.sessionID)
                    WorkspaceAccess.forget(session: target.sessionID)
                case .cowork:
                    if let active = coworkVM, active.sessionID == target.sessionID {
                        guard !active.isWorking else {
                            throw IntatisError.io("Wait for the current Cowork task to finish before deleting this session.")
                        }
                        let transitionID = UUID()
                        coworkTransitionID = transitionID
                        await active.stop()
                        guard coworkTransitionID == transitionID else { return }
                        coworkVM = nil
                    }
                    try SessionHistoryStore.deleteSession(
                        root: AppConfig.appSupportDir(),
                        session: target.sessionID)
                    CoworkProjectSettingsStore.remove(sessionID: target.sessionID)
                    WorkspaceAccess.forget(session: target.sessionID)
                }
                refreshAllSessions()
            } catch {
                sessionActionError = error.localizedDescription
            }
        }
    }

    private func startNewCodeSession() {
        guard let url = WorkspaceAccess.choose() else { return }
        selection = .code
        isSettings = false
        codeVM?.stop()
        do {
            codeVM = try env.makeCodeViewModel(workspace: url)
            codeSessionError = nil
            refreshCodeSessions()
        } catch {
            codeSessionError = "Could not start Code session: \(error.localizedDescription)"
        }
    }

    private func showCodeSessions() {
        codeVM?.stop()
        codeVM = nil
        refreshCodeSessions()
    }

    private func resumeCodeSession(_ sessionID: SessionID) {
        guard let workspace = WorkspaceAccess.restoredWorkspace(for: sessionID) ?? WorkspaceAccess.choose() else {
            return
        }
        selection = .code
        isSettings = false
        codeVM?.stop()
        do {
            codeVM = try env.makeCodeViewModel(session: sessionID, workspace: workspace)
            codeSessionError = nil
            refreshCodeSessions()
        } catch {
            codeSessionError = "Could not resume Code session: \(error.localizedDescription)"
        }
    }

    private func startNewCoworkSession() {
        guard let workspace = WorkspaceAccess.choose(prompt: "Choose Cowork Workspace") else { return }
        selection = .cowork
        isSettings = false
        let transitionID = UUID()
        coworkTransitionID = transitionID
        let previous = coworkVM
        Task { @MainActor in
            await previous?.stop()
            guard coworkTransitionID == transitionID else { return }
            do {
                coworkVM = try env.makeCoworkViewModel(primaryWorkspace: workspace)
                coworkSessionError = nil
                refreshCoworkSessions()
            } catch {
                coworkSessionError = "Could not start Cowork session: \(error.localizedDescription)"
            }
        }
    }

    private func showCoworkSessions() {
        let transitionID = UUID()
        coworkTransitionID = transitionID
        let previous = coworkVM
        Task { @MainActor in
            await previous?.stop()
            guard coworkTransitionID == transitionID else { return }
            coworkVM = nil
            refreshCoworkSessions()
        }
    }

    private func resumeCoworkSession(_ sessionID: SessionID) {
        selection = .cowork
        isSettings = false
        let transitionID = UUID()
        coworkTransitionID = transitionID
        let previous = coworkVM
        Task { @MainActor in
            await previous?.stop()
            guard coworkTransitionID == transitionID else { return }
            do {
                coworkVM = try env.makeCoworkViewModel(session: sessionID)
                coworkSessionError = nil
                refreshCoworkSessions()
            } catch {
                coworkSessionError = "Could not resume Cowork session: \(error.localizedDescription)"
            }
        }
    }
}

private struct SessionRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorText: String?
    private let onRename: (String) throws -> Void

    init(initialName: String,
         onRename: @escaping (String) throws -> Void) {
        _name = State(initialValue: initialName)
        self.onRename = onRename
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 120
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.headline)
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func rename() {
        guard canRename else { return }
        do {
            try onRename(trimmedName)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Sidebar

struct IntatisSidebar: View {
    let items: [IntatisNavItem]
    @Binding var selection: IntatisNavItem
    @Binding var isSettings: Bool
    let historyItems: [IntatisSessionHistoryItem]
    let historyTitle: String
    let emptyHistoryTitle: String
    let newSessionTitle: String
    let isNewDisabled: Bool
    let onNewSession: () -> Void
    let onSelectSession: (SessionID) -> Void
    let onRenameSession: (SessionID) -> Void
    let onDeleteSession: (SessionID) -> Void
    @Environment(\.colorScheme) private var scheme

    private var modeTabs: [IntatisModeTab] {
        items.map { IntatisModeTab(id: $0.rawValue, title: $0.title, systemImage: $0.icon) }
    }

    private var selectionID: Binding<String> {
        Binding(
            get: { selection.rawValue },
            set: { raw in
                guard let item = IntatisNavItem(rawValue: raw) else { return }
                selection = item
                isSettings = false
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 12)

            IntatisModeSegmentedControl(
                tabs: modeTabs,
                selectionID: selectionID,
                style: .intatisMac(scheme))
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            Divider().opacity(0.45)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            IntatisSessionHistoryList(
                title: historyTitle,
                newTitle: newSessionTitle,
                emptyTitle: emptyHistoryTitle,
                items: historyItems,
                style: .intatisMac(scheme),
                isNewDisabled: isNewDisabled,
                onNew: onNewSession,
                onSelect: onSelectSession,
                onRename: onRenameSession,
                onDelete: onDeleteSession)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity, alignment: .top)

            Button { isSettings = true } label: {
                IntatisSidebarSettingsRow(selected: isSettings)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Intatis")
                .font(IntatisType.brand(28))
                .foregroundStyle(IntatisTheme.deepText(scheme))
            Text("Local AI workbench")
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IntatisSidebarSettingsRow: View {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? IntatisTheme.accent(scheme) : IntatisTheme.softText(scheme))
                .frame(width: 20)
            Text("Settings")
                .font(IntatisType.body(13, selected ? .semibold : .medium))
                .foregroundStyle(selected ? IntatisTheme.deepText(scheme) : IntatisTheme.softText(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? IntatisTheme.selectedStroke(scheme) : IntatisTheme.separator(scheme),
                        lineWidth: 1)
                .opacity(selected ? 1 : (hover ? 0.4 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
    }
}
#endif
