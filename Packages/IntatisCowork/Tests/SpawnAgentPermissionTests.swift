import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private struct EmptyProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class SpawnAgentPermissionTests: XCTestCase {
    private func tempLog() throws -> EventLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-spawn-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        return try EventLog(session: SessionID.new(), fileURL: url)
    }

    private func tempWorkspace(name: String = "ws") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func orchestrator(log: EventLog, decision: PermissionDecision) -> Orchestrator {
        Orchestrator(log: log, allowsShell: true, responder: FixedResponder(decision)) { _ in EmptyProvider() }
    }

    func testAttachNormalWorkspaceCreatesPermissionRequest() async throws {
        let log = try tempLog()
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let orch = orchestrator(log: log, decision: .allow)

        let attached = await orch.attach(Agent(name: AgentID(rawValue: "A"), workspaceRoot: ws,
                                               model: ModelID(rawValue: "m"), profile: .reviewed))

        XCTAssertTrue(attached)
        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
        XCTAssertTrue(types.contains(.permissionResolved))
        XCTAssertTrue(types.contains(.agentAttached))
    }

    func testAttachRootDeniedEvenIfResponderAllows() async throws {
        let log = try tempLog()
        let orch = orchestrator(log: log, decision: .allow)

        let attached = await orch.attach(Agent(name: AgentID(rawValue: "root"), workspaceRoot: URL(fileURLWithPath: "/"),
                                               model: ModelID(rawValue: "m"), profile: .reviewed))
        let agents = await orch.agentList()

        XCTAssertFalse(attached)
        XCTAssertTrue(agents.isEmpty)
        let resolved = await log.replay().compactMap { env -> PermissionResolvedPayload? in
            if case .permissionResolved(let p) = env.event { return p }
            return nil
        }
        XCTAssertEqual(resolved.last?.decision, .deny)
    }

    func testAttachHomeDeniedEvenIfResponderAllows() async throws {
        let log = try tempLog()
        let orch = orchestrator(log: log, decision: .allow)
        let home = FileManager.default.homeDirectoryForCurrentUser

        let attached = await orch.attach(Agent(name: AgentID(rawValue: "home"), workspaceRoot: home,
                                               model: ModelID(rawValue: "m"), profile: .reviewed))

        XCTAssertFalse(attached)
    }

    func testAttachSensitiveDirDenied() async throws {
        let log = try tempLog()
        let ws = try tempWorkspace()
        let sensitive = ws.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sensitive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }
        let orch = orchestrator(log: log, decision: .allow)

        let attached = await orch.attach(Agent(name: AgentID(rawValue: "ssh"), workspaceRoot: sensitive,
                                               model: ModelID(rawValue: "m"), profile: .reviewed))

        XCTAssertFalse(attached)
    }

    func testAgentPermissionProfilesAreIndependent() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(name: "a")
        let wsB = try tempWorkspace(name: "b")
        defer {
            try? FileManager.default.removeItem(at: wsA)
            try? FileManager.default.removeItem(at: wsB)
        }
        let orch = orchestrator(log: log, decision: .allow)

        await orch.attach(Agent(name: AgentID(rawValue: "A"), workspaceRoot: wsA,
                                model: ModelID(rawValue: "m"), profile: .manual))
        await orch.attach(Agent(name: AgentID(rawValue: "B"), workspaceRoot: wsB,
                                model: ModelID(rawValue: "m"), profile: .readOnly))

        let profiles = await Dictionary(uniqueKeysWithValues: orch.agentList().map { ($0.name.rawValue, $0.profile) })
        XCTAssertEqual(profiles["A"], .manual)
        XCTAssertEqual(profiles["B"], .readOnly)
    }

    func testSpawnAgentCannotSilentlyAttachAnotherWorkspace() async throws {
        let log = try tempLog()
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let orch = orchestrator(log: log, decision: .deny)

        let message = await orch.spawnFromTool(
            requestedBy: Orchestrator.mainAgentID,
            name: "worker",
            path: ws.path,
            model: "m")
        let agents = await orch.agentList()

        XCTAssertTrue(message.contains("permission denied"))
        XCTAssertTrue(agents.isEmpty)
        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
        XCTAssertTrue(types.contains(.permissionResolved))
    }
}
