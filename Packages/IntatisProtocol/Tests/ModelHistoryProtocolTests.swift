import XCTest
import IntatisCore
@testable import IntatisProtocol

final class ModelHistoryProtocolTests: XCTestCase {
    private let encoder = Envelope.makeEncoder()
    private let decoder = Envelope.makeDecoder()

    func testModelHistoryPayloadKindsCodableRoundTrip() throws {
        let turnID = TurnID(rawValue: "turn_history")
        let agent = AgentID(rawValue: "main")
        let taskID = TaskID(rawValue: "task_history")
        let submissionID = SubmissionID(rawValue: "sub_history")
        let metadata = (
            turnID: turnID,
            agent: agent,
            taskID: Optional(taskID),
            submissionID: Optional(submissionID),
            taskAttempt: Optional(2)
        )
        let payloads: [ModelHistoryItemPayload] = [
            .message(
                itemID: "item_user",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                role: .user,
                content: "Inspect the project.",
                attachmentIDs: [
                    ArtifactID(rawValue: "artifact_one"),
                    ArtifactID(rawValue: "artifact_two"),
                ]),
            .functionCallBatch(
                itemID: "item_calls",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                content: "I will inspect both files.",
                calls: [
                    ModelHistoryFunctionCall(
                        callID: "call_read",
                        name: "read_file",
                        arguments: #"{"path":"README.md"}"#),
                    ModelHistoryFunctionCall(
                        callID: "call_redacted",
                        name: "write_stdin",
                        arguments: #"{"_intatis":"arguments_redacted"}"#,
                        argumentsRedacted: true),
                ]),
            .functionCallOutput(
                itemID: "item_output",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                callID: "call_read",
                output: "README contents"),
            ModelHistoryItemPayload(
                itemID: "item_reasoning",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                kind: .reasoning,
                reasoningSummary: ["Checked the durable history."],
                reasoningContent: "Model-visible reasoning content",
                encryptedReasoningContent: "opaque-encrypted-content"),
        ]

        for payload in payloads {
            let data = try JSONEncoder().encode(payload)
            XCTAssertEqual(
                try JSONDecoder().decode(ModelHistoryItemPayload.self, from: data),
                payload)
        }
    }

    func testModelHistoryEventsRoundTripThroughEnvelopeWithStableWireType() throws {
        let session = SessionID(rawValue: "sess_model_history")
        let agent = AgentID(rawValue: "main")
        let turnID = TurnID(rawValue: "turn_model_history")
        let payloads: [ModelHistoryItemPayload] = [
            .message(
                itemID: "item_assistant",
                turnID: turnID,
                agent: agent,
                taskID: TaskID(rawValue: "task_model_history"),
                submissionID: SubmissionID(rawValue: "sub_model_history"),
                taskAttempt: 1,
                role: .assistant,
                content: "Done."),
            .functionCallOutput(
                itemID: "item_tool_output",
                turnID: turnID,
                agent: agent,
                taskID: TaskID(rawValue: "task_model_history"),
                submissionID: SubmissionID(rawValue: "sub_model_history"),
                taskAttempt: 1,
                callID: "call_model_history",
                output: "ok"),
        ]

        for (index, payload) in payloads.enumerated() {
            let envelope = Envelope(
                seq: index + 1,
                ts: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                session: session,
                event: .modelHistoryItem(payload))
            let data = try encoder.encode(envelope)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(object["type"] as? String, "model_history_item")
            XCTAssertEqual(try decoder.decode(Envelope.self, from: data), envelope)
        }
    }

    func testLegacyEnvelopeStillDecodesWithoutModelHistoryItem() throws {
        let legacyJSON = #"{"seq":7,"ts":"2023-11-14T22:13:20Z","session":"sess_legacy_history","v":1,"type":"message_completed","payload":{"messageId":"msg_legacy","role":"assistant","text":"legacy answer"}}"#

        let envelope = try decoder.decode(Envelope.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(envelope.seq, 7)
        XCTAssertEqual(envelope.session, SessionID(rawValue: "sess_legacy_history"))
        XCTAssertEqual(envelope.v, 1)
        XCTAssertEqual(
            envelope.event,
            .messageCompleted(MessageCompletedPayload(
                messageId: MessageID(rawValue: "msg_legacy"),
                role: .assistant,
                text: "legacy answer")))
    }
}
