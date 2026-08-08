import Foundation
import XCTest
import IntatisConversation
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisAgentKernel

private final class AuthorizationReporterProvider:
    ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [AgentChunk]
    private var captured: [AgentRequest] = []

    init(chunks: [AgentChunk]) {
        self.chunks = chunks
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest)
        -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private final class AuthorizationReporterHangingProvider:
    ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [AgentRequest] = []
    private var terminationCount = 0

    var requestCount: Int {
        lock.withLock { captured.count }
    }

    var terminatedRequests: Int {
        lock.withLock { terminationCount }
    }

    func stream(_ request: AgentRequest)
        -> AsyncThrowingStream<AgentChunk, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.terminationCount += 1 }
            }
        }
    }
}

final class PermissionAuthorizationContextReporterTests: XCTestCase {
    func testContinueReportMapsHandlesToCanonicalClosedEvidenceWithoutHistoryPollution()
        async throws {
        let fixture = try makeFixture("continue")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalID = SubmissionID(rawValue: "submission_original")
        let currentID = SubmissionID(rawValue: "submission_continue")
        let original = try await fixture.log.append(.userMessage(
            UserMessagePayload(
                text: "Update the permission report to the agreed evidence-based design.",
                submissionID: originalID)))
        let current = try await fixture.log.append(.userMessage(
            UserMessagePayload(
                text: "Continue.",
                submissionID: currentID)))
        let provider = AuthorizationReporterProvider(chunks: [
            .textDelta(reportJSON(handles: ["U1"])),
            .usage(Usage(promptTokens: 80, completionTokens: 40, totalTokens: 120)),
            .done(finishReason: "stop"),
        ])
        let providerMessages: [AgentMessage] = [
            .system("system"),
            .user("Update the permission report to the agreed evidence-based design."),
            .assistant("I have inspected the report and prepared the revision."),
            .user("Continue."),
        ]
        let reporter = PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "acting-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil)

        let result = await reporter.report(
            turn: PermissionAuthorizationReportingTurn(
                providerMessages: providerMessages,
                assistantText: "",
                toolCalls: [ToolCall(
                    id: "call_patch",
                    name: "apply_patch",
                    arguments: #"{"patch":"bounded"}"#)],
                visibleUserMessages: [
                    PermissionAuthorizationVisibleUserMessage(
                        submissionID: originalID,
                        expectedContent: "Update the permission report to the agreed evidence-based design."),
                    PermissionAuthorizationVisibleUserMessage(
                        submissionID: currentID,
                        expectedContent: "Continue."),
                ],
                currentSubmissionID: currentID),
            authorization: authorization(
                sessionID: fixture.sessionID,
                toolCallID: "call_patch"))

        XCTAssertEqual(
            result.context?.supportingUserEventSequences,
            [original.seq, current.seq])
        XCTAssertEqual(
            result.context?.report.latestInstructionInterpretation,
            "Continue the already agreed report revision without expanding scope.")
        XCTAssertEqual(result.usage?.totalTokens, 120)
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(Array(request.messages.dropLast()), providerMessages)
        XCTAssertEqual(request.model, ModelID(rawValue: "acting-model"))
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertTrue(request.includeUsage)
        XCTAssertNil(request.maxOutputTokens)
        let prompt = request.messages.last?.content ?? ""
        XCTAssertTrue(prompt.contains("U1:"))
        XCTAssertTrue(prompt.contains("U2:"))
        XCTAssertTrue(prompt.contains("Always cite the current user handle"))
        let replayedEventTypes = await fixture.log.replay().map(\.event.type)
        XCTAssertEqual(replayedEventTypes, [
            .userMessage,
            .userMessage,
        ])
    }

    func testUnknownEvidenceHandleFailsClosed() async throws {
        let fixture = try makeFixture("unknown-handle")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let submissionID = SubmissionID(rawValue: "submission_current")
        _ = try await fixture.log.append(.userMessage(
            UserMessagePayload(text: "Make the bounded edit.", submissionID: submissionID)))
        let provider = AuthorizationReporterProvider(chunks: [
            .textDelta(reportJSON(handles: ["U999"])),
            .done(finishReason: "stop"),
        ])

        let result = await PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "acting-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil)
            .report(
                turn: PermissionAuthorizationReportingTurn(
                    providerMessages: [.user("Make the bounded edit.")],
                    assistantText: "",
                    toolCalls: [ToolCall(
                        id: "call_patch",
                        name: "apply_patch",
                        arguments: "{}")],
                    visibleUserMessages: [
                        PermissionAuthorizationVisibleUserMessage(
                            submissionID: submissionID,
                            expectedContent: "Make the bounded edit."),
                    ],
                    currentSubmissionID: submissionID),
                authorization: authorization(
                    sessionID: fixture.sessionID,
                    toolCallID: "call_patch"))

        XCTAssertNil(result.context)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testSecretBearingReportFailsClosed() async throws {
        let fixture = try makeFixture("secret-report")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let submissionID = SubmissionID(rawValue: "submission_secret")
        _ = try await fixture.log.append(.userMessage(
            UserMessagePayload(text: "Make the bounded edit.", submissionID: submissionID)))
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let provider = AuthorizationReporterProvider(chunks: [
            .textDelta(reportJSON(
                handles: ["U1"],
                justification: "Use credential \(secret) to perform the action.")),
            .done(finishReason: "stop"),
        ])

        let result = await PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "acting-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil)
            .report(
                turn: PermissionAuthorizationReportingTurn(
                    providerMessages: [.user("Make the bounded edit.")],
                    assistantText: "",
                    toolCalls: [ToolCall(
                        id: "call_patch",
                        name: "apply_patch",
                        arguments: "{}")],
                    visibleUserMessages: [
                        PermissionAuthorizationVisibleUserMessage(
                            submissionID: submissionID,
                            expectedContent: "Make the bounded edit."),
                    ],
                    currentSubmissionID: submissionID),
                authorization: authorization(
                    sessionID: fixture.sessionID,
                    toolCallID: "call_patch"))

        XCTAssertNil(result.context)
    }

    func testTaskScopedWorkerEvidenceDoesNotExposeMainPrivateTurn() async throws {
        let fixture = try makeFixture("worker-scope")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let privateID = SubmissionID(rawValue: "submission_private")
        let scopedID = SubmissionID(rawValue: "submission_scoped")
        _ = try await fixture.log.append(.userMessage(UserMessagePayload(
            text: "MAIN_PRIVATE_MARKER do not share with worker",
            submissionID: privateID)))
        let scoped = try await fixture.log.append(.userMessage(UserMessagePayload(
            text: "Audit the selected report section.",
            submissionID: scopedID)))
        let provider = AuthorizationReporterProvider(chunks: [
            .textDelta(reportJSON(handles: ["U1"])),
            .done(finishReason: "stop"),
        ])

        let result = await PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "worker-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil)
            .report(
                turn: PermissionAuthorizationReportingTurn(
                    providerMessages: [
                        .system("worker system"),
                        .user("Task-scoped delegated audit."),
                    ],
                    assistantText: "",
                    toolCalls: [ToolCall(
                        id: "call_read",
                        name: "read_file",
                        arguments: "{}")],
                    visibleUserMessages: [
                        PermissionAuthorizationVisibleUserMessage(
                            submissionID: scopedID),
                    ],
                    currentSubmissionID: scopedID),
                authorization: authorization(
                    sessionID: fixture.sessionID,
                    toolCallID: "call_read"))

        XCTAssertEqual(
            result.context?.supportingUserEventSequences,
            [scoped.seq])
        let prompt = provider.requests.first?.messages.last?.content ?? ""
        XCTAssertFalse(prompt.contains("MAIN_PRIVATE_MARKER"))
        XCTAssertTrue(prompt.contains("Audit the selected report section."))
    }

    func testTimeoutFailsClosedAndTerminatesTheRequestOwnedStream() async throws {
        let fixture = try makeFixture("timeout")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let submissionID = SubmissionID(rawValue: "submission_timeout")
        _ = try await fixture.log.append(.userMessage(UserMessagePayload(
            text: "Make the bounded edit.",
            submissionID: submissionID)))
        let provider = AuthorizationReporterHangingProvider()
        let startedAt = Date()

        let result = await PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "acting-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil,
            timeoutSeconds: 0.01)
            .report(
                turn: PermissionAuthorizationReportingTurn(
                    providerMessages: [.user("Make the bounded edit.")],
                    assistantText: "",
                    toolCalls: [ToolCall(
                        id: "call_timeout",
                        name: "apply_patch",
                        arguments: "{}")],
                    visibleUserMessages: [
                        PermissionAuthorizationVisibleUserMessage(
                            submissionID: submissionID,
                            expectedContent: "Make the bounded edit."),
                    ],
                    currentSubmissionID: submissionID),
                authorization: authorization(
                    sessionID: fixture.sessionID,
                    toolCallID: "call_timeout"))

        XCTAssertNil(result.context)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        for _ in 0..<100 where provider.terminatedRequests == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(provider.terminatedRequests, 1)
    }

    func testResponseWithoutCompletionMarkerFailsClosed() async throws {
        let fixture = try makeFixture("missing-completion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let submissionID = SubmissionID(
            rawValue: "submission_missing_completion")
        _ = try await fixture.log.append(.userMessage(UserMessagePayload(
            text: "Make the bounded edit.",
            submissionID: submissionID)))
        let provider = AuthorizationReporterProvider(chunks: [
            .textDelta(reportJSON(handles: ["U1"])),
        ])

        let result = await PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "acting-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil)
            .report(
                turn: PermissionAuthorizationReportingTurn(
                    providerMessages: [.user("Make the bounded edit.")],
                    assistantText: "",
                    toolCalls: [ToolCall(
                        id: "call_missing_completion",
                        name: "apply_patch",
                        arguments: "{}")],
                    visibleUserMessages: [
                        PermissionAuthorizationVisibleUserMessage(
                            submissionID: submissionID,
                            expectedContent: "Make the bounded edit."),
                    ],
                    currentSubmissionID: submissionID),
                authorization: authorization(
                    sessionID: fixture.sessionID,
                    toolCallID: "call_missing_completion"))

        XCTAssertNil(result.context)
    }

    func testCallerCancellationFailsClosedAndTerminatesCurrentStream()
        async throws {
        let fixture = try makeFixture("caller-cancel")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let submissionID = SubmissionID(
            rawValue: "submission_caller_cancel")
        _ = try await fixture.log.append(.userMessage(UserMessagePayload(
            text: "Make the bounded edit.",
            submissionID: submissionID)))
        let provider = AuthorizationReporterHangingProvider()
        let reporter = PermissionAuthorizationContextReporter(
            log: fixture.log,
            provider: provider,
            model: ModelID(rawValue: "acting-model"),
            reasoningEffort: nil,
            tokenBudgetMeter: nil,
            timeoutSeconds: 1)
        let task = Task {
            await reporter.report(
                turn: PermissionAuthorizationReportingTurn(
                    providerMessages: [.user("Make the bounded edit.")],
                    assistantText: "",
                    toolCalls: [ToolCall(
                        id: "call_cancel",
                        name: "apply_patch",
                        arguments: "{}")],
                    visibleUserMessages: [
                        PermissionAuthorizationVisibleUserMessage(
                            submissionID: submissionID,
                            expectedContent: "Make the bounded edit."),
                    ],
                    currentSubmissionID: submissionID),
                authorization: authorization(
                    sessionID: fixture.sessionID,
                    toolCallID: "call_cancel"))
        }
        for _ in 0..<100 where provider.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        task.cancel()
        let result = await task.value

        XCTAssertNil(result.context)
        for _ in 0..<100 where provider.terminatedRequests == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(provider.terminatedRequests, 1)
    }

    private func makeFixture(_ suffix: String) throws
        -> (root: URL, sessionID: SessionID, log: EventLog) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "permission-authorization-reporter-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let sessionID = SessionID(rawValue: "reporter_\(suffix)")
        return (
            root,
            sessionID,
            try EventLog(
                session: sessionID,
                fileURL: root.appendingPathComponent("events.jsonl")))
    }

    private func authorization(
        sessionID: SessionID,
        toolCallID: String
    ) -> ResolvedToolAuthorization {
        let intent = PermissionIntent(
            action: "filesystem.patch",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "Report.md",
                access: .readWrite)],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .requiresManualReconciliation)
        return ResolvedToolAuthorization(
            authorizationID: "authorization-reporter",
            registryVersion: "test.reporter.v1",
            concreteToolID: "test.reporter.v1/apply_patch",
            descriptorFingerprint: String(repeating: "a", count: 64),
            toolName: "apply_patch",
            canonicalAction: intent.action,
            canonicalPermission: "filesystem.edit",
            actionPreview: PermissionActionPreview(
                kind: "filesystem.patch",
                fields: ["path": "Report.md"]),
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: nil,
            workspaceAccess: nil,
            workspaceRootIdentity: nil,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: sessionID,
                agent: AgentID(rawValue: "main"),
                toolCallID: toolCallID),
            normalizedArgumentsDigest: String(repeating: "b", count: 64),
            normalizedArgumentsCharacterCount: 2,
            intent: intent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .requiresManualReconciliation,
            deterministicGate: PermissionReviewGateSnapshot(
                decision: .ask,
                risk: .medium,
                reason: "workspace mutation requires review"))
    }

    private func reportJSON(
        handles: [String],
        justification: String = "The exact bounded patch is the next necessary action."
    ) -> String {
        let object: [String: Any] = [
            "report": [
                "authorization_goal": "Finish the already requested report revision.",
                "current_progress": "The report was inspected and the target change was prepared.",
                "latest_instruction_interpretation": "Continue the already agreed report revision without expanding scope.",
                "current_action_justification": justification,
                "scope_assessment": "The action stays inside the selected report.",
            ],
            "supporting_user_handles": handles,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
