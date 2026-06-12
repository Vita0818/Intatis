import Foundation
import IntatisCore

// Event payloads for v0.3 (Cowork): multi-agent attach, agent messages,
// mediated agent-to-agent messages, and reviewer audit records.

public struct AgentAttachedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var path: String
    public var model: ModelID
    public var profile: String
    public init(agent: AgentID, path: String, model: ModelID, profile: String) {
        self.agent = agent
        self.path = path
        self.model = model
        self.profile = profile
    }
}

public struct AgentDetachedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public init(agent: AgentID) { self.agent = agent }
}

public struct AgentMessagePayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var messageId: MessageID
    public var content: String
    public init(agent: AgentID, messageId: MessageID, content: String) {
        self.agent = agent
        self.messageId = messageId
        self.content = content
    }
}

/// A message routed between two agents. Always mediated through the Message Bus
/// and always logged (ARCHITECTURE.md §7, §6.5). `content` is the post-mediation
/// (redacted/summarized) text — raw file bytes never appear here.
public struct AgentToAgentMessagePayload: Codable, Equatable, Sendable {
    public var from: AgentID
    public var to: AgentID
    public var content: String
    public var mediated: Bool
    public init(from: AgentID, to: AgentID, content: String, mediated: Bool) {
        self.from = from
        self.to = to
        self.content = content
        self.mediated = mediated
    }
}

/// Audit record of an automatic permission decision (gate `pass` → reviewer).
public struct PermissionReviewPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var tool: String
    public var reviewerModel: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var reason: String
    public init(agent: AgentID? = nil, tool: String, reviewerModel: String,
                decision: PermissionDecision, risk: RiskLevel, reason: String) {
        self.agent = agent
        self.tool = tool
        self.reviewerModel = reviewerModel
        self.decision = decision
        self.risk = risk
        self.reason = reason
    }
}
