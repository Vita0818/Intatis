import XCTest
import IntatisCore
@testable import IntatisProtocol

final class ToolExecutionProtocolTests: XCTestCase {
    func testConservativeReplayPolicyOnlyReplaysReadOnlyNonCollaborationTools() {
        XCTAssertEqual(
            ToolExecutionReplayPolicy.conservative(for: .readOnly, tool: "read_file"),
            .safeToReplay)
        XCTAssertEqual(
            ToolExecutionReplayPolicy.conservative(for: .write, tool: "write_file"),
            .requiresManualReconciliation)
        XCTAssertEqual(
            ToolExecutionReplayPolicy.conservative(for: .readOnly, tool: "ask_agent"),
            .requiresManualReconciliation)

        let read = ToolExecutionPreparedPayload(
            executionID: "read",
            toolCallID: "read-call",
            tool: "read_file",
            sideEffect: .readOnly)
        let write = ToolExecutionPreparedPayload(
            executionID: "write",
            toolCallID: "write-call",
            tool: "write_file",
            sideEffect: .write)
        XCTAssertFalse(read.requiresTaskReplayReconciliation)
        XCTAssertTrue(write.requiresTaskReplayReconciliation)
    }

    func testPrepareAndSettledEventsRoundTripWithStableWireTypes() throws {
        let session = SessionID(rawValue: "sess_tool_execution")
        let taskID = TaskID(rawValue: "task_tool_execution")
        let agent = AgentID(rawValue: "worker")
        let prepared = ToolExecutionPreparedPayload(
            executionID: "exec_1",
            taskID: taskID,
            attempt: 2,
            toolCallID: "call_1",
            agent: agent,
            tool: "write_file",
            sideEffect: .write)
        let settled = ToolExecutionSettledPayload(
            prepared: prepared,
            outcome: .succeeded,
            reason: "result persisted")
        let envelopes = [
            Envelope(
                seq: 10,
                ts: Date(timeIntervalSince1970: 1_700_000_010),
                session: session,
                event: .toolExecutionPrepared(prepared)),
            Envelope(
                seq: 11,
                ts: Date(timeIntervalSince1970: 1_700_000_011),
                session: session,
                event: .toolExecutionSettled(settled)),
        ]
        let encoder = Envelope.makeEncoder()
        let decoder = Envelope.makeDecoder()

        let encoded = try envelopes.map(encoder.encode)
        let wireTypes = try encoded.map { data -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["type"] as? String)
        }

        XCTAssertEqual(wireTypes, ["tool_execution_prepared", "tool_execution_settled"])
        XCTAssertEqual(try encoded.map { try decoder.decode(Envelope.self, from: $0) }, envelopes)
        XCTAssertEqual(settled.prepared, prepared)
    }

    func testLegacyToolResultStillDecodesWithoutExecutionEvents() throws {
        let json = #"{"seq":2,"ts":"2023-11-14T22:13:20Z","session":"sess_legacy","v":1,"type":"tool_result","payload":{"toolCallId":"call_legacy","observation":"ok"}}"#

        let envelope = try Envelope.makeDecoder().decode(Envelope.self, from: Data(json.utf8))

        XCTAssertEqual(
            envelope.event,
            .toolResult(.init(toolCallId: "call_legacy", observation: "ok")))
    }
}
