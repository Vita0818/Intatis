# Intatis rbook helper

This is the fixed, separately built EPUB backend for `IntatisTools`. It is not
a general EPUB CLI and is never model-configurable.

Build and verify from this directory with the pinned Rust 1.88-or-newer
toolchain:

```sh
cargo build --release --locked
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

The development runtime expects the resulting executable at:

- macOS: `~/Library/Application Support/Intatis/document-runtime/bin/intatis-rbook-helper`
- Linux: `~/.local/share/intatis/document-runtime/bin/intatis-rbook-helper`

Intatis only reads that optional user-managed runtime. It does not install or
update the helper during a tool call. A missing executable is a typed
`backend_missing` result.

The protocol is intentionally closed: argv must be exactly `json-v1`, the
versioned request is supplied through the two host-owned `INTATIS_DOCUMENT_*`
environment variables, and stdout is exactly one bounded JSON envelope.
Permissions, workspace confinement, network denial, process cleanup, staging,
EPUBCheck validation, and final commit remain host responsibilities.

Dependency provenance and the binary-distribution gate are recorded in
`ThirdPartyNotices/DocumentRBookHelper.md` at the repository root.
