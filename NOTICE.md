# NOTICE

## Clean-room statement

Intatis is a clean-room implementation. All names, protocols, prompts, code, and
UI assets are original to this project. Intatis does **not** copy, link against, or
run the source code, private prompts, icons, trademarks, or brand copy of DeepCode,
Codex / Codex CLI, Claude Code, OpenCode, or any other product. Public product
capabilities and interaction patterns may have informed the design; the internal
architecture, code, naming, and wire protocol are independent.

## Third-party dependencies

### v0.1
- None. Only the Swift standard library, Foundation, and (on Apple platforms)
  SwiftUI / AppKit / Security, which ship with the OS toolchain.

### Planned (later milestones — listed for transparency, not yet vendored)
- **libgit2 / SwiftGit2** (v0.2): in-process git so `git_status` / `git_diff` /
  `apply_patch` work inside the App Store sandbox without spawning `git`.
  License: libgit2 is GPLv2-with-linking-exception. To be reviewed before adoption.

Update this file whenever a dependency is added.
