import XCTest
@testable import IntatisCore

final class PathConfinementTests: XCTestCase {

    private func tempWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testWorkspaceInsidePathAllowed() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try PathConfinement.resolve("Sources/App.swift", within: root)
        XCTAssertTrue(resolved.path.hasPrefix(root.path))
    }

    func testTraversalEscapeDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try PathConfinement.resolve("../secret", within: root))
    }

    func testAbsoluteOutsideDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try PathConfinement.resolve("/etc/passwd", within: root))
    }

    func testSymlinkPointingOutsideDenied() throws {
        let root = try tempWorkspace()
        let outside = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("out"),
            withDestinationURL: outside)

        XCTAssertThrowsError(try PathConfinement.resolve("out/secret.txt", within: root))
    }

    func testEnvDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try PathConfinement.resolve(".env", within: root))
    }

    func testSSHPathDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try PathConfinement.resolve("~/.ssh/id_rsa", within: root))
    }

    func testNonExistingChildUnderWorkspaceAllowedWhenParentConfined() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"), withIntermediateDirectories: true)

        let resolved = try PathConfinement.resolve("new/file.txt", within: root)
        XCTAssertEqual(resolved.path, root.appendingPathComponent("new/file.txt").path)
    }

    func testNonExistingPathEscapingWorkspaceDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try PathConfinement.resolve("../outside/new.txt", within: root))
    }
}
