#if canImport(SwiftUI)
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

/// Presentational Code thread (v0.2). All data + callbacks are injected, so the
/// kernel-driving view model lives in the app, not here (keeps SharedUI free of
/// Tools/Permission/AgentKernel dependencies).
public struct CodeShell: View {
    private let items: [CodeItem]
    private let pending: PermissionRequestPayload?
    private let isWorking: Bool
    private let workspaceName: String
    private let agentState: String
    @Binding private var input: String
    private let onSend: () -> Void
    private let onResolve: (PermissionDecision) -> Void

    public init(items: [CodeItem],
                pending: PermissionRequestPayload?,
                isWorking: Bool,
                workspaceName: String,
                agentState: String,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void) {
        self.items = items
        self.pending = pending
        self.isWorking = isWorking
        self.workspaceName = workspaceName
        self.agentState = agentState
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
    }

    public var body: some View {
        NavigationSplitView {
            List { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } content: {
            thread.navigationSplitViewColumnWidth(min: 380, ideal: 600)
        } detail: {
            CodeInspectorView(workspaceName: workspaceName, agentState: agentState, itemCount: items.count)
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
                TextField("Ask the agent to read or edit files…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(onSend)
                    .disabled(isWorking || pending != nil)
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(isWorking || pending != nil || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }
}

struct CodeItemRow: View {
    let item: CodeItem

    var body: some View {
        switch item.kind {
        case .user:
            bubble(title: "You", body: item.body, tint: Color.accentColor.opacity(0.12), mono: false)
        case .agent:
            bubble(title: item.title, body: item.body.isEmpty && !item.complete ? "…" : item.body,
                   tint: Color.gray.opacity(0.10), mono: false)
        case .toolCall:
            card(icon: "wrench.and.screwdriver", title: "tool · \(item.title)", body: item.body, tint: .blue)
        case .toolResult:
            card(icon: "arrow.turn.down.right", title: "result", body: item.body, tint: .gray)
        case .patch:
            card(icon: "doc.badge.gearshape", title: "patch · \(item.files.joined(separator: ", "))",
                 body: item.body, tint: .purple)
        case .note:
            Text(item.body).font(.caption).foregroundStyle(.secondary)
        case .error:
            card(icon: "exclamationmark.triangle", title: "error", body: item.body, tint: .red)
        case .agentToAgent:
            card(icon: "arrow.left.arrow.right", title: "↔ \(item.title)", body: item.body, tint: .teal)
        }
    }

    private func bubble(title: String, body: String, tint: Color, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10).background(tint).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func card(icon: String, title: String, body: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(tint)
            Text(body).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PermissionCard: View {
    let request: PermissionRequestPayload
    let onResolve: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Permission needed", systemImage: "lock.shield").font(.headline)
                Spacer()
                Text(request.risk.rawValue.uppercased()).font(.caption.bold()).foregroundStyle(riskColor)
            }
            Text("\(request.tool) — \(request.reason)").font(.callout)
            if let diff = Self.diff(from: request.args) {
                ScrollView { Text(diff).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
                    .padding(6)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Reject") { onResolve(.deny) }
                Button("Approve") { onResolve(.allow) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var riskColor: Color {
        switch request.risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    static func diff(from args: String) -> String? {
        struct A: Decodable { let diff: String? }
        return (try? JSONDecoder().decode(A.self, from: Data(args.utf8)))?.diff
    }
}

struct CodeInspectorView: View {
    let workspaceName: String
    let agentState: String
    let itemCount: Int

    var body: some View {
        List {
            Section("Agent") {
                LabeledContent("Workspace", value: workspaceName)
                LabeledContent("State", value: agentState)
                LabeledContent("Items", value: "\(itemCount)")
            }
            Section("About") {
                Text("Tool calls and patches require approval unless the gate auto-allows "
                     + "a read-only action. Reviewer auto-approval arrives in v0.3.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
