# OpenAI Codex App Server external runtime

## Upstream identity

- Project: OpenAI Codex (`https://github.com/openai/codex`)
- Adopted release: `rust-v0.145.0`
- Annotated tag object: `1635de866c61d1b76e50b31928ee6d61482435a8`
- Fixed source commit: `25af12f7e61572b0bc18ddb1008be543b91519b0`
- Copyright: Copyright 2025 OpenAI
- Root license: Apache License 2.0
- Root LICENSE SHA-256:
  `d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc`
- Root NOTICE SHA-256:
  `9d71575ecfd9a843fc1677b0efb08053c6ba9fd686a0de1a6f5382fd3c220915`

The upstream NOTICE reads:

> OpenAI Codex
>
> Copyright 2025 OpenAI
>
> This project includes code derived from Ratatui, licensed under the MIT
> license. Copyright (c) 2016-2022 Florian Dehau; Copyright (c) 2023-2025 The
> Ratatui Developers.

The complete Apache-2.0 text already preserved for the same upstream project
and release is at
`ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`.

## Reuse classification and local integration

- Reuse type: `derived external-runtime` + official stable App Server API.
- Reproducible patch:
  `ThirdPartyPatches/OpenAICodexRuntime/0001-responses-provider-passthrough.patch`.
- Local Swift host:
  `Packages/IntatisCodexRuntime/Sources/`.
- Provider projection:
  `Packages/IntatisProviders/Sources/ResponsesRuntimeRoute.swift`.
- macOS product wiring:
  `Apps/IntatisMac/Sources/CodeViewModel.swift` and
  `Apps/IntatisMac/Sources/CoworkViewModel.swift`.
- CLI wiring:
  `Apps/intatis-cli/Sources/CodexRuntimeCLI.swift`.
- Tests:
  `Packages/IntatisCodexRuntime/Tests/CodexRuntimeTests.swift`.

No complete Codex Rust source tree is copied into the Intatis repository. The
single checked-in patch adds a request-owned opaque JSON channel for exactly
the top-level Responses `provider` object and tests unknown nested fields for
lossless HTTP/WebSocket serialization. No local Swift implementation substitutes for Codex's agent loop, tool
orchestration, sandbox, approval review, context management, thread/turn/item lifecycle, or
subagent runtime. The Swift target is limited to executable discovery and
version verification, process lifecycle, newline-delimited JSON-RPC,
Intatis-provider configuration, owner-only thread identity, and projection
onto existing Intatis UI/event types.

The integration accepts exactly `codex-cli 0.145.0-intatis.2`, built from the
fixed upstream commit plus the checked-in patch. It uses stable stdio App
Server methods including `initialize`, `thread/start`, `thread/resume`,
`turn/start`, `turn/interrupt`, stable item/turn notifications, server-initiated
command/file/permission approvals, and stable thread Goal methods. Experimental
dynamic-tool and paginated-history APIs are not used by the first version.

## Authentication and provider boundary

Intatis does not use Codex's ChatGPT login flow. Each process receives an
isolated session-owned `CODEX_HOME`; thread configuration selects an
`intatis` model provider with `wire_api = "responses"` and
`requires_openai_auth = false`. The exact credential resolved by Intatis is
placed only in a request-specific child-process environment variable. It is
not written to `runtime.json`, `models.json`, EventLog, project documentation,
or command-line arguments.

For an exact OpenRouter route, Intatis takes the already-decoded
`options.provider` object after recursive secret/transport-key scanning and
structural resource validation, then supplies it as
`intatis_responses_provider` in the custom-provider config. The derived runtime
clones the object into `ResponsesApiRequest.provider` without enumerating,
interpreting, renaming, or merging its children. Provider-owned future fields
therefore cross unchanged. There is no control header, OpenRouter parser,
generic whole-request `extra_body`, protocol translator, or proxy; this object
cannot override host-owned `model`, `input`, `tools`, `stream`, or `reasoning`.

Codex's official `shell_environment_policy` is set to inherit only core shell
variables, enable the runtime's default `*KEY*` / `*SECRET*` / `*TOKEN*`
exclusions, and explicitly exclude `INTATIS_*` plus `CODEX_HOME`. The provider
credential is therefore available to the App Server HTTP client but not to
agent-launched shell children. Codex 0.145.0's stable `shell_snapshot` feature
captures the parent process environment before that tool filter, so this
integration explicitly disables that official feature; otherwise it would
persist the provider token below `CODEX_HOME/shell_snapshots`. If an isolated
home already contains that directory from an older configuration, startup
fails before credential injection and requires a new session; Intatis does not
inspect, rewrite, or delete potentially sensitive snapshots.

The generated owner-only `models.json` uses Codex's official
`model_catalog_json` extension point. It binds `auto_review_model_override` to
the same selected Responses model so a third-party endpoint is never silently
asked for an unrelated OpenAI model. This is configuration of the upstream
runtime, not a replacement reviewer implementation.

## Persistence and migration boundary

Every Intatis Code/Cowork session owns `codex-runtime/` beside its EventLog:

- `codex-home/` is the isolated upstream runtime home and rollout store;
- `runtime.json` is an owner-only schema-v2 mapping to an exact, materialized
  Codex thread. A thread created and closed before its first accepted turn is
  not recorded, so the next open may safely create another empty thread;
- `models.json` is the non-secret fixed model catalog supplied to Codex.
- `runtime.lock` is a safe owner-only `flock` lease; only one process may own
  the session's Codex home/thread at a time. Host shutdown releases it only
  after observing process exit; a TERM timeout escalates to KILL, and an
  unconfirmed exit keeps the lease through deferred retirement.

Codex rollout history is authoritative for future model context. Intatis
EventLog remains the UI/audit projection and intentionally stores only bounded,
redacted presentation facts for Codex tool items. A legacy Intatis agent
session without `runtime.json` is not auto-migrated or silently replayed into a
new Codex thread; the first version fails clearly and requires a new session.

## Local development build evidence (not a release artifact)

The 2026-08-22 arm64 development build used Rust/Cargo 1.97.1, the fixed
upstream source, and the exact checked-in patch. Evidence:

- upstream `codex-rs/Cargo.lock` SHA-256:
  `e0843448b5767ff36a2a3b15212feb480cd4eaafe8a0c0ca08547e3c7da03a05`;
- derived `codex-rs/Cargo.lock` SHA-256 (existing `serde_json` package-edge
  only):
  `aca116b64735186879a2108a154db4d9cbe39ff9430d91edd0d4d813b9d1ed5a`;
- patch SHA-256:
  `24b9d75efee98175df5a7a73dd2b17564776e09b710354c94fb267d2f5e29c14`;
- resulting arm64 `codex-cli 0.145.0-intatis.2` SHA-256:
  `68c7a96809d9e6f5afbf3f54834c5ea724ca263b12c8f65a02155fa2707aa334`;
- reused same-version/same-target rusty_v8 v149.2.0 release-profile archive
  SHA-256:
  `7131418bf7a62a02cbc53cc07aa80776fec10e2197812fdfc0ee0def15686adf`.

Cargo 1.97.1 mechanically rewrites upstream workspace package versions in
the lockfile from `0.0.0` to `0.145.0`; that generated-only drift was discarded.
The sole retained lock change records the existing workspace `serde_json`
dependency for `codex-model-provider-info`. The development executable is installed
separately as `~/.local/bin/intatis-codex`, is thin arm64 and linker ad-hoc
signed, and is not copied into the repository or App bundle. This evidence
does not satisfy the universal/license/Developer-ID/notarization gate below.

## Current distribution gate

This source revision does **not** copy a Codex executable into the repository
or into release resources. Development/runtime discovery checks, in order, an
explicit `INTATIS_CODEX_RUNTIME`, an app-bundled auxiliary executable, normal
local installation locations beginning with `~/.local/bin/intatis-codex`, and
`PATH`, then requires the exact version above. The separately installed
official `codex` remains untouched. This is dependency discovery, not a
fallback to the former Swift kernel.

Before a public Intatis macOS archive can bundle Codex, release engineering
must separately:

1. produce and hash arm64 and x86_64 binaries from the fixed source commit and
   checked-in patch;
2. audit the exact Cargo lock closure and preserve every required license and
   NOTICE, including Ratatui-derived attribution;
3. assemble a universal or otherwise architecture-correct auxiliary
   executable;
4. sign the nested executable with the same Developer ID team before signing
   the outer app, then verify Hardened Runtime, notarization, stapling, and
   Gatekeeper from a fresh account;
5. verify final-bundle license inventory and the exact `codex --version`
   runtime gate.

Until that gate is complete, a missing or mismatched runtime is an explicit
startup error. Intatis never falls back to `AgentLoop`, `Orchestrator`, another
provider, a mock runtime, or a compatibility protocol.

## Upgrade procedure

For an upgrade, pin a new annotated release and peeled commit, first test
whether the official runtime has made this patch unnecessary, regenerate the
stable JSON schemas from that exact executable, compare all consumed request,
response, and notification shapes, update the model-catalog schema from that
same release source, rerun the fake lifecycle and real offline App Server
handshakes, repeat the complete dependency/license/distribution audit, and
only then change `CodexRuntimeExecutable.pinnedVersion`, the patch (or its
documented removal), and this record.
