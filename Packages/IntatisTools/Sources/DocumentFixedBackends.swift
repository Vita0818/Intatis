import Foundation
import IntatisCore
import IntatisProtocol

enum LibreOfficeDocumentBackend {
    static let expectedVersion = "26.2.5.2"

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
        try createPrivateBackendDirectory(profileDirectory)
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
        let invocation = DocumentBackendInvocation(
            executable: .libreOffice,
            arguments: [
                "--headless",
                "--nologo",
                "--nodefault",
                "--nofirststartwizard",
                "--nolockcheck",
                profileArgument,
                "--convert-to", exportFilter,
                "--outdir", outputDirectory.path,
                actualInput.path,
            ],
            readableWorkspacePaths: [reviewedInputPath],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path])
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

    /// The fixed Calc route is intentionally a UNO `calculateAll` + explicit
    /// XLSX save, not a `--convert-to` claim. The helper launches the exact
    /// bundled soffice binary with an isolated profile and no macro/link update.
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
        let profile = stageRoot.appendingPathComponent("libreoffice-profile", isDirectory: true)
        try createPrivateBackendDirectory(profile)
        let request: JSONValue = .object([
            "input_path": .string(editedInput.path),
            "output_path": .string(stagedXLSX.path),
            "preview_pdf_path": .string(previewPDF.path),
            "profile_path": .string(profile.path),
            "expected_version": .string(expectedVersion),
        ])
        let data = try JSONEncoder.sortedFixedBackendEncoder.encode(request)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DocumentToolError(.validationFailed, "Calc request could not be encoded")
        }
        let invocation = DocumentBackendInvocation(
            executable: .libreOfficePython,
            arguments: ["-c", calcUNOProgram],
            environment: [
                "INTATIS_DOCUMENT_REQUEST": encoded,
                "INTATIS_DOCUMENT_OPERATION": "xlsx_calculate_save",
                "PYTHONHASHSEED": "0",
            ],
            readableWorkspacePaths: [reviewedInputPath],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: [editedInput.path])
        let result: ShellResult
        do {
            result = try await context.documentBackend.run(invocation, cwd: context.workspaceRoot)
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "LibreOffice UNO runtime is unavailable")
            }
            throw DocumentToolError(.backendFailed, "LibreOffice UNO helper could not start")
        } catch let error as DocumentToolError {
            throw error
        } catch {
            throw DocumentToolError(.backendFailed, "LibreOffice UNO helper could not start")
        }
        guard result.exitCode == 0,
              let responseData = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                  LibreOfficeUNOResponse.self,
                  from: responseData) else {
            throw DocumentToolError(
                .backendMissing,
                "LibreOffice UNO helper is unavailable or incompatible")
        }
        guard response.ok else {
            let code = response.code.flatMap(DocumentToolErrorCode.init(rawValue:))
                ?? .backendFailed
            throw DocumentToolError(code, "LibreOffice Calc calculate/save failed")
        }
        guard FileManager.default.fileExists(atPath: stagedXLSX.path),
              FileManager.default.fileExists(atPath: previewPDF.path) else {
            throw DocumentToolError(.validationFailed, "Calc did not produce both XLSX and preview PDF")
        }
        return ["libreoffice": version, "uno": "calculateAll"]
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
        guard firstLine.contains("LibreOffice \(expectedVersion)") else {
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

    private struct LibreOfficeUNOResponse: Decodable {
        let ok: Bool
        let code: String?
    }

    private static let calcUNOProgram = #"""
import json
import os
import pathlib
import subprocess
import sys
import time

def emit(value):
    print(json.dumps(value, sort_keys=True, separators=(',', ':')))

process = None
document = None
try:
    import uno
    from com.sun.star.beans import PropertyValue
    request = json.loads(os.environ['INTATIS_DOCUMENT_REQUEST'])
    if set(request) != {'expected_version', 'input_path', 'output_path', 'preview_pdf_path', 'profile_path'}:
        raise ValueError('invalid UNO request')
    for key in ('input_path', 'output_path', 'preview_pdf_path', 'profile_path'):
        if not isinstance(request[key], str) or not os.path.isabs(request[key]) or '\x00' in request[key]:
            raise ValueError('invalid UNO path')
    soffice = '/Applications/LibreOffice.app/Contents/MacOS/soffice'
    version = subprocess.run([soffice, '--version'], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, timeout=5, check=False).stdout
    if ('LibreOffice ' + request['expected_version']) not in version:
        emit({'ok': False, 'code': 'backend_version_mismatch'})
        sys.exit(0)
    pipe_name = 'intatis_document_' + os.urandom(12).hex()
    profile_url = pathlib.Path(request['profile_path']).as_uri()
    process = subprocess.Popen([
        soffice, '--headless', '--nologo', '--nodefault', '--nofirststartwizard',
        '--nolockcheck', '-env:UserInstallation=' + profile_url,
        '--accept=pipe,name=' + pipe_name + ';urp;StarOffice.ComponentContext',
    ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    local_context = uno.getComponentContext()
    resolver = local_context.ServiceManager.createInstanceWithContext(
        'com.sun.star.bridge.UnoUrlResolver', local_context)
    context = None
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        try:
            context = resolver.resolve(
                'uno:pipe,name=' + pipe_name + ';urp;StarOffice.ComponentContext')
            break
        except Exception:
            time.sleep(0.05)
    if context is None:
        emit({'ok': False, 'code': 'backend_missing'})
        sys.exit(0)
    service_manager = context.ServiceManager
    desktop = service_manager.createInstanceWithContext('com.sun.star.frame.Desktop', context)
    def prop(name, value):
        item = PropertyValue()
        item.Name = name
        item.Value = value
        return item
    load_properties = (
        prop('Hidden', True),
        prop('ReadOnly', False),
        prop('MacroExecutionMode', 0),
        prop('UpdateDocMode', 0),
    )
    document = desktop.loadComponentFromURL(
        pathlib.Path(request['input_path']).as_uri(), '_blank', 0, load_properties)
    if document is None or not hasattr(document, 'calculateAll'):
        emit({'ok': False, 'code': 'unsupported_feature'})
        sys.exit(0)
    document.calculateAll()
    xlsx_properties = (
        prop('FilterName', 'Calc MS Excel 2007 XML'),
        prop('Overwrite', True),
    )
    document.storeAsURL(pathlib.Path(request['output_path']).as_uri(), xlsx_properties)
    pdf_properties = (
        prop('FilterName', 'calc_pdf_Export'),
        prop('Overwrite', True),
    )
    document.storeToURL(pathlib.Path(request['preview_pdf_path']).as_uri(), pdf_properties)
    emit({'ok': True})
except ModuleNotFoundError:
    emit({'ok': False, 'code': 'backend_missing'})
except Exception:
    emit({'ok': False, 'code': 'backend_failed'})
finally:
    if document is not None:
        try:
            document.close(True)
        except Exception:
            try:
                document.dispose()
            except Exception:
                pass
    if process is not None:
        try:
            process.terminate()
            process.wait(timeout=2)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
"""#
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
            arguments: ["version"],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let versionResult = try await run(versionInvocation, in: context)
        guard versionResult.exitCode == 0,
              (versionResult.stdout + versionResult.stderr).contains("v\(expectedVersion)") else {
            throw DocumentToolError(.backendVersionMismatch, "pdfcpu version does not match the fixed manifest")
        }
        let invocation = DocumentBackendInvocation(
            executable: .pdfcpu,
            arguments: [
                "-conf", "disable",
                "-offline",
                "validate",
                "-mode", "strict",
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
