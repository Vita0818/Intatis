#if canImport(SwiftUI)
import SwiftUI
import Combine
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation

public enum ChatArtifactGenerationState: Equatable, Sendable {
    case idle
    case running
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Bridges the event log to SwiftUI. It subscribes to the log's event stream and
/// folds it into `messages`; it never talks to a provider directly except
/// through `ChatLoop`. This is the UI-side enforcement of "consume structured
/// events, never parse text" (ARCHITECTURE.md §3.11).
@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessageView] = []
    @Published public private(set) var artifacts: [ArtifactCardInfo] = []
    @Published public private(set) var artifactProgress: [ArtifactProgressSnapshot] = []
    @Published public private(set) var latestTurnStats: TurnStatsSnapshot?
    @Published public var input: String = ""
    @Published public private(set) var isStreaming = false
    @Published public private(set) var imageGenerationState: ChatArtifactGenerationState = .idle
    @Published public var errorText: String?

    /// Wired by the app (v0.4): generate an image from a prompt. The resulting
    /// `artifact_added` event flows back through the log subscription.
    public var onGenerateImage: (@MainActor (String) async throws -> Void)?

    private let log: EventLog
    private var registry: ProviderRegistry
    private var subscription: Task<Void, Never>?

    public init(log: EventLog, registry: ProviderRegistry) {
        self.log = log
        self.registry = registry
    }

    public func updateProviderRegistry(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    public var isGeneratingArtifact: Bool { imageGenerationState.isRunning }

    public var isBusy: Bool { isStreaming || isGeneratingArtifact }

    /// Begin folding the log into `messages`. Call once (e.g. from `.task`).
    public func start() {
        guard subscription == nil else { return }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.log.stream(from: 0)
            var projection = ConversationProjection()
            var artifactProgressProjection = ArtifactProgressProjection()
            var turnStatsProjection = TurnStatsProjection()
            for await envelope in stream {
                projection.apply(envelope)
                artifactProgressProjection.apply(envelope)
                turnStatsProjection.apply(envelope)
                self.messages = projection.messages
                self.artifactProgress = artifactProgressProjection.active
                self.latestTurnStats = turnStatsProjection.latest
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
        guard !isBusy else { return }
        let originalInput = input
        let parsed: ParsedUserInput
        switch GoalInputParser.parse(originalInput) {
        case .success(let value):
            parsed = value
        case .failure(.empty):
            return
        case .failure(let error):
            errorText = error.message
            return
        }
        input = ""
        isStreaming = true
        errorText = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let startSeq = await self.log.replay().last?.seq ?? -1
            do {
                let provider = try await self.registry.defaultChatProvider()
                let model = await self.registry.chatModel()
                let loop = ChatLoop(log: self.log, provider: provider, model: model)
                try await loop.send(parsed.text, userMessage: parsed.userMessagePayload)
            } catch {
                let loggedError = await self.hasLoggedError(after: startSeq)
                self.errorText = loggedError ? nil : error.localizedDescription
            }
            self.isStreaming = false
        }
    }

    private func hasLoggedError(after seq: Int) async -> Bool {
        await log.replay(from: seq).contains { envelope in
            guard envelope.seq > seq else { return false }
            if case .error = envelope.event {
                return true
            }
            return false
        }
    }

    /// Generate an image from the current composer text (wired by the app).
    public func generateImage() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        guard let onGenerateImage else {
            let message = "Image generation is not available."
            imageGenerationState = .failed(message)
            errorText = message
            return
        }
        input = ""
        errorText = nil
        imageGenerationState = .running
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onGenerateImage(prompt)
                self.imageGenerationState = .idle
            } catch {
                let message = "Image generation failed: \(error.localizedDescription)"
                self.errorText = message
                self.imageGenerationState = .failed(message)
                if self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.input = prompt
                }
            }
        }
    }
}
#endif
