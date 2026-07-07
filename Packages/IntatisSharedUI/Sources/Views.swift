#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

/// Shared chat shell. The caller chooses split or single-thread presentation via
/// `ThreeColumnShellLayout`, so macOS/iPad-style panes and compact iOS chat use
/// the same thread/composer implementation with different parameters.
public struct ThreeColumnShell: View {
    @ObservedObject private var model: ChatViewModel
    private let layout: ThreeColumnShellLayout

    public init(model: ChatViewModel,
                layout: ThreeColumnShellLayout = .split) {
        self.model = model
        self.layout = layout
    }

    public var body: some View {
        Group {
            switch layout.presentation {
            case .split:
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: layout.columns.sidebarMin,
                                                        ideal: layout.columns.sidebarIdeal)
                } content: {
                    ThreadView(model: model)
                        .navigationSplitViewColumnWidth(min: layout.columns.contentMin,
                                                        ideal: layout.columns.contentIdeal)
                } detail: {
                    InspectorView(messages: model.messages,
                                  isStreaming: model.isStreaming,
                                  isGeneratingArtifact: model.isGeneratingArtifact,
                                  artifacts: model.artifacts,
                                  artifactProgress: model.artifactProgress)
                        .navigationSplitViewColumnWidth(min: layout.columns.detailMin,
                                                        ideal: layout.columns.detailIdeal)
                }
            case .threadOnly:
                NavigationStack {
                    ThreadView(model: model)
                        .navigationTitle("Chat")
                }
            }
        }
        .task { model.start() }
    }
}

// MARK: - Left: Sidebar

struct SidebarView: View {
    private var surfaces: [SessionKind] {
        SessionKind.allCases.filter { PlatformProfile.current.supports($0) }
    }

    var body: some View {
        List {
            Section("Intatis") {
                ForEach(surfaces, id: \.self) { kind in
                    Label(title(kind), systemImage: icon(kind))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func title(_ kind: SessionKind) -> String {
        switch kind {
        case .chat:   return "Chat"
        case .code:   return "Code"
        case .cowork: return "Cowork"
        }
    }

    private func icon(_ kind: SessionKind) -> String {
        switch kind {
        case .chat:   return "bubble.left"
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "person.2"
        }
    }
}

// MARK: - Center: Thread

struct ThreadView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var scheme
    private static let bottomAnchorID = "intatis-shared-chat-thread-bottom"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding()
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: chatScrollSignature) { _ in
                    scrollToBottom(proxy)
                }
            }
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let latestTurnStats = model.latestTurnStats {
                IntatisTurnStatsSummaryView(stats: latestTurnStats, style: .standard(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
            Divider()
            ComposerView(model: model)
        }
    }

    private var chatScrollSignature: String {
        guard let last = model.messages.last else { return "0" }
        return [
            "\(model.messages.count)",
            last.id.rawValue,
            "\(last.text.count)",
            "\(last.isComplete)",
            "\(model.isStreaming)"
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
}

struct MessageRow: View {
    let message: ChatMessageView
    @Environment(\.colorScheme) private var scheme

    private var style: IntatisThreadStyle {
        .standard(scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(message.tags, id: \.self) { tag in
                    tagBadge(tag)
                }
            }
            Text(displayText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let advice = message.recoveryAdvice {
                IntatisRecoveryAdviceView(advice: advice, tint: .red, style: style)
            }
        }
        .padding(10)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var displayText: String {
        (message.text.isEmpty && !message.isComplete) ? "…" : message.text
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      return "You"
        case .assistant: return "Assistant"
        case .agent:     return message.agent?.rawValue ?? "Agent"
        case .system:    return "System"
        }
    }

    private var background: Color {
        message.role == .user ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.10)
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

struct ComposerView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Intatis…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { model.send() }
                .disabled(model.isBusy)
            Button {
                model.generateImage()
            } label: {
                if model.isGeneratingArtifact {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo").font(.title3)
                }
            }
            .buttonStyle(.plain)
            .help("Generate image from prompt")
            .disabled(model.isBusy || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }
}

// MARK: - Right: Inspector

struct InspectorView: View {
    let messages: [ChatMessageView]
    let isStreaming: Bool
    let isGeneratingArtifact: Bool
    let artifacts: [ArtifactCardInfo]
    let artifactProgress: [ArtifactProgressSnapshot]

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Messages", value: "\(messages.count)")
                LabeledContent("Streaming", value: isStreaming ? "Yes" : "No")
                LabeledContent("Image job", value: isGeneratingArtifact ? "Running" : "Idle")
                LabeledContent("Artifact progress", value: artifactProgress.isEmpty ? "None" : "\(artifactProgress.count) active")
                LabeledContent("Artifacts", value: "\(artifacts.count)")
            }
            Section("Artifacts") {
                ArtifactInspector(artifacts: artifacts, progress: artifactProgress)
            }
        }
    }
}
#endif
