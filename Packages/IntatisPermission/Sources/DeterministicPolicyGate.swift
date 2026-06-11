import Foundation
import IntatisCore
import IntatisProtocol

/// Layer A: pure, deterministic, model-free. Runs first and its `deny` is final
/// (ARCHITECTURE.md §6.1–§6.2). Encodes the hard rules; everything contextual is
/// left as `pass` for the reviewer (or, in v0.2, the user).
public struct DeterministicPolicyGate: Sendable {
    public init() {}

    public func evaluate(_ call: ToolCallContext, _ ctx: PermissionContext) -> GateResult {
        // 0. Locked agent: nothing runs.
        if ctx.profile == .locked {
            return .deny(reason: "agent is locked", risk: .low)
        }

        // 1. Path rules apply to every touched path (sensitive + confinement).
        for path in call.touchedPaths {
            if SecretScanner.isSensitivePath(path) {
                return .deny(reason: "touches sensitive file: \(path)", risk: .high)
            }
            if !PathConfinement.isWithin(path, root: ctx.workspaceRoot) {
                return .deny(reason: "path escapes workspace: \(path)", risk: .high)
            }
        }

        // 2. Network: never silently; denied in read-only.
        if call.risksNetwork {
            return ctx.profile == .readOnly
                ? .deny(reason: "network not allowed in read_only", risk: .medium)
                : .ask(reason: "network access requested", risk: .medium)
        }

        // 3. By side effect.
        switch call.sideEffect {
        case .readOnly:
            return .allow(reason: "read-only operation within workspace", risk: .low)

        case .network:
            return ctx.profile == .readOnly
                ? .deny(reason: "network not allowed in read_only", risk: .medium)
                : .ask(reason: "network access requested", risk: .medium)

        case .destructive:
            return ctx.profile == .readOnly
                ? .deny(reason: "destructive operation not allowed in read_only", risk: .high)
                : .ask(reason: "destructive operation", risk: .high)

        case .exec:
            return evaluateShell(call, ctx)

        case .write:
            return evaluateWrite(call, ctx)
        }
    }

    private func evaluateShell(_ call: ToolCallContext, _ ctx: PermissionContext) -> GateResult {
        if !ctx.allowsShell {
            return .deny(reason: "shell is disabled in this build (sandbox)", risk: .high)
        }
        if ctx.profile == .readOnly {
            return .deny(reason: "shell not allowed in read_only", risk: .high)
        }
        let command = Self.shellCommand(from: call.rawArgs)
        if ShellInspector.isDangerous(command) {
            return .deny(reason: "dangerous shell command", risk: .high)
        }
        if ShellInspector.risksNetworkOrInstall(command) {
            return .ask(reason: "shell command may access network or install packages", risk: .high)
        }
        if ShellInspector.isReadOnlyCommand(command) {
            return .allow(reason: "read-only shell command", risk: .low)
        }
        switch ctx.profile {
        case .manual:
            return .ask(reason: "run shell command", risk: .medium)
        case .reviewed, .autopilot:
            return .pass(reason: "shell command", risk: .medium)
        case .readOnly, .locked:
            return .deny(reason: "shell not allowed", risk: .high)
        }
    }

    private func evaluateWrite(_ call: ToolCallContext, _ ctx: PermissionContext) -> GateResult {
        if ctx.profile == .readOnly {
            return .deny(reason: "writes not allowed in read_only", risk: .medium)
        }
        if call.touchedPaths.contains(where: SecretScanner.isProtectedConfigPath) {
            return .ask(reason: "modifies lockfile / CI / build config", risk: .high)
        }
        switch ctx.profile {
        case .manual:
            return .ask(reason: "write to workspace", risk: .medium)
        case .reviewed, .autopilot:
            return .pass(reason: "write within workspace", risk: .low)
        case .readOnly, .locked:
            return .deny(reason: "writes not allowed", risk: .medium)
        }
    }

    static func shellCommand(from rawArgs: String) -> String {
        struct A: Decodable { let command: String? }
        return (try? JSONDecoder().decode(A.self, from: Data(rawArgs.utf8)))?.command ?? ""
    }
}
