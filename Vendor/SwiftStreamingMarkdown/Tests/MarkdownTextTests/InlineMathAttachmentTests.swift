//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: inline-math attachment safety coverage.
//

#if canImport(AppKit)
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import XCTest
@testable import SwiftStreamingMarkdown

final class InlineMathAttachmentTests: XCTestCase {
  private func attributes() -> NSAttributeContainer {
    [
      .font: NSFont.systemFont(ofSize: 15),
      .foregroundColor: NSColor.labelColor
    ]
  }

  func testDedicatedAttachmentPayloadAndRawCopyContract() throws {
    let rendered = InlineMathAttachment.attributedString(
      source: #"\frac{a}{b}"#,
      originalLiteral: #"$\frac{a}{b}$"#,
      attributes: attributes()
    )

    XCTAssertEqual(rendered.length, 1)
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )
    XCTAssertNotNil(attachment.contents)
    XCTAssertEqual(attachment.fileType, InlineMathAttachment.typeIdentifier)
    XCTAssertNil(attachment.attachmentCell)
    let contentType = try XCTUnwrap(
      UTType(InlineMathAttachment.typeIdentifier)
    )
    XCTAssertTrue(contentType.conforms(to: .json))
    XCTAssertNotEqual(contentType, .json)
    XCTAssertNotEqual(contentType, .data)
    XCTAssertEqual(attachment.mathData.source, #"\frac{a}{b}"#)
    XCTAssertEqual(
      rendered.plainTextRestoringInlineMath,
      #"$\frac{a}{b}$"#
    )
    XCTAssertEqual(
      rendered.replacingInlineMathAttachmentsWithLiteral().string,
      #"$\frac{a}{b}$"#
    )
  }

  func testMalformedFormulaFallsBackToExactLiteralWithoutAttachment() {
    let literal = #"$\notAnIosMathCommand{x}$"#
    let rendered = InlineMathAttachment.attributedString(
      source: #"\notAnIosMathCommand{x}"#,
      originalLiteral: literal,
      attributes: attributes()
    )

    XCTAssertEqual(rendered.string, literal)
    XCTAssertNil(rendered.attribute(.attachment, at: 0, effectiveRange: nil))
  }

  func testDeeplyNestedFormulaFailsClosedToExactLiteral() {
    let source = String(repeating: "{", count: 200)
      + "x"
      + String(repeating: "}", count: 200)
    let literal = "$\(source)$"
    let rendered = InlineMathAttachment.attributedString(
      source: source,
      originalLiteral: literal,
      attributes: attributes()
    )

    XCTAssertEqual(rendered.string, literal)
    XCTAssertNil(rendered.attribute(.attachment, at: 0, effectiveRange: nil))
  }

  @MainActor
  func testValidFormulaPreflightsFiniteLiveTextKitView() throws {
    let rendered = InlineMathAttachment.attributedString(
      source: #"E=mc^2"#,
      originalLiteral: #"$E=mc^2$"#,
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )

    XCTAssertTrue(attachment.allowsTextAttachmentView)
    XCTAssertTrue(attachment.preflightLayout())
    XCTAssertNil(attachment.image)
    XCTAssertTrue(attachment.bounds.width.isFinite)
    XCTAssertTrue(attachment.bounds.height.isFinite)
    XCTAssertGreaterThan(attachment.bounds.width, 0)
    XCTAssertGreaterThan(attachment.bounds.height, 0)

    let paragraph = ParagraphNSView()
    paragraph.setParagraphContents(rendered, animatedByWord: false)
    XCTAssertNotNil(paragraph.textLayoutManager)
    XCTAssertNotNil(paragraph.textContentStorage)
    XCTAssertTrue(attachment.usesTextAttachmentView)
    let label = attachment.makeLiveLabel()
    XCTAssertEqual(label.latex, "E=mc^2")
    XCTAssertEqual(label.mode, .text)
    XCTAssertEqual(label.frame.size, attachment.bounds.size)
    XCTAssertNil(label.error)
    XCTAssertNotNil(label.displayList)
  }

  @MainActor
  func testDisplayPresentationUsesIosMathDisplayMode() throws {
    let literal = #"\[\sum_{i=1}^{n} i\]"#
    let rendered = InlineMathAttachment.attributedString(
      source: #"\sum_{i=1}^{n} i"#,
      originalLiteral: literal,
      presentation: .display,
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )

    XCTAssertEqual(attachment.mathData.presentation, .display)
    XCTAssertEqual(rendered.plainTextRestoringInlineMath, literal)
    XCTAssertTrue(attachment.preflightLayout())
    XCTAssertEqual(attachment.makeLiveLabel().mode, .display)
  }

  @MainActor
  func testTextKitTwoNetworkResolvesDedicatedLiveMathProvider() throws {
    let rendered = InlineMathAttachment.attributedString(
      source: #"E=mc^2"#,
      originalLiteral: #"$E=mc^2$"#,
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )
    XCTAssertTrue(attachment.preflightLayout())

    let paragraph = ParagraphNSView()
    paragraph.frame = NSRect(x: 0, y: 0, width: 480, height: 80)
    let window = NSWindow(
      contentRect: paragraph.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = paragraph
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    paragraph.setParagraphContents(rendered, animatedByWord: false)
    _ = paragraph.measureSize(fittingWidth: 480)
    XCTAssertNil(attachment.image)
    let storedAttachment = try XCTUnwrap(
      paragraph.textStorage?.attribute(
        .attachment,
        at: 0,
        effectiveRange: nil
      ) as? InlineMathAttachment
    )
    XCTAssertTrue(storedAttachment === attachment)
    let layoutManager = try XCTUnwrap(paragraph.textLayoutManager)
    let contentStorage = try XCTUnwrap(paragraph.textContentStorage)
    let textContainer = try XCTUnwrap(paragraph.textContainer)
    let documentRange = try XCTUnwrap(contentStorage.documentRange)
    XCTAssertTrue(textContainer.textLayoutManager === layoutManager)
    XCTAssertTrue(contentStorage.primaryTextLayoutManager === layoutManager)
    XCTAssertEqual(attachment.fileType, InlineMathAttachment.typeIdentifier)
    XCTAssertTrue(attachment.usesTextAttachmentView)
    XCTAssertTrue(
      NSTextAttachment.textAttachmentViewProviderClass(
        forFileType: InlineMathAttachment.typeIdentifier
      ) === InlineMathAttachmentViewProvider.self
    )
    let directProvider = try XCTUnwrap(
      attachment.viewProvider(
        for: paragraph,
        location: documentRange.location,
        textContainer: textContainer
      ) as? InlineMathAttachmentViewProvider
    )
    XCTAssertTrue(directProvider.textLayoutManager === layoutManager)
    XCTAssertTrue(directProvider.view is InlineMathLabelView)
    let label = try XCTUnwrap(directProvider.view as? InlineMathLabelView)
    XCTAssertEqual(label.latex, "E=mc^2")
    XCTAssertEqual(label.frame.size, attachment.bounds.size)

    layoutManager.ensureLayout(for: documentRange)
    paragraph.layoutSubtreeIfNeeded()
    layoutManager.textViewportLayoutController.layoutViewport()
    // AppKit creates attachment view providers at the end of the current Core
    // Animation transaction. Flush that deterministic framework boundary
    // instead of sleeping or spinning the run loop.
    CATransaction.flush()
    layoutManager.textViewportLayoutController.layoutViewport()

    var providers: [NSTextAttachmentViewProvider] = []
    layoutManager.enumerateTextLayoutFragments(
      from: documentRange.location,
      options: [.ensuresLayout]
    ) { fragment in
      providers.append(contentsOf: fragment.textAttachmentViewProviders)
      return true
    }

    let layoutProvider = try XCTUnwrap(
      providers.first as? InlineMathAttachmentViewProvider
    )
    let layoutLabel = try XCTUnwrap(
      layoutProvider.view as? InlineMathLabelView
    )
    XCTAssertEqual(layoutLabel.latex, "E=mc^2")
    XCTAssertEqual(layoutLabel.frame.size, attachment.bounds.size)
    XCTAssertNotNil(layoutLabel.displayList)
  }

  @MainActor
  func testLiveMathLabelDrawsVisibleGlyphPixelsOffscreen() throws {
    let rendered = InlineMathAttachment.attributedString(
      source: #"E=mc^2"#,
      originalLiteral: #"$E=mc^2$"#,
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )
    XCTAssertTrue(attachment.preflightLayout())

    let label = attachment.makeLiveLabel()
    let host = NSView(frame: label.bounds)
    host.appearance = NSAppearance(named: .aqua)
    host.addSubview(label)
    label.viewDidChangeEffectiveAppearance()
    label.layoutSubtreeIfNeeded()
    label.displayIfNeeded()

    let bitmap = try XCTUnwrap(
      label.bitmapImageRepForCachingDisplay(in: label.bounds)
    )
    label.cacheDisplay(in: label.bounds, to: bitmap)
    var visibleDarkPixelCount = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?
          .usingColorSpace(.sRGB) else { continue }
        if color.alphaComponent > 0.1,
           color.redComponent < 0.75,
           color.greenComponent < 0.75,
           color.blueComponent < 0.75 {
          visibleDarkPixelCount += 1
        }
      }
    }
    XCTAssertGreaterThan(visibleDarkPixelCount, 10)
  }

  @MainActor
  func testMoreThanThirtyTwoFormulaAttachmentsPreflight() {
    for index in 1...40 {
      let source = "x_{\(index)}"
      let rendered = InlineMathAttachment.attributedString(
        source: source,
        originalLiteral: "$\(source)$",
        attributes: attributes()
      )
      guard let attachment = rendered.attribute(
        .attachment,
        at: 0,
        effectiveRange: nil
      ) as? InlineMathAttachment else {
        XCTFail("Expected formula \(index) to produce an attachment")
        return
      }
      XCTAssertTrue(attachment.preflightLayout())
      XCTAssertNil(attachment.image)
    }
  }

  @MainActor
  func testWideFormulaIsNotRejectedByLegacyAttachmentBound() throws {
    let source = String(repeating: "x", count: 300)
    let literal = "$\(source)$"
    let rendered = InlineMathAttachment.attributedString(
      source: source,
      originalLiteral: literal,
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )

    XCTAssertTrue(attachment.preflightLayout())
    XCTAssertGreaterThan(attachment.bounds.width, 1_024)
    XCTAssertNotEqual(
      materializeInlineMathAttachments(in: rendered).string,
      literal
    )
  }

  @MainActor
  func testSemanticLabelColorTracksActualHostAppearance() throws {
    let rendered = InlineMathAttachment.attributedString(
      source: "x",
      originalLiteral: "$x$",
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )
    XCTAssertTrue(attachment.preflightLayout())

    let host = NSView()
    host.appearance = NSAppearance(named: .aqua)
    let label = attachment.makeLiveLabel()
    host.addSubview(label)
    label.viewDidChangeEffectiveAppearance()
    let light = try XCTUnwrap(label.textColor.usingColorSpace(.sRGB))

    host.appearance = NSAppearance(named: .darkAqua)
    label.viewDidChangeEffectiveAppearance()
    let dark = try XCTUnwrap(label.textColor.usingColorSpace(.sRGB))

    XCTAssertLessThan(light.redComponent, 0.5)
    XCTAssertGreaterThan(dark.redComponent, 0.5)
  }

  @MainActor
  func testLiveLabelIsNotRetainedAfterParagraphReleasesIt() throws {
    let rendered = InlineMathAttachment.attributedString(
      source: "x",
      originalLiteral: "$x$",
      attributes: attributes()
    )
    let attachment = try XCTUnwrap(
      rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        as? InlineMathAttachment
    )
    XCTAssertTrue(attachment.preflightLayout())

    weak var weakLabel: InlineMathLabelView?
    autoreleasepool {
      let label = attachment.makeLiveLabel()
      weakLabel = label
      XCTAssertNotNil(weakLabel)
    }
    XCTAssertNil(weakLabel)
  }

  @MainActor
  func testNoMathMaterializationKeepsMutableFastPathIdentity() {
    let plain = NSMutableAttributedString(string: "ordinary markdown text")

    let result = materializeInlineMathAttachments(in: plain)

    XCTAssertTrue(result === plain)
  }
}
#endif
