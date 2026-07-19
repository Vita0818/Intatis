// Intatis derivative validation. This file is not from upstream v0.6.0.

import Foundation
import SwiftUI
@testable import SwiftStreamingMarkdown
import XCTest
#if os(macOS)
import AppKit
#endif

final class CandidatePhase2MatrixTests: XCTestCase {
  @MainActor
  private func parse(
    _ name: String,
    input: String,
    config: sending MarkdownRenderConfig = MarkdownRenderConfig()
  ) async -> RenderableDocument {
    let clock = ContinuousClock()
    let started = clock.now
    let document = await MarkdownDocumentParser.parse(text: input, config: config)
    let duration = started.duration(to: clock.now).components
    let milliseconds = Double(duration.seconds) * 1_000
      + Double(duration.attoseconds) / 1_000_000_000_000_000
    print(
      "CANDIDATE_PHASE2 name=\(name) bytes=\(input.utf8.count) blocks=\(document.renderables.count) elapsed_ms=\(milliseconds)"
    )
    return document
  }

  private func makeSizedMarkdown(byteCount: Int) -> String {
    precondition(byteCount > 0)
    let unit = "## Deterministic block\n\nParagraph with **bold**, [link](https://example.invalid), and `code`.\n\n"
    let repeated = String(repeating: unit, count: byteCount / unit.utf8.count + 1)
    let result = String(decoding: repeated.utf8.prefix(byteCount), as: UTF8.self)
    precondition(result.utf8.count == byteCount)
    return result
  }

  private func makeManyBlocks(count: Int) -> String {
    (0..<count).map { index in
      "## Block \(index)\n\nParagraph \(index) with **bold** and `inline code`."
    }.joined(separator: "\n\n")
  }

  private func makeCodeBody(byteCount: Int) -> String {
    let line = "value += 1; // deterministic payload\n"
    let repeated = String(repeating: line, count: byteCount / line.utf8.count + 1)
    let result = String(decoding: repeated.utf8.prefix(byteCount), as: UTF8.self)
    precondition(result.utf8.count == byteCount)
    return result
  }

  private func makePlainText(byteCount: Int) -> String {
    let unit = "deterministic plain text payload "
    let repeated = String(repeating: unit, count: byteCount / unit.utf8.count + 1)
    let result = String(decoding: repeated.utf8.prefix(byteCount), as: UTF8.self)
    precondition(result.utf8.count == byteCount)
    return result
  }

  private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  @MainActor
  func testMalformedTablesAndStreamingPrefixesDoNotCrashOrCreateRaggedRows() async {
    let cases: [(String, String)] = [
      ("table_pipes_only", "||||"),
      ("table_well_formed", "| A | B |\n| --- | --- |\n| 1 | 2 |"),
      ("table_more_body_columns", "| A | B |\n| --- | --- |\n| 1 | 2 | 3 |"),
      ("table_fewer_body_columns", "| A | B | C |\n| --- | --- | --- |\n| 1 | 2 |"),
      ("table_missing_separator", "| A | B |\n| 1 | 2 |"),
      ("table_partial_separator", "| A | B |\n| ---"),
      ("table_partial_header", "| A | B |"),
      ("table_partial_body", "| A | B |\n| --- | --- |\n| 1")
    ]

    for (name, input) in cases {
      let document = await parse(name, input: input)
      for renderable in document.renderables {
        if case .table(_, let headers, let rows, _) = renderable {
          XCTAssertTrue(
            rows.allSatisfy { $0.count == headers.count },
            "\(name) produced a ragged renderer row"
          )
        }
      }
    }

    let wellFormed = await parse("table_well_formed_assertions", input: cases[1].1)
    guard case .table(_, let headers, let rows, let rawMarkdown) = wellFormed.renderables.first else {
      return XCTFail("Expected a table for the well-formed case")
    }
    XCTAssertEqual(headers.count, 2)
    XCTAssertEqual(rows.count, 1)
    XCTAssertFalse(rawMarkdown.isEmpty)

    let chunks = ["| A", " | B |\n", "| ---", " | --- |\n", "| 1", " | 2"]
    var cumulative = ""
    for (index, chunk) in chunks.enumerated() {
      cumulative.append(chunk)
      let document = await parse("table_stream_prefix_\(index + 1)", input: cumulative)
      for renderable in document.renderables {
        if case .table(_, let prefixHeaders, let prefixRows, _) = renderable {
          XCTAssertTrue(prefixRows.allSatisfy { $0.count == prefixHeaders.count })
        }
      }
    }
  }

  @MainActor
  func testLatexDelimitersRemainByteExactInsideCode() async {
    let fencedBody = #"""
    let inline = "\(value\)"
    $$code_dollar$$
    \[code_bracket\]
    """#
    let fenced = "```swift\n\(fencedBody)\n```"
    let fencedDocument = await parse("latex_fenced_code_literal", input: fenced)
    guard case .codeBlock(_, let language, let code) = fencedDocument.renderables.first else {
      return XCTFail("Expected fenced code")
    }
    XCTAssertEqual(language, "swift")
    XCTAssertEqual(code, fencedBody + "\n")

    let inlinePayload = #"literal \(value\) and $$money$$ and \[bracket\]"#
    let inlineDocument = await parse("latex_inline_code_literal", input: "`\(inlinePayload)`")
    guard case .paragraph(_, let content) = inlineDocument.renderables.first else {
      return XCTFail("Expected inline-code paragraph")
    }
    XCTAssertEqual(content.string, inlinePayload)
  }

  @MainActor
  func testLargeInputsManyBlocksAndLargeCodePreserveContent() async {
    for size in [100 * 1_024, 256 * 1_024] {
      let input = makeSizedMarkdown(byteCount: size)
      let document = await parse("sized_markdown_\(size)", input: input)
      XCTAssertFalse(document.isEmpty)
      XCTAssertGreaterThan(document.plainText.utf8.count, size / 2)
    }

    let manyBlocks = makeManyBlocks(count: 256)
    let manyBlocksDocument = await parse("many_blocks_256", input: manyBlocks)
    XCTAssertGreaterThanOrEqual(manyBlocksDocument.renderables.count, 256)

    for (name, language, body) in [
      ("code_c", "c", "#include <stdio.h>\nint main(void) { return 0; }"),
      ("code_cpp", "c++", "#include <vector>\nint main() { std::vector<int> v; }"),
      ("code_unknown", "definitely-not-a-language", "alpha beta gamma\n<>&")
    ] {
      let document = await parse(name, input: "```\(language)\n\(body)\n```")
      guard case .codeBlock(_, let parsedLanguage, let parsedCode) = document.renderables.first else {
        return XCTFail("Expected code block for \(name)")
      }
      XCTAssertEqual(parsedLanguage, language)
      XCTAssertEqual(parsedCode, body + "\n")
    }

    let largeBody = makeCodeBody(byteCount: 70 * 1_024)
    let largeDocument = await parse(
      "code_unknown_71680_byte_body",
      input: "```definitely-not-a-language\n\(largeBody)\n```"
    )
    guard case .codeBlock(_, let language, let code) = largeDocument.renderables.first else {
      return XCTFail("Expected large code block")
    }
    XCTAssertEqual(language, "definitely-not-a-language")
    XCTAssertEqual(code, largeBody + "\n")
  }

  @MainActor
  func testRequestedImagesStayDisabledInProductionParser() async {
    let cases = [
      ("image_https", "![alt](https://example.invalid/a.png)"),
      ("image_http", "![alt](http://example.invalid/a.png)"),
      ("image_file", "![alt](file:///tmp/a.png)"),
      ("image_data", "![alt](data:image/png;base64,AA==)"),
      ("image_custom", "![alt](custom://example/a.png)"),
      ("image_asset", "![alt](assets://Images/logo)"),
      ("image_relative", "![alt](folder/logo.png)")
    ]

    for (name, input) in cases {
      let requested = MarkdownRenderConfig(
        imageConfig: ImageConfig(
          enabled: true,
          allowedImageTypes: [
            .remote(allowedDomains: ["example.invalid"]),
            .assetCatalog,
            .bundledResource
          ],
          fullscreenViewerEnabled: true
        )
      )
      let document = await parse(name, input: input, config: requested)
      XCTAssertFalse(document.renderables.contains { renderable in
        if case .image = renderable { return true }
        return false
      })
    }
  }

  @MainActor
  func testLinkSchemeMatrix() async {
    let input = "[http](http://example.invalid/a) [https](https://example.invalid/b) [mail](mailto:user@example.invalid) [custom](myapp://open/item) [file](file:///tmp/example.txt) [data](data:text/plain,hello)"
    let document = await parse("link_schemes", input: input)
    let links = document.attributedStrings.flatMap { attributed -> [String] in
      var result: [String] = []
      attributed.enumerateAttribute(
        .link,
        in: NSRange(location: 0, length: attributed.length)
      ) { value, _, _ in
        if let url = value as? URL {
          result.append(url.absoluteString)
        }
      }
      return result
    }
    XCTAssertEqual(links.count, 6)
    XCTAssertEqual(Set(links).count, 6)
  }

  #if os(macOS)
  @MainActor
  private func fittingSizeForHost(input: String, name: String) async -> CGSize {
    let renderable = await parse(name, input: input)
    let displayConfig = MarkdownRenderConfig()
    let root = ScrollView {
      DocumentView(renderableDocument: renderable, config: displayConfig)
    }
    .frame(width: 640, height: 700)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 640, height: 700)
    host.layoutSubtreeIfNeeded()
    let fittingSize = host.fittingSize
    await Task.yield()
    return fittingSize
  }

  @MainActor
  func testUIHostPlain100K() async {
    let name = "ui_host_100k_plain"
    let size = await fittingSizeForHost(
      input: makeSizedMarkdown(byteCount: 100 * 1_024),
      name: name
    )
    XCTAssertGreaterThan(size.width, 0, name)
    XCTAssertGreaterThan(size.height, 0, name)
  }

  @MainActor
  func testUIHostPlain256K() async {
    let name = "ui_host_256k_plain"
    let size = await fittingSizeForHost(
      input: makeSizedMarkdown(byteCount: 256 * 1_024),
      name: name
    )
    XCTAssertGreaterThan(size.width, 0, name)
    XCTAssertGreaterThan(size.height, 0, name)
  }

  @MainActor
  func testUIHostCode71680() async {
    let name = "ui_host_71680_code"
    let size = await fittingSizeForHost(
      input: "```definitely-not-a-language\n\(makeCodeBody(byteCount: 70 * 1_024))\n```",
      name: name
    )
    XCTAssertGreaterThan(size.width, 0, name)
    XCTAssertGreaterThan(size.height, 0, name)
  }

  @MainActor
  func testWholeMessagePlainTextAdmissionTimings() async {
    let clock = ContinuousClock()
    _ = await fittingSizeForHost(
      input: makePlainText(byteCount: 1_024),
      name: "admission_warmup_not_measured"
    )
    for kibibytes in [16, 32, 48, 64, 96] {
      let input = makePlainText(byteCount: kibibytes * 1_024)
      var samples: [Double] = []
      for run in 1...3 {
        let started = clock.now
        let size = await fittingSizeForHost(
          input: input,
          name: "admission_plain_\(kibibytes)k_run_\(run)"
        )
        samples.append(milliseconds(started.duration(to: clock.now)))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
      }
      let ordered = samples.sorted()
      let median = ordered[1]
      let maximum = ordered[2]
      print(
        "CANDIDATE_ADMISSION plain_kib=\(kibibytes) runs_ms=\(samples) median_ms=\(median) max_ms=\(maximum)"
      )
    }
  }

  @MainActor
  func testUIHostLifecycleAppearanceAndResize() async {
    let input = """
    # UI lifecycle smoke

    Paragraph with **bold**, `inline`, and [link](https://example.invalid).

    | A | B |
    | --- | --- |
    | 1 | 2 |

    ```swift
    let value = 42
    ```
    """
    let renderable = await parse("ui_lifecycle_parse", input: input)
    var nonZeroFittingSizes = 0
    for iteration in 0..<20 {
      autoreleasepool {
        let scheme: ColorScheme = iteration.isMultiple(of: 2) ? .light : .dark
        let width = [320.0, 640.0, 900.0][iteration % 3]
        let displayConfig = MarkdownRenderConfig()
        let root = DocumentView(renderableDocument: renderable, config: displayConfig)
          .environment(\.colorScheme, scheme)
          .frame(width: width)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        host.layoutSubtreeIfNeeded()
        if host.fittingSize.width > 0, host.fittingSize.height > 0 {
          nonZeroFittingSizes += 1
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
        }
      }
      await Task.yield()
    }
    XCTAssertEqual(nonZeroFittingSizes, 20)
  }
  #endif
}
