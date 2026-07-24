import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

/// The tool-free chat loop (ARCHITECTURE.md §3.4). Lives in Conversation — not
/// in the Agent Kernel — so the iOS subset and the Chat surface get streaming
/// chat without linking any tools, permissions, or workspace code (§4).
///
/// It reconstructs history from the log, appends the user turn, streams the
/// assistant reply as `message_delta` events, and finalizes with
/// `message_completed`. Every state change goes through the event log.
public struct ChatLoop: Sendable {
    private let log: EventLog
    private let provider: ChatProvider
    private let model: ModelID
    private let systemPrompt: String?
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool

    public init(log: EventLog, provider: ChatProvider, model: ModelID,
                systemPrompt: String? = nil, reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false) {
        self.log = log
        self.provider = provider
        self.model = model
        self.systemPrompt = systemPrompt
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
    }

    /// Send one user message and stream the assistant reply into the log.
    public func send(_ userText: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil) async throws {
        let turnID = TurnID.new()
        let submissionID = userMessage?.submissionID
        let history = await buildHistory()
        try await log.append(.userMessage(userMessage ?? UserMessagePayload(text: userText)))

        var messages: [ChatMessage] = []
        if let systemPrompt { messages.append(ChatMessage(role: .system, content: systemPrompt)) }
        messages.append(contentsOf: history)
        messages.append(ChatMessage(role: .user, content: userText, images: images))

        let assistantID = MessageID.new()
        var full = ""
        let start = Date()
        var firstTokenAt: Date?
        var usage: Usage?
        do {
            let request = ChatRequest(model: model, messages: messages,
                                      reasoningEffort: reasoningEffort, includeUsage: includeUsage)
            for try await chunk in provider.stream(request) {
                switch chunk {
                case .delta(let d):
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    full += d
                    try await log.append(.messageDelta(
                        MessageDeltaPayload(messageId: assistantID, role: .assistant, textDelta: d)))
                case .usage(let u):
                    usage = Usage.merging(usage, with: u)
                case .done:
                    break
                }
            }
            // A transport can finish its stream while cancellation is racing
            // the final callback. Never turn a user Stop into a completed
            // partial assistant message.
            try Task.checkCancellation()
            try await log.append(.messageCompleted(
                MessageCompletedPayload(messageId: assistantID, role: .assistant, text: full)))
            await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
            try Task.checkCancellation()
            try await log.append(.turnOutcome(TurnOutcomePayload(
                turnID: turnID,
                outcome: .completed,
                submissionID: submissionID)))
        } catch {
            let interrupted = IntatisCancellation.isCurrentTaskCancellation(error)
            if !interrupted {
                let payload: ErrorPayload
                if IntatisCancellation.isCancellationSignal(error) {
                    // A provider-originated CancellationError is not evidence
                    // that the user cancelled this turn.
                    payload = ErrorPayload(
                        code: "runtime_failed",
                        message: "The provider or runtime ended with an unexpected cancellation signal.")
                } else {
                    payload = RuntimeErrorPresentation.payload(
                        for: error,
                        fallbackCode: "provider")
                }
                _ = try? await log.append(.error(payload))
            }
            let diagnostic = PermissionReviewTextSanitizer.sanitizeDiagnostic(
                error.localizedDescription,
                maxCharacters: 512).text
            _ = try? await log.append(.turnOutcome(TurnOutcomePayload(
                turnID: turnID,
                outcome: interrupted ? .interrupted : .failed,
                failureSource: interrupted ? .turnCancelled : .runtimeFailed,
                reason: diagnostic,
                submissionID: submissionID)))
            throw error
        }
    }

    private func appendTurnStats(start: Date, firstTokenAt: Date?, usage: Usage?) async {
        let now = Date()
        try? await log.append(.turnStats(TurnStatsPayload(
            promptTokens: usage?.promptTokens,
            cachedPromptTokens: usage?.cachedPromptTokens,
            completionTokens: usage?.completionTokens,
            totalTokens: usage?.totalTokens,
            contextWindowTokens: usage?.contextWindowTokens,
            ttftMillis: firstTokenAt.map { Int($0.timeIntervalSince(start) * 1000) },
            totalMillis: Int(now.timeIntervalSince(start) * 1000),
            model: model.rawValue)))
    }

    /// Rebuild prior turns from the log as provider-shaped messages.
    private func buildHistory() async -> [ChatMessage] {
        let projection = ConversationProjection.build(from: await log.replay())
        return projection.messages.compactMap { m in
            switch m.role {
            case .user:
                return ChatMessage(role: .user, content: m.text)
            case .assistant, .agent:
                return m.isComplete ? ChatMessage(role: .assistant, content: m.text) : nil
            case .system:
                return nil
            }
        }
    }
}
