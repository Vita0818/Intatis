#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisConversation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct IntatisThreadStyle {
    public var primaryText: Color
    public var secondaryText: Color
    public var tertiaryText: Color
    public var accent: Color
    public var stroke: Color
    public var cardStroke: Color
    public var error: Color

    public init(primaryText: Color,
                secondaryText: Color,
                tertiaryText: Color,
                accent: Color,
                stroke: Color,
                cardStroke: Color,
                error: Color = .red) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.accent = accent
        self.stroke = stroke
        self.cardStroke = cardStroke
        self.error = error
    }

    public static func standard(_: ColorScheme) -> IntatisThreadStyle {
        let stroke = intatisPlatformSeparator
        return IntatisThreadStyle(
            primaryText: .primary,
            secondaryText: .secondary,
            tertiaryText: .secondary.opacity(0.72),
            accent: .accentColor,
            stroke: stroke,
            cardStroke: stroke,
            error: .red)
    }
}

enum IntatisThreadStackLayoutMode: Equatable {
    case eager
    case lazy

    static let eagerRowLimit = 4

    static func resolve(visibleRowCount: Int) -> Self {
        visibleRowCount <= eagerRowLimit ? .eager : .lazy
    }
}

/// A small thread does not benefit from top-level row virtualization, and a
/// single very tall row can make `LazyVStack` expose only estimated scroll
/// ranges. Larger threads retain the production lazy layout and its measured
/// interaction characteristics.
public struct IntatisAdaptiveThreadStack<Content: View>: View {
    private let visibleRowCount: Int
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat?
    private let content: Content

    public init(
        visibleRowCount: Int,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.visibleRowCount = visibleRowCount
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        switch IntatisThreadStackLayoutMode.resolve(
            visibleRowCount: visibleRowCount) {
        case .eager:
            VStack(alignment: alignment, spacing: spacing) {
                content
            }
        case .lazy:
            LazyVStack(alignment: alignment, spacing: spacing) {
                content
            }
        }
    }
}

// MARK: - System materials and Liquid Glass

private var intatisPlatformSeparator: Color {
    #if canImport(AppKit)
    return Color(nsColor: .separatorColor)
    #elseif canImport(UIKit)
    return Color(uiColor: .separator)
    #else
    return .secondary.opacity(0.28)
    #endif
}

private struct IntatisContentSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(intatisPlatformSeparator, lineWidth: 1)
            }
    }
}

private struct IntatisLiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isInteractive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(
                isInteractive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(intatisPlatformSeparator, lineWidth: 1)
            }
    }
}

private struct IntatisGlassButtonModifier: ViewModifier {
    let isProminent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder private func fallback(_ content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

public extension View {
    /// Standard Material for content-layer cards and read-only information.
    func intatisContentSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(IntatisContentSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Native Liquid Glass on current systems, with semantic Material fallback.
    func intatisLiquidGlass(cornerRadius: CGFloat = 16,
                            interactive: Bool = false) -> some View {
        modifier(IntatisLiquidGlassModifier(
            cornerRadius: cornerRadius,
            isInteractive: interactive))
    }

    /// Native glass button artwork on current systems, native bordered fallback.
    func intatisGlassButton(prominent: Bool = false) -> some View {
        modifier(IntatisGlassButtonModifier(isProminent: prominent))
    }
}

public struct IntatisGlassEffectGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil,
                @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

public struct IntatisTurnStatsSummaryView: View {
    private let stats: TurnStatsSnapshot
    private let style: IntatisThreadStyle

    public init(stats: TurnStatsSnapshot, style: IntatisThreadStyle) {
        self.stats = stats
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "speedometer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.tertiaryText)
            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(style.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .intatisContentSurface(cornerRadius: 14)
        .help(summary)
    }

    private var summary: String {
        parts.joined(separator: " · ")
    }

    private var parts: [String] {
        var values: [String] = []
        if let tokenPart {
            values.append(tokenPart)
        }
        if let totalMillis = stats.totalMillis {
            values.append(formatDuration(totalMillis))
        }
        if let ttftMillis = stats.ttftMillis {
            values.append("ttft \(formatDuration(ttftMillis))")
        }
        return values
    }

    private var tokenPart: String? {
        if let totalTokens = stats.totalTokens {
            let total = "\(formatNumber(totalTokens)) tok"
            if let promptTokens = stats.promptTokens,
               let cachedPromptTokens = stats.cachedPromptTokens,
               let completionTokens = stats.completionTokens {
                let uncachedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
                return "\(total) (\(formatNumber(uncachedPromptTokens)) input + \(formatNumber(cachedPromptTokens)) cached / \(formatNumber(completionTokens)) output)"
            }
            if let promptTokens = stats.promptTokens,
               let completionTokens = stats.completionTokens {
                return "\(total) (\(formatNumber(promptTokens)) in / \(formatNumber(completionTokens)) out)"
            }
            return total
        }

        var pieces: [String] = []
        if let promptTokens = stats.promptTokens,
           let cachedPromptTokens = stats.cachedPromptTokens {
            let uncachedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
            pieces.append("\(formatNumber(uncachedPromptTokens)) input")
            pieces.append("\(formatNumber(cachedPromptTokens)) cached")
        } else if let promptTokens = stats.promptTokens {
            pieces.append("\(formatNumber(promptTokens)) in")
        }
        if let completionTokens = stats.completionTokens {
            pieces.append("\(formatNumber(completionTokens)) out")
        }
        if let promptTokens = stats.promptTokens,
           let contextWindowTokens = stats.contextWindowTokens {
            pieces.append("ctx \(formatNumber(promptTokens))/\(formatNumber(contextWindowTokens))")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " / ")
    }

    private func formatDuration(_ millis: Int) -> String {
        if millis < 1000 {
            return "\(millis)ms"
        }
        let seconds = Double(millis) / 1000
        return seconds < 10
            ? String(format: "%.2fs", seconds)
            : String(format: "%.1fs", seconds)
    }

    private func formatNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

public struct IntatisModeTab: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

public struct IntatisModeSegmentedControl: View {
    private let tabs: [IntatisModeTab]
    @Binding private var selectionID: String
    private let style: IntatisThreadStyle

    public init(tabs: [IntatisModeTab],
                selectionID: Binding<String>,
                style: IntatisThreadStyle) {
        self.tabs = tabs
        self._selectionID = selectionID
        self.style = style
    }

    public var body: some View {
        Picker("", selection: $selectionID) {
            ForEach(tabs) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
        .tint(style.accent)
    }
}

public struct IntatisSessionHistoryItem: Identifiable, Hashable {
    public var id: SessionID
    public var title: String
    public var detail: String
    public var systemImage: String
    public var isSelected: Bool
    public var isDeleteDisabled: Bool

    public init(id: SessionID,
                title: String,
                detail: String,
                systemImage: String,
                isSelected: Bool = false,
                isDeleteDisabled: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDeleteDisabled = isDeleteDisabled
    }
}

public struct IntatisSessionHistoryList: View {
    private let title: String
    private let newTitle: String
    private let emptyTitle: String
    private let items: [IntatisSessionHistoryItem]
    private let style: IntatisThreadStyle
    private let isNewDisabled: Bool
    private let onNew: () -> Void
    private let onSelect: (SessionID) -> Void
    private let onRename: ((SessionID) -> Void)?
    private let onDelete: ((SessionID) -> Void)?

    public init(title: String,
                newTitle: String,
                emptyTitle: String,
                items: [IntatisSessionHistoryItem],
                style: IntatisThreadStyle,
                isNewDisabled: Bool = false,
                onNew: @escaping () -> Void,
                onSelect: @escaping (SessionID) -> Void,
                onRename: ((SessionID) -> Void)? = nil,
                onDelete: ((SessionID) -> Void)? = nil) {
        self.title = title
        self.newTitle = newTitle
        self.emptyTitle = emptyTitle
        self.items = items
        self.style = style
        self.isNewDisabled = isNewDisabled
        self.onNew = onNew
        self.onSelect = onSelect
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .controlSize(.small)
                .intatisGlassButton()
                .disabled(isNewDisabled)
                .help(newTitle)
            }

            if items.isEmpty {
                Text(emptyTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(items) { item in
                            Button {
                                onSelect(item.id)
                            } label: {
                                IntatisSessionHistoryRow(item: item, style: style)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let onRename {
                                    Button {
                                        onRename(item.id)
                                    } label: {
                                        Label("Rename…", systemImage: "pencil")
                                    }
                                }
                                if let onDelete {
                                    if onRename != nil {
                                        Divider()
                                    }
                                    Button(role: .destructive) {
                                        onDelete(item.id)
                                    } label: {
                                        Label("Delete…", systemImage: "trash")
                                    }
                                    .disabled(item.isDeleteDisabled)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct IntatisSessionHistoryRow: View {
    let item: IntatisSessionHistoryItem
    let style: IntatisThreadStyle

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.isSelected ? style.accent : style.tertiaryText)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: item.isSelected ? .semibold : .medium))
                    .foregroundStyle(item.isSelected ? style.primaryText : style.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(style.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.isSelected ? style.accent.opacity(0.42) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

public struct IntatisRecoveryAdviceView: View {
    private let advice: RuntimeRecoveryAdvice
    private let tint: Color
    private let style: IntatisThreadStyle

    public init(advice: RuntimeRecoveryAdvice,
                tint: Color,
                style: IntatisThreadStyle) {
        self.advice = advice
        self.tint = tint
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(advice.title, systemImage: advice.retryable ? "arrow.clockwise" : "info.circle")
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(advice.detail)
                .font(.caption)
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

public struct IntatisThreadComposerSecondaryAction {
    public var systemImage: String
    public var help: String
    public var isBusy: Bool
    public var isDisabled: Bool
    public var action: () -> Void

    public init(systemImage: String,
                help: String,
                isBusy: Bool = false,
                isDisabled: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.action = action
    }
}

public struct IntatisThreadComposer: View {
    @Binding private var input: String
    private let placeholder: String
    private let canSend: Bool
    private let isInputDisabled: Bool
    private let style: IntatisThreadStyle
    private let secondaryAction: IntatisThreadComposerSecondaryAction?
    private let accessory: AnyView?
    private let onSend: () -> Void
    @FocusState private var focused: Bool

    public init(placeholder: String,
                input: Binding<String>,
                canSend: Bool,
                isInputDisabled: Bool,
                style: IntatisThreadStyle,
                secondaryAction: IntatisThreadComposerSecondaryAction? = nil,
                onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._input = input
        self.canSend = canSend
        self.isInputDisabled = isInputDisabled
        self.style = style
        self.secondaryAction = secondaryAction
        self.accessory = nil
        self.onSend = onSend
    }

    public init<Accessory: View>(placeholder: String,
                                 input: Binding<String>,
                                 canSend: Bool,
                                 isInputDisabled: Bool,
                                 style: IntatisThreadStyle,
                                 secondaryAction: IntatisThreadComposerSecondaryAction? = nil,
                                 @ViewBuilder accessory: () -> Accessory,
                                 onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._input = input
        self.canSend = canSend
        self.isInputDisabled = isInputDisabled
        self.style = style
        self.secondaryAction = secondaryAction
        self.accessory = AnyView(accessory())
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let accessory {
                accessory
            }

            IntatisGlassEffectGroup(spacing: 10) {
                composerControls
            }
        }
    }

    private var composerControls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            inputControl
            sendButton
        }
    }

    private var inputControl: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit {
                    guard canSend else { return }
                    onSend()
                }
                .disabled(isInputDisabled)
                .accessibilityIdentifier("thread.composer.input")

            if let secondaryAction {
                Button(action: secondaryAction.action) {
                    if secondaryAction.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: secondaryAction.systemImage)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(secondaryAction.isDisabled ? .tertiary : .primary)
                    }
                }
                .buttonStyle(.plain)
                .help(secondaryAction.help)
                .disabled(secondaryAction.isDisabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .intatisLiquidGlass(cornerRadius: 22, interactive: true)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .controlSize(.large)
        .intatisGlassButton(prominent: true)
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("thread.composer.send")
    }

}

public struct IntatisThreadContentLayout {
    public let rawWidth: CGFloat
    private let maxContentWidth: CGFloat
    private let maxMessageWidth: CGFloat

    public init(rawWidth: CGFloat,
                contentMaxWidth: CGFloat = 940,
                messageMaxWidth: CGFloat = 640) {
        self.rawWidth = rawWidth
        self.maxContentWidth = contentMaxWidth
        self.maxMessageWidth = messageMaxWidth
    }

    private var width: CGFloat { max(rawWidth, 1) }

    public var isCompact: Bool { width < 700 }

    public var horizontalPadding: CGFloat {
        if width < 380 { return 10 }
        if width < 500 { return 14 }
        if width < 760 { return 20 }
        return 30
    }

    public var contentMaxWidth: CGFloat { maxContentWidth }

    public var contentWidth: CGFloat {
        min(maxContentWidth, max(1, width - (horizontalPadding * 2)))
    }

    public var messageMaxWidth: CGFloat {
        let available = contentWidth - messageGutter
        return min(maxMessageWidth, max(1, available))
    }

    public var messageGutter: CGFloat {
        if width < 420 { return 0 }
        if width < 560 { return 8 }
        if width < 760 { return 24 }
        return 48
    }
}

public struct IntatisThreadBubbleRow<Content: View>: View {
    private let isTrailing: Bool
    private let rowWidth: CGFloat?
    private let maxWidth: CGFloat
    private let gutter: CGFloat
    private let content: Content

    public init(isTrailing: Bool,
                rowWidth: CGFloat? = nil,
                maxWidth: CGFloat,
                gutter: CGFloat,
                @ViewBuilder content: () -> Content) {
        self.isTrailing = isTrailing
        self.rowWidth = rowWidth
        self.maxWidth = maxWidth
        self.gutter = gutter
        self.content = content()
    }

    public var body: some View {
        row
            .frame(width: rowWidth, alignment: isTrailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
    }

    private var row: some View {
        HStack(spacing: 0) {
            if isTrailing {
                Spacer(minLength: gutter)
            }

            content
                .frame(maxWidth: maxWidth, alignment: isTrailing ? .trailing : .leading)
                .layoutPriority(1)

            if !isTrailing {
                Spacer(minLength: gutter)
            }
        }
    }
}

/// Shared first-token waiting state for Code and Cowork threads.
///
/// The caller decides when a model response is pending; this view only owns the
/// visual treatment so both workspace modes stay consistent.
public struct IntatisThreadThinkingRow: View {
    private let layout: IntatisThreadContentLayout
    private let style: IntatisThreadStyle
    private let label: String

    public init(layout: IntatisThreadContentLayout,
                style: IntatisThreadStyle,
                label: String = "Thinking…") {
        self.layout = layout
        self.style = style
        self.label = label
    }

    public var body: some View {
        IntatisThreadBubbleRow(
            isTrailing: false,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(style.accent)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking")
    }
}

enum IntatisThreadActivity {
    /// Returns true only while the thread is waiting for the next visible model
    /// response. Informational bookkeeping events are ignored, while streamed
    /// text and tool calls count as visible output.
    static func isAwaitingModelOutput(items: [CodeItem],
                                      isWorking: Bool,
                                      permissionBlocksResponse: Bool) -> Bool {
        guard isWorking, !permissionBlocksResponse else { return false }

        for item in items.reversed() {
            switch item.kind {
            case .note:
                continue
            case .user, .toolResult:
                return true
            case .agent:
                return item.body.isEmpty && !item.complete
            case .toolCall, .patch, .error, .agentToAgent:
                return false
            }
        }
        return true
    }
}

struct IntatisThreadHeaderAction {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    init(title: String,
         systemImage: String,
         isDisabled: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.action = action
    }
}

struct IntatisWorkspaceThreadHeader: View {
    let title: String
    let subtitle: String
    let style: IntatisThreadStyle
    let actions: [IntatisThreadHeaderAction]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                titleBlock
                Spacer(minLength: 12)
                actionRow
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                actionRow
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(style.primaryText)
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(style.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actionRow: some View {
        if !actions.isEmpty {
            IntatisGlassEffectGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action: action.action) {
                            Label(action.title, systemImage: action.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .intatisGlassButton()
                        .disabled(action.isDisabled)
                    }
                }
            }
        }
    }
}
#endif
