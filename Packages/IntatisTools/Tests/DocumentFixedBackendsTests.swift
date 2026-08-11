import Foundation
import IntatisCore
@testable import IntatisTools
import XCTest

private actor FixedBackendRecordingRunner: DocumentBackendRunner {
    private var values: [DocumentBackendInvocation] = []

    func run(
        _ invocation: DocumentBackendInvocation,
        cwd: URL
    ) async throws -> ShellResult {
        values.append(invocation)
        if invocation.arguments == ["--version"] {
            return ShellResult(
                stdout: "LibreOfficeDev 26.8.0.0.beta1 test-build\n",
                stderr: "",
                exitCode: 0)
        }
        if invocation.executable == .pdfcpu,
           invocation.arguments == ["--conf", "disable", "version"] {
            return ShellResult(
                stdout: "version: 0.13.0\n config: disabled\n",
                stderr: "",
                exitCode: 0)
        }
        if invocation.executable == .pdfcpu {
            return ShellResult(stdout: "valid\n", stderr: "", exitCode: 0)
        }
        guard invocation.executable == .libreOffice,
              let convertIndex = invocation.arguments.firstIndex(of: "--convert-to"),
              invocation.arguments.indices.contains(convertIndex + 1),
              let outputIndex = invocation.arguments.firstIndex(of: "--outdir"),
              invocation.arguments.indices.contains(outputIndex + 1),
              let inputPath = invocation.arguments.last else {
            return ShellResult(stdout: "", stderr: "unsupported invocation", exitCode: 2)
        }
        let outputDirectory = URL(
            fileURLWithPath: invocation.arguments[outputIndex + 1],
            isDirectory: true)
        let input = URL(fileURLWithPath: inputPath)
        let format = invocation.arguments[convertIndex + 1]
        if format.hasPrefix("xlsx:") {
            try FileManager.default.copyItem(
                at: input,
                to: outputDirectory.appendingPathComponent(input.lastPathComponent))
        } else if format.hasPrefix("pdf:") {
            let output = outputDirectory
                .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("pdf")
            try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: output)
        } else {
            return ShellResult(stdout: "", stderr: "unsupported format", exitCode: 2)
        }
        return ShellResult(stdout: "converted\n", stderr: "", exitCode: 0)
    }

    func invocations() -> [DocumentBackendInvocation] {
        values
    }
}

final class DocumentFixedBackendsTests: XCTestCase {
    func testPDFCPUUsesExactLongFlagsForStrictValidation() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let pdf = stage.appendingPathComponent("preview.pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf)
        let runner = FixedBackendRecordingRunner()

        _ = try await PDFCPUValidationBackend.validateStrict(
            stagedPDF: pdf,
            reviewedOutputPath: "result.pdf",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].executable, .pdfcpu)
        XCTAssertEqual(invocations[0].arguments, ["--conf", "disable", "version"])
        XCTAssertEqual(invocations[1].executable, .pdfcpu)
        XCTAssertEqual(invocations[1].arguments, [
            "--conf", "disable",
            "--offline",
            "validate",
            "--mode", "strict",
            "--",
            pdf.path,
        ])
    }

    func testLibreOfficePreviewForcesVerifiedStagedInputReadOnly() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let input = stage.appendingPathComponent("report.docx")
        try Data("docx fixture".utf8).write(to: input)
        let preview = stage.appendingPathComponent("preview.pdf")
        let runner = FixedBackendRecordingRunner()

        _ = try await LibreOfficeDocumentBackend.exportPDF(
            actualInput: input,
            reviewedInputPath: "report.docx",
            stagedPDF: preview,
            reviewedOutputPath: "result.docx",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[1].internalReadOnlyWorkspacePaths, [input.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        let profile = stage.appendingPathComponent(
            "libreoffice-profile/user/registrymodifications.xcu")
        let configuration = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(configuration.contains("DisableMacrosExecution"))
        XCTAssertTrue(configuration.contains("DisableActiveContent"))
    }

    func testLibreOfficeExportKeepsExternalInputOnReviewedReadPath() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("report.docx")
        try Data("docx fixture".utf8).write(to: input)
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let preview = stage.appendingPathComponent("preview.pdf")
        let runner = FixedBackendRecordingRunner()

        _ = try await LibreOfficeDocumentBackend.exportPDF(
            actualInput: input,
            reviewedInputPath: "report.docx",
            stagedPDF: preview,
            reviewedOutputPath: "result.pdf",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[1].readableWorkspacePaths, ["report.docx"])
        XCTAssertTrue(invocations[1].internalReadOnlyWorkspacePaths.isEmpty)
    }

    func testCalcRoundTripUsesOnlySofficeAndThenExportsPreview() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let intermediate = stage.appendingPathComponent("openpyxl-intermediate.xlsx")
        let staged = stage.appendingPathComponent("final.xlsx")
        let preview = stage.appendingPathComponent("preview.pdf")
        let source = Data("xlsx fixture".utf8)
        try source.write(to: intermediate)
        let runner = FixedBackendRecordingRunner()

        let versions = try await LibreOfficeDocumentBackend.recalculateAndSaveXLSX(
            editedInput: intermediate,
            stagedXLSX: staged,
            previewPDF: preview,
            reviewedInputPath: "source.xlsx",
            reviewedOutputPath: "result.xlsx",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 4)
        XCTAssertTrue(invocations.allSatisfy { $0.executable == .libreOffice })
        XCTAssertEqual(invocations[1].internalReadOnlyWorkspacePaths, [intermediate.path])
        XCTAssertEqual(invocations[3].internalReadOnlyWorkspacePaths, [staged.path])
        XCTAssertEqual(try Data(contentsOf: staged), source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertEqual(
            versions["xlsx_recalculation"],
            "calc_roundtrip_cache_verified")
        let profile = stage.appendingPathComponent(
            "libreoffice-calc-profile/user/registrymodifications.xcu")
        let configuration = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(configuration.contains("MacroSecurityLevel"))
        XCTAssertTrue(configuration.contains("DisablePythonRuntime"))
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-fixed-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        return workspace
    }
}
