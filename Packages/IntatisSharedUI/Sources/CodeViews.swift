#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

/// Presentational Code thread (v0.2). All data + callbacks are injected, so the
/// kernel-driving view model lives in the app, not here (keeps SharedUI free of
/// Tools/Permission/AgentKernel dependencies).
public struct CodeShell: View {
    private static let bottomAnchorID = "intatis-code-thread-bottom"
    private let items: [CodeItem]
    private let pending: PendingPermission?
    private let permissionNotice: PermissionResolutionNotice?
    private let latestTurnStats: TurnStatsSnapshot?
    private let isWorking: Bool
    private let workspaceName: String
    private let agentState: String
    private let composerError: String?
    private let threadStyle: IntatisThreadStyle
    private let onShowSessions: (() -> Void)?
    private let onNewSession: (() -> Void)?
    private let composerAccessory: AnyView?
    @Binding private var input: String
    private let onSend: () -> Void
    private let onResolve: (PermissionDecision) -> Void

    public init(items: [CodeItem],
                pending: PendingPermission?,
                permissionNotice: PermissionResolutionNotice? = nil,
                latestTurnStats: TurnStatsSnapshot? = nil,
                isWorking: Bool,
                workspaceName: String,
                agentState: String,
                composerError: String? = nil,
                threadStyle: IntatisThreadStyle = .standard(.light),
                splitLayout: IntatisSplitColumnLayout = .workspace,
                onShowSessions: (() -> Void)? = nil,
                onNewSession: (() -> Void)? = nil,
                composerAccessory: AnyView? = nil,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onResolve: @escaping (PermissionDecision) -> Void) {
        self.items = items
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.latestTurnStats = latestTurnStats
        self.isWorking = isWorking
        self.workspaceName = workspaceName
        self.agentState = agentState
        self.composerError = composerError
        self.threadStyle = threadStyle
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.composerAccessory = composerAccessory
        self._input = input
        self.onSend = onSend
        self.onResolve = onResolve
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
    }

    @ViewBuilder private func content(rawWidth: CGFloat) -> some View {
        if rawWidth >= 940 {
            HStack(spacing: 0) {
                threadColumn(layout: IntatisThreadContentLayout(rawWidth: rawWidth - 300))
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.45)
                CodeInspectorView(
                    workspaceName: workspaceName,
                    agentState: agentState,
                    itemCount: items.count,
                    pending: pending,
                    latestTurnStats: latestTurnStats,
                    failedItems: failedItems,
                    style: threadStyle)
                .frame(width: 292)
                .frame(maxHeight: .infinity)
            }
        } else {
            threadColumn(layout: IntatisThreadContentLayout(rawWidth: rawWidth))
        }
    }

    private var failedItems: [CodeItem] {
        Array(items.filter { $0.isFailure || $0.kind == .error }.suffix(4))
    }

    private func threadColumn(layout: IntatisThreadContentLayout) -> some View {
        VStack(spacing: 0) {
            header(layout: layout)
            thread(layout: layout)
            permissionArea(layout: layout)
            composerArea(layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(layout: IntatisThreadContentLayout) -> some View {
        IntatisWorkspaceThreadHeader(
            title: "Code",
            subtitle: "\(workspaceName) · \(agentState)",
            style: threadStyle,
            actions: [])
        .frame(maxWidth: layout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    private var headerActions: [IntatisThreadHeaderAction] {
        var actions: [IntatisThreadHeaderAction] = []
        if let onShowSessions {
            actions.append(IntatisThreadHeaderAction(title: "Sessions", systemImage: "clock.arrow.circlepath", action: onShowSessions))
        }
        if let onNewSession {
            actions.append(IntatisThreadHeaderAction(title: "New", systemImage: "plus", action: onNewSession))
        }
        return actions
    }

    @ViewBuilder private func thread(layout: IntatisThreadContentLayout) -> some View {
        if items.isEmpty {
            CodeEmptyThreadView(style: threadStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, layout.horizontalPadding)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
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
                placeholder: "Message Coder...",
                input: $input,
                canSend: !isWorking
                    && !permissionBlocksComposer
                    && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isInputDisabled: isWorking || permissionBlocksComposer,
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

struct CodeItemRow: View {
    let item: CodeItem
    let style: IntatisThreadStyle
    let layout: IntatisThreadContentLayout

    init(item: CodeItem,
         style: IntatisThreadStyle = .standard(.light),
         layout: IntatisThreadContentLayout = IntatisThreadContentLayout(rawWidth: 900)) {
        self.item = item
        self.style = style
        self.layout = layout
    }

    var body: some View {
        switch item.kind {
        case .user:
            bubble(title: "You", body: item.body, isUser: true, tags: item.tags)
        case .agent:
            bubble(title: item.title, body: item.body.isEmpty && !item.complete ? "…" : item.body,
                   isUser: false)
        case .toolCall:
            card(icon: "wrench.and.screwdriver", title: "tool · \(item.title)", body: item.body, tint: .blue)
        case .toolResult:
            card(icon: item.isFailure ? "exclamationmark.triangle" : "arrow.turn.down.right",
                 title: item.title,
                 body: item.body,
                 tint: item.isFailure ? .red : .gray)
        case .patch:
            card(icon: "doc.badge.gearshape", title: "patch · \(item.files.joined(separator: ", "))",
                 body: item.body, tint: .purple)
        case .note:
            Text(item.body).font(.caption).foregroundStyle(.secondary)
        case .error:
            card(icon: "exclamationmark.triangle", title: item.title, body: item.body, tint: .red)
        case .agentToAgent:
            card(icon: "arrow.left.arrow.right", title: "↔ \(item.title)", body: item.body, tint: .teal)
        }
    }

    private func bubble(title: String, body: String, isUser: Bool, tags: [String] = []) -> some View {
        IntatisThreadBubbleRow(
            isTrailing: isUser,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
                bubbleContent(title: title, body: body, isUser: isUser, tags: tags)
            }
    }

    private func bubbleContent(title: String, body: String, isUser: Bool, tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(isUser ? style.accent : style.tertiaryText)
                ForEach(tags, id: \.self) { tag in
                    tagBadge(tag)
                }
            }
            Text(body)
                .font(.system(size: 15))
                .foregroundStyle(style.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let advice = item.recoveryAdvice {
                IntatisRecoveryAdviceView(
                    advice: advice,
                    tint: item.isFailure ? style.error : style.accent,
                    style: style)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isUser ? style.userBubble : style.assistantBubble)
                .background(style.material, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(bubbleStroke(isUser: isUser), lineWidth: 1)
                }
        }
    }

    private func bubbleStroke(isUser: Bool) -> Color {
        if isUser { return style.accentSoft }
        if item.isFailure { return style.error.opacity(0.36) }
        return style.stroke
    }

    private func card(icon: String, title: String, body: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(tint)
            Text(body).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let advice = item.recoveryAdvice {
                IntatisRecoveryAdviceView(advice: advice, tint: tint, style: style)
            }
        }
        .padding(11)
        .background(style.cardSurface)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: min(layout.contentMaxWidth, 740), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagBadge(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(style.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(style.accentSoft, in: Capsule())
    }
}

private struct CodeEmptyThreadView: View {
    let style: IntatisThreadStyle

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(style.accent)
                .frame(width: 76, height: 76)
                .background(style.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer()
        }
        .multilineTextAlignment(.center)
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

private struct CodeInspectorView: View {
    let workspaceName: String
    let agentState: String
    let itemCount: Int
    let pending: PendingPermission?
    let latestTurnStats: TurnStatsSnapshot?
    let failedItems: [CodeItem]
    let style: IntatisThreadStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorHeader
                inspectorSection("Plan") {
                    inspectorRow("Current task", value: agentState)
                    inspectorRow("Thread events", value: "\(itemCount)")
                    if let pending {
                        inspectorRow("Permission", value: pending.request.tool)
                    } else {
                        inspectorRow("Permission", value: "none pending")
                    }
                }
                inspectorSection("Workspace") {
                    inspectorRow("Root", value: workspaceName)
                    inspectorRow("Git", value: "status only")
                    Text("Commit, branch, PR, CI, and review workflows are deferred.")
                        .font(.caption2)
                        .foregroundStyle(style.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                inspectorSection("Recent Failures") {
                    if failedItems.isEmpty {
                        Text("No failed tool or runtime events in the current projection.")
                            .font(.caption)
                            .foregroundStyle(style.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(failedItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.caption.bold())
                                    .foregroundStyle(style.primaryText)
                                    .lineLimit(1)
                                Text(item.body)
                                    .font(.caption2)
                                    .foregroundStyle(style.secondaryText)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if let latestTurnStats {
                    inspectorSection("Last Turn") {
                        IntatisTurnStatsSummaryView(stats: latestTurnStats, style: style)
                    }
                }
            }
            .padding(16)
        }
        .background(style.cardSurface.opacity(0.38))
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inspector")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(style.primaryText)
            Text("Task and workspace status")
                .font(.caption)
                .foregroundStyle(style.secondaryText)
        }
    }

    private func inspectorSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(style.tertiaryText)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(style.cardStroke, lineWidth: 1)
        }
    }

    private func inspectorRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(style.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(style.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
#endif
