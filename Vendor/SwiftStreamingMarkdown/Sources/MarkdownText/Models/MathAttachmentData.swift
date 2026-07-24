//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//
//  Intatis derivative modification: bounded native math payload.
//

import Foundation

/// Bounded, request-owned payload persisted inside an inline-math text
/// attachment. It deliberately contains no iosMath objects, views, images, or
/// global identifiers.
struct MathAttachmentData: Codable, Hashable {
  let source: String
  let originalLiteral: String
  let fontSize: Double
}
