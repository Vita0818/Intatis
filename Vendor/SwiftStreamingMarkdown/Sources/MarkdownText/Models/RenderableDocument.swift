//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A `MarkdownRenderConfig`-aware snapshot of a parsed markdown `Document`,
/// ready to be handed to a `DocumentView` for rendering. Producing one is
/// the heavyweight step; rendering it is cheap.
public final class RenderableDocument: Equatable {
  let renderables: [MarkdownRenderable]

  var containsCodeBlock: Bool {
    return renderables.contains(where: { $0.isCodeBlock })
  }

  var containsBlockQuote: Bool {
    return renderables.contains(where: { $0.isBlockQuote })
  }

  var isEmpty: Bool {
    return renderables.isEmpty
  }

  /// Convert a parsed `Document` into a `RenderableDocument` using the supplied config.
  /// - Parameters:
  ///   - document: The parsed markdown tree.
  ///   - config: Styling and behavior used during conversion.
  public init(document: Markdown.Document, config: MarkdownRenderConfig) async {
    self.renderables = document.convert(with: config)
  }

  /// Construct a renderable wrapping a single plain-text paragraph styled
  /// with `config.paragraphStyle`. Useful for showing non-markdown text in a
  /// `DocumentView` without round-tripping through the parser.
  public convenience init(plainText: String, config: MarkdownRenderConfig) {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: config.paragraphStyle.textFonts.normal,
      .foregroundColor: MDColor(config.paragraphStyle.textColor)
    ]
    if let kern = config.paragraphStyle.textFonts.preferredLetterSpacing {
      attributes[.kern] = kern
    }
    let content = NSMutableAttributedString(string: plainText, attributes: attributes)
    self.init(renderables: [.paragraph(id: UUID().uuidString, content: content)])
  }

  init(renderables: [MarkdownRenderable]) {
    self.renderables = renderables
  }

  /// A fresh empty document. This is computed so no non-Sendable document is
  /// shared through global state.
  public static var empty: RenderableDocument {
    RenderableDocument(renderables: [])
  }

  public static func == (lhs: RenderableDocument, rhs: RenderableDocument) -> Bool {
    lhs.renderables == rhs.renderables
  }
}

extension RenderableDocument {
  var attributedStrings: [NSAttributedString] {
    return renderables.flatMap { $0.extractAttributedStrings() }
  }

  /// The full document rendered as plain text, across every block kind
  /// (headings, paragraphs, lists, code blocks, tables, block quotes). Used to
  /// populate the "Select more text" modal.
  var plainText: String {
    renderables
      .compactMap { $0.plainText }
      .joined(separator: "\n\n")
  }
}

extension MarkdownRenderable {
  /// A plain-text representation of this block, or `nil` for blocks that carry
  /// no selectable text (e.g. thematic breaks).
  var plainText: String? {
    switch self {
    case .paragraph(_, let content), .heading(_, _, let content):
      return content.plainTextRestoringInlineMath
    case .orderedList(_, let items):
      return items.plainText(separator: "\n")
    case .unorderedList(_, let items, _):
      return items.plainText(separator: "\n")
    case .codeBlock(_, _, let code):
      return code
    case .table(_, let headers, let rows, _):
      let headerLine = headers
        .map(\.plainTextRestoringInlineMath)
        .joined(separator: "\t")
      let rowLines = rows.map { row in
        row.map(\.plainTextRestoringInlineMath).joined(separator: "\t")
      }
      return ([headerLine] + rowLines).joined(separator: "\n")
    case .blockQuote(_, let item):
      return item.quoteType.plainText
    case .thematicBreak:
      return nil
    case .image(_, let data):
      return data.alt.isEmpty ? nil : data.alt
    }
  }
}

private extension Array where Element == MarkdownListItem {
  func plainText(separator: String) -> String? {
    let lines = flatMap { item in
      item.children.compactMap { $0.plainText }
    }
    return lines.isEmpty ? nil : lines.joined(separator: separator)
  }
}

private extension BlockQuoteType {
  var plainText: String {
    switch self {
    case .text(let text):
      return text.plainTextRestoringBlockQuoteAttachments
    case .nested(let items):
      return items.map { $0.plainText }.joined(separator: "\n")
    }
  }

  var attributedStrings: [NSAttributedString] {
    switch self {
    case .text(let text):
      return [text]
    case .nested(let items):
      return items.flatMap(\.attributedStrings)
    }
  }
}

private extension NSAttributedString {
  /// Block quotes historically restored citation titles in their plain-text
  /// projection. Keep that contract while also restoring raw math literals.
  var plainTextRestoringBlockQuoteAttachments: String {
    guard length > 0 else { return "" }
    let mutable = NSMutableAttributedString(attributedString: self)
    var replacements: [(NSRange, String)] = []
    enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: length),
      options: []
    ) { value, range, _ in
      if let attachment = value as? InlineMathAttachment {
        replacements.append((range, attachment.mathData.originalLiteral))
      } else if let attachment = value as? InlineCitationAttachment,
                let citationData = attachment.citationData {
        replacements.append((range, citationData.title))
      }
    }
    for (range, replacement) in replacements.reversed() {
      mutable.replaceCharacters(in: range, with: replacement)
    }
    return mutable.string
  }
}

extension MarkdownRenderable {
  func extractAttributedStrings() -> [NSAttributedString] {
    switch self {
    case .paragraph(_, let str), .heading(_, _, let str):
      return [str]
    case .orderedList(_, let items):
      return items.flatMap { $0.attributedStrings() }
    case .unorderedList(_, let items, _):
      return items.flatMap { $0.attributedStrings() }
    case .table(_, let headers, let rows, _):
      return headers + rows.flatMap { $0 }
    case .blockQuote(_, let item):
      return item.quoteType.attributedStrings
    default:
      return []
    }
  }
}

extension MarkdownListItem {
  func attributedStrings() -> [NSAttributedString] {
    return self.children.flatMap { $0.extractAttributedStrings() }
  }
}
