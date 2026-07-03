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

private final class CapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()

    init(_ chunks: [AgentChunk] = [.done(finishReason: "stop")]) {
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
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        }
    }
}

private enum ProviderFailure: LocalizedError {
    case unavailable

    var errorDescription: String? { "provider unavailable" }
}

private struct ThrowingProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderFailure.unavailable)
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

private func spawnArgs(name: String, path: String, model: String? = nil) -> String {
    var object = ["name": name, "path": path]
    if let model { object["model"] = model }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func taskCreatedContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskCreated(let payload) = $0.event { return payload.contract }
        return nil
    }
}

private func taskAssignedContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskAssigned(let payload) = $0.event { return payload.contract }
        return nil
    }
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

    func testExplicitMissingSendTargetDoesNotFallbackToFirstAgent() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let provider = CapturingProvider([.textDelta("should not run"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("do not fallback", to: AgentID(rawValue: "Ghost"))

        XCTAssertTrue(provider.requests.isEmpty)
        let errors = await log.replay().compactMap { envelope -> ErrorPayload? in
            if case .error(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(errors.last?.code, "no_such_agent")
    }

    func testSendReturnsFailureWhenAgentRunFails() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in
            ThrowingProvider()
        }

        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        let result = await orch.send("fail visibly", to: A)

        XCTAssertEqual(result, .failed("provider unavailable"))
        let errors = await log.replay().compactMap { envelope -> ErrorPayload? in
            if case .error(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(errors.last?.message, "provider unavailable")
    }

    func testSendRecordsGoalPayloadForTargetedCoworkMessage() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let provider = CapturingProvider([.textDelta("ok"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))

        let result = await orch.send(
            "ship v0.12",
            to: A,
            userMessage: UserMessagePayload(text: "ship v0.12", to: A, tags: ["Goal"], goal: "ship v0.12"))

        XCTAssertEqual(result, .sent)
        let payloads = await log.replay().compactMap { envelope -> UserMessagePayload? in
            if case .userMessage(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(payloads.last?.text, "ship v0.12")
        XCTAssertEqual(payloads.last?.to, A)
        XCTAssertEqual(payloads.last?.tags ?? [], ["Goal"])
        XCTAssertEqual(payloads.last?.goal, "ship v0.12")
        let userMessages = provider.requests.last?.messages.filter { $0.role == .user }.compactMap(\.content)
        XCTAssertEqual(userMessages?.last, "ship v0.12")
    }

    func testRetryFailedTaskRequeuesExistingContract() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let provider = CapturingProvider([.textDelta("retried"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        let contract = TaskContract(
            id: TaskID(rawValue: "task_retry"),
            issuer: nil,
            assignee: A,
            objective: "Retry the failed task.",
            roleHint: "retry worker",
            expectedDeliverable: "retried")
        let failed = CoworkTaskView(
            id: contract.id,
            contract: contract,
            status: .failed,
            assignee: A,
            error: "provider failed")

        let result = await orch.retry(failed)

        XCTAssertEqual(result, .sent)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.tasks[contract.id]?.status, .completed)
        XCTAssertEqual(projection.tasks[contract.id]?.result, "retried")
    }

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
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("compare sync designs", to: A)

        let events = await log.replay()
        let a2a = events.compactMap { e -> AgentToAgentMessagePayload? in
            if case .agentToAgentMessage(let p) = e.event { return p } else { return nil }
        }
        XCTAssertEqual(a2a.count, 2)
        guard a2a.count == 2 else { return }
        XCTAssertEqual(a2a[0].from, A); XCTAssertEqual(a2a[0].to, B)
        XCTAssertEqual(a2a[1].from, B); XCTAssertEqual(a2a[1].to, A)
        XCTAssertTrue(a2a[1].content.contains("confirmed bytes"))
        XCTAssertTrue(events.map { $0.event.type }.contains(.agentAttached))
    }

    func testAskAgentCreatesTaskContractAndInjectsPrompt() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(), wsB = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsA)
            try? FileManager.default.removeItem(at: wsB)
        }
        let workerProvider = CapturingProvider([.textDelta("done"), .done(finishReason: "stop")])
        let mainProvider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "ask", name: "ask_agent",
                                  arguments: askArgs(to: B.rawValue, question: "Inspect the workspace API."))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("worker answered"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == B {
                return workerProvider
            }
            return mainProvider
        }

        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("ask worker", to: A)

        let events = await log.replay()
        let created = taskCreatedContracts(events)
        let assigned = taskAssignedContracts(events)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(assigned.count, 1)
        let contract = try XCTUnwrap(created.first)
        XCTAssertEqual(assigned.first, contract)
        XCTAssertEqual(contract.issuer, A)
        XCTAssertEqual(contract.assignee, B)
        XCTAssertFalse(contract.objective.isEmpty)
        XCTAssertFalse(contract.expectedDeliverable.isEmpty)
        XCTAssertTrue(contract.relatedAgents.contains(A))
        XCTAssertTrue(contract.constraints.contains("Complete only the assigned task."))
        XCTAssertTrue(contract.constraints.contains("Do not re-run the global task decomposition."))
        XCTAssertTrue(contract.constraints.contains("Do not create, remove, or coordinate other agents."))

        let request = try XCTUnwrap(workerProvider.requests.first)
        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("Current task:"))
        XCTAssertTrue(systemPrompt.contains("- Task ID: \(contract.id.rawValue)"))
        XCTAssertTrue(systemPrompt.contains("- Assigned by: @\(A.rawValue)"))
        XCTAssertTrue(systemPrompt.contains("- Your role in this task: \(contract.roleHint)"))
        XCTAssertTrue(systemPrompt.contains("- Objective: \(contract.objective)"))
        XCTAssertTrue(systemPrompt.contains("- Expected deliverable: \(contract.expectedDeliverable)"))
        XCTAssertTrue(systemPrompt.contains("Complete only the assigned task."))
        XCTAssertTrue(systemPrompt.contains("Do not re-run the global task decomposition."))
        XCTAssertTrue(systemPrompt.contains("Do not create, remove, or coordinate other agents."))
        XCTAssertFalse(systemPrompt.lowercased().contains("you can spawn agents"))
        XCTAssertFalse(systemPrompt.lowercased().contains("you can coordinate agents"))
        XCTAssertFalse(systemPrompt.lowercased().contains("you can delegate freely"))
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
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
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

    func testMainCanSpawnWorkerButSpawnedWorkerHasNoCoordinatorTools() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let wsMain = try tempWorkspace()
        let wsWorker = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let mainProvider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "spawn", name: "spawn_agent",
                                  arguments: spawnArgs(name: worker.rawValue, path: wsWorker.path, model: "m"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("worker ready"), .done(finishReason: "stop")],
        ])
        let workerProvider = CapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == worker {
                return workerProvider
            }
            return mainProvider
        }

        let attached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orch.send("create a worker", to: main)

        let spawned = await orch.agentList().first { $0.name == worker }
        XCTAssertNotNil(spawned)
        XCTAssertEqual(spawned?.coordinationDepth, 0)

        await orch.send("count assigned files", to: worker)
        let request = try XCTUnwrap(workerProvider.requests.last)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertFalse(toolNames.contains("spawn_agent"))
        XCTAssertFalse(toolNames.contains("ask_agent"))
        XCTAssertFalse(toolNames.contains("list_agents"))
        XCTAssertFalse(toolNames.contains("remove_agent"))

        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("You are executing the assigned task as a worker agent."))
        XCTAssertTrue(systemPrompt.contains("Do not create, remove, or coordinate other agents."))
        XCTAssertTrue(systemPrompt.contains("Only reply to task-related messages when reply_message is available."))
        XCTAssertTrue(systemPrompt.contains("Do not re-run the global task decomposition."))
        XCTAssertFalse(systemPrompt.contains("spawn_agent"))
        XCTAssertFalse(systemPrompt.contains("ask_agent"))
        XCTAssertFalse(systemPrompt.contains("list_agents"))
        XCTAssertFalse(systemPrompt.contains("remove_agent"))
        XCTAssertFalse(systemPrompt.contains("COORDINATOR"))
        XCTAssertFalse(systemPrompt.lowercased().contains("delegate"))
    }

    func testWorkerCannotAskItself() async throws {
        let log = try tempLog()
        let worker = AgentID(rawValue: "worker")
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = CapturingProvider([.textDelta("should not run"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        let attached = await orch.attach(Agent(name: worker, workspaceRoot: ws, model: ModelID(rawValue: "m"),
                                               profile: .reviewed))
        XCTAssertTrue(attached)
        let response = await orch.ask(from: worker, to: "@worker", question: "can you do this?")

        XCTAssertEqual(response, "error: agent cannot ask itself")
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        XCTAssertFalse(events.contains { if case .agentToAgentMessage = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains {
            if case .error(let payload) = $0.event { return payload.code == "agent_self_call" }
            return false
        })
    }

    func testSpawnAgentDescriptorIsNotReadOnly() {
        XCTAssertEqual(SpawnAgentTool.descriptor.sideEffect, .write)
    }

    func testCountScenarioCreatesSeparateWorkerContracts() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try tempWorkspace()
        let wsMacos = try tempWorkspace()
        let wsIOS = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let macosProvider = CapturingProvider([.textDelta("macOS count"), .done(finishReason: "stop")])
        let iosProvider = CapturingProvider([.textDelta("iOS count"), .done(finishReason: "stop")])
        let mainProvider = CapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == macos {
                return macosProvider
            }
            if agent.name == ios {
                return iosProvider
            }
            return mainProvider
        }

        await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: macos, workspaceRoot: wsMacos, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.attach(Agent(name: ios, workspaceRoot: wsIOS, model: ModelID(rawValue: "m"), profile: .reviewed))

        _ = await orch.ask(from: main, to: macos.rawValue,
                           question: "Recursively count macOS Swift files only.")
        _ = await orch.ask(from: main, to: ios.rawValue,
                           question: "Recursively count iOS Swift files only.")

        let contracts = taskCreatedContracts(await log.replay())
        XCTAssertEqual(contracts.count, 2)
        let macosContract = try XCTUnwrap(contracts.first { $0.assignee == macos })
        let iosContract = try XCTUnwrap(contracts.first { $0.assignee == ios })

        XCTAssertEqual(macosContract.roleHint, "macOS Swift file counter")
        XCTAssertEqual(iosContract.roleHint, "iOS Swift file counter")
        XCTAssertTrue(macosContract.objective.contains("macOS"))
        XCTAssertFalse(macosContract.objective.contains("iOS"))
        XCTAssertTrue(iosContract.objective.contains("iOS"))
        XCTAssertFalse(iosContract.objective.contains("macOS"))
        XCTAssertNotEqual(macosContract.assignee, iosContract.assignee)
        XCTAssertTrue(macosContract.relatedAgents.contains(ios))
        XCTAssertTrue(iosContract.relatedAgents.contains(macos))

        let agents = await orch.agentList()
        XCTAssertEqual(agents.first { $0.name == macos }?.coordinationDepth, 0)
        XCTAssertEqual(agents.first { $0.name == ios }?.coordinationDepth, 0)

        let macosPrompt = try XCTUnwrap(macosProvider.requests.first?.messages.first?.content)
        let iosPrompt = try XCTUnwrap(iosProvider.requests.first?.messages.first?.content)
        XCTAssertTrue(macosPrompt.contains("macOS Swift file counter"))
        XCTAssertTrue(macosPrompt.contains("Recursively count macOS Swift files only."))
        XCTAssertTrue(iosPrompt.contains("iOS Swift file counter"))
        XCTAssertTrue(iosPrompt.contains("Recursively count iOS Swift files only."))
    }
}
