//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct OrderedListView: View {

  let items: [MarkdownListItem]
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig

  var body: some View {
    VStack(alignment: .leading, spacing: 8, content: {
      ForEach(0..<items.count, id: \.self) { idx in
        HStack(alignment: .centerOfFirstLine, spacing: 11) {
          Text(verbatim: "\(idx+1).")
            .font(config.orderedListStyle.textFonts, bold: true)
            .foregroundStyle(config.orderedListStyle.textColor)
            .transition(.opacity)
          if let firstChild = items[idx].children.first {
            if case .paragraph(_, let contents) = firstChild {
              // Wrap the SingleBlockView to provide proper baseline alignment. This is to fix the mis-alignment when the view is rendered off-screen, e.g. snapshot.
              ListItemContentWrapper(paragraphContents: contents) {
                SingleBlockView(renderable: firstChild)
              }
              .accessibilityLabel(Text(markdownListAccessibilityLabel(
                for: contents.accessibilityTextDescribingAttachments,
                at: idx,
                length: items.count
              )))
            } else {
              SingleBlockView(renderable: firstChild)
            }
          }
          Spacer()
        }
        if items[idx].children.count > 1 {
          BlockView(renderables: Array(items[idx].children.dropFirst()))
            .padding([.leading], 0)
        }
      }
    })
  }
}

// Wrapper to provide proper baseline alignment for UIViewRepresentable content
struct ListItemContentWrapper<Content: View>: View {
  let paragraphContents: NSMutableAttributedString
  let content: () -> Content

  init(paragraphContents: NSMutableAttributedString, @ViewBuilder content: @escaping () -> Content) {
    self.paragraphContents = paragraphContents
    self.content = content
  }

  var body: some View {
    let firstLineCenter = extractFirstFont().lineHeight / 2.0
    content()
      .alignmentGuide(.centerOfFirstLine) { _ in
        firstLineCenter
      }
  }

  private func extractFirstFont() -> MDFont {
    // First check if the first character is a citation attachment - use its
    // own font so the alignment guide matches the actual rendered glyph,
    // not a stale default.
    if let citation = firstCharacterCitationAttachment(in: paragraphContents) {
      return citation.font
    }
    if let math = firstCharacterMathAttachment(in: paragraphContents) {
      return math.font
    }
    // Otherwise, look for regular font attributes
    if let font = firstFont(in: paragraphContents) {
      return font
    }
    return Typography.base.mdFont
  }

  private func firstCharacterCitationAttachment(in attributedString: NSAttributedString) -> InlineCitationAttachment? {
    guard attributedString.length > 0 else { return nil }
    return attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? InlineCitationAttachment
  }

  private func firstCharacterMathAttachment(in attributedString: NSAttributedString) -> InlineMathAttachment? {
    guard attributedString.length > 0 else { return nil }
    return attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? InlineMathAttachment
  }

  private func firstFont(in attributedString: NSAttributedString) -> MDFont? {
    guard attributedString.length > 0 else { return nil }

    // Fast path: attribute at location 0
    if let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? MDFont {
      return font
    }

    var found: MDFont?
    attributedString.enumerateAttribute(.font, in: NSRange(location: 0, length: attributedString.length)) { value, _, stop in
      if let font = value as? MDFont {
        found = font
        stop.pointee = true
      }
    }
    return found
  }
}

func markdownListAccessibilityLabel(for item: String, at index: Int, length: Int) -> String {
  "\(String.markdownList(length: String(length))), item \(index + 1): \(item)"
}

extension NSAttributedString {
  /// Accessibility text keeps the surrounding prose while expanding inline
  /// attachments into the same spoken descriptions used by paragraph views.
  var accessibilityTextDescribingAttachments: String {
    guard length > 0 else { return "" }
    let mutable = NSMutableAttributedString(attributedString: self)
    var replacements: [(NSRange, String)] = []
    enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: length),
      options: []
    ) { value, range, _ in
      if let attachment = value as? InlineMathAttachment {
        replacements.append((
          range,
          String.localizedStringWithFormat(
            String.mathFormulaAccessibilityFormat,
            attachment.mathData.source
          )
        ))
      } else if let attachment = value as? InlineCitationAttachment,
                let citationData = attachment.citationData {
        replacements.append((range, citationData.accessibilityLabel))
      }
    }
    for (range, description) in replacements.reversed() {
      mutable.replaceCharacters(in: range, with: description)
    }
    return mutable.string
  }
}

#Preview(body: {
  let items: [MarkdownListItem] = (0..<40).map { i in
    MarkdownListItem(children: [.paragraph(id: "\(i)", content: NSMutableAttributedString(string: "item \(i + 1)"))], startsWithBold: false)
  }
  return ScrollView {
    OrderedListView(items: items)
  }
})
