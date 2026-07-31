//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: native math payload.
//

import Foundation

enum MathPresentation: String, Codable, Hashable {
  case inline
  case display
}

/// Request-owned scalar payload persisted inside a math text attachment. It
/// deliberately contains no iosMath objects, views, images, or global
/// identifiers.
struct MathAttachmentData: Codable, Hashable {
  let source: String
  let originalLiteral: String
  let presentation: MathPresentation
  let fontSize: Double
}
