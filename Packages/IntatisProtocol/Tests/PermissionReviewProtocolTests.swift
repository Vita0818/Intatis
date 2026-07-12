import XCTest
import IntatisCore
@testable import IntatisProtocol

final class PermissionReviewProtocolTests: XCTestCase {
    func testLegacyPermissionRequestWithoutContextStillDecodes() throws {
        let data = Data(#"""
        {
          "requestId":"req_legacy",
          "agent":"main",
          "tool":"write_file",
          "args":"{}",
          "risk":"medium",
          "reason":"write to workspace"
        }
        """#.utf8)

        let payload = try JSONDecoder().decode(PermissionRequestPayload.self, from: data)

        XCTAssertEqual(payload.requestId, RequestID(rawValue: "req_legacy"))
        XCTAssertNil(payload.context)
    }

    func testPartialPermissionRequestContextUsesAdditiveDefaults() throws {
        let data = Data(#"{"taskID":"task_partial","gate":{"decision":"ask","risk":"medium","reason":"write"}}"#.utf8)

        let context = try JSONDecoder().decode(PermissionRequestContext.self, from: data)

        XCTAssertEqual(context.taskID, TaskID(rawValue: "task_partial"))
        XCTAssertEqual(context.touchedPaths, [])
        XCTAssertNil(context.sideEffect)
        XCTAssertNil(context.executionID)
    }

    func testReviewRequestedAndSettledEventsRoundTrip() throws {
        let reviewer = AgentID(rawValue: "permission-reviewer")
        let requestID = RequestID(rawValue: "req_roundtrip")
        let reviewID = PermissionReviewTaskID(rawValue: "review_roundtrip")
        let task = PermissionReviewTask(
            id: reviewID,
            sessionID: SessionID(rawValue: "sess_roundtrip"),
            requestID: requestID,
            requestingAgent: AgentID(rawValue: "main"),
            reviewerAgent: reviewer,
            taskID: TaskID(rawValue: "task_roundtrip"),
            rootTaskID: TaskID(rawValue: "task_root"),
            attempt: 3,
            toolCallID: "call_roundtrip",
            tool: "write_file",
            normalizedArgs: "{}",
            touchedPaths: ["Sources/App.swift"],
            risksNetwork: false,
            sideEffect: .write,
            gate: .init(decision: .ask, risk: .medium, reason: "write to workspace"),
            causalContext: .init(eventSequenceNumbers: [1, 2]),
            executionID: "exec_roundtrip",
            replayPolicy: "requires_reconciliation",
            createdAt: Date(timeIntervalSince1970: 10),
            deadline: Date(timeIntervalSince1970: 20))
        let settled = PermissionReviewSettledPayload(
            reviewTaskID: reviewID,
            requestID: requestID,
            requestingAgent: AgentID(rawValue: "main"),
            reviewerAgent: reviewer,
            reviewerModel: ModelID(rawValue: "reviewer-model"),
            tool: "write_file",
            decision: .allow,
            risk: .medium,
            status: .allowed,
            reason: "within task scope",
            usage: .init(promptTokens: 8, completionTokens: 2, totalTokens: 10),
            cumulativeTokens: 10,
            durationMillis: 15,
            settledAt: Date(timeIntervalSince1970: 11))
        let envelopes = [
            Envelope(seq: 1, ts: Date(timeIntervalSince1970: 100), session: task.sessionID,
                     event: .permissionReviewRequested(.init(task: task))),
            Envelope(seq: 2, ts: Date(timeIntervalSince1970: 101), session: task.sessionID,
                     event: .permissionReviewSettled(settled)),
        ]
        let encoder = Envelope.makeEncoder()
        let decoder = Envelope.makeDecoder()

        let decoded = try envelopes.map { try decoder.decode(Envelope.self, from: encoder.encode($0)) }

        XCTAssertEqual(decoded, envelopes)
        XCTAssertEqual(decoded.map(\.event.type), [.permissionReviewRequested, .permissionReviewSettled])
    }
}
