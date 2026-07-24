//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

/// Options that control how a `MarkdownParser` processes input text.
public struct MarkdownParseOption {
  /// Whether to speculative rewrite the markdown if it is considered as incomplete
  /// Such as a string ends with a partial table or partial emphasis
  public let speculativeRewrite: Bool

  /// Whether to enable experimental block-level handling of Markdown images.
  ///
  /// When enabled, the parser rewrites paragraphs that contain images so each
  /// image is isolated into its own block-level paragraph.
  ///
  /// - Important: Image support is **experimental** and incomplete. There is no
  ///   image renderer yet, so an isolated image paragraph currently renders as
  ///   empty; enabling this only changes the parsed document structure. The
  ///   behavior, API, and rendering output may change in future releases.
  ///   Defaults to `false`.
  public let imageSupport: Bool
  /// Math grammar applied during parsing. Internal so the public low-level
  /// parser cannot return a tokenized AST without its request-local catalog.
  let mathConfig: MathRenderConfig

  /// Create a new parse option.
  /// - Parameters:
  ///   - speculativeRewrite: See `speculativeRewrite`.
  ///   - imageSupport: See `imageSupport`. Experimental; defaults to `false`.
  public init(
    speculativeRewrite: Bool,
    imageSupport: Bool = false
  ) {
    self.speculativeRewrite = speculativeRewrite
    self.imageSupport = imageSupport
    self.mathConfig = .disabled
  }

  /// Internal resolved-render path. Callers that enable math must retain and
  /// consume the request-local catalog before exposing rendered output.
  init(
    speculativeRewrite: Bool,
    imageSupport: Bool = false,
    mathConfig: MathRenderConfig
  ) {
    self.speculativeRewrite = speculativeRewrite
    self.imageSupport = imageSupport
    self.mathConfig = mathConfig
  }
}
