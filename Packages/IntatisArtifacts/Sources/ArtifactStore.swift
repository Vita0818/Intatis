import Foundation
import IntatisCore

/// File-backed artifact store. Blobs live under `<root>/blobs/`, the index in
/// `<root>/index.json`. An `actor`, so concurrent appends are safe.
public actor ArtifactStore {
    private let root: URL
    private let blobsDir: URL
    private let indexURL: URL
    private var index: [ArtifactID: ArtifactRef]

    public init(root: URL) throws {
        self.root = root
        self.blobsDir = root.appendingPathComponent("blobs", isDirectory: true)
        self.indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let refs = try? Self.makeDecoder().decode([ArtifactRef].self, from: data) {
            self.index = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            self.index = [:]
        }
    }

    @discardableResult
    public func add(kind: ArtifactKind,
                    mime: String,
                    data: Data,
                    ext: String,
                    producedBy: String? = nil,
                    prompt: String? = nil) throws -> ArtifactRef {
        let id = ArtifactID.new()
        let safeExt = ext.isEmpty ? "bin" : ext
        let filename = "\(id.rawValue).\(safeExt)"
        try data.write(to: blobsDir.appendingPathComponent(filename), options: .atomic)
        let ref = ArtifactRef(id: id, kind: kind, mime: mime,
                              path: "blobs/\(filename)", producedBy: producedBy, prompt: prompt)
        index[id] = ref
        try persist()
        return ref
    }

    @discardableResult
    public func addAttachment(name: String, data: Data, mime: String) throws -> ArtifactRef {
        try add(kind: .fileAttachment, mime: mime, data: data, ext: Self.fileExtension(of: name))
    }

    public func ref(for id: ArtifactID) -> ArtifactRef? { index[id] }

    public func data(for id: ArtifactID) throws -> Data {
        guard let ref = index[id] else { throw IntatisError.notFound("artifact \(id)") }
        return try Data(contentsOf: root.appendingPathComponent(ref.path))
    }

    public func list() -> [ArtifactRef] {
        index.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Absolute on-disk URL for an artifact. `nonisolated` because `root` is immutable.
    public nonisolated func absoluteURL(for ref: ArtifactRef) -> URL {
        root.appendingPathComponent(ref.path)
    }

    // MARK: - Private

    private func persist() throws {
        let refs = list()
        let data = try Self.makeEncoder().encode(refs)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func fileExtension(of name: String) -> String {
        let parts = name.split(separator: ".")
        return parts.count > 1 ? String(parts.last!) : ""
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
