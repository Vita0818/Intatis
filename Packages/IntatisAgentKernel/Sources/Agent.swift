import Foundation
import IntatisCore
import IntatisPermission

/// A single agent: a workspace-bound, tool-using loop with its own permission
/// profile. It has no awareness of whether it is alone (Code) or one of many
/// (Cowork) — that lives one layer up (ARCHITECTURE.md §1.2 principle D).
public struct Agent: Sendable {
    public var name: AgentID
    public var workspaceRoot: URL
    public var model: ModelID
    public var profile: PermissionProfile
    /// May this agent build & steer its own sub-team (spawn_agent / ask_agent /
    /// list_agents / remove_agent)? Only top-level coordinators (@main and
    /// user-added agents) get this; tool-spawned workers do not, which keeps the
    /// orchestrator-worker hierarchy two levels deep instead of recursing.
    public var canCoordinate: Bool

    public init(name: AgentID, workspaceRoot: URL, model: ModelID,
                profile: PermissionProfile = .reviewed, canCoordinate: Bool = false) {
        self.name = name
        self.workspaceRoot = workspaceRoot
        self.model = model
        self.profile = profile
        self.canCoordinate = canCoordinate
    }
}
