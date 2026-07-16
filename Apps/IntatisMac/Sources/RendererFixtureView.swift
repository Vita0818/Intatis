#if DEBUG && canImport(SwiftUI)
import SwiftUI
import IntatisSharedUI

/// Offline, deterministic renderer fixture used by visual verification.
/// It never creates an AppEnvironment, provider, session, or credential resolver.
struct RendererFixtureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var streamStage = 0
    @State private var copiedValue = "Nothing copied"

    private var style: IntatisThreadStyle {
        .intatisMac(colorScheme)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                fixtureHeader
                fixtureSection("Markdown + code + LaTeX", identifier: "renderer.fixture.markdown") {
                    IntatisMessageContentView(
                        messageID: "fixture-combined",
                        rawText: Self.combinedSource,
                        isComplete: true,
                        policy: .richText,
                        style: style)
                }
                fixtureSection("Long code line", identifier: "renderer.fixture.code.swift") {
                    IntatisMessageContentView(
                        messageID: "fixture-long-code",
                        rawText: Self.longCodeSource,
                        isComplete: true,
                        policy: .richText,
                        style: style)
                }
                fixtureSection("Streaming", identifier: "renderer.fixture.streaming") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Advance stream") {
                            streamStage = (streamStage + 1) % Self.streamingSources.count
                        }
                        .accessibilityIdentifier("renderer.fixture.advance")
                        Text("Stage \(streamStage + 1) / \(Self.streamingSources.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        IntatisMessageContentView(
                            messageID: "fixture-streaming",
                            rawText: Self.streamingSources[streamStage],
                            isComplete: streamStage == Self.streamingSources.count - 1,
                            policy: .richText,
                            style: style)
                    }
                }
                fixtureSection("Safe fallbacks", identifier: "renderer.fixture.fallback") {
                    IntatisMessageContentView(
                        messageID: "fixture-fallback",
                        rawText: Self.fallbackSource,
                        isComplete: true,
                        policy: .richText,
                        style: style)
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .intatisCodeCopyAction { source in
            copiedValue = source.contains("END_OF_LONG_LINE")
                ? "Copied END_OF_LONG_LINE"
                : "Copied \(source.utf8.count) bytes"
        }
        .accessibilityIdentifier("renderer.fixture")
    }

    private var fixtureHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Intatis renderer fixture")
                .font(.title.bold())
            Text("Offline · MarkdownUI 2.4.1 · highlight.js 11.11.1 · iosMath 2.5.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(copiedValue)
                .font(.caption.monospaced())
                .foregroundStyle(style.accent)
                .accessibilityIdentifier("renderer.fixture.copyResult")
        }
    }

    private func fixtureSection<Content: View>(
        _ title: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(style.tertiaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .intatisContentSurface(cornerRadius: 14)
        .accessibilityIdentifier(identifier)
    }

    private static let combinedSource = #"""
    # Rendering that behaves like a chat answer

    MarkdownUI owns the **Markdown parser**. This fixture covers *emphasis*, [a safe link](https://example.com), quotes, lists, tasks, and a table.

    > Rich content stays selectable and falls back to its original source.

    1. First item
       - Nested item
    2. Second item

    - [x] Markdown renderer
    - [x] Code-block renderer
    - [x] LaTeX renderer

    | Engine | Responsibility |
    | --- | --- |
    | MarkdownUI | GFM structure |
    | highlight.js | Language tokens |
    | iosMath | TeX layout |

    ```swift
    struct Fibonacci {
        static func values(upTo limit: Int) -> [Int] {
            var result = [0, 1]
            for index in 2..<limit {
                result.append(result[index - 1] + result[index - 2]) // recurrence
            }
            return result
        }
    }
    ```

    Inline math is routed separately: \(E = mc^2\).

    A sole inline formula remains math when MarkdownUI promotes its paragraph:

    \(a + b\)

    \[
      \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
    \]
    """#

    private static let longCodeSource = #"""
    ```typescript
    const status: string = "This line intentionally remains unwrapped so horizontal scrolling can reveal its sentinel" + " -------------------------------- END_OF_LONG_LINE";
    for (let index = 0; index < 3; index += 1) { console.log(index, status); }
    ```
    """#

    private static let streamingSources = [
        "**Streaming emphasis",
        #"""
        **Streaming emphasis is complete.**

        ```swift
        for index in 0..<3 {
        """#,
        #"""
        **Streaming emphasis is complete.**

        ```swift
        for index in 0..<3 {
            print(index)
        }
        ```

        Final inline formula: \(x^2 + y^2 = z^2\).
        """#,
    ]

    private static let fallbackSource = #"""
    Invalid TeX remains source text: \(\notAnIosMathCommand{x}\)

    Unknown languages still get a complete, selectable code container:

    ```future-lang
    quantum launch when ready
    ```

    Remote images are blocked: ![tracking pixel](https://example.com/tracker.png)
    """#
}
#endif
