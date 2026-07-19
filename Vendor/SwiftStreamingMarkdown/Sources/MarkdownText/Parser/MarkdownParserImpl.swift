//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown

/// The built-in `MarkdownParser` implementation.
public final class MarkdownParserImpl: MarkdownParser {

  private let rewriters: [MarkupPostParsingRewriter] = [
    PartialStrongMarkupPostParsingRewriter(),
    PartialTableMarkupPostParsingRewriter()
  ]

  private let imageBlockRewriter = ImageBlockMarkupPostParsingRewriter()

  public init() {}

  /// Parse `text` into a `MarkdownParseResult`. See `MarkdownParser.parse(text:option:)`.
  public func parse(text: String, option: MarkdownParseOption) async -> MarkdownParseResult {
    parseSynchronously(text: text, option: option)
  }

  /// Synchronous core used when a caller deliberately keeps the entire parse
  /// and conversion on one actor.
  func parseSynchronously(text: String, option: MarkdownParseOption) -> MarkdownParseResult {
    var result: MarkdownParseResult = MarkdownParseResult(
      document: Document(parsing: text),
      speculativeRewritten: false
    )

    if option.speculativeRewrite {
      for rewriter in rewriters {
        if let rewrittenDoc = rewriter.rewriteIfApplicable(document: result.document) {
          result = MarkdownParseResult(document: rewrittenDoc, speculativeRewritten: true)
        }
      }
    }

    if option.imageSupport {
      if let rewrittenDoc = imageBlockRewriter.rewriteIfApplicable(document: result.document) {
        result = MarkdownParseResult(
          document: rewrittenDoc,
          speculativeRewritten: result.speculativeRewritten
        )
      }
    }
    return result
  }
}
