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
        case .chat:   return IntatisLocalization.string("Chat")
        case .code:   return IntatisLocalization.string("Code")
        case .cowork: return IntatisLocalization.string("Cowork")
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
                    IntatisAdaptiveThreadStack(
                        visibleRowCount: model.messages.count,
                        alignment: .leading,
                        spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 16)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
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

    private var isUninterruptedAgentReply: Bool {
        (message.role == .assistant || message.role == .agent)
            && message.recoveryAdvice == nil
    }

    @ViewBuilder var body: some View {
        if isUninterruptedAgentReply {
            messageBody
                .padding(.vertical, 8)
        } else {
            messageBody
                .padding(10)
                .intatisContentSurface(cornerRadius: 10)
                .overlay {
                    if message.role == .user {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(style.accent.opacity(0.64), lineWidth: 1)
                    }
                }
        }
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if (message.role == .assistant || message.role == .agent),
                   let timestamp = message.timestamp {
                    Text(IntatisMessageTimestampPresentation.string(for: timestamp))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                ForEach(message.tags, id: \.self) { tag in
                    tagBadge(tag)
                }
            }
            if message.role == .assistant || message.role == .agent {
                IntatisMessageContentView(
                    messageID: message.id.rawValue,
                    rawText: message.text,
                    isComplete: message.isComplete,
                    policy: .richText,
                    style: style)
            } else {
                Text(displayText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let advice = message.recoveryAdvice {
                IntatisRecoveryAdviceView(advice: advice, tint: .red, style: style)
            }
        }
    }

    private var displayText: String {
        (message.text.isEmpty && !message.isComplete) ? "…" : message.text
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      return IntatisLocalization.string("You")
        case .assistant: return IntatisLocalization.string("Assistant")
        case .agent:
            return message.agent?.rawValue ?? IntatisLocalization.string("Agent")
        case .system:    return IntatisLocalization.string("System")
        }
    }

    private func tagBadge(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay {
                Capsule().stroke(style.stroke, lineWidth: 1)
            }
    }
}

struct ComposerView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var scheme

    private var canSend: Bool {
        !model.isBusy
            && !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        IntatisThreadComposer(
            placeholder: IntatisLocalization.string("Message Intatis…"),
            input: $model.input,
            canSend: canSend,
            isInputDisabled: model.isBusy,
            style: .standard(scheme),
            secondaryAction: IntatisThreadComposerSecondaryAction(
                systemImage: "photo",
                help: IntatisLocalization.string("Generate image from prompt"),
                isBusy: model.isGeneratingArtifact,
                isDisabled: !canSend,
                action: { model.generateImage() }),
            stopAction: model.isBusy
                ? IntatisThreadComposerSecondaryAction(
                    systemImage: "stop.fill",
                    help: IntatisLocalization.string("Stop"),
                    action: { model.cancelCurrentOperation() })
                : nil,
            onSend: { model.send() })
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
                LabeledContent(
                    "Streaming",
                    value: isStreaming
                        ? IntatisLocalization.string("Yes")
                        : IntatisLocalization.string("No"))
                LabeledContent(
                    "Image job",
                    value: isGeneratingArtifact
                        ? IntatisLocalization.string("Running")
                        : IntatisLocalization.string("Idle"))
                LabeledContent(
                    "Artifact progress",
                    value: artifactProgress.isEmpty
                        ? IntatisLocalization.string("None")
                        : IntatisLocalization.format("%lld active", Int64(artifactProgress.count)))
                LabeledContent("Artifacts", value: "\(artifacts.count)")
            }
            Section("Artifacts") {
                ArtifactInspector(artifacts: artifacts, progress: artifactProgress)
            }
        }
    }
}
#endif
