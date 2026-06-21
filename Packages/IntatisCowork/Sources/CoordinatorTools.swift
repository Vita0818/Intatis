import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// Coordinator tools (ARCHITECTURE.md §7). They let a lead agent build and steer
/// a small team of sub-agents itself, instead of the user wiring everything up by
/// hand. This mirrors the "supervisor / orchestrator-worker" pattern used by
/// frameworks like LangGraph, CrewAI, AutoGen and OpenAI Swarm: one agent owns
/// the plan and delegates concrete sub-tasks. All three are `readOnly` — they
/// only touch the in-memory agent registry, never the filesystem; the agents they
/// create still run under the normal permission gate.

/// Create + attach a new sub-agent bound to a folder.
public struct SpawnAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "spawn_agent",
        description: "Create a new sub-agent bound to a folder so you can delegate work to it. "
            + "Give it a short name and an absolute folder path; model is optional (defaults to "
            + "yours). After spawning, talk to it with ask_agent.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("short agent name, e.g. reviewer")]),
                "path": .object(["type": .string("string"),
                                 "description": .string("absolute path to the agent's workspace folder")]),
                "model": .object(["type": .string("string"),
                                  "description": .string("optional model id; defaults to your model")]),
            ]),
            "required": .array([.string("name"), .string("path")]),
        ])
    )

    struct Args: Decodable { let name: String; let path: String; let model: String? }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.spawnAgent(name: a.name, path: a.path, model: a.model))
    }
}

/// List the agents active in this conversation.
public struct ListAgentsTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "list_agents",
        description: "List the agents currently active in this conversation (name, model, folder).",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.listAgents())
    }
}

/// Detach a sub-agent you no longer need.
public struct RemoveAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "remove_agent",
        description: "Remove a sub-agent you no longer need. You cannot remove @main.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("the agent name to remove")]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    struct Args: Decodable { let name: String }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.removeAgent(name: a.name))
    }
}
