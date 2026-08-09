import Foundation
import IntatisCore
import IntatisProtocol
import Yams

public struct OKFSource: Equatable, Sendable {
    public let id: String?
    public let resource: String
    public let title: String?
    public let author: String?
    public let usageCount: Int?
    public let lastModified: String?
}

public struct OKFVerification: Equatable, Sendable {
    public let by: String
    public let at: String
}

public struct OKFConcept: Equatable, Sendable {
    public let conceptID: String
    public let relativePath: String
    public let normalizedText: String
    public let body: String
    public let bodyUTF8Start: Int
    public let revision: String
    public let type: String
    public let title: String?
    public let description: String?
    public let sources: [OKFSource]
    public let verifications: [OKFVerification]
    public let status: String
    public let staleAfter: String?
    public let generatedAt: String?
    public let legacyTimestamp: String?
    public let frontmatter: [String: JSONValue]

    public var trustTier: String {
        if verifications.contains(where: { $0.by.hasPrefix("human:") }) {
            return "human-reviewed"
        }
        return verifications.isEmpty ? "unverified" : "machine-confirmed"
    }
}

public struct OKFReaderLimits: Equatable, Sendable {
    public var maximumConceptBytes = 4 * 1_024 * 1_024
    public var maximumFrontmatterBytes = 256 * 1_024
    public var maximumNodes = 20_000
    public var maximumDepth = 64
    public var maximumScalarCharacters = 64 * 1_024

    public init() {}
}

public struct OKFReader: Sendable {
    public let limits: OKFReaderLimits

    public init(limits: OKFReaderLimits = OKFReaderLimits()) {
        self.limits = limits
    }

    public func readConcept(data: Data,
                            relativePath: String) throws -> OKFConcept {
        guard data.count <= limits.maximumConceptBytes else {
            throw KnowledgeDomainError(.okfInvalid, "OKF concept exceeds the bounded file size.")
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw KnowledgeDomainError(.okfInvalid, "OKF concept is not valid UTF-8.")
        }
        let normalized = Self.normalize(raw)
        let split = try splitFrontmatter(normalized)
        guard Data(split.yaml.utf8).count <= limits.maximumFrontmatterBytes else {
            throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter exceeds the bounded size.")
        }

        let root: Node
        do {
            guard let parsed = try compose(yaml: split.yaml) else {
                throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter is empty.")
            }
            root = parsed
        } catch let domain as KnowledgeDomainError {
            throw domain
        } catch {
            throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter is not valid YAML.")
        }
        try validateNodeTree(root)

        guard case .mapping(let mapping) = root else {
            throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter must be a mapping.")
        }
        let object = try objectValue(mapping)
        guard case .string(let type)? = object["type"],
              !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeDomainError(.okfInvalid, "OKF concept requires a non-empty type.")
        }

        let declaredSources = try parseSources(object["sources"])
        let sources = declaredSources.isEmpty
            ? parseLegacyCitations(split.body)
            : declaredSources
        let sourceIDs = sources.compactMap(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw KnowledgeDomainError(.okfInvalid, "OKF concept contains duplicate source IDs.")
        }
        let verifications = try parseVerifications(object["verified"])
        let conceptID = try Self.conceptID(relativePath)
        return OKFConcept(
            conceptID: conceptID,
            relativePath: relativePath,
            normalizedText: normalized,
            body: split.body,
            bodyUTF8Start: split.bodyUTF8Start,
            revision: KnowledgeDigest.sha256(normalized),
            type: type,
            title: object["title"]?.stringValue,
            description: object["description"]?.stringValue,
            sources: sources,
            verifications: verifications,
            status: object["status"]?.stringValue ?? "stable",
            staleAfter: object["stale_after"]?.stringValue,
            generatedAt: object["generated"]?.objectValue?["at"]?.stringValue,
            legacyTimestamp: object["timestamp"]?.stringValue,
            frontmatter: object)
    }

    public func readRootIndexVersion(data: Data) throws -> String? {
        guard data.count <= limits.maximumConceptBytes,
              let raw = String(data: data, encoding: .utf8) else {
            throw KnowledgeDomainError(.okfInvalid, "OKF root index is not valid bounded UTF-8.")
        }
        let normalized = Self.normalize(raw)
        guard normalized.hasPrefix("---\n") else { return nil }
        let split = try splitFrontmatter(normalized)
        guard let node = try compose(yaml: split.yaml) else { return nil }
        try validateNodeTree(node)
        guard case .mapping(let mapping) = node else {
            throw KnowledgeDomainError(.okfInvalid, "OKF root index frontmatter must be a mapping.")
        }
        return try objectValue(mapping)["okf_version"]?.stringValue
    }

    public static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private func splitFrontmatter(_ text: String) throws -> (
        yaml: String,
        body: String,
        bodyUTF8Start: Int
    ) {
        guard text.hasPrefix("---\n") else {
            throw KnowledgeDomainError(.okfInvalid, "OKF concept must start with YAML frontmatter.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let closing = lines.indices.dropFirst().first(where: {
            lines[$0] == "---"
        }) else {
            throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter closing delimiter is missing.")
        }
        let yaml = lines[1..<closing].joined(separator: "\n")
        let prefix = lines[0...closing].joined(separator: "\n") + "\n"
        let body = lines.index(after: closing) < lines.endIndex
            ? lines[lines.index(after: closing)...].joined(separator: "\n")
            : ""
        return (yaml, body, Data(prefix.utf8).count)
    }

    private func validateNodeTree(_ root: Node) throws {
        let allowedTags: Set<String> = [
            "", "!", "tag:yaml.org,2002:str", "tag:yaml.org,2002:seq",
            "tag:yaml.org,2002:map", "tag:yaml.org,2002:bool",
            "tag:yaml.org,2002:float", "tag:yaml.org,2002:null",
            "tag:yaml.org,2002:int", "tag:yaml.org,2002:timestamp",
        ]
        var stack: [(Node, Int)] = [(root, 0)]
        var count = 0
        while let (node, depth) = stack.popLast() {
            count += 1
            guard count <= limits.maximumNodes, depth <= limits.maximumDepth else {
                throw KnowledgeDomainError(.unsafeStorage, "YAML structure exceeds the bounded node or depth limit.")
            }
            guard node.anchor == nil else {
                throw KnowledgeDomainError(.unsafeStorage, "YAML anchors and aliases are not accepted by the host safety profile.")
            }
            guard allowedTags.contains(node.tag.rawValue) else {
                throw KnowledgeDomainError(.unsafeStorage, "YAML custom tags are not accepted by the host safety profile.")
            }
            switch node {
            case .alias:
                throw KnowledgeDomainError(.unsafeStorage, "YAML anchors and aliases are not accepted by the host safety profile.")
            case .scalar(let scalar):
                guard scalar.string.count <= limits.maximumScalarCharacters else {
                    throw KnowledgeDomainError(.unsafeStorage, "YAML scalar exceeds the bounded length.")
                }
            case .sequence(let sequence):
                for child in sequence.reversed() {
                    stack.append((child, depth + 1))
                }
            case .mapping(let mapping):
                for pair in mapping.reversed() {
                    stack.append((pair.value, depth + 1))
                    stack.append((pair.key, depth + 1))
                }
            }
        }
    }

    private func objectValue(_ mapping: Node.Mapping) throws -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        for pair in mapping {
            guard let key = pair.key.string, !key.isEmpty else {
                throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter keys must be non-empty strings.")
            }
            guard object[key] == nil else {
                throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter contains a duplicate key.")
            }
            object[key] = try jsonValue(pair.value)
        }
        return object
    }

    private func jsonValue(_ node: Node) throws -> JSONValue {
        switch node {
        case .alias:
            throw KnowledgeDomainError(.unsafeStorage, "YAML aliases are not accepted.")
        case .sequence(let sequence):
            return .array(try sequence.map(jsonValue))
        case .mapping(let mapping):
            return .object(try objectValue(mapping))
        case .scalar(let scalar):
            switch node.tag.rawValue {
            case "tag:yaml.org,2002:null":
                return .null
            case "tag:yaml.org,2002:bool":
                return .bool(node.bool ?? false)
            case "tag:yaml.org,2002:int":
                if let integer = node.int { return .number(Double(integer)) }
                return .string(scalar.string)
            case "tag:yaml.org,2002:float":
                if let number = node.float, number.isFinite { return .number(number) }
                throw KnowledgeDomainError(.okfInvalid, "OKF frontmatter contains a non-finite number.")
            default:
                return .string(scalar.string)
            }
        }
    }

    private func parseSources(_ value: JSONValue?) throws -> [OKFSource] {
        guard let value else { return [] }
        guard case .array(let entries) = value else {
            throw KnowledgeDomainError(.okfInvalid, "OKF sources must be a list.")
        }
        return try entries.map { entry in
            guard case .object(let object) = entry,
                  let resource = object["resource"]?.stringValue,
                  !resource.isEmpty else {
                throw KnowledgeDomainError(.okfInvalid, "Every OKF source requires a resource.")
            }
            return OKFSource(
                id: object["id"]?.stringValue,
                resource: resource,
                title: object["title"]?.stringValue,
                author: object["author"]?.stringValue,
                usageCount: object["usage_count"]?.integerValue,
                lastModified: object["last_modified"]?.stringValue)
        }
    }

    /// OKF v0.2 permits consumers to read the v0.1 `# Citations` body list.
    /// Stable synthetic IDs are an Intatis adapter detail so those legacy
    /// sources can participate in the same grounded chunk contract without
    /// trusting a model-authored identity.
    private func parseLegacyCitations(_ body: String) -> [OKFSource] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var inCitations = false
        var resources: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let heading = line.dropFirst(2)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if inCitations, heading.caseInsensitiveCompare("Citations") != .orderedSame {
                    break
                }
                inCitations = heading.caseInsensitiveCompare("Citations") == .orderedSame
                continue
            }
            guard inCitations,
                  (line.hasPrefix("- ") || line.hasPrefix("* ")) else { continue }
            let resource = String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !resource.isEmpty, !resources.contains(resource) {
                resources.append(resource)
            }
        }
        return resources.map { resource in
            let digest = KnowledgeDigest.sha256(resource)
                .replacingOccurrences(of: "sha256:", with: "")
            return OKFSource(
                id: "legacy-\(digest.prefix(24))",
                resource: resource,
                title: nil,
                author: nil,
                usageCount: nil,
                lastModified: nil)
        }
    }

    private func parseVerifications(_ value: JSONValue?) throws -> [OKFVerification] {
        guard let value else { return [] }
        let entries: [JSONValue]
        switch value {
        case .object:
            entries = [value]
        case .array(let array):
            entries = array
        default:
            throw KnowledgeDomainError(.okfInvalid, "OKF verified must be a mapping or list.")
        }
        return try entries.map { entry in
            guard case .object(let object) = entry,
                  let by = object["by"]?.stringValue,
                  let at = object["at"]?.stringValue,
                  !by.isEmpty, !at.isEmpty else {
                throw KnowledgeDomainError(.okfInvalid, "Every OKF verification requires by and at.")
            }
            return OKFVerification(by: by, at: at)
        }
    }

    private static func conceptID(_ relativePath: String) throws -> String {
        guard relativePath.hasSuffix(".md"),
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw KnowledgeDomainError(.okfInvalid, "OKF concept path is invalid.")
        }
        return String(relativePath.dropLast(3))
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
