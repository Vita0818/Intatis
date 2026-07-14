import XCTest
@testable import IntatisCore

final class IntatisCoreTests: XCTestCase {

    func testProfilePresets() {
        XCTAssertFalse(PlatformProfile.macAppStore.allowsShell)
        XCTAssertTrue(PlatformProfile.macDeveloperID.allowsShell)
        XCTAssertFalse(PlatformProfile.iOS.allowsWorkspace)
        XCTAssertEqual(PlatformProfile.iOS.surfaces, [.chat])
        XCTAssertTrue(PlatformProfile.macAppStore.supports(.cowork))
        XCTAssertFalse(PlatformProfile.iOS.supports(.code))
    }

    func testIDCodesAsBareString() throws {
        let id = SessionID(rawValue: "sess_test")
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"sess_test\"")
        let back = try JSONDecoder().decode(SessionID.self, from: data)
        XCTAssertEqual(back, id)
    }

    func testIDGenPrefixAndUniqueness() {
        XCTAssertTrue(SessionID.new().rawValue.hasPrefix("sess_"))
        XCTAssertNotEqual(MessageID.new(), MessageID.new())
    }

    func testSessionKindWorkspace() {
        XCTAssertFalse(SessionKind.chat.usesWorkspace)
        XCTAssertTrue(SessionKind.code.usesWorkspace)
        XCTAssertTrue(SessionKind.cowork.usesWorkspace)
    }

    func testSessionHistoryRenamePersistsDisplayNameWithoutChangingIdentity() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "sess_rename")
        try createSession(session, root: root, lines: 2)

        try SessionHistoryStore.setDisplayName(
            "  Research notes  ",
            root: root,
            session: session)

        let summary = try XCTUnwrap(
            SessionHistoryStore.recentSessions(root: root, kind: .chat).first)
        XCTAssertEqual(summary.id, session)
        XCTAssertEqual(summary.displayName, "Research notes")
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionHistoryStore.sessionFile(root: root, session: session).path))
    }

    func testSessionHistoryRejectsInvalidDisplayNames() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "sess_invalid_name")
        try createSession(session, root: root)

        XCTAssertThrowsError(try SessionHistoryStore.setDisplayName(
            "  ", root: root, session: session)) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidDisplayName)
        }
        XCTAssertThrowsError(try SessionHistoryStore.setDisplayName(
            "line\nbreak", root: root, session: session)) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidDisplayName)
        }
    }

    func testSessionHistoryDeleteRemovesOnlyTargetSession() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = SessionID(rawValue: "sess_delete")
        let sibling = SessionID(rawValue: "sess_keep")
        try createSession(target, root: root)
        try createSession(sibling, root: root)

        try SessionHistoryStore.deleteSession(root: root, session: target)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(target.rawValue).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionHistoryStore.sessionFile(root: root, session: sibling).path))
    }

    func testSessionHistoryDeleteRejectsTraversalIdentifier() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("keep".utf8).write(to: outside.appendingPathComponent("events.jsonl"))

        XCTAssertThrowsError(try SessionHistoryStore.deleteSession(
            root: root,
            session: SessionID(rawValue: "../\(outside.lastPathComponent)"))) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidSessionID)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSessionHistoryRenameRejectsSymlinkedSessionDirectory() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-session-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{}\n".utf8).write(to: outside.appendingPathComponent("events.jsonl"))
        let session = SessionID(rawValue: "sess_symlink")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(session.rawValue),
            withDestinationURL: outside)

        XCTAssertThrowsError(try SessionHistoryStore.setDisplayName(
            "Should not escape",
            root: root,
            session: session)) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidSessionID)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("session.json").path))
    }

    private func temporarySessionRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-sessions-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createSession(_ session: SessionID,
                               root: URL,
                               lines: Int = 1) throws {
        let events = SessionHistoryStore.sessionFile(root: root, session: session)
        try FileManager.default.createDirectory(
            at: events.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let body = Array(repeating: "{}", count: lines).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: events)
    }
}
