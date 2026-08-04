# Design QA — permission review and conversation chrome

文档状态：截至 2026-08-02 的历史视觉验证日志
当前产品版本与 UI 规范分别见 `docs/VERSIONING.md` 和
`docs/CURRENT_UI_COLOR_SYSTEM.md`；本文中的日期、截图和结果只证明对应构建。

Date: 2026-08-01

## Scope

- Make the permission review surface quieter and integrated with the existing system-material conversation design.
- Remove the redundant `You` header from user bubbles without removing assistant/agent/system identity.
- Remove `Local AI workbench` beneath the macOS sidebar title.
- Keep active Chat/Code/Cowork session headers title-only and remove the gray metadata row beneath every sidebar Recent session name.

## Comparison inputs

- Permission reference: `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_dv3KRW/Screenshot 2026-07-31 at 17.39.50.png`.
- Permission implementation, collapsed: `/Users/vita/.codex/visualizations/2026/07/31/019fb6e9-d207-7f11-b7f1-078a6e77ed93/permission-card-collapsed.png`.
- Permission implementation, expanded/automatic/resolved/dark: the sibling `permission-card-expanded.png`, `permission-card-automatic.png`, `permission-card-resolved.png`, and `permission-card-dark.png` files in that directory.
- Chat/sidebar reference: `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_9v6CLl/Screenshot 2026-07-31 at 14.43.13.png`.
- Chat/sidebar implementation: `/Users/vita/.codex/visualizations/2026/07/31/019fb6e9-d207-7f11-b7f1-078a6e77ed93/chat-user-bubble.png`.
- Session-metadata source truth: `/Users/vita/.codex/visualizations/2026/07/31/019fb6e9-d207-7f11-b7f1-078a6e77ed93/chat-user-bubble.png`, with the explicit target delta to remove the gray provider/model/host line beneath the active session title and the event/date/path line beneath every Recent session title.
- Session-metadata implementation: `/Users/vita/.codex/visualizations/2026/07/31/019fb6e9-d207-7f11-b7f1-078a6e77ed93/session-titles-clean.png`.
- The session source and implementation are both 1100 × 760 native macOS captures at the same application viewport and Light appearance. No density normalization was needed. The transcript scroll position differs, but both title regions are fully visible and directly comparable.
- Each reference and its implementation screenshot were opened together in one comparison input. The permission reference is the reported incident state while the implementation uses a deterministic offline permission request; copy/data differ, so the comparison judges hierarchy, exposure, density, semantic color and control visibility rather than text identity.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Permission UI no longer dominates the transcript | Passed | The card is left-aligned and width-bounded; the whole-card red outline is gone. Risk color is limited to the lock icon and small chip. |
| Long review context is progressive disclosure | Passed | Tool/reason/status/actions remain visible; structured action/resource and patch are behind a collapsed `Details` disclosure. |
| Details remain secret-safe | Passed | Generic details consume structured authorization preview/intent/resources/touched paths. A focused test proves raw secret-like args are excluded. |
| Manual permission semantics remain clear | Passed | Approve Call, Decline Call and Cancel Turn remain separate accessible buttons; the approved state becomes a compact notice. |
| Automatic review is non-actionable | Passed | Automatic mode shows progress and no manual approve/decline/cancel controls. |
| Light and Dark use native hierarchy | Passed | The same system Material, semantic text, accent and status colors remain legible in both fixture appearances. |
| User bubbles omit `You` | Passed | The real-history Chat capture shows a trailing user bubble whose first visible content is the message; the adjacent assistant keeps `Intatis` and timestamp. |
| Sidebar subtitle is removed | Passed | The current app capture shows only `Intatis` above the mode rows, with history and Settings unchanged. |
| Active session headers are title-only | Passed | The real-history Chat capture exposes only `sess_muftosxo`; the former `Kimi K3 · Moonshot CN · api.moonshot.cn` line is absent. Code and Cowork pass the same nil-subtitle contract to the shared production header. |
| Recent session rows are title-only | Passed | Chat and Cowork runtime captures show one line per session; event count, timestamp, workspace path and runtime-state metadata are absent while selection, icons, New, Rename/Delete affordances and Settings remain unchanged. |

## Required fidelity surfaces

- Fonts and typography: existing serif session-title and system session-row fonts, sizes and weights are unchanged; only the requested secondary text is removed.
- Spacing and layout rhythm: both title stacks collapse without an empty subtitle row; sidebar rows become compact single-line entries with their existing padding and selection outline.
- Colors and tokens: no color, Material, semantic state or glass token changed.
- Image and asset fidelity: no image, logo or icon asset was introduced, removed or substituted; existing SF Symbols remain unchanged.
- Copy and content: only session-adjacent gray metadata is suppressed. Settings/home explanatory subtitles and assistant/agent identity remain because they are not session-title metadata.

## Severity review

- P0: none.
- P1: none.
- P2: none within the requested scope.
- Remaining matrix, not a discovered mismatch: Reduce Transparency, Increase Contrast, very narrow permission-card layout, a live active Code session, and a live Cowork pending permission backed by a real provider remain `UNKNOWN`.

## Validation loop

1. Built an unsigned Developer ID Debug app with a unique bundle identifier and no debug dylib indirection.
2. Launched the production `PermissionCard`/notice through the DEBUG-only offline Phase C fixture; checked collapsed, expanded, automatic, approved, Light and Dark states through accessibility and pixels.
3. Launched the same current build against existing Chat history without clicking Send; navigated to a real user/assistant boundary and captured the sidebar and user bubble.
4. Put the two user references and their corresponding implementation captures into paired visual comparison inputs, then rechecked spacing, hierarchy, semantic color, labels and control availability.
5. Confirmed the fixture created no provider, EventLog, credential resolver, responder or executor. No provider request was sent during the real-history read-only check.
6. Built a fresh unique-bundle production app, opened the existing Chat history read-only and captured the 1100 × 760 title-only result. Switched to Code and Cowork without creating a session; Cowork Recent rows were also visually confirmed as title-only. The focused title regions were fully readable in the full-view pair, so a separate crop was unnecessary.

## Comparison history

- Initial 2026-07-31 pass removed `You`, the sidebar brand subtitle and permission-card visual dominance; no P0/P1/P2 issue remained.
- The 2026-08-01 user delta identified two remaining secondary-metadata surfaces. Both were removed, the app was rebuilt, and the paired post-fix capture shows no empty subtitle row or remaining Recent-row detail. No new P0/P1/P2 issue was found.

final result: passed

# Design QA — Cowork integrated rail and Agent communication

Date: 2026-08-02

## Scope

- Merge the wide Cowork status rail into the conversation canvas: no divider and no independent
  rail backing surface; only the native Liquid Glass sections retain boundaries.
- Keep the primary thread scroller at the far-right detail edge and prevent the overlay rail from
  intercepting that edge.
- Present generic Agent-to-Agent messages and information request/reply events as ordinary agent
  answers, with exact `sender->recipient` identity and no card.

## Comparison inputs

- Reference: the user-supplied
  `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_1wPkBG/Screenshot 2026-08-02 at 22.21.43.png`.
- Latest native build capture:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-integrated-agent-communication-final.jpeg`.
- Agent-row capture from the same implementation before the final hit-test-only rail-edge
  refinement:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-integrated-agent-communication.jpeg`.
- Combined reference/latest/row-style comparison inspected in one image input:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-integrated-comparison-final.jpeg`.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Rail and transcript share one canvas | Passed | The latest wide native capture has no vertical separator and no full-height `.bar`/Material rail backing; only the permission, Agents and Tasks glass sections remain bounded. |
| Primary scrollbar owns the far-right edge | Passed | The final AX tree exposes the main thread scroll area and its native scrollbar independently from `cowork.inspector`; the thread viewport spans the detail width, while a non-hit-testing transparent rail-edge clearance prevents the overlay from intercepting the scroller. `ThreadLayoutTests` freezes this source contract. |
| Agent communication is not carded | Passed | The Agent-row capture shows the task report directly on the system canvas with the same typography and width policy as a normal agent answer, without the previous cyan/structured card. |
| Identity is exact and directional | Passed | The capture and final-build AX tree both expose `doc-reader->main`; projection tests cover generic Agent message, Agent-to-Agent message, information request and information reply as exact `sender->recipient`. |
| Existing rail content remains intact | Passed | Permission status remains first, followed by Agents and Tasks in this session; no Git section, workspace path or Git control is present. |
| Runtime and security semantics are unchanged | Passed | The change is limited to projection titles and SharedUI presentation/layout. EventLog payloads, Mediator, permissions, leases, scheduling and tool execution were not changed. |

## Severity review

- P0: none.
- P1: none.
- P2: none on the tested wide Dark Cowork state.
- Narrow-width behavior was not changed in this slice; its earlier permission fallback and
  no-duplicate Goal/Tasks checks remain the recorded baseline.

## Validation loop

1. Inspected the supplied reference and mapped the divider, rail backing, primary scrollbar,
   Agent communication card and identity label to their current SwiftUI/projection owners.
2. Replaced the Cowork split presentation with a trailing overlay, reserved body width through
   scroll-content margin, and added an edge pass-through for the primary scroller.
3. Routed Agent communication rows through the normal agent answer surface and normalized four
   communication event kinds to directional identity.
4. Built and launched a uniquely identified ad-hoc QA copy of the latest IntatisMac Debug app,
   opened the existing `Test` Cowork session, widened the window and inspected the real rail,
   transcript, primary scroll area and Agent event accessibility tree without sending a message.
5. Compared the reference, latest rail capture and Agent-row capture together. No tested-surface
   P0/P1/P2 mismatch remains.

## Build and test evidence

- Targeted SwiftPM regression: 32 tests / 0 failures across
  `ExecutionTracePresentationTests`, `IntatisConversationCodeTests` and `ThreadLayoutTests`.
- Latest `IntatisMac` macOS Debug Xcode build: `BUILD SUCCEEDED` with local ad-hoc signing.
- Native read-only QA confirmed `doc-reader->main`, ordinary answer rendering, no divider/backing
  rail, permission-first glass cards and no Git surface.
- No provider request, permission decision, message send or durable Cowork state mutation was
  performed during QA.

final result: passed

# Design QA — Cowork permission-first Liquid Glass rail

Date: 2026-08-02

## Scope

- Remove Git presentation from the Cowork trailing rail without removing permission-gated Agent
  Git tools.
- Move the permission review surface to the first rail position while preserving the existing
  permission projection, actions and automatic-review behavior.
- Replace the flat gray status boxes with native macOS Liquid Glass in Light and Dark appearance.

## Comparison inputs

- Reference / before state:
  `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_ZacIZr/Screenshot 2026-08-02 at 11.45.06.png`
  (3024×1898 pixels).
- Final Light implementation:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-permission-rail-light.png`
  (1372×768 pixels).
- Final Dark implementation:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-permission-rail-dark.png`
  (1373×768 pixels).
- The before image and both final images were opened together in one comparison input. The current
  display cannot reproduce the reference's larger viewport, so this is a comparable wide-state
  hierarchy/material review rather than a claim of pixel identity.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Git is gone from the Cowork rail | Passed | Neither final appearance contains a Git card, branch icon, workspace path, `status only`, or Git explanatory copy. Static source search also returns no Cowork hit for those strings. |
| Permission review is first | Passed | The latest durable permission result is the first rail surface, above Agents and Tasks. The live-pending path uses the same first slot and pins the rail at wide widths. |
| Cards use native Liquid Glass | Passed | The production rail uses one `GlassEffectContainer`; each section uses noninteractive native `.regular` `glassEffect` with a continuous 18pt corner. No sampled color, fixed gray fill, gradient, custom highlight or fake glass asset is present. |
| Light and Dark resolve natively | Passed | Both captures preserve readable semantic text, system-derived translucency and appropriate contrast without maintaining a second hand-tuned palette. |
| Rail hierarchy is quieter and more coherent | Passed | Section titles use SF Symbols and semibold hierarchy; content spacing is consistent; the permission result is compact; Agents and Tasks remain independently scannable. |
| Narrow layout has no dead rail | Passed | At the compact runtime width, the rail and its separator/placeholder disappear cleanly. Goal/Tasks are not duplicated into the transcript. |
| Permission behavior is preserved | Passed | RequestID/FIFO, automatic non-actionable status, manual approve/decline/cancel-turn, remembered MCP approval, keyboard shortcut and accessibility IDs keep the existing production component and focused permission suites. |
| Product/platform scope is preserved | Passed | EventLog, PermissionEngine, responder, projections, Git tool registry, iOS capability boundary and dependency graph were not changed. |

## Required fidelity surfaces

- Material and color: native system glass and semantic foreground styles; no imitation glass.
- Shape and spacing: 18pt continuous corners, 16pt inter-card rhythm and 18pt rail inset produce a
  compact status stack without the old flat gray slabs.
- Iconography: existing SF Symbols only; no copied logo, asset or handmade vector.
- Information architecture: permission status first, then Agents, optional Goal and optional Tasks;
  Git presentation is absent.
- Responsive behavior: wide live-pending state owns the rail; the compact state owns exactly one
  actionable Material fallback and never duplicates Goal/Tasks.

## Severity review

- P0: none.
- P1: the old Git-first rail and transcript-level permission card contradicted the requested
  hierarchy. Fixed and revalidated in the paired Light/Dark wide-state review.
- P2: the old fixed-looking gray slabs made all sections visually equal and inexpensive. Fixed
  with native Liquid Glass, semantic typography, SF Symbol section labels and consistent rhythm.
- All observed P0/P1/P2 issues are resolved. The current durable session exposed a resolved
  permission notice rather than a live pending request; pending pixels were not recreated by
  sending a provider/tool request. Its placement, single-surface hosting and compact fallback use
  the same production component and are covered by focused layout/permission tests.

## Validation loop

1. Opened the supplied before screenshot and inspected the existing Cowork rail implementation.
2. Removed the full Git presentation and moved permission status to the first rail slot.
3. Replaced section Materials with a shared native glass container and native glass effects.
4. Built the SharedUI target and both Apple product targets; ran 61 focused layout/permission tests.
5. Opened the installed Release app in Light and a Debug appearance-isolated build in Dark, then
   inspected the same real `Test` Cowork session without sending or approving anything.
6. Opened the before, final Light and final Dark images together and checked hierarchy, material,
   spacing, contrast, iconography and the complete absence of Git presentation.

## Build and interaction evidence

- `ThreadLayoutTests` 10/10, `PermissionProjectionTests` 16/16 and
  `PermissionReviewControlPlaneTests` 35/35 passed.
- `IntatisSharedUI`, `IntatisMac` Release/Debug and generic Simulator `IntatisiOS` Debug builds
  succeeded.
- `/Applications/Intatis.app` contains the latest Release build. The host has no valid Developer ID
  identity, so this local installation is ad-hoc Hardened Runtime signed and is not a notarized
  distributable artifact.
- No provider request, permission action, message send or durable Cowork state mutation was used
  during visual QA.

final result: passed

# Design QA — iOS reference typography

Date: 2026-08-02

## Scope

- Apply the user's final correction: the app-owned iOS chrome uses the Apple system serif
  design, not merely reference-matched sizes and weights.
- Keep the accepted top model picker, Intatis drawer, Recents hierarchy, composer and Settings
  native to SwiftUI and Dynamic Type; do not add a font asset.
- Preserve the macOS font environment and composer contract.

## Comparison inputs

- Source truth: user-supplied `IMG_4904.HEIC`, `IMG_4905.HEIC` and `IMG_4906.HEIC`.
- Read-only PNG conversions: `/private/tmp/intatis-font-reference/IMG_4904.png`,
  `/private/tmp/intatis-font-reference/IMG_4905.png` and
  `/private/tmp/intatis-font-reference/IMG_4906.png`.
- Final implementation captures: `/private/tmp/intatis-ios-serif-home.png`,
  `/private/tmp/intatis-ios-serif-sidebar.png` and
  `/private/tmp/intatis-ios-serif-settings.png`.
- Paired full-screen comparisons: `/private/tmp/intatis-serif-home-comparison.png` and
  `/private/tmp/intatis-serif-sidebar-comparison.png`.
- Each source is 1206×2622 pixels, or 402×874 points at @3x. The implementation is
  1170×2532 pixels, or 390×844 points at @3x. The viewport differs by 12×30 points, so the
  review uses same-density overlapping typography regions rather than claiming whole-screen
  pixel identity.
- Reference copy/model state and implementation copy/model state differ intentionally. The
  references remain source truth for layout, scale, weight and hierarchy. Their sans family is
  intentionally superseded for app chrome by the user's explicit serif correction.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| App chrome family is serif | Passed | The iOS app root applies `.fontDesign(.serif)`. Home, drawer, composer and Settings visibly inherit the Apple system serif design. |
| Top model hierarchy remains correct | Passed | The closed model label is headline semibold and primary; the Menu label no longer uses accent blue. |
| Drawer hierarchy remains correct | Passed | `Intatis` is title2 semibold, `Recents` is headline semibold, and the empty state is subordinate body copy, all in serif. |
| Composer uses serif body copy | Passed | The iOS placeholder is system body in serif; the macOS branch remains its existing fixed 15pt contract. |
| Settings is covered by the global rule | Passed | Sheet title, Cancel/Save, section labels, explanatory copy, buttons and field values are visibly serif in the final capture. |
| Content rendering stays aligned with macOS | Passed with runtime caveat | Markdown, plain fallback, code, math and notices keep the shared macOS font implementation; no iOS-only serif descriptor rewrite remains. A real long rich reply was not created during this no-network QA pass. |
| Dark appearance remains native | Passed | Primary/secondary text remains readable with semantic colors and no hard-coded font file or pixel color. |
| Product/platform scope is unchanged | Passed | No provider, search, configuration, persistence or iOS package boundary changed; no message or network request was sent during QA. |

## Required fidelity surfaces

- Fonts and typography: Apple system serif + Dynamic Type for the iOS app chrome;
  title2/headline/body styles and semibold/regular weights preserve the accepted hierarchy,
  while content rendering keeps the shared macOS typography contract.
- Spacing and layout rhythm: the Recents baseline was corrected; accepted header, drawer and
  composer geometry otherwise remains unchanged.
- Colors and tokens: model text is semantic primary rather than Menu accent; other text remains
  primary/secondary and continues to follow appearance.
- Image and asset fidelity: no logo, icon, image or font asset was copied or introduced. Existing
  SF Symbols and native controls remain in use.
- Copy and content: `Intatis`, the configured model name, empty-state text and composer prompt are
  product/runtime copy and intentionally differ from the reference.

## Severity review

- P0: none.
- P1: the prior pass used the default sans family for app chrome. Fixed at the iOS app root and
  revalidated; the later overreach into Markdown/content fonts was removed to match macOS.
- P2: none in the final Dark home, drawer or Settings pass.
- Remaining matrix: real rich-text/code/math replies, long session names, every Dynamic Type
  category, Bold Text, Increase Contrast, Light appearance and Reduce Transparency remain
  `UNKNOWN`; these are not observed mismatches in the tested default-size Dark states.

## Validation loop

1. Reopened the three read-only reference conversions and the previous implementation pass.
2. Accepted the user's correction that the entire iOS UI must be serif. This intentionally
   overrides the references' sans family while retaining their layout and hierarchy.
3. Applied `.fontDesign(.serif)` at the iOS `WindowGroup` content root, while preserving the
   shared macOS Markdown/code/math typography path; rebuilt and reinstalled.
4. Inspected the final Dark home, drawer and Settings in the iPhone 17e simulator. Device Hub AX
   confirmed the expected sidebar/model/new-chat/composer and Settings controls without sending.
5. Opened same-density reference/implementation pairs for home and drawer, then separately
   inspected the Settings capture. No remaining tested-surface P0/P1/P2 typography issue exists.

## Build and interaction evidence

- `IntatisiOS` generic iOS Simulator Debug unsigned build completed successfully after the final
  source patch.
- `swift test --filter MessageRenderingTests` passed 41/41; the existing unrelated macOS
  `onChange` deprecation warning remains.
- The app was installed and launched on an iOS 27.0 iPhone 17e simulator. The simulator remains
  booted with Settings visible for user inspection and continued configuration.
- Browser/Sites console checks do not apply to this native iOS build. Device Hub accessibility
  inspection and simulator pixels were used instead.
- No provider, credential resolver, web-search or message-send path was invoked.

final result: passed

# Design QA — macOS design language applied to iOS

Date: 2026-08-02

## Scope

- Apply the current macOS visual language to the iOS Chat-only product: typography roles,
  navigation hierarchy, session title, native Liquid Glass controls and two-row composer.
- Keep the platform adaptation native to iOS rather than copying desktop geometry or adding
  Code/Cowork/workspace capabilities.
- Compile the latest root `Intatis.icon` into the iOS app and verify its installed appearance.

This section supersedes the preceding same-day global-serif iOS pass. The macOS source of truth
uses serif for brand/page/session titles and system sans for body copy, controls, menus, forms and
input; the iOS implementation now follows that same role split.

## Comparison inputs

- macOS source truth:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-integrated-agent-communication-final.jpeg`.
- iOS final default states:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/intatis-ios-dark-home.png`
  and
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/intatis-ios-final-light-home.png`.
- iOS component states:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/intatis-ios-light-sidebar.png`
  and
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/intatis-ios-light-settings.png`.
- Installed icon:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/intatis-ios-home-icon.png`.
- Required combined reference/implementation input:
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/intatis-macos-ios-design-comparison.png`.

The desktop and phone viewports intentionally differ. The comparison judges the design-token and
hierarchy mapping—title family, control family, materials, information order and composer roles—
rather than claiming cross-platform pixel identity.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Typography matches macOS roles | Passed | `Intatis`, session and Settings titles use system serif; body, model label, buttons, menus, forms and input use system sans. The former root `.fontDesign(.serif)` is removed. |
| Top header matches the product hierarchy | Passed | The center slot is the current serif session title; model selection no longer competes with navigation and New in the header. |
| Drawer uses the same information architecture | Passed | Serif `Intatis`, selected Chat glass row, `Recent` + circular New, session list and bottom Settings replace the prior gear/search/large-Chat arrangement. |
| Composer matches the macOS control cluster | Passed | Row one contains the model glass capsule and optional usage; row two contains the existing Chat paperclip menu, multiline input and the single Send/Stop slot. |
| Native appearance works in Light and Dark | Passed | Semantic surfaces, text and glass controls remain legible in both captured appearances without fixed RGB/black/white or simulated glass. |
| Settings keeps the same title/body split | Passed | Settings has a serif page title while native toolbar buttons, sections, descriptions and fields stay system sans. |
| Latest app icon is installed | Passed | Built Info.plist declares `CFBundleIconName=Intatis`; iPhone/iPad icon files are present and the simulator home screen shows the new pointer icon. |
| iOS product boundary is preserved | Passed | No Tools, Permission, AgentKernel, Cowork, workspace, shell or generic attachment dependency was added. |

## Required fidelity surfaces

- Fonts and typography: Apple system serif is limited to title roles; Apple system sans and
  Dynamic Type remain the control/body default. Markdown, code and math keep their shared semantic
  fonts.
- Spacing and layout rhythm: the 64pt top header, 82% drawer, compact selected mode row, Recent
  hierarchy and bottom two-row composer preserve the current native spacing system.
- Colors and materials: `.primary`, `.secondary`, separators, system background and native
  Liquid Glass resolve per appearance; no sampled color or handcrafted glass was introduced.
- Iconography: only SF Symbols and the user-provided canonical Icon Composer source are used.
- Copy and content: session/model/provider values remain runtime data. Empty Chat intentionally has
  no onboarding or suggestion cards.

## Severity review

- P0: none.
- P1: none.
- P2: none on the tested home, drawer, Settings or installed-icon surfaces.
- Remaining matrix: rich long replies, long session names, keyboard interaction, every Dynamic
  Type category, Reduce Transparency, Increase Contrast and physical devices remain `UNKNOWN`;
  they are not observed mismatches in the tested states.

## Validation loop

1. Re-opened the current macOS implementation screenshot and audited its typography hierarchy,
   sidebar order, composer roles, semantic materials and control geometry.
2. Removed the iOS global-serif override, moved model selection into a parameterized shared
   composer first row, moved session title into the header and rebuilt the drawer from shared
   session-history/native glass surfaces.
3. Added the root `Intatis.icon` to the iOS resource graph, regenerated the Xcode project and
   confirmed the compiled Info.plist/icon inventory.
4. Installed on an iOS 27.0 iPhone 17e simulator and captured final Light/Dark home pixels. Two
   QA-only incremental builds changed only the initial presentation state to expose drawer and
   Settings for screenshots; both flags were restored to `false` before the final source build.
5. Put the macOS reference, iOS Dark home and iOS Light drawer in one combined image and reviewed
   hierarchy, type family, spacing, materials, iconography and capability scope. No tested-surface
   P0/P1/P2 issue remained.

## Build and interaction evidence

- Swift parse passed for the three touched Swift files.
- `MessageRenderingTests|ThreadLayoutTests` passed 51/51.
- XcodeGen and generic `IntatisiOS` Simulator Debug unsigned build succeeded.
- CoreSimulator supplied native installed pixels. This host has CoreSimulator runtimes but no
  launchable `Simulator.app`, so Computer Use could not target the headless iOS process; drawer and
  Settings interaction automation is not claimed.
- No provider request, credential read, web search or message send occurred during visual QA.

final result: passed

# Design QA — Cowork Agent rail polish

Date: 2026-08-04

## Scope and comparison input

This pass evaluates the user-provided Cowork screenshot against the shipping `CoworkShell` surface
driven by the offline DEBUG agent-conversation fixture. The fixture changes only data and exposes a
diagnostic strip; the session header, transcript, composer, inspector overlay, Liquid Glass section
and Agent rows are the production views.

- Reference: `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_WIaMnh/Screenshot 2026-08-04 at 15.07.05.png`
- Main implementation state: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-main.png`
- Selected-agent state: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-research.png`
- Required combined input: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-comparison.png`

The fixture does not reproduce the reference session's permission and task card contents, so this
comparison judges the requested header and Agent rail surfaces rather than claiming whole-window
pixel identity.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Header no longer repeats the viewed agent | Passed | The production header presents only the durable session name; the former `Viewing @…` subtitle is absent. |
| Cards read as floating on the conversation canvas | Passed | The rail remains a trailing ZStack overlay with no divider or full-column material; the canvas continues beneath the native Liquid Glass card. |
| Agent card feels spacious and native | Passed | The section uses native headline typography, 18pt insets, 52pt minimum rows, SF Symbols and semantic system colors/materials. |
| Selection is blue without a checkmark | Passed | Both main and research states use only the accent rounded background; AX reports the selected row and no visual checkmark is mounted. |
| Agent ordering is stable | Passed | The GUI consumes first durable-admission order; status, messages, detach and reattach do not reorder rows. Projection and source-contract tests cover this behavior. |
| Rapid switching remains bounded | Passed | Computer Use completed 1,000 switches under the 8 × 1,000-row / 500 delta/s fixture with 0 warnings, 0 incidents and no more than 16 mounted rows. |

## Severity review

- P0: none.
- P1: none.
- P2: none on the tested header, rail, row-selection and rapid-switch surfaces.
- Remaining matrix: Reduce Transparency, Increase Contrast, every Dynamic Type category and the
  exact user session with simultaneous permission/Goal/Tasks cards remain `UNKNOWN`.

## Validation loop

1. Compared the reference and implementation in the same combined image, concentrating on header
   hierarchy, shared-canvas continuity, section geometry, status iconography and selection language.
2. Switched from `@main` to `@research` through the native accessibility action and confirmed that
   only the selected transcript changed while the composer continued to target Main.
3. Ran the native 1,000-switch action during the four-agent background delta burst; it finished on
   `@docs` with 0 warnings, 0 incidents and the bounded 16-row page intact.
4. No provider request, EventLog, workspace, permission runtime, credential, network request or
   message send was opened by this visual fixture.

final result: passed

# Design QA — Cowork rail lighting and fixed conversation geometry

Date: 2026-08-04

## Scope and combined evidence

This corrective pass follows the user's rejection of the prior rail-polish result. The visible
separation was treated as a lighting/material problem, while the transcript-width change was treated
as a geometry ownership problem. The production `CoworkShell` was exercised through the offline
DEBUG fixture with eight 1,000-row conversations and a compact resolved-permission example.

- User reference: `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_WIaMnh/Screenshot 2026-08-04 at 15.07.05.png`
- Current Main state: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-clear-main.png`
- Current selected-agent state: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-clear-research.png`
- User-reference/current combined input: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-user-reference-vs-current.png`
- Same-viewport old/current/switch input: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-agent-rail-before-after-and-switch.png`

The user reference and fixture have different session content. The same-viewport input therefore
provides the direct material and geometry comparison; the supplied screenshot provides the product
hierarchy reference rather than a claim of whole-window pixel identity.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Rail shares the conversation's light | Passed | Passive cards now use native `Glass.clear` in the existing shared `GlassEffectContainer`; no rail backing, gradient, custom shadow or highlight was added. On the same host/window, the sampled card interior moved from 240/255 to 244/255 while the canvas remained 255/255, reducing the independent gray-light block without erasing the native glass edge. |
| Middle and rail widths do not react to selection | Passed | One outer-width policy owns exact 348pt rail and 318pt card widths. At 1372×768, both Main and Research captures have identical composer runs and the same rail pixel range x=1076…1365. |
| Switching does not replace the scroll geometry | Passed | Empty, loading and populated states share one `ScrollViewReader`/`ScrollView`; content/raw frames are fixed before the scroller expands under the trailing overlay. Source contracts and layout tests freeze this. |
| Right-card typography is larger | Passed | Section title, agent name/model and Goal/Task supporting text each use the next native text role; no custom font or fixed-size bitmap text was introduced. |
| Permission review is concise | Passed | The resolved example shows only icon plus `task_get approved`. The pending compact variant keeps tool, a bounded safe summary and necessary actions while omitting risk chip, raw arguments and default details. Existing manual/automatic permission semantics remain unchanged. |
| Heavy switching remains responsive | Passed | The native 1,000-switch action completed under 8×1,000 rows plus a 500 delta/s burst with 0 warnings, 0 incidents and at most 16 mounted rows. |

## Severity review

- P0: none.
- P1: none.
- P2: none on the tested Light material, fixed-width, typography, compact-permission and rapid-switch surfaces.
- Remaining matrix: Dark, Reduce Transparency, Increase Contrast, all Dynamic Type categories,
  VoiceOver, 180-second soak and the exact production session with simultaneous Goal/Tasks remain
  `UNKNOWN` and are not implied by this pass.

## Validation loop

1. Put the supplied screenshot and current native output in one combined input, then put the rejected
   old fixture, current Main and current Research in a second same-viewport input.
2. Replaced only the passive rail material with the system clear-glass variant; the shared canvas,
   semantic colors and native glass container remain the design-system owners.
3. Froze rail/card/thread geometry to stable outer width and verified identical Main/Research pixel
   boundaries after native accessibility clicks.
4. Ran 30 focused layout/presentation tests, macOS and iOS Debug builds, and the fixture's 1,000-switch
   stress action. No provider, EventLog, workspace, permission runtime, credential, network request or
   message send was opened.

final result: passed

# Design QA — Cowork rail window-position stability

Date: 2026-08-04

## Scope and combined evidence

This corrective pass follows the user's report that the right-side Liquid Glass cards still drifted
slightly when the window moved and jumped when focus or the selected Agent changed. The existing
fixed-width checks were retained, but this pass measures the rendered card boundary rather than
inferring stability from layout constants.

- User reference: `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_WIaMnh/Screenshot 2026-08-04 at 15.07.05.png`
- Final native state: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-pass.png`
- Required reference/final combined input: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-reference-vs-final-stable.png`
- Main/Research/window-return strip: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-stability-strip.png`

The supplied session and fixture contain different Agent/Task data. The comparison therefore judges
the rail's hierarchy, light integration and structural boundaries; same-viewport fixture states are
the direct geometry evidence.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Window movement does not leave card edges on alternating pixel phases | Passed | The whole rail is snapped once to the current backing-pixel grid. The Computer Use crop itself changed from 1373px to 1372px after dragging; after correcting that one-pixel window crop, the rail aligns at the same physical phase. |
| Agent switching does not move the cards | Passed | At 1372×768, both `@main` and `@research` render the Agents card at x=1076…1366. Only the selected-row fill moves. |
| Window focus switching does not rematerialize or jump the rail | Passed | Switching to Finder and back produced a byte-identical rail crop: RMS 0 and maximum channel delta 0. |
| Glass cards remain native but optically isolated | Passed | `Glass.clear` and one `GlassEffectContainer` remain. The 8pt interaction spacing is smaller than the 18pt card gap, passive cards use the identity glass transition, and inspector transactions carry no implicit animation. |
| The structural edge remains visible when glass lighting changes | Passed | Each passive surface has a one-backing-pixel system separator `strokeBorder`; no sampled color, custom highlight, gradient, shadow or rail backing was introduced. |
| Heavy Agent switching remains bounded | Passed | 1,000 rapid switches completed under 8×1,000 rows plus 500 delta/s with 0 warnings, 0 incidents and no more than 16 mounted rows. |

## Severity review

- P0: none.
- P1: none.
- P2: none on the tested Light window-move, Agent-switch, focus-return and stress surfaces.
- Remaining matrix: Dark, Reduce Transparency, Increase Contrast, VoiceOver, 180-second soak,
  cross-display scale changes and the exact production session with simultaneous Goal/Tasks remain
  `UNKNOWN`; this pass does not claim them.

## Validation loop

1. Reproduced the visible optical drift and audited the production modifier/container hierarchy.
2. Confirmed from Apple's Liquid Glass documentation that a container spacing larger than the
   interior stack spacing makes glass shapes blend at rest and permits morphing during transitions.
3. Made the rail a non-layout overlay, isolated glass interaction, disabled glass/layout morphing,
   added a semantic one-pixel structural anchor and aligned the whole rail to backing pixels.
4. Rebuilt the native fixture, moved the window, switched Main/Research, switched to Finder and back,
   and compared rendered rail crops rather than only screenshots or source constants.
5. Ran 31 focused tests and the fixture's 1,000-switch stress action. No provider, EventLog,
   workspace, permission runtime, credential, network request or message send was opened.

final result: passed

# Design QA — Cowork rail stable surface and feedback-loop removal

Date: 2026-08-04

## Scope and corrective evidence

This pass supersedes the earlier window-position conclusion after the user reproduced the same jump.
The production Test session then exposed the actual feedback loop: the old
`IntatisThreadViewportFramesPreferenceKey` updated more than once in a frame during window changes.
The final build removes that preference path instead of compensating its output.

- User reference: `/var/folders/8p/t9gqz5213cqdslvht9fmd0zm0000gn/T/TemporaryItems/NSIRD_screencaptureui_WIaMnh/Screenshot 2026-08-04 at 15.07.05.png`
- Final Main: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-main.jpeg`
- Final code-reader: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-code-reader.jpeg`
- Final focus return: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-focus-return.jpeg`
- Required reference/current combined input: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-reference-comparison.png`
- Same-viewport Main/code-reader/focus-return input: `/Users/vita/.codex/visualizations/2026/08/03/019fc7e8-65d2-71b3-9bf2-9e29ab9af97c/cowork-rail-final-switch-focus-strip.png`

The reference and current capture use different appearance and session content, so the combined
reference input is used for hierarchy and material direction. The same-viewport strip is the direct
position and focus-lighting comparison.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Agent switching does not move the cards | Passed | Real Test history was switched repeatedly among Main, code-reader and doc-reader. The same-viewport strip keeps every card edge and gap in the same place; only transcript and blue row selection change. |
| Focus lighting does not become a position jump | Passed | The app was raised behind Xcode and returned. Native glass lighting changed as expected, while the structural outlines and card geometry stayed fixed; the returned accessibility tree reported no rail structure change. |
| Transcript updates cannot remount the glass rail | Passed | The rail is behind an Equatable boundary whose snapshot excludes empty/loading/page/rich transcript state. AX diffs across real switches removed and added transcript nodes but retained the rail. |
| Card content cannot remount the optical surface | Passed | Each `Glass.clear` now lives on a dedicated backdrop behind its dynamic content. Independent status cards are no longer grouped by a morphing `GlassEffectContainer`. |
| Window position cannot feed back into thread layout | Passed | GeometryReader frame probes and `IntatisThreadViewportFramesPreferenceKey` were removed; bottom restoration uses `onScrollVisibilityChange`. The old preference warning count was zero after real full-screen, repeated agent switching and focus return. |
| Heavy layout churn remains bounded | Passed | 85 focused rendering/layout/scroll tests passed, including a production-shaped AppKit host with 360 interleaved agent-selection, mode, inspector and window-size changes. |

## Severity review

- P0: none.
- P1: none.
- P2: native AppKit emitted one negative-geometry warning only during the operating system full-screen
  transition, next to `ThemeWidgetControlViewService` and `NSLocalWindowSharingWindow`; it did not recur
  during agent switching or focus return and is not the removed viewport-preference issue.
- Remaining matrix: Light appearance, cross-display scale changes, Reduce Transparency, Increase
  Contrast, VoiceOver and 180-second soak were not rerun in this corrective pass.

## Validation loop

1. Reproduced and read the old preference warning from the real production-shaped Test session.
2. Removed the coordinate preference path, separated glass from dynamic content and removed the
   grouping container around independent cards.
3. Ran 85 focused tests and rebuilt the native RailLiveQA app.
4. Loaded the real long Test history, entered full screen, switched Main/code-reader/doc-reader six
   times, moved focus to Xcode and returned, then checked the same-viewport visual strip and AX diffs.
5. Re-read the process log after each interaction group: the old `Bound preference` warning remained
   at zero. No provider request, message send, workspace mutation, permission action or network call
   was performed.

final result: passed
