#if canImport(SwiftUI) && canImport(JavaScriptCore)
import Foundation
import SwiftUI
import JavaScriptCore

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private struct IntatisCodeCopyActionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var intatisCodeCopyAction: ((String) -> Void)? {
        get { self[IntatisCodeCopyActionKey.self] }
        set { self[IntatisCodeCopyActionKey.self] = newValue }
    }
}

public extension View {
    /// Overrides code-block copying. Intended for deterministic fixtures and tests.
    func intatisCodeCopyAction(_ action: @escaping (String) -> Void) -> some View {
        environment(\.intatisCodeCopyAction, action)
    }
}

struct IntatisCodeBlockView: View {
    let source: String
    let language: String?
    let isComplete: Bool
    let style: IntatisThreadStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.intatisCodeCopyAction) private var copyOverride
    @State private var highlighted: AttributedString?
    @State private var copied = false

    private var normalizedLanguage: String? {
        IntatisCodeLanguage.normalize(language)
    }

    private var languageLabel: String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value!.uppercased() : "CODE"
    }

    private var renderKey: IntatisCodeRenderRevision {
        IntatisCodeRenderRevision(
            isDark: colorScheme == .dark,
            isComplete: isComplete,
            language: language,
            source: source)
    }

    private var contentHeight: CGFloat {
        let lineCount = max(1, source.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        return min(max(CGFloat(lineCount) * 18 + 22, 48), 360)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? style.accent : style.secondaryText)
                .accessibilityIdentifier("intatis.code-copy.\(normalizedLanguage ?? "plain")")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider().opacity(0.62)

            ScrollView([.horizontal, .vertical]) {
                codeText
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: contentHeight)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(style.cardStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intatis.code-block.\(normalizedLanguage ?? "plain")")
        .task(id: renderKey) {
            highlighted = nil
            guard let normalizedLanguage,
                  source.utf8.count <= IntatisSyntaxHighlightingService.maximumHighlightedBytes else {
                return
            }
            if !isComplete {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
            }
            let nextHighlight = await IntatisSyntaxHighlightingService.shared.highlight(
                source,
                language: normalizedLanguage,
                colorScheme: colorScheme)
            guard !Task.isCancelled else { return }
            highlighted = nextHighlight
        }
    }

    @ViewBuilder private var codeText: some View {
        if let highlighted {
            Text(highlighted)
                .textSelection(.enabled)
        } else {
            Text(source)
                .font(.custom("Menlo", size: 13))
                .foregroundStyle(style.primaryText)
                .textSelection(.enabled)
        }
    }

    private func copy() {
        if let copyOverride {
            copyOverride(source)
        } else {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
            #elseif canImport(UIKit)
            UIPasteboard.general.string = source
            #endif
        }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

struct IntatisCodeRenderRevision: Hashable {
    let isDark: Bool
    let isComplete: Bool
    let languageUTF8: Data?
    let sourceUTF8: Data

    init(isDark: Bool, isComplete: Bool, language: String?, source: String) {
        self.isDark = isDark
        self.isComplete = isComplete
        self.languageUTF8 = language.map { Data($0.utf8) }
        self.sourceUTF8 = Data(source.utf8)
    }
}

enum IntatisCodeLanguage {
    static func normalize(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        return aliases[value] ?? value
    }

    private static let aliases: [String: String] = [
        "c#": "csharp",
        "c++": "cpp",
        "cs": "csharp",
        "html": "xml",
        "js": "javascript",
        "jsx": "javascript",
        "kt": "kotlin",
        "md": "markdown",
        "objc": "objectivec",
        "py": "python",
        "rb": "ruby",
        "sh": "bash",
        "shell": "bash",
        "ts": "typescript",
        "tsx": "typescript",
        "yml": "yaml",
        "zsh": "bash",
    ]
}

@MainActor
final class IntatisSyntaxHighlightingService {
    static let shared = IntatisSyntaxHighlightingService()
    static let maximumHighlightedBytes = 64 * 1024
    // highlight.js 11.11.1 has an open quadratic FUNCTION_DECLARATION ReDoS
    // in its C-family grammars (upstream issue #4362). Keep the complete code
    // container but fail these languages to plaintext until a fixed audited
    // upstream release is adopted; do not locally fork the grammar engine.
    static let temporarilyPlaintextLanguages: Set<String> = ["c", "cpp"]

    private let worker = IntatisSyntaxHighlightingWorker()
    private var cache: [IntatisSyntaxHighlightCacheKey: AttributedString] = [:]
    private var cacheOrder: [IntatisSyntaxHighlightCacheKey] = []

    func highlight(
        _ source: String,
        language: String,
        colorScheme: ColorScheme
    ) async -> AttributedString? {
        guard source.utf8.count <= Self.maximumHighlightedBytes,
              !Self.temporarilyPlaintextLanguages.contains(language) else {
            return nil
        }
        let theme = colorScheme == .dark ? "a11y-dark" : "a11y-light"
        let key = IntatisSyntaxHighlightCacheKey(
            theme: theme,
            language: language,
            source: source)
        if let cached = cache[key], hasExactUTF8(cached, source: source) {
            return cached
        }

        guard let html = await worker.highlightHTML(source, as: language, theme: theme),
              !Task.isCancelled,
              let rendered = renderedHTML(html, expectedSource: source),
              let attributed = try? platformAttributedString(rendered) else {
            return nil
        }

        cache[key] = attributed
        cacheOrder.append(key)
        if cacheOrder.count > 64 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return attributed
    }

    private func renderedHTML(_ html: String, expectedSource: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let documentOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let rendered = try? NSMutableAttributedString(
            data: data,
            options: documentOptions,
            documentAttributes: nil) else {
            return nil
        }
        if Data(rendered.string.utf8) == Data((expectedSource + "\n").utf8) {
            rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1))
        }
        guard Data(rendered.string.utf8) == Data(expectedSource.utf8) else { return nil }
        return rendered
    }

    private func hasExactUTF8(_ attributed: AttributedString, source: String) -> Bool {
        Data(String(attributed.characters).utf8) == Data(source.utf8)
    }

    private func platformAttributedString(_ source: NSAttributedString) throws -> AttributedString {
        #if canImport(AppKit)
        return try AttributedString(source, including: \.appKit)
        #elseif canImport(UIKit)
        return try AttributedString(source, including: \.uiKit)
        #endif
    }
}

struct IntatisSyntaxHighlightCacheKey: Hashable {
    let theme: String
    let language: String
    let sourceUTF8: Data

    init(theme: String, language: String, source: String) {
        self.theme = theme
        self.language = language
        self.sourceUTF8 = Data(source.utf8)
    }
}

/// Serializes the upstream JavaScript engine away from SwiftUI's main actor.
/// The AppKit/UIKit HTML-to-attributed-string conversion remains on the main
/// actor and is bounded by `maximumHighlightedBytes`.
private actor IntatisSyntaxHighlightingWorker {
    private var didAttemptLoad = false
    private var highlighter: IntatisHighlightJS?
    private var supportedLanguages: Set<String>?

    func highlightHTML(_ source: String, as language: String, theme: String) -> String? {
        guard !Task.isCancelled, let highlighter = loadHighlighter() else { return nil }
        let languages: Set<String>
        if let supportedLanguages {
            languages = supportedLanguages
        } else {
            let loaded = Set(highlighter.supportedLanguages())
            supportedLanguages = loaded
            languages = loaded
        }
        guard languages.contains(language), !Task.isCancelled else { return nil }
        return highlighter.highlightHTML(source, as: language, theme: theme)
    }

    private func loadHighlighter() -> IntatisHighlightJS? {
        if didAttemptLoad { return highlighter }
        didAttemptLoad = true
        let loaded = IntatisHighlightJS()
        highlighter = loaded
        return loaded
    }
}

/// Thin platform adapter around the fixed, bundled highlight.js engine. The
/// language grammars and token classification stay entirely upstream.
private final class IntatisHighlightJS {
    private let context: JSContext
    private let engine: JSValue
    private let themes: [String: String]

    init?() {
        guard let context = JSContext(),
              let scriptURL = Bundle.module.url(forResource: "highlight.min", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let lightURL = Bundle.module.url(forResource: "a11y-light", withExtension: "css"),
              let darkURL = Bundle.module.url(forResource: "a11y-dark", withExtension: "css"),
              let light = try? String(contentsOf: lightURL, encoding: .utf8),
              let dark = try? String(contentsOf: darkURL, encoding: .utf8) else {
            return nil
        }
        context.evaluateScript(script)
        guard context.exception == nil,
              let engine = context.globalObject.objectForKeyedSubscript("hljs"),
              !engine.isUndefined else {
            return nil
        }
        self.context = context
        self.engine = engine
        self.themes = ["a11y-light": light, "a11y-dark": dark]
    }

    func supportedLanguages() -> [String] {
        context.exception = nil
        guard let languages = engine.invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String],
              context.exception == nil else {
            return []
        }
        return languages
    }

    func highlightHTML(_ source: String, as language: String, theme: String) -> String? {
        guard let themeCSS = themes[theme] else { return nil }
        context.exception = nil
        let options: [String: Any] = ["language": language, "ignoreIllegals": true]
        guard let result = engine.invokeMethod("highlight", withArguments: [source, options]),
              context.exception == nil,
              let fragment = result.objectForKeyedSubscript("value")?.toString() else {
            return nil
        }

        return """
        <style>
        \(themeCSS)
        pre, code, .hljs {
          font-family: Menlo, monospace !important;
          font-size: 13px !important;
          background: transparent !important;
          padding: 0 !important;
          margin: 0 !important;
          white-space: pre !important;
        }
        </style><pre><code class="hljs">\(fragment)</code></pre>
        """
    }
}
#endif
