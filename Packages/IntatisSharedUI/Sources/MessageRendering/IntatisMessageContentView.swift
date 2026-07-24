#if canImport(SwiftUI) && canImport(SwiftStreamingMarkdown)
import Combine
import Foundation
import SwiftUI
import SwiftStreamingMarkdown

public enum IntatisMessageRenderingPolicy: Sendable {
    case plainText
    case richText
}

/// A non-publishing lifecycle gate for one message facade. SwiftUI may rebuild
/// the value view for changes emitted by either projection; those rebuilds must
/// not resubmit the same raw snapshot or restart the same Markdown parse.
@MainActor
final class IntatisMessageProjectionLifecycleGate: ObservableObject {
    private var isVisible = false
    private var lastAppliedInput: IntatisMessageProjectionInput?

    func activate(
        _ input: IntatisMessageProjectionInput,
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard !isVisible else {
            receive(input, rawState: rawState, richState: richState)
            return
        }
        isVisible = true
        lastAppliedInput = nil
        apply(input, rawState: rawState, richState: richState)
    }

    func receive(
        _ input: IntatisMessageProjectionInput,
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard isVisible else { return }
        apply(input, rawState: rawState, richState: richState)
    }

    func deactivate(
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        isVisible = false
        lastAppliedInput = nil
        richState.deactivate()
        rawState.deactivate()
    }

    private func apply(
        _ input: IntatisMessageProjectionInput,
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard input != lastAppliedInput else { return }
        // Record before touching either ObservableObject so a SwiftUI rebuild
        // caused by publication is already a no-op when its Just emits.
        lastAppliedInput = input
        rawState.submit(input.rawRevision)
        if input.usesRichRenderer {
            richState.submit(request: input.richRequest)
        } else {
            richState.deactivate()
        }
    }
}

struct IntatisMessageProjectionInput: Equatable {
    let rawRevision: IntatisRawTextProjectionRevision
    let richRequest: IntatisMarkdownRenderRequest
    let usesRichRenderer: Bool
}

/// Renderer-neutral product facade shared by Chat, Code, Cowork, and iOS.
/// Raw text remains visible until an admitted upstream projection is ready.
public struct IntatisMessageContentView: View {
    let messageID: String
    let rawText: String
    let isComplete: Bool
    let policy: IntatisMessageRenderingPolicy
    let style: IntatisThreadStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var lifecycleGate = IntatisMessageProjectionLifecycleGate()
    @StateObject private var richState = IntatisMicrosoftMarkdownRenderState()
    @StateObject private var rawState: IntatisRawTextProjectionState
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var persistedRendererMode = IntatisMessageRendererMode.microsoft.rawValue

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
        _rawState = StateObject(wrappedValue: IntatisRawTextProjectionState(
            revision: IntatisRawTextProjectionRevision(
                activation: IntatisRawTextProjectionActivation(
                    messageID: messageID,
                    lane: policy == .richText ? .richFallback : .plain),
                rawText: rawText,
                isComplete: isComplete)))
    }

    public var body: some View {
        Group {
            if renderPlan.usesRichRenderer,
               let published = richState.publishedDocument,
               published.request == richRequest {
                DocumentView(
                    renderableDocument: published.document,
                    config: published.displayConfiguration)
                    .environment(\.openURL, OpenURLAction { url in
                        guard IntatisMarkdownLinkPolicy.allows(url) else { return .discarded }
                        return .systemAction(url)
                    })
                    .accessibilityIdentifier("intatis.message.microsoft.\(messageID)")
            } else {
                Text(verbatim: rawState.text(for: rawProjectionRevision))
                    .font(.system(size: 15 * typographyRevision.scale))
                    .foregroundStyle(style.primaryText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("intatis.message.plain.\(messageID)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(Just(projectionInput)) { input in
            lifecycleGate.receive(
                input,
                rawState: rawState,
                richState: richState)
        }
        .onAppear {
            // Keep one raw projection alive even while a rich document is on
            // screen. A rich→fallback transition therefore inherits the same
            // bounded stream instead of recreating an exact Text every token.
            lifecycleGate.activate(
                projectionInput,
                rawState: rawState,
                richState: richState)
        }
        .onDisappear {
            lifecycleGate.deactivate(
                rawState: rawState,
                richState: richState)
        }
    }

    private var rendererMode: IntatisMessageRendererMode {
        IntatisMessageRendererMode.resolve(persistedRawValue: persistedRendererMode)
    }

    private var renderPlan: IntatisMessageRenderPlan {
        IntatisMessageRenderPlan.resolve(
            rawText: rawText,
            isComplete: isComplete,
            policyIsRich: policy == .richText,
            rendererMode: rendererMode)
    }

    private var rawProjectionRevision: IntatisRawTextProjectionRevision {
        IntatisRawTextProjectionRevision(
            activation: IntatisRawTextProjectionActivation(
                messageID: messageID,
                lane: renderPlan.usesRichRenderer ? .richFallback : .plain),
            rawText: rawText,
            isComplete: isComplete)
    }

    private var renderRevision: IntatisMarkdownRenderRevision {
        IntatisMarkdownRenderRevision(
            messageID: messageID,
            rawText: rawText,
            isComplete: isComplete,
            appearance: IntatisMarkdownAppearanceRevision(colorScheme),
            typography: typographyRevision,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)
    }

    private var typographyRevision: IntatisMarkdownTypographyRevision {
        IntatisMarkdownTypographyRevision(dynamicTypeSize)
    }

    private var richRequest: IntatisMarkdownRenderRequest {
        IntatisMarkdownRenderRequest(
            revision: renderRevision,
            style: IntatisMarkdownStyleSnapshot(style))
    }

    private var projectionInput: IntatisMessageProjectionInput {
        IntatisMessageProjectionInput(
            rawRevision: rawProjectionRevision,
            richRequest: richRequest,
            usesRichRenderer: renderPlan.usesRichRenderer)
    }
}
#endif
