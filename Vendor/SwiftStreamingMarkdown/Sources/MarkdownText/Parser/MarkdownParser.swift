//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown

/// Parse a given text into a markdown tree, represented by `Document`
public protocol MarkdownParser {

  /// Perform the parsing
  /// - Parameter text: The incoming text
  /// - Parameter option: The option for parsing
  /// - Returns: The parse result
  func parse(text: String, option: MarkdownParseOption) async -> MarkdownParseResult
}

extension MarkdownParser {

  /// Convenience overload that parses `text` with all options disabled and
  /// returns only the parsed `Document`.
  /// - Parameter text: The incoming text
  /// - Returns: The parsed markdown `Document` tree
  public func parse(text: String) async -> Document {
    return await parse(text: text, option: .init(speculativeRewrite: false)).document
  }

  /// Convenience overload that parses `text` and produces a fully laid-out
  /// `RenderableDocument` ready to hand to `DocumentView`.
  /// - Parameters:
  ///   - text: The incoming text.
  ///   - config: Render configuration applied when building the renderable.
  /// - Returns: A `RenderableDocument` built from the parsed `Document`.
  public func parse(text: String, config: MarkdownRenderConfig) async -> RenderableDocument {
    let result = await parse(
      text: text,
      option: .init(
        speculativeRewrite: false,
        imageSupport: config.imageConfig.enabled,
        mathConfig: config.mathConfig
      )
    )
    return await RenderableDocument(
      document: result.document,
      config: config.withInlineMathCatalog(result.inlineMathCatalog)
    )
  }
}

/// The ownership-transfer boundary used by clients that parse away from the
/// main actor and retain the resulting document exclusively in main-actor UI
/// state. The parser is deliberately local to each call: neither it nor the
/// non-Sendable Markdown tree is stored in an actor, task, or async sequence.
public enum MarkdownDocumentParser {
  @concurrent
  public static func parse(
    text: String,
    config: sending MarkdownRenderConfig
  ) async -> sending RenderableDocument {
    let safeConfig = config.firstReleaseParseConfiguration()
    let parser = MarkdownParserImpl()
    let result = parser.parseSynchronously(
      text: text,
      option: .init(
        speculativeRewrite: false,
        imageSupport: false,
        mathConfig: safeConfig.mathConfig
      )
    )
    let resolvedConfig = safeConfig.withInlineMathCatalog(
      result.inlineMathCatalog
    )
    return RenderableDocument(
      renderables: result.document.convert(with: resolvedConfig)
    )
  }

  /// Compatibility path for the package convenience views. It preserves the
  /// caller's complete configuration, but intentionally performs all work on
  /// the main actor. Intatis production streaming uses `parse(text:config:)`
  /// above with its external output-free scheduler instead.
  @MainActor
  static func parseOnMain(
    text: String,
    config: MarkdownRenderConfig
  ) -> RenderableDocument {
    let parser = MarkdownParserImpl()
    let result = parser.parseSynchronously(
      text: text,
      option: .init(
        speculativeRewrite: false,
        imageSupport: config.imageConfig.enabled,
        mathConfig: config.mathConfig
      )
    )
    let resolvedConfig = config.withInlineMathCatalog(
      result.inlineMathCatalog
    )
    return RenderableDocument(
      renderables: result.document.convert(with: resolvedConfig)
    )
  }
}
