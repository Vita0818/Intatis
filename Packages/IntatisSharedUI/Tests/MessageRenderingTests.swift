#if canImport(SwiftUI) && canImport(MarkdownUI) && canImport(JavaScriptCore) && canImport(iosMath)
import XCTest
@testable import IntatisSharedUI

final class MessageRenderingTests: XCTestCase {
    func testPlainMarkdownPassesThroughWithoutAHomegrownParser() {
        let source = "# Heading\n\n- **one**\n- two"
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertEqual(result.markdown, source)
        XCTAssertTrue(result.expressions.isEmpty)
    }

    func testExplicitInlineAndDisplayMathAreRoutedIndependently() {
        let source = #"""
        Energy \(E = mc^2\).

        \[\sum_{i=1}^{n} i = \frac{n(n+1)}{2}\]
        """#
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertEqual(result.expressions.count, 2)
        let inline = result.expressions.values.first { $0.presentation == .inline }
        let display = result.expressions.values.first { $0.presentation == .display }
        XCTAssertEqual(inline?.source, "E = mc^2")
        XCTAssertEqual(display?.source, #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#)
        XCTAssertTrue(result.markdown.contains("intatis-math://inline/"))
        XCTAssertTrue(result.markdown.contains("intatis-math://display/"))
    }

    func testDollarMathUsesDisplayDelimitersButLeavesCurrencyAlone() {
        let source = "Price is $25.00.\n\n$$x^2 + y^2 = z^2$$"
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertTrue(result.markdown.contains("Price is $25.00."))
        XCTAssertEqual(result.expressions.count, 1)
        XCTAssertEqual(result.expressions.values.first?.presentation, .display)
    }

    func testMathInsideInlineCodeAndFencedCodeIsNeverIntercepted() {
        let source = #"""
        Use `\(notMath\)` here.

        ```swift
        let value = "$$stillCode$$"
        ```

        Then \(x + 1\).
        """#
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertTrue(result.markdown.contains(#"`\(notMath\)`"#))
        XCTAssertTrue(result.markdown.contains(#""$$stillCode$$""#))
        XCTAssertEqual(result.expressions.count, 1)
        XCTAssertEqual(result.expressions.values.first?.source, "x + 1")
    }

    func testUnicodeAndMultilineInlineCodeUseCmarkSourceRanges() {
        let rootSource = #"""
        Prefix 漢字 `first
        \(notMath\)
        last` then \(realMath\).
        """#
        let rootResult = IntatisMathDelimiterAdapter.transform(rootSource)

        XCTAssertTrue(rootResult.markdown.contains(#"\(notMath\)"#))
        XCTAssertEqual(rootResult.expressions.values.map(\.source), ["realMath"])

        // cmark reports multiline inline-code continuation columns after
        // stripping blockquote/list prefixes. The protected source range must
        // still cover the raw continuation line through the closing backtick.
        for lineEnding in ["\n", "\r", "\r\n"] {
            let nestedSource = [
                #"> - alpha ``first"#,
                #">   `shorter run` \(containerNotMath\)`` omega"#,
                "",
                #"Outside \(nestedRealMath\)."#,
            ].joined(separator: lineEnding)
            let nestedResult = IntatisMathDelimiterAdapter.transform(nestedSource)

            XCTAssertTrue(
                nestedResult.markdown.contains(#"\(containerNotMath\)"#),
                "line ending: \(lineEnding.debugDescription)")
            XCTAssertEqual(
                nestedResult.expressions.values.map(\.source),
                ["nestedRealMath"],
                "line ending: \(lineEnding.debugDescription)")
        }
    }

    func testUnmatchedBacktickCannotPairAcrossParagraphOrFencedBlock() {
        let source = #"""
        Unmatched ` then \(firstMath\).

        ```text
        A single ` and \(fencedLiteral\).
        ```

        After \(secondMath\).
        """#
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertTrue(result.markdown.contains(#"\(fencedLiteral\)"#))
        XCTAssertEqual(
            Set(result.expressions.values.map(\.source)),
            Set(["firstMath", "secondMath"]))
    }

    func testMathInsideEveryCommonMarkCodeBlockShapeIsNeverIntercepted() {
        let source = #"""
            \(indentedCode\)

        > ```swift
        > let nested = "\(blockquoteCode\)"
        > ```not-a-close
        > \(stillBlockquoteCode\)
        > ```

        Outside \(realMath\).
        """#
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertTrue(result.markdown.contains(#"\(indentedCode\)"#))
        XCTAssertTrue(result.markdown.contains(#"\(blockquoteCode\)"#))
        XCTAssertTrue(result.markdown.contains(#"\(stillBlockquoteCode\)"#))
        XCTAssertEqual(result.expressions.count, 1)
        XCTAssertEqual(result.expressions.values.first?.source, "realMath")
    }

    func testCodeBlockRangesProtectMathAcrossEveryCommonMarkLineEnding() {
        for lineEnding in ["\n", "\r", "\r\n"] {
            let source = [
                "```swift",
                #"let literal = "\(notMath\)""#,
                "```",
                #"Outside \(realMath\)."#,
            ].joined(separator: lineEnding)
            let result = IntatisMathDelimiterAdapter.transform(source)

            XCTAssertFalse(result.exceededLimits, "line ending: \(lineEnding.debugDescription)")
            XCTAssertTrue(
                result.markdown.contains(#"\(notMath\)"#),
                "line ending: \(lineEnding.debugDescription)")
            XCTAssertEqual(
                result.expressions.values.map(\.source),
                ["realMath"],
                "line ending: \(lineEnding.debugDescription)")
        }
    }

    func testStandaloneDisplayMathRecognizesEveryCommonMarkLineEnding() {
        for lineEnding in ["\n", "\r", "\r\n"] {
            let source = "before\(lineEnding)\\[x + 1\\]\(lineEnding)after"
            let result = IntatisMathDelimiterAdapter.transform(source)

            XCTAssertFalse(result.exceededLimits, "line ending: \(lineEnding.debugDescription)")
            XCTAssertEqual(
                result.expressions.values.map(\.source),
                ["x + 1"],
                "line ending: \(lineEnding.debugDescription)")
            XCTAssertTrue(
                result.markdown.contains("intatis-math://display/"),
                "line ending: \(lineEnding.debugDescription)")
        }
    }

    func testEscapedMathOpenersAndClosersRemainLiteral() {
        let source = #"Escaped \\(literal\) then \(x + \\) + 1\)."#
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertTrue(result.markdown.contains(#"\\(literal\)"#))
        XCTAssertEqual(result.expressions.count, 1)
        XCTAssertEqual(result.expressions.values.first?.source, #"x + \\) + 1"#)
    }

    func testDisplayMathInsideMarkdownContainersRemainsLiteral() {
        let source = #"""
        - derivation:
          \[nestedListFormula\]
          next

        > $$blockquoteFormula$$

        \[topLevelFormula\]
        """#
        let result = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertTrue(result.markdown.contains(#"\\[nestedListFormula\\]"#))
        XCTAssertTrue(result.markdown.contains(#"$$blockquoteFormula$$"#))
        XCTAssertEqual(result.expressions.count, 1)
        XCTAssertEqual(result.expressions.values.first?.source, "topLevelFormula")
    }

    func testUnclosedAndInvalidMathRemainCopyableSource() {
        let invalid = #"Invalid \(\notARealCommand{x}\) and unclosed \(x + 1"#
        let result = IntatisMathDelimiterAdapter.transform(invalid)

        XCTAssertEqual(result.markdown, #"Invalid \\(\notARealCommand{x}\\) and unclosed \\(x + 1"#)
        XCTAssertTrue(result.expressions.isEmpty)
    }

    func testStreamingFormulaContentChangesInternalImageIdentity() {
        let first = IntatisMathDelimiterAdapter.transform(#"Value \(x\)."#)
        let second = IntatisMathDelimiterAdapter.transform(#"Value \(y\)."#)

        XCTAssertNotEqual(first.markdown, second.markdown)
        XCTAssertNotEqual(Set(first.expressions.keys), Set(second.expressions.keys))
        XCTAssertEqual(first.expressions.values.first?.source, "x")
        XCTAssertEqual(second.expressions.values.first?.source, "y")
    }

    func testSoleInlineFormulaRoutesThroughBlockImageProviderAsMath() throws {
        let transformed = IntatisMathDelimiterAdapter.transform(#"\(x + 1\)"#)
        let entry = try XCTUnwrap(transformed.expressions.first)
        let url = try XCTUnwrap(URL(string: "intatis-math://\(entry.key)"))

        XCTAssertEqual(
            IntatisMathURL.route(for: url, in: transformed.expressions),
            .inline(entry.value))
    }

    func testRenderedDocumentAlwaysRetainsRawTruth() {
        let source = #"**Markdown** plus \(a^2+b^2=c^2\)"#
        let document = IntatisRenderDocumentBuilder.build(
            rawText: source,
            cacheCompletedResult: true)

        XCTAssertEqual(document.rawText, source)
        XCTAssertNotNil(document.markdownText)
        XCTAssertEqual(document.mathExpressions.count, 1)
    }

    func testOversizedMessagesFailClosedToPlainText() {
        let source = String(
            repeating: "x",
            count: IntatisRenderDocumentBuilder.maximumRichTextBytes + 1)
        let document = IntatisRenderDocumentBuilder.build(
            rawText: source,
            cacheCompletedResult: false)

        XCTAssertEqual(document, .plain(source))
    }

    func testFormulaOccurrenceLimitFailsClosedToPlainText() {
        let source = String(
            repeating: #"\(x\) "#,
            count: IntatisRenderDocumentBuilder.maximumFormulaCount + 1)
        let transformed = IntatisMathDelimiterAdapter.transform(source)
        let document = IntatisRenderDocumentBuilder.build(
            rawText: source,
            cacheCompletedResult: false)

        XCTAssertTrue(transformed.exceededLimits)
        XCTAssertEqual(transformed.markdown, source)
        XCTAssertEqual(document, .plain(source))
    }

    func testRepeatedUnclosedOpenersRemainBoundedLiteralSource() {
        let source = String(repeating: #"\( "#, count: 4_096)
        let transformed = IntatisMathDelimiterAdapter.transform(source)

        XCTAssertFalse(transformed.exceededLimits)
        XCTAssertTrue(transformed.expressions.isEmpty)
        XCTAssertEqual(transformed.markdown.filter { $0 == "(" }.count, 4_096)
    }

    func testIncreasingUnmatchedBacktickRunsAreScannedInBoundedTime() {
        let runs = (1...1_000)
            .map { String(repeating: "`", count: $0) + "x" }
            .joined(separator: " ")
        let source = #"\("# + runs
        XCTAssertLessThan(source.utf8.count, IntatisRenderDocumentBuilder.maximumRichTextBytes)

        let clock = ContinuousClock()
        let started = clock.now
        let transformed = IntatisMathDelimiterAdapter.transform(
            source,
            protectedRanges: [])
        let elapsed = started.duration(to: clock.now)

        XCTAssertFalse(transformed.exceededLimits)
        XCTAssertTrue(transformed.expressions.isEmpty)
        XCTAssertTrue(transformed.markdown.hasSuffix(runs))
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testMarkdownComplexityGateAllows128BreaksAndRejects129() {
        let atLimit = (0...128)
            .map { "line \($0)" }
            .joined(separator: "\n")
        let overLimit = (0...129)
            .map { "line \($0)" }
            .joined(separator: "\n")
        let knownCrashShape = (0..<500)
            .map { "line \($0)" }
            .joined(separator: "\n")
        let allowed = IntatisRenderDocumentBuilder.build(
            rawText: atLimit,
            cacheCompletedResult: false)
        let rejected = IntatisRenderDocumentBuilder.build(
            rawText: overLimit,
            cacheCompletedResult: false)
        let rejectedKnownCrashShape = IntatisRenderDocumentBuilder.build(
            rawText: knownCrashShape,
            cacheCompletedResult: false)

        XCTAssertNotNil(allowed.markdownContent)
        XCTAssertEqual(rejected, .plain(overLimit))
        XCTAssertEqual(rejectedKnownCrashShape, .plain(knownCrashShape))
    }

    func testMarkdownComplexityGateAllowsEightListLevelsAndRejectsNine() {
        func nestedList(levels: Int) -> String {
            (0..<levels).map { depth in
                let marker = depth.isMultiple(of: 2) ? "- " : "1. "
                return String(repeating: "    ", count: depth) + marker + "level \(depth)"
            }
            .joined(separator: "\n")
        }

        let atLimit = nestedList(levels: 8)
        let overLimit = nestedList(levels: 9)
        let allowed = IntatisRenderDocumentBuilder.build(
            rawText: atLimit,
            cacheCompletedResult: false)
        let rejected = IntatisRenderDocumentBuilder.build(
            rawText: overLimit,
            cacheCompletedResult: false)

        XCTAssertNotNil(allowed.markdownContent)
        XCTAssertEqual(rejected, .plain(overLimit))
    }

    func testMarkdownComplexityGateRejectsLargeGFMTableAST() {
        let columns = 25
        let header = "| " + (0..<columns).map { "h\($0)" }.joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: "x", count: columns).joined(separator: " | ") + " |"
        let source = ([header, delimiter] + Array(repeating: row, count: 100))
            .joined(separator: "\n")
        let document = IntatisRenderDocumentBuilder.build(
            rawText: source,
            cacheCompletedResult: false)

        XCTAssertEqual(document, .plain(source))
    }

    func testMarkdownComplexityGateRejectsWideInlineTree() {
        let source = (0..<300)
            .map { "*item\($0)*" }
            .joined(separator: " ")
        let document = IntatisRenderDocumentBuilder.build(
            rawText: source,
            cacheCompletedResult: false)

        XCTAssertEqual(document, .plain(source))
    }

    func testMarkdownComplexityGateAllowsOrdinaryGFMContent() {
        let source = #"""
        # Heading

        A short paragraph with **strong**, *emphasis*, and [a link](https://example.com).

        GFM keeps ~~strikethrough~~ and <https://example.com>.

        - one
          - nested
        - [x] completed task

        | Name | Value |
        | --- | ---: |
        | alpha | 1 |
        """#
        let document = IntatisRenderDocumentBuilder.build(
            rawText: source,
            cacheCompletedResult: false)

        XCTAssertEqual(document.rawText, source)
        XCTAssertNotNil(document.markdownText)
        XCTAssertNotNil(document.markdownContent)
    }

    func testMathRasterPolicyRejectsInvalidAndOversizedBitmaps() {
        XCTAssertTrue(IntatisMathRasterPolicy.allows(
            size: CGSize(width: 400, height: 40),
            scale: 2))
        XCTAssertFalse(IntatisMathRasterPolicy.allows(
            size: CGSize(width: 1_025, height: 40),
            scale: 2))
        XCTAssertFalse(IntatisMathRasterPolicy.allows(
            size: CGSize(width: CGFloat.infinity, height: 40),
            scale: 1))
    }

    func testCodeLanguageAliasesAndUnknownLanguageHandling() {
        XCTAssertEqual(IntatisCodeLanguage.normalize(" Swift "), "swift")
        XCTAssertEqual(IntatisCodeLanguage.normalize("js"), "javascript")
        XCTAssertEqual(IntatisCodeLanguage.normalize("C++"), "cpp")
        XCTAssertEqual(IntatisCodeLanguage.normalize("zsh"), "bash")
        XCTAssertEqual(IntatisCodeLanguage.normalize("future-lang"), "future-lang")
        XCTAssertNil(IntatisCodeLanguage.normalize("  "))
        XCTAssertNil(IntatisCodeLanguage.normalize(nil))
    }

    @MainActor
    func testBundledHighlightJSEngineReturnsTheExactSource() async {
        let source = "for index in 0..<3 { print(index) }"
        let result = await IntatisSyntaxHighlightingService.shared.highlight(
            source,
            language: "swift",
            colorScheme: .light)

        XCTAssertNotNil(result)
        XCTAssertEqual(result.map { String($0.characters) }, source)
    }

    @MainActor
    func testAffectedCGrammarsFailClosedToPlaintext() async {
        for language in ["c", "cpp"] {
            let result = await IntatisSyntaxHighlightingService.shared.highlight(
                "int main(void) { while (1) {} }",
                language: language,
                colorScheme: .light)
            XCTAssertNil(result, "\(language) must remain plaintext until upstream issue #4362 is fixed")
        }
    }

    func testHighlightAndRenderKeysCannotCollideAcrossFieldBoundaries() {
        let cacheA = IntatisSyntaxHighlightCacheKey(
            theme: "a11y-light",
            language: "swift",
            source: "foo:bar")
        let cacheB = IntatisSyntaxHighlightCacheKey(
            theme: "a11y-light",
            language: "swift:foo",
            source: "bar")
        let revisionA = IntatisCodeRenderRevision(
            isDark: false,
            isComplete: true,
            language: "swift",
            source: "foo:bar")
        let revisionB = IntatisCodeRenderRevision(
            isDark: false,
            isComplete: true,
            language: "swift:foo",
            source: "bar")
        let composed = IntatisSyntaxHighlightCacheKey(
            theme: "a11y-light",
            language: "swift",
            source: "caf\u{00E9}")
        let decomposed = IntatisSyntaxHighlightCacheKey(
            theme: "a11y-light",
            language: "swift",
            source: "cafe\u{0301}")

        XCTAssertNotEqual(cacheA, cacheB)
        XCTAssertNotEqual(revisionA, revisionB)
        XCTAssertNotEqual(composed, decomposed)
    }
}
#endif
