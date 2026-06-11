import Foundation
import IntatisCore

// MARK: - Shell

/// Runs a command via `/bin/sh -c` in a working directory. Used by the
/// Developer-ID build; in the sandboxed App Store build `run_shell` is denied by
/// the permission gate before reaching here (ARCHITECTURE.md §9.1).
public struct ProcessShellRunner: ShellRunner {
    public init() {}

    public func run(_ command: String, cwd: URL) async throws -> ShellResult {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Read to EOF before waiting to avoid pipe-buffer deadlock on moderate output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self),
                           exitCode: Int(process.terminationStatus))
        #else
        throw IntatisError.io("shell execution is unavailable on this platform")
        #endif
    }
}

public struct RunShellTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "run_shell",
        description: "Run a shell command in the workspace directory.",
        sideEffect: .exec,
        parameters: Schema.object(["command": Schema.string], required: ["command"])
    )
    struct Args: Decodable { let command: String }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let result = try await context.shell.run(a.command, cwd: context.workspaceRoot)
        var out = result.stdout
        if !result.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + "[stderr]\n" + result.stderr }
        out += "\n[exit \(result.exitCode)]"
        return ToolObservation(text: out)
    }
}

// MARK: - Git

public enum GitStatus {
    public struct Entry: Equatable, Sendable {
        public let x: Character   // index status
        public let y: Character   // worktree status
        public let path: String
        public init(x: Character, y: Character, path: String) {
            self.x = x; self.y = y; self.path = path
        }
    }

    /// Parse `git status --porcelain=v1` output (`XY <path>` per line).
    public static func parse(_ porcelain: String) -> [Entry] {
        porcelain.split(separator: "\n", omittingEmptySubsequences: true).compactMap { sub in
            let line = String(sub)
            guard line.count >= 4 else { return nil }
            let chars = Array(line)
            return Entry(x: chars[0], y: chars[1], path: String(line.dropFirst(3)))
        }
    }
}

/// Spawns `git` through a `ShellRunner`. The sandbox build replaces this with a
/// libgit2-backed `GitService` (same protocol).
public struct ProcessGitService: GitService {
    private let runner: ShellRunner
    public init(runner: ShellRunner = ProcessShellRunner()) { self.runner = runner }

    public func status(workspace: URL) async throws -> String {
        try await runner.run("git status --porcelain=v1", cwd: workspace).stdout
    }
    public func diff(workspace: URL) async throws -> String {
        try await runner.run("git diff", cwd: workspace).stdout
    }
}

public struct GitStatusTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_status",
        description: "Show working-tree status (porcelain).",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let porcelain = try await context.git.status(workspace: context.workspaceRoot)
        let entries = GitStatus.parse(porcelain)
        if entries.isEmpty { return ToolObservation(text: "clean") }
        let lines = entries.map { "\($0.x)\($0.y) \($0.path)" }
        return ToolObservation(text: lines.joined(separator: "\n"))
    }
}

public struct GitDiffTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_diff",
        description: "Show unstaged changes as a unified diff.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let diff = try await context.git.diff(workspace: context.workspaceRoot)
        let limit = 200_000
        let truncated = diff.utf8.count > limit
        let text = truncated ? String(diff.prefix(limit)) : diff
        return ToolObservation(text: text.isEmpty ? "(no changes)" : text, truncated: truncated, diff: diff)
    }
}
