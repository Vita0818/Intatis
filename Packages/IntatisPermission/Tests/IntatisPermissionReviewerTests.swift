import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisPermission

private struct CannedChat: ChatProvider {
    let text: String
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { c in c.yield(.delta(text)); c.yield(.done); c.finish() }
    }
}

private func reviewCtx(profile: PermissionProfile = .reviewed) -> PermissionContext {
    PermissionContext(workspaceRoot: URL(fileURLWithPath: "/ws"), profile: profile,
                      allowsShell: true, userGoal: "edit a file", agent: AgentID(rawValue: "Coder"))
}

private func writeCall() -> ToolCallContext {
    ToolCallContext(toolName: "write_file", sideEffect: .write, touchedPaths: ["a.swift"],
                    risksNetwork: false, rawArgs: #"{"path":"a.swift","content":"x"}"#)
}

final class IntatisPermissionReviewerTests: XCTestCase {

    func testReviewerParsesAllow() async {
        let r = ModelPermissionReviewer(
            provider: CannedChat(text: #"{"decision":"allow","risk":"low","reason":"ok"}"#),
            model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .low)
        XCTAssertEqual(out.decision, .allow)
        XCTAssertEqual(out.reason, "ok")
    }

    func testReviewerParsesDenyWithSurroundingProse() async {
        let r = ModelPermissionReviewer(
            provider: CannedChat(text: "Sure: {\"decision\":\"deny\",\"risk\":\"high\",\"reason\":\"unrelated\"} ."),
            model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .medium)
        XCTAssertEqual(out.decision, .deny)
        XCTAssertEqual(out.risk, .high)
    }

    func testReviewerUnparseableAsksUser() async {
        let r = ModelPermissionReviewer(provider: CannedChat(text: "no json here"), model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .medium)
        XCTAssertEqual(out.decision, .askUser)
    }

    func testEngineWriteUsesConfiguredModelReviewer() async {
        let reviewer = ModelPermissionReviewer(
            provider: CannedChat(text: #"{"decision":"allow","risk":"low","reason":"fine"}"#),
            model: ModelID(rawValue: "rev"))
        let engine = PermissionEngine(reviewer: reviewer)
        let out = await engine.decide(writeCall(), reviewCtx(profile: .reviewed))
        XCTAssertEqual(out.decision, .allow)
        XCTAssertEqual(out.reason, "fine")
    }

    func testHardDenyNeverReachesReviewer() async {
        // The reviewer would say allow, but a sensitive read is a hard deny at the
        // gate — it returns `deny`, never `pass`, so the reviewer is not consulted.
        let reviewer = ModelPermissionReviewer(provider: CannedChat(text: #"{"decision":"allow"}"#),
                                               model: ModelID(rawValue: "rev"))
        let engine = PermissionEngine(reviewer: reviewer)
        let sensitive = ToolCallContext(toolName: "read_file", sideEffect: .readOnly,
                                        touchedPaths: [".env"], risksNetwork: false, rawArgs: "{}")
        let out = await engine.decide(sensitive, reviewCtx())
        XCTAssertEqual(out.decision, .deny)
    }
}
