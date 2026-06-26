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
