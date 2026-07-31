// Intatis derivative validation. This file is not from upstream v0.6.0.

import Foundation
import Markdown
@testable import SwiftStreamingMarkdown
import XCTest

final class InlineMathParserTests: XCTestCase {
  func testConcurrentRequestLocalMathParsesDoNotShareCatalogs() async {
    let outcomes = await withTaskGroup(
      of: Bool.self,
      returning: [Bool].self
    ) { group in
      for index in 0..<64 {
        group.addTask {
          let source = "$x_{\(index)}$"
          let document = await MarkdownDocumentParser.parse(
            text: source,
            config: MarkdownRenderConfig(mathConfig: .latex)
          )
          let attachmentCount = document.attributedStrings.reduce(into: 0) {
            count, string in
            string.enumerateAttribute(
              .attachment,
              in: NSRange(location: 0, length: string.length)
            ) { value, _, _ in
              if value is InlineMathAttachment {
                count += 1
              }
            }
          }
          return document.plainText == source && attachmentCount == 1
        }
      }

      var values: [Bool] = []
      for await outcome in group {
        values.append(outcome)
      }
      return values
    }

    XCTAssertEqual(outcomes.count, 64)
    XCTAssertTrue(outcomes.allSatisfy { $0 })
  }

  func testPublicLowLevelParseOptionAlwaysDisablesMath() {
    let option = MarkdownParseOption(
      speculativeRewrite: false,
      imageSupport: true
    )

    XCTAssertTrue(option.imageSupport)
    XCTAssertEqual(option.mathConfig, .disabled)
  }

  func testParserCatalogProtectsFormulaMarkdownMetacharacters() {
    let source = #"before $\vec{x}_i * y^{2}$ after"#
    let parser = MarkdownParserImpl()
    let result = parser.parseSynchronously(
      text: source,
      option: .init(
        speculativeRewrite: false,
        mathConfig: .latex
      )
    )

    XCTAssertEqual(
      result.inlineMathCatalog?.entries.map(\.source),
      [#"\vec{x}_i * y^{2}"#]
    )
    XCTAssertEqual(
      result.inlineMathCatalog?.entries.map(\.originalLiteral),
      [#"$\vec{x}_i * y^{2}$"#]
    )
  }

  func testParserCatalogCarriesAllSupportedDelimiterPresentations() {
    let source =
      #"inline \(x\), dollar $y$, display $$z$$, bracket \[w\]"#
    let result = MarkdownParserImpl().parseSynchronously(
      text: source,
      option: .init(
        speculativeRewrite: false,
        mathConfig: .latex
      )
    )

    XCTAssertEqual(
      result.inlineMathCatalog?.entries.map(\.source),
      ["x", "y", "z", "w"]
    )
    XCTAssertEqual(
      result.inlineMathCatalog?.entries.map(\.presentation),
      [.inline, .inline, .display, .display]
    )
    XCTAssertEqual(
      result.inlineMathCatalog?.entries.map(\.originalLiteral),
      [#"\(x\)"#, "$y$", "$$z$$", #"\[w\]"#]
    )
  }

  func testParserDisabledAndRejectedCandidatesRetainFirstAST() {
    let parser = MarkdownParserImpl()
    for (source, config) in [
      ("ordinary **Markdown**", MathRenderConfig.latex),
      ("price is $29.99", MathRenderConfig.latex),
      ("formula $x$", MathRenderConfig.disabled)
    ] {
      let result = parser.parseSynchronously(
        text: source,
        option: .init(
          speculativeRewrite: false,
          mathConfig: config
        )
      )
      XCTAssertNil(result.inlineMathCatalog)
      XCTAssertEqual(
        result.document.format(),
        Markdown.Document(parsing: source).format()
      )
    }
  }

  func testParserCarriesCatalogThroughSpeculativeRewrite() {
    let parser = MarkdownParserImpl()
    let result = parser.parseSynchronously(
      text: "## Partial **heading with $x_i$",
      option: .init(
        speculativeRewrite: true,
        mathConfig: .latex
      )
    )

    XCTAssertTrue(result.speculativeRewritten)
    XCTAssertEqual(result.inlineMathCatalog?.entries.map(\.source), ["x_i"])
  }

  func testParserFindsMathAcrossSupportedMarkdownBlockContexts() {
    let source = #"""
    # Heading $h^2$

    **Strong before $s_i$ after**

    - List $l_1$

    > Quote $\vec{q}$

    | Name | Value |
    | --- | --- |
    | row | $t_{0}$ |
    """#
    let parser = MarkdownParserImpl()
    let result = parser.parseSynchronously(
      text: source,
      option: .init(
        speculativeRewrite: false,
        mathConfig: .latex
      )
    )

    XCTAssertEqual(
      result.inlineMathCatalog?.entries.map(\.source),
      ["h^2", "s_i", "l_1", #"\vec{q}"#, "t_{0}"]
    )
  }

  @MainActor
  func testRenderableUsesAttachmentAndRestoresOriginalPlainText() async {
    let source = "Value $x_i$ after."
    let document = await MarkdownDocumentParser.parse(
      text: source,
      config: MarkdownRenderConfig(
        mathConfig: .latex
      )
    )

    guard case .paragraph(_, let content) = document.renderables.first else {
      return XCTFail("Expected a paragraph")
    }
    XCTAssertEqual(content.plainTextRestoringInlineMath, source)
    var attachmentCount = 0
    content.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: content.length)
    ) { value, _, _ in
      if value is InlineMathAttachment {
        attachmentCount += 1
      }
    }
    XCTAssertEqual(attachmentCount, 1)
  }

  @MainActor
  func testRenderableMaterializesMathAcrossStructuredBlocksWithoutTokenLeak() async {
    let source = #"""
    # Heading $h^2$

    - List $l_1$

    > Quote $\vec{q}$

    | Header $c_h$ | Value |
    | --- | --- |
    | body | $c_b$ |
    """#
    let document = await MarkdownDocumentParser.parse(
      text: source,
      config: MarkdownRenderConfig(mathConfig: .latex)
    )

    var attachmentCounts: [String: Int] = [:]
    for renderable in document.renderables {
      let label: String
      switch renderable {
      case .heading:
        label = "heading"
      case .unorderedList:
        label = "list"
      case .blockQuote:
        label = "blockquote"
      case .table:
        label = "table"
      default:
        continue
      }
      let strings = renderable.extractAttributedStrings()
      attachmentCounts[label] = strings.reduce(0) {
        $0 + inlineMathAttachmentCount(in: $1)
      }
      XCTAssertFalse(
        strings.contains(where: containsInlineMathCatalogSentinel),
        "\(label) leaked a request-local parser token"
      )
    }

    XCTAssertEqual(attachmentCounts["heading"], 1)
    XCTAssertEqual(attachmentCounts["list"], 1)
    XCTAssertEqual(attachmentCounts["blockquote"], 1)
    XCTAssertEqual(attachmentCounts["table"], 2)
    XCTAssertTrue(document.plainText.contains("$h^2$"))
    XCTAssertTrue(document.plainText.contains("$l_1$"))
    XCTAssertTrue(document.plainText.contains(#"$\vec{q}$"#))
    XCTAssertTrue(document.plainText.contains("$c_h$"))
    XCTAssertTrue(document.plainText.contains("$c_b$"))
  }

  @MainActor
  func testTableMathCapturesFinalHeaderAndBodyForegroundColors() async {
    let config = MarkdownRenderConfig(mathConfig: .latex)
    let expectedHeaderColor = MDColor(config.tableStyle.headerTextColor)
    let expectedBodyColor = MDColor(config.tableStyle.regularTextColor)
    let document = await MarkdownDocumentParser.parse(
      text: """
      | $h$ |
      | --- |
      | $b$ |
      """,
      config: config
    )

    guard case .table(_, let headers, let rows, _) = document.renderables.first,
          let header = headers.first,
          let body = rows.first?.first,
          let headerAttachment = firstInlineMathAttachment(in: header),
          let bodyAttachment = firstInlineMathAttachment(in: body) else {
      return XCTFail("Expected table header and body math attachments")
    }

    XCTAssertEqual(
      headerAttachment.textColor,
      expectedHeaderColor
    )
    XCTAssertEqual(
      bodyAttachment.textColor,
      expectedBodyColor
    )
  }

  @MainActor
  func testListAccessibilityUsesLocalizedMathDescriptionInsteadOfRawSource() async {
    let document = await MarkdownDocumentParser.parse(
      text: "- Before $x_i$ after",
      config: MarkdownRenderConfig(mathConfig: .latex)
    )
    guard case .unorderedList(_, let items, _) = document.renderables.first,
          case .paragraph(_, let contents) = items.first?.children.first else {
      return XCTFail("Expected an unordered list paragraph")
    }

    let expectedDescription = String.localizedStringWithFormat(
      String.mathFormulaAccessibilityFormat,
      "x_i"
    )
    XCTAssertTrue(
      contents.accessibilityTextDescribingAttachments.contains(
        expectedDescription
      )
    )
    XCTAssertFalse(contents.accessibilityTextDescribingAttachments.contains("$x_i$"))
  }

  @MainActor
  func testMathEnabledParserKeepsCodePayloadsByteExact() async {
    let fencedBody = """
    let template = "$x_i$"
    let display = "$$not_math$$"
    """
    let fenced = "```swift\n\(fencedBody)\n```"
    let fencedDocument = await MarkdownDocumentParser.parse(
      text: fenced,
      config: MarkdownRenderConfig(mathConfig: .latex)
    )
    guard case .codeBlock(_, let language, let code) =
      fencedDocument.renderables.first
    else {
      return XCTFail("Expected fenced code")
    }
    XCTAssertEqual(language, "swift")
    XCTAssertEqual(code, fencedBody + "\n")

    let inlinePayload = #"$x_i$ and $$not_math$$"#
    let inlineDocument = await MarkdownDocumentParser.parse(
      text: "`\(inlinePayload)`",
      config: MarkdownRenderConfig(mathConfig: .latex)
    )
    guard case .paragraph(_, let content) =
      inlineDocument.renderables.first
    else {
      return XCTFail("Expected inline code")
    }
    XCTAssertEqual(content.string, inlinePayload)
  }

  @MainActor
  func testMoreThanThirtyTwoFormulasAllMaterialize() async {
    let count = 64
    let formulas = (0..<count)
      .map { "$x_{\($0)}$" }
      .joined(separator: " ")
    let source = "**bold** \(formulas)"
    let document = await MarkdownDocumentParser.parse(
      text: source,
      config: MarkdownRenderConfig(mathConfig: .latex)
    )

    guard case .paragraph(_, let content) = document.renderables.first else {
      return XCTFail("Expected a paragraph")
    }
    XCTAssertEqual(
      content.plainTextRestoringInlineMath,
      "bold \(formulas)"
    )
    var attachmentCount = 0
    content.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: content.length)
    ) { value, _, _ in
      if value is InlineMathAttachment {
        attachmentCount += 1
      }
    }
    XCTAssertEqual(attachmentCount, count)
  }

  func testEveryBuilderPreservesImageMathAndRequestCatalogFields() {
    let image = ImageConfig(
      enabled: true,
      allowedImageTypes: [],
      fullscreenViewerEnabled: false
    )
    let catalog = InlineMathCatalog(
      namespace: "BUILDERS",
      entries: [
        .init(
          source: "x",
          originalLiteral: "$x$",
          presentation: .inline
        )
      ]
    )
    let config = MarkdownRenderConfig(
      imageConfig: image,
      mathConfig: .latex
    ).withInlineMathCatalog(catalog)

    let copies = [
      config.withShouldAnimateText(value: true),
      config.withBlockQuoteStyle(value: config.blockQuoteStyle),
      config.withHeadingStyle(value: config.headingStyle),
      config.withOrderedListStyle(value: config.orderedListStyle),
      config.withParagraphStyle(value: config.paragraphStyle),
      config.withTableStyle(value: config.tableStyle),
      config.withInlineStyle(value: config.inlineStyle),
      config.withTextContextMenu(value: config.textContextMenu),
      config.withBlockSpacing(value: config.blockSpacing + 1),
      config.withCodeBlockConfig(value: config.codeBlockConfig),
      config.withTextSelectionConfig(value: config.textSelectionConfig),
      config.withThematicBreakColor(value: config.thematicBreakColor),
      config.withImageConfig(image),
      config.withMathConfig(.latex)
    ]

    for copy in copies {
      XCTAssertEqual(copy.imageConfig, image)
      XCTAssertEqual(copy.mathConfig, .latex)
      XCTAssertEqual(copy.inlineMathCatalog, catalog)
    }
  }

  func testFirstReleaseProfilePreservesExplicitMathKillSwitch() {
    let enabled = MarkdownRenderConfig(
      mathConfig: .latex
    ).firstReleaseParseConfiguration()
    let disabled = MarkdownRenderConfig(
      mathConfig: .disabled
    ).firstReleaseParseConfiguration()

    XCTAssertEqual(enabled.mathConfig, .latex)
    XCTAssertEqual(disabled.mathConfig, .disabled)
    XCTAssertFalse(enabled.imageConfig.enabled)
    XCTAssertFalse(enabled.citationConfig.isEnabled)
  }

  @MainActor
  private func inlineMathAttachmentCount(
    in attributedString: NSAttributedString
  ) -> Int {
    var result = 0
    attributedString.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: attributedString.length)
    ) { value, _, _ in
      if value is InlineMathAttachment {
        result += 1
      }
    }
    return result
  }

  @MainActor
  private func firstInlineMathAttachment(
    in attributedString: NSAttributedString
  ) -> InlineMathAttachment? {
    var result: InlineMathAttachment?
    attributedString.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: attributedString.length)
    ) { value, _, stop in
      guard let attachment = value as? InlineMathAttachment else { return }
      result = attachment
      stop.pointee = true
    }
    return result
  }

  @MainActor
  private func containsInlineMathCatalogSentinel(
    _ attributedString: NSAttributedString
  ) -> Bool {
    attributedString.string.unicodeScalars.contains {
      $0.value == 0xE000 || $0.value == 0xE001
    }
  }
}
