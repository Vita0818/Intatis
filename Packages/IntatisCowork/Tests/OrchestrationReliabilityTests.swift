import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private actor ReliabilityConcurrencyProbe {
    private var active = 0
    private var activeByAgent: [AgentID: Int] = [:]
    private var maximumActive = 0
    private var maximumByAgent: [AgentID: Int] = [:]

    func begin(_ agent: AgentID) {
        active += 1
        activeByAgent[agent, default: 0] += 1
        maximumActive = max(maximumActive, active)
        maximumByAgent[agent] = max(maximumByAgent[agent] ?? 0, activeByAgent[agent] ?? 0)
    }

    func end(_ agent: AgentID) {
        active = max(0, active - 1)
        activeByAgent[agent] = max(0, (activeByAgent[agent] ?? 0) - 1)
    }

    func snapshot() -> (maximumActive: Int, maximumByAgent: [AgentID: Int]) {
        (maximumActive, maximumByAgent)
    }
}

private actor ReliabilityTaskStartGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum ReliabilityForcedError: Error, LocalizedError {
    case providerFailure
    case terminalPersistenceFailure

    var errorDescription: String? {
        switch self {
        case .providerFailure: return "forced provider failure"
        case .terminalPersistenceFailure: return "forced terminal persistence failure"
        }
    }
}

private actor ReliabilityOneShotRevocationFailure {
    private var hasFailed = false

    func append(_ events: [Event], to log: EventLog) async throws {
        if !hasFailed, events.contains(where: { event in
            if case .capabilityLeaseRevoked = event { return true }
            if case .workspaceLeaseRevoked = event { return true }
            return false
        }) {
            hasFailed = true
            throw ReliabilityForcedError.terminalPersistenceFailure
        }
        try await log.append(events)
    }
}

private final class ReliabilityFailingProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ReliabilityForcedError.providerFailure)
        }
    }
}

private final class ReliabilityMailboxSideEffectThenFailProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        let requestNumber = capturedRequestCount
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(.toolCalls([ToolCall(
                    id: "mailbox-reply-side-effect",
                    name: "reply_message",
                    arguments: #"{"to":"missing-agent","content":"already attempted"}"#)]))
                continuation.yield(.done(finishReason: "tool_calls"))
                continuation.finish()
            } else {
                continuation.finish(throwing: ReliabilityForcedError.providerFailure)
            }
        }
    }
}

private actor ReliabilityDelayedStreamState {
    private var phase = 0
    private let agent: AgentID
    private let delayNanoseconds: UInt64
    private let response: String
    private let probe: ReliabilityConcurrencyProbe

    init(agent: AgentID,
         delayNanoseconds: UInt64,
         response: String,
         probe: ReliabilityConcurrencyProbe) {
        self.agent = agent
        self.delayNanoseconds = delayNanoseconds
        self.response = response
        self.probe = probe
    }

    func next() async throws -> AgentChunk? {
        switch phase {
        case 0:
            phase = 1
            await probe.begin(agent)
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                phase = 3
                await probe.end(agent)
                throw error
            }
            return .textDelta(response)
        case 1:
            phase = 2
            await probe.end(agent)
            return .done(finishReason: "stop")
        default:
            return nil
        }
    }
}

private final class ReliabilityDelayedProvider: ToolCallingProvider, @unchecked Sendable {
    private let agent: AgentID
    private let delayNanoseconds: UInt64
    private let response: String
    private let probe: ReliabilityConcurrencyProbe
    private let lock = NSLock()
    private var capturedRequestCount = 0

    init(agent: AgentID,
         delayNanoseconds: UInt64,
         response: String = "done",
         probe: ReliabilityConcurrencyProbe) {
        self.agent = agent
        self.delayNanoseconds = delayNanoseconds
        self.response = response
        self.probe = probe
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        lock.unlock()
        let state = ReliabilityDelayedStreamState(
            agent: agent,
            delayNanoseconds: delayNanoseconds,
            response: response,
            probe: probe)
        return AsyncThrowingStream(unfolding: { try await state.next() })
    }
}

private struct ReliabilityFinalProvider: ToolCallingProvider {
    var text: String = "done"

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private final class ReliabilityBlockingProvider: ToolCallingProvider, @unchecked Sendable {
    private let blockingSeconds: TimeInterval
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(blockingSeconds: TimeInterval) {
        self.blockingSeconds = blockingSeconds
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests.count
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
        // Deliberately blocks synchronously and ignores Swift task cancellation.
        Thread.sleep(forTimeInterval: blockingSeconds)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("late"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private final class ReliabilityCapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [AgentRequest] = []

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("mailbox handled"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private struct ReliabilityEndlessToolProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.toolCalls([
                ToolCall(id: IDGen.random(prefix: "call"), name: "missing_tool", arguments: "{}"),
            ]))
            continuation.yield(.done(finishReason: "tool_calls"))
            continuation.finish()
        }
    }
}

private func reliabilityLog(_ name: String = UUID().uuidString) throws -> EventLog {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-reliability-\(name)", isDirectory: true)
    return try EventLog(
        session: SessionID(rawValue: "reliability"),
        fileURL: directory.appendingPathComponent("events.jsonl"))
}

private func reliabilityWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-reliability-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func reliabilityEventIndex(_ events: [Envelope],
                                   type: Event.TypeTag,
                                   taskID: TaskID) -> Int? {
    events.firstIndex { envelope in
        switch envelope.event {
        case .taskCreated(let payload):
            return type == .taskCreated && payload.contract.id == taskID
        case .taskAssigned(let payload):
            return type == .taskAssigned && payload.contract.id == taskID
        case .taskQueued(let payload):
            return type == .taskQueued && payload.contract.id == taskID
        case .taskStarted(let payload):
            return type == .taskStarted && payload.taskID == taskID
        case .taskCompleted(let payload):
            return type == .taskCompleted && payload.taskID == taskID
        case .taskFailed(let payload):
            return type == .taskFailed && payload.taskID == taskID
        case .taskCancelled(let payload):
            return type == .taskCancelled && payload.taskID == taskID
        default:
            return false
        }
    }
}

@discardableResult
private func appendReliabilityTaskWithSettledSideEffect(
    to log: EventLog,
    workspace: URL,
    taskID: TaskID,
    agent: AgentID,
    terminalStatus: TaskStatus?
) async throws -> TaskContract {
    let workspaceLease = WorkspaceLease(
        taskID: taskID,
        rootPath: workspace.path,
        access: .readWrite)
    let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
    let contract = TaskContract(
        id: taskID,
        kind: .root,
        issuer: nil,
        assignee: agent,
        objective: "do not replay an already completed side effect",
        roleHint: "root coordinator",
        expectedDeliverable: "manual reconciliation",
        workspaceID: workspaceLease.workspaceID,
        workspaceLeaseID: workspaceLease.id,
        capabilityLeaseID: capabilityLease.id,
        replyMode: TaskReplyMode.none,
        maxAttempts: 3)
    let metadata = CoworkEventMetadata(
        taskID: taskID,
        rootTaskID: taskID,
        agentID: agent,
        assignee: agent,
        workspaceID: workspaceLease.workspaceID,
        workspaceLeaseID: workspaceLease.id,
        capabilityLeaseID: capabilityLease.id,
        scope: .task)
    let prepared = ToolExecutionPreparedPayload(
        executionID: "settled-write-\(taskID.rawValue)",
        taskID: taskID,
        attempt: 1,
        toolCallID: "settled-write-call",
        agent: agent,
        tool: "write_file",
        sideEffect: .write)
    var events: [Event] = [
        .agentAttached(AgentAttachedPayload(
            agent: agent,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)),
        .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: agent,
            lease: workspaceLease)),
        .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: agent,
            lease: capabilityLease)),
        .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
        .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
        .taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: agent,
            hopCount: 0,
            visitedAgents: [agent],
            attempt: 1,
            metadata: metadata)),
        .taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: agent,
            attempt: 1,
            metadata: metadata)),
        .toolExecutionPrepared(prepared),
        .toolExecutionSettled(ToolExecutionSettledPayload(
            prepared: prepared,
            outcome: .succeeded,
            reason: "the write completed before the task stopped")),
    ]
    switch terminalStatus {
    case .failed:
        events.append(.taskFailed(TaskFailedPayload(
            taskID: taskID,
            agent: agent,
            error: "failure after completed write",
            attempt: 1,
            metadata: metadata)))
    case .cancelled:
        events.append(.taskCancelled(TaskCancelledPayload(
            taskID: taskID,
            agent: agent,
            reason: "cancelled after completed write",
            attempt: 1,
            metadata: metadata)))
    case nil, .running:
        break
    default:
        preconditionFailure("test helper only supports running, failed, or cancelled tasks")
    }
    try await log.append(events)
    return contract
}

final class OrchestrationReliabilityTests: XCTestCase {
    private let main = AgentID(rawValue: "main")

    func testPublicRuntimeFactoryRetainsExclusiveSessionWriterLease() throws {
        let log = try reliabilityLog()
        let orchestrator = try Orchestrator.runtime(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }

        do {
            _ = try log.acquireWriterLease()
            XCTFail("a second runtime must not acquire the same session writer lease")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .writerAlreadyActive)
        }
        withExtendedLifetime(orchestrator) {}
    }

    func testAttachAdmissionPersistenceFailureDoesNotExposeAgentOrLeases() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }
        await orchestrator.setAdmissionEventAppender { event in
            if case .agentAttached = event {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        XCTAssertFalse(attached)
        let agentNames = await orchestrator.agentNames()
        let capabilityLeases = await orchestrator.capabilityLeaseList()
        let workspaceLeases = await orchestrator.workspaceLeaseList()
        let events = await log.replay()
        XCTAssertTrue(agentNames.isEmpty)
        XCTAssertTrue(capabilityLeases.isEmpty)
        XCTAssertTrue(workspaceLeases.isEmpty)
        XCTAssertFalse(events.contains { envelope in
            if case .agentAttached = envelope.event { return true }
            return false
        })
    }

    func testDetachPersistenceFailureKeepsAgentAndLeasesInRuntime() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let worker = AgentID(rawValue: "detach-worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }
        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(attached)
        let initialCapabilityLeases = await orchestrator.capabilityLeaseList()
        let initialWorkspaceLeases = await orchestrator.workspaceLeaseList()
        let baselineCapabilityIDs = Set(initialCapabilityLeases.map(\.id))
        let baselineWorkspaceIDs = Set(initialWorkspaceLeases.map(\.id))
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .capabilityLeaseRevoked = event { return true }
                return false
            }) {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            try await log.append(events)
        }

        let detached = await orchestrator.detach(worker, reason: "forced detach failure")
        let agentNames = await orchestrator.agentNames()
        let finalCapabilityLeases = await orchestrator.capabilityLeaseList()
        let finalWorkspaceLeases = await orchestrator.workspaceLeaseList()
        let events = await log.replay()
        XCTAssertFalse(detached)
        XCTAssertTrue(agentNames.contains(worker))
        XCTAssertEqual(Set(finalCapabilityLeases.map(\.id)), baselineCapabilityIDs)
        XCTAssertEqual(Set(finalWorkspaceLeases.map(\.id)), baselineWorkspaceIDs)
        let projection = CoworkProjection.build(from: events)
        XCTAssertNotNil(projection.agentRoster[worker])
        XCTAssertFalse(events.contains { envelope in
            if case .agentDetached(let payload) = envelope.event { return payload.agent == worker }
            return false
        })
    }

    func testRemoveToolReportsFailureWhenDetachAuditCannotBePersisted() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let worker = AgentID(rawValue: "remove-failure-worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let failure = ReliabilityOneShotRevocationFailure()
        await orchestrator.setAdmissionEventsAppender { events in
            try await failure.append(events, to: log)
        }

        let result = await orchestrator.removeFromTool(
            requestedBy: main,
            currentTaskID: nil,
            name: worker.rawValue)

        XCTAssertTrue(result.hasPrefix("error:"))
        let names = await orchestrator.agentNames()
        XCTAssertTrue(names.contains(worker))
    }

    func testDelegationQueuePersistenceFailureDoesNotCommitOrExecuteTask() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let rootIDValue = await orchestrator.createRootTask(
            assignee: main,
            objective: "delegation root")
        let rootID = try XCTUnwrap(rootIDValue)
        let baselineCapabilityLeases = await orchestrator.capabilityLeaseList().count
        let baselineWorkspaceLeases = await orchestrator.workspaceLeaseList().count
        await orchestrator.setAdmissionEventAppender { event in
            if case .taskQueued(let payload) = event,
               payload.contract.kind == .agentInvocation {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        let queued = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "must remain unexecutable",
            parentTaskID: rootID)
        await orchestrator.runSchedulerUntilIdle()

        let queuedTasks = await orchestrator.queuedTasks()
        let graph = await orchestrator.taskGraphSnapshot()
        let finalCapabilityLeaseCount = await orchestrator.capabilityLeaseList().count
        let finalWorkspaceLeaseCount = await orchestrator.workspaceLeaseList().count
        let projection = CoworkProjection.build(from: await log.replay())
        let partialTask = try XCTUnwrap(projection.tasks.values.first {
            $0.contract?.objective == "must remain unexecutable"
        })
        XCTAssertNil(queued.taskID)
        XCTAssertTrue(queued.message.contains("could not be persisted"))
        XCTAssertTrue(queuedTasks.isEmpty)
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(finalCapabilityLeaseCount, baselineCapabilityLeases)
        XCTAssertEqual(finalWorkspaceLeaseCount, baselineWorkspaceLeases)
        XCTAssertEqual(partialTask.status, .cancelled)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testRecoveryRequeuePersistenceFailureFailsClosedWithoutProviderExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "interrupted",
            roleHint: "root",
            expectedDeliverable: "result",
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            scope: .task)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 1,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 1,
            metadata: metadata)))
        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.setAdmissionEventAppender { event in
            if case .taskQueued(let payload) = event,
               payload.contract.id == taskID,
               payload.attempt == 2 {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        let remainingQueuedTasks = await restored.queuedTasks()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(remainingQueuedTasks.isEmpty)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 2)
    }

    func testMailboxFailureRetriesSameTaskOnlyToConfiguredAttemptLimit() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityFailingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let sendResult = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "retry mailbox")
        XCTAssertEqual(sendResult, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()

        XCTAssertEqual(provider.requestCount, 3)
        let mailboxQueues = await log.replay().compactMap { envelope -> (TaskID, Int)? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery,
                  let attempt = payload.attempt else { return nil }
            return (payload.contract.id, attempt)
        }
        let pendingMessageCount = await orchestrator.mailbox(for: worker).pendingMessages.count
        let remainingQueuedTasks = await orchestrator.queuedTasks()
        XCTAssertEqual(Set(mailboxQueues.map(\.0)).count, 1)
        XCTAssertEqual(mailboxQueues.map(\.1), [1, 2, 3])
        XCTAssertEqual(pendingMessageCount, 1)
        XCTAssertTrue(remainingQueuedTasks.isEmpty)
    }

    func testMailboxAutomaticRetryStopsAfterSettledNonReplayableExecution() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityMailboxSideEffectThenFailProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let sendResult = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "handle once")
        XCTAssertEqual(sendResult, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()

        let events = await log.replay()
        let mailboxQueues = events.compactMap { envelope -> (TaskID, Int)? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery,
                  let attempt = payload.attempt else { return nil }
            return (payload.contract.id, attempt)
        }
        let settledSideEffect = events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.toolCallID == "mailbox-reply-side-effect" else { return nil }
            return payload
        }

        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(mailboxQueues.map(\.1), [1])
        XCTAssertEqual(settledSideEffect.map(\.outcome), [.succeeded])
        let pendingMessageCount = await orchestrator.mailbox(for: worker).pendingMessages.count
        let remainingQueuedTasks = await orchestrator.queuedTasks()
        XCTAssertEqual(pendingMessageCount, 1)
        XCTAssertTrue(remainingQueuedTasks.isEmpty)
    }

    func testFailedTaskCannotRenewFromStillLiveLeaseWhenRevokeAuditFails() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityFailingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .capabilityLeaseRevoked = event { return true }
                if case .workspaceLeaseRevoked = event { return true }
                return false
            }) {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            try await log.append(events)
        }

        let sendResult = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "fail once")
        XCTAssertEqual(sendResult, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()

        let projection = CoworkProjection.build(from: await log.replay())
        let failedTask = try XCTUnwrap(projection.tasks.values.first {
            $0.contract?.kind == .mailboxDelivery
        })
        XCTAssertEqual(failedTask.status, .failed)
        let capabilityLeaseID = try XCTUnwrap(failedTask.contract?.capabilityLeaseID)
        let workspaceLeaseID = try XCTUnwrap(failedTask.contract?.workspaceLeaseID)
        let retainedCapabilityLease = await orchestrator.capabilityLease(id: capabilityLeaseID)
        let retainedWorkspaceLease = await orchestrator.workspaceLease(id: workspaceLeaseID)
        XCTAssertNotNil(retainedCapabilityLease)
        XCTAssertNotNil(retainedWorkspaceLease)

        let explicitRetry = await orchestrator.retry(failedTask)

        guard case .failed(let message) = explicitRetry else {
            return XCTFail("Retry must fail closed without committed renewal history.")
        }
        XCTAssertTrue(message.contains("missing without renewal history"))
        XCTAssertEqual(provider.requestCount, 1)
        let queueAttempts = await log.replay().compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == failedTask.id else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queueAttempts, [1])
    }

    func testProductionSendPersistsRealRootLifecycle() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider(text: "root result") }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendResult = await orchestrator.send("real root work", to: main)
        XCTAssertEqual(sendResult, .sent)

        let events = await log.replay()
        let root = try XCTUnwrap(events.compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .root else { return nil }
            return payload.contract
        }.first)
        XCTAssertNil(root.parentTaskID)
        XCTAssertNil(root.issuer)
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[root.id]?.status, .completed)
        XCTAssertEqual(projection.tasks[root.id]?.attempt, 1)
        let created = try XCTUnwrap(reliabilityEventIndex(events, type: .taskCreated, taskID: root.id))
        let assigned = try XCTUnwrap(reliabilityEventIndex(events, type: .taskAssigned, taskID: root.id))
        let queued = try XCTUnwrap(reliabilityEventIndex(events, type: .taskQueued, taskID: root.id))
        let started = try XCTUnwrap(reliabilityEventIndex(events, type: .taskStarted, taskID: root.id))
        let completed = try XCTUnwrap(reliabilityEventIndex(events, type: .taskCompleted, taskID: root.id))
        XCTAssertLessThan(created, assigned)
        XCTAssertLessThan(assigned, queued)
        XCTAssertLessThan(queued, started)
        XCTAssertLessThan(started, completed)
    }

    func testTaskStartPersistenceFailureDoesNotExecuteProvider() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskLifecycleEventAppender { event in
            if case .taskStarted = event {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        let result = await orchestrator.send("must not execute", to: main)

        guard case .failed(let message) = result else {
            return XCTFail("task-start persistence failure must fail the send")
        }
        XCTAssertTrue(message.contains("Task start could not be persisted"))
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let taskID = try XCTUnwrap(events.compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .root else { return nil }
            return payload.contract.id
        }.first)
        XCTAssertNil(reliabilityEventIndex(events, type: .taskStarted, taskID: taskID))
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskFailed, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .failed)
    }

    func testCompletionPersistenceFailureFallsBackToDurableFailureWithoutReplay() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskLifecycleEventAppender { event in
            if case .taskCompleted = event {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        let result = await orchestrator.send("persist completion", to: main)

        guard case .failed(let message) = result else {
            return XCTFail("completion persistence failure must fail the send")
        }
        XCTAssertTrue(message.contains("Task completion could not be persisted"))
        XCTAssertEqual(provider.requests.count, 1)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        let root = try XCTUnwrap(projection.tasks.values.first { $0.contract?.kind == .root })
        XCTAssertEqual(root.status, .failed)
        XCTAssertNil(reliabilityEventIndex(events, type: .taskCompleted, taskID: root.id))
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskFailed, taskID: root.id))

        let replayProvider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in replayProvider }
        await restored.restore(from: projection)
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()
        XCTAssertTrue(replayProvider.requests.isEmpty)
    }

    func testRuntimeConcurrencyIsBoundedAndPerAgentSingleFlight() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let firstWorkspace = try reliabilityWorkspace()
        let secondWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let first = AgentID(rawValue: "first")
        let second = AgentID(rawValue: "second")
        let probe = ReliabilityConcurrencyProbe()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxConcurrentTasks: 2)) { agent in
                ReliabilityDelayedProvider(
                    agent: agent.name,
                    delayNanoseconds: 150_000_000,
                    probe: probe)
            }
        let mainAttached = await orchestrator.attach(Agent(
            name: main, workspaceRoot: mainWorkspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        let firstAttached = await orchestrator.attach(Agent(
            name: first, workspaceRoot: firstWorkspace, model: ModelID(rawValue: "m"), profile: .reviewed))
        let secondAttached = await orchestrator.attach(Agent(
            name: second, workspaceRoot: secondWorkspace, model: ModelID(rawValue: "m"), profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(firstAttached)
        XCTAssertTrue(secondAttached)
        let rootIDValue = await orchestrator.createRootTask(assignee: main, objective: "parallel root")
        let rootID = try XCTUnwrap(rootIDValue)
        let firstA = await orchestrator.enqueueDelegatedTask(
            from: main, to: first.rawValue, objective: "first A", parentTaskID: rootID)
        let firstB = await orchestrator.enqueueDelegatedTask(
            from: main, to: first.rawValue, objective: "first B", parentTaskID: rootID)
        let secondA = await orchestrator.enqueueDelegatedTask(
            from: main, to: second.rawValue, objective: "second A", parentTaskID: rootID)
        XCTAssertNotNil(firstA.taskID)
        XCTAssertNotNil(firstB.taskID)
        XCTAssertNotNil(secondA.taskID)

        await orchestrator.runSchedulerUntilIdle()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 2)
        XCTAssertEqual(snapshot.maximumByAgent[first], 1)
        XCTAssertEqual(snapshot.maximumByAgent[second], 1)
        let completed = CoworkProjection.build(from: await log.replay()).completedTasks
        XCTAssertEqual(Set(completed.map(\.id)), Set([firstA.taskID, firstB.taskID, secondA.taskID].compactMap { $0 }))
    }

    func testRetryUsesCurrentSchedulerAttemptInsteadOfStaleView() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityFailingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        guard case .failed = await orchestrator.send("always fail", to: main) else {
            return XCTFail("first attempt must fail")
        }
        let failedReplay = await log.replay()
        let staleView = try XCTUnwrap(
            CoworkProjection.build(from: failedReplay).failedTasks.first)

        guard case .failed = await orchestrator.retry(staleView) else {
            return XCTFail("second attempt must fail")
        }
        guard case .failed = await orchestrator.retry(staleView) else {
            return XCTFail("stale view must still advance to the current third attempt")
        }
        let exhausted = await orchestrator.retry(staleView)

        XCTAssertEqual(exhausted, .failed("Task reached its maximum of 3 attempts."))
        XCTAssertEqual(provider.requestCount, 3)
        let attempts = await log.replay().compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == staleView.id else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(attempts, [1, 2, 3])
    }

    func testClaimedTaskCanBeCancelledBeforeTaskStartedCommit() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let gate = ReliabilityTaskStartGate()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskStartGate { _ in await gate.pause() }

        let sendTask = Task { await orchestrator.send("cancel before start", to: main) }
        await gate.waitUntilEntered()
        let queuedProjection = CoworkProjection.build(from: await log.replay())
        let taskID = try XCTUnwrap(queuedProjection.queuedTasks.first?.id)
        let cancelled = await orchestrator.cancel(taskID: taskID, reason: "cancel claimed task")
        await gate.release()
        let result = await sendTask.value
        await orchestrator.runSchedulerUntilIdle()

        XCTAssertTrue(cancelled)
        guard case .failed(let message) = result else {
            return XCTFail("cancelled claimed task must fail the send")
        }
        XCTAssertTrue(message.contains("cancel claimed task"))
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        XCTAssertNil(reliabilityEventIndex(events, type: .taskStarted, taskID: taskID))
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskCancelled, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .cancelled)
    }

    func testRunningTaskCancellationHasOneCancelledTerminalState() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ReliabilityConcurrencyProbe()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { agent in
                ReliabilityDelayedProvider(
                    agent: agent.name,
                    delayNanoseconds: 5_000_000_000,
                    probe: probe)
            }
        let attached = await orchestrator.attach(Agent(
            name: main, workspaceRoot: workspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendTask = Task { await orchestrator.send("cancel me", to: main) }
        var runningID: TaskID?
        for _ in 0..<200 {
            runningID = CoworkProjection.build(from: await log.replay()).runningTasks.first?.id
            if runningID != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(runningID)
        let cancelled = await orchestrator.cancel(taskID: taskID, reason: "test cancellation")
        XCTAssertTrue(cancelled)
        guard case .failed(let message) = await sendTask.value else {
            return XCTFail("cancelled send must report failure")
        }
        XCTAssertTrue(message.contains("test cancellation"))

        let events = await log.replay()
        let terminalEvents = events.filter { envelope in
            switch envelope.event {
            case .taskCompleted(let payload): return payload.taskID == taskID
            case .taskFailed(let payload): return payload.taskID == taskID
            case .taskCancelled(let payload): return payload.taskID == taskID
            default: return false
            }
        }
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskCancelled, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .cancelled)
    }

    func testRunningCancellationRefreshesConsumedTokenCount() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ReliabilityConcurrencyProbe()
        let provider = ReliabilityDelayedProvider(
            agent: main,
            delayNanoseconds: 5_000_000_000,
            probe: probe)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(tokenBudget: 100_000)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        try await log.append(.turnStats(TurnStatsPayload(totalTokens: 100_000)))

        let firstSend = Task { await orchestrator.send("cancel and refresh", to: main) }
        var runningID: TaskID?
        for _ in 0..<200 {
            runningID = CoworkProjection.build(from: await log.replay()).runningTasks.first?.id
            if runningID != nil, provider.requestCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(runningID)
        let cancelled = await orchestrator.cancel(taskID: taskID, reason: "refresh budget")
        XCTAssertTrue(cancelled)
        _ = await firstSend.value

        let secondResult = await orchestrator.send("must be budget blocked", to: main)

        guard case .failed(let message) = secondResult else {
            return XCTFail("refreshed token budget must block the next task")
        }
        XCTAssertTrue(message.contains("token budget"))
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testEnablingBudgetKeepsTimedOutNonCooperativeRequestOnTheSessionMeter() async throws {
        let log = try reliabilityLog("budget-in-place-reconfigure-\(UUID().uuidString)")
        let firstWorkspace = try reliabilityWorkspace()
        let secondWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let mainAgent = main
        let secondAgent = AgentID(rawValue: "budget-second")
        let firstProvider = ReliabilityBlockingProvider(blockingSeconds: 0.75)
        let secondProvider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(
                maxConcurrentTasks: 2,
                taskTimeoutSeconds: 0.05,
                tokenBudget: nil)) { agent in
                    if agent.name == mainAgent { return firstProvider }
                    return secondProvider
                }
        let firstAttached = await orchestrator.attach(Agent(
            name: mainAgent,
            workspaceRoot: firstWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let secondAttached = await orchestrator.attach(Agent(
            name: secondAgent,
            workspaceRoot: secondWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(firstAttached)
        XCTAssertTrue(secondAttached)

        let started = Date()
        guard case .failed(let firstMessage) = await orchestrator.send(
            "start while disabled and ignore timeout cancellation",
            to: mainAgent) else {
            return XCTFail("the watchdog must finish before the blocking provider")
        }
        XCTAssertTrue(firstMessage.lowercased().contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
        XCTAssertEqual(firstProvider.requestCount, 1)
        XCTAssertNil(firstProvider.requests.first?.maxOutputTokens)

        let outstanding = await orchestrator.tokenBudgetSnapshotForTesting()
        XCTAssertNil(outstanding.limit)
        XCTAssertEqual(outstanding.consumed, 0)
        XCTAssertGreaterThan(outstanding.reserved, 0)
        XCTAssertNil(outstanding.remaining)

        // Enabling must mutate the same actor. The request whose outer timeout
        // already fired still owns its tracking reservation, so the new limit is
        // unavailable rather than becoming a fresh second pool.
        await orchestrator.updateExecutionPolicy(CoworkExecutionPolicy(
            maxConcurrentTasks: 2,
            taskTimeoutSeconds: 0.05,
            tokenBudget: outstanding.reserved))
        let enabled = await orchestrator.tokenBudgetSnapshotForTesting()
        XCTAssertEqual(enabled.limit, outstanding.reserved)
        XCTAssertEqual(enabled.reserved, outstanding.reserved)
        XCTAssertEqual(enabled.remaining, 0)

        guard case .failed(let blockedMessage) = await orchestrator.send(
            "must not double-spend the in-flight reservation",
            to: secondAgent) else {
            return XCTFail("the in-flight disabled-era request must block a new dispatch")
        }
        XCTAssertTrue(blockedMessage.lowercased().contains("budget"))
        XCTAssertTrue(secondProvider.requests.isEmpty)

        var settled = await orchestrator.tokenBudgetSnapshotForTesting()
        for _ in 0..<300 where settled.reserved != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
            settled = await orchestrator.tokenBudgetSnapshotForTesting()
        }
        XCTAssertEqual(settled.reserved, 0, "the late cancelled request must settle exactly once")
        XCTAssertGreaterThan(settled.consumed, 0)
        XCTAssertEqual(firstProvider.requestCount, 1)

        // Raising the same actor's limit after settlement must admit work again,
        // proving the old reservation was neither leaked nor forgotten.
        await orchestrator.updateExecutionPolicy(CoworkExecutionPolicy(
            maxConcurrentTasks: 2,
            taskTimeoutSeconds: 0.05,
            tokenBudget: settled.consumed + 10_000))
        let finalSend = await orchestrator.send(
            "run after the old reservation settles",
            to: secondAgent)
        XCTAssertEqual(finalSend, .sent)
        XCTAssertEqual(secondProvider.requests.count, 1)
        XCTAssertNotNil(secondProvider.requests.first?.maxOutputTokens)
        let final = await orchestrator.tokenBudgetSnapshotForTesting()
        XCTAssertEqual(final.reserved, 0)
        XCTAssertGreaterThan(final.consumed, settled.consumed)
    }

    func testPolicyUpdateAndCancelAllKeepSchedulerSuspendedUntilBothOwnersRelease() async throws {
        let log = try reliabilityLog("budget-update-cancel-all-\(UUID().uuidString)")
        let firstWorkspace = try reliabilityWorkspace()
        let secondWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let mainAgent = main
        let secondAgent = AgentID(rawValue: "budget-after-cancel")
        let concurrencyProbe = ReliabilityConcurrencyProbe()
        let firstProvider = ReliabilityDelayedProvider(
            agent: mainAgent,
            delayNanoseconds: 5_000_000_000,
            probe: concurrencyProbe)
        let secondProvider = ReliabilityCapturingProvider()
        let cancelResumeGate = ReliabilityTaskStartGate()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(
                maxConcurrentTasks: 2,
                taskTimeoutSeconds: 10,
                tokenBudget: 100_000)) { agent in
                    if agent.name == mainAgent { return firstProvider }
                    return secondProvider
                }
        await orchestrator.setCancelAllBeforeResumeHook {
            await cancelResumeGate.pause()
        }
        let firstAttached = await orchestrator.attach(Agent(
            name: mainAgent,
            workspaceRoot: firstWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let secondAttached = await orchestrator.attach(Agent(
            name: secondAgent,
            workspaceRoot: secondWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(firstAttached)
        XCTAssertTrue(secondAttached)

        let firstSend = Task { await orchestrator.send("cancel during policy drain", to: mainAgent) }
        for _ in 0..<200 where firstProvider.requestCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(firstProvider.requestCount, 1)

        let policyUpdate = Task {
            await orchestrator.updateExecutionPolicy(CoworkExecutionPolicy(
                maxConcurrentTasks: 2,
                taskTimeoutSeconds: 10,
                tokenBudget: 200_000))
        }
        for _ in 0..<200 {
            if await orchestrator.isExecutionPolicyUpdateInProgress() { break }
            await Task.yield()
        }
        let cancelAll = Task {
            await orchestrator.cancelAll(reason: "overlapping policy update")
        }
        await cancelResumeGate.waitUntilEntered()

        // The policy owner can finish first, but its resume request must remain
        // pending while cancelAll still owns a separate suspension token.
        await policyUpdate.value
        let secondSend = Task {
            await orchestrator.send("run only after cancelAll releases", to: secondAgent)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(secondProvider.requests.isEmpty)

        await cancelResumeGate.release()
        await cancelAll.value
        let secondResult = await secondSend.value
        XCTAssertEqual(secondResult, .sent)
        XCTAssertEqual(secondProvider.requests.count, 1)
        guard case .failed = await firstSend.value else {
            return XCTFail("cancelAll must cancel the old-meter task")
        }
    }

    func testTimeoutAndIterationExhaustionAreFailedNeverCompleted() async throws {
        let timeoutLog = try reliabilityLog("timeout-\(UUID().uuidString)")
        let timeoutWorkspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: timeoutWorkspace) }
        let probe = ReliabilityConcurrencyProbe()
        let timeoutOrchestrator = Orchestrator(
            log: timeoutLog,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(taskTimeoutSeconds: 1)) { agent in
                ReliabilityDelayedProvider(
                    agent: agent.name,
                    delayNanoseconds: 5_000_000_000,
                    probe: probe)
            }
        let timeoutAttached = await timeoutOrchestrator.attach(Agent(
            name: main, workspaceRoot: timeoutWorkspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(timeoutAttached)
        guard case .failed(let timeoutMessage) = await timeoutOrchestrator.send("time out", to: main) else {
            return XCTFail("timeout must fail")
        }
        XCTAssertTrue(timeoutMessage.lowercased().contains("timed out"))
        let timeoutProjection = CoworkProjection.build(from: await timeoutLog.replay())
        XCTAssertEqual(timeoutProjection.failedTasks.count, 1)
        XCTAssertTrue(timeoutProjection.completedTasks.isEmpty)

        let iterationLog = try reliabilityLog("iteration-\(UUID().uuidString)")
        let iterationWorkspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: iterationWorkspace) }
        let iterationOrchestrator = Orchestrator(
            log: iterationLog,
            allowsShell: true,
            responder: FixedResponder(.allow),
            maxSteps: 1) { _ in ReliabilityEndlessToolProvider() }
        let iterationAttached = await iterationOrchestrator.attach(Agent(
            name: main, workspaceRoot: iterationWorkspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(iterationAttached)
        guard case .failed(let iterationMessage) = await iterationOrchestrator.send("never complete", to: main) else {
            return XCTFail("iteration exhaustion must fail")
        }
        XCTAssertTrue(iterationMessage.contains("maximum of 1"))
        let iterationProjection = CoworkProjection.build(from: await iterationLog.replay())
        XCTAssertEqual(iterationProjection.failedTasks.count, 1)
        XCTAssertTrue(iterationProjection.completedTasks.isEmpty)
    }

    func testTimeoutDoesNotWaitForProviderThatIgnoresCancellation() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityBlockingProvider(blockingSeconds: 0.5)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(taskTimeoutSeconds: 0.05)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let started = Date()
        let result = await orchestrator.send("timeout a non-cooperative provider", to: main)
        let elapsed = Date().timeIntervalSince(started)

        guard case .failed(let message) = result else {
            return XCTFail("the bounded watchdog must fail the task")
        }
        XCTAssertTrue(message.lowercased().contains("timed out"))
        XCTAssertLessThan(elapsed, 0.3)
        XCTAssertEqual(provider.requestCount, 1)
        // Let the deliberately blocked test provider unwind before deleting its
        // temporary log; its late result must not change the terminal task state.
        try await Task.sleep(nanoseconds: 550_000_000)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.failedTasks.count, 1)
        XCTAssertTrue(projection.completedTasks.isEmpty)
    }

    func testRestoreRequeuesInterruptedAttemptAndCompletesNextAttempt() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let workspaceLease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator()
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "resume after crash",
            roleHint: "root coordinator",
            expectedDeliverable: "recovered result",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: main,
            lease: workspaceLease)))
        try await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: main,
            lease: capabilityLease)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 1,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 1,
            metadata: metadata)))

        let restoredProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(restoredProjection.tasks[taskID]?.status, .running)
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider(text: "recovered") }
        await restored.restore(from: restoredProjection)
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .completed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 2)
        XCTAssertEqual(projection.tasks[taskID]?.result, "recovered")
        let attempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(attempts, [1, 2])
    }

    func testRestoreDoesNotReplayUnsettledNonReplayableToolExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "do not duplicate the interrupted write",
            roleHint: "root coordinator",
            expectedDeliverable: "manual reconciliation",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append([
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: main,
                lease: workspaceLease)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: main,
                lease: capabilityLease)),
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: main,
                attempt: 1,
                metadata: metadata)),
            .toolExecutionPrepared(ToolExecutionPreparedPayload(
                executionID: "interrupted-write",
                taskID: taskID,
                attempt: 1,
                toolCallID: "write-call",
                agent: main,
                tool: "write_file",
                sideEffect: .write)),
        ])

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 1)
        XCTAssertTrue(projection.tasks[taskID]?.error?.contains("manual reconciliation required") == true)
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [1])
    }

    func testRestoreDoesNotReplayTaskAfterSettledSuccessfulNonReplayableExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "running-after-settled-write")
        try await appendReliabilityTaskWithSettledSideEffect(
            to: log,
            workspace: workspace,
            taskID: taskID,
            agent: main,
            terminalStatus: nil)

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 1)
        XCTAssertTrue(projection.tasks[taskID]?.error?.contains("side effect already succeeded") == true)
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [1])
    }

    func testRetryRejectsFailedTaskWithUnsettledNonReplayableExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "do not retry an uncertain write",
            roleHint: "root coordinator",
            expectedDeliverable: "manual reconciliation",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append([
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: main,
                lease: workspaceLease)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: main,
                lease: capabilityLease)),
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: main,
                attempt: 1,
                metadata: metadata)),
            .toolExecutionPrepared(ToolExecutionPreparedPayload(
                executionID: "failed-uncertain-write",
                taskID: taskID,
                attempt: 1,
                toolCallID: "write-call",
                agent: main,
                tool: "write_file",
                sideEffect: .write)),
            .taskFailed(TaskFailedPayload(
                taskID: taskID,
                agent: main,
                error: "tool completion audit failed",
                attempt: 1,
                metadata: metadata)),
        ])

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let initialProjection = CoworkProjection.build(from: await log.replay())
        await restored.restore(from: initialProjection)
        let failedView = try XCTUnwrap(initialProjection.tasks[taskID])

        let result = await restored.retry(failedView)

        guard case .failed(let message) = result else {
            return XCTFail("Retry must be blocked pending reconciliation.")
        }
        XCTAssertTrue(message.contains("manual reconciliation required"))
        XCTAssertTrue(provider.requests.isEmpty)
        let queuedAttempts = await log.replay().compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [1])
    }

    func testRetryRejectsFailedOrCancelledTaskAfterSettledSuccessfulNonReplayableExecution() async throws {
        for terminalStatus in [TaskStatus.failed, .cancelled] {
            let log = try reliabilityLog()
            let workspace = try reliabilityWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let taskID = TaskID(rawValue: "\(terminalStatus.rawValue)-after-settled-write")
            try await appendReliabilityTaskWithSettledSideEffect(
                to: log,
                workspace: workspace,
                taskID: taskID,
                agent: main,
                terminalStatus: terminalStatus)

            let provider = ReliabilityCapturingProvider()
            let restored = Orchestrator(
                log: log,
                allowsShell: true,
                responder: FixedResponder(.allow)) { _ in provider }
            let initialProjection = CoworkProjection.build(from: await log.replay())
            await restored.restore(from: initialProjection)
            let terminalView = try XCTUnwrap(initialProjection.tasks[taskID])

            let result = await restored.retry(terminalView)

            guard case .failed(let message) = result else {
                return XCTFail("Retry must be blocked after a settled non-replayable execution.")
            }
            XCTAssertTrue(message.contains("side effect already succeeded"))
            XCTAssertTrue(provider.requests.isEmpty)
            let queuedAttempts = await log.replay().compactMap { envelope -> Int? in
                guard case .taskQueued(let payload) = envelope.event,
                      payload.contract.id == taskID else { return nil }
                return payload.attempt
            }
            XCTAssertEqual(queuedAttempts, [1])
        }
    }

    func testRestoreAtMaxAttemptFailsAtLastActualAttemptWithoutPhantomRetry() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "do not replay",
            roleHint: "root",
            expectedDeliverable: "result",
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 2)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            scope: .task)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 2,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 2,
            metadata: metadata)))

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        let startedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskStarted(let payload) = envelope.event,
                  payload.taskID == taskID else { return nil }
            return payload.attempt
        }
        let failedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskFailed(let payload) = envelope.event,
                  payload.taskID == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [2])
        XCTAssertEqual(startedAttempts, [2])
        XCTAssertEqual(failedAttempts, [2])
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 2)
    }

    func testRestoreSynthesizesMailboxWakeAndConsumesOnlyProjectedBatches() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sender = AgentID(rawValue: "sender")
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: sender,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        let messageIDs = (0..<10).map { MessageID(rawValue: "mail_\($0)") }
        for (index, messageID) in messageIDs.enumerated() {
            try await log.append(.agentMessage(AgentMessagePayload(
                from: sender,
                to: main,
                content: "pending message \(index)",
                kind: .sendMessage,
                messageId: messageID)))
        }

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        let queuedBeforeResume = await restored.queuedTasks()
        XCTAssertEqual(queuedBeforeResume.filter { $0.contract.kind == .mailboxDelivery }.count, 1)
        XCTAssertTrue(provider.requests.isEmpty)

        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertEqual(provider.requests.count, 2, "ten messages should be delivered in the configured 8+2 context batches")
        let finalEvents = await log.replay()
        let consumed = finalEvents.compactMap { envelope -> MessageID? in
            guard case .agentMessageConsumed(let payload) = envelope.event else { return nil }
            return payload.messageID
        }
        XCTAssertEqual(Set(consumed), Set(messageIDs))
        XCTAssertEqual(consumed.count, messageIDs.count)
        XCTAssertTrue(CoworkProjection.build(from: finalEvents).mailboxes[main]?.pendingMessages.isEmpty == true)
    }
}
