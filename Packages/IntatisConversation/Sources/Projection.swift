import Foundation
import IntatisCore
import IntatisProtocol

/// A message as the UI shows it — the result of folding events. Streaming deltas
/// accumulate into `text`; `isComplete` flips on `message_completed`.
public struct ChatMessageView: Identifiable, Equatable, Sendable {
    public let id: MessageID
    public var role: MessageRole
    public var agent: AgentID?
    public var text: String
    public var isComplete: Bool

    public init(id: MessageID, role: MessageRole, agent: AgentID? = nil, text: String, isComplete: Bool) {
        self.id = id
        self.role = role
        self.agent = agent
        self.text = text
        self.isComplete = isComplete
    }
}

/// Folds an event stream into renderable messages. The UI consumes *this*, never
/// raw model text (ARCHITECTURE.md §1.2 principle A / §3.11).
public struct ConversationProjection: Equatable, Sendable {
    public private(set) var messages: [ChatMessageView] = []

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        apply(envelope.event)
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .userMessage(let p):
            messages.append(ChatMessageView(id: MessageID.new(), role: .user, text: p.text, isComplete: true))

        case .messageDelta(let p):
            if let i = messages.firstIndex(where: { $0.id == p.messageId }) {
                messages[i].text += p.textDelta
            } else {
                messages.append(ChatMessageView(id: p.messageId, role: p.role, agent: p.agent,
                                                text: p.textDelta, isComplete: false))
            }

        case .messageCompleted(let p):
            if let i = messages.firstIndex(where: { $0.id == p.messageId }) {
                messages[i].text = p.text
                messages[i].isComplete = true
            } else {
                messages.append(ChatMessageView(id: p.messageId, role: p.role, agent: p.agent,
                                                text: p.text, isComplete: true))
            }

        case .error(let p):
            messages.append(ChatMessageView(id: MessageID.new(), role: .system,
                                            text: "⚠️ \(p.message)", isComplete: true))

        case .artifactAdded(let p):
            messages.append(ChatMessageView(id: MessageID.new(), role: .system,
                                            text: "📎 \(p.kind) artifact" + (p.prompt.map { ": \($0)" } ?? ""),
                                            isComplete: true))

        case .toolCall, .toolResult, .permissionRequest, .permissionResolved, .patchProposed, .agentStatus,
             .agentAttached, .agentDetached, .agentMessage, .agentToAgentMessage, .permissionReview,
             .artifactProgress, .turnStats:
            break   // tool/permission/agent/progress/stats events are not shown in the chat text view
        }
    }

    /// Convenience: build a full projection from a sequence of envelopes.
    public static func build(from envelopes: [Envelope]) -> ConversationProjection {
        var p = ConversationProjection()
        for e in envelopes { p.apply(e) }
        return p
    }
}
