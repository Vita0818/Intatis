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
    /// Temporary compatibility fuse for Cowork coordination tools. Explicit
    /// coordinators get the coordination tools while this is > 0; tool-spawned
    /// children default to 0 and run as workers.
    public var coordinationDepth: Int

    /// Default marker for a top-level coordinator (@main, user-added agents).
    /// Phase 0 still uses this as a tool-exposure fuse, not as a task role model.
    public static let defaultCoordinationDepth = 2

    public init(name: AgentID, workspaceRoot: URL, model: ModelID,
                profile: PermissionProfile = .reviewed, coordinationDepth: Int = 0) {
        self.name = name
        self.workspaceRoot = workspaceRoot
        self.model = model
        self.profile = profile
        self.coordinationDepth = coordinationDepth
    }
}
