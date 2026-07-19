//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
@testable import SwiftStreamingMarkdown
import SwiftUI
import XCTest

final class ViewEquatableContractTests: XCTestCase {
  @MainActor
  func testDocumentViewEqualityIgnoresControllerAndTracksDocumentAndConfig() {
    let config = MarkdownRenderConfig()
    let document = RenderableDocument(plainText: "same document", config: config)
    let lhs = DocumentView(renderableDocument: document, config: config)
    let rhs = DocumentView(renderableDocument: document, config: config)

    XCTAssertEqual(lhs, rhs)
    _ = lhs.equatable()

    let differentDocument = RenderableDocument(plainText: "different document", config: config)
    XCTAssertNotEqual(
      lhs,
      DocumentView(renderableDocument: differentDocument, config: config)
    )
    XCTAssertNotEqual(
      lhs,
      DocumentView(
        renderableDocument: document,
        config: MarkdownRenderConfig(blockSpacing: config.blockSpacing + 1)
      )
    )
  }

  @MainActor
  func testParagraphViewEqualityTracksAttributedContentsAndLineSpacing() {
    let attribute = NSAttributedString.Key("Intatis.ViewEquatableContract")
    let firstContents = NSMutableAttributedString(string: "same paragraph")
    firstContents.addAttribute(attribute, value: "same", range: NSRange(location: 0, length: firstContents.length))
    let secondContents = NSMutableAttributedString(string: "same paragraph")
    secondContents.addAttribute(attribute, value: "same", range: NSRange(location: 0, length: secondContents.length))

    let lhs = ParagraphView(contents: firstContents, lineSpacing: 5)
    XCTAssertEqual(lhs, ParagraphView(contents: secondContents, lineSpacing: 5))
    XCTAssertNotEqual(
      lhs,
      ParagraphView(contents: NSMutableAttributedString(string: "different paragraph"), lineSpacing: 5)
    )

    let differentAttributes = NSMutableAttributedString(string: "same paragraph")
    differentAttributes.addAttribute(
      attribute,
      value: "different",
      range: NSRange(location: 0, length: differentAttributes.length)
    )
    XCTAssertNotEqual(lhs, ParagraphView(contents: differentAttributes, lineSpacing: 5))
    XCTAssertNotEqual(lhs, ParagraphView(contents: secondContents, lineSpacing: 6))
  }
}
