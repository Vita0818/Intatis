//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(UIKit)
import Foundation
@testable import SwiftStreamingMarkdown
import Testing
import UIKit

@Suite("ParagraphUIView Layout Tests")
@MainActor
struct ParagraphUIViewTests {
  @Test("Stable positive width does not repeat intrinsic-size invalidation")
  func stablePositiveWidthDoesNotInvalidateAgain() {
    let view = IntrinsicInvalidationCountingParagraphUIView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "stable width ", count: 40)),
      animatedByWord: false
    )
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)

    view.layoutSubviews()
    _ = view.intrinsicContentSize
    view.resetIntrinsicInvalidationCount()

    for _ in 0..<32 {
      view.layoutSubviews()
    }

    #expect(view.window == nil)
    #expect(view.intrinsicInvalidationCount == 0)
  }

  @Test("Zero width does not create an intrinsic-size feedback path")
  func zeroWidthDoesNotInvalidate() {
    let view = IntrinsicInvalidationCountingParagraphUIView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "zero width ", count: 40)),
      animatedByWord: false
    )
    view.frame = .zero
    view.resetIntrinsicInvalidationCount()

    for _ in 0..<32 {
      view.layoutSubviews()
    }

    #expect(view.window == nil)
    #expect(view.intrinsicInvalidationCount == 0)
  }

  @Test("A real width change refreshes measurement then becomes stable")
  func widthChangeRefreshesMeasurementThenStabilizes() {
    let view = IntrinsicInvalidationCountingParagraphUIView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "width dependent paragraph ", count: 120)),
      animatedByWord: false
    )
    view.frame = CGRect(x: 0, y: 0, width: 240, height: 500)
    view.layoutSubviews()
    let narrowSize = view.intrinsicContentSize

    view.frame = CGRect(x: 0, y: 0, width: 640, height: 500)
    view.layoutSubviews()
    let wideSize = view.intrinsicContentSize

    #expect(wideSize.height < narrowSize.height)

    view.resetIntrinsicInvalidationCount()
    for _ in 0..<32 {
      view.layoutSubviews()
    }
    #expect(view.intrinsicInvalidationCount == 0)
  }

  @Test("Returning from zero width refreshes the previous valid width")
  func returningFromZeroWidthRefreshesPreviousWidth() {
    let view = IntrinsicInvalidationCountingParagraphUIView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "initial paragraph ", count: 40)),
      animatedByWord: false
    )
    view.frame = CGRect(x: 0, y: 0, width: 120, height: 500)
    view.layoutSubviews()
    _ = view.intrinsicContentSize

    view.frame = .zero
    view.layoutSubviews()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "replacement paragraph ", count: 120)),
      animatedByWord: false
    )
    let fallbackSize = view.intrinsicContentSize

    view.frame = CGRect(x: 0, y: 0, width: 120, height: 500)
    view.layoutSubviews()
    let restoredSize = view.intrinsicContentSize

    #expect(restoredSize.height > fallbackSize.height)
  }
}

private final class IntrinsicInvalidationCountingParagraphUIView: ParagraphUIView {
  private(set) var intrinsicInvalidationCount = 0

  override func invalidateIntrinsicContentSize() {
    intrinsicInvalidationCount += 1
    super.invalidateIntrinsicContentSize()
  }

  func resetIntrinsicInvalidationCount() {
    intrinsicInvalidationCount = 0
  }
}
#endif
