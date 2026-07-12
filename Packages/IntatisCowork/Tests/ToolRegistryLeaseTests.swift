import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
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

        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("You may also act as a COORDINATOR"))
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
