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

/// Formats the stable event time shown beside an assistant or agent name.
/// The thresholds are rolling durations; the rendered value follows the
/// user's current locale, calendar, time zone, and 12/24-hour preference.
public enum IntatisMessageTimestampPresentation {
    private static let oneDay: TimeInterval = 24 * 60 * 60
    private static let oneWeek: TimeInterval = 7 * oneDay

    public static func string(for timestamp: Date,
                              relativeTo referenceDate: Date = Date()) -> String {
        let age = max(0, referenceDate.timeIntervalSince(timestamp))
        if age < oneDay {
            return timeFormatter.string(from: timestamp)
        }
        if age < oneWeek {
            return weekdayTimeFormatter.string(from: timestamp)
        }
        return dateTimeFormatter.string(from: timestamp)
    }

    private static func formatter(configure: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        configure(formatter)
        return formatter
    }

    private static let timeFormatter = formatter {
        $0.dateStyle = .none
        $0.timeStyle = .short
    }

    private static let weekdayTimeFormatter = formatter {
        $0.setLocalizedDateFormatFromTemplate("EEEEjm")
    }

    private static let dateTimeFormatter = formatter {
        $0.dateStyle = .medium
        $0.timeStyle = .short
    }
}

/// Window-local identity for one visible thread presentation. This is never a
/// runtime key and is never persisted; it only scopes SwiftUI identity,
/// bottom anchors, and cancellable UI work.
public struct IntatisThreadPresentationScope: Hashable, Sendable {
    public let kind: String
    public let sessionID: String

    public init(kind: SessionKind, sessionID: SessionID) {
        self.kind = kind.rawValue
        self.sessionID = sessionID.rawValue
    }

    public init(kind: String, sessionID: String) {
        self.kind = kind
        self.sessionID = sessionID
    }
}

public struct IntatisThreadBottomAnchorID: Hashable, Sendable {
    public let scope: IntatisThreadPresentationScope

    public init(scope: IntatisThreadPresentationScope) {
        self.scope = scope
    }
}

enum IntatisThreadScrollReason: Equatable, Sendable {
    case initialRestore
    case liveUpdate
    case completion
    case richHeightCorrection

    var requiresBottomFollowing: Bool {
        self != .initialRestore
    }

    var isAnimated: Bool {
        self == .completion
    }
}

struct IntatisThreadScrollRequest: Equatable, Sendable {
    let scope: IntatisThreadPresentationScope
    let generation: UInt64
    let reason: IntatisThreadScrollReason
    let animated: Bool
    let wasBottomFollowing: Bool
}

struct IntatisThreadScrollSignature: Equatable, Sendable {
    let visibleItemCount: Int
    let lastItemID: String?
    let lastBodyUTF8Count: Int
    let lastItemComplete: Bool
    let isWorking: Bool
    let showsThinkingIndicator: Bool
}

struct IntatisThreadScrollGeometry: Equatable, Sendable {
    let isAtBottom: Bool
    let contentHeight: CGFloat

    static func measure(
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        contentHeight: CGFloat,
        tolerance: CGFloat = 24
    ) -> Self {
        Self(
            isAtBottom: contentOffsetY
                + containerHeight
                + bottomInset
                >= contentHeight - tolerance,
            contentHeight: contentHeight)
    }

    func hasMaterialHeightChange(
        from previous: Self,
        epsilon: CGFloat = 1
    ) -> Bool {
        abs(contentHeight - previous.contentHeight) >= epsilon
    }
}

/// One coordinator belongs to one visible SwiftUI thread subtree. It owns at
/// most one pending task, invalidates generations on scope changes, and keeps
/// user-driven scroll position separate from content-height movement.
@MainActor
final class IntatisThreadScrollCoordinator: ObservableObject {
    private(set) var activeScope: IntatisThreadPresentationScope?
    private(set) var generation: UInt64 = 0
    private(set) var pendingRequest: IntatisThreadScrollRequest?
    private(set) var executionCount = 0
    private(set) var cancellationCount = 0
    private(set) var staleRejectionCount = 0
    private(set) var isFollowingBottom = true

    private var pendingTask: Task<Void, Never>?
    private var isUserInteracting = false
    private var latestIsAtBottom = true
    private var lastRichCorrectionContentHeight: CGFloat = 0
    private var isAdjustingShrinkBaseline = false
    private var didCompleteShrinkRecovery = false

    func activate(scope: IntatisThreadPresentationScope) {
        guard activeScope != scope else { return }
        invalidatePending()
        activeScope = scope
        isFollowingBottom = true
        latestIsAtBottom = true
        isUserInteracting = false
        lastRichCorrectionContentHeight = 0
        isAdjustingShrinkBaseline = false
        didCompleteShrinkRecovery = false
    }

    func deactivate(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope else { return }
        invalidatePending()
        activeScope = nil
        isUserInteracting = false
    }

    /// Starts a new raw-content or width layout epoch. A single epoch may
    /// recover from one shrink→regrow cycle, but an oscillating native layout
    /// cannot reopen that recovery window after the first corrective scroll.
    func beginLayoutEpoch(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope else { return }
        invalidatePending()
        lastRichCorrectionContentHeight = 0
        isAdjustingShrinkBaseline = false
        didCompleteShrinkRecovery = false
    }

    func updateBottomProximity(
        _ isAtBottom: Bool,
        contentHeight: CGFloat? = nil,
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope else { return }
        latestIsAtBottom = isAtBottom
        if isAtBottom, let contentHeight {
            if lastRichCorrectionContentHeight == 0 {
                lastRichCorrectionContentHeight = contentHeight
            } else if contentHeight < lastRichCorrectionContentHeight - 1,
                      !didCompleteShrinkRecovery {
                // Keep following a continuing shrink to its lowest observed
                // bottom. The first subsequent regrowth closes this recovery
                // window for the rest of the explicit layout epoch.
                lastRichCorrectionContentHeight = contentHeight
                isAdjustingShrinkBaseline = true
            } else if contentHeight > lastRichCorrectionContentHeight {
                lastRichCorrectionContentHeight = contentHeight
            }
        }
        if isUserInteracting, isAtBottom {
            isFollowingBottom = true
        }
    }

    func userInteractionDidBegin(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope else { return }
        isUserInteracting = true
        invalidatePending()
    }

    func userInteractionDidEnd(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope, isUserInteracting else { return }
        isUserInteracting = false
        isFollowingBottom = latestIsAtBottom
        if !isFollowingBottom {
            invalidatePending()
        }
    }

    @discardableResult
    func request(
        scope: IntatisThreadPresentationScope,
        reason: IntatisThreadScrollReason,
        perform: @escaping @MainActor (IntatisThreadScrollRequest) -> Void
    ) -> IntatisThreadScrollRequest? {
        guard activeScope == scope else {
            staleRejectionCount += 1
            return nil
        }
        guard !reason.requiresBottomFollowing ||
                (!isUserInteracting && isFollowingBottom) else {
            return nil
        }

        if pendingTask != nil {
            pendingTask?.cancel()
            cancellationCount += 1
        }
        generation &+= 1
        let request = IntatisThreadScrollRequest(
            scope: scope,
            generation: generation,
            reason: reason,
            animated: reason.isAnimated,
            wasBottomFollowing: isFollowingBottom)
        pendingRequest = request
        pendingTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            guard self.activeScope == request.scope,
                  self.generation == request.generation,
                  self.pendingRequest == request else {
                self.staleRejectionCount += 1
                return
            }
            guard !request.reason.requiresBottomFollowing ||
                    (!self.isUserInteracting && self.isFollowingBottom) else {
                self.staleRejectionCount += 1
                self.pendingRequest = nil
                self.pendingTask = nil
                return
            }
            self.pendingRequest = nil
            self.pendingTask = nil
            self.executionCount += 1
            perform(request)
        }
        return request
    }

    @discardableResult
    func requestRichHeightCorrection(
        scope: IntatisThreadPresentationScope,
        contentHeight: CGFloat,
        perform: @escaping @MainActor (IntatisThreadScrollRequest) -> Void
    ) -> IntatisThreadScrollRequest? {
        guard contentHeight >= lastRichCorrectionContentHeight + 1 else {
            return nil
        }
        guard let request = request(
            scope: scope,
            reason: .richHeightCorrection,
            perform: perform
        ) else {
            return nil
        }
        lastRichCorrectionContentHeight = contentHeight
        if isAdjustingShrinkBaseline {
            isAdjustingShrinkBaseline = false
            didCompleteShrinkRecovery = true
        }
        return request
    }

    private func invalidatePending() {
        if pendingTask != nil {
            pendingTask?.cancel()
            cancellationCount += 1
        }
        pendingTask = nil
        pendingRequest = nil
        generation &+= 1
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

    /// Shared geometry for compact icon-only actions. The visual treatment is
    /// still supplied by SwiftUI's native glass/bordered button styles.
    func intatisCompactIconButton(prominent: Bool = false) -> some View {
        labelStyle(.iconOnly)
            .controlSize(.regular)
            .buttonBorderShape(.circle)
            .intatisGlassButton(prominent: prominent)
    }

    /// A native Menu owns selection and keyboard behavior while its label
    /// supplies the same interactive Liquid Glass surface as the composer.
    func intatisComposerSelectionMenu() -> some View {
        buttonStyle(.plain)
    }

    /// Shared 40-point capsule geometry for the model/profile Menu label.
    func intatisComposerSelectionLabel() -> some View {
        padding(
            .horizontal,
            IntatisComposerControlMetrics.selectionHorizontalPadding)
            .frame(
                height: IntatisComposerControlMetrics.controlHeight,
                alignment: .leading)
            .frame(
                maxWidth: IntatisComposerControlMetrics.selectionMaxWidth,
                alignment: .leading)
            .intatisLiquidGlass(
                cornerRadius: IntatisComposerControlMetrics.controlHeight / 2,
                interactive: true)
    }

    /// Gives native compact glass buttons a stable visual diameter instead of
    /// leaving their size to each SF Symbol's intrinsic bounds.
    func intatisComposerIconLabel() -> some View {
        font(.system(size: 15, weight: .semibold))
            .frame(
                width: IntatisComposerControlMetrics.iconLabelExtent,
                height: IntatisComposerControlMetrics.iconLabelExtent)
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
            values.append(IntatisLocalization.format(
                "ttft %@",
                formatDuration(ttftMillis)))
        }
        return values
    }

    private var tokenPart: String? {
        if let totalTokens = stats.totalTokens {
            let total = IntatisLocalization.format(
                "%@ tok",
                formatNumber(totalTokens))
            if let promptTokens = stats.promptTokens,
               let cachedPromptTokens = stats.cachedPromptTokens,
               let completionTokens = stats.completionTokens {
                let uncachedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
                return IntatisLocalization.format(
                    "%@ (%@ input + %@ cached / %@ output)",
                    total,
                    formatNumber(uncachedPromptTokens),
                    formatNumber(cachedPromptTokens),
                    formatNumber(completionTokens))
            }
            if let promptTokens = stats.promptTokens,
               let completionTokens = stats.completionTokens {
                return IntatisLocalization.format(
                    "%@ (%@ in / %@ out)",
                    total,
                    formatNumber(promptTokens),
                    formatNumber(completionTokens))
            }
            return total
        }

        var pieces: [String] = []
        if let promptTokens = stats.promptTokens,
           let cachedPromptTokens = stats.cachedPromptTokens {
            let uncachedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
            pieces.append(IntatisLocalization.format(
                "%@ input",
                formatNumber(uncachedPromptTokens)))
            pieces.append(IntatisLocalization.format(
                "%@ cached",
                formatNumber(cachedPromptTokens)))
        } else if let promptTokens = stats.promptTokens {
            pieces.append(IntatisLocalization.format(
                "%@ in",
                formatNumber(promptTokens)))
        }
        if let completionTokens = stats.completionTokens {
            pieces.append(IntatisLocalization.format(
                "%@ out",
                formatNumber(completionTokens)))
        }
        if let promptTokens = stats.promptTokens,
           let contextWindowTokens = stats.contextWindowTokens {
            pieces.append(IntatisLocalization.format(
                "ctx %@/%@",
                formatNumber(promptTokens),
                formatNumber(contextWindowTokens)))
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

/// Low-noise, composer-local usage metadata. Unlike action controls, it is
/// deliberately not glass-backed and occupies the trailing side of the
/// composer's read-only first row.
public struct IntatisComposerUsageStrip: View {
    private let stats: TurnStatsSnapshot?
    private let style: IntatisThreadStyle

    public init(stats: TurnStatsSnapshot?, style: IntatisThreadStyle) {
        self.stats = stats
        self.style = style
    }

    @ViewBuilder public var body: some View {
        if let stats, stats.hasDisplayableMetrics {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    if let contextValue = contextValue(for: stats) {
                        metric(IntatisLocalization.string("Context"), value: contextValue)
                    }
                    if let promptTokens = stats.promptTokens {
                        let cachedTokens = stats.cachedPromptTokens ?? 0
                        metric(
                            IntatisLocalization.string("Input"),
                            value: formatNumber(max(promptTokens - cachedTokens, 0)))
                    }
                    if let cachedPromptTokens = stats.cachedPromptTokens {
                        metric(
                            IntatisLocalization.string("Cached"),
                            value: formatNumber(cachedPromptTokens))
                    }
                    if let completionTokens = stats.completionTokens {
                        metric(
                            IntatisLocalization.string("Output"),
                            value: formatNumber(completionTokens))
                    }
                    if stats.promptTokens == nil,
                       stats.completionTokens == nil,
                       let totalTokens = stats.totalTokens {
                        metric(
                            IntatisLocalization.string("Total"),
                            value: formatNumber(totalTokens))
                    }
                    if let totalMillis = stats.totalMillis {
                        metric(
                            IntatisLocalization.string("Time"),
                            value: formatDuration(totalMillis))
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(style.tertiaryText)
            Text(value)
                .foregroundStyle(style.secondaryText)
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private func contextValue(for stats: TurnStatsSnapshot) -> String? {
        if let promptTokens = stats.promptTokens,
           let contextWindowTokens = stats.contextWindowTokens {
            return "\(formatNumber(promptTokens)) / \(formatNumber(contextWindowTokens))"
        }
        if let promptTokens = stats.promptTokens {
            return formatNumber(promptTokens)
        }
        if let contextWindowTokens = stats.contextWindowTokens {
            return formatNumber(contextWindowTokens)
        }
        return nil
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
                    Label(newTitle, systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .intatisGlassButton()
                .disabled(isNewDisabled)
                .help(newTitle)
                .accessibilityLabel(newTitle)
                .accessibilityIdentifier("sidebar.session.new")
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
                            .accessibilityIdentifier(
                                "sidebar.session.\(item.id.rawValue)")
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
            Label(
                IntatisLocalization.string(advice.title),
                systemImage: advice.retryable ? "arrow.clockwise" : "info.circle")
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(IntatisLocalization.string(advice.detail))
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

public enum IntatisComposerControlMetrics {
    public static let controlHeight: CGFloat = 40
    public static let iconLabelExtent: CGFloat = 32
    public static let selectionMaxWidth: CGFloat = 220
    public static let selectionHorizontalPadding: CGFloat = 12
    public static let rowSpacing: CGFloat = 8
    public static let inputHorizontalPadding: CGFloat = 14
    public static let inputVerticalPadding: CGFloat = 9
    public static let inputCornerRadius: CGFloat = controlHeight / 2
}

public struct IntatisThreadComposer: View {
    @Binding private var input: String
    private let placeholder: String
    private let canSend: Bool
    private let isInputDisabled: Bool
    private let style: IntatisThreadStyle
    private let secondaryAction: IntatisThreadComposerSecondaryAction?
    private let stopAction: IntatisThreadComposerSecondaryAction?
    private let accessory: AnyView?
    private let leadingAccessory: AnyView?
    private let inputLeadingAccessory: AnyView?
    private let onSend: () -> Void
    @FocusState private var focused: Bool

    public init(placeholder: String,
                input: Binding<String>,
                canSend: Bool,
                isInputDisabled: Bool,
                style: IntatisThreadStyle,
                secondaryAction: IntatisThreadComposerSecondaryAction? = nil,
                leadingAccessory: AnyView? = nil,
                inputLeadingAccessory: AnyView? = nil,
                stopAction: IntatisThreadComposerSecondaryAction? = nil,
                onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._input = input
        self.canSend = canSend
        self.isInputDisabled = isInputDisabled
        self.style = style
        self.secondaryAction = secondaryAction
        self.stopAction = stopAction
        self.accessory = nil
        self.leadingAccessory = leadingAccessory
        self.inputLeadingAccessory = inputLeadingAccessory
        self.onSend = onSend
    }

    public init<Accessory: View>(placeholder: String,
                                 input: Binding<String>,
                                 canSend: Bool,
                                 isInputDisabled: Bool,
                                 style: IntatisThreadStyle,
                                 secondaryAction: IntatisThreadComposerSecondaryAction? = nil,
                                 leadingAccessory: AnyView? = nil,
                                 inputLeadingAccessory: AnyView? = nil,
                                 stopAction: IntatisThreadComposerSecondaryAction? = nil,
                                 @ViewBuilder accessory: () -> Accessory,
                                 onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._input = input
        self.canSend = canSend
        self.isInputDisabled = isInputDisabled
        self.style = style
        self.secondaryAction = secondaryAction
        self.stopAction = stopAction
        self.accessory = AnyView(accessory())
        self.leadingAccessory = leadingAccessory
        self.inputLeadingAccessory = inputLeadingAccessory
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topAccessoryRow

            IntatisGlassEffectGroup(spacing: 10) {
                composerControls
            }
        }
    }

    @ViewBuilder private var topAccessoryRow: some View {
        if leadingAccessory != nil || accessory != nil {
            HStack(alignment: .center, spacing: 12) {
                if let leadingAccessory {
                    leadingAccessory
                        .controlSize(.regular)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if leadingAccessory != nil, accessory != nil {
                    Spacer(minLength: 12)
                }

                if let accessory {
                    accessory
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: IntatisComposerControlMetrics.controlHeight,
                alignment: .center)
        }
    }

    private var composerControls: some View {
        HStack(
            alignment: .bottom,
            spacing: IntatisComposerControlMetrics.rowSpacing
        ) {
            inputLeadingControls
            inputControl
            if let stopAction {
                stopButton(stopAction)
            } else {
                sendButton
            }
        }
    }

    @ViewBuilder private var inputLeadingControls: some View {
        if inputLeadingAccessory != nil || secondaryAction != nil {
            HStack(
                alignment: .center,
                spacing: IntatisComposerControlMetrics.rowSpacing
            ) {
                if let inputLeadingAccessory {
                    inputLeadingAccessory
                        .controlSize(.regular)
                }
                if let secondaryAction {
                    compactActionButton(secondaryAction)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var inputControl: some View {
        TextField(placeholder, text: $input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .lineLimit(1...6)
            .focused($focused)
            .onSubmit {
                guard stopAction == nil, canSend else { return }
                onSend()
            }
            .disabled(isInputDisabled)
            .accessibilityIdentifier("thread.composer.input")
            .padding(.horizontal, IntatisComposerControlMetrics.inputHorizontalPadding)
            .padding(.vertical, IntatisComposerControlMetrics.inputVerticalPadding)
            .frame(
                minHeight: IntatisComposerControlMetrics.controlHeight,
                alignment: .center)
            .intatisLiquidGlass(
                cornerRadius: IntatisComposerControlMetrics.inputCornerRadius,
                interactive: true)
    }

    private func compactActionButton(
        _ action: IntatisThreadComposerSecondaryAction
    ) -> some View {
        Button(action: action.action) {
            Label(action.help, systemImage: action.systemImage)
                .intatisComposerIconLabel()
                .opacity(action.isBusy ? 0 : 1)
                .overlay {
                    if action.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
        }
        .intatisCompactIconButton()
        .help(action.help)
        .accessibilityLabel(action.help)
        .disabled(action.isDisabled)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Label(IntatisLocalization.string("Send"), systemImage: "arrow.up")
                .intatisComposerIconLabel()
        }
        .intatisCompactIconButton(prominent: true)
        .disabled(!canSend)
        .accessibilityLabel(IntatisLocalization.string("Send"))
        .accessibilityIdentifier("thread.composer.send")
    }

    private func stopButton(
        _ action: IntatisThreadComposerSecondaryAction
    ) -> some View {
        Button(role: .destructive, action: action.action) {
            Label(
                IntatisLocalization.string("Stop"),
                systemImage: action.systemImage)
                .intatisComposerIconLabel()
                .opacity(action.isBusy ? 0 : 1)
                .overlay {
                    if action.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
        }
        .intatisCompactIconButton(prominent: true)
        .tint(.red)
        .help(action.help)
        .disabled(action.isDisabled)
        .accessibilityLabel(IntatisLocalization.string("Stop"))
        .accessibilityIdentifier("thread.composer.stop")
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

enum IntatisThreadBubbleWidthPolicy: Equatable {
    case fullWidthLeading
    case constrained(
        isTrailing: Bool,
        maxWidth: CGFloat,
        gutter: CGFloat)

    static func resolve(
        isTrailing: Bool,
        fillsAvailableWidth: Bool,
        maxWidth: CGFloat,
        gutter: CGFloat
    ) -> Self {
        if fillsAvailableWidth, !isTrailing {
            return .fullWidthLeading
        }
        return .constrained(
            isTrailing: isTrailing,
            maxWidth: maxWidth,
            gutter: gutter)
    }
}

public struct IntatisThreadBubbleRow<Content: View>: View {
    private let isTrailing: Bool
    private let fillsAvailableWidth: Bool
    private let rowWidth: CGFloat?
    private let maxWidth: CGFloat
    private let gutter: CGFloat
    private let content: Content

    public init(isTrailing: Bool,
                fillsAvailableWidth: Bool = false,
                rowWidth: CGFloat? = nil,
                maxWidth: CGFloat,
                gutter: CGFloat,
                @ViewBuilder content: () -> Content) {
        self.isTrailing = isTrailing
        self.fillsAvailableWidth = fillsAvailableWidth
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

    @ViewBuilder private var row: some View {
        switch IntatisThreadBubbleWidthPolicy.resolve(
            isTrailing: isTrailing,
            fillsAvailableWidth: fillsAvailableWidth,
            maxWidth: maxWidth,
            gutter: gutter
        ) {
        case .fullWidthLeading:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        case let .constrained(isTrailing, maxWidth, gutter):
            HStack(spacing: 0) {
                if isTrailing {
                    Spacer(minLength: gutter)
                }
                content
                    .frame(
                        maxWidth: maxWidth,
                        alignment: isTrailing ? .trailing : .leading)
                    .layoutPriority(1)
                if !isTrailing {
                    Spacer(minLength: gutter)
                }
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
    private let phaseID: String

    public init(layout: IntatisThreadContentLayout,
                style: IntatisThreadStyle,
                label: String = IntatisLocalization.string("Thinking…"),
                phaseID: String = "thinking") {
        self.layout = layout
        self.style = style
        self.label = label
        self.phaseID = phaseID
    }

    public var body: some View {
        IntatisThreadBubbleRow(
            isTrailing: false,
            fillsAvailableWidth: true,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(style.accent)
                IntatisThinkingElapsedLabel(
                    label: label,
                    phaseID: phaseID)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A phase-local elapsed clock for the visible first-token waiting state.
/// Removing the Thinking row destroys this state, so a later waiting phase
/// starts again from zero without adding protocol or EventLog fields.
public struct IntatisThinkingElapsedLabel: View {
    private let label: String
    private let phaseID: String
    @State private var startedAt = Date()

    public init(
        label: String = IntatisLocalization.string("Thinking…"),
        phaseID: String = "thinking"
    ) {
        self.label = label
        self.phaseID = phaseID
    }

    public var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(
                0,
                Int(context.date.timeIntervalSince(startedAt)))
            let text = IntatisLocalization.format(
                "%llds %@",
                Int64(elapsed),
                label)
            Text(text)
                .monospacedDigit()
                .accessibilityLabel(text)
        }
        .onChange(of: phaseID) { _, _ in
            startedAt = Date()
        }
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
