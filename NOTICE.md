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

## Current Markdown and math renderer integration

The current working tree replaces the former MarkdownUI/highlight.js renderer
stack with an in-tree, thin derivative of Microsoft's
SwiftStreamingMarkdown. The complete buildable derivative is vendored at
`Vendor/SwiftStreamingMarkdown`; the containing Intatis Git revision versions
the source, tests, Microsoft MIT license, and adjacent patch/provenance ledger
together. No separately published Intatis fork is required for reproducible
resolution of this package.

- **SwiftStreamingMarkdown 0.6.0**
  (`microsoft/SwiftStreamingMarkdown`), upstream tag `v0.6.0`, commit
  `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`: MIT. The Intatis candidate is a
  modified derivative whose initial cutover removed optional runtimes and
  branded assets, then selectively restored only exact iosMath 2.5.0 for the
  bounded single-dollar path. It hardens the ownership/concurrency boundary
  and retains the upstream Markdown parser and SwiftUI/AppKit/UIKit rendering
  structure; the removed highlighting, animation, image, citation, and legacy
  regex-math runtimes remain absent.
  **Derivative location: `Vendor/SwiftStreamingMarkdown` in the Intatis root
  revision being built or distributed.**
- **swift-markdown 0.8.0** (`swiftlang/swift-markdown`), revision
  `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`: Apache License 2.0 with the
  Swift Runtime Library Exception. Direct dependency of the derivative.
- **swift-cmark 0.8.0** (`swiftlang/swift-cmark`), revision
  `924936d0427cb25a61169739a7660230bffa6ea6`: BSD-2-Clause core with the
  MIT-derived runtime portions identified by upstream `COPYING`. Transitive
  parser dependency through swift-markdown.
- **iosMath 2.5.0** (`kostub/iosMath`), tag `2.5.0`, commit
  `838cddc01fdd67efd530f8bb67959ad2715f9b06`: MIT. Exact, conditionally linked
  Apple-platform dependency of the derivative for native TeX math parsing and
  layout. iosMath has no transitive package dependency. Its SwiftPM resource
  bundle copies eight OpenType math fonts and their table/license/readme
  resources without modification; four fonts use the GUST Font License
  (LPPL 1.3c or later) and four use the SIL Open Font License 1.1. The copied
  `fonts/` payload is 26 files / 7,234,424 bytes; a built Xcode bundle has 27
  files after the generated root `Info.plist` is included.

Copyright, license, exact upstream/parser versions, distribution requirements,
and the current high-level modification summary are in
`ThirdPartyNotices/MarkdownRendering.md`. The persistent modified-file and
patch ledger is stored beside the vendored source at
`Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md`. The iosMath engine,
font inventory, attributions, shipped GUST notice, and OFL terms are in
`ThirdPartyNotices/MathRendering.md`.

## Feature and asset status

- Syntax highlighting is disabled. The current root dependency graph contains
  no HighlightSwift or highlight.js package, and the former vendored
  `highlight.min.js` and a11y CSS resources are removed. See
  `ThirdPartyNotices/SyntaxHighlighting.md`.
- The Microsoft renderer supports code-aware inline TeX delimited by a normal
  single dollar pair, for example `$x^2$`, through iosMath on macOS and iOS.
  Admission is capped at 32 formulas per message and 8 KiB UTF-8 per formula;
  crossing either cap leaves that message's candidates literal.
  Fenced and inline code remain byte-exact literal text. Block `$$...$$`,
  `\(...\)`, and `\[...\]` forms are not enabled by this first math
  profile and remain literal/ordinary Markdown input. The permanent
  `.plainSafe` mode bypasses Markdown and math parsing entirely.
- The derivative also removes Shimmer, SnapshotTesting, upstream branded color
  and media asset catalogs, and their associated first-release surface. Its
  directly owned package resource remains the localization catalog. iosMath
  separately supplies `iosMath_iosMath.bundle` with its audited math-font and
  license resources.

## Integration and distribution boundary

- Markdown rendering is linked only through `IntatisSharedUI` on Apple
  platforms. It does not add shell, Git, workspace-agent, or Cowork execution
  capabilities to iOS or to the CLI/headless graph.
- Rendering operates on projected message text and does not own or mutate
  EventLog records, capability leases, permission decisions, workspace paths,
  credentials, or provider requests.
- The current first-release profile disables images, citations, animation,
  syntax highlighting, and block math. Single-dollar inline math is native;
  code blocks remain plain text with a native copy control.
- iosMath uses AppKit/UIKit/Core Text and its bundled OpenType math data. It
  does not add a WebView, JavaScript runtime, network request, shell, Git,
  workspace-agent, or Cowork capability. The bundled math fonts are
  typesetting resources and do not change Intatis' separately selected
  product-interface font. Intatis hosts formulas as live TextKit 2 attachment
  views with a 1024×256-point bound, semantic appearance, and Dynamic Type;
  it does not retain a formula raster cache.
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
