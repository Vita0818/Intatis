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

/// Thin owner for one official `codex app-server` process and one durable
/// Codex thread. The upstream runtime remains authoritative for agent-loop,
/// tools, sandboxing, approval review, context, and subagents.
public actor CodexAppServerSession {
    public static let pinnedRuntimeVersion =
        CodexRuntimeExecutable.pinnedVersion

    private typealias ResponseContinuation =
        CheckedContinuation<JSONValue, Error>
    private typealias TurnContinuation =
        CheckedContinuation<CodexRuntimeTurnResult, Error>

    private struct PendingResponse {
        let method: String
        let continuation: ResponseContinuation
        let timeoutTask: Task<Void, Never>
    }

    private let configuration: CodexRuntimeConfiguration
    private let storage: CodexRuntimeStorage
    private var processLease: CodexRuntimeProcessLease?
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stdoutBuffer = Data()
    private var stderrDiagnostic = ""
    private var nextRequestID = 1
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var pendingApprovals:
        [CodexRuntimeRequestID: CodexRuntimeApprovalRequest] = [:]
    private var turnWaiters: [String: [TurnContinuation]] = [:]
    private var terminalTurns: [String: CodexRuntimeTurnResult] = [:]
    private var terminalTurnOrder: [String] = []
    private var emittedTurnStarts: Set<String> = []
    private var eventContinuations:
        [UUID: AsyncStream<CodexRuntimeEvent>.Continuation] = [:]
    private var runtimeIdentity: CodexRuntimeIdentity?
    private var hasPersistedThreadRecord = false
    private var activeTurnID: String?
    private var isStarting = false
    private var isShuttingDown = false
    private var isStoppingProcess = false
    private var isFailingEventBuffer = false
    private var deferredProcessRetirement: Task<Void, Never>?

    public init(configuration: CodexRuntimeConfiguration) {
        self.configuration = configuration
        self.storage = CodexRuntimeStorage(
            rootURL: configuration.runtimeRootURL)
    }

    public func events() -> AsyncStream<CodexRuntimeEvent> {
        let streamID = UUID()
        return AsyncStream(
            bufferingPolicy: .bufferingOldest(4_096)
        ) { continuation in
            eventContinuations[streamID] = continuation
            if let runtimeIdentity {
                continuation.yield(.ready(runtimeIdentity))
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(streamID) }
            }
        }
    }

    public func currentIdentity() -> CodexRuntimeIdentity? {
        runtimeIdentity
    }

    public func currentTurnID() -> String? {
        activeTurnID
    }

    @discardableResult
    public func start() async throws -> CodexRuntimeIdentity {
        if let runtimeIdentity { return runtimeIdentity }
        guard process == nil, !isStarting, !isShuttingDown else {
            throw CodexRuntimeError.alreadyRunning
        }
        isStarting = true
        defer { isStarting = false }
        isFailingEventBuffer = false
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrDiagnostic = ""

        try storage.prepare()
        try storage.rejectPersistedShellSnapshots()
        processLease = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        do {
            try storage.writeModelCatalog(
                modelID: configuration.route.model.rawValue,
                baseInstructions: configuration.mode.baseInstructions)
            let executable = try CodexRuntimeExecutable.locate(
                override: configuration.executableOverride)
            let version = try CodexRuntimeExecutable.verifiedVersion(
                at: executable)
            try launchProcess(executableURL: executable)

            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("intatis"),
                        "title": .string("Intatis"),
                        "version": .string("0.55"),
                    ]),
                    "capabilities": .object([
                        // The first integration consumes only stable methods.
                        "experimentalApi": .bool(false),
                    ]),
                ]))

            let workspacePath = configuration.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            let result: JSONValue
            let resumedThreadID: String?
            if let record = try storage.readRecord() {
                guard record.mode == configuration.mode,
                      record.workspacePath == workspacePath else {
                    throw CodexRuntimeError.unsafeRuntimeStorage
                }
                var params = threadLifecycleParameters()
                params["threadId"] = .string(record.threadID)
                result = try await request(
                    method: "thread/resume",
                    params: .object(params))
                resumedThreadID = record.threadID
            } else {
                guard configuration.allowsThreadCreation else {
                    throw CodexRuntimeError.threadMigrationRequired
                }
                result = try await request(
                    method: "thread/start",
                    params: .object(threadLifecycleParameters()))
                resumedThreadID = nil
            }

            let threadID = try Self.threadID(from: result)
            if let resumedThreadID,
               resumedThreadID != threadID {
                throw CodexRuntimeError.malformedProtocol(
                    "thread/resume returned a different thread id")
            }
            hasPersistedThreadRecord = resumedThreadID != nil
            let identity = CodexRuntimeIdentity(
                threadID: threadID,
                runtimeVersion: version,
                mode: configuration.mode)
            runtimeIdentity = identity
            emit(.ready(identity))
            return identity
        } catch {
            await stopProcess(after: error)
            throw error
        }
    }

    /// Starts a turn and returns as soon as App Server accepts it. Completion
    /// continues through the event stream.
    @discardableResult
    public func startTurn(
        text: String,
        localImageURLs: [URL] = []
    ) async throws -> String {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        guard activeTurnID == nil else {
            throw CodexRuntimeError.alreadyRunning
        }
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !localImageURLs.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "a turn requires text or an image")
        }

        var input: [JSONValue] = []
        if !normalized.isEmpty {
            input.append(.object([
                "type": .string("text"),
                "text": .string(text),
            ]))
        }
        for imageURL in localImageURLs {
            guard imageURL.isFileURL,
                  imageURL.path.hasPrefix("/") else {
                throw CodexRuntimeError.malformedProtocol(
                    "local image inputs require absolute file URLs")
            }
            input.append(.object([
                "type": .string("localImage"),
                "path": .string(imageURL.standardizedFileURL.path),
            ]))
        }

        var params: [String: JSONValue] = [
            "threadId": .string(identity.threadID),
            "input": .array(input),
            "clientUserMessageId": .string(UUID().uuidString.lowercased()),
            "cwd": .string(configuration.workspaceURL.path),
            "model": .string(configuration.route.model.rawValue),
            "approvalsReviewer": .string(
                configuration.approvalReviewer.rawValue),
        ]
        if let reasoningEffort = configuration.reasoningEffort,
           !reasoningEffort.isEmpty {
            params["effort"] = .string(reasoningEffort)
        }
        let result = try await request(
            method: "turn/start",
            params: .object(params))
        guard let turn = result.objectValue?["turn"]?.objectValue,
              let turnID = turn["id"]?.stringValue,
              !turnID.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "turn/start response is missing turn.id")
        }
        if terminalTurns[turnID] == nil {
            activeTurnID = turnID
            emitTurnStartedIfNeeded(turnID)
        }
        if !hasPersistedThreadRecord {
            let workspacePath = configuration.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            try storage.writeRecord(
                threadID: identity.threadID,
                mode: configuration.mode,
                workspacePath: workspacePath)
            hasPersistedThreadRecord = true
        }
        return turnID
    }

    /// Runs one accepted turn to its official terminal notification.
    public func runTurn(
        text: String,
        localImageURLs: [URL] = []
    ) async throws -> CodexRuntimeTurnResult {
        let turnID = try await startTurn(
            text: text,
            localImageURLs: localImageURLs)
        return try await withTaskCancellationHandler {
            try await waitForTurn(turnID)
        } onCancel: {
            Task { try? await self.interruptTurn(turnID: turnID) }
        }
    }

    public func waitForTurn(
        _ turnID: String
    ) async throws -> CodexRuntimeTurnResult {
        if let result = terminalTurns[turnID] {
            return try Self.validated(result)
        }
        return try await withCheckedThrowingContinuation { continuation in
            turnWaiters[turnID, default: []].append(continuation)
        }
    }

    public func interruptCurrentTurn() async throws {
        guard let activeTurnID else {
            throw CodexRuntimeError.noActiveTurn
        }
        try await interruptTurn(turnID: activeTurnID)
    }

    public func interruptTurn(turnID: String) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        _ = try await request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(identity.threadID),
                "turnId": .string(turnID),
            ]),
            timeoutSeconds: 5)
    }

    public func setGoal(
        objective: String,
        tokenBudget: Int? = nil
    ) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        let objective = objective.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "a Codex goal requires a nonempty objective")
        }
        var params: [String: JSONValue] = [
            "threadId": .string(identity.threadID),
            "objective": .string(objective),
            "status": .string("active"),
        ]
        if let tokenBudget {
            guard tokenBudget > 0 else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex goal token budget must be positive")
            }
            params["tokenBudget"] = .number(Double(tokenBudget))
        }
        _ = try await request(
            method: "thread/goal/set",
            params: .object(params))
    }

    public func setGoalStatus(_ status: String) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        guard [
            "active", "paused", "blocked", "usageLimited",
            "budgetLimited", "complete",
        ].contains(status) else {
            throw CodexRuntimeError.malformedProtocol(
                "unsupported Codex goal status")
        }
        _ = try await request(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(identity.threadID),
                "status": .string(status),
            ]))
    }

    public func clearGoal() async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        _ = try await request(
            method: "thread/goal/clear",
            params: .object([
                "threadId": .string(identity.threadID),
            ]))
    }

    public func resolveApproval(
        requestID: CodexRuntimeRequestID,
        decision: CodexRuntimeApprovalDecision
    ) throws {
        guard let request = pendingApprovals[requestID] else {
            throw CodexRuntimeError.requestNotPending
        }
        let result: JSONValue
        switch request.kind {
        case .command, .fileChange:
            result = .object([
                "decision": .string(decision.rawValue),
            ])
        case .permissions:
            let permissions: JSONValue
            switch decision {
            case .accept, .acceptForSession:
                permissions = request.requestedPermissions
                    ?? .object([:])
            case .decline, .cancel:
                permissions = .object([:])
            }
            result = .object([
                "permissions": permissions,
                "scope": .string(
                    decision == .acceptForSession ? "session" : "turn"),
            ])
        }
        try sendResponse(id: requestID.wireValue, result: result)
        pendingApprovals.removeValue(forKey: requestID)
        emit(.approvalResolved(requestID))
        if request.kind == .permissions,
           decision == .cancel,
           !request.turnID.isEmpty {
            Task {
                try? await self.interruptTurn(
                    turnID: request.turnID)
            }
        }
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if let activeTurnID,
           let identity = runtimeIdentity,
           process != nil {
            _ = try? await request(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(identity.threadID),
                    "turnId": .string(activeTurnID),
                ]),
                timeoutSeconds: 5)
        }
        await stopProcess(after: nil)
        finishEventStreams()
    }

    func threadLifecycleParameters() -> [String: JSONValue] {
        var provider: [String: JSONValue] = [
            "name": .string("Intatis Responses"),
            "base_url": .string(configuration.route.baseURL.absoluteString),
            "env_key": .string("INTATIS_CODEX_PROVIDER_TOKEN"),
            "wire_api": .string("responses"),
            "requires_openai_auth": .bool(false),
            "supports_websockets": .bool(false),
        ]
        if !configuration.route.queryParameters.isEmpty {
            provider["query_params"] = .object(
                configuration.route.queryParameters.mapValues(JSONValue.string))
        }
        if let providerOptions = configuration.route.providerOptions {
            provider["intatis_responses_provider"] = .object(
                providerOptions)
        }
        let runtimeConfig: JSONValue = .object([
            "model": .string(configuration.route.model.rawValue),
            "model_provider": .string("intatis"),
            "model_catalog_json": .string(
                storage.modelCatalogURL.path),
            "model_providers": .object([
                "intatis": .object(provider),
            ]),
            "analytics": .object([
                "enabled": .bool(false),
            ]),
            "features": .object([
                // 0.145.0 snapshots the App Server process environment before
                // the tool-level filter, which would persist provider tokens.
                "shell_snapshot": .bool(false),
            ]),
            "shell_environment_policy": .object([
                "inherit": .string("core"),
                "ignore_default_excludes": .bool(false),
                "exclude": .array([
                    .string("INTATIS_*"),
                    .string("CODEX_HOME"),
                ]),
            ]),
        ])
        return [
            "cwd": .string(configuration.workspaceURL.path),
            "model": .string(configuration.route.model.rawValue),
            "modelProvider": .string("intatis"),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string(
                configuration.approvalReviewer.rawValue),
            "sandbox": .string("workspace-write"),
            "developerInstructions": .string(
                configuration.mode.developerInstructions),
            "baseInstructions": .string(
                configuration.mode.baseInstructions),
            "ephemeral": .bool(false),
            "config": runtimeConfig,
        ]
    }

    private func launchProcess(executableURL: URL) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "app-server", "--stdio", "--strict-config",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = storage.homeURL.path
        environment["INTATIS_CODEX_PROVIDER_TOKEN"] =
            configuration.route.bearerToken
        process.environment = environment

        let stdoutStream = Self.byteStream(
            from: output.fileHandleForReading)
        let stderrStream = Self.byteStream(
            from: error.fileHandleForReading)
        process.terminationHandler = { [weak self] terminated in
            Task {
                await self?.processDidTerminate(
                    status: terminated.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            throw CodexRuntimeError.processLaunchFailed(
                error.localizedDescription)
        }
        self.process = process
        self.standardInput = input.fileHandleForWriting
        stdoutTask = Task { [weak self] in
            for await data in stdoutStream {
                guard !Task.isCancelled else { return }
                await self?.consumeStdout(data)
            }
        }
        stderrTask = Task { [weak self] in
            for await data in stderrStream {
                guard !Task.isCancelled else { return }
                await self?.consumeStderr(data)
            }
        }
    }

    private func request(
        method: String,
        params: JSONValue,
        timeoutSeconds: UInt64 = 30
    ) async throws -> JSONValue {
        guard process?.isRunning == true,
              standardInput != nil else {
            throw CodexRuntimeError.notStarted
        }
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(requestID)
            }
            pendingResponses[requestID] = PendingResponse(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask)
            do {
                try writeJSON(.object([
                    "id": .number(Double(requestID)),
                    "method": .string(method),
                    "params": params,
                ]))
            } catch {
                pendingResponses.removeValue(
                    forKey: requestID)?.timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendResponse(
        id: JSONValue,
        result: JSONValue
    ) throws {
        try writeJSON(.object([
            "id": id,
            "result": result,
        ]))
    }

    private func timeoutRequest(_ requestID: Int) {
        guard let pending = pendingResponses.removeValue(
            forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(
            throwing: CodexRuntimeError.requestTimedOut(
                pending.method))
    }

    private func sendErrorResponse(
        id: JSONValue,
        message: String
    ) throws {
        try writeJSON(.object([
            "id": id,
            "error": .object([
                "code": .number(-32_601),
                "message": .string(message),
            ]),
        ]))
    }

    private func writeJSON(_ value: JSONValue) throws {
        guard let standardInput else {
            throw CodexRuntimeError.notStarted
        }
        var data = try JSONEncoder.intatisCodex.encode(value)
        data.append(0x0A)
        do {
            try standardInput.write(contentsOf: data)
        } catch {
            throw CodexRuntimeError.processLaunchFailed(
                "could not write to App Server: \(error.localizedDescription)")
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        let maximumBufferedBytes = 16 * 1_024 * 1_024
        guard stdoutBuffer.count <= maximumBufferedBytes else {
            failProtocol("one JSON-RPC line exceeded 16 MiB")
            return
        }
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let value = try JSONDecoder().decode(
                    JSONValue.self,
                    from: line)
                try handleIncoming(value)
            } catch {
                failProtocol(error.localizedDescription)
                return
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return }
        let redacted = redact(value)
        stderrDiagnostic = CodexRuntimeExecutable.boundedDiagnostic(
            stderrDiagnostic + redacted)
    }

    private func handleIncoming(_ value: JSONValue) throws {
        guard let object = value.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "top-level message is not an object")
        }
        if let method = object["method"]?.stringValue {
            if let id = object["id"] {
                try handleServerRequest(
                    id: id,
                    method: method,
                    params: object["params"] ?? .object([:]))
            } else {
                handleNotification(
                    method: method,
                    params: object["params"] ?? .object([:]))
            }
            return
        }
        guard let idValue = object["id"],
              let requestID = idValue.integralIntValue,
              let pending = pendingResponses.removeValue(
                forKey: requestID) else {
            throw CodexRuntimeError.malformedProtocol(
                "response has no matching request id")
        }
        pending.timeoutTask.cancel()
        if let error = object["error"]?.objectValue {
            let code = error["code"]?.integralIntValue
            let message = redact(
                error["message"]?.stringValue
                    ?? "unknown App Server error")
            pending.continuation.resume(throwing: CodexRuntimeError.serverError(
                code: code,
                message: bounded(message)))
        } else {
            pending.continuation.resume(
                returning: object["result"] ?? .null)
        }
    }

    private func handleServerRequest(
        id: JSONValue,
        method: String,
        params: JSONValue
    ) throws {
        guard let requestID = CodexRuntimeRequestID(wireValue: id),
              let object = params.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "server request has an invalid id or params")
        }
        let kind: CodexRuntimeApprovalKind
        let title: String
        let summary: String
        let requestedPermissions: JSONValue?
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .command
            title = "Codex command"
            summary = object["reason"]?.stringValue
                ?? object["command"]?.stringValue
                ?? "Codex requests permission to run a command."
            requestedPermissions = nil
        case "item/fileChange/requestApproval":
            kind = .fileChange
            title = "Codex file change"
            summary = object["reason"]?.stringValue
                ?? "Codex requests permission to modify workspace files."
            requestedPermissions = nil
        case "item/permissions/requestApproval":
            kind = .permissions
            title = "Codex permissions"
            summary = object["reason"]?.stringValue
                ?? "Codex requests additional runtime permissions."
            requestedPermissions = object["permissions"]
        default:
            let message =
                "Intatis does not expose the App Server interaction '\(method)' in this first runtime version."
            try sendErrorResponse(id: id, message: message)
            emit(.runtimeError(
                code: "unsupported_app_server_request",
                message: message,
                fatal: false))
            return
        }
        let request = CodexRuntimeApprovalRequest(
            requestID: requestID,
            kind: kind,
            threadID: object["threadId"]?.stringValue ?? "",
            turnID: object["turnId"]?.stringValue ?? "",
            itemID: object["itemId"]?.stringValue ?? "",
            title: title,
            summary: bounded(redact(summary), limit: 8_192),
            requestedPermissions: requestedPermissions)
        guard pendingApprovals[requestID] == nil else {
            throw CodexRuntimeError.malformedProtocol(
                "duplicate live server request id")
        }
        pendingApprovals[requestID] = request
        emit(.approvalRequested(request))
    }

    private func handleNotification(
        method: String,
        params: JSONValue
    ) {
        let object = params.objectValue ?? [:]
        switch method {
        case "turn/started":
            if let turnID = object["turn"]?.objectValue?["id"]?.stringValue {
                activeTurnID = turnID
                emitTurnStartedIfNeeded(turnID)
            }
        case "item/agentMessage/delta":
            guard let itemID = object["itemId"]?.stringValue,
                  let text = object["delta"]?.stringValue else { return }
            emit(.assistantDelta(
                itemID: itemID,
                text: redact(text)))
        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta":
            guard let itemID = object["itemId"]?.stringValue,
                  let text = object["delta"]?.stringValue else { return }
            emit(.reasoningDelta(
                itemID: itemID,
                text: redact(text)))
        case "item/started":
            if let item = object["item"],
               let parsed = runtimeItem(from: item) {
                emit(.itemStarted(parsed))
            }
        case "item/completed":
            guard let item = object["item"] else { return }
            if let itemObject = item.objectValue,
               itemObject["type"]?.stringValue == "agentMessage",
               let itemID = itemObject["id"]?.stringValue,
               let text = itemObject["text"]?.stringValue {
                emit(.assistantCompleted(
                    itemID: itemID,
                    text: redact(text)))
            } else if let parsed = runtimeItem(from: item) {
                emit(.itemCompleted(parsed))
            }
        case "turn/completed":
            guard let turn = object["turn"]?.objectValue,
                  let turnID = turn["id"]?.stringValue,
                  let status = turn["status"]?.stringValue else { return }
            let message = turn["error"]?.objectValue?["message"]?
                .stringValue.map { bounded(redact($0)) }
            completeTurn(CodexRuntimeTurnResult(
                turnID: turnID,
                status: status,
                errorMessage: message))
        case "serverRequest/resolved":
            guard let idValue = object["requestId"],
                  let requestID = CodexRuntimeRequestID(
                    wireValue: idValue) else { return }
            if pendingApprovals.removeValue(forKey: requestID) != nil {
                emit(.approvalResolved(requestID))
            }
        case "error":
            let error = object["error"]?.objectValue
            let message = error?["message"]?.stringValue
                ?? "Codex Runtime reported an unknown error."
            emit(.runtimeError(
                code: "codex_runtime",
                message: bounded(redact(message)),
                fatal: false))
        default:
            break
        }
    }

    private func runtimeItem(from value: JSONValue) -> CodexRuntimeItem? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let type = object["type"]?.stringValue else {
            return nil
        }
        let status = object["status"]?.stringValue
        let failure = status == "failed" || status == "declined"
        switch type {
        case "commandExecution":
            return CodexRuntimeItem(
                id: id,
                kind: .command,
                title: "command",
                detail: "",
                status: status,
                isFailure: failure)
        case "fileChange":
            let files = Self.fileChangePaths(
                from: object["changes"])
            return CodexRuntimeItem(
                id: id,
                kind: .fileChange,
                title: "file changes",
                detail: files.isEmpty
                    ? ""
                    : "\(files.count) file change(s)",
                status: status,
                isFailure: failure)
        case "mcpToolCall":
            let server = object["server"]?.stringValue ?? "MCP"
            let tool = object["tool"]?.stringValue ?? "tool"
            return CodexRuntimeItem(
                id: id,
                kind: .mcpTool,
                title: "\(server) · \(tool)",
                status: status,
                isFailure: failure)
        case "dynamicToolCall":
            return CodexRuntimeItem(
                id: id,
                kind: .dynamicTool,
                title: object["tool"]?.stringValue ?? "tool",
                status: status,
                isFailure: failure)
        case "collabAgentToolCall", "collabToolCall":
            let related = object["receiverThreadIds"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            return CodexRuntimeItem(
                id: id,
                kind: .collaboration,
                title: object["tool"]?.stringValue ?? "collaboration",
                detail: "",
                status: status,
                isFailure: failure,
                relatedThreadIDs: related)
        case "subAgentActivity":
            let threadID = object["agentThreadId"]?.stringValue
            return CodexRuntimeItem(
                id: id,
                kind: .subagent,
                title: object["kind"]?.stringValue ?? "subagent",
                detail: "",
                status: nil,
                relatedThreadIDs: threadID.map { [$0] } ?? [])
        case "webSearch":
            return CodexRuntimeItem(
                id: id,
                kind: .webSearch,
                title: "web search",
                detail: "",
                status: status,
                isFailure: failure)
        case "imageGeneration", "imageView":
            return CodexRuntimeItem(
                id: id,
                kind: .image,
                title: "image",
                detail: "",
                status: status,
                isFailure: failure)
        case "plan":
            return CodexRuntimeItem(
                id: id,
                kind: .plan,
                title: "plan",
                detail: "",
                status: status,
                isFailure: failure)
        case "reasoning":
            return CodexRuntimeItem(
                id: id,
                kind: .reasoning,
                title: "reasoning",
                status: status,
                isFailure: failure)
        case "userMessage", "agentMessage":
            return nil
        default:
            return CodexRuntimeItem(
                id: id,
                kind: .other,
                title: type,
                status: status,
                isFailure: failure)
        }
    }

    private func completeTurn(_ result: CodexRuntimeTurnResult) {
        if activeTurnID == result.turnID {
            activeTurnID = nil
        }
        let clearedApprovalIDs = pendingApprovals.compactMap {
            requestID, request in
            request.turnID == result.turnID ? requestID : nil
        }
        for requestID in clearedApprovalIDs {
            pendingApprovals.removeValue(forKey: requestID)
            emit(.approvalResolved(requestID))
        }
        terminalTurns[result.turnID] = result
        terminalTurnOrder.append(result.turnID)
        while terminalTurnOrder.count > 8 {
            let removed = terminalTurnOrder.removeFirst()
            terminalTurns.removeValue(forKey: removed)
        }
        emit(.turnCompleted(result))
        let waiters = turnWaiters.removeValue(forKey: result.turnID) ?? []
        for waiter in waiters {
            do {
                waiter.resume(returning: try Self.validated(result))
            } catch {
                waiter.resume(throwing: error)
            }
        }
    }

    private static func validated(
        _ result: CodexRuntimeTurnResult
    ) throws -> CodexRuntimeTurnResult {
        guard result.succeeded else {
            throw CodexRuntimeError.turnFailed(
                result.errorMessage ?? result.status)
        }
        return result
    }

    private func emitTurnStartedIfNeeded(_ turnID: String) {
        guard emittedTurnStarts.insert(turnID).inserted else { return }
        emit(.turnStarted(turnID))
    }

    private func emit(_ event: CodexRuntimeEvent) {
        var dropped = false
        for continuation in eventContinuations.values {
            if case .dropped = continuation.yield(event) {
                dropped = true
            }
        }
        guard dropped, !isFailingEventBuffer else { return }
        isFailingEventBuffer = true
        let error = CodexRuntimeError.malformedProtocol(
            "the App Server event consumer exceeded its 4096-event buffer")
        for continuation in eventContinuations.values {
            _ = continuation.yield(.runtimeError(
                code: "codex_event_backpressure",
                message: error.localizedDescription,
                fatal: true))
            continuation.finish()
        }
        eventContinuations.removeAll()
        Task {
            await self.stopProcess(after: error)
            self.finishEventStreams()
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func finishEventStreams() {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func processDidTerminate(status: Int32) {
        guard process != nil else { return }
        // `stopProcess` retains both the Process object and the session flock
        // until it has observed an actual exit. Its polling path owns cleanup
        // while this flag is set, so the termination callback must not release
        // the lock early or emit a second terminal error.
        guard !isStoppingProcess else { return }
        let error = CodexRuntimeError.processTerminated(
            status,
            bounded(redact(stderrDiagnostic), limit: 2_048))
        process = nil
        standardInput = nil
        runtimeIdentity = nil
        processLease?.release()
        processLease = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        let responses = pendingResponses.values
        pendingResponses.removeAll()
        for pending in responses {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        let waiters = turnWaiters.values.flatMap { $0 }
        turnWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: error)
        }
        let approvalIDs = Array(pendingApprovals.keys)
        pendingApprovals.removeAll()
        for requestID in approvalIDs {
            emit(.approvalResolved(requestID))
        }
        activeTurnID = nil
        if !isShuttingDown {
            emit(.runtimeError(
                code: "codex_runtime_exited",
                message: error.localizedDescription,
                fatal: true))
            finishEventStreams()
        }
    }

    private func stopProcess(after error: Error?) async {
        // Actor reentrancy allows shutdown to arrive while a protocol-failure
        // stop is sleeping. The first stop remains authoritative and retains
        // the process lease until exit; later calls only need their caller to
        // finish its own UI/event lifecycle.
        guard !isStoppingProcess else { return }
        isStoppingProcess = true
        let terminationError = error ?? CodexRuntimeError.notStarted
        let responses = pendingResponses.values
        pendingResponses.removeAll()
        for pending in responses {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: terminationError)
        }
        let waiters = turnWaiters.values.flatMap { $0 }
        turnWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: terminationError)
        }
        let approvalIDs = Array(pendingApprovals.keys)
        pendingApprovals.removeAll()
        for requestID in approvalIDs {
            emit(.approvalResolved(requestID))
        }
        activeTurnID = nil
        runtimeIdentity = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        try? standardInput?.close()
        standardInput = nil
        let runningProcess = process
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
            var exited = await waitForProcessExit(runningProcess)
            if !exited {
                Self.forceTerminate(runningProcess)
                exited = await waitForProcessExit(runningProcess)
            }
            if !exited {
                // A process in an uninterruptible kernel state must continue
                // holding the CODEX_HOME flock. Retire it in a self-retaining
                // background task instead of claiming shutdown completed and
                // allowing a second owner into the same session directory.
                beginDeferredProcessRetirement(runningProcess)
                return
            }
        }
        finishStoppedProcess(runningProcess)
    }

    private func waitForProcessExit(
        _ runningProcess: Process
    ) async -> Bool {
        for _ in 0..<100 {
            if !runningProcess.isRunning { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !runningProcess.isRunning
    }

    private static func forceTerminate(_ runningProcess: Process) {
        let pid = runningProcess.processIdentifier
        guard pid > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(pid, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(pid, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(pid, SIGKILL)
        #else
        runningProcess.terminate()
        #endif
    }

    private func beginDeferredProcessRetirement(
        _ runningProcess: Process
    ) {
        deferredProcessRetirement = Task { [self] in
            while runningProcess.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finishStoppedProcess(runningProcess)
        }
    }

    private func finishStoppedProcess(_ runningProcess: Process?) {
        if let runningProcess,
           let process,
           process !== runningProcess {
            return
        }
        process = nil
        isStoppingProcess = false
        processLease?.release()
        processLease = nil
        deferredProcessRetirement = nil
    }

    private func failProtocol(_ message: String) {
        let error = CodexRuntimeError.malformedProtocol(
            bounded(redact(message)))
        emit(.runtimeError(
            code: "codex_protocol",
            message: error.localizedDescription,
            fatal: true))
        Task {
            await self.stopProcess(after: error)
            self.finishEventStreams()
        }
    }

    private func redact(_ value: String) -> String {
        let secret = configuration.route.bearerToken
        guard !secret.isEmpty else { return value }
        return value.replacingOccurrences(
            of: secret,
            with: "<redacted>")
    }

    private func bounded(_ value: String, limit: Int = 32_768) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func threadID(from result: JSONValue) throws -> String {
        guard let threadID = result.objectValue?["thread"]?
            .objectValue?["id"]?.stringValue,
              !threadID.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "thread response is missing thread.id")
        }
        return threadID
    }

    private static func fileChangePaths(
        from value: JSONValue?
    ) -> [String] {
        (value?.arrayValue ?? []).compactMap { change in
            guard let object = change.objectValue else { return nil }
            return object["path"]?.stringValue
                ?? object["file"]?.stringValue
        }
    }

    private static func byteStream(
        from handle: FileHandle
    ) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integralIntValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
