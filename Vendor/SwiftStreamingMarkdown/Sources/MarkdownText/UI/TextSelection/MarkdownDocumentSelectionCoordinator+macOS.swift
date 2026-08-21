//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: direct cross-block AppKit text selection.
//

#if canImport(AppKit)
import AppKit
import SwiftUI

/// Coordinates one native drag selection across the paragraph text views that
/// make up a single rendered Markdown document.
///
/// SwiftStreamingMarkdown deliberately keeps one `NSTextView` per paragraph so
/// headings, lists, block quotes, tables, code, and TextKit attachments retain
/// their native layout owners. AppKit normally terminates selection at the
/// boundary of the originating text view. This coordinator leaves those native
/// owners in place and distributes one contiguous document selection across
/// them. No second renderer, selection overlay, or derived document is created.
@MainActor
final class MarkdownDocumentSelectionCoordinator: ObservableObject {
  private final class WeakEntry {
    weak var view: ParagraphNSView?
    let sequence: UInt64

    init(view: ParagraphNSView, sequence: UInt64) {
      self.view = view
      self.sequence = sequence
    }
  }

  private var entries: [ObjectIdentifier: WeakEntry] = [:]
  private var nextSequence: UInt64 = 0
  private weak var anchorView: ParagraphNSView?
  private var anchorCharacterIndex: Int?
  private var selectedRanges: [ObjectIdentifier: NSRange] = [:]
  private(set) var isSelectionActive = false

  func register(_ view: ParagraphNSView) {
    removeReleasedEntries()
    let identifier = ObjectIdentifier(view)
    guard entries[identifier]?.view !== view else { return }
    nextSequence &+= 1
    entries[identifier] = WeakEntry(view: view, sequence: nextSequence)
  }

  func unregister(_ view: ParagraphNSView) {
    let identifier = ObjectIdentifier(view)
    let wasSelected = coordinatedRange(in: view).length > 0
    guard entries.removeValue(forKey: identifier) != nil else { return }
    if wasSelected {
      view.clearCoordinatedSelection()
    }
    if anchorView === view || (isSelectionActive && wasSelected) {
      cancelSelection()
    }
  }

  /// Clears a previous distributed selection before AppKit handles a fresh
  /// ordinary click, word selection, or insertion-point move in one leaf.
  func prepareForNativeMouseDown(in _: ParagraphNSView) {
    guard isSelectionActive else { return }
    clearSelectedRanges(except: nil)
    resetSelectionState()
  }

  /// A streaming replacement invalidates document character positions. Clear
  /// the transient selection rather than rebinding it to unrelated new text.
  func contentsWillChange(in _: ParagraphNSView) {
    guard isSelectionActive else { return }
    cancelSelection()
  }

  func beginSelection(in view: ParagraphNSView, atCharacterIndex index: Int) {
    if isSelectionActive {
      cancelSelection()
    }
    register(view)
    clearSelectedRanges(except: view)
    view.setCoordinatedSelectionRange(nil)
    anchorView = view
    anchorCharacterIndex = clamped(index, in: view)
    isSelectionActive = true
    applySelection(to: view, characterIndex: index)
  }

  func beginSelection(in view: ParagraphNSView, at point: NSPoint) {
    beginSelection(
      in: view,
      atCharacterIndex: insertionIndex(in: view, at: point)
    )
  }

  func extendSelection(to view: ParagraphNSView, characterIndex index: Int) {
    guard isSelectionActive else { return }
    register(view)
    applySelection(to: view, characterIndex: index)
  }

  func extendSelection(from sourceView: ParagraphNSView, to point: NSPoint) {
    guard isSelectionActive, let window = sourceView.window else { return }

    if let event = NSApp.currentEvent,
       event.type == .leftMouseDragged {
      _ = sourceView.autoscroll(with: event)
    }

    let pointInWindow = sourceView.convert(point, to: nil)
    guard let target = nearestView(toWindowPoint: pointInWindow, in: window) else {
      return
    }
    let targetPoint = target.convert(pointInWindow, from: nil)
    extendSelection(
      to: target,
      characterIndex: insertionIndex(in: target, at: targetPoint)
    )
  }

  func finishSelection() {
    guard isSelectionActive else { return }
    let views = orderedViews()
    let selectedView = views.first {
      coordinatedRange(in: $0).length > 0
    }
    if let selectedView {
      selectedView.window?.makeFirstResponder(selectedView)
      for view in views {
        view.emphasizeCoordinatedSelection()
        view.clearNativeSelectionKeepingCoordinatedEmphasis()
      }
      selectedView.activateCoordinatedSelectionAsPrimary()
    } else {
      resetSelectionState()
    }
  }

  func cancelSelection() {
    clearSelectedRanges(except: nil)
    resetSelectionState()
  }

  @discardableResult
  func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
    guard let text = selectedPlainText, !text.isEmpty else { return false }
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }

  var selectedPlainText: String? {
    guard isSelectionActive else { return nil }
    let selectedViews = orderedViews().compactMap { view -> (ParagraphNSView, String)? in
      let range = coordinatedRange(in: view)
      guard range.length > 0,
            let text = view.plainTextForCoordinatedSelection(in: range),
            !text.isEmpty else {
        return nil
      }
      return (view, text)
    }
    guard !selectedViews.isEmpty else { return nil }

    var result = selectedViews[0].1
    for index in selectedViews.indices.dropFirst() {
      let previous = selectedViews[index - 1].0
      let current = selectedViews[index].0
      result.append(selectionSeparator(between: previous, and: current))
      result.append(selectedViews[index].1)
    }
    return result
  }

  var hasCopyableSelection: Bool {
    isSelectionActive && selectedRanges.values.contains { $0.length > 0 }
  }

  var registeredViewCount: Int {
    removeReleasedEntries()
    return entries.count
  }

  func coordinatedRange(in view: ParagraphNSView) -> NSRange {
    selectedRanges[ObjectIdentifier(view)]
      ?? NSRange(location: 0, length: 0)
  }

  private func applySelection(
    to targetView: ParagraphNSView,
    characterIndex targetCharacterIndex: Int
  ) {
    guard let anchorView,
          let anchorCharacterIndex else {
      return
    }
    let views = orderedViews()
    guard let anchorPosition = views.firstIndex(where: { $0 === anchorView }),
          let targetPosition = views.firstIndex(where: { $0 === targetView }) else {
      return
    }

    let anchorIndex = clamped(anchorCharacterIndex, in: anchorView)
    let targetIndex = clamped(targetCharacterIndex, in: targetView)
    let isForward = anchorPosition < targetPosition
      || (anchorPosition == targetPosition && anchorIndex <= targetIndex)

    for (position, view) in views.enumerated() {
      let length = view.textStorage?.length ?? 0
      let range: NSRange
      if anchorPosition == targetPosition {
        if position == anchorPosition {
          range = NSRange(
            location: min(anchorIndex, targetIndex),
            length: abs(targetIndex - anchorIndex)
          )
        } else {
          range = NSRange(location: 0, length: 0)
        }
      } else if isForward {
        switch position {
        case anchorPosition:
          range = NSRange(location: anchorIndex, length: length - anchorIndex)
        case targetPosition:
          range = NSRange(location: 0, length: targetIndex)
        case (anchorPosition + 1)..<targetPosition:
          range = NSRange(location: 0, length: length)
        default:
          range = NSRange(location: 0, length: 0)
        }
      } else {
        switch position {
        case targetPosition:
          range = NSRange(location: targetIndex, length: length - targetIndex)
        case anchorPosition:
          range = NSRange(location: 0, length: anchorIndex)
        case (targetPosition + 1)..<anchorPosition:
          range = NSRange(location: 0, length: length)
        default:
          range = NSRange(location: 0, length: 0)
        }
      }
      let identifier = ObjectIdentifier(view)
      if range.length > 0 {
        selectedRanges[identifier] = range
        view.setCoordinatedSelectionRange(range)
      } else {
        selectedRanges.removeValue(forKey: identifier)
        view.setCoordinatedSelectionRange(nil)
      }
    }
  }

  private func orderedViews() -> [ParagraphNSView] {
    removeReleasedEntries()
    return entries.values
      .sorted { $0.sequence < $1.sequence }
      .compactMap(\.view)
  }

  private func nearestView(
    toWindowPoint pointInWindow: NSPoint,
    in window: NSWindow
  ) -> ParagraphNSView? {
    let screenPoint = window.convertPoint(toScreen: pointInWindow)
    let candidates = orderedViews().compactMap { view -> (ParagraphNSView, NSRect)? in
      guard view.window === window,
            !view.isHidden,
            view.alphaValue > 0,
            (view.textStorage?.length ?? 0) > 0,
            let frame = screenFrame(of: view) else {
        return nil
      }
      return (view, frame)
    }
    guard !candidates.isEmpty else { return nil }

    if let containing = candidates.first(where: { $0.1.contains(screenPoint) }) {
      return containing.0
    }

    return candidates.min { lhs, rhs in
      squaredDistance(from: screenPoint, to: lhs.1)
        < squaredDistance(from: screenPoint, to: rhs.1)
    }?.0
  }

  private func insertionIndex(in view: ParagraphNSView, at point: NSPoint) -> Int {
    let length = view.textStorage?.length ?? 0
    guard length > 0 else { return 0 }
    if point.y <= view.bounds.minY {
      return 0
    }
    if point.y >= view.bounds.maxY {
      return length
    }
    return min(max(view.characterIndexForInsertion(at: point), 0), length)
  }

  private func clamped(_ index: Int, in view: ParagraphNSView) -> Int {
    min(max(index, 0), view.textStorage?.length ?? 0)
  }

  private func clearSelectedRanges(except retainedView: ParagraphNSView?) {
    for view in orderedViews() where view !== retainedView {
      selectedRanges.removeValue(forKey: ObjectIdentifier(view))
      view.clearCoordinatedSelection()
    }
  }

  private func resetSelectionState() {
    anchorView = nil
    anchorCharacterIndex = nil
    selectedRanges.removeAll(keepingCapacity: true)
    isSelectionActive = false
  }

  private func removeReleasedEntries() {
    entries = entries.filter { $0.value.view != nil }
  }

  private func screenFrame(of view: NSView) -> NSRect? {
    guard let window = view.window else { return nil }
    return window.convertToScreen(view.convert(view.bounds, to: nil))
  }

  private func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
    let dx: CGFloat
    if point.x < rect.minX {
      dx = rect.minX - point.x
    } else if point.x > rect.maxX {
      dx = point.x - rect.maxX
    } else {
      dx = 0
    }

    let dy: CGFloat
    if point.y < rect.minY {
      dy = rect.minY - point.y
    } else if point.y > rect.maxY {
      dy = point.y - rect.maxY
    } else {
      dy = 0
    }
    return dx * dx + dy * dy
  }

  private func selectionSeparator(
    between lhs: ParagraphNSView,
    and rhs: ParagraphNSView
  ) -> String {
    guard let lhsFrame = screenFrame(of: lhs),
          let rhsFrame = screenFrame(of: rhs) else {
      return "\n"
    }
    let overlap = max(
      0,
      min(lhsFrame.maxY, rhsFrame.maxY) - max(lhsFrame.minY, rhsFrame.minY)
    )
    let referenceHeight = max(1, min(lhsFrame.height, rhsFrame.height))
    return overlap / referenceHeight >= 0.5 ? "\t" : "\n"
  }
}

extension EnvironmentValues {
  @Entry var markdownDocumentSelectionCoordinator: MarkdownDocumentSelectionCoordinator?
}
#endif
