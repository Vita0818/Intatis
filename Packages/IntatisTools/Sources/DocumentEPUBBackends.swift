import Foundation
import IntatisCore
import IntatisProtocol

enum RBookDocumentBackend {
    static let expectedVersion = "0.7.10"

    static func run(
        operation: String,
        payload: JSONValue,
        reviewedInputPaths: [String],
        reviewedOutputPaths: [String] = [],
        internalStageRoot: String? = nil,
        in context: ToolContext
    ) async throws -> DocumentBackendEnvelope {
        let request: JSONValue = .object([
            "schema_version": .number(1),
            "engine": .string("rbook"),
            "expected_version": .string(expectedVersion),
            "operation": .string(operation),
            "payload": payload,
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.utf8.count <= 256 * 1_024 else {
            throw DocumentToolError(.validationFailed, "EPUB helper request is too large")
        }
        let invocation = DocumentBackendInvocation(
            executable: .rbookHelper,
            arguments: ["json-v1"],
            environment: [
                "INTATIS_DOCUMENT_REQUEST": encoded,
                "INTATIS_DOCUMENT_OPERATION": operation,
                "PYTHONHASHSEED": "0",
            ],
            readableWorkspacePaths: reviewedInputPaths,
            writableWorkspacePaths: reviewedOutputPaths,
            internalWritableWorkspacePaths: internalStageRoot.map { [$0] } ?? [])
        let result: ShellResult
        do {
            result = try await context.documentBackend.run(invocation, cwd: context.workspaceRoot)
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "fixed rbook helper is unavailable")
            }
            throw DocumentToolError(.backendFailed, "rbook helper could not start")
        } catch let error as DocumentToolError {
            throw error
        } catch {
            throw DocumentToolError(.backendFailed, "rbook helper could not start")
        }
        guard result.exitCode == 0,
              let responseData = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                  DocumentBackendEnvelope.self,
                  from: responseData),
              response.schemaVersion == 1 else {
            throw DocumentToolError(.backendFailed, "rbook helper returned an invalid envelope")
        }
        guard response.ok else {
            let code = response.code.flatMap(DocumentToolErrorCode.init(rawValue:))
                ?? .backendFailed
            throw DocumentToolError(code, "rbook EPUB operation failed")
        }
        guard response.engineVersions["rbook"] == expectedVersion else {
            throw DocumentToolError(.backendVersionMismatch, "rbook helper version mismatch")
        }
        return response
    }
}

enum EPUBCheckValidationBackend {
    static let expectedVersion = "5.3.0"

    static func validate(
        stagedEPUB: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        let stageRoot = stagedEPUB.deletingLastPathComponent()
        let report = stageRoot.appendingPathComponent("epubcheck-report.json")
        let versionInvocation = DocumentBackendInvocation(
            executable: .epubCheck,
            arguments: ["--version"],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let version = try await run(versionInvocation, in: context)
        guard version.exitCode == 0,
              (version.stdout + version.stderr).contains(expectedVersion) else {
            throw DocumentToolError(.backendVersionMismatch, "EPUBCheck version mismatch")
        }
        let invocation = DocumentBackendInvocation(
            executable: .epubCheck,
            arguments: [
                stagedEPUB.path,
                "--json", report.path,
            ],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: [stagedEPUB.path])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.validationFailed, "EPUBCheck rejected the staged EPUB")
        }
        return ["epubcheck": expectedVersion]
    }

    private static func run(
        _ invocation: DocumentBackendInvocation,
        in context: ToolContext
    ) async throws -> ShellResult {
        do {
            return try await context.documentBackend.run(invocation, cwd: context.workspaceRoot)
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "fixed EPUBCheck runtime is unavailable")
            }
            throw DocumentToolError(.backendFailed, "EPUBCheck could not start")
        } catch let error as DocumentToolError {
            throw error
        } catch {
            throw DocumentToolError(.backendFailed, "EPUBCheck could not start")
        }
    }
}
