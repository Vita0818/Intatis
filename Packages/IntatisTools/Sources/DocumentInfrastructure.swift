import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisTools requires CryptoKit or swift-crypto")
#endif
import IntatisCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum DocumentToolErrorCode: String, Codable, Sendable {
    case backendMissing = "backend_missing"
    case backendVersionMismatch = "backend_version_mismatch"
    case backendFailed = "backend_failed"
    case unsupportedOperation = "unsupported_operation"
    case unsupportedFeature = "unsupported_feature"
    case ocrRequired = "ocr_required"
    case validationFailed = "validation_failed"
    case renderFailed = "render_failed"
    case outputConflict = "output_conflict"
    case commitUncertain = "commit_uncertain"
}

struct DocumentToolError: Error, LocalizedError, Sendable {
    let code: DocumentToolErrorCode
    let summary: String

    init(_ code: DocumentToolErrorCode, _ summary: String) {
        self.code = code
        self.summary = summary
    }

    var errorDescription: String? { "\(code.rawValue): \(summary)" }
}

enum DocumentFormat: String, Codable, CaseIterable, Sendable {
    case pdf, docx, pptx, xlsx, html, epub

    var isPDF: Bool { self == .pdf }

    static var editableFormats: Set<DocumentFormat> {
        [.docx, .pptx, .xlsx, .html, .epub]
    }
}

struct DocumentFileSnapshot: Equatable, Sendable {
    let sha256: String
    let byteCount: UInt64
    let deviceID: UInt64
    let fileID: UInt64
}

struct DocumentDirectorySnapshot: Equatable, Sendable {
    let sha256: String
    let fileCount: Int
    let byteCount: UInt64
}

struct DocumentCommitReceipt: Equatable, Sendable {
    let relativePath: String
    let sha256: String
    let byteCount: UInt64
    let fileCount: Int
    let cleanupWarning: String?
}

struct DocumentInputSnapshot: Equatable, Sendable {
    let url: URL
    let identity: DocumentFileSnapshot
}

enum DocumentInputFile {
    static func freeze(
        path: String,
        expectedFormat: DocumentFormat,
        expectedSHA256: String? = nil,
        maximumBytes: UInt64 = 512 * 1_024 * 1_024,
        workspace: URL
    ) throws -> DocumentInputSnapshot {
        try validateDigest(expectedSHA256, field: "expected_source_sha256")
        let root = try PathConfinement.canonicalExistingDirectory(workspace)
        let url = try resolveDocumentInputPath(path, within: root)
        let actualExtension = url.pathExtension.lowercased()
        let allowedExtensions: Set<String> = expectedFormat == .html
            ? ["html", "htm"]
            : [expectedFormat.rawValue]
        guard allowedExtensions.contains(actualExtension) else {
            throw DocumentToolError(.validationFailed, "input extension does not match format")
        }
        let identity = try snapshotRegularFile(url, maximumBytes: maximumBytes)
        if let expectedSHA256,
           identity.sha256 != expectedSHA256.lowercased() {
            throw DocumentToolError(.outputConflict, "source digest does not match the reviewed input")
        }
        return DocumentInputSnapshot(url: url, identity: identity)
    }

    static func verifyUnchanged(_ snapshot: DocumentInputSnapshot) throws {
        let current = try snapshotRegularFile(
            snapshot.url,
            maximumBytes: snapshot.identity.byteCount)
        guard current == snapshot.identity else {
            throw DocumentToolError(.outputConflict, "source changed during document processing")
        }
    }

    /// Freezes an auxiliary input (for example an image referenced by a write
    /// operation) without imposing a document-format extension. Callers pass
    /// the returned snapshot into the staged request so the transaction checks
    /// the exact reviewed file both before backend work and inside the commit
    /// lock.
    static func freezeReadOnly(
        path: String,
        expectedSHA256: String? = nil,
        maximumBytes: UInt64 = 512 * 1_024 * 1_024,
        workspace: URL
    ) throws -> DocumentInputSnapshot {
        try validateDigest(expectedSHA256, field: "expected_input_sha256")
        let root = try PathConfinement.canonicalExistingDirectory(workspace)
        let url = try resolveDocumentInputPath(path, within: root)
        let identity = try snapshotRegularFile(url, maximumBytes: maximumBytes)
        if let expectedSHA256,
           identity.sha256 != expectedSHA256.lowercased() {
            throw DocumentToolError(.outputConflict, "read-only input digest does not match the reviewed input")
        }
        return DocumentInputSnapshot(url: url, identity: identity)
    }
}

struct DocumentStagedFileRequest: Sendable {
    let sourcePath: String?
    let expectedSourceSHA256: String?
    let destinationPath: String
    let replaceExisting: Bool
    let expectedDestinationSHA256: String?
    let fileExtension: String
    let maximumBytes: UInt64
    let readOnlyInputSnapshots: [DocumentInputSnapshot]

    init(
        sourcePath: String?,
        expectedSourceSHA256: String?,
        destinationPath: String,
        replaceExisting: Bool,
        expectedDestinationSHA256: String?,
        fileExtension: String,
        maximumBytes: UInt64,
        readOnlyInputSnapshots: [DocumentInputSnapshot] = []
    ) {
        self.sourcePath = sourcePath
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.destinationPath = destinationPath
        self.replaceExisting = replaceExisting
        self.expectedDestinationSHA256 = expectedDestinationSHA256
        self.fileExtension = fileExtension
        self.maximumBytes = maximumBytes
        self.readOnlyInputSnapshots = readOnlyInputSnapshots
    }
}

struct DocumentStagedDirectoryRequest: Sendable {
    let sourcePath: String?
    let expectedSourceSHA256: String?
    let destinationPath: String
    let replaceExisting: Bool
    let expectedDestinationSHA256: String?
    let maximumFiles: Int
    let maximumBytes: UInt64
    let readOnlyInputSnapshots: [DocumentInputSnapshot]

    init(
        sourcePath: String?,
        expectedSourceSHA256: String?,
        destinationPath: String,
        replaceExisting: Bool,
        expectedDestinationSHA256: String?,
        maximumFiles: Int,
        maximumBytes: UInt64,
        readOnlyInputSnapshots: [DocumentInputSnapshot] = []
    ) {
        self.sourcePath = sourcePath
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.destinationPath = destinationPath
        self.replaceExisting = replaceExisting
        self.expectedDestinationSHA256 = expectedDestinationSHA256
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
        self.readOnlyInputSnapshots = readOnlyInputSnapshots
    }
}

/// Host-owned staged output transaction for backend-generated documents.
/// The backend sees only a random same-parent stage. Validation and digesting
/// finish before the synchronous terminal commit begins; after that point no
/// cancellation check is performed until read-back reconciliation completes.
enum DocumentStagedOutput {
    static func writeFile(
        _ request: DocumentStagedFileRequest,
        workspace: URL,
        produce: @Sendable (URL) async throws -> Void,
        validate: @Sendable (URL) throws -> Void
    ) async throws -> DocumentCommitReceipt {
        try validateDigest(request.expectedSourceSHA256, field: "expected_source_sha256")
        try validateDigest(
            request.expectedDestinationSHA256,
            field: "expected_destination_sha256")
        guard request.maximumBytes > 0 else {
            throw DocumentToolError(.validationFailed, "maximum output size must be positive")
        }
        let locations = try preflightLocations(
            sourcePath: request.sourcePath,
            destinationPath: request.destinationPath,
            workspace: workspace)
        defer { _ = close(locations.parent.descriptor) }
        let baseline = try preflight(
            source: locations.source,
            expectedSourceSHA256: request.expectedSourceSHA256,
            readOnlyInputSnapshots: request.readOnlyInputSnapshots,
            destinationParent: locations.parent,
            destinationName: locations.destinationName,
            replaceExisting: request.replaceExisting,
            expectedDestinationSHA256: request.expectedDestinationSHA256)
        let stage = try createStageDirectory(parent: locations.parent)
        defer {
            _ = close(stage.descriptor)
            removeStageIfSafe(stage, parent: locations.parent)
        }
        let suffix = normalizedExtension(request.fileExtension)
        let payload = stage.url.appendingPathComponent("payload\(suffix)", isDirectory: false)
        let payloadName = payload.lastPathComponent
        try await produce(payload)
        try validate(payload)
        let staged = try snapshotRegularFile(
            at: stage.descriptor,
            name: payloadName,
            maximumBytes: request.maximumBytes)
        try Task.checkCancellation()

        return try commitFile(
            payloadName: payloadName,
            stage: stage,
            staged: staged,
            source: locations.source,
            destination: locations.destination,
            destinationParent: locations.parent,
            destinationName: locations.destinationName,
            baseline: baseline,
            replaceExisting: request.replaceExisting,
            workspace: workspace)
    }

    static func writeDirectory(
        _ request: DocumentStagedDirectoryRequest,
        workspace: URL,
        produce: @Sendable (URL) async throws -> Void,
        validate: @Sendable (URL) throws -> Void
    ) async throws -> DocumentCommitReceipt {
        try validateDigest(request.expectedSourceSHA256, field: "expected_source_sha256")
        try validateDigest(
            request.expectedDestinationSHA256,
            field: "expected_destination_sha256")
        guard request.maximumFiles > 0, request.maximumBytes > 0 else {
            throw DocumentToolError(.validationFailed, "directory output limits must be positive")
        }
        let locations = try preflightLocations(
            sourcePath: request.sourcePath,
            destinationPath: request.destinationPath,
            workspace: workspace)
        defer { _ = close(locations.parent.descriptor) }
        let baseline = try preflight(
            source: locations.source,
            expectedSourceSHA256: request.expectedSourceSHA256,
            readOnlyInputSnapshots: request.readOnlyInputSnapshots,
            destinationParent: locations.parent,
            destinationName: locations.destinationName,
            replaceExisting: request.replaceExisting,
            expectedDestinationSHA256: request.expectedDestinationSHA256)
        let stage = try createStageDirectory(parent: locations.parent)
        defer {
            _ = close(stage.descriptor)
            removeStageIfSafe(stage, parent: locations.parent)
        }
        try await produce(stage.url)
        try validate(stage.url)
        let staged = try snapshotDirectory(
            stage.descriptor,
            maximumFiles: request.maximumFiles,
            maximumBytes: request.maximumBytes)
        try Task.checkCancellation()

        let receipt = try commitDirectory(
            stage: stage,
            staged: staged,
            source: locations.source,
            destination: locations.destination,
            destinationParent: locations.parent,
            destinationName: locations.destinationName,
            baseline: baseline,
            replaceExisting: request.replaceExisting,
            workspace: workspace)
        return receipt
    }
}

private struct DocumentPreflightBaseline {
    let source: DocumentFileSnapshot?
    let readOnlyInputSnapshots: [DocumentInputSnapshot]
    let destinationFile: DocumentFileSnapshot?
    let destinationDirectory: DocumentDirectorySnapshot?
    let destinationDirectoryIdentity: DirectoryIdentity?
    let destinationKind: DocumentDestinationKind
}

private enum DocumentDestinationKind: Equatable {
    case missing
    case file
    case directory
}

private struct DocumentLocations {
    let source: URL?
    let destination: URL
    let parent: PinnedDirectory
    let destinationName: String
}

private struct PinnedDirectory {
    let url: URL
    let descriptor: Int32
    let identity: DirectoryIdentity
}

private func preflightLocations(
    sourcePath: String?,
    destinationPath: String,
    workspace: URL
) throws -> DocumentLocations {
    let root = try PathConfinement.canonicalExistingDirectory(workspace)
    let source = try sourcePath.map { try PathConfinement.resolve($0, within: root) }
    let destination = try PathConfinement.resolve(destinationPath, within: root)
    guard destination.path != root.path else {
        throw DocumentToolError(.validationFailed, "workspace root cannot be a document destination")
    }
    let parent = destination.deletingLastPathComponent()
    let descriptor = open(parent.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "destination parent must be an existing safe directory")
    }
    guard let identity = safeDirectoryIdentity(descriptor) else {
        _ = close(descriptor)
        throw DocumentToolError(.validationFailed, "destination parent must be an existing safe directory")
    }
    guard safeDirectoryIdentity(parent) == identity else {
        _ = close(descriptor)
        throw DocumentToolError(.validationFailed, "destination parent identity changed during preflight")
    }
    return DocumentLocations(
        source: source,
        destination: destination,
        parent: PinnedDirectory(url: parent, descriptor: descriptor, identity: identity),
        destinationName: destination.lastPathComponent)
}

private func preflight(
    source: URL?,
    expectedSourceSHA256: String?,
    readOnlyInputSnapshots: [DocumentInputSnapshot],
    destinationParent: PinnedDirectory,
    destinationName: String,
    replaceExisting: Bool,
    expectedDestinationSHA256: String?
) throws -> DocumentPreflightBaseline {
    let sourceSnapshot: DocumentFileSnapshot?
    if let source {
        sourceSnapshot = try snapshotRegularFile(source, maximumBytes: UInt64.max)
        if let expectedSourceSHA256,
           sourceSnapshot?.sha256 != expectedSourceSHA256.lowercased() {
            throw DocumentToolError(.outputConflict, "source digest does not match the reviewed input")
        }
    } else {
        sourceSnapshot = nil
        if expectedSourceSHA256 != nil {
            throw DocumentToolError(.validationFailed, "source digest requires source_path")
        }
    }

    try verifyReadOnlyInputs(readOnlyInputSnapshots, phase: "preflight")
    try verifyPinnedDirectoryPath(destinationParent)
    let destinationState = try destinationSnapshot(
        parentDescriptor: destinationParent.descriptor,
        name: destinationName)
    switch destinationState {
    case .missing:
        guard replaceExisting == false, expectedDestinationSHA256 == nil else {
            throw DocumentToolError(
                .outputConflict,
                "replacement was requested but the destination does not exist")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            readOnlyInputSnapshots: readOnlyInputSnapshots,
            destinationFile: nil,
            destinationDirectory: nil,
            destinationDirectoryIdentity: nil,
            destinationKind: .missing)
    case .file(let snapshot):
        guard replaceExisting,
              let expectedDestinationSHA256,
              snapshot.sha256 == expectedDestinationSHA256.lowercased() else {
            throw DocumentToolError(
                .outputConflict,
                "existing destination requires replace_existing and its exact digest")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            readOnlyInputSnapshots: readOnlyInputSnapshots,
            destinationFile: snapshot,
            destinationDirectory: nil,
            destinationDirectoryIdentity: nil,
            destinationKind: .file)
    case .directory(let snapshot, let identity):
        guard replaceExisting,
              let expectedDestinationSHA256,
              snapshot.sha256 == expectedDestinationSHA256.lowercased() else {
            throw DocumentToolError(
                .outputConflict,
                "existing destination directory requires replace_existing and its exact digest")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            readOnlyInputSnapshots: readOnlyInputSnapshots,
            destinationFile: nil,
            destinationDirectory: snapshot,
            destinationDirectoryIdentity: identity,
            destinationKind: .directory)
    }
}

private enum DestinationSnapshot {
    case missing
    case file(DocumentFileSnapshot)
    case directory(DocumentDirectorySnapshot, DirectoryIdentity)
}

private func destinationSnapshot(
    parentDescriptor: Int32,
    name: String
) throws -> DestinationSnapshot {
    var status = stat()
    let result = name.withCString {
        fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        if errno == ENOENT { return .missing }
        throw DocumentToolError(.validationFailed, "destination metadata could not be inspected")
    }
    switch status.st_mode & S_IFMT {
    case S_IFREG:
        let snapshot = try snapshotRegularFile(
            at: parentDescriptor,
            name: name,
            maximumBytes: UInt64.max)
        guard snapshot.deviceID == UInt64(status.st_dev),
              snapshot.fileID == UInt64(status.st_ino) else {
            throw DocumentToolError(.outputConflict, "destination changed while it was inspected")
        }
        return .file(snapshot)
    case S_IFDIR:
        let descriptor = try openDirectory(at: parentDescriptor, name: name)
        defer { _ = close(descriptor) }
        guard let identity = safeDirectoryIdentity(descriptor),
              identity.deviceID == UInt64(status.st_dev),
              identity.fileID == UInt64(status.st_ino) else {
            throw DocumentToolError(.outputConflict, "destination directory changed while it was inspected")
        }
        return .directory(try snapshotDirectory(
            descriptor,
            maximumFiles: 100_000,
            maximumBytes: UInt64.max), identity)
    default:
        throw DocumentToolError(.validationFailed, "destination must be a regular file or directory")
    }
}

private struct DocumentStage {
    let url: URL
    let name: String
    let descriptor: Int32
    let identity: DirectoryIdentity
}

private func createStageDirectory(parent: PinnedDirectory) throws -> DocumentStage {
    try verifyPinnedDirectoryPath(parent)
    guard safeDirectoryIdentity(parent.descriptor) == parent.identity else {
        throw DocumentToolError(.validationFailed, "destination parent identity changed")
    }
    for _ in 0..<8 {
        let name = ".intatis-document-stage-\(UUID().uuidString)"
        let created = name.withCString { mkdirat(parent.descriptor, $0, S_IRWXU) }
        if created == 0 {
            let descriptor: Int32 = name.withCString {
                openat(parent.descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
            }
            guard descriptor >= 0,
                  let identity = safeDirectoryIdentity(descriptor),
                  identity.permissions == UInt16(S_IRWXU) else {
                if descriptor >= 0 { _ = close(descriptor) }
                _ = name.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
                throw DocumentToolError(.validationFailed, "staging directory is unsafe")
            }
            return DocumentStage(
                url: parent.url.appendingPathComponent(name, isDirectory: true),
                name: name,
                descriptor: descriptor,
                identity: identity)
        }
        if errno != EEXIST { break }
    }
    throw DocumentToolError(.backendFailed, "could not create same-directory staging")
}

private func removeStageIfSafe(_ stage: DocumentStage, parent: PinnedDirectory) {
    guard stage.name.hasPrefix(".intatis-document-stage-") else { return }
    try? removeDirectoryTree(
        parentDescriptor: parent.descriptor,
        name: stage.name,
        expectedIdentity: stage.identity)
}

private struct DirectoryIdentity: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let permissions: UInt16
}

private func safeDirectoryIdentity(_ url: URL) -> DirectoryIdentity? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return DirectoryIdentity(
        deviceID: UInt64(status.st_dev),
        fileID: UInt64(status.st_ino),
        permissions: UInt16(status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)))
}

private func safeDirectoryIdentity(_ descriptor: Int32) -> DirectoryIdentity? {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return DirectoryIdentity(
        deviceID: UInt64(status.st_dev),
        fileID: UInt64(status.st_ino),
        permissions: UInt16(status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)))
}

private func verifyPinnedDirectoryPath(_ directory: PinnedDirectory) throws {
    guard safeDirectoryIdentity(directory.descriptor) == directory.identity,
          safeDirectoryIdentity(directory.url) == directory.identity else {
        throw DocumentToolError(.outputConflict, "destination parent changed during document processing")
    }
}

private func snapshotRegularFile(
    _ url: URL,
    maximumBytes: UInt64
) throws -> DocumentFileSnapshot {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "document file could not be opened safely")
    }
    defer { _ = close(descriptor) }
    return try snapshotRegularFile(descriptor, maximumBytes: maximumBytes)
}

private func snapshotRegularFile(
    at directoryDescriptor: Int32,
    name: String,
    maximumBytes: UInt64
) throws -> DocumentFileSnapshot {
    let descriptor: Int32 = name.withCString {
        openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "document file could not be opened safely")
    }
    defer { _ = close(descriptor) }
    return try snapshotRegularFile(descriptor, maximumBytes: maximumBytes)
}

private func snapshotRegularFile(
    _ descriptor: Int32,
    maximumBytes: UInt64
) throws -> DocumentFileSnapshot {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          status.st_size >= 0 else {
        throw DocumentToolError(.validationFailed, "document output is not a safe single-link regular file")
    }
    let byteCount = UInt64(status.st_size)
    guard byteCount <= maximumBytes else {
        throw DocumentToolError(.validationFailed, "document output exceeds the configured byte limit")
    }
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw DocumentToolError(.validationFailed, "document output could not be read for digesting")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return read(descriptor, base, raw.count)
        }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw DocumentToolError(.validationFailed, "document output digest read failed")
        }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          UInt64(status.st_size) == byteCount else {
        throw DocumentToolError(.validationFailed, "document output changed while it was validated")
    }
    return DocumentFileSnapshot(
        sha256: hexadecimal(hasher.finalize()),
        byteCount: byteCount,
        deviceID: UInt64(status.st_dev),
        fileID: UInt64(status.st_ino))
}

private struct DocumentDirectoryEntrySnapshot {
    let relativePath: String
    let snapshot: DocumentFileSnapshot
}

private struct DocumentDirectoryNode: Hashable {
    let deviceID: UInt64
    let fileID: UInt64
}

private func snapshotDirectory(
    _ rootDescriptor: Int32,
    maximumFiles: Int,
    maximumBytes: UInt64
) throws -> DocumentDirectorySnapshot {
    guard safeDirectoryIdentity(rootDescriptor) != nil else {
        throw DocumentToolError(.validationFailed, "document output bundle is not a safe directory")
    }
    var files: [DocumentDirectoryEntrySnapshot] = []
    var visited: Set<DocumentDirectoryNode> = []
    var observedBytes: UInt64 = 0
    try collectDirectorySnapshots(
        descriptor: rootDescriptor,
        prefix: "",
        maximumFiles: maximumFiles,
        maximumBytes: maximumBytes,
        files: &files,
        observedBytes: &observedBytes,
        visited: &visited)
    files.sort { $0.relativePath < $1.relativePath }
    var total: UInt64 = 0
    var hasher = SHA256()
    for file in files {
        let relative = file.relativePath
        let snapshot = file.snapshot
        let next = total.addingReportingOverflow(snapshot.byteCount)
        guard next.overflow == false, next.partialValue <= maximumBytes else {
            throw DocumentToolError(.validationFailed, "document output bundle exceeds the byte limit")
        }
        total = next.partialValue
        let pathData = Data(relative.utf8)
        hasher.update(data: framed(pathData))
        hasher.update(data: framed(Data(snapshot.sha256.utf8)))
        hasher.update(data: framed(Data(String(snapshot.byteCount).utf8)))
    }
    return DocumentDirectorySnapshot(
        sha256: hexadecimal(hasher.finalize()),
        fileCount: files.count,
        byteCount: total)
}

private func collectDirectorySnapshots(
    descriptor: Int32,
    prefix: String,
    maximumFiles: Int,
    maximumBytes: UInt64,
    files: inout [DocumentDirectoryEntrySnapshot],
    observedBytes: inout UInt64,
    visited: inout Set<DocumentDirectoryNode>
) throws {
    guard let identity = safeDirectoryIdentity(descriptor) else {
        throw DocumentToolError(.validationFailed, "document output bundle contains an unsafe directory")
    }
    let node = DocumentDirectoryNode(deviceID: identity.deviceID, fileID: identity.fileID)
    guard visited.insert(node).inserted else {
        throw DocumentToolError(.validationFailed, "document output bundle contains a directory cycle")
    }

    let enumerationDescriptor = openat(
        descriptor,
        ".",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard enumerationDescriptor >= 0,
          let directory = fdopendir(enumerationDescriptor) else {
        if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
        throw DocumentToolError(.validationFailed, "document output bundle could not be enumerated")
    }
    defer { _ = closedir(directory) }

    while let entry = readdir(directory) {
        let name = directoryEntryName(entry)
        if name == "." || name == ".." { continue }

        var status = stat()
        let inspected = name.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0 else {
            throw DocumentToolError(.validationFailed, "document output bundle changed while it was enumerated")
        }
        let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            let snapshot = try snapshotRegularFile(
                at: descriptor,
                name: name,
                maximumBytes: maximumBytes)
            guard snapshot.deviceID == UInt64(status.st_dev),
                  snapshot.fileID == UInt64(status.st_ino) else {
                throw DocumentToolError(.validationFailed, "document output bundle entry changed while it was inspected")
            }
            let next = observedBytes.addingReportingOverflow(snapshot.byteCount)
            guard next.overflow == false, next.partialValue <= maximumBytes else {
                throw DocumentToolError(.validationFailed, "document output bundle exceeds the byte limit")
            }
            observedBytes = next.partialValue
            files.append(DocumentDirectoryEntrySnapshot(
                relativePath: relative,
                snapshot: snapshot))
            guard files.count <= maximumFiles else {
                throw DocumentToolError(.validationFailed, "document output bundle exceeds the file-count limit")
            }
        case S_IFDIR:
            let child = try openDirectory(at: descriptor, name: name)
            defer { _ = close(child) }
            guard let childIdentity = safeDirectoryIdentity(child),
                  childIdentity.deviceID == UInt64(status.st_dev),
                  childIdentity.fileID == UInt64(status.st_ino) else {
                throw DocumentToolError(.validationFailed, "document output bundle directory changed while it was inspected")
            }
            try collectDirectorySnapshots(
                descriptor: child,
                prefix: relative,
                maximumFiles: maximumFiles,
                maximumBytes: maximumBytes,
                files: &files,
                observedBytes: &observedBytes,
                visited: &visited)
        default:
            throw DocumentToolError(.validationFailed, "document output bundle contains a non-regular entry")
        }
    }

    guard safeDirectoryIdentity(descriptor) == identity else {
        throw DocumentToolError(.validationFailed, "document output bundle directory changed during validation")
    }
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
            to: CChar.self,
            capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
            String(cString: $0)
        }
    }
}

private func openDirectory(at parentDescriptor: Int32, name: String) throws -> Int32 {
    let descriptor: Int32 = name.withCString {
        openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    }
    guard descriptor >= 0,
          safeDirectoryIdentity(descriptor) != nil else {
        if descriptor >= 0 { _ = close(descriptor) }
        throw DocumentToolError(.validationFailed, "document directory could not be opened safely")
    }
    return descriptor
}

private func commitFile(
    payloadName: String,
    stage: DocumentStage,
    staged: DocumentFileSnapshot,
    source: URL?,
    destination: URL,
    destinationParent: PinnedDirectory,
    destinationName: String,
    baseline: DocumentPreflightBaseline,
    replaceExisting: Bool,
    workspace: URL
) throws -> DocumentCommitReceipt {
    guard baseline.destinationKind != .directory else {
        throw DocumentToolError(.outputConflict, "a file output cannot replace a directory")
    }
    try verifyPinnedDirectoryPath(destinationParent)
    let lock = documentLockURL(destination: destination)
    return try DurableOwnerOnlyFile.withExclusiveLock(at: lock) {
        try verifyPinnedDirectoryPath(destinationParent)
        try recheckPreconditions(
            source: source,
            destinationParent: destinationParent,
            destinationName: destinationName,
            baseline: baseline)
        let stageNow = try snapshotRegularFile(
            at: stage.descriptor,
            name: payloadName,
            maximumBytes: staged.byteCount)
        guard stageNow == staged else {
            throw DocumentToolError(.validationFailed, "staged output changed before commit")
        }
        try synchronizeRegularFile(at: stage.descriptor, name: payloadName)

        var commitStarted = false
        do {
            if replaceExisting {
                let renamed = payloadName.withCString { payloadPointer in
                    destinationName.withCString { destinationPointer in
                        renameat(
                            stage.descriptor,
                            payloadPointer,
                            destinationParent.descriptor,
                            destinationPointer)
                    }
                }
                guard renamed == 0 else {
                    throw DocumentToolError(.backendFailed, "atomic document replacement failed")
                }
            } else {
                try installFileExclusively(
                    payloadDirectoryDescriptor: stage.descriptor,
                    payloadName: payloadName,
                    destinationParentDescriptor: destinationParent.descriptor,
                    destinationName: destinationName)
            }
            commitStarted = true
            guard synchronizeRegularFileIfPresent(
                    at: destinationParent.descriptor,
                    name: destinationName),
                  fsync(destinationParent.descriptor) == 0 else {
                throw DocumentToolError(.commitUncertain, "installed document could not be synchronized")
            }
            let installed = try snapshotRegularFile(
                at: destinationParent.descriptor,
                name: destinationName,
                maximumBytes: staged.byteCount)
            guard installed == staged else {
                throw DocumentToolError(.commitUncertain, "installed document does not match staged bytes")
            }
            try verifyPinnedDirectoryPath(destinationParent)
            return DocumentCommitReceipt(
                relativePath: PathConfinement.relativePath(of: destination, root: workspace),
                sha256: installed.sha256,
                byteCount: installed.byteCount,
                fileCount: 1,
                cleanupWarning: nil)
        } catch let error as DocumentToolError {
            if commitStarted, error.code != .commitUncertain {
                throw DocumentToolError(.commitUncertain, "document commit began but reconciliation failed")
            }
            throw error
        } catch {
            throw DocumentToolError(
                commitStarted ? .commitUncertain : .backendFailed,
                commitStarted
                    ? "document commit began but reconciliation failed"
                    : "document could not be atomically installed")
        }
    }
}

private func commitDirectory(
    stage: DocumentStage,
    staged: DocumentDirectorySnapshot,
    source: URL?,
    destination: URL,
    destinationParent: PinnedDirectory,
    destinationName: String,
    baseline: DocumentPreflightBaseline,
    replaceExisting: Bool,
    workspace: URL
) throws -> DocumentCommitReceipt {
    guard baseline.destinationKind != .file else {
        throw DocumentToolError(.outputConflict, "a directory output cannot replace a file")
    }
    try verifyPinnedDirectoryPath(destinationParent)
    let lock = documentLockURL(destination: destination)
    return try DurableOwnerOnlyFile.withExclusiveLock(at: lock) {
        try verifyPinnedDirectoryPath(destinationParent)
        try recheckPreconditions(
            source: source,
            destinationParent: destinationParent,
            destinationName: destinationName,
            baseline: baseline)
        let stageNow = try snapshotDirectory(
            stage.descriptor,
            maximumFiles: max(staged.fileCount, 1),
            maximumBytes: staged.byteCount)
        guard stageNow == staged else {
            throw DocumentToolError(.validationFailed, "staged output bundle changed before commit")
        }
        try synchronizeDirectoryTree(stage.descriptor)

        var commitStarted = false
        do {
            if replaceExisting {
                try exchangeDirectories(
                    parentDescriptor: destinationParent.descriptor,
                    stageName: stage.name,
                    destinationName: destinationName)
            } else {
                try installDirectoryExclusively(
                    parentDescriptor: destinationParent.descriptor,
                    stageName: stage.name,
                    destinationName: destinationName)
            }
            commitStarted = true
            guard fsync(destinationParent.descriptor) == 0 else {
                throw DocumentToolError(.commitUncertain, "installed output bundle could not be synchronized")
            }
            let installedDescriptor = try openDirectory(
                at: destinationParent.descriptor,
                name: destinationName)
            defer { _ = close(installedDescriptor) }
            let installed = try snapshotDirectory(
                installedDescriptor,
                maximumFiles: max(staged.fileCount, 1),
                maximumBytes: staged.byteCount)
            guard installed == staged else {
                throw DocumentToolError(.commitUncertain, "installed output bundle does not match staged files")
            }
            var cleanupWarning: String?
            if replaceExisting {
                do {
                    guard let replacedIdentity = baseline.destinationDirectoryIdentity else {
                        throw DocumentToolError(.commitUncertain, "replaced output identity is unavailable")
                    }
                    try removeDirectoryTree(
                        parentDescriptor: destinationParent.descriptor,
                        name: stage.name,
                        expectedIdentity: replacedIdentity)
                } catch {
                    cleanupWarning = "the replaced output was retained in an internal staging directory"
                }
            }
            try verifyPinnedDirectoryPath(destinationParent)
            return DocumentCommitReceipt(
                relativePath: PathConfinement.relativePath(of: destination, root: workspace),
                sha256: installed.sha256,
                byteCount: installed.byteCount,
                fileCount: installed.fileCount,
                cleanupWarning: cleanupWarning)
        } catch let error as DocumentToolError {
            if commitStarted, error.code != .commitUncertain {
                throw DocumentToolError(.commitUncertain, "bundle commit began but reconciliation failed")
            }
            throw error
        } catch {
            throw DocumentToolError(
                commitStarted ? .commitUncertain : .backendFailed,
                commitStarted
                    ? "bundle commit began but reconciliation failed"
                    : "output bundle could not be atomically installed")
        }
    }
}

private func recheckPreconditions(
    source: URL?,
    destinationParent: PinnedDirectory,
    destinationName: String,
    baseline: DocumentPreflightBaseline
) throws {
    if let source, let expected = baseline.source {
        let current = try snapshotRegularFile(source, maximumBytes: expected.byteCount)
        guard current == expected else {
            throw DocumentToolError(.outputConflict, "source changed before commit")
        }
    }
    try verifyReadOnlyInputs(baseline.readOnlyInputSnapshots, phase: "commit")
    try verifyPinnedDirectoryPath(destinationParent)
    let current = try destinationSnapshot(
        parentDescriptor: destinationParent.descriptor,
        name: destinationName)
    switch (baseline.destinationKind, current) {
    case (.missing, .missing):
        return
    case (.file, .file(let snapshot)) where snapshot == baseline.destinationFile:
        return
    case (.directory, .directory(let snapshot, let identity))
        where snapshot == baseline.destinationDirectory
            && identity == baseline.destinationDirectoryIdentity:
        return
    default:
        throw DocumentToolError(.outputConflict, "destination changed before commit")
    }
}

private func documentLockURL(destination: URL) -> URL {
    let digest = hexadecimal(SHA256.hash(data: Data(destination.path.utf8)))
    return destination.deletingLastPathComponent().appendingPathComponent(
        ".intatis-document-lock-\(digest).lock",
        isDirectory: false)
}

private func verifyReadOnlyInputs(
    _ snapshots: [DocumentInputSnapshot],
    phase: String
) throws {
    for snapshot in snapshots {
        do {
            let current = try snapshotRegularFile(
                snapshot.url,
                maximumBytes: snapshot.identity.byteCount)
            guard current == snapshot.identity else {
                throw DocumentToolError(
                    .outputConflict,
                    "read-only input changed during document processing")
            }
        } catch let error as DocumentToolError where error.code == .outputConflict {
            throw error
        } catch {
            throw DocumentToolError(
                .outputConflict,
                "read-only input failed the \(phase) identity check")
        }
    }
}

private func installFileExclusively(
    payloadDirectoryDescriptor: Int32,
    payloadName: String,
    destinationParentDescriptor: Int32,
    destinationName: String
) throws {
    #if canImport(Darwin)
    let result = payloadName.withCString { payloadPointer in
        destinationName.withCString { destinationPointer in
            renameatx_np(
                payloadDirectoryDescriptor,
                payloadPointer,
                destinationParentDescriptor,
                destinationPointer,
                UInt32(RENAME_EXCL))
        }
    }
    guard result == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "destination appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic document creation failed")
    }
    #else
    let linked = payloadName.withCString { payloadPointer in
        destinationName.withCString { destinationPointer in
            linkat(
                payloadDirectoryDescriptor,
                payloadPointer,
                destinationParentDescriptor,
                destinationPointer,
                0)
        }
    }
    guard linked == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "destination appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic document creation failed")
    }
    guard payloadName.withCString({ unlinkat(payloadDirectoryDescriptor, $0, 0) }) == 0 else {
        throw DocumentToolError(.commitUncertain, "document was linked but staging cleanup failed")
    }
    #endif
}

private func installDirectoryExclusively(
    parentDescriptor: Int32,
    stageName: String,
    destinationName: String
) throws {
    #if canImport(Darwin)
    let result = stageName.withCString { stagePointer in
        destinationName.withCString { destinationPointer in
            renameatx_np(
                parentDescriptor,
                stagePointer,
                parentDescriptor,
                destinationPointer,
                UInt32(RENAME_EXCL))
        }
    }
    guard result == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "output directory appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic output-directory creation failed")
    }
    #else
    let result = stageName.withCString { stagePointer in
        destinationName.withCString { destinationPointer in
            renameat(parentDescriptor, stagePointer, parentDescriptor, destinationPointer)
        }
    }
    guard result == 0 else {
        if errno == EEXIST || errno == ENOTEMPTY {
            throw DocumentToolError(.outputConflict, "output directory appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic output-directory creation failed")
    }
    #endif
}

private func exchangeDirectories(
    parentDescriptor: Int32,
    stageName: String,
    destinationName: String
) throws {
    #if canImport(Darwin)
    let result = stageName.withCString { stagePointer in
        destinationName.withCString { destinationPointer in
            renameatx_np(
                parentDescriptor,
                stagePointer,
                parentDescriptor,
                destinationPointer,
                UInt32(RENAME_SWAP))
        }
    }
    guard result == 0 else {
        throw DocumentToolError(.backendFailed, "atomic output-directory replacement failed")
    }
    #else
    throw DocumentToolError(
        .unsupportedFeature,
        "atomic replacement of a non-empty output directory is unavailable on this platform")
    #endif
}

private func synchronizeRegularFile(at directoryDescriptor: Int32, name: String) throws {
    let descriptor: Int32 = name.withCString {
        openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "staged document could not be reopened")
    }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          fsync(descriptor) == 0 else {
        throw DocumentToolError(.validationFailed, "staged document could not be synchronized")
    }
}

private func synchronizeRegularFileIfPresent(
    at directoryDescriptor: Int32,
    name: String
) -> Bool {
    (try? synchronizeRegularFile(at: directoryDescriptor, name: name)) != nil
}

private func synchronizeDirectoryTree(_ descriptor: Int32) throws {
    let enumerationDescriptor = openat(
        descriptor,
        ".",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard enumerationDescriptor >= 0,
          let directory = fdopendir(enumerationDescriptor) else {
        if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
        throw DocumentToolError(.validationFailed, "output bundle could not be synchronized")
    }
    defer { _ = closedir(directory) }

    while let entry = readdir(directory) {
        let name = directoryEntryName(entry)
        if name == "." || name == ".." { continue }
        var status = stat()
        let inspected = name.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0 else {
            throw DocumentToolError(.validationFailed, "output bundle changed while it was synchronized")
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            try synchronizeRegularFile(at: descriptor, name: name)
        case S_IFDIR:
            let child = try openDirectory(at: descriptor, name: name)
            defer { _ = close(child) }
            try synchronizeDirectoryTree(child)
        default:
            throw DocumentToolError(.validationFailed, "output bundle contains an unsafe entry")
        }
    }
    guard fsync(descriptor) == 0 else {
        throw DocumentToolError(.validationFailed, "output bundle directory could not be synchronized")
    }
}

private func removeDirectoryTree(
    parentDescriptor: Int32,
    name: String,
    expectedIdentity: DirectoryIdentity
) throws {
    let descriptor = try openDirectory(at: parentDescriptor, name: name)
    defer { _ = close(descriptor) }
    guard safeDirectoryIdentity(descriptor) == expectedIdentity else {
        throw DocumentToolError(.validationFailed, "staging directory identity changed before cleanup")
    }
    try removeDirectoryContents(descriptor)
    guard name.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
        throw DocumentToolError(.backendFailed, "staging directory could not be removed")
    }
}

private func removeDirectoryContents(_ descriptor: Int32) throws {
    let enumerationDescriptor = openat(
        descriptor,
        ".",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard enumerationDescriptor >= 0,
          let directory = fdopendir(enumerationDescriptor) else {
        if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
        throw DocumentToolError(.backendFailed, "staging directory could not be enumerated for cleanup")
    }
    defer { _ = closedir(directory) }

    while let entry = readdir(directory) {
        let name = directoryEntryName(entry)
        if name == "." || name == ".." { continue }
        var status = stat()
        let inspected = name.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0 else {
            throw DocumentToolError(.backendFailed, "staging entry changed during cleanup")
        }
        if (status.st_mode & S_IFMT) == S_IFDIR {
            let child = try openDirectory(at: descriptor, name: name)
            defer { _ = close(child) }
            try removeDirectoryContents(child)
            guard name.withCString({ unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                throw DocumentToolError(.backendFailed, "staging subdirectory could not be removed")
            }
        } else {
            guard name.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                throw DocumentToolError(.backendFailed, "staging entry could not be removed")
            }
        }
    }
}

private func resolveDocumentInputPath(_ path: String, within root: URL) throws -> URL {
    let lexical: URL
    if path.hasPrefix("~") {
        lexical = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    } else if path.hasPrefix("/") {
        lexical = URL(fileURLWithPath: path).standardizedFileURL
    } else {
        lexical = root.appendingPathComponent(path).standardizedFileURL
    }
    let resolved = try PathConfinement.resolve(path, within: root)
    guard lexical.path == resolved.path else {
        throw DocumentToolError(.validationFailed, "document inputs cannot traverse symbolic links")
    }
    return resolved
}

private func validateDigest(_ value: String?, field: String) throws {
    guard let value else { return }
    guard value.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
        throw DocumentToolError(.validationFailed, "\(field) must be a SHA-256 hex digest")
    }
}

private func normalizedExtension(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard trimmed.isEmpty == false,
          trimmed.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil else {
        return ""
    }
    return ".\(trimmed.lowercased())"
}

private func framed(_ data: Data) -> Data {
    var length = UInt64(data.count).bigEndian
    var result = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
    result.append(data)
    return result
}

private func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
