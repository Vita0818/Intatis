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

struct ChatProjectionState: Equatable, Sendable {
    var conversation = ConversationProjection()
    var artifactProgress = ArtifactProgressProjection()
    var turnStats = TurnStatsProjection()
    var artifacts: [ArtifactCardInfo] = []

    mutating func apply(_ envelope: Envelope) {
        conversation.apply(envelope)
        artifactProgress.apply(envelope)
        turnStats.apply(envelope)
        if case .artifactAdded(let payload) = envelope.event {
            artifacts.append(ArtifactCardInfo(
                id: payload.artifactId.rawValue,
                kind: payload.kind,
                mime: payload.mime,
                path: payload.path,
                prompt: payload.prompt))
        }
    }
}

actor ChatHistoryProjectionBuilder {
    private let beforeBuild: (@Sendable () async -> Void)?

    init(beforeBuild: (@Sendable () async -> Void)? = nil) {
        self.beforeBuild = beforeBuild
    }

    func build(_ envelopes: [Envelope]) async -> ChatProjectionState? {
        await beforeBuild?()
        guard !Task.isCancelled else { return nil }
        var state = ChatProjectionState()
        for envelope in envelopes {
            guard !Task.isCancelled else { return nil }
            state.apply(envelope)
        }
        return state
    }
}

typealias ChatHistorySnapshotLoader =
    @Sendable (EventLog) async throws -> [Envelope]

let defaultChatHistorySnapshotLoader: ChatHistorySnapshotLoader = { log in
    try await log.replayChecked()
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

    #if canImport(AVFoundation)
    public let voiceInput: ComposerVoiceInputController
    private var voiceInputObservation: AnyCancellable?
    #endif

    /// Wired by the app (v0.4): generate an image from a prompt. The resulting
    /// `artifact_added` event flows back through the log subscription.
    public var onGenerateImage: (@MainActor (String) async throws -> Void)?

    private let log: EventLog
    private var registry: ProviderRegistry
    private var subscription: Task<Void, Never>?
    private var runningOperation: Task<Void, Never>?
    private var imageGenerationOperation: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isShutdown = false
    private let historyProjectionBuilder: ChatHistoryProjectionBuilder
    private let historySnapshotLoader: ChatHistorySnapshotLoader
    private var historyReplayErrorText: String?

    public init(log: EventLog, registry: ProviderRegistry) {
        self.log = log
        self.registry = registry
        #if canImport(AVFoundation)
        self.voiceInput = ComposerVoiceInputController(registry: registry)
        #endif
        self.historyProjectionBuilder = ChatHistoryProjectionBuilder()
        self.historySnapshotLoader = defaultChatHistorySnapshotLoader
        #if canImport(AVFoundation)
        observeVoiceInput()
        #endif
    }

    init(
        log: EventLog,
        registry: ProviderRegistry,
        historyProjectionBuilder: ChatHistoryProjectionBuilder,
        historySnapshotLoader: @escaping ChatHistorySnapshotLoader
    ) {
        self.log = log
        self.registry = registry
        #if canImport(AVFoundation)
        self.voiceInput = ComposerVoiceInputController(registry: registry)
        #endif
        self.historyProjectionBuilder = historyProjectionBuilder
        self.historySnapshotLoader = historySnapshotLoader
        #if canImport(AVFoundation)
        observeVoiceInput()
        #endif
    }

    public func updateProviderRegistry(_ registry: ProviderRegistry) {
        self.registry = registry
        #if canImport(AVFoundation)
        voiceInput.updateProviderRegistry(registry)
        #endif
    }

    public var isGeneratingArtifact: Bool { imageGenerationState.isRunning }

    public var isBusy: Bool { isStreaming || isGeneratingArtifact }

    /// Begin folding the log into `messages`. Call once (e.g. from `.task`).
    public func start() {
        guard !isShutdown, subscription == nil else { return }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let history: [Envelope]
            do {
                history = try await self.historySnapshotLoader(self.log)
            } catch {
                guard !Task.isCancelled, !self.isShutdown else { return }
                let message = IntatisLocalization.format(
                    "Chat history could not be loaded: %@",
                    error.localizedDescription)
                self.historyReplayErrorText = message
                self.errorText = message
                // The failed task must not occupy the subscription slot
                // forever. A later view appearance or explicit start can
                // retry the strict snapshot without restarting the runtime.
                self.subscription = nil
                return
            }
            guard !Task.isCancelled else { return }
            let historyLastSeq = history.last?.seq ?? -1
            let liveFrom = historyLastSeq == Int.max
                ? Int.max
                : historyLastSeq + 1
            // Register the live subscriber before folding. Events appended
            // after the replay snapshot are replayed into this exact stream,
            // so the off-main fold cannot create a loss window.
            let stream = await self.log.stream(from: liveFrom)
            // `stream(from:)` intentionally keeps compatibility fail-soft
            // replay semantics. Take a second strict catch-up snapshot after
            // subscriber registration and de-duplicate by seq: this covers an
            // event appended between the initial snapshot and registration,
            // even if the stream's compatibility replay could not read it.
            let catchUp: [Envelope]
            do {
                catchUp = try await self.log.replayChecked(from: liveFrom)
            } catch {
                guard !Task.isCancelled, !self.isShutdown else { return }
                let message = IntatisLocalization.format(
                    "Chat history could not be loaded: %@",
                    error.localizedDescription)
                self.historyReplayErrorText = message
                self.errorText = message
                self.subscription = nil
                return
            }
            var restoreInput = history
            restoreInput.append(contentsOf: catchUp.filter {
                $0.seq > historyLastSeq
            })
            guard let restored = await self.historyProjectionBuilder.build(restoreInput),
                  !Task.isCancelled else {
                return
            }
            var state = restored
            var lastAppliedSeq = restoreInput.last?.seq ?? -1
            if self.errorText == self.historyReplayErrorText {
                self.errorText = nil
            }
            self.historyReplayErrorText = nil
            self.publish(state)
            for await envelope in stream {
                guard !Task.isCancelled else { return }
                guard envelope.seq > lastAppliedSeq else { continue }
                state.apply(envelope)
                lastAppliedSeq = envelope.seq
                self.publish(state)
            }
        }
    }

    private func publish(_ state: ChatProjectionState) {
        let restoredMessages = state.conversation.messages
        if messages != restoredMessages {
            messages = restoredMessages
        }
        let restoredArtifacts = state.artifacts
        if artifacts != restoredArtifacts {
            artifacts = restoredArtifacts
        }
        let restoredProgress = state.artifactProgress.active
        if artifactProgress != restoredProgress {
            artifactProgress = restoredProgress
        }
        let restoredStats = state.turnStats.latest
        if latestTurnStats != restoredStats {
            latestTurnStats = restoredStats
        }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Cancels only the currently submitted Chat operation. The process-owned
    /// session runtime, EventLog subscription, and future Send capability stay
    /// alive.
    public func cancelCurrentOperation() {
        runningOperation?.cancel()
        imageGenerationOperation?.cancel()
    }

    /// Permanently stops this session runtime and waits for provider-backed
    /// work to unwind. Hiding or switching a page must not call this method;
    /// the application-level runtime owner uses it only for deletion or quit.
    public func shutdown(reason: String = "Chat session stopped") async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShutdown = true
        let runningSubscription = subscription
        subscription = nil
        runningSubscription?.cancel()
        let runningOperation = runningOperation
        let imageGenerationOperation = imageGenerationOperation
        runningOperation?.cancel()
        imageGenerationOperation?.cancel()
        let task = Task<Void, Never> { @MainActor [weak self] in
            #if canImport(AVFoundation)
            if let self { await self.voiceInput.shutdown() }
            #endif
            if let runningOperation { await runningOperation.value }
            if let imageGenerationOperation { await imageGenerationOperation.value }
            if let runningSubscription { await runningSubscription.value }
        }
        shutdownTask = task
        await task.value
        self.runningOperation = nil
        self.imageGenerationOperation = nil
        isStreaming = false
        if imageGenerationState.isRunning {
            imageGenerationState = .idle
        }
        _ = reason
    }

    /// Send the composed message. Streaming output arrives via the log subscription.
    public func send() {
        guard !isShutdown, !isBusy else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
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
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let startSeq = await self.log.replay().last?.seq ?? -1
            do {
                let route = try await self.registry
                    .chatRuntimeRoute()
                let loop = ChatLoop(
                    log: self.log,
                    provider: route.provider,
                    model: route.model,
                    webSearch: route.webSearch)
                try await loop.send(parsed.text, userMessage: parsed.userMessagePayload)
            } catch {
                if IntatisCancellation.isCurrentTaskCancellation(error) {
                    self.errorText = nil
                } else {
                    let loggedError = await self.hasLoggedError(after: startSeq)
                    self.errorText = loggedError ? nil : error.localizedDescription
                }
            }
            self.isStreaming = false
            self.runningOperation = nil
        }
        runningOperation = operation
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
        guard !isShutdown, !prompt.isEmpty, !isBusy else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
        guard let onGenerateImage else {
            let message = IntatisLocalization.string("Image generation is not available.")
            imageGenerationState = .failed(message)
            errorText = message
            return
        }
        input = ""
        errorText = nil
        imageGenerationState = .running
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onGenerateImage(prompt)
                self.imageGenerationState = .idle
            } catch {
                if IntatisCancellation.isCurrentTaskCancellation(error) {
                    self.imageGenerationState = .idle
                    self.errorText = nil
                    if self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.input = prompt
                    }
                    self.imageGenerationOperation = nil
                    return
                }
                let message = IntatisLocalization.format(
                    "Image generation failed: %@",
                    error.localizedDescription)
                self.errorText = message
                self.imageGenerationState = .failed(message)
                if self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.input = prompt
                }
            }
            self.imageGenerationOperation = nil
        }
        imageGenerationOperation = operation
    }

    #if canImport(AVFoundation)
    public func toggleVoiceInput() {
        guard !isShutdown else { return }
        if !voiceInput.isRecording {
            guard !isBusy else { return }
        }
        voiceInput.toggle { [weak self] transcript in
            guard let self else { return }
            self.input = ComposerVoiceDraft.appending(
                transcript: transcript,
                to: self.input)
        }
    }

    private func observeVoiceInput() {
        voiceInputObservation = voiceInput.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
    #endif
}
#endif
