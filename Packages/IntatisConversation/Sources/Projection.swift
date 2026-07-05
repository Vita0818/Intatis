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
    public var tags: [String]
    public var goal: String?
    public var recoveryAdvice: RuntimeRecoveryAdvice?

    public init(id: MessageID,
                role: MessageRole,
                agent: AgentID? = nil,
                text: String,
                isComplete: Bool,
                tags: [String] = [],
                goal: String? = nil,
                recoveryAdvice: RuntimeRecoveryAdvice? = nil) {
        self.id = id
        self.role = role
        self.agent = agent
        self.text = text
        self.isComplete = isComplete
        self.tags = tags
        self.goal = goal
        self.recoveryAdvice = recoveryAdvice
    }
}

/// Folds an event stream into renderable messages. The UI consumes *this*, never
/// raw model text (ARCHITECTURE.md §1.2 principle A / §3.11).
public struct ConversationProjection: Equatable, Sendable {
    public private(set) var messages: [ChatMessageView] = []

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        apply(envelope.event) { suffix in
            MessageID(rawValue: "msg_\(envelope.session.rawValue)_\(envelope.seq)_\(suffix)")
        }
    }

    public mutating func apply(_ event: Event) {
        apply(event) { _ in MessageID.new() }
    }

    private mutating func apply(_ event: Event, syntheticID: (String) -> MessageID) {
        switch event {
        case .userMessage(let p):
            messages.append(ChatMessageView(id: syntheticID("user"),
                                            role: .user,
                                            text: p.text,
                                            isComplete: true,
                                            tags: p.tags ?? [],
                                            goal: p.goal))

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
            markCurrentPartialMessageStopped(with: p)
            messages.append(ChatMessageView(id: syntheticID("error"), role: .system,
                                            text: "⚠️ \(p.message)", isComplete: true,
                                            recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(for: p)))

        case .artifactAdded(let p):
            messages.append(ChatMessageView(id: syntheticID("artifact"), role: .system,
                                            text: "📎 \(p.kind) artifact" + (p.prompt.map { ": \($0)" } ?? ""),
                                            isComplete: true))

        case .toolCall, .toolResult, .permissionRequest, .permissionResolved, .patchProposed, .agentStatus,
             .agentAttached, .agentAttachRequested, .agentDetached, .agentSpawnRequested, .agentSpawned,
             .agentMessage, .agentToAgentMessage, .permissionReview,
             .informationRequested, .informationReplied,
             .delegationRequested, .delegationApproved, .delegationRejected, .taskDelegated,
             .workspaceLeaseRequested, .workspaceLeaseGranted, .workspaceLeaseDenied,
             .capabilityLeaseCreated, .capabilityLeaseRevoked,
             .taskCreated, .taskAssigned, .taskQueued, .taskStarted, .taskCompleted, .taskFailed, .taskRejected,
             .artifactProgress, .turnStats:
            break   // tool/permission/agent/task/progress/stats events are not shown in the chat text view
        }
    }

    /// Convenience: build a full projection from a sequence of envelopes.
    public static func build(from envelopes: [Envelope]) -> ConversationProjection {
        var p = ConversationProjection()
        for e in envelopes { p.apply(e) }
        return p
    }

    private mutating func markCurrentPartialMessageStopped(with payload: ErrorPayload) {
        guard let index = messages.indices.last else { return }
        guard !messages[index].isComplete else { return }
        switch messages[index].role {
        case .assistant, .agent:
            messages[index].recoveryAdvice = RuntimeErrorPresentation.partialResponseAdvice(for: payload)
        case .user, .system:
            break
        }
    }
}
