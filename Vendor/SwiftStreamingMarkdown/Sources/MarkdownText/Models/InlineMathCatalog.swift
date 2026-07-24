//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: request-local inline-math catalog.
//

import Foundation

/// Request-local mapping between parser-safe tokens and inline math.
///
/// A catalog is created for one parse/conversion only. Its random namespace
/// prevents model text from naming a token that belongs to another request.
struct InlineMathCatalog: Hashable {
  enum Rendering: Hashable {
    case attachment
    case literalOnly
  }

  struct Entry: Hashable {
    /// Formula source without the surrounding `$` delimiters.
    let source: String
    /// Exact source literal, including its original delimiters.
    let originalLiteral: String
    /// Whether conversion may create an attachment for this entry.
    let rendering: Rendering
  }

  private static let tokenStart = "\u{E000}"
  private static let tokenEnd = "\u{E001}"

  let namespace: String
  let entries: [Entry]

  init(namespace: String, entries: [Entry]) {
    precondition(!namespace.isEmpty)
    self.namespace = namespace
    self.entries = entries
  }

  func token(at index: Int) -> String {
    precondition(entries.indices.contains(index))
    return "\(Self.tokenStart)INTATISMATH\(namespace)\(index)\(Self.tokenEnd)"
  }

  /// Replaces exact current-request tokens found in a Markdown text leaf.
  ///
  /// Unknown, stale, partial, or model-authored token-like text is not matched
  /// and therefore remains ordinary text.
  func attributedString(
    replacingTokensIn text: String,
    attributes: NSAttributeContainer
  ) -> NSMutableAttributedString? {
    var matches: [(range: Range<String.Index>, entry: Entry)] = []
    matches.reserveCapacity(entries.count)

    for (index, entry) in entries.enumerated() {
      let token = token(at: index)
      var searchStart = text.startIndex
      while searchStart < text.endIndex,
            let range = text.range(
              of: token,
              range: searchStart..<text.endIndex
            ) {
        matches.append((range, entry))
        searchStart = range.upperBound
      }
    }

    guard !matches.isEmpty else { return nil }
    matches.sort { lhs, rhs in
      lhs.range.lowerBound < rhs.range.lowerBound
    }

    let result = NSMutableAttributedString()
    var cursor = text.startIndex
    for match in matches where match.range.lowerBound >= cursor {
      if cursor < match.range.lowerBound {
        result.append(
          NSMutableAttributedString(
            string: String(text[cursor..<match.range.lowerBound])
          ).mergingAttributes(attributes)
        )
      }

      switch match.entry.rendering {
      case .attachment:
        result.append(
          InlineMathAttachment.attributedString(
            source: match.entry.source,
            originalLiteral: match.entry.originalLiteral,
            attributes: attributes
          )
        )
      case .literalOnly:
        result.append(
          NSMutableAttributedString(
            string: match.entry.originalLiteral
          ).mergingAttributes(attributes)
        )
      }
      cursor = match.range.upperBound
    }

    if cursor < text.endIndex {
      result.append(
        NSMutableAttributedString(
          string: String(text[cursor..<text.endIndex])
        ).mergingAttributes(attributes)
      )
    }
    return result
  }
}
