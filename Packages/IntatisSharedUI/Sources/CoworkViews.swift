#if canImport(SwiftUI)
import Foundation
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
    public let role: String
    public let pendingTasks: Int
    public let pendingMessages: Int
    public let completedTasks: Int
    public let workspaceLease: String?
    public let capabilityLease: String?
    public let canRemove: Bool

    public init(id: String,
                name: String,
                workspace: String,
                model: String,
                profile: String,
                status: String = "idle",
                role: String = "worker",
                pendingTasks: Int = 0,
                pendingMessages: Int = 0,
                completedTasks: Int = 0,
                workspaceLease: String? = nil,
                capabilityLease: String? = nil,
                canRemove: Bool = true) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.model = model
        self.profile = profile
        self.status = status
        self.role = role
        self.pendingTasks = pendingTasks
        self.pendingMessages = pendingMessages
        self.completedTasks = completedTasks
        self.workspaceLease = workspaceLease
        self.capabilityLease = capabilityLease
        self.canRemove = canRemove
    }

    public var statusLine: String {
        let queued = pendingTasks + pendingMessages
        if queued > 0 {
            return "\(status) · \(queued) queued"
        }
        if completedTasks > 0 {
            return "\(status) · \(completedTasks) completed"
        }
        return status
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

public struct CoworkWorkspaceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let displayName: String
    public let agentName: String?
    public let isPrimary: Bool
    public let access: String
    public let canRemove: Bool

    public init(path: String,
                displayName: String,
                agentName: String? = nil,
                isPrimary: Bool = false,
                access: String = "read_write",
                canRemove: Bool = true) {
        self.id = path
        self.path = path
        self.displayName = displayName
        self.agentName = agentName
        self.isPrimary = isPrimary
        self.access = access
        self.canRemove = canRemove
    }
}

private enum CoworkInspectorTab: String, CaseIterable, Identifiable {
    case agents
    case tasks
    case context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .tasks: return "Tasks"
        case .context: return "Context"
        }
    }
}

public struct CoworkProjectInfo: Equatable, Sendable {
    public let sessionID: String
    public let mainAgentName: String
    public let defaultModel: String
    public let defaultPermission: String
    public let tokenBudget: String?
    public let workspaces: [CoworkWorkspaceInfo]

    public init(sessionID: String = "",
                mainAgentName: String = "main",
                defaultModel: String = "current model",
                defaultPermission: String = "reviewed",
                tokenBudget: String? = nil,
                workspaces: [CoworkWorkspaceInfo] = []) {
        self.sessionID = sessionID
        self.mainAgentName = mainAgentName
        self.defaultModel = defaultModel
        self.defaultPermission = defaultPermission
        self.tokenBudget = tokenBudget
        self.workspaces = workspaces
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

/// Presentational Cowork project thread: the user gives work to Main, while
/// the roster/inspector exposes the sub-agent activity Main schedules.
public struct CoworkShell: View {
    private static let bottomAnchorID = "intatis-cowork-thread-bottom"
    private let items: [CodeItem]
    private let agents: [CoworkAgentInfo]
    private let pending: PendingPermission?
    private let permissionNotice: PermissionResolutionNotice?
    private let latestTurnStats: TurnStatsSnapshot?
    private let summary: CoworkStatusSummary
    private let project: CoworkProjectInfo
    private let composerError: String?
    private let isWorking: Bool
    private let threadStyle: IntatisThreadStyle
    private let onShowSessions: (() -> Void)?
    private let onNewSession: (() -> Void)?
    private let onShowProjectSettings: (() -> Void)?
    private let composerAccessory: AnyView?
    @Binding private var input: String
    private let onSend: () -> Void
    private let onResolve: (PermissionDecision) -> Void
    private let onAddAgent: (() -> Void)?
    private let onRemoveAgent: ((String) -> Void)?
    private let onRetryTask: ((String) -> Void)?
    @State private var selectedAgentID: String?
    @State private var inspectorTab: CoworkInspectorTab = .agents

    public init(items: [CodeItem],
                agents: [CoworkAgentInfo],
                pending: PendingPermission?,
                permissionNotice: PermissionResolutionNotice? = nil,
                latestTurnStats: TurnStatsSnapshot? = nil,
                summary: CoworkStatusSummary,
                project: CoworkProjectInfo = CoworkProjectInfo(),
                composerError: String?,
                isWorking: Bool,
                threadStyle: IntatisThreadStyle = .standard(.light),
                splitLayout: IntatisSplitColumnLayout = .workspace,
                onShowSessions: (() -> Void)? = nil,
                onNewSession: (() -> Void)? = nil,
                onShowProjectSettings: (() -> Void)? = nil,
                composerAccessory: AnyView? = nil,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void,
                onAddAgent: (() -> Void)? = nil,
                onRemoveAgent: ((String) -> Void)? = nil,
                onRetryTask: ((String) -> Void)? = nil) {
        self.items = items
        self.agents = agents
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.latestTurnStats = latestTurnStats
        self.summary = summary
        self.project = project
        self.composerError = composerError
        self.isWorking = isWorking
        self.threadStyle = threadStyle
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.onShowProjectSettings = onShowProjectSettings
        self.composerAccessory = composerAccessory
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
        self.onAddAgent = onAddAgent
        self.onRemoveAgent = onRemoveAgent
        self.onRetryTask = onRetryTask
        _ = splitLayout
    }

    private var permissionBlocksComposer: Bool {
        guard let pending else { return false }
        return pending.state == .livePending || pending.state == .resolving
    }

    private var selectedAgent: CoworkAgentInfo? {
        guard let selectedAgentID else { return agents.first }
        return agents.first { $0.id == selectedAgentID } ?? agents.first
    }

    public var body: some View {
        GeometryReader { proxy in
            content(rawWidth: proxy.size.width)
        }
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
            if let onShowProjectSettings {
                actions.append(IntatisThreadHeaderAction(
                    title: "Project",
                    systemImage: "slider.horizontal.3",
                    isDisabled: isWorking,
                    action: onShowProjectSettings))
            }
            if let onAddAgent {
                actions.append(IntatisThreadHeaderAction(title: "Attach", systemImage: "person.badge.plus", action: onAddAgent))
            }
        }
        return actions
    }

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                gitStatusSection
                agentStatusSection
                goalTableSection
            }
            .padding(16)
        }
        .background(threadStyle.cardSurface.opacity(0.38))
    }

    private var gitStatusSection: some View {
        rightRailSection("Git Status") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption.bold())
                        .foregroundStyle(threadStyle.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryWorkspaceName)
                            .font(.caption.bold())
                            .foregroundStyle(threadStyle.primaryText)
                            .lineLimit(1)
                        Text("status only")
                            .font(.caption2)
                            .foregroundStyle(threadStyle.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "circle")
                        .font(.caption2)
                        .foregroundStyle(threadStyle.tertiaryText)
                }
                Text(primaryWorkspacePath)
                    .font(.caption2)
                    .foregroundStyle(threadStyle.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Branch, commit, PR, CI, and review controls stay out of this rail.")
                    .font(.caption2)
                    .foregroundStyle(threadStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentStatusSection: some View {
        rightRailSection("Agents") {
            agentStatusList
        }
    }

    @ViewBuilder private var agentStatusList: some View {
        if visibleAgents.isEmpty {
            Text("No active agents")
                .font(.caption)
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(visibleAgents) { agent in
                    agentStatusRow(agent)
                }
            }
        }
    }

    private func agentStatusRow(_ agent: CoworkAgentInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName(for: agent.status))
                .font(.caption)
                .foregroundStyle(statusColor(for: agent.status))
                .frame(width: 18)
            Text("@\(agent.name)")
                .font(.caption.bold())
                .foregroundStyle(threadStyle.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .help("\(agent.name): \(agent.status)")
    }

    private var goalTableSection: some View {
        rightRailSection("Goals") {
            goalTable
        }
    }

    @ViewBuilder private var goalTable: some View {
        if goalRows.isEmpty {
            Text("No agent-declared goals yet")
                .font(.caption)
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(goalRows.enumerated()), id: \.element.id) { index, task in
                    goalRow(index: index + 1, task: task)
                }
            }
        }
    }

    private func goalRow(index: Int, task: CoworkTaskLine) -> some View {
        let completed = isCompleted(task)
        return HStack(alignment: .top, spacing: 8) {
            goalMarker(index: index, completed: completed)
            VStack(alignment: .leading, spacing: 3) {
                Text(goalText(for: task))
                    .font(.caption)
                    .foregroundStyle(completed ? threadStyle.secondaryText : threadStyle.primaryText)
                    .strikethrough(completed, color: threadStyle.secondaryText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.title.isEmpty {
                    Text(task.title)
                        .font(.caption2)
                        .foregroundStyle(threadStyle.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func goalMarker(index: Int, completed: Bool) -> some View {
        if completed {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
        } else {
            ZStack {
                Circle()
                    .stroke(threadStyle.secondaryText, lineWidth: 1)
                Text("\(index)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(threadStyle.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 22, height: 22)
        }
    }

    private func rightRailSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        inspectorSection(title) {
            content()
        }
    }

    private var inspectorOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(project.mainAgentName)")
                        .font(.caption.bold())
                        .foregroundStyle(threadStyle.primaryText)
                        .lineLimit(1)
                    Text(project.defaultModel)
                        .font(.caption2)
                        .foregroundStyle(threadStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let onShowProjectSettings {
                    Button(action: onShowProjectSettings) {
                        Label("Project Settings", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                    .help("Project Settings")
                }
            }

            Divider().opacity(0.35)

            HStack(alignment: .top, spacing: 12) {
                overviewMetric("Agents", "\(agents.count)")
                overviewMetric("Running", "\(summary.runningCount)")
                overviewMetric("Tasks", "\(summary.activeCount)")
                overviewMetric("Inbox", "\(summary.pendingMailboxCount)")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(threadStyle.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(threadStyle.cardStroke, lineWidth: 1)
        }
    }

    private func overviewMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(threadStyle.tertiaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inspectorTabs: some View {
        Picker("Inspector view", selection: $inspectorTab) {
            ForEach(CoworkInspectorTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder private var inspectorTabContent: some View {
        switch inspectorTab {
        case .agents:
            agentsInspector
        case .tasks:
            tasksInspector
        case .context:
            contextInspector
        }
    }

    @ViewBuilder private var agentsInspector: some View {
        inspectorSection("Roster") {
            agentRosterList
        }
        if let agent = selectedAgent {
            inspectorSection("Selected Agent") {
                selectedAgentDetails(agent)
            }
        }
    }

    private var tasksInspector: some View {
        inspectorSection("Task Flow") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 12) {
                    overviewMetric("Active", "\(summary.activeCount)")
                    overviewMetric("Running", "\(summary.runningCount)")
                    overviewMetric("Failed", "\(summary.failedCount)")
                }
                Divider().opacity(0.35)
                taskList
            }
        }
    }

    @ViewBuilder private var contextInspector: some View {
        inspectorSection("Project") {
            projectSection
        }
        inspectorSection("Workspaces") {
            inspectorRow("Directories", value: "\(project.workspaces.count)")
            workspaceDirectoryList
        }
        inspectorSection("Access") {
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

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            inspectorRow("Session", value: project.sessionID.isEmpty ? "current" : project.sessionID)
            inspectorRow("Main", value: "@\(project.mainAgentName)")
            inspectorRow("Model", value: project.defaultModel)
            inspectorRow("Permission", value: project.defaultPermission)
            if let tokenBudget = project.tokenBudget {
                inspectorRow("Soft token budget", value: tokenBudget)
            }
            if let onShowProjectSettings {
                Button(action: onShowProjectSettings) {
                    Label("Project Settings", systemImage: "slider.horizontal.3")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
            }
        }
    }

    @ViewBuilder private var workspaceDirectoryList: some View {
        if project.workspaces.isEmpty {
            Text("No workspace directories")
                .font(.caption)
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(project.workspaces.prefix(5)) { workspace in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: workspace.isPrimary ? "house" : "folder")
                                .font(.caption2)
                                .foregroundStyle(workspace.isPrimary ? threadStyle.accent : threadStyle.secondaryText)
                            Text(workspace.displayName)
                                .font(.caption.bold())
                                .foregroundStyle(threadStyle.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if let agentName = workspace.agentName {
                                Text("@\(agentName)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(threadStyle.secondaryText)
                            }
                        }
                        Text(workspace.path)
                            .font(.caption2)
                            .foregroundStyle(threadStyle.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(agents) { agent in
                    agentListRow(agent)
                }
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
            ForEach(summary.runningTasks) { task in
                taskCompactRow(task: task)
            }
            ForEach(summary.failedTasks) { task in
                taskCompactRow(
                    task: task,
                    actionTitle: onRetryTask == nil ? nil : "Retry",
                    actionDisabled: isWorking,
                    action: onRetryTask.map { retry in { retry(task.id) } })
            }
            ForEach(summary.recentCompletedTasks) { task in
                taskCompactRow(task: task)
            }
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

    private func agentListRow(_ agent: CoworkAgentInfo) -> some View {
        let selected = selectedAgentID == agent.id
        return Button {
            selectedAgentID = agent.id
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor(for: agent.status))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("@\(agent.name)")
                            .font(.caption.bold())
                            .foregroundStyle(threadStyle.primaryText)
                            .lineLimit(1)
                        Text(agent.role)
                            .font(.caption2.bold())
                            .foregroundStyle(threadStyle.secondaryText)
                            .lineLimit(1)
                    }
                    Text(agent.statusLine)
                        .font(.caption2)
                        .foregroundStyle(threadStyle.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(threadStyle.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(selected ? threadStyle.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func selectedAgentDetails(_ agent: CoworkAgentInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("@\(agent.name)")
                    .font(.caption.bold())
                    .foregroundStyle(threadStyle.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(agent.status)
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor(for: agent.status))
                    .lineLimit(1)
                if agent.canRemove, let onRemoveAgent {
                    Button {
                        onRemoveAgent(agent.name)
                    } label: {
                        Label("Remove agent", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                    .help("Remove agent")
                }
            }
            Text(agent.workspace)
                .font(.caption2)
                .foregroundStyle(threadStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Divider().opacity(0.35)
            agentDetailRow("Role", value: agent.role)
            agentDetailRow("Model", value: agent.model)
            agentDetailRow("Permission", value: agent.profile)
            agentDetailRow("Queued", value: "\(agent.pendingTasks) tasks / \(agent.pendingMessages) messages")
            agentDetailRow("Completed", value: "\(agent.completedTasks) tasks")
            if let workspaceLease = agent.workspaceLease {
                agentDetailRow("Workspace lease", value: workspaceLease)
            }
            if let capabilityLease = agent.capabilityLease {
                agentDetailRow("Capability lease", value: capabilityLease)
            }
        }
    }

    private func taskCompactRow(task: CoworkTaskLine,
                                actionTitle: String? = nil,
                                actionDisabled: Bool = false,
                                action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(task.title)
                    .font(.caption.bold())
                    .foregroundStyle(threadStyle.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderless)
                        .disabled(actionDisabled)
                }
                Text(task.status)
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor(for: task.status))
                    .lineLimit(1)
            }
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.caption2)
                    .foregroundStyle(threadStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "failed", "error", "rejected":
            return threadStyle.error
        case "running", "thinking", "tool":
            return threadStyle.accent
        case "assigned", "queued", "mailbox":
            return .orange
        case "completed", "complete", "done":
            return .green
        default:
            return threadStyle.tertiaryText
        }
    }

    private func statusIconName(for status: String) -> String {
        switch status.lowercased() {
        case "failed", "error", "rejected":
            return "exclamationmark.triangle.fill"
        case "running", "thinking", "tool":
            return "play.circle.fill"
        case "assigned", "queued", "mailbox":
            return "clock.fill"
        case "completed", "complete", "done":
            return "checkmark.circle.fill"
        default:
            return "circle"
        }
    }

    private var visibleAgents: [CoworkAgentInfo] {
        agents.filter { agent in
            let status = agent.status.lowercased()
            return status != "cleaned" && status != "removed" && status != "detached"
        }
    }

    private var goalRows: [CoworkTaskLine] {
        summary.runningTasks + summary.failedTasks + summary.recentCompletedTasks
    }

    private var primaryWorkspace: CoworkWorkspaceInfo? {
        project.workspaces.first { $0.isPrimary } ?? project.workspaces.first
    }

    private var primaryWorkspaceName: String {
        primaryWorkspace?.displayName ?? "No workspace"
    }

    private var primaryWorkspacePath: String {
        primaryWorkspace?.path ?? "Attach a workspace to inspect git state."
    }

    private func isCompleted(_ task: CoworkTaskLine) -> Bool {
        switch task.status.lowercased() {
        case "completed", "complete", "done":
            return true
        default:
            return false
        }
    }

    private func goalText(for task: CoworkTaskLine) -> String {
        task.detail.isEmpty ? task.title : task.detail
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
                    if let onAddAgent {
                        Button(action: onAddAgent) {
                            Label("Attach", systemImage: "plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderless)
                    }
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
            agentDetailRow("Role", value: agent.role)
            agentDetailRow("Model", value: agent.model)
            agentDetailRow("Permission", value: agent.profile)
            agentDetailRow("Queued", value: "\(agent.pendingTasks) tasks / \(agent.pendingMessages) messages")
            agentDetailRow("Completed", value: "\(agent.completedTasks) tasks")
            if let workspaceLease = agent.workspaceLease {
                agentDetailRow("Workspace lease", value: workspaceLease)
            }
            if let capabilityLease = agent.capabilityLease {
                agentDetailRow("Capability lease", value: capabilityLease)
            }
            if agent.canRemove, let onRemoveAgent {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        onRemoveAgent(agent.name)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                    .help("Remove agent")
                }
            }
        }
        .padding(11)
        .background(threadStyle.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(threadStyle.cardStroke, lineWidth: 1)
        }
    }

    private func agentDetailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(threadStyle.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2.bold())
                .foregroundStyle(threadStyle.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
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
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.vertical, 16)
                }
                .scrollContentBackground(.hidden)
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: itemScrollSignature) { _ in
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private var itemScrollSignature: String {
        guard let last = items.last else { return "0" }
        return [
            "\(items.count)",
            last.id,
            "\(last.body.count)",
            "\(last.complete)",
            "\(isWorking)"
        ].joined(separator: ":")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
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
                placeholder: "Give Main a project task...",
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
