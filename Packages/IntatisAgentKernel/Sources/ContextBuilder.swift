import Foundation
import IntatisProtocol
import IntatisProviders
import IntatisTools

/// Builds the model request: system prompt + tool specs + message history.
public struct ContextBuilder: Sendable {
    public let systemPrompt: String
    public let taskContract: TaskContract?
    public let contextBundle: ContextBundle?

    public init(systemPrompt: String = ContextBuilder.defaultSystemPrompt,
                taskContract: TaskContract? = nil,
                contextBundle: ContextBundle? = nil) {
        self.systemPrompt = systemPrompt
        self.taskContract = taskContract
        self.contextBundle = contextBundle
    }

    public static let defaultSystemPrompt = """
    You are an Intatis coding agent working inside a single local workspace.
    Use the provided tools to read, search, and edit files. Prefer small, focused
    changes. Read before you write. When you are done, briefly explain what you did.
    Never attempt to access files outside the workspace or read secrets.
    """

    /// Role-aware prompt for an agent in a multi-agent (Cowork) session. The
    /// current task lease decides whether coordinator behavior is available;
    /// `coordinationDepth` remains only as a compatibility safety fuse.
    public static func coworkSystemPrompt(name: String,
                                          folder: String,
                                          coordinationDepth: Int,
                                          canCoordinate: Bool? = nil) -> String {
        var prompt = defaultSystemPrompt + "\n\nYou are agent @\(name), working in \(folder)."
        if canCoordinate ?? (coordinationDepth > 0) {
            prompt += """


            You may also act as a COORDINATOR. You hold the agent-coordination tools
            delegate_task, request_information, send_message, reply_message, spawn_agent,
            list_agents and remove_agent. ask_agent exists only as a compatibility wrapper.
            Build a small team by spawning sub-agents bound to specific folders, delegate
            one concrete sub-task to each with delegate_task, then synthesize their task reports.
            Task-scoped sub-agents are recycled by the orchestrator when idle; use remove_agent
            only to cancel or clean up an agent early.
            Reach other agents only through the provided communication/delegation tools,
            so send concise, self-contained instructions — never raw file contents.

            Delegation is bounded by the current task capability lease. Agents you create are
            workers by default and do not receive agent-coordination tools. Prefer
            doing the work yourself — delegate only when a task is large or naturally
            splits across folders, and never spawn a helper for something you can
            finish directly in a step or two.
            """
        } else {
            prompt += """


            You are executing the assigned task as a worker agent.
            Do not create, remove, or coordinate other agents.
            Do not re-run the global task decomposition.
            If you need help, report that need to the assigning agent or user, or use request_delegation when that tool is available.
            Only reply to task-related messages when reply_message is available.
            Complete the task with your available tools, then reply with a concise, self-contained answer.
            """
        }
        return prompt
    }

    public static func taskContractPrompt(_ contract: TaskContract) -> String {
        var lines: [String] = [
            "",
            "Current task:",
            "- Task ID: \(contract.id.rawValue)",
            "- Assigned by: \(contract.issuer.map { "@\($0.rawValue)" } ?? "user")",
            "- Assignee: @\(contract.assignee.rawValue)",
            "- Task kind: \(contract.kind.rawValue)",
            "- Your role in this task: \(contract.roleHint)",
            "- Objective: \(contract.objective)",
            "- Expected deliverable: \(contract.expectedDeliverable)",
        ]
        if let parentTaskID = contract.parentTaskID {
            lines.append("- Parent task ID: \(parentTaskID.rawValue)")
        }
        if let workspaceID = contract.workspaceID {
            lines.append("- Workspace ID: \(workspaceID.rawValue)")
        }
        if let workspaceLeaseID = contract.workspaceLeaseID {
            lines.append("- Workspace lease ID: \(workspaceLeaseID.rawValue)")
        }
        if let capabilityLeaseID = contract.capabilityLeaseID {
            lines.append("- Capability lease ID: \(capabilityLeaseID.rawValue)")
        }
        if !contract.relatedAgents.isEmpty {
            let related = contract.relatedAgents.map { "@\($0.rawValue)" }.joined(separator: ", ")
            lines.append("- Related agents: \(related)")
        }
        if !contract.relatedTasks.isEmpty {
            lines.append("- Related tasks: \(contract.relatedTasks.map(\.rawValue).joined(separator: ", "))")
        }
        if !contract.constraints.isEmpty {
            lines.append("- Constraints:")
            lines.append(contentsOf: contract.constraints.map { "  - \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    public static func contextBundlePrompt(_ bundle: ContextBundle) -> String {
        var lines: [String] = [
            "",
            "Scoped context:",
            "- Global brief: \(bundle.globalBrief)",
            "- Safety policy: \(bundle.safetyPolicy)",
        ]

        if let contract = bundle.taskContract {
            lines.append(taskContractPrompt(contract))
        }

        if !bundle.lineage.isEmpty {
            lines.append("")
            lines.append("Lineage:")
            lines.append(contentsOf: bundle.lineage.map { "- \($0.text)" })
        }

        if !bundle.allowedToolNames.isEmpty {
            lines.append("")
            lines.append("Allowed tools:")
            lines.append(contentsOf: bundle.allowedToolNames.map { "- \($0)" })
        }

        if !bundle.directMessages.isEmpty {
            lines.append("")
            lines.append("Relevant direct messages:")
            lines.append(contentsOf: bundle.directMessages.map { event in
                let sender = event.sender.map { "@\($0.rawValue)" } ?? "unknown"
                return "- \(sender): \(event.content)"
            })
        }

        if !bundle.agentLocalEvents.isEmpty {
            lines.append("")
            lines.append("Agent-local history:")
            lines.append(contentsOf: bundle.agentLocalEvents.map { event in
                "- \(event.kind): \(event.content)"
            })
        }

        if !bundle.explicitlySharedArtifacts.isEmpty {
            lines.append("")
            lines.append("Explicitly shared artifacts:")
            lines.append(contentsOf: bundle.explicitlySharedArtifacts.map { "- \($0.rawValue)" })
        }

        if let workspaceBrief = bundle.workspaceBrief, !workspaceBrief.isEmpty {
            lines.append("")
            lines.append("Workspace brief:")
            lines.append("- \(workspaceBrief)")
        }

        return lines.joined(separator: "\n")
    }

    /// Tool specs derived from a registry's descriptors.
    public func toolSpecs(_ registry: ToolRegistry) -> [ToolSpec] {
        registry.descriptors().map {
            ToolSpec(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
    }

    /// system + prior history + the new user turn (optionally with images).
    public func initialMessages(history: [AgentMessage], userText: String,
                                userImages: [ImageAttachment] = []) -> [AgentMessage] {
        let prompt: String
        if let contextBundle {
            prompt = systemPrompt + ContextBuilder.contextBundlePrompt(contextBundle)
        } else if let taskContract {
            prompt = systemPrompt + ContextBuilder.taskContractPrompt(taskContract)
        } else {
            prompt = systemPrompt
        }
        var messages: [AgentMessage] = [.system(prompt)]
        messages.append(contentsOf: history)
        messages.append(.user(userText, images: userImages))
        return messages
    }
}
