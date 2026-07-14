import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// Coordinator tools (ARCHITECTURE.md §7). They let an explicit lead agent build
/// and steer a small team of worker agents. Their structured PermissionIntent
/// separates control-plane admission from later workspace file operations.

/// Create + attach a new sub-agent bound to a folder.
public struct SpawnAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "spawn_agent",
        description: "Create a new sub-agent bound to a folder so you can delegate work to it. "
            + "Give it a short name and an absolute folder path; model is optional (defaults to "
            + "yours). Set canCoordinate only when this sub-agent must manage lower-level agents. "
            + "New agents are read-only unless requestedAccess is explicitly read_write. "
            + "After spawning, assign work with delegate_task; the orchestrator recycles task-scoped agents when idle.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("short agent name, e.g. reviewer")]),
                "path": .object(["type": .string("string"),
                                 "description": .string("absolute path to the agent's workspace folder")]),
                "model": .object(["type": .string("string"),
                                  "description": .string("optional model id; defaults to your model")]),
                "requestedAccess": .object([
                    "type": .string("string"),
                    "enum": .array([.string("read_only"), .string("read_write")]),
                    "description": .string("optional workspace ceiling; defaults to read_only"),
                ]),
                "canCoordinate": .object(["type": .string("boolean"),
                                           "description": .string("optional; true grants coordinator tools to this sub-agent")]),
            ]),
            "required": .array([.string("name"), .string("path")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable {
        let name: String
        let path: String
        let model: String?
        let requestedAccess: WorkspaceAccess?
        let canCoordinate: Bool?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        // The target is a workspace admission resource, not a file path that
        // this invocation reads or writes. The orchestrator separately
        // canonicalizes and assesses it before committing the admission.
        []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? args.decode(Args.self) else {
            return .derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: [],
                risksNetwork: false)
        }
        let requestedAccess = value.requestedAccess ?? .readOnly
        var risks: Set<PermissionRisk> = [.controlPlaneMutation, .capabilityGrant, .modelCost]
        if !PathConfinement.isWithin(value.path, root: workspaceRoot) {
            risks.insert(.workspaceExpansion)
        }
        if requestedAccess == .readWrite {
            risks.insert(.workspaceMutation)
        }
        return PermissionIntent(
            action: "agent.spawn",
            resources: [
                PermissionResource(kind: .agent, value: value.name),
                PermissionResource(kind: .workspace, value: value.path, access: requestedAccess),
            ],
            metadata: [
                "model": value.model.map(JSONValue.string) ?? .null,
                "requestedAccess": .string(requestedAccess.rawValue),
                "canCoordinate": .bool(value.canCoordinate ?? false),
            ],
            dataEffects: [.none],
            controlEffects: [.createAgent, .grantCapability],
            risks: risks,
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.spawnAgent(
            name: a.name,
            path: a.path,
            model: a.model,
            requestedAccess: a.requestedAccess ?? .readOnly,
            canCoordinate: a.canCoordinate ?? false))
    }
}

/// List the agents active in this conversation.
public struct ListAgentsTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "list_agents",
        description: "List active agents with name, model, coordinator/worker lease role, compact task state, and folder.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "agent.list",
            resources: [PermissionResource(kind: .agent, value: "thread")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

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
        description: "Remove a sub-agent early. Completed task-scoped sub-agents are recycled automatically. You cannot remove @main.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("the agent name to remove")]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let name: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let name = (try? args.decode(Args.self))?.name ?? "unknown"
        return PermissionIntent(
            action: "agent.remove",
            resources: [PermissionResource(kind: .agent, value: name)],
            dataEffects: [.none],
            controlEffects: [.removeAgent],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.removeAgent(name: a.name))
    }
}
