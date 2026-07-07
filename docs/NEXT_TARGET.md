# NEXT_TARGET

This temporary file records the next concrete objective for this project.

## Active Target

- Status: agreed
- Objective: Make Intatis a real model-backed local AI client/workbench after provider connection, without positioning it as an IDE and with git/PR workflows deferred.
- Scope: macOS Chat / Code / Cowork, iOS Chat subset, shared provider/config/runtime infrastructure, GUI observability, permissions, context, task recovery, and artifact surfaces.
- Validation: prefer real-provider E2E checks plus SwiftPM/Xcode builds for touched targets; document UNKNOWN where real key/device/provider matrices are not exercised.
- Blockers: real endpoint/key coverage, long-running task recovery design, Cowork reliability gaps, and provider-specific streaming/tool-call differences.

## Current Progress Notes

- First API/tool stability slice is in progress and has SwiftPM/Xcode build coverage: OpenAI-compatible HTTP failures, provider SSE error payloads, malformed SSE chunks, transport failures, and multimodal non-2xx responses now flow through shared provider/runtime error formatting instead of raw transport text.
- HTTP non-2xx response bodies now distinguish structured provider errors from unstructured gateway/proxy pages: JSON fields such as `error` / `message` / `detail` / `error_description` are still shown as `Provider said`, while ordinary HTML or plain-text bodies are capped as `Preview` so users see useful context without mistaking proxy noise for a provider-authored diagnostic.
- Tool execution feedback now records clearer unknown-tool, denied-permission, and tool-error observations; Code projection and CLI output can mark these tool results as failures without parsing assistant transcript text.
- Chat / Code / Cowork projections now derive compact recovery advice from `ErrorPayload` and failed `tool_result` observations, so GUI error cards can tell the user whether to retry, fix provider config, check endpoint/model compatibility, rerun after permission changes, or inspect tool inputs without changing the append-only event schema.
- Provider health check/model test call has a shared implementation: `ProviderRegistry.healthCheck(role:options:)` resolves the selected provider/model/secret and uses `ProviderHealthReport` for chat/agent checks, timeout reporting, partial stream detection, and compact user-facing summaries. macOS Settings now runs both Chat and Code(agent) checks from that shared API and shows the non-secret key source type (`auth file`, `env`, `secret file`, or legacy keychain); iOS settings stays chat-only. Both chat and agent health checks request usage, and the agent request body is covered by provider tests.
- OpenAI-compatible providers now normalize bearer authorization at request build time: accidental saved values like `Bearer <key>` or quoted keys are sent as a single `Authorization: Bearer <key>` token. macOS direct `provider.<id>.options.apiKey` values in OpenCode-compatible config are now resolved from that provider config file instead of falling back to the broader auth-file scan, so stale auth JSON entries cannot shadow the config that selected the provider/model. macOS/iOS provider registry refresh also clears the in-process secret cache so model/provider changes and settings saves do not keep using a stale key value.
- Provider runtime policy now applies shared request timeout and retry/backoff behavior to OpenAI-compatible chat streaming, tool-calling streaming, image generation, and transcription. Streaming retry is deliberately limited to failures before any response bytes are received, so partial text/tool-call streams are not duplicated. HTTP `Retry-After` and common rate-limit reset headers are parsed as numeric seconds, HTTP dates, or duration strings such as `750ms` / `1m30s`, then fed into both retry delays and user-facing error guidance with long server delays capped by policy.
- Provider endpoint URL validation now runs before transport for OpenAI-compatible chat streaming, tool-calling streaming, image generation, and transcription. Chat/tool-calling validate the effective Chat endpoint, while image/transcription validate Base URL plus their path; non-HTTP URLs, missing schemes, and missing hosts become `config` errors and health check failures instead of raw URLSession behavior.
- Non-streaming image generation and transcription now normalize HTTP 2xx but schema-incompatible payloads into actionable decoding errors. A provider error object, HTML page, missing `data[].b64_json`, invalid base64, empty image data, or missing transcription `text` is reported with a structured provider message or a capped preview plus endpoint/model/response-format guidance. Plain HTML, missing-field JSON, and bad base64 previews are not mislabeled as `Provider said`.
- OpenAI-compatible chat and tool-calling streams now accept either SSE `[DONE]` or chunk `finish_reason` as completion. They keep reading after `finish_reason` so separately emitted usage is preserved, avoid duplicate done events when `[DONE]` follows, and health check treats missing `[DONE]` plus present `finish_reason` as a completed stream rather than partial. If the stream ends with neither `[DONE]` nor `finish_reason`, adapters now throw a completion-marker compatibility error; Chat/Code preserve partial text and mark it stopped instead of writing a completed answer. Tool-calling now prefers `tool_calls` / legacy `function_call` over ordinary `stop` when multiple choices finish in one chunk. If tool-calling finishes with incomplete deltas or missing tool names, including provider drift that emits tool-call deltas and then incorrectly finishes with `stop`, the adapter throws an explicit provider tool-call stream compatibility error instead of silently succeeding with no tool execution.
- Token/usage handling now uses shared `Usage` helpers: multiple usage chunks from the same provider response are merged field-by-field, while AgentLoop accumulates usage across separate model requests in a tool loop. Chat, Agent, and ProviderHealthCheck reuse this path instead of maintaining separate counting behavior.
- Chat and Code projections now mark the current incomplete assistant/agent stream as stopped when an `error` event follows partial deltas. The partial text is preserved, the bubble gets a "response stopped before completion" recovery hint, and no new event type or schema change is introduced.
- Code view model no longer writes a second outer `agent` error after `AgentLoop` has already logged the provider/stream/tool failure, and Chat view model no longer keeps a bottom composer error when `ChatLoop` has already logged the provider failure into `EventLog`, so one failed provider request should produce one structured error card instead of duplicated event-card plus composer-error UI. Configuration failures that happen before the loop starts are still surfaced by the outer view model.
- Tool-call streaming decoder now accepts common OpenAI-compatible drift: missing single-tool `index`, string-form `index`, JSON object/array/number/bool `function.arguments`, and non-first-choice content/tool-call/finish chunks, normalizing them into the existing `ToolCall` shape without changing events or tool execution. Before emitting a `ToolCall`, non-empty accumulated `function.arguments` must decode as complete JSON; truncated or invalid JSON arguments now become explicit provider tool-call compatibility errors, while empty arguments remain allowed for no-argument tool compatibility.
- AgentLoop now validates known tool arguments before permission decisions and execution: arguments must be JSON objects and satisfy descriptor schema required fields, basic primitive types, numeric `minimum`/`maximum` constraints, string `minLength`/`maxLength` constraints, and `additionalProperties:false` unknown-field rejection. `read_file.maxBytes` is now bounded to `>= 1`, and standard tool path/query/command/diff strings are non-empty. No-argument tools can accept empty / `null` arguments as `{}`, while invalid JSON, non-object arguments, missing required fields, wrong primitive types, numeric range violations, string length violations, or unknown fields become an `invalid tool input:` `tool_result` with GUI/CLI failure classification and recovery advice.
- Cowork project-mode slice is implemented locally for macOS in the Main-led model: New Cowork session chooses a primary workspace, per-session `CoworkProjectSettings` persists main-agent/default model/default permission/token-budget/workspace metadata, session start restores workspace bookmarks and bootstraps `@main` through the existing `agent.attach` permission flow, and GUI user messages without @mention default to `@main` even when multiple sub agents exist. `@main` is the project lead agent and uses `spawn_agent` / `delegate_task` / `remove_agent` to manage sub agents. `spawn_agent` now defaults to worker children but accepts explicit `canCoordinate:true` so a sub agent can be granted coordinator tools and create/delegate to lower-level agents when needed; this still runs through scheduler/message bus/task graph, not nested `AgentLoop` recursion. Project Settings can add/remove project directory metadata but direct multi-root tool context is not yet implemented. The Cowork right inspector now shows project summary plus agent name/role/model/permission/status/queue/completed counts/workspace leases/capability leases with delete controls for ordinary sub agents. Per-agent independent model selection remains a future extension.
- The macOS UI information-architecture slice is implemented locally: the root sidebar now owns the compact `Chat / Code / Cowork` segmented mode switch, mode-specific session history, and New session actions; model switching plus token/context stats moved into the composer cluster; Chat has no default right inspector; Code and Cowork use right-side inspectors for structured status, workspace, Git-status-only, task/plan, and agent state. SharedUI now contains reusable mode tabs, session history rows, composer accessory plumbing, richer turn-stat display, responsive thread width calculation, explicit thread `contentWidth`, and shared `IntatisThreadBubbleRow` leading/trailing bubble alignment for Chat/Code/Cowork; all three message lists now fix their rendered column to `contentWidth` before centering, including Cowork. Synthetic `NSHostingView` renders cover Chat-shell, Chat-like bubble row, CodeShell, and CoworkShell at 360/500/700/940/980/1180pt key widths, including short user bubbles, long wrapped bubbles, compact composer controls, and wide inspector layouts. A temporary `LayoutAssert` verifier also performs pixel-level row assertions at 320/360/380/420/500/560/700/760/940/1180/1440pt, checking short user trailing alignment, assistant leading alignment, long user max-width, and content-column containment; it now renders a Chat-equivalent shell at 320/360/500/700/760/940/1180/1440pt and real `CodeShell` / `CoworkShell` with diagnostic bubble colors at compact, regular, inspector-breakpoint, and wide sizes to verify header/composer/inspector paths keep user/assistant bubbles inside the content column. OpenAI-compatible usage parsing records optional cached prompt tokens in `Usage` / `TurnStatsPayload` / projections while keeping old JSONL decodable.
- Current validation evidence: full SwiftPM tests pass locally (275 tests, 0 failures), Provider focused tests pass locally (63 tests, 0 failures), AgentKernel focused tests pass locally (18 tests, 0 failures), Cowork focused tests pass locally (81 tests, 0 failures), Tools focused tests pass locally (9 tests, 0 failures), Conversation focused tests pass locally (34 tests, 0 failures), `swift build` passes, and both `IntatisMac` and `IntatisiOS` Xcode Debug builds pass. Latest v0.15 Cowork project-mode validation reran Cowork focused tests（81 tests, 0 failures）, `swift build`, `xcodegen generate`, `IntatisMac` Debug build, and `IntatisiOS` Debug build after Main-led routing and `spawn_agent(canCoordinate:)` changes. Real provider/key/device matrices remain UNKNOWN.
- This does not complete the broader target: real endpoint/key matrices, real-provider mid-stream behavior matrices, broader provider-specific rate-limit semantics, durable long-task resume/replay, direct multi-root tool context, per-agent independent model selection, and GUI permission/task recovery UX still need verification and productization.

## Product Positioning

Intatis should not chase AI IDE parity. The target is a local-first, multi-provider, auditable AI workbench:

- Chat surface for regular model interaction.
- Code surface for local workspace agent execution without IDE/editor assumptions.
- Cowork surface for multi-agent task collaboration.
- macOS as full product surface; iOS remains a chat/multimodal subset.
- Git, PR, CI, and IDE/editor integration are intentionally deferred.

## Next Implementation Slice: macOS UI Information Architecture

Status: completed locally for the UI slice; synthetic multi-width visual verification passed for Chat-shell, Chat-like bubble row, CodeShell, and CoworkShell; temporary `LayoutAssert` pixel assertions passed for the shared bubble row at 320/360/380/420/500/560/700/760/940/1180/1440pt, a Chat-equivalent shell at 320/360/500/700/760/940/1180/1440pt, and real CodeShell/CoworkShell render paths at compact, regular, inspector-breakpoint, and wide sizes. A real app window can be launched under isolated HOME, but current macOS Screen Recording/CGWindow permissions block pixel capture, so manual visual verification of the running app remains UNKNOWN.

Objective: restructure the macOS client layout so Intatis feels like a real local AI client/workbench rather than three separate demo screens. The reference direction is a dense desktop client layout: navigation and session history belong in the sidebar, model/context/token controls belong with the composer, and the right-side area should become a mode-specific inspector instead of a loose place for model/session controls.

Chinese design understanding:

- This is an information-architecture problem, not a single control-placement issue. The current macOS UI still reads like separate demo pages instead of a mature client.
- The left sidebar should become the real navigation and session center: `Intatis` stays at the top, a horizontal `Chat / Code / Cowork` mode switch sits directly below it, and the remaining vertical space down to Settings is used for mode-specific session/conversation history.
- The main thread area should focus on conversation content. Current upper-right `New`, session, and model controls should not remain scattered in the content header.
- The composer should become the unified control cluster for input, model switching, context-window usage, and token accounting. The model info button/menu should switch models directly, without a second separate model selector elsewhere.
- Token accounting should eventually show cached input, non-cached input, output, and total token counts when the API reports them. OpenAI/OpenAI-compatible usage details are the first target; missing provider fields should degrade cleanly rather than inventing numbers.
- The right side should be mode-specific: Chat has no inspector by default; Code uses it for plan/task status and workspace/Git status; Cowork uses it for agent statuses, plan/task status, and workspace/Git status.
- Git in this UI slice is status-only. Commit, branch, PR, CI, and review workflows stay deferred.
- Shared implementation is required. Sidebar mode selection, session lists, composer model/token controls, and inspector sections should be reusable/parameterized SwiftUI surfaces; iOS may share lower-level chat/session/token pieces but remains a chat-only subset.
- Structured projections and event state should drive the UI. Do not infer task, agent, token, or Git/workspace state from assistant transcript text.
- The intended end state is a client skeleton where the left side handles mode and history, the bottom composer handles model/resource context, the middle is the conversation, and the right side is the mode status panel.

Core requirements:

- Sidebar layout:
  - Keep the `Intatis` title at the top.
  - Directly below the title, use one horizontal segmented control for the three modes: Chat, Code, Cowork.
  - Use icon-forward compact buttons; avoid the current tall vertical Chat/Code/Cowork rows.
  - Use the remaining sidebar space down to the Settings button for session/conversation history.
  - Session/history rows should be compact, scannable, and mode-aware. Switching mode should switch the visible history set: Chat sessions, Code sessions, or Cowork sessions.
  - New session actions should live in or near the sidebar/history surface, not in the upper-right content toolbar.

- Main thread header:
  - Remove current upper-right model/session controls from the main content header.
  - Chat mode does not need a persistent right inspector by default; use the main thread area and composer.
  - Keep page title/subtitle restrained and avoid wasting first-viewport space.

- Composer cluster:
  - Move model switching into the composer cluster. The model information button/menu should directly switch model; do not introduce another separate model UI element elsewhere.
  - Place current context-window usage and current conversation token stats with the composer, not as detached pills above the input.
  - Token stats should distinguish cached input, non-cached input, output, and total when the provider reports them.
  - At minimum, adapt OpenAI/OpenAI-compatible usage details first. Extend `Usage`, `TurnStatsPayload`, projections, and shared UI with optional fields so old JSONL continues to decode.
  - If a provider does not report cached input or context-window limits, degrade to the current prompt/completion/total display without fake numbers.

- Right-side mode inspector:
  - Chat: no right inspector by default unless a future artifact/context panel is explicitly opened.
  - Code: use the right side for a plan/task table and Git/workspace status summary.
  - Cowork: use the right side for agent statuses, plan/task table, and Git/workspace status summary.
  - Git in this slice is informational/status-oriented. Do not implement commit/branch/PR workflows yet.
  - The inspector must consume structured state/projections where possible; do not infer task state from assistant transcript text.

- Shared implementation:
  - Build reusable SwiftUI surfaces for sidebar mode selection, session history lists, composer model/token controls, and inspector sections.
  - macOS and iOS must share lower-level model/session/token components where applicable, with platform-specific layout parameters. iOS remains chat-only and must not link workspace/tool/Cowork modules.
  - Avoid duplicating Chat/Code/Cowork UI logic when a parameterized component can express mode differences.

Implementation order for the next round:

1. Audit the existing `IntatisMacRootView`, Chat/Code/Cowork containers, `ThreadSurfaces`, `ProviderModelMenu`, and `TurnStatsProjection` surfaces to identify what can be reused.
2. Refactor the macOS sidebar into title + horizontal mode segmented control + mode-specific session/history list + bottom Settings.
3. Move Chat/Code/Cowork model switching and turn/context stats into the composer cluster.
4. Extend OpenAI-compatible usage parsing and `turn_stats` with optional cached-input/context fields, preserving old event-log compatibility.
5. Add right-side inspectors for Code and Cowork with plan/task and Git/workspace status placeholders backed by structured state where available.
6. Verify responsive resizing on macOS and check that iOS Chat still builds and remains a restricted chat subset.

Acceptance criteria for this slice:

- The fourth screenshot's current scattered header controls are gone: mode selection lives in the sidebar, model/token/context controls live with the input, and the upper-right content area is reserved for mode-specific inspector content.
- Sidebar history is usable for Chat/Code/Cowork sessions and does not fight the Settings button for space.
- OpenAI-compatible responses can populate cached input/input/output token stats when available; missing provider fields do not break UI or event replay.
- Code and Cowork have a clear right-side status area, but no IDE/editor feature parity or Git workflow implementation is introduced.
- macOS app build passes; iOS app build passes without adding workspace/tool dependencies.

Implementation result:

- Satisfied in code: sidebar mode/history/New session layout; composer-local model/context/token controls; Chat without a default inspector; Code/Cowork right inspectors; Git status-only treatment; reusable SharedUI surfaces; responsive message width/gutter calculation; explicit content width for message lists; Chat/Code/Cowork bubble rows aligned at the row level through shared `IntatisThreadBubbleRow` instead of spacer-only positioning; optional cached-input usage fields; OpenAI-compatible cached token parsing; old `turn_stats` decode compatibility.
- Verified locally: `swift build`, full `swift test`, focused Provider/Conversation/AgentKernel checks, `IntatisMac` Xcode Debug build, and `IntatisiOS` Xcode Debug build.
- Verified by synthetic render: `NSHostingView` layout probe covers Chat-shell, Chat-like bubble rows, CodeShell, and CoworkShell at 360/500/700/940/980/1180pt key widths, including short user bubble right alignment, long message wrapping, narrow-window gutter reduction, compact composer controls, and wide-window inspector layout.
- Verified by pixel assertions: temporary `LayoutAssert` renders diagnostic rows through the real `IntatisThreadContentLayout` / `IntatisThreadBubbleRow` path at 320/360/380/420/500/560/700/760/940/1180/1440pt and confirms short user bubbles align to the trailing content edge, assistant bubbles align to the leading content edge, long user bubbles stay within `messageMaxWidth`, and all marker bubbles remain inside the content column. The same verifier renders a Chat-equivalent shell at 320/360/500/700/760/940/1180/1440pt, real `CodeShell` at 360/500/700/940/1180/1440pt, and real `CoworkShell` at 360/500/700/980/1180/1440pt with diagnostic bubble colors, confirming shell-level user/assistant bubbles keep the expected content-column edges when header, composer, and inspectors appear.
- Partially checked at runtime: using isolated `/private/tmp` HOME and placeholder auth JSON, LaunchServices created an Intatis app window; this run observed a CGWindow around 1022×660 with `AX_TRUSTED=true`, but `AXFocusedWindow`, `AXFocusedUIElement`, and `AXWindows` exposed only app/menu-bar hierarchy, and `CGWindowListCreateImage` returned no image for the window. Current Screen Recording/CGWindow permission prevents capturing the window pixels, so this is window-existence evidence rather than visual QA.
- Still UNKNOWN: manual visual QA on a running macOS app, real provider cached-token/context-window reporting, and real device/key matrices.

## Next Functional Priorities

1. Real provider runtime stability.
   - Continue normalizing streaming, usage, tool calls, provider errors, rate limits, retry, timeout, cancellation, and real-provider partial-response behavior across OpenAI-compatible providers.
   - Keep endpoint/key handling tied to the current config/auth-file design; do not reintroduce OS Keychain reads in GUI.

2. Context quality.
   - Improve workspace-relevant context selection, long-history trimming, scoped summaries, and explicit file/artifact inclusion.
   - Do not rely on IDE indexing assumptions; the agent must be able to decide what to inspect from local workspace signals and user-selected scope.

3. Tool execution feedback loop.
   - GUI should clearly show what tools ran, what they changed or observed, why they failed, and what is still pending.
   - Keep the event log as the source of truth; UI should consume projections rather than parsing transcript text.

4. Permission UX.
   - Productize the existing three-layer permission gate in GUI with clear risk text, path/tool/session context, deny-and-continue behavior, and permission history.
   - Do not weaken `DeterministicPolicyGate`, `PathConfinement`, `SecretScanner`, or Mediator secret filtering for convenience.

5. Long task and recovery model.
   - Add a durable task queue/status model for cancel, resume, replay after app restart, retry after failure, and clear "why stopped" reporting.
   - Preserve append-only `EventLog` semantics and `seq` monotonicity.

6. Cowork productization.
   - Make agent roster, task status, delegation results, shared artifacts, and message summaries trustworthy in GUI.
   - Follow `docs/COWORK_PRINCIPLES.md`: task contracts, scoped context, capability leases, mailbox/scheduler flow, and no nested `AgentLoop` recursion.

7. Observability.
   - Extend the current token/turn stats direction into request timing, model/provider identity, context size, tool duration, permission decisions, retries, and failure reason summaries.
   - Keep the UI compact; detailed diagnostics should be inspectable without dominating the main conversation.

8. Artifact experience.
   - Make generated files, reports, images, transcriptions, logs, and tool outputs easy to inspect, open, and trace back to their originating event/task.
   - Keep `ArtifactStore` index/blobs compatibility.

9. Configuration and onboarding.
   - Continue hardening provider health checks, model test calls, endpoint normalization checks, and user-facing error explanations against real provider/key matrices.
   - Avoid printing or persisting secrets in docs, UserDefaults, logs, or diagnostics.

## Explicit Non-Goals For This Target

- No IDE/editor feature parity: no inline code editor, IDE code index, language-server integration, editor diagnostics, or Cursor-style codebase UI.
- No git/PR/CI workflow for now: commits, branches, PR creation, CI triage, and review bots are deferred.
- No new third-party dependency unless explicitly approved.
- No iOS workspace agent execution; iOS remains the restricted Chat subset.
- No provider-specific UI fork when a shared parameterized implementation can express platform/provider differences.

## Acceptance Criteria

- A real model-backed macOS session can complete Chat and Code workflows with visible streaming, stats, errors, tool feedback, and permission decisions.
- iOS Chat continues to build and use only the chat subset.
- Provider failures are actionable to the user rather than raw transport noise.
- Long-running or interrupted work can be explained and recovered or safely abandoned.
- Cowork UI reflects task/agent state from structured events, not transcript inference.
- Documentation is updated with any durable behavior, schema, config, or safety changes.

## Rules

- Keep at most one active objective here.
- Update this file when a concrete next target is agreed.
- Delete this file when the target is completed or no longer current.
