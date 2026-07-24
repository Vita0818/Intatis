#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

private func intatisLocalizedAgentState(_ state: String) -> String {
    switch state {
    case AgentState.idle.rawValue:
        return IntatisLocalization.string("Idle")
    case AgentState.thinking.rawValue:
        return IntatisLocalization.string("Thinking")
    case AgentState.tool.rawValue:
        return IntatisLocalization.string("Tool")
    case AgentState.blocked.rawValue:
        return IntatisLocalization.string("Blocked")
    default:
        return state
    }
}

/// Presentational Code thread (v0.2). All data + callbacks are injected, so the
/// kernel-driving view model lives in the app, not here (keeps SharedUI free of
/// Tools/Permission/AgentKernel dependencies).
public struct CodeShell: View {
    private let displayedItems: [CodeItem]
    private let presentationScope: IntatisThreadPresentationScope
    private let sessionTitle: String
    private let thinkingPhaseID: String
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
    private let onCancelCurrent: (() -> Void)?
    private let onResolve: (PermissionResponseAction) -> Void
    @Binding private var showsInspector: Bool
    @StateObject private var scrollCoordinator = IntatisThreadScrollCoordinator()

    public init(items: [CodeItem],
                presentationScope: IntatisThreadPresentationScope,
                sessionTitle: String = IntatisLocalization.string("Code"),
                thinkingScopeID: String = "code",
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
                showsInspector: Binding<Bool>,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onCancelCurrent: (() -> Void)? = nil,
                onResolve: @escaping (PermissionResponseAction) -> Void) {
        self.displayedItems = IntatisExecutionTracePresentation.displayedItems(items)
        self.presentationScope = presentationScope
        self.sessionTitle = sessionTitle
        self.thinkingPhaseID = "\(thinkingScopeID):\(items.last?.id ?? "initial")"
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
        self._showsInspector = showsInspector
        self._input = input
        self.onSend = onSend
        self.onCancelCurrent = onCancelCurrent
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(showsInspector
                    ? IntatisLocalization.string("Hide Inspector")
                    : IntatisLocalization.string("Show Inspector"))
            }
        }
    }

    private func content(rawWidth: CGFloat) -> some View {
        let usesInspector = rawWidth >= 940
        let inspectorVisible = usesInspector && showsInspector
        let threadWidth = inspectorVisible ? max(rawWidth - 300, 1) : rawWidth
        let inspectorBinding = Binding(
            get: { inspectorVisible },
            set: { if usesInspector { showsInspector = $0 } })

        return threadColumn(layout: IntatisThreadContentLayout(rawWidth: threadWidth))
            .inspector(isPresented: inspectorBinding) {
                CodeInspectorView(
                    workspaceName: workspaceName,
                    agentState: agentState,
                    itemCount: displayedItems.count,
                    pending: pending,
                    failedItems: failedItems,
                    style: threadStyle)
                .inspectorColumnWidth(min: 260, ideal: 292, max: 360)
            }
    }

    private var failedItems: [CodeItem] {
        Array(displayedItems.filter { $0.isFailure || $0.kind == .error }.suffix(4))
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
            title: sessionTitle,
            subtitle: "\(workspaceName) · \(intatisLocalizedAgentState(agentState))",
            style: threadStyle,
            actions: [])
        .frame(maxWidth: layout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func thread(layout: IntatisThreadContentLayout) -> some View {
        if displayedItems.isEmpty && !showsThinkingIndicator {
            CodeEmptyThreadView(style: threadStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, layout.horizontalPadding)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    IntatisAdaptiveThreadStack(
                        visibleRowCount: displayedItems.count + (showsThinkingIndicator ? 1 : 0),
                        alignment: .leading,
                        spacing: 12) {
                        ForEach(displayedItems) { item in
                            CodeItemRow(item: item, style: threadStyle, layout: layout)
                                .id(item.id)
                        }
                        if showsThinkingIndicator {
                            IntatisThreadThinkingRow(
                                layout: layout,
                                style: threadStyle,
                                phaseID: thinkingPhaseID)
                                .id("intatis-code-thinking-\(thinkingPhaseID)")
                        }
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 16)
                            .id(IntatisThreadBottomAnchorID(scope: presentationScope))
                    }
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, 16)
                }
                .scrollContentBackground(.hidden)
                .onAppear {
                    scrollCoordinator.activate(scope: presentationScope)
                    requestScroll(
                        proxy,
                        reason: .initialRestore)
                }
                .onChange(of: itemScrollSignature) { _, _ in
                    scrollCoordinator.beginLayoutEpoch(
                        scope: presentationScope)
                    requestScroll(
                        proxy,
                        reason: scrollReason)
                }
                .onChange(of: layout.contentWidth) { _, _ in
                    scrollCoordinator.beginLayoutEpoch(
                        scope: presentationScope)
                }
                .onChange(of: presentationScope) { _, newScope in
                    scrollCoordinator.activate(scope: newScope)
                    requestScroll(
                        proxy,
                        reason: .initialRestore)
                }
                .onScrollGeometryChange(
                    for: IntatisThreadScrollGeometry.self
                ) { geometry in
                    IntatisThreadScrollGeometry.measure(
                        contentOffsetY: geometry.contentOffset.y,
                        containerHeight: geometry.containerSize.height,
                        bottomInset: geometry.contentInsets.bottom,
                        contentHeight: geometry.contentSize.height)
                } action: { previous, current in
                    scrollCoordinator.updateBottomProximity(
                        current.isAtBottom,
                        contentHeight: current.contentHeight,
                        scope: presentationScope)
                    if !current.isAtBottom,
                       current.hasMaterialHeightChange(from: previous) {
                        requestScroll(
                            proxy,
                            reason: .richHeightCorrection,
                            contentHeight: current.contentHeight)
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        scrollCoordinator.userInteractionDidBegin(
                            scope: presentationScope)
                    case .idle:
                        scrollCoordinator.userInteractionDidEnd(
                            scope: presentationScope)
                    case .animating:
                        break
                    }
                }
                .onDisappear {
                    scrollCoordinator.deactivate(scope: presentationScope)
                }
            }
            .id(presentationScope)
        }
    }

    private var showsThinkingIndicator: Bool {
        IntatisThreadActivity.isAwaitingModelOutput(
            items: displayedItems,
            isWorking: isWorking,
            permissionBlocksResponse: permissionBlocksComposer)
    }

    private var itemScrollSignature: IntatisThreadScrollSignature {
        let last = displayedItems.last
        return IntatisThreadScrollSignature(
            visibleItemCount: displayedItems.count,
            lastItemID: last?.id,
            lastBodyUTF8Count: last?.body.utf8.count ?? 0,
            lastItemComplete: last?.complete ?? false,
            isWorking: isWorking,
            showsThinkingIndicator: showsThinkingIndicator)
    }

    private var scrollReason: IntatisThreadScrollReason {
        guard let last = displayedItems.last else { return .liveUpdate }
        return last.complete && !isWorking ? .completion : .liveUpdate
    }

    private func requestScroll(
        _ proxy: ScrollViewProxy,
        reason: IntatisThreadScrollReason,
        contentHeight: CGFloat? = nil
    ) {
        let perform: @MainActor (IntatisThreadScrollRequest) -> Void = { request in
            let anchorID = IntatisThreadBottomAnchorID(scope: request.scope)
            if request.animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(anchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(anchorID, anchor: .bottom)
            }
        }
        if reason == .richHeightCorrection,
           let contentHeight {
            scrollCoordinator.requestRichHeightCorrection(
                scope: presentationScope,
                contentHeight: contentHeight,
                perform: perform)
        } else {
            scrollCoordinator.request(
                scope: presentationScope,
                reason: reason,
                perform: perform)
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
                placeholder: IntatisLocalization.string("Message Coder..."),
                input: $input,
                canSend: !isWorking
                    && !permissionBlocksComposer
                    && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isInputDisabled: isWorking || permissionBlocksComposer,
                style: threadStyle,
                leadingAccessory: composerAccessory,
                stopAction: isWorking
                    ? onCancelCurrent.map { onCancelCurrent in
                        IntatisThreadComposerSecondaryAction(
                            systemImage: "stop.fill",
                            help: IntatisLocalization.string("Stop"),
                            action: onCancelCurrent)
                    }
                    : nil,
                accessory: {
                    IntatisComposerUsageStrip(
                        stats: latestTurnStats,
                        style: threadStyle)
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
    let onRetrySubmission: ((SubmissionID) -> Void)?

    init(item: CodeItem,
         style: IntatisThreadStyle = .standard(.light),
         layout: IntatisThreadContentLayout = IntatisThreadContentLayout(rawWidth: 900),
         onRetrySubmission: ((SubmissionID) -> Void)? = nil) {
        self.item = item
        self.style = style
        self.layout = layout
        self.onRetrySubmission = onRetrySubmission
    }

    var body: some View {
        switch item.kind {
        case .user:
            bubble(
                title: IntatisLocalization.string("You"),
                body: item.body,
                isUser: true,
                tags: item.tags)
        case .agent:
            bubble(title: item.title, body: item.body.isEmpty && !item.complete ? "…" : item.body,
                   isUser: false)
        case .toolCall:
            card(
                icon: "wrench.and.screwdriver",
                title: IntatisLocalization.format("tool · %@", item.title),
                body: item.body,
                tint: .blue)
        case .toolResult:
            card(icon: item.isFailure ? "exclamationmark.triangle" : "arrow.turn.down.right",
                 title: item.title,
                 body: item.body,
                 tint: item.isFailure ? .red : .gray)
        case .patch:
            card(
                icon: "doc.badge.gearshape",
                title: IntatisLocalization.format(
                    "patch · %@",
                    item.files.joined(separator: ", ")),
                body: item.body,
                tint: .purple)
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
            fillsAvailableWidth: !isUser,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
                bubbleContent(title: title, body: body, isUser: isUser, tags: tags)
            }
    }

    @ViewBuilder private func bubbleContent(title: String,
                                            body: String,
                                            isUser: Bool,
                                            tags: [String]) -> some View {
        if isUser || item.isFailure {
            bubbleBody(title: title, body: body, isUser: isUser, tags: tags)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .intatisContentSurface(cornerRadius: 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(bubbleStroke(isUser: isUser), lineWidth: 1)
                }
        } else {
            bubbleBody(title: title, body: body, isUser: false, tags: tags)
                .padding(.vertical, 8)
        }
    }

    private func bubbleBody(title: String,
                            body: String,
                            isUser: Bool,
                            tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(displayTitle(title))
                    .font(.caption2.bold())
                    .foregroundStyle(isUser ? style.accent : style.tertiaryText)
                if !isUser, let timestamp = item.timestamp {
                    Text(IntatisMessageTimestampPresentation.string(for: timestamp))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(style.tertiaryText)
                }
                ForEach(tags, id: \.self) { tag in
                    tagBadge(tag)
                }
            }
            if isUser {
                if !body.isEmpty {
                    Text(body)
                        .font(.system(size: 15))
                        .foregroundStyle(style.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.attachments.isEmpty {
                    Label(
                        item.attachments.count == 1
                            ? IntatisLocalization.format(
                                "%lld attachment",
                                Int64(item.attachments.count))
                            : IntatisLocalization.format(
                                "%lld attachments",
                                Int64(item.attachments.count)),
                        systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(style.secondaryText)
                }
            } else {
                IntatisMessageContentView(
                    messageID: item.id,
                    rawText: item.body,
                    isComplete: item.complete,
                    policy: .richText,
                    style: style)
            }
            if let advice = item.recoveryAdvice {
                IntatisRecoveryAdviceView(
                    advice: advice,
                    tint: item.isFailure ? style.error : style.accent,
                    style: style)
            }
            if isUser,
               let submissionID = item.submissionID,
               let submissionStatus = item.submissionStatus {
                submissionStatusView(
                    id: submissionID,
                    status: submissionStatus,
                    failure: item.submissionFailure)
            }
        }
    }

    private func displayTitle(_ title: String) -> String {
        title == "Agent" ? "Intatis" : title
    }

    private func submissionStatusView(
        id: SubmissionID,
        status: SubmissionStatus,
        failure: SubmissionFailure?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: submissionStatusIcon(status))
                .foregroundStyle(status == .failed || status == .cancelled
                    ? style.error
                    : style.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(submissionStatusLabel(status))
                    .font(.caption2.bold())
                    .foregroundStyle(status == .failed || status == .cancelled
                        ? style.error
                        : style.secondaryText)
                if let failure {
                    Text(failure.message)
                        .font(.caption2)
                        .foregroundStyle(style.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if failure?.retryable == true, let onRetrySubmission {
                Button("Retry") { onRetrySubmission(id) }
                    .buttonStyle(.borderless)
                    .font(.caption.bold())
                    .accessibilityIdentifier("submission.\(id.rawValue).retry")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("submission.\(id.rawValue).status")
    }

    private func submissionStatusLabel(_ status: SubmissionStatus) -> String {
        switch status {
        case .queued: return IntatisLocalization.string("Queued locally")
        case .running: return IntatisLocalization.string("Running")
        case .completed: return IntatisLocalization.string("Completed")
        case .failed: return IntatisLocalization.string("Needs attention")
        case .cancelled: return IntatisLocalization.string("Cancelled")
        }
    }

    private func submissionStatusIcon(_ status: SubmissionStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private func bubbleStroke(isUser: Bool) -> Color {
        if isUser && item.isFailure { return style.error.opacity(0.48) }
        if isUser { return style.accent.opacity(0.48) }
        if item.isFailure { return style.error.opacity(0.36) }
        return .clear
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
        .intatisContentSurface(cornerRadius: 8)
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
            .overlay { Capsule().stroke(style.stroke, lineWidth: 1) }
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
                Text(title)
                    .font(.caption.bold())
                Text(notice.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .intatisContentSurface(cornerRadius: 8)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .accessibilityIdentifier("permission.resolution")
    }

    private var title: String {
        if notice.decision == .allow {
            return IntatisLocalization.format("%@ approved", notice.tool)
        }
        if notice.action == .cancelTurn {
            return IntatisLocalization.string("Turn cancelled")
        }
        switch notice.failureSource {
        case .userDenied:
            return IntatisLocalization.format("%@ call declined", notice.tool)
        case .userCancelled, .turnCancelled:
            return IntatisLocalization.string("Turn cancelled")
        case .policyDenied:
            return IntatisLocalization.format("%@ call denied by policy", notice.tool)
        case .reviewerTimedOut:
            return IntatisLocalization.string("Automatic review timed out")
        case .reviewerFailed:
            return IntatisLocalization.string("Automatic review failed")
        case .sandboxDenied:
            return IntatisLocalization.format("Sandbox denied %@", notice.tool)
        case .runtimeFailed:
            return IntatisLocalization.format("%@ runtime failed", notice.tool)
        case nil:
            return IntatisLocalization.format("%@ denied", notice.tool)
        }
    }
}

public struct PermissionCard: View {
    let permission: PendingPermission
    let onResolve: (PermissionResponseAction) -> Void

    public init(permission: PendingPermission, onResolve: @escaping (PermissionResponseAction) -> Void) {
        self.permission = permission
        self.onResolve = onResolve
    }

    private var request: PermissionRequestPayload { permission.request }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Permission needed", systemImage: "lock.shield").font(.headline)
                Spacer()
                Text(riskLabel).font(.caption.bold()).foregroundStyle(riskColor)
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
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    }
            }
            HStack {
                Spacer()
                if permission.state == .resolving {
                    ProgressView().controlSize(.small)
                    Text(request.effectiveApprovalMode == .automaticReviewer
                         ? IntatisLocalization.string("Automatic review in progress…")
                         : IntatisLocalization.string("Resolving…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if permission.state.isActionable {
                    Button("Cancel Turn") { onResolve(.cancelTurn) }
                        .accessibilityIdentifier("permission.cancel-turn")
                    Button("Decline Call") { onResolve(.decline) }
                        .accessibilityIdentifier("permission.decline-call")
                    Button("Approve Call") { onResolve(.approve) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("permission.approve-call")
                }
            }
        }
        .padding(12)
        .intatisContentSurface(cornerRadius: 10)
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

    private var riskLabel: String {
        switch request.risk {
        case .low: return IntatisLocalization.string("LOW")
        case .medium: return IntatisLocalization.string("MEDIUM")
        case .high: return IntatisLocalization.string("HIGH")
        }
    }

    private var statusText: String {
        switch permission.state {
        case .livePending:
            return IntatisLocalization.string("Waiting for your decision.")
        case .resolving:
            return request.effectiveApprovalMode == .automaticReviewer
                ? IntatisLocalization.string(
                    "The reserved permission reviewer is evaluating this call.")
                : IntatisLocalization.string("Applying your decision.")
        case .approved:
            return IntatisLocalization.string("Approved.")
        case .rejected:
            return IntatisLocalization.string("Rejected.")
        case .expired:
            return IntatisLocalization.string(
                "This approval channel expired. Rerun the task to continue.")
        case .needsRerun:
            return IntatisLocalization.string(
                "This request was restored from history. Rerun the task to continue.")
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
    let failedItems: [CodeItem]
    let style: IntatisThreadStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorHeader
                inspectorSection(IntatisLocalization.string("Plan")) {
                    inspectorRow(
                        IntatisLocalization.string("Current task"),
                        value: intatisLocalizedAgentState(agentState))
                    inspectorRow(IntatisLocalization.string("Thread events"), value: "\(itemCount)")
                    if let pending {
                        inspectorRow(
                            IntatisLocalization.string("Permission"),
                            value: pending.request.tool)
                    } else {
                        inspectorRow(
                            IntatisLocalization.string("Permission"),
                            value: IntatisLocalization.string("none pending"))
                    }
                }
                inspectorSection(IntatisLocalization.string("Workspace")) {
                    inspectorRow(IntatisLocalization.string("Root"), value: workspaceName)
                    inspectorRow(
                        IntatisLocalization.string("Git"),
                        value: IntatisLocalization.string("status only"))
                    Text("Commit, branch, PR, CI, and review workflows are deferred.")
                        .font(.caption2)
                        .foregroundStyle(style.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                inspectorSection(IntatisLocalization.string("Recent Failures")) {
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
            }
            .padding(16)
        }
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
        .intatisContentSurface(cornerRadius: 8)
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
