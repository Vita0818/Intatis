#if canImport(SwiftUI) && canImport(MarkdownUI) && canImport(iosMath)
import CryptoKit
import Foundation
import cmark_gfm
import cmark_gfm_extensions
import iosMath
import MarkdownUI

enum IntatisMathPresentation: String, Equatable, Sendable {
    case inline
    case display
}

struct IntatisMathExpression: Equatable, Sendable {
    let source: String
    let presentation: IntatisMathPresentation
}

/// `MarkdownContent` is an immutable value in MarkdownUI 2.4.1 but that release
/// predates Swift concurrency annotations. The document is created on the
/// serial render worker and then treated as immutable by SwiftUI.
struct IntatisRenderedDocument: Equatable, @unchecked Sendable {
    let rawText: String
    let markdownText: String?
    let markdownContent: MarkdownContent?
    let mathExpressions: [String: IntatisMathExpression]

    static func plain(_ rawText: String) -> IntatisRenderedDocument {
        IntatisRenderedDocument(
            rawText: rawText,
            markdownText: nil,
            markdownContent: nil,
            mathExpressions: [:])
    }
}

/// Builds a display-only Markdown document while preserving the persisted source.
///
/// Markdown display parsing remains entirely in MarkdownUI. A read-only pass
/// through MarkdownUI's pinned cmark engine supplies complexity checks and code
/// source ranges; this adapter only routes explicit TeX delimiters outside those
/// code literals to iosMath through private image URLs.
enum IntatisRenderDocumentBuilder {
    static let maximumRichTextBytes = 512 * 1024
    static let maximumFormulaBytes = 32 * 1024
    static let maximumFormulaCount = 64
    static let maximumDerivedMarkdownBytes = 768 * 1024

    private static let cache: NSCache<NSString, IntatisRenderedDocumentBox> = {
        let cache = NSCache<NSString, IntatisRenderedDocumentBox>()
        cache.countLimit = 96
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func build(rawText: String, cacheCompletedResult: Bool) -> IntatisRenderedDocument {
        guard rawText.utf8.count <= maximumRichTextBytes else {
            return .plain(rawText)
        }

        let cacheKey = rawText as NSString
        if cacheCompletedResult, let cached = cache.object(forKey: cacheKey) {
            return cached.document
        }

        // Inspect every message before constructing MarkdownUI's recursive view
        // tree. The same pinned cmark parse also supplies exact block-code
        // source ranges to the math adapter when formulas are present.
        guard let commonMark = IntatisCommonMarkInspector.inspect(rawText),
              commonMark.isWithinComplexityLimits else {
            return .plain(rawText)
        }

        let transformed = IntatisMathDelimiterAdapter.transform(
            rawText,
            protectedRanges: commonMark.codeRanges)
        guard !transformed.exceededLimits,
              transformed.markdown.utf8.count <= maximumDerivedMarkdownBytes else {
            return .plain(rawText)
        }

        let document = IntatisRenderedDocument(
            rawText: rawText,
            markdownText: transformed.markdown,
            markdownContent: MarkdownContent(transformed.markdown),
            mathExpressions: transformed.expressions)

        if cacheCompletedResult {
            cache.setObject(
                IntatisRenderedDocumentBox(document),
                forKey: cacheKey,
                cost: rawText.utf8.count)
        }
        return document
    }

    static func cachedDocument(for rawText: String) -> IntatisRenderedDocument? {
        cache.object(forKey: rawText as NSString)?.document
    }
}

/// Serializes cmark parsing across concurrently visible messages and keeps the
/// synchronous parser off SwiftUI's main actor. Engine behavior remains wholly
/// owned by MarkdownUI/swift-cmark.
actor IntatisRenderDocumentWorker {
    static let shared = IntatisRenderDocumentWorker()

    func build(rawText: String, cacheCompletedResult: Bool) -> IntatisRenderedDocument {
        if Task.isCancelled {
            return .plain(rawText)
        }
        return IntatisRenderDocumentBuilder.build(
            rawText: rawText,
            cacheCompletedResult: cacheCompletedResult)
    }
}

private final class IntatisRenderedDocumentBox: NSObject {
    let document: IntatisRenderedDocument

    init(_ document: IntatisRenderedDocument) {
        self.document = document
    }
}

enum IntatisMathDelimiterAdapter {
    struct Result: Equatable, Sendable {
        var markdown: String
        var expressions: [String: IntatisMathExpression]
        var exceededLimits = false
    }

    static func transform(_ source: String) -> Result {
        guard source.range(of: "\\(") != nil
                || source.range(of: "\\[") != nil
                || source.range(of: "$$") != nil else {
            return Result(markdown: source, expressions: [:])
        }

        // Direct adapter callers still fail closed if source-range discovery
        // cannot be completed. Production document building injects the one
        // cmark preflight analysis; MarkdownUI still performs its own display
        // parse when the resulting document is rendered.
        guard let commonMark = IntatisCommonMarkInspector.inspect(source),
              commonMark.isWithinComplexityLimits else {
            return Result(markdown: source, expressions: [:], exceededLimits: true)
        }
        return transform(source, protectedRanges: commonMark.codeRanges)
    }

    static func transform(
        _ source: String,
        protectedRanges: [Range<String.Index>]
    ) -> Result {
        guard source.range(of: "\\(") != nil
                || source.range(of: "\\[") != nil
                || source.range(of: "$$") != nil else {
            return Result(markdown: source, expressions: [:])
        }

        var output = ""
        output.reserveCapacity(source.count)
        var expressions: [String: IntatisMathExpression] = [:]
        var formulaOccurrenceCount = 0
        var exhaustedClosers: Set<String> = []
        var cursor = source.startIndex
        var protectedRangeIndex = 0

        while cursor < source.endIndex {
            while protectedRangeIndex < protectedRanges.count,
                  cursor >= protectedRanges[protectedRangeIndex].upperBound {
                protectedRangeIndex += 1
            }
            if protectedRangeIndex < protectedRanges.count {
                let protectedRange = protectedRanges[protectedRangeIndex]
                if cursor >= protectedRange.lowerBound, cursor < protectedRange.upperBound {
                    output.append(contentsOf: source[cursor..<protectedRange.upperBound])
                    cursor = protectedRange.upperBound
                    continue
                }
            }

            let character = source[cursor]

            if hasPrefix("\\(", at: cursor, in: source),
               !isEscaped(cursor, in: source),
               let next = replaceMath(
                   opener: "\\(",
                   closer: "\\)",
                   presentation: .inline,
                   at: cursor,
                   source: source,
                   output: &output,
                   expressions: &expressions,
                   protectedRanges: protectedRanges,
                   exhaustedClosers: &exhaustedClosers,
                   formulaOccurrenceCount: &formulaOccurrenceCount
               ) {
                if formulaOccurrenceCount > IntatisRenderDocumentBuilder.maximumFormulaCount {
                    return Result(markdown: source, expressions: [:], exceededLimits: true)
                }
                cursor = next
                continue
            }
            if hasPrefix("\\(", at: cursor, in: source), !isEscaped(cursor, in: source) {
                output.append("\\\\(")
                cursor = source.index(cursor, offsetBy: 2)
                continue
            }

            if hasPrefix("\\[", at: cursor, in: source),
               !isEscaped(cursor, in: source),
               let next = replaceMath(
                   opener: "\\[",
                   closer: "\\]",
                   presentation: .display,
                   at: cursor,
                   source: source,
                   output: &output,
                   expressions: &expressions,
                   protectedRanges: protectedRanges,
                   exhaustedClosers: &exhaustedClosers,
                   formulaOccurrenceCount: &formulaOccurrenceCount
               ) {
                if formulaOccurrenceCount > IntatisRenderDocumentBuilder.maximumFormulaCount {
                    return Result(markdown: source, expressions: [:], exceededLimits: true)
                }
                cursor = next
                continue
            }
            if hasPrefix("\\[", at: cursor, in: source), !isEscaped(cursor, in: source) {
                output.append("\\\\[")
                cursor = source.index(cursor, offsetBy: 2)
                continue
            }

            if hasPrefix("$$", at: cursor, in: source),
               !isEscaped(cursor, in: source),
               let next = replaceMath(
                   opener: "$$",
                   closer: "$$",
                   presentation: .display,
                   at: cursor,
                   source: source,
                   output: &output,
                   expressions: &expressions,
                   protectedRanges: protectedRanges,
                   exhaustedClosers: &exhaustedClosers,
                   formulaOccurrenceCount: &formulaOccurrenceCount
               ) {
                if formulaOccurrenceCount > IntatisRenderDocumentBuilder.maximumFormulaCount {
                    return Result(markdown: source, expressions: [:], exceededLimits: true)
                }
                cursor = next
                continue
            }

            output.append(character)
            cursor = source.index(after: cursor)
        }

        guard output.utf8.count <= IntatisRenderDocumentBuilder.maximumDerivedMarkdownBytes else {
            return Result(markdown: source, expressions: [:], exceededLimits: true)
        }
        return Result(markdown: output, expressions: expressions)
    }

    private static func replaceMath(
        opener: String,
        closer: String,
        presentation: IntatisMathPresentation,
        at start: String.Index,
        source: String,
        output: inout String,
        expressions: inout [String: IntatisMathExpression],
        protectedRanges: [Range<String.Index>],
        exhaustedClosers: inout Set<String>,
        formulaOccurrenceCount: inout Int
    ) -> String.Index? {
        let contentStart = source.index(start, offsetBy: opener.count)
        guard let closeStart = findCloser(
            closer,
            from: contentStart,
            in: source,
            protectedRanges: protectedRanges,
            exhaustedClosers: &exhaustedClosers
        ) else {
            return nil
        }
        let end = source.index(closeStart, offsetBy: closer.count)
        formulaOccurrenceCount += 1
        guard formulaOccurrenceCount <= IntatisRenderDocumentBuilder.maximumFormulaCount else {
            return end
        }

        // Display delimiters are block syntax in this first integration. If a
        // pair is embedded in prose, a list, blockquote, or table cell, retain
        // its literal source instead of injecting root-level blank lines that
        // would corrupt the surrounding CommonMark container.
        if presentation == .display,
           (!isStandaloneDisplayStart(start, in: source)
               || !isStandaloneDisplayEnd(end, in: source)) {
            output.append(escapedMathDelimiters(in: String(source[start..<end])))
            return end
        }

        let formula = String(source[contentStart..<closeStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formula.isEmpty,
              formula.utf8.count <= IntatisRenderDocumentBuilder.maximumFormulaBytes,
              MTMathListBuilder.build(from: formula) != nil else {
            output.append(escapedMathDelimiters(in: String(source[start..<end])))
            return end
        }

        // Formula content is part of the internal URL identity. MarkdownUI
        // caches inline images by URL, so a positional key alone could leave a
        // stale image visible when a streaming formula changes in place.
        let digest = SHA256.hash(data: Data(formula.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let key = "\(presentation.rawValue)/\(digest)"
        expressions[key] = IntatisMathExpression(source: formula, presentation: presentation)
        let placeholder = "![LaTeX formula](intatis-math://\(key))"
        if presentation == .display {
            if !output.isEmpty, !output.hasSuffix("\n\n") {
                output.append(output.hasSuffix("\n") ? "\n" : "\n\n")
            }
            output.append(placeholder)
            if end < source.endIndex, !source[end...].hasPrefix("\n\n") {
                output.append("\n\n")
            }
        } else {
            output.append(placeholder)
        }
        return end
    }

    private static func escapedMathDelimiters(in source: String) -> String {
        source
            .replacingOccurrences(of: "\\(", with: "\\\\(")
            .replacingOccurrences(of: "\\)", with: "\\\\)")
            .replacingOccurrences(of: "\\[", with: "\\\\[")
            .replacingOccurrences(of: "\\]", with: "\\\\]")
    }

    private static func isStandaloneDisplayStart(
        _ start: String.Index,
        in source: String
    ) -> Bool {
        var lineStart = start
        while lineStart > source.startIndex {
            let previous = source.index(before: lineStart)
            if IntatisLineBreak.isLineBreak(source[previous]) { break }
            lineStart = previous
        }
        // Column-one only is deliberate: up to three leading spaces are legal
        // at the document root but are also list-continuation indentation. The
        // adapter refuses that ambiguity rather than reimplementing cmark's
        // container-prefix grammar.
        return lineStart == start
    }

    private static func isStandaloneDisplayEnd(
        _ end: String.Index,
        in source: String
    ) -> Bool {
        var cursor = end
        while cursor < source.endIndex,
              !IntatisLineBreak.isLineBreak(source[cursor]) {
            guard source[cursor] == " " || source[cursor] == "\t" else { return false }
            cursor = source.index(after: cursor)
        }
        return true
    }

    /// Finds a closer once, skipping upstream-recognized block code and valid
    /// CommonMark-style inline code spans. A failed search is memoized per
    /// delimiter, preventing repeated unclosed openers from rescanning to EOF.
    private static func findCloser(
        _ token: String,
        from start: String.Index,
        in source: String,
        protectedRanges: [Range<String.Index>],
        exhaustedClosers: inout Set<String>
    ) -> String.Index? {
        guard !exhaustedClosers.contains(token) else { return nil }
        var cursor = start
        var protectedRangeIndex = firstProtectedRangeIndex(
            endingAfter: start,
            in: protectedRanges)
        while cursor < source.endIndex {
            while protectedRangeIndex < protectedRanges.count,
                  cursor >= protectedRanges[protectedRangeIndex].upperBound {
                protectedRangeIndex += 1
            }
            if protectedRangeIndex < protectedRanges.count {
                let protectedRange = protectedRanges[protectedRangeIndex]
                if cursor >= protectedRange.lowerBound, cursor < protectedRange.upperBound {
                    cursor = protectedRange.upperBound
                    continue
                }
            }

            if hasPrefix(token, at: cursor, in: source), !isEscaped(cursor, in: source) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        exhaustedClosers.insert(token)
        return nil
    }

    private static func firstProtectedRangeIndex(
        endingAfter index: String.Index,
        in ranges: [Range<String.Index>]
    ) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upperBound <= index {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func hasPrefix(_ token: String, at index: String.Index, in source: String) -> Bool {
        source[index...].hasPrefix(token)
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        guard index > source.startIndex else { return false }
        var cursor = source.index(before: index)
        var count = 0
        while source[cursor] == "\\" {
            count += 1
            guard cursor > source.startIndex else { break }
            cursor = source.index(before: cursor)
        }
        return count.isMultiple(of: 2) == false
    }

}

private struct IntatisCommonMarkAnalysis {
    let codeRanges: [Range<String.Index>]
    let isWithinComplexityLimits: Bool
}

/// Uses the same pinned cmark-gfm parser and extension set as MarkdownUI 2.4.1.
/// One read-only AST pass supplies code-block source ranges and rejects shapes
/// that would create dangerously deep or wide recursive SwiftUI Text trees.
private enum IntatisCommonMarkInspector {
    private static let maximumNodeCount = 4_096
    private static let maximumTreeDepth = 32
    private static let maximumListNestingDepth = 8
    private static let maximumInlineNodesPerContainer = 256
    private static let maximumBreaksPerParagraph = 128
    private static let registerExtensions: Void = {
        cmark_gfm_core_extensions_ensure_registered()
    }()
    private static let extensionNames = [
        "autolink", "strikethrough", "tagfilter", "tasklist", "table",
    ]
    private static let knownNodeTypeNames: Set<String> = [
        "document", "block_quote", "list", "item", "code_block",
        "html_block", "custom_block", "paragraph", "heading",
        "thematic_break", "text", "softbreak", "linebreak", "code",
        "html_inline", "custom_inline", "emph", "strong", "link",
        "image", "attribute", "strikethrough", "table", "table_header",
        "table_row", "table_cell", "tasklist",
    ]

    static func inspect(_ source: String) -> IntatisCommonMarkAnalysis? {
        _ = registerExtensions
        let canExpandMathPlaceholders = source.range(of: "\\(") != nil
            || source.range(of: "\\[") != nil
            || source.range(of: "$$") != nil
        // A valid formula can expand one raw text node into surrounding text,
        // an image, and image-alt text. Reserve the worst-case 64-formula
        // growth here so the single raw-source parse also bounds the exact
        // Markdown tree later handed to MarkdownUI.
        let nodeLimit = canExpandMathPlaceholders
            ? maximumNodeCount - (IntatisRenderDocumentBuilder.maximumFormulaCount * 4)
            : maximumNodeCount
        let treeDepthLimit = canExpandMathPlaceholders
            ? maximumTreeDepth - 1
            : maximumTreeDepth
        let inlineNodeLimit = canExpandMathPlaceholders
            ? maximumInlineNodesPerContainer
                - (IntatisRenderDocumentBuilder.maximumFormulaCount * 3)
            : maximumInlineNodesPerContainer
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT | CMARK_OPT_SOURCEPOS) else {
            return nil
        }
        defer { cmark_parser_free(parser) }

        for extensionName in extensionNames {
            guard let syntaxExtension = cmark_find_syntax_extension(extensionName),
                  cmark_parser_attach_syntax_extension(parser, syntaxExtension) != 0 else {
                return nil
            }
        }
        source.withCString { buffer in
            cmark_parser_feed(parser, buffer, source.utf8.count)
        }
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }

        let lineStarts = IntatisLineBreak.lineStartIndices(in: source)
        var result: [Range<String.Index>] = []
        var nodeCount = 0
        var stack = [(node: document, depth: 1, listDepth: 0)]

        while let entry = stack.popLast() {
            let node = entry.node
            nodeCount += 1
            guard nodeCount <= nodeLimit,
                  entry.depth <= treeDepthLimit else {
                return IntatisCommonMarkAnalysis(
                    codeRanges: [],
                    isWithinComplexityLimits: false)
            }

            let typeName = String(cString: cmark_node_get_type_string(node))
            guard knownNodeTypeNames.contains(typeName) else {
                return IntatisCommonMarkAnalysis(
                    codeRanges: [],
                    isWithinComplexityLimits: false)
            }

            let listDepth = entry.listDepth + (typeName == "list" ? 1 : 0)
            guard listDepth <= maximumListNestingDepth else {
                return IntatisCommonMarkAnalysis(
                    codeRanges: [],
                    isWithinComplexityLimits: false)
            }

            if cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK {
                let startLine = Int(cmark_node_get_start_line(node))
                let endLine = Int(cmark_node_get_end_line(node))
                if startLine > 0,
                   endLine >= startLine,
                   startLine <= lineStarts.count {
                    let lowerBound = lineStarts[startLine - 1]
                    let upperBound = endLine < lineStarts.count
                        ? lineStarts[endLine]
                        : source.endIndex
                    if lowerBound < upperBound {
                        result.append(lowerBound..<upperBound)
                    }
                }
            } else if cmark_node_get_type(node) == CMARK_NODE_CODE {
                let startLine = Int(cmark_node_get_start_line(node))
                let endLine = Int(cmark_node_get_end_line(node))
                let inlineCodeRange: Range<String.Index>?
                if endLine > startLine {
                    // cmark strips blockquote/list continuation prefixes before
                    // reporting a multiline inline-code end column. Use the
                    // engine's own end line and backtick-count metadata to find
                    // that already-parsed closing run in the raw line; this is
                    // source-position repair, not a second code-span parser.
                    inlineCodeRange = IntatisLineBreak.multilineInlineCodeContentRange(
                        in: source,
                        lineStarts: lineStarts,
                        startLine: startLine,
                        startColumn: Int(cmark_node_get_start_column(node)),
                        endLine: endLine,
                        endColumn: Int(cmark_node_get_end_column(node)),
                        backtickCount: Int(cmark_node_get_backtick_count(node)))
                } else {
                    inlineCodeRange = IntatisLineBreak.sourceRange(
                        in: source,
                        lineStarts: lineStarts,
                        startLine: startLine,
                        startColumn: Int(cmark_node_get_start_column(node)),
                        endLine: endLine,
                        endColumn: Int(cmark_node_get_end_column(node)))
                }
                guard let inlineCodeRange else {
                    return IntatisCommonMarkAnalysis(
                        codeRanges: [],
                        isWithinComplexityLimits: false)
                }
                result.append(inlineCodeRange)
            }

            if typeName == "paragraph" || typeName == "heading" || typeName == "table_cell" {
                var inlineNodeCount = 0
                var breakCount = 0
                var inlineStack: [UnsafeMutablePointer<cmark_node>] = []
                var inlineChild = cmark_node_first_child(node)
                while let child = inlineChild {
                    inlineStack.append(child)
                    inlineChild = cmark_node_next(child)
                }
                while let inlineNode = inlineStack.popLast() {
                    let inlineType = cmark_node_get_type(inlineNode)
                    if inlineType == CMARK_NODE_SOFTBREAK || inlineType == CMARK_NODE_LINEBREAK {
                        breakCount += 1
                    } else {
                        // Break nodes have their own tighter bound below. Keep
                        // the independent recursive-inline budget available to
                        // catch emphasis/link/image-heavy paragraphs.
                        inlineNodeCount += 1
                    }
                    if inlineNodeCount > inlineNodeLimit
                        || (typeName == "paragraph" && breakCount > maximumBreaksPerParagraph) {
                        return IntatisCommonMarkAnalysis(
                            codeRanges: [],
                            isWithinComplexityLimits: false)
                    }
                    var nestedChild = cmark_node_first_child(inlineNode)
                    while let child = nestedChild {
                        inlineStack.append(child)
                        nestedChild = cmark_node_next(child)
                    }
                }
            }

            var child = cmark_node_first_child(node)
            while let current = child {
                stack.append((
                    node: current,
                    depth: entry.depth + 1,
                    listDepth: listDepth))
                child = cmark_node_next(current)
            }
        }

        return IntatisCommonMarkAnalysis(
            codeRanges: merged(result),
            isWithinComplexityLimits: true)
    }

    private static func merged(
        _ ranges: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var result: [Range<String.Index>] = []

        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}

private enum IntatisLineBreak {
    static func isLineBreak(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }
    }

    /// cmark counts LF, CR, and CRLF as line endings, with CRLF contributing
    /// exactly one line. Scalar iteration avoids treating CRLF's single Swift
    /// `Character` as neither `"\r"` nor `"\n"`.
    static func lineStartIndices(in source: String) -> [String.Index] {
        var result = [source.startIndex]
        let scalars = source.unicodeScalars
        var cursor = scalars.startIndex
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if scalar.value == 0x0D {
                var next = scalars.index(after: cursor)
                if next < scalars.endIndex, scalars[next].value == 0x0A {
                    next = scalars.index(after: next)
                }
                result.append(next)
                cursor = next
            } else if scalar.value == 0x0A {
                let next = scalars.index(after: cursor)
                result.append(next)
                cursor = next
            } else {
                cursor = scalars.index(after: cursor)
            }
        }
        return result
    }

    /// Repairs cmark's multiline inline-code end column, which is relative to
    /// container-stripped content. cmark has already parsed the span and exposes
    /// both its end line and exact delimiter length; this routine only locates
    /// that closing run in the corresponding raw line.
    static func multilineInlineCodeContentRange(
        in source: String,
        lineStarts: [String.Index],
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        backtickCount: Int
    ) -> Range<String.Index>? {
        guard startLine > 0,
              endLine > startLine,
              startLine <= lineStarts.count,
              endLine <= lineStarts.count,
              startColumn > 0,
              endColumn > 0,
              backtickCount > 0 else {
            return nil
        }

        let utf8 = source.utf8
        guard let startLineUTF8 = lineStarts[startLine - 1].samePosition(in: utf8),
              let startLimitUTF8 = (startLine < lineStarts.count
                  ? lineStarts[startLine]
                  : source.endIndex).samePosition(in: utf8),
              let endLineUTF8 = lineStarts[endLine - 1].samePosition(in: utf8),
              let endLimitUTF8 = (endLine < lineStarts.count
                  ? lineStarts[endLine]
                  : source.endIndex).samePosition(in: utf8),
              let lowerUTF8 = utf8.index(
                  startLineUTF8,
                  offsetBy: startColumn - 1,
                  limitedBy: startLimitUTF8),
              let searchStart = utf8.index(
                  endLineUTF8,
                  offsetBy: endColumn,
                  limitedBy: endLimitUTF8),
              let lowerBound = String.Index(lowerUTF8, within: source) else {
            return nil
        }

        var cursor = searchStart
        while cursor < endLimitUTF8 {
            let byte = utf8[cursor]
            if byte == 0x0A || byte == 0x0D { break }
            guard byte == 0x60 else {
                cursor = utf8.index(after: cursor)
                continue
            }

            let runStart = cursor
            var runLength = 0
            while cursor < endLimitUTF8, utf8[cursor] == 0x60 {
                runLength += 1
                cursor = utf8.index(after: cursor)
            }
            if runLength == backtickCount,
               let upperBound = String.Index(runStart, within: source),
               lowerBound < upperBound {
                return lowerBound..<upperBound
            }
        }
        return nil
    }

    /// Converts cmark's 1-based, byte-oriented, inclusive source positions to
    /// a native half-open String range. Returning nil fails the enclosing AST
    /// inspection closed rather than guessing across an invalid UTF-8 boundary.
    static func sourceRange(
        in source: String,
        lineStarts: [String.Index],
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int
    ) -> Range<String.Index>? {
        guard startLine > 0,
              endLine >= startLine,
              startLine <= lineStarts.count,
              endLine <= lineStarts.count,
              startColumn > 0,
              endColumn > 0 else {
            return nil
        }

        let utf8 = source.utf8
        guard let startUTF8 = lineStarts[startLine - 1].samePosition(in: utf8),
              let endUTF8 = lineStarts[endLine - 1].samePosition(in: utf8) else {
            return nil
        }
        let startLimit = startLine < lineStarts.count
            ? lineStarts[startLine].samePosition(in: utf8) ?? utf8.endIndex
            : utf8.endIndex
        let endLimit = endLine < lineStarts.count
            ? lineStarts[endLine].samePosition(in: utf8) ?? utf8.endIndex
            : utf8.endIndex
        guard let lowerUTF8 = utf8.index(
                  startUTF8,
                  offsetBy: startColumn - 1,
                  limitedBy: startLimit),
              let upperUTF8 = utf8.index(
                  endUTF8,
                  offsetBy: endColumn,
                  limitedBy: endLimit),
              let lowerBound = String.Index(lowerUTF8, within: source),
              let upperBound = String.Index(upperUTF8, within: source),
              lowerBound < upperBound else {
            return nil
        }
        return lowerBound..<upperBound
    }
}
#endif
