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
    private let pending: PendingPermission?
    private let permissionNotice: PermissionResolutionNotice?
    private let isWorking: Bool
    private let workspaceName: String
    private let agentState: String
    private let composerError: String?
    @Binding private var input: String
    private let onSend: () -> Void
    private let onResolve: (PermissionDecision) -> Void

    public init(items: [CodeItem],
                pending: PendingPermission?,
                permissionNotice: PermissionResolutionNotice? = nil,
                isWorking: Bool,
                workspaceName: String,
                agentState: String,
                composerError: String? = nil,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void) {
        self.items = items
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.isWorking = isWorking
        self.workspaceName = workspaceName
        self.agentState = agentState
        self.composerError = composerError
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
    }

    private var permissionBlocksComposer: Bool {
        guard let pending else { return false }
        return pending.state == .livePending || pending.state == .resolving
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
                TextField("Ask the agent to read or edit files…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(onSend)
                    .disabled(isWorking || permissionBlocksComposer)
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(isWorking || permissionBlocksComposer || input.trimmingCharacters(in: .whitespaces).isEmpty)
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
            bubble(title: "You", body: item.body, tint: Color.accentColor.opacity(0.12), mono: false, tags: item.tags)
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

    private func bubble(title: String, body: String, tint: Color, mono: Bool, tags: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(tags, id: \.self) { tag in
                    tagBadge(tag)
                }
            }
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

    private func tagBadge(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

public struct PermissionResolutionNoticeView: View {
    let notice: PermissionResolutionNotice

    public init(notice: PermissionResolutionNotice) {
        self.notice = notice
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(notice.decision == .allow ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(notice.tool) \(notice.decision == .allow ? "approved" : "rejected")")
                    .font(.caption.bold())
                Text(notice.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

public struct PermissionCard: View {
    let permission: PendingPermission
    let onResolve: (PermissionDecision) -> Void

    public init(permission: PendingPermission, onResolve: @escaping (PermissionDecision) -> Void) {
        self.permission = permission
        self.onResolve = onResolve
    }

    private var request: PermissionRequestPayload { permission.request }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Permission needed", systemImage: "lock.shield").font(.headline)
                Spacer()
                Text(request.risk.rawValue.uppercased()).font(.caption.bold()).foregroundStyle(riskColor)
            }
            Text("\(request.tool) — \(request.reason)").font(.callout)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
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
                if permission.state == .resolving {
                    ProgressView().controlSize(.small)
                    Text("Resolving…").font(.caption).foregroundStyle(.secondary)
                } else if permission.state.isActionable {
                    Button("Reject") { onResolve(.deny) }
                    Button("Approve") { onResolve(.allow) }.keyboardShortcut(.defaultAction)
                }
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

    private var statusText: String {
        switch permission.state {
        case .livePending:
            return "Waiting for your decision."
        case .resolving:
            return "Applying your decision."
        case .approved:
            return "Approved."
        case .rejected:
            return "Rejected."
        case .expired:
            return "This approval channel expired. Rerun the task to continue."
        case .needsRerun:
            return "This request was restored from history. Rerun the task to continue."
        }
    }

    private var statusColor: Color {
        switch permission.state {
        case .livePending, .resolving:
            return .secondary
        case .approved:
            return .green
        case .rejected, .expired, .needsRerun:
            return .orange
        }
    }

    public static func diff(from args: String) -> String? {
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
