//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import AppKit
@testable import SwiftStreamingMarkdown
import Testing

@Suite("ParagraphNSView Measurement Tests")
@MainActor
struct ParagraphNSViewTests {
  @Test("Uses TextKit 2 for live attachment view providers")
  func usesTextKitTwo() {
    let view = ParagraphNSView()

    #expect(view.textLayoutManager != nil)
    #expect(view.textContentStorage != nil)
  }

  /// Regression: a paragraph is often measured before SwiftUI has given the view a frame
  /// (e.g. during a navigation transition). Measuring through the view's own text container
  /// used to return a zero height in that state because `widthTracksTextView` forces the
  /// container width to follow the frame width (0), collapsing the paragraph. Measurement
  /// must instead honor the requested width regardless of the view's frame.
  @Test("Measures a non-zero, width-dependent height without a frame")
  func measuresHeightWithoutFrame() {
    let view = ParagraphNSView()
    let longText = String(repeating: "word ", count: 200)
    view.setParagraphContents(NSMutableAttributedString(string: longText), animatedByWord: false)

    let narrow = view.measureSize(fittingWidth: 200)
    let wide = view.measureSize(fittingWidth: 1000)

    #expect(narrow.height > 0, "Wrapping content must have a non-zero height even without a frame")
    #expect(wide.height > 0, "Wrapping content must have a non-zero height even without a frame")
    #expect(
      narrow.height > wide.height,
      "A narrower width must wrap to more lines and therefore be taller, proving the requested width is honored"
    )
  }

  @Test("Empty content measures as zero")
  func measuresEmptyContentAsZero() {
    let view = ParagraphNSView()
    view.setParagraphContents(NSMutableAttributedString(string: ""), animatedByWord: false)

    #expect(view.measureSize(fittingWidth: 400) == .zero)
  }

  @Test("Stable positive width does not repeat intrinsic-size invalidation")
  func stablePositiveWidthDoesNotInvalidateAgain() {
    let view = IntrinsicInvalidationCountingParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "stable width ", count: 40)),
      animatedByWord: false
    )
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 200)

    view.layout()
    _ = view.intrinsicContentSize
    view.resetIntrinsicInvalidationCount()

    for _ in 0..<32 {
      view.layout()
    }

    #expect(view.window == nil)
    #expect(view.intrinsicInvalidationCount == 0)
  }

  @Test("Zero width does not create an intrinsic-size feedback path")
  func zeroWidthDoesNotInvalidate() {
    let view = IntrinsicInvalidationCountingParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "zero width ", count: 40)),
      animatedByWord: false
    )
    view.frame = .zero
    view.resetIntrinsicInvalidationCount()

    for _ in 0..<32 {
      view.layout()
    }

    #expect(view.window == nil)
    #expect(view.intrinsicInvalidationCount == 0)
  }

  @Test("A real width change refreshes measurement once then becomes stable")
  func widthChangeRefreshesMeasurementThenStabilizes() {
    let view = IntrinsicInvalidationCountingParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "width dependent paragraph ", count: 120)),
      animatedByWord: false
    )
    view.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
    view.layout()
    let narrowSize = view.intrinsicContentSize

    view.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
    view.layout()
    let wideSize = view.intrinsicContentSize

    #expect(wideSize.height < narrowSize.height)

    view.resetIntrinsicInvalidationCount()
    for _ in 0..<32 {
      view.layout()
    }
    #expect(view.intrinsicInvalidationCount == 0)
  }

  @Test("Returning from zero width refreshes the previous valid width")
  func returningFromZeroWidthRefreshesPreviousWidth() {
    let view = IntrinsicInvalidationCountingParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "initial paragraph ", count: 40)),
      animatedByWord: false
    )
    view.frame = NSRect(x: 0, y: 0, width: 160, height: 500)
    view.layout()
    _ = view.intrinsicContentSize

    view.frame = .zero
    view.layout()
    view.setParagraphContents(
      NSMutableAttributedString(string: String(repeating: "replacement paragraph ", count: 120)),
      animatedByWord: false
    )
    let fallbackSize = view.intrinsicContentSize

    view.frame = NSRect(x: 0, y: 0, width: 160, height: 500)
    view.layout()
    let restoredSize = view.intrinsicContentSize

    #expect(restoredSize.height > fallbackSize.height)
  }
}

private final class IntrinsicInvalidationCountingParagraphNSView: ParagraphNSView {
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
