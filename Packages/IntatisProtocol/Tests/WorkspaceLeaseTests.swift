import XCTest
import IntatisCore
@testable import IntatisProtocol

final class WorkspaceLeaseTests: XCTestCase {
    func testWorkspaceLeaseCodableRoundTrip() throws {
        let lease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "wlease_1"),
            workspaceID: WorkspaceID(rawValue: "ws_1"),
            rootPath: "/tmp/project",
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: "Sources/**")],
            deniedPatterns: [".env", ".ssh"])

        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(WorkspaceLease.self, from: data)

        XCTAssertEqual(decoded, lease)
    }

    func testWorkspaceLeaseExpressesRootAccessAndDeniedPatterns() {
        let lease = WorkspaceLease(rootPath: "/tmp/project", access: .readWrite)

        XCTAssertEqual(lease.rootPath, "/tmp/project")
        XCTAssertEqual(lease.access, .readWrite)
        XCTAssertTrue(lease.allowedPathRules.contains(PathRule(pattern: ".")))
        XCTAssertTrue(lease.deniedPatterns.contains(".ssh"))
        XCTAssertTrue(lease.deniedPatterns.contains { $0.contains("token") })
    }
}
