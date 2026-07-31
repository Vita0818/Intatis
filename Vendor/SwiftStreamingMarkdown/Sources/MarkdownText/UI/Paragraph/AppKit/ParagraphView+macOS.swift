//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import SwiftUI

struct ParagraphView: NSViewRepresentable {
  @Environment(\.openURL) var openURL
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  @Environment(\.markdownController) var markdownController: MarkdownController?

  var contents: NSMutableAttributedString
  var lineSpacing: CGFloat?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> ParagraphNSView {
    let openUrlFunction = openURL.callAsFunction(_:)
    // Do not reuse paragraph views on macOS. Reused NSTextView instances can retain
    // stale attachment subviews from a
    // previously displayed document, which then render at the wrong positions. Each
    // paragraph gets its own view instead.
    let view = ParagraphNSView()
    view.onUrlTap = openUrlFunction
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    view.setTextContextMenu(config.resolvedTextContextMenu)
    view.setMarkdownController(markdownController)

    if config.shouldAnimateText {
      view.alphaValue = 0
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = ParagraphNSView.animationDuration
        view.animator().alphaValue = 1
      }
    }

    return view
  }

  func updateNSView(_ view: ParagraphNSView, context: Context) {
    if view.paragraphContents != contents || view.lineSpacing != lineSpacing {
      let shouldAnimate = view.window != nil && config.shouldAnimateText
      view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: shouldAnimate)
    }
    view.setTextContextMenu(config.resolvedTextContextMenu)
    view.setMarkdownController(markdownController)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ParagraphNSView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, width.isFinite else {
      return nil
    }

    if contents != context.coordinator.lastContents || lineSpacing != context.coordinator.lastLineSpacing {
      context.coordinator.measurementCache.reset()
      context.coordinator.lastContents = contents
      context.coordinator.lastLineSpacing = lineSpacing
    }

    let widthKey = width

    if let cachedHeight = context.coordinator.measurementCache.height(
      forWidthKey: widthKey
    ) {
      return Self.layoutSize(
        proposalWidth: width,
        measuredHeight: cachedHeight
      )
    }

    let measuredSize = nsView.measureSize(fittingWidth: widthKey)
    let measuredHeight = measuredSize.height.rounded(.up)

    context.coordinator.measurementCache.store(
      height: measuredHeight,
      forWidthKey: widthKey
    )
    return Self.layoutSize(
      proposalWidth: width,
      measuredHeight: measuredHeight
    )
  }

  class Coordinator {
    var measurementCache = ParagraphMeasurementCache()
    var lastContents: NSMutableAttributedString?
    var lastLineSpacing: CGFloat?
  }

  /// A paragraph is a wrapping, horizontally flexible leaf. Returning the
  /// measured glyph width lets AppKit's intrinsic width and SwiftUI's proposed
  /// width negotiate against each other during a window resize. Claiming the
  /// finite proposal while reporting only the measured height gives that
  /// negotiation a single owner and prevents a width -> intrinsic-size ->
  /// width feedback loop.
  static func layoutSize(
    proposalWidth: CGFloat,
    measuredHeight: CGFloat
  ) -> CGSize {
    CGSize(width: proposalWidth, height: measuredHeight)
  }

}

extension ParagraphView: @MainActor Equatable {
  static func == (lhs: ParagraphView, rhs: ParagraphView) -> Bool {
    lhs.contents.isEqual(to: rhs.contents) && lhs.lineSpacing == rhs.lineSpacing
  }
}

/// Per-representable, one-entry measurement memo. Window zoom and live resize
/// can issue hundreds of distinct proposals. Retaining every historical width
/// is both unnecessary and unbounded; only the most recent proposal can be
/// reused by the next SwiftUI layout pass.
struct ParagraphMeasurementCache {
  private(set) var widthKey: CGFloat?
  private(set) var measuredHeight: CGFloat?

  var entryCount: Int {
    widthKey == nil || measuredHeight == nil ? 0 : 1
  }

  func height(forWidthKey candidate: CGFloat) -> CGFloat? {
    guard widthKey == candidate else { return nil }
    return measuredHeight
  }

  mutating func store(height: CGFloat, forWidthKey widthKey: CGFloat) {
    self.widthKey = widthKey
    measuredHeight = height
  }

  mutating func reset() {
    widthKey = nil
    measuredHeight = nil
  }
}

#endif
