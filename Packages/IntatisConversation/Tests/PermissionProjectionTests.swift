import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class PermissionProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "perm")

    private func env(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
    }

    private func request(_ id: String = "req_1") -> PermissionRequestPayload {
        PermissionRequestPayload(requestId: RequestID(rawValue: id),
                                 agent: AgentID(rawValue: "A"),
                                 tool: "write_file",
                                 args: #"{"path":"a.txt"}"#,
                                 risk: .medium,
                                 reason: "write to workspace")
    }

    func testUnresolvedPermissionRequestAppearsPending() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request()))
        ])

        XCTAssertEqual(projection.pending.count, 1)
        XCTAssertEqual(projection.latest?.request.requestId, RequestID(rawValue: "req_1"))
        XCTAssertEqual(projection.latest?.state, .livePending)
        XCTAssertEqual(projection.latest?.state.isActionable, true)
    }

    func testPermissionResolvedRemovesPending() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(requestId: RequestID(rawValue: "req_1"),
                                             tool: "write_file",
                                             decision: .deny,
                                             risk: .medium,
                                             reason: "user denied")))
        ])

        XCTAssertTrue(projection.pending.isEmpty)
    }

    func testPermissionResolvedRetainsLatestNoticeWithStableID() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(requestId: RequestID(rawValue: "req_1"),
                                             tool: "write_file",
                                             decision: .allow,
                                             risk: .medium,
                                             reason: "user approved")))
        ])
        let replayed = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(requestId: RequestID(rawValue: "req_1"),
                                             tool: "write_file",
                                             decision: .allow,
                                             risk: .medium,
                                             reason: "user approved")))
        ])

        XCTAssertEqual(projection.latestResolved?.id, "permission:req_1:resolved")
        XCTAssertEqual(projection.latestResolved?.decision, .allow)
        XCTAssertEqual(projection.latestResolved, replayed.latestResolved)
    }

    func testReplayAfterReloadPreservesPendingPermissionState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-perm-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: session, fileURL: url)
        try await log.append(.permissionRequest(request()))

        let reloaded = try EventLog(session: session, fileURL: url)
        let projection = PermissionProjection.build(from: await reloaded.replay())

        XCTAssertEqual(projection.pending.count, 1)
        XCTAssertEqual(projection.latest?.request.tool, "write_file")
    }

    func testExpiredPermissionCanBeShownAsNeedsRerun() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request()))
        ], markNeedsRerun: true)

        XCTAssertEqual(projection.latest?.state, .needsRerun)
        XCTAssertEqual(projection.latest?.state.isActionable, false)
        XCTAssertFalse(projection.latest?.request.reason.contains("needs rerun") == true)
    }

    func testResolvingAndExpiredPermissionsAreNotActionable() {
        XCTAssertFalse(PendingPermissionState.resolving.isActionable)
        XCTAssertFalse(PendingPermissionState.approved.isActionable)
        XCTAssertFalse(PendingPermissionState.rejected.isActionable)
        XCTAssertFalse(PendingPermissionState.expired.isActionable)
        XCTAssertFalse(PendingPermissionState.needsRerun.isActionable)
    }
}
