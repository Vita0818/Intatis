import IntatisMCP
import IntatisProviders
import IntatisTools

/// Immutable tool catalog captured immediately before one provider dispatch.
///
/// A provider response may arrive after the live MCP catalog has refreshed.
/// Holding this value through response parsing, authorization, durable prepare,
/// and execution guarantees that the model can invoke only the exact
/// registrations and schemas it was shown.
public struct AgentRequestToolSnapshot: Sendable {
    public let snapshotID: String
    public let registry: ToolRegistry
    /// Exact provider-visible specs for this dispatch. This may be narrower
    /// than the execution registry when deferred tools are searchable.
    public let providerToolSpecs: [ToolSpec]?

    public init(snapshotID: String,
                registry: ToolRegistry,
                providerToolSpecs: [ToolSpec]? = nil) {
        self.snapshotID = snapshotID
        self.registry = registry
        self.providerToolSpecs = providerToolSpecs
    }

    public init(registry: ToolRegistry) {
        self.init(snapshotID: registry.registryVersion, registry: registry)
    }
}

/// Host-neutral seam used by Code/Cowork session owners to publish a fresh,
/// response-owned registry for each provider request.
public typealias AgentRequestToolSnapshotProvider =
    @Sendable (
        ToolCallingProviderCapabilities,
        MCPToolResultAggregateBudget
    ) async throws -> AgentRequestToolSnapshot

public typealias AgentExternalToolOutputBudget =
    MCPToolResultAggregateBudget
