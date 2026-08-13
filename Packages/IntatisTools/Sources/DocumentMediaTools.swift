import Foundation
import IntatisCore
import IntatisProtocol

// MARK: - Shared helpers

private func shellQuote(_ text: String) -> String {
    "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func outputText(stdout: String, stderr: String, exitCode: Int, limit: Int = 20_000) -> String {
    var text = stdout
    if !stderr.isEmpty {
        text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + stderr
    }
    text += "\n[exit \(exitCode)]"
    if text.count > limit {
        return String(text.prefix(limit)) + "\n[truncated]"
    }
    return text
}

private func ensureParentDirectory(for url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
}

// MARK: - read_pdf

public struct ReadPDFTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_pdf",
        description: "Read only the text already embedded in selected pages of a workspace PDF. This never edits the PDF and never performs OCR. An image-only PDF returns the typed ocr_required error so document_ocr can be requested explicitly.",
        sideEffect: .readOnly,
        parameters: ReadPDFArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try ReadPDFArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? ReadPDFArguments.decodeValidated(args)).map { [$0.path] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "document.read",
            resources: touchedPaths(args).map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
            },
            metadata: ["operation": .string("read_native_pdf_text")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try ReadPDFArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.path,
            expectedFormat: .pdf,
            workspace: context.workspaceRoot)
        let pages = try DocumentPageSelection.parse(value.pages, maximumCount: 10_000)
        let result: PDFNativeTextReadResult
        do {
            result = try PDFNativeDocumentService.readNativeText(
                from: snapshot.url,
                pages: pages,
                maximumCharacters: value.maxCharacters ?? 200_000)
        } catch let error as PDFNativeDocumentServiceError {
            switch error {
            case .unavailable:
                throw DocumentToolError(.backendMissing, "PDFKit native reading is unavailable")
            case .inputChangedWhileReading:
                throw DocumentToolError(.outputConflict, "PDF changed while it was being read")
            case .lockedPDF:
                throw DocumentToolError(.unsupportedFeature, "password-protected PDF input is unsupported")
            default:
                throw DocumentToolError(.validationFailed, "PDF input or page selection is invalid")
            }
        }
        try DocumentInputFile.verifyUnchanged(snapshot)
        guard !result.requiresOCR else {
            throw DocumentToolError(
                .ocrRequired,
                "the selected PDF pages have no extractable native text; request document_ocr explicitly")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentToolError(.backendFailed, "PDF result could not be encoded")
        }
        return ToolObservation(text: text, truncated: result.truncated)
    }
}

// MARK: - compile_latex

public struct CompileLaTeXTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "compile_latex",
        description: "Compile a LaTeX .tex file in the workspace to PDF using installed Tectonic, latexmk, xelatex, or pdflatex.",
        sideEffect: .exec,
        parameters: Schema.object([
            "inputPath": Schema.nonEmptyString,
            "outputDir": Schema.nonEmptyString,
            "engine": Schema.nonEmptyString,
        ], required: ["inputPath"])
    )

    struct Args: Decodable {
        let inputPath: String
        let outputDir: String?
        let engine: String?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let a = try? args.decode(Args.self) else { return [] }
        return [a.inputPath, a.outputDir].compactMap { $0 }
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let inputURL = try PathConfinement.resolve(a.inputPath, within: context.workspaceRoot)
        guard inputURL.pathExtension.lowercased() == "tex" else {
            throw IntatisError.decoding("compile_latex inputPath must point to a .tex file")
        }
        let outputDir = a.outputDir?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? PathConfinement.relativePath(of: inputURL.deletingLastPathComponent(), root: context.workspaceRoot)
        let outputDirURL = try PathConfinement.resolve(outputDir, within: context.workspaceRoot)
        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)

        let engine = (a.engine ?? "auto").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let outputPDF = outputDirURL.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + ".pdf")
        let command = """
        set -e
        # Keep TeX's own path policy restrictive in addition to the OS-level
        # workspace sandbox, and never permit shell escape from document input.
        export openin_any=p
        export openout_any=p
        INPUT=\(shellQuote(inputURL.path))
        OUTDIR=\(shellQuote(outputDirURL.path))
        ENGINE=\(shellQuote(engine))
        run_auto() {
          if command -v tectonic >/dev/null 2>&1; then
            tectonic --untrusted --keep-logs --keep-intermediates --outdir "$OUTDIR" "$INPUT"
          elif command -v latexmk >/dev/null 2>&1; then
            latexmk -norc -pdf -interaction=nonstopmode -halt-on-error \
              -pdflatex="pdflatex -no-shell-escape %O %S" -outdir="$OUTDIR" "$INPUT"
          elif command -v xelatex >/dev/null 2>&1; then
            xelatex -no-shell-escape -interaction=nonstopmode -halt-on-error -output-directory="$OUTDIR" "$INPUT"
          elif command -v pdflatex >/dev/null 2>&1; then
            pdflatex -no-shell-escape -interaction=nonstopmode -halt-on-error -output-directory="$OUTDIR" "$INPUT"
          else
            echo "No LaTeX engine found. Install tectonic, TeX Live latexmk, xelatex, or pdflatex." >&2
            exit 127
          fi
        }
        case "$ENGINE" in
          auto) run_auto ;;
          tectonic)
            command -v tectonic >/dev/null 2>&1 || { echo "tectonic is not installed" >&2; exit 127; }
            tectonic --untrusted --keep-logs --keep-intermediates --outdir "$OUTDIR" "$INPUT"
            ;;
          latexmk)
            command -v latexmk >/dev/null 2>&1 || { echo "latexmk is not installed" >&2; exit 127; }
            latexmk -norc -pdf -interaction=nonstopmode -halt-on-error \
              -pdflatex="pdflatex -no-shell-escape %O %S" -outdir="$OUTDIR" "$INPUT"
            ;;
          xelatex|pdflatex)
            command -v "$ENGINE" >/dev/null 2>&1 || { echo "$ENGINE is not installed" >&2; exit 127; }
            "$ENGINE" -no-shell-escape -interaction=nonstopmode -halt-on-error -output-directory="$OUTDIR" "$INPUT"
            ;;
          *)
            echo "unsupported LaTeX engine: $ENGINE" >&2
            exit 2
            ;;
        esac
        """
        let result = try await context.structuredShell.run(command, cwd: context.workspaceRoot)
        let transcript = outputText(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        guard result.exitCode == 0 else {
            throw IntatisError.io("LaTeX compile failed. \(transcript)")
        }
        guard FileManager.default.fileExists(atPath: outputPDF.path) else {
            throw IntatisError.io("LaTeX compile finished but did not create \(outputPDF.lastPathComponent). \(transcript)")
        }
        let changed = PathConfinement.relativePath(of: outputPDF, root: context.workspaceRoot)
        return ToolObservation(text: "compiled \(a.inputPath) to \(changed)\n\(transcript)",
                               changedFiles: [changed])
    }
}

// MARK: - generate_image

public struct GenerateImageTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "generate_image",
        description: "Generate image files from a prompt using the configured image provider or injected local image model backend.",
        sideEffect: .write,
        parameters: Schema.object([
            "prompt": Schema.nonEmptyString,
            "outputPath": Schema.nonEmptyString,
            "size": Schema.nonEmptyString,
            "count": Schema.boundedInteger(minimum: 1, maximum: 4),
        ], required: ["prompt", "outputPath"])
    )

    struct Args: Decodable {
        let prompt: String
        let outputPath: String
        let size: String?
        let count: Int?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).outputPath).map { [$0] } ?? []
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try PathConfinement.resolve(a.outputPath, within: context.workspaceRoot)
        guard let generator = context.imageGenerator else {
            throw IntatisError.config("generate_image is not configured; attach an image provider or local image backend before using this tool")
        }
        return try await generator.generateImage(
            prompt: a.prompt,
            size: a.size?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "1024x1024",
            count: a.count ?? 1,
            outputPath: a.outputPath,
            workspaceRoot: context.workspaceRoot)
    }
}

// MARK: - edit_image

public struct EditImageTool: Tool {
    public init() {}

    static let maximumInputMiB = 50
    static let maximumInputBytes = maximumInputMiB * 1_024 * 1_024
    private static let supportedImageMIMEs: [String: String] = [
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
    ]

    public static let descriptor = ToolDescriptor(
        name: "edit_image",
        description: "Edit one existing PNG, JPEG, or WebP image in the workspace using the configured image provider. Writes a new PNG file; imagePath and outputPath must be different.",
        sideEffect: .write,
        parameters: Schema.object([
            "imagePath": Schema.nonEmptyString,
            "prompt": Schema.boundedString(minLength: 1, maxLength: 32_000),
            "outputPath": Schema.nonEmptyString,
        ], required: ["imagePath", "prompt", "outputPath"])
    )

    struct Args: Decodable {
        let imagePath: String
        let prompt: String
        let outputPath: String
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? args.decode(Args.self) else { return [] }
        return [value.imagePath, value.outputPath]
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        var resources: [PermissionResource] = []
        if let imagePath = value?.imagePath {
            resources.append(PermissionResource(
                kind: .workspacePath,
                value: imagePath,
                access: .readOnly))
        }
        if let outputPath = value?.outputPath {
            resources.append(PermissionResource(
                kind: .workspacePath,
                value: outputPath,
                access: .readWrite))
        }
        return PermissionIntent(
            action: "media.edit",
            resources: resources,
            metadata: [
                "operation": .string("edit_image"),
                "promptCharacterCount": .number(Double(value?.prompt.count ?? 0)),
            ],
            dataEffects: [.read, .mutate, .network],
            risks: [.workspaceMutation, .networkAccess, .modelCost],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        let prompt = value.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_empty_prompt",
                message: "edit_image prompt must contain non-whitespace text")
        }

        let inputURL: URL
        let outputURL: URL
        do {
            inputURL = try PathConfinement.resolve(value.imagePath, within: context.workspaceRoot)
            outputURL = try PathConfinement.resolve(value.outputPath, within: context.workspaceRoot)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_invalid_path",
                message: "edit_image input and output must resolve inside the workspace")
        }
        guard inputURL.standardizedFileURL.path != outputURL.standardizedFileURL.path else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_same_path",
                message: "edit_image outputPath must be different from imagePath")
        }
        guard outputURL.pathExtension.lowercased() == "png" else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_output_must_be_png",
                message: "edit_image outputPath must use the .png extension")
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try inputURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_input_unavailable",
                message: "edit_image could not inspect the input image")
        }
        guard resourceValues.isRegularFile == true else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_not_regular_file",
                message: "edit_image imagePath must be a regular file")
        }
        if let fileSize = resourceValues.fileSize,
           fileSize > Self.maximumInputBytes {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_input_too_large",
                message: "edit_image input exceeds the \(Self.maximumInputMiB) MiB safety limit")
        }

        let fileExtension = inputURL.pathExtension.lowercased()
        guard let mime = Self.supportedImageMIMEs[fileExtension] else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_unsupported_format",
                message: "edit_image supports PNG, JPEG, and WebP input images")
        }

        let image: Data
        do {
            image = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_input_unreadable",
                message: "edit_image could not read the input image")
        }
        guard !image.isEmpty, image.count <= Self.maximumInputBytes else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: image.isEmpty ? "edit_image_input_empty" : "edit_image_input_too_large",
                message: image.isEmpty
                    ? "edit_image input image is empty"
                    : "edit_image input exceeds the \(Self.maximumInputMiB) MiB safety limit")
        }
        guard Self.matchesImageSignature(image, fileExtension: fileExtension) else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_invalid_image",
                message: "edit_image input bytes do not match the file extension")
        }
        guard let generator = context.imageGenerator else {
            throw IntatisError.config("edit_image is not configured; attach an image provider or local image backend before using this tool")
        }

        let normalizedExtension = fileExtension == "jpeg" ? "jpg" : fileExtension
        return try await generator.editImage(
            image: image,
            filename: "input.\(normalizedExtension)",
            mime: mime,
            prompt: prompt,
            outputPath: value.outputPath,
            workspaceRoot: context.workspaceRoot)
    }

    private static func matchesImageSignature(_ data: Data,
                                              fileExtension: String) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        switch fileExtension {
        case "png":
            return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "jpg", "jpeg":
            return bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case "webp":
            return bytes.count >= 12
                && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
                && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
        default:
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
