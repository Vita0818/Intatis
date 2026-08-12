import Foundation
import IntatisProtocol
@testable import IntatisTools
import XCTest

private struct FixedPythonEnvelopeRunner: DocumentBackendRunner {
    let result: ShellResult

    func run(
        _ invocation: DocumentBackendInvocation,
        cwd: URL
    ) async throws -> ShellResult {
        result
    }
}

final class DocumentPythonWriteBackendTests: XCTestCase {
    func testEmbeddedProgramIsValidPython() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable for syntax checking")
        }
        let invocation = try DocumentPythonBackend.invocation(
            operation: "write",
            payload: .object([
                "format": .string("html"),
                "mode": .string("create"),
                "output_path": .string("/tmp/unused.htm"),
                "operations": .array([]),
            ]),
            readableWorkspacePaths: [])
        guard let program = invocation.arguments.last else {
            return XCTFail("embedded Python program is missing")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import sys; compile(sys.argv[1], 'DocumentPythonBackend', 'exec')",
            program,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
    }

    func testOCRPageSelectionSplitsSparsePagesIntoContiguousRuns() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable for helper checking")
        }
        let invocation = try DocumentPythonBackend.invocation(
            operation: "ocr",
            payload: .object([:]),
            readableWorkspacePaths: [])
        guard let program = invocation.arguments.last else {
            return XCTFail("embedded Python program is missing")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            #"""
import sys
source = sys.argv[1]
marker = "\ntry:\n    main()"
cutoff = source.rfind(marker)
assert cutoff >= 0
namespace = {}
exec(source[:cutoff], namespace)
assert namespace['contiguous_page_runs']([1, 2, 4, 100]) == [(1, 2), (4, 4), (100, 100)]
"""#,
            program,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
    }

    func testUnexpectedPythonExceptionReturnsOnlyFixedSanitizedSummary() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable for exception checking")
        }
        let program = try embeddedProgram()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-c", program]
        var environment = ProcessInfo.processInfo.environment
        environment["INTATIS_DOCUMENT_REQUEST"] = "{not-json-/private/secret.xlsx"
        environment["INTATIS_DOCUMENT_OPERATION"] = "read"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let envelope = try JSONDecoder().decode(
            DocumentBackendEnvelope.self,
            from: outputPipe.fileHandleForReading.readDataToEndOfFile())
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.code, DocumentToolErrorCode.backendFailed.rawValue)
        XCTAssertEqual(envelope.summary, "fixed document backend failed unexpectedly")
        XCTAssertFalse(envelope.summary?.contains("private") ?? true)
        XCTAssertFalse(envelope.summary?.contains("JSON") ?? true)
    }

    func testPythonRequestOperationMustMatchHostEnvironmentBinding() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable for operation binding checking")
        }
        let invocation = try DocumentPythonBackend.invocation(
            operation: "write",
            payload: .object([
                "format": .string("html"),
                "mode": .string("create"),
                "output_path": .string("/tmp/unused.htm"),
                "operations": .array([]),
            ]),
            readableWorkspacePaths: [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in invocation.environment {
            environment[key] = value
        }
        environment["INTATIS_DOCUMENT_OPERATION"] = "read"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let envelope = try JSONDecoder().decode(
            DocumentBackendEnvelope.self,
            from: outputPipe.fileHandleForReading.readDataToEndOfFile())
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.code, DocumentToolErrorCode.validationFailed.rawValue)
        XCTAssertEqual(envelope.summary, "operation binding mismatch")
    }

    func testSwiftBoundaryNeverForwardsBackendFailedSummary() async throws {
        let malicious = #"{"schema_version":1,"ok":false,"code":"backend_failed","summary":"ValueError: /Users/private/customer.xlsx cell SECRET","engine_versions":{},"warnings":[]}"#
        let runner = FixedPythonEnvelopeRunner(
            result: ShellResult(stdout: malicious, stderr: "", exitCode: 0))
        do {
            _ = try await DocumentPythonBackend.run(
                operation: "read",
                payload: .object([:]),
                readableWorkspacePaths: [],
                in: ToolContext(
                    workspaceRoot: FileManager.default.temporaryDirectory,
                    documentBackend: runner))
            XCTFail("backend failure unexpectedly succeeded")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .backendFailed)
            XCTAssertEqual(error.summary, "the fixed document backend failed")
            XCTAssertFalse(error.summary.contains("private"))
            XCTAssertFalse(error.summary.contains("SECRET"))
        }
    }

    func testOOXMLCentralDirectoryPreflightRejectsUnsafeMembersBeforeLibraryOpen() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable for ZIP fixture creation")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-ooxml-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        for fixture in ["traversal", "duplicate", "symlink", "ratio"] {
            let archive = root.appendingPathComponent("\(fixture).docx")
            try runPython(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [
                    "-c",
                    #"""
import stat, sys, warnings, zipfile
path, fixture = sys.argv[1], sys.argv[2]
with warnings.catch_warnings():
    warnings.simplefilter('ignore')
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        if fixture == 'traversal':
            archive.writestr('../word/document.xml', b'x')
        elif fixture == 'duplicate':
            archive.writestr('word/document.xml', b'a')
            archive.writestr('WORD/document.xml', b'b')
        elif fixture == 'symlink':
            info = zipfile.ZipInfo('word/document.xml')
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, b'target')
        else:
            archive.writestr('word/document.xml', b'0' * (2 * 1024 * 1024))
"""#,
                    archive.path,
                    fixture,
                ])
            let envelope = try runBackend(
                runtime: URL(fileURLWithPath: "/usr/bin/python3"),
                operation: "read",
                payload: .object([
                    "format": .string("docx"),
                    "input_path": .string(archive.path),
                ]))
            XCTAssertFalse(envelope.ok, fixture)
            XCTAssertEqual(
                envelope.code,
                DocumentToolErrorCode.validationFailed.rawValue,
                fixture)
        }
    }

    func testOOXMLPreflightRejectsPackageWhoseContentsDoNotMatchRequestedFormat() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable for ZIP fixture creation")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-ooxml-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let disguisedPPTX = root.appendingPathComponent("slides.docx")
        try runPython(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import sys, zipfile; zipfile.ZipFile(sys.argv[1], 'w').writestr('ppt/presentation.xml', b'<p:presentation/>')",
                disguisedPPTX.path,
            ])

        let envelope = try runBackend(
            runtime: URL(fileURLWithPath: "/usr/bin/python3"),
            operation: "read",
            payload: .object([
                "format": .string("docx"),
                "input_path": .string(disguisedPPTX.path),
            ]))
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.code, DocumentToolErrorCode.validationFailed.rawValue)
    }

    func testFixedWritersCreateAndEditSupportedNativeFormats() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-write-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let docx = root.appendingPathComponent("created.docx")
        let docxOperations = [operation("paragraph.add", ["text": .string("hello")])]
        let docxEnvelope = try runWrite(
            runtime: runtime,
            payload: writePayload(
                format: "docx",
                output: docx,
                operations: docxOperations))
        try assertSuccess(docxEnvelope, format: "docx", mode: "create", applied: 1)
        try assertVerified(
            runVerify(runtime: runtime, format: "docx", input: docx, operations: docxOperations),
            format: "docx",
            count: 1)

        let pptx = root.appendingPathComponent("created.pptx")
        let pptxOperations = [
            operation("slide.add", ["title": .string("hello")]),
            operation("shape.add", [
                "slide_index": .number(0),
                "shape_type": .string("line"),
                "x_points": .number(10),
                "y_points": .number(10),
                "width_points": .number(100),
                "height_points": .number(30),
                "text": .string("line label"),
            ]),
        ]
        let pptxEnvelope = try runWrite(
            runtime: runtime,
            payload: writePayload(
                format: "pptx",
                output: pptx,
                operations: pptxOperations))
        try assertSuccess(pptxEnvelope, format: "pptx", mode: "create", applied: 2)
        try assertVerified(
            runVerify(runtime: runtime, format: "pptx", input: pptx, operations: pptxOperations),
            format: "pptx",
            count: 2)

        let xlsx = root.appendingPathComponent("created.xlsx")
        let xlsxOperations = [
            operation("cell.set", [
                "sheet": .string("Sheet"),
                "cell": .string("C3"),
                "value": .string("sparse workbook marker"),
            ]),
            operation("style.set", [
                "sheet": .string("Sheet"),
                "range": .string("C3:C3"),
                "bold": .bool(true),
            ]),
        ]
        let xlsxEnvelope = try runWrite(
            runtime: runtime,
            payload: writePayload(
                format: "xlsx",
                output: xlsx,
                operations: xlsxOperations))
        try assertSuccess(xlsxEnvelope, format: "xlsx", mode: "create", applied: 2)
        try assertVerified(
            runVerify(runtime: runtime, format: "xlsx", input: xlsx, operations: xlsxOperations),
            format: "xlsx",
            count: 2)
        let sparseRead = try runBackend(
            runtime: runtime,
            operation: "read",
            payload: .object([
                "format": .string("xlsx"),
                "input_path": .string(xlsx.path),
                "maximum_characters": .number(100_000),
                "maximum_file_bytes": .number(512 * 1_024 * 1_024),
            ]))
        XCTAssertTrue(sparseRead.ok, sparseRead.summary ?? "sparse XLSX read failed")
        guard case .object(let sparseResult)? = sparseRead.result,
              case .string(let sparseMarkdown)? = sparseResult["markdown"] else {
            return XCTFail("sparse XLSX Markdown result is incomplete")
        }
        XCTAssertTrue(sparseMarkdown.contains("sparse workbook marker"), sparseMarkdown)
        XCTAssertEqual(sparseRead.engineVersions["openpyxl"], "3.1.5")

        let html = root.appendingPathComponent("created.htm")
        let htmlOperations = [operation("xpath.append", [
            "xpath": .string("//body"),
            "expected_match_count": .number(1),
            "html": .string("<p>hello</p>"),
        ])]
        let htmlEnvelope = try runWrite(
            runtime: runtime,
            payload: writePayload(
                format: "html",
                output: html,
                operations: htmlOperations))
        try assertSuccess(htmlEnvelope, format: "html", mode: "create", applied: 1)
        try assertVerified(
            runVerify(runtime: runtime, format: "html", input: html, operations: htmlOperations),
            format: "html",
            count: 1)

        let editedHTML = root.appendingPathComponent("edited.html")
        let editedEnvelope = try runWrite(
            runtime: runtime,
            payload: writePayload(
                format: "html",
                mode: "edit",
                input: html,
                output: editedHTML,
                operations: [operation("xpath.set_text", [
                    "xpath": .string("//p"),
                    "expected_match_count": .number(1),
                    "text": .string("updated"),
                ])]))
        try assertSuccess(editedEnvelope, format: "html", mode: "edit", applied: 1)

        for output in [docx, pptx, xlsx, html, editedHTML] {
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        }
    }

    func testVerifyWriteChecksCompleteXLSXDeclaration() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-verify-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("complete.xlsx")
        let operations = [
            operation("sheet.rename", ["current_name": .string("Sheet"), "new_name": .string("Data")]),
            operation("sheet.add", ["name": .string("Other")]),
            operation("range.set", [
                "sheet": .string("Data"), "start_cell": .string("A1"),
                "values": .array([
                    .array([.string("Category"), .string("Value"), .string("Formula")]),
                    .array([.string("A"), .number(1), .number(2)]),
                    .array([.string("B"), .number(2), .number(4)]),
                ]),
            ]),
            operation("cell.set", ["sheet": .string("Other"), "cell": .string("A1"), "value": .string("hello")]),
            operation("style.set", [
                "sheet": .string("Data"), "range": .string("A1:C1"),
                "bold": .bool(true), "italic": .bool(true),
                "font_color": .string("112233"), "fill_color": .string("DDEEFF"),
                "number_format": .string("General"),
                "horizontal_alignment": .string("center"),
                "vertical_alignment": .string("center"),
            ]),
            operation("table.add", [
                "sheet": .string("Data"), "range": .string("A1:C3"),
                "name": .string("DataTable"), "style": .string("TableStyleMedium2"),
            ]),
            operation("name.set", ["name": .string("Values"), "reference": .string("Data!$B$2:$B$3")]),
            operation("chart.add", [
                "sheet": .string("Data"), "chart_type": .string("column"),
                "data_range": .string("B2:B3"), "category_range": .string("A2:A3"),
                "anchor": .string("E2"), "title": .string("Chart"),
            ]),
        ]
        try assertSuccess(
            runWrite(runtime: runtime, payload: writePayload(format: "xlsx", output: output, operations: operations)),
            format: "xlsx",
            mode: "create",
            applied: operations.count)
        try assertVerified(
            runVerify(runtime: runtime, format: "xlsx", input: output, operations: operations),
            format: "xlsx",
            count: operations.count)

        var wrongChart = operations
        wrongChart[wrongChart.count - 1] = operation("chart.add", [
            "sheet": .string("Data"), "chart_type": .string("column"),
            "data_range": .string("B2:B3"), "category_range": .string("A2:A3"),
            "anchor": .string("E2"), "title": .string("Wrong title"),
        ])
        let rejected = try runVerify(
            runtime: runtime,
            format: "xlsx",
            input: output,
            operations: wrongChart)
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.code, DocumentToolErrorCode.validationFailed.rawValue)

        var wrongTable = operations
        wrongTable[5] = operation("table.add", [
            "sheet": .string("Data"), "range": .string("A1:C3"),
            "name": .string("DataTable"), "style": .string("TableStyleMedium3"),
        ])
        let rejectedTable = try runVerify(
            runtime: runtime,
            format: "xlsx",
            input: output,
            operations: wrongTable)
        XCTAssertFalse(rejectedTable.ok)
        XCTAssertEqual(rejectedTable.code, DocumentToolErrorCode.unsupportedFeature.rawValue)
    }

    func testXLSXFormulaVerificationRequiresAndReadsCalculatedCache() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-xlsx-formula-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let uncalculated = root.appendingPathComponent("uncalculated.xlsx")
        let calculated = root.appendingPathComponent("calculated.xlsx")
        let operations = [
            operation("cell.set", [
                "sheet": .string("Sheet"), "cell": .string("A1"), "value": .number(2),
            ]),
            operation("cell.set", [
                "sheet": .string("Sheet"), "cell": .string("B1"), "value": .string("=A1*2"),
            ]),
        ]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "xlsx",
                    output: uncalculated,
                    operations: operations)),
            format: "xlsx",
            mode: "create",
            applied: operations.count)

        let missingCache = try runVerify(
            runtime: runtime,
            format: "xlsx",
            input: uncalculated,
            operations: operations)
        XCTAssertFalse(missingCache.ok)
        XCTAssertEqual(missingCache.code, DocumentToolErrorCode.unsupportedFeature.rawValue)

        try runPython(
            executable: runtime,
            arguments: [
                "-c",
                #"""
import re, sys, zipfile
source, destination = sys.argv[1:]
with zipfile.ZipFile(source, 'r') as incoming, zipfile.ZipFile(destination, 'w') as outgoing:
    for info in incoming.infolist():
        data = incoming.read(info.filename)
        if info.filename == 'xl/worksheets/sheet1.xml':
            pattern = rb'(<c\s+r="B1"[^>]*>\s*<f[^>]*>A1\*2</f>\s*<v>)[^<]*(</v>)'
            data, count = re.subn(pattern, rb'\g<1>4\g<2>', data, count=1)
            assert count == 1
        outgoing.writestr(info, data)
"""#,
                uncalculated.path,
                calculated.path,
            ])
        try assertVerified(
            runVerify(
                runtime: runtime,
                format: "xlsx",
                input: calculated,
                operations: operations),
            format: "xlsx",
            count: operations.count)
    }

    func testXLSXEditRejectsPreservationHazardsAndExternalFormulas() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-xlsx-preservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let base = root.appendingPathComponent("base.xlsx")
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "xlsx",
                    output: base,
                    operations: [operation("cell.set", [
                        "sheet": .string("Sheet"), "cell": .string("A1"), "value": .number(1),
                    ])])),
            format: "xlsx",
            mode: "create",
            applied: 1)

        let connections = root.appendingPathComponent("connections.xlsx")
        try runPython(
            executable: runtime,
            arguments: [
                "-c",
                "import sys,zipfile; a=zipfile.ZipFile(sys.argv[1]); b=zipfile.ZipFile(sys.argv[2],'w'); [b.writestr(i,a.read(i.filename)) for i in a.infolist()]; b.writestr('xl/connections.xml',b'<connections/>'); a.close(); b.close()",
                base.path,
                connections.path,
            ])

        let externalFormula = root.appendingPathComponent("external.xlsx")
        try runPython(
            executable: runtime,
            arguments: [
                "-c",
                "from openpyxl import Workbook; import sys; w=Workbook(); w.active['A1']=\"='[Outside.xlsx]Sheet1'!A1\"; w.save(sys.argv[1]); w.close()",
                externalFormula.path,
            ])

        let vendorExtension = root.appendingPathComponent("vendor-extension.xlsx")
        try runPython(
            executable: runtime,
            arguments: [
                "-c",
                #"""
import sys, zipfile
source, destination = sys.argv[1:]
with zipfile.ZipFile(source, 'r') as incoming, zipfile.ZipFile(destination, 'w') as outgoing:
    for info in incoming.infolist():
        data = incoming.read(info.filename)
        if info.filename == 'xl/worksheets/sheet1.xml':
            data = data.replace(b'</worksheet>', b'<extLst/></worksheet>')
        outgoing.writestr(info, data)
"""#,
                base.path,
                vendorExtension.path,
            ])

        for (index, input) in [connections, externalFormula, vendorExtension].enumerated() {
            let destination = root.appendingPathComponent("rejected-\(index).xlsx")
            let envelope = try runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "xlsx",
                    mode: "edit",
                    input: input,
                    output: destination,
                    operations: [operation("cell.set", [
                        "sheet": .string("Sheet"), "cell": .string("B1"), "value": .number(2),
                    ])]))
            XCTAssertFalse(envelope.ok, input.lastPathComponent)
            XCTAssertEqual(
                envelope.code,
                DocumentToolErrorCode.unsupportedFeature.rawValue,
                input.lastPathComponent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testVerifyHTMLAcceptsOnlyExplicitAllowlistedLocalAssets() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-verify-html-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = root.appendingPathComponent("pixel.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: asset, options: .withoutOverwriting)
        let output = root.appendingPathComponent("asset.html")
        let operations = [operation("xpath.append", [
            "xpath": .string("//body"),
            "expected_match_count": .number(1),
            "html": .string("<img src=\"\(asset.path)\">")
        ])]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "html",
                    output: output,
                    operations: operations,
                    allowedAssets: [asset])),
            format: "html",
            mode: "create",
            applied: 1)
        try assertVerified(
            runVerify(
                runtime: runtime,
                format: "html",
                input: output,
                operations: operations,
                allowedAssets: [asset]),
            format: "html",
            count: 1)

        let missingAllowlist = try runVerify(
            runtime: runtime,
            format: "html",
            input: output,
            operations: operations)
        XCTAssertFalse(missingAllowlist.ok)
        XCTAssertEqual(missingAllowlist.code, DocumentToolErrorCode.unsupportedFeature.rawValue)
    }

    func testWriteVerifiersHonorFinalStateAfterConsecutiveOverwrites() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-final-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let docx = root.appendingPathComponent("final.docx")
        let docxOperations = [
            operation("paragraph.add", ["text": .string("initial")]),
            operation("run.add", ["paragraph_index": .number(0), "text": .string(" discarded")]),
            operation("paragraph.set_text", ["paragraph_index": .number(0), "text": .string("final")]),
            operation("run.add", [
                "paragraph_index": .number(0), "text": .string("!"), "bold": .bool(true),
            ]),
            operation("table.add", [
                "values": .array([.array([.string("old")])]),
            ]),
            operation("table.set_cell", [
                "table_index": .number(0), "row_index": .number(0),
                "column_index": .number(0), "text": .string("new"),
            ]),
        ]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(format: "docx", output: docx, operations: docxOperations)),
            format: "docx",
            mode: "create",
            applied: docxOperations.count)
        try assertVerified(
            runVerify(runtime: runtime, format: "docx", input: docx, operations: docxOperations),
            format: "docx",
            count: docxOperations.count)

        let pptx = root.appendingPathComponent("final.pptx")
        let pptxOperations = [
            operation("slide.add", ["title": .string("Title")]),
            operation("shape.add", [
                "slide_index": .number(0), "shape_type": .string("rectangle"),
                "x_points": .number(10), "y_points": .number(10),
                "width_points": .number(100), "height_points": .number(30),
                "text": .string("initial"),
            ]),
            operation("text.set", [
                "slide_index": .number(0), "shape_index": .number(1),
                "text": .string("intermediate"),
            ]),
            operation("text.set", [
                "slide_index": .number(0), "shape_index": .number(1),
                "text": .string("final"),
            ]),
        ]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(format: "pptx", output: pptx, operations: pptxOperations)),
            format: "pptx",
            mode: "create",
            applied: pptxOperations.count)
        try assertVerified(
            runVerify(runtime: runtime, format: "pptx", input: pptx, operations: pptxOperations),
            format: "pptx",
            count: pptxOperations.count)

        let xlsx = root.appendingPathComponent("final.xlsx")
        let xlsxOperations = [
            operation("cell.set", [
                "sheet": .string("Sheet"), "cell": .string("A1"), "value": .string("old"),
            ]),
            operation("cell.set", [
                "sheet": .string("Sheet"), "cell": .string("A1"), "value": .string("new"),
            ]),
            operation("name.set", ["name": .string("Choice"), "reference": .string("Sheet!$A$1")]),
            operation("name.set", ["name": .string("Choice"), "reference": .string("Sheet!$A$2")]),
        ]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(format: "xlsx", output: xlsx, operations: xlsxOperations)),
            format: "xlsx",
            mode: "create",
            applied: xlsxOperations.count)
        try assertVerified(
            runVerify(runtime: runtime, format: "xlsx", input: xlsx, operations: xlsxOperations),
            format: "xlsx",
            count: xlsxOperations.count)

        let html = root.appendingPathComponent("final.html")
        let htmlOperations = [
            operation("xpath.append", [
                "xpath": .string("//body"), "expected_match_count": .number(1),
                "html": .string("<p id=\"target\">initial</p>"),
            ]),
            operation("xpath.set_text", [
                "xpath": .string("//*[@id='target']"), "expected_match_count": .number(1),
                "text": .string("first"),
            ]),
            operation("xpath.set_text", [
                "xpath": .string("//*[@id='target']"), "expected_match_count": .number(1),
                "text": .string("final"),
            ]),
            operation("xpath.set_attribute", [
                "xpath": .string("//*[@id='target']"), "expected_match_count": .number(1),
                "name": .string("data-state"), "value": .string("old"),
            ]),
            operation("xpath.set_attribute", [
                "xpath": .string("//*[@id='target']"), "expected_match_count": .number(1),
                "name": .string("data-state"), "value": .string("new"),
            ]),
            operation("xpath.append", [
                "xpath": .string("//*[@id='target']"), "expected_match_count": .number(1),
                "html": .string("<span>tail</span>"),
            ]),
        ]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(format: "html", output: html, operations: htmlOperations)),
            format: "html",
            mode: "create",
            applied: htmlOperations.count)
        try assertVerified(
            runVerify(runtime: runtime, format: "html", input: html, operations: htmlOperations),
            format: "html",
            count: htmlOperations.count)
    }

    func testImageVerificationBindsEmbeddedContentDigest() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-image-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let different = root.appendingPathComponent("different.png")
        var imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try imageData.write(to: original, options: .withoutOverwriting)
        imageData.append(0)
        try imageData.write(to: different, options: .withoutOverwriting)

        let docx = root.appendingPathComponent("image.docx")
        let writtenDOCX = [operation("image.add", ["path": .string(original.path)])]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "docx", output: docx, operations: writtenDOCX,
                    allowedAssets: [original])),
            format: "docx", mode: "create", applied: 1)
        try assertVerified(
            runVerify(
                runtime: runtime, format: "docx", input: docx,
                operations: writtenDOCX, allowedAssets: [original]),
            format: "docx", count: 1)
        let wrongDOCX = [operation("image.add", ["path": .string(different.path)])]
        let rejectedDOCX = try runVerify(
            runtime: runtime, format: "docx", input: docx,
            operations: wrongDOCX, allowedAssets: [different])
        XCTAssertFalse(rejectedDOCX.ok)
        XCTAssertEqual(rejectedDOCX.code, DocumentToolErrorCode.validationFailed.rawValue)

        let pptx = root.appendingPathComponent("image.pptx")
        let imageParameters: [String: JSONValue] = [
            "slide_index": .number(0), "path": .string(original.path),
            "x_points": .number(10), "y_points": .number(10),
            "width_points": .number(50), "height_points": .number(50),
        ]
        let writtenPPTX = [operation("slide.add", [:]), operation("image.add", imageParameters)]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "pptx", output: pptx, operations: writtenPPTX,
                    allowedAssets: [original])),
            format: "pptx", mode: "create", applied: 2)
        try assertVerified(
            runVerify(
                runtime: runtime, format: "pptx", input: pptx,
                operations: writtenPPTX, allowedAssets: [original]),
            format: "pptx", count: 2)
        var wrongParameters = imageParameters
        wrongParameters["path"] = .string(different.path)
        let rejectedPPTX = try runVerify(
            runtime: runtime, format: "pptx", input: pptx,
            operations: [operation("slide.add", [:]), operation("image.add", wrongParameters)],
            allowedAssets: [different])
        XCTAssertFalse(rejectedPPTX.ok)
        XCTAssertEqual(rejectedPPTX.code, DocumentToolErrorCode.validationFailed.rawValue)
    }

    func testPPTXChartVerificationBindsSeriesDataCategoriesAndTitle() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-pptx-chart-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("chart.pptx")
        let chart: [String: JSONValue] = [
            "slide_index": .number(0), "chart_type": .string("column"),
            "categories": .array([.string("A"), .string("B")]),
            "series_name": .string("Series"),
            "values": .array([.number(1), .number(2)]),
            "title": .string("Exact title"),
            "x_points": .number(10), "y_points": .number(10),
            "width_points": .number(300), "height_points": .number(180),
        ]
        let operations = [operation("slide.add", [:]), operation("chart.add", chart)]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(format: "pptx", output: output, operations: operations)),
            format: "pptx", mode: "create", applied: 2)
        try assertVerified(
            runVerify(runtime: runtime, format: "pptx", input: output, operations: operations),
            format: "pptx", count: 2)

        var wrongChart = chart
        wrongChart["values"] = .array([.number(1), .number(3)])
        wrongChart["title"] = .string("Wrong title")
        let rejected = try runVerify(
            runtime: runtime,
            format: "pptx",
            input: output,
            operations: [operation("slide.add", [:]), operation("chart.add", wrongChart)])
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.code, DocumentToolErrorCode.validationFailed.rawValue)
    }

    func testWriteRouteRejectsExecutionControlFields() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-write-rejection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("blocked.html")
        var payload = writePayload(
            format: "html",
            output: output,
            operations: [operation("xpath.set_text", [
                "xpath": .string("//body"),
                "expected_match_count": .number(1),
                "text": .string("blocked"),
            ])])
        guard case .object(var object) = payload else {
            return XCTFail("test payload is not an object")
        }
        object["command"] = .string("ignored")
        payload = .object(object)

        let envelope = try runWrite(runtime: runtime, payload: payload)
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.code, DocumentToolErrorCode.validationFailed.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testVerifyWriteRejectsExtraPayloadFields() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-document-verify-rejection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("source.html")
        let operations = [operation("xpath.set_text", [
            "xpath": .string("//body"),
            "expected_match_count": .number(1),
            "text": .string("safe"),
        ])]
        _ = try runWrite(
            runtime: runtime,
            payload: writePayload(format: "html", output: output, operations: operations))
        let envelope = try runBackend(
            runtime: runtime,
            operation: "verify_write",
            payload: .object([
                "format": .string("html"),
                "input_path": .string(output.path),
                "operations": .array(operations),
                "command": .string("ignored"),
            ]))
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.code, DocumentToolErrorCode.validationFailed.rawValue)
    }

    func testPrepareHTMLRenderInlinesAllowlistedImagesAndRejectsResponsiveSources() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-html-render-prepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = root.appendingPathComponent("pixel.png")
        let pixelData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try pixelData.write(to: pixel, options: .withoutOverwriting)
        let input = root.appendingPathComponent("input.html")
        try "<html><body><picture><source src=\"pixel.png\"><img src=\"pixel.png\"></picture></body></html>"
            .write(to: input, atomically: false, encoding: .utf8)
        let output = root.appendingPathComponent("sanitized.html")
        let prepared = try runBackend(
            runtime: runtime,
            operation: "prepare_html_render",
            payload: .object([
                "input_path": .string(input.path),
                "output_path": .string(output.path),
                "allowed_asset_paths": .array([.string(pixel.path)]),
            ]))
        XCTAssertTrue(prepared.ok, prepared.summary ?? "HTML preparation failed")
        guard case .object(let result)? = prepared.result else {
            return XCTFail("HTML preparation result is missing")
        }
        XCTAssertEqual(result["format"], .string("html"))
        XCTAssertEqual(result["sanitized"], .bool(true))
        XCTAssertEqual(result["inlined_asset_count"], .number(2))
        let sanitized = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(sanitized.components(separatedBy: "data:image/png;base64,").count - 1, 2)
        XCTAssertFalse(sanitized.contains("pixel.png"))
        XCTAssertFalse(sanitized.contains(pixel.path))

        for (index, attribute) in ["srcset", "imagesrcset"].enumerated() {
            let rejectedInput = root.appendingPathComponent("responsive-\(index).html")
            try "<html><body><img src=\"data:image/png;base64,iVBORw0KGgo=\" \(attribute)=\"pixel.png 1x\"></body></html>"
                .write(to: rejectedInput, atomically: false, encoding: .utf8)
            let rejectedOutput = root.appendingPathComponent("responsive-\(index)-sanitized.html")
            let rejected = try runBackend(
                runtime: runtime,
                operation: "prepare_html_render",
                payload: .object([
                    "input_path": .string(rejectedInput.path),
                    "output_path": .string(rejectedOutput.path),
                    "allowed_asset_paths": .array([.string(pixel.path)]),
                ]))
            XCTAssertFalse(rejected.ok, attribute)
            XCTAssertEqual(
                rejected.code,
                DocumentToolErrorCode.unsupportedFeature.rawValue,
                attribute)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedOutput.path), attribute)
        }

        let closedOutput = root.appendingPathComponent("closed-schema.html")
        let closedSchema = try runBackend(
            runtime: runtime,
            operation: "prepare_html_render",
            payload: .object([
                "input_path": .string(input.path),
                "output_path": .string(closedOutput.path),
                "allowed_asset_paths": .array([.string(pixel.path)]),
                "network": .bool(true),
            ]))
        XCTAssertFalse(closedSchema.ok)
        XCTAssertEqual(closedSchema.code, DocumentToolErrorCode.validationFailed.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: closedOutput.path))
    }

    func testReadDOCXReturnsBoundedMarkdownAndRejectsProjectionControls() throws {
        let runtime = try requireFixedRuntime()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-docx-read-flags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = root.appendingPathComponent("flags.docx")
        let operations = [
            operation("paragraph.add", ["text": .string("body value")]),
            operation("table.add", [
                "values": .array([.array([.string("table value")])]),
            ]),
            operation("header.set_text", [
                "section_index": .number(0),
                "text": .string("header value"),
            ]),
            operation("footer.set_text", [
                "section_index": .number(0),
                "text": .string("footer value"),
            ]),
        ]
        try assertSuccess(
            runWrite(
                runtime: runtime,
                payload: writePayload(
                    format: "docx",
                    output: document,
                    operations: operations)),
            format: "docx",
            mode: "create",
            applied: operations.count)

        let projected = try runBackend(
            runtime: runtime,
            operation: "read",
            payload: .object([
                "format": .string("docx"),
                "input_path": .string(document.path),
                "maximum_characters": .number(100_000),
                "maximum_file_bytes": .number(512 * 1_024 * 1_024),
            ]))
        XCTAssertTrue(projected.ok, projected.summary ?? "DOCX Markdown read failed")
        guard case .object(let result)? = projected.result,
              case .string(let markdown)? = result["markdown"] else {
            return XCTFail("DOCX Markdown result is incomplete")
        }
        XCTAssertTrue(markdown.contains("body value"), markdown)
        XCTAssertTrue(markdown.contains("table value"), markdown)
        XCTAssertEqual(result["truncated"], .bool(false))

        let bounded = try runBackend(
            runtime: runtime,
            operation: "read",
            payload: .object([
                "format": .string("docx"),
                "input_path": .string(document.path),
                "maximum_characters": .number(10),
                "maximum_file_bytes": .number(512 * 1_024 * 1_024),
            ]))
        XCTAssertTrue(bounded.ok, bounded.summary ?? "bounded DOCX read failed")
        guard case .object(let boundedResult)? = bounded.result,
              case .string(let boundedMarkdown)? = boundedResult["markdown"] else {
            return XCTFail("bounded DOCX result is incomplete")
        }
        XCTAssertLessThanOrEqual(boundedMarkdown.count, 10)
        XCTAssertEqual(boundedResult["truncated"], .bool(true))

        let invalid = try runBackend(
            runtime: runtime,
            operation: "read",
            payload: .object([
                "format": .string("docx"),
                "input_path": .string(document.path),
                "include_tables": .string("false"),
            ]))
        XCTAssertFalse(invalid.ok)
        XCTAssertEqual(invalid.code, DocumentToolErrorCode.validationFailed.rawValue)
    }

    #if os(macOS) && canImport(WebKit)
    func testHTMLRendererRendersSanitizedInputInsideStageReadRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-html-render-positive-\(UUID().uuidString)", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sanitizedInput = stage.appendingPathComponent("sanitized.html")
        try "<html><body>stage-only render</body></html>"
            .write(to: sanitizedInput, atomically: false, encoding: .utf8)
        let output = stage.appendingPathComponent("preview.pdf")

        let versions = try await HTMLDocumentPDFRenderer.render(
            input: sanitizedInput,
            stageRoot: stage,
            stagedPDF: output)
        XCTAssertEqual(versions["html_renderer"], "WKWebView-system")
        XCTAssertTrue(try Data(contentsOf: output).starts(with: Data("%PDF-".utf8)))
    }

    func testHTMLRendererRejectsInputOutsideItsStageReadRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-html-render-read-root-\(UUID().uuidString)", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideInput = root.appendingPathComponent("outside.html")
        try "<html><body>outside stage</body></html>"
            .write(to: outsideInput, atomically: false, encoding: .utf8)

        do {
            _ = try await HTMLDocumentPDFRenderer.render(
                input: outsideInput,
                stageRoot: stage,
                stagedPDF: stage.appendingPathComponent("preview.pdf"))
            XCTFail("renderer accepted HTML outside its stage read root")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .validationFailed)
        }
    }
    #endif

    private func requireFixedRuntime() throws -> URL {
        guard let root = intatisDocumentRuntimeRoot() else {
            throw XCTSkip("fixed document runtime has no platform location")
        }
        let python = root.appendingPathComponent("bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("fixed document runtime is not installed")
        }
        return python
    }

    private func embeddedProgram() throws -> String {
        let invocation = try DocumentPythonBackend.invocation(
            operation: "write",
            payload: .object([
                "format": .string("html"),
                "mode": .string("create"),
                "output_path": .string("/tmp/unused.htm"),
                "operations": .array([]),
            ]),
            readableWorkspacePaths: [])
        return try XCTUnwrap(invocation.arguments.last)
    }

    private func runPython(
        executable: URL,
        arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "\(output)\n\(error)",
            file: file,
            line: line)
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "DocumentPythonWriteBackendTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    private func operation(
        _ kind: String,
        _ parameters: [String: JSONValue]
    ) -> JSONValue {
        .object([
            "kind": .string(kind),
            "parameters": .object(parameters),
        ])
    }

    private func writePayload(
        format: String,
        mode: String = "create",
        input: URL? = nil,
        output: URL,
        operations: [JSONValue],
        allowedAssets: [URL] = []
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "format": .string(format),
            "mode": .string(mode),
            "output_path": .string(output.path),
            "operations": .array(operations),
        ]
        if !allowedAssets.isEmpty {
            value["allowed_asset_paths"] = .array(allowedAssets.map { .string($0.path) })
        }
        if let input {
            value["input_path"] = .string(input.path)
        }
        return .object(value)
    }

    private func runWrite(
        runtime: URL,
        payload: JSONValue
    ) throws -> DocumentBackendEnvelope {
        try runBackend(runtime: runtime, operation: "write", payload: payload)
    }

    private func runVerify(
        runtime: URL,
        format: String,
        input: URL,
        operations: [JSONValue],
        allowedAssets: [URL] = []
    ) throws -> DocumentBackendEnvelope {
        var payload: [String: JSONValue] = [
            "format": .string(format),
            "input_path": .string(input.path),
            "operations": .array(operations),
        ]
        if !allowedAssets.isEmpty {
            payload["allowed_asset_paths"] = .array(allowedAssets.map { .string($0.path) })
        }
        return try runBackend(
            runtime: runtime,
            operation: "verify_write",
            payload: .object(payload))
    }

    private func runBackend(
        runtime: URL,
        operation: String,
        payload: JSONValue
    ) throws -> DocumentBackendEnvelope {
        let invocation = try DocumentPythonBackend.invocation(
            operation: operation,
            payload: payload,
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let process = Process()
        process.executableURL = runtime
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in invocation.environment {
            environment[key] = value
        }
        process.environment = environment
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
        return try JSONDecoder().decode(DocumentBackendEnvelope.self, from: output)
    }

    private func assertSuccess(
        _ envelope: DocumentBackendEnvelope,
        format: String,
        mode: String,
        applied: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(envelope.ok, envelope.summary ?? "backend failed", file: file, line: line)
        guard case .object(let result)? = envelope.result else {
            return XCTFail("write result is missing", file: file, line: line)
        }
        XCTAssertEqual(result["format"], .string(format), file: file, line: line)
        XCTAssertEqual(result["mode"], .string(mode), file: file, line: line)
        XCTAssertEqual(result["applied_operations"], .number(Double(applied)), file: file, line: line)
    }

    private func assertVerified(
        _ envelope: DocumentBackendEnvelope,
        format: String,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(envelope.ok, envelope.summary ?? "verification failed", file: file, line: line)
        guard case .object(let result)? = envelope.result else {
            return XCTFail("verification result is missing", file: file, line: line)
        }
        XCTAssertEqual(result["format"], .string(format), file: file, line: line)
        XCTAssertEqual(result["verified_count"], .number(Double(count)), file: file, line: line)
    }
}
