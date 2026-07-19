# Intatis SwiftStreamingMarkdown Vendored Patch Ledger

> **PERMANENT PROVENANCE RECORD.** Keep this file beside the vendored source,
> update it whenever the upstream basis or local patches change, and retain the
> Microsoft MIT license in `LICENSE`.

This ledger describes the Intatis-maintained vendored derivative of Microsoft
SwiftStreamingMarkdown. The vendored snapshot lives at
`Vendor/SwiftStreamingMarkdown` and is versioned by the containing Intatis Git
revision. It is third-party-derived code, not independently authored Intatis
renderer code.

## Provenance and toolchain contract

- Upstream tag: `v0.6.0`
- Upstream commit: `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`
- Package tools contract: Swift tools 6.2 or newer; Swift language mode 6
- Intended Apple toolchain: Xcode 26 or newer
- Supported deployment targets: macOS 14 or newer and iOS 16 or newer
- Direct package dependency: `swift-markdown` 0.8.0,
  revision `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`
- Transitive parser dependency: `swift-cmark` 0.8.0,
  revision `924936d0427cb25a61169739a7660230bffa6ea6`

`swift-markdown` 0.8.0 itself uses a Swift 6.2 tools manifest but explicitly
declares `swiftLanguageModes: [.v5]`. The derivative is Swift 6; the parser
dependency is compiled in its declared Swift 5 mode. Do not globally override
the complete dependency graph to Swift 6: doing so exposes upstream Sendable
errors and is not a supported validation configuration.

Do not advertise Swift 6.0 compatibility. The public ownership-transfer API
uses `@concurrent`, so the package manifest and consumer documentation must
retain the Swift 6.2+ requirement.

## Patch groups

### 1. Dependency and resource thinning

Paths:

- `Package.swift`
- `Package.resolved`
- `README.md`
- `Sources/MarkdownText/Resources/Assets.xcassets/**` (deleted)
- `Sources/MarkdownText/Resources/Media.xcassets/**` (deleted)
- `Sources/MarkdownText/Resources/Localizable.xcstrings` (retained)

Changes and reason:

- Remove HighlightSwift, iosMath, Shimmer, SnapshotTesting, and their
  transitive first-release surface.
- Pin `swift-markdown` exactly to 0.8.0 because its malformed-table handling is
  required by the retained table path.
- Remove branded color/media assets instead of compiling or excluding dead
  payload. A SwiftPM build bundle contains only `Info.plist` and
  `Localizable.xcstrings`; Xcode compiles the same catalog to localized
  `*.lproj/Localizable.strings`. Neither form may contain image/color assets.

Regression obligations:

- Resolve from an empty package cache using the pinned graph.
- Inventory the macOS and iOS resource bundles after Release builds.
- Preserve MIT and dependency notices in the consuming application.

### 2. Audited ownership-transfer boundary

Paths:

- `Sources/MarkdownText/Parser/MarkdownParser.swift`
- `Sources/MarkdownText/Parser/MarkdownParserImpl.swift`
- `Sources/MarkdownText/Models/RenderableDocument.swift`
- `Sources/MarkdownText/Models/MarkdownRenderable.swift`
- `Sources/MarkdownText/Models/MarkdownRenderConfig.swift`
- `Sources/MarkdownText/Style/TextFonts.swift`
- font/configuration support files under `Sources/MarkdownText/**`

Changes and reason:

- Make `MarkdownDocumentParser.parse(text:config:)` an `@concurrent`
  operation taking `sending MarkdownRenderConfig` and returning
  `sending RenderableDocument`.
- Construct the parser locally in the worker and transfer the completed result
  once to a receiving `@MainActor` owner.
- Make `RenderableDocument` a non-`Sendable` final class. A copyable struct
  wrapper around mutable attributed-string references does not provide an
  identity-level transfer guarantee.
- Remove all package-owned `@unchecked Sendable`, `nonisolated(unsafe)`, and
  `@preconcurrency` escape hatches.
- Keep the parser and renderable document out of actors, AsyncStreams, and
  scheduler state. A scheduler may hold only Sendable permits/generations while
  the awaiting task retains its candidate locally.

Regression obligations:

- Strict Swift 6.2 Release compile with complete concurrency checking,
  concurrency warnings, and warnings as errors.
- A headless probe must parse off-main, cross a Sendable-only gate, then install
  the document on the main actor.
- A source scan must find no package-owned unchecked/unsafe concurrency marker.

### 3. Main-actor compatibility controllers

Paths:

- `Sources/MarkdownText/MarkdownView.swift`
- `Sources/MarkdownText/StreamedMarkdownView.swift`
- `Sources/MarkdownText/Utilities/MarkdownListener.swift`
- `Sources/MarkdownText/UI/DocumentView.swift`

Changes and reason:

- Isolate convenience controllers/listeners to `@MainActor`.
- Remove the document-bearing `AsyncStream`; render callbacks are synchronous
  on the main actor.
- Route convenience views through the internal `parseOnMain` compatibility
  path so caller-supplied fonts and display configuration are preserved.
- Reserve the public `@concurrent` transfer boundary for Intatis' external
  parse scheduler. Intatis must own the result on `@MainActor` and retain a
  distinct display configuration.

Regression obligations:

- Verify a custom platform paragraph font survives the convenience-view path.
- Verify streamed updates cannot retain or forward documents through an
  AsyncStream or actor mailbox.

### 4. Disabled first-release features

Paths:

- `Sources/MarkdownText/Parser/MarkdownParseOption.swift`
- `Sources/MarkdownText/Parser/LaTexPreProcessor.swift` (deleted)
- `Sources/MarkdownText/Models/LatexAttachmentData.swift` (deleted)
- `Sources/MarkdownText/UI/BlockMathView.swift` (deleted)
- `Sources/MarkdownText/UI/Paragraph/LatexViewProvider.swift` (deleted)
- `Sources/MarkdownText/UI/HighlightTaskManager.swift` (deleted)
- math/highlight branches in block, inline, config, and view sources

Changes and reason:

- Delete math and syntax-highlighting implementations and APIs.
- Force animation, citations, and images off in
  `firstReleaseParseConfiguration()` for the production off-main parser.
- Keep any still-compiled legacy image/citation compatibility source out of the
  Intatis production parse profile; it is not a first-release capability.

Regression obligations:

- Contract-test the forced-off production parse configuration.
- Scan the production dependency graph and source tree for removed optional
  runtimes and branded assets.

### 5. Native code-copy control and accessibility

Paths:

- `Sources/MarkdownText/UI/CodeBlockView.swift`
- `Sources/MarkdownText/Models/CodeBlockConfig.swift`

Changes and reason:

- Replace the gesture-only copy target with a real SwiftUI `Button`, plain
  style, content shape, and accessibility label.
- Preserve byte-exact clipboard writes and the existing copy callback.
- Reduce code-block configuration to retained chrome foreground/background
  colors; remove highlight-theme CSS.
- Neutralize the private select-more context-menu sentinel from the upstream
  reverse-DNS brand to `SwiftStreamingMarkdown.textSelection.selectMore`. The
  value is internal routing state, not a persisted/public identifier, so no
  compatibility reason justifies retaining `com.microsoft` in the derivative.

Regression obligations:

- Source contract verifies `Button`, plain style, accessibility label, exact
  platform clipboard calls, and absence of `onTapGesture` in the copy control.
- Manual VoiceOver and keyboard activation remain required before release.

### 6. Zero native-view retention cache

Path:

- `Sources/MarkdownText/UI/Paragraph/ParagraphViewCache.swift`

Changes and reason:

- Set the retention budget to exactly zero: every request creates a fresh
  native paragraph view and `clearCache()` is a no-op.
- This removes `ParagraphViewCache` itself as a retention source. It does not
  prove that the surrounding SwiftUI/TextKit/AppKit/UIKit view graph has
  bounded memory: repeated representable recreation can still allocate fresh
  native views faster than the framework releases prior graph generations.

Regression obligations:

- Assert two cache requests return distinct native view identities.
- Treat a zero cache as one ownership boundary, not as a whole-view-graph
  memory proof. Measure long-session memory, CPU, recreation rate, and
  scrolling on representative macOS hardware; the policy trades cache
  retention for additional allocation work when a parent graph is unstable.

### 7. Swift 6 actor/lifecycle hardening

Paths:

- `Sources/MarkdownText/ContextMenu/TextContextMenu.swift`
- `Sources/MarkdownText/TextTransition/FadeInTextTransitionViewModifier.swift`
- `Sources/MarkdownText/UI/OrderedListView.swift`
- `Sources/MarkdownText/UI/TableView.swift`
- paragraph AppKit/UIKit sources
- deprecated change-observer call sites under `Sources/MarkdownText/**`

Changes and reason:

- Main-actor isolate platform UI operations and context-menu construction.
- Main-actor isolate the Debug-only mutable-attributed-string table fixtures;
  this fixes their Swift 6 shared-global diagnostic without changing table
  layout or production behavior.
- Use isolated deinitializers for native paragraph views.
- Compute platform-font metrics before Sendable closures.
- Replace deprecated change observers with task identity where appropriate.

Regression obligations:

- macOS and iOS strict Release builds with warnings treated as errors.
- Lifecycle stress testing while rapidly replacing streamed documents.

### 8. View diff, layout invalidation, and selection-overlay hardening

Paths:

- `Sources/MarkdownText/UI/DocumentView.swift`
- `Sources/MarkdownText/UI/Paragraph/AppKit/ParagraphView+macOS.swift`
- `Sources/MarkdownText/UI/Paragraph/AppKit/ParagraphNSView.swift`
- `Sources/MarkdownText/UI/Paragraph/UIKit/ParagraphView+iOS.swift`
- `Sources/MarkdownText/UI/Paragraph/UIKit/ParagraphUIView.swift`
- `Sources/MarkdownText/UI/TableView.swift`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift`
- `Tests/MarkdownTextTests/ParagraphNSViewTests.swift`
- `Tests/MarkdownTextTests/ParagraphUIViewTests.swift` (added)
- `Tests/MarkdownTextTests/ViewEquatableContractTests.swift` (added)
- `Tests/MarkdownTextTests/FirstReleaseContractTests.swift`
- `Packages/IntatisSharedUI/Tests/MessageRenderingTests.swift`

Changes and reason:

- Restore hand-written `Equatable` conformances for `DocumentView` and the
  AppKit/UIKit `ParagraphView` representables. These preserve the upstream
  `@Equatable` diffing semantics without restoring the removed macro
  dependency: controller state is ignored, while document/configuration or
  paragraph contents/line spacing remain part of equality.
- Track the last valid laid-out paragraph width independently from the
  intrinsic-size cache. A stable positive width does not repeatedly invalidate
  intrinsic size; zero, negative, NaN, and infinite widths clear the width
  tracker without invalidating. Returning through
  `valid -> zero -> same valid` therefore forces exactly one fresh measurement
  instead of either retaining a screen-width fallback or opening a stable-zero
  invalidation path. The AppKit and UIKit implementations have the same
  contract.
- Remove the Intatis facade's whole-rich-document
  `.textSelection(.enabled)` modifier. Native paragraph views remain directly
  selectable, while selection for plain fallback text and SwiftUI-only table
  and code text is retained at those leaf views. This avoids wrapping native
  selectable paragraph representables in a second SwiftUI `SelectionOverlay`
  without silently dropping the product selection contract.

Regression obligations:

- Assert `DocumentView` equality ignores its controller and tracks document
  plus configuration; assert both platform paragraph wrappers track attributed
  contents plus line spacing.
- Count intrinsic-size invalidations across stable positive width, stable zero
  width, a real width change, and `valid -> zero -> same valid` on both AppKit
  and UIKit.
- Source-contract test that the rich facade has no whole-document selection
  modifier, while plain fallback, table text leaves, and code text retain
  selection.
- Passing unit tests are necessary but not sufficient: repeat bounded,
  watchdog-controlled on-window memory/CPU validation before changing the
  release disposition below.

### 9. Test-suite routing

Paths:

- `Tests/MarkdownTextTests/FirstReleaseContractTests.swift` (added)
- `Tests/MarkdownTextTests/ParagraphNSViewTests.swift`
- `Tests/MarkdownTextTests/ParagraphUIViewTests.swift` (added)
- `Tests/MarkdownTextTests/ViewEquatableContractTests.swift` (added)
- `Tests/MarkdownTextTests/MarkdownParserTests.swift`
- retained focused parser, link, task-list, TextKit, and rewrite tests
- obsolete optional-feature/snapshot tests and `__Snapshots__/**` (deleted)

Changes and reason:

- Compile every remaining test source; do not hide files with a manifest
  allowlist or `exclude` gate.
- Replace removed math/image/citation/highlight/snapshot suites with focused
  first-release ownership, profile, zero-cache, code-copy, table, font, and
  parser contracts.
- Cover the restored view-diff guards, stable-width/zero-width layout
  invalidation contract, and selection-overlay ownership described above.
- Snapshot image deletions are mechanical repository thinning and must be
  counted separately from renderer implementation changes.

Regression obligations:

- Run the full retained Release suite under strict concurrency and warnings as
  errors on macOS.
- Add Intatis-level golden rendering, streaming replacement, selection/copy,
  tables, accessibility, and memory/performance coverage before cutover.
- Keep large SwiftUI host tests offscreen in headless XCTest. The same
  on-window teardown pattern reproduces an optimized-XCTest `objc_release`
  crash in both the reference matrix and derivative matrix. That comparison
  invalidates the headless `NSWindow` harness; it is not evidence attributing a
  renderer defect to either implementation. Validate real window open/close in
  a signed GUI host through Computer Use.

## Current validation evidence

All evidence below was produced with Swift 6.3.3 / Xcode 26.6. The release
hygiene checks were repeated after removing the scratch probes. Re-run the
same checks whenever this vendored snapshot or its exact parser pins change.

- Post-hygiene `swift package dump-package` reports exactly one library
  product, one regular library target, and one test target; no executable
  product or target remains.
- Fresh post-hygiene macOS Debug and Release SwiftPM resolutions fetched both
  dependencies from an isolated local cache at the exact revisions above.
  After the view-diff/layout/selection hardening in patch group 8, the current
  snapshot reran strict concurrency, concurrency warnings, and Swift
  warnings-as-errors in both configurations. Each ran all 38 XCTest tests and
  six Swift Testing tests (44 total per configuration, zero failures).
- The retained suite plus Phase-2 corpus passed: malformed and streaming table
  prefixes; byte-exact LaTeX delimiters inside fenced/inline code; disabled
  image matrix; six link schemes; 100 KiB and 256 KiB Markdown; 71,680-byte
  code; offscreen large SwiftUI hosts; and light/dark/resize host lifecycle.
- A separate headless consumer resolved the local derivative plus both exact
  remote pins from a fresh scratch directory, built strict Release with Swift
  warnings-as-errors, and printed `HEADLESS_CONSUMER_OK`.
- An independent minimal app rebuilt Release after release hygiene and had
  previously built Debug for `generic/platform=iOS` without signing, resolving
  the same exact graph. A separate arm64 iOS library-only SwiftPM build passed
  strict concurrency and Swift warnings-as-errors. The generic Xcode builds
  respect the dependency's declared Swift 5 language mode; they must not be
  described as all-dependencies Swift-6 builds.
- Before its required removal, the scratch-only output-free scheduler
  integration executable built under the same strict flags and printed
  `SENDING_BOUNDARY_OK`.
- Source scans found no package-owned unchecked/unsafe concurrency escape,
  removed optional runtime name, branded private identifier, or
  document-bearing AsyncStream/actor storage.

### Adverse GUI validation evidence and release disposition

The latest on-window validation did **not** pass. On 2026-07-18, three
`Intatis Renderer Validation` instances were accidentally allowed to coexist.
The macOS Force Quit UI reported **129.63 GB of application memory** for the
dominant instance. That number is a macOS UI value; it must not be restated as
an exact RSS, footprint, or byte count.

System CPU diagnostic incident
`FA228932-2C40-4AC2-A0C2-62EF41342B4A` covers 160 seconds, records 90 seconds of
CPU use (about 56%), and shows its sampled footprint increasing from
109.16 MB to 803.30 MB. Heavy stacks include SwiftUICore, AttributeGraph, lazy
layout, `ParagraphView` copy/destruction, and `SelectionOverlay`. This proves
uncontrolled renderer/UI lifecycle growth in that validation process. It does
not identify the final retaining edge, and the root cause remains
**UNKNOWN**; attributing the incident solely to Microsoft, the parser,
Computer Use, or a particular Apple framework leak would overstate the
evidence.

Patch group 8 addresses a high-confidence amplification path: lost upstream
diff guards, stable-width intrinsic-size invalidation, and a duplicate rich
whole-document selection overlay. The strict unit suites, Intatis focused
tests, iOS test-target compilation, and non-GUI product builds verify those
contracts, but they do not supersede the adverse on-window evidence. The
latest Computer Use result is therefore **FAIL / ABORTED**, and the current
release disposition remains **NO-GO** until a single-instance,
watchdog-controlled GUI rerun demonstrates bounded memory/CPU and the required
selection/copy/accessibility behavior.

Warm offscreen single-paragraph plain-text timings (parse plus host, six
Release samples across two test processes, each after an explicit 1 KiB
warm-up) were:

| Input | Median | Maximum |
| --- | ---: | ---: |
| 16 KiB | 7.130 ms | 8.993 ms |
| 32 KiB | 12.276 ms | 12.612 ms |
| 48 KiB | 17.363 ms | 17.475 ms |
| 64 KiB | 22.214 ms | 22.374 ms |
| 96 KiB | 32.324 ms | 32.672 ms |

The first exploratory run without an in-process warm-up observed a 129.707 ms
16 KiB cold-start maximum. Also, byte count alone does not bound Markdown block
complexity: the 100 KiB and 256 KiB syntax-dense hosts took about 2.27 seconds
and 12.15 seconds respectively. A syntax-agnostic whole-message admission cap
therefore needs a conservative fallback policy; these plain-text figures are
not a general renderer latency guarantee.

## Upstream issue mapping

Only issues that materially intersect this patch are listed:

- `microsoft/SwiftStreamingMarkdown#73`: malformed/extra-pipe table parsing.
  The fork's `swift-markdown` 0.8.0 pin is part of the required fix evidence.
- `microsoft/SwiftStreamingMarkdown#124`: safely making font-holding
  configuration Sendable. This fork deliberately chooses non-Sendable config
  plus `sending` transfer instead of introducing an unchecked font wrapper.
- `microsoft/SwiftStreamingMarkdown#144`: asynchronous controller lifecycle.
  It motivates lifecycle work but does not by itself establish this fork's
  no-document-AsyncStream or ownership-transfer architecture.

New upstream issues or PRs should be proposed for:

- a non-copyable-in-practice `sending` parser/document ownership boundary;
- removal of renderable documents from AsyncStream/controller mailboxes;
- configurable paragraph-view cache budget, including zero;
- an accessible native code-copy button;
- a supported dependency-minimal feature/resource profile;
- strict Swift 6.2 concurrency without unchecked escape hatches.

Do not claim upstream coverage from issue numbers whose exact relevance has not
been verified.

## Import and release-hygiene disposition

The following compiler/integration probe artifacts were local evidence and
have been removed from the package before final validation; they must not be
restored or shipped in the vendored library package:

- `SendingProbe.swift`
- `StructAliasProbe.swift`
- `IntegrationProbe.swift`
- `IntegrationNegativeProbe.swift`
- `ProbeExecutable/**`
- the `SendingIntegrationProbe` executable product/target in `Package.swift`

The vendored package includes
`Tests/MarkdownTextTests/CandidatePhase2MatrixTests.swift` and
`Tests/MarkdownTextTests/FirstReleaseContractTests.swift`; these retained
regression tests are compiled by the sole test target. This ledger is included
as the adjacent provenance record. The import intentionally excludes the
upstream `.git`, build caches, automation/agent instructions, empty probe
directory, and the non-production `Examples` tree with branded configuration,
fonts, and sample media.

The Intatis root revision is the immutable identity for a distributed source
snapshot. Before release, rerun resolution, strict Mac/iOS builds, tests,
license/brand scans, and bundle inventory against that exact root revision.

## Upstream delta accounting at vendored import

These numbers describe the audited source delta imported from the candidate
tree relative to upstream `v0.6.0`; recompute them whenever the vendored source
or upstream basis changes:

- Tracked total: 331 files, 325 insertions, 5,616 deletions.
- Renderer/package source excluding `Resources/**`: 39 text files, 269
  insertions, 1,142 deletions.
- Production resources: 54 tracked asset/media files deleted; only the
  localization catalog remains.
- Tracked test cleanup: 235 files changed/deleted, including 213 binary
  snapshots; remaining tracked text delta is 2 insertions and 3,168 deletions.
- New retained validation sources, not included in Git's unstaged diff count:
  `CandidatePhase2MatrixTests.swift` (342 lines) and
  `FirstReleaseContractTests.swift` (111 lines).
- Scratch-only probe source and the public probe product/target have been
  removed; they contribute zero files to the release candidate.

The 54 resource deletions and 235 test/snapshot changes are mechanical
repository thinning. They must not be presented as 289 files of renderer
redesign; the auditable implementation surface is the 39-file source delta
above, plus manifest/README and the two new test files.

## Conditions for deleting the fork patch

Replace this derivative with an official release only when one audited upstream
revision provides all of the following, or equivalent demonstrably safe APIs:

1. `swift-markdown` 0.8.0 or newer and the required malformed-table behavior.
2. Strict Swift 6.2+ concurrency with no unchecked/unsafe assertion on the
   parser/config/document transfer boundary.
3. Supported off-main parse followed by single-owner `@MainActor` installation,
   without document-bearing actor or AsyncStream storage.
4. Optional math, highlighting, images, citations, branded resources, and
   associated dependencies removable or completely absent from the Intatis
   build artifact.
5. A bounded paragraph-view cache with a supported zero-retention mode.
6. A native, keyboard- and accessibility-operable, byte-exact code-copy button.
7. Passing strict Mac/iOS builds plus functional, accessibility, memory, and
   streaming-performance evidence at least equivalent to the fork.

When every condition is met, pin the official immutable revision, update
notices and provenance, rerun the full Intatis cutover suite, and delete the
corresponding local patch groups rather than carrying duplicate implementations.
