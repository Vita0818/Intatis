import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Host-owned cache for deterministic validation receipts. Receipts never
/// live inside the bundle and never replace a snapshot identity check; callers
/// may use a matching, unexpired receipt only after re-opening the exact root.
public struct KnowledgeValidationReceiptStore: Sendable {
    public let root: URL

    private var registryLockURL: URL {
        root.appendingPathComponent(".receipt-registry.lock", isDirectory: false)
    }

    public init(root: URL) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            guard chmod(root.path, 0o700) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Validation receipt directory permissions could not be secured.")
            }
            #endif
        }
        self.root = try DurableOwnerOnlyFile.validateOwnedDirectory(at: root)
    }

    public func makeReceipt(
        for snapshot: KnowledgeValidatedSnapshot,
        storeID: String,
        validatedAt: String,
        expiresAt: String? = nil
    ) throws -> KnowledgeValidationReceipt {
        guard snapshot.report.semanticVerdict,
              snapshot.profile.bundle.id == storeID,
              ISO8601DateFormatter().date(from: validatedAt) != nil,
              expiresAt.map({ ISO8601DateFormatter().date(from: $0) != nil }) ?? true else {
            throw KnowledgeDomainError(.integrityFailed, "A validation receipt can only represent an exact valid snapshot and bounded date-time.")
        }
        let diagnosticsDigest = try KnowledgeDigest.canonical(
            snapshot.report.diagnostics)
        return KnowledgeValidationReceipt(
            schema: KnowledgeContract.validationSchema,
            storeID: storeID,
            snapshotID: snapshot.profile.retrievalSnapshot.id,
            snapshotRevision: snapshot.profile.retrievalSnapshot.revision,
            bundleRevision: snapshot.profile.bundle.revision,
            profileVersion: snapshot.profile.profileVersion,
            validator: .init(
                identity: KnowledgeContract.validatorIdentity,
                version: KnowledgeContract.validatorVersion),
            backendRegistryDigest: try KnowledgeBackendRegistry().digest,
            rootIdentity: .init(
                deviceID: snapshot.rootIdentity.deviceID,
                fileID: snapshot.rootIdentity.fileID,
                canonicalPathDigest: KnowledgeDigest.sha256(
                    snapshot.rootIdentity.canonicalPath)),
            semanticVerdict: "valid",
            diagnosticsDigest: diagnosticsDigest,
            validatedAt: validatedAt,
            expiresAt: expiresAt)
    }

    public func write(_ receipt: KnowledgeValidationReceipt) throws {
        try validateShape(receipt)
        let data = try KnowledgeJSON.encode(receipt, pretty: true)
        do {
            try DurableOwnerOnlyFile.withExclusiveLock(at: registryLockURL) {
                try DurableOwnerOnlyFile.writeAtomically(
                    data,
                    to: root.appendingPathComponent(fileName(for: receipt)),
                    temporaryPrefix: ".knowledge-receipt-")
            }
        } catch let error as DurableOwnerOnlyFileError {
            throw KnowledgeDomainError(
                error == .commitUncertain ? .revisionChanged : .unsafeStorage,
                retryable: error == .commitUncertain,
                "Validation receipt could not be committed safely.")
        }
    }

    public func read(
        storeID: String,
        snapshotID: String,
        snapshotRevision: String,
        snapshotRoot: URL,
        backendRegistry: KnowledgeBackendRegistry,
        at evaluationDate: String
    ) throws -> KnowledgeValidationReceipt? {
        guard let identity = WorkspaceRootIdentity.capture(rootPath: snapshotRoot.path),
              let date = ISO8601DateFormatter().date(from: evaluationDate) else {
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt root or evaluation date is invalid.")
        }
        let key = KnowledgeValidationReceipt(
            schema: KnowledgeContract.validationSchema,
            storeID: storeID,
            snapshotID: snapshotID,
            snapshotRevision: snapshotRevision,
            bundleRevision: snapshotRevision,
            profileVersion: KnowledgeContract.profileVersion,
            validator: .init(identity: KnowledgeContract.validatorIdentity, version: KnowledgeContract.validatorVersion),
            backendRegistryDigest: backendRegistry.digest,
            rootIdentity: .init(deviceID: 0, fileID: 0, canonicalPathDigest: KnowledgeDigest.sha256("placeholder")),
            semanticVerdict: "valid",
            diagnosticsDigest: KnowledgeDigest.sha256(Data()),
            validatedAt: evaluationDate,
            expiresAt: nil)
        let url = root.appendingPathComponent(fileName(for: key))
        return try DurableOwnerOnlyFile.withExclusiveLock(at: registryLockURL) {
            guard let data = try DurableOwnerOnlyFile.read(from: url) else { return nil }
            guard data.count <= 64 * 1_024 else {
                throw KnowledgeDomainError(.unsafeStorage, "Validation receipt exceeds its byte limit.")
            }
            let receipt: KnowledgeValidationReceipt
            do {
                receipt = try KnowledgeJSON.decode(KnowledgeValidationReceipt.self, from: data)
            } catch {
                throw KnowledgeDomainError(.integrityFailed, "Validation receipt could not be decoded.")
            }
            try validateShape(receipt)
            guard receipt.storeID == storeID,
                  receipt.snapshotID == snapshotID,
                  receipt.snapshotRevision == snapshotRevision,
                  receipt.backendRegistryDigest == backendRegistry.digest,
                  receipt.rootIdentity.deviceID == identity.deviceID,
                  receipt.rootIdentity.fileID == identity.fileID,
                  receipt.rootIdentity.canonicalPathDigest
                    == KnowledgeDigest.sha256(identity.canonicalPath),
                  receipt.semanticVerdict == "valid" else {
                return nil
            }
            if let expires = receipt.expiresAt,
               let expiryDate = ISO8601DateFormatter().date(from: expires),
               date >= expiryDate {
                return nil
            }
            return receipt
        }
    }

    /// Removes host-side receipts for an exact store, optionally narrowed to
    /// explicit snapshot IDs. The registry-wide owner-only flock serializes
    /// invalidation with all reads and writes so urgent purge cannot race a
    /// receipt re-publication.
    @discardableResult
    public func invalidate(
        storeID: String,
        snapshotIDs: Set<String>? = nil
    ) throws -> Int {
        guard KnowledgeStoreIdentifier.isValidStoreID(storeID),
              snapshotIDs?.allSatisfy(KnowledgeStoreIdentifier.isValidSnapshotID) ?? true else {
            throw KnowledgeDomainError(.profileInvalid, "Validation receipt invalidation scope is invalid.")
        }
        return try DurableOwnerOnlyFile.withExclusiveLock(at: registryLockURL) {
            let children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [])
            var removed = 0
            var removedAnyLeaf = false
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if name == registryLockURL.lastPathComponent { continue }
                if name.hasPrefix(".knowledge-receipt-"), name.hasSuffix(".tmp") {
                    // A crash-left temporary was never a committed receipt.
                    // It contains receipt metadata only, but urgent cleanup
                    // removes it under the same registry writer lock.
                    try removeOwnerOnlyLeaf(child)
                    removedAnyLeaf = true
                    continue
                }
                guard name.range(
                    of: #"^[0-9a-f]{64}\.json$"#,
                    options: .regularExpression) != nil else {
                    throw KnowledgeDomainError(.unsafeStorage, "Validation receipt registry contains an unexpected entry.")
                }
                guard let data = try DurableOwnerOnlyFile.read(from: child) else { continue }
                guard data.count <= 64 * 1_024 else {
                    throw KnowledgeDomainError(.unsafeStorage, "Validation receipt exceeds its byte limit.")
                }
                let receipt: KnowledgeValidationReceipt
                do {
                    receipt = try KnowledgeJSON.decode(
                        KnowledgeValidationReceipt.self,
                        from: data)
                    try validateShape(receipt)
                } catch {
                    // A malformed receipt can never authorize a mount, but its
                    // provenance cannot be guessed. Fail closed for manual
                    // inspection instead of deleting an unrelated file.
                    throw KnowledgeDomainError(.integrityFailed, "Validation receipt registry contains an invalid receipt.")
                }
                guard receipt.storeID == storeID,
                      snapshotIDs?.contains(receipt.snapshotID) ?? true else {
                    continue
                }
                try removeOwnerOnlyLeaf(child)
                removed += 1
                removedAnyLeaf = true
            }
            if removedAnyLeaf {
                try synchronizeRoot()
            }
            return removed
        }
    }

    private func validateShape(_ receipt: KnowledgeValidationReceipt) throws {
        guard receipt.schema == KnowledgeContract.validationSchema,
              receipt.storeID.range(of: #"^kb_[A-Za-z0-9._-]{1,125}$"#, options: .regularExpression) != nil,
              receipt.snapshotID.range(of: #"^snap_[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              KnowledgeDigest.isValid(receipt.snapshotRevision),
              KnowledgeDigest.isValid(receipt.bundleRevision),
              receipt.profileVersion == KnowledgeContract.profileVersion,
              receipt.validator.identity == KnowledgeContract.validatorIdentity,
              receipt.validator.version == KnowledgeContract.validatorVersion,
              KnowledgeDigest.isValid(receipt.backendRegistryDigest),
              KnowledgeDigest.isValid(receipt.rootIdentity.canonicalPathDigest),
              receipt.semanticVerdict == "valid",
              KnowledgeDigest.isValid(receipt.diagnosticsDigest),
              ISO8601DateFormatter().date(from: receipt.validatedAt) != nil,
              receipt.expiresAt.map({ ISO8601DateFormatter().date(from: $0) != nil }) ?? true else {
            throw KnowledgeDomainError(.integrityFailed, "Validation receipt shape is invalid.")
        }
    }

    private func fileName(for receipt: KnowledgeValidationReceipt) -> String {
        let key = [
            receipt.storeID,
            receipt.snapshotID,
            receipt.snapshotRevision,
            KnowledgeContract.validatorVersion,
        ].joined(separator: "\n")
        return KnowledgeDigest.sha256(key)
            .replacingOccurrences(of: "sha256:", with: "") + ".json"
    }

    private func removeOwnerOnlyLeaf(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt leaf could not be opened safely.")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var installed = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(url.path, &installed) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              (opened.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO))
                == (S_IRUSR | S_IWUSR),
              opened.st_dev == installed.st_dev,
              opened.st_ino == installed.st_ino,
              unlink(url.path) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt leaf could not be removed safely.")
        }
    }

    private func synchronizeRoot() throws {
        let descriptor = open(root.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt registry could not be synchronized.")
        }
        let result = fsync(descriptor)
        _ = close(descriptor)
        guard result == 0 else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Validation receipt invalidation durability is uncertain.")
        }
    }
}
