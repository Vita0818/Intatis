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
import IntatisCore
import IntatisProtocol
import IntatisConversation
import IntatisSharedUI

struct IntatisChatScreen: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            IntatisPageHeader(title: "Chat", subtitle: subtitle)
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
        let host = URL(string: AppConfig.baseURL)?.host ?? AppConfig.baseURL
        return "\(AppConfig.chatModelName) · \(host)"
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
                Text(roleLabel.uppercased())
                    .font(IntatisType.caption(10, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isUser ? IntatisTheme.goldDeep : IntatisTheme.tertiaryText(scheme))
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
}

// MARK: - Composer

struct IntatisComposer: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !model.isStreaming && !model.input.trimmingCharacters(in: .whitespaces).isEmpty
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

                Button { model.generateImage() } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(canSend ? IntatisTheme.goldDeep : IntatisTheme.tertiaryText(scheme))
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
    @State private var baseURL = AppConfig.baseURL
    @State private var modelName = AppConfig.chatModelName
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                IntatisPageHeader(title: "Settings", subtitle: "Endpoint · model · API key")

                VStack(alignment: .leading, spacing: 16) {
                    field("Base URL", text: $baseURL, placeholder: AppConfig.defaultBaseURL)
                    field("Model", text: $modelName, placeholder: AppConfig.defaultModel)
                    secureField("API key", text: $key, placeholder: "sk-… (any non-empty for local servers)")

                    Text("Works with any OpenAI-compatible API — OpenAI, Ollama, vLLM, OpenRouter, DeepSeek… The key is stored in your macOS keychain. Endpoint / model changes take effect on relaunch.")
                        .font(IntatisType.caption(12, .regular))
                        .foregroundStyle(IntatisTheme.softText(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(IntatisType.caption(12, .semibold))
                                .foregroundStyle(IntatisTheme.goldDeep)
                        }
                        Spacer()
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
                }
                .padding(22)
                .intatisGlassCard(cornerRadius: 24)
                .frame(maxWidth: 620, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 30)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }

    private func save() {
        AppConfig.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.chatModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { env.saveAPIKey(key) }
        key = ""
        withAnimation { saved = true }
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
