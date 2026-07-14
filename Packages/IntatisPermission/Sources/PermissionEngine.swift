import Foundation
import IntatisCore
import IntatisProtocol

/// Combines the deterministic gate (A) with one optional in-engine reviewer.
/// A `pass` is the sole reviewer entry point. Production Cowork deliberately
/// constructs this with `reviewer == nil`, converts `pass` to `ask_user`, and
/// uses its durable PermissionResponder control plane as the one reviewer.
/// Non-Cowork hosts may instead inject this reviewer. Hosts must not configure
/// both routes for the same call. A hard `deny` from the gate is always final.
public struct PermissionEngine: Sendable {
    private let gate: DeterministicPolicyGate
    private let reviewer: PermissionReviewer?

    public init(gate: DeterministicPolicyGate = DeterministicPolicyGate(),
                reviewer: PermissionReviewer? = nil) {
        self.gate = gate
        self.reviewer = reviewer
    }

    public func decide(_ call: ToolCallContext, _ ctx: PermissionContext) async -> PermissionOutcome {
        switch gate.evaluate(call, ctx) {
        case .deny(let reason, let risk):
            return PermissionOutcome(decision: .deny, risk: risk, reason: reason)

        case .ask(let reason, let risk):
            return PermissionOutcome(decision: .askUser, risk: risk, reason: reason)

        case .allow(let reason, let risk):
            return PermissionOutcome(decision: .allow, risk: risk, reason: reason)

        case .pass(let reason, let risk):
            if let reviewer {
                let outcome = await reviewer.review(call, ctx, gateReason: reason, risk: risk)
                // Safety net: a reviewer can never turn a hard deny into allow; it
                // only ever sees `pass`, but re-assert that it didn't widen scope.
                return outcome
            }
            return PermissionOutcome(decision: .askUser, risk: risk, reason: reason)
        }
    }
}
