import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum CodexRuntimeExecutable {
    /// The exact audited upstream release plus Intatis's request-owned
    /// Responses `provider` passthrough patch.
    public static let pinnedVersion = "0.145.0-intatis.2"

    public static func locate(
        override: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let override {
            let normalized = override.standardizedFileURL
                .resolvingSymlinksInPath()
            guard fileManager.isExecutableFile(
                atPath: normalized.path) else {
                throw CodexRuntimeError.executableUnavailable
            }
            return normalized
        }
        if let configured = environment["INTATIS_CODEX_RUNTIME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !configured.isEmpty {
            let normalized = URL(fileURLWithPath: configured)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard fileManager.isExecutableFile(
                atPath: normalized.path) else {
                throw CodexRuntimeError.executableUnavailable
            }
            return normalized
        }

        var candidates: [URL] = []
        if let bundled = bundle.url(forAuxiliaryExecutable: "codex") {
            candidates.append(bundled)
        }
        if let resources = bundle.resourceURL {
            candidates.append(
                resources
                    .appendingPathComponent("CodexRuntime", isDirectory: true)
                    .appendingPathComponent("codex"))
        }

        candidates.append(contentsOf: [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/intatis-codex"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])
        for directory in (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true) {
            let directoryURL = URL(
                fileURLWithPath: String(directory),
                isDirectory: true)
            candidates.append(
                directoryURL.appendingPathComponent("intatis-codex"))
            candidates.append(
                directoryURL.appendingPathComponent("codex"))
        }

        var seen: Set<String> = []
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL
                .resolvingSymlinksInPath()
            guard seen.insert(normalized.path).inserted,
                  fileManager.isExecutableFile(atPath: normalized.path) else {
                continue
            }
            return normalized
        }
        throw CodexRuntimeError.executableUnavailable
    }

    public static func verifiedVersion(
        at executableURL: URL,
        expectedVersion: String = pinnedVersion
    ) throws -> String {
        try verifiedVersion(
            at: executableURL,
            expectedVersion: expectedVersion,
            timeoutSeconds: 5)
    }

    static func verifiedVersion(
        at executableURL: URL,
        expectedVersion: String,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        guard timeoutSeconds.isFinite,
              timeoutSeconds > 0 else {
            throw CodexRuntimeError.requestTimedOut("codex --version")
        }
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw CodexRuntimeError.processLaunchFailed(
                error.localizedDescription)
        }
        if !waitForExit(
            process,
            until: Date().addingTimeInterval(timeoutSeconds)) {
            process.terminate()
            if !waitForExit(
                process,
                until: Date().addingTimeInterval(0.25)) {
                forceTerminate(process)
                _ = waitForExit(
                    process,
                    until: Date().addingTimeInterval(1))
            }
            throw CodexRuntimeError.requestTimedOut("codex --version")
        }
        process.waitUntilExit()

        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        let diagnostic = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CodexRuntimeError.processTerminated(
                process.terminationStatus,
                boundedDiagnostic(diagnostic))
        }

        let tokens = output
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let actual = tokens.last, !actual.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "the runtime did not report a version")
        }
        guard actual == expectedVersion else {
            throw CodexRuntimeError.incompatibleRuntime(
                expected: expectedVersion,
                actual: actual)
        }
        return actual
    }

    private static func waitForExit(
        _ process: Process,
        until deadline: Date
    ) -> Bool {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private static func forceTerminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(pid, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(pid, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(pid, SIGKILL)
        #else
        process.terminate()
        #endif
    }

    static func boundedDiagnostic(_ value: String, limit: Int = 2_048) -> String {
        let normalized = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}
