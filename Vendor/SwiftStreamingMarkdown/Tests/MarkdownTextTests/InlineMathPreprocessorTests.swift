// Intatis derivative validation. This file is not from upstream v0.6.0.

import Markdown
@testable import SwiftStreamingMarkdown
import XCTest

final class InlineMathPreprocessorTests: XCTestCase {
  private func preprocess(
    _ source: String,
    namespace: String = "TESTNAMESPACE"
  ) -> InlineMathPreprocessor.Output? {
    InlineMathPreprocessor.preprocess(
      source: source,
      protectedUTF8Ranges: [],
      config: .latex,
      namespace: namespace
    )
  }

  func testDelimiterMatrixAcceptsCommonInlineAndDisplaySyntax() {
    let cases: [
      (
        source: String,
        formula: String,
        literal: String,
        presentation: MathPresentation
      )
    ] = [
      ("$x$", "x", "$x$", .inline),
      (#"\( x_i \)"#, "x_i", #"\( x_i \)"#, .inline),
      (
        #"$$\frac{a}{b}$$"#,
        #"\frac{a}{b}"#,
        #"$$\frac{a}{b}$$"#,
        .display
      ),
      (#"\[E=mc^2\]"#, "E=mc^2", #"\[E=mc^2\]"#, .display),
      ("中文🙂 $E=mc^2$ 后缀", "E=mc^2", "$E=mc^2$", .inline),
      (#"$x\$y$"#, #"x\$y"#, #"$x\$y$"#, .inline)
    ]

    for item in cases {
      let output = preprocess(item.source)
      XCTAssertEqual(output?.catalog.entries.count, 1, item.source)
      XCTAssertEqual(output?.catalog.entries.first?.source, item.formula)
      XCTAssertEqual(
        output?.catalog.entries.first?.originalLiteral,
        item.literal
      )
      XCTAssertEqual(
        output?.catalog.entries.first?.presentation,
        item.presentation
      )
    }
  }

  func testDelimiterMatrixKeepsCurrencyEscapesAndMalformedPairsLiteral() {
    let cases = [
      #"\$x$"#,
      "$29.99",
      "$5 and $10",
      "$$",
      "$ x $",
      "$x",
      "x$",
      "$x$1",
      "$x\nx$",
      #"\\(x\)"#,
      #"\(x"#,
      #"\[x"#,
      "$$x"
    ]

    for source in cases {
      XCTAssertNil(preprocess(source), source)
    }
  }

  func testDisplayDelimitersMaySpanLines() {
    let source = #"""
    $$
    \frac{
      a
    }{b}
    $$

    \[
    x^2 + y^2
    \]
    """#
    let output = preprocess(source)
    let multilineFormula = #"""
    \frac{
      a
    }{b}
    """#

    XCTAssertEqual(
      output?.catalog.entries.map(\.source),
      [multilineFormula, "x^2 + y^2"]
    )
    XCTAssertEqual(
      output?.catalog.entries.map(\.presentation),
      [.display, .display]
    )
  }

  func testUnicodeIndicesAndProtectedRangesRemainByteSafe() {
    let source = "🙂前 `$code$` 中 $向量_α$ 后"
    let document = Document(parsing: source)
    let output = InlineMathPreprocessor.preprocess(
      source: source,
      document: document,
      config: .latex
    )

    XCTAssertEqual(output?.catalog.entries.map(\.source), ["向量_α"])
    XCTAssertTrue(output?.transformedSource.contains("`$code$`") == true)
    XCTAssertFalse(output?.transformedSource.contains("$向量_α$") == true)

    let crlfSource = "🙂 $a$\r\n`$code$`\r\n$y$"
    let crlfOutput = InlineMathPreprocessor.preprocess(
      source: crlfSource,
      document: Document(parsing: crlfSource),
      config: .latex
    )
    XCTAssertEqual(crlfOutput?.catalog.entries.map(\.source), ["a", "y"])
    XCTAssertTrue(crlfOutput?.transformedSource.contains("`$code$`") == true)
  }

  func testASTCodeRangesProtectInlineFencedIndentedAndNestedCode() {
    let source = #"""
    outside $a$

    `$inline$` and ``$multi$``

    ```swift
    let value = "$fenced$"
    ```

    ~~~
    $tilde$
    ~~~

        $indented$

    > `$quoted$`

    - `$listed$`

    outside $b$
    """#
    let document = Document(parsing: source)
    let output = InlineMathPreprocessor.preprocess(
      source: source,
      document: document,
      config: .latex
    )

    XCTAssertEqual(output?.catalog.entries.map(\.source), ["a", "b"])
    for literal in [
      "`$inline$`",
      "``$multi$``",
      #""$fenced$""#,
      "$tilde$",
      "$indented$",
      "`$quoted$`",
      "`$listed$`"
    ] {
      XCTAssertTrue(output?.transformedSource.contains(literal) == true)
    }
  }

  func testLinkImageAutolinkAndRawHTMLRangesStayLiteralWhileNearbyMathRenders() {
    let cases: [(name: String, source: String, protectedLiteral: String)] = [
      (
        "link destination",
        "[link](https://e.test/$x$) and $y$",
        "https://e.test/$x$"
      ),
      (
        "image destination",
        "![alt](https://e.test/$x$) and $y$",
        "https://e.test/$x$"
      ),
      (
        "autolink",
        "<https://e.test/$x$> and $y$",
        "<https://e.test/$x$>"
      ),
      (
        "inline raw HTML",
        #"<span data-formula="$x$">raw</span> and $y$"#,
        #"data-formula="$x$""#
      ),
      (
        "raw HTML block",
        """
        <div>
        $x$
        </div>

        nearby $y$
        """,
        "$x$"
      )
    ]

    for item in cases {
      let document = Document(parsing: item.source)
      let output = InlineMathPreprocessor.preprocess(
        source: item.source,
        document: document,
        config: .latex
      )
      XCTAssertEqual(
        output?.catalog.entries.map(\.source),
        ["y"],
        item.name
      )
      XCTAssertTrue(
        output?.transformedSource.contains(item.protectedLiteral) == true,
        item.name
      )
    }
  }

  func testUnclosedFenceIsProtectedAndUnmatchedBacktickCannotSwallowMathToken() {
    let unclosedFence = """
    ```swift
    let value = "$inside$"
    """
    let fencedDocument = Document(parsing: unclosedFence)
    XCTAssertNil(
      InlineMathPreprocessor.preprocess(
        source: unclosedFence,
        document: fencedDocument,
        config: .latex
      )
    )

    let unmatchedBacktick = "unmatched ` marker then $outside$"
    let unmatchedDocument = Document(parsing: unmatchedBacktick)
    let output = InlineMathPreprocessor.preprocess(
      source: unmatchedBacktick,
      document: unmatchedDocument,
      config: .latex
    )
    XCTAssertEqual(output?.catalog.entries.map(\.source), ["outside"])

    guard let output else {
      return XCTFail("Expected an accepted formula")
    }
    let reparsed = Document(parsing: output.transformedSource)
    XCTAssertTrue(
      reparsed.format().contains(output.catalog.token(at: 0)),
      "The parser-safe token must remain text even after an unmatched backtick"
    )
  }

  func testFormulaSourceHasNoIntatisByteAdmissionCap() {
    let formula = String(repeating: "x", count: 12 * 1_024)
    let output = preprocess("$\(formula)$")

    XCTAssertEqual(output?.catalog.entries.count, 1)
    XCTAssertEqual(output?.catalog.entries.first?.source, formula)
  }

  func testFormulaCountHasNoLegacyThirtyTwoAdmissionCap() {
    let count = 64
    let source = (0..<count)
      .map { "$x_{\($0)}$" }
      .joined(separator: " ")
    let output = preprocess(source)

    XCTAssertEqual(output?.catalog.entries.count, count)
  }

  func testRequestNamespacesDoNotResolveTokensAcrossCatalogs() {
    guard let first = preprocess("$x$", namespace: "FIRST"),
          let second = preprocess("$y$", namespace: "SECOND")
    else {
      return XCTFail("Expected both requests to produce catalogs")
    }

    XCTAssertNotEqual(first.catalog.token(at: 0), second.catalog.token(at: 0))
    XCTAssertNil(
      second.catalog.attributedString(
        replacingTokensIn: first.catalog.token(at: 0),
        attributes: [:]
      )
    )

    let sourceContainingOldToken =
      "\(first.catalog.token(at: 0)) and $z$"
    guard let third = preprocess(
      sourceContainingOldToken,
      namespace: "THIRD"
    ) else {
      return XCTFail("Expected the new formula to be accepted")
    }
    XCTAssertTrue(
      third.transformedSource.contains(first.catalog.token(at: 0))
    )
    XCTAssertEqual(third.catalog.entries.map(\.source), ["z"])
  }

  func testInvalidProtectedRangeAndMissingASTSourceRangeFailClosed() {
    XCTAssertNil(
      InlineMathPreprocessor.preprocess(
        source: "$x$",
        protectedUTF8Ranges: [0..<100],
        config: .latex,
        namespace: "INVALID"
      )
    )

    let constructed = Document(Paragraph(InlineCode("$x$")))
    XCTAssertNil(
      InlineMathPreprocessor.protectedLiteralRanges(
        in: constructed,
        source: "$x$"
      )
    )
    XCTAssertNil(
      InlineMathPreprocessor.preprocess(
        source: "$x$",
        document: constructed,
        config: .latex
      )
    )
  }

  func testDisabledAndNoDelimiterFastPathsProduceNoCatalog() {
    let ordinary = "A paragraph with **bold**, `code`, and no math."
    XCTAssertFalse(
      InlineMathPreprocessor.mightContainMathDelimiter(ordinary)
    )
    XCTAssertFalse(
      InlineMathPreprocessor.mightContainMathDelimiter(#"\$x\$"#)
    )
    XCTAssertNil(
      InlineMathPreprocessor.preprocess(
        source: "$x$",
        document: Document(parsing: "$x$"),
        config: .disabled
      )
    )
  }
}
