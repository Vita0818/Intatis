import Foundation
import IntatisCore
import IntatisProtocol
@testable import IntatisTools
import XCTest

#if canImport(CoreGraphics) && canImport(PDFKit)
import CoreGraphics
import PDFKit
#endif

private actor RecordingDocumentBackendRunner: DocumentBackendRunner {
    private let result: ShellResult
    private var invocations: [DocumentBackendInvocation] = []

    init(result: ShellResult) {
        self.result = result
    }

    func run(
        _ invocation: DocumentBackendInvocation,
        cwd: URL
    ) async throws -> ShellResult {
        invocations.append(invocation)
        return result
    }

    func invocationCount() -> Int {
        invocations.count
    }
}

final class DocumentToolsIntegrationTests: XCTestCase {
    private let fileManager = FileManager.default

    func testStandardRegistryExposesOnlySixReplacementDocumentTools() throws {
        let registry = ToolRegistry.standard()
        let names = Set(registry.descriptors().map(\.name))

        XCTAssertTrue([
            "read_pdf",
            "document_read",
            "document_ocr",
            "document_render",
            "document_export_pdf",
            "document_write",
        ].allSatisfy(names.contains))
        XCTAssertFalse(names.contains("read_document"))
        XCTAssertFalse(names.contains("edit_pdf_pages"))
        XCTAssertFalse(names.contains("reconstruct_document_image"))
        XCTAssertEqual(registry.registryVersion, "intatis.standard.v2")
    }

    func testDescriptorsPermissionsAndTouchedPathsAreExact() throws {
        XCTAssertEqual(ReadPDFTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(DocumentReadTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentOCRTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentRenderTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentExportPDFTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentWriteTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ReadPDFTool.canonicalPermission, "document.read")
        XCTAssertEqual(DocumentReadTool.canonicalPermission, "document.read")
        XCTAssertEqual(DocumentOCRTool.canonicalPermission, "document.ocr")
        XCTAssertEqual(DocumentRenderTool.canonicalPermission, "document.render")
        XCTAssertEqual(DocumentExportPDFTool.canonicalPermission, "document.export.pdf")
        XCTAssertEqual(DocumentWriteTool.canonicalPermission, "document.write")

        let digest = String(repeating: "a", count: 64)
        let readArgs = ToolArgs(raw: #"{"format":"docx","input_path":"report.docx"}"#)
        let readIntent = DocumentReadTool().permissionIntent(
            readArgs,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertTrue(readIntent.isStructuredReadOnlyExecution)
        XCTAssertTrue(readIntent.isReadOnlyWorkspaceCompatible)
        XCTAssertEqual(readIntent.dataEffects, [.read, .execute])

        let renderArgs = ToolArgs(raw: """
        {"input_format":"html","input_path":"site/index.html",
         "expected_source_sha256":"\(digest)",
         "local_asset_paths":["site/logo.png","site/style.css"],
         "output_dir":"site/preview"}
        """)
        let render = DocumentRenderTool()
        XCTAssertEqual(
            render.touchedPaths(renderArgs),
            ["site/index.html", "site/logo.png", "site/style.css", "site/preview"])
        let renderIntent = render.permissionIntent(
            renderArgs,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(renderIntent.action, "document.render")
        XCTAssertEqual(renderIntent.dataEffects, [.read, .execute, .mutate])
        XCTAssertEqual(renderIntent.risks, [.processExecution, .workspaceMutation])
        XCTAssertEqual(renderIntent.replayPolicy, .requiresManualReconciliation)
        XCTAssertEqual(renderIntent.resources, [
            PermissionResource(kind: .workspacePath, value: "site/index.html", access: .readOnly),
            PermissionResource(kind: .workspacePath, value: "site/logo.png", access: .readOnly),
            PermissionResource(kind: .workspacePath, value: "site/style.css", access: .readOnly),
            PermissionResource(kind: .workspacePath, value: "site/preview", access: .readWrite),
        ])

        let writeArgs = ToolArgs(raw: """
        {"format":"docx","mode":"create","output_path":"out/report.docx",
         "operations":[{"kind":"image.add","parameters":{"path":"assets/chart.png"}}]}
        """)
        let write = DocumentWriteTool()
        XCTAssertEqual(write.touchedPaths(writeArgs), ["assets/chart.png", "out/report.docx"])
        let writeIntent = write.permissionIntent(
            writeArgs,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(writeIntent.resources, [
            PermissionResource(kind: .workspacePath, value: "assets/chart.png", access: .readOnly),
            PermissionResource(kind: .workspacePath, value: "out/report.docx", access: .readWrite),
        ])

        let htmlWriteArgs = ToolArgs(raw: #"""
        {"format":"html","mode":"create","output_path":"site/index.html",
         "local_asset_paths":["site/logo.png"],
         "operations":[{"kind":"xpath.append","parameters":{
           "xpath":"//body","expected_match_count":1,
           "html":"<img src=\"logo.png\" alt=\"logo\">"}}]}
        """#)
        XCTAssertEqual(
            write.touchedPaths(htmlWriteArgs),
            ["site/logo.png", "site/index.html"])
        XCTAssertEqual(
            write.permissionIntent(
                htmlWriteArgs,
                workspaceRoot: URL(fileURLWithPath: "/workspace"))
                .resources,
            [
                PermissionResource(
                    kind: .workspacePath,
                    value: "site/logo.png",
                    access: .readOnly),
                PermissionResource(
                    kind: .workspacePath,
                    value: "site/index.html",
                    access: .readWrite),
            ])
    }

    func testReadPDFReturnsTypedOCRRequiredForImageOnlyPDF() async throws {
        #if canImport(CoreGraphics) && canImport(PDFKit)
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("scan.pdf")
        try makeImageOnlyPDF(at: input)

        do {
            _ = try await ReadPDFTool().execute(
                ToolArgs(raw: #"{"path":"scan.pdf"}"#),
                in: ToolContext(workspaceRoot: workspace))
            XCTFail("image-only PDF should require explicit OCR")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .ocrRequired)
        }
        #else
        throw XCTSkip("PDFKit integration requires Apple PDF frameworks")
        #endif
    }

    func testPDFRenderCommitsCompleteBundleWithoutLeakingStageDirectory() async throws {
        #if canImport(CoreGraphics) && canImport(PDFKit)
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("source.pdf")
        try makeImageOnlyPDF(at: input)
        let digest = try DocumentInputFile.freeze(
            path: "source.pdf",
            expectedFormat: .pdf,
            workspace: workspace).identity.sha256

        let observation = try await DocumentRenderTool().execute(
            ToolArgs(raw: """
            {"input_format":"pdf","input_path":"source.pdf",
             "expected_source_sha256":"\(digest)","output_dir":"preview",
             "dpi":72,"maximum_page_pixels":20000000,
             "maximum_total_pixels":20000000,"maximum_output_bytes":67108864}
            """),
            in: ToolContext(workspaceRoot: workspace))

        XCTAssertEqual(observation.changedFiles, ["preview"])
        let output = workspace.appendingPathComponent("preview", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: output.appendingPathComponent("page-0001.png").path))
        XCTAssertTrue(fileManager.fileExists(atPath: output.appendingPathComponent("manifest.json").path))
        let rootChildren = try fileManager.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(rootChildren.contains { $0.hasPrefix(".intatis-document-stage-") })
        #else
        throw XCTSkip("PDFKit integration requires Apple PDF frameworks")
        #endif
    }

    func testDocumentReadMapsFixedBackendMissingEnvelopeToTypedFailure() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try Data("not parsed by the fake".utf8).write(
            to: workspace.appendingPathComponent("report.docx"))
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: #"{"schema_version":1,"ok":false,"code":"backend_missing","summary":"private path","engine_versions":{},"warnings":[]}"#,
            stderr: "",
            exitCode: 0))

        do {
            _ = try await DocumentReadTool().execute(
                ToolArgs(raw: #"{"format":"docx","input_path":"report.docx"}"#),
                in: ToolContext(workspaceRoot: workspace, documentBackend: backend))
            XCTFail("missing backend should fail")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .backendMissing)
            XCTAssertFalse(error.summary.contains("private path"))
        }
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testExportAndWritePrecommitConflictsDoNotClobberOrInvokeBackend() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source.html")
        try Data("<html><body>source</body></html>".utf8).write(to: source)
        let digest = try DocumentInputFile.freeze(
            path: "source.html",
            expectedFormat: .html,
            workspace: workspace).identity.sha256
        let originalPDF = Data("existing-pdf".utf8)
        let originalHTML = Data("existing-html".utf8)
        let pdfOutput = workspace.appendingPathComponent("output.pdf")
        let htmlOutput = workspace.appendingPathComponent("output.html")
        try originalPDF.write(to: pdfOutput)
        try originalHTML.write(to: htmlOutput)
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: "",
            stderr: "unexpected invocation",
            exitCode: 99))
        let context = ToolContext(workspaceRoot: workspace, documentBackend: backend)

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentExportPDFTool().execute(
                ToolArgs(raw: """
                {"input_format":"html","input_path":"source.html",
                 "expected_source_sha256":"\(digest)","output_path":"output.pdf"}
                """),
                in: context)
        }
        await assertDocumentError(.outputConflict) {
            _ = try await DocumentWriteTool().execute(
                ToolArgs(raw: #"{"format":"html","mode":"create","output_path":"output.html","operations":[{"kind":"xpath.set_text","parameters":{"xpath":"//body","expected_match_count":1,"text":"replacement"}}]}"#),
                in: context)
        }

        XCTAssertEqual(try Data(contentsOf: pdfOutput), originalPDF)
        XCTAssertEqual(try Data(contentsOf: htmlOutput), originalHTML)
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testDocumentProcessLeaseNarrowsBroadWorkspaceAuthorityToReviewedInputAndStage() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("source.docx")
        try Data("input".utf8).write(to: input)
        let outputDirectory = workspace.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        let stage = outputDirectory.appendingPathComponent(
            ".intatis-document-stage-test",
            isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        let durable = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])

        let narrowed = try documentProcessLease(
            durable,
            workspace: workspace,
            reviewedReadablePaths: ["source.docx"],
            reviewedWritablePaths: ["out/result.pdf"],
            internalWritablePaths: ["out/.intatis-document-stage-test"])

        XCTAssertEqual(narrowed.access, .readWrite)
        XCTAssertEqual(
            Set(narrowed.allowedPathRules.map(\.pattern)),
            ["source.docx", "out/.intatis-document-stage-test"])
        XCTAssertFalse(narrowed.allowedPathRules.contains { $0.pattern == "." })
        XCTAssertGreaterThan(
            DocumentBackendProcessRunner.maximumGeneratedFileBytes,
            8 * 1_024 * 1_024)

        #if os(macOS)
        let profile = try macOSSandboxProfile(
            workspace: workspace,
            runtime: fileManager.temporaryDirectory,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: narrowed,
            forcedReadOnlyWorkspaceRoots: [input],
            networkAccess: .denied)
        XCTAssertTrue(profile.contains("source\\\\.docx"))
        XCTAssertTrue(profile.contains("intatis-document-stage-test"))
        XCTAssertTrue(profile.contains("(deny file-write* (subpath \""))
        XCTAssertTrue(profile.contains("(deny network*)"))
        #endif
    }

    func testDocumentProcessLeaseRejectsLiteralPathThatWouldBecomeAGlob() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let durable = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])

        XCTAssertThrowsError(try documentProcessLease(
            durable,
            workspace: workspace,
            reviewedReadablePaths: ["report?.docx"],
            reviewedWritablePaths: [],
            internalWritablePaths: []))
    }

    func testDocumentVersionProbeCanDenyAllWorkspaceAccess() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let durable = WorkspaceLease(
            rootPath: canonicalWorkspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])

        let narrowed = try documentProcessLease(
            durable,
            workspace: canonicalWorkspace,
            reviewedReadablePaths: [],
            reviewedWritablePaths: [],
            internalWritablePaths: [])

        XCTAssertTrue(narrowed.allowedPathRules.isEmpty)
        XCTAssertNoThrow(try effectiveWorkspaceLease(
            narrowed,
            workspace: canonicalWorkspace,
            allowEmptyPathRules: true))
        XCTAssertThrowsError(try effectiveWorkspaceLease(
            narrowed,
            workspace: canonicalWorkspace))

        #if os(macOS)
        let profile = try macOSSandboxProfile(
            workspace: canonicalWorkspace,
            runtime: fileManager.temporaryDirectory,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: narrowed,
            networkAccess: .denied)
        XCTAssertTrue(profile.contains("(deny file-read-data file-map-executable file-write*"))
        XCTAssertTrue(profile.contains("(deny network*)"))
        #endif
    }

    func testDocumentGeneratedOutputBudgetCountsAggregateFilesAndEntries() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("generated", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data(repeating: 0x41, count: 4_096).write(
            to: stage.appendingPathComponent("one.bin"))
        try Data(repeating: 0x42, count: 4_096).write(
            to: stage.appendingPathComponent("two.bin"))
        try fileManager.createDirectory(
            at: stage.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: false)

        XCTAssertFalse(documentGeneratedOutputExceedsBudget(
            roots: [stage],
            maximumBytes: 16_384,
            maximumEntries: 3))
        XCTAssertTrue(documentGeneratedOutputExceedsBudget(
            roots: [stage],
            maximumBytes: 6_000,
            maximumEntries: 3))
        XCTAssertTrue(documentGeneratedOutputExceedsBudget(
            roots: [stage],
            maximumBytes: 16_384,
            maximumEntries: 2))
    }

    private func makeWorkspace() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "intatis-document-tool-integration-\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func assertDocumentError(
        _ expected: DocumentToolErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected.rawValue)", file: file, line: line)
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, expected, error.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    #if canImport(CoreGraphics) && canImport(PDFKit)
    private func makeImageOnlyPDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 144, height: 96)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 2)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 12, y: 12, width: 120, height: 72))
        context.endPDFPage()
        context.closePDF()
    }
    #endif
}
