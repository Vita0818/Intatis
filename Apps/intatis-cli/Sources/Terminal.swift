import Foundation
import IntatisCore
import IntatisProtocol
import IntatisConversation
import IntatisAgentKernel

func out(_ s: String) { try? FileHandle.standardOutput.write(contentsOf: Data(s.utf8)) }
func errOut(_ s: String) { try? FileHandle.standardError.write(contentsOf: Data(s.utf8)) }

private func truncate(_ s: String, _ n: Int) -> String {
    s.count > n ? String(s.prefix(n)) + "…" : s
}

/// First line only, hard-capped — for collapsed one-liners.
private func oneLine(_ s: String, _ n: Int) -> String {
    let first = s.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return first.count > n ? String(first.prefix(n)) + "…" : first
}

/// Collapsed tool / terminal output: first line, plus a "(+N 行)" hint if multiline.
private func summary(_ s: String) -> String {
    let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    let head = oneLine(s, 72)
    let extra = lines.count - 1
    return extra > 0 ? "\(head)  (+\(extra) 行，/verbose 看全部)" : head
}

/// Shared, mutable render verbosity. Collapsed by default; `/verbose` flips it.
final class RenderOptions: @unchecked Sendable {
    private let lock = NSLock()
    private var _verbose: Bool
    init(verbose: Bool = false) { _verbose = verbose }
    var verbose: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _verbose }
        set { lock.lock(); _verbose = newValue; lock.unlock() }
    }
}

// Minimal ANSI helpers.
private let dim = "\u{001B}[2m", cyan = "\u{001B}[36m", yellow = "\u{001B}[33m"
private let magenta = "\u{001B}[35m", red = "\u{001B}[31m", reset = "\u{001B}[0m"

/// Streams events from the log to stdout as they arrive. It only writes stdout
/// (never reads stdin), so it runs concurrently with the input loop and the
/// permission prompt with no contention.
func renderLoop(_ log: EventLog, showAgentLabels: Bool = false, spinner: TurnSpinner? = nil,
                options: RenderOptions = RenderOptions()) async {
    let stream = await log.stream(from: 0)
    var currentMessage = ""
    for await env in stream {
        // Keep the "Thinking…" line alive through the pre-output events
        // (user_message, agent_status); stop it only when real output arrives.
        switch env.event {
        case .userMessage, .agentStatus: break
        default: spinner?.stop()
        }
        switch env.event {
        case .messageDelta(let p):
            if showAgentLabels, let agent = p.agent, p.messageId.rawValue != currentMessage {
                out("\n\(cyan)● \(agent.rawValue)\(reset)\n")
                currentMessage = p.messageId.rawValue
            }
            out(p.textDelta)
        case .messageCompleted:
            out("\n")
        case .toolCall(let p):
            let args = options.verbose ? truncate(p.args, 800) : oneLine(p.args, 72)
            out("\n  \(cyan)· \(p.name)\(reset) \(dim)\(args)\(reset)\n")
        case .toolResult(let p):
            if options.verbose {
                out("  \(dim)⎿\(reset) \(truncate(p.observation, 4000))\n")
            } else {
                out("  \(dim)⎿ \(summary(p.observation))\(reset)\n")
            }
        case .permissionResolved(let p):
            out("  \(yellow)[\(p.decision.rawValue): \(p.tool) — \(p.reason)]\(reset)\n")
        case .patchProposed(let p):
            out("  \(magenta)± patch: \(p.files.joined(separator: ", "))\(reset)\n")
        case .agentToAgentMessage(let p):
            out("  \(cyan)↔ \(p.from.rawValue)→\(p.to.rawValue):\(reset) \(truncate(p.content, 300))\n")
        case .artifactAdded(let p):
            out("  📎 \(p.kind): \(p.path)\n")
        case .turnStats(let p):
            var parts: [String] = []
            if let total = p.totalMillis { parts.append(String(format: "%.1fs", Double(total) / 1000)) }
            if let ttft = p.ttftMillis { parts.append("ttft \(String(format: "%.2fs", Double(ttft) / 1000))") }
            if let tot = p.totalTokens {
                if let pin = p.promptTokens, let pout = p.completionTokens {
                    parts.append("\(tot) tok (\(pin) in / \(pout) out)")
                } else {
                    parts.append("\(tot) tok")
                }
            }
            if !parts.isEmpty { out("  \(dim)⎿ \(parts.joined(separator: " · "))\(reset)\n") }
        case .error(let p):
            out("  \(red)! \(p.message)\(reset)\n")
        default:
            break
        }
    }
}

/// Terminal approval for `ask_user` decisions (Code mode).
struct TerminalResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        out("\n  \(yellow)⚠ \(request.tool) (\(request.risk.rawValue)) — \(request.reason)\(reset)\n  approve? [y/N] ")
        guard let line = readLine() else { return .deny }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        return (answer == "y" || answer == "yes") ? .allow : .deny
    }
}
