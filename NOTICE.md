# NOTICE

## Project origin and source-reuse policy

Intatis is an Apple-first, Swift-native-first local AI workbench. Project-owned
code and assets are original unless an upstream source is identified here.
Compatible open-source work may be linked, vendored, or modified only after
its provenance and licenses have been reviewed under
`docs/OPEN_SOURCE_REUSE.md`.

Intatis does not use leaked or private source code or prompts, and does not use
third-party names, logos, icons, screenshots, UI assets, trademarks, or brand
copy as its product identity. Open-source reuse does not bypass Intatis'
permission, workspace, event-log, secret, or Apple-platform boundaries.

## Current Markdown renderer integration

The current working tree replaces the former MarkdownUI/highlight.js/iosMath
stack with an in-tree, thin derivative of Microsoft's SwiftStreamingMarkdown.
The complete buildable derivative is vendored at
`Vendor/SwiftStreamingMarkdown`; the containing Intatis Git revision versions
the source, tests, Microsoft MIT license, and adjacent patch/provenance ledger
together. No separately published Intatis fork is required for reproducible
resolution of this package.

- **SwiftStreamingMarkdown 0.6.0**
  (`microsoft/SwiftStreamingMarkdown`), upstream tag `v0.6.0`, commit
  `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`: MIT. The Intatis candidate is a
  modified derivative that removes optional runtimes and branded assets,
  hardens the ownership/concurrency boundary, and retains the upstream
  Markdown parser and SwiftUI/AppKit/UIKit rendering structure.
  **Derivative location: `Vendor/SwiftStreamingMarkdown` in the Intatis root
  revision being built or distributed.**
- **swift-markdown 0.8.0** (`swiftlang/swift-markdown`), revision
  `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`: Apache License 2.0 with the
  Swift Runtime Library Exception. Direct dependency of the derivative.
- **swift-cmark 0.8.0** (`swiftlang/swift-cmark`), revision
  `924936d0427cb25a61169739a7660230bffa6ea6`: BSD-2-Clause core with the
  MIT-derived runtime portions identified by upstream `COPYING`. Transitive
  parser dependency through swift-markdown.

Copyright, license, exact upstream/parser versions, distribution requirements,
and the current high-level modification summary are in
`ThirdPartyNotices/MarkdownRendering.md`. The persistent modified-file and
patch ledger is stored beside the vendored source at
`Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md`.

## Features and assets not distributed by the current renderer

- Syntax highlighting is disabled. The current root dependency graph contains
  no HighlightSwift or highlight.js package, and the former vendored
  `highlight.min.js` and a11y CSS resources are removed. See
  `ThirdPartyNotices/SyntaxHighlighting.md`.
- TeX/math rendering is disabled. The current root dependency graph contains
  no iosMath package, and no iosMath fonts or math resources are bundled. See
  `ThirdPartyNotices/MathRendering.md`.
- The derivative also removes Shimmer, SnapshotTesting, upstream branded color
  and media asset catalogs, and their associated first-release surface. Its
  retained package resource is the localization catalog only.

## Integration and distribution boundary

- Markdown rendering is linked only through `IntatisSharedUI` on Apple
  platforms. It does not add shell, Git, workspace-agent, or Cowork execution
  capabilities to iOS or to the CLI/headless graph.
- Rendering operates on projected message text and does not own or mutate
  EventLog records, capability leases, permission decisions, workspace paths,
  credentials, or provider requests.
- The current first-release profile disables images, citations, animation,
  syntax highlighting, and math. Code blocks remain plain text with a native
  copy control.
- Distributed macOS and iOS artifacts must make this file and the referenced
  detailed notices readable in the application. Merely keeping them in the
  source tree is not sufficient.
- A distributed source or binary must be traceable to an Intatis root revision
  containing the vendored package, its Microsoft `LICENSE`, and the adjacent
  patch ledger. Uncommitted local edits are not a release identity.

## Other source status

- OpenCode (`anomalyco/opencode`, MIT) remains research-only. No OpenCode
  source, public prompt, UI asset, or runtime is currently linked, vendored, or
  copied into Intatis.
- `CodeEditor` (`mchakravarty/CodeEditor`) was evaluated but is not adopted,
  linked, vendored, or copied.
- libgit2 / SwiftGit2 remain planned candidates only and require a separate
  license and integration review before adoption.

The Swift standard library, Foundation, SwiftUI, AppKit, UIKit, and other Apple
system frameworks are provided by the Apple toolchain and are not vendored
third-party packages in this repository.

Update this file whenever an upstream source, dependency, bundled runtime,
licensed asset, or immutable renderer revision changes.
