import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisTools
@testable import IntatisCowork

private final class LeaseCapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

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
            continuation.yield(.textDelta("done"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private func leaseTempLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-lease-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "lease"), fileURL: url)
}

private func leaseTempWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("lease-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func leaseTaskCreatedContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskCreated(let payload) = $0.event { return payload.contract }
        return nil
    }
}

final class ToolRegistryLeaseTests: XCTestCase {
    func testRenameSessionRegistryRequiresBothMainIdentityAndDedicatedCapability() {
        let granted = CapabilityLease(tools: [.renameSession])
        let mainRegistry = Orchestrator.toolRegistry(
            for: granted,
            agentID: Orchestrator.mainAgentID)
        XCTAssertNotNil(mainRegistry.tool(named: "rename_session"))
        XCTAssertEqual(
            mainRegistry.registration(named: "rename_session")?.grantingCapabilities,
            [.renameSession])

        let workerRegistry = Orchestrator.toolRegistry(
            for: granted,
            agentID: AgentID(rawValue: "worker"))
        XCTAssertNil(workerRegistry.tool(named: "rename_session"))
        XCTAssertNil(Orchestrator.toolRegistry(for: granted).tool(named: "rename_session"))

        let missingCapability = Orchestrator.toolRegistry(
            for: CapabilityLease(tools: []),
            agentID: Orchestrator.mainAgentID)
        XCTAssertNil(missingCapability.tool(named: "rename_session"))
    }

    func testRestoreDurablyUpgradesLegacyMainDefaultRenameCapabilityOnce() async throws {
        let log = try leaseTempLog()
        let workspace = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let main = Orchestrator.mainAgentID
        var legacyCapability = CapabilityLease.coordinator()
        legacyCapability.tools.remove(.renameSession)
        legacyCapability.expiresAtTaskCompletion = false
        let workspaceLease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            expiresAtTaskCompletion: false)
        try await log.append([
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: main,
                lease: workspaceLease)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: main,
                lease: legacyCapability)),
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
        ])

        let first = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.deny)) { _ in LeaseCapturingProvider() }
        await first.restore(from: CoworkProjection.build(from: await log.replay()))

        let afterFirst = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(afterFirst.capabilityLeases[legacyCapability.id])
        let upgraded = afterFirst.capabilityLeaseAgents.compactMap { leaseID, agent in
            agent == main ? afterFirst.capabilityLeases[leaseID] : nil
        }
        XCTAssertEqual(upgraded.count, 1)
        let upgradedLease = try XCTUnwrap(upgraded.first)
        XCTAssertTrue(upgradedLease.tools.contains(.renameSession))
        let firstEvents = await log.replay()
        let firstCreatedCount = firstEvents.filter {
            if case .capabilityLeaseCreated(let payload) = $0.event,
               payload.agent == main { return true }
            return false
        }.count

        let second = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.deny)) { _ in LeaseCapturingProvider() }
        await second.restore(from: afterFirst)
        let secondEvents = await log.replay()
        let secondCreatedCount = secondEvents.filter {
            if case .capabilityLeaseCreated(let payload) = $0.event,
               payload.agent == main { return true }
            return false
        }.count
        XCTAssertEqual(secondCreatedCount, firstCreatedCount)
    }

    func testInferenceAuthorizationFingerprintChangesAcrossTrustDomains() {
        let ref = InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(rawValue: "same-profile"),
            inferenceProfileRevision: InferenceProfileRevision(rawValue: "rev-1"))
        let first = AgentInferenceBinding(
            inferenceProfileRef: ref,
            inferenceConnectionID: InferenceConnectionID(rawValue: "same-connection"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-rev-1"),
            modelID: ModelID(rawValue: "same-model"),
            safeRouteLabel: "Route A",
            trustDomain: "trust-a",
            egressClassification: "external",
            immutableDefinitionFingerprint: "same-immutable-digest")
        var second = first
        second.trustDomain = "trust-b"

        XCTAssertNotEqual(
            ToolRegistry.authorizationFingerprint(first),
            ToolRegistry.authorizationFingerprint(second))
    }

    func testApplyPatchCapabilityRegistersBothConcreteEditToolsFromOneSource() throws {
        let lease = CapabilityLease(tools: [.applyPatch])
        let registry = Orchestrator.toolRegistry(for: lease)
        let names = Set(registry.descriptors().map(\.name))

        XCTAssertEqual(names, ["write_file", "apply_patch"])
        XCTAssertEqual(
            registry.registration(named: "write_file")?.grantingCapabilities,
            [.applyPatch])
        XCTAssertEqual(
            registry.registration(named: "apply_patch")?.grantingCapabilities,
            [.applyPatch])

        let root = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceLease = WorkspaceLease(rootPath: root.path, access: .readWrite)
        let write = try XCTUnwrap(registry.tool(named: "write_file"))
        let patch = try XCTUnwrap(registry.tool(named: "apply_patch"))
        let writeArgs = ToolArgs(raw: #"{"path":"a.txt","content":"a"}"#)
        let patchArgs = ToolArgs(raw: #"{"diff":"*** Begin Patch\n*** Add File: b.txt\n+b\n*** End Patch"}"#)
        let writeIntent = write.permissionIntent(writeArgs, workspaceRoot: root)
        let patchIntent = patch.permissionIntent(patchArgs, workspaceRoot: root)
        let writeAuthorization = try registry.resolveAuthorization(
            toolName: "write_file",
            intent: writeIntent,
            risksNetwork: false,
            normalizedArguments: writeArgs.raw,
            capabilityLease: lease,
            workspaceLease: workspaceLease)
        let patchAuthorization = try registry.resolveAuthorization(
            toolName: "apply_patch",
            intent: patchIntent,
            risksNetwork: false,
            normalizedArguments: patchArgs.raw,
            capabilityLease: lease,
            workspaceLease: workspaceLease)

        XCTAssertEqual(writeAuthorization.membership, .granted)
        XCTAssertEqual(patchAuthorization.membership, .granted)
        XCTAssertEqual(writeAuthorization.requiredCapabilities, [.applyPatch])
        XCTAssertEqual(patchAuthorization.requiredCapabilities, [.applyPatch])
        XCTAssertEqual(writeAuthorization.canonicalAction, "filesystem.write")
        XCTAssertEqual(patchAuthorization.canonicalAction, "filesystem.patch")
        XCTAssertEqual(writeAuthorization.canonicalPermission, "filesystem.edit")
        XCTAssertEqual(patchAuthorization.canonicalPermission, "filesystem.edit")
        XCTAssertEqual(writeAuthorization.actionPreview?.fields["content"], "a")
        XCTAssertTrue(patchAuthorization.actionPreview?.fields["diff"]?.contains("Add File: b.txt") == true)
        XCTAssertEqual(writeAuthorization.concreteToolID, "intatis.cowork.v1/write_file")
        XCTAssertEqual(patchAuthorization.concreteToolID, "intatis.cowork.v1/apply_patch")
        XCTAssertNotEqual(writeAuthorization.concreteToolID, patchAuthorization.concreteToolID)
        XCTAssertFalse(writeAuthorization.descriptorFingerprint.isEmpty)
        XCTAssertFalse(patchAuthorization.descriptorFingerprint.isEmpty)
    }

    func testScopedRegistryFailsClosedForWrongLeaseAndDuplicateNames() throws {
        let grantedLease = CapabilityLease(tools: [.applyPatch])
        let wrongLease = CapabilityLease(tools: [.readWorkspace])
        let registry = Orchestrator.toolRegistry(for: grantedLease)
        let root = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = try XCTUnwrap(registry.tool(named: "write_file"))
        let args = ToolArgs(raw: #"{"path":"a.txt","content":"a"}"#)

        XCTAssertThrowsError(try registry.resolveAuthorization(
            toolName: "write_file",
            intent: tool.permissionIntent(args, workspaceRoot: root),
            risksNetwork: false,
            normalizedArguments: args.raw,
            capabilityLease: wrongLease,
            workspaceLease: WorkspaceLease(rootPath: root.path, access: .readWrite))) { error in
                guard case ToolRegistryAuthorizationError.capabilityNotGranted = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let duplicate = ToolRegistry([WriteFileTool(), WriteFileTool()])
        XCTAssertNil(duplicate.tool(named: "write_file"))
        XCTAssertFalse(duplicate.descriptors().contains { $0.name == "write_file" })
        XCTAssertThrowsError(try duplicate.resolveAuthorization(
            toolName: "write_file",
            intent: tool.permissionIntent(args, workspaceRoot: root),
            risksNetwork: false,
            normalizedArguments: args.raw,
            capabilityLease: nil,
            workspaceLease: nil)) { error in
                XCTAssertEqual(
                    error as? ToolRegistryAuthorizationError,
                    .duplicateRegistration("write_file"))
            }
    }

    func testAuthorizationSnapshotValidationFailsClosedForIdentityDrift() throws {
        let lease = CapabilityLease(tools: [.applyPatch])
        let registry = Orchestrator.toolRegistry(for: lease)
        let root = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = try XCTUnwrap(registry.tool(named: "write_file"))
        let arguments = #"{"path":"a.txt","content":"a"}"#
        let intent = tool.permissionIntent(ToolArgs(raw: arguments), workspaceRoot: root)
        let workspaceLease = WorkspaceLease(
            taskID: TaskID(rawValue: "task-snapshot"),
            rootPath: root.path,
            access: .readWrite)
        let scopedLease = CapabilityLease(
            id: lease.id,
            taskID: TaskID(rawValue: "task-snapshot"),
            tools: lease.tools)
        let invocation = ToolAuthorizationInvocationContext(
            sessionID: SessionID(rawValue: "snapshot-session"),
            agent: AgentID(rawValue: "snapshot-agent"),
            taskID: TaskID(rawValue: "task-snapshot"),
            rootTaskID: TaskID(rawValue: "root-snapshot"),
            attempt: 2,
            toolCallID: "snapshot-call")
        let authorization = try registry.resolveAuthorization(
            toolName: "write_file",
            intent: intent,
            risksNetwork: false,
            normalizedArguments: arguments,
            invocation: invocation,
            capabilityLease: scopedLease,
            workspaceLease: workspaceLease)

        func replacing(_ key: String, with value: Any) throws -> ResolvedToolAuthorization {
            let encoded = try JSONEncoder().encode(authorization)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[key] = value
            return try JSONDecoder().decode(
                ResolvedToolAuthorization.self,
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }

        try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false,
            invocation: invocation,
            capabilityLease: scopedLease,
            workspaceLease: workspaceLease)

        let wrongSchema = try replacing("schemaVersion", with: 99)
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            wrongSchema,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationSchemaMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let wrongRegistry = try replacing("registryVersion", with: "intatis.cowork.other")
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            wrongRegistry,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationRegistryMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let wrongConcreteTool = try replacing("concreteToolID", with: "intatis.cowork.v1/other")
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            wrongConcreteTool,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationConcreteToolMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let wrongDescriptor = try replacing("descriptorFingerprint", with: "forged")
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            wrongDescriptor,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationDescriptorMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let wrongToolCall = try replacing("toolCallID", with: "other-call")
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            wrongToolCall,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false,
            invocation: invocation,
            capabilityLease: scopedLease,
            workspaceLease: workspaceLease)) { error in
                guard case ToolRegistryAuthorizationError.authorizationInvocationMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false,
            invocation: invocation,
            workspaceLease: workspaceLease)) { error in
                guard case ToolRegistryAuthorizationError.authorizationLeaseMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false,
            invocation: invocation,
            capabilityLease: scopedLease)) { error in
                guard case ToolRegistryAuthorizationError.authorizationLeaseMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false,
            capabilityLease: scopedLease,
            workspaceLease: workspaceLease)) { error in
                guard case ToolRegistryAuthorizationError.authorizationInvocationMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: #"{"path":"b.txt","content":"b"}"#,
            intent: intent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationArgumentsMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        var changedIntent = intent
        changedIntent.action = "filesystem.patch"
        XCTAssertThrowsError(try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: changedIntent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationIntentMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let remappedRegistry = ToolRegistry(
            registrations: [ToolRegistration(
                tool: WriteFileTool(),
                grantingCapabilities: [.readWorkspace])],
            registryVersion: registry.registryVersion)
        XCTAssertThrowsError(try remappedRegistry.validateAuthorizationSnapshot(
            authorization,
            toolName: "write_file",
            normalizedArguments: arguments,
            intent: intent,
            risksNetwork: false)) { error in
                guard case ToolRegistryAuthorizationError.authorizationCapabilityMismatch = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
    }

    func testScopedRegistryEnforcesCommunicationAndDelegationGrantFacts() throws {
        let granted = CapabilityLease.coordinator()
        let registry = Orchestrator.toolRegistry(for: granted)
        XCTAssertEqual(
            registry.registration(named: "send_message")?.requiredCommunication,
            .initiate)
        XCTAssertEqual(
            registry.registration(named: "reply_message")?.requiredCommunication,
            .reply)
        XCTAssertEqual(
            registry.registration(named: "delegate_task")?.requiredDelegation,
            .granted)
        XCTAssertEqual(
            registry.registration(named: "spawn_agent")?.requiredDelegation,
            .granted)

        let root = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let send = try XCTUnwrap(registry.tool(named: "send_message"))
        let sendArgs = ToolArgs(raw: #"{"to":"worker","content":"hello"}"#)
        let narrowedCommunication = CapabilityLease(
            id: granted.id,
            taskID: granted.taskID,
            tools: granted.tools,
            communication: .none,
            delegation: granted.delegation)
        XCTAssertThrowsError(try registry.resolveAuthorization(
            toolName: "send_message",
            intent: send.permissionIntent(sendArgs, workspaceRoot: root),
            risksNetwork: false,
            normalizedArguments: sendArgs.raw,
            capabilityLease: narrowedCommunication,
            workspaceLease: nil)) { error in
                guard case ToolRegistryAuthorizationError.communicationNotGranted = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let delegate = try XCTUnwrap(registry.tool(named: "delegate_task"))
        let delegateArgs = ToolArgs(raw: #"{"to":"worker","objective":"inspect"}"#)
        let narrowedDelegation = CapabilityLease(
            id: granted.id,
            taskID: granted.taskID,
            tools: granted.tools,
            communication: granted.communication,
            delegation: .requestOnly)
        XCTAssertThrowsError(try registry.resolveAuthorization(
            toolName: "delegate_task",
            intent: delegate.permissionIntent(delegateArgs, workspaceRoot: root),
            risksNetwork: false,
            normalizedArguments: delegateArgs.raw,
            capabilityLease: narrowedDelegation,
            workspaceLease: nil)) { error in
                guard case ToolRegistryAuthorizationError.delegationNotGranted = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
    }

    func testAuthorizationLeaseFingerprintsAreCanonicalAcrossCollectionOrder() {
        let capabilityID = CapabilityLeaseID(rawValue: "canonical-capability")
        let firstCapability = CapabilityLease(
            id: capabilityID,
            tools: [.applyPatch, .readWorkspace, .sendMessage],
            communication: .selectedAgents([
                AgentID(rawValue: "zeta"),
                AgentID(rawValue: "alpha"),
            ]),
            delegation: .granted(DelegationBudget(maxTasks: 4, maxDepth: 1)),
            expiresAtTaskCompletion: false)
        let secondCapability = CapabilityLease(
            id: capabilityID,
            tools: [.sendMessage, .readWorkspace, .applyPatch],
            communication: .selectedAgents([
                AgentID(rawValue: "alpha"),
                AgentID(rawValue: "zeta"),
            ]),
            delegation: .granted(DelegationBudget(maxTasks: 4, maxDepth: 1)),
            expiresAtTaskCompletion: false)
        XCTAssertEqual(
            ToolRegistry.authorizationFingerprint(firstCapability),
            ToolRegistry.authorizationFingerprint(secondCapability))

        let identity = WorkspaceRootIdentity(
            canonicalPath: "/tmp/canonical",
            deviceID: 7,
            fileID: 9)
        let workspaceID = WorkspaceID(rawValue: "canonical-workspace")
        let leaseID = WorkspaceLeaseID(rawValue: "canonical-workspace-lease")
        let firstWorkspace = WorkspaceLease(
            id: leaseID,
            workspaceID: workspaceID,
            rootPath: "/tmp/canonical",
            rootIdentity: identity,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: "Sources/**"), PathRule(pattern: "Tests/**")],
            deniedPatterns: [".env", "*.key"],
            expiresAtTaskCompletion: false)
        let secondWorkspace = WorkspaceLease(
            id: leaseID,
            workspaceID: workspaceID,
            rootPath: "/tmp/canonical",
            rootIdentity: identity,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: "Tests/**"), PathRule(pattern: "Sources/**")],
            deniedPatterns: ["*.key", ".env"],
            expiresAtTaskCompletion: false)
        XCTAssertEqual(
            ToolRegistry.authorizationFingerprint(firstWorkspace),
            ToolRegistry.authorizationFingerprint(secondWorkspace))
    }

    func testWorkerLeaseDoesNotExposeCoordinatorTools() {
        let registry = Orchestrator.toolRegistry(for: .worker(taskID: TaskID(rawValue: "task_worker")))
        let toolNames = Set(registry.descriptors().map(\.name))

        XCTAssertTrue(toolNames.contains("read_file"))
        XCTAssertTrue(toolNames.contains("read_pdf"))
        XCTAssertTrue(toolNames.contains("list_files"))
        XCTAssertTrue(toolNames.contains("search_text"))
        XCTAssertFalse(toolNames.contains("edit_pdf_pages"))
        XCTAssertFalse(toolNames.contains("compile_latex"))
        XCTAssertFalse(toolNames.contains("generate_image"))
        XCTAssertFalse(toolNames.contains("edit_image"))
        XCTAssertFalse(toolNames.contains("web_fetch"))
        XCTAssertFalse(toolNames.contains("browser_diagnostics"))
        XCTAssertFalse(toolNames.contains("browser_profiles"))
        XCTAssertFalse(toolNames.contains("browser_profile_delete"))
        XCTAssertFalse(toolNames.contains("browser_history"))
        XCTAssertFalse(toolNames.contains("browser_navigate"))
        XCTAssertFalse(toolNames.contains("browser_snapshot"))
        XCTAssertFalse(toolNames.contains("browser_handoff"))
        XCTAssertFalse(toolNames.contains("browser_reload"))
        XCTAssertFalse(toolNames.contains("browser_back"))
        XCTAssertFalse(toolNames.contains("browser_forward"))
        XCTAssertFalse(toolNames.contains("browser_click"))
        XCTAssertFalse(toolNames.contains("browser_type"))
        XCTAssertFalse(toolNames.contains("browser_submit"))
        XCTAssertFalse(toolNames.contains("browser_select_option"))
        XCTAssertFalse(toolNames.contains("browser_press_key"))
        XCTAssertFalse(toolNames.contains("browser_scroll"))
        XCTAssertFalse(toolNames.contains("browser_wait"))
        XCTAssertFalse(toolNames.contains("browser_screenshot"))
        XCTAssertFalse(toolNames.contains("browser_upload_file"))
        XCTAssertFalse(toolNames.contains("browser_download"))
        XCTAssertFalse(toolNames.contains("browser_downloads"))
        XCTAssertFalse(toolNames.contains("browser_search"))
        XCTAssertFalse(toolNames.contains("git_status"))
        XCTAssertFalse(toolNames.contains("git_diff"))
        XCTAssertFalse(toolNames.contains("git_diff_staged"))
        XCTAssertFalse(toolNames.contains("git_info"))
        XCTAssertFalse(toolNames.contains("git_recent_commits"))
        XCTAssertFalse(toolNames.contains("git_diff_base"))
        XCTAssertFalse(toolNames.contains("git_branch"))
        XCTAssertFalse(toolNames.contains("git_create_branch"))
        XCTAssertFalse(toolNames.contains("git_stage"))
        XCTAssertFalse(toolNames.contains("git_unstage"))
        XCTAssertFalse(toolNames.contains("git_commit"))
        XCTAssertFalse(toolNames.contains("git_apply_patch_check"))
        XCTAssertFalse(toolNames.contains("git_apply_patch"))
        XCTAssertFalse(toolNames.contains("git_stage_patch"))
        XCTAssertFalse(toolNames.contains("git_unstage_patch"))
        XCTAssertFalse(toolNames.contains("git_revert_patch"))
        XCTAssertFalse(toolNames.contains("git_worktree_list"))
        XCTAssertFalse(toolNames.contains("git_worktree_create"))
        XCTAssertFalse(toolNames.contains("git_worktree_remove"))
        XCTAssertFalse(toolNames.contains("git_remotes"))
        XCTAssertFalse(toolNames.contains("git_fetch"))
        XCTAssertFalse(toolNames.contains("git_pull_ff"))
        XCTAssertFalse(toolNames.contains("git_push"))
        XCTAssertFalse(toolNames.contains("git_switch"))
        XCTAssertFalse(toolNames.contains("spawn_agent"))
        XCTAssertFalse(toolNames.contains("remove_agent"))
        XCTAssertFalse(toolNames.contains("ask_agent"))
        XCTAssertFalse(toolNames.contains("task_create"))
        XCTAssertTrue(toolNames.contains("task_update"))
        XCTAssertTrue(toolNames.contains("task_get"))
        XCTAssertTrue(toolNames.contains("task_list"))
        XCTAssertTrue(toolNames.contains("get_goal"))
        XCTAssertFalse(toolNames.contains("create_goal"))
        XCTAssertFalse(toolNames.contains("update_goal"))
    }

    func testCoordinatorLeaseCanExposeDelegationTools() {
        let registry = Orchestrator.toolRegistry(for: .coordinator(taskID: TaskID(rawValue: "task_coord")))
        let toolNames = Set(registry.descriptors().map(\.name))

        XCTAssertTrue(toolNames.contains("spawn_agent"))
        XCTAssertTrue(toolNames.contains("remove_agent"))
        XCTAssertTrue(toolNames.contains("list_agents"))
        XCTAssertTrue(toolNames.contains("ask_agent"))
        XCTAssertTrue(toolNames.contains("read_pdf"))
        XCTAssertTrue(toolNames.contains("edit_pdf_pages"))
        XCTAssertTrue(toolNames.contains("reconstruct_document_image"))
        XCTAssertTrue(toolNames.contains("compile_latex"))
        XCTAssertTrue(toolNames.contains("generate_image"))
        XCTAssertTrue(toolNames.contains("edit_image"))
        XCTAssertTrue(toolNames.contains("web_fetch"))
        XCTAssertTrue(toolNames.contains("browser_diagnostics"))
        XCTAssertTrue(toolNames.contains("browser_profiles"))
        XCTAssertTrue(toolNames.contains("browser_profile_delete"))
        XCTAssertTrue(toolNames.contains("browser_history"))
        XCTAssertTrue(toolNames.contains("browser_navigate"))
        XCTAssertTrue(toolNames.contains("browser_snapshot"))
        XCTAssertTrue(toolNames.contains("browser_handoff"))
        XCTAssertTrue(toolNames.contains("browser_reload"))
        XCTAssertTrue(toolNames.contains("browser_back"))
        XCTAssertTrue(toolNames.contains("browser_forward"))
        XCTAssertTrue(toolNames.contains("browser_click"))
        XCTAssertTrue(toolNames.contains("browser_type"))
        XCTAssertTrue(toolNames.contains("browser_submit"))
        XCTAssertTrue(toolNames.contains("browser_select_option"))
        XCTAssertTrue(toolNames.contains("browser_press_key"))
        XCTAssertTrue(toolNames.contains("browser_scroll"))
        XCTAssertTrue(toolNames.contains("browser_wait"))
        XCTAssertTrue(toolNames.contains("browser_screenshot"))
        XCTAssertTrue(toolNames.contains("browser_upload_file"))
        XCTAssertTrue(toolNames.contains("browser_download"))
        XCTAssertTrue(toolNames.contains("browser_downloads"))
        XCTAssertTrue(toolNames.contains("browser_search"))
        XCTAssertFalse(toolNames.contains("run_shell"))
        XCTAssertTrue(toolNames.contains("exec_command"))
        XCTAssertTrue(toolNames.contains("write_stdin"))
        XCTAssertTrue(toolNames.contains("git_status"))
        XCTAssertTrue(toolNames.contains("git_diff"))
        XCTAssertTrue(toolNames.contains("git_diff_staged"))
        XCTAssertTrue(toolNames.contains("git_info"))
        XCTAssertTrue(toolNames.contains("git_recent_commits"))
        XCTAssertTrue(toolNames.contains("git_diff_base"))
        XCTAssertTrue(toolNames.contains("git_branch"))
        XCTAssertTrue(toolNames.contains("git_create_branch"))
        XCTAssertTrue(toolNames.contains("git_stage"))
        XCTAssertTrue(toolNames.contains("git_unstage"))
        XCTAssertTrue(toolNames.contains("git_commit"))
        XCTAssertTrue(toolNames.contains("git_apply_patch_check"))
        XCTAssertTrue(toolNames.contains("git_apply_patch"))
        XCTAssertTrue(toolNames.contains("git_stage_patch"))
        XCTAssertTrue(toolNames.contains("git_unstage_patch"))
        XCTAssertTrue(toolNames.contains("git_revert_patch"))
        XCTAssertTrue(toolNames.contains("git_worktree_list"))
        XCTAssertTrue(toolNames.contains("git_worktree_create"))
        XCTAssertTrue(toolNames.contains("git_worktree_remove"))
        XCTAssertTrue(toolNames.contains("git_remotes"))
        XCTAssertTrue(toolNames.contains("git_fetch"))
        XCTAssertTrue(toolNames.contains("git_pull_ff"))
        XCTAssertTrue(toolNames.contains("git_push"))
        XCTAssertTrue(toolNames.contains("git_switch"))
        XCTAssertTrue(toolNames.contains("task_create"))
        XCTAssertTrue(toolNames.contains("task_update"))
        XCTAssertTrue(toolNames.contains("task_get"))
        XCTAssertTrue(toolNames.contains("task_list"))
        XCTAssertTrue(toolNames.contains("get_goal"))
        XCTAssertTrue(toolNames.contains("create_goal"))
        XCTAssertFalse(toolNames.contains("update_goal"))
    }

    func testManagedTerminalCanBeSuppressedByHostPlatform() {
        let lease = CapabilityLease.coordinator(taskID: TaskID(rawValue: "task_no_shell"))
        let toolNames = Set(Orchestrator.toolRegistry(
            for: lease,
            includesTerminal: false).descriptors().map(\.name))

        XCTAssertFalse(toolNames.contains("run_shell"))
        XCTAssertFalse(toolNames.contains("exec_command"))
        XCTAssertFalse(toolNames.contains("write_stdin"))
    }

    func testGoalVerifierCapabilityExposesOnlyReadAndVerdictGoalTools() {
        let lease = CapabilityLease(
            tools: [.readGoal, .readWorkTasks, .submitGoalVerdict])
        let toolNames = Set(Orchestrator.toolRegistry(for: lease).descriptors().map(\.name))

        XCTAssertTrue(toolNames.contains("get_goal"))
        XCTAssertTrue(toolNames.contains("task_get"))
        XCTAssertTrue(toolNames.contains("task_list"))
        XCTAssertTrue(toolNames.contains("update_goal"))
        XCTAssertFalse(toolNames.contains("create_goal"))
        XCTAssertFalse(toolNames.contains("task_create"))
        XCTAssertFalse(toolNames.contains("task_update"))
        XCTAssertFalse(toolNames.contains("delegate_task"))
    }

    func testTaskLeasePreservesCoordinatorCapabilityAndPrompt() async throws {
        let log = try leaseTempLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "legacy-depth-worker")
        let wsMain = try leaseTempWorkspace()
        let ws = try leaseTempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: ws)
        }
        let provider = LeaseCapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: wsMain,
                                                   model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let attached = await orch.attach(Agent(name: worker,
                                               workspaceRoot: ws,
                                               model: ModelID(rawValue: "m"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(attached)
        _ = await orch.ask(from: main,
                           to: worker.rawValue,
                           question: "Coordinate the assigned task within the lease budget.")

        let request = try XCTUnwrap(provider.requests.first)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertTrue(toolNames.contains("spawn_agent"))
        XCTAssertTrue(toolNames.contains("remove_agent"))
        XCTAssertTrue(toolNames.contains("list_agents"))
        XCTAssertTrue(toolNames.contains("ask_agent"))
        XCTAssertFalse(toolNames.contains("create_goal"), "only @main receives Goal creation authority")
        XCTAssertTrue(toolNames.contains("get_goal"))

        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("You may also act as a COORDINATOR"))
        XCTAssertTrue(systemPrompt.contains("Proactively drive the user's requested outcome"))
        XCTAssertTrue(systemPrompt.contains("Inspect the bounded INTATIS_SKILL_CATALOG"))
        XCTAssertTrue(systemPrompt.contains("those branches early rather than using collaboration"))
        XCTAssertTrue(systemPrompt.contains("instead of waiting idly"))
        XCTAssertTrue(systemPrompt.contains("out-of-workspace denial"))
        XCTAssertTrue(systemPrompt.contains("spawn_agent is present in the authoritative API tools list"))
        XCTAssertTrue(systemPrompt.contains("directory-scoped work with delegate_task"))
        XCTAssertFalse(systemPrompt.contains("You are executing the assigned task as a worker agent."))

        let events = await log.replay()
        let contract = try XCTUnwrap(leaseTaskCreatedContracts(events).first { $0.assignee == worker })
        let capabilityLeaseID = try XCTUnwrap(contract.capabilityLeaseID)
        let taskLease = try XCTUnwrap(events.compactMap { envelope -> CapabilityLeaseCreatedPayload? in
            if case .capabilityLeaseCreated(let payload) = envelope.event,
               payload.lease.id == capabilityLeaseID {
                return payload
            }
            return nil
        }.first?.lease)
        XCTAssertEqual(taskLease.taskID, contract.id)
        XCTAssertTrue(taskLease.tools.contains(.delegateTask))
        XCTAssertTrue(taskLease.tools.contains(.attachWorkspace))
        if case .granted = taskLease.delegation {
            // Expected coordinator delegation grant.
        } else {
            XCTFail("coordinator task lease must retain a delegation grant")
        }
    }

    func testAskTaskContractReferencesCapabilityAndWorkspaceLeases() async throws {
        let log = try leaseTempLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let wsMain = try leaseTempWorkspace()
        let ws = try leaseTempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: ws)
        }
        let provider = LeaseCapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: wsMain,
                                                   model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let attached = await orch.attach(Agent(name: worker,
                                               workspaceRoot: ws,
                                               model: ModelID(rawValue: "m"),
                                               profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(attached)
        _ = await orch.ask(from: main,
                           to: worker.rawValue,
                           question: "Count assigned Swift files.")

        let events = await log.replay()
        let contract = try XCTUnwrap(leaseTaskCreatedContracts(events).first)
        let capabilityLeaseID = try XCTUnwrap(contract.capabilityLeaseID)
        let workspaceLeaseID = try XCTUnwrap(contract.workspaceLeaseID)
        let capabilityLease = try XCTUnwrap(events.compactMap { envelope -> CapabilityLeaseCreatedPayload? in
            if case .capabilityLeaseCreated(let payload) = envelope.event,
               payload.lease.id == capabilityLeaseID {
                return payload
            }
            return nil
        }.first?.lease)
        let workspaceLease = try XCTUnwrap(events.compactMap { envelope -> WorkspaceLeaseGrantedPayload? in
            if case .workspaceLeaseGranted(let payload) = envelope.event,
               payload.lease.id == workspaceLeaseID {
                return payload
            }
            return nil
        }.first?.lease)

        XCTAssertEqual(capabilityLease.taskID, contract.id)
        XCTAssertTrue(capabilityLease.expiresAtTaskCompletion)
        XCTAssertFalse(capabilityLease.tools.contains(.delegateTask))
        XCTAssertFalse(capabilityLease.tools.contains(.attachWorkspace))
        XCTAssertEqual(workspaceLease.taskID, contract.id)
        XCTAssertTrue(workspaceLease.expiresAtTaskCompletion)
        XCTAssertEqual(workspaceLease.access, .readOnly)
        XCTAssertEqual(workspaceLease.rootPath, ws.standardizedFileURL.path)
        XCTAssertEqual(contract.workspaceID, workspaceLease.workspaceID)
        let liveCapabilityLease = await orch.capabilityLease(id: capabilityLeaseID)
        let liveWorkspaceLease = await orch.workspaceLease(id: workspaceLeaseID)
        XCTAssertNil(liveCapabilityLease)
        XCTAssertNil(liveWorkspaceLease)
        XCTAssertTrue(events.contains {
            if case .capabilityLeaseRevoked(let payload) = $0.event {
                return payload.leaseID == capabilityLeaseID && payload.agent == worker
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .workspaceLeaseRevoked(let payload) = $0.event {
                return payload.leaseID == workspaceLeaseID && payload.agent == worker
            }
            return false
        })
    }

    func testWorkspaceAttachCreatesLeaseOnlyAfterPermission() async throws {
        let deniedLog = try leaseTempLog()
        let deniedWorkspace = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: deniedWorkspace) }
        let denied = Orchestrator(log: deniedLog, allowsShell: true, responder: FixedResponder(.deny)) { _ in LeaseCapturingProvider() }

        let deniedAttached = await denied.attach(Agent(name: AgentID(rawValue: "denied"),
                                                       workspaceRoot: deniedWorkspace,
                                                       model: ModelID(rawValue: "m"),
                                                       profile: .reviewed))
        XCTAssertFalse(deniedAttached)
        let deniedLeases = await denied.workspaceLeaseList()
        XCTAssertTrue(deniedLeases.isEmpty)
        let deniedEvents = await deniedLog.replay()
        XCTAssertTrue(deniedEvents.contains {
            if case .permissionRequest(let payload) = $0.event {
                return payload.tool == "agent.attach"
            }
            return false
        })

        let allowedLog = try leaseTempLog()
        let allowedWorkspace = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: allowedWorkspace) }
        let allowed = Orchestrator(log: allowedLog, allowsShell: true, responder: FixedResponder(.allow)) { _ in LeaseCapturingProvider() }
        let allowedAttached = await allowed.attach(Agent(name: AgentID(rawValue: "allowed"),
                                                         workspaceRoot: allowedWorkspace,
                                                         model: ModelID(rawValue: "m"),
                                                         profile: .reviewed))
        XCTAssertTrue(allowedAttached)
        let allowedLeases = await allowed.workspaceLeaseList()
        let allowedPath = allowedWorkspace.standardizedFileURL.path
        XCTAssertTrue(allowedLeases.contains { lease in
            lease.rootPath == allowedPath && lease.access == .readWrite
        })
    }

    func testCounterWorkersGetWorkerLeasesAndNoDelegationTools() async throws {
        let log = try leaseTempLog()
        let main = AgentID(rawValue: "main")
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try leaseTempWorkspace()
        let wsMacos = try leaseTempWorkspace()
        let wsIOS = try leaseTempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let macosProvider = LeaseCapturingProvider()
        let iosProvider = LeaseCapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == macos ? macosProvider : iosProvider
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

        _ = await orch.ask(from: main, to: macos.rawValue,
                           question: "Recursively count macOS Swift files only.")
        _ = await orch.ask(from: main, to: ios.rawValue,
                           question: "Recursively count iOS Swift files only.")

        let events = await log.replay()
        let contracts = leaseTaskCreatedContracts(events)
        let macosContract = try XCTUnwrap(contracts.first { $0.assignee == macos })
        let iosContract = try XCTUnwrap(contracts.first { $0.assignee == ios })
        let macosCapabilityLeaseID = try XCTUnwrap(macosContract.capabilityLeaseID)
        let iosCapabilityLeaseID = try XCTUnwrap(iosContract.capabilityLeaseID)
        let createdTaskLeases = events.compactMap { envelope -> CapabilityLease? in
            if case .capabilityLeaseCreated(let payload) = envelope.event,
               payload.lease.taskID != nil {
                return payload.lease
            }
            return nil
        }
        let macosLease = try XCTUnwrap(createdTaskLeases.first { $0.id == macosCapabilityLeaseID })
        let iosLease = try XCTUnwrap(createdTaskLeases.first { $0.id == iosCapabilityLeaseID })

        XCTAssertEqual(macosLease.taskID, macosContract.id)
        XCTAssertEqual(iosLease.taskID, iosContract.id)
        XCTAssertFalse(macosLease.tools.contains(.delegateTask))
        XCTAssertFalse(iosLease.tools.contains(.delegateTask))
        XCTAssertFalse(macosLease.tools.contains(.attachWorkspace))
        XCTAssertFalse(iosLease.tools.contains(.attachWorkspace))
        XCTAssertTrue(events.contains {
            if case .capabilityLeaseRevoked(let payload) = $0.event {
                return payload.leaseID == macosCapabilityLeaseID
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .capabilityLeaseRevoked(let payload) = $0.event {
                return payload.leaseID == iosCapabilityLeaseID
            }
            return false
        })

        let macosToolNames = Set(try XCTUnwrap(macosProvider.requests.first).tools.map(\.name))
        let iosToolNames = Set(try XCTUnwrap(iosProvider.requests.first).tools.map(\.name))
        XCTAssertFalse(macosToolNames.contains("spawn_agent"))
        XCTAssertFalse(macosToolNames.contains("ask_agent"))
        XCTAssertFalse(iosToolNames.contains("spawn_agent"))
        XCTAssertFalse(iosToolNames.contains("ask_agent"))
    }
}
