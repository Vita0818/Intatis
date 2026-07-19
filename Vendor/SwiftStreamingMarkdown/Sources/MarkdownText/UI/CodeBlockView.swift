//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct CodeBlockView: View {

  @Environment(\.markdownConfig) private var config: MarkdownRenderConfig
  let language: String
  let code: String
  let onCodeCopied: (() -> Void)?

  @State var copied: Bool = false

  init(language: String, code: String, onCodeCopied: (() -> Void)? = nil) {
    self.language = language
    self.code = code
    self.onCodeCopied = onCodeCopied
  }

  private var backgroundColor: Color? {
    config.codeBlockConfig.backgroundColor
  }

  private var foregroundColor: Color {
    config.codeBlockConfig.foregroundColor ?? Color.Static.Stone.Stone350
  }

  @ViewBuilder
  var codeblock: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top) {
        Text(code)
          .font(Typography.codeTextFonts)
          .foregroundStyle(Color.Theme.Component.CodeBlock.Foreground.FunctionParameter)
          .textSelection(.enabled)
          .transition(.opacity)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }

    }.transaction { transaction in
      // The horizontal scrollView resizing animation was causing the code block to animate
      // all janky.
      transaction.animation = nil
    }
    .padding(16)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        Text(language)
          .font(Typography.smallTextFonts)
          .foregroundStyle(foregroundColor)
        Spacer()
        Button {
          copied = true
          #if canImport(UIKit)
          UIPasteboard.general.string = code
          #elseif canImport(AppKit)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          #endif
          onCodeCopied?()
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 6.0) {
            Image(systemName: "doc.on.doc")
            Text(copied ? String.codeCopiedLabel : String.codeCopyLabel)
              .font(Typography.smallTextFonts)
          }
          .foregroundStyle(foregroundColor)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? String.codeCopiedLabel : String.codeCopyLabel)
      }.frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
          backgroundColor
            .clipShape(.rect(
              topLeadingRadius: 20,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: 20
            ))
        )
      codeblock
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.automatic)
        .if(backgroundColor != nil, content: { view in
          let color = backgroundColor ?? Color.clear
          return view.background(color
            .clipShape(.rect(
              topLeadingRadius: 0,
              bottomLeadingRadius: 20,
              bottomTrailingRadius: 20,
              topTrailingRadius: 0
            ))
          )
        })
    }
    .task(id: copied) {
      guard copied else { return }
      do {
        try await Task.sleep(seconds: 3)
      } catch {
        return
      }
      copied = false
    }
  }
}

#if DEBUG

#Preview {
  return LazyVStack {
    Spacer()
    CodeBlockView(language: "Python", code: "import random\n\ndef generate_and_add_numbers(num_numbers):\n    # Generate a list of random numbers random_numbers\n    random_numbers = [random.randint(1, 100) for _ in range(num_numbers)]\n\n\n    # Add the numbers together\n    sum_of_numbers = sum(random_numbers)\n\n    return random_numbers, sum_of_numbers\n\n# Example: Generate 5 random numbers and add them together\nnum_numbers = 5\nrandom_numbers, sum_of_numbers = generate_and_add_numbers(num_numbers)\nprint(f\"Generated numbers: {random_numbers}\")\nprint(f\"Sum of numbers: {sum_of_numbers}\")")
    Spacer()
  }.padding(24)
}

#endif
