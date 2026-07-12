import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class ToolExecutionProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_tool_projection")
    private let taskID = TaskID(rawValue: "task_tool_projection")
    private let agent = AgentID(rawValue: "worker")

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: seq,
            ts: Date(timeIntervalSince1970: Double(seq)),
            session: session,
            event: event)
    }

    private func prepared(id: String,
                          callID: String,
                          tool: String,
                          sideEffect: SideEffect) -> ToolExecutionPreparedPayload {
        ToolExecutionPreparedPayload(
            executionID: id,
            taskID: taskID,
            attempt: 1,
            toolCallID: callID,
            agent: agent,
            tool: tool,
            sideEffect: sideEffect)
    }

    func testCoworkProjectionExposesOnlyUnsettledExecutionsForRecovery() throws {
        let read = prepared(id: "exec_read", callID: "call_read", tool: "read_file", sideEffect: .readOnly)
        let write = prepared(id: "exec_write", callID: "call_write", tool: "write_file", sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(read)),
            envelope(2, .toolExecutionPrepared(write)),
            envelope(3, .toolExecutionSettled(.init(
                prepared: read,
                outcome: .succeeded,
                reason: "result persisted"))),
        ])

        XCTAssertEqual(projection.toolExecutions.count, 2)
        XCTAssertEqual(projection.toolExecutions["exec_read"]?.settled?.outcome, .succeeded)
        XCTAssertEqual(projection.unresolvedToolExecutions.map(\.id), ["exec_write"])
        XCTAssertEqual(projection.unresolvedNonReplayableToolExecutions.map(\.id), ["exec_write"])
        XCTAssertEqual(
            try XCTUnwrap(projection.unresolvedToolExecutions.first).prepared.taskID,
            taskID)
    }

    func testSettledEventCanReconstructIndexWhenPrepareRecordIsMissing() throws {
        let write = prepared(id: "exec_orphan_settle", callID: "call_write", tool: "write_file", sideEffect: .write)
        let settled = ToolExecutionSettledPayload(prepared: write, outcome: .failed, reason: "tool failed")

        let projection = CoworkProjection.build(from: [
            envelope(5, .toolExecutionSettled(settled)),
        ])

        let execution = try XCTUnwrap(projection.toolExecutions[write.executionID])
        XCTAssertEqual(execution.prepared, write)
        XCTAssertEqual(execution.settled, settled)
        XCTAssertTrue(projection.unresolvedToolExecutions.isEmpty)
    }

    func testSettledSuccessfulNonReplayableExecutionStillBlocksWholeTaskReplay() throws {
        let write = prepared(
            id: "exec_completed_write",
            callID: "call_completed_write",
            tool: "write_file",
            sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(write)),
            envelope(2, .toolExecutionSettled(.init(prepared: write, outcome: .succeeded))),
        ])

        XCTAssertTrue(projection.unresolvedNonReplayableToolExecutions.isEmpty)
        XCTAssertEqual(projection.startedNonReplayableToolExecutions.map(\.id), [write.executionID])
        XCTAssertEqual(
            projection.startedNonReplayableToolExecutions(taskID: taskID, attempt: 1).map(\.id),
            [write.executionID])
        XCTAssertTrue(
            projection.startedNonReplayableToolExecutions(taskID: taskID, attempt: 2).isEmpty)
    }

    func testChatAndCodeProjectionsIgnoreRecoveryBookkeepingEvents() {
        let execution = prepared(id: "exec_ignored", callID: "call_ignored", tool: "read_file", sideEffect: .readOnly)
        let events = [
            envelope(1, .toolExecutionPrepared(execution)),
            envelope(2, .toolExecutionSettled(.init(prepared: execution, outcome: .succeeded))),
        ]

        XCTAssertTrue(ConversationProjection.build(from: events).messages.isEmpty)
        XCTAssertTrue(CodeProjection.build(from: events).items.isEmpty)
    }
}
