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

final class AgentInvocationNonRecursiveTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    func testDelegateTaskToolQueuesWithoutRunningTargetBeforeCallerLoopContinues() async throws {
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
        let workerNotRunWhenCallerContinued = NonRecursiveFlag()
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
            [.textDelta("main observed queue"), .done(finishReason: "stop")],
        ], onStream: { index, _ in
            if index == 1 {
                workerNotRunWhenCallerContinued.set(workerProvider.requests.isEmpty)
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

        XCTAssertTrue(workerNotRunWhenCallerContinued.value)
        XCTAssertEqual(workerProvider.requests.count, 1)
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .taskQueued = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .taskStarted = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .taskCompleted(let payload) = $0.event { return payload.result == "worker result" } else { return false } })
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
