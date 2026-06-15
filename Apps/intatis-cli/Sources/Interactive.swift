import Foundation
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisTools
import IntatisPermission
import IntatisAgentKernel
import IntatisCowork

enum REPLExit { case quit; case switchTo(Mode) }

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
  /model [name]             show or switch the model for this session
  /reasoning [level|off]    show or set reasoning (minimal|low|medium|high)
  /mode <chat|code|cowork>  switch mode
  /clear                    start a fresh session (clears history)
  /config                   show endpoint / model / reasoning
  /help                     this help
  /exit                     quit

"""

private func chatCodeREPL(_ config: CLIConfig, mode: Mode, workspace: URL) async throws -> REPLExit {
    let registry = ProviderRegistry(config: config.providerConfig(), resolver: StaticSecretResolver(key: config.apiKey))
    var model = config.model
    var reasoning = config.reasoningEffort
    var log = try sessionLog()
    var render = Task { await renderLoop(log) }
    defer { render.cancel() }

    out("\nIntatis \(mode.rawValue) · \(model) @ \(config.baseURL.host ?? config.baseURL.absoluteString)  ·  /help\n")

    while true {
        out("\n\u{001B}[32m\(mode.rawValue)›\u{001B}[0m ")
        guard let line = readLine() else { return .quit }
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
            case "mode":
                if let m = Mode(rawValue: arg.lowercased()) {
                    if m == mode { out("already in \(m.rawValue)\n") } else { return .switchTo(m) }
                } else {
                    out("usage: /mode chat|code|cowork\n")
                }
            case "clear":
                render.cancel(); log = try sessionLog(); render = Task { await renderLoop(log) }
                out("(new session)\n")
            case "config":
                out("endpoint \(config.baseURL.absoluteString) · model \(model) · reasoning \(reasoning?.rawValue ?? "off")\n")
            default:
                out("unknown command /\(cmd) — /help\n")
            }
            continue
        }

        do {
            switch mode {
            case .chat:
                let provider = try await registry.defaultChatProvider()
                try await ChatLoop(log: log, provider: provider,
                                   model: ModelID(rawValue: model), reasoningEffort: reasoning).send(text)
            case .code:
                let provider = try await registry.defaultAgentProvider()
                let agent = Agent(name: AgentID(rawValue: "cli"), workspaceRoot: workspace,
                                  model: ModelID(rawValue: model), profile: .reviewed)
                _ = try await AgentLoop(log: log, provider: provider, registry: .standard(),
                                        engine: PermissionEngine(), responder: TerminalResponder(),
                                        agent: agent, allowsShell: true, reasoningEffort: reasoning).send(text)
            case .cowork:
                break
            }
        } catch {
            errOut("error: \(error.localizedDescription)\n")
        }
    }
}

private let coworkHelp = """
  /agent add <name> <path>   attach an agent bound to a workspace
  /agents                    list attached agents
  @name <message>            send to a specific agent
  <message>                  send to the first agent
  /mode <chat|code|cowork>   switch mode
  /help   /exit

"""

private func coworkREPL(_ config: CLIConfig, workspace: URL) async throws -> REPLExit {
    let registry = ProviderRegistry(config: config.providerConfig(), resolver: StaticSecretResolver(key: config.apiKey))
    let model = config.model
    let log = try sessionLog()
    let render = Task { await renderLoop(log) }
    defer { render.cancel() }

    let orchestrator = Orchestrator(log: log, allowsShell: true, responder: TerminalResponder()) { _ in
        try await registry.defaultAgentProvider()
    }

    out("\nIntatis cowork · attach agents: `/agent add <name> <path>`, then `@name <message>`.  ·  /help\n")

    while true {
        out("\n\u{001B}[32mcowork›\u{001B}[0m ")
        guard let line = readLine() else { return .quit }
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
            case "agents":
                let names = await orchestrator.agentNames().map { "@\($0.rawValue)" }.joined(separator: ", ")
                out(names.isEmpty ? "(no agents attached)\n" : names + "\n")
            case "agent":
                if parts.count >= 4, parts[1] == "add" {
                    let name = parts[2]
                    let path = parts[3...].joined(separator: " ")
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                    await orchestrator.attach(Agent(name: AgentID(rawValue: name), workspaceRoot: url,
                                                    model: ModelID(rawValue: model), profile: .reviewed))
                    out("attached @\(name) → \(url.path)\n")
                } else {
                    out("usage: /agent add <name> <path>\n")
                }
            default:
                out("unknown command /\(cmd) — /help\n")
            }
            continue
        }

        if text.hasPrefix("@") {
            let rest = String(text.dropFirst())
            let bits = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let name = bits.first ?? ""
            let message = bits.count > 1 ? bits[1] : ""
            await orchestrator.send(message, to: AgentID(rawValue: name))
        } else {
            await orchestrator.send(text, to: nil)
        }
    }
}
