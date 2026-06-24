import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class SplitProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(_ chunks: [AgentChunk] = [.textDelta("done"), .done(finishReason: "stop")]) {
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

private func splitLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-split-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "split"), fileURL: url)
}

private func splitWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("split-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func splitTaskContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskCreated(let payload) = $0.event { return payload.contract }
        return nil
    }
}

final class MessageDelegationSplitTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func makeOrchestrator(log: EventLog,
                                  mainProvider: SplitProvider = SplitProvider(),
                                  workerProvider: SplitProvider = SplitProvider()) async throws -> (Orchestrator, URL, URL) {
        let wsMain = try splitWorkspace()
        let wsWorker = try splitWorkspace()
        let worker = self.worker
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == worker ? workerProvider : mainProvider
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

    func testSendMessageRecordsCommunicationEventWithoutTaskContract() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.sendMessage(from: main, to: worker.rawValue, content: "status ping")

        XCTAssertEqual(result, "sent message to @worker")
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .agentMessage(let payload) = $0.event {
                return payload.from == main && payload.to == worker && payload.kind == .sendMessage
            }
            return false
        })
        XCTAssertTrue(splitTaskContracts(events).isEmpty)
    }

    func testRequestInformationRecordsInformationEventWithoutDelegationTask() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.requestInformation(from: main, to: worker.rawValue, question: "Which folder is active?")

        XCTAssertEqual(result, "requested information from @worker")
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .informationRequested(let payload) = $0.event {
                return payload.from == main && payload.to == worker && payload.question.contains("folder")
            }
            return false
        })
        XCTAssertTrue(splitTaskContracts(events).isEmpty)
        XCTAssertFalse(events.contains { if case .taskDelegated = $0.event { return true } else { return false } })
    }

    func testReplyMessageRecordsReplyEventWithoutTaskContract() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.replyMessage(from: worker, to: main.rawValue, content: "macOS count is ready", inReplyTo: "msg_info")

        XCTAssertEqual(result, "replied to @main")
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .informationReplied(let payload) = $0.event {
                return payload.from == worker
                    && payload.to == main
                    && payload.inReplyTo == MessageID(rawValue: "msg_info")
                    && payload.content.contains("ready")
            }
            return false
        })
        XCTAssertTrue(splitTaskContracts(events).isEmpty)
    }

    func testDelegateTaskCreatesTaskContractAndTaskDelegatedEvent() async throws {
        let log = try splitLog()
        let workerProvider = SplitProvider([.textDelta("worker result"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.delegateTask(from: main,
                                             to: worker.rawValue,
                                             objective: "Count macOS Swift files only.",
                                             roleHint: "macOS Swift counter",
                                             expectedDeliverable: "count and path list")

        XCTAssertEqual(result, "worker result")
        let events = await log.replay()
        let contract = try XCTUnwrap(splitTaskContracts(events).first)
        XCTAssertEqual(contract.issuer, main)
        XCTAssertEqual(contract.assignee, worker)
        XCTAssertEqual(contract.roleHint, "macOS Swift counter")
        XCTAssertEqual(contract.expectedDeliverable, "count and path list")
        XCTAssertTrue(events.contains {
            if case .taskDelegated(let payload) = $0.event {
                return payload.contract == contract
            }
            return false
        })
    }

    func testRequestDelegationRecordsRequestWithoutSpawnOrAttach() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let before = await log.replay().filter { if case .agentAttached = $0.event { return true } else { return false } }.count

        let result = await orch.requestDelegation(from: worker,
                                                  objective: "Need docs counter",
                                                  reason: "Assigned workspace excludes docs")

        XCTAssertEqual(result, "delegation request recorded")
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .delegationRequested(let payload) = $0.event {
                return payload.requester == worker && payload.objective == "Need docs counter"
            }
            return false
        })
        let after = events.filter { if case .agentAttached = $0.event { return true } else { return false } }.count
        XCTAssertEqual(after, before)
        XCTAssertTrue(splitTaskContracts(events).isEmpty)
    }

    func testCapabilityLeaseControlsMessageAndDelegationTools() {
        let workerTools = Set(Orchestrator.toolRegistry(for: .worker()).descriptors().map(\.name))
        XCTAssertTrue(workerTools.contains("reply_message"))
        XCTAssertTrue(workerTools.contains("request_delegation"))
        XCTAssertFalse(workerTools.contains("delegate_task"))
        XCTAssertFalse(workerTools.contains("ask_agent"))

        let coordinatorTools = Set(Orchestrator.toolRegistry(for: .coordinator()).descriptors().map(\.name))
        XCTAssertTrue(coordinatorTools.contains("send_message"))
        XCTAssertTrue(coordinatorTools.contains("request_information"))
        XCTAssertTrue(coordinatorTools.contains("reply_message"))
        XCTAssertTrue(coordinatorTools.contains("delegate_task"))
        XCTAssertTrue(coordinatorTools.contains("ask_agent"))
    }

    func testAskAgentCompatibilityWrapperRejectsSelfCallAndWorkerDoesNotSeeAskAgent() async throws {
        let log = try splitLog()
        let workerProvider = SplitProvider()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let selfCall = await orch.ask(from: worker, to: "@worker", question: "call yourself")
        XCTAssertEqual(selfCall, "error: agent cannot ask itself")

        await orch.send("capture worker request", to: worker)
        let request = try XCTUnwrap(workerProvider.requests.first)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertFalse(toolNames.contains("ask_agent"))
        XCTAssertFalse(toolNames.contains("delegate_task"))
    }

    func testMessageBusEventsDistinguishCommunicationFromDelegation() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        _ = await orch.sendMessage(from: main, to: worker.rawValue, content: "hello")
        _ = await orch.requestInformation(from: main, to: worker.rawValue, question: "question")
        _ = await orch.replyMessage(from: worker, to: main.rawValue, content: "answer", inReplyTo: nil)
        _ = await orch.delegateTask(from: main, to: worker.rawValue, objective: "Do one task.")

        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.agentMessage))
        XCTAssertTrue(types.contains(.informationRequested))
        XCTAssertTrue(types.contains(.informationReplied))
        XCTAssertTrue(types.contains(.taskDelegated))
        XCTAssertTrue(types.contains(.taskCreated))
    }
}
