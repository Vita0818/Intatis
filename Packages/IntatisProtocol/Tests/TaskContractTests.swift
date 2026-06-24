import XCTest
import IntatisCore
@testable import IntatisProtocol

final class TaskContractTests: XCTestCase {
    private let encoder = Envelope.makeEncoder()
    private let decoder = Envelope.makeDecoder()

    func testTaskContractCodableRoundTrip() throws {
        let contract = TaskContract(
            id: TaskID(rawValue: "task_count_macos"),
            kind: .agentInvocation,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "macos-counter"),
            parentTaskID: TaskID(rawValue: "task_root"),
            objective: "Recursively count macOS Swift files.",
            roleHint: "macOS Swift file counter",
            expectedDeliverable: "File count and path list.",
            workspaceID: WorkspaceID(rawValue: "workspace_macos"),
            workspaceLeaseID: WorkspaceLeaseID(rawValue: "wlease_macos"),
            capabilityLeaseID: CapabilityLeaseID(rawValue: "clease_macos"),
            relatedAgents: [AgentID(rawValue: "ios-counter")],
            relatedTasks: [TaskID(rawValue: "task_count_ios")],
            constraints: ["Complete only the assigned task."])

        let data = try JSONEncoder().encode(contract)
        let decoded = try JSONDecoder().decode(TaskContract.self, from: data)

        XCTAssertEqual(decoded, contract)
        XCTAssertEqual(decoded.workspaceLeaseID, WorkspaceLeaseID(rawValue: "wlease_macos"))
        XCTAssertEqual(decoded.capabilityLeaseID, CapabilityLeaseID(rawValue: "clease_macos"))
    }

    func testTaskEventsRoundTripThroughEnvelope() throws {
        let contract = TaskContract(
            id: TaskID(rawValue: "task_1"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            objective: "Inspect the assigned workspace.",
            roleHint: "workspace inspector",
            expectedDeliverable: "Summary of findings.",
            constraints: ["Complete only the assigned task."])

        try roundTrip(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1),
                               session: SessionID(rawValue: "sess_task"),
                               event: .taskCreated(.init(contract: contract))))
        try roundTrip(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 2),
                               session: SessionID(rawValue: "sess_task"),
                               event: .taskAssigned(.init(contract: contract))))
    }

    private func roundTrip(_ envelope: Envelope, line: UInt = #line) throws {
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(Envelope.self, from: data)
        XCTAssertEqual(decoded, envelope, line: line)
    }
}
