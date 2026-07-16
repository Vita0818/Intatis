#if canImport(SwiftUI) && canImport(MarkdownUI) && canImport(JavaScriptCore) && canImport(iosMath)
import SwiftUI
import MarkdownUI

public enum IntatisMessageRenderingPolicy: Sendable {
    case plainText
    case richText
}

public struct IntatisMessageContentView: View {
    private struct Revision: Equatable {
        let rawText: String
        let isComplete: Bool
        let policyIsRich: Bool
    }

    let messageID: String
    let rawText: String
    let isComplete: Bool
    let policy: IntatisMessageRenderingPolicy
    let style: IntatisThreadStyle

    @State private var document: IntatisRenderedDocument

    public init(
        messageID: String,
        rawText: String,
        isComplete: Bool,
        policy: IntatisMessageRenderingPolicy,
        style: IntatisThreadStyle
    ) {
        self.messageID = messageID
        self.rawText = rawText
        self.isComplete = isComplete
        self.policy = policy
        self.style = style
        _document = State(initialValue: Self.makeDocument(
            rawText: rawText,
            isComplete: isComplete,
            policy: policy))
    }

    private var revision: Revision {
        Revision(
            rawText: rawText,
            isComplete: isComplete,
            policyIsRich: policy == .richText)
    }

    public var body: some View {
        Group {
            if policy == .richText, let markdown = document.markdownContent {
                Markdown(markdown)
                    .markdownTheme(markdownTheme)
                    .markdownImageProvider(
                        IntatisMarkdownImageProvider(expressions: document.mathExpressions))
                    .markdownInlineImageProvider(
                        IntatisMarkdownInlineImageProvider(expressions: document.mathExpressions))
                    .environment(\.openURL, OpenURLAction { url in
                        guard Self.isAllowedLink(url) else { return .discarded }
                        return .systemAction(url)
                    })
                    .accessibilityIdentifier("intatis.message.rich.\(messageID)")
            } else {
                Text(displayText)
                    .font(.system(size: 15))
                    .foregroundStyle(style.primaryText)
                    .accessibilityIdentifier("intatis.message.plain.\(messageID)")
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: revision) {
            guard policy == .richText else {
                document = .plain(rawText)
                return
            }
            if !isComplete {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            let nextDocument = await IntatisRenderDocumentWorker.shared.build(
                rawText: displayText,
                cacheCompletedResult: isComplete)
            guard !Task.isCancelled else { return }
            document = nextDocument
        }
    }

    private var displayText: String {
        rawText.isEmpty && !isComplete ? "…" : rawText
    }

    private var markdownTheme: Theme {
        Theme.basic
            .text {
                ForegroundColor(style.primaryText)
            }
            .link {
                ForegroundColor(style.accent)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.94))
                BackgroundColor(style.stroke.opacity(0.22))
            }
            .codeBlock { configuration in
                IntatisCodeBlockView(
                    source: configuration.content,
                    language: configuration.language,
                    isComplete: isComplete,
                    style: style)
                    .markdownMargin(top: .zero, bottom: .em(1))
            }
    }

    private static func makeDocument(
        rawText: String,
        isComplete: Bool,
        policy: IntatisMessageRenderingPolicy
    ) -> IntatisRenderedDocument {
        let displayText = rawText.isEmpty && !isComplete ? "…" : rawText
        guard policy == .richText else { return .plain(displayText) }
        if isComplete,
           let cached = IntatisRenderDocumentBuilder.cachedDocument(for: displayText) {
            return cached
        }
        // First paint stays cheap and preserves the exact source. The view task
        // replaces this with a pre-parsed MarkdownContent value from the serial
        // render worker without blocking SwiftUI's main actor.
        return .plain(displayText)
    }

    private static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }
}
#endif
