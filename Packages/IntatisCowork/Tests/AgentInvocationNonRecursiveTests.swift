import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class NonRecursiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private actor CapturingNonRecursiveResponder: PermissionResponder {
    private var captured: [PermissionRequestPayload] = []
    private let decision: PermissionDecision

    init(_ decision: PermissionDecision) {
        self.decision = decision
    }

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        captured.append(request)
        return decision
    }

    func requests() -> [PermissionRequestPayload] { captured }
}

private actor DenyDelegationNonRecursiveResponder: PermissionResponder {
    private var captured: [PermissionRequestPayload] = []

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        captured.append(request)
        return request.tool == "delegate_task" ? .deny : .allow
    }

    func requests() -> [PermissionRequestPayload] { captured }
}

private final class NonRecursiveProvider: ToolCallingProvider, @unchecked Sendable {
    private let responses: [[AgentChunk]]
    private let onStream: (@Sendable (Int, AgentRequest) -> Void)?
    private let lock = NSLock()
    private var index = 0
    private var capturedRequests: [AgentRequest] = []

    init(_ responses: [[AgentChunk]], onStream: (@Sendable (Int, AgentRequest) -> Void)? = nil) {
        self.responses = responses
        self.onStream = onStream
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let streamIndex = index
        let chunks = responses.isEmpty ? [.done(finishReason: "stop")] : responses[min(index, responses.count - 1)]
        index += 1
        capturedRequests.append(request)
        lock.unlock()
        onStream?(streamIndex, request)
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private actor SuspendedAnswerReviewer: ForwardingReviewer {
    private let answer: String
    private var answerReached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(answer: String) {
        self.answer = answer
    }

    func review(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision {
        guard content == answer else { return .forward(content) }
        answerReached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return .block(reason: "test blocked the completed answer")
    }

    func waitUntilAnswerReached() async {
        if answerReached { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func releaseAnswer() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private func nonRecursiveLog(_ suffix: String = UUID().uuidString) throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-nonrecursive-\(suffix)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "nonrecursive"), fileURL: url)
}

private func nonRecursiveWorkspace(_ suffix: String = UUID().uuidString) throws -> URL {
    let ws = FileManager.default.temporaryDirectory
        .appendingPathComponent("nonrecursive-ws-\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func delegateArgs(to: String,
                          objective: String,
                          roleHint: String? = nil,
                          expectedDeliverable: String? = nil) -> String {
    var object: [String: String] = ["to": to, "objective": objective]
    if let roleHint { object["roleHint"] = roleHint }
    if let expectedDeliverable { object["expectedDeliverable"] = expectedDeliverable }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func automaticDelegateArgs(objective: String,
                                   roleHint: String? = nil,
                                   expectedDeliverable: String? = nil) -> String {
    var object: [String: String] = ["objective": objective]
    if let roleHint { object["roleHint"] = roleHint }
    if let expectedDeliverable { object["expectedDeliverable"] = expectedDeliverable }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func askArgs(to: String, question: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [
        "to": to,
        "question": question,
    ]), as: UTF8.self)
}

private func spawnArgs(name: String,
                       path: String,
                       model: String? = nil,
                       canCoordinate: Bool? = nil) -> String {
    var object: [String: Any] = ["name": name, "path": path]
    if let model { object["model"] = model }
    if let canCoordinate { object["canCoordinate"] = canCoordinate }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

final class AgentInvocationNonRecursiveTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    func testDelegateTaskWithoutTargetAtomicallyCreatesWorkerAndReturnsStableIdentity() async throws {
        let log = try nonRecursiveLog()
        let workspace = try nonRecursiveWorkspace("automatic-worker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let generatedWorker = AgentID(rawValue: "worker-1")
        let workerProvider = NonRecursiveProvider([
            [.textDelta("automatic worker result"), .done(finishReason: "stop")],
        ])
        let mainProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(
                    id: "delegate-auto",
                    name: "delegate_task",
                    arguments: automaticDelegateArgs(
                        objective: "Perform one bounded worker task.",
                        roleHint: "automatic worker",
                        expectedDeliverable: "Return the bounded result."))
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("main synthesized automatic worker result"), .done(finishReason: "stop")],
        ])
        let responder = CapturingNonRecursiveResponder(.allow)
        let orch = Orchestrator(log: log, allowsShell: true, responder: responder) { agent in
            agent.name == generatedWorker ? workerProvider : mainProvider
        }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)

        let sent = await orch.send("Delegate without naming a worker.", to: main)
        XCTAssertEqual(sent, .sent)

        XCTAssertEqual(workerProvider.requests.count, 1)
        let mainFollowup = try XCTUnwrap(mainProvider.requests.last)
        let delegateResult = try XCTUnwrap(mainFollowup.messages.first {
            $0.role == .tool && $0.toolCallId == "delegate-auto"
        }?.content)
        XCTAssertTrue(delegateResult.contains("task_id="))
        XCTAssertTrue(delegateResult.contains("agent_id=@worker-1"))
        XCTAssertTrue(delegateResult.contains("automatic worker result"))
        let approvals = await responder.requests()
        XCTAssertEqual(approvals.filter { $0.tool == "delegate_task" }.count, 1)
        let delegateApproval = try XCTUnwrap(approvals.first { $0.tool == "delegate_task" })
        let reviewedAuthorization = try XCTUnwrap(delegateApproval.context?.authorization)
        XCTAssertEqual(
            reviewedAuthorization.intent.resources.first { $0.kind == .agent }?.value,
            generatedWorker.rawValue)
        XCTAssertEqual(
            delegateApproval.context?.intent?.resources.first { $0.kind == .agent }?.value,
            generatedWorker.rawValue)
        XCTAssertEqual(
            reviewedAuthorization.intent.metadata["targetResolution"],
            .string("create_proposed"))
        XCTAssertEqual(reviewedAuthorization.actionPreview?.fields["to"], nil)
        XCTAssertTrue(delegateApproval.args.hasPrefix("digest="))
        XCTAssertFalse(delegateApproval.args.contains("Perform one bounded worker task."))
        XCTAssertFalse(approvals.contains { $0.tool == "agent.attach" && $0.agent == generatedWorker })
        let events = await log.replay()
        let delegateRequestSequence = try XCTUnwrap(events.first { envelope in
            if case .permissionRequest(let payload) = envelope.event {
                return payload.tool == "delegate_task"
            }
            return false
        }?.seq)
        let workerSpawnSequence = try XCTUnwrap(events.first { envelope in
            if case .agentSpawnRequested(let payload) = envelope.event {
                return payload.agent == generatedWorker
            }
            return false
        }?.seq)
        XCTAssertGreaterThan(workerSpawnSequence, delegateRequestSequence)
        XCTAssertTrue(events.contains {
            if case .agentSpawned(let payload) = $0.event { return payload.agent == generatedWorker }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .taskCompleted(let payload) = $0.event {
                return payload.report?.summary == "automatic worker result"
            }
            return false
        })
    }

    func testDeniedAutomaticDelegateReviewsConcreteTargetWithoutCreatingWorker() async throws {
        let log = try nonRecursiveLog()
        let workspace = try nonRecursiveWorkspace("automatic-worker-denied-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let generatedWorker = AgentID(rawValue: "worker-1")
        let mainProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(
                    id: "delegate-auto-denied",
                    name: "delegate_task",
                    arguments: automaticDelegateArgs(
                        objective: "Attempt one reviewed worker task."))
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("The delegation was denied."), .done(finishReason: "stop")],
        ])
        let responder = DenyDelegationNonRecursiveResponder()
        let orch = Orchestrator(log: log, allowsShell: true, responder: responder) { _ in
            mainProvider
        }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let result = await orch.send("Try a reviewed automatic delegation.", to: main)
        guard case .failed = result else {
            return XCTFail("A denied required delegation must fail its calling task.")
        }
        let approvals = await responder.requests()
        let delegateApproval = try XCTUnwrap(approvals.first { $0.tool == "delegate_task" })
        XCTAssertEqual(
            delegateApproval.context?.authorization?.intent.resources.first {
                $0.kind == .agent
            }?.value,
            generatedWorker.rawValue)
        let agentNames = await orch.agentNames()
        XCTAssertFalse(agentNames.contains(generatedWorker))
        let events = await log.replay()
        XCTAssertFalse(events.contains { envelope in
            if case .agentSpawnRequested(let payload) = envelope.event {
                return payload.agent == generatedWorker
            }
            return false
        })
    }

    func testAutomaticDelegateRollsBackNewWorkerWhenTaskAdmissionIsBlocked() async throws {
        let log = try nonRecursiveLog()
        let workspace = try nonRecursiveWorkspace("automatic-worker-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = NonRecursiveProvider([
            [.textDelta("unused"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)

        let result = await orch.delegateTask(
            from: main,
            to: nil,
            objective: "Do not forward this secret marker ghp_abcdef1234567890")

        XCTAssertEqual(result, "your delegated task was blocked by the mediator")
        let remainingAgents = await orch.agentNames()
        XCTAssertFalse(remainingAgents.contains(AgentID(rawValue: "worker-1")))
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .agentSpawned(let payload) = $0.event {
                return payload.agent == AgentID(rawValue: "worker-1")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .agentDetached(let payload) = $0.event {
                return payload.agent == AgentID(rawValue: "worker-1")
            }
            return false
        })
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testDelegateTaskToolRunsScheduledWorkerAndReturnsResultToCallerLoop() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let workerProvider = NonRecursiveProvider([
            [.textDelta("worker result"), .done(finishReason: "stop")],
        ])
        let workerRanBeforeCallerContinued = NonRecursiveFlag()
        let mainProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(id: "delegate",
                         name: "delegate_task",
                         arguments: delegateArgs(
                            to: worker.rawValue,
                            objective: "Run the worker task.",
                            roleHint: "worker",
                            expectedDeliverable: "Return a concise result."))
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("main synthesized worker result"), .done(finishReason: "stop")],
        ], onStream: { index, _ in
            if index == 1 {
                workerRanBeforeCallerContinued.set(workerProvider.requests.count == 1)
            }
        })
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == self.worker ? workerProvider : mainProvider
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        await orch.send("delegate to worker", to: main)

        XCTAssertTrue(workerRanBeforeCallerContinued.value)
        XCTAssertEqual(workerProvider.requests.count, 1)
        XCTAssertEqual(mainProvider.requests.count, 2)
        let secondMainRequest = try XCTUnwrap(mainProvider.requests.last)
        XCTAssertTrue(secondMainRequest.messages.contains {
            $0.role == .tool && $0.content?.contains("worker result") == true
        })
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .taskQueued = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .taskStarted = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains {
            if case .taskCompleted(let payload) = $0.event {
                return payload.result == "worker result" && payload.report?.summary == "worker result"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .agentToAgentMessage(let payload) = $0.event {
                return payload.from == self.worker
                    && payload.to == self.main
                    && payload.content.contains("Task Report")
                    && payload.content.contains("worker result")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .toolResult(let payload) = $0.event {
                return payload.toolCallId == "delegate"
                    && payload.observation.contains("Task Report")
                    && payload.observation.contains("worker result")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .messageCompleted(let payload) = $0.event {
                return payload.agent == self.main && payload.text == "main synthesized worker result"
            }
            return false
        })
        let remainingAgentsAfterManualDelegate = await orch.agentNames()
        XCTAssertTrue(remainingAgentsAfterManualDelegate.contains(worker))
    }

    func testToolSpawnedWorkerReportsStructuredResultAndIsAutoDetachedWhenIdle() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let workerProvider = NonRecursiveProvider([
            [.textDelta("spawned worker result"), .done(finishReason: "stop")],
        ])
        let mainProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(id: "spawn",
                         name: "spawn_agent",
                         arguments: spawnArgs(
                            name: worker.rawValue,
                            path: wsWorker.path,
                            model: "m"))
            ]), .done(finishReason: "tool_calls")],
            [.toolCalls([
                ToolCall(id: "delegate",
                         name: "delegate_task",
                         arguments: delegateArgs(
                            to: worker.rawValue,
                            objective: "Run the spawned worker task.",
                            roleHint: "spawned worker",
                            expectedDeliverable: "Return the spawned worker result."))
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("main synthesized spawned worker report"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == self.worker ? workerProvider : mainProvider
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)

        await orch.send("spawn and delegate to worker", to: main)

        XCTAssertEqual(workerProvider.requests.count, 1)
        XCTAssertEqual(mainProvider.requests.count, 3)
        let finalMainRequest = try XCTUnwrap(mainProvider.requests.last)
        XCTAssertTrue(finalMainRequest.messages.contains {
            $0.role == .tool
                && $0.content?.contains("Task Report") == true
                && $0.content?.contains("spawned worker result") == true
        })
        let remainingAgentsAfterAutoRecycle = await orch.agentNames()
        XCTAssertFalse(remainingAgentsAfterAutoRecycle.contains(worker))

        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .agentSpawnRequested(let payload) = $0.event {
                return payload.requestedBy == self.main && payload.agent == self.worker
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .agentSpawned(let payload) = $0.event {
                return payload.requestedBy == self.main && payload.agent == self.worker
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .taskCompleted(let payload) = $0.event {
                return payload.agent == self.worker
                    && payload.result == "spawned worker result"
                    && payload.report?.status == .completed
                    && payload.report?.summary == "spawned worker result"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .agentToAgentMessage(let payload) = $0.event {
                return payload.from == self.worker
                    && payload.to == self.main
                    && payload.content.contains("Task Report")
                    && payload.content.contains("spawned worker result")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .agentDetached(let payload) = $0.event {
                return payload.agent == self.worker
                    && payload.reason?.contains("auto-recycled tool-spawned agent") == true
            }
            return false
        })
    }

    func testDelegatedWorkerCanUseToolsAndReturnObservedResultToParent() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        try "fixture\n".write(
            to: wsWorker.appendingPathComponent("worker-file.txt"),
            atomically: true,
            encoding: .utf8)

        let workerProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(id: "list",
                         name: "list_files",
                         arguments: "{\"path\":\".\"}")
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("worker used list_files and saw worker-file.txt"), .done(finishReason: "stop")],
        ])
        let mainProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(id: "delegate",
                         name: "delegate_task",
                         arguments: delegateArgs(
                            to: worker.rawValue,
                            objective: "List your workspace and report the file names.",
                            roleHint: "workspace lister",
                            expectedDeliverable: "Return the observed file names."))
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("main received worker file report"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == self.worker ? workerProvider : mainProvider
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        await orch.send("delegate tool-using work to worker", to: main)

        XCTAssertEqual(workerProvider.requests.count, 2)
        let workerSecondRequest = try XCTUnwrap(workerProvider.requests.last)
        XCTAssertTrue(workerSecondRequest.messages.contains {
            $0.role == .tool && $0.content?.contains("worker-file.txt") == true
        })
        XCTAssertEqual(mainProvider.requests.count, 2)
        let mainSecondRequest = try XCTUnwrap(mainProvider.requests.last)
        XCTAssertTrue(mainSecondRequest.messages.contains {
            $0.role == .tool && $0.content?.contains("worker used list_files") == true
        })

        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .toolCall(let payload) = $0.event {
                return payload.agent == self.worker && payload.name == "list_files"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .toolResult(let payload) = $0.event {
                return payload.toolCallId == "list" && payload.observation.contains("worker-file.txt")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .agentToAgentMessage(let payload) = $0.event {
                return payload.from == self.worker
                    && payload.to == self.main
                    && payload.content.contains("Task Report")
                    && payload.content.contains("worker used list_files")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .messageCompleted(let payload) = $0.event {
                return payload.agent == self.main && payload.text == "main received worker file report"
            }
            return false
        })
    }

    func testAskAgentToolReturnsScheduledWorkerResultToCallerLoop() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let workerProvider = NonRecursiveProvider([
            [.textDelta("ask worker answer"), .done(finishReason: "stop")],
        ])
        let mainProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(id: "ask",
                         name: "ask_agent",
                         arguments: askArgs(to: worker.rawValue, question: "Answer through scheduler."))
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("main synthesized ask answer"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == self.worker ? workerProvider : mainProvider
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        await orch.send("ask worker", to: main)

        XCTAssertEqual(workerProvider.requests.count, 1)
        XCTAssertEqual(mainProvider.requests.count, 2)
        let secondMainRequest = try XCTUnwrap(mainProvider.requests.last)
        XCTAssertTrue(secondMainRequest.messages.contains {
            $0.role == .tool && $0.content == "ask worker answer"
        })
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .agentToAgentMessage(let payload) = $0.event {
                return payload.from == self.worker && payload.to == self.main && payload.content == "ask worker answer"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .toolResult(let payload) = $0.event {
                return payload.toolCallId == "ask" && payload.observation == "ask worker answer"
            }
            return false
        })
    }

    func testAskAgentMediatorFailureCannotSettleSucceededOrCompleteCallingTask() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        let recipient = AgentID(rawValue: "recipient")
        let wsRecipient = try nonRecursiveWorkspace("recipient-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
            try? FileManager.default.removeItem(at: wsRecipient)
        }
        let workerProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(
                    id: "ask-blocked",
                    name: "ask_agent",
                    arguments: askArgs(
                        to: recipient.rawValue,
                        question: "Do not forward this secret marker ghp_abcdef1234567890"))
            ]), .done(finishReason: "tool_calls")],
        ])
        let unusedProvider = NonRecursiveProvider([
            [.textDelta("must not run"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { agent in
                agent.name == self.worker ? workerProvider : unusedProvider
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: wsMain,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(
            name: worker,
            workspaceRoot: wsWorker,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let recipientAttached = await orch.attach(Agent(
            name: recipient,
            workspaceRoot: wsRecipient,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        XCTAssertTrue(recipientAttached)

        let result = await orch.delegateTask(
            from: main,
            to: worker.rawValue,
            objective: "Ask the recipient the supplied question.")

        XCTAssertTrue(result.contains("status=failed") || result.contains("error:"), result)
        XCTAssertEqual(workerProvider.requests.count, 1)
        XCTAssertTrue(unusedProvider.requests.isEmpty)

        let events = await log.replay()
        let failedTask = try XCTUnwrap(events.compactMap { envelope -> TaskFailedPayload? in
            guard case .taskFailed(let payload) = envelope.event,
                  payload.agent == self.worker else { return nil }
            return payload
        }.last)
        XCTAssertFalse(events.contains { envelope in
            guard case .taskCompleted(let payload) = envelope.event else { return false }
            return payload.taskID == failedTask.taskID
        })

        let prepared = events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event,
                  payload.toolCallID == "ask-blocked" else { return nil }
            return payload
        }
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.taskID, failedTask.taskID)
        XCTAssertEqual(prepared.first?.replayPolicy, .requiresManualReconciliation)
        XCTAssertFalse(events.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return false }
            return payload.toolCallID == "ask-blocked" && payload.outcome == .succeeded
        })
    }

    func testAskAgentBlockedAnswerCannotBecomeSuccessfulToolObservation() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        let recipient = AgentID(rawValue: "recipient")
        let wsRecipient = try nonRecursiveWorkspace("recipient-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
            try? FileManager.default.removeItem(at: wsRecipient)
        }
        let workerProvider = NonRecursiveProvider([
            [.toolCalls([
                ToolCall(
                    id: "ask-blocked-answer",
                    name: "ask_agent",
                    arguments: askArgs(
                        to: recipient.rawValue,
                        question: "Return one concise status line."))
            ]), .done(finishReason: "tool_calls")],
        ])
        let recipientProvider = NonRecursiveProvider([
            [.textDelta("secret answer ghp_abcdef1234567890"), .done(finishReason: "stop")],
        ])
        let unusedProvider = NonRecursiveProvider([
            [.textDelta("must not run"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { agent in
                switch agent.name {
                case self.worker: workerProvider
                case recipient: recipientProvider
                default: unusedProvider
                }
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: wsMain,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(
            name: worker,
            workspaceRoot: wsWorker,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let recipientAttached = await orch.attach(Agent(
            name: recipient,
            workspaceRoot: wsRecipient,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        XCTAssertTrue(recipientAttached)

        let result = await orch.delegateTask(
            from: main,
            to: worker.rawValue,
            objective: "Ask the recipient for the status line.")

        XCTAssertTrue(result.contains("status=failed") || result.contains("error:"), result)
        XCTAssertEqual(workerProvider.requests.count, 1)
        XCTAssertEqual(recipientProvider.requests.count, 1)
        XCTAssertTrue(unusedProvider.requests.isEmpty)

        let events = await log.replay()
        let blockedToolResult = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "ask-blocked-answer" else { return nil }
            return payload
        }.last)
        XCTAssertTrue(blockedToolResult.observation.hasPrefix("tool error:"), blockedToolResult.observation)
        XCTAssertTrue(blockedToolResult.observation.contains("blocked by the mediator"), blockedToolResult.observation)
        XCTAssertFalse(events.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return false }
            return payload.toolCallID == "ask-blocked-answer" && payload.outcome == .succeeded
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .taskCompleted(let payload) = envelope.event else { return false }
            return payload.agent == self.worker
        })
    }

    func testLateAskWaiterCannotBypassPendingMediatorDeliveryOutcome() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let answer = "answer awaiting mediated delivery"
        let reviewer = SuspendedAnswerReviewer(answer: answer)
        let workerProvider = NonRecursiveProvider([
            [.textDelta(answer), .done(finishReason: "stop")],
        ])
        let unusedProvider = NonRecursiveProvider([
            [.textDelta("must not run"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(
            log: log,
            mediator: Mediator(reviewer: reviewer),
            allowsShell: true,
            responder: FixedResponder(.allow)) { agent in
                agent.name == self.worker ? workerProvider : unusedProvider
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: wsMain,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(
            name: worker,
            workspaceRoot: wsWorker,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let queued = await orch.enqueueAsk(
            from: main,
            to: worker.rawValue,
            question: "Return the safe test answer.",
            parentTaskID: nil)
        let taskID = try XCTUnwrap(queued.taskID)
        await reviewer.waitUntilAnswerReached()

        let waiterReturned = NonRecursiveFlag()
        let waiterRegistered = expectation(description: "late scheduler waiter registered")
        await orch.setSchedulerResultWaiterHookForTesting { registeredTaskID in
            if registeredTaskID == taskID {
                waiterRegistered.fulfill()
            }
        }
        let lateWaiter = Task {
            let value = await orch.awaitSchedulerResult(taskID)
            waiterReturned.set(true)
            return value
        }
        await fulfillment(of: [waiterRegistered], timeout: 1)
        XCTAssertFalse(waiterReturned.value)

        await reviewer.releaseAnswer()
        let delivered = await lateWaiter.value
        await orch.setSchedulerResultWaiterHookForTesting(nil)
        XCTAssertTrue(waiterReturned.value)
        XCTAssertEqual(
            delivered,
            "delegated task completed, but the result was blocked by the mediator; ask @worker for a shorter summary")
    }

    func testAskAgentCompatibilityWrapperAwaitsSchedulerResultWithoutNestedExecution() async throws {
        let log = try nonRecursiveLog()
        let wsMain = try nonRecursiveWorkspace("main-\(UUID().uuidString)")
        let wsWorker = try nonRecursiveWorkspace("worker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let workerProvider = NonRecursiveProvider([
            [.textDelta("compat result"), .done(finishReason: "stop")],
        ])
        let mainProvider = NonRecursiveProvider([
            [.textDelta("main idle"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == self.worker ? workerProvider : mainProvider
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let result = await orch.ask(from: main, to: worker.rawValue, question: "Use compatibility wrapper.")

        XCTAssertEqual(result, "compat result")
        XCTAssertEqual(workerProvider.requests.count, 1)
        let remainingTasks = await orch.queuedTasks()
        XCTAssertTrue(remainingTasks.isEmpty)
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .taskQueued = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .taskCompleted(let payload) = $0.event { return payload.result == "compat result" } else { return false } })
    }
}
