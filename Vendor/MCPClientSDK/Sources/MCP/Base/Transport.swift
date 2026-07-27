import Logging

import struct Foundation.Data

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data
    func send(_ data: Data) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

/// Client transports that need the negotiated MCP version on subsequent
/// requests (for example, Streamable HTTP's `MCP-Protocol-Version` header).
///
/// This is deliberately transport-neutral so hosts can supply a hardened
/// Streamable HTTP implementation without the SDK special-casing its concrete
/// `HTTPClientTransport` actor.
public protocol NegotiatedProtocolVersionTransport: Transport {
    func updateNegotiatedProtocolVersion(_ version: String) throws
}
