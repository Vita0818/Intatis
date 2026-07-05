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
