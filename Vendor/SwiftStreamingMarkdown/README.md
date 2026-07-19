# SwiftStreamingMarkdown — Intatis-maintained vendored derivative

This in-tree package is a dependency-minimal derivative of Microsoft’s
SwiftStreamingMarkdown v0.6.0 for the first Intatis rich-message cutover.
It retains the upstream Markdown parser and native SwiftUI/TextKit rendering
path while deliberately narrowing optional behavior.

The vendored source is maintained with the Intatis repository at
`Vendor/SwiftStreamingMarkdown`. It is not an independently authored Intatis
renderer. Microsoft’s copyright and MIT license remain in `LICENSE`; the exact
upstream basis and all local patch groups are recorded in
`INTATIS_PATCH_LEDGER.md`.

## First-release profile

- macOS 14+ and iOS 16+
- Swift 6.2+ strict concurrency (Xcode 26 or newer)
- `swift-markdown` 0.8.0 as the only package dependency
- headings, emphasis, links, lists, task lists, block quotes, tables,
  thematic breaks, selectable plain code blocks, and exact code copying
- Intatis production profile performs no syntax highlighting, math rendering,
  image loading, or inline citation handling
- no table download/copy actions, bundled media, or paragraph-view reuse cache

The supported off-main boundary is `MarkdownDocumentParser.parse(text:config:)`.
It consumes a parse-only `MarkdownRenderConfig` and returns a `sending`
`RenderableDocument`. The receiving UI controller must be `@MainActor` and
retain the document there. Create a separate display configuration; do not
share the parse configuration with UI state.

`RenderableDocument`, `MarkdownRenderable`, and the render configuration are
intentionally not `Sendable`. No unchecked or unsafe concurrency escape hatch
is part of this package.

## Validation

Run the strict Release test suite:

```sh
swift test -c release \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency \
  -Xswiftc -warnings-as-errors
```

The package test target covers parser rewrites, task lists, tables, TextKit
attribute types, paragraph measurement, the ownership-transfer boundary,
the zero-cache contract, and the real code-copy `Button` contract.

## License and provenance

Upstream code remains covered by Microsoft’s MIT license. The Intatis root Git
revision versions this vendored snapshot and its adjacent modification ledger.
The consuming application must include notices for this derivative,
`swift-markdown`, and `cmark-gfm`.
