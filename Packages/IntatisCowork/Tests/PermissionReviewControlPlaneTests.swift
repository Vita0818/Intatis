import Foundation
import XCTest
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
@testable import IntatisCowork

private final class ReviewControlPlaneProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let delayNanoseconds: UInt64
    private let chunks: [AgentChunk]
    private let ignoresConsumerCancellation: Bool
    private var captured: [AgentRequest] = []
    private var activeCount = 0
    private var maximumActiveCount = 0

    init(delayNanoseconds: UInt64 = 0,
         chunks: [AgentChunk] = [
            .textDelta(#"{"decision":"allow","reason":"within task scope"}"#),
            .done(finishReason: "stop"),
         ],
         ignoresConsumerCancellation: Bool = false) {
        self.delayNanoseconds = delayNanoseconds
        self.chunks = chunks
        self.ignoresConsumerCancellation = ignoresConsumerCancellation
    }

    var requests: [AgentRequest] {
        lock.withLock { captured }
    }

    var callCount: Int {
        lock.withLock { captured.count }
    }

    var maximumConcurrentCalls: Int {
        lock.withLock { maximumActiveCount }
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.withLock {
            captured.append(request)
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
        }
        let delayNanoseconds = delayNanoseconds
        let chunks = chunks
        let finish: @Sendable () -> Void = { [weak self] in
            self?.lock.withLock { self?.activeCount -= 1 }
        }
        return AsyncThrowingStream { continuation in
            let producer: Task<Void, Never>
            if self.ignoresConsumerCancellation {
                producer = Task.detached {
                    if delayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                    }
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                    finish()
                }
            } else {
                producer = Task {
                    do {
                        if delayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: delayNanoseconds)
                        }
                        for chunk in chunks { continuation.yield(chunk) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: CancellationError())
                    }
                    finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
            _ = producer
        }
    }
}

private final class ReviewScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[AgentChunk]]
    private var index = 0

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        let chunks = lock.withLock { () -> [AgentChunk] in
            defer { index += 1 }
            return responses[min(index, responses.count - 1)]
        }
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct ReviewAttachOnlyResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        request.tool == "agent.attach" ? .allow : .deny
    }
}

private actor ReviewFallbackProbe {
    private(set) var requests: [PermissionRequestPayload] = []

    func record(_ request: PermissionRequestPayload) {
        requests.append(request)
    }
}

private struct ReviewFallbackResponder: PermissionResponder {
    let decision: PermissionDecision
    let probe: ReviewFallbackProbe?

    init(_ decision: PermissionDecision, probe: ReviewFallbackProbe? = nil) {
        self.decision = decision
        self.probe = probe
    }

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await probe?.record(request)
        return decision
    }
}

private actor ReviewFallbackConcurrencyProbe {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var order: [String] = []

    func decide(_ request: PermissionRequestPayload) async -> PermissionDecision {
        active += 1
        maximumActive = max(maximumActive, active)
        order.append("start:\(request.requestId.rawValue)")
        try? await Task.sleep(nanoseconds: 30_000_000)
        order.append("end:\(request.requestId.rawValue)")
        active -= 1
        return .deny
    }
}

private struct ReviewDelayedFallbackResponder: PermissionResponder {
    let probe: ReviewFallbackConcurrencyProbe

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await probe.decide(request)
    }
}

private actor ReviewFirstFallbackGate {
    private var callCount = 0
    private var firstStarted = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func decide(_ request: PermissionRequestPayload) async -> PermissionDecision {
        callCount += 1
        guard callCount == 1 else { return .deny }
        firstStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return .deny
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct ReviewFirstBlockingFallbackResponder: PermissionResponder {
    let gate: ReviewFirstFallbackGate

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await gate.decide(request)
    }
}

private actor ReviewUncooperativeFallbackGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionWaiters: [CheckedContinuation<PermissionDecision, Never>] = []

    func decide() async -> PermissionDecision {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            decisionWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseLate(_ decision: PermissionDecision) {
        let waiters = decisionWaiters
        decisionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: decision) }
    }
}

private struct ReviewUncooperativeFallbackResponder: PermissionResponder {
    let gate: ReviewUncooperativeFallbackGate

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await gate.decide()
    }
}

private final class ReviewPartialUsageFailureProvider: ToolCallingProvider, @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.usage(Usage(
                promptTokens: 99_000,
                completionTokens: 900,
                totalTokens: 99_900)))
            continuation.finish(throwing: Failure.injected)
        }
    }
}

private actor ReviewFailingAppender {
    enum FailurePoint {
        case requested
        case settled
    }

    enum TestError: Error {
        case injected
    }

    let failurePoint: FailurePoint

    init(_ failurePoint: FailurePoint) {
        self.failurePoint = failurePoint
    }

    func append(_ event: Event, to log: EventLog) async throws {
        switch (failurePoint, event) {
        case (.requested, .permissionReviewRequested),
             (.settled, .permissionReviewSettled):
            throw TestError.injected
        default:
            _ = try await log.append(event)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class PermissionReviewControlPlaneTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let reviewerID = Orchestrator.automaticPermissionReviewerID

    func testReviewerControlPlaneDoesNotConsumeOnlyDataPlaneSchedulerSlot() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mainProvider = ReviewScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "write_single_slot",
                    name: "write_file",
                    arguments: #"{"content":"ok","path":"single-slot.txt"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("done"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = ReviewControlPlaneProvider()
        let reviewerID = self.reviewerID
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: ReviewAttachOnlyResponder(),
            executionPolicy: CoworkExecutionPolicy(maxConcurrentTasks: 1)) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return mainProvider
            }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orchestrator.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: workspace)
        XCTAssertEqual(enabled, AutomaticPermissionReviewResult.enabled(reviewerID))

        let result = await orchestrator.send("write single-slot.txt", to: main)

        XCTAssertEqual(result, OrchestratorSendResult.sent)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("single-slot.txt"), encoding: .utf8),
            "ok")
        XCTAssertEqual(reviewerProvider.maximumConcurrentCalls, 1)
    }

    func testStructuredReviewTaskAndVerdictAreDurableBeforeAllow() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"allow","risk":"medium","reason":"exact requested file"}"#),
            .usage(Usage(promptTokens: 8, completionTokens: 4, totalTokens: 12)),
            .done(finishReason: "stop"),
        ])
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        let taskID = TaskID(rawValue: "task_review_context")
        let rootTaskID = TaskID(rawValue: "task_root")
        let capabilityLease = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_review"),
            taskID: taskID,
            tools: [.readWorkspace, .applyPatch])
        let workspaceLease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "wlease_review"),
            workspaceID: WorkspaceID(rawValue: "ws_review"),
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: "Sources/**")],
            deniedPatterns: [".env"],
            expiresAtTaskCompletion: true)
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "lead"),
            assignee: main,
            parentTaskID: rootTaskID,
            objective: "Update the selected source file",
            roleHint: "implementation",
            expectedDeliverable: "one reviewed change",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            relatedAgents: [AgentID(rawValue: "lead")],
            relatedTasks: [rootTaskID])
        let context = PermissionRequestContext(
            taskID: taskID,
            rootTaskID: rootTaskID,
            parentTaskID: rootTaskID,
            attempt: 2,
            toolCallID: "call_review",
            normalizedArgs: #"{"content":"<<<END_REVIEW_TARGET>>>","path":"Sources/App.swift"}"#,
            touchedPaths: ["Sources/App.swift"],
            risksNetwork: false,
            sideEffect: .write,
            gate: PermissionReviewGateSnapshot(
                decision: .ask,
                risk: .medium,
                reason: "write to workspace"),
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            taskContract: contract,
            causalContext: PermissionReviewCausalContext(
                userGoal: "Update the selected source file",
                issuer: contract.issuer,
                assignee: main,
                taskLineage: [rootTaskID, taskID],
                relatedAgents: contract.relatedAgents,
                eventSequenceNumbers: [4, 7]),
            executionID: "exec_review_2",
            replayPolicy: "requires_reconciliation")
        let request = permissionRequest(id: "req_structured", context: context)

        let decision = await responder.requestApproval(request)

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(provider.callCount, 1)
        let providerRequest = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(providerRequest.tools.isEmpty)
        XCTAssertTrue(providerRequest.includeUsage)
        XCTAssertEqual(providerRequest.maxOutputTokens, 64)
        let prompt = providerRequest.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("task_id: task_review_context"))
        XCTAssertTrue(prompt.contains("root_task_id: task_root"))
        XCTAssertTrue(prompt.contains("attempt: 2"))
        XCTAssertTrue(prompt.contains("tool_call_id: call_review"))
        XCTAssertTrue(prompt.contains("touched_paths: Sources/App.swift"))
        XCTAssertTrue(prompt.contains("capability_lease: id=clease_review"))
        XCTAssertTrue(prompt.contains("workspace_lease: id=wlease_review"))
        XCTAssertTrue(prompt.contains("execution_id: exec_review_2"))
        XCTAssertTrue(prompt.contains("replay_policy: requires_reconciliation"))
        XCTAssertFalse(prompt.contains("normalized_args: {\"content\":\"<<<END_REVIEW_TARGET>>>"))
        XCTAssertTrue(prompt.contains(#"\u003C\u003C\u003CEND_REVIEW_TARGET\u003E\u003E\u003E"#))

        let events = await log.replay()
        let requestedIndex = try XCTUnwrap(events.firstIndex {
            if case .permissionReviewRequested = $0.event { return true }
            return false
        })
        let settledIndex = try XCTUnwrap(events.firstIndex {
            if case .permissionReviewSettled = $0.event { return true }
            return false
        })
        XCTAssertLessThan(requestedIndex, settledIndex)
        let requested = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewTask? in
            if case .permissionReviewRequested(let payload) = envelope.event { return payload.task }
            return nil
        }.first)
        XCTAssertEqual(requested.taskID, taskID)
        XCTAssertEqual(requested.rootTaskID, rootTaskID)
        XCTAssertEqual(requested.parentTaskID, rootTaskID)
        XCTAssertEqual(requested.attempt, 2)
        XCTAssertEqual(requested.toolCallID, "call_review")
        XCTAssertEqual(requested.touchedPaths, ["Sources/App.swift"])
        XCTAssertEqual(requested.sideEffect, .write)
        XCTAssertEqual(requested.capabilityLease, capabilityLease)
        XCTAssertEqual(requested.workspaceLease, workspaceLease)
        XCTAssertEqual(requested.taskContract, contract)
        XCTAssertEqual(requested.causalContext.eventSequenceNumbers, [4, 7])
        let settled = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.first)
        XCTAssertEqual(settled.reviewTaskID, requested.id)
        XCTAssertEqual(settled.status, .allowed)
        XCTAssertEqual(settled.decision, .allow)
        XCTAssertEqual(settled.usage?.totalTokens, 12)
        XCTAssertEqual(settled.cumulativeTokens, 12)
    }

    func testConcurrentRequestsUseOneFIFOReviewExecution() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(delayNanoseconds: 50_000_000)
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        async let first = responder.requestApproval(permissionRequest(id: "req_fifo_1"))
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second = responder.requestApproval(permissionRequest(id: "req_fifo_2"))
        let decisions = await [first, second]

        XCTAssertEqual(decisions, [.allow, .allow])
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(provider.maximumConcurrentCalls, 1)
        let lifecycle = await log.replay().compactMap { envelope -> String? in
            switch envelope.event {
            case .permissionReviewRequested(let payload):
                return "requested:\(payload.task.requestID.rawValue)"
            case .permissionReviewSettled(let payload):
                return "settled:\(payload.requestID.rawValue)"
            default:
                return nil
            }
        }
        XCTAssertEqual(lifecycle, [
            "requested:req_fifo_1", "settled:req_fifo_1",
            "requested:req_fifo_2", "settled:req_fifo_2",
        ])
    }

    func testAskUserFallbackRemainsFIFOAcrossTheWholeReviewLifecycle() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"ask_user","reason":"needs human review"}"#),
            .done(finishReason: "stop"),
        ])
        let probe = ReviewFallbackConcurrencyProbe()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewDelayedFallbackResponder(probe: probe))

        async let first = responder.requestApproval(permissionRequest(id: "req_fallback_fifo_1"))
        try await Task.sleep(nanoseconds: 2_000_000)
        async let second = responder.requestApproval(permissionRequest(id: "req_fallback_fifo_2"))
        let decisions = await [first, second]
        let maximumFallbackConcurrency = await probe.maximumActive
        let fallbackOrder = await probe.order

        XCTAssertEqual(decisions, [.deny, .deny])
        XCTAssertEqual(maximumFallbackConcurrency, 1)
        XCTAssertEqual(fallbackOrder, [
            "start:req_fallback_fifo_1", "end:req_fallback_fifo_1",
            "start:req_fallback_fifo_2", "end:req_fallback_fifo_2",
        ])
        XCTAssertEqual(provider.maximumConcurrentCalls, 1)
    }

    func testShutdownDoesNotWaitForUncooperativeFallbackAndLateAllowCannotWin() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"ask_user","reason":"needs human review"}"#),
            .done(finishReason: "stop"),
        ])
        let fallbackGate = ReviewUncooperativeFallbackGate()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewUncooperativeFallbackResponder(gate: fallbackGate))
        let requestTask = Task {
            await responder.requestApproval(permissionRequest(id: "req_uncooperative_fallback"))
        }
        await fallbackGate.waitUntilStarted()
        let started = Date()

        await responder.shutdown(reason: "test shutdown")
        let decision = await requestTask.value
        await fallbackGate.releaseLate(.allow)

        XCTAssertEqual(decision, .deny)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
    }

    func testQueueWaitUsesSubmissionDeadlineAndFallsBackAfterDurableTimeout() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"ask_user","reason":"needs human review"}"#),
            .done(finishReason: "stop"),
        ])
        let fallbackGate = ReviewFirstFallbackGate()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewFirstBlockingFallbackResponder(gate: fallbackGate),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 0.04,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12))
        async let first = responder.requestApproval(permissionRequest(id: "req_deadline_1"))
        await fallbackGate.waitUntilFirstStarted()
        async let second = responder.requestApproval(permissionRequest(id: "req_deadline_2"))
        try await Task.sleep(nanoseconds: 70_000_000)
        await fallbackGate.releaseFirst()
        let decisions = await [first, second]

        XCTAssertEqual(decisions, [.deny, .deny])
        XCTAssertEqual(provider.callCount, 1)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.map(\.requestID.rawValue), ["req_deadline_1", "req_deadline_2"])
        XCTAssertEqual(settled.map(\.status), [.awaitingUser, .timedOut])
    }

    func testPendingReviewCapacityFailsClosedWithoutGrowingTheQueue() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"ask_user","reason":"needs human review"}"#),
            .done(finishReason: "stop"),
        ])
        let fallbackGate = ReviewFirstFallbackGate()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewFirstBlockingFallbackResponder(gate: fallbackGate),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 1,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12,
                maxPendingReviews: 1))
        let first = Task {
            await responder.requestApproval(permissionRequest(id: "req_capacity_1"))
        }
        await fallbackGate.waitUntilFirstStarted()
        let started = Date()

        let overflow = await responder.requestApproval(permissionRequest(id: "req_capacity_overflow"))
        await fallbackGate.releaseFirst()
        let firstDecision = await first.value

        XCTAssertEqual(overflow, .deny)
        XCTAssertEqual(firstDecision, .deny)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testRequestedPersistenceFailureNeverCallsProviderOrAllows() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider()
        let appender = ReviewFailingAppender(.requested)
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            eventAppender: { event in try await appender.append(event, to: log) })

        let decision = await responder.requestApproval(permissionRequest(id: "req_fail_requested"))

        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(provider.callCount, 0)
        let events = await log.replay()
        XCTAssertTrue(events.isEmpty)
    }

    func testSettledPersistenceFailureConvertsModelAllowToDeny() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider()
        let appender = ReviewFailingAppender(.settled)
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            eventAppender: { event in try await appender.append(event, to: log) })

        let decision = await responder.requestApproval(permissionRequest(id: "req_fail_settled"))

        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(provider.callCount, 1)
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .permissionReviewRequested = $0.event { return true }; return false })
        XCTAssertFalse(events.contains { if case .permissionReviewSettled = $0.event { return true }; return false })
        XCTAssertFalse(events.contains { if case .permissionReview = $0.event { return true }; return false })
    }

    func testTimeoutDoesNotWaitForUncooperativeProviderAndFallsBackAfterDurableVerdict() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(
            delayNanoseconds: 500_000_000,
            ignoresConsumerCancellation: true)
        let fallbackProbe = ReviewFallbackProbe()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewFallbackResponder(.deny, probe: fallbackProbe),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 0.03,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12))
        let start = Date()

        let decision = await responder.requestApproval(permissionRequest(id: "req_timeout"))
        let secondDecision = await responder.requestApproval(
            permissionRequest(id: "req_while_timed_out_provider_stops"))

        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(secondDecision, .deny)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        let fallbackRequestCount = await fallbackProbe.requests.count
        XCTAssertEqual(fallbackRequestCount, 2)
        XCTAssertEqual(provider.callCount, 1)
        guard case .degraded(let reason) = await responder.health() else {
            return XCTFail("timed-out reviewer must remain visibly degraded")
        }
        XCTAssertTrue(reason.contains("quarantined"))
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.map(\.status), [.timedOut, .failed])
        XCTAssertTrue(settled.allSatisfy { $0.decision == .askUser })
    }

    func testCancellationSettlesDenyAndDoesNotWaitForProvider() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(delayNanoseconds: 500_000_000)
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        let task = Task {
            await responder.requestApproval(permissionRequest(id: "req_cancel"))
        }
        for _ in 0..<100 where provider.callCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let start = Date()

        task.cancel()
        let decision = await task.value

        XCTAssertEqual(decision, .deny)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        guard case .degraded(let reason) = await responder.health() else {
            return XCTFail("cancelled reviewer must remain visibly degraded")
        }
        XCTAssertTrue(reason.contains("quarantined"))
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.last?.status, .cancelled)
        XCTAssertEqual(settled.last?.decision, .deny)
    }

    func testTimedOutProviderQuarantineSurvivesControlPlaneReplacementForSession() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let firstProvider = ReviewControlPlaneProvider(
            delayNanoseconds: 500_000_000,
            ignoresConsumerCancellation: true)
        let firstResponder = makeResponder(
            log: log,
            workspace: workspace,
            provider: firstProvider,
            fallback: ReviewFallbackResponder(.deny),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 0.03,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12))

        let firstDecision = await firstResponder.requestApproval(
            permissionRequest(id: "req_poison_session"))
        XCTAssertEqual(firstDecision, .deny)
        XCTAssertEqual(firstProvider.callCount, 1)

        let replacementProvider = ReviewControlPlaneProvider()
        let fallbackProbe = ReviewFallbackProbe()
        let replacement = makeResponder(
            log: log,
            workspace: workspace,
            provider: replacementProvider,
            fallback: ReviewFallbackResponder(.deny, probe: fallbackProbe))
        guard case .degraded(let initialReason) = await replacement.health() else {
            return XCTFail("replacement control plane must start in the inherited session quarantine")
        }
        XCTAssertTrue(initialReason.contains("restart Intatis"))
        let replacementDecision = await replacement.requestApproval(
            permissionRequest(id: "req_after_replacement"))
        XCTAssertEqual(replacementDecision, .deny)
        XCTAssertEqual(replacementProvider.callCount, 0)
        let fallbackRequestCount = await fallbackProbe.requests.count
        XCTAssertEqual(fallbackRequestCount, 1)
        guard case .degraded(let reason) = await replacement.health() else {
            return XCTFail("replacement control plane must inherit the session quarantine")
        }
        XCTAssertTrue(reason.contains("restart Intatis"))
    }

    func testHardDenyAndSelfReviewNeverReachProvider() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider()
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        let hardDeny = PermissionRequestContext(
            gate: PermissionReviewGateSnapshot(
                decision: .deny,
                risk: .high,
                reason: "path escapes workspace"))

        let denied = await responder.requestApproval(
            permissionRequest(id: "req_hard_deny", context: hardDeny))
        let selfReview = await responder.requestApproval(PermissionRequestPayload(
            requestId: RequestID(rawValue: "req_self_review"),
            agent: reviewerID,
            tool: "write_file",
            args: "{}",
            risk: .high,
            reason: "self review"))

        XCTAssertEqual(denied, .deny)
        XCTAssertEqual(selfReview, .deny)
        XCTAssertEqual(provider.callCount, 0)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.map(\.status), [.denied, .denied])
    }

    func testReviewBudgetExhaustionIsDurableAndCannotAutoAllow() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider()
        let fallbackProbe = ReviewFallbackProbe()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewFallbackResponder(.deny, probe: fallbackProbe),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 1,
                tokenBudget: 1,
                reservedCompletionTokens: 1,
                maxRecentEvents: 4))

        let decision = await responder.requestApproval(permissionRequest(id: "req_budget"))

        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(provider.callCount, 0)
        guard case .degraded(let reason) = await responder.health() else {
            return XCTFail("exhausted reviewer budget must remain visibly degraded")
        }
        XCTAssertTrue(reason.contains("budget"))
        let fallbackRequestCount = await fallbackProbe.requests.count
        XCTAssertEqual(fallbackRequestCount, 1)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.last?.status, .budgetExceeded)
        XCTAssertEqual(settled.last?.decision, .askUser)
    }

    func testProviderFailureAfterUsageChargesBudgetAndDegradesHealth() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewPartialUsageFailureProvider()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewFallbackResponder(.deny),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 1,
                tokenBudget: 100_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 4))

        let first = await responder.requestApproval(permissionRequest(id: "req_partial_usage_failure"))
        let second = await responder.requestApproval(permissionRequest(id: "req_partial_usage_budget"))

        XCTAssertEqual(first, .deny)
        XCTAssertEqual(second, .deny)
        XCTAssertEqual(provider.callCount, 1)
        guard case .degraded(let reason) = await responder.health() else {
            return XCTFail("provider failure or its restored budget must be visible in health")
        }
        XCTAssertTrue(reason.contains("budget") || reason.contains("failed"))
        let settlements = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlements.first?.status, .failed)
        XCTAssertEqual(settlements.first?.usage?.totalTokens, 99_900)
        XCTAssertEqual(settlements.first?.cumulativeTokens, 99_900)
        XCTAssertEqual(settlements.last?.status, .budgetExceeded)
        XCTAssertEqual(settlements.last?.cumulativeTokens, 99_900)
    }

    func testOrphanedDurableReviewIsDeniedBeforeNewAutomaticReviewRuns() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orphanTask = PermissionReviewTask(
            id: PermissionReviewTaskID(rawValue: "review_orphaned"),
            sessionID: await log.sessionID,
            requestID: RequestID(rawValue: "req_orphaned"),
            requestingAgent: main,
            reviewerAgent: reviewerID,
            taskID: TaskID(rawValue: "task_orphaned"),
            tool: "write_file",
            normalizedArgs: "{}",
            gate: PermissionReviewGateSnapshot(
                decision: .ask,
                risk: .medium,
                reason: "write to workspace"),
            createdAt: Date().addingTimeInterval(-10),
            deadline: Date().addingTimeInterval(-9))
        _ = try await log.append(.permissionReviewRequested(.init(task: orphanTask)))
        let provider = ReviewControlPlaneProvider()
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        let decision = await responder.requestApproval(permissionRequest(id: "req_after_orphan"))

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(provider.callCount, 1)
        let lifecycle = await log.replay().compactMap { envelope -> String? in
            switch envelope.event {
            case .permissionReviewRequested(let payload):
                return "requested:\(payload.task.requestID.rawValue)"
            case .permissionReviewSettled(let payload):
                return "settled:\(payload.requestID.rawValue):\(payload.status.rawValue):\(payload.decision.rawValue)"
            default:
                return nil
            }
        }
        XCTAssertEqual(lifecycle, [
            "requested:req_orphaned",
            "settled:req_orphaned:cancelled:deny",
            "requested:req_after_orphan",
            "settled:req_after_orphan:allowed:allow",
        ])
    }

    func testReviewBudgetRestoresFromDurableSettlements() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let firstProvider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"allow","reason":"first review"}"#),
            .usage(Usage(promptTokens: 98_900, completionTokens: 100, totalTokens: 99_000)),
            .done(finishReason: "stop"),
        ])
        let firstResponder = makeResponder(
            log: log,
            workspace: workspace,
            provider: firstProvider,
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 1,
                tokenBudget: 200_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 4))
        let firstDecision = await firstResponder.requestApproval(permissionRequest(id: "req_budget_seed"))
        XCTAssertEqual(firstDecision, .allow)

        let secondProvider = ReviewControlPlaneProvider()
        let secondResponder = makeResponder(
            log: log,
            workspace: workspace,
            provider: secondProvider,
            fallback: ReviewFallbackResponder(.deny),
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 1,
                tokenBudget: 99_500,
                reservedCompletionTokens: 64,
                maxRecentEvents: 4))

        let decision = await secondResponder.requestApproval(permissionRequest(id: "req_budget_restored"))

        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(secondProvider.callCount, 0)
        let settlements = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlements.last?.status, .budgetExceeded)
        XCTAssertEqual(settlements.last?.cumulativeTokens, 99_000)
    }

    private func makeResponder(log: EventLog,
                               workspace: URL,
                               provider: ToolCallingProvider,
                               fallback: PermissionResponder = ReviewFallbackResponder(.deny),
                               policy: PermissionReviewControlPlanePolicy = PermissionReviewControlPlanePolicy(
                                timeoutSeconds: 1,
                                tokenBudget: 100_000,
                                reservedCompletionTokens: 64,
                                maxRecentEvents: 12),
                               eventAppender: PermissionReviewEventAppender? = nil) -> AgentPermissionResponder {
        AgentPermissionResponder(
            log: log,
            reviewerAgent: Agent(
                name: reviewerID,
                workspaceRoot: workspace,
                model: ModelID(rawValue: "reviewer-model"),
                profile: .readOnly,
                coordinationDepth: 0),
            provider: provider,
            fallback: fallback,
            policy: policy,
            eventAppender: eventAppender)
    }

    private func permissionRequest(id: String,
                                   context: PermissionRequestContext? = nil) -> PermissionRequestPayload {
        PermissionRequestPayload(
            requestId: RequestID(rawValue: id),
            agent: main,
            tool: "write_file",
            args: #"{"content":"ok","path":"Sources/App.swift"}"#,
            risk: .medium,
            reason: "write to workspace",
            context: context)
    }

    private func makeLogAndWorkspace() throws -> (EventLog, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("permission-review-control-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = try EventLog(
            session: SessionID(rawValue: "review_control"),
            fileURL: root.appendingPathComponent("events.jsonl"))
        return (log, workspace)
    }
}
