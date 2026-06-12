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
    public init(id: String, name: String, workspace: String, model: String, profile: String) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.model = model
        self.profile = profile
    }
}

/// Presentational Cowork thread (v0.3): agent roster + add button on the left,
/// the merged multi-agent thread in the middle (reuses `CodeItemRow`, including
/// the `agentToAgent` card), per-agent details on the right. `@mention` parsing
/// happens in the view model; the composer just hints at it.
public struct CoworkShell: View {
    private let items: [CodeItem]
    private let agents: [CoworkAgentInfo]
    private let pending: PermissionRequestPayload?
    private let isWorking: Bool
    @Binding private var input: String
    private let onSend: () -> Void
    private let onResolve: (PermissionDecision) -> Void
    private let onAddAgent: () -> Void

    public init(items: [CodeItem],
                agents: [CoworkAgentInfo],
                pending: PermissionRequestPayload?,
                isWorking: Bool,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void,
                onAddAgent: @escaping () -> Void) {
        self.items = items
        self.agents = agents
        self.pending = pending
        self.isWorking = isWorking
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
        self.onAddAgent = onAddAgent
    }

    public var body: some View {
        NavigationSplitView {
            List {
                Section("Agents") {
                    ForEach(agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(agent.name)").font(.callout.bold())
                            Text(agent.workspace).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
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
                        LabeledContent("@\(agent.name)", value: agent.profile)
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
                PermissionCard(request: pending, onResolve: onResolve)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message agents — use @Name to direct it…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(onSend)
                    .disabled(isWorking || pending != nil || agents.isEmpty)
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(isWorking || pending != nil || agents.isEmpty
                              || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }
}
#endif
