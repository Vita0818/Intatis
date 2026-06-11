import XCTest
import IntatisCore
@testable import IntatisTools

private struct FakeShell: ShellRunner {
    let result: ShellResult
    func run(_ command: String, cwd: URL) async throws -> ShellResult { result }
}

private struct FakeGit: GitService {
    let statusText: String
    let diffText: String
    func status(workspace: URL) async throws -> String { statusText }
    func diff(workspace: URL) async throws -> String { diffText }
}

final class IntatisToolsTests: XCTestCase {

    private func tempWorkspace() throws -> URL {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return ws
    }

    // MARK: Path confinement

    func testPathConfinement() throws {
        let root = URL(fileURLWithPath: "/ws")
        XCTAssertNoThrow(try PathConfinement.resolve("src/a.swift", within: root))
        XCTAssertEqual(try PathConfinement.resolve("a/../b.txt", within: root).path, "/ws/b.txt")
        XCTAssertThrowsError(try PathConfinement.resolve("../etc/passwd", within: root))
        XCTAssertThrowsError(try PathConfinement.resolve("/etc/passwd", within: root))
        XCTAssertThrowsError(try PathConfinement.resolve("../ws2/x", within: root))
        XCTAssertFalse(PathConfinement.isWithin("../x", root: root))
    }

    // MARK: Unified diff

    func testUnifiedDiffParseAndApply() throws {
        let diff = [
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@ -1,3 +1,3 @@",
            " line1",
            "-line2",
            "+CHANGED",
            " line3",
        ].joined(separator: "\n")

        let patches = UnifiedDiff.parse(diff)
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].path, "file.txt")

        let updated = try UnifiedDiff.apply(content: "line1\nline2\nline3", hunks: patches[0].hunks)
        XCTAssertEqual(updated, "line1\nCHANGED\nline3")
    }

    func testUnifiedDiffRejectsNonMatchingHunk() {
        let hunk = UnifiedDiff.Hunk(oldLines: ["nope"], newLines: ["x"])
        XCTAssertThrowsError(try UnifiedDiff.apply(content: "a\nb", hunks: [hunk]))
    }

    // MARK: Git status parse

    func testGitStatusParse() {
        let porcelain = " M src/a.swift\n?? new.txt\nA  added.kt\n"
        let entries = GitStatus.parse(porcelain)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].x, Character(" "))
        XCTAssertEqual(entries[0].y, Character("M"))
        XCTAssertEqual(entries[0].path, "src/a.swift")
        XCTAssertEqual(entries[1].path, "new.txt")
        XCTAssertEqual(entries[2].path, "added.kt")
    }

    // MARK: File tools

    func testFileToolsReadWriteListSearch() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        _ = try await WriteFileTool().execute(ToolArgs(raw: #"{"path":"src/a.txt","content":"hello world"}"#), in: ctx)
        let read = try await ReadFileTool().execute(ToolArgs(raw: #"{"path":"src/a.txt"}"#), in: ctx)
        XCTAssertEqual(read.text, "hello world")

        let list = try await ListFilesTool().execute(ToolArgs(raw: #"{"path":"src"}"#), in: ctx)
        XCTAssertTrue(list.text.contains("a.txt"))

        let search = try await SearchTextTool().execute(ToolArgs(raw: #"{"query":"hello","path":"."}"#), in: ctx)
        XCTAssertTrue(search.text.contains("a.txt"))

        do {
            _ = try await ReadFileTool().execute(ToolArgs(raw: #"{"path":"../escape"}"#), in: ctx)
            XCTFail("path confinement should have rejected the read")
        } catch {
            // expected
        }
    }

    func testApplyPatchToolEditsFile() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        _ = try await WriteFileTool().execute(ToolArgs(raw: #"{"path":"f.txt","content":"a\nb\nc"}"#), in: ctx)

        let diff = ["--- a/f.txt", "+++ b/f.txt", "@@ -1,3 +1,3 @@", " a", "-b", "+B", " c"].joined(separator: "\n")
        let argsData = try JSONSerialization.data(withJSONObject: ["diff": diff])
        let obs = try await ApplyPatchTool().execute(ToolArgs(raw: String(decoding: argsData, as: UTF8.self)), in: ctx)
        XCTAssertEqual(obs.changedFiles, ["f.txt"])

        let read = try await ReadFileTool().execute(ToolArgs(raw: #"{"path":"f.txt"}"#), in: ctx)
        XCTAssertEqual(read.text, "a\nB\nc")
    }

    // MARK: Shell + git tools (injected fakes)

    func testRunShellUsesInjectedRunner() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "hi", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))
        let obs = try await RunShellTool().execute(ToolArgs(raw: #"{"command":"echo hi"}"#), in: ctx)
        XCTAssertTrue(obs.text.contains("hi"))
        XCTAssertTrue(obs.text.contains("[exit 0]"))
    }

    func testGitToolsUseInjectedService() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: " M a.swift\n?? b\n", diffText: "diffbody"))
        let status = try await GitStatusTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertTrue(status.text.contains("a.swift"))
        let diff = try await GitDiffTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertEqual(diff.text, "diffbody")
    }

    // MARK: Registry

    func testStandardRegistry() {
        let reg = ToolRegistry.standard()
        XCTAssertEqual(reg.descriptors().count, 8)
        XCTAssertNotNil(reg.tool(named: "read_file"))
        XCTAssertNotNil(reg.tool(named: "apply_patch"))
        XCTAssertNil(reg.tool(named: "nonexistent"))
        XCTAssertEqual(ReadFileTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(WriteFileTool.descriptor.sideEffect, .write)
        XCTAssertEqual(RunShellTool.descriptor.sideEffect, .exec)
    }
}
