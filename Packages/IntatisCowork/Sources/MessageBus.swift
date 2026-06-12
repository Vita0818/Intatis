import Foundation
import IntatisCore
import IntatisProtocol
import IntatisConversation

/// The single channel for agent-to-agent traffic. Every message is mediated and
/// logged — there is no other delivery path (ARCHITECTURE.md §3.10 invariant).
public struct MessageBus: Sendable {
    private let log: EventLog
    private let mediator: Mediator

    public init(log: EventLog, mediator: Mediator) {
        self.log = log
        self.mediator = mediator
    }

    /// Mediate + log an `from → to` message. Returns the forwarded (possibly
    /// redacted) content, or `nil` if the mediator blocked it. Either way an audit
    /// record is appended.
    public func deliver(from: AgentID, to: AgentID, content: String) async -> String? {
        switch await mediator.mediate(from: from, to: to, content: content) {
        case .forward(let forwarded):
            try? await log.append(.agentToAgentMessage(
                AgentToAgentMessagePayload(from: from, to: to, content: forwarded, mediated: true)))
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "agent_forward", reviewerModel: "mediator",
                                        decision: .allow, risk: .low, reason: "forwarded after mediation")))
            return forwarded
        case .block(let reason):
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "agent_forward", reviewerModel: "mediator",
                                        decision: .deny, risk: .high, reason: reason)))
            return nil
        }
    }
}
