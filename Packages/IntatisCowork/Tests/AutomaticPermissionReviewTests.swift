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
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    var requests: [AgentRequest] {
        lock.withLock { capturedRequests }
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
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

private final class AutoReviewProviderResolutionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let providers: [ToolCallingProvider]
    private var index = 0

    init(_ providers: [ToolCallingProvider]) {
        precondition(!providers.isEmpty)
        self.providers = providers
    }

    var resolutionCount: Int { lock.withLock { index } }

    func next() -> ToolCallingProvider {
        lock.withLock {
            let provider = providers[min(index, providers.count - 1)]
            index += 1
            return provider
        }
    }
}

private actor AutoReviewPendingAllowGate {
    private var started = false
    private var released = false
    private var finished = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    func startAndWaitForRelease() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markFinished() {
        finished = true
        let waiters = finishedWaiters
        finishedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            finishedWaiters.append(continuation)
        }
    }
}

private actor AutoReviewSecondResolutionGate {
    private var resolutionCount = 0
    private var secondResolutionStarted = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseSecondResolution() async {
        resolutionCount += 1
        guard resolutionCount == 2 else { return }
        secondResolutionStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSecondResolutionStarts() async {
        if secondResolutionStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseSecondResolution() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class AutoReviewPendingAllowProvider: ToolCallingProvider, @unchecked Sendable {
    let gate: AutoReviewPendingAllowGate

    init(gate: AutoReviewPendingAllowGate) {
        self.gate = gate
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        let gate = gate
        return AsyncThrowingStream { continuation in
            // Deliberately implementation-owned: consumer cancellation does
            // not stop this producer, exercising retired-generation/quiesce guards.
            Task.detached {
                await gate.startAndWaitForRelease()
                continuation.yield(.textDelta(#"{"decision":"allow","reason":"late allow"}"#))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
                await gate.markFinished()
            }
        }
    }
}

private actor AutoReviewDisableBatchGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct AttachOnlyResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        request.tool == "agent.attach" ? .allow : .deny
    }
}

private struct DenyAllResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        .deny
    }
}

private enum AutoReviewPersistenceError: Error {
    case forcedBatchFailure
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

    private func phaseSBinding() -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: "phase-s-profile"),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: "revision-1")),
            inferenceConnectionID: InferenceConnectionID(rawValue: "phase-s-connection"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-revision-1"),
            modelID: ModelID(rawValue: "phase-s-model"),
            immutableDefinitionFingerprint: "sha256:phase-s-safe-fingerprint")
    }

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
        let reviewerWorkspaceLease = await orch.workspaceLeaseList().first { $0.access == .readOnly }
        let reviewerWorkspaceLeaseID = try XCTUnwrap(reviewerWorkspaceLease?.id)

        let disabled = await orch.disableAutomaticPermissionReview()
        XCTAssertEqual(disabled, .disabled(reviewer))
        let enabledAfterDisable = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(enabledAfterDisable)
        let agentsAfterDisable = await orch.agentList()
        XCTAssertNil(agentsAfterDisable.first { $0.name == reviewer })
        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .workspaceLeaseRevoked(let payload) = envelope.event else { return false }
            return payload.agent == reviewer && payload.leaseID == reviewerWorkspaceLeaseID
        })
        XCTAssertNil(CoworkProjection.build(from: events).workspaceLeases[reviewerWorkspaceLeaseID])
    }

    func testFreshSessionBootstrapsMainThenReviewerWithoutReviewingMainAdmission() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"unused"}"#),
            .done(finishReason: "stop"),
        ])
        let orch = try Orchestrator.runtime(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in reviewerProvider }

        let mainResult = await orch.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertEqual(mainResult, .attached(main))

        let reviewerResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(reviewerResult, .enabled(reviewer))
        XCTAssertTrue(reviewerProvider.requests.isEmpty)

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(Set(projection.agentRoster.keys), Set([main, reviewer]))
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else { return false }
            return payload.tool == "agent.attach" && payload.agent == main
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewRequested(let payload) = envelope.event else { return false }
            return payload.task.tool == "agent.attach" && payload.task.requestingAgent == main
        })
        let mainWorkspaceLeases = projection.workspaceLeaseAgents.filter { $0.value == main }
        let reviewerWorkspaceLeases = projection.workspaceLeaseAgents.filter { $0.value == reviewer }
        XCTAssertEqual(mainWorkspaceLeases.count, 1)
        XCTAssertEqual(reviewerWorkspaceLeases.count, 1)
        XCTAssertEqual(mainWorkspaceLeases.values.first, main)
        XCTAssertEqual(reviewerWorkspaceLeases.values.first, reviewer)
        XCTAssertEqual(
            mainWorkspaceLeases.keys.first.flatMap { projection.workspaceLeases[$0]?.access },
            .readWrite)
        XCTAssertEqual(
            reviewerWorkspaceLeases.keys.first.flatMap { projection.workspaceLeases[$0]?.access },
            .readOnly)
    }

    func testPhaseSFreshBootstrapPersistsSettingsAndBothRegistrationsInOneBatch() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let binding = phaseSBinding()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [
                CoworkSessionWorkspace(
                    path: ws.path,
                    agentName: main.rawValue,
                    isPrimary: true,
                    addedAt: Date(timeIntervalSince1970: 0)),
            ])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings)

        XCTAssertEqual(result, .attached(main))
        XCTAssertTrue(provider.requests.isEmpty, "local registration must not issue a model request")
        let events = try await log.replayChecked()
        XCTAssertEqual(events.count, 7)
        XCTAssertTrue({ if case .sessionSettingsUpdated = events[0].event { return true }; return false }())
        XCTAssertTrue({ if case .workspaceLeaseGranted = events[1].event { return true }; return false }())
        XCTAssertTrue({ if case .capabilityLeaseCreated = events[2].event { return true }; return false }())
        XCTAssertTrue({ if case .agentAttached = events[3].event { return true }; return false }())
        XCTAssertTrue({ if case .workspaceLeaseGranted = events[4].event { return true }; return false }())
        XCTAssertTrue({ if case .capabilityLeaseCreated = events[5].event { return true }; return false }())
        XCTAssertTrue({ if case .agentAttached = events[6].event { return true }; return false }())

        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(Set(projection.agentRoster.keys), Set([main, reviewer]))
        XCTAssertEqual(projection.agentRoster[main]?.agentInferenceBinding, binding)
        XCTAssertEqual(projection.agentRoster[reviewer]?.agentInferenceBinding, binding)
        XCTAssertEqual(projection.agentRoster[reviewer]?.profile, PermissionProfile.readOnly.rawValue)
        let mainCapabilities = projection.capabilityLeaseAgents.compactMap { leaseID, agent in
            agent == main ? projection.capabilityLeases[leaseID] : nil
        }
        XCTAssertEqual(mainCapabilities.count, 1)
        XCTAssertTrue(mainCapabilities[0].tools.contains(.renameSession))
        let reviewerCapabilities = projection.capabilityLeaseAgents.compactMap { leaseID, agent in
            agent == reviewer ? projection.capabilityLeases[leaseID] : nil
        }
        XCTAssertEqual(reviewerCapabilities.count, 1)
        XCTAssertEqual(reviewerCapabilities[0].tools, [])
        let mainWorkspaceID = try XCTUnwrap(projection.workspaceLeaseAgents.first {
            $0.value == main
        }?.key)
        let reviewerWorkspaceID = try XCTUnwrap(projection.workspaceLeaseAgents.first {
            $0.value == reviewer
        }?.key)
        XCTAssertNotEqual(mainWorkspaceID, reviewerWorkspaceID)
        XCTAssertEqual(projection.workspaceLeases[mainWorkspaceID]?.access, .readWrite)
        XCTAssertEqual(projection.workspaceLeases[reviewerWorkspaceID]?.access, .readOnly)
        let automaticReviewEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertTrue(automaticReviewEnabled)

        let document = try SessionProjectionStore.load(
            from: SessionProjectionStore.fileURL(for: log),
            expectedSession: await log.sessionID)
        XCTAssertEqual(document.projectedThroughSeq, 6)
        XCTAssertEqual(document.coworkSettings, settings)
    }

    func testPhaseSFreshBootstrapRejectsPermissionProfileDriftBeforePersistenceOrModelUse() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            defaultPermissionProfile: PermissionProfile.readOnly.rawValue,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings)

        guard case .failed = result else {
            return XCTFail("profile drift must reject the fixed local registration")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let replayed = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSFreshBootstrapBatchFailureLeavesNoGhostState() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in
                AutoReviewCapturingProvider([.done(finishReason: "stop")])
            }
        await orch.setAdmissionEventsAppender { events in
            XCTAssertEqual(events.count, 7)
            throw AutoReviewPersistenceError.forcedBatchFailure
        }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings)

        guard case .failed = result else { return XCTFail("forced batch failure must fail") }
        let replayed = await log.replay()
        let agents = await orch.agentList()
        let workspaceLeases = await orch.workspaceLeaseList()
        let capabilityLeases = await orch.capabilityLeaseList()
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(workspaceLeases.isEmpty)
        XCTAssertTrue(capabilityLeases.isEmpty)
        let automaticReviewEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(automaticReviewEnabled)
    }

    func testPhaseSTwoEventLogInstancesCannotBothBootstrapTheSameFreshSession() async throws {
        let firstLog = try autoReviewTempLog()
        let secondLog = try EventLog(
            session: await firstLog.sessionID,
            fileURL: firstLog.sessionDirectoryURL.appendingPathComponent("events.jsonl"))
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let firstProvider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let secondProvider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let first = Orchestrator(
            log: firstLog,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in firstProvider }
        let second = Orchestrator(
            log: secondLog,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in secondProvider }
        let settings = CoworkSessionSettings(
            sessionID: await firstLog.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        let mainAgent = Agent(
            name: main,
            workspaceRoot: ws,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)

        async let firstResult = first.bootstrapFreshSession(
            main: mainAgent,
            settings: settings)
        async let secondResult = second.bootstrapFreshSession(
            main: mainAgent,
            settings: settings)
        let (resolvedFirst, resolvedSecond) = await (firstResult, secondResult)
        let results = [resolvedFirst, resolvedSecond]

        XCTAssertEqual(results.filter {
            if case .attached = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(results.filter {
            if case .failed = $0 { return true }
            return false
        }.count, 1)
        let durableEvents = try await firstLog.replayChecked()
        XCTAssertEqual(durableEvents.count, 7)
        XCTAssertTrue(firstProvider.requests.isEmpty)
        XCTAssertTrue(secondProvider.requests.isEmpty)
        let firstAgents = await first.agentList()
        let secondAgents = await second.agentList()
        let totalRuntimeAgents = firstAgents.count + secondAgents.count
        XCTAssertEqual(totalRuntimeAgents, 2, "only the winning runtime may register @main and reviewer")
    }

    func testPhaseSHistoricalMainRecoveryUsesCanonicalSettingsWithoutModelReview() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: settings)))
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let agent = Agent(
            name: main,
            workspaceRoot: ws,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)

        let denied = await orch.restoreHistoricalMainAgent(
            agent,
            settings: settings,
            hostAuthorized: false)
        XCTAssertEqual(
            denied,
            .failed("Historical @main recovery requires explicit host authorization."))
        let deniedEvents = try await log.replayChecked()
        XCTAssertEqual(deniedEvents.count, 1)

        let recovered = await orch.restoreHistoricalMainAgent(
            agent,
            settings: settings,
            hostAuthorized: true)

        XCTAssertEqual(recovered, .attached(main))
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        XCTAssertEqual(events.count, 4)
        XCTAssertFalse(events.contains {
            if case .permissionRequest = $0.event { return true }
            if case .permissionReviewRequested = $0.event { return true }
            return false
        })
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.agentRoster[main]?.agentInferenceBinding, binding)
        XCTAssertEqual(projection.workspaceLeaseAgents.values.filter { $0 == main }.count, 1)
        XCTAssertEqual(projection.capabilityLeaseAgents.values.filter { $0 == main }.count, 1)
        let repeated = await orch.restoreHistoricalMainAgent(
            agent,
            settings: settings,
            hostAuthorized: true)
        XCTAssertEqual(repeated, .alreadyAttached(main))
    }

    func testPhaseSHistoricalMainRecoveryCASRejectsInvalidSettingsRevisionChain() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: settings)))

        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let resolutionGate = AutoReviewSecondResolutionGate()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder(),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                await resolutionGate.pauseSecondResolution()
                guard let resolvedBinding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: resolvedBinding,
                    model: agent.model,
                    provider: provider)
            },
            providerFor: { _ in provider })
        let mainAgent = Agent(
            name: main,
            workspaceRoot: ws,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)

        let restoreTask = Task {
            await orch.restoreHistoricalMainAgent(
                mainAgent,
                settings: settings,
                hostAuthorized: true)
        }
        await resolutionGate.waitUntilSecondResolutionStarts()
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 3,
            previousRevision: 1,
            changeKind: .updated,
            kind: .cowork,
            cowork: settings)))
        await resolutionGate.releaseSecondResolution()

        let result = await restoreTask.value
        guard case .failed = result else {
            return XCTFail("invalid settings history must fail the final recovery CAS")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let replayed = try await log.replayChecked()
        XCTAssertEqual(replayed.count, 2)
        XCTAssertFalse(replayed.contains {
            switch $0.event {
            case .workspaceLeaseGranted, .capabilityLeaseCreated, .agentAttached:
                return true
            default:
                return false
            }
        })
        let agents = await orch.agentList()
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSHistoricalMainRecoveryRejectsPermissionProfileDrift() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let canonical = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: canonical)))
        var drifted = canonical
        drifted.defaultPermissionProfile = PermissionProfile.readOnly.rawValue
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }

        let result = await orch.restoreHistoricalMainAgent(
            Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: drifted,
            hostAuthorized: true)

        guard case .failed = result else {
            return XCTFail("historical profile drift must fail closed")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let replayed = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertEqual(replayed.count, 1)
        XCTAssertTrue(agents.isEmpty)
    }

    func testMainBootstrapFailsClosedForNonemptySession() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try await log.append(.error(ErrorPayload(code: "existing", message: "existing session state")))
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in
                AutoReviewScriptedProvider([[.done(finishReason: "stop")]])
            }

        let result = await orch.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        guard case .failed(let message) = result else {
            return XCTFail("nonempty sessions must not use the bootstrap bypass")
        }
        XCTAssertTrue(message.contains("empty Cowork session"))
        let agents = await orch.agentList()
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertTrue(agents.isEmpty)
        XCTAssertNil(projection.agentRoster[main])
    }

    func testMainBootstrapTreatsUnknownStateAsNonemptyAndKnownCorruptionAsFailure() async throws {
        let encoder = Envelope.makeEncoder()
        let session = SessionID(rawValue: "auto_review")
        let valid = try encoder.encode(Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .error(ErrorPayload(code: "existing", message: "state"))))
        var unknownObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        unknownObject["type"] = "future_security_state"
        var corruptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var corruptPayload = try XCTUnwrap(corruptObject["payload"] as? [String: Any])
        corruptPayload.removeValue(forKey: "message")
        corruptObject["payload"] = corruptPayload
        let variants: [(suffix: String, line: Data, expected: String)] = [
            ("unknown", try JSONSerialization.data(withJSONObject: unknownObject), "empty Cowork session"),
            ("corrupt-known", try JSONSerialization.data(withJSONObject: corruptObject), "could not verify"),
        ]

        for variant in variants {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-bootstrap-\(variant.suffix)-\(UUID().uuidString)",
                    isDirectory: true)
            let url = directory.appendingPathComponent("events.jsonl")
            let ws = try autoReviewWorkspace()
            defer {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: ws)
            }
            let log = try EventLog(session: session, fileURL: url)
            var line = variant.line
            line.append(0x0A)
            try line.write(to: url, options: .atomic)
            let orch = Orchestrator(
                log: log,
                allowsShell: true,
                responder: DenyAllResponder()) { _ in
                    AutoReviewScriptedProvider([[.done(finishReason: "stop")]])
                }

            let result = await orch.bootstrapMainAgent(Agent(
                name: main,
                workspaceRoot: ws,
                model: ModelID(rawValue: "main-model"),
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth))

            guard case .failed(let message) = result else {
                return XCTFail("bootstrap must fail closed for \(variant.suffix) log state")
            }
            XCTAssertTrue(message.contains(variant.expected), message)
            let agents = await orch.agentList()
            XCTAssertTrue(agents.isEmpty)
        }
    }

    func testMainBootstrapPersistenceFailureLeavesNoGhostAgentOrLease() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in
                AutoReviewScriptedProvider([[.done(finishReason: "stop")]])
            }
        let mainID = main
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .agentAttached(let payload) = event else { return false }
                return payload.agent == mainID
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let result = await orch.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        guard case .failed = result else {
            return XCTFail("bootstrap must fail when its atomic admission batch fails")
        }
        let agents = await orch.agentList()
        let workspaceLeases = await orch.workspaceLeaseList()
        let capabilityLeases = await orch.capabilityLeaseList()
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(workspaceLeases.isEmpty)
        XCTAssertTrue(capabilityLeases.isEmpty)
        XCTAssertNil(projection.agentRoster[main])
    }

    func testRestoreRevokesStaleReviewerIdentityAndLeasesBeforeReenable() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"ok"}"#),
            .done(finishReason: "stop"),
        ])
        let first = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        let firstEnableResult = await first.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(firstEnableResult, .enabled(reviewer))
        let firstCapabilityLeases = await first.capabilityLeaseList()
        let firstWorkspaceLeases = await first.workspaceLeaseList()
        let oldCapabilityLease = try XCTUnwrap(
            firstCapabilityLeases.first { $0.tools.isEmpty })
        let oldWorkspaceLease = try XCTUnwrap(
            firstWorkspaceLeases.first { $0.access == .readOnly })
        await first.cancelAll(reason: "simulate session close")

        let replacement = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        let beforeRestore = CoworkProjection.build(from: await log.replay())
        XCTAssertNotNil(beforeRestore.agentRoster[reviewer])
        await replacement.restore(from: beforeRestore)

        let afterRestore = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(afterRestore.agentRoster[reviewer])
        XCTAssertNil(afterRestore.capabilityLeases[oldCapabilityLease.id])
        XCTAssertNil(afterRestore.workspaceLeases[oldWorkspaceLease.id])
        let replacementEnableResult = await replacement.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(replacementEnableResult, .enabled(reviewer))
        let afterReenable = CoworkProjection.build(from: await log.replay())
        let activeReviewerCapabilityLeases = afterReenable.capabilityLeaseAgents.filter {
            $0.value == reviewer
        }
        let activeReviewerWorkspaceLeases = afterReenable.workspaceLeaseAgents.filter {
            $0.value == reviewer
        }
        XCTAssertEqual(activeReviewerCapabilityLeases.count, 1)
        XCTAssertEqual(activeReviewerWorkspaceLeases.count, 1)
    }

    func testEnableAdmissionBatchFailureLeavesNoGhostReviewerLease() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"ok"}"#),
            .done(finishReason: "stop"),
        ])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .agentAttached(let payload) = event else { return false }
                return payload.agent == Orchestrator.automaticPermissionReviewerID
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let result = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)

        guard case .failed = result else {
            return XCTFail("reviewer enable must fail when its atomic admission batch fails")
        }
        let enabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(enabled)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(projection.agentRoster[reviewer])
        XCTAssertFalse(projection.capabilityLeaseAgents.values.contains(reviewer))
        XCTAssertFalse(projection.workspaceLeaseAgents.values.contains(reviewer))
    }

    func testDisableBatchFailureLeavesReviewerHealthyAndDurablyAttached() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"ok"}"#),
            .done(finishReason: "stop"),
        ])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))
        let capabilityLeases = await orch.capabilityLeaseList()
        let workspaceLeases = await orch.workspaceLeaseList()
        let reviewerCapabilityLease = try XCTUnwrap(
            capabilityLeases.first { $0.tools.isEmpty })
        let reviewerWorkspaceLease = try XCTUnwrap(
            workspaceLeases.first { $0.access == .readOnly })
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .agentDetached = event { return true }
                return false
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let disabled = await orch.disableAutomaticPermissionReview()
        let stillEnabled = await orch.automaticPermissionReviewEnabled()
        let health = await orch.automaticPermissionReviewHealth()
        let agents = await orch.agentList()
        let retainedCapabilityLease = await orch.capabilityLease(id: reviewerCapabilityLease.id)
        let retainedWorkspaceLease = await orch.workspaceLease(id: reviewerWorkspaceLease.id)
        guard case .failed(let disableMessage) = disabled else {
            return XCTFail("disable persistence failure must be distinguishable from already disabled")
        }
        XCTAssertTrue(disableMessage.contains("remains enabled"))
        XCTAssertTrue(stillEnabled)
        XCTAssertEqual(health, .healthy)
        XCTAssertNotNil(agents.first { $0.name == reviewer })
        XCTAssertNotNil(retainedCapabilityLease)
        XCTAssertNotNil(retainedWorkspaceLease)
        let events = await log.replay()
        XCTAssertFalse(events.contains { envelope in
            if case .capabilityLeaseRevoked(let payload) = envelope.event {
                return payload.agent == reviewer
            }
            if case .workspaceLeaseRevoked(let payload) = envelope.event {
                return payload.agent == reviewer
            }
            if case .agentDetached(let payload) = envelope.event {
                return payload.agent == reviewer
            }
            return false
        })
        let projection = CoworkProjection.build(from: events)
        XCTAssertNotNil(projection.agentRoster[reviewer])
        XCTAssertNotNil(projection.capabilityLeases[reviewerCapabilityLease.id])
        XCTAssertNotNil(projection.workspaceLeases[reviewerWorkspaceLease.id])
    }

    func testFailedDisableResumesWithFreshGenerationWhileRetiredAllowArrivesLate() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let preflightProvider = AutoReviewCapturingProvider([
            .done(finishReason: "stop"),
        ])
        let lateGate = AutoReviewPendingAllowGate()
        let lateProvider = AutoReviewPendingAllowProvider(gate: lateGate)
        let recoveredProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"fresh review after failed disable"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerProviders = AutoReviewProviderResolutionSequence([
            preflightProvider,
            lateProvider,
            recoveredProvider,
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProviders.next() }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let firstWorker = AgentID(rawValue: "worker-before-resume")
        let firstAttach = Task {
            await orch.attach(Agent(
                name: firstWorker,
                workspaceRoot: ws,
                model: ModelID(rawValue: "worker-model"),
                profile: .reviewed,
                coordinationDepth: 0))
        }
        await lateGate.waitUntilStarted()
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .agentDetached(let payload) = event else { return false }
                return payload.agent == reviewerID
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let disableResult = await orch.disableAutomaticPermissionReview()
        let firstAttached = await firstAttach.value
        guard case .failed(let message) = disableResult else {
            return XCTFail("failed reviewer detach must roll quiesce back")
        }
        XCTAssertTrue(message.contains("remains enabled"))
        XCTAssertFalse(firstAttached)
        let stillEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertTrue(stillEnabled)

        let secondWorker = AgentID(rawValue: "worker-after-resume")
        let secondAttached = await orch.attach(Agent(
            name: secondWorker,
            workspaceRoot: ws,
            model: ModelID(rawValue: "worker-model"),
            profile: .reviewed,
            coordinationDepth: 0))
        XCTAssertTrue(secondAttached)
        XCTAssertEqual(reviewerProviders.resolutionCount, 3)
        XCTAssertTrue(preflightProvider.requests.isEmpty)
        XCTAssertEqual(recoveredProvider.requests.count, 1)
        let recoveredHealth = await orch.automaticPermissionReviewHealth()
        XCTAssertEqual(recoveredHealth, .healthy)
        let eventsBeforeLateAllow = await log.replay()
        let settlementsBeforeLateAllow = eventsBeforeLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlementsBeforeLateAllow.map(\.status), [.cancelled, .allowed])
        let rosterBeforeLateAllow = CoworkProjection.build(from: eventsBeforeLateAllow).agentRoster
        XCTAssertNil(rosterBeforeLateAllow[firstWorker])
        XCTAssertNotNil(rosterBeforeLateAllow[secondWorker])

        await lateGate.release()
        await lateGate.waitUntilFinished()
        let eventsAfterLateAllow = await log.replay()
        let settlementsAfterLateAllow = eventsAfterLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlementsAfterLateAllow, settlementsBeforeLateAllow)
        let rosterAfterLateAllow = CoworkProjection.build(from: eventsAfterLateAllow).agentRoster
        XCTAssertNil(rosterAfterLateAllow[firstWorker])
        XCTAssertNotNil(rosterAfterLateAllow[secondWorker])
    }

    func testDisableQuiescesPendingAllowBeforeDurableDetach() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let allowGate = AutoReviewPendingAllowGate()
        let reviewerProvider = AutoReviewPendingAllowProvider(gate: allowGate)
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let attachTask = Task {
            await orch.attach(Agent(
                name: main,
                workspaceRoot: ws,
                model: ModelID(rawValue: "main-model"),
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth))
        }
        await allowGate.waitUntilStarted()

        let batchGate = AutoReviewDisableBatchGate()
        await orch.setAdmissionEventsAppender { events in
            await batchGate.pause()
            try await log.append(events)
        }
        let disableTask = Task { await orch.disableAutomaticPermissionReview() }
        await batchGate.waitUntilEntered()

        // The quiescence barrier has drained the permission job. Commit the
        // detach, then let the implementation-owned producer emit its late
        // `allow`; it must no longer be able to authorize the attach.
        await batchGate.release()
        let disabled = await disableTask.value
        await allowGate.release()
        await allowGate.waitUntilFinished()
        let attached = await attachTask.value

        XCTAssertEqual(disabled, .disabled(reviewer))
        XCTAssertFalse(attached)
        let events = await log.replay()
        let reviewerDetachSeq = try XCTUnwrap(events.first { envelope in
            guard case .agentDetached(let payload) = envelope.event else { return false }
            return payload.agent == reviewer
        }?.seq)
        XCTAssertFalse(events.contains { envelope in
            guard envelope.seq >= reviewerDetachSeq,
                  case .permissionReviewSettled(let payload) = envelope.event else { return false }
            return payload.decision == .allow
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else { return false }
            return payload.tool == "agent.attach" && payload.decision == .allow
        })
        let projection = CoworkProjection.build(from: events)
        XCTAssertNil(projection.agentRoster[reviewer])
        XCTAssertNil(projection.agentRoster[main])
    }

    func testCallerCancellationCannotAttachAfterLateReviewerAllow() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let allowGate = AutoReviewPendingAllowGate()
        let reviewerProvider = AutoReviewPendingAllowProvider(gate: allowGate)
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let worker = AgentID(rawValue: "worker-cancelled-before-late-allow")
        let attachTask = Task {
            await orch.attach(Agent(
                name: worker,
                workspaceRoot: ws,
                model: ModelID(rawValue: "worker-model"),
                profile: .reviewed,
                coordinationDepth: 0))
        }
        await allowGate.waitUntilStarted()

        attachTask.cancel()
        await allowGate.release()
        await allowGate.waitUntilFinished()
        let attached = await attachTask.value

        XCTAssertFalse(attached)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertNil(projection.agentRoster[worker])
        let settlements = events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlements.last?.status, .cancelled)
        XCTAssertEqual(settlements.last?.decision, .deny)
        let attachDecisions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "agent.attach" else { return nil }
            return payload
        }
        XCTAssertEqual(attachDecisions.last?.decision, .deny)
    }

    func testCallerCancellationDuringPostReviewInferenceResolutionCannotCommitAttach() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let resolutionGate = AutoReviewSecondResolutionGate()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder(),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                await resolutionGate.pauseSecondResolution()
                guard let resolvedBinding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: resolvedBinding,
                    model: agent.model,
                    provider: provider)
            },
            providerFor: { _ in provider })
        let worker = AgentID(rawValue: "worker-cancelled-during-post-review-resolution")
        let attachTask = Task {
            await orch.attach(Agent(
                name: worker,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: 0))
        }
        await resolutionGate.waitUntilSecondResolutionStarts()

        attachTask.cancel()
        await resolutionGate.releaseSecondResolution()
        let attached = await attachTask.value

        XCTAssertFalse(attached)
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        let projection = CoworkProjection.build(from: events)
        XCTAssertNil(projection.agentRoster[worker])
        XCTAssertFalse(events.contains { envelope in
            if case .workspaceLeaseGranted(let payload) = envelope.event {
                return payload.agent == worker
            }
            if case .capabilityLeaseCreated(let payload) = envelope.event {
                return payload.agent == worker
            }
            if case .agentAttached(let payload) = envelope.event {
                return payload.agent == worker
            }
            return false
        })
        let attachDecisions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "agent.attach" else { return nil }
            return payload
        }
        XCTAssertEqual(attachDecisions.last?.decision, .deny)
        XCTAssertEqual(attachDecisions.last?.source, .callerCancellation)
        XCTAssertEqual(attachDecisions.last?.reviewStatus, .cancelled)
        XCTAssertEqual(attachDecisions.last?.failureKind, .callerCancelled)
    }

    func testAttachRejectsWorkspaceRootReplacedWhileReviewIsPending() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        let moved = ws.deletingLastPathComponent()
            .appendingPathComponent("\(ws.lastPathComponent)-reviewed")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: moved)
        }
        let allowGate = AutoReviewPendingAllowGate()
        let reviewerProvider = AutoReviewPendingAllowProvider(gate: allowGate)
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let attachTask = Task {
            await orch.attach(Agent(
                name: main,
                workspaceRoot: ws,
                model: ModelID(rawValue: "main-model"),
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth))
        }
        await allowGate.waitUntilStarted()
        try FileManager.default.moveItem(at: ws, to: moved)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        await allowGate.release()

        let attached = await attachTask.value
        let agents = await orch.agentList()
        XCTAssertFalse(attached)
        XCTAssertNil(agents.first { $0.name == main })
        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else { return false }
            return payload.tool == "agent.attach"
                && payload.decision == .deny
                && payload.reason.contains("identity changed")
        })
    }

    func testReviewerCanApproveMainAttachBeforeMainExists() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","risk":"low","reason":"workspace attach matches session root"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: DenyAllResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return AutoReviewScriptedProvider([[.textDelta("unused"), .done(finishReason: "stop")]])
        }

        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let attached = await orch.attach(Agent(name: main,
                                               workspaceRoot: ws,
                                               model: ModelID(rawValue: "main-model"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        let prompt = try XCTUnwrap(reviewerProvider.requests.first?.messages.compactMap(\.content).joined(separator: "\n"))
        XCTAssertTrue(prompt.contains("tool: agent.attach"))
        XCTAssertTrue(prompt.contains("requesting_agent: @main"))
        XCTAssertTrue(prompt.contains("Directly related causal events:"))

        let reviews = await log.replay().compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.tool, "agent.attach")
        XCTAssertEqual(reviews.last?.decision, .allow)
    }

    func testReviewerSeesFrozenWorkerAttachContractAndCommittedLeasesMatch() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","risk":"medium","reason":"reviewed worker admission"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: DenyAllResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return AutoReviewScriptedProvider([[.textDelta("unused"), .done(finishReason: "stop")]])
        }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let workerID = AgentID(rawValue: "worker-admission")
        let attached = await orch.attach(Agent(
            name: workerID,
            workspaceRoot: ws,
            model: ModelID(rawValue: "worker-model"),
            profile: .reviewed,
            coordinationDepth: 0))

        XCTAssertTrue(attached)
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        let events = await log.replay()
        let reviewTask = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewTask? in
            guard case .permissionReviewRequested(let payload) = envelope.event,
                  payload.task.requestingAgent == workerID,
                  payload.task.tool == "agent.attach" else { return nil }
            return payload.task
        }.first)
        let taskID = try XCTUnwrap(reviewTask.taskID)
        let proposedCapability = try XCTUnwrap(reviewTask.capabilityLease)
        let proposedWorkspace = try XCTUnwrap(reviewTask.workspaceLease)
        let contract = try XCTUnwrap(reviewTask.taskContract)

        XCTAssertEqual(reviewTask.rootTaskID, taskID)
        XCTAssertNil(reviewTask.parentTaskID)
        XCTAssertEqual(reviewTask.attempt, 1)
        XCTAssertEqual(reviewTask.causalContext.taskLineage, [taskID])
        XCTAssertEqual(contract.id, taskID)
        XCTAssertEqual(contract.kind, .agentAdmission)
        XCTAssertEqual(contract.assignee, workerID)
        XCTAssertEqual(contract.workspaceID, proposedWorkspace.workspaceID)
        XCTAssertEqual(contract.workspaceLeaseID, proposedWorkspace.id)
        XCTAssertEqual(contract.capabilityLeaseID, proposedCapability.id)
        XCTAssertEqual(proposedWorkspace.access, .readWrite)
        XCTAssertFalse(proposedCapability.tools.contains(.delegateTask))
        XCTAssertFalse(proposedCapability.tools.contains(.attachWorkspace))
        XCTAssertEqual(proposedCapability.delegation, .requestOnly)

        let authorization = try XCTUnwrap(reviewTask.authorization)
        XCTAssertEqual(
            reviewTask.normalizedArgs,
            "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)")
        XCTAssertEqual(reviewTask.intent?.metadata["canCoordinate"], .bool(false))
        XCTAssertEqual(authorization.taskID, taskID)
        XCTAssertEqual(authorization.capabilityLeaseID, proposedCapability.id)
        XCTAssertEqual(authorization.workspaceLeaseID, proposedWorkspace.id)

        let committedCapability = try XCTUnwrap(events.compactMap { envelope -> CapabilityLease? in
            guard case .capabilityLeaseCreated(let payload) = envelope.event,
                  payload.agent == workerID else { return nil }
            return payload.lease
        }.last)
        let committedWorkspace = try XCTUnwrap(events.compactMap { envelope -> WorkspaceLease? in
            guard case .workspaceLeaseGranted(let payload) = envelope.event,
                  payload.agent == workerID else { return nil }
            return payload.lease
        }.last)
        XCTAssertEqual(committedCapability, proposedCapability)
        XCTAssertEqual(committedWorkspace, proposedWorkspace)
        let attachedMetadata = try XCTUnwrap(events.compactMap { envelope -> CoworkEventMetadata? in
            guard case .agentAttached(let payload) = envelope.event,
                  payload.agent == workerID else { return nil }
            return payload.metadata
        }.last)
        XCTAssertEqual(attachedMetadata.taskID, taskID)
        XCTAssertEqual(attachedMetadata.rootTaskID, taskID)
        XCTAssertEqual(attachedMetadata.workspaceLeaseID, proposedWorkspace.id)
        XCTAssertEqual(attachedMetadata.capabilityLeaseID, proposedCapability.id)

        let prompt = try XCTUnwrap(
            reviewerProvider.requests.first?.messages.compactMap(\.content).joined(separator: "\n"))
        XCTAssertTrue(prompt.contains("task_id: \(taskID.rawValue)"))
        XCTAssertTrue(prompt.contains("root_task_id: \(taskID.rawValue)"))
        XCTAssertTrue(prompt.contains("kind=agent_admission"))
        XCTAssertTrue(prompt.contains("capability_lease: id=\(proposedCapability.id.rawValue)"))
        XCTAssertTrue(prompt.contains("workspace_lease: id=\(proposedWorkspace.id.rawValue)"))
        XCTAssertTrue(prompt.contains("canCoordinate=false"))
    }

    func testSpawnToolUsesOneAutomaticReviewAndCommitsCoordinatorAdmissionAtomically() async throws {
        let log = try autoReviewTempLog()
        let mainWorkspace = try autoReviewWorkspace()
        let childWorkspace = mainWorkspace.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mainWorkspace) }
        let spawnArgs = String(decoding: try JSONSerialization.data(withJSONObject: [
            "name": "coordinator-admission",
            "path": childWorkspace.path,
            "model": "child-model",
            "canCoordinate": true,
        ], options: [.sortedKeys]), as: UTF8.self)
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "spawn-once", name: "spawn_agent", arguments: spawnArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("coordinator created"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","risk":"medium","reason":"bounded coordinator spawn"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: mainWorkspace)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let sent = await orch.send("create one coordinator for child", to: main)
        XCTAssertEqual(sent, .sent)

        let childID = AgentID(rawValue: "coordinator-admission")
        let events = await log.replay()
        let reviewTasks = events.compactMap { envelope -> PermissionReviewTask? in
            guard case .permissionReviewRequested(let payload) = envelope.event else { return nil }
            return payload.task
        }
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        XCTAssertEqual(reviewTasks.filter { $0.tool == "spawn_agent" }.count, 1)
        XCTAssertFalse(reviewTasks.contains { $0.tool == "agent.attach" && $0.requestingAgent == childID })
        let spawnReview = try XCTUnwrap(reviewTasks.first { $0.tool == "spawn_agent" })
        XCTAssertEqual(spawnReview.requestingAgent, main)
        let spawnAuthorization = try XCTUnwrap(spawnReview.authorization)
        XCTAssertEqual(
            spawnReview.normalizedArgs,
            "digest=\(spawnAuthorization.normalizedArgumentsDigest); characters=\(spawnAuthorization.normalizedArgumentsCharacterCount)")
        XCTAssertTrue(spawnReview.touchedPaths.isEmpty)
        XCTAssertEqual(spawnReview.intent?.action, "agent.spawn")
        XCTAssertEqual(spawnReview.intent?.dataEffects, [.none])
        XCTAssertEqual(
            spawnReview.intent?.controlEffects,
            [.createAgent, .attachWorkspace, .grantCapability])
        XCTAssertEqual(spawnReview.intent?.metadata["canCoordinate"], .bool(true))
        XCTAssertEqual(spawnReview.intent?.metadata["requestedAccess"],
                       .string(WorkspaceAccess.readOnly.rawValue))

        let committedCapability = try XCTUnwrap(events.compactMap { envelope -> CapabilityLease? in
            guard case .capabilityLeaseCreated(let payload) = envelope.event,
                  payload.agent == childID else { return nil }
            return payload.lease
        }.last)
        let committedWorkspace = try XCTUnwrap(events.compactMap { envelope -> WorkspaceLease? in
            guard case .workspaceLeaseGranted(let payload) = envelope.event,
                  payload.agent == childID else { return nil }
            return payload.lease
        }.last)
        XCTAssertEqual(committedWorkspace.rootPath, childWorkspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(committedWorkspace.access, .readOnly)
        XCTAssertTrue(committedCapability.tools.contains(.delegateTask))
        XCTAssertTrue(committedCapability.tools.contains(.attachWorkspace))
        XCTAssertFalse(committedCapability.tools.contains(.applyPatch))
        if case .granted(let budget) = committedCapability.delegation {
            XCTAssertEqual(budget.maxDepth, 0)
        } else {
            XCTFail("committed coordinator lease must include delegation")
        }
        XCTAssertTrue(events.contains {
            guard case .agentSpawned(let payload) = $0.event else { return false }
            return payload.agent == childID && payload.requestedBy == main
        })
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
        XCTAssertEqual(reviewRequest.maxOutputTokens, 1_024)
        let prompt = reviewRequest.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Active agent roster:"))
        XCTAssertTrue(prompt.contains("@main"))
        XCTAssertTrue(prompt.contains("Directly related causal events:"))
        XCTAssertTrue(prompt.contains("create auto.txt with approved"))
        XCTAssertTrue(prompt.contains("write_file"))
        XCTAssertTrue(prompt.contains("membership=granted"))
        XCTAssertTrue(prompt.contains("canonical_permission=filesystem.edit"))
        XCTAssertFalse(prompt.contains("required_capabilities=[apply_patch]"))
        XCTAssertFalse(prompt.contains("lease-inconsistent"))

        let events = await log.replay()
        let reviews = events.compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.decision, .allow)
        XCTAssertEqual(reviews.last?.reviewerModel, "@permission-reviewer:reviewer-model")
        let requested = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewTask? in
            if case .permissionReviewRequested(let payload) = envelope.event { return payload.task }
            return nil
        }.last)
        let settled = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.last)
        let resolved = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "write_file",
               payload.requestId != nil { return payload }
            return nil
        }.last)
        let prepared = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            if case .toolExecutionPrepared(let payload) = envelope.event,
               payload.tool == "write_file" { return payload }
            return nil
        }.last)
        let executionSettled = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            if case .toolExecutionSettled(let payload) = envelope.event,
               payload.tool == "write_file" { return payload }
            return nil
        }.last)
        let authorization = try XCTUnwrap(requested.authorization)
        XCTAssertEqual(authorization.membership, .granted)
        XCTAssertEqual(authorization.requiredCapabilities, [.applyPatch])
        XCTAssertEqual(authorization.canonicalAction, "filesystem.write")
        XCTAssertEqual(authorization.deterministicGate?.decision, .pass)
        XCTAssertEqual(settled.authorization, authorization)
        XCTAssertEqual(resolved.authorization, authorization)
        XCTAssertEqual(prepared.authorization, authorization)
        XCTAssertEqual(executionSettled.authorization, authorization)
        XCTAssertEqual(resolved.source, .automaticReviewer)
        XCTAssertEqual(resolved.reviewTaskID, requested.id)
        XCTAssertEqual(resolved.reviewStatus, .allowed)
    }

    func testTimedOutReviewDeniesOnlyItsToolAndFreshGenerationCanExecuteNextTool() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "write-timed-out-generation",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "timed-out.txt",
                    content: "must not be written"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("first write was denied"), .done(finishReason: "stop")],
            [.toolCalls([ToolCall(
                id: "write-fresh-generation",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "fresh.txt",
                    content: "fresh generation approved"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("second write completed"), .done(finishReason: "stop")],
        ])
        let lateGate = AutoReviewPendingAllowGate()
        let lateProvider = AutoReviewPendingAllowProvider(gate: lateGate)
        let preflightProvider = AutoReviewCapturingProvider([
            .done(finishReason: "stop"),
        ])
        let recoveredProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"fresh generation matches the second request"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerProviders = AutoReviewProviderResolutionSequence([
            preflightProvider,
            lateProvider,
            recoveredProvider,
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProviders.next() }
                return mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws,
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 0.03,
                tokenBudget: 50_000,
                reservedCompletionTokens: 64,
                maxRecentEvents: 12))
        XCTAssertEqual(enabled, .enabled(reviewer))

        let first = await orch.send("write timed-out.txt", to: main)
        let firstPath = ws.appendingPathComponent("timed-out.txt")
        guard case .failed(let firstFailure) = first else {
            return XCTFail("the invocation whose required write timed out must fail")
        }
        XCTAssertTrue(firstFailure.contains("required side effects remain denied or failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))

        let second = await orch.send("write fresh.txt", to: main)
        let secondPath = ws.appendingPathComponent("fresh.txt")
        XCTAssertEqual(second, .sent)
        XCTAssertEqual(
            try String(contentsOf: secondPath, encoding: .utf8),
            "fresh generation approved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))
        XCTAssertEqual(reviewerProviders.resolutionCount, 3)
        XCTAssertTrue(preflightProvider.requests.isEmpty)
        XCTAssertEqual(recoveredProvider.requests.count, 1)

        let eventsBeforeLateAllow = await log.replay()
        let reviewSettlements = eventsBeforeLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(reviewSettlements.map(\.status), [.timedOut, .allowed])
        XCTAssertEqual(reviewSettlements.map(\.decision), [.deny, .allow])
        let permissionDecisions = eventsBeforeLateAllow.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "write_file" else { return nil }
            return payload
        }
        XCTAssertEqual(permissionDecisions.map(\.decision), [.deny, .allow])
        let executionSettlements = eventsBeforeLateAllow.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertFalse(executionSettlements.contains {
            $0.toolCallID == "write-timed-out-generation" && $0.outcome == .succeeded
        })
        XCTAssertEqual(executionSettlements.filter {
            $0.toolCallID == "write-fresh-generation" && $0.outcome == .succeeded
        }.count, 1)

        await lateGate.release()
        await lateGate.waitUntilFinished()
        let eventsAfterLateAllow = await log.replay()
        let settlementsAfterLateAllow = eventsAfterLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlementsAfterLateAllow, reviewSettlements)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))
    }

    func testCancellingActiveTasksKeepsAutomaticReviewerAvailableForNextRequest() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "write-after-cancel",
                name: "write_file",
                arguments: autoReviewWriteArgs(path: "after-cancel.txt", content: "reviewed"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("done"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"allow","reason":"next request remains reviewable"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProvider }
                return mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enabled, .enabled(reviewer))

        await orch.cancelActiveTasks(reason: "cancelled by user")

        let stillEnabled = await orch.automaticPermissionReviewEnabled()
        let health = await orch.automaticPermissionReviewHealth()
        let sent = await orch.send("write after-cancel.txt", to: main)
        XCTAssertTrue(stillEnabled)
        XCTAssertEqual(health, .healthy)
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent("after-cancel.txt"),
                encoding: .utf8),
            "reviewed")
        XCTAssertEqual(reviewerProvider.requests.count, 1)
    }

    func testReviewerAskUserIsNormalizedToAutomaticDenyWithoutFallback() async throws {
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
        guard case .failed(let failure) = sendResult else {
            return XCTFail("a denied required write must fail the invocation")
        }
        XCTAssertTrue(failure.contains("required side effects remain denied or failed"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("fallback.txt").path))
        let reviews = await log.replay().compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.decision, .deny)
    }

    func testReviewerDenyReasonIsPreservedAndDeniedWriteCannotCompleteInvocation() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let exactReason = "requested overwrite is outside the assigned deliverable"
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "denied-write",
                name: "write_file",
                arguments: autoReviewWriteArgs(path: "denied.txt", content: "not allowed"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Created denied.txt successfully."), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(#"{"decision":"deny","reason":"requested overwrite is outside the assigned deliverable"}"#),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProvider }
                return mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)

        let sent = await orch.send("create denied.txt", to: main)
        XCTAssertTrue(attached)
        XCTAssertEqual(enabled, AutomaticPermissionReviewResult.enabled(reviewer))
        guard case .failed(let failure) = sent else {
            return XCTFail("a denied required write must fail the invocation")
        }
        XCTAssertTrue(failure.contains("required side effects remain denied or failed"))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ws.appendingPathComponent("denied.txt").path))
        let events = await log.replay()
        let settled = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.last)
        let resolved = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "write_file",
               payload.requestId != nil { return payload }
            return nil
        }.last)
        let observation = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            if case .toolResult(let payload) = envelope.event,
               payload.toolCallId == "denied-write" { return payload }
            return nil
        }.last?.observation)
        XCTAssertEqual(settled.reason, exactReason)
        XCTAssertEqual(resolved.reason, exactReason)
        XCTAssertEqual(resolved.source, .automaticReviewer)
        XCTAssertEqual(resolved.reviewTaskID, settled.reviewTaskID)
        XCTAssertEqual(resolved.reviewStatus, .denied)
        XCTAssertEqual(observation, "permission denied: \(exactReason)")
        XCTAssertFalse(observation.contains("permission denied: permission denied:"))
        XCTAssertTrue(mainProvider.requests.dropFirst().first?.messages.contains {
            $0.content == observation
        } == true)
        XCTAssertFalse(events.contains { envelope in
            if case .taskCompleted(let payload) = envelope.event {
                return payload.agent == main
            }
            return false
        })
        XCTAssertTrue(events.contains { envelope in
            if case .taskFailed(let payload) = envelope.event {
                return payload.agent == main
                    && payload.error.contains("required side effects remain denied or failed")
            }
            return false
        })
    }

    func testSuccessfulEquivalentEditClearsEarlierDeniedWriteEvidence() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let file = ws.appendingPathComponent("document.txt")
        try "old\n".write(to: file, atomically: true, encoding: .utf8)
        let diff = [
            "--- a/document.txt",
            "+++ b/document.txt",
            "@@ -1 +1 @@",
            "-old",
            "+new",
        ].joined(separator: "\n")
        let patchArgs = String(decoding: try JSONSerialization.data(
            withJSONObject: ["diff": diff],
            options: [.sortedKeys]), as: UTF8.self)
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "denied-write",
                name: "write_file",
                arguments: autoReviewWriteArgs(path: "document.txt", content: "new\n"))]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "approved-patch",
                name: "apply_patch",
                arguments: patchArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Updated document.txt through the approved patch."),
             .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewScriptedProvider([
            [.textDelta(#"{"decision":"deny","reason":"replace the broad overwrite with a minimal patch"}"#),
             .done(finishReason: "stop")],
            [.textDelta(#"{"decision":"allow","reason":"minimal patch matches the requested edit"}"#),
             .done(finishReason: "stop")],
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                agent.name == reviewerID ? reviewerProvider : mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let result = await orch.send("change document.txt from old to new", to: main)

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new\n")
        XCTAssertEqual(reviewerProvider.requests.count, 2)
        let settlements = await log.replay().compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertTrue(settlements.contains {
            $0.tool == "apply_patch" && $0.outcome == .succeeded
        })
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
        guard case .failed(let failure) = sendResult else {
            return XCTFail("a hard-denied required write must fail the invocation")
        }
        XCTAssertTrue(failure.contains("required side effects remain denied or failed"))

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
