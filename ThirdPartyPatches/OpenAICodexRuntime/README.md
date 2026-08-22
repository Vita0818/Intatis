# OpenAI Codex Runtime patch

Intatis Code, Cowork, and CLI use a narrowly derived build of the official
open-source OpenAI Codex App Server.

- Upstream release: `rust-v0.145.0`
- Peeled upstream commit: `25af12f7e61572b0bc18ddb1008be543b91519b0`
- Derived runtime version: `0.145.0-intatis.2`
- Patch: `0001-responses-provider-passthrough.patch`
- License and provenance: `ThirdPartyNotices/OpenAICodexRuntime.md`

The patch restores the former Intatis request-owned passthrough semantics for
exactly one isolated subtree: top-level Responses `provider`. Intatis passes
the already-decoded, non-secret `options.provider` JSON object through the
derived custom-provider config field `intatis_responses_provider`; Codex
clones that object into `ResponsesApiRequest.provider` without enumerating,
interpreting, renaming, or merging its children. Future provider-owned keys
therefore do not require another Codex patch.

This is not a generic `extra_body`: provider JSON cannot replace host-owned
`model`, `input`, `tools`, `stream`, `reasoning`, or other request fields. No
control header, proxy, protocol translator, or OpenRouter-specific parser is
introduced. Intatis applies recursive secret/transport-key scanning and
structural resource bounds before the object crosses the process boundary.

Apply and build from the exact upstream commit:

```sh
git checkout 25af12f7e61572b0bc18ddb1008be543b91519b0
git apply /absolute/path/to/0001-responses-provider-passthrough.patch
cd codex-rs
cargo build --release -p codex-cli
./target/release/codex --version
```

The expected version output is `codex-cli 0.145.0-intatis.2`. The patch reuses
the workspace's existing `serde_json` version and records that package-edge in
`Cargo.lock`; do not retain Cargo-generated workspace-version-only rewrites.
Install the resulting executable as
`~/.local/bin/intatis-codex`; Intatis checks the exact derived version before
starting App Server. The existing official `codex` executable remains
untouched.

The patch can be retired when the exact official Codex release exposes an
official request-owned Responses `provider` body extension or otherwise
serializes the same provider object without a local change.
