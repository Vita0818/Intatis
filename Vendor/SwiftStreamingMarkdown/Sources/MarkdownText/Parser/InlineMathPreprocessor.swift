//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: code-aware LaTeX preprocessing.
//

import Foundation
import Markdown

/// Code-aware, request-local preprocessing for inline and display math.
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
    let presentation: MathPresentation
  }

  private struct PositionedCharacter {
    let index: String.Index
    let endIndex: String.Index
    let character: Character
    let utf8Offset: Int
    let isProtected: Bool
  }

  /// A cheap check used to keep ordinary no-math messages on the one-parse path.
  static func mightContainMathDelimiter(_ source: String) -> Bool {
    let bytes = Array(source.utf8)
    var precedingBackslashes = 0

    for index in bytes.indices {
      let byte = bytes[index]
      if byte == 0x5C {
        if precedingBackslashes.isMultiple(of: 2),
           index + 1 < bytes.endIndex,
           bytes[index + 1] == 0x28 || bytes[index + 1] == 0x5B {
          return true
        }
        precedingBackslashes += 1
      } else {
        if byte == 0x24, precedingBackslashes.isMultiple(of: 2) {
          return true
        }
        precedingBackslashes = 0
      }
    }
    return false
  }

  static func preprocess(
    source: String,
    document: Document,
    config: MathRenderConfig
  ) -> Output? {
    guard config.isEnabled,
          mightContainMathDelimiter(source),
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
    guard config.isEnabled,
          mightContainMathDelimiter(source),
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

    let entries = candidates.map {
      InlineMathCatalog.Entry(
        source: $0.source,
        originalLiteral: $0.originalLiteral,
        presentation: $0.presentation
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

  private enum Delimiter {
    case singleDollar
    case doubleDollar
    case parenthesis
    case bracket

    var length: Int {
      self == .singleDollar ? 1 : 2
    }

    var presentation: MathPresentation {
      switch self {
      case .singleDollar, .parenthesis:
        return .inline
      case .doubleDollar, .bracket:
        return .display
      }
    }

    var allowsNewlines: Bool {
      presentation == .display
    }
  }

  private struct OpenDelimiter {
    let delimiter: Delimiter
    let characterIndex: Int
  }

  private static func scanCandidates(
    in source: String,
    characters: [PositionedCharacter]
  ) -> [Candidate] {
    var candidates: [Candidate] = []
    var opener: OpenDelimiter?
    var index = characters.startIndex

    while index < characters.endIndex {
      let positioned = characters[index]
      if positioned.isProtected {
        opener = nil
        index += 1
        continue
      }

      if let open = opener {
        if positioned.character.isNewline,
           !open.delimiter.allowsNewlines {
          opener = nil
          index += 1
          continue
        }

        if isClosingDelimiter(
          open.delimiter,
          at: index,
          characters: characters
        ) {
          let openerEnd = characters[
            open.characterIndex + open.delimiter.length - 1
          ].endIndex
          let closerEnd = characters[
            index + open.delimiter.length - 1
          ].endIndex
          let literalRange =
            characters[open.characterIndex].index..<closerEnd
          let rawFormula = String(source[openerEnd..<positioned.index])
          let formula = rawFormula.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          if !formula.isEmpty {
            candidates.append(
              Candidate(
                range: literalRange,
                source: formula,
                originalLiteral: String(source[literalRange]),
                presentation: open.delimiter.presentation
              )
            )
          }
          opener = nil
          index += open.delimiter.length
          continue
        }

        index += 1
        continue
      }

      if let delimiter = openingDelimiter(
        at: index,
        characters: characters
      ) {
        opener = OpenDelimiter(
          delimiter: delimiter,
          characterIndex: index
        )
        index += delimiter.length
      } else {
        index += 1
      }
    }

    return candidates
  }

  private static func openingDelimiter(
    at index: Int,
    characters: [PositionedCharacter]
  ) -> Delimiter? {
    let positioned = characters[index]
    guard !positioned.isProtected else { return nil }

    if positioned.character == "$" {
      guard !isEscapedDelimiter(at: index, characters: characters) else {
        return nil
      }
      if isDoubleDollarDelimiter(at: index, characters: characters) {
        return .doubleDollar
      }

      let previous = index > characters.startIndex
        ? characters[index - 1].character
        : nil
      let next = index + 1 < characters.endIndex
        ? characters[index + 1].character
        : nil
      guard previous != "$",
            next != "$",
            isValidOpener(next: next) else {
        return nil
      }
      return .singleDollar
    }

    guard positioned.character == "\\",
          !isEscapedDelimiter(at: index, characters: characters),
          index + 1 < characters.endIndex,
          !characters[index + 1].isProtected else {
      return nil
    }
    switch characters[index + 1].character {
    case "(":
      return .parenthesis
    case "[":
      return .bracket
    default:
      return nil
    }
  }

  private static func isClosingDelimiter(
    _ delimiter: Delimiter,
    at index: Int,
    characters: [PositionedCharacter]
  ) -> Bool {
    switch delimiter {
    case .singleDollar:
      guard characters[index].character == "$",
            !isEscapedDelimiter(at: index, characters: characters)
      else {
        return false
      }
      let previous = index > characters.startIndex
        ? characters[index - 1].character
        : nil
      let next = index + 1 < characters.endIndex
        ? characters[index + 1].character
        : nil
      return previous != "$"
        && next != "$"
        && isValidCloser(previous: previous, next: next)

    case .doubleDollar:
      return isDoubleDollarDelimiter(at: index, characters: characters)

    case .parenthesis:
      return isBackslashDelimiter(
        ")",
        at: index,
        characters: characters
      )

    case .bracket:
      return isBackslashDelimiter(
        "]",
        at: index,
        characters: characters
      )
    }
  }

  private static func isDoubleDollarDelimiter(
    at index: Int,
    characters: [PositionedCharacter]
  ) -> Bool {
    guard index + 1 < characters.endIndex,
          characters[index].character == "$",
          characters[index + 1].character == "$",
          !characters[index].isProtected,
          !characters[index + 1].isProtected,
          !isEscapedDelimiter(at: index, characters: characters)
    else {
      return false
    }
    let previous = index > characters.startIndex
      ? characters[index - 1].character
      : nil
    let next = index + 2 < characters.endIndex
      ? characters[index + 2].character
      : nil
    return previous != "$" && next != "$"
  }

  private static func isBackslashDelimiter(
    _ terminal: Character,
    at index: Int,
    characters: [PositionedCharacter]
  ) -> Bool {
    index + 1 < characters.endIndex
      && characters[index].character == "\\"
      && characters[index + 1].character == terminal
      && !characters[index].isProtected
      && !characters[index + 1].isProtected
      && !isEscapedDelimiter(at: index, characters: characters)
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
