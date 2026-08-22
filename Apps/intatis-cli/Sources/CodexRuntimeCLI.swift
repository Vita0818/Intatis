import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisCodexRuntime

private enum CodexCLIStyle {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"
}

private let codexCLIHelp = """
  Codex Runtime commands
  /goal <objective>          set the official Codex thread goal and run it
  /model                     show the fixed Responses model for this runtime
  /config                    show the safe runtime route summary
  /mode <chat|code|cowork>   switch Intatis surface
  /auto                      show automatic approval-review status
  /attach                    not exposed in this first CLI runtime version
  /mcp                       configure MCP through the Codex runtime (next slice)
  /clear                     start a new Intatis session from the UI (next slice)
  /help                      show this help
  /exit                      stop the runtime and quit

  The CLI uses codex app-server 0.145.0-intatis.2, an isolated CODEX_HOME, and the
  selected Intatis Responses route. ChatGPT login is never consulted.

"""

func codexRuntimeREPL(
    _ config: CLIConfig,
    mode: Mode,
    workspace: URL
) async throws -> REPLExit {
    precondition(mode == .code || mode == .cowork)
    let canonicalWorkspace = workspace
        .resolvingSymlinksInPath()
        .standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: canonicalWorkspace.path,
        isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw IntatisError.config(
            "Codex Runtime workspace is not an existing directory")
    }

    let registry = ProviderRegistry(
        config: config.providerConfig(),
        resolver: CLIExactSecretResolver(config: config))
    let route = try await registry.responsesRuntimeRoute(
        model: ModelID(rawValue: config.model))
    let identity = try codexCLISessionIdentity(
        mode: mode,
        workspace: canonicalWorkspace)
    let runtime = CodexAppServerSession(configuration:
        CodexRuntimeConfiguration(
            sessionID: identity.sessionID,
            mode: mode == .cowork ? .cowork : .code,
            workspaceURL: canonicalWorkspace,
            runtimeRootURL: identity.runtimeRoot,
            route: route,
            approvalReviewer: .automatic,
            reasoningEffort: config.reasoningEffort?.rawValue
                ?? route.reasoningEffort))
    let events = await runtime.events()
    let eventTask = Task {
        var streamedMessageIDs: Set<String> = []
        for await event in events {
            guard !Task.isCancelled else { return }
            switch event {
            case .ready(let identity):
                out("\(CodexCLIStyle.dim)Codex Runtime \(identity.runtimeVersion) · thread \(identity.threadID.prefix(8))… ready\(CodexCLIStyle.reset)\n")
            case .turnStarted:
                break
            case .assistantDelta(let itemID, let text):
                streamedMessageIDs.insert(itemID)
                out(text)
            case .assistantCompleted(let itemID, let text):
                if streamedMessageIDs.remove(itemID) != nil {
                    out("\n")
                } else {
                    out(text + "\n")
                }
            case .reasoningDelta:
                break
            case .itemStarted(let item):
                let detail = item.detail.isEmpty
                    ? ""
                    : " · \(item.detail)"
                out("\n\(CodexCLIStyle.dim)[\(item.title)\(detail)]\(CodexCLIStyle.reset)\n")
            case .itemCompleted(let item):
                if item.isFailure {
                    errOut("[\(item.title) · \(item.status ?? "failed")]\n")
                }
            case .approvalRequested(let request):
                out("\n\(CodexCLIStyle.yellow)Permission · \(request.title)\(CodexCLIStyle.reset)\n")
                out(request.summary + "\n")
                out("Approve? [y]es / [a]lways this session / [n]o / [c]ancel turn: ")
                let answer = Swift.readLine()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? "n"
                let decision: CodexRuntimeApprovalDecision
                switch answer {
                case "y", "yes": decision = .accept
                case "a", "always": decision = .acceptForSession
                case "c", "cancel": decision = .cancel
                default: decision = .decline
                }
                do {
                    try await runtime.resolveApproval(
                        requestID: request.requestID,
                        decision: decision)
                } catch {
                    errOut("approval failed: \(error.localizedDescription)\n")
                }
            case .approvalResolved:
                break
            case .turnCompleted:
                break
            case .runtimeError(_, let message, _):
                errOut("runtime: \(message)\n")
            }
        }
    }
    do {
        _ = try await runtime.start()
    } catch {
        eventTask.cancel()
        await runtime.shutdown()
        throw error
    }

    let editor = LineEditor()
    out("\n\(CodexCLIStyle.bold)Intatis\(CodexCLIStyle.reset) \(CodexCLIStyle.dim)·\(CodexCLIStyle.reset) \(CodexCLIStyle.cyan)\(mode.rawValue)\(CodexCLIStyle.reset) \(CodexCLIStyle.dim)· Codex Runtime · \(config.model)\(CodexCLIStyle.reset)\n")
    out("\(CodexCLIStyle.dim)/help for commands · /mode to switch · /exit to quit\(CodexCLIStyle.reset)\n")

    func finish(_ result: REPLExit) async -> REPLExit {
        eventTask.cancel()
        await runtime.shutdown()
        await eventTask.value
        return result
    }

    while true {
        let line: String
        switch editor.readLine(
            prompt: "\n\(CodexCLIStyle.green)\(mode.rawValue) ❯\(CodexCLIStyle.reset) ") {
        case .eof, .shortcut(.exit):
            return await finish(.quit)
        case .shortcut(.cycleMode):
            return await finish(.switchTo(codexNextMode(mode)))
        case .shortcut(.switchModel):
            out("model is fixed to the selected Intatis Responses route for this runtime: \(config.model)\n")
            continue
        case .shortcut(.settings):
            try runSettings()
            out("settings saved — restart this runtime to apply route changes\n")
            continue
        case .text(let value):
            line = value
        }
        let text = line.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(
                separator: " ",
                maxSplits: 1).map(String.init)
            let command = parts.first?.lowercased() ?? ""
            let argument = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces)
                : ""
            switch command {
            case "help":
                out(codexCLIHelp)
                continue
            case "exit", "quit":
                return await finish(.quit)
            case "mode":
                guard let next = Mode(rawValue: argument.lowercased()) else {
                    out("usage: /mode chat|code|cowork\n")
                    continue
                }
                if next == mode {
                    out("already in \(mode.rawValue)\n")
                    continue
                }
                return await finish(.switchTo(next))
            case "model":
                out("model: \(config.model) · Responses API\n")
                continue
            case "config":
                out("\(config.selectedRouteLabel) · endpoint hidden · model \(config.model) · Codex Runtime \(CodexAppServerSession.pinnedRuntimeVersion)\n")
                continue
            case "auto":
                out("approval reviewer: Codex auto_review\n")
                continue
            case "attach":
                out("attachments are not exposed by this first CLI Codex Runtime slice; macOS Code/Cowork image attachments are supported\n")
                continue
            case "mcp":
                out("Intatis MCP projection is not bridged in this first slice; use Codex Runtime MCP configuration in the next integration slice\n")
                continue
            case "clear":
                out("/clear is intentionally unavailable until App Server thread replacement is wired without deleting history\n")
                continue
            case "goal":
                guard !argument.isEmpty else {
                    out("usage: /goal <objective>\n")
                    continue
                }
                do {
                    try await runtime.setGoal(objective: argument)
                    _ = try await runtime.runTurn(text: argument)
                } catch {
                    errOut("error: \(error.localizedDescription)\n")
                }
                continue
            default:
                out("unknown command /\(command) — /help\n")
                continue
            }
        }

        do {
            _ = try await runtime.runTurn(text: text)
        } catch {
            errOut("error: \(error.localizedDescription)\n")
        }
    }
}

private func codexNextMode(_ mode: Mode) -> Mode {
    switch mode {
    case .chat: return .code
    case .code: return .cowork
    case .cowork: return .chat
    }
}

private struct CodexCLISessionIdentity {
    let sessionID: SessionID
    let runtimeRoot: URL
}

private func codexCLISessionIdentity(
    mode: Mode,
    workspace: URL
) throws -> CodexCLISessionIdentity {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in "\(mode.rawValue):\(workspace.path)".utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    let key = String(hash, radix: 16)
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true)
    let root = support
        .appendingPathComponent("Intatis", isDirectory: true)
        .appendingPathComponent("cli", isDirectory: true)
        .appendingPathComponent(
            "codex_\(mode.rawValue)_\(key)",
            isDirectory: true)
    return CodexCLISessionIdentity(
        sessionID: SessionID(
            rawValue: "\(mode.rawValue)_cli_\(key)"),
        runtimeRoot: root)
}
