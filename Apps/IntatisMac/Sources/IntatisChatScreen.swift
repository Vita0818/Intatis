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
import IntatisConversation
import IntatisSharedUI

struct IntatisChatScreen: View {
    @ObservedObject var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    private var model: ChatViewModel { env.viewModel }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                IntatisPageHeader(title: "Chat", subtitle: subtitle)
                IntatisChatModelMenu(
                    catalog: env.providerCatalog,
                    isBusy: model.isBusy,
                    onSelect: env.selectProviderModel(providerID:modelID:))
                    .padding(.top, 2)
            }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 14)

            messages

            if let err = model.errorText {
                Text(err)
                    .font(IntatisType.caption(12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
            }

            if !model.artifactProgress.isEmpty {
                IntatisArtifactProgressStrip(progress: model.artifactProgress)
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 30)
                    .padding(.top, 8)
            }

            IntatisComposer(model: model)
                .frame(maxWidth: 900)
                .padding(.horizontal, 30)
                .padding(.top, 10)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .task { model.start() }
    }

    private var subtitle: String {
        let catalog = env.providerCatalog
        let provider = catalog.selectedProvider
        let model = catalog.selectedModel
        let host = provider.flatMap { URL(string: $0.baseURL)?.host } ?? provider?.baseURL ?? AppConfig.defaultBaseURL
        return "\(model?.title ?? AppConfig.defaultDisplayName(for: AppConfig.defaultModel)) · \(provider?.title ?? "OpenAI") · \(host)"
    }

    @ViewBuilder private var messages: some View {
        if model.messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.messages) { msg in
                            IntatisMessageBubble(message: msg).id(msg.id)
                        }
                        if model.isStreaming, model.messages.last?.role == .user {
                            thinkingRow
                        }
                    }
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 30)
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

            Text("怎么开始都行")
                .font(IntatisType.title(22))
                .foregroundStyle(IntatisTheme.deepText(scheme))
            Text("Ask Intatis anything — it streams back as it thinks.")
                .font(IntatisType.body(14))
                .foregroundStyle(IntatisTheme.softText(scheme))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thinkingRow: some View {
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

struct IntatisChatModelMenu: View {
    let catalog: AppProviderCatalog
    let isBusy: Bool
    let onSelect: (String, String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var selectedProvider: AppProviderSettings? { catalog.selectedProvider }
    private var selectedModel: AppProviderModel? { catalog.selectedModel }

    var body: some View {
        Menu {
            ForEach(catalog.providers) { provider in
                Section(provider.title) {
                    ForEach(provider.models) { model in
                        Button {
                            onSelect(provider.id, model.id)
                        } label: {
                            Label(model.title,
                                  systemImage: isSelected(providerID: provider.id, modelID: model.id)
                                  ? "checkmark"
                                  : "circle")
                        }
                    }
                }
            }
        } label: {
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
                    Text(selectedProvider?.title ?? "OpenAI")
                        .font(IntatisType.caption(11, .medium))
                        .foregroundStyle(IntatisTheme.softText(scheme))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IntatisTheme.tertiaryText(scheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 190, maxWidth: 260, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.28 : 0.66))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(IntatisTheme.glassStroke(scheme).opacity(0.75), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(isBusy ? "Model changes apply after the current response finishes" : "Switch chat model")
    }

    private func isSelected(providerID: String, modelID: String) -> Bool {
        catalog.selectedProviderID == providerID && catalog.selectedModelID == modelID
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
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 48) }
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
            .frame(maxWidth: 560, alignment: .leading)
            if !isUser { Spacer(minLength: 48) }
        }
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
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !model.isBusy && !model.input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Intatis…", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(IntatisType.chat(15))
                    .foregroundStyle(IntatisTheme.deepText(scheme))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.send() }
                    .disabled(model.isBusy)

                Button { model.generateImage() } label: {
                    if model.isGeneratingArtifact {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(canSend ? IntatisTheme.goldDeep : IntatisTheme.tertiaryText(scheme))
                    }
                }
                .buttonStyle(.plain)
                .help("Generate image from prompt")
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .intatisGlassCapsule()

            Button { model.send() } label: {
                ZStack {
                    Circle().fill(canSend
                        ? AnyShapeStyle(IntatisTheme.accentGradient)
                        : AnyShapeStyle(IntatisTheme.glassSurface(scheme).opacity(0.5)))
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSend ? .white : IntatisTheme.tertiaryText(scheme))
                }
                .frame(width: 40, height: 40)
                .shadow(color: IntatisTheme.gold.opacity(canSend && scheme == .light ? 0.32 : 0), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                IntatisPageHeader(title: "Settings", subtitle: "Providers · models · API keys")

                HStack(alignment: .top, spacing: 18) {
                    providerList
                    Divider().opacity(0.45)
                    providerDetail
                }
                .padding(22)
                .intatisGlassCard(cornerRadius: 24)
                .frame(maxWidth: 820, alignment: .leading)

                Text(settingsStorageNote)
                    .font(IntatisType.caption(12, .regular))
                    .foregroundStyle(IntatisTheme.softText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 820, alignment: .leading)

                if let settingsError {
                    Text(settingsError)
                        .font(IntatisType.caption(12, .regular))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 820, alignment: .leading)
                }

                HStack {
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(IntatisType.caption(12, .semibold))
                            .foregroundStyle(IntatisTheme.goldDeep)
                    }
                    Spacer()
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
                .frame(maxWidth: 820)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 30)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
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
        .frame(width: 220, alignment: .topLeading)
    }

    private var providerDetail: some View {
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
                activeModelPicker(providerIndex: providerIndex)
                modelList(providerIndex: providerIndex)
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

    private func activeModelPicker(providerIndex: Int) -> some View {
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
            .frame(maxWidth: 280, alignment: .leading)
        }
    }

    private func modelList(providerIndex: Int) -> some View {
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
                HStack(spacing: 8) {
                    field("Model ID",
                          text: modelFieldBinding(providerIndex: providerIndex,
                                                  modelIndex: modelIndex,
                                                  keyPath: \.id),
                          placeholder: AppConfig.defaultModel)
                    field("Display name",
                          text: modelFieldBinding(providerIndex: providerIndex,
                                                  modelIndex: modelIndex,
                                                  keyPath: \.displayName),
                          placeholder: "GPT-4o mini")
                    Button(action: { removeModel(providerIndex: providerIndex, modelIndex: modelIndex) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(IntatisTheme.tertiaryText(scheme))
                    }
                    .buttonStyle(.plain)
                    .disabled(catalog.providers[providerIndex].models.count == 1)
                    .help("Remove model")
                    .padding(.top, 20)
                }
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

    private func save() {
        do {
            try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
            catalog = AppConfig.providerCatalog
            apiKeysByProviderID = [:]
            settingsError = nil
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
        return "\(provider.models.count) models · \(host)"
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
        env.hasAPIKey(for: provider) ? "••••••••••••••••" : "Enter API key"
    }

    private var settingsStorageNote: String {
        if let path = AppConfig.externalConfigDescription {
            return "Advanced config is active from \(path). Provider metadata comes from that JSON file; API keys resolve from its source setting, an auth JSON file, or the keychain."
        }
        return "Provider entries store endpoint metadata in UserDefaults and API keys in the macOS keychain. Use Open JSON for an editable provider config at \(AppConfig.editableConfigDescription)."
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
