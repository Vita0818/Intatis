# MCP Client SDK patch ledger

Every entry is relative to upstream `0.12.1` commit
`a0ae212ebf6eab5f754c3129608bc5557637e605`.

## CLIENT-ONLY-001 — remove hosting surface

- Upstream inputs: `Package.swift`, `Sources/MCP/Server/Server.swift`,
  `Sources/MCP/Base/Transports/HTTPServer/**`, `Sources/MCPConformance/**`
- Local action: publish only one library target; omit the server actor, server
  HTTP transports, bidirectional in-memory/custom network transports,
  server-side OAuth validation/metadata types, server/conformance executables,
  SwiftNIO, and docc plugin.
  The small HTTP header/content-type constant subset used by the client is
  isolated in `HTTPClientWireConstants.swift`.
- Reason: Intatis is solely an external MCP Server client and must expose no
  server target, API, binary, protocol handler, or future hosting seam.
- Verification: package graph audit and a source/API deny-list test.

## CLIENT-ONLY-002 — remote server metadata is not a hosting API

- Upstream inputs: nested `Server.Info` and `Server.Capabilities` declarations
  in `Sources/MCP/Server/Server.swift`.
- Local action: move the two wire metadata values to
  `RemoteServerInfo.swift` as `RemoteServerInfo` and
  `RemoteServerCapabilities`; update lifecycle/client references.
- Reason: initialization must decode remote server metadata without exporting
  the upstream `Server` actor or a server namespace.
- Verification: initialization fixtures plus a source deny-list for
  `actor Server`, `HTTPServerTransport`, and conformance server products.

## VERSION-001 — per-server requested and allowed protocol versions

- Upstream input: `Sources/MCP/Client/Client.swift`.
- Local action: add `connect(transport:requestedProtocolVersion:
  allowedProtocolVersions:)`; reject a requested version outside the supplied
  set and reject an initialization response outside that set before sending
  `notifications/initialized`.
- Reason: each Intatis server has an exact protocol profile and maximum version;
  the upstream client always requested `Version.latest`.
- Verification: codex-compat and standard-extended negotiation fixtures,
  including out-of-bound server responses.

## INITIALIZE-002 — host validation before initialized

- Upstream input: `Sources/MCP/Client/Client.swift`.
- Local action: the per-server `connect` overload accepts an async
  `validateInitializeResult` hook. It runs immediately after the initialize
  response arrives and before the SDK allow-set fence, negotiated-state write,
  HTTP protocol-header update, or `notifications/initialized`.
- Reason: Intatis must validate the selected profile version, required
  capabilities, bounded instructions, and host policy with stable typed errors
  before acknowledging initialization. A thrown validator error disconnects
  the exact transport generation.
- Verification: missing-required-capability and out-of-profile-version
  fixtures assert no initialized notification and no published handshake.

## TASKS-001 — 2025-11-25 experimental Tasks wire surface

- Upstream inputs: `Sources/MCP/Client/Client.swift`,
  `Sources/MCP/Client/Sampling.swift`,
  `Sources/MCP/Client/Elicitation.swift`,
  `Sources/MCP/Server/Tools.swift`, and the 2025-11-25 schema.
- Local action: add client-only wire values and methods in
  `ProtocolDomain/Tasks.swift` for task metadata/state, `tasks/get`,
  `tasks/result`, `tasks/list`, `tasks/cancel`, and
  `notifications/tasks/status`; add exact top-level client/server Tasks
  capability shapes, tool `execution.taskSupport`, and task augmentation on
  tools, sampling, and elicitation request parameters. Patch
  `CallTool.Result`, `CreateSamplingMessage.Result`, and
  `CreateElicitation.Result` as discriminated result unions so an immediate
  task-augmented response encodes and decodes the exact `CreateTaskResult`
  shape (`task` plus optional `_meta`) without ordinary-result fields.
- Reason: upstream 0.12.1 has no Tasks API, while the frozen
  `standard-extended` profile requires the complete experimental 2025-11-25
  surface. These are request/response types used by an external-server client;
  they do not add an MCP Server actor, target, transport, executable, or
  hosting API.
- Verification: `MCPTaskWireTests`, including
  `testTaskAugmentedMethodResultsUseExactCreateTaskShape`, exact JSON wire
  fixtures, exhaustive capability negotiation, separate Intatis
  remote-server/client-hosted state-machine tests, TTL and cancellation tests,
  and pinned 2025-11-25 conformance.

## RESOURCES-001 — construct subscribe/unsubscribe requests

- Upstream input: `Sources/MCP/ProtocolDomain/Resources.swift`.
- Local action: add public `init(uri:)` initializers to the client-side
  `ResourceSubscribe.Parameters` and `ResourceUnsubscribe.Parameters` wire
  values.
- Reason: upstream exposes both request methods and public parameter fields,
  but its implicit memberwise initializers are internal, so an external client
  module cannot issue either standard request.
- Verification: W7 resource subscription lifecycle tests cover exact
  subscribe, update delivery, unsubscribe, grant revocation, disconnect, and
  shutdown drain.

## HTTP-001 — no protocol header before negotiation

- Upstream input:
  `Sources/MCP/Base/Transports/HTTPClientTransport.swift`.
- Local action: make the initial protocol version optional and default it to
  `nil`; the client sets it only after a valid initialize result.
- Reason: the Streamable HTTP protocol-version header applies after
  negotiation, not to the initialize request.
- Verification: request-capture tests for initialize and subsequent POST/GET.

## HOST-HTTP-002 — replace unsafe transport behavior at the Intatis boundary

- Upstream input:
  `Sources/MCP/Base/Transports/HTTPClientTransport.swift`.
- Local action: production Intatis connections use
  `Packages/IntatisMCP/Sources/MCPStreamableHTTPTransport.swift`. The SDK
  transport remains only an upstream comparison surface. The Intatis transport
  calls the Intatis-owned `Packages/IntatisCurlTransport` boundary for
  production HTTP/OAuth I/O; there is no URLSession or SDK-transport fallback
  on a production path. On macOS that target links Apple system libcurl. The
  fully static Linux CLI links the official Swift 6.3.3 Static Linux SDK
  closure `libcurl.a + libssl.a + libcrypto.a + libz.a`; exact artifact/SBOM
  and dual-architecture archive hashes, the Swift build recipe plus
  byte-matched source pins (curl
  `cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a`, BoringSSL
  `817ab07ebb53da35afea409ab9328f578492832d`, zlib
  `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`), their license obligations,
  and the remaining artifact/source-attestation boundary are in
  `ThirdPartyNotices/MCPHTTPTransport.md`.
  The Intatis transport
  implements POST JSON/SSE, 202, optional GET SSE, a distinct resumability and
  deduplication state per stream, generation-bound `MCP-Session-Id`, 404
  retirement, DELETE termination, bounded owned drain, strict origin/redirect,
  no-cookie, explicit proxy, TLS pin, DNS/egress/rebinding, and hard
  request/header/body/frame/stream limits.
- Reason: upstream 0.12.1 has one global event ID, incomplete Linux SSE, no
  DELETE, no hard caps, logs complete session identifiers, and can
  automatically repeat a request after authorization/session recovery.
  Intatis must never replay a dispatched `tools/call`; an ambiguous dispatched
  operation returns a typed execution-uncertain result.
- Verification: `MCPStreamableHTTPTests`, including JSON/SSE/202,
  independent GET and POST-associated per-stream resume/dedup, session 404,
  DELETE/405, cookie/proxy policy, DNS rebinding, hard caps, authorization
  challenge no-replay, and no-replay network failures; W10 additionally
  rebuilds both Static Linux SDK architectures, rechecks archive/SBOM
  provenance, and verifies the Apple product does not bundle a private libcurl
  copy.

## HOST-OAUTH-003 — durable authority-bound OAuth instead of SDK auto-retry

- Upstream inputs:
  `Sources/MCP/Base/Authorization/OAuthAuthorizer.swift`,
  `OAuthModels.swift`, and `TokenStorage.swift`.
- Local action: production Intatis OAuth uses
  `Packages/IntatisMCP/Sources/MCPOAuth.swift` with RFC 9728 path/root/header
  discovery, RFC 8414 then OIDC discovery, OAuth 2.1 authorization code + PKCE,
  state/login-generation fencing, exact loopback callback validation, Client
  ID Metadata Documents before explicitly enabled DCR, RFC 8707 resource
  binding, challenge scope step-up, account/authority isolation, single-flight
  refresh, logout/reset, and a generation-fenced HTTP authorization adapter.
  Tokens and DCR client secrets are persisted only through
  `MCPSecretStore`; handles contain opaque references and safe identity
  metadata.
  `MCPOAuthLoopbackCallbackListener` provides the one-shot macOS/Linux socket
  implementation and binds only `127.0.0.1` or `::1` (including OS-assigned
  ephemeral ports), with a bounded request and a constant non-reflecting
  response.
- Reason: the upstream synchronous/nonthrowing token-store interface cannot
  fail closed, DCR credentials are memory-only, a refresh response can drop
  the old refresh token, and automatic challenge recovery can replay the MCP
  operation that triggered authentication.
- Verification: `MCPOAuthTests`, including discovery order, origin/resource/
  audience fences, PKCE/state/generation, Client ID Metadata Document/DCR
  selection, refresh-token retention and single-flight, logout, scope step-up,
  and secret-free durable handles.

## PORTABLE-CRYPTO-004 — Linux OAuth cryptography

- Upstream inputs:
  `Sources/MCP/Base/Authorization/PKCE.swift`,
  `OAuthConfiguration.swift`, and `OAuthAuthorizer.swift`.
- Local action: declare official `apple/swift-crypto 4.5.1` as an exact,
  Linux-only target dependency; import system `CryptoKit` on Darwin and the
  API-compatible `Crypto` module on Linux. PKCE S256 and ES256
  `private_key_jwt` now execute through either reviewed backend and still fail
  closed if neither module is available.
- Reason: upstream gates these paths solely on `canImport(CryptoKit)`, which
  makes OAuth authorization-code PKCE unavailable on the shipped Linux CLI.
  Intatis does not permit a plaintext, SHA-256 placeholder, or home-grown
  cryptographic fallback.
- Verification: `MCPPortableCryptoTests` known-answer vectors for SHA-256,
  HMAC-SHA256, AES-GCM authentication, and RFC 7636 PKCE S256; Linux static SDK
  builds compile the vendored SDK through the `Crypto` backend. Exact
  swift-crypto, swift-asn1, BoringSSL, and XKCP provenance/licenses are in
  `ThirdPartyNotices/SwiftCrypto.md`.

## Tracked adapter/conformance work

Intatis-owned `Packages/IntatisMCP/Sources/SDKPatchCompatibility.swift` records
features implemented above or around this source derivative, including managed
stdio ownership, HTTP generation fencing, OAuth replay prevention, sampling
with tools, provider-neutral URL elicitation, and experimental 2025-11-25
tasks. Each entry must remain tied to conformance tests during SDK upgrades.
