//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: code-aware inline-math preprocessing.
//

import Foundation
import Markdown

/// Code-aware, request-local preprocessing for conservative inline math.
///
/// The first raw `Document` remains the authority for identifying code and
/// literal-only syntax. Only accepted candidates outside code, link/image,
/// autolink, and raw-HTML source ranges are replaced, after which the caller
/// may perform one second Markdown parse.
enum InlineMathPreprocessor {
  struct Output {
    let transformedSource: String
    let catalog: InlineMathCatalog
  }

  private struct Candidate {
    let range: Range<String.Index>
    let source: String
    let originalLiteral: String
  }

  private struct PositionedCharacter {
    let index: String.Index
    let endIndex: String.Index
    let character: Character
    let utf8Offset: Int
    let isProtected: Bool
  }

  /// A cheap check used to keep ordinary no-math messages on the one-parse path.
  static func mightContainSingleDollarDelimiter(_ source: String) -> Bool {
    guard source.utf8.contains(0x24) else { return false }
    let bytes = Array(source.utf8)

    for index in bytes.indices where bytes[index] == 0x24 {
      let previousIsDollar = index > bytes.startIndex && bytes[index - 1] == 0x24
      let nextIsDollar = index + 1 < bytes.endIndex && bytes[index + 1] == 0x24
      guard !previousIsDollar, !nextIsDollar else { continue }

      var backslashCount = 0
      var cursor = index
      while cursor > bytes.startIndex, bytes[cursor - 1] == 0x5C {
        backslashCount += 1
        cursor -= 1
      }
      if backslashCount.isMultiple(of: 2) {
        return true
      }
    }
    return false
  }

  static func preprocess(
    source: String,
    document: Document,
    config: MathRenderConfig
  ) -> Output? {
    guard config.isSingleDollarInlineEnabled,
          mightContainSingleDollarDelimiter(source),
          let protectedRanges = protectedLiteralRanges(
            in: document,
            source: source
          )
    else {
      return nil
    }

    return preprocess(
      source: source,
      protectedUTF8Ranges: protectedRanges,
      config: config
    )
  }

  /// Internal scanner entry point kept separate for focused boundary tests.
  static func preprocess(
    source: String,
    protectedUTF8Ranges: [Range<Int>],
    config: MathRenderConfig,
    namespace: String = UUID().uuidString.replacingOccurrences(
      of: "-",
      with: ""
    )
  ) -> Output? {
    guard config.isSingleDollarInlineEnabled,
          mightContainSingleDollarDelimiter(source),
          let protectedRanges = normalizedProtectedRanges(
            protectedUTF8Ranges,
            source: source
          )
    else {
      return nil
    }

    let characters = positionedCharacters(
      in: source,
      protectedRanges: protectedRanges
    )
    let candidates = scanCandidates(in: source, characters: characters)
    guard !candidates.isEmpty else { return nil }

    let literalOnly =
      candidates.count > config.maxFormulaCount
      || candidates.contains {
        $0.source.utf8.count > config.maxFormulaUTF8Bytes
      }

    let entries = candidates.map {
      InlineMathCatalog.Entry(
        source: $0.source,
        originalLiteral: $0.originalLiteral,
        rendering: literalOnly ? .literalOnly : .attachment
      )
    }
    let catalog = InlineMathCatalog(namespace: namespace, entries: entries)

    var pieces: [String] = []
    pieces.reserveCapacity(candidates.count * 2 + 1)
    var cursor = source.startIndex
    for (index, candidate) in candidates.enumerated() {
      pieces.append(String(source[cursor..<candidate.range.lowerBound]))
      pieces.append(catalog.token(at: index))
      cursor = candidate.range.upperBound
    }
    pieces.append(String(source[cursor..<source.endIndex]))

    return Output(
      transformedSource: pieces.joined(),
      catalog: catalog
    )
  }

  /// Returns `nil` when any protected node cannot be mapped safely. That
  /// fail-closed result leaves all math delimiters literal for the request.
  static func protectedLiteralRanges(
    in document: Document,
    source: String
  ) -> [Range<Int>]? {
    let mapper = SourceLocationMapper(source: source)
    var ranges: [Range<Int>] = []
    var mappingFailed = false

    func visit(_ markup: any Markup) {
      let protectsLiteralSource =
        markup is InlineCode
        || markup is CodeBlock
        || markup is Link
        || markup is Markdown.Image
        || markup is InlineHTML
        || markup is HTMLBlock
      if protectsLiteralSource {
        guard let sourceRange = markup.range,
              let range = mapper.utf8Range(for: sourceRange)
        else {
          mappingFailed = true
          return
        }
        ranges.append(range)
      }

      for child in markup.children {
        visit(child)
      }
    }

    visit(document)
    guard !mappingFailed else { return nil }
    return normalizedProtectedRanges(ranges, source: source)
  }

  private static func positionedCharacters(
    in source: String,
    protectedRanges: [Range<Int>]
  ) -> [PositionedCharacter] {
    var result: [PositionedCharacter] = []
    result.reserveCapacity(source.count)

    var index = source.startIndex
    var utf8Offset = 0
    var protectedIndex = 0
    while index < source.endIndex {
      while protectedIndex < protectedRanges.count,
            protectedRanges[protectedIndex].upperBound <= utf8Offset {
        protectedIndex += 1
      }

      let endIndex = source.index(after: index)
      let character = source[index]
      let isProtected =
        protectedIndex < protectedRanges.count
        && protectedRanges[protectedIndex].contains(utf8Offset)
      result.append(
        PositionedCharacter(
          index: index,
          endIndex: endIndex,
          character: character,
          utf8Offset: utf8Offset,
          isProtected: isProtected
        )
      )
      utf8Offset += character.utf8.count
      index = endIndex
    }
    return result
  }

  private static func scanCandidates(
    in source: String,
    characters: [PositionedCharacter]
  ) -> [Candidate] {
    var candidates: [Candidate] = []
    var openerIndex: Int?

    for index in characters.indices {
      let positioned = characters[index]
      if positioned.isProtected {
        openerIndex = nil
        continue
      }

      if positioned.character.isNewline {
        openerIndex = nil
        continue
      }

      guard positioned.character == "$" else { continue }
      let escaped = isEscapedDelimiter(at: index, characters: characters)
      if escaped {
        continue
      }

      let previous = index > characters.startIndex
        ? characters[index - 1].character
        : nil
      let next = index + 1 < characters.endIndex
        ? characters[index + 1].character
        : nil
      let isSingleDelimiter = previous != "$" && next != "$"
      guard isSingleDelimiter else {
        openerIndex = nil
        continue
      }

      if let openIndex = openerIndex {
        if isValidCloser(previous: previous, next: next) {
          let open = characters[openIndex]
          let contentRange = open.endIndex..<positioned.index
          let literalRange = open.index..<positioned.endIndex
          let formulaSource = String(source[contentRange])
          candidates.append(
            Candidate(
              range: literalRange,
              source: formulaSource,
              originalLiteral: String(source[literalRange])
            )
          )
          openerIndex = nil
        } else {
          openerIndex = isValidOpener(next: next) ? index : nil
        }
      } else if isValidOpener(next: next) {
        openerIndex = index
      }
    }

    return candidates
  }

  private static func isEscapedDelimiter(
    at index: Int,
    characters: [PositionedCharacter]
  ) -> Bool {
    var backslashCount = 0
    var cursor = index
    while cursor > characters.startIndex,
          characters[cursor - 1].character == "\\" {
      backslashCount += 1
      cursor -= 1
    }
    return !backslashCount.isMultiple(of: 2)
  }

  private static func isValidOpener(next: Character?) -> Bool {
    guard let next else { return false }
    return next != "$" && !next.isWhitespace && !next.isNewline
  }

  private static func isValidCloser(
    previous: Character?,
    next: Character?
  ) -> Bool {
    guard let previous,
          previous != "$",
          !previous.isWhitespace,
          !previous.isNewline
    else {
      return false
    }
    return next?.wholeNumberValue == nil
  }

  private static func normalizedProtectedRanges(
    _ ranges: [Range<Int>],
    source: String
  ) -> [Range<Int>]? {
    let byteCount = source.utf8.count
    guard ranges.allSatisfy({
      $0.lowerBound >= 0
        && $0.lowerBound <= $0.upperBound
        && $0.upperBound <= byteCount
        && isStringBoundary($0.lowerBound, in: source)
        && isStringBoundary($0.upperBound, in: source)
    }) else {
      return nil
    }

    let sorted = ranges
      .filter { !$0.isEmpty }
      .sorted { lhs, rhs in
        lhs.lowerBound == rhs.lowerBound
          ? lhs.upperBound < rhs.upperBound
          : lhs.lowerBound < rhs.lowerBound
      }
    var merged: [Range<Int>] = []
    for range in sorted {
      if let last = merged.last, range.lowerBound <= last.upperBound {
        merged[merged.count - 1] =
          last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  private static func isStringBoundary(
    _ utf8Offset: Int,
    in source: String
  ) -> Bool {
    let utf8 = source.utf8
    let utf8Index = utf8.index(utf8.startIndex, offsetBy: utf8Offset)
    return String.Index(utf8Index, within: source) != nil
  }
}

private struct SourceLocationMapper {
  private let source: String
  private let lineStartUTF8Offsets: [Int]

  init(source: String) {
    self.source = source
    let bytes = Array(source.utf8)
    var starts = [0]
    for index in bytes.indices {
      if bytes[index] == 0x0A {
        starts.append(index + 1)
      } else if bytes[index] == 0x0D,
                (index + 1 == bytes.endIndex || bytes[index + 1] != 0x0A) {
        starts.append(index + 1)
      }
    }
    self.lineStartUTF8Offsets = starts
  }

  func utf8Range(for range: SourceRange) -> Range<Int>? {
    guard let lower = utf8Offset(for: range.lowerBound),
          let upper = utf8Offset(for: range.upperBound),
          lower <= upper
    else {
      return nil
    }
    return lower..<upper
  }

  private func utf8Offset(for location: SourceLocation) -> Int? {
    guard location.line > 0,
          location.line <= lineStartUTF8Offsets.count,
          location.column > 0
    else {
      return nil
    }

    let lineStart = lineStartUTF8Offsets[location.line - 1]
    let offset = lineStart + location.column - 1
    let nextLineStart = location.line < lineStartUTF8Offsets.count
      ? lineStartUTF8Offsets[location.line]
      : source.utf8.count
    guard offset >= lineStart,
          offset <= nextLineStart,
          offset <= source.utf8.count
    else {
      return nil
    }

    let utf8 = source.utf8
    let utf8Index = utf8.index(utf8.startIndex, offsetBy: offset)
    guard String.Index(utf8Index, within: source) != nil else {
      return nil
    }
    return offset
  }
}
