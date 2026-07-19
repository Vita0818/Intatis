//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI

/// A SwiftUI view that renders a pre-parsed `RenderableDocument`. Use this
/// view when you already have a parsed document (e.g. driven by a streaming
/// pipeline).
public struct DocumentView: View {
  @StateObject var controller: MarkdownController

  let renderableDocument: RenderableDocument
  let config: MarkdownRenderConfig

  /// Create a `DocumentView`.
  /// - Parameters:
  ///   - renderableDocument: The parsed Markdown document to render.
  ///   - config: Render configuration. Defaults to `.default`.
  ///   - listener: Optional listener that receives render and interaction events.
  public init(
    renderableDocument: RenderableDocument,
    config: MarkdownRenderConfig = .default,
    listener: MarkdownListener? = nil
  ) {
    self.renderableDocument = renderableDocument
    self.config = config
    self._controller = StateObject(wrappedValue: MarkdownController(listener: listener))
  }

  public var body: some View {
    BlockView(renderables: renderableDocument.renderables)
    .environment(\.markdownConfig, config)
    .environment(\.markdownController, controller)
    .task(id: ObjectIdentifier(renderableDocument)) {
      controller.onAppear(markdown: renderableDocument)
    }
    .onDisappear {
      controller.onDisappear()
    }
    .sheet(isPresented: $controller.isTextSelectionRequested) {
      TextSelectionView(
        text: renderableDocument.plainText,
        backgroundColor: config.textSelectionConfig.backgroundColor ?? Color.Theme.Background.Page.Chat.Flat
      ) {
        controller.isTextSelectionRequested = false
      }
    }
  }
}

extension DocumentView: @MainActor Equatable {
  public static func == (lhs: DocumentView, rhs: DocumentView) -> Bool {
    lhs.config == rhs.config && lhs.renderableDocument == rhs.renderableDocument
  }
}

extension EnvironmentValues {
  /// The render configuration applied to descendant Markdown views.
  @Entry public var markdownConfig: MarkdownRenderConfig = .default
  /// The shared controller used by descendant Markdown views to route
  /// table/context-menu events to the configured `MarkdownListener`.
  @Entry public var markdownController: MarkdownController?
}
