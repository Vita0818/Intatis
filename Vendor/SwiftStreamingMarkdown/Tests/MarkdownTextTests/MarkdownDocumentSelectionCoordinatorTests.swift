//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import AppKit
@testable import SwiftStreamingMarkdown
import SwiftUI
import Testing

@Suite("Markdown document selection coordinator")
@MainActor
struct MarkdownDocumentSelectionCoordinatorTests {
  @Test("Forward drag selects every native text leaf in document order")
  func forwardSelectionAcrossParagraphs() throws {
    let fixture = makeVerticalFixture()
    fixture.coordinator.beginSelection(
      in: fixture.views[0],
      atCharacterIndex: 6
    )
    fixture.coordinator.extendSelection(
      to: fixture.views[2],
      characterIndex: 5
    )
    fixture.coordinator.finishSelection()

    #expect(fixture.coordinator.coordinatedRange(in: fixture.views[0]) == NSRange(location: 6, length: 7))
    #expect(fixture.coordinator.coordinatedRange(in: fixture.views[1]) == NSRange(location: 0, length: 15))
    #expect(fixture.coordinator.coordinatedRange(in: fixture.views[2]) == NSRange(location: 0, length: 5))
    #expect(fixture.views[0].selectedRange() == NSRange(location: 6, length: 7))
    #expect(fixture.views[0].selectedTextAttributes.isEmpty)
    #expect(fixture.views[1].selectedRange().length == 0)
    #expect(fixture.views[2].selectedRange().length == 0)
    #expect(
      fixture.coordinator.selectedPlainText
        == "heading\nMiddle sentence\nThird"
    )
  }

  @Test("Reverse drag keeps one contiguous document-order selection")
  func reverseSelectionAcrossParagraphs() throws {
    let fixture = makeVerticalFixture()
    fixture.coordinator.beginSelection(
      in: fixture.views[2],
      atCharacterIndex: 5
    )
    fixture.coordinator.extendSelection(
      to: fixture.views[0],
      characterIndex: 6
    )

    #expect(fixture.coordinator.coordinatedRange(in: fixture.views[0]) == NSRange(location: 6, length: 7))
    #expect(fixture.coordinator.coordinatedRange(in: fixture.views[1]) == NSRange(location: 0, length: 15))
    #expect(fixture.coordinator.coordinatedRange(in: fixture.views[2]) == NSRange(location: 0, length: 5))
    #expect(
      fixture.coordinator.selectedPlainText
        == "heading\nMiddle sentence\nThird"
    )
  }

  @Test("Window-space drag point resolves a different native leaf")
  func windowPointResolvesTargetLeaf() {
    let fixture = makeVerticalFixture()
    fixture.coordinator.beginSelection(
      in: fixture.views[0],
      atCharacterIndex: 1
    )
    let targetPointInWindow = NSPoint(x: 80, y: 70)
    let targetPointInAnchor = fixture.views[0].convert(
      targetPointInWindow,
      from: nil
    )

    fixture.coordinator.extendSelection(
      from: fixture.views[0],
      to: targetPointInAnchor
    )

    #expect(
      fixture.coordinator.coordinatedRange(in: fixture.views[1]).length
        == fixture.views[1].string.utf16.count
    )
    #expect(
      fixture.coordinator.coordinatedRange(in: fixture.views[2]).length > 0
    )
  }

  @Test("Table-row leaves copy with a tab separator")
  func sameRowSelectionUsesTabSeparator() {
    let coordinator = MarkdownDocumentSelectionCoordinator()
    let window = makeWindow()
    let first = makeView(
      "left cell",
      frame: NSRect(x: 20, y: 100, width: 180, height: 40)
    )
    let second = makeView(
      "right cell",
      frame: NSRect(x: 220, y: 100, width: 180, height: 40)
    )
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    coordinator.register(first)
    coordinator.register(second)

    coordinator.beginSelection(in: first, atCharacterIndex: 0)
    coordinator.extendSelection(to: second, characterIndex: second.string.utf16.count)

    #expect(coordinator.selectedPlainText == "left cell\tright cell")
  }

  @Test("Document registration order is stable across unequal table heights")
  func registrationOrderSurvivesUnequalTableHeights() {
    let coordinator = MarkdownDocumentSelectionCoordinator()
    let window = makeWindow()
    let first = makeView(
      "first",
      frame: NSRect(x: 20, y: 180, width: 150, height: 40)
    )
    let tallMiddle = makeView(
      "tall middle",
      frame: NSRect(x: 190, y: 80, width: 180, height: 160)
    )
    let last = makeView(
      "last",
      frame: NSRect(x: 390, y: 180, width: 150, height: 40)
    )
    for view in [first, tallMiddle, last] {
      window.contentView?.addSubview(view)
      coordinator.register(view)
    }

    coordinator.beginSelection(in: first, atCharacterIndex: 0)
    coordinator.extendSelection(
      to: last,
      characterIndex: last.string.utf16.count
    )

    #expect(
      coordinator.coordinatedRange(in: tallMiddle).length
        == tallMiddle.string.utf16.count
    )
  }

  @Test("Distributed copy writes one combined plain-text value")
  func copiesCombinedSelection() {
    let fixture = makeVerticalFixture()
    fixture.coordinator.beginSelection(
      in: fixture.views[0],
      atCharacterIndex: 6
    )
    fixture.coordinator.extendSelection(
      to: fixture.views[2],
      characterIndex: 5
    )
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("Intatis.Selection.\(UUID().uuidString)")
    )

    #expect(fixture.coordinator.copySelection(to: pasteboard))
    #expect(
      pasteboard.string(forType: .string)
        == "heading\nMiddle sentence\nThird"
    )
  }

  @Test("Every distributed range uses one system selection appearance")
  func everyRangeUsesOneSystemSelectionAppearance() async throws {
    let fixture = makeVerticalFixture()
    fixture.coordinator.beginSelection(
      in: fixture.views[0],
      atCharacterIndex: 1
    )
    fixture.coordinator.extendSelection(
      to: fixture.views[2],
      characterIndex: 5
    )
    fixture.coordinator.finishSelection()
    await Task.yield()

    let referenceView = fixture.views[0]
    let referenceRange = try #require(
      fixture.coordinator.coordinatedRange(in: referenceView).nonEmpty
    )
    let expectedBackground = NSColor.selectedTextBackgroundColor
    let expectedForeground = NSColor.selectedTextColor

    for view in fixture.views {
      let range = try #require(
        fixture.coordinator.coordinatedRange(in: view).nonEmpty
      )
      let background = try #require(
        view.textStorage?.attribute(
          .backgroundColor,
          at: range.location,
          effectiveRange: nil
        ) as? NSColor
      )
      let foreground = try #require(
        view.textStorage?.attribute(
          .foregroundColor,
          at: range.location,
          effectiveRange: nil
        ) as? NSColor
      )

      #expect(background.isEqual(expectedBackground))
      #expect(foreground.isEqual(expectedForeground))
      if view === referenceView {
        #expect(view.selectedRange() == range)
        #expect(view.selectedTextAttributes.isEmpty)
      } else {
        #expect(view.selectedRange().length == 0)
      }
    }

    #expect(referenceRange.length > 0)
  }

  @Test("Streaming content replacement cancels stale distributed ranges")
  func contentReplacementCancelsSelection() {
    let fixture = makeVerticalFixture()
    fixture.coordinator.beginSelection(
      in: fixture.views[0],
      atCharacterIndex: 1
    )
    fixture.coordinator.extendSelection(
      to: fixture.views[1],
      characterIndex: 4
    )

    fixture.views[1].setParagraphContents(
      NSMutableAttributedString(string: "replacement"),
      animatedByWord: false
    )

    #expect(!fixture.coordinator.isSelectionActive)
    #expect(fixture.views.allSatisfy { $0.selectedRange().length == 0 })
  }

  @Test("Ordinary click cleanup restores the exact attributed projection")
  func ordinaryClickRestoresAttributedProjection() {
    let coordinator = MarkdownDocumentSelectionCoordinator()
    let view = ParagraphNSView()
    let original = NSMutableAttributedString(
      string: "Styled selection",
      attributes: [
        .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
        .foregroundColor: NSColor.systemRed,
        .kern: 0.75,
      ]
    )
    view.setParagraphContents(original, lineSpacing: 4, animatedByWord: false)
    view.setDocumentSelectionCoordinator(coordinator)
    let baseline = NSAttributedString(attributedString: view.textStorage!)
    coordinator.beginSelection(in: view, atCharacterIndex: 0)
    coordinator.extendSelection(
      to: view,
      characterIndex: view.string.utf16.count
    )
    coordinator.finishSelection()
    #expect(view.textStorage?.attribute(
      .backgroundColor,
      at: 0,
      effectiveRange: nil
    ) != nil)

    coordinator.prepareForNativeMouseDown(in: view)

    #expect(!coordinator.isSelectionActive)
    #expect(view.selectedRange().length == 0)
    #expect(
      (view.selectedTextAttributes[.backgroundColor] as? NSColor)?
        .isEqual(NSColor.selectedTextBackgroundColor) == true
    )
    #expect(view.textStorage?.isEqual(to: baseline) == true)
  }

  @Test("Paragraph installs a delayed primary-button pan recognizer")
  func paragraphInstallsNativeDragRecognizer() throws {
    let view = makeView("selectable", frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    let recognizer = try #require(
      view.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }.first
    )

    #expect(recognizer.buttonMask == 1)
    #expect(recognizer.delaysPrimaryMouseButtonEvents)
  }

  @Test("DocumentView injects one coordinator into every native paragraph")
  func documentViewInjectsCoordinator() throws {
    let config = MarkdownRenderConfig()
    let document = RenderableDocument(renderables: [
      .heading(
        id: "heading",
        level: 1,
        content: NSMutableAttributedString(string: "Heading")
      ),
      .paragraph(
        id: "first",
        content: NSMutableAttributedString(string: "First paragraph")
      ),
      .paragraph(
        id: "second",
        content: NSMutableAttributedString(string: "Second paragraph")
      ),
    ])
    let host = NSHostingView(rootView: DocumentView(
      renderableDocument: document,
      config: config
    ))
    let window = makeWindow()
    window.contentView = host
    host.frame = window.contentView?.bounds ?? .zero
    host.layoutSubtreeIfNeeded()

    let paragraphs = paragraphSubviews(in: host)

    #expect(paragraphs.count == 3)
    #expect(paragraphs.allSatisfy {
      $0.documentSelectionCoordinatorReference != nil
    })
  }

  @Test("Native table leaves retain nonzero measured frames and text")
  func nativeTableLeavesRemainVisible() {
    let config = MarkdownRenderConfig()
    let document = RenderableDocument(renderables: [
      .table(
        id: "table",
        headers: [
          NSMutableAttributedString(string: "First"),
          NSMutableAttributedString(string: "Second"),
        ],
        rows: [[
          NSMutableAttributedString(string: "Alpha"),
          NSMutableAttributedString(string: "Beta"),
        ]],
        rawMarkdown: ""
      ),
    ])
    let host = NSHostingView(rootView: DocumentView(
      renderableDocument: document,
      config: config
    ))
    let window = makeWindow()
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 560, height: 260)
    host.layoutSubtreeIfNeeded()

    let paragraphs = paragraphSubviews(in: host)

    #expect(paragraphs.count == 4)
    #expect(paragraphs.allSatisfy { !$0.string.isEmpty })
    #expect(paragraphs.allSatisfy { $0.bounds.width > 10 })
    #expect(paragraphs.allSatisfy { $0.bounds.height > 0 })

    let first = paragraphs.first { $0.string == "First" }
    let second = paragraphs.first { $0.string == "Second" }
    let alpha = paragraphs.first { $0.string == "Alpha" }
    let beta = paragraphs.first { $0.string == "Beta" }
    let coordinator = first?.documentSelectionCoordinatorReference
    #expect(coordinator != nil)
    #expect(paragraphs.allSatisfy {
      $0.documentSelectionCoordinatorReference === coordinator
    })
    if let coordinator, let first, let second, let alpha, let beta {
      coordinator.beginSelection(in: first, atCharacterIndex: 0)
      coordinator.extendSelection(
        to: beta,
        characterIndex: beta.string.utf16.count
      )
      #expect(
        coordinator.coordinatedRange(in: second).length
          == second.string.utf16.count
      )
      #expect(
        coordinator.coordinatedRange(in: alpha).length
          == alpha.string.utf16.count
      )
    }
  }

  @Test("List item paragraphs participate in document-order selection")
  func listItemsParticipateInSelection() {
    let config = MarkdownRenderConfig()
    let document = RenderableDocument(renderables: [
      .heading(
        id: "heading",
        level: 1,
        content: NSMutableAttributedString(string: "Heading")
      ),
      .orderedList(
        id: "list",
        items: [
          MarkdownListItem(
            children: [.paragraph(
              id: "first-item",
              content: NSMutableAttributedString(string: "First item")
            )],
            startsWithBold: false
          ),
          MarkdownListItem(
            children: [.paragraph(
              id: "second-item",
              content: NSMutableAttributedString(string: "Second item")
            )],
            startsWithBold: false
          ),
        ]
      ),
      .paragraph(
        id: "ending",
        content: NSMutableAttributedString(string: "Ending paragraph")
      ),
    ])
    let host = NSHostingView(rootView: DocumentView(
      renderableDocument: document,
      config: config
    ))
    let window = makeWindow()
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 560, height: 260)
    host.layoutSubtreeIfNeeded()
    let paragraphs = paragraphSubviews(in: host)
    let heading = paragraphs.first { $0.string == "Heading" }
    let first = paragraphs.first { $0.string == "First item" }
    let second = paragraphs.first { $0.string == "Second item" }
    let ending = paragraphs.first { $0.string == "Ending paragraph" }
    let coordinator = heading?.documentSelectionCoordinatorReference

    if let coordinator, let heading, let first, let second, let ending {
      coordinator.beginSelection(in: heading, atCharacterIndex: 0)
      coordinator.extendSelection(to: ending, characterIndex: 6)
      #expect(
        coordinator.coordinatedRange(in: first).length
          == first.string.utf16.count
      )
      #expect(
        coordinator.coordinatedRange(in: second).length
          == second.string.utf16.count
      )
    } else {
      Issue.record("Expected every list selection leaf and one coordinator")
    }
  }

  @Test("Unwrapped code layout reports its full native width")
  func unwrappedCodeMeasuresFullWidth() {
    let view = makeView(
      String(repeating: "wide-code-token ", count: 40),
      frame: NSRect(x: 0, y: 0, width: 120, height: 40)
    )
    view.setParagraphLayoutMode(.unwrapped)

    let unwrapped = view.measureSize(fittingWidth: 120)

    #expect(unwrapped.width > 120)
    #expect(unwrapped.height > 0)
    #expect(view.paragraphLayoutMode == .unwrapped)
  }

  private func makeVerticalFixture() -> (
    coordinator: MarkdownDocumentSelectionCoordinator,
    window: NSWindow,
    views: [ParagraphNSView]
  ) {
    let coordinator = MarkdownDocumentSelectionCoordinator()
    let window = makeWindow()
    let views = [
      makeView("Alpha heading", frame: NSRect(x: 20, y: 190, width: 500, height: 40)),
      makeView("Middle sentence", frame: NSRect(x: 20, y: 120, width: 500, height: 40)),
      makeView("Third paragraph", frame: NSRect(x: 20, y: 50, width: 500, height: 40)),
    ]
    for view in views {
      window.contentView?.addSubview(view)
      view.setDocumentSelectionCoordinator(coordinator)
    }
    return (coordinator, window, views)
  }

  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
  }

  private func makeView(_ text: String, frame: NSRect) -> ParagraphNSView {
    let view = ParagraphNSView()
    view.frame = frame
    view.setParagraphContents(
      NSMutableAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 18)]
      ),
      animatedByWord: false
    )
    return view
  }

  private func paragraphSubviews(in root: NSView) -> [ParagraphNSView] {
    var result: [ParagraphNSView] = []
    if let paragraph = root as? ParagraphNSView {
      result.append(paragraph)
    }
    for subview in root.subviews {
      result.append(contentsOf: paragraphSubviews(in: subview))
    }
    return result
  }
}

private extension NSRange {
  var nonEmpty: NSRange? {
    length > 0 ? self : nil
  }
}
#endif
