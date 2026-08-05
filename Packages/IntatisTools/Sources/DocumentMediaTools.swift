import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Shared helpers

private enum PageSelection {
    static func parse(_ raw: String?, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { return [] }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.lowercased() == "all" {
            return Array(0..<pageCount)
        }

        var pages: [Int] = []
        var seen = Set<Int>()
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let dash = token.firstIndex(of: "-") {
                let left = token[..<dash].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = token[token.index(after: dash)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = Int(left), let end = Int(right), start > 0, end > 0, start <= end else {
                    throw IntatisError.decoding("invalid page range: \(token)")
                }
                for page in start...end {
                    try append(page, pageCount: pageCount, to: &pages, seen: &seen)
                }
            } else {
                guard let page = Int(token), page > 0 else {
                    throw IntatisError.decoding("invalid page number: \(token)")
                }
                try append(page, pageCount: pageCount, to: &pages, seen: &seen)
            }
        }
        return pages
    }

    private static func append(_ oneBased: Int,
                               pageCount: Int,
                               to pages: inout [Int],
                               seen: inout Set<Int>) throws {
        guard oneBased <= pageCount else {
            throw IntatisError.decoding("page \(oneBased) exceeds document page count \(pageCount)")
        }
        let zeroBased = oneBased - 1
        if seen.insert(zeroBased).inserted {
            pages.append(zeroBased)
        }
    }
}

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
    public static let descriptor = ToolDescriptor(
        name: "read_pdf",
        description: "Read text already embedded in a workspace PDF, with optional 1-based page ranges such as '1-3,5'. This tool does not perform OCR. Use it for PDFs with an extractable text layer; for scanned or image-only PDFs that need reading or summarization, use read_document with backend omitted or set to 'auto'.",
        sideEffect: .readOnly,
        parameters: Schema.object([
            "path": Schema.nonEmptyString,
            "pages": Schema.nonEmptyString,
            "maxCharacters": Schema.boundedInteger(minimum: 1, maximum: 500_000),
        ], required: ["path"])
    )

    struct Args: Decodable {
        let path: String
        let pages: String?
        let maxCharacters: Int?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).path).map { [$0] } ?? []
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let url = try PathConfinement.resolve(a.path, within: context.workspaceRoot)

        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw IntatisError.decoding("could not open PDF: \(a.path)")
        }
        let selectedPages = try PageSelection.parse(a.pages, pageCount: document.pageCount)
        let limit = min(a.maxCharacters ?? 200_000, 500_000)
        var lines: [String] = [
            "PDF: \(a.path)",
            "Pages: \(document.pageCount)",
            "Selected pages: \(selectedPages.map { String($0 + 1) }.joined(separator: ","))",
        ]
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        lines.append("")

        var truncated = false
        for pageIndex in selectedPages {
            if lines.joined(separator: "\n").count >= limit {
                truncated = true
                break
            }
            let pageText = document.page(at: pageIndex)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append("--- page \(pageIndex + 1) ---")
            lines.append(pageText.isEmpty ? "(no extractable text on this page)" : pageText)
        }

        var text = lines.joined(separator: "\n")
        if text.count > limit {
            text = String(text.prefix(limit))
            truncated = true
        }
        if text.contains("(no extractable text") {
            text += "\n\nHint: this PDF has no extractable text layer. To read or summarize it, use read_document with backend omitted or set to 'auto'. Use reconstruct_document_image only when the user explicitly requests a new editable output artifact from an image file."
        }
        return ToolObservation(text: text, truncated: truncated)
        #else
        throw IntatisError.config("read_pdf requires PDFKit on Apple platforms; use an explicitly integrated, workspace-confined PDF backend on this platform.")
        #endif
    }
}

// MARK: - read_document

/// Reads common office/document formats through a fixed, locally installed
/// parser command. The model controls only the input path, backend preference,
/// and output bound; it never supplies a command line or enables networking.
public struct ReadDocumentTool: Tool {
    public init() {}

    static let maximumInputMiB = 512
    static let maximumInputBytes = maximumInputMiB * 1_024 * 1_024

    public static let descriptor = ToolDescriptor(
        name: "read_document",
        description: "Read a workspace document up to 512 MiB as bounded Markdown for analysis or summarization using an installed local Docling or MarkItDown backend. This is the preferred reading tool for scanned or image-only PDFs and documents that need OCR or layout parsing; omit backend or use 'auto' unless the user explicitly requires a specific compatible backend. It returns text and does not create an output artifact. Supports modern and legacy Word, PowerPoint, and Excel formats plus common open document formats. Legacy .doc/.ppt/.xls parsing requires LibreOffice. Remote services and plugins remain disabled.",
        sideEffect: .exec,
        parameters: Schema.object([
            "path": Schema.nonEmptyString,
            "backend": Schema.nonEmptyString,
            "maxCharacters": Schema.boundedInteger(minimum: 1, maximum: 500_000),
        ], required: ["path"])
    )

    struct Args: Decodable {
        let path: String
        let backend: String?
        let maxCharacters: Int?
    }

    private static let supportedExtensions: Set<String> = [
        "doc", "docx", "ppt", "pptx", "xls", "xlsx", "xlsm", "xlsb",
        "odt", "ods", "odp", "rtf", "csv", "html", "htm", "md",
        "markdown", "txt", "epub", "pdf",
    ]

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).path).map { [$0] } ?? []
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        let inputURL: URL
        do {
            inputURL = try PathConfinement.resolve(value.path, within: context.workspaceRoot)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "read_document_invalid_path",
                message: "read_document input must resolve to a readable file inside the workspace")
        }
        let resourceValues: URLResourceValues
        do {
            resourceValues = try inputURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "read_document_input_unavailable",
                message: "read_document could not inspect the input file")
        }
        guard resourceValues.isRegularFile == true else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "read_document_not_regular_file",
                message: "read_document path must be a regular file")
        }
        if let fileSize = resourceValues.fileSize, fileSize > Self.maximumInputBytes {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "read_document_input_too_large",
                message: "read_document input exceeds the \(Self.maximumInputMiB) MiB safety limit")
        }

        let fileExtension = inputURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "read_document_unsupported_extension",
                message: "unsupported document extension '.\(fileExtension)'; supported formats include doc/docx, ppt/pptx, xls/xlsx, OpenDocument, RTF, CSV, HTML, Markdown, text, EPUB, and PDF")
        }

        let backend = (value.backend ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["auto", "docling", "markitdown"].contains(backend) else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "read_document_unsupported_backend",
                message: "unsupported read_document backend '\(backend)'; use auto, docling, or markitdown")
        }

        let runtimeRoot = intatisDocumentRuntimeRoot()
        let runtimePath = runtimeRoot?.path ?? ""
        let command = """
        set -u
        INPUT=\(shellQuote(inputURL.path))
        BACKEND=\(shellQuote(backend))
        DOCUMENT_RUNTIME=\(shellQuote(runtimePath))
        if [ -n "$DOCUMENT_RUNTIME" ] && [ -d "$DOCUMENT_RUNTIME/bin" ]; then
          PATH="$DOCUMENT_RUNTIME/bin:$PATH"
        fi
        if [ -d "/Applications/LibreOffice.app/Contents/MacOS" ]; then
          PATH="/Applications/LibreOffice.app/Contents/MacOS:$PATH"
        fi
        export PATH

        WORK=$(mktemp -d "$TMPDIR/intatis-read-document.XXXXXX") || exit 70
        cleanup() { rm -rf "$WORK"; }
        trap cleanup EXIT
        trap 'exit 130' HUP INT TERM

        DOCLING=$(command -v docling 2>/dev/null || true)
        MARKITDOWN=$(command -v markitdown 2>/dev/null || true)

        emit_result() {
          printf '__INTATIS_DOCUMENT_BACKEND__=%s\\n' "$1"
          cat "$2"
        }

        run_docling() {
          mkdir -p "$WORK/docling-output"
          if [ -n "$DOCUMENT_RUNTIME" ] && [ -d "$DOCUMENT_RUNTIME/models" ]; then
            "$DOCLING" convert --to md --image-export-mode placeholder \
              --html-image-fetch none --no-enable-remote-services \
              --no-allow-external-plugins --abort-on-error \
              --document-timeout 240 --num-threads 2 \
              --artifacts-path "$DOCUMENT_RUNTIME/models" \
              --output "$WORK/docling-output" "$INPUT" \
              >"$WORK/docling.stdout" 2>"$WORK/docling.stderr" || return $?
          else
            "$DOCLING" convert --to md --image-export-mode placeholder \
              --html-image-fetch none --no-enable-remote-services \
              --no-allow-external-plugins --abort-on-error \
              --document-timeout 240 --num-threads 2 \
              --output "$WORK/docling-output" "$INPUT" \
              >"$WORK/docling.stdout" 2>"$WORK/docling.stderr" || return $?
          fi
          GENERATED=$(find "$WORK/docling-output" -type f -name '*.md' -print | head -n 1)
          if [ -z "$GENERATED" ] || [ ! -f "$GENERATED" ]; then
            printf 'Docling produced no Markdown output.\\n' >>"$WORK/docling.stderr"
            return 3
          fi
          emit_result docling "$GENERATED"
        }

        run_markitdown() {
          "$MARKITDOWN" "$INPUT" -o "$WORK/markitdown.md" \
            >"$WORK/markitdown.stdout" 2>"$WORK/markitdown.stderr" || return $?
          if [ ! -f "$WORK/markitdown.md" ]; then
            printf 'MarkItDown produced no Markdown output.\\n' >>"$WORK/markitdown.stderr"
            return 3
          fi
          emit_result markitdown "$WORK/markitdown.md"
        }

        case "$BACKEND" in
          docling)
            if [ -z "$DOCLING" ]; then
              printf 'Docling is not installed in the trusted document runtime or system PATH.\\n' >&2
              exit 127
            fi
            if run_docling; then exit 0; fi
            cat "$WORK/docling.stderr" >&2
            exit 1
            ;;
          markitdown)
            if [ -z "$MARKITDOWN" ]; then
              printf 'MarkItDown is not installed in the trusted document runtime or system PATH.\\n' >&2
              exit 127
            fi
            if run_markitdown; then exit 0; fi
            cat "$WORK/markitdown.stderr" >&2
            exit 1
            ;;
          auto)
            if [ -n "$DOCLING" ] && run_docling; then exit 0; fi
            if [ -n "$MARKITDOWN" ] && run_markitdown; then exit 0; fi
            if [ -n "$DOCLING" ] && [ -f "$WORK/docling.stderr" ]; then
              printf '[Docling]\\n' >&2
              cat "$WORK/docling.stderr" >&2
            fi
            if [ -n "$MARKITDOWN" ] && [ -f "$WORK/markitdown.stderr" ]; then
              printf '[MarkItDown]\\n' >&2
              cat "$WORK/markitdown.stderr" >&2
            fi
            if [ -z "$DOCLING" ] && [ -z "$MARKITDOWN" ]; then
              printf 'No local document backend was found. Install docling or markitdown[all] into the Intatis document runtime.\\n' >&2
            fi
            exit 127
            ;;
        esac
        """

        let result = try await context.structuredShell.run(
            command,
            cwd: context.workspaceRoot)
        let sanitizedStdout = sanitizeProcessText(
            result.stdout,
            inputURL: inputURL,
            inputPath: value.path,
            workspaceRoot: context.workspaceRoot,
            runtimeRoot: runtimeRoot)
        let sanitizedStderr = sanitizeProcessText(
            result.stderr,
            inputURL: inputURL,
            inputPath: value.path,
            workspaceRoot: context.workspaceRoot,
            runtimeRoot: runtimeRoot)
        guard result.exitCode == 0 else {
            let transcript = outputText(
                stdout: sanitizedStdout,
                stderr: sanitizedStderr,
                exitCode: result.exitCode)
            let legacyHint = ["doc", "ppt", "xls"].contains(fileExtension)
                ? " Legacy Office formats also require LibreOffice."
                : ""
            throw IntatisError.io(
                "document reading failed. Install a backend in the Intatis document runtime or select another backend.\(legacyHint) \(transcript)")
        }

        let markerPrefix = "__INTATIS_DOCUMENT_BACKEND__="
        guard sanitizedStdout.hasPrefix(markerPrefix),
              let firstNewline = sanitizedStdout.firstIndex(of: "\n") else {
            throw IntatisError.io("document backend returned an invalid structured result")
        }
        let backendName = sanitizedStdout[
            sanitizedStdout.index(sanitizedStdout.startIndex, offsetBy: markerPrefix.count)..<firstNewline]
        let extracted = String(sanitizedStdout[sanitizedStdout.index(after: firstNewline)...])
        let limit = max(1, min(value.maxCharacters ?? 200_000, 500_000))
        let header = "Document: \(value.path)\nFormat: .\(fileExtension)\nBackend: \(backendName)\n\n"
        let output = header + extracted
        let truncated = output.count > limit
        return ToolObservation(
            text: truncated ? String(output.prefix(limit)) : output,
            truncated: truncated)
    }

    private func sanitizeProcessText(
        _ text: String,
        inputURL: URL,
        inputPath: String,
        workspaceRoot: URL,
        runtimeRoot: URL?
    ) -> String {
        var sanitized = text.replacingOccurrences(
            of: inputURL.path,
            with: inputPath)
        sanitized = sanitized.replacingOccurrences(
            of: workspaceRoot.path,
            with: "<workspace>")
        if let runtimeRoot {
            sanitized = sanitized.replacingOccurrences(
                of: runtimeRoot.path,
                with: "<Intatis document runtime>")
        }
        return sanitized
    }
}

// MARK: - edit_pdf_pages

public struct EditPDFPagesTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "edit_pdf_pages",
        description: "Page-level PDF editing: extract selected pages to one PDF or split selected pages into one PDF per page.",
        sideEffect: .write,
        parameters: Schema.object([
            "mode": Schema.nonEmptyString,
            "inputPath": Schema.nonEmptyString,
            "pages": Schema.nonEmptyString,
            "outputPath": Schema.nonEmptyString,
            "outputDir": Schema.nonEmptyString,
            "outputPrefix": Schema.nonEmptyString,
        ], required: ["mode", "inputPath"])
    )

    struct Args: Decodable {
        let mode: String
        let inputPath: String
        let pages: String?
        let outputPath: String?
        let outputDir: String?
        let outputPrefix: String?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let a = try? args.decode(Args.self) else { return [] }
        return [a.inputPath, a.outputPath, a.outputDir].compactMap { $0 }
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let inputURL = try PathConfinement.resolve(a.inputPath, within: context.workspaceRoot)
        let mode = a.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        #if canImport(PDFKit)
        guard let source = PDFDocument(url: inputURL) else {
            throw IntatisError.decoding("could not open PDF: \(a.inputPath)")
        }
        let selectedPages = try PageSelection.parse(a.pages, pageCount: source.pageCount)
        guard !selectedPages.isEmpty else {
            throw IntatisError.decoding("no pages selected")
        }

        switch mode {
        case "extract":
            guard let outputPath = a.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !outputPath.isEmpty else {
                throw IntatisError.decoding("edit_pdf_pages mode 'extract' requires outputPath")
            }
            let outputURL = try PathConfinement.resolve(outputPath, within: context.workspaceRoot)
            try ensureParentDirectory(for: outputURL)
            let output = PDFDocument()
            for (position, pageIndex) in selectedPages.enumerated() {
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                    throw IntatisError.decoding("could not copy page \(pageIndex + 1)")
                }
                output.insert(page, at: position)
            }
            guard output.write(to: outputURL) else {
                throw IntatisError.io("failed to write PDF: \(outputPath)")
            }
            let changed = PathConfinement.relativePath(of: outputURL, root: context.workspaceRoot)
            return ToolObservation(
                text: "extracted \(selectedPages.count) page(s) from \(a.inputPath) to \(changed)",
                changedFiles: [changed])

        case "split":
            guard let outputDir = a.outputDir?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !outputDir.isEmpty else {
                throw IntatisError.decoding("edit_pdf_pages mode 'split' requires outputDir")
            }
            let dirURL = try PathConfinement.resolve(outputDir, within: context.workspaceRoot)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let prefix = a.outputPrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? inputURL.deletingPathExtension().lastPathComponent
            let digits = max(3, String(source.pageCount).count)
            var changed: [String] = []
            for pageIndex in selectedPages {
                let output = PDFDocument()
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                    throw IntatisError.decoding("could not copy page \(pageIndex + 1)")
                }
                output.insert(page, at: 0)
                let filename = "\(prefix)-page-\(String(format: "%0\(digits)d", pageIndex + 1)).pdf"
                let pageURL = dirURL.appendingPathComponent(filename)
                guard output.write(to: pageURL) else {
                    throw IntatisError.io("failed to write PDF: \(filename)")
                }
                changed.append(PathConfinement.relativePath(of: pageURL, root: context.workspaceRoot))
            }
            return ToolObservation(
                text: "split \(selectedPages.count) page(s) from \(a.inputPath) into \(PathConfinement.relativePath(of: dirURL, root: context.workspaceRoot))",
                changedFiles: changed)

        default:
            throw IntatisError.decoding("unsupported edit_pdf_pages mode '\(a.mode)'; use 'extract' or 'split'")
        }
        #else
        throw IntatisError.config("edit_pdf_pages requires PDFKit on Apple platforms; use an explicitly integrated, workspace-confined PDF backend on this platform.")
        #endif
    }
}

// MARK: - reconstruct_document_image

public struct ReconstructDocumentImageTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "reconstruct_document_image",
        description: "Create a new editable document artifact from a photographed or scanned document image using installed OCR or layout CLIs such as Docling, Marker, or Tesseract. Use this only when the user explicitly requests conversion or reconstruction with an output file; do not use it for ordinary reading or summarization, and do not pass a PDF as imagePath. For scanned or image-only PDF reading, use read_document with backend omitted or set to 'auto'.",
        sideEffect: .exec,
        parameters: Schema.object([
            "imagePath": Schema.nonEmptyString,
            "outputPath": Schema.nonEmptyString,
            "format": Schema.nonEmptyString,
            "backend": Schema.nonEmptyString,
        ], required: ["imagePath", "outputPath"])
    )

    struct Args: Decodable {
        let imagePath: String
        let outputPath: String
        let format: String?
        let backend: String?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let a = try? args.decode(Args.self) else { return [] }
        return [a.imagePath, a.outputPath]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let inputURL = try PathConfinement.resolve(a.imagePath, within: context.workspaceRoot)
        let outputURL = try PathConfinement.resolve(a.outputPath, within: context.workspaceRoot)
        try ensureParentDirectory(for: outputURL)

        let format = normalizedDocumentFormat(a.format, outputPath: a.outputPath)
        let backend = (a.backend ?? "auto").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = extensionForDocumentFormat(format)
        let markerFormat = format == "md" ? "markdown" : format

        let command = """
        set -e
        INPUT=\(shellQuote(inputURL.path))
        OUTPUT=\(shellQuote(outputURL.path))
        FORMAT=\(shellQuote(format))
        MARKER_FORMAT=\(shellQuote(markerFormat))
        EXT=\(shellQuote(ext))
        BACKEND=\(shellQuote(backend))
        OUTDIR=$(dirname "$OUTPUT")
        TMPDIR="$OUTDIR/.intatis-doc-reconstruct-$$"
        mkdir -p "$TMPDIR"
        cleanup() { rm -rf "$TMPDIR"; }
        trap cleanup EXIT

        run_docling() {
          docling convert --to "$FORMAT" --output "$TMPDIR" "$INPUT"
          GENERATED=$(find "$TMPDIR" -type f -name "*.$EXT" | head -n 1)
          if [ -z "$GENERATED" ]; then
            echo "docling produced no .$EXT output" >&2
            return 3
          fi
          cp "$GENERATED" "$OUTPUT"
        }

        run_marker() {
          marker_single "$INPUT" --output_dir "$TMPDIR" --output_format "$MARKER_FORMAT"
          GENERATED=$(find "$TMPDIR" -type f -name "*.$EXT" | head -n 1)
          if [ -z "$GENERATED" ]; then
            echo "marker produced no .$EXT output" >&2
            return 3
          fi
          cp "$GENERATED" "$OUTPUT"
        }

        run_tesseract() {
          if [ "$FORMAT" = "html" ]; then
            echo "tesseract fallback only supports markdown or text output; install docling or marker for HTML layout output" >&2
            return 4
          fi
          if [ "$FORMAT" = "md" ]; then
            printf '# Reconstructed document\\n\\n' > "$OUTPUT"
            tesseract "$INPUT" stdout --psm 1 >> "$OUTPUT"
          else
            tesseract "$INPUT" stdout --psm 1 > "$OUTPUT"
          fi
        }

        case "$BACKEND" in
          docling)
            command -v docling >/dev/null 2>&1 || { echo "docling is not installed" >&2; exit 127; }
            run_docling
            ;;
          marker)
            command -v marker_single >/dev/null 2>&1 || { echo "marker_single is not installed" >&2; exit 127; }
            run_marker
            ;;
          tesseract)
            command -v tesseract >/dev/null 2>&1 || { echo "tesseract is not installed" >&2; exit 127; }
            run_tesseract
            ;;
          auto)
            if command -v docling >/dev/null 2>&1; then
              run_docling
            elif command -v marker_single >/dev/null 2>&1; then
              run_marker
            elif command -v tesseract >/dev/null 2>&1; then
              run_tesseract
            else
              echo "No document reconstruction backend found. Install docling, marker, PaddleOCR, OCRmyPDF, or tesseract." >&2
              exit 127
            fi
            ;;
          *)
            echo "unsupported backend: $BACKEND" >&2
            exit 2
            ;;
        esac
        """

        let result = try await context.structuredShell.run(command, cwd: context.workspaceRoot)
        let transcript = outputText(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        guard result.exitCode == 0 else {
            throw IntatisError.io("document reconstruction failed. \(transcript)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw IntatisError.io("document reconstruction finished but did not create \(a.outputPath)")
        }
        let changed = PathConfinement.relativePath(of: outputURL, root: context.workspaceRoot)
        return ToolObservation(
            text: "reconstructed \(a.imagePath) to \(changed) using \(backend) backend\n\(transcript)",
            changedFiles: [changed])
    }

    private func normalizedDocumentFormat(_ raw: String?, outputPath: String) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inferred = (outputPath as NSString).pathExtension.lowercased()
        switch value?.nilIfEmpty ?? inferred {
        case "markdown", "md": return "md"
        case "html", "htm": return "html"
        case "text", "txt": return "text"
        default: return "md"
        }
    }

    private func extensionForDocumentFormat(_ format: String) -> String {
        switch format {
        case "html": return "html"
        case "text": return "txt"
        default: return "md"
        }
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
            replayPolicy: .requiresManualReconciliation)
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
