//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: optional LaTeX delimiter support.
//

/// Configuration for the package's optional LaTeX grammar extension.
///
/// Math rendering is disabled by default. Enabling it recognizes the common
/// inline `$...$` and `\(...\)` forms plus display `$$...$$` and `\[...\]`
/// forms outside protected Markdown literals. Formula admission does not add
/// Intatis-specific count or source-size limits.
public struct MathRenderConfig: Hashable, Sendable {
  /// The math grammar selected for a parse request.
  public enum Mode: Hashable, Sendable {
    /// Leave all math delimiters as ordinary Markdown text.
    case disabled
    /// Recognize common inline and display LaTeX delimiters outside code.
    case latex
  }

  /// The selected math grammar.
  public let mode: Mode

  private init(mode: Mode) {
    self.mode = mode
  }

  /// Math is off unless a caller explicitly enables it.
  public static let disabled = MathRenderConfig(mode: .disabled)

  /// Common inline and display LaTeX delimiters without local formula caps.
  public static let latex = MathRenderConfig(mode: .latex)

  var isEnabled: Bool {
    mode == .latex
  }
}
