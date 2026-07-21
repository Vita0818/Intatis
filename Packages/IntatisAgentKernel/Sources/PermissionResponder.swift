import Foundation
import IntatisProtocol

/// Bridges an `ask_user` decision to whoever can answer it. In the GUI this is
/// backed by the permission card; in tests, a stub. The kernel emits a
/// `permission_request` event and then awaits this.
public protocol PermissionResponder: Sendable {
    /// Declares whether a newly persisted request is answered by a user-facing
    /// manual queue or the reserved automatic reviewer control plane.
    var approvalMode: PermissionApprovalMode { get }
    /// Returns `.allow` or `.deny` for the given request.
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision
    /// Returns the decision together with its authoritative reason/source when
    /// the responder supports structured settlement.
    func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution
}

public extension PermissionResponder {
    var approvalMode: PermissionApprovalMode { .manual }

    func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: await requestApproval(request),
            risk: request.risk,
            source: .user)
    }
}

/// Convenience responder that always returns the same decision (tests / autopilot UI off).
public struct FixedResponder: PermissionResponder {
    public let decision: PermissionDecision
    public init(_ decision: PermissionDecision) { self.decision = decision }
    public func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision { decision }
}
