#if canImport(SwiftUI)
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

public struct CoworkAgentInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let workspace: String
    public let model: String
    public let profile: String
    public let status: String
    public let pendingTasks: Int
    public let pendingMessages: Int
    public let completedTasks: Int
    public let workspaceLease: String?
    public let capabilityLease: String?

    public init(id: String,
                name: String,
                workspace: String,
                model: String,
                profile: String,
                status: String = "idle",
                pendingTasks: Int = 0,
                pendingMessages: Int = 0,
                completedTasks: Int = 0,
                workspaceLease: String? = nil,
                capabilityLease: String? = nil) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.model = model
        self.profile = profile
        self.status = status
        self.pendingTasks = pendingTasks
        self.pendingMessages = pendingMessages
        self.completedTasks = completedTasks
        self.workspaceLease = workspaceLease
        self.capabilityLease = capabilityLease
    }
}

public struct CoworkTaskLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let status: String

    public init(id: String, title: String, detail: String, status: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct CoworkStatusSummary: Equatable, Sendable {
    public let activeCount: Int
    public let runningCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let pendingMailboxCount: Int
    public let completedMailboxCount: Int
    public let workspaceLeaseCount: Int
    public let capabilityLeaseCount: Int
    public let runningTasks: [CoworkTaskLine]
    public let failedTasks: [CoworkTaskLine]
    public let recentCompletedTasks: [CoworkTaskLine]

    public init(activeCount: Int = 0,
                runningCount: Int = 0,
                completedCount: Int = 0,
                failedCount: Int = 0,
                pendingMailboxCount: Int = 0,
                completedMailboxCount: Int = 0,
                workspaceLeaseCount: Int = 0,
                capabilityLeaseCount: Int = 0,
                runningTasks: [CoworkTaskLine] = [],
                failedTasks: [CoworkTaskLine] = [],
                recentCompletedTasks: [CoworkTaskLine] = []) {
        self.activeCount = activeCount
        self.runningCount = runningCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.pendingMailboxCount = pendingMailboxCount
        self.completedMailboxCount = completedMailboxCount
        self.workspaceLeaseCount = workspaceLeaseCount
        self.capabilityLeaseCount = capabilityLeaseCount
        self.runningTasks = runningTasks
        self.failedTasks = failedTasks
        self.recentCompletedTasks = recentCompletedTasks
    }
}

/// Presentational Cowork thread (v0.3): agent roster + add button on the left,
/// the merged multi-agent thread in the middle (reuses `CodeItemRow`, including
/// the `agentToAgent` card), per-agent details on the right. `@mention` parsing
/// happens in the view model; the composer just hints at it.
public struct CoworkShell: View {
    private let items: [CodeItem]
    private let agents: [CoworkAgentInfo]
    private let pending: PendingPermission?
    private let permissionNotice: PermissionResolutionNotice?
    private let latestTurnStats: TurnStatsSnapshot?
    private let summary: CoworkStatusSummary
    private let composerError: String?
    private let isWorking: Bool
    private let threadStyle: IntatisThreadStyle
    private let onShowSessions: (() -> Void)?
    private let onNewSession: (() -> Void)?
    private let composerAccessory: AnyView?
    @Binding private var input: String
    private let onSend: () -> Void
    private let onResolve: (PermissionDecision) -> Void
    private let onAddAgent: () -> Void
    private let onRetryTask: ((String) -> Void)?
    @State private var selectedAgentID: String?

    public init(items: [CodeItem],
                agents: [CoworkAgentInfo],
                pending: PendingPermission?,
                permissionNotice: PermissionResolutionNotice? = nil,
                latestTurnStats: TurnStatsSnapshot? = nil,
                summary: CoworkStatusSummary,
                composerError: String?,
                isWorking: Bool,
                threadStyle: IntatisThreadStyle = .standard(.light),
                splitLayout: IntatisSplitColumnLayout = .workspace,
                onShowSessions: (() -> Void)? = nil,
                onNewSession: (() -> Void)? = nil,
                composerAccessory: AnyView? = nil,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void,
                onAddAgent: @escaping () -> Void,
                onRetryTask: ((String) -> Void)? = nil) {
        self.items = items
        self.agents = agents
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.latestTurnStats = latestTurnStats
        self.summary = summary
        self.composerError = composerError
        self.isWorking = isWorking
        self.threadStyle = threadStyle
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.composerAccessory = composerAccessory
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
        self.onAddAgent = onAddAgent
        self.onRetryTask = onRetryTask
        _ = splitLayout
    }

    private var permissionBlocksComposer: Bool {
        guard let pending else { return false }
        return pending.state == .livePending || pending.state == .resolving
    }

    public var body: some View {
        GeometryReader { proxy in
            content(rawWidth: proxy.size.width)
        }
        .onAppear { selectedAgentID = selectedAgentID ?? agents.first?.id }
        .onChange(of: agents) { newAgents in
            if let selectedAgentID,
               newAgents.contains(where: { $0.id == selectedAgentID }) {
                return
            }
            selectedAgentID = newAgents.first?.id
        }
    }

    private var selectedAgent: CoworkAgentInfo? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    @ViewBuilder private func content(rawWidth: CGFloat) -> some View {
        if rawWidth >= 980 {
            HStack(spacing: 0) {
                threadColumn(
                    layout: IntatisThreadContentLayout(rawWidth: rawWidth - 320),
                    showsCompactActions: false)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.45)
                inspectorColumn
                    .frame(width: 318)
                    .frame(maxHeight: .infinity)
            }
        } else {
            threadColumn(
                layout: IntatisThreadContentLayout(rawWidth: rawWidth),
                showsCompactActions: true)
        }
    }

    private func threadColumn(layout: IntatisThreadContentLayout,
                              showsCompactActions: Bool) -> some View {
        VStack(spacing: 0) {
            header(layout: layout, showsCompactActions: showsCompactActions)
            thread(layout: layout)
            permissionArea(layout: layout)
            composerArea(layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(layout: IntatisThreadContentLayout, showsCompactActions: Bool) -> some View {
        IntatisWorkspaceThreadHeader(
            title: "Cowork",
            subtitle: "\(agents.count) agents · \(summary.runningCount) running",
            style: threadStyle,
            actions: headerActions(showsCompactActions: showsCompactActions))
        .frame(maxWidth: layout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    private func headerActions(showsCompactActions: Bool) -> [IntatisThreadHeaderAction] {
        var actions: [IntatisThreadHeaderAction] = []
        if showsCompactActions {
            actions.append(IntatisThreadHeaderAction(title: "Add Agent", systemImage: "person.badge.plus", action: onAddAgent))
        }
        return actions
    }

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorHeader
                inspectorSection("Agents") {
                    HStack(spacing: 8) {
                        metric("Active", summary.activeCount)
                        metric("Running", summary.runningCount)
                    }
                    HStack(spacing: 8) {
                        metric("Failed", summary.failedCount)
                        metric("Mailbox", summary.pendingMailboxCount)
                    }
                    Button(action: onAddAgent) {
                        Label("Add Agent", systemImage: "person.badge.plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                    agentRosterList
                }
                inspectorSection("Plan") {
                    taskList
                }
                inspectorSection("Workspace") {
                    inspectorRow("Workspace leases", value: "\(summary.workspaceLeaseCount)")
                    inspectorRow("Capability leases", value: "\(summary.capabilityLeaseCount)")
                    inspectorRow("Git", value: "status only")
                    Text("Commit, branch, PR, CI, and review workflows are deferred.")
                        .font(.caption2)
                        .foregroundStyle(threadStyle.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let latestTurnStats {
                    inspectorSection("Last Turn") {
                        IntatisTurnStatsSummaryView(stats: latestTurnStats, style: threadStyle)
                    }
                }
            }
            .padding(16)
        }
        .background(threadStyle.cardSurface.opacity(0.38))
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inspector")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
            Text("Agents, tasks, and workspace status")
                .font(.caption)
                .foregroundStyle(threadStyle.secondaryText)
        }
    }

    @ViewBuilder private var agentRosterList: some View {
        if agents.isEmpty {
            Text("No agents attached")
                .font(.caption)
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            ForEach(agents) { agent in
                agentPill(agent)
            }
            if let agent = selectedAgent {
                selectedAgentCard(agent)
            }
        }
    }

    @ViewBuilder private var taskList: some View {
        let allTasks = summary.runningTasks + summary.failedTasks + summary.recentCompletedTasks
        if allTasks.isEmpty {
            Text("No structured task events in the current projection.")
                .font(.caption)
                .foregroundStyle(threadStyle.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(summary.runningTasks) { task in CoworkTaskLineRow(task: task, style: threadStyle) }
            ForEach(summary.failedTasks) { task in
                CoworkTaskLineRow(
                    task: task,
                    style: threadStyle,
                    actionTitle: onRetryTask == nil ? nil : "Retry",
                    actionDisabled: isWorking,
                    action: onRetryTask.map { retry in { retry(task.id) } })
            }
            ForEach(summary.recentCompletedTasks) { task in CoworkTaskLineRow(task: task, style: threadStyle) }
        }
    }

    private func inspectorSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(threadStyle.tertiaryText)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(threadStyle.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(threadStyle.cardStroke, lineWidth: 1)
        }
    }

    private func inspectorRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(threadStyle.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(threadStyle.primaryText)
        }
    }

    private func statusStrip(layout: IntatisThreadContentLayout) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                metric("Active", summary.activeCount)
                metric("Running", summary.runningCount)
                metric("Failed", summary.failedCount)
                metric("Mailbox", summary.pendingMailboxCount)
                metric("Leases", summary.workspaceLeaseCount + summary.capabilityLeaseCount)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], alignment: .leading, spacing: 8) {
                metric("Active", summary.activeCount)
                metric("Running", summary.runningCount)
                metric("Failed", summary.failedCount)
                metric("Mailbox", summary.pendingMailboxCount)
                metric("Leases", summary.workspaceLeaseCount + summary.capabilityLeaseCount)
            }
        }
        .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, 10)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(threadStyle.tertiaryText)
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minWidth: 96, alignment: .leading)
        .background(threadStyle.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(threadStyle.cardStroke, lineWidth: 1)
        }
    }

    private func agentRoster(layout: IntatisThreadContentLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if agents.isEmpty {
                        Text("No agents attached")
                            .font(.caption)
                            .foregroundStyle(threadStyle.secondaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(threadStyle.cardSurface, in: Capsule())
                    }
                    ForEach(agents) { agent in
                        agentPill(agent)
                    }
                    Button(action: onAddAgent) {
                        Label("Add", systemImage: "plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            if let agent = selectedAgent {
                selectedAgentCard(agent)
            }
        }
        .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, 10)
    }

    private func agentPill(_ agent: CoworkAgentInfo) -> some View {
        let selected = selectedAgentID == agent.id
        return Button {
            selectedAgentID = agent.id
        } label: {
            HStack(spacing: 7) {
                Text("@\(agent.name)")
                    .font(.caption.bold())
                    .foregroundStyle(selected ? threadStyle.accent : threadStyle.primaryText)
                Text(agent.status)
                    .font(.caption2)
                    .foregroundStyle(threadStyle.secondaryText)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(threadStyle.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? threadStyle.accentSoft : threadStyle.cardSurface, in: Capsule())
            .overlay { Capsule().stroke(selected ? threadStyle.accent : threadStyle.cardStroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func selectedAgentCard(_ agent: CoworkAgentInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("@\(agent.name)")
                    .font(.caption.bold())
                    .foregroundStyle(threadStyle.primaryText)
                Spacer(minLength: 8)
                Text(agent.status)
                    .font(.caption2.bold())
                    .foregroundStyle(threadStyle.accent)
            }
            Text(agent.workspace)
                .font(.caption2)
                .foregroundStyle(threadStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(agent.model)
                    Text(agent.profile)
                    Text("\(agent.pendingMessages + agent.pendingTasks) pending")
                    Text("\(agent.completedTasks) completed")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.model)
                    Text(agent.profile)
                    Text("\(agent.pendingMessages + agent.pendingTasks) pending · \(agent.completedTasks) completed")
                }
            }
            .font(.caption2)
            .foregroundStyle(threadStyle.tertiaryText)
        }
        .padding(11)
        .background(threadStyle.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(threadStyle.cardStroke, lineWidth: 1)
        }
    }

    @ViewBuilder private func taskHighlights(layout: IntatisThreadContentLayout) -> some View {
        if !summary.runningTasks.isEmpty || !summary.failedTasks.isEmpty || !summary.recentCompletedTasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.runningTasks) { task in CoworkTaskLineRow(task: task, style: threadStyle) }
                ForEach(summary.failedTasks) { task in
                    CoworkTaskLineRow(
                        task: task,
                        style: threadStyle,
                        actionTitle: onRetryTask == nil ? nil : "Retry",
                        actionDisabled: isWorking,
                        action: onRetryTask.map { retry in { retry(task.id) } })
                }
                ForEach(summary.recentCompletedTasks) { task in CoworkTaskLineRow(task: task, style: threadStyle) }
            }
            .frame(maxWidth: layout.contentMaxWidth)
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private func thread(layout: IntatisThreadContentLayout) -> some View {
        if items.isEmpty {
            CoworkEmptyThreadView(style: threadStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, layout.horizontalPadding)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            CodeItemRow(item: item, style: threadStyle, layout: layout)
                                .id(item.id)
                        }
                    }
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.vertical, 16)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: items.count) { _ in
                    if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    @ViewBuilder private func permissionArea(layout: IntatisThreadContentLayout) -> some View {
        if let pending {
            PermissionCard(permission: pending, onResolve: onResolve)
                .frame(maxWidth: layout.contentMaxWidth)
                .padding(.horizontal, layout.horizontalPadding)
        } else if let permissionNotice {
            PermissionResolutionNoticeView(notice: permissionNotice)
                .frame(maxWidth: layout.contentMaxWidth)
                .padding(.horizontal, layout.horizontalPadding)
        }
    }

    private func composerArea(layout: IntatisThreadContentLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let composerError {
                Text(composerError)
                    .font(.caption)
                    .foregroundStyle(threadStyle.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            IntatisThreadComposer(
                placeholder: "Message agents...",
                input: $input,
                canSend: !isWorking
                    && !permissionBlocksComposer
                    && !agents.isEmpty
                    && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isInputDisabled: isWorking || permissionBlocksComposer || agents.isEmpty,
                style: threadStyle,
                accessory: {
                    if let composerAccessory {
                        composerAccessory
                    } else if let latestTurnStats {
                        IntatisTurnStatsSummaryView(stats: latestTurnStats, style: threadStyle)
                    }
                },
                onSend: onSend)
        }
        .frame(maxWidth: layout.contentMaxWidth)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }
}

private struct CoworkTaskLineRow: View {
    let task: CoworkTaskLine
    let style: IntatisThreadStyle
    let actionTitle: String?
    let actionDisabled: Bool
    let action: (() -> Void)?

    init(task: CoworkTaskLine,
         style: IntatisThreadStyle = .standard(.light),
         actionTitle: String? = nil,
         actionDisabled: Bool = false,
         action: (() -> Void)? = nil) {
        self.task = task
        self.style = style
        self.actionTitle = actionTitle
        self.actionDisabled = actionDisabled
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title)
                    .font(.caption.bold())
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderless)
                        .disabled(actionDisabled)
                }
                Text(task.status).font(.caption).foregroundStyle(style.secondaryText)
            }
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(style.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(style.cardStroke, lineWidth: 1)
        }
    }
}

private struct CoworkEmptyThreadView: View {
    let style: IntatisThreadStyle

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(style.accent)
                .frame(width: 76, height: 76)
                .background(style.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer()
        }
        .multilineTextAlignment(.center)
    }
}
#endif
