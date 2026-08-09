import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisKnowledge requires CryptoKit or swift-crypto")
#endif
import IntatisCore
import IntatisProtocol

public enum KnowledgeContract {
    public static let okfVersion = "0.2"
    public static let okfSpecCommit = "3fcbb9f828c2f23d109c855ee403c3a4c81f3a96"
    public static let profileSchema = "intatis-okf-rag-profile/0.1"
    public static let profileIdentity = "org.vita.intatis.okf-rag"
    public static let profileVersion = "0.1"
    public static let storeSchema = "intatis-rag-store/1"
    public static let chunkSchema = "intatis-chunk/1"
    public static let checksumsSchema = "intatis-rag-checksums/1"
    public static let validationSchema = "intatis-rag-validation/1"
    public static let evidenceContract = "intatis-evidence/1"
    public static let validatorIdentity = "org.vita.intatis.knowledge-validator"
    public static let validatorVersion = "1"
    public static let textNormalizationVersion = "intatis-text-normalization/1"
    public static let deterministicChunkerIdentity = "org.vita.intatis.heading-paragraph-window"
    public static let deterministicChunkerVersion = "1"
    public static let exactKNNBackendIdentity = "org.vita.intatis.exact-knn"
    public static let exactKNNFormatVersion = "float32-json/1"
    public static let exactKNNRuntimeVersion = "1"
    public static let lexicalBackendIdentity = "org.vita.intatis.bm25"
    public static let lexicalFormatVersion = "json/1"
    public static let lexicalRuntimeVersion = "1"
}

public enum KnowledgeJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    public static func value<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encode(value))
    }
}

public enum KnowledgeDigest {
    public static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    public static func canonical<T: Encodable>(_ value: T) throws -> String {
        sha256(try KnowledgeJSON.encode(value))
    }

    public static func isValid(_ value: String) -> Bool {
        value.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}

public enum KnowledgeErrorCode: String, Codable, CaseIterable, Sendable {
    case toolInputInvalid = "TOOL_INPUT_INVALID"
    case unknown = "KB_UNKNOWN"
    case accessDenied = "KB_ACCESS_DENIED"
    case unsafeStorage = "KB_UNSAFE_STORAGE"
    case okfInvalid = "KB_OKF_INVALID"
    case profileInvalid = "KB_PROFILE_INVALID"
    case versionUnsupported = "KB_VERSION_UNSUPPORTED"
    case integrityFailed = "KB_INTEGRITY_FAILED"
    case indexBackendUnsupported = "KB_INDEX_BACKEND_UNSUPPORTED"
    case indexNotReady = "KB_INDEX_NOT_READY"
    case embeddingUnavailable = "KB_EMBEDDING_UNAVAILABLE"
    case embeddingIncompatible = "KB_EMBEDDING_INCOMPATIBLE"
    case revisionChanged = "KB_REVISION_CHANGED"
    case rerankUnavailable = "RERANK_UNAVAILABLE"
    case searchBudgetExceeded = "SEARCH_BUDGET_EXCEEDED"
    case searchTimeout = "SEARCH_TIMEOUT"
    case searchCancelled = "SEARCH_CANCELLED"
    case internalError = "INTERNAL_ERROR"
}

public struct KnowledgeFailure: Codable, Equatable, Sendable {
    public let code: KnowledgeErrorCode
    public let retryable: Bool
    public let message: String

    public init(code: KnowledgeErrorCode, retryable: Bool, message: String) {
        self.code = code
        self.retryable = retryable
        self.message = String(
            PermissionReviewTextSanitizer
                .sanitizeDiagnostic(message, maxCharacters: 1_024)
                .text
                .prefix(1_024))
    }
}

public struct KnowledgeDomainError: Error, LocalizedError, Equatable, Sendable {
    public let failure: KnowledgeFailure
    public let diagnostics: [KnowledgeDiagnostic]

    public init(_ code: KnowledgeErrorCode,
                retryable: Bool = false,
                _ message: String,
                diagnostics: [KnowledgeDiagnostic] = []) {
        failure = KnowledgeFailure(code: code, retryable: retryable, message: message)
        self.diagnostics = diagnostics
    }

    public var errorDescription: String? { failure.message }
}

public struct KnowledgeStorePointer: Codable, Equatable, Sendable {
    public let schema: String
    public let storeID: String
    public let revision: Int
    public let currentSnapshot: String
    public let currentSnapshotRevision: String

    public init(storeID: String,
                revision: Int,
                currentSnapshot: String,
                currentSnapshotRevision: String) {
        schema = KnowledgeContract.storeSchema
        self.storeID = storeID
        self.revision = revision
        self.currentSnapshot = currentSnapshot
        self.currentSnapshotRevision = currentSnapshotRevision
    }
}

public struct KnowledgeBackendIdentity: Codable, Equatable, Hashable, Sendable {
    public let identity: String
    public let formatVersion: String
    public let runtimeVersion: String

    public init(identity: String, formatVersion: String, runtimeVersion: String) {
        self.identity = identity
        self.formatVersion = formatVersion
        self.runtimeVersion = runtimeVersion
    }
}

public struct KnowledgeEmbeddingModelIdentity: Codable, Equatable, Hashable, Sendable {
    public enum RuntimeBindingKind: String, Codable, Sendable {
        case local
        case remote
    }

    public let identity: String
    public let revision: String
    public let tokenizerRevision: String
    public let runtimeBindingKind: RuntimeBindingKind
    public let runtimeBindingDigest: String
    public let dimensions: Int
    public let scalarType: String
    public let quantization: String
    public let pooling: String
    public let normalization: String
    public let similarity: String
    public let documentInstruction: String
    public let queryInstruction: String
    public let maxInputTokens: Int
    public let truncation: String

    public init(identity: String,
                revision: String,
                tokenizerRevision: String,
                runtimeBindingKind: RuntimeBindingKind,
                runtimeBindingDigest: String,
                dimensions: Int,
                scalarType: String = "float32",
                quantization: String = "none",
                pooling: String,
                normalization: String = "l2",
                similarity: String = "cosine",
                documentInstruction: String = "",
                queryInstruction: String = "",
                maxInputTokens: Int,
                truncation: String = "end") {
        self.identity = identity
        self.revision = revision
        self.tokenizerRevision = tokenizerRevision
        self.runtimeBindingKind = runtimeBindingKind
        self.runtimeBindingDigest = runtimeBindingDigest
        self.dimensions = dimensions
        self.scalarType = scalarType
        self.quantization = quantization
        self.pooling = pooling
        self.normalization = normalization
        self.similarity = similarity
        self.documentInstruction = documentInstruction
        self.queryInstruction = queryInstruction
        self.maxInputTokens = maxInputTokens
        self.truncation = truncation
    }
}

public struct KnowledgeEmbeddingIndexProfile: Codable, Equatable, Sendable {
    public let id: String
    public let componentRevision: String
    public let indexPath: String
    public let backend: KnowledgeBackendIdentity
    public let model: KnowledgeEmbeddingModelIdentity
    public let chunkManifestDigest: String
    public let vectorCount: Int
    public let indexDigest: String
}

public struct KnowledgeLexicalIndexProfile: Codable, Equatable, Sendable {
    public let id: String
    public let componentRevision: String
    public let indexPath: String
    public let backend: KnowledgeBackendIdentity
    public let tokenizer: String
    public let languagePolicy: String
    public let chunkManifestDigest: String
    public let documentCount: Int
    public let indexDigest: String
}

public struct KnowledgeRerankerModelIdentity: Codable, Equatable, Hashable, Sendable {
    public let identity: String
    public let revision: String
    public let tokenizerRevision: String
    public let runtimeBindingKind: KnowledgeEmbeddingModelIdentity.RuntimeBindingKind
    public let runtimeBindingDigest: String
    public let templateDigest: String
    public let maxInputTokens: Int
    public let truncation: String
    public let scoreSemantics: String
}

public struct KnowledgeRerankerProfile: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case required
        case optional
        case disabled
    }

    public let mode: Mode
    public let model: KnowledgeRerankerModelIdentity?
}

public struct KnowledgeComponentReference: Codable, Equatable, Sendable {
    public let id: String
    public let componentRevision: String
}

public struct KnowledgeProfile: Codable, Equatable, Sendable {
    public struct OKF: Codable, Equatable, Sendable {
        public let version: String
        public let specCommit: String
    }

    public struct Bundle: Codable, Equatable, Sendable {
        public let id: String
        public let revision: String
        public let createdAt: String
    }

    public struct Normalization: Codable, Equatable, Sendable {
        public let textEncoding: String
        public let lineEndings: String
        public let unicode: String
        public let version: String
    }

    public struct Chunking: Codable, Equatable, Sendable {
        public let manifest: String
        public let algorithm: String
        public let version: String
        public let parametersDigest: String
        public let manifestDigest: String
    }

    public struct Retrieval: Codable, Equatable, Sendable {
        public let dense: String
        public let lexical: String
        public let fusion: String
        public let reranker: KnowledgeRerankerProfile
        public let evidenceContract: String
    }

    public struct RetrievalSnapshot: Codable, Equatable, Sendable {
        public let id: String
        public let revision: String
        public let bundleRevision: String
        public let chunkManifestDigest: String
        public let dense: KnowledgeComponentReference
        public let lexical: KnowledgeComponentReference?
        public let retrievalPolicyDigest: String
        public let rerankerBindingDigest: String
    }

    public struct Integrity: Codable, Equatable, Sendable {
        public let algorithm: String
        public let inventory: String
    }

    public let schema: String
    public let profile: String
    public let profileVersion: String
    public let okf: OKF
    public let bundle: Bundle
    public let normalization: Normalization
    public let chunking: Chunking
    public let embeddingIndexes: [KnowledgeEmbeddingIndexProfile]
    public let lexicalIndexes: [KnowledgeLexicalIndexProfile]
    public let retrieval: Retrieval
    public let retrievalSnapshot: RetrievalSnapshot
    public let integrity: Integrity
}

public struct KnowledgeConceptLocator: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        kind = "utf8-byte-range"
        self.start = start
        self.end = end
    }
}

public struct KnowledgeSourceLocator: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let sourceID: String
    public let sourceRevision: String
    public let adapterIdentity: String
    public let adapterVersion: String
    public let kind: String
    public let value: String
}

public struct KnowledgeProducer: Codable, Equatable, Hashable, Sendable {
    public let identity: String
    public let version: String
    public let at: String
}

public struct KnowledgeSupportingConcept: Codable, Equatable, Hashable, Sendable {
    public let conceptID: String
    public let conceptRevision: String
    public let conceptLocator: KnowledgeConceptLocator
}

public enum KnowledgeEvidenceClass: String, Codable, Sendable {
    case exactConceptSlice = "exact_concept_slice"
    case generatedDerivative = "generated_derivative"
}

public struct KnowledgeChunk: Codable, Equatable, Sendable {
    public let schema: String
    public let chunkID: String
    public let conceptID: String?
    public let conceptRevision: String?
    public let evidenceClass: KnowledgeEvidenceClass
    public let text: String
    public let textSha256: String
    public let conceptLocator: KnowledgeConceptLocator?
    public let sourceIDs: [String]
    public let sourceLocators: [KnowledgeSourceLocator]?
    public let producer: KnowledgeProducer
    public let supportingConcepts: [KnowledgeSupportingConcept]?

    public init(chunkID: String,
                conceptID: String?,
                conceptRevision: String?,
                evidenceClass: KnowledgeEvidenceClass,
                text: String,
                textSha256: String,
                conceptLocator: KnowledgeConceptLocator?,
                sourceIDs: [String],
                sourceLocators: [KnowledgeSourceLocator]? = nil,
                producer: KnowledgeProducer,
                supportingConcepts: [KnowledgeSupportingConcept]? = nil) {
        schema = KnowledgeContract.chunkSchema
        self.chunkID = chunkID
        self.conceptID = conceptID
        self.conceptRevision = conceptRevision
        self.evidenceClass = evidenceClass
        self.text = text
        self.textSha256 = textSha256
        self.conceptLocator = conceptLocator
        self.sourceIDs = sourceIDs
        self.sourceLocators = sourceLocators
        self.producer = producer
        self.supportingConcepts = supportingConcepts
    }
}

public struct KnowledgeChecksumEntry: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int
    public let sha256: String
    public let role: String
}

public struct KnowledgeChecksums: Codable, Equatable, Sendable {
    public let schema: String
    public let algorithm: String
    public let files: [KnowledgeChecksumEntry]

    public init(files: [KnowledgeChecksumEntry]) {
        schema = KnowledgeContract.checksumsSchema
        algorithm = "sha256"
        self.files = files
    }
}

public struct KnowledgeDenseVectorRecord: Codable, Equatable, Sendable {
    public let chunkID: String
    public let values: [Float]
}

public struct KnowledgeLexicalDocumentRecord: Codable, Equatable, Sendable {
    public let chunkID: String
    public let length: Int
    public let terms: [String: Int]
}

public struct KnowledgeDenseIndexFile: Codable, Equatable, Sendable {
    public let schema: String
    public let dimensions: Int
    public let vectors: [KnowledgeDenseVectorRecord]

    public init(dimensions: Int, vectors: [KnowledgeDenseVectorRecord]) {
        schema = "intatis-dense-exact-knn/1"
        self.dimensions = dimensions
        self.vectors = vectors
    }
}

public struct KnowledgeLexicalIndexFile: Codable, Equatable, Sendable {
    public let schema: String
    public let tokenizer: String
    public let documents: [KnowledgeLexicalDocumentRecord]

    public init(tokenizer: String, documents: [KnowledgeLexicalDocumentRecord]) {
        schema = "intatis-lexical-bm25/1"
        self.tokenizer = tokenizer
        self.documents = documents
    }
}

public struct SearchKnowledgeInput: Codable, Equatable, Sendable {
    public let knowledgeBase: String
    public let query: String
    public let limit: Int?

    public init(knowledgeBase: String, query: String, limit: Int? = nil) {
        self.knowledgeBase = knowledgeBase
        self.query = query
        self.limit = limit
    }
}

public struct KnowledgeSearchEvidence: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let rank: Int
    public let text: String
    public let textSha256: String
    public let evidenceURI: String
    public let conceptID: String?
    public let conceptRevision: String?
    public let evidenceClass: KnowledgeEvidenceClass
    public let conceptLocator: KnowledgeConceptLocator?
    public let supportingConcepts: [KnowledgeSupportingConcept]?
    public let producer: KnowledgeProducer?
    public let sourceIDs: [String]
    public let sourceLocators: [KnowledgeSourceLocator]?
    public let trust: String?
    public let status: String
    public let stale: Bool
}

public struct KnowledgeSearchResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case insufficientEvidence = "insufficient_evidence"
        case error
    }

    public let status: Status
    public let knowledgeBase: String?
    public let knowledgeBaseRevision: String?
    public let retrievalSnapshot: String?
    public let retrievalSnapshotRevision: String?
    public let rerankApplied: Bool?
    public let truncated: Bool?
    public let evidence: [KnowledgeSearchEvidence]?
    public let error: KnowledgeFailure?

    public static func success(knowledgeBase: String,
                               knowledgeBaseRevision: String,
                               retrievalSnapshot: String,
                               retrievalSnapshotRevision: String,
                               rerankApplied: Bool,
                               truncated: Bool,
                               evidence: [KnowledgeSearchEvidence]) -> KnowledgeSearchResponse {
        KnowledgeSearchResponse(
            status: evidence.isEmpty ? .insufficientEvidence : .ok,
            knowledgeBase: knowledgeBase,
            knowledgeBaseRevision: knowledgeBaseRevision,
            retrievalSnapshot: retrievalSnapshot,
            retrievalSnapshotRevision: retrievalSnapshotRevision,
            rerankApplied: rerankApplied,
            truncated: evidence.isEmpty ? false : truncated,
            evidence: evidence,
            error: nil)
    }

    public static func failure(_ failure: KnowledgeFailure,
                               knowledgeBase: String? = nil,
                               knowledgeBaseRevision: String? = nil,
                               retrievalSnapshot: String? = nil,
                               retrievalSnapshotRevision: String? = nil) -> KnowledgeSearchResponse {
        KnowledgeSearchResponse(
            status: .error,
            knowledgeBase: knowledgeBase,
            knowledgeBaseRevision: knowledgeBaseRevision,
            retrievalSnapshot: retrievalSnapshot,
            retrievalSnapshotRevision: retrievalSnapshotRevision,
            rerankApplied: nil,
            truncated: nil,
            evidence: nil,
            error: failure)
    }
}

public enum KnowledgeDiagnosticSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct KnowledgeDiagnostic: Codable, Equatable, Sendable {
    public let severity: KnowledgeDiagnosticSeverity
    public let code: String
    public let subject: String
    public let message: String

    public init(severity: KnowledgeDiagnosticSeverity,
                code: String,
                subject: String,
                message: String) {
        self.severity = severity
        self.code = code
        self.subject = String(
            PermissionReviewTextSanitizer
                .sanitizeDiagnostic(subject, maxCharacters: 256)
                .text
                .prefix(256))
        self.message = String(
            PermissionReviewTextSanitizer
                .sanitizeDiagnostic(message, maxCharacters: 1_024)
                .text
                .prefix(1_024))
    }
}

public struct KnowledgeValidationReport: Equatable, Sendable {
    public let semanticVerdict: Bool
    public let profile: KnowledgeProfile?
    public let chunks: [KnowledgeChunk]
    public let diagnostics: [KnowledgeDiagnostic]

    public init(profile: KnowledgeProfile?,
                chunks: [KnowledgeChunk],
                diagnostics: [KnowledgeDiagnostic]) {
        self.profile = profile
        self.chunks = chunks
        self.diagnostics = diagnostics.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue < $1.severity.rawValue
            }
            if $0.code != $1.code { return $0.code < $1.code }
            if $0.subject != $1.subject { return $0.subject < $1.subject }
            return $0.message < $1.message
        }
        semanticVerdict = !diagnostics.contains { $0.severity == .error }
    }
}

public struct KnowledgeValidationReceipt: Codable, Equatable, Sendable {
    public struct Validator: Codable, Equatable, Sendable {
        public let identity: String
        public let version: String
    }

    public struct RootIdentity: Codable, Equatable, Sendable {
        public let deviceID: UInt64
        public let fileID: UInt64
        public let canonicalPathDigest: String
    }

    public let schema: String
    public let storeID: String
    public let snapshotID: String
    public let snapshotRevision: String
    public let bundleRevision: String
    public let profileVersion: String
    public let validator: Validator
    public let backendRegistryDigest: String
    public let rootIdentity: RootIdentity
    public let semanticVerdict: String
    public let diagnosticsDigest: String
    public let validatedAt: String
    public let expiresAt: String?
}

public struct KnowledgeResultBudget: Equatable, Sendable {
    public var maximumEvidenceCount = 20
    public var maximumEvidenceCharacters = 4_096
    public var maximumEvidenceBytes = 16 * 1_024
    public var maximumAggregateEvidenceBytes = 32 * 1_024
    public var maximumSerializedBytes = 64 * 1_024
    public var maximumEstimatedTokens = 12_000
    public var maximumCandidates = 2_000

    public init() {}
}
