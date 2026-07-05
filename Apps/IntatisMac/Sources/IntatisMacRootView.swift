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
    @State private var codeSessionError: String?
    @State private var coworkSessionError: String?

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
                onSelectSession: resumeSelectedSession)
                .navigationSplitViewColumnWidth(
                    min: IntatisSplitColumnLayout.chatInspector.sidebarMin,
                    ideal: 236)
        } detail: {
            ZStack {
                IntatisTheme.pageGradient(scheme).ignoresSafeArea()
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
                onSelectModel: env.selectProviderModel(providerID:modelID:),
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
                onSelectModel: env.selectProviderModel(providerID:modelID:),
                onShowSessions: showCoworkSessions,
                onNewSession: startNewCoworkSession)
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
            title: session.id.rawValue,
            detail: sessionDetail(session),
            systemImage: icon,
            isSelected: selected)
    }

    private func sessionDetail(_ session: AppSessionSummary) -> String {
        let timestamp = session.updatedAt == .distantPast
            ? "Unknown date"
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let count = session.eventCount == 1 ? "1 event" : "\(session.eventCount) events"
        let workspace = selection == .code ? WorkspaceAccess.workspacePath(for: session.id).map { " · \($0)" } ?? "" : ""
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
        selection = .cowork
        isSettings = false
        coworkVM?.stop()
        do {
            coworkVM = try env.makeCoworkViewModel()
            coworkSessionError = nil
            refreshCoworkSessions()
        } catch {
            coworkSessionError = "Could not start Cowork session: \(error.localizedDescription)"
        }
    }

    private func showCoworkSessions() {
        coworkVM?.stop()
        coworkVM = nil
        refreshCoworkSessions()
    }

    private func resumeCoworkSession(_ sessionID: SessionID) {
        selection = .cowork
        isSettings = false
        coworkVM?.stop()
        do {
            coworkVM = try env.makeCoworkViewModel(session: sessionID)
            coworkSessionError = nil
            refreshCoworkSessions()
        } catch {
            coworkSessionError = "Could not resume Cowork session: \(error.localizedDescription)"
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
                onSelect: onSelectSession)
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
        .background {
            Rectangle()
                .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.18 : 0.32))
                .background(.thinMaterial)
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
                .foregroundStyle(selected ? IntatisTheme.goldDeep : IntatisTheme.softText(scheme))
                .frame(width: 20)
            Text("Settings")
                .font(IntatisType.body(13, selected ? .semibold : .medium))
                .foregroundStyle(selected ? IntatisTheme.deepText(scheme) : IntatisTheme.softText(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.22 : 0.36)
                               : IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.16 : 0.30))
                .opacity(selected || hover ? 1 : 0.85)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(IntatisTheme.gold.opacity(scheme == .dark ? 0.34 : 0.42), lineWidth: 1)
                .opacity(selected ? 1 : (hover ? 0.4 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
    }
}
#endif
