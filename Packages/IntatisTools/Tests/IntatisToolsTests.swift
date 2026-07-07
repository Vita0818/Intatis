import XCTest
import IntatisCore
@testable import IntatisTools

#if canImport(Darwin)
import Darwin
#endif

#if canImport(PDFKit) && canImport(AppKit)
import AppKit
import PDFKit
#endif

private struct FakeShell: ShellRunner {
    let result: ShellResult
    func run(_ command: String, cwd: URL) async throws -> ShellResult { result }
}

private actor ShellResultQueue {
    private var results: [ShellResult]

    init(_ results: [ShellResult]) {
        self.results = results
    }

    func next() throws -> ShellResult {
        guard results.isEmpty == false else {
            throw IntatisError.io("no fake shell results remain")
        }
        return results.removeFirst()
    }
}

private struct SequenceShell: ShellRunner {
    let queue: ShellResultQueue

    init(_ results: [ShellResult]) {
        self.queue = ShellResultQueue(results)
    }

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        try await queue.next()
    }
}

private actor CommandRecorder {
    private var commands: [String] = []

    func record(_ command: String) {
        commands.append(command)
    }

    func all() -> [String] {
        commands
    }
}

private struct RecordingShell: ShellRunner {
    let recorder: CommandRecorder
    let result: ShellResult

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        await recorder.record(command)
        return result
    }
}

private actor AsyncBarrier {
    private let expected: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func wait() async {
        arrivals += 1
        if arrivals >= expected {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct BarrierShell: ShellRunner {
    let barrier: AsyncBarrier
    let result: ShellResult

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        await barrier.wait()
        return result
    }
}

private actor ShellOverlapState {
    private var activeCount = 0
    private var callCount = 0
    private var didOverlap = false

    func enter() -> Int {
        activeCount += 1
        callCount += 1
        if activeCount > 1 {
            didOverlap = true
        }
        return callCount
    }

    func leave() {
        activeCount -= 1
    }

    func overlapped() -> Bool {
        didOverlap
    }
}

private struct OverlapDetectingShell: ShellRunner {
    let state: ShellOverlapState

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        let index = await state.enter()
        do {
            try await Task.sleep(nanoseconds: 100_000_000)
            let url = index == 1 ? "https://example.com/one" : "https://example.com/two"
            let title = index == 1 ? "One" : "Two"
            let stdout = """
            {"action":"navigate","profile":"shared","backend":"cdp","backendDetail":"edge","url":"\(url)","title":"\(title)","text":"\(title) marker","links":[]}
            """
            await state.leave()
            return ShellResult(stdout: stdout, stderr: "", exitCode: 0)
        } catch {
            await state.leave()
            throw error
        }
    }
}

private struct FakeGit: GitService {
    let statusText: String
    let diffText: String
    func status(workspace: URL) async throws -> String { statusText }
    func diff(workspace: URL) async throws -> String { diffText }
}

private struct FakeImageGenerator: ImageGenerationToolService {
    func generateImage(prompt: String,
                       size: String,
                       count: Int,
                       outputPath: String,
                       workspaceRoot: URL) async throws -> ToolObservation {
        let url = try PathConfinement.resolve(outputPath, within: workspaceRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake-image".utf8).write(to: url)
        return ToolObservation(text: "generated fake image: \(outputPath)", changedFiles: [outputPath])
    }
}

final class IntatisToolsTests: XCTestCase {

    private func tempWorkspace() throws -> URL {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return ws
    }

    private func browserPayload(from command: String) throws -> [String: Any] {
        let marker = "INTATIS_BROWSER_ARGS='"
        guard let markerRange = command.range(of: marker) else {
            throw IntatisError.decoding("missing browser args payload")
        }
        let payloadStart = markerRange.upperBound
        guard let payloadEnd = command[payloadStart...].firstIndex(of: "'") else {
            throw IntatisError.decoding("unterminated browser args payload")
        }
        let encoded = String(command[payloadStart..<payloadEnd])
        guard let data = Data(base64Encoded: encoded),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntatisError.decoding("browser args payload is not JSON")
        }
        return object
    }

    #if canImport(PDFKit) && canImport(AppKit)
    private func makeBlankPDF(pageCount: Int, at url: URL) throws {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 72, height: 72))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 72, height: 72)).fill()
            image.unlockFocus()
            guard let page = PDFPage(image: image) else {
                throw IntatisError.io("could not create test PDF page \(index)")
            }
            document.insert(page, at: index)
        }
        guard document.write(to: url) else {
            throw IntatisError.io("could not write test PDF")
        }
    }
    #endif

    #if canImport(Darwin)
    private func freeLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw IntatisError.io("could not create loopback socket")
        }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw IntatisError.io("could not bind loopback socket")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw IntatisError.io("could not inspect loopback socket")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func python3Executable() -> String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func startStaticHTTPServer(directory: URL, port: Int) throws -> Process {
        guard let python = python3Executable() else {
            throw IntatisError.io("python3 is required for the real browser persistence smoke")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-m", "http.server", "\(port)",
            "--bind", "127.0.0.1",
            "--directory", directory.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    private func waitForHTTPServer(port: Int, path: String = "/login.html") async throws {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntatisError.io("local browser smoke server did not start")
    }
    #endif

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

    func testWebFetchLocalHTTPAndTruncation() async throws {
        #if canImport(Darwin)
        guard python3Executable() != nil else {
            throw XCTSkip("python3 is required for the web_fetch local HTTP smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let site = ws.appendingPathComponent("fetch-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("fetch-marker body that should be truncated".utf8)
            .write(to: site.appendingPathComponent("fetch.txt"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/fetch.txt")

        let obs = try await WebFetchTool().execute(
            ToolArgs(raw: #"{"url":"http://127.0.0.1:\#(port)/fetch.txt","maxCharacters":12}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(obs.text.contains("status: 200"), obs.text)
        XCTAssertTrue(obs.text.contains("fetch-marker"), obs.text)
        XCTAssertFalse(obs.text.contains("body that should be truncated"), obs.text)
        XCTAssertTrue(obs.truncated)
        #else
        throw XCTSkip("web_fetch local HTTP smoke requires Darwin test helpers")
        #endif
    }

    func testWebFetchRejectsNonHTTPURL() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        do {
            _ = try await WebFetchTool().execute(
                ToolArgs(raw: #"{"url":"file:///etc/passwd"}"#),
                in: ToolContext(workspaceRoot: ws))
            XCTFail("web_fetch should reject non-HTTP URLs")
        } catch {
            XCTAssertTrue(String(describing: error).contains("http(s)"), "\(error)")
        }
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

    // MARK: Document/media tools

    func testPDFReadExtractAndSplitTools() async throws {
        #if canImport(PDFKit) && canImport(AppKit)
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let pdfURL = ws.appendingPathComponent("input.pdf")
        try makeBlankPDF(pageCount: 3, at: pdfURL)
        let ctx = ToolContext(workspaceRoot: ws)

        let read = try await ReadPDFTool().execute(ToolArgs(raw: #"{"path":"input.pdf","pages":"1-2"}"#), in: ctx)
        XCTAssertTrue(read.text.contains("Pages: 3"))
        XCTAssertTrue(read.text.contains("--- page 1 ---"))

        let extractArgs = #"{"mode":"extract","inputPath":"input.pdf","pages":"2-3","outputPath":"out/extract.pdf"}"#
        let extracted = try await EditPDFPagesTool().execute(ToolArgs(raw: extractArgs), in: ctx)
        XCTAssertEqual(extracted.changedFiles, ["out/extract.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out/extract.pdf").path))

        let splitArgs = #"{"mode":"split","inputPath":"input.pdf","pages":"1,3","outputDir":"split","outputPrefix":"doc"}"#
        let split = try await EditPDFPagesTool().execute(ToolArgs(raw: splitArgs), in: ctx)
        XCTAssertEqual(split.changedFiles?.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.appendingPathComponent("split/doc-page-001.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.appendingPathComponent("split/doc-page-003.pdf").path))
        #else
        throw XCTSkip("PDFKit/AppKit unavailable")
        #endif
    }

    func testCompileLatexUsesInjectedShellAndReportsPDF() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data(#"\documentclass{article}\begin{document}Hi\end{document}"#.utf8)
            .write(to: ws.appendingPathComponent("main.tex"))
        try Data("%PDF".utf8).write(to: ws.appendingPathComponent("build/main.pdf"))
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: "tectonic ok", stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await CompileLaTeXTool().execute(
            ToolArgs(raw: #"{"inputPath":"main.tex","outputDir":"build","engine":"tectonic"}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["build/main.pdf"])
        XCTAssertTrue(obs.text.contains("compiled main.tex"))
    }

    func testReconstructDocumentImageUsesInjectedShellAndReportsOutput() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("image".utf8).write(to: ws.appendingPathComponent("scan.png"))
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("# Scan".utf8).write(to: ws.appendingPathComponent("docs/scan.md"))
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: "docling ok", stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await ReconstructDocumentImageTool().execute(
            ToolArgs(raw: #"{"imagePath":"scan.png","outputPath":"docs/scan.md","format":"markdown","backend":"docling"}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["docs/scan.md"])
        XCTAssertTrue(obs.text.contains("reconstructed scan.png"))
    }

    func testGenerateImageUsesInjectedService() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws, imageGenerator: FakeImageGenerator())

        let obs = try await GenerateImageTool().execute(
            ToolArgs(raw: #"{"prompt":"clean document icon","outputPath":"art/icon.png","size":"512x512","count":1}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["art/icon.png"])
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("art/icon.png"), encoding: .utf8), "fake-image")
    }

    // MARK: Network/browser tools

    func testBrowserNavigateUsesPersistentProfileStateAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"navigate","profile":"work","url":"https://example.com/","title":"Example Domain","text":"Example page text","links":[{"text":"More information","href":"https://iana.org/domains/example"}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","channel":"chromium","headless":true}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("title: Example Domain"))
        XCTAssertTrue(obs.text.contains("Persistent browser profile: .intatis/browser/profiles/work"))
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        let stateData = try Data(contentsOf: stateURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/")
    }

    func testBrowserOutputReportsInteractiveElementsForForms() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = ##"{"action":"navigate","profile":"work","url":"https://example.com/form","title":"Task Form","text":"Ready to submit","links":[],"elements":[{"role":"textbox","name":"Email","selector":"#email","tag":"input","type":"email","placeholder":"name@example.com","disabled":false},{"role":"combobox","name":"Priority","selector":"#priority","tag":"select","options":["Low","High"]},{"role":"button","name":"Submit request","selector":"#submit","tag":"button"}]}"##
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/form","profile":"work","channel":"chromium","headless":true}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("interactive elements:"), obs.text)
        XCTAssertTrue(obs.text.contains(#"textbox "Email" selector=#email type=email"#), obs.text)
        XCTAssertTrue(obs.text.contains(#"combobox "Priority" selector=#priority options=[Low, High]"#), obs.text)
        XCTAssertTrue(obs.text.contains(#"button "Submit request" selector=#submit"#), obs.text)
    }

    func testBrowserNavigateFallsBackToCDPWhenPlaywrightMissing() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let fallbackStdout = #"{"action":"navigate","profile":"work","backend":"cdp","backendDetail":"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge","url":"https://example.com/","title":"Example Domain","text":"Example page text","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: SequenceShell([
                ShellResult(stdout: "", stderr: "playwright is not installed or not resolvable by Node.", exitCode: 127),
                ShellResult(stdout: fallbackStdout, stderr: "", exitCode: 0),
            ]),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","channel":"msedge","headless":true}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("backend: cdp"))
        XCTAssertTrue(obs.text.contains("Microsoft Edge"))
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let stateData = try Data(contentsOf: stateURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["title"] as? String, "Example Domain")
    }

    func testBrowserHandoffUsesHeadedPersistentProfileAndRecordsHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"handoff","profile":"login","backend":"playwright","backendDetail":"playwright","url":"https://example.com/account","title":"Account","text":"signed in marker","links":[]}"#
        let recorder = CommandRecorder()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(
                recorder: recorder,
                result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserHandoffTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/account","profile":"login","channel":"msedge","handoffSeconds":2,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: handoff"))
        XCTAssertTrue(obs.text.contains("signed in marker"))
        XCTAssertTrue(obs.text.contains("Persistent browser profile: .intatis/browser/profiles/login"))
        let commands = await recorder.all()
        let payload = try browserPayload(from: try XCTUnwrap(commands.first))
        XCTAssertEqual(payload["action"] as? String, "handoff")
        XCTAssertEqual(payload["headless"] as? Bool, false)
        XCTAssertEqual(payload["handoffTimeoutMillis"] as? Int, 2000)
        XCTAssertEqual(payload["profile"] as? String, "login")
        XCTAssertEqual(payload["channel"] as? String, "msedge")

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/login.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/account")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""action":"handoff""#))
        XCTAssertTrue(history.contains(#""profile":"login""#))
    }

    func testBrowserConcurrentProfilesKeepSeparateStateAndHistoryMetadata() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let barrier = AsyncBarrier(expected: 2)
        let stdoutA = #"{"action":"navigate","profile":"profile-a","backend":"cdp","backendDetail":"edge","url":"https://example.com/a","title":"Profile A","text":"profile a marker","links":[]}"#
        let stdoutB = #"{"action":"navigate","profile":"profile-b","backend":"cdp","backendDetail":"edge","url":"https://example.com/b","title":"Profile B","text":"profile b marker","links":[]}"#
        let ctxA = ToolContext(
            workspaceRoot: ws,
            shell: BarrierShell(barrier: barrier, result: ShellResult(stdout: stdoutA, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))
        let ctxB = ToolContext(
            workspaceRoot: ws,
            shell: BarrierShell(barrier: barrier, result: ShellResult(stdout: stdoutB, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        async let first = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/a","profile":"profile-a","channel":"msedge","headless":true}"#),
            in: ctxA)
        async let second = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/b","profile":"profile-b","channel":"msedge","headless":true}"#),
            in: ctxB)
        let (obsA, obsB) = try await (first, second)

        XCTAssertTrue(obsA.text.contains("profile a marker"), obsA.text)
        XCTAssertTrue(obsB.text.contains("profile b marker"), obsB.text)

        let stateAURL = ws.appendingPathComponent(".intatis/browser/state/profile-a.json")
        let stateBURL = ws.appendingPathComponent(".intatis/browser/state/profile-b.json")
        let stateAData = try Data(contentsOf: stateAURL)
        let stateBData = try Data(contentsOf: stateBURL)
        let stateA = try XCTUnwrap(JSONSerialization.jsonObject(with: stateAData) as? [String: Any])
        let stateB = try XCTUnwrap(JSONSerialization.jsonObject(with: stateBData) as? [String: Any])
        XCTAssertEqual(stateA["title"] as? String, "Profile A")
        XCTAssertEqual(stateB["title"] as? String, "Profile B")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""profile":"profile-a""#), historyText)
        XCTAssertTrue(historyText.contains(#""profile":"profile-b""#), historyText)
        let entries = try historyText.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        }
        XCTAssertTrue(entries.contains { $0["profile"] == "profile-a" && $0["url"] == "https://example.com/a" })
        XCTAssertTrue(entries.contains { $0["profile"] == "profile-b" && $0["url"] == "https://example.com/b" })
    }

    func testBrowserCommandsForSameProfileAreSerialized() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let state = ShellOverlapState()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: OverlapDetectingShell(state: state),
            git: FakeGit(statusText: "", diffText: ""))

        async let first = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/one","profile":"shared","channel":"msedge","headless":true}"#),
            in: ctx)
        async let second = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/two","profile":"shared","channel":"msedge","headless":true}"#),
            in: ctx)
        let (obsOne, obsTwo) = try await (first, second)

        let didOverlap = await state.overlapped()
        XCTAssertFalse(didOverlap)
        XCTAssertTrue(obsOne.text.contains("marker"), obsOne.text)
        XCTAssertTrue(obsTwo.text.contains("marker"), obsTwo.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertEqual(historyText.split(separator: "\n").count, 2)
        XCTAssertTrue(historyText.contains(#""profile":"shared""#), historyText)
    }

    func testRealBrowserBackendSmokeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser backend smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("backend: cdp") || obs.text.contains("backend: playwright"))
        XCTAssertTrue(obs.text.contains("Example Domain"))
        XCTAssertTrue(obs.text.contains("Persistent browser profile: .intatis/browser/profiles/smoke"))
    }

    func testRealBrowserSearchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser search smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        let obs = try await BrowserSearchTool().execute(
            ToolArgs(raw: #"{"query":"site:example.com example domain","engine":"duckduckgo","profile":"search-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":4000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: search"), obs.text)
        XCTAssertTrue(obs.text.contains("duckduckgo.com"), obs.text)
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"search-smoke""#), history)
        XCTAssertTrue(history.contains(#""action":"search""#), history)
        XCTAssertTrue(history.contains("duckduckgo.com"), history)
    }

    func testRealBrowserHandoffWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_HANDOFF_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_HANDOFF_SMOKE=1 to run the headed browser handoff smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("handoff-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let pageHTML = """
        <!doctype html>
        <title>Intatis Handoff</title>
        <body>handoff marker ready</body>
        """
        try Data(pageHTML.utf8).write(to: site.appendingPathComponent("handoff.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/handoff.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let obs = try await BrowserHandoffTool().execute(
            ToolArgs(raw: #"{"url":"http://127.0.0.1:\#(port)/handoff.html","profile":"handoff-smoke","channel":"msedge","handoffSeconds":1,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: handoff"), obs.text)
        XCTAssertTrue(obs.text.contains("handoff marker ready"), obs.text)
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"handoff""#), historyText)
        #else
        throw XCTSkip("headed browser handoff smoke requires Darwin")
        #endif
    }

    func testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser profile persistence smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let loginHTML = """
        <!doctype html>
        <title>Intatis Login Set</title>
        <body>pending</body>
        <script>
        document.cookie = "intatis_login=present; Max-Age=3600; path=/; SameSite=Lax";
        localStorage.setItem("intatisLocalLogin", "present");
        document.body.innerText = "login marker set";
        </script>
        """
        let stateHTML = """
        <!doctype html>
        <title>Intatis Login State</title>
        <body>pending</body>
        <script>
        document.body.innerText = "cookie=" + document.cookie + "\\nlocal=" + localStorage.getItem("intatisLocalLogin");
        </script>
        """
        try Data(loginHTML.utf8).write(to: site.appendingPathComponent("login.html"))
        try Data(stateHTML.utf8).write(to: site.appendingPathComponent("state.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port)

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/login.html","profile":"session-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/state.html","profile":"session-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("cookie=intatis_login=present"), obs.text)
        XCTAssertTrue(obs.text.contains("local=present"), obs.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains("/login.html"))
        XCTAssertTrue(historyText.contains("/state.html"))
        #else
        throw XCTSkip("real browser profile persistence smoke requires Darwin")
        #endif
    }

    func testRealBrowserBackForwardWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser back/forward smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("history-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let oneHTML = """
        <!doctype html>
        <title>Intatis History One</title>
        <body>history page one marker</body>
        """
        let twoHTML = """
        <!doctype html>
        <title>Intatis History Two</title>
        <body>history page two marker</body>
        """
        try Data(oneHTML.utf8).write(to: site.appendingPathComponent("one.html"))
        try Data(twoHTML.utf8).write(to: site.appendingPathComponent("two.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/one.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/one.html","profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/two.html","profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)

        let back = try await BrowserBackTool().execute(
            ToolArgs(raw: #"{"profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)
        XCTAssertTrue(back.text.contains("browser action: back"), back.text)
        XCTAssertTrue(back.text.contains("history page one marker"), back.text)

        let forward = try await BrowserForwardTool().execute(
            ToolArgs(raw: #"{"profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)
        XCTAssertTrue(forward.text.contains("browser action: forward"), forward.text)
        XCTAssertTrue(forward.text.contains("history page two marker"), forward.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"back""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"forward""#), historyText)
        #else
        throw XCTSkip("real browser back/forward smoke requires Darwin")
        #endif
    }

    func testRealBrowserProfilesRemainIsolatedWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser profile isolation smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("isolation-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let profileHTML = """
        <!doctype html>
        <title>Intatis Profile Isolation</title>
        <body>pending</body>
        <script>
        const params = new URLSearchParams(window.location.search);
        const marker = params.get("marker");
        if (marker) {
          document.cookie = "intatis_profile_marker=" + marker + "; Max-Age=3600; path=/; SameSite=Lax";
          localStorage.setItem("intatisProfileMarker", marker);
        }
        document.body.innerText = "cookie=" + document.cookie + "\\nlocal=" + localStorage.getItem("intatisProfileMarker");
        </script>
        """
        try Data(profileHTML.utf8).write(to: site.appendingPathComponent("profile.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/profile.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html?marker=profile-a-marker","profile":"isolation-a","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html?marker=profile-b-marker","profile":"isolation-b","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        let obsA = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html","profile":"isolation-a","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)
        let obsB = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html","profile":"isolation-b","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obsA.text.contains("intatis_profile_marker=profile-a-marker"), obsA.text)
        XCTAssertTrue(obsA.text.contains("local=profile-a-marker"), obsA.text)
        XCTAssertFalse(obsA.text.contains("profile-b-marker"), obsA.text)
        XCTAssertTrue(obsB.text.contains("intatis_profile_marker=profile-b-marker"), obsB.text)
        XCTAssertTrue(obsB.text.contains("local=profile-b-marker"), obsB.text)
        XCTAssertFalse(obsB.text.contains("profile-a-marker"), obsB.text)

        let historyA = try await BrowserHistoryTool().execute(
            ToolArgs(raw: #"{"profile":"isolation-a","limit":10}"#),
            in: ctx)
        let historyB = try await BrowserHistoryTool().execute(
            ToolArgs(raw: #"{"profile":"isolation-b","limit":10}"#),
            in: ctx)
        XCTAssertTrue(historyA.text.contains("[isolation-a]"), historyA.text)
        XCTAssertFalse(historyA.text.contains("[isolation-b]"), historyA.text)
        XCTAssertTrue(historyB.text.contains("[isolation-b]"), historyB.text)
        XCTAssertFalse(historyB.text.contains("[isolation-a]"), historyB.text)
        #else
        throw XCTSkip("real browser profile isolation smoke requires Darwin")
        #endif
    }

    func testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE=1 to run the real browser concurrent profile smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("concurrent-profile-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }

        let pageA = """
        <!doctype html>
        <title>Intatis Concurrent A</title>
        <body>
        <h1>Concurrent profile A</h1>
        <p>concurrent profile A marker</p>
        </body>
        """
        let pageB = """
        <!doctype html>
        <title>Intatis Concurrent B</title>
        <body>
        <h1>Concurrent profile B</h1>
        <p>concurrent profile B marker</p>
        </body>
        """
        try Data(pageA.utf8).write(to: site.appendingPathComponent("a.html"))
        try Data(pageB.utf8).write(to: site.appendingPathComponent("b.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/a.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        async let first = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/a.html","profile":"concurrent-a","channel":"msedge","headless":true,"waitMillis":750,"maxCharacters":2000}"#),
            in: ctx)
        async let second = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/b.html","profile":"concurrent-b","channel":"msedge","headless":true,"waitMillis":750,"maxCharacters":2000}"#),
            in: ctx)
        let (obsA, obsB) = try await (first, second)

        XCTAssertTrue(obsA.text.contains("concurrent profile A marker"), obsA.text)
        XCTAssertTrue(obsB.text.contains("concurrent profile B marker"), obsB.text)

        let stateAURL = ws.appendingPathComponent(".intatis/browser/state/concurrent-a.json")
        let stateBURL = ws.appendingPathComponent(".intatis/browser/state/concurrent-b.json")
        let stateA = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateAURL)) as? [String: Any])
        let stateB = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateBURL)) as? [String: Any])
        XCTAssertEqual(stateA["profile"] as? String, "concurrent-a")
        XCTAssertEqual(stateB["profile"] as? String, "concurrent-b")
        XCTAssertTrue((stateA["url"] as? String)?.hasSuffix("/a.html") == true, "\(stateA)")
        XCTAssertTrue((stateB["url"] as? String)?.hasSuffix("/b.html") == true, "\(stateB)")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""profile":"concurrent-a""#), historyText)
        XCTAssertTrue(historyText.contains(#""profile":"concurrent-b""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"navigate""#), historyText)
        #else
        throw XCTSkip("real browser concurrent profile smoke requires Darwin")
        #endif
    }

    func testRealBrowserUploadDownloadWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser upload/download smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let uploadDir = ws.appendingPathComponent("upload", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        try Data("upload-body".utf8).write(to: uploadDir.appendingPathComponent("report.txt"))

        let formHTML = """
        <!doctype html>
        <title>Intatis Upload Download</title>
        <body>
        <label for="file">Upload file</label>
        <input id="file" type="file">
        <pre id="status">waiting</pre>
        <a id="download" href="#" download="report.txt">Download report</a>
        <script>
        const blob = new Blob(["download-body-secret"], { type: "text/plain" });
        document.getElementById("download").href = URL.createObjectURL(blob);
        document.getElementById("file").addEventListener("change", () => {
          const file = document.getElementById("file").files[0];
          document.getElementById("status").innerText = file ? "uploaded " + file.name : "no file";
        });
        </script>
        </body>
        """
        let pageURL = "data:text/html;base64,\(Data(formHTML.utf8).base64EncodedString())"
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/io-smoke.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statePayload: [String: String] = [
            "profile": "io-smoke",
            "url": pageURL,
            "title": "Intatis Upload Download",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let stateData = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
        try stateData.write(to: stateURL, options: .atomic)

        let ctx = ToolContext(workspaceRoot: ws)

        let upload = try await BrowserUploadFileTool().execute(
            ToolArgs(raw: ##"{"selector":"#file","filePath":"upload/report.txt","profile":"io-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        XCTAssertTrue(upload.text.contains("uploaded files:"), upload.text)
        XCTAssertTrue(upload.text.contains("upload/report.txt"), upload.text)
        XCTAssertTrue(upload.text.contains("uploaded report.txt"), upload.text)

        let download = try await BrowserDownloadTool().execute(
            ToolArgs(raw: ##"{"selector":"#download","profile":"io-smoke","channel":"msedge","headless":true,"downloadTimeoutMillis":10000,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        let changed = try XCTUnwrap(download.changedFiles)
        XCTAssertEqual(changed.count, 1)
        let downloadedPath = changed[0]
        XCTAssertTrue(downloadedPath.hasPrefix(".intatis/browser/downloads/io-smoke/"), downloadedPath)
        XCTAssertTrue(downloadedPath.hasSuffix(".txt"), downloadedPath)
        XCTAssertTrue(download.text.contains("downloads:"), download.text)

        let downloadedURL = try PathConfinement.resolve(downloadedPath, within: ws)
        XCTAssertEqual(try String(contentsOf: downloadedURL, encoding: .utf8), "download-body-secret")

        let listed = try await BrowserDownloadsTool().execute(
            ToolArgs(raw: #"{"profile":"io-smoke","limit":10}"#),
            in: ctx)

        XCTAssertTrue(listed.text.contains("browser downloads: 1 file"), listed.text)
        XCTAssertTrue(listed.text.contains(".intatis/browser/downloads/io-smoke/"), listed.text)
        XCTAssertFalse(listed.text.contains("download-body-secret"), listed.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"upload""#))
        XCTAssertTrue(historyText.contains(#""action":"download""#))
        #else
        throw XCTSkip("real browser upload/download smoke requires Darwin")
        #endif
    }

    func testRealBrowserSelectAndPressKeyWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser select/press smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let formHTML = """
        <!doctype html>
        <title>Intatis Select Press</title>
        <body>
        <label for="color">Color</label>
        <select id="color">
          <option value="red">Red</option>
          <option value="blue">Blue</option>
        </select>
        <input id="q" value="ready">
        <pre id="status">waiting</pre>
        <script>
        const status = document.getElementById("status");
        document.getElementById("color").addEventListener("change", (event) => {
          status.innerText = "color=" + event.target.value;
        });
        document.getElementById("q").addEventListener("keydown", (event) => {
          if (event.key === "Enter") status.innerText = "pressed Enter value=" + event.target.value;
        });
        </script>
        </body>
        """
        let pageURL = "data:text/html;base64,\(Data(formHTML.utf8).base64EncodedString())"
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/form-smoke.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statePayload: [String: String] = [
            "profile": "form-smoke",
            "url": pageURL,
            "title": "Intatis Select Press",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let stateData = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
        try stateData.write(to: stateURL, options: .atomic)

        let ctx = ToolContext(workspaceRoot: ws)

        let select = try await BrowserSelectOptionTool().execute(
            ToolArgs(raw: ##"{"selector":"#color","optionValue":"blue","profile":"form-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(select.text.contains("color=blue"), select.text)
        XCTAssertTrue(select.text.contains("interactive elements:"), select.text)
        XCTAssertTrue(select.text.contains(#"combobox "Color" selector=#color"#), select.text)
        XCTAssertTrue(select.text.contains("options=[Red, Blue]"), select.text)

        let press = try await BrowserPressKeyTool().execute(
            ToolArgs(raw: ##"{"selector":"#q","key":"Enter","profile":"form-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(press.text.contains("pressed Enter value=ready"), press.text)
        XCTAssertTrue(press.text.contains("textbox selector=#q"), press.text)
        #else
        throw XCTSkip("real browser select/press smoke requires Darwin")
        #endif
    }

    func testRealBrowserSubmitWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser submit smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("submit-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let formHTML = """
        <!doctype html>
        <title>Intatis Submit Form</title>
        <body>
        <form id="request" method="get" action="/submitted.html">
          <label for="q">Request</label>
          <input id="q" name="q" value="ready-submit-marker">
          <button id="submit" type="submit">Send request</button>
        </form>
        </body>
        """
        let submittedHTML = """
        <!doctype html>
        <title>Intatis Submit Result</title>
        <body>submitted marker reached</body>
        """
        try Data(formHTML.utf8).write(to: site.appendingPathComponent("form.html"))
        try Data(submittedHTML.utf8).write(to: site.appendingPathComponent("submitted.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/form.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/form.html","profile":"submit-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)

        let submit = try await BrowserSubmitTool().execute(
            ToolArgs(raw: ##"{"selector":"#submit","profile":"submit-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        XCTAssertTrue(submit.text.contains("browser action: submit"), submit.text)
        XCTAssertTrue(submit.text.contains("submitted marker reached"), submit.text)
        XCTAssertTrue(submit.text.contains("/submitted.html"), submit.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"submit""#), historyText)
        XCTAssertTrue(historyText.contains("/submitted.html"), historyText)
        #else
        throw XCTSkip("real browser submit smoke requires Darwin")
        #endif
    }

    func testRealBrowserPopupNewPageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser popup/new-page smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("popup-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let indexHTML = """
        <!doctype html>
        <title>Intatis Popup Source</title>
        <body>
        <a id="open" href="/popup.html" target="_blank" rel="noopener">Open popup page</a>
        </body>
        """
        let popupHTML = """
        <!doctype html>
        <title>Intatis Popup Result</title>
        <body>popup page marker reached</body>
        """
        try Data(indexHTML.utf8).write(to: site.appendingPathComponent("index.html"))
        try Data(popupHTML.utf8).write(to: site.appendingPathComponent("popup.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/index.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/index.html","profile":"popup-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)

        let click = try await BrowserClickTool().execute(
            ToolArgs(raw: ##"{"selector":"#open","profile":"popup-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        XCTAssertTrue(click.text.contains("browser action: click"), click.text)
        XCTAssertTrue(click.text.contains("popup page marker reached"), click.text)
        XCTAssertTrue(click.text.contains("selected new page:"), click.text)
        XCTAssertTrue(click.text.contains("/popup.html"), click.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"click""#), historyText)
        XCTAssertTrue(historyText.contains("/popup.html"), historyText)
        #else
        throw XCTSkip("real browser popup/new-page smoke requires Darwin")
        #endif
    }

    func testRealBrowserScrollAndWaitWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser scroll/wait smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("scroll-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let pageHTML = """
        <!doctype html>
        <title>Intatis Scroll Wait</title>
        <style>
        body { min-height: 2400px; font-family: sans-serif; }
        #status { margin-top: 1600px; }
        </style>
        <body>
        <p>top marker</p>
        <pre id="status">waiting</pre>
        <script>
        window.addEventListener("scroll", () => {
          if (window.scrollY > 300) document.getElementById("status").innerText = "scrolled marker";
        });
        setTimeout(() => {
          document.getElementById("status").innerText += " loaded later";
        }, 500);
        </script>
        </body>
        """
        try Data(pageHTML.utf8).write(to: site.appendingPathComponent("scroll.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/scroll.html")

        let pageURL = "http://127.0.0.1:\(port)/scroll.html"
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/scroll-smoke.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statePayload: [String: String] = [
            "profile": "scroll-smoke",
            "url": pageURL,
            "title": "Intatis Scroll Wait",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let stateData = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
        try stateData.write(to: stateURL, options: .atomic)

        let ctx = ToolContext(workspaceRoot: ws)

        let scroll = try await BrowserScrollTool().execute(
            ToolArgs(raw: ##"{"direction":"down","amount":900,"profile":"scroll-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(scroll.text.contains("scrolled marker") || scroll.text.contains("loaded later"), scroll.text)

        let waited = try await BrowserWaitTool().execute(
            ToolArgs(raw: ##"{"text":"loaded later","profile":"scroll-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":100,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(waited.text.contains("loaded later"), waited.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"scroll""#))
        XCTAssertTrue(historyText.contains(#""action":"wait""#))
        #else
        throw XCTSkip("real browser scroll/wait smoke requires Darwin")
        #endif
    }

    func testRealBrowserDynamicFeedAndOnlineTaskWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser dynamic feed/task smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let site = ws.appendingPathComponent("feed-task-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)

        let feedHTML = """
        <!doctype html>
        <title>Intatis Social Feed Smoke</title>
        <style>
        body { margin: 0; min-height: 2200px; font-family: sans-serif; }
        header { position: sticky; top: 0; padding: 16px; background: white; border-bottom: 1px solid #d0d7de; }
        main { max-width: 720px; padding: 24px; }
        article { padding: 18px 0; border-bottom: 1px solid #d0d7de; }
        #new-posts { margin-top: 780px; padding: 18px; background: #f6f8fa; }
        </style>
        <body>
        <header>
          <h1>Social Feed</h1>
          <a id="task-link" href="/task.html">Open task</a>
        </header>
        <main>
          <section aria-label="Timeline">
            <h2>Timeline</h2>
            <article>Alice posted Launch update</article>
            <article>Ben posted Support handoff</article>
            <button id="load-more" type="button">Load more</button>
            <section id="new-posts" hidden>
              <article>Cara posted Incident review</article>
              <a href="/task.html">Convert to task</a>
            </section>
          </section>
        </main>
        <script>
        const newPosts = document.getElementById("new-posts");
        function revealNewPosts() {
          newPosts.hidden = false;
        }
        window.addEventListener("scroll", () => {
          if (window.scrollY > 300) revealNewPosts();
        });
        document.getElementById("load-more").addEventListener("click", revealNewPosts);
        setTimeout(revealNewPosts, 1500);
        </script>
        </body>
        """
        let taskHTML = """
        <!doctype html>
        <title>Intatis Online Task</title>
        <body>
        <h1>Online Task</h1>
        <form id="task-form" method="get" action="/done.html">
          <label for="request">Request</label>
          <input id="request" name="request" autocomplete="off">
          <button id="submit-task" type="submit">Submit task</button>
        </form>
        <script>
        document.getElementById("task-form").addEventListener("submit", (event) => {
          event.preventDefault();
          window.location.href = "/done.html";
        });
        </script>
        </body>
        """
        let doneHTML = """
        <!doctype html>
        <title>Intatis Task Done</title>
        <body>Task completed. Reference 77.</body>
        """
        try Data(feedHTML.utf8).write(to: site.appendingPathComponent("feed.html"))
        try Data(taskHTML.utf8).write(to: site.appendingPathComponent("task.html"))
        try Data(doneHTML.utf8).write(to: site.appendingPathComponent("done.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/feed.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        let navigate = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/feed.html","profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":3000}"#),
            in: ctx)
        XCTAssertTrue(navigate.text.contains("Social Feed"), navigate.text)
        XCTAssertTrue(navigate.text.contains("Timeline"), navigate.text)
        XCTAssertTrue(navigate.text.contains("Alice posted Launch update"), navigate.text)

        let scroll = try await BrowserScrollTool().execute(
            ToolArgs(raw: ##"{"direction":"down","amount":1200,"profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(scroll.text.contains("browser action: scroll"), scroll.text)

        let waited = try await BrowserWaitTool().execute(
            ToolArgs(raw: ##"{"text":"Cara posted Incident review","profile":"feed-task-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":200,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(waited.text.contains("Cara posted Incident review"), waited.text)

        let click = try await BrowserClickTool().execute(
            ToolArgs(raw: ##"{"selector":"#task-link","profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(click.text.contains("Online Task"), click.text)

        let type = try await BrowserTypeTool().execute(
            ToolArgs(raw: ##"{"selector":"#request","value":"summarize feed","profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":100,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(type.text.contains("browser action: type"), type.text)
        XCTAssertFalse(type.text.contains("summarize feed"), type.text)

        let submit = try await BrowserSubmitTool().execute(
            ToolArgs(raw: ##"{"selector":"#submit-task","profile":"feed-task-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":500,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(submit.text.contains("browser action: submit"), submit.text)
        XCTAssertTrue(submit.text.contains("Task completed. Reference 77."), submit.text)
        XCTAssertTrue(submit.text.contains("/done.html"), submit.text)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/feed-task-smoke.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["profile"] as? String, "feed-task-smoke")
        XCTAssertTrue((state["url"] as? String)?.hasSuffix("/done.html") == true, "\(state)")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""profile":"feed-task-smoke""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"navigate""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"scroll""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"wait""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"click""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"type""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"submit""#), historyText)
        #else
        throw XCTSkip("real browser dynamic feed/task smoke requires Darwin")
        #endif
    }

    func testBrowserToolRejectsInvalidProfileName() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))
        do {
            _ = try await BrowserNavigateTool().execute(
                ToolArgs(raw: #"{"url":"https://example.com","profile":"../secret"}"#),
                in: ctx)
            XCTFail("invalid profile should be rejected")
        } catch {
            // expected
        }
    }

    func testBrowserTypeRedactsTypedValueFromObservation() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"type","profile":"work","url":"https://example.com/form","title":"Form","text":"Saved secret-value successfully","links":[{"text":"secret-value result","href":"https://example.com/search?q=secret-value"}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserTypeTool().execute(
            ToolArgs(raw: ##"{"selector":"#q","value":"secret-value","profile":"work"}"##),
            in: ctx)

        XCTAssertFalse(obs.text.contains("secret-value"))
        XCTAssertTrue(obs.text.contains("[redacted input]"))
    }

    func testBrowserTypeRejectsLikelyPasswordTargetBeforeShell() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(
                recorder: recorder,
                result: ShellResult(stdout: #"{"action":"type","profile":"work"}"#, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserTypeTool().execute(
                ToolArgs(raw: ##"{"selector":"input[type=password]","value":"hunter2","profile":"work"}"##),
                in: ctx)
            XCTFail("password targets should be refused before launching the browser backend")
        } catch {
            XCTAssertTrue(String(describing: error).contains("browser_handoff"), "\(error)")
        }
        let commands = await recorder.all()
        XCTAssertTrue(commands.isEmpty)
    }

    func testBrowserTypeRejectsVerificationCodeTargetBeforeShell() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(
                recorder: recorder,
                result: ShellResult(stdout: #"{"action":"type","profile":"work"}"#, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserTypeTool().execute(
                ToolArgs(raw: ##"{"role":"textbox","name":"Verification code","value":"123456","profile":"work"}"##),
                in: ctx)
            XCTFail("verification code targets should be refused before launching the browser backend")
        } catch {
            XCTAssertTrue(String(describing: error).contains("browser_handoff"), "\(error)")
        }
        let commands = await recorder.all()
        XCTAssertTrue(commands.isEmpty)
    }

    func testBrowserSubmitReportsPageTextPayloadAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let stdout = #"{"action":"submit","profile":"work","url":"https://example.com/result","title":"Result","text":"Form submitted","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(recorder: recorder, result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserSubmitTool().execute(
            ToolArgs(raw: #"{"profile":"work","timeoutMillis":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: submit"))
        XCTAssertTrue(obs.text.contains("Form submitted"))
        let commands = await recorder.all()
        XCTAssertEqual(commands.count, 1)
        let payload = try browserPayload(from: commands[0])
        XCTAssertEqual(payload["action"] as? String, "submit")
        XCTAssertEqual(payload["profile"] as? String, "work")
        XCTAssertEqual(payload["timeoutMillis"] as? Int, 2000)
        XCTAssertNil(payload["selector"])
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"submit""#))
    }

    func testBrowserClickReportsAndPersistsOpenedPage() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"click","profile":"work","backend":"playwright","url":"https://example.com/popup","title":"Popup","text":"Popup ready","links":[],"openedPage":{"url":"https://example.com/popup","title":"Popup"},"pageCount":2}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserClickTool().execute(
            ToolArgs(raw: ##"{"selector":"#open","profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("selected new page: Popup - https://example.com/popup"), obs.text)
        XCTAssertTrue(obs.text.contains("open pages observed: 2"), obs.text)
        XCTAssertTrue(obs.text.contains("Popup ready"), obs.text)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/popup")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"click""#), historyText)
        XCTAssertTrue(historyText.contains(#""url":"https:\/\/example.com\/popup""#), historyText)
    }

    func testBrowserSelectOptionReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"select","profile":"work","url":"https://example.com/form","title":"Form","text":"Selected Blue","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserSelectOptionTool().execute(
            ToolArgs(raw: ##"{"selector":"#color","optionLabel":"Blue","profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: select"))
        XCTAssertTrue(obs.text.contains("Selected Blue"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"select""#))
    }

    func testBrowserPressKeyCanTargetElementAndReportsHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"press","profile":"work","url":"https://example.com/form","title":"Form","text":"Submitted","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserPressKeyTool().execute(
            ToolArgs(raw: ##"{"selector":"#q","key":"Enter","profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: press"))
        XCTAssertTrue(obs.text.contains("Submitted"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"press""#))
    }

    func testBrowserPressKeyRejectsControlCharacters() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserPressKeyTool().execute(
                ToolArgs(raw: #"{"key":"En\nter"}"#),
                in: ctx)
            XCTFail("control characters should be rejected")
        } catch {
            // expected
        }
    }

    func testBrowserScrollReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"scroll","profile":"work","url":"https://example.com/feed","title":"Feed","text":"Older feed item loaded","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserScrollTool().execute(
            ToolArgs(raw: ##"{"direction":"down","amount":1200,"profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: scroll"))
        XCTAssertTrue(obs.text.contains("Older feed item loaded"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"scroll""#))
    }

    func testBrowserScrollRejectsZeroDelta() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserScrollTool().execute(
                ToolArgs(raw: #"{"deltaX":0,"deltaY":0}"#),
                in: ctx)
            XCTFail("zero scroll delta should be rejected")
        } catch {
            // expected
        }
    }

    func testBrowserWaitReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"wait","profile":"work","url":"https://example.com/app","title":"App","text":"Async panel loaded","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserWaitTool().execute(
            ToolArgs(raw: ##"{"text":"Async panel","profile":"work","timeoutMillis":3000}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: wait"))
        XCTAssertTrue(obs.text.contains("Async panel loaded"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"wait""#))
    }

    func testBrowserReloadReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"reload","profile":"work","url":"https://example.com/feed","title":"Feed","text":"Feed refreshed","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserReloadTool().execute(
            ToolArgs(raw: ##"{"profile":"work","ignoreCache":true,"waitMillis":100}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: reload"))
        XCTAssertTrue(obs.text.contains("Feed refreshed"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"reload""#))
    }

    func testBrowserBackForwardReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let shell = SequenceShell([
            ShellResult(stdout: #"{"action":"navigate","profile":"work","url":"https://example.com/one","title":"One","text":"First page","links":[]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"action":"navigate","profile":"work","url":"https://example.com/two","title":"Two","text":"Second page","links":[]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"action":"back","profile":"work","url":"https://example.com/one","title":"One","text":"First page again","links":[]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"action":"forward","profile":"work","url":"https://example.com/two","title":"Two","text":"Second page again","links":[]}"#, stderr: "", exitCode: 0),
        ])
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: shell,
            git: FakeGit(statusText: "", diffText: ""))

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/one","profile":"work","waitMillis":0}"#),
            in: ctx)
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/two","profile":"work","waitMillis":0}"#),
            in: ctx)

        let back = try await BrowserBackTool().execute(
            ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
            in: ctx)
        XCTAssertTrue(back.text.contains("browser action: back"))
        XCTAssertTrue(back.text.contains("https://example.com/one"))
        XCTAssertTrue(back.text.contains("First page again"))

        let forward = try await BrowserForwardTool().execute(
            ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
            in: ctx)
        XCTAssertTrue(forward.text.contains("browser action: forward"))
        XCTAssertTrue(forward.text.contains("https://example.com/two"))
        XCTAssertTrue(forward.text.contains("Second page again"))

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""action":"back""#))
        XCTAssertTrue(history.contains(#""action":"forward""#))

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["navigationIndex"] as? Int, 1)
        let stack = (state["navigationStack"] as? [Any])?.compactMap { $0 as? String }
        XCTAssertEqual(stack, ["https://example.com/one", "https://example.com/two"])
    }

    func testBrowserDiagnosticsReportsBackendAvailability() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"diagnostics","nodeVersion":"v26.3.0","platform":"darwin","arch":"arm64","channel":"chromium","profile":"work","profileDir":"/tmp/profile","downloadsDir":"/tmp/downloads","stateFile":"/tmp/state.json","historyFile":"/tmp/history.jsonl","playwrightAvailable":false,"checkedLocations":["node resolution: playwright","/opt/homebrew/lib/node_modules/playwright"],"nodeWebSocketAvailable":true,"cdpAvailable":true,"cdpExecutable":"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge","browserApps":{"chrome":true,"edge":false}}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserDiagnosticsTool().execute(
            ToolArgs(raw: #"{"profile":"work","channel":"chromium"}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("node: v26.3.0"))
        XCTAssertTrue(obs.text.contains("playwright available: no"))
        XCTAssertTrue(obs.text.contains("node WebSocket available: yes"))
        XCTAssertTrue(obs.text.contains("cdp fallback available: yes"))
        XCTAssertTrue(obs.text.contains("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"))
        XCTAssertTrue(obs.text.contains("/opt/homebrew/lib/node_modules/playwright"))
    }

    func testBrowserProfilesListsMetadataWithoutReadingProfileDatabaseContents() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let cookieFile = ws.appendingPathComponent(".intatis/browser/profiles/work/Default/Cookies")
        try FileManager.default.createDirectory(at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret-cookie-token".utf8).write(to: cookieFile)
        let activeMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/DevToolsActivePort")
        let lockMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/SingletonLock")
        try Data("active-marker-secret".utf8).write(to: activeMarkerFile)
        try Data("lock-marker-secret".utf8).write(to: lockMarkerFile)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = """
        {
          "profile": "work",
          "url": "https://example.com/account",
          "title": "Work Portal",
          "updatedAt": "2026-07-07T03:00:00Z",
          "navigationStack": ["https://example.com/login", "https://example.com/account"],
          "navigationIndex": 1
        }
        """
        try Data(state.utf8).write(to: stateURL)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let history = [
            #"{"ts":"2026-07-07T02:00:00Z","profile":"work","action":"navigate","url":"https://example.com/login","title":"Login"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"navigate","url":"https://example.com/account","title":"Work Portal"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: historyURL)

        let downloadURL = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        try FileManager.default.createDirectory(at: downloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download-secret-body".utf8).write(to: downloadURL)

        let obs = try await BrowserProfilesTool().execute(
            ToolArgs(raw: #"{"profile":"work","limit":10,"includeProfileSize":true}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(obs.text.contains("browser profiles: 1 profile"))
        XCTAssertTrue(obs.text.contains("profile filter: work"))
        XCTAssertTrue(obs.text.contains("metadata only:"))
        XCTAssertTrue(obs.text.contains("title: Work Portal"))
        XCTAssertTrue(obs.text.contains("url: https://example.com/account"))
        XCTAssertTrue(obs.text.contains("navigation: 2 entries, index 1"))
        XCTAssertTrue(obs.text.contains("history entries: 2"))
        XCTAssertTrue(obs.text.contains("runtime markers: active browser marker present; profile lock marker present"))
        XCTAssertTrue(obs.text.contains("latest history: 2026-07-07T03:00:00Z navigate - Work Portal - https://example.com/account"))
        XCTAssertTrue(obs.text.contains("downloads: 1 file"))
        XCTAssertTrue(obs.text.contains("profile dir: .intatis/browser/profiles/work (present;"))
        XCTAssertTrue(obs.text.contains("state file: .intatis/browser/state/work.json (present)"))
        XCTAssertFalse(obs.text.contains("secret-cookie-token"))
        XCTAssertFalse(obs.text.contains("active-marker-secret"))
        XCTAssertFalse(obs.text.contains("lock-marker-secret"))
        XCTAssertFalse(obs.text.contains("DevToolsActivePort"))
        XCTAssertFalse(obs.text.contains("SingletonLock"))
        XCTAssertFalse(obs.text.contains("download-secret-body"))
        XCTAssertFalse(obs.text.contains("Default/Cookies"))
    }

    func testBrowserProfileDeleteRequiresConfirmationAndOnlyDeletesTargetProfile() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let workCookieFile = ws.appendingPathComponent(".intatis/browser/profiles/work/Default/Cookies")
        let personalCookieFile = ws.appendingPathComponent(".intatis/browser/profiles/personal/Default/Cookies")
        try FileManager.default.createDirectory(at: workCookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalCookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret-cookie-token".utf8).write(to: workCookieFile)
        try Data("personal-cookie-token".utf8).write(to: personalCookieFile)
        let activeMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/DevToolsActivePort")
        let lockMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/SingletonLock")
        try Data("active-marker-secret".utf8).write(to: activeMarkerFile)
        try Data("lock-marker-secret".utf8).write(to: lockMarkerFile)

        let workStateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let personalStateURL = ws.appendingPathComponent(".intatis/browser/state/personal.json")
        try FileManager.default.createDirectory(at: workStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"profile":"work","url":"https://example.com/work"}"#.utf8).write(to: workStateURL)
        try Data(#"{"profile":"personal","url":"https://example.com/personal"}"#.utf8).write(to: personalStateURL)

        let workDownload = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        let personalDownload = ws.appendingPathComponent(".intatis/browser/downloads/personal/keep.pdf")
        try FileManager.default.createDirectory(at: workDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download-secret-body".utf8).write(to: workDownload)
        try Data("personal-download-body".utf8).write(to: personalDownload)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let history = [
            #"{"ts":"2026-07-07T01:00:00Z","profile":"work","action":"navigate","url":"https://example.com/work","title":"Work"}"#,
            #"{"ts":"2026-07-07T02:00:00Z","profile":"personal","action":"navigate","url":"https://example.com/personal","title":"Personal"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"download","url":"https://example.com/report","title":"Report"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: historyURL)

        do {
            _ = try await BrowserProfileDeleteTool().execute(
                ToolArgs(raw: #"{"profile":"work","confirmProfile":"personal"}"#),
                in: ToolContext(workspaceRoot: ws))
            XCTFail("expected browser profile delete to require exact confirmation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("confirmProfile"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workCookieFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDownload.path))

        let obs = try await BrowserProfileDeleteTool().execute(
            ToolArgs(raw: #"{"profile":"work","confirmProfile":"work"}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(obs.text.contains("browser profile deleted: work"))
        XCTAssertTrue(obs.text.contains("profile runtime markers: present before delete (active browser marker present; profile lock marker present"))
        XCTAssertTrue(obs.text.contains("removed profile data: yes (.intatis/browser/profiles/work)"))
        XCTAssertTrue(obs.text.contains("removed state file: yes (.intatis/browser/state/work.json)"))
        XCTAssertTrue(obs.text.contains("removed downloads: yes (.intatis/browser/downloads/work)"))
        XCTAssertTrue(obs.text.contains("removed history entries: 2"))
        XCTAssertTrue(obs.text.contains("kept history entries: 1"))
        XCTAssertFalse(obs.text.contains("secret-cookie-token"))
        XCTAssertFalse(obs.text.contains("active-marker-secret"))
        XCTAssertFalse(obs.text.contains("lock-marker-secret"))
        XCTAssertFalse(obs.text.contains("DevToolsActivePort"))
        XCTAssertFalse(obs.text.contains("SingletonLock"))
        XCTAssertFalse(obs.text.contains("download-secret-body"))
        XCTAssertFalse(obs.text.contains("Default/Cookies"))
        XCTAssertFalse(obs.text.contains("report.pdf"))
        XCTAssertEqual(obs.changedFiles, [
            ".intatis/browser/profiles/work",
            ".intatis/browser/state/work.json",
            ".intatis/browser/downloads/work",
            ".intatis/browser/history.jsonl",
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: workCookieFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workStateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDownload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalCookieFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalDownload.path))

        let remainingHistory = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(remainingHistory.contains(#""profile":"work""#))
        XCTAssertTrue(remainingHistory.contains(#""profile":"personal""#))
    }

    func testBrowserHistoryReadsRecentMetadataOnly() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"ts":"2026-07-07T01:00:00Z","profile":"default","action":"navigate","url":"https://example.com","title":"Example"}"#,
            #"{"ts":"2026-07-07T02:00:00Z","profile":"work","action":"search","url":"https://duckduckgo.com/?q=test","title":"Search"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"screenshot","url":"https://example.com","title":"Example","screenshotPath":"shots/page.png"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: historyURL)
        let ctx = ToolContext(workspaceRoot: ws)

        let obs = try await BrowserHistoryTool().execute(
            ToolArgs(raw: #"{"profile":"work","limit":1}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser history: 1 entry"))
        XCTAssertTrue(obs.text.contains("screenshot - Example - https://example.com - screenshot: shots/page.png"))
        XCTAssertFalse(obs.text.contains("duckduckgo"))
        XCTAssertFalse(obs.text.contains("profileDir"))
    }

    func testBrowserSearchReportsResultTextLinksAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"search","profile":"research","backend":"cdp","backendDetail":"edge","url":"https://duckduckgo.com/?q=Intatis%20agent","title":"Intatis agent at DuckDuckGo","text":"Search results for Intatis agent","links":[{"text":"Intatis project","href":"https://example.com/intatis"}],"elements":[{"role":"textbox","name":"Search","selector":"input[name=q]","tag":"input","type":"search"}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserSearchTool().execute(
            ToolArgs(raw: #"{"query":"Intatis agent","engine":"duckduckgo","profile":"research","channel":"msedge","waitMillis":100}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: search"), obs.text)
        XCTAssertTrue(obs.text.contains("title: Intatis agent at DuckDuckGo"), obs.text)
        XCTAssertTrue(obs.text.contains("Intatis project - https://example.com/intatis"), obs.text)
        XCTAssertTrue(obs.text.contains(#"textbox "Search" selector=input[name=q] type=search"#), obs.text)
        XCTAssertTrue(obs.text.contains("Search results for Intatis agent"), obs.text)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/research.json")
        let stateData = try Data(contentsOf: stateURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://duckduckgo.com/?q=Intatis%20agent")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"research""#), history)
        XCTAssertTrue(history.contains(#""action":"search""#), history)
        XCTAssertTrue(history.contains("duckduckgo.com"), history)
    }

    func testBrowserScreenshotReportsChangedPNGAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"screenshot","profile":"work","url":"https://example.com/","title":"Example Domain","text":"Example page text","links":[],"screenshotPath":"screens/page.png"}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserScreenshotTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","outputPath":"screens/page.png","fullPage":true}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["screens/page.png"])
        XCTAssertTrue(obs.text.contains("screenshot: screens/page.png"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
    }

    func testBrowserUploadFileUsesWorkspaceFileAndReportsRelativePath() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("upload"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: ws.appendingPathComponent("upload/report.txt"))
        let stdout = #"{"action":"upload","profile":"work","url":"https://example.com/form","title":"Upload","text":"Ready","links":[],"uploadedFiles":["upload/report.txt"]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserUploadFileTool().execute(
            ToolArgs(raw: #"{"selector":"input[type=file]","filePath":"upload/report.txt","profile":"work"}"#),
            in: ctx)

        XCTAssertNil(obs.changedFiles)
        XCTAssertTrue(obs.text.contains("uploaded files:"))
        XCTAssertTrue(obs.text.contains("upload/report.txt"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"upload""#))
    }

    func testBrowserDownloadReportsChangedFileAndDownloadsListMetadataOnly() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"download","profile":"work","url":"https://example.com/files","title":"Files","text":"Downloaded","links":[],"downloads":[{"filename":"report.pdf","path":".intatis/browser/downloads/work/report.pdf","url":"https://example.com/report.pdf","bytes":7}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let download = try await BrowserDownloadTool().execute(
            ToolArgs(raw: #"{"text":"Download report","profile":"work","downloadTimeoutMillis":1000}"#),
            in: ctx)

        XCTAssertEqual(download.changedFiles, [".intatis/browser/downloads/work/report.pdf"])
        XCTAssertTrue(download.text.contains("downloads:"))
        XCTAssertTrue(download.text.contains("report.pdf -> .intatis/browser/downloads/work/report.pdf"))

        let downloadedFile = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        try FileManager.default.createDirectory(at: downloadedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1".utf8).write(to: downloadedFile)

        let listed = try await BrowserDownloadsTool().execute(
            ToolArgs(raw: #"{"profile":"work","limit":10}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(listed.text.contains("browser downloads: 1 file"))
        XCTAssertTrue(listed.text.contains(".intatis/browser/downloads/work/report.pdf"))
        XCTAssertFalse(listed.text.contains("%PDF-1"))
    }

    // MARK: Registry

    func testStandardRegistry() {
        let reg = ToolRegistry.standard()
        XCTAssertEqual(reg.descriptors().count, 36)
        XCTAssertNotNil(reg.tool(named: "read_file"))
        XCTAssertNotNil(reg.tool(named: "apply_patch"))
        XCTAssertNotNil(reg.tool(named: "read_pdf"))
        XCTAssertNotNil(reg.tool(named: "edit_pdf_pages"))
        XCTAssertNotNil(reg.tool(named: "reconstruct_document_image"))
        XCTAssertNotNil(reg.tool(named: "compile_latex"))
        XCTAssertNotNil(reg.tool(named: "generate_image"))
        XCTAssertNotNil(reg.tool(named: "web_fetch"))
        XCTAssertNotNil(reg.tool(named: "browser_diagnostics"))
        XCTAssertNotNil(reg.tool(named: "browser_profiles"))
        XCTAssertNotNil(reg.tool(named: "browser_profile_delete"))
        XCTAssertNotNil(reg.tool(named: "browser_history"))
        XCTAssertNotNil(reg.tool(named: "browser_navigate"))
        XCTAssertNotNil(reg.tool(named: "browser_snapshot"))
        XCTAssertNotNil(reg.tool(named: "browser_handoff"))
        XCTAssertNotNil(reg.tool(named: "browser_reload"))
        XCTAssertNotNil(reg.tool(named: "browser_back"))
        XCTAssertNotNil(reg.tool(named: "browser_forward"))
        XCTAssertNotNil(reg.tool(named: "browser_click"))
        XCTAssertNotNil(reg.tool(named: "browser_type"))
        XCTAssertNotNil(reg.tool(named: "browser_submit"))
        XCTAssertNotNil(reg.tool(named: "browser_select_option"))
        XCTAssertNotNil(reg.tool(named: "browser_press_key"))
        XCTAssertNotNil(reg.tool(named: "browser_scroll"))
        XCTAssertNotNil(reg.tool(named: "browser_wait"))
        XCTAssertNotNil(reg.tool(named: "browser_screenshot"))
        XCTAssertNotNil(reg.tool(named: "browser_upload_file"))
        XCTAssertNotNil(reg.tool(named: "browser_download"))
        XCTAssertNotNil(reg.tool(named: "browser_downloads"))
        XCTAssertNotNil(reg.tool(named: "browser_search"))
        XCTAssertNil(reg.tool(named: "nonexistent"))
        XCTAssertEqual(ReadFileTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(WriteFileTool.descriptor.sideEffect, .write)
        XCTAssertEqual(RunShellTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(GenerateImageTool.descriptor.sideEffect, .write)
        XCTAssertEqual(WebFetchTool.descriptor.sideEffect, .network)
        XCTAssertEqual(BrowserNavigateTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserProfilesTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(BrowserProfileDeleteTool.descriptor.sideEffect, .destructive)
        XCTAssertEqual(BrowserHistoryTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(BrowserHandoffTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserReloadTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserBackTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserForwardTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserSubmitTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserSelectOptionTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserPressKeyTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserScrollTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserWaitTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserScreenshotTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserUploadFileTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserDownloadTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserDownloadsTool.descriptor.sideEffect, .readOnly)
    }
}
