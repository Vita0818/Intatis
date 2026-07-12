import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class PolicyScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var responseIndex = 0
    private var capturedRequests: [AgentRequest] = []

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        let chunks = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private actor PolicyStreamEndCancellationState {
    private var phase = 0
    private var waitingForEnd = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func next() async -> AgentChunk? {
        switch phase {
        case 0:
            phase = 1
            return .textDelta("finished response")
        case 1:
            phase = 2
            return .usage(Usage(promptTokens: 8, completionTokens: 4, totalTokens: 12))
        case 2:
            phase = 3
            return .done(finishReason: "stop")
        default:
            waitingForEnd = true
            let waiters = waitingContinuations
            waitingContinuations.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
            return nil
        }
    }

    func waitUntilProviderIsReadyToEnd() async {
        if waitingForEnd { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func finishStream() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private struct PolicyStreamEndCancellationProvider: ToolCallingProvider {
    let state: PolicyStreamEndCancellationState

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream(unfolding: { await state.next() })
    }
}

private actor ParallelToolProbe {
    private var activeCount = 0
    private var peakActiveCount = 0
    private var completionOrder: [String] = []

    func begin() {
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func finish(label: String) -> String {
        activeCount -= 1
        completionOrder.append(label)
        return "result:\(label)"
    }

    func snapshot() -> (peakActiveCount: Int, completionOrder: [String]) {
        (peakActiveCount, completionOrder)
    }
}

private struct ParallelToolArguments: Decodable {
    var label: String
    var delayMillis: Int
}

private let parallelToolParameters = JSONValue.object([
    "type": .string("object"),
    "properties": .object([
        "label": .object([
            "type": .string("string"),
            "minLength": .number(1),
        ]),
        "delayMillis": .object([
            "type": .string("integer"),
            "minimum": .number(0),
            "maximum": .number(1_000),
        ]),
    ]),
    "required": .array([.string("label"), .string("delayMillis")]),
    "additionalProperties": .bool(false),
])

private struct PolicyAskAgentTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "ask_agent",
        description: "Test-only ask tool with observable concurrency.",
        sideEffect: .readOnly,
        parameters: parallelToolParameters)

    let probe: ParallelToolProbe

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let decoded = try args.decode(ParallelToolArguments.self)
        await probe.begin()
        try await Task.sleep(nanoseconds: UInt64(decoded.delayMillis) * 1_000_000)
        return ToolObservation(text: await probe.finish(label: decoded.label))
    }
}

private struct PolicyDelegateTaskTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "delegate_task",
        description: "Test-only delegation tool with observable concurrency.",
        sideEffect: .readOnly,
        parameters: parallelToolParameters)

    let probe: ParallelToolProbe

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let decoded = try args.decode(ParallelToolArguments.self)
        await probe.begin()
        try await Task.sleep(nanoseconds: UInt64(decoded.delayMillis) * 1_000_000)
        return ToolObservation(text: await probe.finish(label: decoded.label))
    }
}

private actor CapturingPolicyResponder: PermissionResponder {
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

private struct DeleteAuditBeforeAllowResponder: PermissionResponder {
    let eventLogURL: URL

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        try? FileManager.default.removeItem(at: eventLogURL)
        return .allow
    }
}

private struct ReplaceWorkspaceBeforeAllowResponder: PermissionResponder {
    let workspace: URL
    let movedWorkspace: URL

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        do {
            try FileManager.default.moveItem(at: workspace, to: movedWorkspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            return .allow
        } catch {
            return .deny
        }
    }
}

private struct PolicyUncertainWriteTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "uncertain_write",
        description: "Test-only non-replayable tool that can fail after an uncertain side effect.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        throw IntatisError.io("the executor lost its completion acknowledgement")
    }
}

private actor PolicyCancellationGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func runUntilCancelled() async throws -> ToolObservation {
        entered = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return ToolObservation(text: "unexpected completion")
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct PolicyCancellableUncertainWriteTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "cancellable_uncertain_write",
        description: "Test-only non-replayable tool cancelled after its executor boundary.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    let gate: PolicyCancellationGate

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        try await gate.runUntilCancelled()
    }
}

final class AgentLoopPolicyTests: XCTestCase {
    private func makeWorkspaceAndLog(_ suffix: String) throws -> (URL, EventLog) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-policy-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = try EventLog(
            session: SessionID(rawValue: "agent_policy_\(suffix)"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        return (workspace, log)
    }

    private func makeLoop(workspace: URL,
                          log: EventLog,
                          provider: ToolCallingProvider,
                          registry: ToolRegistry = ToolRegistry([]),
                          responder: PermissionResponder = FixedResponder(.allow),
                          context: ContextBuilder = ContextBuilder(),
                          capabilityLease: CapabilityLease? = nil,
                          workspaceLease: WorkspaceLease? = nil,
                          rootTaskID: TaskID? = nil,
                          taskAttempt: Int? = nil,
                          tokenBudgetMeter: AgentTokenBudgetMeter? = nil,
                          agentName: String = "policy-agent") -> AgentLoop {
        AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(
                name: AgentID(rawValue: agentName),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            context: context,
            allowsShell: false,
            includeUsage: tokenBudgetMeter != nil,
            maxIterations: 4,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: taskAttempt,
            tokenBudgetMeter: tokenBudgetMeter)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func toolResults(in log: EventLog) async -> [ToolResultPayload] {
        await log.replay().compactMap { envelope in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
    }

    private func errors(in log: EventLog) async -> [ErrorPayload] {
        await log.replay().compactMap { envelope in
            guard case .error(let payload) = envelope.event else { return nil }
            return payload
        }
    }

    func testReadOnlyWorkspaceLeaseRejectsWriteToolBeforeExecution() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("readonly")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "write",
                    name: "write_file",
                    arguments: json(["path": "blocked.txt", "content": "must not be written"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Write was blocked."), .done(finishReason: "stop")],
        ])
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            workspaceLease: lease)

        let answer = try await loop.send("Attempt a write under a read-only lease.")

        XCTAssertEqual(answer, "Write was blocked.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("blocked.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.observation, "permission denied: workspace lease is read-only")
        let permissionRequests = await log.replay().filter {
            if case .permissionRequest = $0.event { return true }
            return false
        }
        XCTAssertTrue(permissionRequests.isEmpty)
    }

    func testWorkspaceLeaseAllowListAndDeniedPatternsConstrainTouchedPaths() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("paths")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([
                    ToolCall(id: "allowed", name: "write_file", arguments: json([
                        "path": "allowed/ok.txt", "content": "ok",
                    ])),
                    ToolCall(id: "outside", name: "write_file", arguments: json([
                        "path": "outside/no.txt", "content": "outside",
                    ])),
                    ToolCall(id: "denied", name: "write_file", arguments: json([
                        "path": "allowed/private/blocked.txt", "content": "blocked",
                    ])),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Path checks complete."), .done(finishReason: "stop")],
        ])
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: "allowed/**")],
            deniedPatterns: ["allowed/private/**"])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            workspaceLease: lease)

        _ = try await loop.send("Exercise lease path rules.")

        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("allowed/ok.txt"), encoding: .utf8),
            "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("outside/no.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("allowed/private/blocked.txt").path))
        let resultsByID = Dictionary(uniqueKeysWithValues: await toolResults(in: log).map {
            ($0.toolCallId, $0.observation)
        })
        XCTAssertTrue(resultsByID["allowed"]?.hasPrefix("wrote 2 bytes") == true)
        XCTAssertEqual(
            resultsByID["outside"],
            "permission denied: path is outside the workspace lease allow-list: outside/no.txt")
        XCTAssertEqual(
            resultsByID["denied"],
            "permission denied: path is denied by the workspace lease: allowed/private/blocked.txt")
        let executionEvents = await log.replay().filter {
            if case .toolExecutionPrepared = $0.event { return true }
            if case .toolExecutionSettled = $0.event { return true }
            return false
        }
        XCTAssertEqual(executionEvents.count, 2, "only the allowed write reaches the executor boundary")
    }

    func testWorkspaceLeaseRejectsRootReplacementBeforeToolExecution() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("root-identity")
        let parent = workspace.deletingLastPathComponent()
        let moved = parent.appendingPathComponent("\(workspace.lastPathComponent)-moved")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: moved)
        }
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        try FileManager.default.moveItem(at: workspace, to: moved)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "identity-write",
                    name: "write_file",
                    arguments: json(["path": "unexpected.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Blocked."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            workspaceLease: lease)

        _ = try await loop.send("Attempt to use a replaced workspace root.")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("unexpected.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(
            results.first?.observation,
            "permission denied: workspace root changed after the lease was granted; reattach the workspace")
    }

    func testWorkspaceLeaseRejectsRootReplacementWhileAwaitingPermission() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-policy-root-review-\(UUID().uuidString)", isDirectory: true)
        let workspace = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("workspace-reviewed", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let log = try EventLog(
            session: SessionID(rawValue: "agent_policy_root_review"),
            fileURL: parent.appendingPathComponent("events.jsonl"))
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "reviewed-identity-write",
                    name: "write_file",
                    arguments: json(["path": "unexpected.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Blocked after review."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: ReplaceWorkspaceBeforeAllowResponder(
                workspace: workspace,
                movedWorkspace: moved),
            workspaceLease: lease)

        _ = try await loop.send("Approve a write while replacing the workspace root.")

        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("unexpected.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(
            results.first?.observation,
            "permission denied: workspace root changed after the lease was granted; reattach the workspace")
        let prepared = await log.replay().contains { envelope in
            if case .toolExecutionPrepared = envelope.event { return true }
            return false
        }
        XCTAssertFalse(prepared, "root replacement after approval must be rejected before executor prepare")
    }

    func testPermissionAuditFailurePreventsAllowedToolExecution() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("audit-fail-closed")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let logURL = workspace.appendingPathComponent("events.jsonl")
        let provider = PolicyScriptedProvider([[
            .toolCalls([ToolCall(
                id: "write",
                name: "write_file",
                arguments: json(["path": "must-not-exist.txt", "content": "blocked"]))]),
            .done(finishReason: "tool_calls"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: DeleteAuditBeforeAllowResponder(eventLogURL: logURL))

        do {
            _ = try await loop.send("Attempt a write while the permission audit store fails.")
            XCTFail("The loop must fail closed when the allow verdict cannot be persisted.")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
    }

    func testPermissionRequestCarriesExactTaskLeaseAndToolContext() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("review-context")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let responder = CapturingPolicyResponder(.deny)
        let rootTaskID = TaskID(rawValue: "root-context")
        let parentTaskID = TaskID(rawValue: "parent-context")
        let taskID = TaskID(rawValue: "task-context")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            parentTaskID: parentTaskID,
            objective: "Write the scoped file",
            roleHint: "worker",
            expectedDeliverable: "one file")
        let capability = CapabilityLease.worker(taskID: taskID)
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "context-write",
                    name: "write_file",
                    arguments: json(["path": "scoped.txt", "content": "no"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Denied."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder,
            context: ContextBuilder(taskContract: contract),
            capabilityLease: capability,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: 3)

        let answer = try await loop.send("Write it.")
        XCTAssertEqual(answer, "Denied.")
        let capturedRequests = await responder.requests()
        let request = try XCTUnwrap(capturedRequests.first)
        let reviewContext = try XCTUnwrap(request.context)
        XCTAssertEqual(reviewContext.taskID, taskID)
        XCTAssertEqual(reviewContext.rootTaskID, rootTaskID)
        XCTAssertEqual(reviewContext.parentTaskID, parentTaskID)
        XCTAssertEqual(reviewContext.attempt, 3)
        XCTAssertEqual(reviewContext.toolCallID, "context-write")
        XCTAssertEqual(reviewContext.touchedPaths, ["scoped.txt"])
        XCTAssertEqual(reviewContext.sideEffect, .write)
        XCTAssertEqual(reviewContext.capabilityLease, capability)
        XCTAssertEqual(reviewContext.workspaceLease, workspaceLease)
        XCTAssertEqual(reviewContext.taskContract, contract)
        XCTAssertEqual(reviewContext.replayPolicy, ToolExecutionReplayPolicy.requiresManualReconciliation.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("scoped.txt").path))
    }

    func testNonReplayableToolFailureLeavesExecutionUnsettledForManualReconciliation() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("uncertain-side-effect")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-uncertain-side-effect")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Run an uncertain write.",
            roleHint: "worker",
            expectedDeliverable: "result")
        let provider = PolicyScriptedProvider([[
            .toolCalls([ToolCall(
                id: "uncertain-call",
                name: "uncertain_write",
                arguments: "{}")]),
            .done(finishReason: "tool_calls"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyUncertainWriteTool()]),
            context: ContextBuilder(taskContract: contract),
            taskAttempt: 1)

        do {
            _ = try await loop.send("Run it.")
            XCTFail("An uncertain non-replayable failure must stop the task.")
        } catch let error as AgentLoopError {
            guard case .toolExecutionRequiresManualReconciliation(
                tool: "uncertain_write",
                executionID: _,
                reason: _) = error else {
                return XCTFail("Unexpected AgentLoopError: \(error)")
            }
        }

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        let execution = try XCTUnwrap(projection.unresolvedNonReplayableToolExecutions.first)
        XCTAssertEqual(execution.prepared.taskID, taskID)
        XCTAssertEqual(execution.prepared.attempt, 1)
        XCTAssertEqual(execution.prepared.tool, "uncertain_write")
        XCTAssertFalse(events.contains { envelope in
            if case .toolExecutionSettled(let payload) = envelope.event {
                return payload.executionID == execution.id
            }
            return false
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else { return false }
            return payload.toolCallId == "uncertain-call"
                && payload.observation.contains("manual reconciliation required")
        })
    }

    func testCancelledNonReplayableToolLeavesExecutionUnsettledForManualReconciliation() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("cancelled-uncertain-side-effect")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-cancelled-uncertain-side-effect")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Cancel an uncertain write.",
            roleHint: "worker",
            expectedDeliverable: "result")
        let provider = PolicyScriptedProvider([[
            .toolCalls([ToolCall(
                id: "cancelled-uncertain-call",
                name: "cancellable_uncertain_write",
                arguments: "{}")]),
            .done(finishReason: "tool_calls"),
        ]])
        let gate = PolicyCancellationGate()
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyCancellableUncertainWriteTool(gate: gate)]),
            context: ContextBuilder(taskContract: contract),
            taskAttempt: 1)
        let execution = Task { try await loop.send("Run it once.") }
        await gate.waitUntilEntered()

        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("Cancelling an uncertain non-replayable executor must stop the task.")
        } catch is CancellationError {
            // Expected.
        }

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        let unresolved = try XCTUnwrap(projection.unresolvedNonReplayableToolExecutions.first)
        XCTAssertEqual(unresolved.prepared.taskID, taskID)
        XCTAssertEqual(unresolved.prepared.tool, "cancellable_uncertain_write")
        XCTAssertFalse(events.contains { envelope in
            if case .toolExecutionSettled(let payload) = envelope.event {
                return payload.executionID == unresolved.id
            }
            return false
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else { return false }
            return payload.toolCallId == "cancelled-uncertain-call"
                && payload.observation.contains("manual reconciliation required")
        })
    }

    func testSharedSoftTokenBudgetReservesBeforeDispatchAndReportsProviderOverrun() async throws {
        let meter = AgentTokenBudgetMeter(limit: 800)
        let (firstWorkspace, firstLog) = try makeWorkspaceAndLog("budget-first")
        let (secondWorkspace, secondLog) = try makeWorkspaceAndLog("budget-second")
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let firstProvider = PolicyScriptedProvider([[
            .textDelta("first"),
            .usage(Usage(promptTokens: 4, completionTokens: 2, totalTokens: 6)),
            .done(finishReason: "stop"),
        ]])
        let secondProvider = PolicyScriptedProvider([[
            .textDelta("second"),
            // Simulates a provider that ignores the requested output ceiling.
            .usage(Usage(promptTokens: 80, completionTokens: 715, totalTokens: 795)),
            .done(finishReason: "stop"),
        ]])
        let firstLoop = makeLoop(
            workspace: firstWorkspace,
            log: firstLog,
            provider: firstProvider,
            tokenBudgetMeter: meter,
            agentName: "budget-first")
        let secondLoop = makeLoop(
            workspace: secondWorkspace,
            log: secondLog,
            provider: secondProvider,
            tokenBudgetMeter: meter,
            agentName: "budget-second")

        let firstResult = try await firstLoop.send("Spend six tokens.")
        XCTAssertEqual(firstResult, "first")
        let afterFirst = await meter.snapshot()
        XCTAssertEqual(afterFirst.consumed, 6)
        XCTAssertEqual(afterFirst.remaining, 794)
        XCTAssertNotNil(firstProvider.requests.first?.maxOutputTokens)

        do {
            _ = try await secondLoop.send("Simulate a provider that ignores its output ceiling.")
            XCTFail("Expected the explicitly soft budget to report the provider overrun.")
        } catch let error as AgentExecutionBudgetError {
            XCTAssertEqual(error, .exhausted(limit: 800, consumed: 801))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let finalSnapshot = await meter.snapshot()
        XCTAssertEqual(finalSnapshot.consumed, 801)
        XCTAssertEqual(finalSnapshot.remaining, 0)
        let requestedCeiling = try XCTUnwrap(secondProvider.requests.first?.maxOutputTokens)
        XCTAssertLessThan(requestedCeiling, 795)
        let errorPayloads = await errors(in: secondLog)
        XCTAssertEqual(errorPayloads.count, 1)
        XCTAssertEqual(errorPayloads.first?.code, "token_budget_exhausted")
    }

    func testConcurrentTokenReservationsCannotSpendTheSameRemainingBalance() async throws {
        let meter = AgentTokenBudgetMeter(
            limit: 100,
            preferredOutputTokensPerRequest: 40)

        let first = try await meter.reserve(estimatedInputTokens: 10)
        let second = try await meter.reserve(estimatedInputTokens: 10)
        let fullyReserved = await meter.snapshot()
        XCTAssertEqual(fullyReserved.consumed, 0)
        XCTAssertEqual(fullyReserved.reserved, 100)
        XCTAssertEqual(fullyReserved.remaining, 0)

        do {
            _ = try await meter.reserve(estimatedInputTokens: 10)
            XCTFail("A third concurrent request must not reuse the reserved balance.")
        } catch let error as AgentExecutionBudgetError {
            XCTAssertEqual(error, .requestTooLarge(limit: 100, available: 0, estimatedInput: 10))
        }

        try await meter.settle(first, reportedTokens: 45, estimatedTokens: 45)
        try await meter.settle(second, reportedTokens: 45, estimatedTokens: 45)
        let settled = await meter.snapshot()
        XCTAssertEqual(settled.consumed, 90)
        XCTAssertEqual(settled.reserved, 0)
        XCTAssertEqual(settled.remaining, 10)
    }

    func testCancellationAfterNormalProviderEndSettlesReservationExactlyOnce() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("budget-post-stream-cancel")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let state = PolicyStreamEndCancellationState()
        let meter = AgentTokenBudgetMeter(limit: 10_000)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: PolicyStreamEndCancellationProvider(state: state),
            tokenBudgetMeter: meter,
            agentName: "budget-post-stream-cancel")

        let sendTask = Task { () -> String in
            do {
                _ = try await loop.send("Finish the stream, then cancel before accounting.")
                return "unexpected-success"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected-error:\(error.localizedDescription)"
            }
        }

        await state.waitUntilProviderIsReadyToEnd()
        sendTask.cancel()
        await state.finishStream()
        let sendResult = await sendTask.value
        XCTAssertEqual(sendResult, "cancelled")

        let snapshot = await meter.snapshot()
        XCTAssertEqual(snapshot.consumed, 12)
        XCTAssertEqual(snapshot.reserved, 0)
        XCTAssertEqual(snapshot.remaining, 9_988)
        let stats = await log.replay().compactMap { envelope -> TurnStatsPayload? in
            guard case .turnStats(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(stats.last?.totalTokens, 12)
    }

    func testBudgetReconfigurationPreservesOutstandingReservationAcrossDisableAndReenable() async throws {
        let meter = AgentTokenBudgetMeter(
            limit: 100,
            preferredOutputTokensPerRequest: 40)
        let reservation = try await meter.reserve(estimatedInputTokens: 10)

        await meter.reconfigure(tokenBudget: nil, durableConsumed: 0)
        let disabled = await meter.snapshot()
        XCTAssertNil(disabled.limit)
        XCTAssertEqual(disabled.consumed, 0)
        XCTAssertEqual(disabled.reserved, 50)
        XCTAssertNil(disabled.remaining)

        await meter.reconfigure(tokenBudget: 60, durableConsumed: 0)
        let reconfigured = await meter.snapshot()
        XCTAssertEqual(reconfigured.limit, 60)
        XCTAssertEqual(reconfigured.consumed, 0)
        XCTAssertEqual(reconfigured.reserved, 50)
        XCTAssertEqual(reconfigured.remaining, 10)

        do {
            _ = try await meter.reserve(estimatedInputTokens: 10)
            XCTFail("reconfiguration must not make the old reservation disappear")
        } catch let error as AgentExecutionBudgetError {
            XCTAssertEqual(error, .requestTooLarge(limit: 60, available: 10, estimatedInput: 10))
        }

        try await meter.settle(reservation, reportedTokens: 12, estimatedTokens: 12)
        let settled = await meter.snapshot()
        XCTAssertEqual(settled.consumed, 12)
        XCTAssertEqual(settled.reserved, 0)
        XCTAssertEqual(settled.remaining, 48)
    }

    func testDisabledBudgetTracksUsageWithoutProviderOutputCeiling() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("budget-disabled")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let meter = AgentTokenBudgetMeter(limit: nil)
        let provider = PolicyScriptedProvider([[
            .textDelta("unmetered"),
            .done(finishReason: "stop"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            tokenBudgetMeter: meter,
            agentName: "budget-disabled")

        let result = try await loop.send("Run while the budget is disabled.")
        XCTAssertEqual(result, "unmetered")
        XCTAssertNil(provider.requests.first?.maxOutputTokens)
        let snapshot = await meter.snapshot()
        XCTAssertNil(snapshot.limit)
        XCTAssertGreaterThan(snapshot.consumed, 0)
        XCTAssertEqual(snapshot.reserved, 0)
        XCTAssertNil(snapshot.remaining)
    }

    func testMultipleCollaborationToolCallsRunConcurrentlyAndFeedResultsInCallOrder() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("parallel")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ParallelToolProbe()
        let calls = [
            ToolCall(id: "ask-slow", name: "ask_agent", arguments: json([
                "label": "ask-slow", "delayMillis": 100,
            ])),
            ToolCall(id: "delegate-fast", name: "delegate_task", arguments: json([
                "label": "delegate-fast", "delayMillis": 5,
            ])),
            ToolCall(id: "ask-mid", name: "ask_agent", arguments: json([
                "label": "ask-mid", "delayMillis": 60,
            ])),
            ToolCall(id: "delegate-mid", name: "delegate_task", arguments: json([
                "label": "delegate-mid", "delayMillis": 20,
            ])),
        ]
        let provider = PolicyScriptedProvider([
            [.toolCalls(calls), .done(finishReason: "tool_calls")],
            [.textDelta("Combined in order."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([
                PolicyAskAgentTool(probe: probe),
                PolicyDelegateTaskTool(probe: probe),
            ]))

        let result = try await loop.send("Run all collaboration calls.")
        XCTAssertEqual(result, "Combined in order.")

        let snapshot = await probe.snapshot()
        XCTAssertGreaterThan(snapshot.peakActiveCount, 1)
        let requests = provider.requests
        XCTAssertEqual(requests.count, 2)
        let toolMessages = requests[1].messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.compactMap(\.toolCallId), calls.map(\.id))
        XCTAssertEqual(
            toolMessages.compactMap(\.content),
            ["result:ask-slow", "result:delegate-fast", "result:ask-mid", "result:delegate-mid"])
    }
}
