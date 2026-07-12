import Foundation
import IntatisCore
import IntatisProtocol

/// Layer A: pure, deterministic, model-free. Runs first and its `deny` is final
/// (ARCHITECTURE.md §6.1–§6.2). Encodes hard rules and only returns `pass` for
/// non-shell operations that remain eligible for an optional reviewer/user gate.
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

        // 2. Shell-backed tools must be checked for shell availability before
        // generic network handling, otherwise an exec tool that also touches the
        // network could bypass App Store / read-only shell denial.
        if call.sideEffect == .exec {
            return evaluateShell(call, ctx)
        }

        // 3. Network: never silently; denied in read-only.
        if call.risksNetwork {
            if call.sideEffect == .destructive {
                return ctx.profile == .readOnly
                    ? .deny(reason: "network not allowed in read_only", risk: .high)
                    : .ask(reason: "destructive network operation requested", risk: .high)
            }
            return ctx.profile == .readOnly
                ? .deny(reason: "network not allowed in read_only", risk: .medium)
                : .ask(reason: "network access requested", risk: .medium)
        }

        // 4. By side effect.
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
        if call.risksNetwork {
            return .ask(reason: "browser or shell-backed network access requested", risk: .high)
        }
        let command = Self.shellCommand(from: call.rawArgs)
        if ShellInspector.isDangerous(command) {
            return .deny(reason: "dangerous shell command", risk: .high)
        }
        if ShellInspector.risksNetworkOrInstall(command) {
            return .ask(reason: "shell command may access network or install packages", risk: .high)
        }
        switch ShellInspector.inspectReadOnlyCommand(command, workspaceRoot: ctx.workspaceRoot) {
        case .allow(let reason):
            return .allow(reason: reason, risk: .low)
        case .deny(let reason):
            return .deny(reason: reason, risk: .high)
        case .ask:
            break
        }
        return .ask(reason: "run shell command", risk: .medium)
    }

    private func evaluateWrite(_ call: ToolCallContext, _ ctx: PermissionContext) -> GateResult {
        if ctx.profile == .readOnly {
            return .deny(reason: "writes not allowed in read_only", risk: .medium)
        }
        if call.touchedPaths.contains(where: SecretScanner.isProtectedConfigPath) {
            return .ask(reason: "modifies lockfile / CI / build config", risk: .high)
        }
        switch ctx.profile {
        case .manual, .reviewed, .autopilot:
            return .ask(reason: "write to workspace", risk: .medium)
        case .readOnly, .locked:
            return .deny(reason: "writes not allowed", risk: .medium)
        }
    }

    static func shellCommand(from rawArgs: String) -> String {
        struct A: Decodable { let command: String? }
        return (try? JSONDecoder().decode(A.self, from: Data(rawArgs.utf8)))?.command ?? ""
    }
}
