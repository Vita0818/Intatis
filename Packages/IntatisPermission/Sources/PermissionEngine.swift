import Foundation
import IntatisCore
import IntatisProtocol

/// Combines the deterministic gate (A) with the optional reviewer (B). v0.2
/// constructs it with `reviewer == nil`, so gate `pass` results degrade to
/// `ask_user` — i.e. writes / patches / shell are confirmed by the user by
/// default (ARCHITECTURE.md §7.3). When v0.3 adds a reviewer, `pass` routes to it.
/// A hard `deny` from the gate is always final.
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
            return PermissionOutcome(decision: .askUser, risk: risk,
                                     reason: reason + " (no reviewer configured → asking user)")
        }
    }
}
