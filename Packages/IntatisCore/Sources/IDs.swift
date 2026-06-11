import Foundation

/// A strongly-typed identifier backed by a `String`.
///
/// Conforming types encode/decode as a bare JSON string (not an object), so the
/// wire format stays compact and human-readable in the event log.
public protocol TypedID: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: String { get }
    init(rawValue: String)
}

public extension TypedID {
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Generates short, prefixed, URL-safe identifiers (e.g. `sess_a1b2c3d4`).
public enum IDGen {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func random(prefix: String, length: Int = 8) -> String {
        let suffix = String((0..<length).map { _ in alphabet.randomElement()! })
        return "\(prefix)_\(suffix)"
    }
}

public struct SessionID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> SessionID { SessionID(rawValue: IDGen.random(prefix: "sess")) }
}

public struct ThreadID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ThreadID { ThreadID(rawValue: IDGen.random(prefix: "thr")) }
}

public struct MessageID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> MessageID { MessageID(rawValue: IDGen.random(prefix: "msg")) }
}

public struct AgentID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ArtifactID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ArtifactID { ArtifactID(rawValue: IDGen.random(prefix: "art")) }
}

public struct ModelID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Correlates a request (e.g. a permission ask) with its later response.
public struct RequestID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> RequestID { RequestID(rawValue: IDGen.random(prefix: "req")) }
}
