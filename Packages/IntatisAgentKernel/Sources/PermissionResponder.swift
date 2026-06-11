import Foundation
import IntatisProtocol

/// Bridges an `ask_user` decision to whoever can answer it. In the GUI this is
/// backed by the permission card; in tests, a stub. The kernel emits a
/// `permission_request` event and then awaits this.
public protocol PermissionResponder: Sendable {
    /// Returns `.allow` or `.deny` for the given request.
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision
}

/// Convenience responder that always returns the same decision (tests / autopilot UI off).
public struct FixedResponder: PermissionResponder {
    public let decision: PermissionDecision
    public init(_ decision: PermissionDecision) { self.decision = decision }
    public func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision { decision }
}
