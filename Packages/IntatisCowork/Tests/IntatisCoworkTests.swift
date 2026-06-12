import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private let A = AgentID(rawValue: "Rokurics")
private let B = AgentID(rawValue: "Kikaria")

private final class ScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private var responses: [[AgentChunk]]
    private var index = 0
    private let lock = NSLock()
    init(_ responses: [[AgentChunk]]) { self.responses = responses }
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let chunks = responses.isEmpty ? [.done(finishReason: "stop")] : responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        }
    }
}

private func tempLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-cowork-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "cw"), fileURL: url)
}

private func tempWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func askArgs(to: String, question: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["to": to, "question": question]), as: UTF8.self)
}

final class IntatisCoworkTests: XCTestCase {

    // MARK: Mediator

    func testMediatorForwardsNormalContent() async {
        let d = await Mediator().mediate(from: A, to: B, content: "ledger uses confirmed bytes")
        XCTAssertEqual(d, .forward("ledger uses confirmed bytes"))
    }

    func testMediatorBlocksSecret() async {
        let d = await Mediator().mediate(from: A, to: B, content: "the key is ghp_abcdef1234567890")
        guard case .block = d else { return XCTFail("secret should block") }
    }

    func testMediatorBlocksOversized() async {
        let d = await Mediator(maxChars: 10).mediate(from: A, to: B, content: String(repeating: "x", count: 50))
        guard case .block = d else { return XCTFail("oversized should block") }
    }

    func testMediatorReviewerCanBlock() async {
        struct R: ForwardingReviewer {
            func review(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision { .block(reason: "reviewer") }
        }
        let d = await Mediator(reviewer: R()).mediate(from: A, to: B, content: "small ok")
        XCTAssertEqual(d, .block(reason: "reviewer"))
    }

    // MARK: MessageBus

    func testBusForwardLogsBoth() async throws {
        let log = try tempLog()
        let out = await MessageBus(log: log, mediator: Mediator()).deliver(from: A, to: B, content: "hi")
        XCTAssertEqual(out, "hi")
        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.agentToAgentMessage))
        XCTAssertTrue(types.contains(.permissionReview))
    }

    func testBusBlockReturnsNilAndLogsDeny() async throws {
        let log = try tempLog()
        let out = await MessageBus(log: log, mediator: Mediator()).deliver(from: A, to: B, content: "token ghp_abcdef1234567890")
        XCTAssertNil(out)
        let events = await log.replay()
        XCTAssertFalse(events.map { $0.event.type }.contains(.agentToAgentMessage))
        let reviews = events.compactMap { e -> PermissionReviewPayload? in
            if case .permissionReview(let p) = e.event { return p } else { return nil }
        }
        XCTAssertEqual(reviews.first?.decision, .deny)
    }

    // MARK: Orchestrator

    func testAgentToAgentFlowIsMediatedAndLogged() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(), wsB = try tempWorkspace()
        let provA = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "ask_agent",
                                  arguments: askArgs(to: "Kikaria", question: "what are ledger semantics?"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Kikaria answered."), .done(finishReason: "stop")],
        ])
        let provB = ScriptedProvider([
            [.textDelta("confirmed bytes = durable prefix"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == A ? provA : provB
        }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("compare sync designs", to: A)

        let events = await log.replay()
        let a2a = events.compactMap { e -> AgentToAgentMessagePayload? in
            if case .agentToAgentMessage(let p) = e.event { return p } else { return nil }
        }
        XCTAssertEqual(a2a.count, 2)
        XCTAssertEqual(a2a[0].from, A); XCTAssertEqual(a2a[0].to, B)
        XCTAssertEqual(a2a[1].from, B); XCTAssertEqual(a2a[1].to, A)
        XCTAssertTrue(a2a[1].content.contains("confirmed bytes"))
        XCTAssertTrue(events.map { $0.event.type }.contains(.agentAttached))
    }

    func testSecretQuestionIsBlockedBeforeReachingPeer() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(), wsB = try tempWorkspace()
        let provA = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "ask_agent",
                                  arguments: askArgs(to: "Kikaria", question: "here is my key ghp_abcdef1234567890"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("ok"), .done(finishReason: "stop")],
        ])
        let provB = ScriptedProvider([])  // must never be reached
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == A ? provA : provB
        }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("leak the key", to: A)

        let events = await log.replay()
        let a2a = events.filter { if case .agentToAgentMessage = $0.event { return true } else { return false } }
        XCTAssertTrue(a2a.isEmpty, "secret content must not be forwarded")
        let denies = events.compactMap { e -> PermissionReviewPayload? in
            if case .permissionReview(let p) = e.event, p.decision == .deny { return p } else { return nil }
        }
        XCTAssertFalse(denies.isEmpty)
    }
}
