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

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public let id: SessionID
    public let kind: SessionKind
    public let updatedAt: Date
    public let eventCount: Int

    public init(id: SessionID, kind: SessionKind, updatedAt: Date, eventCount: Int) {
        self.id = id
        self.kind = kind
        self.updatedAt = updatedAt
        self.eventCount = eventCount
    }
}

public enum SessionHistoryStore {
    public static func sessionFile(root: URL, session: SessionID) -> URL {
        root
            .appendingPathComponent(session.rawValue, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    public static func artifactsDir(root: URL, session: SessionID) -> URL {
        root
            .appendingPathComponent(session.rawValue, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    public static func recentSessions(root: URL, kind: SessionKind) -> [SessionSummary] {
        let prefix: String
        switch kind {
        case .chat:
            prefix = "sess_"
        case .code:
            prefix = "code_"
        case .cowork:
            prefix = "cowork_"
        }

        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return sessions.compactMap { url -> SessionSummary? in
            let raw = url.lastPathComponent
            guard raw.hasPrefix(prefix) else { return nil }
            let events = url.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: events.path) else { return nil }
            let values = try? events.resourceValues(forKeys: [.contentModificationDateKey])
            return SessionSummary(
                id: SessionID(rawValue: raw),
                kind: kind,
                updatedAt: values?.contentModificationDate ?? .distantPast,
                eventCount: eventCount(in: events))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func eventCount(in fileURL: URL) -> Int {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return 0 }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }
}
