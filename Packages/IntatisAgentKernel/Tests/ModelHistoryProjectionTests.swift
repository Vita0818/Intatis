import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisAgentKernel

final class ModelHistoryProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_model_projection")
    private let main = AgentID(rawValue: "main")
    private let other = AgentID(rawValue: "other")

    func testProjectsLegacyAndDirectTurnsInSubmissionOrderAndNormalizesToolPairs() throws {
        let legacyID = SubmissionID(rawValue: "sub_legacy")
        let directID = SubmissionID(rawValue: "sub_direct")
        let currentID = SubmissionID(rawValue: "sub_current")
        let legacyTask = rootTask("task_legacy", legacyID, "legacy U")
        let directTask = rootTask("task_direct", directID, "direct U")
        let currentTask = rootTask("task_current", currentID, "current U")
        let turnID = TurnID(rawValue: "turn_direct")

        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "legacy U",
                to: main,
                submissionID: legacyID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: legacyTask))),
            envelope(3, .taskCompleted(TaskCompletedPayload(
                taskID: legacyTask.id,
                agent: main,
                result: "legacy A"))),
            envelope(4, .userMessage(UserMessagePayload(
                text: "direct U",
                to: main,
                submissionID: directID))),
            envelope(5, .taskCreated(TaskCreatedPayload(contract: directTask))),
            envelope(6, .modelHistoryItem(.message(
                itemID: "direct-user",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                role: .user,
                content: "direct U"))),
            // This output has no matching call and must not be sent.
            envelope(7, .modelHistoryItem(.functionCallOutput(
                itemID: "orphan-output",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                callID: "orphan",
                output: "must disappear"))),
            envelope(8, .modelHistoryItem(.functionCallBatch(
                itemID: "direct-calls",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                content: "checking",
                calls: [
                    ModelHistoryFunctionCall(
                        callID: "call_a",
                        name: "read_file",
                        arguments: #"{"path":"A"}"#),
                    ModelHistoryFunctionCall(
                        callID: "call_b",
                        name: "read_file",
                        arguments: #"{"path":"B"}"#),
                ]))),
            // Completion order does not decide provider order.
            envelope(9, .modelHistoryItem(.functionCallOutput(
                itemID: "output-b",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                callID: "call_b",
                output: "B result"))),
            envelope(10, .modelHistoryItem(.message(
                itemID: "direct-assistant",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                role: .assistant,
                content: "direct A"))),
            envelope(11, .userMessage(UserMessagePayload(
                text: "current U",
                to: main,
                submissionID: currentID))),
            envelope(12, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        let messages = try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(messages.count, 7)
        XCTAssertEqual(messages[0], .user("legacy U"))
        XCTAssertEqual(messages[1], .assistant("legacy A"))
        XCTAssertEqual(messages[2], .user("direct U"))
        XCTAssertEqual(messages[3].role, .assistant)
        XCTAssertEqual(messages[3].content, "checking")
        XCTAssertEqual(messages[3].toolCalls?.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(messages[4], .tool(id: "call_a", content: "aborted"))
        XCTAssertEqual(messages[5], .tool(id: "call_b", content: "B result"))
        XCTAssertEqual(messages[6], .assistant("direct A"))
        XCTAssertFalse(messages.contains { $0.content == "must disappear" })
    }

    func testLatestAttemptReplacesEarlierInvocationForSameSubmission() throws {
        let priorID = SubmissionID(rawValue: "sub_retry")
        let currentID = SubmissionID(rawValue: "sub_after_retry")
        let priorTask = rootTask("task_retry", priorID, "retry U")
        let currentTask = rootTask("task_after_retry", currentID, "current U")

        var events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "retry U",
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
        ]
        events.append(contentsOf: invocationEvents(
            startingAt: 3,
            turnID: TurnID(rawValue: "turn_attempt_1"),
            task: priorTask,
            attempt: 1,
            answer: "old answer"))
        events.append(contentsOf: invocationEvents(
            startingAt: 5,
            turnID: TurnID(rawValue: "turn_attempt_2"),
            task: priorTask,
            attempt: 2,
            answer: "new answer"))
        events.append(envelope(7, .userMessage(UserMessagePayload(
            text: "current U",
            to: main,
            submissionID: currentID))))
        events.append(envelope(8, .taskCreated(TaskCreatedPayload(
            contract: currentTask))))

        let messages = try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(messages, [
            .user("retry U"),
            .assistant("new answer"),
        ])
    }

    func testConflictingReuseOfItemIDFailsClosed() throws {
        let priorID = SubmissionID(rawValue: "sub_conflict")
        let currentID = SubmissionID(rawValue: "sub_conflict_current")
        let priorTask = rootTask("task_conflict", priorID, "U1")
        let currentTask = rootTask("task_conflict_current", currentID, "U2")
        let turnID = TurnID(rawValue: "turn_conflict")
        let first = ModelHistoryItemPayload.message(
            itemID: "same-item",
            turnID: turnID,
            agent: main,
            taskID: priorTask.id,
            submissionID: priorID,
            taskAttempt: 1,
            role: .user,
            content: "U1")
        let second = ModelHistoryItemPayload.message(
            itemID: "same-item",
            turnID: turnID,
            agent: main,
            taskID: priorTask.id,
            submissionID: priorID,
            taskAttempt: 1,
            role: .assistant,
            content: "conflict")
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "U1", to: main, submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(first)),
            envelope(4, .modelHistoryItem(second)),
            envelope(5, .userMessage(UserMessagePayload(
                text: "U2", to: main, submissionID: currentID))),
            envelope(6, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .conflictingItemID("same-item"))
            }
    }

    func testWrongAgentOrAcceptedTargetFailsClosed() throws {
        let priorID = SubmissionID(rawValue: "sub_wrong_binding")
        let currentID = SubmissionID(rawValue: "sub_wrong_binding_current")
        let priorTask = rootTask("task_wrong_binding", priorID, "U1")
        let currentTask = rootTask(
            "task_wrong_binding_current",
            currentID,
            "U2")
        let wrongAgentEvents = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "U1", to: main, submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "wrong-agent-user",
                turnID: TurnID(rawValue: "turn_wrong_agent"),
                agent: other,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: "U1"))),
            envelope(4, .userMessage(UserMessagePayload(
                text: "U2", to: main, submissionID: currentID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: wrongAgentEvents)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .invalidItem(
                        "wrong-agent-user",
                        "item agent does not match the durable root assignee"))
            }

        let wrongTargetEvents = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "U2", to: other, submissionID: currentID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]
        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: wrongTargetEvents)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .invalidItem(
                        "accepted-submission:\(currentID.rawValue)",
                        "accepted user target does not match the current root assignee"))
            }
    }

    private func invocationEvents(
        startingAt sequence: Int,
        turnID: TurnID,
        task: TaskContract,
        attempt: Int,
        answer: String
    ) -> [Envelope] {
        [
            envelope(sequence, .modelHistoryItem(.message(
                itemID: "user-\(turnID.rawValue)",
                turnID: turnID,
                agent: main,
                taskID: task.id,
                submissionID: task.submissionID,
                taskAttempt: attempt,
                role: .user,
                content: task.objective))),
            envelope(sequence + 1, .modelHistoryItem(.message(
                itemID: "assistant-\(turnID.rawValue)",
                turnID: turnID,
                agent: main,
                taskID: task.id,
                submissionID: task.submissionID,
                taskAttempt: attempt,
                role: .assistant,
                content: answer))),
        ]
    }

    private func rootTask(
        _ taskID: String,
        _ submissionID: SubmissionID,
        _ objective: String
    ) -> TaskContract {
        TaskContract(
            id: TaskID(rawValue: taskID),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: submissionID,
            objective: objective,
            roleHint: "root",
            expectedDeliverable: "answer")
    }

    private func envelope(_ sequence: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: sequence,
            session: session,
            event: event)
    }
}
