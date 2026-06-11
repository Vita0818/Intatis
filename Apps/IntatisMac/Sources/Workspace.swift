#if canImport(SwiftUI)
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Workspace folder selection. In the sandboxed App Store build this grants
/// access via a user-selected security-scoped resource (ARCHITECTURE.md §9.1).
/// v0.2 holds access for the session; persisting the bookmark across launches is
/// a later refinement.
enum WorkspaceAccess {
    @MainActor
    static func choose() -> URL? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
        #else
        return nil
        #endif
    }
}
#endif
