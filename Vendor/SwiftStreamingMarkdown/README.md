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
- exact `swift-markdown` 0.8.0 plus Apple-only iosMath 2.5.0; iosMath has no
  transitive package dependency
- headings, emphasis, links, lists, task lists, block quotes, tables,
  thematic breaks, selectable plain code blocks, and exact code copying
- code-aware `$...$` / `\(...\)` inline and `$$...$$` / `\[...\]` display
  math on Apple platforms through a live TextKit 2 `MTMathUILabel` attachment
  provider; formulas preserve their source for literal fallback, copy,
  selection, and accessibility
- Intatis production profile performs no syntax highlighting, image loading,
  or inline citation handling
- no table download/copy actions, bundled media, or paragraph-view reuse cache

The math profile is independently configurable and adds no Intatis-specific
formula-count, per-formula byte, or fixed attachment-size cap. Code, currency,
escaped delimiters, and malformed input stay literal. Formula views follow
their inline/display presentation, semantic appearance, and Dynamic Type.
They are not rasterized or kept in a bitmap cache. The derivative's own UI
font choices remain independent of the eight typesetting fonts distributed by
iosMath.

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
the zero-cache contract, the real code-copy `Button` contract, delimiter and
no-local-cap behavior, final attachments across Markdown structures, live
formula view providers, source-preserving copy/accessibility, and appearance
fallback.

## License and provenance

Upstream code remains covered by Microsoft’s MIT license. The Intatis root Git
revision versions this vendored snapshot and its adjacent modification ledger.
The consuming application must include notices for this derivative,
`swift-markdown`, `cmark-gfm`, iosMath, and iosMath's bundled GUST/LPPL and OFL
font resources. See the root `NOTICE.md` and
`ThirdPartyNotices/MathRendering.md`.
