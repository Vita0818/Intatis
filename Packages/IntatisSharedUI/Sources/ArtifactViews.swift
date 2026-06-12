#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// UI model for an artifact (built from `artifact_added` events). Kept in the UI
/// layer so SharedUI needn't depend on the Artifacts or Multimodal modules.
public struct ArtifactCardInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let mime: String
    public let path: String      // absolute
    public let prompt: String?
    public init(id: String, kind: String, mime: String, path: String, prompt: String?) {
        self.id = id
        self.kind = kind
        self.mime = mime
        self.path = path
        self.prompt = prompt
    }
}

/// Right-pane artifact list: image previews, transcript text, and a labeled row
/// for other kinds (ARCHITECTURE.md §3 inspector).
public struct ArtifactInspector: View {
    private let artifacts: [ArtifactCardInfo]
    public init(artifacts: [ArtifactCardInfo]) { self.artifacts = artifacts }

    public var body: some View {
        if artifacts.isEmpty {
            Text("No artifacts yet").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(artifacts) { ArtifactCardView(artifact: $0) }
        }
    }
}

struct ArtifactCardView: View {
    let artifact: ArtifactCardInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artifact.kind).font(.caption.bold())
            content
            if let prompt = artifact.prompt {
                Text(prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var content: some View {
        switch artifact.kind {
        case "image":
            imagePreview
        case "transcript":
            Text(fileText).font(.caption).textSelection(.enabled).lineLimit(8)
        default:
            Text(artifact.mime).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var imagePreview: some View {
        #if canImport(AppKit)
        if let image = NSImage(contentsOfFile: artifact.path) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text("(image unavailable)").font(.caption).foregroundStyle(.secondary)
        }
        #elseif canImport(UIKit)
        if let image = UIImage(contentsOfFile: artifact.path) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text("(image unavailable)").font(.caption).foregroundStyle(.secondary)
        }
        #else
        Text("(image)").font(.caption).foregroundStyle(.secondary)
        #endif
    }

    private var fileText: String {
        (try? String(contentsOfFile: artifact.path, encoding: .utf8)) ?? "(transcript)"
    }
}
#endif
