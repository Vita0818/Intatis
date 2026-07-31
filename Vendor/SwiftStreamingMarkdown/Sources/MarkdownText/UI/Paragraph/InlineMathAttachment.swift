//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: native TextKit 2 inline-math attachments.
//

import Foundation
import iosMath
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Dedicated attachment type for Intatis inline and display mathematics.
///
/// The attachment crosses the parser-to-MainActor ownership boundary with
/// scalar data only. A short-lived `MTMathUILabel` is used for layout preflight,
/// while TextKit 2 owns the live label used for display.
final class InlineMathAttachment: NSTextAttachment {
  static let mimeType = "application/vnd.vita0818.intatis-inline-math+json"
  static let typeIdentifier: String = {
    guard let type = UTType(
      tag: mimeType,
      tagClass: .mimeType,
      conformingTo: .json
    ) else {
      preconditionFailure("Unable to derive the dedicated inline-math UTI")
    }
    return type.identifier
  }()
  let mathData: MathAttachmentData
  let textColor: MDColor
  let font: MDFont

  /// The attachment subclass owns its provider directly instead of installing
  /// a process-global provider for a broad public UTI. This also keeps the live
  /// TextKit 2 path available in package-test hosts that do not export Intatis's
  /// private UTI in their main-bundle Info.plist.
  override var usesTextAttachmentView: Bool {
    allowsTextAttachmentView && contents != nil
  }

  #if canImport(UIKit)
  override func viewProvider(
    for parentView: UIView?,
    location: any NSTextLocation,
    textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    guard usesTextAttachmentView else { return nil }
    return InlineMathAttachmentViewProvider(
      textAttachment: self,
      parentView: parentView,
      textLayoutManager: textContainer?.textLayoutManager,
      location: location
    )
  }
  #elseif canImport(AppKit)
  override func viewProvider(
    for parentView: NSView?,
    location: any NSTextLocation,
    textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    guard usesTextAttachmentView else { return nil }
    return InlineMathAttachmentViewProvider(
      textAttachment: self,
      parentView: parentView,
      textLayoutManager: textContainer?.textLayoutManager,
      location: location
    )
  }
  #endif

  private init(
    mathData: MathAttachmentData,
    textColor: MDColor,
    font: MDFont,
    payload: Data
  ) {
    self.mathData = mathData
    self.textColor = textColor
    self.font = font
    super.init(data: payload, ofType: Self.typeIdentifier)
    allowsTextAttachmentView = true
    #if canImport(AppKit)
    // NSTextAttachment installs a generic document cell by default on AppKit.
    // TextKit 2 otherwise renders that cell instead of requesting our live
    // attachment view provider, even when the dedicated UTI is registered.
    attachmentCell = nil
    #endif
  }

  required init?(coder: NSCoder) {
    return nil
  }

  /// Validates TeX with a request-local builder and returns either a dedicated
  /// attachment or the byte-exact original literal. No iosMath object escapes
  /// this synchronous call.
  static func attributedString(
    source: String,
    originalLiteral: String,
    presentation: MathPresentation = .inline,
    attributes: NSAttributeContainer
  ) -> NSMutableAttributedString {
    guard !source.isEmpty,
          MTMathListBuilder.build(from: source) != nil,
          let font = attributes[.font] as? MDFont else {
      return NSMutableAttributedString(string: originalLiteral).mergingAttributes(attributes)
    }

    let data = MathAttachmentData(
      source: source,
      originalLiteral: originalLiteral,
      presentation: presentation,
      fontSize: Double(font.pointSize)
    )
    guard let payload = try? JSONEncoder().encode(data) else {
      return NSMutableAttributedString(string: originalLiteral).mergingAttributes(attributes)
    }
    let textColor = (attributes[.foregroundColor] as? MDColor)
      ?? MDColor(Color.Theme.Foreground.Primary.Primary750)
    let attachment = InlineMathAttachment(
      mathData: data,
      textColor: textColor,
      font: font,
      payload: payload
    )
    let result = NSMutableAttributedString(attachment: attachment)
    result.addAttributes(
      attributes,
      range: NSRange(location: 0, length: result.length)
    )
    return result
  }

  /// Measures the formula on the MainActor and freezes its intrinsic attachment
  /// rectangle. A `false` result means the caller must replace the attachment
  /// with `originalLiteral` before handing the paragraph to TextKit.
  @MainActor
  func preflightLayout() -> Bool {
    if bounds.width > 0, bounds.height > 0 {
      return true
    }

    let label = MTMathUILabel()
    configure(label: label, textColor: platformMeasurementColor)
    guard label.error == nil else {
      return false
    }

    let measured = label.intrinsicContentSize
    let renderedSize = CGSize(
      width: measured.width.rounded(.up),
      height: (measured.height + 1).rounded(.up)
    )
    guard renderedSize.width.isFinite,
          renderedSize.height.isFinite,
          renderedSize.width > 0,
          renderedSize.height > 0 else {
      return false
    }

    let yOffset = (font.xHeight - renderedSize.height) / 2
    bounds = CGRect(
      x: 0,
      y: yOffset,
      width: renderedSize.width,
      height: renderedSize.height
    )
    return true
  }

  @MainActor
  func makeLiveLabel() -> InlineMathLabelView {
    let label = InlineMathLabelView(attachment: self)
    label.frame = CGRect(origin: .zero, size: bounds.size)
    #if canImport(UIKit)
    label.setNeedsLayout()
    label.layoutIfNeeded()
    #elseif canImport(AppKit)
    label.needsLayout = true
    label.layoutSubtreeIfNeeded()
    #endif
    return label
  }

  @MainActor
  private func configure(label: MTMathUILabel, textColor: MDColor) {
    label.displayErrorInline = false
    label.mode = mathData.presentation == .display ? .display : .text
    label.fontSize = CGFloat(mathData.fontSize)
    label.textColor = textColor
    label.latex = mathData.source
  }

  private var platformMeasurementColor: MDColor {
    #if canImport(UIKit)
    return .black
    #elseif canImport(AppKit)
    return .black
    #endif
  }
}

/// Registers the dedicated TextKit 2 provider for one exact attachment type.
///
/// Production uses the exact dynamic UTI derived from Intatis's unique MIME
/// tag, so no broad public attachment type is ever registered process-wide.
@MainActor
func registerInlineMathAttachmentViewProvider(
  for typeIdentifier: String = InlineMathAttachment.typeIdentifier
) {
  NSTextAttachment.registerViewProviderClass(
    InlineMathAttachmentViewProvider.self,
    forFileType: typeIdentifier
  )
}

/// Live iosMath view whose semantic color follows the actual host appearance.
#if canImport(UIKit)
final class InlineMathLabelView: MTMathUILabel {
  private let semanticTextColor: UIColor

  init(attachment: InlineMathAttachment) {
    semanticTextColor = attachment.textColor
    super.init(frame: .zero)
    displayErrorInline = false
    mode = attachment.mathData.presentation == .display ? .display : .text
    fontSize = CGFloat(attachment.mathData.fontSize)
    latex = attachment.mathData.source
    isAccessibilityElement = false
    refreshSemanticColor()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func traitCollectionDidChange(
    _ previousTraitCollection: UITraitCollection?
  ) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(
      comparedTo: previousTraitCollection
    ) {
      refreshSemanticColor()
    }
  }

  private func refreshSemanticColor() {
    textColor = semanticTextColor.resolvedColor(with: traitCollection)
  }
}
#elseif canImport(AppKit)
final class InlineMathLabelView: MTMathUILabel {
  private let semanticTextColor: NSColor

  init(attachment: InlineMathAttachment) {
    semanticTextColor = attachment.textColor
    super.init(frame: .zero)
    displayErrorInline = false
    mode = attachment.mathData.presentation == .display ? .display : .text
    fontSize = CGFloat(attachment.mathData.fontSize)
    latex = attachment.mathData.source
    setAccessibilityElement(false)
    refreshSemanticColor()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshSemanticColor()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    prepareForLiveDisplay()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    prepareForLiveDisplay()
  }

  private func prepareForLiveDisplay() {
    refreshSemanticColor()
    needsLayout = true
    layoutSubtreeIfNeeded()
    needsDisplay = true
  }

  private func refreshSemanticColor() {
    var resolved = semanticTextColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = semanticTextColor.usingColorSpace(.sRGB) ?? semanticTextColor
    }
    textColor = resolved
  }
}
#endif

/// Dedicated TextKit-2 registration for the inline-math UTI.
@MainActor
final class InlineMathAttachmentViewProvider: NSTextAttachmentViewProvider {
  #if canImport(UIKit)
  required override nonisolated init(
    textAttachment attachment: NSTextAttachment,
    parentView: UIView?,
    textLayoutManager: NSTextLayoutManager?,
    location: any NSTextLocation
  ) {
    super.init(
      textAttachment: attachment,
      parentView: parentView,
      textLayoutManager: textLayoutManager,
      location: location
    )
    tracksTextAttachmentViewBounds = false
  }
  #elseif canImport(AppKit)
  required override nonisolated init(
    textAttachment attachment: NSTextAttachment,
    parentView: NSView?,
    textLayoutManager: NSTextLayoutManager?,
    location: any NSTextLocation
  ) {
    super.init(
      textAttachment: attachment,
      parentView: parentView,
      textLayoutManager: textLayoutManager,
      location: location
    )
    tracksTextAttachmentViewBounds = false
  }
  #endif

  nonisolated override func loadView() {
    // AppKit/UIKit still import this Objective-C override as nonisolated even
    // though attachment views are instantiated on the UI thread. Assert that
    // framework contract, then use synchronous Objective-C dispatch back into
    // this class's MainActor isolation without declaring unsafe Sendability.
    MainActor.preconditionIsolated()
    _ = perform(#selector(loadMathView))
  }

  @objc
  private func loadMathView() {
    guard let attachment = textAttachment as? InlineMathAttachment,
          attachment.bounds.width > 0,
          attachment.bounds.height > 0 else {
      view = nil
      return
    }
    view = attachment.makeLiveLabel()
  }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any],
    location: any NSTextLocation,
    textContainer: NSTextContainer?,
    proposedLineFragment: CGRect,
    position: CGPoint
  ) -> CGRect {
    textAttachment?.bounds ?? .zero
  }
}

extension NSAttributedString {
  /// User-facing plain text with math attachments restored to their original
  /// single-dollar source.
  var plainTextRestoringInlineMath: String {
    guard length > 0 else { return "" }
    let mutable = NSMutableAttributedString(attributedString: self)
    var replacements: [(NSRange, String)] = []
    enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: length),
      options: []
    ) { value, range, _ in
      guard let attachment = value as? InlineMathAttachment else { return }
      replacements.append((range, attachment.mathData.originalLiteral))
    }
    for (range, literal) in replacements.reversed() {
      mutable.replaceCharacters(in: range, with: literal)
    }
    return mutable.string
  }

  /// A copy-safe attributed substring with math attachments expanded to raw
  /// source while retaining surrounding text attributes.
  func replacingInlineMathAttachmentsWithLiteral() -> NSMutableAttributedString {
    let mutable = NSMutableAttributedString(attributedString: self)
    guard mutable.length > 0 else { return mutable }
    var replacements: [(NSRange, InlineMathAttachment, [NSAttributedString.Key: Any])] = []
    mutable.enumerateAttributes(
      in: NSRange(location: 0, length: mutable.length),
      options: []
    ) { attributes, range, _ in
      guard let attachment = attributes[.attachment] as? InlineMathAttachment else { return }
      var literalAttributes = attributes
      literalAttributes.removeValue(forKey: .attachment)
      literalAttributes.removeValue(forKey: .baselineOffset)
      replacements.append((range, attachment, literalAttributes))
    }
    for (range, attachment, attributes) in replacements.reversed() {
      mutable.replaceCharacters(
        in: range,
        with: NSAttributedString(
          string: attachment.mathData.originalLiteral,
          attributes: attributes
        )
      )
    }
    return mutable
  }
}

@MainActor
func materializeInlineMathAttachments(
  in attributedString: NSAttributedString
) -> NSMutableAttributedString {
  guard attributedString.length > 0 else {
    return (attributedString as? NSMutableAttributedString)
      ?? NSMutableAttributedString()
  }

  var containsInlineMath = false
  attributedString.enumerateAttribute(
    .attachment,
    in: NSRange(location: 0, length: attributedString.length),
    options: []
  ) { value, _, stop in
    if value is InlineMathAttachment {
      containsInlineMath = true
      stop.pointee = true
    }
  }
  guard containsInlineMath else {
    return (attributedString as? NSMutableAttributedString)
      ?? NSMutableAttributedString(attributedString: attributedString)
  }

  let mutable = NSMutableAttributedString(attributedString: attributedString)
  var fallbacks: [(NSRange, InlineMathAttachment, [NSAttributedString.Key: Any])] = []
  mutable.enumerateAttributes(
    in: NSRange(location: 0, length: mutable.length),
    options: []
  ) { attributes, range, _ in
    guard let attachment = attributes[.attachment] as? InlineMathAttachment else { return }
    if !attachment.preflightLayout() {
      var literalAttributes = attributes
      literalAttributes.removeValue(forKey: .attachment)
      literalAttributes.removeValue(forKey: .baselineOffset)
      fallbacks.append((range, attachment, literalAttributes))
    }
  }
  for (range, attachment, attributes) in fallbacks.reversed() {
    mutable.replaceCharacters(
      in: range,
      with: NSAttributedString(
        string: attachment.mathData.originalLiteral,
        attributes: attributes
      )
    )
  }
  return mutable
}
