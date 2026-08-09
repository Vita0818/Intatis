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
        format: DocumentFormat
    ) -> PermissionIntent {
        PermissionIntent(
            action: action,
            resources: paths.map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
            },
            metadata: [
                "operation": .string(operation),
                "format": .string(format.rawValue),
            ],
            dataEffects: [.read, .execute],
            risks: [.processExecution],
            replayPolicy: .requiresManualReconciliation)
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
            replayPolicy: .requiresManualReconciliation)
    }

    static func resolvedAuxiliaryPaths(
        _ paths: [String],
        workspace: URL
    ) throws -> [String: URL] {
        var result: [String: URL] = [:]
        for path in paths {
            let url = try PathConfinement.resolve(path, within: workspace)
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 512 * 1_024 * 1_024 else {
                throw DocumentToolError(
                    .validationFailed,
                    "a document asset is missing, unsafe, or too large")
            }
            result[path] = url
        }
        return result
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
            let payload: JSONValue = .object([
                "format": .string("html"),
                "input_path": .string(input.path),
                "require_self_contained": .bool(true),
                "allowed_asset_paths": .array(
                    allowedHTMLAssets.values.map { .string($0.path) }.sorted(by: jsonStringLess)),
            ])
            _ = try await DocumentPythonBackend.run(
                operation: "validate",
                payload: payload,
                readableWorkspacePaths: [reviewedInputPath] + allowedHTMLAssets.keys.sorted(),
                in: context)
            return try await HTMLDocumentPDFRenderer.render(
                input: input,
                workspaceRoot: context.workspaceRoot,
                stagedPDF: stagedPDF)
        case .epub:
            throw DocumentToolError(
                .unsupportedFeature,
                "EPUB full-spine PDF export has not passed its required corpus gate")
        case .pdf:
            throw DocumentToolError(.unsupportedOperation, "PDF input is not an export route")
        }
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
        for operation in value.operations {
            for key in ["path", "source_path"] {
                if case .string(let path)? = operation.parameters[key] {
                    paths.append(path)
                }
            }
        }
        paths.append(value.outputPath)
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
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

    private static func jsonStringLess(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        guard case .string(let left) = lhs, case .string(let right) = rhs else { return false }
        return left < right
    }
}

// MARK: - document_read

public struct DocumentReadTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "document_read",
        description: "Read the declared native structure of a DOCX, PPTX, XLSX, HTML, or EPUB workspace file using its single fixed local parser. PDF is intentionally handled by read_pdf or document_ocr. No fallback backend is attempted.",
        sideEffect: .exec,
        parameters: DocumentReadArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try DocumentReadArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? DocumentReadArguments.decodeValidated(args)).map { [$0.inputPath] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? DocumentReadArguments.decodeValidated(args) else {
            return PermissionIntent.derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        return DocumentToolSupport.processReadIntent(
            action: "document.read",
            paths: [value.inputPath],
            operation: "read_native_structure",
            format: value.format)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try DocumentReadArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: value.format,
            workspace: context.workspaceRoot)
        let maximumCharacters = value.maxCharacters ?? 200_000
        let envelope: DocumentBackendEnvelope
        if value.format == .epub {
            var payload: [String: JSONValue] = [
                "input_path": .string(snapshot.url.path),
                "maximum_characters": .number(Double(maximumCharacters)),
            ]
            if let start = value.options?.spineStart {
                payload["spine_start"] = .number(Double(start))
            }
            if let count = value.options?.spineCount {
                payload["spine_count"] = .number(Double(count))
            }
            payload["include_metadata"] = .bool(value.options?.includeMetadata ?? true)
            envelope = try await RBookDocumentBackend.run(
                operation: "read",
                payload: .object(payload),
                reviewedInputPaths: [value.inputPath],
                in: context)
        } else {
            var payload: [String: JSONValue] = [
                "format": .string(value.format.rawValue),
                "input_path": .string(snapshot.url.path),
                "maximum_characters": .number(Double(maximumCharacters)),
                "maximum_items": .number(20_000),
            ]
            switch value.format {
            case .docx:
                payload["include_headers"] = .bool(value.options?.includeHeaders ?? true)
                payload["include_footers"] = .bool(value.options?.includeFooters ?? true)
                payload["include_tables"] = .bool(value.options?.includeTables ?? true)
            case .pptx:
                if let pages = try DocumentPageSelection.parse(
                    value.options?.slides,
                    maximumCount: 10_000) {
                    payload["slides"] = .array(pages.map { .number(Double($0)) })
                }
            case .xlsx:
                if let sheet = value.options?.sheet { payload["sheet"] = .string(sheet) }
                if let range = value.options?.cellRange { payload["range"] = .string(range) }
                payload["data_only"] = .bool(!(value.options?.includeFormulas ?? true))
                payload["maximum_cells"] = .number(Double(value.options?.maximumCells ?? 10_000))
            case .html:
                if let xpath = value.options?.xpath { payload["xpath"] = .string(xpath) }
            case .epub, .pdf:
                break
            }
            envelope = try await DocumentPythonBackend.run(
                operation: "read",
                payload: .object(payload),
                readableWorkspacePaths: [value.inputPath],
                in: context)
            if value.format == .html,
               let expected = value.options?.expectedMatchCount,
               case .object(let result)? = envelope.result,
               case .array(let items)? = result["items"],
               items.count != expected {
                throw DocumentToolError(
                    .validationFailed,
                    "HTML XPath result count changed from the exact requested count")
            }
        }
        try DocumentInputFile.verifyUnchanged(snapshot)
        return try DocumentToolSupport.observation(
            operation: "document_read",
            format: value.format,
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
        let assets = try DocumentToolSupport.resolvedAuxiliaryPaths(
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
            maximumBytes: UInt64(value.resolvedMaximumOutputBytes))
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

                let work = stage.appendingPathComponent(".work", isDirectory: true)
                let rendered = stage.appendingPathComponent(".rendered", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: work,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                try FileManager.default.createDirectory(
                    at: rendered,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                let temporaryPDF = work.appendingPathComponent("preview.pdf")
                _ = try await DocumentToolSupport.renderablePDF(
                    format: value.inputFormat,
                    input: snapshot.url,
                    reviewedInputPath: value.inputPath,
                    reviewedOutputPath: value.outputDirectory,
                    allowedHTMLAssets: assets,
                    stagedPDF: temporaryPDF,
                    context: context)
                _ = try await DocumentToolSupport.validateGeneratedPDF(
                    temporaryPDF,
                    reviewedOutputPath: value.outputDirectory,
                    context: context)
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
                try FileManager.default.removeItem(at: work)
            },
            validate: DocumentToolSupport.validateRenderBundle)
        return try DocumentToolSupport.observation(
            operation: "document_render",
            format: value.inputFormat,
            engineVersions: ["page_renderer": "PDFKit-system"],
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
        let assets = try DocumentToolSupport.resolvedAuxiliaryPaths(
            value.localAssetPaths ?? [],
            workspace: context.workspaceRoot)
        let request = DocumentStagedFileRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputPath,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            fileExtension: "pdf",
            maximumBytes: 1_024 * 1_024 * 1_024)
        var versions: [String: String] = [:]
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedPDF in
                let rendererVersions = try await DocumentToolSupport.renderablePDF(
                    format: value.inputFormat,
                    input: snapshot.url,
                    reviewedInputPath: value.inputPath,
                    reviewedOutputPath: value.outputPath,
                    allowedHTMLAssets: assets,
                    stagedPDF: stagedPDF,
                    context: context)
                let validatorVersions = try await DocumentToolSupport.validateGeneratedPDF(
                    stagedPDF,
                    reviewedOutputPath: value.outputPath,
                    context: context)
                versions.merge(rendererVersions) { _, new in new }
                versions.merge(validatorVersions) { _, new in new }
            },
            validate: DocumentToolSupport.validatePDFFile)
        return try DocumentToolSupport.observation(
            operation: "document_export_pdf",
            format: value.inputFormat,
            engineVersions: versions,
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
        let assetPaths = value.operations.flatMap { operation in
            ["path", "source_path"].compactMap { key -> String? in
                guard case .string(let path)? = operation.parameters[key] else { return nil }
                return path
            }
        }
        let assets = try DocumentToolSupport.resolvedAuxiliaryPaths(
            Array(Set(assetPaths)).sorted(),
            workspace: context.workspaceRoot)
        let operations = DocumentToolSupport.resolvedWriteOperations(
            value.operations,
            assets: assets)
        let request = DocumentStagedFileRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputPath,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            fileExtension: URL(fileURLWithPath: value.outputPath).pathExtension,
            maximumBytes: 1_024 * 1_024 * 1_024)
        var versions: [String: String] = [:]
        var warnings: [String] = []
        var writeResult: JSONValue?
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
                        assets.values.map { .string($0.path) }.sorted(by: { left, right in
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
                        reviewedInputPaths: (value.inputPath.map { [$0] } ?? []) + assets.keys.sorted(),
                        reviewedOutputPaths: [value.outputPath],
                        internalStageRoot: stageRoot.path,
                        in: context)
                    writeResult = envelope.result
                    versions.merge(envelope.engineVersions) { _, new in new }
                    warnings.append(contentsOf: envelope.warnings)
                    let validation = try await EPUBCheckValidationBackend.validate(
                        stagedEPUB: stagedOutput,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                    versions.merge(validation) { _, new in new }
                    return
                }

                if value.format == .xlsx {
                    let intermediate = stageRoot.appendingPathComponent("openpyxl-intermediate.xlsx")
                    payload["output_path"] = .string(intermediate.path)
                    let envelope = try await DocumentPythonBackend.run(
                        operation: "write",
                        payload: .object(payload),
                        readableWorkspacePaths: (value.inputPath.map { [$0] } ?? []) + assets.keys.sorted(),
                        writableWorkspacePaths: [value.outputPath],
                        internalWritableWorkspacePaths: [stageRoot.path],
                        in: context)
                    writeResult = envelope.result
                    versions.merge(envelope.engineVersions) { _, new in new }
                    warnings.append(contentsOf: envelope.warnings)
                    let preview = stageRoot.appendingPathComponent("preview.pdf")
                    let calc = try await LibreOfficeDocumentBackend.recalculateAndSaveXLSX(
                        editedInput: intermediate,
                        stagedXLSX: stagedOutput,
                        previewPDF: preview,
                        reviewedInputPath: value.inputPath ?? value.outputPath,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                    versions.merge(calc) { _, new in new }
                    let validation = try await DocumentPythonBackend.run(
                        operation: "validate",
                        payload: .object([
                            "format": .string("xlsx"),
                            "input_path": .string(stagedOutput.path),
                        ]),
                        readableWorkspacePaths: [],
                        writableWorkspacePaths: [value.outputPath],
                        internalWritableWorkspacePaths: [stageRoot.path],
                        in: context)
                    versions.merge(validation.engineVersions) { _, new in new }
                    let pdfVersions = try await DocumentToolSupport.validateGeneratedPDF(
                        preview,
                        reviewedOutputPath: value.outputPath,
                        context: context)
                    versions.merge(pdfVersions) { _, new in new }
                    return
                }

                let envelope = try await DocumentPythonBackend.run(
                    operation: "write",
                    payload: .object(payload),
                    readableWorkspacePaths: (value.inputPath.map { [$0] } ?? []) + assets.keys.sorted(),
                    writableWorkspacePaths: [value.outputPath],
                    internalWritableWorkspacePaths: [stageRoot.path],
                    in: context)
                writeResult = envelope.result
                versions.merge(envelope.engineVersions) { _, new in new }
                warnings.append(contentsOf: envelope.warnings)
                let validation = try await DocumentPythonBackend.run(
                    operation: "validate",
                    payload: .object([
                        "format": .string(value.format.rawValue),
                        "input_path": .string(stagedOutput.path),
                        "require_self_contained": .bool(value.format == .html),
                        "allowed_asset_paths": .array([]),
                    ]),
                    readableWorkspacePaths: [],
                    writableWorkspacePaths: [value.outputPath],
                    internalWritableWorkspacePaths: [stageRoot.path],
                    in: context)
                versions.merge(validation.engineVersions) { _, new in new }

                let preview = stageRoot.appendingPathComponent("preview.pdf")
                let previewVersions: [String: String]
                if value.format == .html {
                    previewVersions = try await HTMLDocumentPDFRenderer.render(
                        input: stagedOutput,
                        workspaceRoot: context.workspaceRoot,
                        stagedPDF: preview)
                } else {
                    previewVersions = try await LibreOfficeDocumentBackend.exportPDF(
                        actualInput: stagedOutput,
                        reviewedInputPath: value.inputPath ?? value.outputPath,
                        stagedPDF: preview,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                }
                versions.merge(previewVersions) { _, new in new }
                let pdfVersions = try await DocumentToolSupport.validateGeneratedPDF(
                    preview,
                    reviewedOutputPath: value.outputPath,
                    context: context)
                versions.merge(pdfVersions) { _, new in new }
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
        return try DocumentToolSupport.observation(
            operation: "document_write",
            format: value.format,
            result: writeResult,
            engineVersions: versions,
            warnings: warnings,
            receipt: receipt,
            changedFiles: [value.outputPath])
    }
}
