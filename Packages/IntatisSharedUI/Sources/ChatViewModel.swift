#if canImport(SwiftUI)
import SwiftUI
import Combine
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation

/// Bridges the event log to SwiftUI. It subscribes to the log's event stream and
/// folds it into `messages`; it never talks to a provider directly except
/// through `ChatLoop`. This is the UI-side enforcement of "consume structured
/// events, never parse text" (ARCHITECTURE.md §3.11).
@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessageView] = []
    @Published public private(set) var artifacts: [ArtifactCardInfo] = []
    @Published public var input: String = ""
    @Published public private(set) var isStreaming = false
    @Published public var errorText: String?

    /// Wired by the app (v0.4): generate an image from a prompt. The resulting
    /// `artifact_added` event flows back through the log subscription.
    public var onGenerateImage: ((String) -> Void)?

    private let log: EventLog
    private let registry: ProviderRegistry
    private var subscription: Task<Void, Never>?

    public init(log: EventLog, registry: ProviderRegistry) {
        self.log = log
        self.registry = registry
    }

    /// Begin folding the log into `messages`. Call once (e.g. from `.task`).
    public func start() {
        guard subscription == nil else { return }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.log.stream(from: 0)
            var projection = ConversationProjection()
            for await envelope in stream {
                projection.apply(envelope)
                self.messages = projection.messages
                if case .artifactAdded(let p) = envelope.event {
                    self.artifacts.append(ArtifactCardInfo(id: p.artifactId.rawValue, kind: p.kind,
                                                           mime: p.mime, path: p.path, prompt: p.prompt))
                }
            }
        }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Send the composed message. Streaming output arrives via the log subscription.
    public func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        isStreaming = true
        errorText = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let provider = try await self.registry.defaultChatProvider()
                let model = await self.registry.chatModel()
                let loop = ChatLoop(log: self.log, provider: provider, model: model)
                try await loop.send(text)
            } catch {
                self.errorText = error.localizedDescription
            }
            self.isStreaming = false
        }
    }

    /// Generate an image from the current composer text (wired by the app).
    public func generateImage() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        input = ""
        onGenerateImage?(prompt)
    }
}
#endif
