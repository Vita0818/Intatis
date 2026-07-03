import XCTest
import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
@testable import IntatisCowork

private final class AutoReviewScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private var responses: [[AgentChunk]]
    private var index = 0
    private let lock = NSLock()

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let chunks = responses.isEmpty ? [.done(finishReason: "stop")] : responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private final class AutoReviewCapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()

    init(_ chunks: [AgentChunk]) {
        self.chunks = chunks
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private struct AttachOnlyResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        request.tool == "agent.attach" ? .allow : .deny
    }
}

private func autoReviewTempLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-auto-review-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "auto_review"), fileURL: url)
}

private func autoReviewWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory
        .appendingPathComponent("auto-review-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func autoReviewWriteArgs(path: String, content: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
    return String(decoding: data, as: UTF8.self)
}

final class AutomaticPermissionReviewTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let reviewer = Orchestrator.automaticPermissionReviewerID

    func testAutoCreatesReadonlyReviewerAndDefaultRemovesIt() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([.textDelta(#"{"decision":"allow","reason":"ok"}"#),
                                                    .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { _ in provider }

        let initiallyEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(initiallyEnabled)
        let result = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)

        XCTAssertEqual(result, .enabled(reviewer))
        let enabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertTrue(enabled)
        let agentsAfterEnable = await orch.agentList()
        let reviewerAgent = try XCTUnwrap(agentsAfterEnable.first { $0.name == reviewer })
        XCTAssertEqual(reviewerAgent.profile, .readOnly)
        XCTAssertEqual(reviewerAgent.coordinationDepth, 0)
        XCTAssertEqual(reviewerAgent.model, ModelID(rawValue: "reviewer-model"))

        let reviewerLease = await orch.capabilityLeaseList().first { $0.tools.isEmpty }
        XCTAssertNotNil(reviewerLease)

        let disabled = await orch.disableAutomaticPermissionReview()
        XCTAssertTrue(disabled)
        let enabledAfterDisable = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(enabledAfterDisable)
        let agentsAfterDisable = await orch.agentList()
        XCTAssertNil(agentsAfterDisable.first { $0.name == reviewer })
    }

    func testReviewerApprovesWorkspaceWriteWithoutTerminalApproval() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "write", name: "write_file",
                                  arguments: autoReviewWriteArgs(path: "auto.txt", content: "approved"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("done"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","risk":"low","reason":"matches the user request"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: ws,
                                                   model: ModelID(rawValue: "main-model"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let result = await orch.send("create auto.txt with approved", to: main)

        XCTAssertEqual(result, OrchestratorSendResult.sent)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("auto.txt"), encoding: .utf8),
                       "approved")
        let reviewRequest = try XCTUnwrap(reviewerProvider.requests.first)
        XCTAssertEqual(reviewRequest.model, ModelID(rawValue: "reviewer-model"))
        XCTAssertTrue(reviewRequest.tools.isEmpty)
        let prompt = reviewRequest.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Active agent roster:"))
        XCTAssertTrue(prompt.contains("@main"))
        XCTAssertTrue(prompt.contains("Recent global events:"))
        XCTAssertTrue(prompt.contains("create auto.txt with approved"))
        XCTAssertTrue(prompt.contains("write_file"))

        let reviews = await log.replay().compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.decision, .allow)
        XCTAssertEqual(reviews.last?.reviewerModel, "@permission-reviewer:reviewer-model")
    }

    func testReviewerAskUserFallsBackToResponderDeny() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "write", name: "write_file",
                                  arguments: autoReviewWriteArgs(path: "fallback.txt", content: "blocked"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("not written"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"ask_user","risk":"medium","reason":"ambiguous"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: ws,
                                                   model: ModelID(rawValue: "main-model"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        _ = await orch.enableAutomaticPermissionReview(model: ModelID(rawValue: "reviewer-model"), workspaceRoot: ws)

        let sendResult = await orch.send("write fallback.txt", to: main)
        XCTAssertEqual(sendResult, OrchestratorSendResult.sent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("fallback.txt").path))
        let reviews = await log.replay().compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.decision, .askUser)
    }

    func testHardDenyNeverReachesAutomaticReviewer() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "write", name: "write_file",
                                  arguments: autoReviewWriteArgs(path: ".env", content: "SECRET=value"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("blocked"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"should not be called"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: ws,
                                                   model: ModelID(rawValue: "main-model"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        _ = await orch.enableAutomaticPermissionReview(model: ModelID(rawValue: "reviewer-model"), workspaceRoot: ws)

        let sendResult = await orch.send("write .env", to: main)
        XCTAssertEqual(sendResult, OrchestratorSendResult.sent)

        XCTAssertTrue(reviewerProvider.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent(".env").path))
        let resolved = await log.replay().compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event, payload.tool == "write_file" {
                return payload
            }
            return nil
        }
        XCTAssertEqual(resolved.last?.decision, .deny)
    }
}
