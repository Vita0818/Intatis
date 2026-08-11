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
        let payload = canonicalizedPayload(payload)
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

    /// The Rust helper deliberately rejects lexical paths that differ from
    /// their canonical filesystem identity. Foundation preserves macOS's
    /// public `/var`, `/tmp`, and `/etc` aliases even when the corresponding
    /// POSIX canonical path starts with `/private`; normalize only the
    /// host-owned path fields before crossing that fixed helper boundary.
    private static func canonicalizedPayload(_ payload: JSONValue) -> JSONValue {
        guard case .object(var object) = payload else { return payload }
        for key in ["input_path", "output_path"] {
            if case .string(let path)? = object[key] {
                object[key] = .string(canonicalPath(path))
            }
        }
        if case .array(let paths)? = object["allowed_asset_paths"] {
            object["allowed_asset_paths"] = .array(paths.map { value in
                guard case .string(let path) = value else { return value }
                return .string(canonicalPath(path))
            })
        }
        if case .array(let operations)? = object["operations"] {
            object["operations"] = .array(operations.map { operation in
                guard case .object(var fields) = operation,
                      case .object(var parameters)? = fields["parameters"] else {
                    return operation
                }
                for key in ["path", "source_path"] {
                    if case .string(let path)? = parameters[key] {
                        parameters[key] = .string(canonicalPath(path))
                    }
                }
                fields["parameters"] = .object(parameters)
                return .object(fields)
            })
        }
        return .object(object)
    }

    private static func canonicalPath(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        #if os(macOS)
        for alias in ["/var", "/tmp", "/etc"]
            where normalized == alias || normalized.hasPrefix(alias + "/") {
            normalized = "/private" + normalized
            break
        }
        #endif
        return normalized
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
