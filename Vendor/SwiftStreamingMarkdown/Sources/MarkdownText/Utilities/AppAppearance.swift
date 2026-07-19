//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform appearance representation used to select
/// the precomputed light/dark citation preview image.
enum AppAppearance: Sendable {
  case light
  case dark

  /// Citations are disabled in the first-release profile, so no cross-thread
  /// mutable appearance cache is retained.
  static let current = AppAppearance.dark

  #if canImport(UIKit)
  var platformType: UIUserInterfaceStyle {
    switch self {
    case .dark: return UIUserInterfaceStyle.dark
    case .light: return UIUserInterfaceStyle.light
    }
  }

  static func update(style: UIUserInterfaceStyle) {
    _ = style
  }

  #elseif canImport(AppKit)
  var platformType: NSAppearance? {
    switch self {
    case .dark: return NSAppearance(named: .darkAqua)
    case .light: return NSAppearance(named: .aqua)
    }
  }

  static func update(appearance: NSAppearance) {
    // bestMatch resolves all dark variants (vibrantDark, accessibilityHighContrastDarkAqua, etc.)
    // to .darkAqua and all light variants to .aqua.
    _ = appearance
  }
  #endif
}
