//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import SwiftUI

/// Plain code-block chrome styling. Syntax highlighting is intentionally not
/// part of the first-release profile.
public struct CodeBlockConfig: Hashable, Sendable {

  /// Background color applied behind the code block chrome. `nil` leaves the
  /// background unset so the surrounding content shows through; this is the
  /// default for any non-default theme.
  public let backgroundColor: Color?

  /// Foreground color applied to the code block chrome (language label and
  /// copy control). `nil` falls back to the bundled `Stone350`.
  public let foregroundColor: Color?

  /// Create a code-block configuration.
  /// - Parameters:
  ///   - backgroundColor: See `backgroundColor`. Defaults to `nil` (unset).
  ///   - foregroundColor: See `foregroundColor`. Defaults to `nil` (`Stone350`).
  public init(
    backgroundColor: Color? = nil,
    foregroundColor: Color? = nil
  ) {
    self.backgroundColor = backgroundColor
    self.foregroundColor = foregroundColor
  }

  /// The default code-block configuration, which keeps the bundled dark
  /// code-block background.
  public static let `default` = CodeBlockConfig(
    backgroundColor: Color.Theme.Component.CodeBlock.Background.Background750
  )
}
