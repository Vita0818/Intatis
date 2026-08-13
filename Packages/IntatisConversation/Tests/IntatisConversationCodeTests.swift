import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class IntatisConversationCodeTests: XCTestCase {

    func testCodeProjectionFoldsToolAndPatchEvents() {
        let s = SessionID(rawValue: "s")
        func env(_ seq: Int, _ e: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: s, event: e)
        }
        let m = MessageID(rawValue: "m1")
        let coder = AgentID(rawValue: "Coder")
        let envs: [Envelope] = [
            env(0, .userMessage(.init(text: "edit file"))),
            env(1, .toolCall(.init(toolCallId: "c1", name: "apply_patch", args: "{}"))),
            env(2, .toolResult(.init(toolCallId: "c1", observation: "applied"))),
            env(3, .patchProposed(.init(patchId: "p1", files: ["a.swift"], diff: "@@ -1 +1 @@"))),
            env(4, .messageDelta(.init(messageId: m, role: .agent, agent: coder, textDelta: "Do"))),
            env(5, .messageCompleted(.init(messageId: m, role: .agent, agent: coder, text: "Done."))),
        ]
        let projection = CodeProjection.build(from: envs)
        XCTAssertEqual(projection.items.map { $0.kind }, [.user, .toolCall, .toolResult, .patch, .agent])
        XCTAssertEqual(projection.items.last?.body, "Done.")
        XCTAssertEqual(projection.items.last?.complete, true)
        XCTAssertEqual(projection.items.first(where: { $0.kind == .patch })?.files, ["a.swift"])
        let result = projection.items.first(where: { $0.kind == .toolResult })
        XCTAssertEqual(result?.title, "result · apply_patch")
        XCTAssertEqual(result?.isFailure, false)
    }

    func testFailedTurnOutcomeInvalidatesOnlyItsCorrelatedCompletedAnswer() {
        let session = SessionID(rawValue: "failed_turn_projection")
        let agent = AgentID(rawValue: "main")
        let other = AgentID(rawValue: "worker")
        let taskID = TaskID(rawValue: "task_failed_turn")
        let otherTaskID = TaskID(rawValue: "task_other_turn")
        let submissionID = SubmissionID(rawValue: "sub_failed_turn")
        let otherSubmissionID = SubmissionID(rawValue: "sub_other_turn")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }
        let events: [Envelope] = [
            env(1, .taskStarted(.init(taskID: taskID, agent: agent, attempt: 1))),
            env(2, .messageDelta(.init(
                messageId: MessageID(rawValue: "failed_answer"),
                role: .agent,
                agent: agent,
                textDelta: "Looks complete",
                submissionID: submissionID))),
            env(3, .messageCompleted(.init(
                messageId: MessageID(rawValue: "failed_answer"),
                role: .agent,
                agent: agent,
                text: "Looks complete",
                submissionID: submissionID))),
            env(4, .taskStarted(.init(taskID: otherTaskID, agent: other, attempt: 1))),
            env(5, .messageCompleted(.init(
                messageId: MessageID(rawValue: "other_answer"),
                role: .agent,
                agent: other,
                text: "Actually complete",
                submissionID: otherSubmissionID))),
            env(6, .error(.init(
                code: "provider_runtime_failure",
                message: "The provider stopped after emitting partial output.",
                submissionID: submissionID))),
            env(7, .turnOutcome(.init(
                turnID: TurnID(rawValue: "turn_failed_projection"),
                outcome: .failed,
                failureSource: .runtimeFailed,
                reason: "provider runtime failure",
                submissionID: submissionID,
                taskID: taskID,
                agentID: agent))),
        ]

        let projection = CodeProjection.build(from: events)
        let invalidated = projection.items.first { $0.id == "failed_answer" }
        let unaffected = projection.items.first { $0.id == "other_answer" }

        XCTAssertEqual(invalidated?.complete, false)
        XCTAssertEqual(invalidated?.isFailure, true)
        XCTAssertEqual(
            invalidated?.recoveryAdvice?.title,
            "Response was not accepted as complete")
        XCTAssertTrue(invalidated?.recoveryAdvice?.detail.contains("provider runtime failure") == true)
        XCTAssertEqual(unaffected?.complete, true)
        XCTAssertEqual(unaffected?.isFailure, false)
        XCTAssertTrue(projection.items.contains {
            $0.kind == .error && $0.body.contains("provider stopped")
        })
    }

    func testCodeProjectionMarksMatchingTaskCompletionAsExecutionTraceForMainAndWorker() {
        let session = SessionID(rawValue: "task_completion_mirror")
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let mainTask = TaskID(rawValue: "task_main")
        let workerTask = TaskID(rawValue: "task_worker")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }

        let envelopes: [Envelope] = [
            env(15, .taskStarted(.init(taskID: mainTask, agent: main, attempt: 1))),
            env(1_552, .messageDelta(.init(
                messageId: MessageID(rawValue: "main_message"),
                role: .agent,
                agent: main,
                textDelta: "Main"))),
            env(1_553, .messageCompleted(.init(
                messageId: MessageID(rawValue: "main_message"),
                role: .agent,
                agent: main,
                text: "Main answer"))),
            env(1_555, .turnStats(.init(
                promptTokens: 10,
                invocationTaskID: mainTask,
                agentID: main))),
            env(1_557, .taskCompleted(.init(
                taskID: mainTask,
                agent: main,
                result: "Main answer",
                attempt: 1))),
            env(1_600, .taskStarted(.init(taskID: workerTask, agent: worker, attempt: 1))),
            env(1_601, .messageCompleted(.init(
                messageId: MessageID(rawValue: "worker_message"),
                role: .agent,
                agent: worker,
                text: "Worker answer"))),
            env(1_602, .taskCompleted(.init(
                taskID: workerTask,
                agent: worker,
                result: "Worker answer",
                attempt: 1))),
        ]

        let agentItems = CodeProjection.build(from: envelopes).items.filter { $0.kind == .agent }

        XCTAssertEqual(agentItems.map(\.id), [
            "main_message",
            "task_main:completed",
            "worker_message",
            "task_worker:completed",
        ])
        XCTAssertEqual(agentItems.map(\.presentationSource), [
            .conversation,
            .executionTrace,
            .conversation,
            .executionTrace,
        ])
    }

    func testCodeProjectionKeepsTaskOnlyAndDifferentTaskResultAsConversationFallbacks() {
        let session = SessionID(rawValue: "task_completion_fallback")
        let agent = AgentID(rawValue: "worker")
        let taskOnly = TaskID(rawValue: "task_only")
        let different = TaskID(rawValue: "task_different")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }

        let envelopes: [Envelope] = [
            env(0, .taskStarted(.init(taskID: taskOnly, agent: agent))),
            env(1, .taskCompleted(.init(taskID: taskOnly, agent: agent, result: "Only durable result"))),
            env(2, .taskStarted(.init(taskID: different, agent: agent))),
            env(3, .messageCompleted(.init(
                messageId: MessageID(rawValue: "different_message"),
                role: .agent,
                agent: agent,
                text: "Presented answer"))),
            env(4, .taskCompleted(.init(
                taskID: different,
                agent: agent,
                result: "Different lifecycle result"))),
        ]

        let completed = CodeProjection.build(from: envelopes).items.filter {
            $0.id.hasSuffix(":completed")
        }

        XCTAssertEqual(completed.map(\.presentationSource), [.conversation, .conversation])
    }

    func testCodeProjectionDoesNotPairIdenticalTextAcrossSequentialTasks() {
        let session = SessionID(rawValue: "task_completion_scope")
        let agent = AgentID(rawValue: "worker")
        let firstTask = TaskID(rawValue: "task_first")
        let secondTask = TaskID(rawValue: "task_second")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }

        let envelopes: [Envelope] = [
            env(0, .taskStarted(.init(taskID: firstTask, agent: agent))),
            env(1, .messageCompleted(.init(
                messageId: MessageID(rawValue: "first_message"),
                role: .agent,
                agent: agent,
                text: "Same text"))),
            env(2, .taskCompleted(.init(taskID: firstTask, agent: agent, result: "Same text"))),
            env(3, .taskStarted(.init(taskID: secondTask, agent: agent))),
            env(4, .taskCompleted(.init(taskID: secondTask, agent: agent, result: "Same text"))),
        ]

        let completed = CodeProjection.build(from: envelopes).items.filter {
            $0.id.hasSuffix(":completed")
        }

        XCTAssertEqual(completed.map(\.presentationSource), [.executionTrace, .conversation])
    }

    func testCodeProjectionDoesNotReuseCompletedMessageAcrossTaskRetry() {
        let session = SessionID(rawValue: "task_completion_retry")
        let agent = AgentID(rawValue: "worker")
        let task = TaskID(rawValue: "task_retry")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }

        let envelopes: [Envelope] = [
            env(0, .taskStarted(.init(taskID: task, agent: agent, attempt: 1))),
            env(1, .messageCompleted(.init(
                messageId: MessageID(rawValue: "first_attempt_message"),
                role: .agent,
                agent: agent,
                text: "Same text"))),
            env(2, .taskFailed(.init(
                taskID: task,
                agent: agent,
                error: "retry",
                attempt: 1))),
            env(3, .taskStarted(.init(taskID: task, agent: agent, attempt: 2))),
            env(4, .taskCompleted(.init(
                taskID: task,
                agent: agent,
                result: "Same text",
                attempt: 2))),
        ]

        let completed = CodeProjection.build(from: envelopes).items.first {
            $0.id == "task_retry:completed"
        }

        XCTAssertEqual(completed?.presentationSource, .conversation)
    }

    func testCodeProjectionScopesLateTerminalToExactTaskAttempt() {
        let session = SessionID(rawValue: "task_completion_late_attempt")
        let agent = AgentID(rawValue: "worker")
        let task = TaskID(rawValue: "task_late_attempt")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }

        let envelopes: [Envelope] = [
            env(0, .taskStarted(.init(taskID: task, agent: agent, attempt: 1))),
            env(1, .messageCompleted(.init(
                messageId: MessageID(rawValue: "attempt_one_message"),
                role: .agent,
                agent: agent,
                text: "Same text"))),
            env(2, .taskStarted(.init(taskID: task, agent: agent, attempt: 2))),
            env(3, .messageCompleted(.init(
                messageId: MessageID(rawValue: "attempt_two_message"),
                role: .agent,
                agent: agent,
                text: "Same text"))),
            env(4, .taskCompleted(.init(
                taskID: task,
                agent: agent,
                result: "Same text",
                attempt: 1))),
            env(5, .taskCompleted(.init(
                taskID: task,
                agent: agent,
                result: "Same text",
                attempt: 2))),
        ]

        let completed = CodeProjection.build(from: envelopes).items.filter {
            $0.id == "task_late_attempt:completed"
        }

        XCTAssertEqual(completed.map(\.presentationSource), [.executionTrace, .executionTrace])
    }

    func testCodeProjectionMarksFailedToolResults() {
        let s = SessionID(rawValue: "tool_failure")
        func env(_ seq: Int, _ e: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: s, event: e)
        }
        let envs: [Envelope] = [
            env(0, .toolCall(.init(toolCallId: "c1", name: "write_file", args: "{}"))),
            env(1, .toolResult(.init(toolCallId: "c1", observation: "permission denied: user denied"))),
        ]

        let result = CodeProjection.build(from: envs).items.last

        XCTAssertEqual(result?.title, "result · write_file")
        XCTAssertEqual(result?.isFailure, true)
        XCTAssertEqual(result?.recoveryAdvice?.title, "Rerun after permission change")
        XCTAssertEqual(result?.recoveryAdvice?.retryable, false)
    }

    func testCodeProjectionMarksInvalidToolInputResults() {
        let s = SessionID(rawValue: "invalid_tool_input")
        func env(_ seq: Int, _ e: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: s, event: e)
        }
        let envs: [Envelope] = [
            env(0, .toolCall(.init(toolCallId: "c1", name: "write_file", args: #"{"path":"out.txt""#))),
            env(1, .toolResult(.init(
                toolCallId: "c1",
                observation: "invalid tool input: arguments for write_file must be valid JSON."))),
        ]

        let result = CodeProjection.build(from: envs).items.last

        XCTAssertEqual(result?.title, "result · write_file")
        XCTAssertEqual(result?.isFailure, true)
        XCTAssertEqual(result?.recoveryAdvice?.title, "Fix tool input")
        XCTAssertEqual(result?.recoveryAdvice?.retryable, true)
    }

    func testCodeProjectionPrefersTypedToolOutcomeOverPresentationText() {
        let session = SessionID(rawValue: "typed_tool_outcome")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }
        let envelopes: [Envelope] = [
            env(0, .toolResult(.init(
                toolCallId: "failed",
                observation: "operation unavailable",
                outcome: .failed,
                failureSource: .runtimeFailed))),
            env(1, .toolResult(.init(
                toolCallId: "succeeded",
                observation: "permission denied: literal file contents",
                outcome: .succeeded))),
        ]

        let results = CodeProjection.build(from: envelopes).items

        XCTAssertEqual(results.map(\.isFailure), [true, false])
    }

    func testCodeProjectionAddsRecoveryAdviceForRetryableProviderErrors() {
        let s = SessionID(rawValue: "provider_recovery")
        let envelope = Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: s,
            event: .error(.init(
                code: "provider",
                message: "streaming request failed with HTTP 429 Too Many Requests. Retry later.")))

        let item = CodeProjection.build(from: [envelope]).items.first

        XCTAssertEqual(item?.kind, .error)
        XCTAssertEqual(item?.recoveryAdvice?.title, "Retry or switch provider")
        XCTAssertEqual(item?.recoveryAdvice?.retryable, true)
    }

    func testCodeProjectionAddsRecoveryAdviceForEndpointCompatibilityErrors() {
        let s = SessionID(rawValue: "decode_recovery")
        let envelope = Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: s,
            event: .error(.init(
                code: "decoding",
                message: "provider stream returned non-JSON SSE data. Check endpoint compatibility.")))

        let item = CodeProjection.build(from: [envelope]).items.first

        XCTAssertEqual(item?.kind, .error)
        XCTAssertEqual(item?.recoveryAdvice?.title, "Check endpoint compatibility")
        XCTAssertEqual(item?.recoveryAdvice?.retryable, false)
    }

    func testCodeProjectionMarksPartialAgentStreamStoppedByError() {
        let s = SessionID(rawValue: "agent_partial_stop")
        let messageID = MessageID(rawValue: "agent_msg_partial")
        func env(_ seq: Int, _ e: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: s, event: e)
        }
        let envs: [Envelope] = [
            env(0, .messageDelta(.init(messageId: messageID, role: .agent, agent: AgentID(rawValue: "Coder"), textDelta: "partial"))),
            env(1, .error(.init(
                code: "provider",
                message: "streaming request failed with HTTP 503 Service Unavailable. Retry later."))),
        ]

        let projection = CodeProjection.build(from: envs)

        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(projection.items[0].id, messageID.rawValue)
        XCTAssertEqual(projection.items[0].body, "partial")
        XCTAssertFalse(projection.items[0].complete)
        XCTAssertTrue(projection.items[0].isFailure)
        XCTAssertEqual(projection.items[0].recoveryAdvice?.title, "Response stopped before completion")
        XCTAssertEqual(projection.items[1].recoveryAdvice?.title, "Retry or switch provider")
    }

    func testCodeProjectionKeepsGoalMetadataOnUserItems() {
        let s = SessionID(rawValue: "goal_code")
        let envelopes: [Envelope] = [
            Envelope(seq: 0, ts: Date(timeIntervalSince1970: 0), session: s,
                     event: .userMessage(.init(text: "ship v0.12", tags: ["Goal"], goal: "ship v0.12"))),
        ]

        let item = CodeProjection.build(from: envelopes).items.first

        XCTAssertEqual(item?.kind, .user)
        XCTAssertEqual(item?.body, "ship v0.12")
        XCTAssertEqual(item?.tags ?? [], ["Goal"])
        XCTAssertEqual(item?.goal, "ship v0.12")
    }

    func testCodeProjectionPresentsAgentCommunicationWithDirectionalIdentity() {
        let session = SessionID(rawValue: "agent_communication_presentation")
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "researcher")
        let requestID = MessageID(rawValue: "request")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(
                seq: seq,
                ts: Date(timeIntervalSince1970: Double(seq)),
                session: session,
                event: event)
        }

        let items = CodeProjection.build(from: [
            env(1, .agentMessage(.init(
                from: main,
                to: worker,
                content: "Please inspect the workspace.",
                kind: .sendMessage,
                messageId: MessageID(rawValue: "message")))),
            env(2, .agentToAgentMessage(.init(
                from: worker,
                to: main,
                content: "Inspection complete.",
                mediated: true))),
            env(3, .informationRequested(.init(
                requestID: requestID,
                from: main,
                to: worker,
                question: "Which files changed?",
                mediated: true))),
            env(4, .informationReplied(.init(
                replyID: MessageID(rawValue: "reply"),
                inReplyTo: requestID,
                from: worker,
                to: main,
                content: "Two Swift files changed.",
                mediated: true))),
        ]).items

        XCTAssertEqual(items.map(\.kind), [
            .agent,
            .agentToAgent,
            .agentToAgent,
            .agentToAgent,
        ])
        XCTAssertEqual(items.map(\.title), [
            "main->researcher",
            "researcher->main",
            "main->researcher",
            "researcher->main",
        ])
        XCTAssertEqual(items.map(\.body), [
            "Please inspect the workspace.",
            "Inspection complete.",
            "Which files changed?",
            "Two Swift files changed.",
        ])
        XCTAssertEqual(
            items.map(\.timestamp),
            (1...4).map { Date(timeIntervalSince1970: Double($0)) })
    }

    func testCodeProjectionUsesStableItemIDsAcrossReplay() {
        let s = SessionID(rawValue: "stable")
        func env(_ seq: Int, _ e: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: s, event: e)
        }
        let worker = AgentID(rawValue: "worker")
        let contract = TaskContract(
            id: TaskID(rawValue: "task_stable"),
            issuer: AgentID(rawValue: "main"),
            assignee: worker,
            objective: "Inspect workspace.",
            roleHint: "workspace inspector",
            expectedDeliverable: "summary")
        let envelopes: [Envelope] = [
            env(0, .userMessage(.init(text: "start"))),
            env(1, .error(.init(code: "e", message: "failed"))),
            env(2, .agentAttached(.init(
                agent: worker,
                path: "/tmp/worker",
                model: ModelID(rawValue: "m"),
                profile: "reviewed"))),
            env(3, .permissionResolved(.init(
                requestId: RequestID(rawValue: "req_stable"),
                tool: "read_file",
                decision: .allow,
                risk: .low,
                reason: "allowed"))),
            env(4, .delegationApproved(.init(contract: contract))),
            env(5, .agentToAgentMessage(.init(from: worker, to: AgentID(rawValue: "main"), content: "done", mediated: true))),
            env(6, .workspaceLeaseDenied(.init(agent: worker, rootPath: "/tmp/blocked", reason: "denied"))),
            env(7, .permissionReview(.init(agent: worker, tool: "send_message", reviewerModel: "mediator", decision: .allow, risk: .low, reason: "ok"))),
        ]

        let first = CodeProjection.build(from: envelopes).items.map(\.id)
        let second = CodeProjection.build(from: envelopes).items.map(\.id)

        XCTAssertEqual(first, second)
    }
}
