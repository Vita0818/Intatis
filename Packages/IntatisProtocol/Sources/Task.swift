import Foundation
import IntatisCore

public enum TaskKind: String, Codable, Sendable, Hashable {
    case root
    case agentInvocation = "agent_invocation"
}

public enum TaskStatus: String, Codable, Sendable, Hashable {
    case created
    case assigned
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct TaskContract: Codable, Sendable, Hashable {
    public var id: TaskID
    public var kind: TaskKind
    public var issuer: AgentID?
    public var assignee: AgentID
    public var parentTaskID: TaskID?

    public var objective: String
    public var roleHint: String
    public var expectedDeliverable: String

    public var workspaceID: WorkspaceID?
    public var workspaceLeaseID: WorkspaceLeaseID?
    public var capabilityLeaseID: CapabilityLeaseID?
    public var relatedAgents: [AgentID]
    public var relatedTasks: [TaskID]
    public var constraints: [String]

    public init(id: TaskID = TaskID.new(),
                kind: TaskKind = .agentInvocation,
                issuer: AgentID?,
                assignee: AgentID,
                parentTaskID: TaskID? = nil,
                objective: String,
                roleHint: String,
                expectedDeliverable: String,
                workspaceID: WorkspaceID? = nil,
                workspaceLeaseID: WorkspaceLeaseID? = nil,
                capabilityLeaseID: CapabilityLeaseID? = nil,
                relatedAgents: [AgentID] = [],
                relatedTasks: [TaskID] = [],
                constraints: [String] = []) {
        self.id = id
        self.kind = kind
        self.issuer = issuer
        self.assignee = assignee
        self.parentTaskID = parentTaskID
        self.objective = objective
        self.roleHint = roleHint
        self.expectedDeliverable = expectedDeliverable
        self.workspaceID = workspaceID
        self.workspaceLeaseID = workspaceLeaseID
        self.capabilityLeaseID = capabilityLeaseID
        self.relatedAgents = relatedAgents
        self.relatedTasks = relatedTasks
        self.constraints = constraints
    }
}
