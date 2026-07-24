# Design QA — OS26 native shell revision (historical)

Date: 2026-07-21

> Historical evidence only. The 2026-07-23 single native `List` and subsequent
> horizontal segmented-mode sidebar passes were both superseded by the current
> title + vertically stacked icon modes + history + Settings sidebar. The
> current Recent New control has a 30×30 native circular glass fitting size,
> and Chat/Code/Cowork share a 40pt interactive-glass model/profile menu.
> Current source passes Swift/SharedUI tests and macOS/iOS Debug builds, but the
> App and renderer fixture were deliberately not launched. Current pixel,
> Light/Dark, narrow-width, focus and keyboard behavior therefore remain
> `UNKNOWN`; the `Passed` results below apply only to the 2026-07-21 build.

## Comparison input

- Reference: `/Users/vita/.codex/generated_images/019f84ed-0331-7c00-ac55-b19fc461a142/exec-a4685a04-83e6-47c5-ac07-6e8e51ab3db8.png` (1505 × 1045)
- Implementation: `/Users/vita/.codex/visualizations/2026/07/21/019f84ed-0331-7c00-ac55-b19fc461a142/intatis-os26-implementation.png` (1100 × 760)
- Both images were opened together in one visual comparison input. The final stable capture uses a named live Cowork session and the user's current system appearance; the reference uses illustrative light appearance and mock session data. A separate maximized live pass verified the native inspector breakpoint. Appearance, live content and available display-size differences are accepted dynamic inputs, not hard-coded targets.

## Acceptance checks

| Requirement | Result | Evidence |
|---|---|---|
| Session name is the conversation title | Passed | Chat and Cowork accessibility trees expose the selected session display title; header code falls back to immutable SessionID only when no display name exists. |
| No message-level agent avatars | Passed | Live Chat/Cowork message surfaces contain no agent portrait/avatar control; Markdown list bullets are content markers, not identities. |
| No generic Agent badge beside agent names | Passed | Message labels use real agent identity; a missing generic agent identity renders as `Intatis`. The inspector keeps only small semantic status icons. |
| Usage occupies a dedicated row above composer | Passed | Live Cowork capture shows Context/Input/Cached/Output/Time directly above the input; model/profile and attachment remain inside the composer. |
| Apple-native OS26 structure | Passed | Sidebar uses native split-view material and vertical interactive glass navigation; Code/Cowork use SwiftUI `.inspector`; glass remains on functional controls rather than long content. |
| Existing font choice remains intact | Passed | No font family/token or user font setting was changed. |

## Severity review

- P0: none.
- P1: none.
- P2: none within the selected structural scope.
- Accepted variability: system light/dark appearance, real session names/content, permission/status banners, agent/task counts, and available display resolution.

## Validation loop

1. Built the macOS app and opened the latest Debug product with Computer Use.
2. Inspected Chat, Cowork, the dedicated usage row, and the wide native inspector without sending a message.
3. Saved the implementation screenshot and opened it together with the revised reference image.
4. Rechecked the four user-requested deviations and the native surface hierarchy; no remaining P0/P1/P2 issue was found.

final result: passed for the historical 2026-07-21 build; all later 2026-07-23 sidebar revisions, the current 30×30 Recent New control, and the current 40pt model/profile menu remain without runtime pixel evidence
