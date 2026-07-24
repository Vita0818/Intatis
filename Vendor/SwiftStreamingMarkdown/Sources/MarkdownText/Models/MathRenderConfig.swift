//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: optional single-dollar math admission.
//

/// Configuration for the package's optional inline-math grammar extension.
///
/// Math rendering is disabled by default. The first supported grammar is a
/// conservative, single-line `$...$` form. Admission limits are intentionally
/// fixed so a caller cannot accidentally opt the renderer into unbounded math
/// parsing or attachment creation.
public struct MathRenderConfig: Hashable, Sendable {
  /// The inline-math grammar selected for a parse request.
  public enum Mode: Hashable, Sendable {
    /// Leave all math delimiters as ordinary Markdown text.
    case disabled
    /// Recognize conservative, single-line `$...$` candidates outside code.
    case singleDollarInline
  }

  /// Maximum UTF-8 size of one formula source, excluding delimiters.
  public static let maximumFormulaUTF8Bytes = 8 * 1_024
  /// Maximum number of formulas admitted in one message.
  public static let maximumFormulaCount = 32

  /// The selected math grammar.
  public let mode: Mode
  /// Maximum UTF-8 size admitted for one formula source.
  public let maxFormulaUTF8Bytes: Int
  /// Maximum number of formulas admitted for one message.
  public let maxFormulaCount: Int

  private init(
    mode: Mode,
    maxFormulaUTF8Bytes: Int,
    maxFormulaCount: Int
  ) {
    self.mode = mode
    self.maxFormulaUTF8Bytes = maxFormulaUTF8Bytes
    self.maxFormulaCount = maxFormulaCount
  }

  /// Math is off unless a caller explicitly enables it.
  public static let disabled = MathRenderConfig(
    mode: .disabled,
    maxFormulaUTF8Bytes: maximumFormulaUTF8Bytes,
    maxFormulaCount: maximumFormulaCount
  )

  /// Conservative single-dollar inline math with fixed admission limits.
  public static let singleDollarInline = MathRenderConfig(
    mode: .singleDollarInline,
    maxFormulaUTF8Bytes: maximumFormulaUTF8Bytes,
    maxFormulaCount: maximumFormulaCount
  )

  var isSingleDollarInlineEnabled: Bool {
    mode == .singleDollarInline
  }
}
