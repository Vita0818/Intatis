//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation

@MainActor
class ParagraphViewCache {
  private init() {}

  static let shared: ParagraphViewCache = .init()

  func createOrReuseView(contents: NSMutableAttributedString, lineSpacing: CGFloat?) -> MDParagraphView {
    // First-release profile: cache budget is exactly zero. SwiftUI owns the
    // returned view; the package retains no native paragraph views.
    MDParagraphView()
  }

  func clearCache() {}
}
