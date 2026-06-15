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

// Minimal ANSI helpers.
private let dim = "\u{001B}[2m", cyan = "\u{001B}[36m", yellow = "\u{001B}[33m"
private let magenta = "\u{001B}[35m", red = "\u{001B}[31m", reset = "\u{001B}[0m"

/// Streams events from the log to stdout as they arrive. It only writes stdout
/// (never reads stdin), so it runs concurrently with the input loop and the
/// permission prompt with no contention.
func renderLoop(_ log: EventLog) async {
    let stream = await log.stream(from: 0)
    for await env in stream {
        switch env.event {
        case .messageDelta(let p):
            out(p.textDelta)
        case .messageCompleted:
            out("\n")
        case .toolCall(let p):
            out("\n  \(cyan)· \(p.name)\(reset) \(dim)\(truncate(p.args, 200))\(reset)\n")
        case .toolResult(let p):
            out("  → \(truncate(p.observation, 400))\n")
        case .permissionResolved(let p):
            out("  \(yellow)[\(p.decision.rawValue): \(p.tool) — \(p.reason)]\(reset)\n")
        case .patchProposed(let p):
            out("  \(magenta)± patch: \(p.files.joined(separator: ", "))\(reset)\n")
        case .agentToAgentMessage(let p):
            out("  \(cyan)↔ \(p.from.rawValue)→\(p.to.rawValue):\(reset) \(truncate(p.content, 300))\n")
        case .artifactAdded(let p):
            out("  📎 \(p.kind): \(p.path)\n")
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
