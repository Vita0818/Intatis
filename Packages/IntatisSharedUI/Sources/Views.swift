#if canImport(SwiftUI)
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

/// Codex-App-style three-pane shell (ARCHITECTURE.md §3): sidebar / thread /
/// inspector. Shared by macOS and iOS; the iOS subset simply shows fewer
/// surfaces because `PlatformProfile.current.surfaces` is smaller (§4).
public struct ThreeColumnShell: View {
    @ObservedObject private var model: ChatViewModel

    public init(model: ChatViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            ThreadView(model: model)
                .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        } detail: {
            InspectorView(messages: model.messages, isStreaming: model.isStreaming, artifacts: model.artifacts)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            Divider()
            ComposerView(model: model)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessageView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
}

struct ComposerView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Intatis…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { model.send() }
            Button {
                model.generateImage()
            } label: {
                Image(systemName: "photo").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Generate image from prompt")
            .disabled(model.isStreaming || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(model.isStreaming || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }
}

// MARK: - Right: Inspector

struct InspectorView: View {
    let messages: [ChatMessageView]
    let isStreaming: Bool
    let artifacts: [ArtifactCardInfo]

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Messages", value: "\(messages.count)")
                LabeledContent("Streaming", value: isStreaming ? "Yes" : "No")
                LabeledContent("Artifacts", value: "\(artifacts.count)")
            }
            Section("Artifacts") {
                ArtifactInspector(artifacts: artifacts)
            }
        }
    }
}
#endif
