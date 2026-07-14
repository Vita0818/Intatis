# NOTICE

## Project origin and source reuse policy

Intatis is an Apple-first, Swift-native-first local AI workbench. Project-owned
code and assets are original unless an upstream source is explicitly identified.
Intatis may copy, translate, modify, link, vendor, or run compatible open-source
implementations when their licenses and provenance have been reviewed and the
required copyright and license notices are preserved.

Intatis does **not** use leaked or private source code/prompts and does not copy
third-party product names, logos, icons, screenshots, UI assets, trademarks, or
brand copy as its product identity. Open-source reuse must not bypass Intatis'
permission, workspace, event-log, secret, or Apple platform boundaries.

The operational policy and provenance requirements are documented in
`docs/OPEN_SOURCE_REUSE.md`.

## Current upstream source status

- OpenCode (`anomalyco/opencode`, MIT): research-only as of 2026-07-12. No
  OpenCode source files, public prompts, UI assets, or runtime are currently
  vendored, translated, linked, or bundled in Intatis.
- Add each adopted upstream project here when source or a dependency is actually
  introduced. For substantial notices, add `ThirdPartyNotices/<project>.md`.

## Third-party dependencies

### v0.1
- None. Only the Swift standard library, Foundation, and (on Apple platforms)
  SwiftUI / AppKit / Security, which ship with the OS toolchain.

### Planned (later milestones — listed for transparency, not yet vendored)
- **libgit2 / SwiftGit2** (v0.2): in-process git so `git_status` / `git_diff` /
  `apply_patch` work inside the App Store sandbox without spawning `git`.
  License: libgit2 is GPLv2-with-linking-exception. To be reviewed before adoption.

Update this file whenever upstream source, a dependency, a bundled runtime, or a
licensed asset is added or upgraded.
