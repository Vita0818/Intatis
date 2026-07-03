#if canImport(SwiftUI)
import Foundation
import IntatisCore
#if canImport(AppKit)
import AppKit
#endif

/// Workspace folder selection. In the sandboxed App Store build this grants
/// access via a user-selected security-scoped resource (ARCHITECTURE.md §9.1).
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
        remember(url)
        return url
        #else
        return nil
        #endif
    }

    static func remember(_ url: URL, for session: SessionID? = nil) {
        #if canImport(AppKit)
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            var bookmarks = bookmarkStore()
            bookmarks[url.path] = data
            UserDefaults.standard.set(bookmarks, forKey: bookmarkStoreKey)
            if let session {
                UserDefaults.standard.set(data, forKey: sessionBookmarkKey(session))
                UserDefaults.standard.set(url.path, forKey: sessionPathKey(session))
            }
        } catch {
            if let session {
                UserDefaults.standard.set(url.path, forKey: sessionPathKey(session))
            }
        }
        #endif
    }

    @discardableResult
    static func restoreAccess(forPath path: String) -> URL? {
        #if canImport(AppKit)
        guard let data = bookmarkStore()[path] else { return nil }
        return resolve(data, pathFallback: path)
        #else
        return nil
        #endif
    }

    @discardableResult
    static func restoredWorkspace(for session: SessionID) -> URL? {
        #if canImport(AppKit)
        guard let data = UserDefaults.standard.data(forKey: sessionBookmarkKey(session)) else {
            if let path = workspacePath(for: session) {
                return restoreAccess(forPath: path)
            }
            return nil
        }
        return resolve(data, pathFallback: workspacePath(for: session))
        #else
        return nil
        #endif
    }

    static func workspacePath(for session: SessionID) -> String? {
        UserDefaults.standard.string(forKey: sessionPathKey(session))
    }

    private static let bookmarkStoreKey = "intatis.workspace.bookmarks"

    private static func sessionBookmarkKey(_ session: SessionID) -> String {
        "intatis.workspace.sessionBookmark.\(session.rawValue)"
    }

    private static func sessionPathKey(_ session: SessionID) -> String {
        "intatis.workspace.sessionPath.\(session.rawValue)"
    }

    private static func bookmarkStore() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data] ?? [:]
    }

    @discardableResult
    private static func resolve(_ data: Data, pathFallback: String?) -> URL? {
        #if canImport(AppKit)
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            if stale {
                remember(url)
            }
            return url
        } catch {
            if let pathFallback {
                return URL(fileURLWithPath: pathFallback)
            }
            return nil
        }
        #else
        return nil
        #endif
    }
}
#endif
