import Foundation
import IntatisCore
import IntatisProtocol

/// Layer A: pure, deterministic, model-free. Runs first and its `deny` is final
/// (ARCHITECTURE.md §6.1–§6.2). Encodes hard rules and returns `pass` for
/// operations that require the configured model reviewer or PermissionResponder.
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

        // 2. Control-plane effects are authorized as control-plane effects,
        // never inferred as file writes from a legacy ToolDescriptor. The
        // WorkspaceLease remains an authority ceiling: a read-only caller may
        // create a read-only worker, but cannot grant read-write workspace
        // access to a child.
        if !call.intent.controlEffects.isEmpty,
           call.intent.isReadOnlyWorkspaceCompatible {
            return evaluateControlPlane(call, ctx)
        }

        // 3. Shell-backed tools must be checked for shell availability before
        // generic network handling, otherwise an exec tool that also touches the
        // network could bypass App Store / read-only shell denial.
        if call.sideEffect == .exec {
            return evaluateShell(call, ctx)
        }

        // 4. Network: never silently; denied in read-only.
        if call.risksNetwork {
            if call.sideEffect == .destructive {
                return ctx.profile == .readOnly
                    ? .deny(reason: "network not allowed in read_only", risk: .high)
                    : .pass(reason: "destructive network operation requested", risk: .high)
            }
            return ctx.profile == .readOnly
                ? .deny(reason: "network not allowed in read_only", risk: .medium)
                : .pass(reason: "network access requested", risk: .medium)
        }

        // 5. By concrete data-plane effect. Fall back to the legacy descriptor
        // only for tools that have not yet supplied richer intent metadata.
        if call.intent.dataEffects.contains(.destructive) {
            return ctx.profile == .readOnly
                ? .deny(reason: "destructive operation not allowed in read_only", risk: .high)
                : .pass(reason: "destructive operation", risk: .high)
        }
        if call.intent.dataEffects.contains(.network) {
            return ctx.profile == .readOnly
                ? .deny(reason: "network not allowed in read_only", risk: .medium)
                : .pass(reason: "network access requested", risk: .medium)
        }
        if call.intent.dataEffects.contains(.mutate) {
            return evaluateWrite(call, ctx)
        }

        switch call.sideEffect {
        case .readOnly:
            return .allow(reason: "read-only operation within workspace", risk: .low)

        case .network:
            return ctx.profile == .readOnly
                ? .deny(reason: "network not allowed in read_only", risk: .medium)
                : .pass(reason: "network access requested", risk: .medium)

        case .destructive:
            return ctx.profile == .readOnly
                ? .deny(reason: "destructive operation not allowed in read_only", risk: .high)
                : .pass(reason: "destructive operation", risk: .high)

        case .exec:
            return evaluateShell(call, ctx)

        case .write:
            return evaluateWrite(call, ctx)
        }
    }

    private func evaluateControlPlane(_ call: ToolCallContext,
                                      _ ctx: PermissionContext) -> GateResult {
        let controls = call.intent.controlEffects
        if controls.contains(.createAgent) {
            let requestedAccess = Self.stringMetadata("requestedAccess", in: call.intent)
            let grantsReadWrite = requestedAccess == WorkspaceAccess.readWrite.rawValue
                || call.intent.resources.contains { $0.access == .readWrite }
            if ctx.profile == .readOnly, grantsReadWrite {
                return .deny(
                    reason: "read-only workspace lease cannot grant read-write access to a child agent",
                    risk: .high)
            }
            let coordinates = Self.boolMetadata("canCoordinate", in: call.intent) ?? false
            let expandsWorkspace = call.intent.risks.contains(.workspaceExpansion)
            let accessDescription = requestedAccess == WorkspaceAccess.readWrite.rawValue
                ? "read-write"
                : "read-only"
            var reason = "create \(accessDescription) child agent"
            if coordinates { reason += " with coordinator capability" }
            if expandsWorkspace { reason += " in another workspace" }
            let risk: RiskLevel = (coordinates
                || expandsWorkspace
                || grantsReadWrite) ? .high : .medium
            return .pass(reason: reason, risk: risk)
        }
        if controls.contains(.attachWorkspace) {
            if ctx.profile == .readOnly,
               call.intent.resources.contains(where: { $0.access == .readWrite }) {
                return .deny(
                    reason: "read-only workspace lease cannot attach a read-write workspace",
                    risk: .high)
            }
            return .pass(reason: "attach workspace resource", risk: .high)
        }
        if controls.contains(.removeAgent) {
            return .pass(reason: "remove attached agent", risk: .medium)
        }
        if controls.contains(.delegateTask) {
            return .pass(reason: "delegate work task to an agent invocation", risk: .medium)
        }
        if controls.contains(.createTask) {
            return .pass(reason: "create work task", risk: .medium)
        }
        if controls.contains(.updateTask) {
            return .pass(reason: "update work task state", risk: .medium)
        }
        if controls.contains(.cancelTask) {
            return .pass(reason: "cancel work task", risk: .medium)
        }
        if controls.contains(.clearGoal) {
            return .pass(reason: "clear durable goal", risk: .medium)
        }
        if controls.contains(.createGoal) {
            return .pass(reason: "create durable goal", risk: .medium)
        }
        if controls.contains(.editGoal) {
            return .pass(reason: "edit durable goal", risk: .medium)
        }
        if controls.contains(.pauseGoal) {
            return .pass(reason: "pause durable goal", risk: .medium)
        }
        if controls.contains(.resumeGoal) {
            return .pass(reason: "resume durable goal", risk: .medium)
        }
        if controls.contains(.submitGoalVerdict) {
            return .pass(reason: "submit goal verification verdict", risk: .low)
        }
        if controls.contains(.grantCapability) {
            return .pass(reason: "grant agent capability", risk: .high)
        }
        if controls.contains(.message) {
            return .pass(reason: "send mediated agent message", risk: .low)
        }
        return .pass(reason: "control-plane operation requested", risk: .medium)
    }

    private func evaluateShell(_ call: ToolCallContext, _ ctx: PermissionContext) -> GateResult {
        if !ctx.allowsShell {
            return .deny(reason: "shell is disabled in this build (sandbox)", risk: .high)
        }
        if ctx.profile == .readOnly {
            return .deny(reason: "shell not allowed in read_only", risk: .high)
        }
        if call.risksNetwork {
            return .pass(reason: "browser or shell-backed network access requested", risk: .high)
        }
        let command = Self.shellCommand(from: call.rawArgs)
        if ShellInspector.isDangerous(command) {
            return .deny(reason: "dangerous shell command", risk: .high)
        }
        if ShellInspector.risksNetworkOrInstall(command) {
            return .pass(reason: "shell command may access network or install packages", risk: .high)
        }
        switch ShellInspector.inspectReadOnlyCommand(command, workspaceRoot: ctx.workspaceRoot) {
        case .allow(let reason):
            return .allow(reason: reason, risk: .low)
        case .deny(let reason):
            return .deny(reason: reason, risk: .high)
        case .ask:
            break
        }
        return .pass(reason: "run shell command", risk: .medium)
    }

    private func evaluateWrite(_ call: ToolCallContext, _ ctx: PermissionContext) -> GateResult {
        if ctx.profile == .readOnly {
            return .deny(reason: "writes not allowed in read_only", risk: .medium)
        }
        if call.touchedPaths.contains(where: SecretScanner.isProtectedConfigPath) {
            return .pass(reason: "modifies lockfile / CI / build config", risk: .high)
        }
        switch ctx.profile {
        case .manual, .reviewed, .autopilot:
            return .pass(reason: "modify workspace resource", risk: .medium)
        case .readOnly, .locked:
            return .deny(reason: "writes not allowed", risk: .medium)
        }
    }

    static func shellCommand(from rawArgs: String) -> String {
        struct A: Decodable { let command: String? }
        return (try? JSONDecoder().decode(A.self, from: Data(rawArgs.utf8)))?.command ?? ""
    }

    private static func stringMetadata(_ key: String, in intent: PermissionIntent) -> String? {
        guard case .string(let value)? = intent.metadata[key] else { return nil }
        return value
    }

    private static func boolMetadata(_ key: String, in intent: PermissionIntent) -> Bool? {
        guard case .bool(let value)? = intent.metadata[key] else { return nil }
        return value
    }
}
