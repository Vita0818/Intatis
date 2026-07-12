import Foundation

/// Compile-/launch-time capability envelope for a build.
///
/// This is how the iOS subset and the two macOS distribution builds differ
/// *without forking code* (ARCHITECTURE.md §4, §9.1):
/// - iOS: chat-only, no workspace, no shell.
/// - macOS App Store (sandboxed): all surfaces, workspace yes, **shell no**.
/// - macOS Developer-ID (notarized): all surfaces, workspace yes, shell yes.
///
/// `allowsShell` gates process-backed exec tools such as browser/document
/// backends. Production registries do not model-expose raw `run_shell`.
public struct PlatformProfile: Sendable, Equatable {
    public let surfaces: Set<SessionKind>
    public let allowsWorkspace: Bool
    public let allowsShell: Bool

    public init(surfaces: Set<SessionKind>, allowsWorkspace: Bool, allowsShell: Bool) {
        self.surfaces = surfaces
        self.allowsWorkspace = allowsWorkspace
        self.allowsShell = allowsShell
    }

    public static let iOS = PlatformProfile(
        surfaces: [.chat],
        allowsWorkspace: false,
        allowsShell: false
    )

    public static let macAppStore = PlatformProfile(
        surfaces: [.chat, .code, .cowork],
        allowsWorkspace: true,
        allowsShell: false
    )

    public static let macDeveloperID = PlatformProfile(
        surfaces: [.chat, .code, .cowork],
        allowsWorkspace: true,
        allowsShell: true
    )

    /// Apps set this once at launch. The default is the most restricted profile,
    /// so a target that forgets to set it can never accidentally enable shell or
    /// workspace access.
    public static var current: PlatformProfile = .iOS

    public func supports(_ kind: SessionKind) -> Bool { surfaces.contains(kind) }
}
