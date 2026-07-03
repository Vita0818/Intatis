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
    private let summary: CoworkStatusSummary
    private let composerError: String?
    private let isWorking: Bool
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
                summary: CoworkStatusSummary,
                composerError: String?,
                isWorking: Bool,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void,
                onAddAgent: @escaping () -> Void,
                onRetryTask: ((String) -> Void)? = nil) {
        self.items = items
        self.agents = agents
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.summary = summary
        self.composerError = composerError
        self.isWorking = isWorking
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
        self.onAddAgent = onAddAgent
        self.onRetryTask = onRetryTask
    }

    private var permissionBlocksComposer: Bool {
        guard let pending else { return false }
        return pending.state == .livePending || pending.state == .resolving
    }

    public var body: some View {
        NavigationSplitView {
            List {
                Section("Agents") {
                    ForEach(agents) { agent in
                        Button {
                            selectedAgentID = agent.id
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("@\(agent.name)").font(.callout.bold())
                                    Text("\(agent.status) · \(agent.workspace)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                if selectedAgentID == agent.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button(action: onAddAgent) { Label("Add Agent…", systemImage: "plus") }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            thread.navigationSplitViewColumnWidth(min: 380, ideal: 600)
        } detail: {
            List {
                Section("Attached") {
                    if agents.isEmpty {
                        Text("No agents yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(agents) { agent in
                        LabeledContent("@\(agent.name)", value: agent.status)
                        if agent.pendingTasks + agent.pendingMessages + agent.completedTasks > 0 {
                            Text("Mailbox \(agent.pendingMessages + agent.pendingTasks) pending · \(agent.completedTasks) completed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Agent Detail") {
                    if let agent = selectedAgent {
                        LabeledContent("Name", value: "@\(agent.name)")
                        LabeledContent("Status", value: agent.status)
                        LabeledContent("Model", value: agent.model)
                        LabeledContent("Profile", value: agent.profile)
                        Text(agent.workspace)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        LabeledContent("Pending messages", value: "\(agent.pendingMessages)")
                        LabeledContent("Pending tasks", value: "\(agent.pendingTasks)")
                        LabeledContent("Completed tasks", value: "\(agent.completedTasks)")
                        if let workspaceLease = agent.workspaceLease {
                            LabeledContent("Workspace lease", value: workspaceLease)
                        }
                        if let capabilityLease = agent.capabilityLease {
                            LabeledContent("Capability lease", value: capabilityLease)
                        }
                    } else {
                        Text(agents.isEmpty ? "No agent selected" : "Select an agent for details")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Tasks") {
                    LabeledContent("Active", value: "\(summary.activeCount)")
                    LabeledContent("Running", value: "\(summary.runningCount)")
                    LabeledContent("Completed", value: "\(summary.completedCount)")
                    LabeledContent("Failed", value: "\(summary.failedCount)")
                }
                if !summary.runningTasks.isEmpty {
                    Section("Running") {
                        ForEach(summary.runningTasks) { task in CoworkTaskLineRow(task: task) }
                    }
                }
                Section("Mailbox") {
                    LabeledContent("Pending", value: "\(summary.pendingMailboxCount)")
                    LabeledContent("Completed", value: "\(summary.completedMailboxCount)")
                }
                Section("Leases") {
                    LabeledContent("Workspace", value: summary.workspaceLeaseCount > 0 ? "\(summary.workspaceLeaseCount) active" : "None")
                    LabeledContent("Capability", value: summary.capabilityLeaseCount > 0 ? "\(summary.capabilityLeaseCount) active" : "None")
                }
                Section("Failed") {
                    if summary.failedTasks.isEmpty {
                        Text("No failed tasks").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(summary.failedTasks) { task in
                            CoworkTaskLineRow(
                                task: task,
                                actionTitle: onRetryTask == nil ? nil : "Retry",
                                actionDisabled: isWorking,
                                action: onRetryTask.map { retry in { retry(task.id) } })
                        }
                    }
                }
                if !summary.recentCompletedTasks.isEmpty {
                    Section("Recent") {
                        ForEach(summary.recentCompletedTasks) { task in CoworkTaskLineRow(task: task) }
                    }
                }
                Section("About") {
                    Text("Agents can't read each other's workspaces. `@name` routes a message; "
                         + "agent-to-agent requests go through the mediated Message Bus and are logged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        }
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

    private var thread: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { CodeItemRow(item: $0).id($0.id) }
                    }
                    .padding()
                }
                .onChange(of: items.count) { _ in
                    if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let pending {
                PermissionCard(permission: pending, onResolve: onResolve)
            } else if let permissionNotice {
                PermissionResolutionNoticeView(notice: permissionNotice)
            }
            Divider()
            if let composerError {
                Text(composerError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message agents — use @Name to direct it…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(onSend)
                    .disabled(isWorking || permissionBlocksComposer || agents.isEmpty)
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(isWorking || permissionBlocksComposer || agents.isEmpty
                              || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }
}

private struct CoworkTaskLineRow: View {
    let task: CoworkTaskLine
    let actionTitle: String?
    let actionDisabled: Bool
    let action: (() -> Void)?

    init(task: CoworkTaskLine,
         actionTitle: String? = nil,
         actionDisabled: Bool = false,
         action: (() -> Void)? = nil) {
        self.task = task
        self.actionTitle = actionTitle
        self.actionDisabled = actionDisabled
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(task.title).lineLimit(1)
                Spacer(minLength: 6)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderless)
                        .disabled(actionDisabled)
                }
                Text(task.status).font(.caption).foregroundStyle(.secondary)
            }
            if !task.detail.isEmpty {
                Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
#endif
