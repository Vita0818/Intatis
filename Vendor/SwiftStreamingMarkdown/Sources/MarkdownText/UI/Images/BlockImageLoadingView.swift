//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import SwiftUI

/// The placeholder shown while a block image is loading.
struct BlockImageLoadingView: View {

  var body: some View {
    ProgressView()
      .frame(maxWidth: .infinity)
      .frame(height: 200)
      .accessibilityHidden(true)
  }
}
