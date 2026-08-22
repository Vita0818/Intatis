import Foundation
import IntatisCore
import IntatisProtocol

struct CodexRuntimeStorage: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let runtimeVersion: String
        let threadID: String
        let mode: CodexRuntimeMode
        let workspacePath: String
        let materialized: Bool
    }

    let rootURL: URL
    let homeURL: URL
    let recordURL: URL
    let modelCatalogURL: URL
    let processLockURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.homeURL = self.rootURL.appendingPathComponent(
            "codex-home",
            isDirectory: true)
        self.recordURL = self.rootURL.appendingPathComponent(
            "runtime.json")
        self.modelCatalogURL = self.rootURL.appendingPathComponent(
            "models.json")
        self.processLockURL = self.rootURL.appendingPathComponent(
            "runtime.lock")
    }

    func prepare() throws {
        try prepareOwnedDirectory(rootURL)
        try prepareOwnedDirectory(homeURL)
    }

    func rejectPersistedShellSnapshots() throws {
        let snapshotURL = homeURL.appendingPathComponent(
            "shell_snapshots",
            isDirectory: true)
        do {
            _ = try FileManager.default.attributesOfItem(
                atPath: snapshotURL.path)
            throw CodexRuntimeError.shellSnapshotStoragePresent
        } catch let error as CodexRuntimeError {
            throw error
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
                || error.code == .fileNoSuchFile {
            return
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    func readRecord() throws -> Record? {
        guard let data = try DurableOwnerOnlyFile.read(
            from: recordURL,
            maximumBytes: 16 * 1_024) else {
            return nil
        }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schemaVersion == 2,
                  record.runtimeVersion == CodexRuntimeExecutable.pinnedVersion,
                  record.materialized,
                  !record.threadID.isEmpty,
                  !record.threadID.contains("\n"),
                  !record.threadID.contains("\r") else {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
            return record
        } catch let error as CodexRuntimeError {
            throw error
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    func writeRecord(
        threadID: String,
        mode: CodexRuntimeMode,
        workspacePath: String
    ) throws {
        guard !threadID.isEmpty,
              !threadID.contains("\n"),
              !threadID.contains("\r") else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/start returned an invalid thread id")
        }
        let data = try JSONEncoder.intatisCodex.encode(Record(
            schemaVersion: 2,
            runtimeVersion: CodexRuntimeExecutable.pinnedVersion,
            threadID: threadID,
            mode: mode,
            workspacePath: workspacePath,
            materialized: true))
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: recordURL,
                temporaryPrefix: ".codex-runtime-")
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    /// Supplies model metadata through Codex's official static-catalog
    /// extension point. The selected Responses model is also the approval
    /// reviewer model, avoiding an implicit request for an unrelated OpenAI
    /// model on third-party Responses endpoints.
    func writeModelCatalog(
        modelID: String,
        baseInstructions: String
    ) throws {
        guard !modelID.isEmpty,
              modelID.count <= 256,
              modelID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CodexRuntimeError.malformedProtocol(
                "the selected Responses model id is invalid")
        }
        let supportedReasoning: [JSONValue] = [
            "minimal", "low", "medium", "high",
            "xhigh", "max", "ultra",
        ].map { effort in
            .object([
                "effort": .string(effort),
                "description": .string(effort),
            ])
        }
        let model: JSONValue = .object([
            "slug": .string(modelID),
            "display_name": .string(modelID),
            "description": .null,
            "base_instructions": .string(baseInstructions),
            "default_reasoning_level": .null,
            "supported_reasoning_levels": .array(
                supportedReasoning),
            "shell_type": .string("unified_exec"),
            "visibility": .string("list"),
            "supported_in_api": .bool(true),
            "priority": .number(1),
            "availability_nux": .null,
            "upgrade": .null,
            "support_verbosity": .bool(false),
            "default_verbosity": .null,
            "apply_patch_tool_type": .null,
            "truncation_policy": .object([
                "mode": .string("bytes"),
                "limit": .number(10_000),
            ]),
            "supports_parallel_tool_calls": .bool(false),
            "experimental_supported_tools": .array([]),
            "input_modalities": .array([
                .string("text"),
                .string("image"),
            ]),
            "context_window": .number(272_000),
            "max_context_window": .number(272_000),
            "effective_context_window_percent": .number(95),
            "include_skills_usage_instructions": .bool(false),
            "include_plugin_usage_instructions": .bool(false),
            "include_apps_usage_instructions": .bool(false),
            "supports_reasoning_summary_parameter": .bool(true),
            "default_reasoning_summary": .string("auto"),
            "web_search_tool_type": .string("text"),
            "supports_image_detail_original": .bool(false),
            "supports_search_tool": .bool(false),
            "use_responses_lite": .bool(false),
            "node_repl_auto_review_required": .bool(false),
            "node_repl_disabled": .bool(false),
            "auto_review_model_override": .string(modelID),
            "multi_agent_version": .string("v1"),
        ])
        let data = try JSONEncoder.intatisCodex.encode(
            JSONValue.object([
                "models": .array([model]),
            ]))
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: modelCatalogURL,
                temporaryPrefix: ".codex-models-")
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    private func prepareOwnedDirectory(_ url: URL) throws {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [
                        .posixPermissions: NSNumber(value: 0o700),
                    ])
            }
            let canonical = try DurableOwnerOnlyFile
                .validateOwnedDirectory(at: url)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: canonical.path)
            guard let permissions = attributes[.posixPermissions]
                    as? NSNumber,
                  permissions.intValue & 0o777 == 0o700 else {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }
}

extension JSONEncoder {
    static var intatisCodex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
