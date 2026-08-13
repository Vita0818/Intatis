import Foundation
import IntatisCore
import IntatisProtocol
@testable import IntatisTools
import XCTest

#if canImport(CoreGraphics) && canImport(PDFKit)
import CoreGraphics
import CoreText
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

    func testInstalledDocumentRuntimeEPUBWriteWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 to run the installed document runtime smoke")
        }
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/intatis-rbook-helper").path),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/intatis-epubcheck").path) else {
            throw XCTSkip("fixed rbook and EPUBCheck runtimes are not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try Data(#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter One</title></head><body><h1>Chapter One</h1><p>Runtime smoke.</p></body></html>"#.utf8)
            .write(to: workspace.appendingPathComponent("chapter.xhtml"))
        let context = ToolContext(
            workspaceRoot: workspace,
            documentBackend: DocumentBackendProcessRunner(timeoutSeconds: 300))

        let observation = try await DocumentWriteTool().execute(
            ToolArgs(raw: #"""
            {
              "format":"epub","mode":"create","output_path":"runtime-smoke.epub",
              "operations":[
                {"kind":"metadata.set","parameters":{"field":"identifier","value":"urn:intatis:runtime-smoke"}},
                {"kind":"metadata.set","parameters":{"field":"title","value":"Intatis Runtime Smoke"}},
                {"kind":"metadata.set","parameters":{"field":"language","value":"en"}},
                {"kind":"resource.add","parameters":{"id":"chapter_one","source_path":"chapter.xhtml","href":"text/chapter.xhtml","media_type":"application/xhtml+xml"}},
                {"kind":"spine.append","parameters":{"resource_id":"chapter_one","linear":true}},
                {"kind":"toc.add","parameters":{"label":"Chapter One","href":"text/chapter.xhtml"}}
              ]
            }
            """#),
            in: context)

        XCTAssertTrue(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("runtime-smoke.epub").path))
        XCTAssertTrue(observation.text.contains(#""epubcheck":"5.3.0""#), observation.text)
        XCTAssertTrue(observation.text.contains(#""rbook":"0.7.10""#), observation.text)

        let read = try await ReadEPUBTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.epub"}"#),
            in: context)
        XCTAssertTrue(read.text.contains("Runtime smoke"), read.text)
    }

    func testInstalledDocumentRuntimeCoreToolChainWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 to run the installed document runtime smoke")
        }
        guard let runtime = intatisDocumentRuntimeRoot(),
              let libreOffice = intatisLibreOfficeRuntimeAppURL()?
                  .appendingPathComponent("Contents/MacOS/soffice"),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/pdfcpu").path),
              fileManager.isExecutableFile(
                  atPath: libreOffice.path) else {
            throw XCTSkip("fixed Python, pdfcpu, or LibreOffice runtime is not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let context = ToolContext(
            workspaceRoot: workspace,
            documentBackend: DocumentBackendProcessRunner(timeoutSeconds: 300))
        let marker = "INTATIS DOCUMENT RUNTIME 73921"

        let write = try await DocumentWriteTool().execute(
            ToolArgs(raw: #"""
            {"format":"docx","mode":"create","output_path":"runtime-smoke.docx",
             "operations":[{"kind":"paragraph.add","parameters":{"text":"INTATIS DOCUMENT RUNTIME 73921"}}]}
            """#),
            in: context)
        XCTAssertTrue(write.text.contains(#""operation":"document_write""#), write.text)

        let read = try await ReadDOCXTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.docx"}"#),
            in: context)
        XCTAssertTrue(read.text.contains(marker), read.text)

        let htmlMarker = "INTATIS HTML RUNTIME 18426"
        try Data("<html><body><h1>\(htmlMarker)</h1></body></html>".utf8)
            .write(to: workspace.appendingPathComponent("runtime-smoke.html"))
        let htmlRead = try await ReadHTMLTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.html"}"#),
            in: context)
        XCTAssertTrue(htmlRead.text.contains(htmlMarker), htmlRead.text)

        let docxDigest = try DocumentInputFile.freeze(
            path: "runtime-smoke.docx",
            expectedFormat: .docx,
            workspace: workspace).identity.sha256
        let export = try await DocumentExportPDFTool().execute(
            ToolArgs(raw: """
            {"input_format":"docx","input_path":"runtime-smoke.docx",
             "expected_source_sha256":"\(docxDigest)","output_path":"runtime-smoke.pdf"}
            """),
            in: context)
        XCTAssertTrue(export.text.contains(#""pdfcpu":"0.13.0""#), export.text)
        XCTAssertTrue(export.text.contains(#""libreoffice":"26.8.0.0.beta1""#), export.text)

        let pdfRead = try await ReadPDFTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.pdf"}"#),
            in: context)
        XCTAssertTrue(pdfRead.text.contains(marker), pdfRead.text)

        let pdfDigest = try DocumentInputFile.freeze(
            path: "runtime-smoke.pdf",
            expectedFormat: .pdf,
            workspace: workspace).identity.sha256
        let render = try await DocumentRenderTool().execute(
            ToolArgs(raw: """
            {"input_format":"pdf","input_path":"runtime-smoke.pdf",
             "expected_source_sha256":"\(pdfDigest)","pages":"1","output_dir":"runtime-pages"}
            """),
            in: context)
        XCTAssertTrue(render.text.contains(#""operation":"document_render""#), render.text)
        XCTAssertTrue(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("runtime-pages/manifest.json").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("runtime-pages/page-0001.png").path))

        let slideMarker = "INTATIS PRESENTATION RUNTIME 48216"
        let pptxWrite = try await DocumentWriteTool().execute(
            ToolArgs(raw: """
            {"format":"pptx","mode":"create","output_path":"runtime-smoke.pptx",
             "operations":[{"kind":"slide.add","parameters":{"layout_index":0,
              "title":"\(slideMarker)"}}]}
            """),
            in: context)
        XCTAssertTrue(pptxWrite.text.contains(#""libreoffice":"26.8.0.0.beta1""#), pptxWrite.text)
        let pptxRead = try await ReadPPTXTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.pptx"}"#),
            in: context)
        XCTAssertTrue(pptxRead.text.contains(slideMarker), pptxRead.text)
        let pptxDigest = try DocumentInputFile.freeze(
            path: "runtime-smoke.pptx",
            expectedFormat: .pptx,
            workspace: workspace).identity.sha256
        let pptxExport = try await DocumentExportPDFTool().execute(
            ToolArgs(raw: """
            {"input_format":"pptx","input_path":"runtime-smoke.pptx",
             "expected_source_sha256":"\(pptxDigest)","output_path":"runtime-smoke-pptx.pdf"}
            """),
            in: context)
        XCTAssertTrue(pptxExport.text.contains(#""libreoffice":"26.8.0.0.beta1""#), pptxExport.text)
        let pptxPDFRead = try await ReadPDFTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke-pptx.pdf"}"#),
            in: context)
        let pptxPDFJSON = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(pptxPDFRead.text.utf8))
        guard case .object(let pptxPDFRoot) = pptxPDFJSON,
              case .string(let pptxPDFText)? = pptxPDFRoot["combinedText"] else {
            XCTFail("PPTX PDF read did not contain combinedText")
            return
        }
        let compactPPTXPDFText = pptxPDFText.filter { $0.isWhitespace == false }
        XCTAssertTrue(
            compactPPTXPDFText.contains(slideMarker.filter { $0.isWhitespace == false }),
            pptxPDFRead.text)

        let xlsxWrite = try await DocumentWriteTool().execute(
            ToolArgs(raw: #"""
            {"format":"xlsx","mode":"create","output_path":"runtime-smoke.xlsx",
             "operations":[
              {"kind":"cell.set","parameters":{"sheet":"Sheet","cell":"C3","value":2}},
              {"kind":"cell.set","parameters":{"sheet":"Sheet","cell":"D3","value":"=C3*2"}},
              {"kind":"cell.set","parameters":{"sheet":"Sheet","cell":"E3","value":"INTATIS SHEET RUNTIME 93715"}}
             ]}
            """#),
            in: context)
        XCTAssertTrue(
            xlsxWrite.text.contains(#""xlsx_recalculation":"calc_roundtrip_cache_verified""#),
            xlsxWrite.text)
        XCTAssertTrue(xlsxWrite.text.contains(#""libreoffice":"26.8.0.0.beta1""#), xlsxWrite.text)
        let xlsxRead = try await ReadXLSXTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.xlsx"}"#),
            in: context)
        XCTAssertTrue(xlsxRead.text.contains("INTATIS SHEET RUNTIME 93715"), xlsxRead.text)
        let xlsxDigest = try DocumentInputFile.freeze(
            path: "runtime-smoke.xlsx",
            expectedFormat: .xlsx,
            workspace: workspace).identity.sha256
        let xlsxExport = try await DocumentExportPDFTool().execute(
            ToolArgs(raw: """
            {"input_format":"xlsx","input_path":"runtime-smoke.xlsx",
             "expected_source_sha256":"\(xlsxDigest)","output_path":"runtime-smoke-xlsx.pdf"}
            """),
            in: context)
        XCTAssertTrue(xlsxExport.text.contains(#""libreoffice":"26.8.0.0.beta1""#), xlsxExport.text)
    }

    func testInstalledDocumentRuntimeReadsUserCorpusWhenConfigured() async throws {
        guard let rawRoot = ProcessInfo.processInfo.environment[
            "INTATIS_REAL_DOCUMENT_CORPUS_ROOT"],
              !rawRoot.isEmpty else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_CORPUS_ROOT to run the external document corpus smoke")
        }
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path) else {
            throw XCTSkip("fixed Python document runtime is not installed")
        }

        let sourceRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
        let sourceFiles = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        let xlsxFiles = sourceFiles.filter { $0.pathExtension.lowercased() == "xlsx" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        let pptxFiles = sourceFiles.filter { $0.pathExtension.lowercased() == "pptx" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        XCTAssertFalse(xlsxFiles.isEmpty, "corpus must contain at least one XLSX")
        XCTAssertGreaterThanOrEqual(pptxFiles.count, 3, "corpus must contain the three lecture PPTX files")
        guard let xlsx = xlsxFiles.first, pptxFiles.count >= 3 else { return }

        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let context = ToolContext(
            workspaceRoot: workspace,
            documentBackend: DocumentBackendProcessRunner(timeoutSeconds: 300))

        let xlsxName = "corpus.xlsx"
        try fileManager.copyItem(
            at: xlsx,
            to: workspace.appendingPathComponent(xlsxName))
        let xlsxRead = try await ReadXLSXTool().execute(
            ToolArgs(raw: #"{"path":"corpus.xlsx","maxCharacters":500000}"#),
            in: context)
        try assertNonemptyMarkdown(xlsxRead, operation: "read_xlsx")

        for (index, source) in pptxFiles.prefix(3).enumerated() {
            let name = "corpus-\(index + 1).pptx"
            try fileManager.copyItem(
                at: source,
                to: workspace.appendingPathComponent(name))
            let read = try await ReadPPTXTool().execute(
                ToolArgs(raw: "{\"path\":\"\(name)\",\"maxCharacters\":500000}"),
                in: context)
            try assertNonemptyMarkdown(read, operation: "read_pptx")
        }
    }

    func testInstalledDocumentRuntimePDFCPUAndOCRWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 to run the installed document runtime smoke")
        }
        #if canImport(CoreGraphics) && canImport(PDFKit)
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/pdfcpu").path),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path) else {
            throw XCTSkip("fixed pdfcpu and Python document runtimes are not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent(
            ".intatis-document-stage-runtime-smoke",
            isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        let input = stage.appendingPathComponent("ocr-source.pdf")
        try makeOCRTextPDF(at: input)
        let runner = DocumentBackendProcessRunner(timeoutSeconds: 300)
        let context = ToolContext(workspaceRoot: workspace, documentBackend: runner)

        let validatorVersions = try await PDFCPUValidationBackend.validateStrict(
            stagedPDF: input,
            reviewedOutputPath: "result.pdf",
            in: context)
        XCTAssertEqual(validatorVersions["pdfcpu"], "0.13.0")

        let digest = try DocumentInputFile.freeze(
            path: ".intatis-document-stage-runtime-smoke/ocr-source.pdf",
            expectedFormat: .pdf,
            workspace: workspace).identity.sha256
        let observation = try await DocumentOCRTool().execute(
            ToolArgs(raw: """
            {"input_path":".intatis-document-stage-runtime-smoke/ocr-source.pdf",
             "expected_source_sha256":"\(digest)",
             "languages":["eng"],"psm":6}
            """),
            in: context)
        let observationJSON = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(observation.text.utf8))
        guard case .object(let root) = observationJSON,
              case .object(let result)? = root["result"],
              case .array(let pages)? = result["pages"] else {
            XCTFail("OCR observation did not contain result.pages")
            return
        }
        let recognized = pages.compactMap { page -> String? in
            guard case .object(let fields) = page,
                  case .string(let text)? = fields["text"] else { return nil }
            return text
        }.joined(separator: "\n")
        let normalized = recognized.uppercased().filter { $0.isLetter || $0.isNumber }
        XCTAssertTrue(normalized.contains("INTATISOCR48291"), observation.text)
        #else
        throw XCTSkip("real document runtime smoke requires Apple PDF frameworks")
        #endif
    }

    func testStandardRegistryExposesSplitDocumentReaders() throws {
        let registry = ToolRegistry.standard()
        let names = Set(registry.descriptors().map(\.name))

        XCTAssertTrue([
            "read_pdf",
            "read_docx",
            "read_pptx",
            "read_xlsx",
            "read_html",
            "read_epub",
            "document_ocr",
            "document_render",
            "document_export_pdf",
            "document_write",
        ].allSatisfy(names.contains))
        XCTAssertFalse(names.contains("read_document"))
        XCTAssertFalse(names.contains("document_read"))
        XCTAssertFalse(names.contains("edit_pdf_pages"))
        XCTAssertFalse(names.contains("reconstruct_document_image"))
        XCTAssertEqual(registry.registryVersion, "intatis.standard.v4")
    }

    func testDescriptorsPermissionsAndTouchedPathsAreExact() throws {
        XCTAssertEqual(ReadPDFTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(ReadDOCXTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ReadPPTXTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ReadXLSXTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ReadHTMLTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ReadEPUBTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentOCRTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentRenderTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentExportPDFTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(DocumentWriteTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ReadPDFTool.canonicalPermission, "document.read")
        XCTAssertEqual(ReadDOCXTool.canonicalPermission, "document.read")
        XCTAssertEqual(ReadPPTXTool.canonicalPermission, "document.read")
        XCTAssertEqual(ReadXLSXTool.canonicalPermission, "document.read")
        XCTAssertEqual(ReadHTMLTool.canonicalPermission, "document.read")
        XCTAssertEqual(ReadEPUBTool.canonicalPermission, "document.read")
        XCTAssertEqual(DocumentOCRTool.canonicalPermission, "document.ocr")
        XCTAssertEqual(DocumentRenderTool.canonicalPermission, "document.render")
        XCTAssertEqual(DocumentExportPDFTool.canonicalPermission, "document.export.pdf")
        XCTAssertEqual(DocumentWriteTool.canonicalPermission, "document.write")

        let digest = String(repeating: "a", count: 64)
        let readArgs = ToolArgs(raw: #"{"path":"report.docx"}"#)
        let readIntent = ReadDOCXTool().permissionIntent(
            readArgs,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertTrue(readIntent.isStructuredReadOnlyExecution)
        XCTAssertTrue(readIntent.isReadOnlyWorkspaceCompatible)
        XCTAssertEqual(readIntent.dataEffects, [.read, .execute])
        XCTAssertEqual(readIntent.replayPolicy, .safeToReplay)

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
        XCTAssertEqual(renderIntent.replayPolicy, .doNotReplay)
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

    func testDocumentReaderMapsFixedBackendMissingEnvelopeToTypedFailure() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try Data("not parsed by the fake".utf8).write(
            to: workspace.appendingPathComponent("report.docx"))
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: #"{"schema_version":1,"ok":false,"code":"backend_missing","summary":"private path","engine_versions":{},"warnings":[]}"#,
            stderr: "",
            exitCode: 0))

        do {
            _ = try await ReadDOCXTool().execute(
                ToolArgs(raw: #"{"path":"report.docx"}"#),
                in: ToolContext(workspaceRoot: workspace, documentBackend: backend))
            XCTFail("missing backend should fail")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .backendMissing)
            XCTAssertFalse(error.summary.contains("private path"))
        }
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testDocumentReaderPropagatesBackendTruncation() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try Data("not parsed by the fake".utf8).write(
            to: workspace.appendingPathComponent("report.docx"))
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: #"{"schema_version":1,"ok":true,"engine_versions":{},"result":{"format":"docx","markdown":"bounded","truncated":true},"warnings":[]}"#,
            stderr: "",
            exitCode: 0))

        let observation = try await ReadDOCXTool().execute(
            ToolArgs(raw: #"{"path":"report.docx"}"#),
            in: ToolContext(workspaceRoot: workspace, documentBackend: backend))
        XCTAssertTrue(observation.truncated)
        XCTAssertTrue(observation.text.contains(#""truncated":true"#), observation.text)
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

    #if os(macOS)
    func testLibreOfficeSandboxAllowsOnlyInvocationPrivateUnixSocket() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let socketRoot = URL(
            fileURLWithPath: "/private/tmp/intatis-lo-0123456789ab",
            isDirectory: true)
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly,
            allowedPathRules: [],
            deniedPatterns: [])

        let profile = try macOSSandboxProfile(
            workspace: workspace,
            runtime: fileManager.temporaryDirectory,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: lease,
            processCompatibility: .libreOfficeHeadless,
            libreOfficeSocketRoot: socketRoot,
            networkAccess: .denied)

        XCTAssertTrue(profile.contains(#"(subpath "/private/tmp/intatis-lo-0123456789ab")"#))
        XCTAssertTrue(profile.contains("(local unix-socket (path-regex"))
        XCTAssertTrue(profile.contains("(remote unix-socket (path-regex"))
        XCTAssertTrue(profile.contains("/OSL_PIPE_[^/]+$"))
        XCTAssertTrue(profile.contains("(deny network* (local ip) (remote ip))"))
        XCTAssertFalse(profile.contains("(allow network*)"))
    }
    #endif

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

    private func assertNonemptyMarkdown(
        _ observation: ToolObservation,
        operation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(observation.text.utf8))
        guard case .object(let root) = value,
              root["operation"] == .string(operation),
              case .object(let result)? = root["result"],
              case .string(let markdown)? = result["markdown"] else {
            return XCTFail("missing bounded Markdown result", file: file, line: line)
        }
        XCTAssertGreaterThan(markdown.trimmingCharacters(in: .whitespacesAndNewlines).count, 20)
        XCTAssertFalse(markdown.contains("data:image/"), "reader must not return embedded image data")
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
    private func makeOCRTextPDF(at url: URL) throws {
        let width = 2_400
        let height = 800
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 3)
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica-Bold" as CFString, 180, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "INTATIS OCR 48291",
            attributes: attributes))
        bitmap.textPosition = CGPoint(x: 120, y: 300)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage(),
              let consumer = CGDataConsumer(url: url as CFURL) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 4)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 200)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 5)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

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
