//
//  IntatisChatScreen.swift
//  IntatisMac
//
//  The fully restyled Chat surface (the vertical slice): page header, message
//  bubbles (user = warm champagne tint, assistant = neutral glass), an empty
//  greeting, and a glass composer with a gold send button. Plus the Settings panel.
//

#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisSharedUI

struct IntatisMacScreenLayout {
    let rawWidth: CGFloat

    private var width: CGFloat { max(rawWidth, 1) }
    private var threadLayout: IntatisThreadContentLayout {
        IntatisThreadContentLayout(rawWidth: rawWidth, contentMaxWidth: 900, messageMaxWidth: 560)
    }

    var isCompact: Bool { width < 700 }

    var horizontalPadding: CGFloat {
        if width < 380 { return 10 }
        if width < 500 { return 14 }
        if width < 760 { return 20 }
        return 30
    }

    var contentMaxWidth: CGFloat { 900 }
    var contentWidth: CGFloat { threadLayout.contentWidth }
    var settingsMaxWidth: CGFloat { 960 }
    var settingsCardMaxWidth: CGFloat { 820 }
    var settingsUsesColumns: Bool { width >= 760 }

    var providerListWidth: CGFloat {
        min(220, max(176, width * 0.30))
    }

    var messageMaxWidth: CGFloat {
        threadLayout.messageMaxWidth
    }

    var messageGutter: CGFloat {
        threadLayout.messageGutter
    }
}

struct IntatisChatScreen: View {
    @ObservedObject var env: AppEnvironment

    var body: some View {
        IntatisChatSessionScreen(env: env, model: env.viewModel)
            .id(env.chatSessionID.rawValue)
    }
}

private struct IntatisChatSessionScreen: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            content(layout: IntatisMacScreenLayout(rawWidth: proxy.size.width))
        }
        .task(id: env.chatSessionID.rawValue) {
            model.start()
        }
    }

    private func content(layout: IntatisMacScreenLayout) -> some View {
        VStack(spacing: 0) {
            header(layout: layout)

            messages(layout: layout)

            errorText(layout: layout)

            if !model.artifactProgress.isEmpty {
                IntatisArtifactProgressStrip(progress: model.artifactProgress)
                    .frame(maxWidth: layout.contentMaxWidth)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, 8)
            }

            IntatisComposer(model: model,
                            catalog: env.providerCatalog,
                            onSelectModel: env.selectProviderModel(providerID:modelID:))
                .frame(maxWidth: layout.contentMaxWidth)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(layout: IntatisMacScreenLayout) -> some View {
        IntatisPageHeader(title: "Chat", subtitle: subtitle)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        let catalog = env.providerCatalog
        let provider = catalog.selectedProvider
        let model = catalog.selectedModel
        let host = provider.flatMap { URL(string: $0.baseURL)?.host } ?? provider?.baseURL ?? AppConfig.defaultBaseURL
        return "\(model?.title ?? AppConfig.defaultDisplayName(for: AppConfig.defaultModel)) · \(provider?.title ?? "OpenAI") · \(host)"
    }

    @ViewBuilder private func errorText(layout: IntatisMacScreenLayout) -> some View {
        if let err = env.chatSessionError ?? model.errorText {
            Text(err)
                .font(IntatisType.caption(12))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, layout.horizontalPadding)
        }
    }

    @ViewBuilder private func messages(layout: IntatisMacScreenLayout) -> some View {
        if model.messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.messages) { msg in
                            IntatisMessageBubble(message: msg,
                                                 rowWidth: layout.contentWidth,
                                                 maxWidth: layout.messageMaxWidth,
                                                 gutter: layout.messageGutter)
                                .id(msg.id)
                        }
                        if model.isStreaming, model.messages.last?.role == .user {
                            thinkingRow(layout: layout)
                        }
                    }
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.vertical, 16)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(IntatisTheme.accentGradient)
                Image(systemName: "sparkle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            .shadow(color: IntatisTheme.gold.opacity(scheme == .light ? 0.3 : 0), radius: 16, x: 0, y: 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thinkingRow(layout: IntatisMacScreenLayout) -> some View {
        IntatisThreadBubbleRow(isTrailing: false,
                               rowWidth: layout.contentWidth,
                               maxWidth: layout.messageMaxWidth,
                               gutter: layout.messageGutter) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
                    .font(IntatisType.caption(12))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct IntatisChatModelMenu: View {
    let catalog: AppProviderCatalog
    let isBusy: Bool
    let isCompact: Bool
    var help: String = "Switch model"
    let onSelect: (String, String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var selectedProvider: AppProviderSettings? { catalog.selectedProvider }
    private var selectedModel: AppProviderModel? { catalog.selectedModel }
    private var menuProviders: [ProviderModelMenuProvider] {
        catalog.providers.map { provider in
            ProviderModelMenuProvider(
                id: provider.id,
                title: provider.title,
                models: provider.models.map { ProviderModelMenuModel(id: $0.id, title: $0.title) })
        }
    }

    var body: some View {
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID: catalog.selectedProviderID,
            selectedModelID: catalog.selectedModelID,
            isBusy: isBusy,
            onSelect: onSelect) {
                label
        }
        .buttonStyle(.plain)
        .help(isBusy ? "Model changes apply after the current response finishes" : help)
    }

    private var label: some View {
        HStack(spacing: 9) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IntatisTheme.goldDeep)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedModel?.title ?? AppConfig.defaultDisplayName(for: AppConfig.defaultModel))
                    .font(IntatisType.body(13, .semibold))
                    .foregroundStyle(IntatisTheme.deepText(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isCompact {
                    Text(selectedProvider?.title ?? "OpenAI")
                        .font(IntatisType.caption(11, .medium))
                        .foregroundStyle(IntatisTheme.softText(scheme))
                        .lineLimit(1)
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IntatisTheme.tertiaryText(scheme))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: isCompact ? 0 : 190,
               maxWidth: isCompact ? .infinity : 260,
               alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.28 : 0.66))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(IntatisTheme.glassStroke(scheme).opacity(0.75), lineWidth: 1)
                }
        }
    }
}

struct IntatisArtifactProgressStrip: View {
    let progress: [ArtifactProgressSnapshot]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(progress) { item in
                HStack(spacing: 10) {
                    ProgressView(value: min(max(item.progress, 0), 1))
                        .frame(width: 120)
                    Text(item.state)
                        .font(IntatisType.caption(12, .semibold))
                        .foregroundStyle(IntatisTheme.deepText(scheme))
                    Spacer(minLength: 8)
                    Text("\(Int(min(max(item.progress, 0), 1) * 100))%")
                        .font(IntatisType.caption(12))
                        .foregroundStyle(IntatisTheme.softText(scheme))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .intatisGlassCard(cornerRadius: 14)
    }
}

// MARK: - Message bubble

struct IntatisMessageBubble: View {
    let message: ChatMessageView
    let rowWidth: CGFloat
    let maxWidth: CGFloat
    let gutter: CGFloat
    @Environment(\.colorScheme) private var scheme

    private var isUser: Bool { message.role == .user }

    private var roleLabel: String {
        switch message.role {
        case .user:      return "You"
        case .assistant: return "Intatis"
        case .agent:     return message.agent?.rawValue ?? "Agent"
        case .system:    return "System"
        }
    }

    private var displayText: String {
        (message.text.isEmpty && !message.isComplete) ? "…" : message.text
    }

    var body: some View {
        IntatisThreadBubbleRow(
            isTrailing: isUser,
            rowWidth: rowWidth,
            maxWidth: maxWidth,
            gutter: gutter) {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(roleLabel.uppercased())
                    .font(IntatisType.caption(10, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isUser ? IntatisTheme.goldDeep : IntatisTheme.tertiaryText(scheme))
                ForEach(message.tags, id: \.self) { tag in
                    goalTag(tag)
                }
            }
            Text(displayText)
                .font(IntatisType.chat(15))
                .foregroundStyle(IntatisTheme.deepText(scheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background { bubbleBackground }
    }

    @ViewBuilder private var bubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if isUser {
            shape
                .fill(IntatisTheme.sand.opacity(scheme == .dark ? 0.16 : 0.85))
                .overlay { shape.stroke(IntatisTheme.gold.opacity(scheme == .dark ? 0.34 : 0.30), lineWidth: 1) }
        } else {
            shape
                .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.30 : 0.70))
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(IntatisTheme.glassStroke(scheme).opacity(scheme == .dark ? 0.50 : 0.85), lineWidth: 1) }
        }
    }

    private func goalTag(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(IntatisType.caption(10, .semibold))
            .foregroundStyle(IntatisTheme.goldDeep)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.24 : 0.45), in: Capsule())
    }
}

// MARK: - Composer

struct IntatisComposer: View {
    @ObservedObject var model: ChatViewModel
    let catalog: AppProviderCatalog
    let onSelectModel: (String, String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var canSend: Bool {
        !model.isBusy && !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        IntatisThreadComposer(
            placeholder: "Message Intatis...",
            input: $model.input,
            canSend: canSend,
            isInputDisabled: model.isBusy,
            style: .intatisMac(scheme),
            secondaryAction: IntatisThreadComposerSecondaryAction(
                systemImage: "photo",
                help: "Generate image from prompt",
                isBusy: model.isGeneratingArtifact,
                isDisabled: !canSend,
                action: { model.generateImage() }),
            accessory: {
                IntatisComposerAccessory(
                    catalog: catalog,
                    isBusy: model.isBusy,
                    latestTurnStats: model.latestTurnStats,
                    contextLabel: contextLabel,
                    onSelectModel: onSelectModel)
            },
            onSend: { model.send() })
    }

    private var contextLabel: String? {
        guard let promptTokens = model.latestTurnStats?.promptTokens else { return nil }
        let formatted = Self.numberFormatter.string(from: NSNumber(value: promptTokens)) ?? "\(promptTokens)"
        return "Context \(formatted) tok"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

struct IntatisComposerAccessory: View {
    let catalog: AppProviderCatalog
    let isBusy: Bool
    let latestTurnStats: TurnStatsSnapshot?
    let contextLabel: String?
    let onSelectModel: (String, String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                modelMenu(isCompact: false)
                metricsRow
            }
            VStack(alignment: .leading, spacing: 8) {
                modelMenu(isCompact: true)
                metricsRow
            }
        }
    }

    private func modelMenu(isCompact: Bool) -> some View {
        IntatisChatModelMenu(
            catalog: catalog,
            isBusy: isBusy,
            isCompact: isCompact,
            help: "Switch model",
            onSelect: onSelectModel)
    }

    @ViewBuilder private var metricsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                metricChips
            }
            VStack(alignment: .leading, spacing: 6) {
                metricChips
            }
        }
    }

    @ViewBuilder private var metricChips: some View {
        if let latestTurnStats {
            IntatisTurnStatsSummaryView(stats: latestTurnStats, style: .intatisMac(scheme))
        }
        if let contextLabel {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                Text(contextLabel)
                    .font(IntatisType.caption(12, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(IntatisTheme.softText(scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.24 : 0.58),
                        in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(IntatisTheme.glassStroke(scheme).opacity(0.70), lineWidth: 1)
            }
        }
    }
}

// MARK: - Settings panel

struct IntatisSettingsPanel: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @State private var catalog = AppConfig.providerCatalog
    @State private var apiKeysByProviderID: [String: String] = [:]
    @State private var saved = false
    @State private var settingsError: String?
    @State private var isTestingProvider = false
    @State private var providerHealthReports: [ProviderHealthReport] = []

    var body: some View {
        GeometryReader { proxy in
            settingsContent(layout: IntatisMacScreenLayout(rawWidth: proxy.size.width))
        }
    }

    private func settingsContent(layout: IntatisMacScreenLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                IntatisPageHeader(title: "Settings", subtitle: "Providers · models · API keys")

                settingsCard(layout: layout)

                Text(settingsStorageNote)
                    .font(IntatisType.caption(12, .regular))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)

                if let settingsError {
                    Text(settingsError)
                        .font(IntatisType.caption(12, .regular))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
                }

                providerHealthSummary
                    .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)

                settingsActions(layout: layout)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.top, 26)
            .padding(.bottom, 30)
            .frame(maxWidth: layout.settingsMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func settingsCard(layout: IntatisMacScreenLayout) -> some View {
        if layout.settingsUsesColumns {
            HStack(alignment: .top, spacing: 18) {
                providerList
                    .frame(width: layout.providerListWidth, alignment: .topLeading)
                Divider().opacity(0.45)
                providerDetail(layout: layout)
            }
            .padding(22)
            .intatisGlassCard(cornerRadius: 24)
            .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                providerList
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Divider().opacity(0.45)
                providerDetail(layout: layout)
            }
            .padding(18)
            .intatisGlassCard(cornerRadius: 20)
            .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
        }
    }

    @ViewBuilder private func settingsActions(layout: IntatisMacScreenLayout) -> some View {
        if layout.isCompact {
            VStack(alignment: .trailing, spacing: 10) {
                savedLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer(minLength: 0)
                    openJSONButton
                    testProviderButton(layout: layout)
                    saveButton
                }
            }
            .frame(maxWidth: layout.settingsCardMaxWidth)
        } else {
            HStack {
                savedLabel
                Spacer()
                openJSONButton
                testProviderButton(layout: layout)
                saveButton
            }
            .frame(maxWidth: layout.settingsCardMaxWidth)
        }
    }

    @ViewBuilder private var savedLabel: some View {
        if saved {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.goldDeep)
        }
    }

    private var openJSONButton: some View {
        Button(action: openJSONConfig) {
            Label("Open JSON", systemImage: "curlybraces")
                .font(IntatisType.body(14, .semibold))
                .foregroundStyle(IntatisTheme.deepText(scheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(inputBackground)
        }
        .buttonStyle(.plain)
        .help("Open provider JSON config")
    }

    private func testProviderButton(layout: IntatisMacScreenLayout) -> some View {
        Button(action: testProvider) {
            Label(isTestingProvider ? "Testing" : (layout.isCompact ? "Test" : "Test Provider"),
                  systemImage: isTestingProvider ? "hourglass" : "checkmark.seal")
                .font(IntatisType.body(14, .semibold))
                .foregroundStyle(IntatisTheme.deepText(scheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(inputBackground)
        }
        .buttonStyle(.plain)
        .disabled(isTestingProvider)
        .help("Save current settings and run a small model health check")
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save")
                .font(IntatisType.body(14, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(IntatisTheme.accentGradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var providerHealthSummary: some View {
        if isTestingProvider {
            Label("Testing provider…", systemImage: "hourglass")
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
        } else if !providerHealthReports.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(providerHealthReports.enumerated()), id: \.offset) { _, report in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(report.displayTitle, systemImage: report.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(IntatisType.caption(12, .semibold))
                            .foregroundStyle(report.isOK ? IntatisTheme.goldDeep : .red)
                        Text(report.displaySummary)
                            .font(IntatisType.caption(11, .medium))
                            .foregroundStyle(IntatisTheme.softText(scheme))
                            .lineLimit(2)
                        Text(report.displayDetail)
                            .font(IntatisType.caption(11, .regular))
                            .foregroundStyle(IntatisTheme.softText(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Providers")
                    .font(IntatisType.caption(12, .semibold))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                Spacer()
                Button(action: addProvider) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Add provider")
            }

            VStack(spacing: 8) {
                ForEach(catalog.providers) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerDetail(layout: IntatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let providerIndex = selectedProviderIndex {
                field("Provider name",
                      text: providerFieldBinding(providerIndex, \.displayName),
                      placeholder: "OpenAI")
                field("Base URL",
                      text: baseURLBinding(providerIndex),
                      placeholder: AppConfig.defaultBaseURL)
                field("Chat endpoint",
                      text: chatEndpointBinding(providerIndex),
                      placeholder: AppConfig.defaultChatEndpoint)
                secureField("API key",
                            text: apiKeyBinding(for: catalog.providers[providerIndex].id),
                            placeholder: apiKeyPlaceholder(for: catalog.providers[providerIndex]))
                Text("Key source: \(apiKeySourceLabel(for: catalog.providers[providerIndex]))")
                    .font(IntatisType.caption(11, .medium))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                activeModelPicker(providerIndex: providerIndex, layout: layout)
                modelList(providerIndex: providerIndex, layout: layout)
            } else {
                Text("Add a provider to configure models.")
                    .font(IntatisType.body(14))
                    .foregroundStyle(IntatisTheme.softText(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerRow(_ provider: AppProviderSettings) -> some View {
        let selected = provider.id == catalog.selectedProviderID
        return Button {
            selectProvider(provider)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? IntatisTheme.goldDeep : IntatisTheme.tertiaryText(scheme))
                    Text(provider.title)
                        .font(IntatisType.body(13, .semibold))
                        .foregroundStyle(IntatisTheme.deepText(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(providerSubtitle(provider))
                    .font(IntatisType.caption(11))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected
                          ? IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.22 : 0.32)
                          : IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.20 : 0.45))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? IntatisTheme.gold.opacity(0.55) : IntatisTheme.glassStroke(scheme).opacity(0.5),
                            lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func activeModelPicker(providerIndex: Int, layout: IntatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active model")
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
            Picker("", selection: $catalog.selectedModelID) {
                ForEach(catalog.providers[providerIndex].models) { model in
                    Text(model.title).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: layout.settingsUsesColumns ? 280 : .infinity, alignment: .leading)
        }
    }

    private func modelList(providerIndex: Int, layout: IntatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models")
                    .font(IntatisType.caption(12, .semibold))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                Spacer()
                Button(action: { addModel(providerIndex: providerIndex) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Add model")
            }

            ForEach(Array(catalog.providers[providerIndex].models.indices), id: \.self) { modelIndex in
                modelEditorRow(providerIndex: providerIndex,
                               modelIndex: modelIndex,
                               layout: layout)
            }

            HStack {
                Spacer()
                Button(action: { removeProvider(providerIndex) }) {
                    Label("Delete provider", systemImage: "trash")
                        .font(IntatisType.caption(12, .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(catalog.providers.count == 1)
            }
        }
    }

    @ViewBuilder private func modelEditorRow(providerIndex: Int,
                                             modelIndex: Int,
                                             layout: IntatisMacScreenLayout) -> some View {
        if layout.settingsUsesColumns {
            HStack(spacing: 8) {
                modelIDField(providerIndex: providerIndex, modelIndex: modelIndex)
                modelDisplayNameField(providerIndex: providerIndex, modelIndex: modelIndex)
                removeModelButton(providerIndex: providerIndex, modelIndex: modelIndex)
                    .padding(.top, 20)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                modelIDField(providerIndex: providerIndex, modelIndex: modelIndex)
                modelDisplayNameField(providerIndex: providerIndex, modelIndex: modelIndex)
                HStack {
                    Spacer()
                    removeModelButton(providerIndex: providerIndex, modelIndex: modelIndex)
                }
            }
        }
    }

    private func modelIDField(providerIndex: Int, modelIndex: Int) -> some View {
        field("Model ID",
              text: modelFieldBinding(providerIndex: providerIndex,
                                      modelIndex: modelIndex,
                                      keyPath: \.id),
              placeholder: AppConfig.defaultModel)
    }

    private func modelDisplayNameField(providerIndex: Int, modelIndex: Int) -> some View {
        field("Display name",
              text: modelFieldBinding(providerIndex: providerIndex,
                                      modelIndex: modelIndex,
                                      keyPath: \.displayName),
              placeholder: "GPT-4o mini")
    }

    private func removeModelButton(providerIndex: Int, modelIndex: Int) -> some View {
        Button(action: { removeModel(providerIndex: providerIndex, modelIndex: modelIndex) }) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IntatisTheme.tertiaryText(scheme))
        }
        .buttonStyle(.plain)
        .disabled(catalog.providers[providerIndex].models.count == 1)
        .help("Remove model")
    }

    private func save() {
        do {
            try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
            catalog = AppConfig.providerCatalog
            apiKeysByProviderID = [:]
            settingsError = nil
            providerHealthReports = []
            withAnimation { saved = true }
        } catch {
            saved = false
            settingsError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private func openJSONConfig() {
        do {
            let url = try AppConfig.prepareEditableConfigFile()
            catalog = AppConfig.providerCatalog
            settingsError = nil
            providerHealthReports = []
            saved = false
            #if canImport(AppKit)
            if !NSWorkspace.shared.open(url) {
                settingsError = "Could not open JSON config at \(url.path)"
            }
            #else
            settingsError = "Opening JSON config is not available on this platform."
            #endif
        } catch {
            saved = false
            settingsError = "Could not open JSON config: \(error.localizedDescription)"
        }
    }

    private func testProvider() {
        guard !isTestingProvider else { return }
        isTestingProvider = true
        settingsError = nil
        providerHealthReports = []
        Task { @MainActor in
            defer { isTestingProvider = false }
            do {
                try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
                catalog = AppConfig.providerCatalog
                apiKeysByProviderID = [:]
                withAnimation { saved = true }
                providerHealthReports = await env.healthCheckSelectedProvider()
            } catch {
                saved = false
                settingsError = "Could not test provider: \(error.localizedDescription)"
            }
        }
    }

    private var selectedProviderIndex: Int? {
        catalog.providers.firstIndex { $0.id == catalog.selectedProviderID } ?? catalog.providers.indices.first
    }

    private func selectProvider(_ provider: AppProviderSettings) {
        catalog.selectedProviderID = provider.id
        if !provider.models.contains(where: { $0.id == catalog.selectedModelID }) {
            catalog.selectedModelID = provider.models.first?.id ?? AppConfig.defaultModel
        }
        saved = false
    }

    private func addProvider() {
        let provider = AppConfig.newProvider()
        catalog.providers.append(provider)
        selectProvider(provider)
        saved = false
    }

    private func removeProvider(_ index: Int) {
        guard catalog.providers.count > 1, catalog.providers.indices.contains(index) else { return }
        let removedID = catalog.providers[index].id
        catalog.providers.remove(at: index)
        apiKeysByProviderID[removedID] = nil
        if catalog.selectedProviderID == removedID {
            let provider = catalog.providers[min(index, catalog.providers.count - 1)]
            selectProvider(provider)
        }
        saved = false
    }

    private func addModel(providerIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex) else { return }
        let existing = Set(catalog.providers[providerIndex].models.map(\.id))
        let modelID = existing.contains(AppConfig.defaultModel) ? "model-id" : AppConfig.defaultModel
        catalog.providers[providerIndex].models.append(AppProviderModel(id: modelID, displayName: modelID))
        catalog.selectedModelID = modelID
        saved = false
    }

    private func removeModel(providerIndex: Int, modelIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex),
              catalog.providers[providerIndex].models.count > 1,
              catalog.providers[providerIndex].models.indices.contains(modelIndex) else { return }
        let removedID = catalog.providers[providerIndex].models[modelIndex].id
        catalog.providers[providerIndex].models.remove(at: modelIndex)
        if catalog.selectedModelID == removedID {
            catalog.selectedModelID = catalog.providers[providerIndex].models[0].id
        }
        saved = false
    }

    private func providerSubtitle(_ provider: AppProviderSettings) -> String {
        let host = URL(string: provider.baseURL)?.host ?? provider.baseURL
        return "\(provider.models.count) models · \(host) · \(apiKeySourceLabel(for: provider))"
    }

    private func providerFieldBinding(_ providerIndex: Int,
                                      _ keyPath: WritableKeyPath<AppProviderSettings, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex][keyPath: keyPath] },
            set: {
                catalog.providers[providerIndex][keyPath: keyPath] = $0
                saved = false
            })
    }

    private func baseURLBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].baseURL },
            set: {
                let baseURL = AppConfig.baseURL(fromChatEndpoint: $0)
                catalog.providers[providerIndex].baseURL = baseURL
                catalog.providers[providerIndex].chatEndpoint = AppConfig.chatEndpoint(forBaseURL: baseURL)
                saved = false
            })
    }

    private func chatEndpointBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].chatEndpoint },
            set: {
                let endpoint = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                catalog.providers[providerIndex].chatEndpoint = endpoint
                catalog.providers[providerIndex].baseURL = AppConfig.baseURL(fromChatEndpoint: endpoint)
                saved = false
            })
    }

    private func modelFieldBinding(providerIndex: Int,
                                   modelIndex: Int,
                                   keyPath: WritableKeyPath<AppProviderModel, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] },
            set: {
                let oldID = catalog.providers[providerIndex].models[modelIndex].id
                catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] = $0
                if keyPath == \AppProviderModel.id, catalog.selectedModelID == oldID {
                    catalog.selectedModelID = $0
                }
                saved = false
            })
    }

    private func apiKeyBinding(for providerID: String) -> Binding<String> {
        Binding(
            get: { apiKeysByProviderID[providerID] ?? "" },
            set: {
                apiKeysByProviderID[providerID] = $0
                saved = false
            })
    }

    private func apiKeyPlaceholder(for provider: AppProviderSettings) -> String {
        let ref = AppConfig.apiKeyRef(for: provider)
        if ref.source != .authFile {
            return "Using \(apiKeySourceLabel(for: provider)); enter key to replace"
        }
        return env.hasAPIKey(for: provider) ? "••••••••••••••••" : "Enter API key"
    }

    private func apiKeySourceLabel(for provider: AppProviderSettings) -> String {
        let ref = AppConfig.apiKeyRef(for: provider)
        switch ref.source {
        case .authFile:
            return "auth file"
        case .environment:
            return ref.account.isEmpty ? "environment" : "env \(ref.account)"
        case .file:
            return "secret file"
        case .keychain:
            return "legacy keychain"
        }
    }

    private var settingsStorageNote: String {
        if let path = AppConfig.externalConfigDescription {
            return "Config: \(path)"
        }
        return "Config: \(AppConfig.editableConfigDescription)"
    }

    @ViewBuilder private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(IntatisType.mono(13))
                .foregroundStyle(IntatisTheme.deepText(scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(inputBackground)
        }
    }

    @ViewBuilder private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(IntatisType.mono(13))
                .foregroundStyle(IntatisTheme.deepText(scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(inputBackground)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.30 : 0.70))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(IntatisTheme.glassStroke(scheme).opacity(0.8), lineWidth: 1)
            }
    }
}
#endif
