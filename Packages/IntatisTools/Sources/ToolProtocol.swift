import Foundation
import IntatisCore
import IntatisProtocol

/// Raw JSON arguments for a tool call, with a typed decode helper.
public struct ToolArgs: Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw IntatisError.decoding("tool args are not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IntatisError.decoding("tool args: \(error.localizedDescription)")
        }
    }
}

/// The result of executing a tool. `diff`/`changedFiles` are set by mutating tools.
public struct ToolObservation: Equatable, Sendable {
    public var text: String
    public var truncated: Bool
    public var diff: String?
    public var changedFiles: [String]?
    public init(text: String, truncated: Bool = false, diff: String? = nil, changedFiles: [String]? = nil) {
        self.text = text
        self.truncated = truncated
        self.diff = diff
        self.changedFiles = changedFiles
    }
}

/// Static metadata the permission gate reads. Tools are dumb executors; they do
/// not decide whether they may run (ARCHITECTURE.md §1.2 principle E).
public struct ToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let sideEffect: SideEffect
    public let parameters: JSONValue   // JSON-Schema object
    public init(name: String, description: String, sideEffect: SideEffect, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.sideEffect = sideEffect
        self.parameters = parameters
    }
}

// MARK: - Injected services (keep tools testable + backend-swappable)

public struct ShellResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int
    public init(stdout: String, stderr: String, exitCode: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol ShellRunner: Sendable {
    func run(_ command: String, cwd: URL) async throws -> ShellResult
}

/// Git backend. v0.2 dev uses `ProcessGitService` (spawns git); the App Store
/// sandbox build swaps in a libgit2-backed implementation (ARCHITECTURE.md §9.1).
public protocol GitService: Sendable {
    func status(workspace: URL) async throws -> String   // porcelain v1
    func diff(workspace: URL) async throws -> String      // unified diff
}

public struct ToolContext: Sendable {
    public let workspaceRoot: URL
    public let shell: ShellRunner
    public let git: GitService
    public init(workspaceRoot: URL,
                shell: ShellRunner = ProcessShellRunner(),
                git: GitService = ProcessGitService()) {
        self.workspaceRoot = workspaceRoot
        self.shell = shell
        self.git = git
    }
}

// MARK: - Tool

public protocol Tool: Sendable {
    static var descriptor: ToolDescriptor { get }
    func touchedPaths(_ args: ToolArgs) -> [String]
    func risksNetwork(_ args: ToolArgs) -> Bool
    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation
}

public extension Tool {
    func touchedPaths(_ args: ToolArgs) -> [String] { [] }
    func risksNetwork(_ args: ToolArgs) -> Bool { false }
}

public struct ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    public init(_ tools: [any Tool]) {
        self.tools = Dictionary(tools.map { (type(of: $0).descriptor.name, $0) },
                                uniquingKeysWith: { first, _ in first })
    }

    public func tool(named name: String) -> (any Tool)? { tools[name] }
    public func all() -> [any Tool] { Array(tools.values) }
    public func descriptors() -> [ToolDescriptor] { all().map { type(of: $0).descriptor } }

    /// The full v0.2 read/write/git/shell tool set.
    public static func standard() -> ToolRegistry {
        ToolRegistry([
            ReadFileTool(), ListFilesTool(), SearchTextTool(), WriteFileTool(),
            ApplyPatchTool(), RunShellTool(), GitStatusTool(), GitDiffTool(),
        ])
    }
}

// MARK: - Small JSON-Schema helpers

enum Schema {
    static let string = JSONValue.object(["type": .string("string")])
    static let integer = JSONValue.object(["type": .string("integer")])

    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }
}
