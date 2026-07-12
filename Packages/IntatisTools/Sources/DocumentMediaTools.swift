import Foundation
import IntatisCore

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
        description: "Extract readable text from a PDF in the workspace, with optional 1-based page ranges such as '1-3,5'.",
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
            text += "\n\nHint: for scanned or photographed documents, use reconstruct_document_image with a Docling/Marker/Tesseract backend."
        }
        return ToolObservation(text: text, truncated: truncated)
        #else
        throw IntatisError.config("read_pdf requires PDFKit on Apple platforms; use an explicitly integrated, workspace-confined PDF backend on this platform.")
        #endif
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
        description: "Convert a photographed/scanned document image into an editable document file using installed mature OCR/layout CLIs such as Docling, Marker, or Tesseract.",
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
