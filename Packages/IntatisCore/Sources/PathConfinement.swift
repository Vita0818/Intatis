import Foundation

/// Workspace path confinement (ARCHITECTURE.md §3.7 invariant). Lives in Core so
/// both Tools (to enforce at execution) and Permission (to deny escapes at the
/// gate) can use it without depending on each other. `..` traversal and absolute
/// paths that escape the workspace root are rejected.
public enum PathConfinement {

    /// Resolve a (possibly relative) path against `root`, rejecting escapes.
    public static func resolve(_ path: String, within root: URL) throws -> URL {
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(path).standardizedFileURL
        }
        let rootStd = root.standardizedFileURL
        let rootPath = rootStd.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.path == rootPath || candidate.path.hasPrefix(prefix) else {
            throw IntatisError.permissionDenied("path escapes workspace: \(path)")
        }
        return candidate
    }

    public static func isWithin(_ path: String, root: URL) -> Bool {
        (try? resolve(path, within: root)) != nil
    }

    /// Path of `url` relative to `root` (for display), or the full path if outside.
    public static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
    }
}
