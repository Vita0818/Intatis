#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisConversation

public struct IntatisThreadStyle {
    public var primaryText: Color
    public var secondaryText: Color
    public var tertiaryText: Color
    public var accent: Color
    public var accentSoft: Color
    public var surface: Color
    public var stroke: Color
    public var userBubble: Color
    public var assistantBubble: Color
    public var cardSurface: Color
    public var cardStroke: Color
    public var warningSurface: Color
    public var warningStroke: Color
    public var error: Color
    public var material: Material

    public init(primaryText: Color,
                secondaryText: Color,
                tertiaryText: Color,
                accent: Color,
                accentSoft: Color,
                surface: Color,
                stroke: Color,
                userBubble: Color,
                assistantBubble: Color,
                cardSurface: Color,
                cardStroke: Color,
                warningSurface: Color,
                warningStroke: Color,
                error: Color = .red,
                material: Material = .ultraThinMaterial) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.accent = accent
        self.accentSoft = accentSoft
        self.surface = surface
        self.stroke = stroke
        self.userBubble = userBubble
        self.assistantBubble = assistantBubble
        self.cardSurface = cardSurface
        self.cardStroke = cardStroke
        self.warningSurface = warningSurface
        self.warningStroke = warningStroke
        self.error = error
        self.material = material
    }

    public static func standard(_ scheme: ColorScheme) -> IntatisThreadStyle {
        let surface = scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : .white
        return IntatisThreadStyle(
            primaryText: .primary,
            secondaryText: .secondary,
            tertiaryText: .secondary.opacity(0.72),
            accent: .accentColor,
            accentSoft: .accentColor.opacity(0.16),
            surface: surface,
            stroke: .secondary.opacity(scheme == .dark ? 0.25 : 0.16),
            userBubble: .accentColor.opacity(scheme == .dark ? 0.18 : 0.12),
            assistantBubble: surface.opacity(scheme == .dark ? 0.30 : 0.70),
            cardSurface: surface.opacity(scheme == .dark ? 0.26 : 0.62),
            cardStroke: .secondary.opacity(scheme == .dark ? 0.22 : 0.14),
            warningSurface: .yellow.opacity(scheme == .dark ? 0.14 : 0.10),
            warningStroke: .yellow.opacity(0.38))
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
        .background(style.cardSurface.opacity(0.72), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(style.cardStroke.opacity(0.75), lineWidth: 1)
        }
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
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                Button {
                    selectionID = tab.id
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(selectionID == tab.id ? style.accent : style.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectionID == tab.id ? style.accentSoft : Color.clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(4)
        .background(style.cardSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(style.cardStroke.opacity(0.85), lineWidth: 1)
        }
    }
}

public struct IntatisSessionHistoryItem: Identifiable, Hashable {
    public var id: SessionID
    public var title: String
    public var detail: String
    public var systemImage: String
    public var isSelected: Bool

    public init(id: SessionID,
                title: String,
                detail: String,
                systemImage: String,
                isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isSelected = isSelected
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

    public init(title: String,
                newTitle: String,
                emptyTitle: String,
                items: [IntatisSessionHistoryItem],
                style: IntatisThreadStyle,
                isNewDisabled: Bool = false,
                onNew: @escaping () -> Void,
                onSelect: @escaping (SessionID) -> Void) {
        self.title = title
        self.newTitle = newTitle
        self.emptyTitle = emptyTitle
        self.items = items
        self.style = style
        self.isNewDisabled = isNewDisabled
        self.onNew = onNew
        self.onSelect = onSelect
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
                        .foregroundStyle(isNewDisabled ? style.tertiaryText : style.accent)
                        .frame(width: 24, height: 24)
                        .background(style.cardSurface.opacity(0.78), in: Circle())
                }
                .buttonStyle(.plain)
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
        .background(item.isSelected ? style.accentSoft : style.cardSurface.opacity(0.30),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(style.primaryText)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(onSend)
                        .disabled(isInputDisabled)

                    if let secondaryAction {
                        Button(action: secondaryAction.action) {
                            if secondaryAction.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: secondaryAction.systemImage)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(secondaryAction.isDisabled ? style.tertiaryText : style.accent)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(secondaryAction.help)
                        .disabled(secondaryAction.isDisabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background {
                    Capsule(style: .continuous)
                        .fill(style.surface.opacity(0.44))
                }
                .background(style.material, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(style.stroke.opacity(0.82), lineWidth: 1)
                }

                Button(action: onSend) {
                    ZStack {
                        Circle()
                            .fill(canSend ? AnyShapeStyle(style.accent)
                                          : AnyShapeStyle(style.surface.opacity(0.50)))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canSend ? .white : style.tertiaryText)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
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
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action: action.action) {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(action.isDisabled)
                }
            }
        }
    }
}
#endif
