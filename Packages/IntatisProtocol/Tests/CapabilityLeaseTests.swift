import Foundation
import XCTest
import IntatisCore
@testable import IntatisProtocol

final class CapabilityLeaseTests: XCTestCase {
    private static let documentCapabilities: Set<ToolCapability> = [
        .readDOCX,
        .readPPTX,
        .readXLSX,
        .readHTML,
        .readEPUB,
        .documentOCR,
        .documentRender,
        .documentExportPDF,
        .documentWrite,
    ]

    private static let documentObservationCapabilities: Set<ToolCapability> = [
        .readDOCX,
        .readPPTX,
        .readXLSX,
        .readHTML,
        .readEPUB,
        .documentOCR,
    ]

    private static let documentMutationCapabilities: Set<ToolCapability> = [
        .documentRender,
        .documentExportPDF,
        .documentWrite,
    ]

    private static let legacyDocumentCapabilities: Set<ToolCapability> = [
        .documentRead,
        .readDocument,
        .editPDF,
        .reconstructDocument,
    ]

    func testWorkerLeaseDoesNotGrantDirectDelegation() throws {
        let lease = CapabilityLease.worker(taskID: TaskID(rawValue: "task_worker"))

        XCTAssertTrue(lease.tools.contains(.readWorkspace))
        XCTAssertTrue(lease.tools.contains(.listWorkspace))
        XCTAssertTrue(lease.tools.contains(.searchWorkspace))
        XCTAssertTrue(lease.tools.contains(.readPDF))
        XCTAssertTrue(Self.documentObservationCapabilities.isSubset(of: lease.tools))
        XCTAssertFalse(lease.tools.contains(.hostedWebSearch))
        XCTAssertTrue(lease.tools.isDisjoint(with: Self.documentMutationCapabilities))
        XCTAssertTrue(lease.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        XCTAssertFalse(lease.tools.contains(.delegateTask))
        XCTAssertFalse(lease.tools.contains(.attachWorkspace))
        XCTAssertFalse(lease.tools.contains(.generateMedia))
        XCTAssertFalse(lease.tools.contains(.browseWeb))
        XCTAssertFalse(lease.tools.contains(.gitControl))
        XCTAssertFalse(lease.tools.contains(.gitRemote))
        XCTAssertEqual(lease.delegation, .none)
    }

    func testCoordinatorLeaseGrantsDelegationTools() {
        let lease = CapabilityLease.coordinator(taskID: TaskID(rawValue: "task_coord"))

        XCTAssertTrue(lease.tools.contains(.delegateTask))
        XCTAssertTrue(lease.tools.contains(.attachWorkspace))
        XCTAssertTrue(lease.tools.contains(.requestInformation))
        XCTAssertTrue(Self.documentCapabilities.isSubset(of: lease.tools))
        XCTAssertTrue(lease.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        XCTAssertTrue(lease.tools.contains(.compileLaTeX))
        XCTAssertTrue(lease.tools.contains(.generateMedia))
        XCTAssertTrue(lease.tools.contains(.browseWeb))
        XCTAssertTrue(lease.tools.contains(.hostedWebSearch))
        XCTAssertTrue(lease.tools.contains(.gitControl))
        XCTAssertTrue(lease.tools.contains(.gitRemote))
        XCTAssertTrue(lease.tools.contains(.runShell))
        guard case .granted(let budget) = lease.delegation else {
            return XCTFail("coordinator lease should grant delegation")
        }
        XCTAssertGreaterThan(budget.maxTasks, 0)
        XCTAssertEqual(budget.maxDepth, 1)
    }

    func testReadWriteWorkerReceivesManagedTerminalCapability() {
        let readOnly = CapabilityLease.worker(workspaceAccess: .readOnly)
        let readWrite = CapabilityLease.worker(workspaceAccess: .readWrite)

        XCTAssertFalse(readOnly.tools.contains(.runShell))
        XCTAssertTrue(readWrite.tools.contains(.runShell))
        XCTAssertFalse(readOnly.tools.contains(.hostedWebSearch))
        XCTAssertTrue(readWrite.tools.contains(.hostedWebSearch))
        XCTAssertTrue(Self.documentObservationCapabilities.isSubset(of: readOnly.tools))
        XCTAssertTrue(readOnly.tools.isDisjoint(with: Self.documentMutationCapabilities))
        XCTAssertTrue(Self.documentCapabilities.isSubset(of: readWrite.tools))
        XCTAssertTrue(readOnly.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        XCTAssertTrue(readWrite.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
    }

    func testLegacyDocumentCapabilitiesDecodeButFreshLeasesDoNotIssueThem() throws {
        let template = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_legacy_document"),
            tools: [])
        let templateData = try JSONEncoder().encode(template)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: templateData) as? [String: Any])
        payload["tools"] = [
            "document_read",
            "read_document",
            "edit_pdf",
            "reconstruct_document",
        ]

        let legacyData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(CapabilityLease.self, from: legacyData)

        XCTAssertEqual(decoded.tools, Self.legacyDocumentCapabilities)

        let freshLeases = [
            CapabilityLease.worker(workspaceAccess: .readOnly),
            CapabilityLease.worker(workspaceAccess: .readWrite),
            CapabilityLease.coordinator(workspaceAccess: .readOnly),
            CapabilityLease.coordinator(workspaceAccess: .readWrite),
        ]
        for lease in freshLeases {
            XCTAssertTrue(lease.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        }
    }

    func testSplitDocumentReadCapabilitiesEncodeWithConcreteToolNames() throws {
        let expected: [ToolCapability: String] = [
            .readDOCX: "read_docx",
            .readPPTX: "read_pptx",
            .readXLSX: "read_xlsx",
            .readHTML: "read_html",
            .readEPUB: "read_epub",
        ]

        for (capability, rawValue) in expected {
            XCTAssertEqual(capability.rawValue, rawValue)
            let encoded = try JSONEncoder().encode(capability)
            XCTAssertEqual(try JSONDecoder().decode(ToolCapability.self, from: encoded), capability)
        }
    }

    func testSplitDocumentReadToolsDeriveDocumentReadAction() {
        for toolName in ["read_docx", "read_pptx", "read_xlsx", "read_html", "read_epub"] {
            let intent = PermissionIntent.derived(
                toolName: toolName,
                sideEffect: .exec,
                touchedPaths: ["document"],
                risksNetwork: false)
            XCTAssertEqual(intent.action, "document.read", toolName)
        }
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
