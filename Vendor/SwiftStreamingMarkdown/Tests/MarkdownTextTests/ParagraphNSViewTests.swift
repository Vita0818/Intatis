//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import AppKit
@testable import SwiftStreamingMarkdown
import SwiftUI
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

  @Test("Intrinsic width stays flexible while intrinsic height remains measured")
  func intrinsicWidthDoesNotCompeteWithSwiftUIProposal() {
    let view = ParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(
        string: String(repeating: "wrapping paragraph ", count: 80)
      ),
      animatedByWord: false
    )
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
    view.layout()

    let intrinsic = view.intrinsicContentSize

    #expect(intrinsic.width == NSView.noIntrinsicMetric)
    #expect(intrinsic.height > 0)
  }

  @Test("Intrinsic height validates the current width before layout")
  func intrinsicHeightDoesNotReuseAStaleWidth() {
    let view = ParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(
        string: String(repeating: "query before layout paragraph ", count: 120)
      ),
      animatedByWord: false
    )

    view.frame = NSRect(x: 0, y: 0, width: 160, height: 500)
    let narrowHeight = view.intrinsicContentSize.height
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
    let wideHeight = view.intrinsicContentSize.height
    view.frame = NSRect(x: 0, y: 0, width: 160, height: 500)
    let returnedNarrowHeight = view.intrinsicContentSize.height

    #expect(narrowHeight > wideHeight)
    #expect(returnedNarrowHeight == narrowHeight)
    #expect(view.intrinsicContentSize.width == NSView.noIntrinsicMetric)
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

  @Test("Continuous width changes do not publish intrinsic invalidations")
  func continuousWidthChangesStayInsideRepresentableMeasurement() {
    let view = IntrinsicInvalidationCountingParagraphNSView()
    view.setParagraphContents(
      NSMutableAttributedString(
        string: String(repeating: "window resize paragraph ", count: 120)
      ),
      animatedByWord: false
    )
    view.resetIntrinsicInvalidationCount()

    for step in 0..<10_000 {
      let width = CGFloat(240) + CGFloat(step % 700) / 10
      view.frame = NSRect(x: 0, y: 0, width: width, height: 500)
      view.layout()
    }

    #expect(view.intrinsicInvalidationCount == 0)
    #expect(view.intrinsicContentSize.width == NSView.noIntrinsicMetric)
    #expect(view.intrinsicContentSize.height > 0)
  }

  @Test("A live SwiftUI host remains finite across repeated A-B-A widths")
  func liveSwiftUIHostResizeDoesNotEnterAFeedbackLoop() {
    let contents = NSMutableAttributedString(
      string: String(repeating: "live hosting resize paragraph ", count: 120)
    )
    let root = HStack(spacing: 0) {
      ParagraphView(contents: contents, lineSpacing: 5)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)

    func paragraphSubview(in view: NSView) -> ParagraphNSView? {
      if let paragraph = view as? ParagraphNSView {
        return paragraph
      }
      for subview in view.subviews {
        if let paragraph = paragraphSubview(in: subview) {
          return paragraph
        }
      }
      return nil
    }

    var observations: [(requestedWidth: CGFloat, paragraphSize: CGSize)] = []
    for width in Array(repeating: [320.0, 900.0, 320.0], count: 120).flatMap({ $0 }) {
      autoreleasepool {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        host.layoutSubtreeIfNeeded()
        let paragraph = paragraphSubview(in: host)
        #expect(paragraph != nil)
        guard let paragraph else { return }

        let paragraphSize = paragraph.bounds.size
        #expect(paragraphSize.width.isFinite)
        #expect(paragraphSize.height.isFinite)
        #expect(paragraphSize.width > 0)
        #expect(paragraphSize.height > 0)
        observations.append((CGFloat(width), paragraphSize))
      }
    }

    #expect(observations.count == 360)
    for index in stride(from: 0, to: observations.count, by: 3) {
      let narrow = observations[index]
      let wide = observations[index + 1]
      let returnedNarrow = observations[index + 2]
      #expect(wide.paragraphSize.width > narrow.paragraphSize.width)
      #expect(narrow.paragraphSize.height > wide.paragraphSize.height)
      #expect(abs(narrow.paragraphSize.width - returnedNarrow.paragraphSize.width) <= 1)
      #expect(abs(narrow.paragraphSize.height - returnedNarrow.paragraphSize.height) <= 1)
    }
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
