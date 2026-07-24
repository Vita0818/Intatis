//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI

extension BlockQuote: BlockConvertible {
  private func quoteTypes(
    attributeContainer: NSAttributeContainer,
    config: MarkdownRenderConfig
  ) -> BlockQuoteType {
    var finalQuoteTypes = [BlockQuoteType]()

    for child in children {
      if child is InlineContainer, let blockMarkup = child as? BlockMarkup {
        let contents = blockMarkup.buildParagraphContent(
          container: attributeContainer,
          config: config
        )
        finalQuoteTypes.append(.text(contents))
      } else if let blockQuoteContainer = child as? BlockQuote {
        finalQuoteTypes.append(
          blockQuoteContainer.quoteTypes(
            attributeContainer: attributeContainer,
            config: config
          )
        )
      }
    }

    return .nested(finalQuoteTypes)
  }

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> MarkdownRenderable {
    var quoteContainer = attributeContainer
    quoteContainer[.font] = config.blockQuoteStyle.textFonts.normal
    quoteContainer[.typography] = config.blockQuoteStyle.textFonts
    if let kern = config.blockQuoteStyle.textFonts.preferredLetterSpacing {
      quoteContainer[.kern] = kern
    }
    quoteContainer[.foregroundColor] = MDColor(config.blockQuoteStyle.textColor)
    return .blockQuote(
      id: id,
      item: .init(
        quoteType: quoteTypes(
          attributeContainer: quoteContainer,
          config: config
        )
      )
    )
  }
}

struct BlockQuoteRenderable: Equatable {
  let quoteType: BlockQuoteType
}
