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
    }

    func testTaskLeaseOverridesCoordinationDepthForToolRegistryAndPrompt() async throws {
        let log = try leaseTempLog()
        let worker = AgentID(rawValue: "legacy-depth-worker")
        let ws = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = LeaseCapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        let attached = await orch.attach(Agent(name: worker,
                                               workspaceRoot: ws,
                                               model: ModelID(rawValue: "m"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        _ = await orch.ask(from: AgentID(rawValue: "main"),
                           to: worker.rawValue,
                           question: "Inspect the assigned worker task only.")

        let request = try XCTUnwrap(provider.requests.first)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertFalse(toolNames.contains("spawn_agent"))
        XCTAssertFalse(toolNames.contains("remove_agent"))
        XCTAssertFalse(toolNames.contains("list_agents"))
        XCTAssertFalse(toolNames.contains("ask_agent"))

        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("You are executing the assigned task as a worker agent."))
        XCTAssertFalse(systemPrompt.contains("You may also act as a COORDINATOR"))
    }

    func testAskTaskContractReferencesCapabilityAndWorkspaceLeases() async throws {
        let log = try leaseTempLog()
        let worker = AgentID(rawValue: "worker")
        let ws = try leaseTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = LeaseCapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        let attached = await orch.attach(Agent(name: worker,
                                               workspaceRoot: ws,
                                               model: ModelID(rawValue: "m"),
                                               profile: .reviewed))
        XCTAssertTrue(attached)
        _ = await orch.ask(from: AgentID(rawValue: "main"),
                           to: worker.rawValue,
                           question: "Count assigned Swift files.")

        let events = await log.replay()
        let contract = try XCTUnwrap(leaseTaskCreatedContracts(events).first)
        let capabilityLeaseID = try XCTUnwrap(contract.capabilityLeaseID)
        let workspaceLeaseID = try XCTUnwrap(contract.workspaceLeaseID)
        let capabilityLeaseOptional = await orch.capabilityLease(id: capabilityLeaseID)
        let workspaceLeaseOptional = await orch.workspaceLease(id: workspaceLeaseID)
        let capabilityLease = try XCTUnwrap(capabilityLeaseOptional)
        let workspaceLease = try XCTUnwrap(workspaceLeaseOptional)

        XCTAssertEqual(capabilityLease.taskID, contract.id)
        XCTAssertFalse(capabilityLease.tools.contains(.delegateTask))
        XCTAssertFalse(capabilityLease.tools.contains(.attachWorkspace))
        XCTAssertEqual(workspaceLease.access, .readOnly)
        XCTAssertEqual(workspaceLease.rootPath, ws.standardizedFileURL.path)
        XCTAssertEqual(contract.workspaceID, workspaceLease.workspaceID)
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

        let contracts = leaseTaskCreatedContracts(await log.replay())
        let macosContract = try XCTUnwrap(contracts.first { $0.assignee == macos })
        let iosContract = try XCTUnwrap(contracts.first { $0.assignee == ios })
        let macosCapabilityLeaseID = try XCTUnwrap(macosContract.capabilityLeaseID)
        let iosCapabilityLeaseID = try XCTUnwrap(iosContract.capabilityLeaseID)
        let macosLeaseOptional = await orch.capabilityLease(id: macosCapabilityLeaseID)
        let iosLeaseOptional = await orch.capabilityLease(id: iosCapabilityLeaseID)
        let macosLease = try XCTUnwrap(macosLeaseOptional)
        let iosLease = try XCTUnwrap(iosLeaseOptional)

        XCTAssertFalse(macosLease.tools.contains(.delegateTask))
        XCTAssertFalse(iosLease.tools.contains(.delegateTask))
        XCTAssertFalse(macosLease.tools.contains(.attachWorkspace))
        XCTAssertFalse(iosLease.tools.contains(.attachWorkspace))

        let macosToolNames = Set(try XCTUnwrap(macosProvider.requests.first).tools.map(\.name))
        let iosToolNames = Set(try XCTUnwrap(iosProvider.requests.first).tools.map(\.name))
        XCTAssertFalse(macosToolNames.contains("spawn_agent"))
        XCTAssertFalse(macosToolNames.contains("ask_agent"))
        XCTAssertFalse(iosToolNames.contains("spawn_agent"))
        XCTAssertFalse(iosToolNames.contains("ask_agent"))
    }
}
