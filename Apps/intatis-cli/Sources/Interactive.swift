import Foundation
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisTools
import IntatisPermission
import IntatisAgentKernel
import IntatisCowork

enum REPLExit { case quit; case switchTo(Mode) }

private enum S {
    static let reset = "\u{001B}[0m", bold = "\u{001B}[1m", dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m", cyan = "\u{001B}[36m"
}

private func banner(mode: Mode, model: String, host: String) {
    out("\n\(S.bold)Intatis\(S.reset) \(S.dim)·\(S.reset) \(S.cyan)\(mode.rawValue)\(S.reset) \(S.dim)· \(model) · \(host)\(S.reset)\n")
    out("\(S.dim)/help for commands · /mode to switch · /exit to quit\(S.reset)\n")
}

private func prompt(_ mode: Mode) -> String {
    "\n\(S.green)\(mode.rawValue) ❯\(S.reset) "
}

/// Ctrl-A cycles chat → code → cowork → chat.
private func nextMode(_ m: Mode) -> Mode {
    switch m { case .chat: return .code; case .code: return .cowork; case .cowork: return .chat }
}

/// Strip surrounding [] '' "" that users sometimes copy from `[model]`-style help.
private func unbracket(_ s: String) -> String {
    var r = Substring(s)
    while let f = r.first, "[]\"'".contains(f) { r = r.dropFirst() }
    while let l = r.last, "[]\"'".contains(l) { r = r.dropLast() }
    return String(r)
}

func sessionLog() throws -> EventLog {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-cli-\(UUID().uuidString)", isDirectory: true)
    return try EventLog(session: SessionID.new(), fileURL: dir.appendingPathComponent("events.jsonl"))
}

/// Top-level mode driver: runs the current mode's REPL and relaunches when a
/// `/mode` command asks to switch (so chat ⇄ code ⇄ cowork is live).
func runMode(_ config: CLIConfig, mode startMode: Mode, workspace: URL) async throws {
    var mode = startMode
    while true {
        let exit: REPLExit
        switch mode {
        case .chat, .code: exit = try await chatCodeREPL(config, mode: mode, workspace: workspace)
        case .cowork:      exit = try await coworkREPL(config, workspace: workspace)
        }
        switch exit {
        case .quit: return
        case .switchTo(let next): mode = next
        }
    }
}

private let replHelp = """
  /attach <path>            queue an image (vision) or text file for the next message
  /attach clear             clear queued attachments
  /model [name]             show or switch the model for this session
  /reasoning [level|off]    show or set reasoning (minimal|low|medium|high)
  /verbose [on|off]         expand tool calls & terminal output (default: collapsed)
  /mode <chat|code|cowork>  switch mode
  /clear                    start a fresh session (clears history)
  /config                   show endpoint / model / reasoning
  /help                     this help
  /exit                     quit

  Keys: ←/→ cursor · Home/End jump · ↑/↓ history · Ctrl-U/K/W edit
        Ctrl-A mode · Ctrl-L model · Ctrl-S settings · Ctrl-C quit

"""

private func chatCodeREPL(_ config: CLIConfig, mode: Mode, workspace: URL) async throws -> REPLExit {
    let registry = ProviderRegistry(config: config.providerConfig(), resolver: StaticSecretResolver(key: config.apiKey))
    var model = config.model
    var reasoning = config.reasoningEffort
    var pending = PendingAttachments()
    var log = try sessionLog()
    let spinner = TurnSpinner()
    let editor = LineEditor()
    let options = RenderOptions()
    var render = Task { await renderLoop(log, spinner: spinner, options: options) }
    defer { render.cancel(); spinner.stop() }

    banner(mode: mode, model: model, host: config.baseURL.host ?? config.baseURL.absoluteString)

    while true {
        if !pending.isEmpty {
            out("\(S.dim)  \(pending.count) attachment(s) queued for your next message\(S.reset)\n")
        }
        let line: String
        switch editor.readLine(prompt: prompt(mode)) {
        case .eof: return .quit
        case .shortcut(.exit): return .quit
        case .shortcut(.cycleMode): return .switchTo(nextMode(mode))
        case .shortcut(.switchModel):
            if case .text(let m) = editor.readLine(prompt: "\(S.green)model ❯\(S.reset) ") {
                let name = unbracket(m.trimmingCharacters(in: .whitespaces))
                if !name.isEmpty { model = name; out("model → \(model)\n") }
            }
            continue
        case .shortcut(.settings):
            try runSettings(); out("(settings saved — restart to apply endpoint/model changes)\n")
            continue
        case .text(let l): line = l
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let cmd = parts.first ?? ""
            let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch cmd {
            case "help":
                out(replHelp)
            case "exit", "quit":
                return .quit
            case "model":
                if arg.isEmpty { out("model: \(model)\n") } else { model = arg; out("model → \(model)\n") }
            case "reasoning":
                if arg.isEmpty {
                    out("reasoning: \(reasoning?.rawValue ?? "off")\n")
                } else if arg.lowercased() == "off" {
                    reasoning = nil; out("reasoning → off\n")
                } else if let r = ReasoningEffort(rawValue: arg.lowercased()) {
                    reasoning = r; out("reasoning → \(r.rawValue)\n")
                } else {
                    out("usage: /reasoning minimal|low|medium|high|off\n")
                }
            case "verbose":
                if arg.lowercased() == "off" { options.verbose = false }
                else if arg.lowercased() == "on" { options.verbose = true }
                else { options.verbose.toggle() }
                out("verbose → \(options.verbose ? "on" : "off")\n")
            case "mode":
                if let m = Mode(rawValue: arg.lowercased()) {
                    if m == mode { out("already in \(m.rawValue)\n") } else { return .switchTo(m) }
                } else {
                    out("usage: /mode chat|code|cowork\n")
                }
            case "attach":
                if arg.isEmpty || arg == "list" {
                    out(pending.isEmpty ? "no attachments queued. usage: /attach <path>\n"
                                        : "\(pending.count) queued (\(pending.images.count) image, \(pending.textFiles.count) text)\n")
                } else if arg == "clear" {
                    pending.clear(); out("attachments cleared\n")
                } else {
                    switch AttachmentLoader.load(arg) {
                    case .image(let img):
                        pending.images.append(img); out("attached image · \(pending.count) queued\n")
                    case .text(let name, let content):
                        pending.textFiles.append((name, content)); out("attached \(name) · \(pending.count) queued\n")
                    case .failure(let message):
                        errOut(message + "\n")
                    }
                }
            case "clear":
                render.cancel(); log = try sessionLog(); render = Task { await renderLoop(log, spinner: spinner, options: options) }
                out("(new session)\n")
            case "config":
                out("endpoint \(config.baseURL.absoluteString) · model \(model) · reasoning \(reasoning?.rawValue ?? "off")\n")
            default:
                out("unknown command /\(cmd) — /help\n")
            }
            continue
        }

        // Compose the message, consuming any queued attachments.
        var sendText = text
        for file in pending.textFiles { sendText += "\n\n[attached file: \(file.name)]\n\(file.content)" }
        let sendImages = pending.images
        pending.clear()

        spinner.start()
        do {
            switch mode {
            case .chat:
                let provider = try await registry.defaultChatProvider()
                try await ChatLoop(log: log, provider: provider, model: ModelID(rawValue: model),
                                   reasoningEffort: reasoning, includeUsage: config.includeUsage)
                    .send(sendText, images: sendImages)
            case .code:
                let provider = try await registry.defaultAgentProvider()
                let agent = Agent(name: AgentID(rawValue: "cli"), workspaceRoot: workspace,
                                  model: ModelID(rawValue: model), profile: .reviewed)
                _ = try await AgentLoop(log: log, provider: provider, registry: .standard(),
                                        engine: PermissionEngine(), responder: TerminalResponder(),
                                        agent: agent, allowsShell: true,
                                        imageGenerator: ProviderImageGenerationToolService(registry: registry),
                                        reasoningEffort: reasoning, includeUsage: config.includeUsage,
                                        maxIterations: config.maxSteps)
                    .send(sendText, images: sendImages)
            case .cowork:
                break
            }
        } catch {
            errOut("error: \(error.localizedDescription)\n")
        }
        spinner.stop()
    }
}

private let coworkHelp = """
  Just talk to @main — it can spawn / list / remove its own helper agents.
  /agent add <name> <path> [model]   manually attach an agent (optional model)
  /agent remove <name>               detach an agent
  /agents                            list attached agents
  /auto                              enable automatic permission review
  /default                           disable automatic permission review
  /model [name]                      default model for newly added agents
  /verbose [on|off]                  expand tool calls & terminal output
  /attach <path>                     queue an image/text file for the next message
  @name <message>                    send to a specific agent
  <message>                          send to @main
  /mode <chat|code|cowork>           switch mode
  /help   /exit

  Keys: ←/→ cursor · Home/End jump · ↑/↓ history · Ctrl-U/K/W edit
        Ctrl-A mode · Ctrl-L model · Ctrl-S settings · Ctrl-C quit

"""

private func coworkREPL(_ config: CLIConfig, workspace: URL) async throws -> REPLExit {
    let registry = ProviderRegistry(config: config.providerConfig(), resolver: StaticSecretResolver(key: config.apiKey))
    var defaultModel = config.model
    var pending = PendingAttachments()
    let log = try sessionLog()
    let spinner = TurnSpinner()
    let editor = LineEditor()
    let options = RenderOptions()
    let render = Task { await renderLoop(log, showAgentLabels: true, spinner: spinner, options: options) }
    defer { render.cancel(); spinner.stop() }

    let orchestrator = Orchestrator(
        log: log, allowsShell: true, responder: TerminalResponder(),
        reasoningEffort: config.reasoningEffort, includeUsage: config.includeUsage,
        maxSteps: config.maxSteps,
        imageGeneratorFor: { _ in ProviderImageGenerationToolService(registry: registry) }
    ) { _ in try await registry.defaultAgentProvider() }

    // A default agent so you can just talk; add more with /agent add.
    let mainAttached = await orchestrator.attach(Agent(name: AgentID(rawValue: "main"), workspaceRoot: workspace,
                                                       model: ModelID(rawValue: defaultModel), profile: .reviewed,
                                                       coordinationDepth: Agent.defaultCoordinationDepth))

    banner(mode: .cowork, model: defaultModel, host: config.baseURL.host ?? config.baseURL.absoluteString)
    if mainAttached {
        out("\(S.dim)@main is ready in \(workspace.lastPathComponent) — just describe the task; it can spawn its own helper agents. /agents to list · /help\(S.reset)\n")
    } else {
        out("\(S.dim)@main was not attached. Use /agent add <name> <path> after approving a workspace. /help\(S.reset)\n")
    }

    while true {
        if !pending.isEmpty {
            out("\(S.dim)  \(pending.count) attachment(s) queued for your next message\(S.reset)\n")
        }
        let line: String
        switch editor.readLine(prompt: prompt(.cowork)) {
        case .eof: return .quit
        case .shortcut(.exit): return .quit
        case .shortcut(.cycleMode): return .switchTo(nextMode(.cowork))
        case .shortcut(.switchModel):
            if case .text(let m) = editor.readLine(prompt: "\(S.green)model ❯\(S.reset) ") {
                let name = unbracket(m.trimmingCharacters(in: .whitespaces))
                if !name.isEmpty { defaultModel = name; out("default model for new agents → \(defaultModel)\n") }
            }
            continue
        case .shortcut(.settings):
            try runSettings(); out("(settings saved — restart to apply)\n")
            continue
        case .text(let l): line = l
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ").map(String.init)
            let cmd = parts.first ?? ""
            switch cmd {
            case "help":
                out(coworkHelp)
            case "exit", "quit":
                return .quit
            case "mode":
                if parts.count > 1, let m = Mode(rawValue: parts[1].lowercased()) { return .switchTo(m) }
                else { out("usage: /mode chat|code|cowork\n") }
            case "model":
                if parts.count > 1 { defaultModel = parts[1]; out("default model for new agents → \(defaultModel)\n") }
                else { out("default model for new agents: \(defaultModel)\n") }
            case "verbose":
                if parts.count > 1, parts[1].lowercased() == "off" { options.verbose = false }
                else if parts.count > 1, parts[1].lowercased() == "on" { options.verbose = true }
                else { options.verbose.toggle() }
                out("verbose → \(options.verbose ? "on" : "off")\n")
            case "agents":
                let list = await orchestrator.agentList()
                if list.isEmpty { out("(no agents attached)\n") }
                else { for a in list { out("  @\(a.name.rawValue)  \(S.dim)\(a.model.rawValue) · \(a.workspaceRoot.path)\(S.reset)\n") } }
            case "auto":
                let result = await orchestrator.enableAutomaticPermissionReview(
                    model: ModelID(rawValue: defaultModel),
                    workspaceRoot: workspace)
                switch result {
                case .enabled(let id):
                    out("automatic permission review → on (@\(id.rawValue), model \(defaultModel))\n")
                case .alreadyEnabled(let id):
                    out("automatic permission review already on (@\(id.rawValue))\n")
                case .failed(let message):
                    out("automatic permission review not enabled: \(message)\n")
                }
            case "default":
                let disabled = await orchestrator.disableAutomaticPermissionReview()
                out(disabled
                    ? "automatic permission review → off\n"
                    : "automatic permission review already off\n")
            case "attach":
                if parts.count < 2 || parts[1] == "list" {
                    out(pending.isEmpty ? "no attachments queued. usage: /attach <path>\n" : "\(pending.count) queued\n")
                } else if parts[1] == "clear" {
                    pending.clear(); out("attachments cleared\n")
                } else {
                    switch AttachmentLoader.load(parts[1]) {
                    case .image(let img): pending.images.append(img); out("attached image · \(pending.count) queued\n")
                    case .text(let name, let content): pending.textFiles.append((name, content)); out("attached \(name) · \(pending.count) queued\n")
                    case .failure(let message): errOut(message + "\n")
                    }
                }
            case "agent":
                if parts.count >= 4, parts[1] == "add" {
                    let name = parts[2]
                    let path = parts[3]
                    let model = parts.count >= 5 ? unbracket(parts[4]) : defaultModel
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                    let attached = await orchestrator.attach(Agent(name: AgentID(rawValue: name), workspaceRoot: url,
                                                                   model: ModelID(rawValue: model), profile: .reviewed,
                                                                   coordinationDepth: Agent.defaultCoordinationDepth))
                    out(attached
                        ? "attached @\(name) · \(model) · \(url.path)\n"
                        : "not attached @\(name) · \(url.path)\n")
                } else if parts.count >= 3, parts[1] == "remove" {
                    await orchestrator.detach(AgentID(rawValue: parts[2]))
                    out("removed @\(parts[2])\n")
                } else {
                    out("usage: /agent add <name> <path> [model]  |  /agent remove <name>\n")
                }
            default:
                out("unknown command /\(cmd) — /help\n")
            }
            continue
        }

        // Determine target agent + message, consuming any queued attachments.
        // No @mention → the default @main agent.
        var target: AgentID? = AgentID(rawValue: "main")
        var message = text
        if text.hasPrefix("@") {
            let bits = String(text.dropFirst()).split(separator: " ", maxSplits: 1).map(String.init)
            target = AgentID(rawValue: bits.first ?? "")
            message = bits.count > 1 ? bits[1] : ""
        }
        for file in pending.textFiles { message += "\n\n[attached file: \(file.name)]\n\(file.content)" }
        let images = pending.images
        pending.clear()
        spinner.start()
        await orchestrator.send(message, to: target, images: images)
        spinner.stop()
    }
}
