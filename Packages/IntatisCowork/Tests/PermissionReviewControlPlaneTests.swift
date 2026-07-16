import Foundation
import XCTest
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
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

    func testDefaultReviewerCompletionAllowanceLeavesRoomForStructuredVerdict() {
        XCTAssertEqual(
            PermissionReviewControlPlanePolicy().reservedCompletionTokens,
            1_024)
    }

    func testCorruptDurableReviewHistoryDeniesBeforeProviderDispatch() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let provider = ReviewControlPlaneProvider()
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        try Data("{\"invalid\":true}\n".utf8)
            .write(to: workspace.deletingLastPathComponent().appendingPathComponent("events.jsonl"))

        let resolution = await responder.requestResolution(
            permissionRequest(id: "req_corrupt_durable_history"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .automaticReviewerFailure)
        XCTAssertEqual(resolution.reviewStatus, .failed)
        XCTAssertEqual(resolution.failureKind, .reconciliationFailure)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testTruncatedReviewerVerdictIsDiagnosedAndDenied() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"allow","reason":"unfinished"#),
            .usage(Usage(promptTokens: 100, completionTokens: 64, totalTokens: 164)),
            // Some OpenAI-compatible providers report `stop` even when usage
            // reaches the exact requested ceiling, so usage must also diagnose
            // the truncation seen in production logs.
            .done(finishReason: "stop"),
        ])
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        let resolution = await responder.requestResolution(
            permissionRequest(id: "req_truncated_verdict"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .automaticReviewerFailure)
        XCTAssertEqual(resolution.reviewStatus, .failed)
        XCTAssertEqual(resolution.failureKind, .malformedVerdict)
        XCTAssertTrue(resolution.reason?.contains("completion-token limit") == true)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.last?.status, .failed)
        XCTAssertTrue(settled.last?.reason.contains("completion-token limit") == true)
        XCTAssertFalse(settled.last?.reason.contains("tool call") == true)
    }

    func testReviewerToolCallHasDistinctFailClosedDiagnosis() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .toolCalls([ToolCall(id: "forbidden", name: "write_file", arguments: "{}")]),
            .done(finishReason: "tool_calls"),
        ])
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        let resolution = await responder.requestResolution(
            permissionRequest(id: "req_reviewer_tool_call"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .automaticReviewerFailure)
        XCTAssertEqual(resolution.reviewStatus, .failed)
        XCTAssertEqual(resolution.failureKind, .reviewerContractViolation)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.last?.status, .failed)
        XCTAssertTrue(settled.last?.reason.contains("attempted a tool call") == true)
        XCTAssertFalse(settled.last?.reason.contains("invalid or") == true)
    }

    func testReviewerAllowWithoutNonemptyReasonIsMalformedAndDenied() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"allow"}"#),
            .done(finishReason: "stop"),
        ])
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        let resolution = await responder.requestResolution(
            permissionRequest(id: "req_missing_reason"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .automaticReviewerFailure)
        XCTAssertEqual(resolution.reviewStatus, .failed)
        XCTAssertEqual(resolution.failureKind, .malformedVerdict)
        XCTAssertTrue(resolution.reason?.contains("malformed verdict JSON") == true)
    }

    func testReviewerCannotDowngradeDeterministicGateRisk() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"allow","risk":"low","reason":"narrowly within scope"}"#),
            .done(finishReason: "stop"),
        ])
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        let context = PermissionRequestContext(gate: PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .high,
            reason: "host classified this action as high risk",
            policyVersion: "intatis.deterministic-policy.v1"))

        let resolution = await responder.requestResolution(
            permissionRequest(id: "req_risk_floor", context: context))

        XCTAssertEqual(resolution.decision, .allow)
        XCTAssertEqual(resolution.risk, .high)
        let replayed = await log.replay()
        let settled = try XCTUnwrap(replayed.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.last)
        XCTAssertEqual(settled.risk, .high)
    }

    func testReviewerPromptUsesBoundedSecretRedactedActionPreviewAndUntrustedFacts() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider()
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        let secret = "review-secret-value-123"
        let args = #"{"content":"Authorization: Bearer \#(secret)","path":"Sources/App.swift?token=\#(secret)"}"#
        let intent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "Sources/App.swift?token=\(secret)",
                access: .readWrite)],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .requiresManualReconciliation)
        let context = PermissionRequestContext(
            normalizedArgs: args,
            touchedPaths: ["Sources/App.swift?token=\(secret)"],
            risksNetwork: false,
            sideEffect: .write,
            intent: intent,
            gate: PermissionReviewGateSnapshot(
                decision: .ask,
                risk: .medium,
                reason: "Authorization: Bearer \(secret)"))

        let resolution = await responder.requestResolution(
            permissionRequest(id: "req_redacted_preview", context: context))

        XCTAssertEqual(resolution.decision, .allow)
        let prompt = try XCTUnwrap(provider.requests.first)
            .messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertFalse(prompt.contains(secret))
        XCTAssertTrue(prompt.contains("[REDACTED]"))
        XCTAssertTrue(prompt.contains("action_preview: kind=write_file"))
        let replayed = await log.replay()
        let requested = try XCTUnwrap(replayed.compactMap { envelope -> PermissionReviewTask? in
            if case .permissionReviewRequested(let payload) = envelope.event { return payload.task }
            return nil
        }.last)
        let preview = try XCTUnwrap(requested.authorization?.actionPreview)
        XCTAssertTrue(preview.redacted)
        XCTAssertFalse(preview.fields.values.joined().contains(secret))
        XCTAssertTrue(requested.normalizedArgs.contains("digest="))
        XCTAssertFalse(requested.normalizedArgs.contains(secret))
    }

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
        let permissionAudit = await log.replay().compactMap { envelope -> String? in
            switch envelope.event {
            case .permissionResolved(let payload):
                return "resolved \(payload.tool) \(payload.decision.rawValue): \(payload.reason)"
            case .permissionReviewSettled(let payload):
                return "review \(payload.status.rawValue): \(payload.reason)"
            case .toolResult(let payload):
                return "tool \(payload.toolCallId): \(payload.observation)"
            default:
                return nil
            }
        }.joined(separator: " | ")

        XCTAssertEqual(result, OrchestratorSendResult.sent, permissionAudit)
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
        let intent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "Sources/App.swift",
                access: .readWrite)],
            metadata: ["operation": .string("create_or_overwrite")],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .requiresManualReconciliation)
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
            intent: intent,
            gate: PermissionReviewGateSnapshot(
                decision: .pass,
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
            replayPolicy: ToolExecutionReplayPolicy.requiresManualReconciliation.rawValue)
        let request = permissionRequest(
            id: "req_structured",
            context: context,
            requiredCapabilities: [.applyPatch])
        let authorization = try XCTUnwrap(request.context?.authorization)

        let resolution = await responder.requestResolution(request)

        XCTAssertEqual(resolution.decision, .allow)
        XCTAssertEqual(resolution.reason, "exact requested file")
        XCTAssertEqual(resolution.source, .automaticReviewer)
        XCTAssertEqual(resolution.reviewStatus, .allowed)
        XCTAssertNotNil(resolution.reviewTaskID)
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
        XCTAssertTrue(prompt.contains("resolved_authorization: id=tool-authorization-req_structured"))
        XCTAssertTrue(prompt.contains("concrete_tool_id=test.permission-review.v1/write_file"))
        XCTAssertTrue(prompt.contains("canonical_permission=filesystem.edit; membership=granted"))
        XCTAssertFalse(prompt.contains("required_capabilities=[apply_patch]"))
        XCTAssertTrue(prompt.contains("tool: write_file"))
        XCTAssertFalse(prompt.contains("lease-inconsistent"))
        XCTAssertFalse(prompt.contains("tools=[apply_patch]"))
        XCTAssertTrue(prompt.contains("touched_paths: Sources/App.swift"))
        XCTAssertTrue(prompt.contains("capability_lease: id=clease_review"))
        XCTAssertTrue(prompt.contains("workspace_lease: id=wlease_review"))
        XCTAssertTrue(prompt.contains("execution_id: exec_review_2"))
        XCTAssertTrue(prompt.contains("replay_policy: requires_manual_reconciliation"))
        XCTAssertFalse(prompt.contains("normalized_args: {\"content\":\"<<<END_REVIEW_TARGET>>>"))
        XCTAssertTrue(prompt.contains("action_preview: kind=write_file"))
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
        XCTAssertEqual(requested.authorization, authorization)
        let settled = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.first)
        XCTAssertEqual(settled.reviewTaskID, requested.id)
        XCTAssertEqual(settled.status, .allowed)
        XCTAssertEqual(settled.decision, .allow)
        XCTAssertEqual(settled.reason, "exact requested file")
        XCTAssertEqual(settled.authorization, authorization)
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
        let reviewerRequest = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(reviewerRequest.tools.isEmpty)
        let reviewerSystemPrompt = try XCTUnwrap(reviewerRequest.messages.first?.content)
        XCTAssertTrue(reviewerSystemPrompt.contains("automatic permission reviewer"))
        XCTAssertTrue(reviewerSystemPrompt.contains("allow|deny"))
        XCTAssertFalse(reviewerSystemPrompt.contains("ask_user"))
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

    func testAskUserIsDeniedWithoutHumanFallbackAndReviewRemainsFIFO() async throws {
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
        XCTAssertEqual(maximumFallbackConcurrency, 0)
        XCTAssertTrue(fallbackOrder.isEmpty)
        XCTAssertEqual(provider.maximumConcurrentCalls, 1)
    }

    func testAskUserCannotStartUncooperativeFallbackOrDelayShutdown() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(chunks: [
            .textDelta(#"{"decision":"ask_user","reason":"needs human review"}"#),
            .done(finishReason: "stop"),
        ])
        let fallbackProbe = ReviewFallbackProbe()
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            fallback: ReviewFallbackResponder(.allow, probe: fallbackProbe))
        let decision = await responder.requestApproval(
            permissionRequest(id: "req_uncooperative_fallback"))
        let started = Date()

        await responder.shutdown(reason: "test shutdown")

        XCTAssertEqual(decision, .deny)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        let fallbackCount = await fallbackProbe.requests.count
        XCTAssertEqual(fallbackCount, 0)
    }

    func testQueueWaitUsesSubmissionDeadlineAndDurablyDeniesOnTimeout() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(delayNanoseconds: 80_000_000)
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 0.04,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12))
        async let first = responder.requestApproval(permissionRequest(id: "req_deadline_1"))
        for _ in 0..<100 where provider.callCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        async let second = responder.requestApproval(permissionRequest(id: "req_deadline_2"))
        let decisions = await [first, second]

        XCTAssertEqual(decisions, [.deny, .deny])
        XCTAssertEqual(provider.callCount, 1)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.map(\.requestID.rawValue), ["req_deadline_1", "req_deadline_2"])
        XCTAssertEqual(settled.map(\.status), [.timedOut, .timedOut])
        XCTAssertTrue(settled.allSatisfy { $0.decision == .deny })
    }

    func testPendingReviewCapacityFailsClosedWithoutGrowingTheQueue() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(delayNanoseconds: 80_000_000)
        let responder = makeResponder(
            log: log,
            workspace: workspace,
            provider: provider,
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 1,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12,
                maxPendingReviews: 1))
        let first = Task {
            await responder.requestApproval(permissionRequest(id: "req_capacity_1"))
        }
        for _ in 0..<100 where provider.callCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = Date()

        let overflow = await responder.requestResolution(permissionRequest(id: "req_capacity_overflow"))
        let firstDecision = await first.value

        XCTAssertEqual(overflow.decision, .deny)
        XCTAssertEqual(overflow.source, .automaticReviewerFailure)
        XCTAssertEqual(overflow.failureKind, .queueCapacity)
        XCTAssertNotNil(overflow.reviewTaskID)
        XCTAssertEqual(firstDecision, .allow)
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

        let resolution = await responder.requestResolution(permissionRequest(id: "req_fail_requested"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .automaticReviewerFailure)
        XCTAssertEqual(resolution.failureKind, .requestPersistenceFailure)
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

        let resolution = await responder.requestResolution(permissionRequest(id: "req_fail_settled"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .automaticReviewerFailure)
        XCTAssertEqual(resolution.failureKind, .settlementPersistenceFailure)
        XCTAssertEqual(provider.callCount, 1)
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .permissionReviewRequested = $0.event { return true }; return false })
        XCTAssertFalse(events.contains { if case .permissionReviewSettled = $0.event { return true }; return false })
        XCTAssertFalse(events.contains { if case .permissionReview = $0.event { return true }; return false })
    }

    func testTimeoutDoesNotWaitForUncooperativeProviderAndNeverFallsBack() async throws {
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

        let resolution = await responder.requestResolution(permissionRequest(id: "req_timeout"))
        let secondResolution = await responder.requestResolution(
            permissionRequest(id: "req_while_timed_out_provider_stops"))

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.reviewStatus, .timedOut)
        XCTAssertEqual(resolution.failureKind, .reviewerTimedOut)
        XCTAssertEqual(secondResolution.decision, .deny)
        XCTAssertEqual(secondResolution.failureKind, .providerStillStopping)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        let fallbackRequestCount = await fallbackProbe.requests.count
        XCTAssertEqual(fallbackRequestCount, 0)
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
        XCTAssertTrue(settled.allSatisfy { $0.decision == .deny })
    }

    func testCancellationSettlesDenyAndDoesNotWaitForProvider() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider(delayNanoseconds: 500_000_000)
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        let task = Task {
            await responder.requestResolution(permissionRequest(id: "req_cancel"))
        }
        for _ in 0..<100 where provider.callCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let start = Date()

        task.cancel()
        let resolution = await task.value

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.reviewStatus, .cancelled)
        XCTAssertEqual(resolution.failureKind, .reviewerCancelled)
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
        XCTAssertEqual(fallbackRequestCount, 0)
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

        let denied = await responder.requestResolution(
            permissionRequest(id: "req_hard_deny", context: hardDeny))
        let selfReview = await responder.requestResolution(
            permissionRequest(id: "req_self_review", agent: reviewerID))

        XCTAssertEqual(denied.decision, .deny)
        XCTAssertEqual(denied.source, .deterministicPolicy)
        XCTAssertEqual(selfReview.decision, .deny)
        XCTAssertEqual(selfReview.failureKind, .reviewerContractViolation)
        XCTAssertEqual(selfReview.reason, "reviewer agent cannot approve its own request")
        XCTAssertEqual(provider.callCount, 0)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.map(\.status), [.denied, .denied])
    }

    func testMissingHostAuthorizationIsDurablyDeniedBeforeProvider() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReviewControlPlaneProvider()
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)
        var request = permissionRequest(id: "req_missing_authorization")
        request.context?.authorization = nil

        let resolution = await responder.requestResolution(request)

        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.source, .deterministicPolicy)
        XCTAssertEqual(resolution.failureKind, .authorizationSnapshotInvalid)
        XCTAssertEqual(provider.callCount, 0)
        let settlements = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            guard case .permissionReviewSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(settlements.last?.failureKind, .authorizationSnapshotInvalid)
        XCTAssertTrue(settlements.last?.reason.contains("snapshot is missing") == true)
    }

    func testPinnedLiveLeasesCannotBeRemovedBeforeAutomaticReview() async throws {
        let (log, workspace) = try makeLogAndWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let provider = ReviewControlPlaneProvider()
        let responder = makeResponder(log: log, workspace: workspace, provider: provider)

        let capability = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "pinned-capability"),
            tools: [.applyPatch],
            expiresAtTaskCompletion: false)
        var missingCapability = permissionRequest(
            id: "req_missing_pinned_capability",
            context: PermissionRequestContext(capabilityLease: capability))
        missingCapability.context?.capabilityLease = nil

        let workspaceLease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "pinned-workspace"),
            workspaceID: WorkspaceID(rawValue: "pinned-workspace-id"),
            rootPath: workspace.path,
            access: .readWrite)
        var missingWorkspace = permissionRequest(
            id: "req_missing_pinned_workspace",
            context: PermissionRequestContext(workspaceLease: workspaceLease))
        missingWorkspace.context?.workspaceLease = nil

        let capabilityResolution = await responder.requestResolution(missingCapability)
        let workspaceResolution = await responder.requestResolution(missingWorkspace)

        XCTAssertEqual(capabilityResolution.decision, .deny)
        XCTAssertEqual(capabilityResolution.failureKind, .authorizationSnapshotInvalid)
        XCTAssertTrue(capabilityResolution.reason?.contains("missing capability lease") == true)
        XCTAssertEqual(workspaceResolution.decision, .deny)
        XCTAssertEqual(workspaceResolution.failureKind, .authorizationSnapshotInvalid)
        XCTAssertTrue(workspaceResolution.reason?.contains("missing workspace lease") == true)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testReviewBudgetIsSoftAndCannotDisableAutomaticAllow() async throws {
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

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(provider.callCount, 1)
        guard case .degraded(let reason) = await responder.health() else {
            return XCTFail("crossing the reviewer soft budget should remain observable")
        }
        XCTAssertTrue(reason.contains("budget"))
        let fallbackRequestCount = await fallbackProbe.requests.count
        XCTAssertEqual(fallbackRequestCount, 0)
        let settled = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settled.last?.status, .allowed)
        XCTAssertEqual(settled.last?.decision, .allow)
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

        let first = await responder.requestResolution(permissionRequest(id: "req_partial_usage_failure"))
        let second = await responder.requestResolution(permissionRequest(id: "req_partial_usage_budget"))

        XCTAssertEqual(first.decision, .deny)
        XCTAssertEqual(first.failureKind, .providerFailure)
        XCTAssertEqual(first.source, .automaticReviewerFailure)
        XCTAssertEqual(second.decision, .deny)
        XCTAssertEqual(second.failureKind, .providerFailure)
        XCTAssertEqual(provider.callCount, 2)
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
        XCTAssertEqual(settlements.last?.status, .failed)
        XCTAssertEqual(settlements.last?.cumulativeTokens, 199_800)
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

    func testReviewBudgetRestoresAsSoftUsageWithoutBlockingNextReview() async throws {
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

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(secondProvider.callCount, 1)
        let settlements = await log.replay().compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlements.last?.status, .allowed)
        XCTAssertGreaterThan(settlements.last?.cumulativeTokens ?? 0, 99_000)
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
                                   context: PermissionRequestContext? = nil,
                                   agent: AgentID? = nil,
                                   requiredCapabilities: [ToolCapability] = []) -> PermissionRequestPayload {
        let requestingAgent = agent ?? main
        let args = #"{"content":"ok","path":"Sources/App.swift"}"#
        let defaultIntent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "Sources/App.swift",
                access: .readWrite)],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .requiresManualReconciliation)
        let defaultGate = PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .medium,
            reason: "write to workspace",
            policyVersion: "intatis.deterministic-policy.v1")
        var resolvedContext = context ?? PermissionRequestContext()
        let normalizedArgs = resolvedContext.normalizedArgs ?? args
        let intent = resolvedContext.intent ?? defaultIntent
        let gate = resolvedContext.gate ?? defaultGate
        resolvedContext.normalizedArgs = normalizedArgs
        resolvedContext.risksNetwork = resolvedContext.risksNetwork ?? false
        resolvedContext.sideEffect = resolvedContext.sideEffect ?? .write
        resolvedContext.intent = intent
        resolvedContext.gate = gate
        resolvedContext.replayPolicy = resolvedContext.replayPolicy
            ?? ToolExecutionReplayPolicy.requiresManualReconciliation.rawValue
        if resolvedContext.authorization == nil {
            let capability = resolvedContext.capabilityLease
            let workspace = resolvedContext.workspaceLease
            resolvedContext.authorization = ResolvedToolAuthorization(
                authorizationID: "tool-authorization-\(id)",
                registryVersion: "test.permission-review.v1",
                concreteToolID: "test.permission-review.v1/write_file",
                descriptorFingerprint: ToolRegistry.authorizationDigest("write_file|v1"),
                toolName: "write_file",
                canonicalAction: intent.action,
                canonicalPermission: "filesystem.edit",
                actionPreview: WriteFileTool().permissionActionPreview(
                    ToolArgs(raw: normalizedArgs)),
                requiredCapabilities: requiredCapabilities,
                membership: requiredCapabilities.isEmpty ? .notRequired : .granted,
                capabilityLeaseID: capability?.id,
                capabilityTaskID: capability?.taskID,
                workspaceLeaseID: workspace?.id,
                workspaceAccess: workspace?.access,
                workspaceRootIdentity: workspace?.rootIdentity,
                invocation: ToolAuthorizationInvocationContext(
                    sessionID: SessionID(rawValue: "review_control"),
                    agent: requestingAgent,
                    taskID: resolvedContext.taskID,
                    rootTaskID: resolvedContext.rootTaskID,
                    parentTaskID: resolvedContext.parentTaskID,
                    attempt: resolvedContext.attempt,
                    toolCallID: resolvedContext.toolCallID,
                    taskObjective: resolvedContext.taskContract.map {
                        String($0.objective.prefix(1_200))
                    }),
                normalizedArgumentsDigest: ToolRegistry.authorizationDigest(normalizedArgs),
                normalizedArgumentsCharacterCount: normalizedArgs.count,
                intent: intent,
                sideEffect: resolvedContext.sideEffect ?? .write,
                risksNetwork: resolvedContext.risksNetwork ?? false,
                replayPolicy: .requiresManualReconciliation,
                deterministicGate: gate,
                capabilityLeaseFingerprint: capability.map(ToolRegistry.authorizationFingerprint),
                workspaceID: workspace?.workspaceID,
                workspaceTaskID: workspace?.taskID,
                workspaceRootPath: workspace?.rootPath,
                workspaceLeaseFingerprint: workspace.map(ToolRegistry.authorizationFingerprint))
        }
        return PermissionRequestPayload(
            requestId: RequestID(rawValue: id),
            agent: requestingAgent,
            tool: "write_file",
            args: normalizedArgs,
            risk: .medium,
            reason: "write to workspace",
            context: resolvedContext)
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
