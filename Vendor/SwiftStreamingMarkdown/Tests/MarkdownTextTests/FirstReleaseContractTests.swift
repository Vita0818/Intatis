import Foundation
@testable import SwiftStreamingMarkdown
import SwiftUI
import XCTest
#if canImport(AppKit)
import AppKit
#endif

// Intatis regression coverage for the narrowed first-release production profile.
final class FirstReleaseContractTests: XCTestCase {
  @MainActor
  func testSendingParserReturnsMainActorOwnedDocument() async {
    let parseOnlyConfig = MarkdownRenderConfig()
    let document = await MarkdownDocumentParser.parse(
      text: "# Heading\n\n| a | b |\n|---|---|\n| 1 | 2 |",
      config: parseOnlyConfig
    )

    XCTAssertFalse(document.isEmpty)
    XCTAssertTrue(document.renderables.contains { renderable in
      if case .table = renderable { return true }
      return false
    })
  }

  func testFirstReleaseParseProfileForcesOptionalFeaturesOff() {
    let base = MarkdownRenderConfig.CitationConfig.default
    let enabledCitation = MarkdownRenderConfig.CitationConfig(
      isEnabled: true,
      coder: base.coder,
      font: base.font,
      textColor: base.textColor,
      backgroundColor: base.backgroundColor
    )
    let requested = MarkdownRenderConfig(
      shouldAnimateText: true,
      citationConfig: enabledCitation,
      imageConfig: ImageConfig(
        enabled: true,
        allowedImageTypes: [.remote(allowedDomains: [])],
        fullscreenViewerEnabled: true
      )
    )

    let safe = requested.firstReleaseParseConfiguration()
    XCTAssertFalse(safe.shouldAnimateText)
    XCTAssertFalse(safe.citationConfig.isEnabled)
    XCTAssertFalse(safe.imageConfig.enabled)
  }

  #if canImport(AppKit)
  @MainActor
  func testConvenienceControllerPreservesCustomParagraphFont() async {
    let font = NSFont.systemFont(ofSize: 31, weight: .semibold)
    let fonts = TextFonts(
      normal: font,
      italic: nil,
      bold: nil,
      boldItalic: nil,
      preferredLetterSpacing: nil,
      preferredLineHeight: nil
    )
    let config = MarkdownRenderConfig(
      paragraphStyle: .init(textFonts: fonts, textColor: .primary)
    )
    let controller = MarkdownViewController(config: config)

    await controller.parse(text: "custom style")

    guard case .paragraph(_, let content) = controller.renderable?.renderables.first else {
      return XCTFail("Expected a rendered paragraph")
    }
    XCTAssertEqual(content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
  }
  #endif

  @MainActor
  func testParagraphViewCacheBudgetIsZero() {
    let first = ParagraphViewCache.shared.createOrReuseView(
      contents: NSMutableAttributedString(string: "first"),
      lineSpacing: nil
    )
    let second = ParagraphViewCache.shared.createOrReuseView(
      contents: NSMutableAttributedString(string: "second"),
      lineSpacing: nil
    )
    XCTAssertFalse(first === second)
  }

  func testCodeCopyControlIsARealButton() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = packageRoot
      .appendingPathComponent("Sources/MarkdownText/UI/CodeBlockView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("Button {"))
    XCTAssertTrue(source.contains(".buttonStyle(.plain)"))
    XCTAssertTrue(source.contains("UIPasteboard.general.string = code"))
    XCTAssertTrue(source.contains("NSPasteboard.general.setString(code, forType: .string)"))
    XCTAssertFalse(source.contains(".onTapGesture"))
  }

  func testSwiftUITextLeavesOwnTheirSelectionWithoutAWholeDocumentOverlay() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let tableSource = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/MarkdownText/UI/TableView.swift"),
      encoding: .utf8
    )
    let codeSource = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/MarkdownText/UI/CodeBlockView.swift"),
      encoding: .utf8
    )
    let documentSource = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/MarkdownText/UI/DocumentView.swift"),
      encoding: .utf8
    )

    XCTAssertEqual(tableSource.components(separatedBy: ".textSelection(.enabled)").count - 1, 2)
    XCTAssertTrue(codeSource.contains(".textSelection(.enabled)"))
    XCTAssertFalse(documentSource.contains(".textSelection(.enabled)"))
  }

  func testSelectMoreSentinelIsBrandNeutral() {
    XCTAssertEqual(
      TextSelectionConfig.selectMoreItemID,
      "SwiftStreamingMarkdown.textSelection.selectMore"
    )
  }
}
