import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class SchedulerProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(_ chunks: [AgentChunk] = [.textDelta("scheduled result"), .done(finishReason: "stop")]) {
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
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private func schedulerLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-scheduler-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "scheduler"), fileURL: url)
}

private func schedulerWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func schedulerTaskCompleted(_ events: [Envelope]) -> [TaskCompletedPayload] {
    events.compactMap {
        if case .taskCompleted(let payload) = $0.event { return payload }
        return nil
    }
}

final class SchedulerMailboxTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func makeOrchestrator(log: EventLog,
                                  workerProvider: SchedulerProvider = SchedulerProvider()) async throws -> (Orchestrator, URL, URL) {
        let wsMain = try schedulerWorkspace()
        let wsWorker = try schedulerWorkspace()
        let worker = self.worker
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == worker ? workerProvider : SchedulerProvider([.textDelta("main"), .done(finishReason: "stop")])
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        return (orch, wsMain, wsWorker)
    }

    func testDelegateTaskEnqueuesScheduledTaskAndMailboxReceivesIt() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Inspect worker workspace.")

        let taskID = try XCTUnwrap(queued.taskID)
        let queuedIDs = await orch.queuedTasks().map(\.contract.id)
        let pendingTasks = await orch.mailbox(for: worker).pendingTasks
        let events = await log.replay()
        XCTAssertEqual(queuedIDs, [taskID])
        XCTAssertEqual(pendingTasks, [taskID])
        XCTAssertTrue(events.contains { if case .taskQueued = $0.event { return true } else { return false } })
    }

    func testSchedulerRunsTargetAgentIndependentlyAndRecordsResult() async throws {
        let log = try schedulerLog()
        let workerProvider = SchedulerProvider([.textDelta("worker done"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Run worker task.")
        let taskID = try XCTUnwrap(queued.taskID)

        let ran = await orch.runNextScheduledTask()
        XCTAssertTrue(ran)

        XCTAssertEqual(workerProvider.requests.count, 1)
        let recordOptional = await orch.executionRecord(taskID: taskID)
        let record = try XCTUnwrap(recordOptional)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.result, "worker done")
        let completedMailboxTaskID = await orch.mailbox(for: worker).completedResults.first?.taskID
        XCTAssertEqual(completedMailboxTaskID, taskID)
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .taskStarted(let payload) = $0.event { return payload.taskID == taskID } else { return false } })
        XCTAssertTrue(events.contains { if case .taskCompleted(let payload) = $0.event { return payload.result == "worker done" } else { return false } })
    }

    func testCallerEqualsTargetIsRejectedBeforeScheduling() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let queued = await orch.enqueueDelegatedTask(from: worker, to: worker.rawValue, objective: "self task")

        XCTAssertNil(queued.taskID)
        XCTAssertEqual(queued.message, "error: agent cannot delegate to itself")
        let queuedTasks = await orch.queuedTasks()
        XCTAssertTrue(queuedTasks.isEmpty)
    }

    func testImmediateABACycleIsRejected() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let first = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "A to B")
        let parentTaskID = try XCTUnwrap(first.taskID)

        let cycle = await orch.enqueueDelegatedTask(from: worker, to: main.rawValue, objective: "B back to A", parentTaskID: parentTaskID)

        XCTAssertNil(cycle.taskID)
        XCTAssertEqual(cycle.message, "error: delegation cycle rejected")
        let queued = await orch.queuedTasks()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.contract.id, parentTaskID)
    }

    func testCompatibilityDelegateTaskCanAwaitSchedulerResult() async throws {
        let log = try schedulerLog()
        let workerProvider = SchedulerProvider([.textDelta("awaited result"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.delegateTask(from: main, to: worker.rawValue, objective: "Await this worker task.")

        XCTAssertEqual(result, "awaited result")
        XCTAssertEqual(workerProvider.requests.count, 1)
        let remainingTasks = await orch.queuedTasks()
        let events = await log.replay()
        XCTAssertTrue(remainingTasks.isEmpty)
        XCTAssertEqual(schedulerTaskCompleted(events).first?.result, "awaited result")
    }

    func testMacOSIOSCounterScenarioRunsTwoWorkersThroughSchedulerEvents() async throws {
        let log = try schedulerLog()
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try schedulerWorkspace()
        let wsMacos = try schedulerWorkspace()
        let wsIOS = try schedulerWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let macosProvider = SchedulerProvider([.textDelta("macOS count: 4"), .done(finishReason: "stop")])
        let iosProvider = SchedulerProvider([.textDelta("iOS count: 7"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == macos { return macosProvider }
            if agent.name == ios { return iosProvider }
            return SchedulerProvider([.textDelta("main"), .done(finishReason: "stop")])
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let macosAttached = await orch.attach(Agent(name: macos, workspaceRoot: wsMacos, model: ModelID(rawValue: "m"),
                                                    profile: .reviewed))
        let iosAttached = await orch.attach(Agent(name: ios, workspaceRoot: wsIOS, model: ModelID(rawValue: "m"),
                                                  profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(macosAttached)
        XCTAssertTrue(iosAttached)

        let macosQueued = await orch.enqueueDelegatedTask(from: main, to: macos.rawValue,
                                                          objective: "Recursively count macOS Swift files only.")
        let iosQueued = await orch.enqueueDelegatedTask(from: main, to: ios.rawValue,
                                                        objective: "Recursively count iOS Swift files only.")
        XCTAssertNotNil(macosQueued.taskID)
        XCTAssertNotNil(iosQueued.taskID)

        await orch.runSchedulerUntilIdle()

        let completions = schedulerTaskCompleted(await log.replay())
        XCTAssertTrue(completions.contains { $0.agent == macos && $0.result == "macOS count: 4" })
        XCTAssertTrue(completions.contains { $0.agent == ios && $0.result == "iOS count: 7" })
        XCTAssertEqual(macosProvider.requests.count, 1)
        XCTAssertEqual(iosProvider.requests.count, 1)
    }
}
