import XCTest
import IntatisCore
@testable import IntatisProtocol

final class CapabilityLeaseTests: XCTestCase {
    func testWorkerLeaseDoesNotGrantDirectDelegation() throws {
        let lease = CapabilityLease.worker(taskID: TaskID(rawValue: "task_worker"))

        XCTAssertTrue(lease.tools.contains(.readWorkspace))
        XCTAssertTrue(lease.tools.contains(.listWorkspace))
        XCTAssertTrue(lease.tools.contains(.searchWorkspace))
        XCTAssertTrue(lease.tools.contains(.readPDF))
        XCTAssertTrue(lease.tools.contains(.requestDelegation))
        XCTAssertFalse(lease.tools.contains(.delegateTask))
        XCTAssertFalse(lease.tools.contains(.attachWorkspace))
        XCTAssertFalse(lease.tools.contains(.generateMedia))
        XCTAssertFalse(lease.tools.contains(.browseWeb))
        XCTAssertFalse(lease.tools.contains(.gitControl))
        XCTAssertFalse(lease.tools.contains(.gitRemote))
        XCTAssertEqual(lease.delegation, .requestOnly)
    }

    func testCoordinatorLeaseGrantsDelegationTools() {
        let lease = CapabilityLease.coordinator(taskID: TaskID(rawValue: "task_coord"))

        XCTAssertTrue(lease.tools.contains(.delegateTask))
        XCTAssertTrue(lease.tools.contains(.attachWorkspace))
        XCTAssertTrue(lease.tools.contains(.requestInformation))
        XCTAssertTrue(lease.tools.contains(.editPDF))
        XCTAssertTrue(lease.tools.contains(.compileLaTeX))
        XCTAssertTrue(lease.tools.contains(.generateMedia))
        XCTAssertTrue(lease.tools.contains(.browseWeb))
        XCTAssertTrue(lease.tools.contains(.gitControl))
        XCTAssertTrue(lease.tools.contains(.gitRemote))
        XCTAssertTrue(lease.tools.contains(.runShell))
        guard case .granted(let budget) = lease.delegation else {
            return XCTFail("coordinator lease should grant delegation")
        }
        XCTAssertGreaterThan(budget.maxTasks, 0)
    }

    func testReadWriteWorkerReceivesManagedTerminalCapability() {
        let readOnly = CapabilityLease.worker(workspaceAccess: .readOnly)
        let readWrite = CapabilityLease.worker(workspaceAccess: .readWrite)

        XCTAssertFalse(readOnly.tools.contains(.runShell))
        XCTAssertTrue(readWrite.tools.contains(.runShell))
    }

    func testCapabilityLeaseCodableRoundTrip() throws {
        let lease = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_1"),
            taskID: TaskID(rawValue: "task_1"),
            tools: [.readWorkspace, .delegateTask],
            communication: .anyAgentInThread,
            delegation: .granted(DelegationBudget(maxTasks: 2, maxDepth: 1)))

        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(CapabilityLease.self, from: data)

        XCTAssertEqual(decoded, lease)
    }
}
