//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum RowContent: Equatable {
  case text(string: AttributedString)
  case containsAttachment(string: NSAttributedString)
}

struct TableView: View {
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  let headings: [RowContent]
  let rows: [[RowContent]]
  let columnMaxWidths: [Int: CGFloat]

  private let defaultMaxColumnWidth: CGFloat = 200
  @State private var scrollWidth: CGFloat = 0
  init(headings: [NSMutableAttributedString], rows: [[NSMutableAttributedString]], columnMaxWidths: [Int: CGFloat] = [:], rawMarkdown: String = "") {
    self.headings = headings.map { content in
      if content.containsAttachments(in: NSRange(location: 0, length: content.length)) {
        return .containsAttachment(string: content)
      }
      return .text(string: AttributedString(content))
    }
    self.rows = rows.map { row in
      row.map { content in
        if content.containsAttachments(in: NSRange(location: 0, length: content.length)) {
          return .containsAttachment(string: content)
        } else {
          return .text(string: AttributedString(content))
        }
      }
    }

    self.columnMaxWidths = columnMaxWidths
  }

  private var numOfRows: Int {
    return rows.count
  }

  @ViewBuilder
  private func headerView(colIdx: Int) -> some View {
    HStack(spacing: 0) {
      switch headings[colIdx] {
      case .containsAttachment(let content):
        ParagraphView(contents: applyTypographyThemingAndGetContent(
          content,
          color: MDColor(config.tableStyle.headerTextColor)
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityValue(String.itemPositionInTable(
          rowIndex: 1,
          totalRow: numOfRows + 1,
          columnIndex: colIdx + 1,
          totalColumn: headings.count
        ))
      case .text(let content):
        Text(content)
          .foregroundStyle(config.tableStyle.headerTextColor)
          .textSelection(.enabled)
          .lineLimit(nil)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .if(config.shouldAnimateText) { view in
            view.fadeInTextTransition(attributedString: content)
          }
          .accessibilityValue(String.itemPositionInTable(
            rowIndex: 1,
            totalRow: numOfRows + 1,
            columnIndex: colIdx + 1,
            totalColumn: headings.count
          ))
      }
      Spacer()
    }
    .padding(12)
    .id("\(colIdx)-heading")
    .background(config.tableStyle.headerBackgroundColor)
    .applyHeaderBorder(colIndex: colIdx, colCount: headings.count, color: config.tableStyle.borderColor)
  }

  @ViewBuilder
  var gridView: some View {
    VStack(alignment: .leading, spacing: 0) {
      TableLayout(columnCount: headings.count, columnMaxWidths: self.actualColumnMaxWidths()) {
        ForEach(0..<headings.count, id: \.self) { colIdx in
          headerView(colIdx: colIdx)
        }

        ForEach(0..<numOfRows, id: \.self) { rowIdx in
          ForEach(0..<headings.count, id: \.self) { colIdx in
            gridCellViewFor(rowIdx: rowIdx, colIdx: colIdx)
          }
        }
      }
    }
  }

  private func actualColumnMaxWidths() -> [CGFloat] {
    let averageWidth = scrollWidth / CGFloat(headings.count)
    var actualColumnMaxWidths = Array(repeating: CGFloat(0), count: headings.count)
    for idx in 0..<headings.count {
      let maxColumnWidth = columnMaxWidths[idx] ?? defaultMaxColumnWidth
      actualColumnMaxWidths[idx] = max(averageWidth, maxColumnWidth)
    }

    return actualColumnMaxWidths
  }

  @ViewBuilder
  private func gridCellViewFor(rowIdx: Int, colIdx: Int) -> some View {
    let content = rows[rowIdx][colIdx]
    switch content {
    case .containsAttachment(let nsAttributedString):
      HStack(spacing: 0) {
        ParagraphView(contents: applyTypographyThemingAndGetContent(
          nsAttributedString,
          color: MDColor(config.tableStyle.regularTextColor)
        ))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .accessibilityValue(String.itemPositionInTable(rowIndex: rowIdx + 2, totalRow: numOfRows + 1, columnIndex: colIdx + 1, totalColumn: headings.count))
        Spacer()
      }
      .frame(maxHeight: .infinity)
      .padding(12)
      .id("\(colIdx)-\(rowIdx)")
      .applyCellBorder(colIndex: colIdx, colCount: headings.count, rowIndex: rowIdx, rowCount: numOfRows, color: config.tableStyle.borderColor)
    case .text(let attributedString):
      HStack(spacing: 0) {
        Text(attributedString)
          .foregroundStyle(config.tableStyle.regularTextColor)
          .textSelection(.enabled)
          .lineLimit(nil)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .if(config.shouldAnimateText) { view in
            view.fadeInTextTransition(attributedString: attributedString)
          }
          .accessibilityValue(String.itemPositionInTable(rowIndex: rowIdx + 2, totalRow: numOfRows + 1, columnIndex: colIdx + 1, totalColumn: headings.count))
        Spacer()
      }
      .frame(maxHeight: .infinity)
      .padding(12)
      .id("\(colIdx)-\(rowIdx)")
      .applyCellBorder(colIndex: colIdx, colCount: headings.count, rowIndex: rowIdx, rowCount: numOfRows, color: config.tableStyle.borderColor)
    }
  }

  var body: some View {
    scrollView
  }

  var scrollView: some View {
    ScrollView([.horizontal]) {
      gridView
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .inset(by: 0.5)
            .stroke(config.tableStyle.borderColor, lineWidth: 1)
        )
        .cornerRadius(12)
        .onWidthChange { newWidth in
          scrollWidth = newWidth
        }
    }
    .background {
      GeometryReader { geo in
        Color.clear
          .task(id: geo.size.width) {
            scrollWidth = geo.size.width
          }
      }
    }
    .scrollIndicators(.hidden)
    .contentShape(Rectangle())
  }

}

extension View {

  func applyHeaderBorder(colIndex: Int, colCount: Int, color: Color) -> some View {
    var edges: [Edge] = [.bottom]
    if colIndex != colCount - 1 {
      edges.append(.trailing)
    }
    return border(width: 1, edges: edges, color: color)
  }

  func applyCellBorder(colIndex: Int, colCount: Int, rowIndex: Int, rowCount: Int, color: Color) -> some View {
    var edges: [Edge] = []
    if rowIndex < rowCount - 1 {
      edges.append(.bottom)
    }
    if colIndex < colCount - 1 {
      edges.append(.trailing)
    }
    return border(width: 1, edges: edges, color: color)
  }

  @ViewBuilder
  func fadeInTextTransition(attributedString: AttributedString) -> some View {
    self.fadeInTextTransition(config: .variableDuration(
      glyphCount: attributedString.characters.count,
      glyphDelay: 0.02,
      glyphDuration: 0.2))
  }
}

struct TableLayout: Layout {
  struct CacheData {
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
  }

  let columnCount: Int
  let columnMaxWidths: [CGFloat]

  private let defaultRowHeight: CGFloat = 44

  func makeCache(subviews: Subviews) -> CacheData {
    guard columnCount > 0 else { return CacheData(columnWidths: [], rowHeights: []) }
    let rowCount = subviews.count / columnCount

    var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
    for row in 0..<rowCount {
      for col in 0..<columnCount {
        let index = row * columnCount + col
        let size = subviews[index].sizeThatFits(.unspecified)
        columnWidths[col] = min(max(columnWidths[col], size.width), columnMaxWidths[col])
      }
    }

    var rowHeights = Array(repeating: CGFloat(0), count: rowCount)
    for row in 0..<rowCount {
      var rowHeight: CGFloat = 0
      for col in 0..<columnCount {
        let index = row * columnCount + col
        let height = subviews[index].sizeThatFits(.init(width: columnWidths[col], height: nil)).height
        let cellHeight = height.isFinite ? height : defaultRowHeight
        rowHeight = max(rowHeight, cellHeight)
      }
      rowHeights[row] = rowHeight
    }

    return CacheData(columnWidths: columnWidths, rowHeights: rowHeights)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
    let totalWidth = cache.columnWidths.reduce(0, +)
    let totalHeight = cache.rowHeights.reduce(0, +)
    return CGSize(width: totalWidth, height: totalHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
    guard bounds.origin.y.isFinite else {
      return
    }
    let rowCount = subviews.count / columnCount
    var y: CGFloat = bounds.origin.y

    for row in 0..<rowCount {
      var x: CGFloat = bounds.minX.isNaN ? 0 : bounds.minX
      let rowHeight = cache.rowHeights[row]

      for col in 0..<columnCount {
        let index = row * columnCount + col
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: .init(width: cache.columnWidths[col], height: rowHeight))
        x += cache.columnWidths[col]
      }

      y += rowHeight
    }
  }
}

// MARK: - Helper Functions
extension TableView {
  /// Apply typography theming and return themed content for use with ParagraphView
  private func applyTypographyThemingAndGetContent(
    _ attributedString: NSAttributedString,
    color themeColor: MDColor
  ) -> NSMutableAttributedString {
    // Apply typography theming for table cells
    let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)
    let fullRange = NSRange(location: 0, length: mutableAttributedString.length)
    // Apply theme color to text that doesn't already have a foreground color
    mutableAttributedString.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { existingColor, range, _ in
      if existingColor == nil {
        mutableAttributedString.addAttribute(.foregroundColor, value: themeColor, range: range)
      }
    }

    // Apply citation baseline offset for proper alignment
    // This is needed because table cells bypass Paragraph+ parsing where baseline offset is normally applied
    var containsCitationAttachments = false
    var containsNonAttachmentContent = false
    var citationRanges: [NSRange] = []

    // One pass: detect & collect citation ranges
    mutableAttributedString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
      guard range.length > 0 else { return }

      // Check if it's a citation attachment
      if let citationAttachment = attributes[.attachment] as? InlineCitationAttachment,
         citationAttachment.citationData != nil {
        containsCitationAttachments = true
        citationRanges.append(range)
        return
      }

      if attributes[.link] != nil {
        containsNonAttachmentContent = true
        return
      }

      // Plain text (non-attachment content)
      containsNonAttachmentContent = true
    }

    // Apply baseline offset only when we have both citations and non-attachment content
    let shouldApplyBaselineOffset = containsCitationAttachments && containsNonAttachmentContent
    if shouldApplyBaselineOffset {
      let baselineOffsetValue = Typography.base.mdFont.descender
      for range in citationRanges {
        mutableAttributedString.addAttribute(.baselineOffset, value: baselineOffsetValue, range: range)
      }
    }

    // Since citations are now already NSTextAttachment in the attributed string during parsing,
    // we can return the themed string directly
    return mutableAttributedString
  }
}

#if DEBUG

@MainActor
let tableViewHeadingMock: [NSMutableAttributedString] = [
  NSMutableAttributedString(string: "Table Heading"),

  NSMutableAttributedString(string: "heading2"),
  NSMutableAttributedString(string: "heading3"),
  NSMutableAttributedString(string: "heading4"),
  NSMutableAttributedString(string: "heading5")
]

@MainActor
let tableviewRowsMock: [[NSMutableAttributedString]] =  [
  [
    NSMutableAttributedString(string: "row1-1 cell Dragon"),
    NSMutableAttributedString(string: "Table body"),
    NSMutableAttributedString(string: "row1-3 cell"),
    NSMutableAttributedString(string: "row1-4 cell"),
    NSMutableAttributedString(string: "row1-5 cell")
  ],
  [
    NSMutableAttributedString(string: "row2-1 cell"),
    NSMutableAttributedString(string: "row2-2 cell"),
    NSMutableAttributedString(string: "row2-3 cell"),
    NSMutableAttributedString(string: "row2-4 cell"),
    NSMutableAttributedString(string: "row2-5 cell")
  ],
  [
    NSMutableAttributedString(string: "row3-1 cell"),
    NSMutableAttributedString(string: "row3-2 cell"),
    NSMutableAttributedString(string: "row3-3 cell"),
    NSMutableAttributedString(string: "row3-4 cell"),
    NSMutableAttributedString(string: "row3-5 cell")
  ]
]

#Preview("Full Table", body: {
  return VStack {
    Spacer()
      .frame(maxHeight: .infinity)
    TableView(
      headings: tableViewHeadingMock,
      rows: tableviewRowsMock
    )
    Spacer()
      .frame(maxHeight: .infinity)
  }
})

#Preview("Header Only", body: {
  return VStack {
    Spacer()
      .frame(maxHeight: .infinity)
    TableView(
      headings: tableViewHeadingMock,
      rows: []
    )
    Spacer()
      .frame(maxHeight: .infinity)
  }
})

#Preview("Table with Citations", body: {
  // Create citation attachments safely
  guard let citationData1 = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Research&citationA11yValue=Research%20Study"
  ),
    let citation1 = InlineCitationAttachment(citationData: citationData1, citationConfig: .default),
    let citationData2 = CitationCoder.default.decode(
      linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Analysis&citationA11yValue=Data%20Analysis"
    ),
    let citation2 = InlineCitationAttachment(citationData: citationData2, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
  }

  // Create rows with citations
  let rowWithCitation1 = NSMutableAttributedString(string: "Study shows ")
  rowWithCitation1.append(NSAttributedString(attachment: citation1))
  rowWithCitation1.append(NSAttributedString(string: " significant results"))

  let rowWithCitation2 = NSMutableAttributedString(string: "According to ")
  rowWithCitation2.append(NSAttributedString(attachment: citation2))
  rowWithCitation2.append(NSAttributedString(string: ", data confirms trends"))

  let headings = [
    NSMutableAttributedString(string: "Finding"),
    NSMutableAttributedString(string: "Source")
  ]

  let rows = [
    [rowWithCitation1, NSMutableAttributedString(string: "Primary research")],
    [rowWithCitation2, NSMutableAttributedString(string: "Secondary analysis")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#Preview("Citation Only Cells", body: {
  // Create citation with NFL (known rendering issue case)
  guard let nflCitationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=NFL&citationA11yValue=National%20Football%20League"
  ),
    let nflCitation = InlineCitationAttachment(citationData: nflCitationData, citationConfig: .default),
    let espnCitationData = CitationCoder.default.decode(
      linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=ESPN&citationA11yValue=ESPN%20Sports"
    ),
    let espnCitation = InlineCitationAttachment(citationData: espnCitationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
  }

  // Create cells with ONLY citations (no other text) to test alignment
  let nflOnlyCell = NSMutableAttributedString(attachment: nflCitation)
  let espnOnlyCell = NSMutableAttributedString(attachment: espnCitation)

  let headings = [
    NSMutableAttributedString(string: "Citation Only"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [nflOnlyCell, NSMutableAttributedString(string: "NFL citation alignment test")],
    [espnOnlyCell, NSMutableAttributedString(string: "ESPN citation alignment test")],
    [NSMutableAttributedString(string: "Regular text"), NSMutableAttributedString(string: "Standard text alignment")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#Preview("Citation Only - Dark Mode", body: {
  // Create citation with NFL (known rendering issue case)
  guard let nflCitationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=NFL&citationA11yValue=National%20Football%20League"
  ),
    let nflCitation = InlineCitationAttachment(citationData: nflCitationData, citationConfig: .default),
    let espnCitationData = CitationCoder.default.decode(
      linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=ESPN&citationA11yValue=ESPN%20Sports"
    ),
    let espnCitation = InlineCitationAttachment(citationData: espnCitationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
      .preferredColorScheme(.dark)
  }

  // Create cells with ONLY citations (no other text) to test alignment
  let nflOnlyCell = NSMutableAttributedString(attachment: nflCitation)
  let espnOnlyCell = NSMutableAttributedString(attachment: espnCitation)

  let headings = [
    NSMutableAttributedString(string: "Citation Only"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [nflOnlyCell, NSMutableAttributedString(string: "NFL citation alignment test")],
    [espnOnlyCell, NSMutableAttributedString(string: "ESPN citation alignment test")],
    [NSMutableAttributedString(string: "Regular text"), NSMutableAttributedString(string: "Standard text alignment")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
  .preferredColorScheme(.dark)
})

#Preview("Table with Mixed Content", body: {
  // Plain-text preview fixture for the first-release profile.
  guard let citationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Source&citationA11yValue=Primary%20Source"
  ),
    let citation = InlineCitationAttachment(citationData: citationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
  }

  // Create content with citation, bold text, and links.
  let complexContent = NSMutableAttributedString(string: "Results from ")
  complexContent.append(NSAttributedString(attachment: citation))
  complexContent.append(NSAttributedString(string: " show "))

  let boldText = NSAttributedString(string: "significant improvement", attributes: [
    .font: MDFont.boldSystemFont(ofSize: 14)
  ])
  complexContent.append(boldText)

  // Add a regular link.
  if let docURL = URL(string: "https://example.com") {
    complexContent.append(NSAttributedString(string: " and see "))
    let linkText = NSAttributedString(string: "documentation", attributes: [
      .link: docURL,
      .foregroundColor: MDColor.systemBlue
    ])
    complexContent.append(linkText)
    complexContent.append(NSAttributedString(string: " for details."))
  }

  let headings = [
    NSMutableAttributedString(string: "Summary"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [complexContent, NSMutableAttributedString(string: "Complete")],
    [NSMutableAttributedString(string: "Standard text only"), NSMutableAttributedString(string: "Pending")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#Preview("Mixed Content - Dark Mode", body: {
  // Plain-text preview fixture for the first-release profile.
  guard let citationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Source&citationA11yValue=Primary%20Source"
  ),
    let citation = InlineCitationAttachment(citationData: citationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
      .preferredColorScheme(.dark)
  }

  // Create content with citation, bold text, and links.
  let complexContent = NSMutableAttributedString(string: "Results from ")
  complexContent.append(NSAttributedString(attachment: citation))
  complexContent.append(NSAttributedString(string: " show "))

  let boldText = NSAttributedString(string: "significant improvement", attributes: [
    .font: MDFont.boldSystemFont(ofSize: 14)
  ])
  complexContent.append(boldText)

  // Add a regular link.
  if let docURL = URL(string: "https://example.com") {
    complexContent.append(NSAttributedString(string: " and see "))
    let linkText = NSAttributedString(string: "documentation", attributes: [
      .link: docURL,
      .foregroundColor: MDColor.systemBlue
    ])
    complexContent.append(linkText)
    complexContent.append(NSAttributedString(string: " for details."))
  }

  let headings = [
    NSMutableAttributedString(string: "Summary"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [complexContent, NSMutableAttributedString(string: "Complete")],
    [NSMutableAttributedString(string: "Standard text only"), NSMutableAttributedString(string: "Pending")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
  .preferredColorScheme(.dark)
})

#Preview("Compact Table", body: {
  let headings = [
    NSMutableAttributedString(string: "Item"),
    NSMutableAttributedString(string: "Value")
  ]

  let rows = [
    [NSMutableAttributedString(string: "Price"), NSMutableAttributedString(string: "$29.99")],
    [NSMutableAttributedString(string: "Tax"), NSMutableAttributedString(string: "$2.40")],
    [NSMutableAttributedString(string: "Total"), NSMutableAttributedString(string: "$32.39")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#endif
