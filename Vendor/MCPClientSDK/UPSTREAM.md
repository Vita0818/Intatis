# MCP Client SDK upstream identity

- Upstream: `modelcontextprotocol/swift-sdk`
- Tag: `0.12.1`
- Commit: `a0ae212ebf6eab5f754c3129608bc5557637e605`
- Retrieved: 2026-07-26
- Upstream product: `MCP`
- Local product: `MCP` from package `MCPClientSDK`

This directory is an auditable, client-only source derivative. The copied
source bytes originated at the commit above. Intatis excludes every upstream
server runtime, server transport, server executable, conformance executable,
test target, and documentation plugin so that no MCP hosting surface or NIO
server dependency enters an Intatis product.

Included upstream source groups:

- `Sources/MCP/Base`, except the transport and OAuth server surfaces listed
  below
- `Sources/MCP/Client`
- `Sources/MCP/Extensions`
- Protocol-domain message types from `Sources/MCP/Server/Completion.swift`,
  `Logging.swift`, `Prompts.swift`, `Resources.swift`, and `Tools.swift`, moved
  locally to `Sources/MCP/ProtocolDomain`
- Intatis-authored `Sources/MCP/ProtocolDomain/Tasks.swift`, supplying the
  experimental 2025-11-25 client wire gap documented in `PATCHES.md`
- Local Tasks result-union patches in `ProtocolDomain/Tools.swift`,
  `Client/Sampling.swift`, and `Client/Elicitation.swift`, which preserve
  ordinary upstream results while encoding/decoding a task-augmented immediate
  response as the exact 2025-11-25 `CreateTaskResult` shape
- The client-used `HTTPHeaderName` and `ContentType` constants from
  `Sources/MCP/Base/Transports/HTTPServer/HTTPServerTypes.swift`, isolated in
  `HTTPClientWireConstants.swift` without the server request/response surface

Excluded upstream source groups:

- `Sources/MCP/Server/Server.swift`
- `Sources/MCP/Base/Transports/HTTPServer`
- `Sources/MCP/Base/Transports/InMemoryTransport.swift`
- `Sources/MCP/Base/Transports/NetworkTransport.swift`
- Server-side `BearerTokenInfo` and
  `OAuthProtectedResourceServerMetadata` declarations from
  `Sources/MCP/Base/Authorization/OAuthModels.swift`
- `Sources/MCPConformance`
- all upstream tests and executable targets

The protocol-domain files define client-consumed JSON-RPC messages and value
types. Server-to-client callback request types are handlers on the client
connection required by the MCP client role; they do not start, host, route, or
expose an MCP server runtime.

Local dependency additions:

- `apple/swift-crypto 4.5.1`, exact commit
  `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6`, exposes `Crypto` only when
  building the MCP target for Linux. This is the official
  CryptoKit-compatible backend used by the OAuth PKCE/private-key JWT patch;
  Darwin continues to use system CryptoKit.
- Its transitive and vendored component inventory (`swift-asn1`, BoringSSL,
  and XKCP), complete distributed terms, and integrity hashes are fixed in
  `ThirdPartyNotices/SwiftCrypto.md` and `ThirdPartyNotices/Licenses/`.
