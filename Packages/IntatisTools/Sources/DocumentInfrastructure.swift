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
        let url = try PathConfinement.resolve(path, within: root)
        guard url.pathExtension.lowercased() == expectedFormat.rawValue else {
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
}

struct DocumentStagedFileRequest: Sendable {
    let sourcePath: String?
    let expectedSourceSHA256: String?
    let destinationPath: String
    let replaceExisting: Bool
    let expectedDestinationSHA256: String?
    let fileExtension: String
    let maximumBytes: UInt64
}

struct DocumentStagedDirectoryRequest: Sendable {
    let sourcePath: String?
    let expectedSourceSHA256: String?
    let destinationPath: String
    let replaceExisting: Bool
    let expectedDestinationSHA256: String?
    let maximumFiles: Int
    let maximumBytes: UInt64
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
        let baseline = try preflight(
            source: locations.source,
            expectedSourceSHA256: request.expectedSourceSHA256,
            destination: locations.destination,
            replaceExisting: request.replaceExisting,
            expectedDestinationSHA256: request.expectedDestinationSHA256)
        let stage = try createStageDirectory(parent: locations.destination.deletingLastPathComponent())
        defer { removeStageIfSafe(stage) }
        let suffix = normalizedExtension(request.fileExtension)
        let payload = stage.url.appendingPathComponent("payload\(suffix)", isDirectory: false)
        try await produce(payload)
        try validate(payload)
        let staged = try snapshotRegularFile(payload, maximumBytes: request.maximumBytes)
        try Task.checkCancellation()

        return try commitFile(
            payload: payload,
            staged: staged,
            source: locations.source,
            destination: locations.destination,
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
        let baseline = try preflight(
            source: locations.source,
            expectedSourceSHA256: request.expectedSourceSHA256,
            destination: locations.destination,
            replaceExisting: request.replaceExisting,
            expectedDestinationSHA256: request.expectedDestinationSHA256)
        let stage = try createStageDirectory(parent: locations.destination.deletingLastPathComponent())
        defer { removeStageIfSafe(stage) }
        try await produce(stage.url)
        try validate(stage.url)
        let staged = try snapshotDirectory(
            stage.url,
            maximumFiles: request.maximumFiles,
            maximumBytes: request.maximumBytes)
        try Task.checkCancellation()

        let receipt = try commitDirectory(
            stage: stage.url,
            staged: staged,
            source: locations.source,
            destination: locations.destination,
            baseline: baseline,
            replaceExisting: request.replaceExisting,
            workspace: workspace)
        return receipt
    }
}

private struct DocumentPreflightBaseline {
    let source: DocumentFileSnapshot?
    let destinationFile: DocumentFileSnapshot?
    let destinationDirectory: DocumentDirectorySnapshot?
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
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          safeDirectoryIdentity(parent) != nil else {
        throw DocumentToolError(.validationFailed, "destination parent must be an existing safe directory")
    }
    return DocumentLocations(source: source, destination: destination)
}

private func preflight(
    source: URL?,
    expectedSourceSHA256: String?,
    destination: URL,
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

    let destinationState = try destinationSnapshot(destination)
    switch destinationState {
    case .missing:
        guard replaceExisting == false, expectedDestinationSHA256 == nil else {
            throw DocumentToolError(
                .outputConflict,
                "replacement was requested but the destination does not exist")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            destinationFile: nil,
            destinationDirectory: nil,
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
            destinationFile: snapshot,
            destinationDirectory: nil,
            destinationKind: .file)
    case .directory(let snapshot):
        guard replaceExisting,
              let expectedDestinationSHA256,
              snapshot.sha256 == expectedDestinationSHA256.lowercased() else {
            throw DocumentToolError(
                .outputConflict,
                "existing destination directory requires replace_existing and its exact digest")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            destinationFile: nil,
            destinationDirectory: snapshot,
            destinationKind: .directory)
    }
}

private enum DestinationSnapshot {
    case missing
    case file(DocumentFileSnapshot)
    case directory(DocumentDirectorySnapshot)
}

private func destinationSnapshot(_ url: URL) throws -> DestinationSnapshot {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        if errno == ENOENT { return .missing }
        throw DocumentToolError(.validationFailed, "destination metadata could not be inspected")
    }
    switch status.st_mode & S_IFMT {
    case S_IFREG:
        return .file(try snapshotRegularFile(url, maximumBytes: UInt64.max))
    case S_IFDIR:
        return .directory(try snapshotDirectory(
            url,
            maximumFiles: 100_000,
            maximumBytes: UInt64.max))
    default:
        throw DocumentToolError(.validationFailed, "destination must be a regular file or directory")
    }
}

private struct DocumentStage {
    let url: URL
    let identity: DirectoryIdentity
}

private func createStageDirectory(parent: URL) throws -> DocumentStage {
    guard safeDirectoryIdentity(parent) != nil else {
        throw DocumentToolError(.validationFailed, "destination parent identity changed")
    }
    for _ in 0..<8 {
        let candidate = parent.appendingPathComponent(
            ".intatis-document-stage-\(UUID().uuidString)",
            isDirectory: true)
        if mkdir(candidate.path, S_IRWXU) == 0 {
            guard let identity = safeDirectoryIdentity(candidate),
                  identity.permissions == UInt16(S_IRWXU) else {
                _ = rmdir(candidate.path)
                throw DocumentToolError(.validationFailed, "staging directory is unsafe")
            }
            return DocumentStage(url: candidate, identity: identity)
        }
        if errno != EEXIST { break }
    }
    throw DocumentToolError(.backendFailed, "could not create same-directory staging")
}

private func removeStageIfSafe(_ stage: DocumentStage) {
    guard stage.url.lastPathComponent.hasPrefix(".intatis-document-stage-"),
          safeDirectoryIdentity(stage.url) == stage.identity else { return }
    try? FileManager.default.removeItem(at: stage.url)
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

private func snapshotDirectory(
    _ root: URL,
    maximumFiles: Int,
    maximumBytes: UInt64
) throws -> DocumentDirectorySnapshot {
    guard safeDirectoryIdentity(root) != nil else {
        throw DocumentToolError(.validationFailed, "document output bundle is not a safe directory")
    }
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in false }) else {
        throw DocumentToolError(.validationFailed, "document output bundle could not be enumerated")
    }
    var files: [(String, URL, DocumentFileSnapshot)] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw DocumentToolError(.validationFailed, "document output bundle contains a symlink")
        }
        if values.isDirectory == true {
            guard safeDirectoryIdentity(url) != nil else {
                throw DocumentToolError(.validationFailed, "document output bundle contains an unsafe directory")
            }
            continue
        }
        guard values.isRegularFile == true else {
            throw DocumentToolError(.validationFailed, "document output bundle contains a non-regular entry")
        }
        let relative = PathConfinement.relativePath(of: url, root: root)
        let snapshot = try snapshotRegularFile(url, maximumBytes: maximumBytes)
        files.append((relative, url, snapshot))
        guard files.count <= maximumFiles else {
            throw DocumentToolError(.validationFailed, "document output bundle exceeds the file-count limit")
        }
    }
    files.sort { $0.0 < $1.0 }
    var total: UInt64 = 0
    var hasher = SHA256()
    for (relative, _, snapshot) in files {
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

private func commitFile(
    payload: URL,
    staged: DocumentFileSnapshot,
    source: URL?,
    destination: URL,
    baseline: DocumentPreflightBaseline,
    replaceExisting: Bool,
    workspace: URL
) throws -> DocumentCommitReceipt {
    guard baseline.destinationKind != .directory else {
        throw DocumentToolError(.outputConflict, "a file output cannot replace a directory")
    }
    let lock = documentLockURL(destination: destination)
    return try DurableOwnerOnlyFile.withExclusiveLock(at: lock) {
        try recheckPreconditions(source: source, destination: destination, baseline: baseline)
        let stageNow = try snapshotRegularFile(payload, maximumBytes: staged.byteCount)
        guard stageNow == staged else {
            throw DocumentToolError(.validationFailed, "staged output changed before commit")
        }
        try synchronizeRegularFile(payload)

        var commitStarted = false
        do {
            if replaceExisting {
                guard rename(payload.path, destination.path) == 0 else {
                    throw DocumentToolError(.backendFailed, "atomic document replacement failed")
                }
            } else {
                try installFileExclusively(payload: payload, destination: destination)
            }
            commitStarted = true
            guard synchronizeRegularFileIfPresent(destination),
                  synchronizeDirectory(destination.deletingLastPathComponent()) else {
                throw DocumentToolError(.commitUncertain, "installed document could not be synchronized")
            }
            let installed = try snapshotRegularFile(destination, maximumBytes: staged.byteCount)
            guard installed.sha256 == staged.sha256,
                  installed.byteCount == staged.byteCount else {
                throw DocumentToolError(.commitUncertain, "installed document does not match staged bytes")
            }
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
    stage: URL,
    staged: DocumentDirectorySnapshot,
    source: URL?,
    destination: URL,
    baseline: DocumentPreflightBaseline,
    replaceExisting: Bool,
    workspace: URL
) throws -> DocumentCommitReceipt {
    guard baseline.destinationKind != .file else {
        throw DocumentToolError(.outputConflict, "a directory output cannot replace a file")
    }
    let lock = documentLockURL(destination: destination)
    return try DurableOwnerOnlyFile.withExclusiveLock(at: lock) {
        try recheckPreconditions(source: source, destination: destination, baseline: baseline)
        let stageNow = try snapshotDirectory(
            stage,
            maximumFiles: max(staged.fileCount, 1),
            maximumBytes: staged.byteCount)
        guard stageNow == staged else {
            throw DocumentToolError(.validationFailed, "staged output bundle changed before commit")
        }
        try synchronizeDirectoryTree(stage)

        var commitStarted = false
        do {
            if replaceExisting {
                try exchangeDirectories(stage: stage, destination: destination)
            } else {
                try installDirectoryExclusively(stage: stage, destination: destination)
            }
            commitStarted = true
            guard synchronizeDirectory(destination.deletingLastPathComponent()) else {
                throw DocumentToolError(.commitUncertain, "installed output bundle could not be synchronized")
            }
            let installed = try snapshotDirectory(
                destination,
                maximumFiles: max(staged.fileCount, 1),
                maximumBytes: staged.byteCount)
            guard installed == staged else {
                throw DocumentToolError(.commitUncertain, "installed output bundle does not match staged files")
            }
            var cleanupWarning: String?
            if replaceExisting {
                do {
                    try FileManager.default.removeItem(at: stage)
                } catch {
                    cleanupWarning = "the replaced output was retained in an internal staging directory"
                }
            }
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
    destination: URL,
    baseline: DocumentPreflightBaseline
) throws {
    if let source, let expected = baseline.source {
        let current = try snapshotRegularFile(source, maximumBytes: expected.byteCount)
        guard current == expected else {
            throw DocumentToolError(.outputConflict, "source changed before commit")
        }
    }
    let current = try destinationSnapshot(destination)
    switch (baseline.destinationKind, current) {
    case (.missing, .missing):
        return
    case (.file, .file(let snapshot)) where snapshot == baseline.destinationFile:
        return
    case (.directory, .directory(let snapshot)) where snapshot == baseline.destinationDirectory:
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

private func installFileExclusively(payload: URL, destination: URL) throws {
    #if canImport(Darwin)
    guard renamex_np(payload.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "destination appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic document creation failed")
    }
    #else
    guard link(payload.path, destination.path) == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "destination appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic document creation failed")
    }
    guard unlink(payload.path) == 0 else {
        throw DocumentToolError(.commitUncertain, "document was linked but staging cleanup failed")
    }
    #endif
}

private func installDirectoryExclusively(stage: URL, destination: URL) throws {
    #if canImport(Darwin)
    guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "output directory appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic output-directory creation failed")
    }
    #else
    guard rename(stage.path, destination.path) == 0 else {
        if errno == EEXIST || errno == ENOTEMPTY {
            throw DocumentToolError(.outputConflict, "output directory appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic output-directory creation failed")
    }
    #endif
}

private func exchangeDirectories(stage: URL, destination: URL) throws {
    #if canImport(Darwin)
    guard renamex_np(stage.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
        throw DocumentToolError(.backendFailed, "atomic output-directory replacement failed")
    }
    #else
    throw DocumentToolError(
        .unsupportedFeature,
        "atomic replacement of a non-empty output directory is unavailable on this platform")
    #endif
}

private func synchronizeRegularFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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

private func synchronizeRegularFileIfPresent(_ url: URL) -> Bool {
    (try? synchronizeRegularFile(url)) != nil
}

private func synchronizeDirectory(_ url: URL) -> Bool {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { _ = close(descriptor) }
    return fsync(descriptor) == 0
}

private func synchronizeDirectoryTree(_ root: URL) throws {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
        throw DocumentToolError(.validationFailed, "output bundle could not be synchronized")
    }
    var directories = [root]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw DocumentToolError(.validationFailed, "output bundle contains a symlink")
        }
        if values.isDirectory == true {
            directories.append(url)
        } else if values.isRegularFile == true {
            try synchronizeRegularFile(url)
        } else {
            throw DocumentToolError(.validationFailed, "output bundle contains an unsafe entry")
        }
    }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
        guard synchronizeDirectory(directory) else {
            throw DocumentToolError(.validationFailed, "output bundle directory could not be synchronized")
        }
    }
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
