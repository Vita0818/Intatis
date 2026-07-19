//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

// swiftlint:disable type_name

import SwiftUI

extension Color {
  enum Theme {
    enum Accent {
      static let Accent600 = Color.accentColor
    }

    enum Background {
      enum Page {
        enum Chat {
          static let Flat = Color.clear
        }
      }
    }

    enum Component {
      enum Button {
        enum Foreground {
          static let Pressed = Color.secondary
          static let Rest = Color.secondary
        }
      }

      enum CodeBlock {
        enum Background {
          static let Background750 = Color.secondary.opacity(0.12)
        }

        enum Foreground {
          static let FunctionParameter = Color.primary
          static let Header = Color.secondary
        }
      }

      enum Table {
        enum Background {
          static let Header = Color.secondary.opacity(0.08)
        }
      }
    }

    enum Foreground {
      enum Primary {
        static let Primary450 = Color.secondary
        static let Primary550 = Color.secondary
        static let Primary650 = Color.primary
        static let Primary750 = Color.primary
        static let Primary800 = Color.primary
      }
    }

    enum Overlay {
      enum Black {
        static let Black5 = Color.primary.opacity(0.05)
      }
    }

    enum Stroke {
      enum Default {
        static let Default250 = Color.secondary.opacity(0.25)
        static let Default300 = Color.secondary.opacity(0.30)
      }

      enum Muted {
        static let Muted300 = Color.secondary.opacity(0.30)
      }
    }
  }
}
