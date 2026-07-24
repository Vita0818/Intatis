// Validation-only macOS process watchdog for the Intatis renderer fixture.
//
// Build (does not launch any app):
//   xcrun swiftc -O -module-cache-path /private/tmp/intatis-renderer-watchdog-module-cache \
//     scripts/RendererValidationWatchdog.swift \
//     -o /private/tmp/intatis-renderer-validation-watchdog
//
// The `run` command intentionally accepts an Intatis validation app plus a
// closed set of fixture options. It is not a general-purpose process runner.

#if os(macOS)
import CryptoKit
import Darwin
import Foundation

private let mib: UInt64 = 1_048_576
private let watchdogLockPath = "/private/tmp/com.Vita0818.Intatis.renderer-validation-watchdog.lock"
private let expectedBundleIdentifier = "com.Vita0818.IntatisMac"
private let expectedFixtureSHA256 = "fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1"
private let validationExecutableMarker = Data("Intatis renderer fixture".utf8)

private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private enum WatchdogFailure: Error, CustomStringConvertible {
    case usage(String)
    case preflight(String)
    case launch(String)
    case telemetry(String)
    case evidence(String)

    var description: String {
        switch self {
        case .usage(let message), .preflight(let message), .launch(let message),
             .telemetry(let message), .evidence(let message):
            return message
        }
    }
}

private enum Outcome: String, Codable {
    case passed
    case wallLimit = "wall_limit"
    case rssLimit = "rss_limit"
    case footprintLimit = "footprint_limit"
    case rollingCPULimit = "rolling_cpu_limit"
    case absoluteCPULimit = "absolute_cpu_limit"
    case instanceLimit = "instance_limit"
    case telemetryFailure = "telemetry_failure"
    case unexpectedExit = "unexpected_exit"
    case interrupted
    case cleanupFailure = "cleanup_failure"
}

private struct Limits: Encodable {
    let observationSeconds: Double
    let hardWallSeconds: Double
    let rssBytes: UInt64
    let footprintBytes: UInt64
    let rollingCPUPercent: Double
    let rollingCPUWindowSeconds: Double
    let cpuGraceSeconds: Double
    let absoluteCPUSeconds: Double
    let termGraceSeconds: Double
    let killGraceSeconds: Double
    let minimumExpectedRuntimeSeconds: Double
}

private enum ContainmentProfile: String, Encodable {
    case minimal
    case isolation
    case computerUse = "computer-use"
    case replaySmoke = "replay-smoke"

    var limits: Limits {
        switch self {
        case .minimal:
            return Limits(
                observationSeconds: 15,
                hardWallSeconds: 20,
                rssBytes: 256 * mib,
                footprintBytes: 256 * mib,
                rollingCPUPercent: 80,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 12,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 12)
        case .isolation:
            return Limits(
                observationSeconds: 20,
                hardWallSeconds: 25,
                rssBytes: 384 * mib,
                footprintBytes: 384 * mib,
                rollingCPUPercent: 150,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 30,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 16)
        case .computerUse:
            return Limits(
                observationSeconds: 45,
                hardWallSeconds: 50,
                rssBytes: 384 * mib,
                footprintBytes: 384 * mib,
                rollingCPUPercent: 150,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 60,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 36)
        case .replaySmoke:
            return Limits(
                observationSeconds: 30,
                hardWallSeconds: 35,
                rssBytes: 512 * mib,
                footprintBytes: 512 * mib,
                rollingCPUPercent: 200,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 50,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 24)
        }
    }
}

private enum FixtureStage: String, Encodable {
    case minimal
    case table
    case codeSelection = "code-selection"
    case mathOne = "math-one"
    case mathThirtyTwo = "math-thirty-two"
    case mathStructure = "math-structure"
    case mathHistory = "math-history"
    case mathStream = "math-stream"
    case streamReplacement = "stream-replacement"
    case incidentReplay = "incident-replay"
    case fullStatic = "full-static"

    func accepts(_ profile: ContainmentProfile) -> Bool {
        switch (self, profile) {
        case (.minimal, .minimal): true
        case (.table, .isolation), (.codeSelection, .isolation),
             (.mathOne, .isolation), (.mathThirtyTwo, .isolation),
             (.mathStructure, .isolation), (.mathHistory, .isolation),
             (.mathStream, .isolation),
             (.streamReplacement, .isolation), (.fullStatic, .isolation): true
        case (.mathOne, .computerUse), (.mathThirtyTwo, .computerUse),
             (.mathStructure, .computerUse), (.mathHistory, .computerUse),
             (.mathStream, .computerUse): true
        case (.incidentReplay, .replaySmoke): true
        default: false
        }
    }
}

private enum RendererMode: String, Encodable {
    case microsoft
    case plainSafe

    var launchArgument: String {
        switch self {
        case .microsoft: "-IntatisMicrosoftMarkdownMessages"
        case .plainSafe: "-IntatisPlainSafeMessages"
        }
    }
}

private enum MathMode: String, Encodable {
    case disabled
    case singleDollar = "single-dollar"

    var launchArgument: String? {
        switch self {
        case .disabled: "-IntatisDisableSingleDollarMath"
        case .singleDollar: nil
        }
    }
}

private enum Appearance: String, Encodable {
    case light
    case dark

    var launchArgument: String {
        switch self {
        case .light: "-IntatisAppearanceLight"
        case .dark: "-IntatisAppearanceDark"
        }
    }
}

private struct RunConfiguration {
    let appPath: String
    let expectedAppSHA256: String
    let fixturePath: String
    let outputPath: String
    let stage: FixtureStage
    let renderer: RendererMode
    let mathMode: MathMode
    let appearance: Appearance
    let profile: ContainmentProfile
}

private struct ProcessIdentity: Encodable {
    let pid: Int32
    let name: String
    let path: String?
    let startSeconds: UInt64?
    let startMicroseconds: UInt64?
}

private struct GroupMetrics {
    let pids: [Int32]
    let rssBytes: UInt64
    let footprintBytes: UInt64
    let cpuNanoseconds: UInt64
}

private struct SampleRecord: Encodable {
    let schema = "intatis.renderer-watchdog.sample.v1"
    let sequence: Int
    let elapsedSeconds: Double
    let processGroupID: Int32
    let pids: [Int32]
    let rssBytes: UInt64
    let footprintBytes: UInt64
    let totalCPUNanoseconds: UInt64
    let rollingCPUPercent: Double?
}

private struct EventRecord: Encodable {
    let schema = "intatis.renderer-watchdog.event.v1"
    let sequence: Int
    let elapsedSeconds: Double
    let kind: String
    let detail: String
}

private struct Manifest: Encodable {
    let schema = "intatis.renderer-watchdog.manifest.v2"
    let createdAt: String
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let appPath: String
    let executablePath: String
    let executableSHA256: String
    let bundleIdentifier: String
    let bundleVersion: String
    let fixturePath: String
    let fixtureSHA256: String
    let stage: FixtureStage
    let renderer: RendererMode
    let mathMode: MathMode
    let appearance: Appearance
    let profile: ContainmentProfile
    let limits: Limits
    let containmentOnly: Bool
}

private struct ResultRecord: Encodable {
    let schema = "intatis.renderer-watchdog.result.v1"
    let outcome: Outcome
    let detail: String
    let elapsedSeconds: Double
    let childPID: Int32
    let processGroupID: Int32
    let childExitCode: Int32?
    let childTerminationSignal: Int32?
    let peakRSSBytes: UInt64
    let peakFootprintBytes: UInt64
    let peakRollingCPUPercent: Double
    let usedSIGTERM: Bool
    let usedSIGKILL: Bool
    let residualGroupPIDs: [Int32]
    let residualRendererProcesses: [ProcessIdentity]
    let cleanupVerifiedTwice: Bool

    var passed: Bool { outcome == .passed }
}

private final class AdvisoryLock {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchdogFailure.preflight("cannot open owner-only watchdog lock: errno \(errno)")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            throw WatchdogFailure.preflight("cannot secure watchdog lock permissions: errno \(errno)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw WatchdogFailure.preflight("another renderer watchdog already owns the validation lock")
        }
        _ = ftruncate(descriptor, 0)
        let owner = "pid=\(getpid())\n"
        owner.withCString { pointer in
            _ = write(descriptor, pointer, strlen(pointer))
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private final class EvidenceWriter {
    let outputURL: URL
    private let eventHandle: FileHandle
    private let sampleHandle: FileHandle
    private let encoder: JSONEncoder
    private var eventSequence = 0

    init(outputPath: String) throws {
        let fileManager = FileManager.default
        outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw WatchdogFailure.preflight("refusing to reuse existing evidence directory: \(outputURL.path)")
        }
        do {
            try fileManager.createDirectory(
                at: outputURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputURL.path)
        } catch {
            throw WatchdogFailure.evidence("cannot create evidence directory: \(error.localizedDescription)")
        }

        eventHandle = try Self.createFile(at: outputURL.appendingPathComponent("events.jsonl"))
        sampleHandle = try Self.createFile(at: outputURL.appendingPathComponent("samples.jsonl"))
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        try? eventHandle.close()
        try? sampleHandle.close()
    }

    func writeManifest(_ manifest: Manifest) throws {
        try writeJSON(manifest, fileName: "manifest.json")
    }

    func writeResult(_ result: ResultRecord) throws {
        try writeJSON(result, fileName: "result.json")
    }

    func event(kind: String, detail: String, elapsedSeconds: Double) throws {
        eventSequence += 1
        try append(
            EventRecord(
                sequence: eventSequence,
                elapsedSeconds: elapsedSeconds,
                kind: kind,
                detail: detail),
            to: eventHandle)
    }

    func sample(_ record: SampleRecord) throws {
        try append(record, to: sampleHandle)
    }

    func consoleFileDescriptor() throws -> Int32 {
        let path = outputURL.appendingPathComponent("app-console.log").path
        let descriptor = open(
            path,
            O_CREAT | O_EXCL | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchdogFailure.evidence("cannot create app-console.log: errno \(errno)")
        }
        return descriptor
    }

    private func writeJSON<T: Encodable>(_ value: T, fileName: String) throws {
        let url = outputURL.appendingPathComponent(fileName)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw WatchdogFailure.evidence("cannot write \(fileName): \(error.localizedDescription)")
        }
    }

    private func append<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        do {
            var data = try encoder.encode(value)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw WatchdogFailure.evidence("cannot append watchdog evidence: \(error.localizedDescription)")
        }
    }

    private static func createFile(at url: URL) throws -> FileHandle {
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchdogFailure.evidence("cannot create \(url.lastPathComponent): errno \(errno)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private struct SpawnedProcess {
    let pid: pid_t
    let processGroupID: pid_t
    let identity: ProcessIdentity
}

private struct MonitorSpecification {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let familyNames: Set<String>
    let excludedPIDs: Set<pid_t>
    let limits: Limits
    let maximumFamilyInstances: Int
    let injectedTelemetryFailureSample: Int?
}

private struct CPUPoint {
    let elapsedSeconds: Double
    let cpuNanoseconds: UInt64
}

private struct CleanupResult {
    let usedSIGTERM: Bool
    let usedSIGKILL: Bool
    let residualGroupPIDs: [pid_t]
    let residualRendererProcesses: [ProcessIdentity]
    let verifiedTwice: Bool
}

private var receivedSignal: sig_atomic_t = 0

private func signalHandler(_ signalNumber: Int32) {
    receivedSignal = signalNumber
}

private func installSignalHandlers() {
    _ = signal(SIGINT, signalHandler)
    _ = signal(SIGTERM, signalHandler)
    _ = signal(SIGHUP, signalHandler)
}

private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

private func sha256(path: String) throws -> String {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    } catch {
        throw WatchdogFailure.preflight("cannot hash \(path): \(error.localizedDescription)")
    }
}

private func allPIDs() throws -> [pid_t] {
    let estimatedCount = proc_listallpids(nil, 0)
    guard estimatedCount >= 0 else {
        throw WatchdogFailure.telemetry("proc_listallpids size query failed: errno \(errno)")
    }
    var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
    let count = pids.withUnsafeMutableBytes { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    guard count >= 0 else {
        throw WatchdogFailure.telemetry("proc_listallpids failed: errno \(errno)")
    }
    return Array(pids.prefix(Int(count))).filter { $0 > 0 }
}

private func processPath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = buffer.withUnsafeMutableBytes { rawBuffer in
        proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
    }
    guard length > 0 else { return nil }
    return canonicalPath(String(cString: buffer))
}

private func processName(pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = buffer.withUnsafeMutableBytes { rawBuffer in
        proc_name(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
    }
    if length > 0 {
        return String(cString: buffer)
    }
    return processPath(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unavailable"
}

private func processStart(pid: pid_t) -> (UInt64, UInt64)? {
    var info = proc_bsdinfo()
    let copied = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            UnsafeMutableRawPointer(pointer),
            Int32(MemoryLayout<proc_bsdinfo>.size))
    }
    guard copied == MemoryLayout<proc_bsdinfo>.size else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
}

private func identity(pid: pid_t) -> ProcessIdentity {
    let start = processStart(pid: pid)
    return ProcessIdentity(
        pid: pid,
        name: processName(pid: pid),
        path: processPath(pid: pid),
        startSeconds: start?.0,
        startMicroseconds: start?.1)
}

private func isFamilyMember(_ identity: ProcessIdentity, familyNames: Set<String>) -> Bool {
    let pathName = identity.path.map { URL(fileURLWithPath: $0).lastPathComponent }
    let candidates = [identity.name, pathName].compactMap { $0 }
    return candidates.contains { candidate in
        familyNames.contains(candidate)
            || candidate.hasPrefix("IntatisRendererValidation")
            || candidate.hasPrefix("IntatisRenderer")
    }
}

private func rendererProcesses(
    familyNames: Set<String>,
    excluding excludedPIDs: Set<pid_t>
) throws -> [ProcessIdentity] {
    try allPIDs()
        .filter { !excludedPIDs.contains($0) }
        .map(identity(pid:))
        .filter { isFamilyMember($0, familyNames: familyNames) }
        .sorted { $0.pid < $1.pid }
}

private func groupPIDs(_ processGroupID: pid_t) throws -> [pid_t] {
    let estimatedCount = proc_listpgrppids(processGroupID, nil, 0)
    guard estimatedCount >= 0 else {
        throw WatchdogFailure.telemetry("proc_listpgrppids size query failed: errno \(errno)")
    }
    guard estimatedCount > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 16)
    let count = pids.withUnsafeMutableBytes { buffer in
        proc_listpgrppids(processGroupID, buffer.baseAddress, Int32(buffer.count))
    }
    guard count >= 0 else {
        throw WatchdogFailure.telemetry("proc_listpgrppids failed: errno \(errno)")
    }
    return Array(pids.prefix(Int(count))).filter { $0 > 0 }
}

private func groupMetrics(_ processGroupID: pid_t) throws -> GroupMetrics {
    let pids = try groupPIDs(processGroupID)
    var rss: UInt64 = 0
    var footprint: UInt64 = 0
    var cpu: UInt64 = 0
    var sampledPIDs: [pid_t] = []

    for pid in pids {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            // Darwin imports `rusage_info_t *` as a pointer to an optional raw
            // pointer even though the API writes the selected rusage struct
            // directly into the supplied storage. Rebind the struct storage;
            // passing `&rawPointer` would give libproc only one pointer-sized
            // stack slot and corrupt the caller's stack.
            UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                .withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
        }
        if result != 0 {
            if kill(pid, 0) != 0, errno == ESRCH {
                continue
            }
            throw WatchdogFailure.telemetry("proc_pid_rusage failed for live pid \(pid): errno \(errno)")
        }
        sampledPIDs.append(pid)
        rss = rss.addingReportingOverflow(usage.ri_resident_size).partialValue
        footprint = footprint.addingReportingOverflow(usage.ri_phys_footprint).partialValue
        // proc_pid_rusage reports CPU in Mach absolute-time ticks on macOS.
        // Convert before applying limits or labeling the evidence as ns.
        let processCPUTicks = usage.ri_user_time
            .addingReportingOverflow(usage.ri_system_time).partialValue
        let processCPU = processCPUTicks
            .multipliedReportingOverflow(by: UInt64(machTimebase.numer)).partialValue
            / UInt64(machTimebase.denom)
        cpu = cpu.addingReportingOverflow(processCPU).partialValue
    }

    return GroupMetrics(
        pids: sampledPIDs.sorted(),
        rssBytes: rss,
        footprintBytes: footprint,
        cpuNanoseconds: cpu)
}

private func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> R
) rethrows -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return try pointers.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

private func spawnSuspended(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    consoleDescriptor: Int32
) throws -> SpawnedProcess {
    var attributes: posix_spawnattr_t?
    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0,
          posix_spawn_file_actions_init(&fileActions) == 0
    else {
        throw WatchdogFailure.launch("cannot initialize posix_spawn state")
    }
    defer {
        _ = posix_spawnattr_destroy(&attributes)
        _ = posix_spawn_file_actions_destroy(&fileActions)
    }

    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
        throw WatchdogFailure.launch("cannot configure suspended process group")
    }

    let nullDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard nullDescriptor >= 0 else {
        throw WatchdogFailure.launch("cannot open /dev/null: errno \(errno)")
    }
    defer { close(nullDescriptor) }

    guard posix_spawn_file_actions_adddup2(&fileActions, nullDescriptor, STDIN_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&fileActions, consoleDescriptor, STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&fileActions, consoleDescriptor, STDERR_FILENO) == 0
    else {
        throw WatchdogFailure.launch("cannot configure child standard streams")
    }

    let argumentStrings = [executablePath] + arguments
    let environmentStrings = environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    var childPID: pid_t = 0
    let spawnStatus = withCStringArray(argumentStrings) { argumentPointers in
        withCStringArray(environmentStrings) { environmentPointers in
            executablePath.withCString { executablePointer in
                posix_spawn(
                    &childPID,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers)
            }
        }
    }
    guard spawnStatus == 0 else {
        throw WatchdogFailure.launch("posix_spawn failed: errno \(spawnStatus)")
    }

    let processGroupID = getpgid(childPID)
    guard processGroupID == childPID else {
        _ = kill(childPID, SIGKILL)
        throw WatchdogFailure.launch(
            "child did not receive an isolated process group (pid \(childPID), pgid \(processGroupID))")
    }
    let childIdentity = identity(pid: childPID)
    guard childIdentity.path == canonicalPath(executablePath),
          childIdentity.startSeconds != nil
    else {
        _ = killpg(processGroupID, SIGKILL)
        throw WatchdogFailure.launch("cannot prove suspended child path/start identity")
    }
    return SpawnedProcess(pid: childPID, processGroupID: processGroupID, identity: childIdentity)
}

private func decodeWaitStatus(_ status: Int32) -> (exitCode: Int32?, signal: Int32?) {
    let signalNumber = status & 0x7f
    if signalNumber == 0 {
        return ((status >> 8) & 0xff, nil)
    }
    if signalNumber != 0x7f {
        return (nil, signalNumber)
    }
    return (nil, nil)
}

private func reapIfExited(_ pid: pid_t) -> (didExit: Bool, status: Int32) {
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    return (result == pid, status)
}

private func monotonicSeconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

private func waitForEmptyGroup(_ processGroupID: pid_t, timeoutSeconds: Double) -> [pid_t] {
    let start = DispatchTime.now().uptimeNanoseconds
    var lastPIDs: [pid_t] = []
    repeat {
        lastPIDs = (try? groupPIDs(processGroupID)) ?? []
        if lastPIDs.isEmpty { return [] }
        usleep(50_000)
    } while monotonicSeconds(since: start) < timeoutSeconds
    return lastPIDs
}

private func verifyCleanupTwice(
    processGroupID: pid_t,
    familyNames: Set<String>,
    excludedPIDs: Set<pid_t>
) -> (Bool, [pid_t], [ProcessIdentity]) {
    var finalGroup: [pid_t] = []
    var finalFamily: [ProcessIdentity] = []
    for index in 0..<2 {
        finalGroup = (try? groupPIDs(processGroupID)) ?? [processGroupID]
        finalFamily = (try? rendererProcesses(
            familyNames: familyNames,
            excluding: excludedPIDs)) ?? [ProcessIdentity(
                pid: -1,
                name: "telemetry-failed",
                path: nil,
                startSeconds: nil,
                startMicroseconds: nil)]
        guard finalGroup.isEmpty, finalFamily.isEmpty else {
            return (false, finalGroup, finalFamily)
        }
        if index == 0 { usleep(100_000) }
    }
    return (true, finalGroup, finalFamily)
}

private func cleanup(
    process: SpawnedProcess,
    familyNames: Set<String>,
    excludedPIDs: Set<pid_t>,
    limits: Limits,
    sendTermination: Bool
) -> CleanupResult {
    var usedSIGTERM = false
    var usedSIGKILL = false

    let groupIsEmpty = (try? groupPIDs(process.processGroupID).isEmpty) ?? false
    if sendTermination, !groupIsEmpty {
        usedSIGTERM = killpg(process.processGroupID, SIGTERM) == 0
    }

    var residualGroup = waitForEmptyGroup(
        process.processGroupID,
        timeoutSeconds: limits.termGraceSeconds)
    if !residualGroup.isEmpty {
        usedSIGKILL = killpg(process.processGroupID, SIGKILL) == 0
        residualGroup = waitForEmptyGroup(
            process.processGroupID,
            timeoutSeconds: limits.killGraceSeconds)
    }

    var waitStatus: Int32 = 0
    _ = waitpid(process.pid, &waitStatus, WNOHANG)
    let verification = verifyCleanupTwice(
        processGroupID: process.processGroupID,
        familyNames: familyNames,
        excludedPIDs: excludedPIDs)
    return CleanupResult(
        usedSIGTERM: usedSIGTERM,
        usedSIGKILL: usedSIGKILL,
        residualGroupPIDs: verification.1,
        residualRendererProcesses: verification.2,
        verifiedTwice: verification.0)
}

private func runMonitor(
    specification: MonitorSpecification,
    writer: EvidenceWriter
) throws -> ResultRecord {
    let existing = try rendererProcesses(
        familyNames: specification.familyNames,
        excluding: specification.excludedPIDs)
    guard existing.isEmpty else {
        throw WatchdogFailure.preflight(
            "refusing to launch while renderer-family processes already exist: \(existing.map(\.pid))")
    }

    let consoleDescriptor = try writer.consoleFileDescriptor()
    defer { close(consoleDescriptor) }
    let process = try spawnSuspended(
        executablePath: specification.executablePath,
        arguments: specification.arguments,
        environment: specification.environment,
        consoleDescriptor: consoleDescriptor)
    let start = DispatchTime.now().uptimeNanoseconds
    try writer.event(
        kind: "spawned_suspended",
        detail: "pid=\(process.pid) pgid=\(process.processGroupID)",
        elapsedSeconds: 0)

    var processIsReaped = false
    var waitStatus: Int32 = 0
    var outcome: Outcome = .unexpectedExit
    var detail = "monitor ended without a terminal reason"
    var peakRSS: UInt64 = 0
    var peakFootprint: UInt64 = 0
    var peakRollingCPU = 0.0
    var cpuPoints: [CPUPoint] = []
    var sampleSequence = 0

    let familyAfterSpawn = try rendererProcesses(
        familyNames: specification.familyNames,
        excluding: specification.excludedPIDs)
    guard familyAfterSpawn.count <= specification.maximumFamilyInstances,
          familyAfterSpawn.contains(where: { $0.pid == process.pid })
    else {
        let cleanupResult = cleanup(
            process: process,
            familyNames: specification.familyNames,
            excludedPIDs: specification.excludedPIDs,
            limits: specification.limits,
            sendTermination: true)
        return ResultRecord(
            outcome: cleanupResult.verifiedTwice ? .instanceLimit : .cleanupFailure,
            detail: "single-instance proof failed before resume",
            elapsedSeconds: monotonicSeconds(since: start),
            childPID: process.pid,
            processGroupID: process.processGroupID,
            childExitCode: nil,
            childTerminationSignal: nil,
            peakRSSBytes: 0,
            peakFootprintBytes: 0,
            peakRollingCPUPercent: 0,
            usedSIGTERM: cleanupResult.usedSIGTERM,
            usedSIGKILL: cleanupResult.usedSIGKILL,
            residualGroupPIDs: cleanupResult.residualGroupPIDs,
            residualRendererProcesses: cleanupResult.residualRendererProcesses,
            cleanupVerifiedTwice: cleanupResult.verifiedTwice)
    }

    guard kill(process.pid, SIGCONT) == 0 else {
        throw WatchdogFailure.launch("cannot resume suspended child: errno \(errno)")
    }
    try writer.event(kind: "resumed", detail: "child resumed", elapsedSeconds: 0)

    monitorLoop: while true {
        let elapsed = monotonicSeconds(since: start)
        if receivedSignal != 0 {
            outcome = .interrupted
            detail = "watchdog received signal \(receivedSignal)"
            break monitorLoop
        }

        var rawStatus: Int32 = 0
        let waitResult = waitpid(process.pid, &rawStatus, WNOHANG)
        if waitResult == process.pid {
            processIsReaped = true
            waitStatus = rawStatus
            let decoded = decodeWaitStatus(rawStatus)
            if decoded.exitCode == 0,
               elapsed >= specification.limits.minimumExpectedRuntimeSeconds {
                outcome = .passed
                detail = "fixture exited cleanly after its planned observation window"
            } else {
                outcome = .unexpectedExit
                detail = "child exited before/without the planned clean observation contract"
            }
            break monitorLoop
        }
        if waitResult < 0, errno != EINTR {
            outcome = .telemetryFailure
            detail = "waitpid failed: errno \(errno)"
            break monitorLoop
        }

        if elapsed >= specification.limits.hardWallSeconds {
            outcome = .wallLimit
            detail = "child exceeded hard wall \(specification.limits.hardWallSeconds)s"
            break monitorLoop
        }

        sampleSequence += 1
        if specification.injectedTelemetryFailureSample == sampleSequence {
            outcome = .telemetryFailure
            detail = "injected telemetry failure at sample \(sampleSequence)"
            break monitorLoop
        }

        do {
            let currentIdentity = identity(pid: process.pid)
            guard currentIdentity.path == process.identity.path,
                  currentIdentity.startSeconds == process.identity.startSeconds,
                  currentIdentity.startMicroseconds == process.identity.startMicroseconds,
                  getpgid(process.pid) == process.processGroupID
            else {
                throw WatchdogFailure.telemetry("leader identity/path/PGID changed")
            }

            let family = try rendererProcesses(
                familyNames: specification.familyNames,
                excluding: specification.excludedPIDs)
            guard family.count <= specification.maximumFamilyInstances,
                  family.contains(where: { $0.pid == process.pid })
            else {
                outcome = .instanceLimit
                detail = "renderer-family instance count changed to \(family.count)"
                break monitorLoop
            }

            let metrics = try groupMetrics(process.processGroupID)
            guard metrics.pids.contains(process.pid) else {
                throw WatchdogFailure.telemetry("leader missing from its process-group sample")
            }
            peakRSS = max(peakRSS, metrics.rssBytes)
            peakFootprint = max(peakFootprint, metrics.footprintBytes)

            cpuPoints.append(CPUPoint(elapsedSeconds: elapsed, cpuNanoseconds: metrics.cpuNanoseconds))
            cpuPoints.removeAll {
                elapsed - $0.elapsedSeconds > specification.limits.rollingCPUWindowSeconds
            }
            var rollingCPU: Double?
            if elapsed >= specification.limits.cpuGraceSeconds,
               let first = cpuPoints.first,
               let last = cpuPoints.last,
               last.elapsedSeconds - first.elapsedSeconds
                   >= specification.limits.rollingCPUWindowSeconds * 0.8,
               last.cpuNanoseconds >= first.cpuNanoseconds {
                let cpuSeconds = Double(last.cpuNanoseconds - first.cpuNanoseconds) / 1_000_000_000
                let wallSeconds = last.elapsedSeconds - first.elapsedSeconds
                rollingCPU = cpuSeconds / wallSeconds * 100
                peakRollingCPU = max(peakRollingCPU, rollingCPU ?? 0)
            }

            try writer.sample(SampleRecord(
                sequence: sampleSequence,
                elapsedSeconds: elapsed,
                processGroupID: process.processGroupID,
                pids: metrics.pids,
                rssBytes: metrics.rssBytes,
                footprintBytes: metrics.footprintBytes,
                totalCPUNanoseconds: metrics.cpuNanoseconds,
                rollingCPUPercent: rollingCPU))

            if metrics.rssBytes > specification.limits.rssBytes {
                outcome = .rssLimit
                detail = "group RSS exceeded \(specification.limits.rssBytes) bytes"
                break monitorLoop
            }
            if metrics.footprintBytes > specification.limits.footprintBytes {
                outcome = .footprintLimit
                detail = "group physical footprint exceeded \(specification.limits.footprintBytes) bytes"
                break monitorLoop
            }
            if let rollingCPU,
               rollingCPU > specification.limits.rollingCPUPercent {
                outcome = .rollingCPULimit
                detail = "rolling CPU exceeded \(specification.limits.rollingCPUPercent)%"
                break monitorLoop
            }
            if Double(metrics.cpuNanoseconds) / 1_000_000_000
                > specification.limits.absoluteCPUSeconds {
                outcome = .absoluteCPULimit
                detail = "absolute CPU exceeded \(specification.limits.absoluteCPUSeconds)s"
                break monitorLoop
            }
        } catch {
            outcome = .telemetryFailure
            detail = String(describing: error)
            break monitorLoop
        }

        usleep(100_000)
    }

    let elapsed = monotonicSeconds(since: start)
    try writer.event(kind: "terminal_reason", detail: "\(outcome.rawValue): \(detail)", elapsedSeconds: elapsed)
    let cleanupResult = cleanup(
        process: process,
        familyNames: specification.familyNames,
        excludedPIDs: specification.excludedPIDs,
        limits: specification.limits,
        sendTermination: outcome != .passed)

    if !processIsReaped {
        let reaped = reapIfExited(process.pid)
        if reaped.didExit {
            waitStatus = reaped.status
        }
    }
    let decoded = decodeWaitStatus(waitStatus)
    let finalOutcome = cleanupResult.verifiedTwice ? outcome : .cleanupFailure
    try writer.event(
        kind: "cleanup",
        detail: cleanupResult.verifiedTwice
            ? "process group and renderer family verified empty twice"
            : "cleanup residual remained",
        elapsedSeconds: monotonicSeconds(since: start))

    return ResultRecord(
        outcome: finalOutcome,
        detail: detail,
        elapsedSeconds: elapsed,
        childPID: process.pid,
        processGroupID: process.processGroupID,
        childExitCode: decoded.exitCode,
        childTerminationSignal: decoded.signal,
        peakRSSBytes: peakRSS,
        peakFootprintBytes: peakFootprint,
        peakRollingCPUPercent: peakRollingCPU,
        usedSIGTERM: cleanupResult.usedSIGTERM,
        usedSIGKILL: cleanupResult.usedSIGKILL,
        residualGroupPIDs: cleanupResult.residualGroupPIDs,
        residualRendererProcesses: cleanupResult.residualRendererProcesses,
        cleanupVerifiedTwice: cleanupResult.verifiedTwice)
}

private func validationEnvironment() -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    let allowedKeys = [
        "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_CTYPE",
        "__CF_USER_TEXT_ENCODING",
    ]
    var environment: [String: String] = [:]
    for key in allowedKeys {
        if let value = inherited[key] { environment[key] = value }
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["NSUnbufferedIO"] = "YES"
    environment["INTATIS_RENDERER_WATCHDOG"] = "1"
    return environment
}

private func validateApp(_ configuration: RunConfiguration) throws -> (String, Manifest) {
    let appPath = canonicalPath(configuration.appPath)
    let fixturePath = canonicalPath(configuration.fixturePath)
    guard appPath.hasSuffix(".app"),
          FileManager.default.fileExists(atPath: appPath),
          let bundle = Bundle(path: appPath),
          let executableURL = bundle.executableURL
    else {
        throw WatchdogFailure.preflight("validation app bundle/executable is missing")
    }
    guard bundle.bundleIdentifier == expectedBundleIdentifier else {
        throw WatchdogFailure.preflight(
            "unexpected bundle identifier: \(bundle.bundleIdentifier ?? "missing")")
    }
    let executablePath = canonicalPath(executableURL.path)
    guard URL(fileURLWithPath: executablePath).lastPathComponent == "IntatisMac" else {
        throw WatchdogFailure.preflight("unexpected validation executable name")
    }
    let executableHash = try sha256(path: executablePath)
    guard executableHash == configuration.expectedAppSHA256 else {
        throw WatchdogFailure.preflight("validation executable SHA-256 mismatch")
    }
    let executableData = try Data(
        contentsOf: URL(fileURLWithPath: executablePath),
        options: [.mappedIfSafe])
    guard executableData.range(of: validationExecutableMarker) != nil else {
        throw WatchdogFailure.preflight(
            "validation fixture marker is absent; refusing to launch a normal Intatis build")
    }
    let fixtureHash = try sha256(path: fixturePath)
    guard fixtureHash == expectedFixtureSHA256 else {
        throw WatchdogFailure.preflight("sanitized fixture SHA-256 mismatch")
    }

    let manifest = Manifest(
        createdAt: ISO8601DateFormatter().string(from: Date()),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        appPath: appPath,
        executablePath: executablePath,
        executableSHA256: executableHash,
        bundleIdentifier: bundle.bundleIdentifier ?? "missing",
        bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "missing",
        fixturePath: fixturePath,
        fixtureSHA256: fixtureHash,
        stage: configuration.stage,
        renderer: configuration.renderer,
        mathMode: configuration.mathMode,
        appearance: configuration.appearance,
        profile: configuration.profile,
        limits: configuration.profile.limits,
        containmentOnly: true)
    return (executablePath, manifest)
}

private func parseRunConfiguration(_ arguments: [String]) throws -> RunConfiguration {
    var values: [String: String] = [:]
    var sawApproval = false
    let valueFlags = Set([
        "--app", "--expected-app-sha256", "--fixture", "--output", "--stage", "--renderer",
        "--math", "--appearance", "--profile",
    ])
    var index = 2
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--user-approved-gui" {
            guard !sawApproval else { throw WatchdogFailure.usage("duplicate --user-approved-gui") }
            sawApproval = true
            index += 1
            continue
        }
        guard valueFlags.contains(argument), arguments.indices.contains(index + 1) else {
            throw WatchdogFailure.usage("unknown or valueless run argument: \(argument)")
        }
        guard values[argument] == nil else {
            throw WatchdogFailure.usage("duplicate run argument: \(argument)")
        }
        values[argument] = arguments[index + 1]
        index += 2
    }

    guard sawApproval else {
        throw WatchdogFailure.preflight(
            "run requires --user-approved-gui after the user explicitly approves this GUI launch")
    }
    func required(_ flag: String) throws -> String {
        guard let value = values[flag], !value.isEmpty else {
            throw WatchdogFailure.usage("missing \(flag)")
        }
        return value
    }
    guard let stage = FixtureStage(rawValue: try required("--stage")),
          let renderer = RendererMode(rawValue: try required("--renderer")),
          let mathMode = MathMode(rawValue: try required("--math")),
          let appearance = Appearance(rawValue: try required("--appearance")),
          let profile = ContainmentProfile(rawValue: try required("--profile"))
    else {
        throw WatchdogFailure.usage("invalid stage/renderer/math/appearance/profile")
    }
    guard stage.accepts(profile) else {
        throw WatchdogFailure.preflight("profile \(profile.rawValue) is not valid for stage \(stage.rawValue)")
    }
    let expectedAppSHA256 = try required("--expected-app-sha256").lowercased()
    let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
    guard expectedAppSHA256.count == 64,
          expectedAppSHA256.unicodeScalars.allSatisfy(hexDigits.contains)
    else {
        throw WatchdogFailure.usage(
            "--expected-app-sha256 must be 64 lowercase or uppercase hex digits")
    }
    return RunConfiguration(
        appPath: try required("--app"),
        expectedAppSHA256: expectedAppSHA256,
        fixturePath: try required("--fixture"),
        outputPath: try required("--output"),
        stage: stage,
        renderer: renderer,
        mathMode: mathMode,
        appearance: appearance,
        profile: profile)
}

private func runValidation(_ arguments: [String]) throws -> Int32 {
    let configuration = try parseRunConfiguration(arguments)
    let lock = try AdvisoryLock(path: watchdogLockPath)
    defer { withExtendedLifetime(lock) {} }
    let writer = try EvidenceWriter(outputPath: configuration.outputPath)
    let validated = try validateApp(configuration)
    try writer.writeManifest(validated.1)
    try writer.event(kind: "preflight", detail: "bundle, fixture, lock, and telemetry prerequisites passed", elapsedSeconds: 0)

    let limits = configuration.profile.limits
    var launchArguments = [
        "-IntatisRendererFixture",
        configuration.renderer.launchArgument,
        configuration.appearance.launchArgument,
        "-IntatisRendererFixtureStage",
        configuration.stage.rawValue,
        "-IntatisRendererIncidentFixture",
        canonicalPath(configuration.fixturePath),
        "-IntatisRendererFixtureAutoExitSeconds",
        String(format: "%.3f", limits.observationSeconds),
    ]
    if let mathLaunchArgument = configuration.mathMode.launchArgument {
        launchArguments.append(mathLaunchArgument)
    }
    let result = try runMonitor(
        specification: MonitorSpecification(
            executablePath: validated.0,
            arguments: launchArguments,
            environment: validationEnvironment(),
            familyNames: ["IntatisMac", "IntatisRendererValidation"],
            excludedPIDs: [getpid()],
            limits: limits,
            maximumFamilyInstances: 1,
            injectedTelemetryFailureSample: nil),
        writer: writer)
    try writer.writeResult(result)
    print("WATCHDOG_RESULT=\(result.outcome.rawValue) OUTPUT=\(writer.outputURL.path)")
    return result.passed ? 0 : 70
}

private func selfExecutablePath() throws -> String {
    guard let path = processPath(pid: getpid()) else {
        throw WatchdogFailure.preflight("cannot resolve watchdog executable path")
    }
    return path
}

private func selfTestLimits(
    hardWall: Double = 2,
    rssMiB: UInt64 = 512,
    footprintMiB: UInt64 = 512,
    rollingCPU: Double = 500,
    cpuWindow: Double = 0.3,
    grace: Double = 0.1,
    absoluteCPU: Double = 10,
    minimumRuntime: Double = 0
) -> Limits {
    Limits(
        observationSeconds: max(0, hardWall - 0.25),
        hardWallSeconds: hardWall,
        rssBytes: rssMiB * mib,
        footprintBytes: footprintMiB * mib,
        rollingCPUPercent: rollingCPU,
        rollingCPUWindowSeconds: cpuWindow,
        cpuGraceSeconds: grace,
        absoluteCPUSeconds: absoluteCPU,
        termGraceSeconds: 0.2,
        killGraceSeconds: 1,
        minimumExpectedRuntimeSeconds: minimumRuntime)
}

private struct SelfTestCaseResult: Encodable {
    let name: String
    let expected: [Outcome]
    let actual: Outcome
    let cleanupVerifiedTwice: Bool
    let passed: Bool
}

private struct SelfTestSummary: Encodable {
    let schema = "intatis.renderer-watchdog.self-test.v1"
    let cases: [SelfTestCaseResult]
    let allPassed: Bool
}

private func runSelfTestCase(
    name: String,
    childMode: String,
    expected: [Outcome],
    limits: Limits,
    maximumFamilyInstances: Int = 1,
    injectedTelemetryFailureSample: Int? = nil,
    rootOutput: URL,
    executablePath: String
) throws -> SelfTestCaseResult {
    let writer = try EvidenceWriter(outputPath: rootOutput.appendingPathComponent(name).path)
    let result = try runMonitor(
        specification: MonitorSpecification(
            executablePath: executablePath,
            arguments: ["--self-test-child", childMode],
            environment: validationEnvironment(),
            familyNames: [URL(fileURLWithPath: executablePath).lastPathComponent],
            excludedPIDs: [getpid()],
            limits: limits,
            maximumFamilyInstances: maximumFamilyInstances,
            injectedTelemetryFailureSample: injectedTelemetryFailureSample),
        writer: writer)
    try writer.writeResult(result)
    let passed = expected.contains(result.outcome) && result.cleanupVerifiedTwice
    return SelfTestCaseResult(
        name: name,
        expected: expected,
        actual: result.outcome,
        cleanupVerifiedTwice: result.cleanupVerifiedTwice,
        passed: passed)
}

private func writeSelfTestSummary(_ summary: SelfTestSummary, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(summary)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func validateClosedSetSelfTestContracts() throws {
    let isolatedMathStages: [FixtureStage] = [
        .mathOne,
        .mathThirtyTwo,
        .mathStructure,
        .mathHistory,
        .mathStream,
    ]
    guard isolatedMathStages.allSatisfy({ $0.accepts(.isolation) }),
          isolatedMathStages.allSatisfy({ $0.accepts(.computerUse) }),
          isolatedMathStages.allSatisfy({ !$0.accepts(.minimal) }),
          isolatedMathStages.allSatisfy({ !$0.accepts(.replaySmoke) }),
          FixtureStage.mathStructure.rawValue == "math-structure",
          FixtureStage.mathHistory.rawValue == "math-history",
          MathMode.disabled.launchArgument == "-IntatisDisableSingleDollarMath",
          MathMode.singleDollar.launchArgument == nil
    else {
        throw WatchdogFailure.preflight(
            "closed-set math validation contracts failed self-test")
    }
}

private func runSelfTests(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 4, arguments[2] == "--output" else {
        throw WatchdogFailure.usage("usage: watchdog self-test --output NEW_DIRECTORY")
    }
    let lock = try AdvisoryLock(path: watchdogLockPath)
    try validateClosedSetSelfTestContracts()
    let outputURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw WatchdogFailure.preflight("refusing to reuse self-test output directory")
    }
    try FileManager.default.createDirectory(
        at: outputURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    let executablePath = try selfExecutablePath()
    let cases: [(String, String, [Outcome], Limits, Int, Int?)] = [
        ("clean-exit", "short", [.passed], selfTestLimits(hardWall: 2, minimumRuntime: 0.2), 1, nil),
        ("wall-fuse", "sleep", [.wallLimit], selfTestLimits(hardWall: 0.6), 1, nil),
        ("memory-fuse", "memory", [.rssLimit, .footprintLimit], selfTestLimits(hardWall: 3, rssMiB: 96, footprintMiB: 160), 1, nil),
        ("cpu-fuse", "cpu", [.rollingCPULimit], selfTestLimits(
            hardWall: 3,
            rollingCPU: 20,
            cpuWindow: 1), 1, nil),
        ("group-kill", "group", [.wallLimit], selfTestLimits(hardWall: 0.8), 2, nil),
        ("exit-seven", "exit7", [.unexpectedExit], selfTestLimits(hardWall: 2), 1, nil),
        ("telemetry-fail-closed", "sleep", [.telemetryFailure], selfTestLimits(hardWall: 2), 1, 3),
    ]
    var results: [SelfTestCaseResult] = []
    for testCase in cases {
        let result = try runSelfTestCase(
            name: testCase.0,
            childMode: testCase.1,
            expected: testCase.2,
            limits: testCase.3,
            maximumFamilyInstances: testCase.4,
            injectedTelemetryFailureSample: testCase.5,
            rootOutput: outputURL,
            executablePath: executablePath)
        results.append(result)
        print("SELF_TEST=\(result.name) EXPECTED=\(result.expected.map(\.rawValue).joined(separator: ",")) ACTUAL=\(result.actual.rawValue) PASS=\(result.passed)")
    }

    // A second lock contender must fail before it can spawn any target.
    let lockWriter = try EvidenceWriter(outputPath: outputURL.appendingPathComponent("lock-contention").path)
    let lockResult = try runMonitor(
        specification: MonitorSpecification(
            executablePath: executablePath,
            arguments: ["--self-test-child", "lock", watchdogLockPath],
            environment: validationEnvironment(),
            familyNames: [URL(fileURLWithPath: executablePath).lastPathComponent],
            excludedPIDs: [getpid()],
            limits: selfTestLimits(hardWall: 2),
            maximumFamilyInstances: 1,
            injectedTelemetryFailureSample: nil),
        writer: lockWriter)
    try lockWriter.writeResult(lockResult)
    let lockCase = SelfTestCaseResult(
        name: "lock-contention",
        expected: [.unexpectedExit],
        actual: lockResult.outcome,
        cleanupVerifiedTwice: lockResult.cleanupVerifiedTwice,
        passed: lockResult.outcome == .unexpectedExit
            && lockResult.childExitCode == 9
            && lockResult.cleanupVerifiedTwice)
    results.append(lockCase)
    print("SELF_TEST=lock-contention EXPECTED=exit9 ACTUAL=\(lockResult.childExitCode.map(String.init) ?? "signal") PASS=\(lockCase.passed)")

    let summary = SelfTestSummary(cases: results, allPassed: results.allSatisfy(\.passed))
    try writeSelfTestSummary(summary, at: outputURL.appendingPathComponent("self-test-result.json"))
    withExtendedLifetime(lock) {}
    return summary.allPassed ? 0 : 70
}

private func spawnSelfTestGrandchild() -> pid_t {
    guard let executablePath = try? selfExecutablePath() else { return -1 }
    var childPID: pid_t = 0
    let arguments = [executablePath, "--self-test-child", "ignore-term"]
    let environment = validationEnvironment().map { "\($0.key)=\($0.value)" }.sorted()
    let status = withCStringArray(arguments) { argumentPointers in
        withCStringArray(environment) { environmentPointers in
            executablePath.withCString { executablePointer in
                posix_spawn(
                    &childPID,
                    executablePointer,
                    nil,
                    nil,
                    argumentPointers,
                    environmentPointers)
            }
        }
    }
    return status == 0 ? childPID : -1
}

private func runSelfTestChild(_ arguments: [String]) -> Never {
    guard arguments.count >= 3 else { exit(64) }
    switch arguments[2] {
    case "short":
        usleep(300_000)
        exit(0)
    case "sleep":
        sleep(10)
        exit(0)
    case "memory":
        let byteCount = 256 * Int(mib)
        guard let pointer = mmap(
            nil,
            byteCount,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0), pointer != MAP_FAILED
        else { exit(8) }
        var checksum: UInt64 = 0
        for offset in stride(from: 0, to: byteCount, by: 4_096) {
            let value = UInt64(offset + 1)
            pointer.advanced(by: offset).storeBytes(of: value, as: UInt64.self)
            checksum &+= value
        }
        withUnsafeBytes(of: &checksum) { bytes in
            _ = write(STDOUT_FILENO, bytes.baseAddress, bytes.count)
        }
        while true {
            var observed: UInt64 = 0
            for offset in stride(from: 0, to: byteCount, by: 4_096) {
                observed &+= pointer.advanced(by: offset).load(as: UInt64.self)
            }
            checksum = observed
            usleep(100_000)
        }
    case "cpu":
        while true { _ = getpid() }
    case "group":
        guard spawnSelfTestGrandchild() > 0 else { exit(8) }
        sleep(10)
        exit(0)
    case "ignore-term":
        _ = signal(SIGTERM, SIG_IGN)
        while true { sleep(1) }
    case "exit7":
        exit(7)
    case "lock":
        guard arguments.count == 4 else { exit(64) }
        let descriptor = open(arguments[3], O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { exit(8) }
        let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        close(descriptor)
        exit(acquired ? 0 : 9)
    default:
        exit(64)
    }
}

private func printUsage() {
    let usage = """
    Usage:
      watchdog self-test --output NEW_DIRECTORY
      watchdog run --user-approved-gui \\
        --app VALIDATION.app --expected-app-sha256 SHA256 \\
        --fixture incident-1249-sanitized-v1.json \\
        --output NEW_DIRECTORY --stage STAGE --renderer microsoft|plainSafe \\
        --math disabled|single-dollar --appearance light|dark \\
        --profile minimal|isolation|computer-use|replay-smoke

    The run command only accepts a hash-pinned Intatis validation build and never
    treats a containment run as release-performance evidence.
    """
    FileHandle.standardError.write(Data((usage + "\n").utf8))
}

private func main() -> Int32 {
    installSignalHandlers()
    let arguments = CommandLine.arguments
    if arguments.count >= 2, arguments[1] == "--self-test-child" {
        runSelfTestChild(arguments)
    }
    do {
        guard arguments.count >= 2 else {
            throw WatchdogFailure.usage("missing command")
        }
        switch arguments[1] {
        case "run":
            return try runValidation(arguments)
        case "self-test":
            return try runSelfTests(arguments)
        default:
            throw WatchdogFailure.usage("unknown command: \(arguments[1])")
        }
    } catch {
        FileHandle.standardError.write(Data(("watchdog error: \(error)\n").utf8))
        printUsage()
        return error is WatchdogFailure ? 64 : 70
    }
}

exit(main())
#else
import Foundation
FileHandle.standardError.write(Data("RendererValidationWatchdog requires macOS.\n".utf8))
exit(64)
#endif
