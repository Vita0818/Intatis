import Foundation

/// The three Intatis product surfaces. A surface is a *policy* over the same
/// kernel, not a separate codebase (ARCHITECTURE.md §1.2, principle C).
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case chat
    case code
    case cowork

    /// Whether this surface binds local workspaces and runs tools.
    public var usesWorkspace: Bool {
        switch self {
        case .chat: return false
        case .code, .cowork: return true
        }
    }
}
