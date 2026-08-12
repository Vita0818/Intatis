# EPUB document helper provenance

## Adoption status

- Local component: `Packages/IntatisTools/Runtime/rbook-helper`
- Reuse class: `dependency` inside an Intatis-owned `external-runtime` helper
- Product scope: macOS/Linux document tools only; never linked into iOS
- Runtime protocol: fixed `json-v1` argv plus a versioned JSON envelope
- Network: denied by the Intatis document process boundary
- Distribution status in this task: buildable source and exact lockfile only;
  no universal signed helper binary is claimed to be bundled

The helper does not copy rbook source. It calls rbook's public Rust API for a
closed EPUB2/EPUB3 write subset and keeps permission review, path authorization,
resource limits, staged output, EPUBCheck validation, and commit ownership in
Intatis.

## Primary upstream

- Project: `rbook`
- Upstream: `https://github.com/DevinSterling/rbook`
- Crate: `rbook 0.7.10`
- Registry source: crates.io index
- Registry checksum:
  `663ec1a8b0a945c8bb9c9912b1f8b328ba698a05165a81072e16604be019f45d`
- License expression: `Apache-2.0`
- Copyright/author metadata: Devin Sterling
- Read-only audit checkout examined locally:
  `d440c7cf35db2fd31e938c0555448dbaec5437d0`

The registry checksum and `Cargo.lock`, not the research checkout name, are
the reproducible build identity.

## Direct dependency lock

| Crate | Version | Cargo checksum | License |
|---|---:|---|---|
| rbook | 0.7.10 | `663ec1a8b0a945c8bb9c9912b1f8b328ba698a05165a81072e16604be019f45d` | Apache-2.0 |
| serde | 1.0.229 | `4148590afebada386688f18773da617792bf2ef03ffc1e4cbd2b1d45b023e0ba` | MIT OR Apache-2.0 |
| serde_json | 1.0.151 | `c841b55ecdae098c80dcae9cf767f6f8a0c2cdb3416bbef72181df4d0fe73f14` | MIT OR Apache-2.0 |
| zip | 8.6.0 | `2d04a6b5381502aa6087c94c669499eb1602eb9c5e8198e534de571f7154809b` | MIT |

The helper disables zip's default feature set and enables only
`deflate-flate2-zlib-rs`. Direct versions are exact `=` constraints.

## Complete resolved runtime closure

`Cargo.lock` schema v4 resolves the following crates. The license expressions
were read from the exact crates resolved by `cargo metadata --locked`:

| Crate | Version | License expression |
|---|---:|---|
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 |
| cfg-if | 1.0.4 | MIT OR Apache-2.0 |
| crc32fast | 1.5.0 | MIT OR Apache-2.0 |
| equivalent | 1.0.2 | Apache-2.0 OR MIT |
| flate2 | 1.1.9 | MIT OR Apache-2.0 |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 |
| indexmap | 2.14.0 | Apache-2.0 OR MIT |
| itoa | 1.0.18 | MIT OR Apache-2.0 |
| memchr | 2.8.3 | Unlicense OR MIT |
| miniz_oxide | 0.8.9 | MIT OR Zlib OR Apache-2.0 |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 |
| quick-xml | 0.41.0 | MIT |
| quote | 1.0.47 | MIT OR Apache-2.0 |
| rbook | 0.7.10 | Apache-2.0 |
| serde / serde_core / serde_derive | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.151 | MIT OR Apache-2.0 |
| simd-adler32 | 0.3.10 | MIT |
| syn | 3.0.3 | MIT OR Apache-2.0 |
| thiserror / thiserror-impl | 2.0.20 | MIT OR Apache-2.0 |
| typed-path | 0.12.3 | MIT OR Apache-2.0 |
| unicode-ident | 1.0.24 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| zip | 8.6.0 | MIT |
| zlib-rs | 0.6.7 | Zlib |
| zmij | 1.0.23 | MIT |

No GPL, AGPL, LGPL, MPL, SSPL, BSL, Commons Clause, or source-available
component appears in this resolved closure.

## Integrity records

- `Cargo.toml` SHA-256:
  `6e20c588fe36bfbd0e4cc243c0bf7ea6e839c4fe5dd64b3c2ee5364874a9f192`
- `Cargo.lock` SHA-256:
  `4930ac8d5f4fd5d068bfe0a4107d86a5ae086d2803b33a10f3bf1cdbd6b77233`

The lockfile contains each registry checksum. Any dependency update must
refresh this record, rerun the license audit, and repeat the EPUB protocol,
round-trip, ZIP-safety, and postcondition tests.

## Local security and semantic boundary

The helper accepts only `write` under its exact schema/version
envelope. It implements bounded spine/metadata/ToC projection and the declared
`metadata.set`, `resource.add`, `spine.append`, and `toc.add` operations. It
rejects command/environment injection, remote or active resource content,
unreviewed assets, unsafe paths, symlinks, hard-to-interpret ZIP members,
encrypted entries, duplicate member names, excessive expansion, and
operations outside the closed subset. Every write is reopened and checked
against operation postconditions before Intatis runs EPUBCheck and considers
the staged commit.

## Binary distribution gate

Before a compiled helper is put into a signed Intatis distribution, the
runtime-packaging task must additionally:

1. build both supported architectures from this exact lockfile with the fixed
   Rust toolchain and record binary hashes;
2. collect the original copyright, LICENSE, and NOTICE files from every
   selected crate into the distributed third-party notice bundle;
3. generate an SBOM matching the linked release binary and verify that dead
   feature/dependency assumptions remain true;
4. sign, harden, notarize, and exercise the helper through the production
   document sandbox on a clean machine.

Until that separate gate passes, a missing installed helper is reported as
typed `backend_missing`; Intatis must not download a helper or switch to a
different EPUB backend automatically.
