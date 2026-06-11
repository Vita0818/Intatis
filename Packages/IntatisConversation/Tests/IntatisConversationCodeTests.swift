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
}
