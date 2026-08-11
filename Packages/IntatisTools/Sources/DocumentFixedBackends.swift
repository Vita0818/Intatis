import Foundation
import IntatisCore
import IntatisProtocol

enum LibreOfficeDocumentBackend {
    static let expectedProductName = "LibreOfficeDev"
    static let expectedVersion = "26.8.0.0.beta1"

    static func exportPDF(
        actualInput: URL,
        reviewedInputPath: String,
        stagedPDF: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        let version = try await requireVersion(in: context)
        let stageRoot = stagedPDF.deletingLastPathComponent()
        let outputDirectory = stageRoot.appendingPathComponent("libreoffice-output", isDirectory: true)
        let profileDirectory = stageRoot.appendingPathComponent("libreoffice-profile", isDirectory: true)
        try createPrivateBackendDirectory(outputDirectory)
        try prepareSafeLibreOfficeProfile(profileDirectory)
        let exportFilter: String
        switch actualInput.pathExtension.lowercased() {
        case "docx":
            exportFilter = "pdf:writer_pdf_Export"
        case "pptx":
            exportFilter = "pdf:impress_pdf_Export"
        case "xlsx":
            exportFilter = "pdf:calc_pdf_Export"
        default:
            throw DocumentToolError(
                .unsupportedOperation,
                "LibreOffice PDF export accepts only DOCX, PPTX, or XLSX")
        }
        let profileArgument = "-env:UserInstallation=\(profileDirectory.absoluteString)"
        let inputIsInternal = actualInput.path != stageRoot.path
            && PathConfinement.isWithin(actualInput.path, root: stageRoot)
        let invocation = DocumentBackendInvocation(
            executable: .libreOffice,
            arguments: [
                "--headless",
                "--nologo",
                "--nodefault",
                "--nofirststartwizard",
                "--nolockcheck",
                "--norestore",
                profileArgument,
                "--convert-to", exportFilter,
                "--outdir", outputDirectory.path,
                actualInput.path,
            ],
            readableWorkspacePaths: [reviewedInputPath],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: inputIsInternal ? [actualInput.path] : [])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendFailed, "LibreOffice PDF export failed")
        }
        let candidates = try safeRegularFiles(in: outputDirectory).filter {
            $0.pathExtension.lowercased() == "pdf"
        }
        guard candidates.count == 1,
              FileManager.default.fileExists(atPath: stagedPDF.path) == false else {
            throw DocumentToolError(.validationFailed, "LibreOffice did not produce exactly one PDF")
        }
        do {
            try FileManager.default.moveItem(at: candidates[0], to: stagedPDF)
        } catch {
            throw DocumentToolError(.backendFailed, "LibreOffice PDF output could not be staged")
        }
        return ["libreoffice": version]
    }

    /// Calc owns the final XLSX round trip. A newly written formula is accepted
    /// only after the caller's data-only verifier proves that LibreOffice wrote
    /// a readable cached value, so this route does not infer recalculation from
    /// a successful conversion alone.
    static func recalculateAndSaveXLSX(
        editedInput: URL,
        stagedXLSX: URL,
        previewPDF: URL,
        reviewedInputPath: String,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        let version = try await requireVersion(in: context)
        let stageRoot = stagedXLSX.deletingLastPathComponent()
        let outputDirectory = stageRoot.appendingPathComponent(
            "libreoffice-calc-output",
            isDirectory: true)
        let profile = stageRoot.appendingPathComponent(
            "libreoffice-calc-profile",
            isDirectory: true)
        try createPrivateBackendDirectory(outputDirectory)
        try prepareSafeLibreOfficeProfile(profile)
        let profileArgument = "-env:UserInstallation=\(profile.absoluteString)"
        let invocation = DocumentBackendInvocation(
            executable: .libreOffice,
            arguments: [
                "--headless",
                "--nologo",
                "--nodefault",
                "--nofirststartwizard",
                "--nolockcheck",
                "--norestore",
                profileArgument,
                "--convert-to", "xlsx:Calc MS Excel 2007 XML",
                "--outdir", outputDirectory.path,
                editedInput.path,
            ],
            readableWorkspacePaths: [reviewedInputPath],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: [editedInput.path])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendFailed, "LibreOffice Calc XLSX round trip failed")
        }
        let candidates = try safeRegularFiles(in: outputDirectory).filter {
            $0.pathExtension.lowercased() == "xlsx"
        }
        guard candidates.count == 1,
              FileManager.default.fileExists(atPath: stagedXLSX.path) == false else {
            throw DocumentToolError(
                .validationFailed,
                "LibreOffice Calc did not produce exactly one XLSX")
        }
        do {
            try FileManager.default.moveItem(at: candidates[0], to: stagedXLSX)
        } catch {
            throw DocumentToolError(.backendFailed, "LibreOffice Calc output could not be staged")
        }
        var versions = try await exportPDF(
            actualInput: stagedXLSX,
            reviewedInputPath: reviewedOutputPath,
            stagedPDF: previewPDF,
            reviewedOutputPath: reviewedOutputPath,
            in: context)
        versions["libreoffice"] = version
        versions["xlsx_recalculation"] = "calc_roundtrip_cache_verified"
        return versions
    }

    private static func requireVersion(in context: ToolContext) async throws -> String {
        let invocation = DocumentBackendInvocation(
            executable: .libreOffice,
            arguments: ["--version"],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendMissing, "LibreOffice is unavailable")
        }
        let firstLine = result.stdout.split(whereSeparator: { $0.isNewline }).first.map(String.init)
            ?? result.stderr.split(whereSeparator: { $0.isNewline }).first.map(String.init)
            ?? ""
        let versionFields = firstLine.split(whereSeparator: { $0.isWhitespace })
        guard versionFields.count >= 2,
              versionFields[0] == Substring(expectedProductName),
              versionFields[1] == Substring(expectedVersion) else {
            throw DocumentToolError(.backendVersionMismatch, "LibreOffice version does not match the fixed manifest")
        }
        return expectedVersion
    }

    private static func run(
        _ invocation: DocumentBackendInvocation,
        in context: ToolContext
    ) async throws -> ShellResult {
        do {
            return try await context.documentBackend.run(invocation, cwd: context.workspaceRoot)
        } catch let error as DocumentToolError {
            throw error
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "LibreOffice is unavailable at its fixed path")
            }
            throw DocumentToolError(.backendFailed, "LibreOffice could not be started")
        } catch {
            throw DocumentToolError(.backendFailed, "LibreOffice could not be started")
        }
    }

}

private func prepareSafeLibreOfficeProfile(_ profile: URL) throws {
    try createPrivateBackendDirectory(profile)
    let user = profile.appendingPathComponent("user", isDirectory: true)
    try createPrivateBackendDirectory(user)
    let configuration = user.appendingPathComponent("registrymodifications.xcu")
    let xml = #"""
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
    <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
    <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="DisableActiveContent" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="DisablePythonRuntime" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="DisableOLEAutomation" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop>
  </item>
</oor:items>
"""#
    do {
        try Data(xml.utf8).write(to: configuration, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: configuration.path)
    } catch {
        throw DocumentToolError(
            .backendFailed,
            "LibreOffice safe profile could not be prepared")
    }
}

enum PDFCPUValidationBackend {
    static let expectedVersion = "0.13.0"

    static func validateStrict(
        stagedPDF: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        let stageRoot = stagedPDF.deletingLastPathComponent()
        let versionInvocation = DocumentBackendInvocation(
            executable: .pdfcpu,
            arguments: ["--conf", "disable", "version"],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let versionResult = try await run(versionInvocation, in: context)
        let versionLines = (versionResult.stdout + "\n" + versionResult.stderr)
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard versionResult.exitCode == 0,
              versionLines.contains("version: \(expectedVersion)") else {
            throw DocumentToolError(.backendVersionMismatch, "pdfcpu version does not match the fixed manifest")
        }
        let invocation = DocumentBackendInvocation(
            executable: .pdfcpu,
            arguments: [
                "--conf", "disable",
                "--offline",
                "validate",
                "--mode", "strict",
                "--",
                stagedPDF.path,
            ],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: [stagedPDF.path])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.validationFailed, "pdfcpu strict validation rejected the generated PDF")
        }
        return ["pdfcpu": expectedVersion, "pdfcpu_mode": "strict"]
    }

    private static func run(
        _ invocation: DocumentBackendInvocation,
        in context: ToolContext
    ) async throws -> ShellResult {
        do {
            return try await context.documentBackend.run(invocation, cwd: context.workspaceRoot)
        } catch let error as DocumentToolError {
            throw error
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "pdfcpu is unavailable at its fixed runtime path")
            }
            throw DocumentToolError(.backendFailed, "pdfcpu could not be started")
        } catch {
            throw DocumentToolError(.backendFailed, "pdfcpu could not be started")
        }
    }
}

private func createPrivateBackendDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw DocumentToolError(.validationFailed, "backend staging path is not a directory")
        }
    } else {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path)
}

private func safeRegularFiles(in directory: URL) throws -> [URL] {
    let values = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    return try values.filter { url in
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isSymbolicLink != true else {
            throw DocumentToolError(.validationFailed, "backend output contains a symlink")
        }
        return properties.isRegularFile == true
    }
}

private extension JSONEncoder {
    static var sortedFixedBackendEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
