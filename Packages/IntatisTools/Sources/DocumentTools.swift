import Foundation
import IntatisCore
import IntatisProtocol

// MARK: - Shared, host-owned document tool glue

enum DocumentPageSelection {
    /// Returns nil for the explicit/default `all` selection. Every returned
    /// page number is one-based, unique, and sorted.
    static func parse(_ raw: String?, maximumCount: Int) throws -> [Int]? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty || value.lowercased() == "all" { return nil }

        var selected = Set<Int>()
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            let token = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw DocumentToolError(.validationFailed, "page selection contains an empty item")
            }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2,
                  let first = Int(bounds[0]),
                  first > 0 else {
                throw DocumentToolError(.validationFailed, "page selection is invalid")
            }
            let last: Int
            if bounds.count == 2 {
                guard let parsed = Int(bounds[1]), parsed >= first else {
                    throw DocumentToolError(.validationFailed, "page range is invalid")
                }
                last = parsed
            } else {
                last = first
            }
            guard last - first < maximumCount else {
                throw DocumentToolError(.validationFailed, "page selection exceeds the operation limit")
            }
            for page in first...last {
                selected.insert(page)
                guard selected.count <= maximumCount else {
                    throw DocumentToolError(.validationFailed, "too many pages were selected")
                }
            }
        }
        return selected.sorted()
    }

    static func expand(
        _ raw: String?,
        pageCount: Int,
        maximumCount: Int
    ) throws -> [Int] {
        let selected = try parse(raw, maximumCount: maximumCount)
            ?? Array(1...pageCount)
        guard selected.count <= maximumCount,
              selected.allSatisfy({ (1...pageCount).contains($0) }) else {
            throw DocumentToolError(
                .validationFailed,
                "selected pages are outside the document or exceed the operation limit")
        }
        return selected
    }
}

private actor DocumentExecutionAccumulator {
    private var engineVersions: [String: String] = [:]
    private var warnings: [String] = []
    private var result: JSONValue?

    func record(
        versions: [String: String] = [:],
        warnings newWarnings: [String] = [],
        result newResult: JSONValue? = nil
    ) {
        engineVersions.merge(versions) { _, new in new }
        warnings.append(contentsOf: newWarnings)
        if let newResult { result = newResult }
    }

    func snapshot() -> (
        versions: [String: String],
        warnings: [String],
        result: JSONValue?
    ) {
        (engineVersions, warnings, result)
    }
}

private enum DocumentToolSupport {
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func observation(
        operation: String,
        format: DocumentFormat,
        result: JSONValue? = nil,
        engineVersions: [String: String] = [:],
        warnings: [String] = [],
        receipt: DocumentCommitReceipt? = nil,
        changedFiles: [String]? = nil,
        truncated: Bool = false
    ) throws -> ToolObservation {
        var object: [String: JSONValue] = [
            "status": .string("ok"),
            "operation": .string(operation),
            "format": .string(format.rawValue),
            "engine_versions": .object(engineVersions.mapValues(JSONValue.string)),
            "warnings": .array(warnings.map(JSONValue.string)),
        ]
        if let result { object["result"] = result }
        if let receipt {
            object["commit"] = .object([
                "path": .string(receipt.relativePath),
                "sha256": .string(receipt.sha256),
                "byte_count": .number(Double(receipt.byteCount)),
                "file_count": .number(Double(receipt.fileCount)),
                "cleanup_warning": receipt.cleanupWarning.map(JSONValue.string) ?? .null,
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(JSONValue.object(object))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentToolError(.backendFailed, "document result could not be encoded")
        }
        return ToolObservation(
            text: text,
            truncated: truncated,
            changedFiles: changedFiles)
    }

    static func processReadIntent(
        action: String,
        paths: [String],
        operation: String,
        format: DocumentFormat,
        replayPolicy: ToolExecutionReplayPolicy = .doNotReplay
    ) -> PermissionIntent {
        PermissionIntent(
            action: action,
            resources: paths.map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
            },
            metadata: [
                "operation": .string(operation),
                "format": .string(format.rawValue),
                "execution_class": .string(
                    PermissionIntent.structuredReadOnlyExecutionClass),
            ],
            dataEffects: [.read, .execute],
            risks: [.processExecution],
            replayPolicy: replayPolicy)
    }

    static func writeIntent(
        action: String,
        readPaths: [String],
        writePath: String,
        operation: String,
        format: DocumentFormat
    ) -> PermissionIntent {
        var resources = readPaths.map {
            PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
        }
        resources.append(PermissionResource(
            kind: .workspacePath,
            value: writePath,
            access: .readWrite))
        return PermissionIntent(
            action: action,
            resources: resources,
            metadata: [
                "operation": .string(operation),
                "format": .string(format.rawValue),
            ],
            dataEffects: [.read, .execute, .mutate],
            risks: [.processExecution, .workspaceMutation],
            replayPolicy: .doNotReplay)
    }

    struct FrozenAuxiliaryInputs: Sendable {
        let urlsByReviewedPath: [String: URL]
        let snapshots: [DocumentInputSnapshot]
    }

    static func freezeAuxiliaryInputs(
        _ paths: [String],
        workspace: URL
    ) throws -> FrozenAuxiliaryInputs {
        let maximumAssetBytes: UInt64 = 128 * 1_024 * 1_024
        let maximumTotalBytes: UInt64 = 512 * 1_024 * 1_024
        var urlsByReviewedPath: [String: URL] = [:]
        var snapshots: [DocumentInputSnapshot] = []
        var totalBytes: UInt64 = 0
        for path in paths {
            let snapshot = try DocumentInputFile.freezeReadOnly(
                path: path,
                maximumBytes: maximumAssetBytes,
                workspace: workspace)
            guard snapshot.identity.byteCount <= maximumTotalBytes - totalBytes else {
                throw DocumentToolError(
                    .validationFailed,
                    "document assets exceed the aggregate input budget")
            }
            totalBytes += snapshot.identity.byteCount
            urlsByReviewedPath[path] = snapshot.url
            snapshots.append(snapshot)
        }
        return FrozenAuxiliaryInputs(
            urlsByReviewedPath: urlsByReviewedPath,
            snapshots: snapshots)
    }

    static func validateGeneratedPDF(
        _ pdf: URL,
        reviewedOutputPath: String,
        context: ToolContext
    ) async throws -> [String: String] {
        var versions = try await PDFCPUValidationBackend.validateStrict(
            stagedPDF: pdf,
            reviewedOutputPath: reviewedOutputPath,
            in: context)
        let smokeDirectory = pdf.deletingLastPathComponent().appendingPathComponent(
            ".pdf-render-smoke-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: smokeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        defer { try? FileManager.default.removeItem(at: smokeDirectory) }
        do {
            _ = try PDFNativeDocumentService.renderPages(
                from: pdf,
                into: smokeDirectory,
                pages: [1],
                box: .cropBox,
                dpi: 72,
                background: .white,
                includeAnnotations: true,
                maximumPagePixels: 20_000_000,
                maximumTotalPixels: 20_000_000,
                maximumOutputBytes: 64 * 1_024 * 1_024)
        } catch {
            throw DocumentToolError(
                .validationFailed,
                "the generated PDF failed the native render smoke test")
        }
        versions["pdf_renderer"] = "PDFKit-system"
        return versions
    }

    static func validatePDFFile(_ pdf: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: pdf) else {
            throw DocumentToolError(.validationFailed, "generated PDF is not readable")
        }
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 5) ?? Data()
        guard prefix == Data("%PDF-".utf8) else {
            throw DocumentToolError(.validationFailed, "generated output is not a PDF")
        }
    }

    static func validateRenderBundle(_ directory: URL) throws {
        let manifestURL = directory.appendingPathComponent(
            PDFNativeDocumentService.manifestFileName,
            isDirectory: false)
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let manifest = try JSONDecoder().decode(PDFNativeRenderManifest.self, from: data)
        guard manifest.schemaVersion == 1,
              !manifest.pages.isEmpty,
              manifest.pages.allSatisfy({ page in
                  page.mimeType == "image/png"
                      && page.byteCount > 0
                      && page.sha256.utf8.count == 64
                      && FileManager.default.fileExists(
                          atPath: directory.appendingPathComponent(page.fileName).path)
              }) else {
            throw DocumentToolError(.validationFailed, "render bundle manifest is invalid")
        }
    }

    static func renderablePDF(
        format: DocumentFormat,
        input: URL,
        reviewedInputPath: String,
        reviewedOutputPath: String,
        allowedHTMLAssets: [String: URL],
        stagedPDF: URL,
        context: ToolContext
    ) async throws -> [String: String] {
        switch format {
        case .docx, .pptx, .xlsx:
            return try await LibreOfficeDocumentBackend.exportPDF(
                actualInput: input,
                reviewedInputPath: reviewedInputPath,
                stagedPDF: stagedPDF,
                reviewedOutputPath: reviewedOutputPath,
                in: context)
        case .html:
            return try await prepareAndRenderHTML(
                input: input,
                reviewedInputPaths: [reviewedInputPath] + allowedHTMLAssets.keys.sorted(),
                reviewedOutputPath: reviewedOutputPath,
                allowedHTMLAssets: allowedHTMLAssets,
                stagedPDF: stagedPDF,
                context: context)
        case .epub:
            throw DocumentToolError(
                .unsupportedFeature,
                "EPUB full-spine PDF export has not passed its required corpus gate")
        case .pdf:
            throw DocumentToolError(.unsupportedOperation, "PDF input is not an export route")
        }
    }

    static func prepareAndRenderHTML(
        input: URL,
        reviewedInputPaths: [String],
        reviewedOutputPath: String,
        allowedHTMLAssets: [String: URL],
        stagedPDF: URL,
        context: ToolContext
    ) async throws -> [String: String] {
        let stageRoot = stagedPDF.deletingLastPathComponent()
        let sanitizedHTML = stageRoot.appendingPathComponent(
            ".sanitized-html-\(UUID().uuidString).html",
            isDirectory: false)
        var needsCleanup = true
        defer {
            if needsCleanup,
               FileManager.default.fileExists(atPath: sanitizedHTML.path) {
                try? FileManager.default.removeItem(at: sanitizedHTML)
            }
        }

        let inputIsInternal = input.path != stageRoot.path
            && PathConfinement.isWithin(input.path, root: stageRoot)
        let envelope = try await DocumentPythonBackend.run(
            operation: "prepare_html_render",
            payload: .object([
                "input_path": .string(input.path),
                "output_path": .string(sanitizedHTML.path),
                "allowed_asset_paths": .array(
                    allowedHTMLAssets.values.map { .string($0.path) }.sorted(by: jsonStringLess)),
            ]),
            readableWorkspacePaths: reviewedInputPaths,
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: inputIsInternal ? [input.path] : [],
            in: context)
        guard case .object(let result)? = envelope.result,
              result["format"] == .string("html"),
              result["sanitized"] == .bool(true),
              case .number(let count)? = result["inlined_asset_count"],
              count.isFinite,
              count.rounded(.towardZero) == count,
              count >= 0,
              count <= 256 else {
            throw DocumentToolError(
                .validationFailed,
                "HTML sanitizer did not return its fixed success contract")
        }
        try Task.checkCancellation()
        let rendererVersions = try await HTMLDocumentPDFRenderer.render(
            input: sanitizedHTML,
            stageRoot: stageRoot,
            stagedPDF: stagedPDF)
        do {
            try FileManager.default.removeItem(at: sanitizedHTML)
            needsCleanup = false
        } catch {
            throw DocumentToolError(
                .validationFailed,
                "sanitized HTML staging cleanup failed")
        }
        var versions = envelope.engineVersions
        for (name, version) in rendererVersions {
            versions[name] = version
        }
        return versions
    }

    static func moveRenderedBundle(from source: URL, to destination: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [])
        for child in children {
            let values = try child.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DocumentToolError(.validationFailed, "render backend emitted an unsafe entry")
            }
            try FileManager.default.moveItem(
                at: child,
                to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    static func writeOperationPaths(_ value: DocumentWriteArguments) -> [String] {
        var paths: [String] = []
        if let input = value.inputPath { paths.append(input) }
        paths.append(contentsOf: value.localAssetPaths ?? [])
        for operation in value.operations {
            for key in ["path", "source_path"] {
                if case .string(let path)? = operation.parameters[key] {
                    paths.append(path)
                }
            }
        }
        paths.append(value.outputPath)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    static func resolvedWriteOperations(
        _ operations: [DocumentWriteOperation],
        assets: [String: URL]
    ) -> JSONValue {
        .array(operations.map { operation in
            var parameters = operation.parameters
            for key in ["path", "source_path"] {
                if case .string(let original)? = parameters[key],
                   let resolved = assets[original] {
                    parameters[key] = .string(resolved.path)
                }
            }
            return .object([
                "kind": .string(operation.kind),
                "parameters": .object(parameters),
            ])
        })
    }

    static func verifyWrittenNativeDocument(
        _ stagedOutput: URL,
        format: DocumentFormat,
        resolvedOperations: JSONValue,
        expectedOperationCount: Int,
        assets: [String: URL],
        reviewedOutputPath: String,
        stageRoot: URL,
        context: ToolContext
    ) async throws -> DocumentBackendEnvelope {
        guard [.docx, .pptx, .xlsx, .html].contains(format) else {
            throw DocumentToolError(
                .unsupportedOperation,
                "format has no fixed native write verifier")
        }
        let allowedAssets = assets.values
            .map { JSONValue.string($0.path) }
            .sorted(by: jsonStringLess)
        let envelope = try await DocumentPythonBackend.run(
            operation: "verify_write",
            payload: .object([
                "format": .string(format.rawValue),
                "input_path": .string(stagedOutput.path),
                "operations": resolvedOperations,
                "allowed_asset_paths": .array(allowedAssets),
            ]),
            readableWorkspacePaths: [],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: [stagedOutput.path],
            in: context)
        guard case .object(let result)? = envelope.result,
              case .string(let verifiedFormat)? = result["format"],
              verifiedFormat == format.rawValue,
              case .number(let verifiedCount)? = result["verified_count"],
              verifiedCount.isFinite,
              verifiedCount.rounded(.towardZero) == verifiedCount,
              Int(exactly: verifiedCount) == expectedOperationCount else {
            throw DocumentToolError(
                .validationFailed,
                "document write verifier did not confirm every declared operation")
        }
        return envelope
    }

    private static func jsonStringLess(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        guard case .string(let left) = lhs, case .string(let right) = rhs else { return false }
        return left < right
    }
}

// MARK: - Fixed-format text readers

private enum DocumentTextReadSupport {
    static func value(_ args: ToolArgs, format: DocumentFormat) throws -> DocumentTextReadArguments {
        try DocumentTextReadArguments.decodeValidated(args, format: format)
    }

    static func touchedPaths(_ args: ToolArgs, format: DocumentFormat) -> [String] {
        (try? value(args, format: format)).map { [$0.path] } ?? []
    }

    static func permissionIntent(
        _ args: ToolArgs,
        format: DocumentFormat,
        toolName: String,
        sideEffect: SideEffect
    ) -> PermissionIntent {
        guard let value = try? value(args, format: format) else {
            return PermissionIntent.derived(
                toolName: toolName,
                sideEffect: sideEffect,
                touchedPaths: touchedPaths(args, format: format),
                risksNetwork: false)
        }
        return DocumentToolSupport.processReadIntent(
            action: "document.read.\(format.rawValue)",
            paths: [value.path],
            operation: "read_bounded_markdown",
            format: format,
            replayPolicy: .safeToReplay)
    }

    static func execute(
        _ args: ToolArgs,
        format: DocumentFormat,
        operation: String,
        context: ToolContext
    ) async throws -> ToolObservation {
        let value = try value(args, format: format)
        let snapshot = try DocumentInputFile.freeze(
            path: value.path,
            expectedFormat: format,
            workspace: context.workspaceRoot)
        let envelope = try await DocumentPythonBackend.run(
            operation: "read",
            payload: .object([
                "format": .string(format.rawValue),
                "input_path": .string(snapshot.url.path),
                "maximum_characters": .number(Double(value.maxCharacters ?? 200_000)),
                "maximum_file_bytes": .number(Double(snapshot.identity.byteCount)),
            ]),
            readableWorkspacePaths: [value.path],
            in: context)
        try DocumentInputFile.verifyUnchanged(snapshot)
        return try DocumentToolSupport.observation(
            operation: operation,
            format: format,
            result: envelope.result,
            engineVersions: envelope.engineVersions,
            warnings: envelope.warnings,
            truncated: {
                guard case .object(let result)? = envelope.result,
                      case .bool(let truncated)? = result["truncated"] else { return false }
                return truncated
            }())
    }
}

public struct ReadDOCXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_docx",
        description: "Read one DOCX workspace file as bounded Markdown with the fixed local Docling DOCX converter. The format and backend are fixed; no fallback, edit, rendering, or OCR is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .docx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .docx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .docx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .docx, operation: Self.descriptor.name, context: context) }
}

public struct ReadPPTXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_pptx",
        description: "Read one PPTX workspace file as bounded Markdown with the fixed local Docling PPTX converter. The format and backend are fixed; no fallback, edit, rendering, or OCR is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .pptx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .pptx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .pptx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .pptx, operation: Self.descriptor.name, context: context) }
}

public struct ReadXLSXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_xlsx",
        description: "Read one XLSX workspace file as bounded Markdown with the fixed local Docling XLSX converter. The format and backend are fixed; no fallback, edit, recalculation, or formula execution is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .xlsx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .xlsx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .xlsx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .xlsx, operation: Self.descriptor.name, context: context) }
}

public struct ReadHTMLTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_html",
        description: "Read one local HTML workspace file as bounded Markdown with the fixed local Docling HTML converter. The format and backend are fixed; no fallback, script execution, network access, or rendering is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .html) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .html) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .html, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .html, operation: Self.descriptor.name, context: context) }
}

public struct ReadEPUBTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_epub",
        description: "Read one EPUB workspace file as bounded Markdown with the fixed local Docling EPUB converter. The format and backend are fixed; no fallback, edit, rendering, or network access is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .epub) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .epub) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .epub, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .epub, operation: Self.descriptor.name, context: context) }
}

// MARK: - document_ocr

public struct DocumentOCRTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.ocr"
    public static let descriptor = ToolDescriptor(
        name: "document_ocr",
        description: "Run explicit offline OCR on selected pages of a workspace PDF with fixed Docling models and fixed Tesseract settings. It returns bounded text and boxes; it never creates or edits a PDF and never chooses an OCR engine automatically.",
        sideEffect: .exec,
        parameters: DocumentOCRArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try DocumentOCRArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? DocumentOCRArguments.decodeValidated(args)).map { [$0.inputPath] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        DocumentToolSupport.processReadIntent(
            action: "document.ocr",
            paths: touchedPaths(args),
            operation: "ocr_selected_pdf_pages",
            format: .pdf)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try DocumentOCRArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: .pdf,
            expectedSHA256: value.expectedSourceSHA256,
            maximumBytes: 100 * 1_024 * 1_024,
            workspace: context.workspaceRoot)
        let pageCount: Int
        do {
            pageCount = try PDFNativeDocumentService.readNativeText(
                from: snapshot.url,
                pages: nil,
                maximumCharacters: 1).pageCount
        } catch {
            throw DocumentToolError(.validationFailed, "PDF could not be inspected before OCR")
        }
        let pages = try DocumentPageSelection.expand(
            value.pages,
            pageCount: pageCount,
            maximumCount: 50)
        let payload = try DocumentPythonBackend.fixedOCRPayload(
            inputPath: snapshot.url.path,
            pages: pages,
            languages: value.languages,
            psm: value.pageSegmentationMode,
            maximumCharacters: value.maxCharacters ?? 200_000,
            maximumFileBytes: 100 * 1_024 * 1_024)
        let envelope = try await DocumentPythonBackend.run(
            operation: "ocr",
            payload: payload,
            readableWorkspacePaths: [value.inputPath],
            in: context)
        try DocumentInputFile.verifyUnchanged(snapshot)
        return try DocumentToolSupport.observation(
            operation: "document_ocr",
            format: .pdf,
            result: envelope.result,
            engineVersions: envelope.engineVersions,
            warnings: envelope.warnings,
            truncated: {
                guard case .object(let result)? = envelope.result,
                      case .bool(let truncated)? = result["truncated"] else { return false }
                return truncated
            }())
    }
}

// MARK: - document_render

public struct DocumentRenderTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.render"
    public static let descriptor = ToolDescriptor(
        name: "document_render",
        description: "Render selected document pages to a workspace directory containing deterministic PNG files and manifest.json. PDF pages are drawn directly with PDFKit; DOCX, PPTX, XLSX, and HTML use one fixed temporary-PDF route. The complete directory is committed atomically.",
        sideEffect: .exec,
        parameters: DocumentRenderArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try DocumentRenderArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? DocumentRenderArguments.decodeValidated(args) else { return [] }
        return [value.inputPath] + (value.localAssetPaths ?? []) + [value.outputDirectory]
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? DocumentRenderArguments.decodeValidated(args) else {
            return PermissionIntent.derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        return DocumentToolSupport.writeIntent(
            action: "document.render",
            readPaths: [value.inputPath] + (value.localAssetPaths ?? []),
            writePath: value.outputDirectory,
            operation: "render_page_png_bundle",
            format: value.inputFormat)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try DocumentRenderArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: value.inputFormat,
            expectedSHA256: value.expectedSourceSHA256,
            workspace: context.workspaceRoot)
        let frozenAssets = try DocumentToolSupport.freezeAuxiliaryInputs(
            value.localAssetPaths ?? [],
            workspace: context.workspaceRoot)
        let pages = try DocumentPageSelection.parse(value.pages, maximumCount: 200)
        let request = DocumentStagedDirectoryRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputDirectory,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            maximumFiles: 201,
            maximumBytes: UInt64(value.resolvedMaximumOutputBytes),
            readOnlyInputSnapshots: frozenAssets.snapshots)
        let accumulator = DocumentExecutionAccumulator()
        let receipt = try await DocumentStagedOutput.writeDirectory(
            request,
            workspace: context.workspaceRoot,
            produce: { stage in
                if value.inputFormat == .pdf {
                    _ = try PDFNativeDocumentService.renderPages(
                        from: snapshot.url,
                        into: stage,
                        pages: pages,
                        box: value.resolvedPageBox == .media ? .mediaBox : .cropBox,
                        dpi: Double(value.resolvedDPI),
                        background: value.resolvedBackground == .white ? .white : .transparent,
                        includeAnnotations: value.resolvedAnnotations == .show,
                        maximumPagePixels: value.resolvedMaximumPagePixels,
                        maximumTotalPixels: value.resolvedMaximumTotalPixels,
                        maximumOutputBytes: value.resolvedMaximumOutputBytes)
                    return
                }

                let rendered = stage.appendingPathComponent(".rendered", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: rendered,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                // Keep backend payloads directly under the transaction root.
                // The process boundary accepts only a same-parent
                // `.intatis-document-stage-*` directory as its internal
                // writable lease; a nested ad-hoc work directory would fail
                // closed before the fixed backend could start.
                let temporaryPDF = stage.appendingPathComponent("preview.pdf")
                let rendererVersions = try await DocumentToolSupport.renderablePDF(
                    format: value.inputFormat,
                    input: snapshot.url,
                    reviewedInputPath: value.inputPath,
                    reviewedOutputPath: value.outputDirectory,
                    allowedHTMLAssets: frozenAssets.urlsByReviewedPath,
                    stagedPDF: temporaryPDF,
                    context: context)
                let validatorVersions = try await DocumentToolSupport.validateGeneratedPDF(
                    temporaryPDF,
                    reviewedOutputPath: value.outputDirectory,
                    context: context)
                await accumulator.record(versions: rendererVersions)
                await accumulator.record(versions: validatorVersions)
                _ = try PDFNativeDocumentService.renderPages(
                    from: temporaryPDF,
                    into: rendered,
                    pages: pages,
                    box: value.resolvedPageBox == .media ? .mediaBox : .cropBox,
                    dpi: Double(value.resolvedDPI),
                    background: value.resolvedBackground == .white ? .white : .transparent,
                    includeAnnotations: value.resolvedAnnotations == .show,
                    maximumPagePixels: value.resolvedMaximumPagePixels,
                    maximumTotalPixels: value.resolvedMaximumTotalPixels,
                    maximumOutputBytes: value.resolvedMaximumOutputBytes)
                try DocumentToolSupport.moveRenderedBundle(from: rendered, to: stage)
                try FileManager.default.removeItem(at: rendered)
                try FileManager.default.removeItem(at: temporaryPDF)
                for backendDirectoryName in [
                    "libreoffice-output",
                    "libreoffice-profile",
                ] {
                    let backendDirectory = stage.appendingPathComponent(
                        backendDirectoryName,
                        isDirectory: true)
                    if FileManager.default.fileExists(atPath: backendDirectory.path) {
                        try FileManager.default.removeItem(at: backendDirectory)
                    }
                }
            },
            validate: { directory in
                try DocumentToolSupport.validateRenderBundle(directory)
            })
        let execution = await accumulator.snapshot()
        var versions = execution.versions
        versions["page_renderer"] = "PDFKit-system"
        return try DocumentToolSupport.observation(
            operation: "document_render",
            format: value.inputFormat,
            engineVersions: versions,
            receipt: receipt,
            changedFiles: [value.outputDirectory])
    }
}

// MARK: - document_export_pdf

public struct DocumentExportPDFTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.export.pdf"
    public static let descriptor = ToolDescriptor(
        name: "document_export_pdf",
        description: "Export one DOCX, PPTX, XLSX, or local self-contained HTML workspace document to a new PDF through its single fixed renderer, then require pdfcpu strict validation and a PDFKit render smoke test before atomic commit. PDF input is rejected; EPUB remains gated.",
        sideEffect: .exec,
        parameters: DocumentExportPDFArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try DocumentExportPDFArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? DocumentExportPDFArguments.decodeValidated(args) else { return [] }
        return [value.inputPath] + (value.localAssetPaths ?? []) + [value.outputPath]
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? DocumentExportPDFArguments.decodeValidated(args) else {
            return PermissionIntent.derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        return DocumentToolSupport.writeIntent(
            action: "document.export.pdf",
            readPaths: [value.inputPath] + (value.localAssetPaths ?? []),
            writePath: value.outputPath,
            operation: "export_new_pdf",
            format: value.inputFormat)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try DocumentExportPDFArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: value.inputFormat,
            expectedSHA256: value.expectedSourceSHA256,
            workspace: context.workspaceRoot)
        let frozenAssets = try DocumentToolSupport.freezeAuxiliaryInputs(
            value.localAssetPaths ?? [],
            workspace: context.workspaceRoot)
        let request = DocumentStagedFileRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputPath,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            fileExtension: "pdf",
            maximumBytes: 1_024 * 1_024 * 1_024,
            readOnlyInputSnapshots: frozenAssets.snapshots)
        let accumulator = DocumentExecutionAccumulator()
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedPDF in
                let rendererVersions = try await DocumentToolSupport.renderablePDF(
                    format: value.inputFormat,
                    input: snapshot.url,
                    reviewedInputPath: value.inputPath,
                    reviewedOutputPath: value.outputPath,
                    allowedHTMLAssets: frozenAssets.urlsByReviewedPath,
                    stagedPDF: stagedPDF,
                    context: context)
                let validatorVersions = try await DocumentToolSupport.validateGeneratedPDF(
                    stagedPDF,
                    reviewedOutputPath: value.outputPath,
                    context: context)
                await accumulator.record(versions: rendererVersions)
                await accumulator.record(versions: validatorVersions)
            },
            validate: { pdf in
                try DocumentToolSupport.validatePDFFile(pdf)
            })
        let execution = await accumulator.snapshot()
        return try DocumentToolSupport.observation(
            operation: "document_export_pdf",
            format: value.inputFormat,
            engineVersions: execution.versions,
            receipt: receipt,
            changedFiles: [value.outputPath])
    }
}

// MARK: - document_write

public struct DocumentWriteTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.write"
    public static let descriptor = ToolDescriptor(
        name: "document_write",
        description: "Create or edit DOCX, PPTX, XLSX, HTML, or EPUB using only the declared fixed high-level operation subset. Each output is staged, reopened, visually validated where applicable, and atomically committed. PDF mutation is unsupported.",
        sideEffect: .exec,
        parameters: DocumentWriteArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try DocumentWriteArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? DocumentWriteArguments.decodeValidated(args) else { return [] }
        return DocumentToolSupport.writeOperationPaths(value)
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? DocumentWriteArguments.decodeValidated(args) else {
            return PermissionIntent.derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        let readPaths = (value.inputPath.map { [$0] } ?? [])
            + (value.localAssetPaths ?? [])
            + value.operations.flatMap { operation in
                ["path", "source_path"].compactMap { key -> String? in
                    guard case .string(let path)? = operation.parameters[key] else { return nil }
                    return path
                }
            }
        return DocumentToolSupport.writeIntent(
            action: "document.write",
            readPaths: readPaths,
            writePath: value.outputPath,
            operation: value.mode.rawValue,
            format: value.format)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try DocumentWriteArguments.decodeValidated(args)
        let inputSnapshot = try value.inputPath.map {
            try DocumentInputFile.freeze(
                path: $0,
                expectedFormat: value.format,
                expectedSHA256: value.expectedSourceSHA256,
                workspace: context.workspaceRoot)
        }
        let assetPaths = (value.localAssetPaths ?? []) + value.operations.flatMap { operation in
            ["path", "source_path"].compactMap { key -> String? in
                guard case .string(let path)? = operation.parameters[key] else { return nil }
                return path
            }
        }
        let frozenAssets = try DocumentToolSupport.freezeAuxiliaryInputs(
            Array(Set(assetPaths)).sorted(),
            workspace: context.workspaceRoot)
        let operations = DocumentToolSupport.resolvedWriteOperations(
            value.operations,
            assets: frozenAssets.urlsByReviewedPath)
        let request = DocumentStagedFileRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputPath,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            fileExtension: URL(fileURLWithPath: value.outputPath).pathExtension,
            maximumBytes: 1_024 * 1_024 * 1_024,
            readOnlyInputSnapshots: frozenAssets.snapshots)
        let accumulator = DocumentExecutionAccumulator()
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedOutput in
                let stageRoot = stagedOutput.deletingLastPathComponent()
                var payload: [String: JSONValue] = [
                    "format": .string(value.format.rawValue),
                    "mode": .string(value.mode.rawValue),
                    "output_path": .string(stagedOutput.path),
                    "operations": operations,
                    "allowed_asset_paths": .array(
                        frozenAssets.urlsByReviewedPath.values.map { .string($0.path) }.sorted(by: { left, right in
                            guard case .string(let lhs) = left,
                                  case .string(let rhs) = right else { return false }
                            return lhs < rhs
                        })),
                ]
                if let input = inputSnapshot?.url { payload["input_path"] = .string(input.path) }

                if value.format == .epub {
                    let envelope = try await RBookDocumentBackend.run(
                        operation: "write",
                        payload: .object(payload),
                        reviewedInputPaths: (value.inputPath.map { [$0] } ?? [])
                            + frozenAssets.urlsByReviewedPath.keys.sorted(),
                        reviewedOutputPaths: [value.outputPath],
                        internalStageRoot: stageRoot.path,
                        in: context)
                    await accumulator.record(
                        versions: envelope.engineVersions,
                        warnings: envelope.warnings,
                        result: envelope.result)
                    let validation = try await EPUBCheckValidationBackend.validate(
                        stagedEPUB: stagedOutput,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                    await accumulator.record(versions: validation)
                    return
                }

                if value.format == .xlsx {
                    let intermediate = stageRoot.appendingPathComponent("openpyxl-intermediate.xlsx")
                    payload["output_path"] = .string(intermediate.path)
                    let envelope = try await DocumentPythonBackend.run(
                        operation: "write",
                        payload: .object(payload),
                        readableWorkspacePaths: (value.inputPath.map { [$0] } ?? [])
                            + frozenAssets.urlsByReviewedPath.keys.sorted(),
                        writableWorkspacePaths: [value.outputPath],
                        internalWritableWorkspacePaths: [stageRoot.path],
                        in: context)
                    await accumulator.record(
                        versions: envelope.engineVersions,
                        warnings: envelope.warnings,
                        result: envelope.result)
                    let preview = stageRoot.appendingPathComponent("preview.pdf")
                    let calc = try await LibreOfficeDocumentBackend.recalculateAndSaveXLSX(
                        editedInput: intermediate,
                        stagedXLSX: stagedOutput,
                        previewPDF: preview,
                        reviewedInputPath: value.inputPath ?? value.outputPath,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                    await accumulator.record(versions: calc)
                    let verification = try await DocumentToolSupport.verifyWrittenNativeDocument(
                        stagedOutput,
                        format: .xlsx,
                        resolvedOperations: operations,
                        expectedOperationCount: value.operations.count,
                        assets: frozenAssets.urlsByReviewedPath,
                        reviewedOutputPath: value.outputPath,
                        stageRoot: stageRoot,
                        context: context)
                    await accumulator.record(
                        versions: verification.engineVersions,
                        warnings: verification.warnings)
                    let pdfVersions = try await DocumentToolSupport.validateGeneratedPDF(
                        preview,
                        reviewedOutputPath: value.outputPath,
                        context: context)
                    await accumulator.record(versions: pdfVersions)
                    return
                }

                let envelope = try await DocumentPythonBackend.run(
                    operation: "write",
                    payload: .object(payload),
                    readableWorkspacePaths: (value.inputPath.map { [$0] } ?? [])
                        + frozenAssets.urlsByReviewedPath.keys.sorted(),
                    writableWorkspacePaths: [value.outputPath],
                    internalWritableWorkspacePaths: [stageRoot.path],
                    in: context)
                await accumulator.record(
                    versions: envelope.engineVersions,
                    warnings: envelope.warnings,
                    result: envelope.result)
                let verification = try await DocumentToolSupport.verifyWrittenNativeDocument(
                    stagedOutput,
                    format: value.format,
                    resolvedOperations: operations,
                    expectedOperationCount: value.operations.count,
                    assets: frozenAssets.urlsByReviewedPath,
                    reviewedOutputPath: value.outputPath,
                    stageRoot: stageRoot,
                    context: context)
                await accumulator.record(
                    versions: verification.engineVersions,
                    warnings: verification.warnings)

                let preview = stageRoot.appendingPathComponent("preview.pdf")
                let previewVersions: [String: String]
                if value.format == .html {
                    previewVersions = try await DocumentToolSupport.prepareAndRenderHTML(
                        input: stagedOutput,
                        reviewedInputPaths: frozenAssets.urlsByReviewedPath.keys.sorted(),
                        reviewedOutputPath: value.outputPath,
                        allowedHTMLAssets: frozenAssets.urlsByReviewedPath,
                        stagedPDF: preview,
                        context: context)
                } else {
                    previewVersions = try await LibreOfficeDocumentBackend.exportPDF(
                        actualInput: stagedOutput,
                        reviewedInputPath: value.inputPath ?? value.outputPath,
                        stagedPDF: preview,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                }
                await accumulator.record(versions: previewVersions)
                let pdfVersions = try await DocumentToolSupport.validateGeneratedPDF(
                    preview,
                    reviewedOutputPath: value.outputPath,
                    context: context)
                await accumulator.record(versions: pdfVersions)
            },
            validate: { output in
                let values = try output.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) > 0 else {
                    throw DocumentToolError(.validationFailed, "document writer produced no safe output")
                }
            })
        let execution = await accumulator.snapshot()
        return try DocumentToolSupport.observation(
            operation: "document_write",
            format: value.format,
            result: execution.result,
            engineVersions: execution.versions,
            warnings: execution.warnings,
            receipt: receipt,
            changedFiles: [value.outputPath])
    }
}
