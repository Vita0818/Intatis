#if (DEBUG || INTATIS_RENDERER_VALIDATION) && canImport(SwiftUI)
import CryptoKit
import Foundation
import IntatisSharedUI
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Offline, deterministic renderer fixture used by visual verification.
/// It never creates an AppEnvironment, provider, session, or credential resolver.
///
/// The fixture is deliberately staged: only one workload is materialized at a
/// time. This lets the external watchdog establish a minimal containment
/// baseline before table, code-selection, isolated math, stream replacement,
/// or incident replay is attempted.
struct RendererFixtureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var incidentReplay: RendererIncidentReplayModel
    @State private var fixtureStage: RendererFixtureStage
    @State private var streamStage = 0
    @State private var mathStreamStage = 0
    private let autoExitSeconds: Double?
    private let mathModeTitle: String
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var rendererModeRawValue = IntatisMessageRendererMode.microsoft.rawValue

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let configuration = RendererFixtureLaunchConfiguration(arguments: arguments)
        _fixtureStage = State(initialValue: configuration.stage)
        _incidentReplay = StateObject(
            wrappedValue: RendererIncidentReplayModel(fixturePath: configuration.incidentFixturePath))
        autoExitSeconds = configuration.autoExitSeconds
        mathModeTitle = configuration.isSingleDollarMathDisabled
            ? "Disabled"
            : "Single-dollar inline"
    }

    private var style: IntatisThreadStyle {
        .intatisMac(colorScheme)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                fixtureHeader
                stagedFixture
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("renderer.fixture")
        .task(id: autoExitSeconds) {
            guard let autoExitSeconds else { return }
            let nanoseconds = UInt64(autoExitSeconds * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            NSApplication.shared.terminate(nil)
        }
    }

    private var fixtureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Intatis renderer fixture")
                .font(.title.bold())
            Text("Offline · SwiftStreamingMarkdown derivative · swift-markdown 0.8.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Renderer", selection: rendererModeSelection) {
                Text("Rich Markdown").tag(IntatisMessageRendererMode.microsoft.rawValue)
                Text("Plain safe").tag(IntatisMessageRendererMode.plainSafe.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("renderer.fixture.mode")

            Picker("Isolated workload", selection: $fixtureStage) {
                ForEach(RendererFixtureStage.allCases) { stage in
                    Text(stage.title).tag(stage)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("renderer.fixture.stage")

            Text("Active workload: \(fixtureStage.title)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("renderer.fixture.stage-status")

            Text("Math mode: \(mathModeTitle)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("renderer.fixture.math-mode")

            if let rendererLaunchOverride {
                Text("Current launch override: \(rendererLaunchOverride == .plainSafe ? "Plain safe" : "Rich Markdown"). Picker stores the next unforced launch mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("renderer.fixture.mode-override")
            }
        }
    }

    @ViewBuilder
    private var stagedFixture: some View {
        switch fixtureStage {
        case .minimal:
            fixtureSection("Minimal paragraph", identifier: "renderer.fixture.minimal") {
                message(
                    id: "fixture-minimal",
                    source: Self.minimalSource,
                    isComplete: true)
            }
        case .table:
            fixtureSection("Table only", identifier: "renderer.fixture.table") {
                message(
                    id: "fixture-table",
                    source: Self.tableSource,
                    isComplete: true)
            }
        case .codeSelection:
            fixtureSection("Code and selection", identifier: "renderer.fixture.code") {
                message(
                    id: "fixture-code",
                    source: Self.codeSelectionSource,
                    isComplete: true)
            }
        case .mathOne:
            fixtureSection("One inline formula", identifier: "renderer.fixture.math-one") {
                message(
                    id: "fixture-math-one",
                    source: Self.mathOneSource,
                    isComplete: true)
            }
        case .mathThirtyTwo:
            fixtureSection(
                "Thirty-two inline formulas",
                identifier: "renderer.fixture.math-thirty-two"
            ) {
                message(
                    id: "fixture-math-thirty-two",
                    source: Self.mathThirtyTwoSource,
                    isComplete: true)
            }
        case .mathStructure:
            fixtureSection(
                "Math across Markdown structures",
                identifier: "renderer.fixture.math-structure"
            ) {
                message(
                    id: "fixture-math-structure",
                    source: Self.mathStructureSource,
                    isComplete: true)
            }
        case .mathHistory:
            fixtureSection(
                "Math message history and re-entry",
                identifier: "renderer.fixture.math-history"
            ) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.mathHistoryMessages) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            message(
                                id: row.id,
                                source: row.source,
                                isComplete: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .quaternary.opacity(0.2),
                            in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .accessibilityIdentifier("renderer.fixture.math-history.rows")
            }
        case .mathStream:
            fixtureSection(
                "Inline math stream closure",
                identifier: "renderer.fixture.math-stream"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Advance math stream") {
                        mathStreamStage =
                            (mathStreamStage + 1) % Self.mathStreamingSources.count
                    }
                    .accessibilityIdentifier("renderer.fixture.math-stream.advance")
                    Text("Stage \(mathStreamStage + 1) / \(Self.mathStreamingSources.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("renderer.fixture.math-stream.status")
                    message(
                        id: "fixture-math-stream",
                        source: Self.mathStreamingSources[mathStreamStage],
                        isComplete: mathStreamStage == Self.mathStreamingSources.count - 1)
                }
            }
        case .streamReplacement:
            fixtureSection("Stream replacement", identifier: "renderer.fixture.streaming") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Advance stream") {
                        streamStage = (streamStage + 1) % Self.streamingSources.count
                    }
                    .accessibilityIdentifier("renderer.fixture.advance")
                    Text("Stage \(streamStage + 1) / \(Self.streamingSources.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("renderer.fixture.stream-status")
                    message(
                        id: "fixture-streaming",
                        source: Self.streamingSources[streamStage],
                        isComplete: streamStage == Self.streamingSources.count - 1)
                }
            }
        case .incidentReplay:
            incidentReplaySection
        case .fullStatic:
            fixtureSection("Full static document", identifier: "renderer.fixture.full") {
                message(
                    id: "fixture-combined",
                    source: Self.combinedSource,
                    isComplete: true)
            }
            fixtureSection("Long code line", identifier: "renderer.fixture.long-code") {
                message(
                    id: "fixture-long-code",
                    source: Self.longCodeSource,
                    isComplete: true)
            }
            fixtureSection("Safe fallbacks", identifier: "renderer.fixture.fallback") {
                message(
                    id: "fixture-fallback",
                    source: Self.fallbackSource,
                    isComplete: true)
            }
        }
    }

    private var incidentReplaySection: some View {
        fixtureSection("Sanitized 1,249-delta incident replay", identifier: "renderer.fixture.incident") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Start exact replay") {
                        incidentReplay.start()
                    }
                    .disabled(!incidentReplay.canStart)
                    .accessibilityIdentifier("renderer.fixture.incident.start")

                    Button("Cancel replay") {
                        incidentReplay.cancel()
                    }
                    .disabled(!incidentReplay.isRunning)
                    .accessibilityIdentifier("renderer.fixture.incident.cancel")
                }

                Text(incidentReplay.status)
                    .font(.caption.monospaced())
                    .foregroundStyle(incidentReplay.hasFailed ? .red : .secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("renderer.fixture.incident.status")

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(incidentReplay.rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("@\(row.agent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            message(
                                id: row.id,
                                source: row.rawText,
                                isComplete: row.isComplete)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .task {
                incidentReplay.loadIfNeeded()
            }
            .onDisappear {
                incidentReplay.cancel()
            }
        }
    }

    private func message(id: String, source: String, isComplete: Bool) -> some View {
        IntatisMessageContentView(
            messageID: id,
            rawText: source,
            isComplete: isComplete,
            policy: .richText,
            style: style)
    }

    private var rendererLaunchOverride: IntatisMessageRendererMode? {
        IntatisMessageRendererMode.launchOverride()
    }

    private var rendererModeSelection: Binding<String> {
        Binding(
            get: {
                IntatisMessageRendererMode.resolve(
                    persistedRawValue: rendererModeRawValue,
                    arguments: []).rawValue
            },
            set: { rendererModeRawValue = $0 })
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

    private static let minimalSource = #"""
    # Minimal containment

    One paragraph with **emphasis**, *italics*, `inline code`, and a [safe link](https://example.com).
    """#

    private static let tableSource = #"""
    # Table isolation

    | Component | Responsibility | Status |
    | --- | --- | --- |
    | SwiftStreamingMarkdown derivative | Native Markdown presentation | active |
    | swift-markdown | GFM structure | active |
    | Intatis facade | Latest-only admission and raw fallback | active |

    Malformed pipe input remains bounded and readable:

    ||||

    | too few |
    | --- | --- | --- |
    | one | two | three | extra |
    """#

    private static let codeSelectionSource = #"""
    # Code and selection isolation

    Select this paragraph, the inline token `literal`, and the complete code block below.

    ```swift
    let singleDollar = "$x$"
    let doubleDollar = "$$y$$"
    let bracketDelimiter = #"\[z\]"#
    let parenthesisDelimiter = #"\(z\)"#
    let escapedDollar = #"\$x$"#

    struct Fibonacci {
        static func values(upTo limit: Int) -> [Int] {
            var result = [0, 1]
            for index in 2..<limit {
                result.append(result[index - 1] + result[index - 2])
            }
            return result
        }
    }
    ```

    Delimiters inside code remain literal: `$x$`, `\(literalCode)`, `$$literalCode$$`, and `\[literalCode\]`.
    """#

    private static let mathOneSource = #"""
    # Single-dollar inline math

    Ordinary **Markdown**, *emphasis*, emoji 🧮, and a [safe link](https://example.com) stay on the normal renderer path.

    中文前缀 $\frac{a}{b} + \vec{x}_i = E = mc^2$ 中文后缀。

    The following delimiter-like text must remain literal:

    - Price: $29.99
    - Comparison: $5 and $10
    - Escaped delimiter: \$x$
    - Spaced delimiters: $ x $
    - Decimal-following closer: $x$1

    Inline code remains literal: `$x$`, `$$y$$`, `\(z\)`, and `\[z\]`.
    """#

    private static let mathThirtyTwoSource: String = {
        let formulas = (1...32).map { index in
            "$x_{\(index)}$"
        }
        return """
        # Thirty-two inline formulas

        This workload contains exactly thirty-two accepted candidates:

        \(formulas.joined(separator: " "))
        """
    }()

    private static let mathStructureSource = #"""
    # Heading formula $E = mc^2$

    The paragraph control is $\alpha + \beta = \gamma$ with ordinary **Markdown** around it.

    - Unordered list formula: $\sum_{i=1}^{n} i$
    - A second item keeps inline code literal: `$not_math$`

    1. Ordered list formula: $a^2 + b^2 = c^2$
    2. Ordered list text remains selectable.

    > Blockquote formula: $\frac{1}{2}mv^2$
    >
    > The quoted source must not expose an internal replacement token.

    | Location | Formula |
    | --- | --- |
    | Table body | $\int_0^1 x^2\,dx$ |
    | Literal control | `$table_code$` |

    Final paragraph formula: $\vec{F} = m\vec{a}$.
    """#

    private static let mathHistoryMessages: [MathHistoryFixtureMessage] = [
        MathHistoryFixtureMessage(
            id: "fixture-math-history-earliest",
            label: "Earlier completed answer",
            source: "Earlier result: $x_0 = 1$ and the source remains selectable."),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-markdown",
            label: "Intervening Markdown-only answer",
            source: "A **Markdown-only** history row separates the formula-bearing messages."),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-middle",
            label: "Later completed answer",
            source: "Later result: $x_1 = x_0 + 1$ with 中文上下文。"),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-latest",
            label: "Latest completed answer",
            source: "Latest result: $x_2 = x_1 + 1$."),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-reentry",
            label: "Stable re-entry sentinel",
            source: #"Leave this stage and return: $\sum_{k=0}^{2} x_k$ must rematerialize."#),
    ]

    private static let mathStreamingSources = [
        "$",
        "$x",
        "$x$",
        "$x$ 后",
        "$y$ 后",
    ]

    private static let combinedSource = #"""
    # Rendering that behaves like a chat answer

    The upstream renderer owns the **Markdown parser and layout**. This fixture covers *emphasis*, [a safe link](https://example.com), quotes, lists, tasks, and a table.

    > Rich content stays selectable and falls back to its original source.

    1. First item
       - Nested item
    2. Second item

    - [x] Markdown renderer
    - [x] Plain, selectable code blocks
    - [x] Raw-text safe mode

    | Component | Responsibility |
    | --- | --- |
    | SwiftStreamingMarkdown derivative | Native Markdown presentation |
    | swift-markdown | GFM structure |
    | Intatis facade | Backpressure and safe fallback |

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

    Inline math follows the validation launch mode: $E = mc^2$.

    Delimiters inside code are never rewritten: `\(literalCode)` and `$$literalCode$$`.
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

        Final source remains exact after the stream closes.
        """#,
    ]

    private static let fallbackSource = #"""
    Malformed math must remain visible rather than blank: $\notACommand{x}$

    Unknown languages still get a complete, selectable code container:

    ```future-lang
    quantum launch when ready
    ```

    Remote images are blocked: ![tracking pixel](https://example.com/tracker.png)
    """#
}

private enum RendererFixtureStage: String, CaseIterable, Identifiable {
    case minimal
    case table
    case codeSelection = "code-selection"
    case mathOne = "math-one"
    case mathThirtyTwo = "math-thirty-two"
    case mathStructure = "math-structure"
    case mathHistory = "math-history"
    case mathStream = "math-stream"
    case streamReplacement = "stream-replacement"
    case incidentReplay = "incident-replay"
    case fullStatic = "full-static"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: "Minimal paragraph"
        case .table: "Table only"
        case .codeSelection: "Code and selection"
        case .mathOne: "One inline formula"
        case .mathThirtyTwo: "Thirty-two inline formulas"
        case .mathStructure: "Math across Markdown structures"
        case .mathHistory: "Math message history and re-entry"
        case .mathStream: "Inline math stream closure"
        case .streamReplacement: "Stream replacement"
        case .incidentReplay: "1,249-delta replay"
        case .fullStatic: "Full static document"
        }
    }
}

private struct MathHistoryFixtureMessage: Identifiable {
    let id: String
    let label: String
    let source: String
}

private struct RendererFixtureLaunchConfiguration {
    static let stageFlag = "-IntatisRendererFixtureStage"
    static let incidentFixtureFlag = "-IntatisRendererIncidentFixture"
    static let autoExitFlag = "-IntatisRendererFixtureAutoExitSeconds"
    static let disableSingleDollarMathFlag = "-IntatisDisableSingleDollarMath"

    let stage: RendererFixtureStage
    let incidentFixturePath: String?
    let autoExitSeconds: Double?
    let isSingleDollarMathDisabled: Bool

    init(arguments: [String]) {
        stage = Self.value(after: Self.stageFlag, arguments: arguments)
            .flatMap(RendererFixtureStage.init(rawValue:))
            ?? .minimal
        incidentFixturePath = Self.value(after: Self.incidentFixtureFlag, arguments: arguments)
        autoExitSeconds = Self.value(after: Self.autoExitFlag, arguments: arguments)
            .flatMap(Double.init)
            .flatMap { (1...300).contains($0) ? $0 : nil }
        isSingleDollarMathDisabled = arguments.contains(
            Self.disableSingleDollarMathFlag)
    }

    private static func value(after flag: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}

private struct RendererIncidentFixture: Decodable {
    struct Message: Decodable {
        let id: String
        let agent: String
        let deltas: [String]

        var finalText: String { deltas.joined() }
    }

    let schema: Int
    let sourceDeltaCount: Int
    let messages: [Message]
}

@MainActor
private final class RendererIncidentReplayModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let agent: String
        var rawText: String
        var isComplete: Bool
    }

    static let expectedFixtureSHA256 = "fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1"
    static let expectedMessageCount = 17
    static let expectedDeltaCount = 1_249

    @Published private(set) var rows: [Row] = []
    @Published private(set) var status = "Fixture not loaded"
    @Published private(set) var isRunning = false
    @Published private(set) var hasFailed = false

    private let fixturePath: String?
    private var fixture: RendererIncidentFixture?
    private var replayTask: Task<Void, Never>?

    init(fixturePath: String?) {
        self.fixturePath = fixturePath
    }

    var canStart: Bool {
        fixture != nil && !isRunning
    }

    func loadIfNeeded() {
        guard fixture == nil, !hasFailed else { return }
        guard let fixturePath else {
            fail("Missing -IntatisRendererIncidentFixture PATH")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == Self.expectedFixtureSHA256 else {
                fail("Fixture SHA-256 mismatch")
                return
            }

            let decoded = try JSONDecoder().decode(RendererIncidentFixture.self, from: data)
            let deltaCount = decoded.messages.reduce(0) { $0 + $1.deltas.count }
            guard decoded.schema == 1,
                  decoded.messages.count == Self.expectedMessageCount,
                  decoded.sourceDeltaCount == Self.expectedDeltaCount,
                  deltaCount == Self.expectedDeltaCount,
                  Set(decoded.messages.map(\.id)).count == Self.expectedMessageCount
            else {
                fail("Fixture shape mismatch; expected 17 messages / 1,249 deltas")
                return
            }

            fixture = decoded
            rows = Self.emptyRows(for: decoded)
            status = "Ready · SHA-256 verified · 17 messages / 1,249 deltas"
        } catch {
            fail("Fixture load failed: \(error.localizedDescription)")
        }
    }

    func start() {
        loadIfNeeded()
        guard let fixture, !isRunning else { return }

        replayTask?.cancel()
        rows = Self.emptyRows(for: fixture)
        hasFailed = false
        isRunning = true
        status = "Replaying 0 / 1,249 deltas"

        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var applied = 0

            for messageIndex in fixture.messages.indices {
                let message = fixture.messages[messageIndex]
                for deltaIndex in message.deltas.indices {
                    guard !Task.isCancelled else {
                        self.isRunning = false
                        self.status = "Replay cancelled at \(applied) / 1,249 deltas"
                        return
                    }

                    self.rows[messageIndex].rawText += message.deltas[deltaIndex]
                    self.rows[messageIndex].isComplete = deltaIndex == message.deltas.index(before: message.deltas.endIndex)
                    applied += 1
                    if applied == 1 || applied.isMultiple(of: 50) || applied == Self.expectedDeltaCount {
                        self.status = "Replaying \(applied) / 1,249 deltas"
                    }

                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }

            let finalInputsAreExact = fixture.messages.indices.allSatisfy {
                self.rows[$0].rawText == fixture.messages[$0].finalText
                    && self.rows[$0].isComplete
            }
            self.isRunning = false
            if finalInputsAreExact {
                self.status = "Complete · 1,249 / 1,249 deltas · final raw inputs 17 / 17 exact"
            } else {
                self.fail("Replay completed but final raw inputs were not exact")
            }
        }
    }

    func cancel() {
        guard replayTask != nil else { return }
        replayTask?.cancel()
        replayTask = nil
        if isRunning {
            isRunning = false
            status = "Replay cancelled"
        }
    }

    private func fail(_ message: String) {
        replayTask?.cancel()
        replayTask = nil
        isRunning = false
        hasFailed = true
        status = message
    }

    private static func emptyRows(for fixture: RendererIncidentFixture) -> [Row] {
        fixture.messages.enumerated().map { index, message in
            Row(
                id: "fixture-incident-\(index + 1)",
                agent: message.agent,
                rawText: "",
                isComplete: false)
        }
    }
}
#endif
