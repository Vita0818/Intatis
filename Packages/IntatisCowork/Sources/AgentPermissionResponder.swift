import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisProtocol
import IntatisProviders

/// PermissionResponder backed by the reserved Cowork permission-review agent.
/// Review work is delegated to a dedicated control-plane actor: it never enters
/// TaskGraph/AgentScheduler and never starts a nested AgentLoop.
public struct AgentPermissionResponder: PermissionResponder {
    private let controlPlane: PermissionReviewControlPlane

    public init(log: EventLog,
                reviewerAgent: Agent,
                provider: ToolCallingProvider,
                fallback: PermissionResponder,
                maxRecentEvents: Int = 36,
                policy: PermissionReviewControlPlanePolicy? = nil,
                eventAppender: PermissionReviewEventAppender? = nil) {
        var effectivePolicy = policy ?? PermissionReviewControlPlanePolicy()
        if policy == nil {
            effectivePolicy.maxRecentEvents = max(1, maxRecentEvents)
        }
        controlPlane = PermissionReviewControlPlane(
            log: log,
            reviewerAgent: reviewerAgent,
            provider: provider,
            fallback: fallback,
            policy: effectivePolicy,
            eventAppender: eventAppender)
    }

    public func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await controlPlane.submit(request)
    }

    public func health() async -> PermissionReviewControlPlaneHealth {
        await controlPlane.health()
    }

    public func quiesce(reason: String) async {
        await controlPlane.quiesce(reason: reason)
    }

    public func resumeAfterFailedQuiesce() async {
        await controlPlane.resumeAfterFailedQuiesce()
    }

    public func finalizeShutdown() async {
        await controlPlane.finalizeShutdown()
    }

    /// Stops accepting review work and resolves queued/running requests safely.
    /// The provider race is cancellation-aware and does not wait for a provider
    /// implementation that ignores cooperative cancellation.
    public func shutdown(reason: String = "automatic permission review disabled") async {
        await controlPlane.shutdown(reason: reason)
    }
}
