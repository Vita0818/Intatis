import Foundation
import XCTest
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisCowork
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import IntatisCLI

final class RealProviderSmokeTests: XCTestCase {
    func testConfiguredAgentRouteWithRealProvider() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_PROVIDER_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set INTATIS_REAL_PROVIDER_SMOKE=1 to spend one minimal real provider request.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))

        let report = await registry.healthCheck(
            role: .agent,
            options: ProviderHealthCheckOptions(
                timeoutSeconds: 60,
                prompt: "Return exactly OK.",
                maxPreviewCharacters: 16))

        XCTAssertEqual(report.status, .ok, report.message)
        XCTAssertEqual(report.role, .agent)
        XCTAssertEqual(report.model.rawValue, config.model)
        XCTAssertFalse(report.responsePreview?.isEmpty ?? true)
    }

    func testRealPermissionReviewControlPlaneWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "INTATIS_REAL_PERMISSION_REVIEW_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set INTATIS_REAL_PERMISSION_REVIEW_SMOKE=1 to spend one real permission-review request.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let models = await registry.models()
        let route = models.agent ?? models.chat
        let sessionID = SessionID(
            rawValue: "real_permission_review_\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            sessionID.rawValue,
            isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let responder = AgentPermissionResponder(
            log: log,
            reviewerAgent: Agent(
                name: Orchestrator.automaticPermissionReviewerID,
                workspaceRoot: workspace,
                model: route.model,
                profile: .readOnly,
                coordinationDepth: 0),
            providerFactory: {
                try await registry.agentProvider(for: route)
            },
            fallback: FixedResponder(.deny),
            policy: PermissionReviewControlPlanePolicy(timeoutSeconds: 60))

        let request = makePermissionReviewRequest(sessionID: sessionID)
        let resolution = await responder.requestResolution(request)

        XCTAssertTrue(
            resolution.decision == .allow || resolution.decision == .deny)
        XCTAssertEqual(
            resolution.source,
            .automaticReviewer,
            resolution.reason ?? "missing reviewer reason")
        XCTAssertTrue(
            resolution.reviewStatus == .allowed
                || resolution.reviewStatus == .denied)
        XCTAssertNil(resolution.failureKind, resolution.reason ?? "")
        XCTAssertFalse(resolution.reason?.isEmpty ?? true)

        let events = await log.replay()
        let requested = events.compactMap { envelope -> PermissionReviewRequestedPayload? in
            if case .permissionReviewRequested(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        let settled = events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(requested.first?.task.requestID, request.requestId)
        XCTAssertEqual(settled.first?.requestID, request.requestId)
    }

    private func makePermissionReviewRequest(
        sessionID: SessionID
    ) -> PermissionRequestPayload {
        let agent = AgentID(rawValue: "main")
        let arguments = #"{"content":"smoke","path":"smoke-output.txt"}"#
        let gate = PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .medium,
            reason: "write a non-sensitive file inside the workspace",
            policyVersion: "intatis.real-smoke.v1")
        let intent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "smoke-output.txt",
                access: .readWrite)],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .requiresManualReconciliation)
        let authorization = ResolvedToolAuthorization(
            authorizationID: "real-permission-review-smoke",
            registryVersion: "intatis.real-smoke.v1",
            concreteToolID: "intatis.standard/write_file",
            descriptorFingerprint: ToolRegistry.authorizationDigest(
                "write_file|real-smoke"),
            toolName: "write_file",
            canonicalAction: intent.action,
            canonicalPermission: "filesystem.edit",
            actionPreview: PermissionActionPreview(
                kind: "workspace_write",
                fields: ["path": "smoke-output.txt"]),
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: nil,
            workspaceAccess: nil,
            workspaceRootIdentity: nil,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: sessionID,
                agent: agent),
            normalizedArgumentsDigest: ToolRegistry.authorizationDigest(
                arguments),
            normalizedArgumentsCharacterCount: arguments.count,
            intent: intent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .requiresManualReconciliation,
            deterministicGate: gate)
        let context = PermissionRequestContext(
            normalizedArgs: arguments,
            touchedPaths: ["smoke-output.txt"],
            risksNetwork: false,
            sideEffect: .write,
            intent: intent,
            gate: gate,
            authorization: authorization,
            replayPolicy:
                ToolExecutionReplayPolicy.requiresManualReconciliation.rawValue)
        return PermissionRequestPayload(
            requestId: RequestID.new(),
            agent: agent,
            tool: "write_file",
            args: arguments,
            risk: .medium,
            reason: gate.reason,
            context: context,
            approvalMode: .automaticReviewer)
    }
}
