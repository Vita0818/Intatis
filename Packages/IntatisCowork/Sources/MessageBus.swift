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
            do {
                try await log.append(.agentToAgentMessage(
                    AgentToAgentMessagePayload(from: from, to: to, content: forwarded, mediated: true)))
            } catch {
                return nil
            }
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

    public func sendMessage(from: AgentID,
                            to: AgentID,
                            content: String,
                            taskID: TaskID? = nil,
                            messageID: MessageID = MessageID.new()) async -> AgentMessagePayload? {
        switch await mediator.mediate(from: from, to: to, content: content) {
        case .forward(let forwarded):
            let payload = AgentMessagePayload(
                from: from,
                to: to,
                content: forwarded,
                kind: .sendMessage,
                messageId: messageID,
                taskID: taskID,
                mediated: true)
            do {
                try await log.append(.agentMessage(payload))
            } catch {
                return nil
            }
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "send_message", reviewerModel: "mediator",
                                        decision: .allow, risk: .low, reason: "forwarded after mediation")))
            return payload
        case .block(let reason):
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "send_message", reviewerModel: "mediator",
                                        decision: .deny, risk: .high, reason: reason)))
            return nil
        }
    }

    public func requestInformation(from: AgentID,
                                   to: AgentID,
                                   question: String,
                                   taskID: TaskID? = nil,
                                   requestID: MessageID = MessageID.new()) async -> InformationRequestedPayload? {
        switch await mediator.mediate(from: from, to: to, content: question) {
        case .forward(let forwarded):
            let payload = InformationRequestedPayload(
                requestID: requestID,
                from: from,
                to: to,
                question: forwarded,
                mediated: true,
                taskID: taskID)
            do {
                try await log.append(.informationRequested(payload))
            } catch {
                return nil
            }
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "request_information", reviewerModel: "mediator",
                                        decision: .allow, risk: .low, reason: "forwarded after mediation")))
            return payload
        case .block(let reason):
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "request_information", reviewerModel: "mediator",
                                        decision: .deny, risk: .high, reason: reason)))
            return nil
        }
    }

    public func replyMessage(from: AgentID,
                             to: AgentID,
                             content: String,
                             inReplyTo: MessageID?,
                             taskID: TaskID? = nil,
                             replyID: MessageID = MessageID.new()) async -> InformationRepliedPayload? {
        switch await mediator.mediate(from: from, to: to, content: content) {
        case .forward(let forwarded):
            let payload = InformationRepliedPayload(
                replyID: replyID,
                inReplyTo: inReplyTo,
                from: from,
                to: to,
                content: forwarded,
                mediated: true,
                taskID: taskID)
            do {
                try await log.append(.informationReplied(payload))
            } catch {
                return nil
            }
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "reply_message", reviewerModel: "mediator",
                                        decision: .allow, risk: .low, reason: "forwarded after mediation")))
            return payload
        case .block(let reason):
            try? await log.append(.permissionReview(
                PermissionReviewPayload(agent: from, tool: "reply_message", reviewerModel: "mediator",
                                        decision: .deny, risk: .high, reason: reason)))
            return nil
        }
    }
}
