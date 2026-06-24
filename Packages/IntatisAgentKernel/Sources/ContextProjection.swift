import Foundation
import IntatisCore
import IntatisProtocol

public struct LineageItem: Codable, Sendable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ContextEventSummary: Codable, Sendable, Hashable {
    public var seq: Int
    public var kind: String
    public var sender: AgentID?
    public var recipient: AgentID?
    public var agent: AgentID?
    public var taskID: TaskID?
    public var content: String

    public init(seq: Int,
                kind: String,
                sender: AgentID? = nil,
                recipient: AgentID? = nil,
                agent: AgentID? = nil,
                taskID: TaskID? = nil,
                content: String) {
        self.seq = seq
        self.kind = kind
        self.sender = sender
        self.recipient = recipient
        self.agent = agent
        self.taskID = taskID
        self.content = content
    }
}

public struct ContextBundle: Codable, Sendable, Hashable {
    public var globalBrief: String
    public var safetyPolicy: String
    public var taskContract: TaskContract?
    public var lineage: [LineageItem]
    public var directMessages: [ContextEventSummary]
    public var agentLocalEvents: [ContextEventSummary]
    public var explicitlySharedArtifacts: [ArtifactID]
    public var workspaceBrief: String?
    public var allowedToolNames: [String]

    public init(globalBrief: String,
                safetyPolicy: String,
                taskContract: TaskContract? = nil,
                lineage: [LineageItem] = [],
                directMessages: [ContextEventSummary] = [],
                agentLocalEvents: [ContextEventSummary] = [],
                explicitlySharedArtifacts: [ArtifactID] = [],
                workspaceBrief: String? = nil,
                allowedToolNames: [String] = []) {
        self.globalBrief = globalBrief
        self.safetyPolicy = safetyPolicy
        self.taskContract = taskContract
        self.lineage = lineage
        self.directMessages = directMessages
        self.agentLocalEvents = agentLocalEvents
        self.explicitlySharedArtifacts = explicitlySharedArtifacts
        self.workspaceBrief = workspaceBrief
        self.allowedToolNames = allowedToolNames
    }
}

public struct ContextProjector: Sendable {
    public init() {}

    public func project(agentID: AgentID,
                        taskContract: TaskContract?,
                        events: [Envelope],
                        allowedToolNames: [String],
                        workspaceRoot: URL?) -> ContextBundle {
        let globalBrief = Self.globalBrief(from: events)
        let lineage = Self.lineage(for: agentID, taskContract: taskContract, globalBrief: globalBrief)
        let directMessages = Self.directMessages(for: agentID, events: events)
        let agentLocalEvents = Self.agentLocalEvents(for: agentID, events: events)
        let artifacts = Self.sharedArtifacts(from: events)
        return ContextBundle(
            globalBrief: globalBrief,
            safetyPolicy: "Follow workspace confinement, permission policy, and the current task constraints.",
            taskContract: taskContract,
            lineage: lineage,
            directMessages: directMessages,
            agentLocalEvents: agentLocalEvents,
            explicitlySharedArtifacts: artifacts,
            workspaceBrief: workspaceRoot.map { "Workspace root: \($0.path)" },
            allowedToolNames: allowedToolNames.sorted())
    }

    private static func globalBrief(from events: [Envelope]) -> String {
        for envelope in events {
            if case .userMessage(let payload) = envelope.event {
                let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return truncate(text, maxCharacters: 280)
                }
            }
        }
        return "No global user objective was recorded before this task."
    }

    private static func lineage(for agentID: AgentID,
                                taskContract: TaskContract?,
                                globalBrief: String) -> [LineageItem] {
        guard let contract = taskContract else {
            return [
                LineageItem(text: "Global objective brief: \(globalBrief)"),
                LineageItem(text: "@\(agentID.rawValue) is handling the current user-directed turn."),
            ]
        }

        var items: [LineageItem] = [
            LineageItem(text: "User objective brief: \(globalBrief)"),
            LineageItem(text: "\(contract.issuer.map { "@\($0.rawValue)" } ?? "The user") assigned task \(contract.id.rawValue) to @\(contract.assignee.rawValue)."),
            LineageItem(text: "@\(contract.assignee.rawValue) is responsible only for: \(contract.objective)"),
            LineageItem(text: "Task role hint: \(contract.roleHint)."),
            LineageItem(text: "Expected deliverable: \(contract.expectedDeliverable)."),
        ]

        if !contract.relatedAgents.isEmpty {
            let related = contract.relatedAgents.map { "@\($0.rawValue)" }.joined(separator: ", ")
            items.append(LineageItem(text: "Related agents in the task group: \(related)."))
        }
        if let parentTaskID = contract.parentTaskID {
            items.append(LineageItem(text: "Parent task: \(parentTaskID.rawValue)."))
        }
        return items
    }

    private static func directMessages(for agentID: AgentID, events: [Envelope]) -> [ContextEventSummary] {
        events.compactMap { envelope in
            switch envelope.event {
            case .agentToAgentMessage(let payload) where payload.to == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "agent_to_agent_message",
                    sender: payload.from,
                    recipient: payload.to,
                    content: truncate(payload.content, maxCharacters: 600))
            case .agentMessage(let payload) where payload.to == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: payload.kind?.rawValue ?? "agent_message",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: truncate(payload.content, maxCharacters: 600))
            case .informationRequested(let payload) where payload.to == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_requested",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: truncate(payload.question, maxCharacters: 600))
            case .informationReplied(let payload) where payload.to == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_replied",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: truncate(payload.content, maxCharacters: 600))
            default:
                return nil
            }
        }
    }

    private static func agentLocalEvents(for agentID: AgentID, events: [Envelope]) -> [ContextEventSummary] {
        events.compactMap { envelope in
            switch envelope.event {
            case .agentToAgentMessage(let payload) where payload.from == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "agent_to_agent_message_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    content: truncate(payload.content, maxCharacters: 600))
            case .agentMessage(let payload) where payload.from == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: payload.kind?.rawValue ?? "agent_message_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: truncate(payload.content, maxCharacters: 600))
            case .informationRequested(let payload) where payload.from == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_requested_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: truncate(payload.question, maxCharacters: 600))
            case .informationReplied(let payload) where payload.from == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_replied_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: truncate(payload.content, maxCharacters: 600))
            case .delegationRequested(let payload) where payload.requester == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "delegation_requested",
                    sender: payload.requester,
                    recipient: payload.recipient,
                    taskID: payload.parentTaskID,
                    content: "\(truncate(payload.objective, maxCharacters: 300)) — \(truncate(payload.reason, maxCharacters: 300))")
            case .messageCompleted(let payload) where payload.agent == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "agent_message_completed",
                    agent: payload.agent,
                    content: truncate(payload.text, maxCharacters: 600))
            case .toolCall(let payload) where payload.agent == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "tool_call",
                    agent: payload.agent,
                    content: "\(payload.name): \(truncate(payload.args, maxCharacters: 300))")
            case .taskAssigned(let payload) where payload.contract.assignee == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_assigned",
                    agent: agentID,
                    taskID: payload.contract.id,
                    content: truncate(payload.contract.objective, maxCharacters: 600))
            case .taskStarted(let payload) where payload.agent == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_started",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: "Task started.")
            case .taskCompleted(let payload) where payload.agent == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_completed",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: truncate(payload.result, maxCharacters: 600))
            case .taskFailed(let payload) where payload.agent == agentID:
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_failed",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: truncate(payload.error, maxCharacters: 600))
            default:
                return nil
            }
        }
    }

    private static func sharedArtifacts(from events: [Envelope]) -> [ArtifactID] {
        events.compactMap { envelope in
            if case .artifactAdded(let payload) = envelope.event {
                return payload.artifactId
            }
            return nil
        }
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<index]) + "..."
    }
}
