#if canImport(SwiftUI) && canImport(MarkdownUI) && canImport(iosMath)
import SwiftUI
import MarkdownUI
import iosMath

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// SwiftUI bridge adapted from iosMath's MIT-licensed
/// `SwiftMathExample/MathLabel.swift` at tag 2.5.0.
struct IntatisMathLabel: View {
    let source: String
    var fontSize: CGFloat
    var mode: MTMathUILabelMode
    var templateColor = false

    var body: some View {
        IntatisMathLabelRepresentable(
            source: source,
            fontSize: fontSize,
            mode: mode,
            templateColor: templateColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Math formula: \(source)")
    }
}

#if canImport(AppKit)
private struct IntatisMathLabelRepresentable: NSViewRepresentable {
    let source: String
    let fontSize: CGFloat
    let mode: MTMathUILabelMode
    let templateColor: Bool

    func makeNSView(context: Context) -> MTMathUILabel {
        MTMathUILabel()
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.latex = source
        label.fontSize = fontSize
        label.mode = mode
        label.textAlignment = .left
        label.displayErrorInline = false
        label.textColor = templateColor ? .black : .labelColor
        label.backgroundColor = .clear
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        IntatisMathLabelSizePolicy.size(proposal: proposal, intrinsic: nsView.intrinsicContentSize)
    }
}
#elseif canImport(UIKit)
private struct IntatisMathLabelRepresentable: UIViewRepresentable {
    let source: String
    let fontSize: CGFloat
    let mode: MTMathUILabelMode
    let templateColor: Bool

    func makeUIView(context: Context) -> MTMathUILabel {
        MTMathUILabel()
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        label.latex = source
        label.fontSize = fontSize
        label.mode = mode
        label.textAlignment = .left
        label.displayErrorInline = false
        label.textColor = templateColor ? .black : .label
        label.backgroundColor = .clear
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        IntatisMathLabelSizePolicy.size(proposal: proposal, intrinsic: uiView.intrinsicContentSize)
    }
}
#endif

private enum IntatisMathLabelSizePolicy {
    static func size(proposal: ProposedViewSize, intrinsic: CGSize) -> CGSize {
        guard let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: width, height: intrinsic.height)
    }
}

struct IntatisDisplayMathView: View {
    let expression: IntatisMathExpression

    var body: some View {
        ScrollView(.horizontal) {
            IntatisMathLabel(
                source: expression.source,
                fontSize: 18,
                mode: .display)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("intatis.math.display")
    }
}

struct IntatisStandaloneInlineMathView: View {
    let expression: IntatisMathExpression

    var body: some View {
        ScrollView(.horizontal) {
            IntatisMathLabel(
                source: expression.source,
                fontSize: 15,
                mode: .text)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("intatis.math.inline-standalone")
    }
}

struct IntatisMarkdownImageProvider: ImageProvider {
    let expressions: [String: IntatisMathExpression]

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        switch IntatisMathURL.route(for: url, in: expressions) {
        case .display(let expression):
            IntatisDisplayMathView(expression: expression)
        case .inline(let expression):
            // MarkdownUI promotes a paragraph containing only one image to
            // its block ImageProvider. Keep a sole inline formula mathematical
            // instead of misclassifying it as a blocked remote image.
            IntatisStandaloneInlineMathView(expression: expression)
        case .blocked:
            Label("Remote image blocked", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("intatis.markdown.image-blocked")
        }
    }
}

struct IntatisMarkdownInlineImageProvider: InlineImageProvider {
    let expressions: [String: IntatisMathExpression]

    func image(with url: URL, label: String) async throws -> Image {
        guard case .inline(let expression) = IntatisMathURL.route(
            for: url,
            in: expressions) else {
            return Image(systemName: "photo.badge.exclamationmark")
        }
        do {
            return try await IntatisInlineMathImageRenderer.image(for: expression)
        } catch {
            // MarkdownUI drops every inline image in a paragraph when an image
            // provider throws. Keep the paragraph intact and show a bounded,
            // visible failure marker; the persisted raw formula remains truth.
            return Image(systemName: "exclamationmark.triangle")
        }
    }
}

enum IntatisMathURL {
    enum Route: Equatable {
        case inline(IntatisMathExpression)
        case display(IntatisMathExpression)
        case blocked
    }

    static func route(
        for url: URL?,
        in expressions: [String: IntatisMathExpression]
    ) -> Route {
        guard let url,
              url.scheme == "intatis-math",
              let host = url.host,
              let expression = expressions[host + url.path] else {
            return .blocked
        }
        switch expression.presentation {
        case .inline: return .inline(expression)
        case .display: return .display(expression)
        }
    }
}

private enum IntatisInlineMathImageRenderer {
    enum RenderError: Error {
        case imageUnavailable
    }

    @MainActor
    static func image(for expression: IntatisMathExpression) throws -> Image {
        #if canImport(AppKit)
        let label = MTMathUILabel()
        label.fontSize = 15
        label.mode = .text
        label.textAlignment = .left
        label.displayErrorInline = false
        label.textColor = .black
        label.backgroundColor = .clear
        label.latex = expression.source
        let size = label.intrinsicContentSize
        guard IntatisMathRasterPolicy.allows(size: size, scale: 2) else {
            throw RenderError.imageUnavailable
        }
        label.frame = NSRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()
        guard let representation = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
            throw RenderError.imageUnavailable
        }
        label.cacheDisplay(in: label.bounds, to: representation)
        let rendered = NSImage(size: size)
        rendered.addRepresentation(representation)
        var proposedRect = NSRect(origin: .zero, size: size)
        guard let cgImage = rendered.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil) else {
            throw RenderError.imageUnavailable
        }
        return Image(
            cgImage,
            scale: 1,
            orientation: .up,
            label: Text("Math formula: \(expression.source)"))
            .renderingMode(.template)
        #elseif canImport(UIKit)
        let label = MTMathUILabel()
        label.fontSize = 15
        label.mode = .text
        label.textAlignment = .left
        label.displayErrorInline = false
        label.textColor = .black
        label.backgroundColor = .clear
        label.latex = expression.source
        let size = label.intrinsicContentSize
        guard IntatisMathRasterPolicy.allows(size: size, scale: 1) else {
            throw RenderError.imageUnavailable
        }
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }
        guard let cgImage = rendered.cgImage else {
            throw RenderError.imageUnavailable
        }
        return Image(
            cgImage,
            scale: 1,
            orientation: .up,
            label: Text("Math formula: \(expression.source)"))
            .renderingMode(.template)
        #endif
    }
}

/// Caps the actual bitmap dimensions before either platform allocates backing
/// storage. macOS is conservatively budgeted at 2x backing scale.
enum IntatisMathRasterPolicy {
    static let maximumPixelWidth: CGFloat = 1_024
    static let maximumPixelHeight: CGFloat = 256
    static let maximumPixelCount: CGFloat = 262_144

    static func allows(size: CGSize, scale: CGFloat) -> Bool {
        guard size.width.isFinite,
              size.height.isFinite,
              scale.isFinite,
              size.width > 0,
              size.height > 0,
              scale > 0 else {
            return false
        }
        let pixelWidth = ceil(size.width * scale)
        let pixelHeight = ceil(size.height * scale)
        return pixelWidth <= maximumPixelWidth
            && pixelHeight <= maximumPixelHeight
            && pixelWidth * pixelHeight <= maximumPixelCount
    }
}
#endif
