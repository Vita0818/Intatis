/// Header names required by the MCP Streamable HTTP client transport.
///
/// These constants originate in upstream `HTTPServerTypes.swift`; they are
/// separated here so the client does not import the server HTTP type surface.
public enum HTTPHeaderName {
    public static let sessionID = "MCP-Session-Id"
    public static let protocolVersion = "MCP-Protocol-Version"
    public static let lastEventID = "Last-Event-ID"
    public static let accept = "Accept"
    public static let contentType = "Content-Type"
    public static let authorization = "Authorization"
    public static let wwwAuthenticate = "WWW-Authenticate"
    public static let cacheControl = "Cache-Control"
}

enum ContentType {
    static let json = "application/json"
    static let sse = "text/event-stream"
}
