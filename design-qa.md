# Design QA — permission review and conversation chrome

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
