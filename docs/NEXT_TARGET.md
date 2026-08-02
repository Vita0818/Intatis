# NEXT_TARGET

This temporary file records the next concrete objective for this project.

## Persistent product decision — 2026-07-28 macOS direct distribution only

- macOS 唯一产品面是 Developer ID 签名、公证和直接分发的 `IntatisMac`；
  不做 Mac App Store 版本，不再把其 App Sandbox 当作未来设计、依赖、功能或
  验收约束。`IntatisMacAppStore` 当前只作为尚未删除的 legacy source target
  记录，不进入默认 follow-up。
- 该决定不弱化 Intatis 自有权限/Lease/PathConfinement/SecretScanner、
  durable execution、managed-terminal Seatbelt/default-network-deny、
  Hardened Runtime 或 iOS target 边界。后续以
  `docs/MACOS_DISTRIBUTION.md` 为准。

## Completed implementation slice — 2026-08-02 Settings progressive disclosure

- macOS Settings 默认层级已收敛为 provider 基础项、Test/Save、Advanced 与
  Diagnostics；Connection、Models 及 MCP/renderer/notices/config 等低频设置改为按需
  展开，诊断导出保留为底部轻量行，不再常驻展示实现细节长文。
- 所有既有设置与本地诊断导出能力仍可达；凭据、EventLog、权限、安全边界、配置 schema
  和 iOS 产品边界不变。Computer Use 已验证默认态及三个 disclosure 的交互，默认 AX
  元素约从 62 降到 33；Swift parse、localization JSON、focused tests 10/10、macOS/iOS
  Debug builds 均通过。
- 本轮运行态视觉验收覆盖深色模式；浅色模式、Reduce Transparency 与 Increase Contrast
  仍是后续视觉 QA 项，不阻塞本次默认信息层级收口。

## Completed implementation slice — 2026-08-02 main Goal transition and document reader

- Cowork exact `@main` 的 fresh/default/task lease 现包含 `submit_goal_verdict`，因此可调用
  `update_goal`；non-main、spawn coordinator 与 reviewer 显式移除。legacy main default
  使用新的 durable lease 替换，历史 task 引用不被原地扩大。该调用仍不能自产 audit：
  complete 要求独立 GoalVerifier + host-bound evidence，blocked 要求既有三轮相同 verified
  blocker。
- 新增结构化 `read_document`：读取 workspace 内 Office/OpenDocument/RTF/CSV/HTML/
  Markdown/text/EPUB/PDF，通过本地 Docling 或 MarkItDown 转为有界 Markdown；legacy
  Office 依赖 LibreOffice。它不接收 model-authored shell/URL，禁用 remote services 与
  plugins，structured process 默认断网并保留 WorkspaceLease、timeout/cancel/process
  cleanup。parser 只从系统受信路径或用户建立的 Intatis document runtime 读取，未加入
  SwiftPM 依赖、未打包 Python runtime，iOS 产品图不变。
- IntatisTools/IntatisCowork targets、CapabilityLease 4/4、ToolRegistryLease 16/16、
  GoalManagerRuntime 7/7、GoalVerifierControlPlane 14/14、Agent request tool snapshot 6/6
  通过；完整 SwiftPM、IntatisMac Debug 与 generic IntatisiOS Simulator Debug build 均成功。
  本机 Docling 2.117.0 已把由 workspace README 生成的真实 DOCX 转回 27,699-byte Markdown。
  完整 Tools bundle 在当前外层沙箱仍因 nested `sandbox-exec` 系统性失败；标准 registry
  数量断言已随 `read_document` 同步为 59，并由 focused registry test 覆盖。
  MarkItDown 未安装，真实 PPTX/XLSX、legacy DOC/PPT/XLS 质量矩阵与 App 内
  provider-triggered E2E 仍为 UNKNOWN。
- 2026-08-02 的工具选择 slice 只追加了计划第 1–2 点：共享系统提示词中的通用选择/失败重评规则，以及 `read_pdf` / `read_document` / `reconstruct_document_image` 互不重叠的 model-facing 说明和 no-text hint。通用宿主确定性路由、完整 executor 兼容性 preflight、输出原子分期和 typed side-effect/no-effect 链路（原第 3–5 点）仍是明确后续项。
- 随后针对真实 314.1 MiB 扫描 PDF 只做了 `read_document` 局部热修：上限调为 512 MiB，并把 parser 启动前的 path/file/size/extension/backend 拒绝类型化为 no-effect。这不等于已完成通用宿主路由、分页、输出原子分期或整套第 3–5 点。

## Completed implementation slice — 2026-08-02 local diagnostic export

- macOS Settings 最底部现可生成并导出本地诊断 ZIP；覆盖 app/system 摘要、结构化脱敏
  session EventLog、unified log、proxy、performance、hang 与 crash，并用 manifest
  明确记录每项成功、失败和截断。
- 原始会话、工具数据、endpoint、credential、配置/auth、workspace、artifact、browser
  与 bookmark 不进入导出；reader/staging/process/ZIP 具备 bounded、owner-only、
  no-follow、timeout/cancel 边界。空 session 的虚假 warning 已修复。
- 专项与全量 SwiftPM tests、XcodeGen、IntatisMac/IntatisiOS Debug builds 和真实
  Settings 导出均已完成；诊断服务仍为 macOS-only。远程上传按用户要求未实现；未来
  若增加 support upload，必须作为新的、显式同意且经过服务端/隐私/安全设计的独立
  目标，不能复用本地按钮暗中发送。

## Completed implementation slice — 2026-08-02 bundled Cowork orchestration Skill

- Cowork coordinator system prompt 现在要求在调度前激活 exact bundled system
  `cowork-agent-orchestration`；正文仍经普通 `activate_skill` tool result 渐进
  披露，不嵌入 system prompt。同名 workspace/user Skill 不可替代，缺失/失败时
  使用 direct、exact-profile inheritance、read-only、no-child-coordination
  fallback。
- Skill 固化 direct/reuse/delegate/spawn、最小 agent/lease、write 与 coordination
  分离，以及 `cost-first` / 默认 `cost-efficient-balanced` /
  `efficiency-first` 三种调度模式。profile 先做 capability hard gate，再在 active/
  adequate 候选中优先新 generation，并按模式权衡成本；main 缺少多模态能力时强制
  搭配 JSON 声明相应 capability 的副 agent。dated vendor reference 只辅助从当前
  `list_inference_profiles` 选择 exact host-approved ID，不新增 route、credential、
  权限、配置 schema 或 UI。通用 attachment 到 child 的 bytes handoff 尚未闭环，
  text-only main 的完整 multimodal companion E2E 仍待后续。
- dated reference 已加入 11-provider 正式矩阵：OpenAI、Anthropic、Google、Meta、
  xAI、Mistral、DeepSeek、Kimi、Z.ai、MiniMax、Qwen。矩阵区分 cost-first、balanced、
  efficiency-first 与 multimodal companion，明确 stable/Preview/open-weight/host-price
  边界，并始终先与用户 JSON exact profiles、declared capabilities 和 active lifecycle
  取交集。
- owner correction 已把 Meta 正式 anchor 换成 Public Preview 的 Muse Spark 1.1，
  把 Gemini 3.1 Pro Preview 显式加入 Google 高能力路线，把
  DeepSeek 完整版本 `DeepSeek-V4-Flash-0731` 排为 V4-Pro 的上位 agent 推荐，且把
  `deepseek-v4-flash` 限定为 wire alias，并把 Qwen Flash exact anchor 固定为
  Qwen3.6-Flash；这些推荐仍不能创建 JSON 中不存在的 profile。
- correction validator、bundled Skill tests 29/29、Developer ID `IntatisMac`
  unsigned Debug build 与最终 App bundle 正反向字符串检查均通过；未做真实 provider
  或 GUI E2E。
- Validator、focused Skill/Context tests、SwiftPM build、XcodeGen、macOS/iOS Debug
  product builds 通过；macOS Bundle 内容与 iOS 零 Skills linkage 已检查。真实
  provider/长时多 agent E2E 仍待后续；外层 managed sandbox 的既有 process/
  Seatbelt/loopback 限制使 full SwiftPM suite 不能在本轮记为通过。
- 正式 11-provider matrix 的增量验证也已完成：Skill validator 通过，bundled
  resource assertions 29/29 通过，Developer ID `IntatisMac` unsigned Debug build
  成功，最终 App bundle 已确认包含矩阵和新增 Kimi/Z.ai/MiniMax/Qwen anchors。

## Completed implementation slice — 2026-08-02 Icon Composer app icon and installed Release

- 用户提供的根目录 `Intatis.icon` 已作为原生 Icon Composer resource 只接入唯一发行
  target `IntatisMac`，主图标名固定为 `Intatis`；遗留 App Store 与 iOS target 未改。
- Xcode 27 Release build 成功，bundle 含 `Intatis.icns`、`Assets.car`、
  `CFBundleIconFile=Intatis` 与 `CFBundleIconName=Intatis`，可执行文件仍为
  `arm64 + x86_64` universal。
- 最新 Release 已安装并单实例运行于 `/Applications/Intatis.app`；旧版保存在
  `/private/tmp/Intatis.app.before-icon-20260802-1320`。构建/安装 payload 比对和
  `codesign --verify --deep --strict` 通过。
- 本机没有 Developer ID identity，故当前安装仅为 ad-hoc Hardened Runtime；
  Developer ID 签名、公证与 Gatekeeper 分发验收仍未完成。图标来源未独立审计，
  本轮没有新依赖或上游源码复用，`NOTICE.md` 不变。

## Completed implementation slice — 2026-08-02 automatic-permission transient failure recovery

- Tool-calling streaming now retries an error-only, retryable SSE provider frame only when no
  non-error payload has been accepted. Any accepted text/tool/usage/completion payload closes the
  retry boundary, so partial model output or tool calls are never replayed.
- The first tool call remains durably denied on a typed reviewer provider failure/timeout. One exact
  model retry may create a fresh permission RequestID/reviewer generation; explicit denials and all
  other failure kinds retain the existing cached-denial fuse, and a second transient failure cannot
  re-arm the exception.
- Duplicate unresolved action descriptions are collapsed in the terminal error. Focused provider
  and AgentLoop suites, full SwiftPM tests, IntatisMac Debug, and IntatisiOS Simulator Debug passed.
  No live provider or executor smoke was run. This section supersedes the older raw-response-byte
  shorthand below for the tool-calling path.

## Completed implementation slice — 2026-08-02 Cowork permission-first Liquid Glass rail

- Cowork trailing rail 已彻底移除 Git 状态、workspace path 与 Git 控件；Git 能力本身仍只作为 Agent tools，经 CapabilityLease、PermissionEngine 与既有安全链调用。
- pending permission / 最近权限结果位于 rail 第一位，其后依次是 Agents、durable Goal、durable Tasks。各 section 统一使用系统原生 `GlassEffectContainer` + `glassEffect`，没有固定灰底、硬编码颜色或手绘玻璃。
- pending permission 且 outer width 可容纳 rail 时，rail 临时固定可见；窄到无法容纳时只在 composer 上方显示一个默认 Material 权限卡兜底。RequestID/FIFO、manual approve/decline/cancel-turn、remembered MCP approval 与 automatic non-actionable 语义未改。
- 已通过 SharedUI build、61 项布局/权限 focused tests、`IntatisMac` Release/Debug、
  `IntatisiOS` generic Simulator Debug、Light/Dark 宽屏和 Light 窄屏只读视觉检查；
  最新 Release 已安装到 `/Applications/Intatis.app`。本机无可用 Developer ID
  identity，当前安装包是 ad-hoc Hardened Runtime 签名，不代表已完成对外分发所需的
  Developer ID、公证或 Gatekeeper 验收。视觉比较和剩余矩阵见根目录
  `design-qa.md`。

## Completed implementation slice — 2026-07-31 browser execution regression

- 浏览器 action 已从 generic `networkStructuredShell` 分离到 shipping
  `BrowserBackendProcessRunner`。macOS 直接执行 host 生成的 opaque Node driver，
  保留 Chromium native sandbox，不使用与 helper sandbox re-init 冲突的外层
  Seatbelt，也不添加 `--no-sandbox`；Linux 保留 Bubblewrap。
- WorkspaceLease/touched-path preflight、sanitized environment、bounded pipe、
  DevTools-port 前后统一 cleanup、真实 Edge/CDP navigate/search/profile
  persistence/upload/download、伪造 state/history HTTP(S) gate 和 stale
  `DevToolsActivePort` generation/loopback endpoint 验证（含 `/json/list` 与
  `/json/new` PUT/GET 全部分支），以及
  Tools/AgentKernel/Permission/Xcode build 回归均已完成。细节见
  `codex-report/07_31_26-15_35-browser-execution-regression-remediation.md`。
- 后续不是继续修改该 runner，而是补真实矩阵：Playwright、
  Chrome/Chromium、headed handoff、同时启动不同 profile，以及 latest-built App
  中从 Cowork 发起一次真实搜索。完成前这些仍标记 `UNKNOWN`。

## Implemented slice / active follow-up — 2026-07-28 Codex-style Skill lifecycle and replacement history

- 稳定 Code conversation 与 Cowork `@main` 的本地 replacement-history 主链已完成：
  pre-turn 在当前输入前压缩，mid-turn 只在工具后仍需采样时压缩；replacement
  保存最多 20k approximate-token、并按 95% usable window 动态收缩的真实用户
  原文、必要的当前 contextual messages 和末尾 continuation summary。summary
  request 在 replacement window 未知且无显式 token budget 时不注入 output
  ceiling；已知 usable window / shared token budget 才派生 request 与
  host-enforced 实际输出上限。已知 secret-like
  summary 会被拒绝，完整 replacement request 在 checkpoint 前再次校验。
  pre-turn 与每个仍需采样的 mid-turn 都冻结对应下一请求的 exact dynamic
  tool snapshot，并用同一 specs 判定、压缩和 dispatch。context overflow
  retry 保护 leading system/developer 前缀且只裁紧邻 call/output group。显式
  Skill body 被标成 contextual，可参与摘要但不会被误保留成真实用户原文；
  Skill 仍按 Turn / invocation snapshot 重读，没有 sticky Session activation。
- 新的 `model_history_compacted` checkpoint 保存完整 replacement items、
  单调 window number 与 UUIDv7 first/previous/current lineage。EventLog 在
  complete-known replay 和 per-agent CAS 下验证整条同-agent lineage，禁止
  generic append 绕过，并先 durable commit、后 live swap；Code 使用
  `taskID == nil` + SubmissionID，Cowork `@main` 使用 exact root
  task/submission/assignee/attempt provenance，worker 不继承主线程。
- 90% auto / 95% usable threshold 已从 exact profile metadata 接通，不按 model
  slug 猜窗口；Code route 原子返回 provider/model/policy，Cowork 使用 frozen
  exact binding。完整源码审计、六项批评判定、测试证据与设计差异见
  `codex-report/07_28_26-10_17-codex-skill-lifecycle-and-history-compaction.md`。
- P1 catalog/preflight 也已完成其受限范围：catalog 从 exact canonical
  primary context 取得 2% approximate-token budget（`context_window` 优先，
  缺失时可由显式 `limit.context` 补位），两者缺失时回退 8,000 characters，
  并冻结 count-only warning/metrics；`agents/openai.yaml` 只接受
  严格 MCP dependency，正文披露由同一 request-owned snapshot（其 response
  选择了该 Skill tool）中 host-attested exact server ID + locator fingerprint
  assertion 的成对匹配决定。production assertion 只从
  request-owned、agent-visible tool view 派生，server 至少贡献一个可见 tool
  entry；无 MCP host、endpoint 改变或 metadata 无效均 fail closed，不读取
  process-global config 兜底。真实 MCP builder/server E2E 仍为 `UNKNOWN`。
- 下一项若继续对齐，优先顺序是：`comp_hash` 或更小窗口切模时使用 previous
  model 先压缩；随后才评估 `body_after_prefix`、catalog metrics 的 host
  consumer、watcher/冲突 UX、remote compact 和真实检索。Codex 的 MCP
  Install/Continue-anyway、OAuth、外部配置写入和 runtime refresh 尚未实现，
  若要增加必须单独设计权限与 durable admission。不得以 embedding、Skill
  专用免审执行器或 sticky lifecycle 作为默认方案。
- 仍未完成且必须单列：provider-native reasoning/arbitrary replacement item、
  历史图片重新装载、同一中断 submission in-place resume、Codex 同构
  world-state full/patch、rollback/fork、remote compact、真实 provider
  token/overflow matrix、真实 MCP server 端到端、process-kill 和长期 soak。
  当前 replacement-history / Skill catalog / MCP dependency 聚焦矩阵为
  129/129，脱离外层 managed sandbox 的全量 SwiftPM 为 1470
  tests / 16 skipped / 0 failures，SwiftPM、当前发行 `IntatisMac` 与
  `IntatisiOS` 产品图均构建通过；遗留 App Store target 的旧构建只算历史
  证据，不再是 follow-up 或 release gate。上述真实环境项仍为 `UNKNOWN`，
  不得宣称 Codex 全等。

## Completed implementation slice — 2026-07-24 real managed terminal

- macOS Code/Cowork/CLI 的 shell-capable agent 已获得真实 `exec_command` / `write_stdin`：长进程可跨调用保留，`tty=true` 有 controlling terminal，stdin/轮询/Ctrl-C/结束/终止可用。production raw `run_shell` 仍不暴露。
- 目标不是“让 agent 想跑什么就跑什么”，而是“像 Codex CLI 一样真的有终端，同时仍属于 Intatis 的工作区和权限系统”：exact owner/task/attempt/WorkspaceLease 绑定、每次交互重新审批、macOS Seatbelt、默认断网、有界输出、凭据环境过滤、stdin durable redaction、task/runtime cancellation cleanup 已完成。
- 最终 `swift test` 984 tests / 14 skipped / 0 failures，其中 `TerminalToolsTests` 25/25；IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 通过。实现仅参考 pinned Codex CLI 公开架构，未复制或翻译其源码，NOTICE 无需变化。
- 这不是要求立即继续扩展的 active target。若用户以后决定继续，最有价值的窄切片依次是：运行中 resize/SIGWINCH + 常见 TUI smoke；macOS 强制杀进程后的 orphan/恢复策略；Linux bwrap denied-pattern 映射与 PTY backend。当前三项仍为 `UNKNOWN` / 未完成。

## Completed reliability follow-up — 2026-07-30 bounded macOS history windows

- The remaining “freeze immediately after entering the session” was isolated
  beyond the paragraph-width fix: the same 13-row/5-rich-row
  `cowork_tf2lkjbh` froze with rich + message-level lazy virtualization, stayed
  responsive with plain + lazy and rich + eager, and still froze when only
  code/table selection was disabled. The process sample pinned the main thread
  in `GraphHost.flushTransactions` / AttributeGraph subgraph updates, making
  selection a secondary cost rather than the necessary cause.
- macOS Chat/Code/Cowork now render a maximum 16-row eager history page and use
  explicit Earlier/Newer/Latest navigation beyond that bound. Old pages keep a
  stable upper bound on append; only latest owns thinking/live follow.
  Per-page presentation scope isolates bottom anchor, scroll coordinator,
  viewport admission and rich settlement. Send, Cowork Retry and Latest return
  to the latest page. This is bounded eager rendering, not a global unbounded
  `VStack`, and it adds no document/native-view/height cache.
- Focused history/render/scroll tests pass 69/69, including four physical
  `NSScrollView` top↔bottom cycles over 16 rich rows with stable paragraph
  identities. The unsigned IntatisMac Debug build passes.
- Real product validation completed first entry, repeated intermediate
  scrollbar positions, A→B→A, and 55-message Earlier/Latest paging with 0.0%
  post-action CPU samples and no new hang incident. No provider request or
  EventLog mutation occurred.
- Shared iOS Chat remains on its UIKit/compatibility container and was not
  validated in this follow-up. A current-container >160-second soak,
  VoiceOver/clipboard, real-device coverage and the 2026-07-18 historical
  retaining edge remain separate follow-ups, not reasons to reopen the reported
  macOS entry/scroll freeze.

## Completed reliability slice — 2026-07-30 projection/scroll/paragraph width ownership

- Code/Cowork now fold every EventLog envelope through a session-scoped
  `SessionProjectionPump`; only consecutive deltas use a 50 ms presentation
  cadence, while every non-delta event remains an immediate barrier.
- Window-local scroll state keeps geometry observation-only, limits live follow
  to a 100 ms cadence, closes rich-settle epochs on interaction/session change,
  and resumes visible rich work only after a per-row 150 ms idle dwell.
- A reproducible production rich-renderer zoom/restore hang was traced to
  competing SwiftUI/AppKit paragraph width ownership. macOS paragraphs now
  expose no intrinsic width, return the exact proposal width with measured
  height, and retain only the latest exact-width measurement.
- Real production validation completed A→B→A, five zoom/restore operations and
  eight scroll actions without a runtime issue in the isolated product-action
  window. Three final-SHA 180-second soaks passed; the interactive run added
  75 AX top/bottom actions with 60 seconds of explicit action dwell.
- That interactive run recorded 18 AppKit negative-geometry issues in the
  Intatis PID. All clusters immediately followed system
  `ThemeWidgetControlViewService` activation, two began before explicit
  scrolling during AX-tree/ReplayKit capture, and no paragraph/thread product
  symbol appeared in their stacks. The two no-AX soaks recorded zero. Keep the
  raw count and classify it as an automation-correlated AppKit transient;
  do not claim that it was absent from the app log.
- Final-source strict vendor/root tests, platform builds, three >160-second
  soaks and final-SHA Instruments evidence are recorded in
  `codex-report/07_29_26-17_05-cowork-scroll-rendering-hang-remediation-plan.md`.
  The 2026-07-18 multi-instance retaining edge, real clipboard/VoiceOver and
  low-end iOS device evidence remain separate `UNKNOWN` items.

## Completed reliability slice — 2026-07-24 session-switch layout storm

- Code/Cowork now separate process-retained runtime from window-local session presentation. Exact session identity rebuilds only the visible thread tree; scoped bottom anchors and a one-pending-task scroll coordinator reject stale generations, preserve user scroll intent, and perform monotonic rich-height correction without stopping background runtime.
- `AppSessionRuntimeManager` no longer turns every retained ViewModel `objectWillChange` into a root-wide revision. It publishes exact-key opening/idle/running/removing status, keeps Cowork delete-busy and conversational-settlement semantics separate, and fences an asynchronously removing key against reopen.
- Chat restore now uses a strict snapshot, registers the post-snapshot stream, takes a second strict catch-up, folds/de-duplicates history once off MainActor, and then publishes live envelopes above the applied seq. Deterministic tests cover live-boundary, strict-failure/reentry and cancellation/restart races.
- Existing Markdown/code/single-dollar-math behavior and renderer stability guards were retained. No renderer/vendor/dependency/NOTICE/EventLog/provider/permission/font change was required after the post-fix profile stopped showing layout activity.
- That statement describes the 2026-07-24 short session-switch profile only.
  A later reproducible rich zoom/restore hang exposed the separate paragraph
  width-feedback defect addressed by the 2026-07-30 slice above.
- Validation includes 8 scroll tests, 6 Chat replay tests, final-source SwiftPM target/class slices totaling 955 tests / 14 skipped / 0 failures, and macOS/iOS Debug builds, plus one-instance Computer Use against 2816/1575/758-event Cowork histories. Thirty-two A→B→C→A clicks settled at about 0.7% CPU and 141 MiB footprint, the main thread sampled idle, manual scroll-up was preserved, two window selections remained isolated, Command-W retained the process, and Command-Q exited it. One-shot runner waits and the earlier parallel-only three-test interference remain recorded in `docs/TESTING.md`; real live-provider background work and long soak remain validation follow-ups, not a missing ownership implementation.

## Completed UI slice — 2026-07-24 full-width macOS agent replies

- macOS Chat and the shared Code/Cowork thread row now distinguish content role from bubble direction: user messages retain the existing trailing cap/gutter, while assistant/agent Markdown and the Thinking row fill the whole thread content column. System messages and operational/permission/task cards keep their prior width policies; iOS `MessageRow`, renderer internals, EventLog and provider payloads are unchanged.
- A pure `IntatisThreadBubbleWidthPolicy` prevents future callers from accidentally applying the user bubble cap to full-width agent output. `ThreadLayoutTests` freeze full-width agent, constrained trailing user and constrained non-agent leading behavior.
- Validation: Swift parse; `ThreadLayoutTests` 3/3 + `MessageRenderingTests` 25/25; `IntatisSharedUI` target; IntatisMac macOS Debug; IntatisiOS generic Simulator Debug all passed. No App was launched for this slice, so final wide-window pixels remain a user/runtime check.

## Completed implementation slice — 2026-07-31 common LaTeX without local formula caps

- The Microsoft-derived renderer now recognizes `$...$` / `\(...\)` inline
  and `$$...$$` / `\[...\]` display delimiters outside protected Markdown
  literals; display math may span lines. Inline/display presentation reaches
  the live iosMath label, while raw EventLog/provider/projection text remains
  unchanged.
- The Intatis-added 32-formula/message, 8-KiB/formula, and 1024×256-point
  attachment limits are removed. Invalid TeX and invalid intrinsic geometry
  still restore exact literal source; code, link/image/autolink/raw HTML,
  currency, escapes, and malformed delimiters remain protected.
- Focused vendor math tests pass 39/39, including 64 formulas, 12-KiB formula
  source, multiline display delimiters, and an attachment wider than the
  removed 1024-point threshold. The full vendor strict Release suite passes
  90/90, root `MessageRenderingTests` pass 41/41, the SharedUI target builds,
  XcodeGen succeeds, and macOS/iOS Simulator Debug apps build. The full root
  suite, Release app matrix, and current real-window verification were not
  run; this evidence is not renderer release GO.
- The syntax-agnostic 64-KiB whole-message rich admission and process-wide
  1-running/32-pending parser scheduler remain separate facade resource
  controls; the remaining 32 is not a formula-count limit.

## Completed implementation slice — 2026-07-24 single-dollar inline math (historical)

- This section records the 2026-07-24 implementation as shipped at that slice; its delimiter exclusions and 32/8-KiB/1024×256 policies are superseded by the 2026-07-31 slice above. Microsoft-derived rich Markdown remained the only rich renderer. Intatis then admitted only protected-context-aware single-dollar `$...$` inline math, with 32-formula/message and 8 KiB/formula all-or-nothing limits; fenced/inline code, currency, escapes, unsupported delimiters, malformed input and oversize input remained literal. EventLog, projection raw strings and provider wire content were unchanged.
- Accepted formulas use iosMath 2.5.0 at exact revision `838cddc01fdd67efd530f8bb67959ad2715f9b06` through a live TextKit 2 `NSTextAttachmentViewProvider`. The AppKit paragraph owns an explicit `NSTextContentStorage → NSTextLayoutManager → NSTextContainer` network, restores the primary layout manager after replacing content, and coalesces viewport layout on the next main turn. Formula source is retained for literal fallback, copy projection and accessibility; no production raster/native-view cache was added.
- Validation completed: vendor 82/82, SharedUI 25/25, root 938 tests/14 skipped/0 failures, strict vendor Release warnings-as-errors, XcodeGen, macOS Debug/Release, iOS Simulator Debug/Release, exact dependency/NOTICE/font-bundle inventory, hash-pinned math-disabled/enabled A/B, five short isolation stages, and Light/Dark Computer Use. All controlled runs exited normally and left no process behind.
- Remaining release evidence is validation-only: the 2026-07-18 historical retaining edge remains `UNKNOWN`; >160-second single-instance soak, real selection/clipboard bytes, real VoiceOver operation, minimum-supported macOS runtime and low-end iPhone/iPad device checks are still open. The implementation is therefore not described as renderer release-ready.

## Completed UI slice — 2026-07-23 session recency / Stop / Thinking

- Recent sessions now use durable completed-work timestamps rather than selection order or EventLog mtime, with an exact-kind background refresh only when a retained runtime transitions from active to idle.
- Chat / Code / Cowork replace Send in the same composer slot with a native destructive red Stop while active. Cancellation remains scoped to the current data-plane operation; Cowork Goal uses durable pause/checkpoint and the reviewer/session runtime stays alive.
- Existing macOS Chat and shared Code / Cowork Thinking rows now display phase-local elapsed seconds before the label. No protocol, EventLog schema, provider payload, permission model, dependency or font changed.
- Validation at that slice boundary: focused 303/303, SharedUI/AgentKernel builds, XcodeGen, macOS Debug, iOS generic Simulator Debug, English/zh-Hans catalog compile and `git diff --check` passed. The renderer fixture was intentionally not launched for this UI slice. A later 2026-07-24 math-specific, hash-pinned single-instance validation is recorded above; it does not retroactively validate Stop/Thinking pixels, VoiceOver or real-provider cancellation timing.

## Completed Target — Phase L app/runtime lifecycle

- Status: completed in the current worktree on 2026-07-20. There is no user-authorized next business-source target.
- App ownership: macOS `AppSessionRuntimeManager` owns Chat/Code/Cowork runtime by exact `{SessionKind, SessionID}` across windows. Window-local environments own only the visible selection. Session/mode switching, History and Command-W do not stop background work; deletion drains only the exact runtime and broadcasts removal to other windows.
- Quit/reopen: Command-Q closes runtime admission, broadcasts stop concurrently and waits to a monotonic bounded deadline before replying to AppKit termination. A timed-out runtime is reported as timed out, not falsely settled. Normal reopen and crash/force-quit reopen only replay/reconcile; historical active Goal becomes durable paused (or budget-limited), historical running/stopping displays interrupted, and no provider work resumes without explicit Send/Retry/Resume. CLI data-plane resume remains explicit through `/auto|/default` and `/goal resume`.
- Runtime shutdown: Chat/Code/Cowork cancel and await their owned work before releasing subscriptions, permission waiters and workspace scopes. Cowork has a quiescing admission fence and a unified operation registry so settings/workspace/agent/Goal/permission mutations cannot start after shutdown begins.
- Validation: `GoalRuntimeControllerTests` 34/34 and `BoundedSessionRuntimeShutdownTests` 5/5; independent full SwiftPM **903 tests / 14 skipped / 0 failures**; IntatisMac macOS Debug and IntatisiOS Simulator Debug builds passed. Computer Use with an offline DEBUG-only fixture passed simultaneous A/B work, session/history switching, Command-W, Command-N reuse, normal Command-Q/reopen, exact process kill/reconcile, explicit single-session Resume and a 700 ms uncooperative-runtime deadline. The fixture does not claim real provider/server cancellation timing.
- Remaining external evidence: real-provider process-kill boundaries, server-side cancellation timing, long-duration real workspace multi-session runs and Linux bwrap remain `UNKNOWN`; these are validation follow-ups, not an unimplemented Phase L ownership contract.

## Completed Targets — Phase C permission/turn outcomes

- Status: completed in the current worktree on 2026-07-20. Phase S、A、B、T、C、L 均已完成各自当前范围；没有经用户明确指定的下一项业务源码目标。
- Phase C objective achieved: permission response 不再是模糊布尔值。`approve` 允许当前 call，`decline` 只拒绝当前 call 并让模型继续，`cancel_turn` 中断整个 turn 且不生成伪造的 denied tool result。新 Chat/Code/Cowork turn 记录 typed `turn_outcome`，user/policy/reviewer/sandbox/runtime/cancel 保持机器可读来源。
- Phase C durable/runtime scope: RequestID first-write 与 permission first-terminal 在 EventLog complete-known-history + cross-process lock 内线性化；exact duplicate/reconnect 幂等共享 owner generation/terminal，冲突 fail closed。Projection/CLI 保持 FIFO，automatic request 不暴露人工 action。可信 sandbox wrapper startup denial 结算为 typed denied/not-started且不自动 retry；structured timeout/cancel 在 terminal/caller return 前 drain provider/tool child。
- Phase C validation: eight focused suites **126/126**；independent full SwiftPM **895 tests / 14 skipped / 0 failures**；XcodeGen、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 通过。Computer Use 使用独立 bundle ID 的 DEBUG-only offline fixture 验证 Approve Call、Decline Call、Cancel Turn 与 automatic non-actionable；fixture 没有 provider、EventLog、credential resolver、responder 或 executor。
- Phase C evidence boundary: 没有执行真实 provider 审批、网络 remote-resolution transport、真实历史 pending approval 的 process-kill/restart 或 Linux bwrap 实机；这些不能由离线 fixture 或 fake provider 测试冒充。Phase L 随后作为独立阶段完成，不改变这些 Phase C 证据边界。
- Objective achieved: the permission reviewer’s process-lifetime `providerActivity` quarantine is replaced by request/generation-scoped isolation, exact terminal-state guards and late-result rejection, so timeout/cancel fail closes only the current ask-class tool and a later review uses a fresh context. A cancel observed after terminal claim may preserve the unique reviewer verdict, but authorization delivery is still denied.
- Implemented scope: `PermissionReviewControlPlane` gives each provider dispatch a `{reviewTaskID, nonce}` generation and provider/timeout first-terminal race. Provider-backed terminal claims must match that exact generation; pre-dispatch terminal paths claim once from running/no-generation state. Production Orchestrator freezes reviewer identity/binding while re-resolving a provider wrapper per generation. Timeout/cancel/factory failure affects only the current call and retires the current generation only when one is active; late/duplicate output has no EventLog/health/authorization path. Quiesce/detach-failure resume and terminal-claim cancellation keep authorization delivery fail closed without duplicate settlements.
- Provider contract: `ToolCallingProvider.stream` must promptly return a request-owned stream, keep continuation/producer state request-scoped and propagate consumer termination. Shipped OpenAI/URLSession adapters satisfy the local ownership chain. `Task.detached` is not claimed to make an arbitrary synchronously blocking implementation safe.
- Evidence boundary: five inspected historical Cowork EventLogs contained permission reviews but no `timed_out`, `cancelled` or `provider_still_stopping` settlement, so the actual first incident request/provider remains `UNKNOWN`; Phase B fixes the source-proven amplification path without claiming a real incident replay.
- Validation: eight focused permission/orchestration suites **164/164**; `swift build`, XcodeGen, macOS Debug and iOS Simulator Debug builds passed. The final cancellation hardening adds a synchronous request token, pre-submit caller classification, post-await caller fence, direct attach fences after review and at the final durable-admission linearization point, a deterministic post-review inference-resolution cancellation test, and explicit late-producer completion barriers. Computer Use on the latest macOS app confirmed reviewer failed/disabled banners, editable composer and local draft Send gating without sending a provider request. The root full SwiftPM attempt was boundedly interrupted after a known Tools no-output hang and is not reported as passed.
- Non-goals at Phase C completion were lifecycle and real multi-upstream E2E. Phase L lifecycle has since completed independently；real multi-upstream Phase D E2E 仍是独立工作。
- Task-local settlement follow-up: OpenCode `a19b52e85bf2630b86157030e2cf7c9fc20ce552`, Codex `bf3c1972b7d045c0a3a48dff91f381070f8f69e1`, and Claude Code public task/hook contracts were cross-checked. Intatis independently implements the combined rule: an executionID keeps its first prepare; any duplicate prepare is permanently ambiguous, identical duplicate settlements are idempotent, and conflicting terminals are permanently ambiguous. New success is explicitly committed; legacy succeeded/nil is compatibility-only completed effect, while succeeded/not_started is invalid and uncertain. Only the production Orchestrator adapter may convert exact task/expected/actual-matched stale rejection to typed no-effect; pre-executor cancellation settles cancelled/not-started but still interrupts, while generic/executor-entered writes remain unresolved. Legacy repair requires no current Goal, complete-known history, exact current record, non-ambiguous zero-settlement history, typed intent, one non-empty task resource, JSON-safe expected revision and pre-prepare `actualRevision > expectedRevision`. Restore/repair, Goal startup, in-process launch and whole-task retry all require `replayForProjectionChecked().hasCompleteKnownHistory`; unknown future events and seq gaps fail closed. No-Goal isolation additionally requires contract-before-prepare, positive exact attempt and terminal-after-prepare; current Goal is never repaired. No source/prompt/dependency was imported and `NOTICE.md` remains unchanged. The six Phase T suites pass **128/128** (5+8+29+13+31+42), followed by a successful final-source `swift build --disable-sandbox`; Phase T did not run full SwiftPM, Xcode/UI, a real provider, or a real legacy-session restore drill.
- 2026-07-31 `task_update` incident follow-up supersedes only the narrow “stale-only” adapter/repair scope above, not its historical validation record: production Orchestrator now proves every rejection raised before its first WorkTask EventLog append as no-effect, while append/lost-ack failures remain unknown. PATCH normalization removes repeated contract fields only when they exactly equal the authoritative task, so worker full-snapshot completion no longer trips frozen-field authority while actual changes still fail closed. Legacy no-Goal repair also accepts exact raw-argument SHA-256 + prepared authorization + agent/TaskContract/capability lease/run/WorkTask snapshot proof for the old worker snapshot-field and manager frozen-contract guards; redacted/missing/mismatched identities remain unresolved and error text is never parsed. New focused tests were added, but this host did not execute them: SwiftPM cache/nested-sandbox startup failed and the sandbox-external request was rejected by the approval service's usage limit. Re-run `WorkTaskRuntimeTests`, `OrchestrationReliabilityTests`, and `swift build` on a SwiftPM-capable host before release.

The later “Next Implementation Slice” sections in this file are retained as completed or historical product backlog context; they are not concurrent active targets. The broad workbench/Git/UI direction remains valid but does not supersede the completed Phase B / Phase T / Phase C / Phase L objectives above.

## Current Progress Notes

- 2026-08-01 workspace chrome layout-cycle 修复已完成：11:11 crash 的 main-thread 栈为 `NSSplitView.layout` / `NSHostingView.layout` 与 `ToolbarBridge.preferencesDidChange` 在 update-constraints transaction 中重入，不是 OOM/provider。Code/Cowork 已移除 mode-dependent window `.toolbar` 与 child-width-driven `.inspector` feedback；MCP/Project/Inspector action 进入内容 header，右栏显隐继续只由 stable outer width policy 决定。Code 保留有界 HStack；2026-08-02 Cowork rail 改为同一 detail canvas 的 trailing overlay，不加 divider/整栏 `.bar` 背景，thread ScrollView 延伸到 detail 最右侧并以 trailing scroll-content margin 为 cards 留位，未恢复 child-width feedback。原最终 `ThreadLayoutTests` 10/10（含真实 NSWindow 360 次 mode/threshold/inspector stress）、ThreadScroll 30/30、MessageRendering 41/41，macOS/iOS Debug build 通过；最新 overlay 回归另见本轮记录。真实 Debug App 的 200 秒 watchdog 为 99 samples、max RSS 229,376 KiB、max CPU 0.4%，Unified Log 指定布局异常 0、1 秒 sample 主线程 872/872 idle、无新 crash、零残留。Computer Use 只读确认 window toolbar 只剩系统 Sidebar item；后续 resize/click 被控制器拒绝，未冒充完成。多小时与真实 streaming 中 resize 仍是外部验证项。
- 2026-08-01 session title metadata 精简已完成：active Chat/Code/Cowork thread header 只显示 durable session display name，sidebar Recent row 只显示 session name；model/provider/host、workspace/state、agent/running、event/date/path/runtime 灰色副文本与对应空白行均删除。空态首页/Settings 说明、session selection、New、Rename/Delete 与 busy delete gate 保留。Swift parse、`ThreadLayoutTests` 6/6、Developer ID macOS Debug build 通过；独立 bundle 的真实历史 Chat 与 Cowork Recent 已用 Computer Use 只读验证，1100×760 前后对比见 `design-qa.md`，未发送 provider 请求。
- 2026-07-31 conversation chrome refinement 已完成：macOS sidebar 品牌块只保留 `Intatis`；Chat/Code/Cowork 与共享 iOS Chat 的用户气泡继续 trailing 但不再重复 `You`；权限 review/resolution surface 改为紧凑、左对齐、低对比 Material，risk 只落小图标/chip，structured scope 与 patch 默认折叠且通用详情不读取 raw args。manual/automatic 权限动作、RequestID/FIFO、PermissionEngine/EventLog 均未改变。`ThreadLayoutTests` 6/6、Developer ID macOS Debug 与 iOS Simulator Debug build 通过；独立离线 fixture 的 Light/Dark、collapsed/expanded、automatic、approved 和真实历史 Chat 的 sidebar/user bubble 已用 Computer Use 验证，未发送 provider 请求。当前证据见 `design-qa.md`。
- 2026-07-22 conversation surface 收口已完成：Cowork 对话页删除常驻 permission-reviewer 顶部横幅，Code/Cowork session header 顶部留白由 26pt 收紧为 12pt；横幅中唯一的 workspace reauthorization / automatic-review retry 入口迁入 Project Settings 的异常 Recovery 区，真正 pending `PermissionCard`、permission FIFO 和权限引擎保持不变。macOS Chat、Code、Cowork 与共享 iOS Chat 的正常 assistant/agent 回复不再套外层 Material/圆角/描边，正文/Markdown/公式直接继承系统 canvas；用户、失败/中断和 tool/error/permission/task 等结构化内容仍有容器。未修改字体、协议、EventLog 或平台边界。`MessageRenderingTests` 22/22、`swift build --disable-sandbox`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 通过；未启动 renderer/真实 App，运行态视觉仍待用户复核。
- Code/Cowork 的 verbose execution trace 展示熔断已完成并补上重复回答修正：完整 EventLog / `CodeProjection` / agent context 继续保留。2026-08-02 起 SharedUI 默认把 user、真实 agent message、媒介化 `.agentToAgent` 通信（通用 agent message、information request/reply）、task-only/different-result fallback 与 actionable error 投入会话树；仍隐藏 tool call/result、patch、内部 note，以及同一 TaskID/agent/attempt 下与最后完整 `message_completed` 正文完全相同的 `task_completed` scheduler 镜像。配对使用 per-agent active `{TaskID, attempt}`，不做全局正文去重；new start/retry 不继承旧配对，迟到旧 terminal 不清除新 attempt，跨任务同文不误删。媒介化通信现在复用普通 agent 无外框回答版式，并统一显示 exact `sender->recipient`，不再添加 `info` / `reply` 前缀。后台 `-IntatisShowExecutionTrace` / `INTATIS_SHOW_EXECUTION_TRACE=1` 可在新进程中恢复原完整调试视图，没有 UI/UserDefaults。本次最新 `ExecutionTracePresentationTests` + `IntatisConversationCodeTests` + `ThreadLayoutTests` 合计 32/32 通过；运行态视觉结果由本轮 `design-qa.md` 记录。
- 2026-07-21 的侧边原生滚动条小修是历史阶段：当时真实 `cowork_9mdz9qkh` 的 2-row/超高 rich row 证明纯 lazy 估算会跳过中后段，因而引入 `<= 4` eager、`>= 5` lazy 的 adaptive 合同。该合同及其 17-row production-lazy 说法已被上方 2026-07-30 最终 follow-up 废止；当前 macOS 产品合同是 16-row bounded eager page + 显式分页。该历史复验的 0.25/0.50/0.75/1.0、约 212 MiB 与 22/22 结果仍保留为当时证据，不得冒充当前容器的长时验证。
- Phase A（Cowork composer / submitted-intent admission）已于 2026-07-20 完成：stable `SubmissionID`、owner-only outbox、唯一 `user_message + queued(attempt 1)`、FIFO、exact Retry/no duplicate message、restored-root pause、submission-scoped context 与 hardened ArtifactStore 已落地。验证为 focused **122/122**、完整 SwiftPM **824 tests / 14 skipped / 0 failures**、Swift/macOS/iOS builds 通过；Computer Use 在 reviewer failed 的历史验证 session 确认 composer 可编辑、文本 Send durable accept、`route_unavailable`/Retry、失败后继续编辑，以及附件 durable import/attachment-only Send eligibility。附件草稿没有点击 Send；没有真实 provider、permission review 或 model output。Phase B、Phase C 与 Phase L 随后均独立完成。
- Phase S（session state / workspace authorization persistence）已于 2026-07-19 在本地完成并验证。`events.jsonl` 是 settings、migration、agent/lease 登记的唯一权威，append 返回/stream/replay 均发布实际落盘反解的 canonical Envelope；schema-v2 `session.json` 是 EventLog-wins 的 owner-only 可重建投影；Apple bookmark 只在 session-owned schema-v1 binary `workspace-access.plist` 中以 `0600` 保存，并由 macOS `WorkspaceAccessLease` 持有实际 security-scope 生命周期。fresh Cowork 固定为 settings-first 七事件（`seq 0...6`），main/reviewer 共享 exact inference binding 但身份和 leases 分离，初始化无模型请求。Legacy display name 先 append settings+marker 再 rebuild；workspace migration 需要 per-session provenance/all-required verification，symlink alias 仅在 scope 后验证并先写 canonical settings 再 marker，marker 后不回退 global map。共享 workspace capability 只有在 settings + live roster 证明零引用时才清理；primary 在 UI、ViewModel 和 plist store 三层默认不可删除，仅允许创建事务失败时显式回滚。Historical main recovery 使用严格 revision fold；CLI `/agent restore-main` 使用专用入口。验证为 focused 137/137、独立 scratch full SwiftPM 785 executed / 14 skipped / 0 failures、Swift/macOS/iOS builds 通过，Computer Use 新建/恢复/重授权、unsent draft 与最新 primary Trash disabled/37-event disk audit 通过；真实 symlink/shared-worker UI 未覆盖，未发送 provider 请求。本轮没有复制或翻译上游源码、没有引入依赖，`OPEN_SOURCE_REUSE.md` / `NOTICE.md` 无需修改。
- Per-agent inference security follow-up now carries safe route/trust-domain/egress classification in the binding and permission fingerprint while keeping connection identity opaque, and exact catalog resolution checks those fields rather than trusting their presentation value. macOS classifies user-configured external routes without exposing their URL and converts raw variant config keys to opaque durable variant IDs. Cowork durable options use an explicit allowlisted schema: unknown keys/shapes, secret/auth/header/query/URL/endpoint material, runtime structural fields, `stream_options`, and multi-candidate controls fail closed. The OpenAI-compatible Chat/Agent builder independently strips config usage/candidate controls on every request; new package adapters omit `n` and metadata-derived `parallel_tool_calls` to match their pinned OpenCode packages, while legacy wire retains explicit `n = 1`. Only host `includeUsage` can recreate controlled usage options, while an output ceiling also removes competing token aliases. Provider transport treats every HTTP 30x as terminal and never follows a redirect to an endpoint outside the reviewed exact connection. Provider diagnostics are sanitized upstream and again at `RuntimeErrorPresentation` before becoming durable EventLog/task-failure text; the diagnostic-only scrubber redacts complete ordinary HTTP(S) URLs as well as credentials. These controls do not constitute a route lease or cross-trust-domain approval primitive.
- The per-agent inference-profile slice from `codex-report/07_16_26-17_53-per-agent-inference-profile-research.md` is implemented locally for Cowork: immutable catalog revisions, exact `AgentInferenceBinding`, frozen task bindings, no-default recovery, exact spawn inheritance, host-approved profile selection, target revalidation and host-only idle rebind are present. Phase A supersedes its old GUI startup wording: exact-main/reviewer health is now a post-admission execution state, the composer stays editable, new submitted intents may be accepted, and recovered root tasks remain paused until exact Retry. CLI still has explicit control-plane/data-plane resume and `/agent restore-main`; unresolved ordinary workers fail only their own invocation. The resolver remains OpenAI-compatible only and real multi-upstream E2E, independent route leases, cross-trust approval and complete capability metadata remain open. Full contract: `docs/PER_AGENT_INFERENCE_PROFILES.md`; no upstream source/dependency was copied and `NOTICE.md` is unchanged.
- The automatic-permission-review source-audit slice from `codex-report/07_15_26-21_19-auto-permission-review-oss-audit.md` is implemented locally. One `ToolRegistry` registration now binds schema, concrete tool, canonical permission, capability membership, semantic preview and executor; an immutable `ResolvedToolAuthorization` is shared and revalidated across review, permission resolution and durable execution. Automatic reviewer input uses args digest/count plus bounded secret-redacted preview, requires a non-empty reason, cannot reduce gate risk and preserves typed failure source/status/reason. `delegate_task(to:auto)` resolves an exact target before review without mutating roster, deny creates no worker, and allow executes only the reviewed target. Durable side-effect evidence survives the review-settled→resolved and resolved→prepared crash windows, so denied/failed writes cannot be narrated as completed; `ask_agent` admission/mediation failures—including a target answer blocked on the return path—remain typed failures, and the reply-delivery outcome is settled before the scheduler publishes terminal success. Attach request/settlement-related events use a synchronized write-ahead journal for crash-recoverable atomic batches; both compatibility and strict readers recover an outstanding journal before exposing JSONL, and WAL/JSONL commits sync their parent directory. Safety-sensitive fresh bootstrap, Cowork restore, reviewer recovery, retry reconciliation and Cowork AgentLoop evidence/history recovery use checked EventLog scans with session/sequence/known-payload validation: known corruption/read failure is fail-closed while valid unknown future events still reserve sequence space and make a session nonempty. Intatis retains strict review-every-write policy; no upstream source or new dependency was copied. Eight focused suites pass **146/146**; Conversation selected tests pass **67/67**（main class 29/29）and the independent final audit reran **164/164** related tests. Final `swift build` passes. Full SwiftPM executed 678 tests with 14 skipped and 36 assertion failures: 34 are the host's existing nested-sandbox/loopback Tools limitation and 2 are the user-owned highlight.js engine XCTest under this outer sandbox; no permission or new EventLog test failed. Earlier macOS/iOS Xcode Debug builds in this work passed, while the final rerun was blocked at package-graph manifest `sandbox-exec` by the managed outer sandbox. Computer Use verified the built Cowork UI (`@permission-reviewer enabled`, 2 agents / 0 running, empty/draft/cleared composer Send gating) without sending a provider request. Real-provider verdict quality, process-kill E2E and low-level FileHandle fault injection remain external validation items, not a known source-design gap; unknown future events still require additive schema governance, and single-event first-create power-loss durability was not broadened by this multi-event atomicity slice.
- Markdown replacement has reached local production cutover: the stable mode contract is now `.microsoft` / `.plainSafe`, missing preference defaults Microsoft, unknown values fail closed plain, and old `rich` state/launch input migrates to Microsoft without touching session data. The display path is raw-first with 64 KiB admission, a process-wide 1-running/32-pending output-free latest-only Markdown parse scheduler, per-view latest revision buffering, 50 ms incomplete parse debounce and strict stale publication guards. Plain-safe and rich pending/rejected/oversize share one facade-lifetime raw projection: append-only snapshots use a non-resetting 100 ms leading/trailing cadence, while activation/reentry/correction/truncation/final publish exact source immediately and stale timers are generation-rejected. The initial 75 ms candidate missed the frozen interaction-p95 budget in 2/20 replay runs and is retained only as rejected performance evidence. iOS keeps the same pre-launch `Settings.bundle` rescue path and plain-safe still bypasses Markdown/math construction.
- The old MarkdownUI/NetworkImage/HighlightSwift/highlight.js stack, custom Intatis renderer/math/highlight adapters, caches and branded resources remain removed. The audited Microsoft v0.6.0 thin derivative owns Markdown grammar/AST/native layout; its request-local code-aware path owns `$...$` / `\(...\)` inline and `$$...$$` / `\[...\]` display delimiter integration, while exact Apple-only iosMath 2.5.0 owns native TeX parse/layout. The deleted upstream regex `LaTexPreProcessor` and old `IntatisMathView` are not restored. Accepted formulas are hosted by a live TextKit 2 `MTMathUILabel` attachment provider using intrinsic layout, semantic appearance and Dynamic Type revision; there is no formula-count/per-formula-byte/fixed-size cap or raster preview/cache, and invalid TeX/geometry restores exact literal source. Images, citations, animation and highlighting remain off; code stays full/selectable/copyable, table actions stay hidden, and only `http`/`https`/`mailto` links are allowed. iosMath's separately bundled eight math fonts and license/readme/table data are approved third-party formula resources, not Intatis interface typography.
- The two `Package.resolved` files agree on exact iosMath 2.5.0 revision `838cddc01fdd67efd530f8bb67959ad2715f9b06`; current `MessageRenderingTests` are 25/25 and vendor full is 75 XCTest + 7 Swift Testing = 82/82. Strict vendor Release, root 938/14 skipped/0 failed, dual-platform Debug/Release products, notice hashes and final bundle/font inventory were reproduced on 2026-07-24. The exact resource baseline remains a 26-file / 7,234,424-byte `fonts/` payload and a 27-file built bundle after Xcode/SwiftPM adds its root `Info.plist`. Runtime validation compared the same Microsoft renderer with math disabled/enabled, then ran `math-one`, `math-thirty-two`, `math-structure`, `math-history` and `math-stream`; plain-safe was not misused as the no-math baseline. Light/Dark, code/currency/escape literals, structure/history/reentry, AX source description, main-thread progress and bounded short-run RSS/footprint/CPU/cleanup passed. Real selection/clipboard bytes, VoiceOver operation, >160-second soak and representative devices remain release gates.
- The earlier 100 ms Plain and production-shaped `LazyVStack` Microsoft protocols remain useful historical interaction evidence, but they do not establish release readiness. The **2026-07-18 historical** GUI/Computer Use validation accidentally left three `Intatis Renderer Validation` instances alive; Force Quit showed 129.63 GB application memory for the dominant instance, while CPU diagnostic incident `FA228932-2C40-4AC2-A0C2-62EF41342B4A` recorded sampled footprint 109.16 MB→803.30 MB and stacks through SwiftUICore/AttributeGraph/lazy layout/`ParagraphView`/`SelectionOverlay`. Root cause and final retaining edge remain `UNKNOWN`; the three-instance condition was itself a validation-operation failure, and the Force Quit value is not exact RSS/footprint. The latest short, hash-pinned single-instance Computer Use runs are now PASS, but do not erase or explain that incident.
- Post-incident hardening restores upstream-equivalent `DocumentView`/ParagraphView equality, prevents repeated stable-width/zero-width intrinsic invalidation, removes the duplicate rich whole-document selection overlay while retaining leaf selection, and completes the math-era TextKit 2 attachment lifecycle. Current evidence includes vendor 82/82 and strict Release, SharedUI 25/25, root 938/14 skipped/0 failed, current macOS/iOS Debug/Release builds, and final notice/resource/font audit. One preceding root rerun entered an XCTest wait state and was boundedly interrupted with no residual before the fresh full pass. The staged hash-pinned Release fixture subsequently completed same-renderer A/B, five isolation stages and Light/Dark Computer Use without TERM/KILL or residual instances. These were short runs; historical malloc retaining-edge, long soak, real clipboard/VoiceOver and real-device validation remain open.
- The task/goal final-design slice from `codex-report/07_14_26-intatis-task-goal-final-design.md` is implemented as four distinct layers: durable user `Goal`, user-visible `WorkTask` DAG, host checkpoint/recovery `ContinuationRun`, and the existing `TaskContract`/scheduler layer retained as AgentInvocation execution. In addition to stable IDs/revisions, legacy decode, CRUD/DAG/capability leases, immutable in-progress contracts, write-set conflicts and atomic carry-forward, the final hardening includes host-derived readiness recomputation; atomic reservations for concurrent `delegate_task(to:auto)`; exact Goal/run admission tombstones; cancellation-persistence quarantine with bounded waiters; durable `agent_message_discarded` settlement for late scoped mailbox sends; a persistent startup scheduler gate; Goal mutation/pending-stop/shutdown/start-cancel fencing; explicit narrow attachment-independent natural-language Goal intent; and an independent strict no-tools GoalVerifier that treats WorkTask result/evidence as agent-reported and accepts only host-derived `validationEvidence` from durable successful allowlisted validation settlements. The Cowork inspector uses real Goal/Tasks projections with full durable edit instead of fake TaskContract Goals. Validation passes the nine-suite Task/Goal-focused **121 tests / 0 failures**, IntatisMac and IntatisiOS Simulator Debug builds, CLI product build, and CLI `/goal` help output. The complete 605-test run executed with 14 skipped and 34 failures (9 unexpected), all in pre-existing Tools process/loopback tests because this host rejects nested `sandbox-exec` or loopback bind; Task/Goal and all other suites passed. Computer Use launched the built app, restored Cowork, opened Project settings, and verified an unsent `/goal` draft enables send before being cleared. Remaining external validation is a real-provider multi-run, active Goal/Tasks button flow, real App process-kill/restart timing, long-duration budget/account usage, and full GUI/device matrices—not a known source-design gap.
- Permission semantics from `codex-report/07_12_26-20_37-opencode-permission-source-audit.md` are implemented at the code/theory level: `PermissionIntent` separates concrete data/control effects from CapabilityLease, WorkspaceLease, reviewer decision and replay policy; `spawn_agent` is reviewed as `agent.spawn` with workspace admission resources rather than a file write, defaults child access to read-only, supports explicit bounded `requestedAccess=read_write`, and keeps `canCoordinate` independent. One outer approval commits one atomic admission; later child tool calls remain separately permissioned. Production Cowork uses only the durable responder reviewer, while optional in-engine review is reserved for non-Cowork hosts; old fallback execution machinery is removed and automatic failures remain fail-closed. Validation passes focused permission tests 109/109, full SwiftPM 506 tests / 14 skipped / 0 failures, and IntatisMac macOS Debug build. Real-provider GUI wording is the remaining external verification item, not a source blocker.
- OpenCode-compatible Chat/Code request options are configuration-lossless but adapter-aware: macOS/CLI retain provider npm, model-level provider npm and arbitrary model options; custom-provider selection is model override → provider npm → `@ai-sdk/openai-compatible`. Only nil advances to the next selector; explicit empty/whitespace npm is retained and fails closed. Exact package semantics are lowered only at the request boundary, and unknown/unsupported packages do not fall back. Options use OpenCode-style deep merge; CLI Chat/Code now includes the selected variant instead of only its reasoning label. Intatis still owns structural/single-candidate/usage/output-ceiling fields. Cowork durable profiles retain their stricter allowlisted schema while freezing the effective adapter into immutable connection/profile revisions; schema-v1 writers continue emitting original required empty option fields. 2026-07-28 validation: Provider 145/145, CLI 21/21, Developer ID IntatisMac Debug build. Real OpenRouter request/dashboard A/B remains external.
- Model configuration has a separate read-only presentation projection, and macOS treats OpenCode-compatible `variants` as named request-parameter presets for the same real model. The menu retains a base model item and flattens each non-disabled variant beside it, with the configured variant/reasoning value in secondary text. Selection persists only provider/model/variant identity; it does not duplicate parameters or rewrite JSON. The request keeps the real model ID and deep-merges the selected variant over base options using plain-object recursion and array/scalar/null replacement. Unselected variants remain inactive. Native Menu pixel/color and real provider body QA remain external.
- Cowork composer now exposes a native provider-grouped selector for the **next `@main` Send**, not the live current agent binding. It consumes the existing AppConfig → immutable inference catalog → secret-free `AppInferenceProfileOption` pipeline; selection remains available while work/agents are active and only updates composer staging. Every new main-hosted Send requires and freezes that instant's exact binding in its immutable `UserMessagePayload`, preserving independent A/B choices through outbox, FIFO, recovery and Retry; direct ordinary-agent messages carry none. New durable Goals also retain that binding for every continuation/restart. At the submission execution boundary the host-only path atomically persists the optional idle-`@main` rebind together with the exact root/retry queue admission, then commits live state; unavailable or changed profiles fail closed with no fallback. Existing workers, current/frozen tasks, permission reviewer, Goal verifier, Chat/Code selection and future-agent default remain unchanged. The prior **110/110** result is retained only as the pre-semantics selector/rebind baseline; current focused/build results are recorded in that slice's final validation. That selector slice did not launch the App, so native busy-menu interaction, process restart and real-provider A/B routing remain manual/external validation; the later math-only fixture run does not validate them.
- Cowork minimum closed loop upgrade from `codex-report/07_12_26-16_25-opencode-cowork-orchestration.md` is implemented locally: Code/Cowork share headless `AgentRuntime`; `RuntimeEnvironmentManifest` and request snapshots define the first-request tool protocol; automatic reviewer is allow/deny-only with current-call fail-closed errors and no hidden GUI fallback; cumulative reviewer token is soft/default-unbounded; `spawn_agent` has one external permission decision and atomic admission; `delegate_task` can reuse/create a worker atomically and rolls back a newly created worker when task admission fails; identical denied calls circuit-break. Its historical validation showed a then-current GUI input gate, but Phase A has since replaced that behavior: Cowork input stays editable, Send durably accepts a local submission, and reviewer availability matters only when an ask-class tool is actually requested. The older 494-test/GUI record remains historical evidence, not the current Phase A acceptance result. A real external provider task was deliberately not sent.
- Project source policy upgraded on 2026-07-12: Intatis is now Apple-first and Swift-native-first rather than strict clean-room. Compatible public source, public model-facing prompts, tests, dependencies, and isolated runtimes may be selectively copied, translated, modified, linked, or bundled under `docs/OPEN_SOURCE_REUSE.md`, with pinned upstream commits, file/dependency license review, provenance, NOTICE updates, Apple platform impact review, and unchanged Permission/Lease/EventLog boundaries. OpenCode is currently research-only; no OpenCode source, prompt, UI asset, or runtime has been integrated yet.
- macOS advanced provider config ownership is corrected: the canonical files are now `~/.config/intatis/intatis.json` / `intatis.jsonc` with app-support `intatis.json` / `intatis.jsonc` fallback, while the JSON content remains OpenCode-compatible. Default discovery, Open Intatis Config generation, settings write fallback and secret resolution no longer inspect any `opencode.json` or OpenCode app config; `INTATIS_CONFIG` remains the only explicit arbitrary-file override. The existing local Intatis-owned file was renamed to the canonical filename without reading its contents.
- Cowork permission/reliability hardening is implemented locally: Permission Reviewer now has a dedicated structured control-plane queue and durable verdict; AgentLoop permission/tool audit is fail-closed; tool execution uses durable prepare/settle tickets and recovery refuses uncertain non-idempotent replay; timeout/cancel no longer waits for a non-cooperative provider; production registries no longer expose raw `run_shell` and the retained runner is additionally OS-confined/network-denied; EventLog has cross-process append locks plus a production session writer lease; detach/revoke are persistence-first; concurrent token requests reserve a soft budget slice before dispatch. Ordinary interrupted read-only work may still requeue with a new attempt, while unresolved write/exec/network/destructive or collaboration side effects fail with manual reconciliation required. Per-agent inference routing was not part of that historical defect repair, but is now implemented as the separate exact-profile slice recorded above; it does not weaken the permission/reliability boundaries.
- Cowork permission/reliability remediation is now `fixed`: final focused runs passed `PermissionReviewControlPlaneTests` 17/17, `AutomaticPermissionReviewTests` 12/12, `OrchestrationReliabilityTests` 28/28, `AgentLoopPolicyTests` 14/14 and `WorkspaceLeaseTests` 4/4; the combined non-process suite passed 401 tests with 0 failures. IntatisMac Debug, generic IntatisiOS Simulator Debug (arm64 + x86_64), and the `intatis` CLI product all build. Production registries contain no raw `run_shell`; workspace leases pin canonical root device/inode identity and fail closed before permission, after permission wait, after durable prepare and before managed process launch; generic tools cannot mutate Git config paths. The Tools test bundle compiles, and earlier independent real macOS process smoke passed workspace confinement, external/symlink denial, loopback denial, cancellation, timeout and large dual-stream output. The final three process/Git runtime tests could not be rerun after their test-fixture portability fix because the host sandbox rejects nested `sandbox-exec`/loopback and outside-sandbox approval hit its usage limit; no source assertion failure remains known. Real provider/device, Linux bwrap, two-runtime writer-lease pressure, real browser and long-running recovery matrices remain verification follow-ups rather than code blockers.
- v0.16 Agent document/media tool slice is implemented locally after GitHub/open-source survey. Standard tools now include `read_pdf`, `read_document`, `edit_pdf_pages`, `reconstruct_document_image`, `compile_latex`, and `generate_image`. The implementation deliberately wraps mature external backends instead of copying or vendoring them: PDF page operations use PDFKit in-process today and can map to qpdf/Poppler-style CLI backends later; Office/general-document reading supports installed local Docling or MarkItDown (plus LibreOffice for legacy formats); scanned document/photo reconstruction supports installed Docling, Marker, and Tesseract wrappers; LaTeX supports installed Tectonic, latexmk, xelatex, or pdflatex; provider-backed image generation writes returned images into the workspace through `ImageGenerationToolService`.
- v0.16 keeps the permission and platform model intact. All new tools run through AgentLoop schema validation, `PermissionEngine`, `PathConfinement`, and structured `tool_result` events. Cowork read-write coordinator/worker leases can expose process-backed `read_document` and the full document/media set, while ordinary workers default to read-only `read_pdf` and do not receive parser execution, PDF editing, LaTeX execution, or image generation tools by default. iOS remains outside Tools/Permission/AgentKernel/Cowork linkage.
- v0.16 validation baseline before the new opt-in browser concurrency smoke: Tools focused tests passed locally (55 tests, 12 skipped, 0 failures, including same-workspace-profile browser command serialization, metadata-only browser profile inventory with runtime marker existence checks, explicit browser profile deletion with non-sensitive marker warning, browser search result/history, browser form submit payload/history, browser opened-page state/history metadata, browser_type credential-target rejection, and web_fetch local HTTP/truncation/non-HTTP rejection), full SwiftPM tests passed locally (331 tests, 12 skipped, 0 failures), AgentKernel focused tests passed locally (22 tests, 0 failures, including browser_search, browser_profile_delete, browser form-task, and dynamic-feed browsing AgentLoop permission flows), `swift build` passed, and the previous IntatisMac / IntatisiOS simulator Xcode Debug builds passed. Existing real Edge/CDP smoke coverage now includes backend fallback, DuckDuckGo search, profile persistence, upload/download, select/press, local HTTP form submit, popup/new-page following, scroll/wait, profile isolation, back/forward, local dynamic feed + online task flow, and headed handoff. Real Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers installations, real provider image generation, real document-photo reconstruction quality, third-party headed login/social/online-task browser matrices, third-party website downloads/uploads/form-submit, long-lived profile cleanup/pollution behavior under real browser process pressure, simultaneous real-browser profile launches, and real device/key matrices remain UNKNOWN; sequential profile isolation has passed.
- v0.16 Agent network/browser tool slice is implemented locally after GitHub/open-source survey. Standard tools now include `web_fetch`, `browser_diagnostics`, `browser_profiles`, `browser_profile_delete`, `browser_history`, `browser_navigate`, `browser_snapshot`, `browser_handoff`, `browser_reload`, `browser_back`, `browser_forward`, `browser_click`, `browser_type`, `browser_submit`, `browser_select_option`, `browser_press_key`, `browser_scroll`, `browser_wait`, `browser_screenshot`, `browser_upload_file`, `browser_download`, `browser_downloads`, and `browser_search`. The implementation wraps URLSession for lightweight fetch and installed Node.js + Playwright for real Chromium/Chrome/Edge persistent browser profiles; when Playwright is not resolvable, it falls back to Node.js built-in `WebSocket` + Chrome DevTools Protocol against an installed Chrome/Edge/Chromium executable, instead of copying Chromium/CEF/Playwright source into the repo. Interactive actions that open a new tab/window now follow the opened page and persist that final URL/title in state/history; Playwright uses page/popup events, while CDP fallback uses real mouse events for click/download and target polling/switching. `browser_profiles` lists safe profile/state/history/download metadata plus active/lock runtime marker existence without reading cookies, localStorage, browser profile databases, marker contents, or downloaded file contents; `browser_profile_delete` is a destructive, confirmation-gated cleanup tool for one workspace-scoped profile and gives only a non-sensitive marker warning before deletion; `browser_submit` submits the current page form or a targeted form/control/submitter as an exec+network browser action; `browser_type` masks typed values in observations and refuses likely password, 2FA, token, or API-key targets before shell/backend entry, requiring `browser_handoff` for user takeover. `browser_handoff` opens a bounded headed persistent profile for user login/manual takeover, then returns a page snapshot and persists state/history. Playwright wrapper and CDP fallback both use command-level watchdogs, and CDP fallback also uses bounded send/close/process-exit handling so browser commands fail instead of hanging indefinitely.
- v0.16 browser state is workspace-scoped: `.intatis/browser/profiles/<profile>` stores browser profile data, `.intatis/browser/downloads/<profile>` stores downloads, `.intatis/browser/state/<profile>.json` stores current page metadata plus Intatis-managed `navigationStack` / `navigationIndex`, and `.intatis/browser/history.jsonl` stores non-secret history metadata. `browser_history` only reads the history metadata file; `browser_back` / `browser_forward` use the state navigation stack to choose a target URL and execute the browser navigation inside the same profile-level critical section; `browser_screenshot` only writes workspace-confined PNG outputs; `browser_upload_file` only accepts workspace-confined input files; `browser_download` only writes explicit downloads under `.intatis/browser/downloads/<profile>`; `browser_downloads` only lists metadata. Same-workspace-profile Playwright/CDP browser commands are serialized in-process so multiple agents do not concurrently open/write the same persistent profile/state/history, while different profiles remain parallel. These profiles may contain cookies/login state and must not be treated as ordinary artifacts, committed files, or shareable logs.
- v0.16 browser permission model is explicit: `web_fetch` is network-only; `browser_profiles`, `browser_history`, and `browser_downloads` are read-only metadata tools; `browser_profile_delete` is destructive and requires permission plus exact `confirmProfile`; `browser_diagnostics` is shell-backed exec without network risk; page navigation/handoff/reload/back/forward/interaction/form-submit/scroll/wait/screenshot/upload/download/search browser tools are exec + network and therefore require shell-capable platform/profile before network approval. Cowork coordinator leases can expose `browse_web`, while ordinary workers default to no `web_fetch` or `browser_*` tools.
- v0.16 browser validation baseline before the new opt-in browser concurrency smoke: Tools focused tests passed locally (55 tests, 12 skipped, 0 failures, including fake-shell concurrent profile state/history metadata, same-workspace-profile serialization overlap detection, metadata-only profile inventory with runtime marker existence checks, confirmation-gated profile deletion with history pruning and marker warning redaction, headed handoff payload/state/history, workspace upload, explicit download changedFiles, metadata-only downloads listing, browser-search result text/link/history, interactive element summaries, opened-page observation/state/history metadata, browser_type credential-target rejection, form-submit payload/history, select-option history/state, press-key history/state, scroll history/state, wait history/state, reload history/state, back/forward navigation stack/history, zero-delta rejection, key control-character rejection, and web_fetch local HTTP/truncation/non-HTTP URL rejection), full SwiftPM tests passed locally (331 tests, 12 skipped, 0 failures), AgentKernel focused tests passed locally (22 tests, 0 failures, including browser_search, browser_profile_delete, browser form-task, and dynamic-feed browsing AgentLoop permission flows), and `swift build` passed. This machine has Node v26.3.0 and `/Applications/Microsoft Edge.app`; `require('playwright')` is currently not resolvable and Google Chrome/Chromium apps were not found, but Edge/CDP smoke runs verified navigation to `https://example.com`, DuckDuckGo search with persisted search history metadata, bounded headed handoff, select+Enter, scroll+wait, persistent cookie/localStorage/history, profile isolation, real file input upload, Blob download, local HTTP form submit, local dynamic feed + online task flow, and local target=_blank popup/new-page following with state/history persistence. Real Playwright browser runs, third-party headed login, social media browsing, online task automation, captcha/2FA, third-party website downloads/uploads/form-submit, long-lived profile cleanup/pollution behavior under real browser process pressure and simultaneous real-browser profile launches remain UNKNOWN; sequential profile isolation has passed. One attempted simultaneous Edge/CDP profile-launch smoke hung and was stopped. `browser_profile_delete` provides explicit workspace profile cleanup plus active/lock marker diagnostics, but real long-lived Edge/Chrome profile deletion behavior remains unverified when external browser processes hold files.
- v0.16 browser concurrency validation note: this session added the opt-in `INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE=1` smoke `testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled` for simultaneous different-profile Edge/CDP launches. The new test compiles and its default skip path passes (`swift test --disable-sandbox --scratch-path /private/tmp/intatis-real-profile-concurrency-skip --filter IntatisToolsTests/testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled`: 1 skipped, 0 failures), and `swift build --disable-sandbox --scratch-path /private/tmp/intatis-build-concurrency` passes. The actual real-browser concurrency smoke was not run because the required outside-sandbox escalation was rejected by the current environment usage limit; a current sandboxed `IntatisToolsTests` run compiled and executed 56 tests / 13 skipped but failed the pre-existing `testWebFetchLocalHTTPAndTruncation` due loopback bind denial. Simultaneous real-browser profile launches therefore remain UNKNOWN.
- Under the latest v0.16 acceptance wording, the Agent network/browser tool goal can be treated as complete at the code/theory level: mature OSS was surveyed first, the shipped implementation wraps Playwright/CDP/installed Chromium-family browsers instead of vendoring browser projects, and the Agent-visible tool/permission/lease surfaces are implemented. The remaining Playwright/Chrome/Chromium, third-party login/social/online-task, long-lived profile, and simultaneous real-browser profile launch items are validation matrix gaps rather than blockers for this scoped goal.
- Codex-aligned Git control slice is implemented after official Codex App/Worktrees/CLI/Cloud docs, openai/codex source, and broader open-source Git tooling survey. Sources reviewed included Codex Git UI/worktree/review/cloud behavior, Codex `git-utils` patterns, libgit2/SwiftGit2 as future in-process Swift-native candidates, go-git/isomorphic-git/JGit/gitoxide as mature ecosystem references, and GitButler/Jujutsu as workflow references. The shipped slice deliberately adds no dependency and keeps `GitService` backend-swappable. Standard tools now include `git_status`, `git_diff`, `git_diff_staged`, `git_info`, `git_recent_commits`, `git_diff_base`, `git_branch`, `git_create_branch`, `git_stage`, `git_unstage`, `git_commit`, `git_apply_patch_check`, `git_apply_patch`, `git_stage_patch`, `git_unstage_patch`, `git_revert_patch`, `git_worktree_list`, `git_worktree_create`, `git_worktree_remove`, `git_remotes`, `git_fetch`, `git_pull_ff`, `git_push`, and `git_switch`. The process-backed implementation uses parameterized `git` invocation instead of shell string interpolation, disables terminal prompts/optional locks/hooks/fsmonitor for internal commands, requires repository root to match the agent workspace, confines path and patch changed paths through `PathConfinement`, allows only Intatis-managed linked worktrees under `.intatis/git-worktrees/`, disables hooks/GPG interaction for agent-created commits, refuses to commit staged sensitive paths, only accepts configured remote names, redacts remote URL credentials/tokens, requires clean working tree for pull-ff/switch, uses `--ff-only` for pull, and rejects force push. Cowork `ToolCapability.gitControl` lets coordinator leases expose local Git control; `ToolCapability.gitRemote` lets coordinator leases expose guarded remote Git control; worker leases expose no Git tools by default; legacy `runShell` compatibility exposes only read-only Git tools. Still deferred: merge/rebase/reset/clean, force-push, remote auth management, PR/CI/review automation, libgit2/SwiftGit2 dependency integration, and real complex-repo/remote matrices.
- Git control validation status: source builds with `swift build`, and fake Git / registry / lease / permission / patch path escape / destructive confirmation tests were updated. Current focused validation used isolated scratch path `/private/tmp/intatis-git-xctest-smoke`: `IntatisToolsTests` passed (64 tests, 14 skipped, 0 failures), `IntatisAgentKernelTests` passed (23 tests, 0 failures), `CapabilityLeaseTests` passed (3 tests, 0 failures), `ToolRegistryLeaseTests` passed (6 tests, 0 failures), and `INTATIS_REAL_GIT_SMOKE=1` real `ProcessGitService` smoke passed (1 test, 0 failures), covering real temporary Git repo stage/commit/recent/info, patch check/apply/revert clean, and `.intatis/git-worktrees` create/info/remove. `/private/tmp/intatis-git-harness`, a temporary SwiftPM executable importing local `IntatisTools`/`IntatisProtocol`, also passed standard Git tool registry, worker/coordinator lease boundary, quoted `diff --git` path parsing, and the same real Git smoke. Default `.build` XCTest helper previously hung while loading `IntatisPackageTests.xctest`, so reliable current XCTest evidence uses the isolated scratch path. Real submodule, merge conflict, hook, detached HEAD, non-repo, patch conflict, GUI/provider E2E Git scenarios, and broader complex-repo matrices remain UNKNOWN.
- First API/tool stability slice is in progress and has SwiftPM/Xcode build coverage: OpenAI-compatible HTTP failures, provider SSE error payloads, malformed SSE chunks, transport failures, and multimodal non-2xx responses now flow through shared provider/runtime error formatting instead of raw transport text.
- HTTP non-2xx response bodies now distinguish structured provider errors from unstructured gateway/proxy pages: JSON fields such as `error` / `message` / `detail` / `error_description` are still shown as `Provider said`, while ordinary HTML or plain-text bodies are capped as `Preview` so users see useful context without mistaking proxy noise for a provider-authored diagnostic.
- Tool execution feedback now records clearer unknown-tool, denied-permission, and tool-error observations; Code projection and CLI output can mark these tool results as failures without parsing assistant transcript text.
- Chat / Code / Cowork projections now derive compact recovery advice from `ErrorPayload` and failed `tool_result` observations, so GUI error cards can tell the user whether to retry, fix provider config, check endpoint/model compatibility, rerun after permission changes, or inspect tool inputs without changing the append-only event schema.
- Provider health check/model test call has a shared implementation: `ProviderRegistry.healthCheck(role:options:)` resolves the selected provider/model/secret and uses `ProviderHealthReport` for chat/agent checks, timeout reporting, partial stream detection, and compact user-facing summaries. macOS Settings now runs both Chat and Code(agent) checks from that shared API and shows the non-secret key source type (`auth file`, `env`, `secret file`, or legacy keychain); iOS settings stays chat-only. Both chat and agent health checks request usage, and the agent request body is covered by provider tests.
- OpenAI-compatible providers now normalize bearer authorization at request build time: accidental saved values like `Bearer <key>` or quoted keys are sent as a single `Authorization: Bearer <key>` token. macOS direct `provider.<id>.options.apiKey` values in Intatis-owned OpenCode-compatible config are now resolved from that provider config file instead of falling back to the broader auth-file scan, so stale auth JSON entries cannot shadow the config that selected the provider/model. macOS/iOS provider registry refresh also clears the in-process secret cache so model/provider changes and settings saves do not keep using a stale key value.
- Provider runtime policy now applies shared request timeout and retry/backoff behavior to OpenAI-compatible chat streaming, tool-calling streaming, image generation, and transcription. Tool-calling retry is limited to failures before any non-error payload is accepted; an error-only retryable SSE frame may consume the remaining attempt, while accepted partial text/tool/usage/completion prevents replay. HTTP `Retry-After` and common rate-limit reset headers are parsed as numeric seconds, HTTP dates, or duration strings such as `750ms` / `1m30s`, then fed into both retry delays and user-facing error guidance with long server delays capped by policy.
- Provider endpoint URL validation now runs before transport for OpenAI-compatible chat streaming, tool-calling streaming, image generation, and transcription. Chat/tool-calling validate the effective Chat endpoint, while image/transcription validate Base URL plus their path; non-HTTP URLs, missing schemes, and missing hosts become `config` errors and health check failures instead of raw URLSession behavior.
- Non-streaming image generation and transcription now normalize HTTP 2xx but schema-incompatible payloads into actionable decoding errors. A provider error object, HTML page, missing `data[].b64_json`, invalid base64, empty image data, or missing transcription `text` is reported with a structured provider message or a capped preview plus endpoint/model/response-format guidance. Plain HTML, missing-field JSON, and bad base64 previews are not mislabeled as `Provider said`.
- OpenAI-compatible chat and tool-calling streams now accept either SSE `[DONE]` or chunk `finish_reason` as completion. They keep reading after `finish_reason` so separately emitted usage is preserved, avoid duplicate done events when `[DONE]` follows, and health check treats missing `[DONE]` plus present `finish_reason` as a completed stream rather than partial. If the stream ends with neither `[DONE]` nor `finish_reason`, adapters now throw a completion-marker compatibility error; Chat/Code preserve partial text and mark it stopped instead of writing a completed answer. Tool-calling now prefers `tool_calls` / legacy `function_call` over ordinary `stop` when multiple choices finish in one chunk. If tool-calling finishes with incomplete deltas or missing tool names, including provider drift that emits tool-call deltas and then incorrectly finishes with `stop`, the adapter throws an explicit provider tool-call stream compatibility error instead of silently succeeding with no tool execution.
- Token/usage handling now uses shared `Usage` helpers: multiple usage chunks from the same provider response are merged field-by-field, while AgentLoop accumulates usage across separate model requests in a tool loop. Chat, Agent, and ProviderHealthCheck reuse this path instead of maintaining separate counting behavior.
- Chat and Code projections now mark the current incomplete assistant/agent stream as stopped when an `error` event follows partial deltas. The partial text is preserved, the bubble gets a "response stopped before completion" recovery hint, and no new event type or schema change is introduced.
- Code view model no longer writes a second outer `agent` error after `AgentLoop` has already logged the provider/stream/tool failure, and Chat view model no longer keeps a bottom composer error when `ChatLoop` has already logged the provider failure into `EventLog`, so one failed provider request should produce one structured error card instead of duplicated event-card plus composer-error UI. Configuration failures that happen before the loop starts are still surfaced by the outer view model.
- Tool-call streaming decoder now accepts common OpenAI-compatible drift: missing single-tool `index`, string-form `index`, JSON object/array/number/bool `function.arguments`, and non-first-choice content/tool-call/finish chunks, normalizing them into the existing `ToolCall` shape without changing events or tool execution. Before emitting a `ToolCall`, non-empty accumulated `function.arguments` must decode as complete JSON; truncated or invalid JSON arguments now become explicit provider tool-call compatibility errors, while empty arguments remain allowed for no-argument tool compatibility.
- AgentLoop now validates known tool arguments before permission decisions and execution: arguments must be JSON objects and satisfy descriptor schema required fields, basic primitive types, numeric `minimum`/`maximum` constraints, string `minLength`/`maxLength` constraints, and `additionalProperties:false` unknown-field rejection. `read_file.maxBytes` is now bounded to `>= 1`, and standard tool path/query/command/diff strings are non-empty. No-argument tools can accept empty / `null` arguments as `{}`, while invalid JSON, non-object arguments, missing required fields, wrong primitive types, numeric range violations, string length violations, or unknown fields become an `invalid tool input:` `tool_result` with GUI/CLI failure classification and recovery advice.
- Cowork project mode is implemented locally for macOS in the Main-led model. Phase S replaces the earlier UserDefaults authority: canonical project settings are full snapshots in EventLog, `session.json` is derived, and bookmark bytes are session-owned capability material. New Cowork uses the strict local seven-event contract for settings/main/reviewer with no provider request; historical missing main/reviewer uses dedicated strict host recovery, while every genuine later workspace/agent expansion keeps the normal permission flow. Shared workspace capability cleanup is reference-safe, primary removal is denied at UI/method/store layers except explicit transaction rollback, and symlink legacy paths use scope-first canonical migration. GUI subscribes before bootstrap and routes no-mention messages to `@main`; Phase A makes the composer independent of exact-main/reviewer/Goal/working readiness and reports those conditions on the accepted submission instead. `@main` remains the project lead and uses `spawn_agent` / `delegate_task` / `remove_agent`. The Phase S validation (137/137 focused, 785/14 skipped/0 failures full, Swift/macOS/iOS builds, Computer Use new/restart/reauthorize/latest restore) remains authoritative for storage; Phase A has its own validation record above. Real provider, symlink picker and shared-worker removal GUI E2E remain UNKNOWN.
- Cowork delegation feedback loop is now repaired at the code/theory level: `ask_agent` and `delegate_task` tool paths wait on scheduler-driven target execution; `ask_agent` preserves direct-answer compatibility, while `delegate_task` returns a mediated structured Task Report as the caller's tool observation and logs the child-to-parent report through MessageBus/Mediator. Focused fake-provider coverage verifies that main can synthesize a worker result in the same tool loop, that a worker can call `list_files` before reporting back, and that a `spawn_agent`-created worker is auto-detached after its structured report while a manually attached worker remains. Real GUI/provider E2E remains UNKNOWN.
- The macOS UI information-architecture slice was revised again on 2026-07-23 after visual feedback: the system `NavigationSplitView` sidebar now contains the `Intatis` title, three vertically stacked SF Symbol mode rows with interactive Liquid Glass only on the selected row, mode-specific `Recent` history with a native 30×30 circular glass New control, and bottom Settings. Both the intervening single `List(selection:)` arrangement and the later horizontal segmented mode revision are superseded. The shared composer keeps two rows: a shared 40pt interactive-glass model/profile `Menu` left and usage right on row one; the product surface's existing attachment/image action left, native multiline input, optional Cowork stop and Send right on row two. Row-two action/stop/Send controls are real 40×40 native glass/bordered circles, the single-line input has the same 40pt minimum height and 8pt shared spacing, and multiline growth keeps the buttons bottom-aligned. Cowork model staging remains busy-selectable and still affects only the next `@main` Send; no Chat/Code attachment capability or font change was introduced. Source tests and macOS/iOS Debug builds pass; that UI slice did not launch the App, so its sidebar/model-menu/keyboard evidence remains `UNKNOWN` and `design-qa.md` remains historical. The later math fixture launch validates only the renderer fixture, not this UI slice.
- Current validation baseline before the new opt-in browser concurrency smoke: full SwiftPM tests passed locally (331 tests, 12 skipped, 0 failures), Tools focused tests passed locally (55 tests, 12 skipped, 0 failures), `swift build` passed, and previous v0.16 focused suites / IntatisMac / IntatisiOS simulator Xcode Debug builds passed. This session additionally passed direct XCTest runs for `AgentInvocationNonRecursiveTests` (5 tests, including structured Task Report + auto-recycle) and `SpawnAgentPermissionTests` (6 tests), and `swift build` passed after sandbox cache restrictions were bypassed through approved escalation. Real GUI/provider Cowork E2E and real Edge/CDP concurrent-profile execution remain UNKNOWN. Real provider/key/device/third-party login/social/online-task/third-party website download-upload-submit browser matrices remain UNKNOWN.
- This does not complete the broader target: real endpoint/key matrices, real-provider mid-stream behavior matrices, broader provider-specific rate-limit semantics, durable long-task resume/replay, direct multi-root tool context, real same-session multi-upstream/per-profile E2E, non-OpenAI-compatible wire adapters, inference route leases/cross-trust-domain approval, complete capability validation, and GUI permission/task recovery UX still need verification and productization. Exact per-agent profile selection, explicit durable-options admission, catalog/admission/attach/bootstrap TOCTOU closure, CLI multi-route exact credential binding/explicit recovery, main/control-plane startup gate with unresolved-worker invocation isolation, opaque durable variants, URL diagnostic redaction and redirect no-follow are no longer future-only items; their final aggregate test evidence belongs to this task's validation record, and the real-network matrix remains external validation.

## Phase S 之后的明确边界

Phase S 只统一了“哪些 session facts 存在哪里、如何迁移、怎样安全恢复登记”，没有把全部问题合并成一次大重写。Phase A 随后已作为独立 Cowork 输入链路改造完成，余下工作继续按独立问题推进：

1. **Phase A — composer / 编辑对话框权限交互（已实施）**：Cowork 草稿编辑和附件导入是纯本地行为；Send 冻结 `SubmissionID` 与完整 payload，经 outbox + EventLog 原子接受后进入 FIFO；route/runtime/reviewer 等失败显示在同一提交上并显式 Retry。恢复出的 root task 保持 paused/interrupted，只有精确 Retry 才运行；active Goal 冷启动语义后来由 Phase L 收口。
2. **Phase B — reviewer request isolation（已实施）**：`@permission-reviewer` 已使用 request/generation scoped 隔离、late-result guard、fresh provider resolution 与 replacement/resume 竞态保护；只 deny 当前 ask-class tool，后续 review 不需重启。不得把 legacy `provider_still_stopping` 兼容枚举重新当作 live runtime 状态。
3. **Phase C — permission action / tool / turn outcome（已实施）**：RequestID first-write、permission first-terminal、FIFO/reconnect idempotence、typed failure taxonomy、Decline-call/Cancel-turn 分离、automatic non-actionable、sandbox denial no-retry 与 cleanup-before-terminal 已进入协议、runtime、GUI/CLI 和测试。
4. **Phase L — runtime ownership / quit lifecycle（已实施）**：App manager 持有 exact session runtime；前台/后台与 session/window 切换不停止；Command-Q bounded stop；进程终止后下次启动只对账。session 状态可重建不等于旧任务应自动续跑，active Goal 冷启动只 durable pause，显式 Resume 才继续。

实施状态：Phase A、Phase B、Phase C、Phase T 与 Phase L 均已按独立授权范围完成。任何后续阶段都必须保留 Phase S 的 EventLog 权威、bookmark session ownership、migration marker、fresh seven-event 合同，以及 Phase L 的“切换不停止、冷启动不自动执行、Command-Q 有界关停”边界。

## Product Positioning

Intatis should not chase AI IDE parity. The target is a local-first, multi-provider, auditable AI workbench:

- Apple-first and Swift-native-first, with selective license-compliant upstream reuse where it materially accelerates the product; non-Swift runtimes stay isolated and must not weaken macOS/iOS boundaries.
- Chat surface for regular model interaction.
- Code surface for local workspace agent execution without IDE/editor assumptions.
- Cowork surface for multi-agent task collaboration.
- macOS as full product surface; iOS remains a chat/multimodal subset.
- Git control is limited to Agent tools and permission-gated local repository status/diff/patch/index/commit/managed-worktree operations plus guarded remote fetch/pull-ff/push/switch primitives. PR, CI, force push, merge/rebase/reset/clean, remote auth management, risky discard-style checkout, and IDE/editor integration are intentionally deferred.

## Next Implementation Slice: macOS UI Information Architecture

Status: completed, revised on 2026-07-21, then revised three times on 2026-07-23. The single native `List(selection:)` and horizontal segmented-mode passes are both superseded by the current title + vertically stacked icon modes + history + Settings sidebar recorded above; the two-row composer remains, with a shared 40pt first-row selection menu and corrected 40pt second-row geometry. The planning text below and the 2026-07-21 `design-qa.md` images are historical; they do not establish current pixel, keyboard, focus, Light/Dark or narrow-width behavior. The Cowork right-rail portion is further superseded by the 2026-08-02 permission-first Liquid Glass slice above.

Objective (historical planning record; superseded in control placement by the 2026-07-21 status above): restructure the macOS client layout so Intatis feels like a real local AI client/workbench rather than three separate demo screens.

Chinese design understanding:

- This is an information-architecture problem, not a single control-placement issue. The current macOS UI still reads like separate demo pages instead of a mature client.
- The left sidebar should become the real navigation and session center: `Intatis` stays at the top, three icon-forward `Chat / Code / Cowork` rows stack vertically below it with glass only on the selected row, and the remaining vertical space down to Settings is used for mode-specific session/conversation history.
- The main thread area should focus on conversation content. Current upper-right `New`, session, and model controls should not remain scattered in the content header.
- The composer should become the unified control cluster for input, model switching, context-window usage, and token accounting. The model info button/menu should switch models directly, without a second separate model selector elsewhere.
- Token accounting should eventually show cached input, non-cached input, output, and total token counts when the API reports them. OpenAI/OpenAI-compatible usage details are the first target; missing provider fields should degrade cleanly rather than inventing numbers.
- The right side should be mode-specific: Chat has no inspector by default; Code uses it for plan/task status and workspace/Git status; Cowork uses Git status, uncleaned agent status icons, and durable Goal/Tasks state rather than an agent-transcript-derived goal table.
- Git in this UI slice is status-only. Commit, branch, PR, CI, and review workflows stay deferred.
- Shared implementation is required. Sidebar mode selection, session lists, composer model/token controls, and inspector sections should be reusable/parameterized SwiftUI surfaces; iOS may share lower-level chat/session/token pieces but remains a chat-only subset.
- Structured projections and event state should drive the UI. Do not infer task, agent, token, or Git/workspace state from assistant transcript text.
- The intended end state is a client skeleton where the left side handles mode and history, the bottom composer handles model/resource context, the middle is the conversation, and the right side is the mode status panel.

Core requirements:

- Sidebar layout:
  - Keep the `Intatis` title at the top.
  - Directly below the title, use three vertically stacked icon-forward mode rows: Chat, Code, Cowork.
  - Keep the rows compact and use interactive Liquid Glass only for the selected mode.
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
  - Cowork: use the wide right side for Git status, uncleaned agent status icons, real Goal and real Tasks cards; when the inspector is unavailable or hidden, do not duplicate Goal/Tasks above the thread.
  - Git in this slice is informational/status-oriented. Do not implement commit/branch/PR workflows yet.
  - The inspector must consume structured state/projections where possible; do not infer task state from assistant transcript text.

- Shared implementation:
  - Build reusable SwiftUI surfaces for sidebar mode selection, session history lists, composer model/token controls, and inspector sections.
  - macOS and iOS must share lower-level model/session/token components where applicable, with platform-specific layout parameters. iOS remains chat-only and must not link workspace/tool/Cowork modules.
  - Avoid duplicating Chat/Code/Cowork UI logic when a parameterized component can express mode differences.

Implementation order for the next round:

1. Audit the existing `IntatisMacRootView`, Chat/Code/Cowork containers, `ThreadSurfaces`, `ProviderModelMenu`, and `TurnStatsProjection` surfaces to identify what can be reused.
2. Refactor the macOS sidebar into title + vertically stacked icon mode rows + mode-specific session/history list + bottom Settings.
3. Move Chat/Code/Cowork model switching and turn/context stats into the composer cluster.
4. Extend OpenAI-compatible usage parsing and `turn_stats` with optional cached-input/context fields, preserving old event-log compatibility.
5. Add right-side inspectors for Code and Cowork with structured state where available; Cowork uses `Git Status`, `Agents`, `Goal`, and `Tasks`, with Goal/Tasks driven only by durable projection.
6. Verify responsive resizing on macOS and check that iOS Chat still builds and remains a restricted chat subset.

Acceptance criteria for this slice:

- The fourth screenshot's current scattered header controls are gone: mode selection lives in the sidebar, model/token/context controls live with the input, and the upper-right content area is reserved for mode-specific inspector content.
- Sidebar history is usable for Chat/Code/Cowork sessions and does not fight the Settings button for space.
- OpenAI-compatible responses can populate cached input/input/output token stats when available; missing provider fields do not break UI or event replay.
- Code and Cowork have a clear right-side status area, but no IDE/editor feature parity or Git workflow implementation is introduced.
- macOS app build passes; iOS app build passes without adding workspace/tool dependencies.

Implementation result:

- Satisfied in code: sidebar mode/history/New session layout; composer-local model/context/token controls whose closed selector labels show only the model name; Chat without a default inspector; Code right inspector; Cowork permission-first native Liquid Glass rail with `Agents` / real `Goal` / real `Tasks`, no Git UI, pending-triggered rail pinning and one narrow pending fallback with no compact Goal/Tasks duplicate; reusable SharedUI surfaces; responsive message width/gutter calculation; explicit content width for message lists; Chat/Code/Cowork bubble rows aligned at the row level through shared `IntatisThreadBubbleRow` instead of spacer-only positioning; optional cached-input usage fields; OpenAI-compatible cached token parsing; old `turn_stats` decode compatibility; every assistant/agent answer keeps its first `Envelope.ts` and shows a localized 24-hour/7-day/full-date timestamp beside the agent name without changing EventLog schema.
- Verified locally: `swift build`, full `swift test`, focused Provider/Conversation/AgentKernel checks, `IntatisMac` Xcode Debug build, and `IntatisiOS` Xcode Debug build.
- Verified by synthetic render: `NSHostingView` layout probe covers Chat-shell, Chat-like bubble rows, CodeShell, and CoworkShell at 360/500/700/940/980/1180pt key widths, including short user bubble right alignment, long message wrapping, narrow-window gutter reduction, compact composer controls, and wide-window inspector layout.
- Verified by pixel assertions: temporary `LayoutAssert` renders diagnostic rows through the real `IntatisThreadContentLayout` / `IntatisThreadBubbleRow` path at 320/360/380/420/500/560/700/760/940/1180/1440pt and confirms short user bubbles align to the trailing content edge, assistant bubbles align to the leading content edge, long user bubbles stay within `messageMaxWidth`, and all marker bubbles remain inside the content column. The same verifier renders a Chat-equivalent shell at 320/360/500/700/760/940/1180/1440pt, real `CodeShell` at 360/500/700/940/1180/1440pt, and real `CoworkShell` at 360/500/700/980/1180/1440pt with diagnostic bubble colors, confirming shell-level user/assistant bubbles keep the expected content-column edges when header, composer, and inspectors appear.
- The synthetic/pixel evidence above predates the latest model-label and compact Goal/Tasks removal; it remains historical layout evidence and does not prove the current narrow-window pixels.
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
   - The local four-layer Goal / WorkTask / ContinuationRun / AgentInvocation model, append-only projections, single host Goal authority, full-requirement verifier proof, once-per-checkpointed-run atomic settlement, scoped barrier/cancel, atomic WorkTask carry-forward, durable typed provider hard-limit classification, crash checkpoint reconciliation, and full Goal edit are implemented at source level.
   - Next validate real-provider multi-run behavior, actual App process termination/restart timing, non-idempotent reconciliation, long-duration budget/account usage, and clear "why stopped" reporting without weakening `EventLog` or `seq` monotonicity. Keep these labeled as external validation gaps unless a source defect is reproduced.

6. Cowork productization.
   - Productize the real Goal/Tasks cards, verifier audit/evidence, agent roster, delegation candidates, shared artifacts, and message summaries in GUI/CLI; do not revive TaskContract-objective-derived fake Goals.
   - Follow `docs/COWORK_PRINCIPLES.md`: four-layer completion authority, scoped context, capability leases, mailbox/scheduler flow, host-driven continuation, and no nested `AgentLoop` recursion.

7. Observability.
   - Extend the current token/turn stats direction into request timing, model/provider identity, context size, tool duration, permission decisions, retries, and failure reason summaries.
   - Keep the UI compact; detailed diagnostics should be inspectable without dominating the main conversation.

8. Artifact experience.
   - Make generated files, reports, images, transcriptions, logs, and tool outputs easy to inspect, open, and trace back to their originating event/task.
   - Keep `ArtifactStore` index/blobs compatibility.
   - Next practical step after v0.16 is a real sample matrix: PDF text extraction, PDF split/extract, scanned document/photo to Markdown/HTML, LaTeX to PDF, provider image generation, optional ComfyUI/Diffusers integration, and Playwright/Chrome/Edge browser diagnostics/login/search/snapshot/interactive-elements/reload/back/forward/click/type/submit/select/press-key/scroll/wait/screenshot/upload/download/downloads/history flows.

9. Configuration and onboarding.
   - Continue hardening provider health checks, model test calls, endpoint normalization checks, and user-facing error explanations against real provider/key matrices.
   - Keep configuration as the source of truth: variant identity/selection is now explicit; next audit remaining legacy typed runtime reasoning overrides so macOS Chat/Code/Cowork never create a second parameter source beside the selected config entry.
   - Avoid printing or persisting secrets in docs, UserDefaults, logs, or diagnostics.

## Explicit Non-Goals For This Target

- No IDE/editor feature parity: no inline code editor, IDE code index, language-server integration, editor diagnostics, or Cursor-style codebase UI.
- No PR/CI/advanced Git workflow for now: PR creation, CI triage, review bots, force push, merge/rebase/reset/clean, remote auth management, and discard-style checkout are deferred. Local status/diff, patch preflight/apply/stage/unstage/revert, path stage/unstage, create-branch/commit, `.intatis/git-worktrees` managed worktrees, configured-remote fetch, clean fast-forward pull, confirmed current-branch push, and confirmed clean branch switch are allowed only through Agent Git control tools and their permission gates.
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
