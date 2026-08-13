import Foundation
import IntatisProtocol
@testable import IntatisTools
import XCTest

final class DocumentReadToolSplitTests: XCTestCase {
    func testStandardRegistryExposesOneReaderPerFormatAndNoAggregateReader() {
        let registry = ToolRegistry.standard()

        for name in ["read_docx", "read_pptx", "read_xlsx", "read_html", "read_epub"] {
            XCTAssertNotNil(registry.tool(named: name), name)
        }
        XCTAssertNil(registry.tool(named: "document_read"))
        XCTAssertEqual(registry.registryVersion, "intatis.standard.v4")
    }

    func testReadersExposeOnlyPathAndCharacterBudget() throws {
        let descriptors = [
            ReadDOCXTool.descriptor,
            ReadPPTXTool.descriptor,
            ReadXLSXTool.descriptor,
            ReadHTMLTool.descriptor,
            ReadEPUBTool.descriptor,
        ]

        for descriptor in descriptors {
            XCTAssertEqual(descriptor.sideEffect, .exec)
            guard case .object(let schema) = descriptor.parameters,
                  case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(descriptor.name) must expose an object schema")
            }
            XCTAssertEqual(Set(properties.keys), ["path", "maxCharacters"])
            XCTAssertEqual(schema["additionalProperties"], .bool(false))
            let encoded = String(
                data: try JSONEncoder().encode(descriptor.parameters),
                encoding: .utf8) ?? ""
            for forbidden in ["format", "options", "sheet", "range", "xpath", "backend"] {
                XCTAssertFalse(encoded.contains("\"\(forbidden)\""), "\(descriptor.name): \(forbidden)")
            }
        }
    }

    func testEachReaderOwnsItsFileExtension() throws {
        XCTAssertNoThrow(try ReadDOCXTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.docx","maxCharacters":12000}"#)))
        XCTAssertNoThrow(try ReadPPTXTool().validateArguments(
            ToolArgs(raw: #"{"path":"slides.pptx"}"#)))
        XCTAssertNoThrow(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"table.xlsx"}"#)))
        XCTAssertNoThrow(try ReadHTMLTool().validateArguments(
            ToolArgs(raw: #"{"path":"page.html"}"#)))
        XCTAssertNoThrow(try ReadEPUBTool().validateArguments(
            ToolArgs(raw: #"{"path":"book.epub"}"#)))

        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"slides.pptx"}"#)))
        XCTAssertThrowsError(try ReadDOCXTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.docx","format":"docx"}"#)))
        XCTAssertThrowsError(try ReadHTMLTool().validateArguments(
            ToolArgs(raw: #"{"path":"page.html","options":{}}"#)))
        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"table.xlsx","maxCharacters":0}"#)))
        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"table.xlsx","maxCharacters":500001}"#)))
        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"maxCharacters":12000}"#)))
    }

    func testReadersAreReviewedProcessExecutionsButSafeToReplay() {
        let workspace = URL(fileURLWithPath: "/workspace")
        let cases: [(PermissionIntent, DocumentFormat)] = [
            (ReadDOCXTool().permissionIntent(
                ToolArgs(raw: #"{"path":"notes.docx"}"#), workspaceRoot: workspace), .docx),
            (ReadPPTXTool().permissionIntent(
                ToolArgs(raw: #"{"path":"slides.pptx"}"#), workspaceRoot: workspace), .pptx),
            (ReadXLSXTool().permissionIntent(
                ToolArgs(raw: #"{"path":"table.xlsx"}"#), workspaceRoot: workspace), .xlsx),
            (ReadHTMLTool().permissionIntent(
                ToolArgs(raw: #"{"path":"page.html"}"#), workspaceRoot: workspace), .html),
            (ReadEPUBTool().permissionIntent(
                ToolArgs(raw: #"{"path":"book.epub"}"#), workspaceRoot: workspace), .epub),
        ]

        for (intent, format) in cases {
            XCTAssertEqual(intent.action, "document.read.\(format.rawValue)")
            XCTAssertEqual(intent.dataEffects, [.read, .execute])
            XCTAssertEqual(intent.risks, [.processExecution])
            XCTAssertEqual(intent.replayPolicy, .safeToReplay)
            XCTAssertTrue(intent.isStructuredReadOnlyExecution)
            XCTAssertTrue(intent.isReadOnlyWorkspaceCompatible)
        }
    }
}
