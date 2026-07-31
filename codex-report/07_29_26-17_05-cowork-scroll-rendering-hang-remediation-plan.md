# Cowork 滚动期间卡死：确定版修复与诊断方案

日期：2026-07-29 17:05（Asia/Singapore）；最终补充：2026-07-30
状态：已实施 Phase 0–4，并完成第 20 节的消息级 lazy 容器最终修复；这不是整个 renderer、辅助功能或 Developer ID 发行流程的 release GO
适用范围：macOS Developer ID 直接分发版的 Chat / Code / Cowork 会话界面

> **最终结算优先级**：第 14–19 节记录了先解决 paragraph width ownership
> 后的阶段性结论；第 20 节记录随后在“进入 session 即卡死”场景取得的
> production A/B、进程 sample、最终容器修复与复验。凡涉及 macOS 顶层消息
> 容器是否继续使用 `LazyVStack`，以第 20 节为准；旧的
> “`<= 4` eager、`>= 5` lazy”不再是产品合同。

## 0. 最终决定

本次不把问题归结为一个未经取样证明的“Markdown 解析器卡死”，也不通过扩大缓存、改成永久纯文本或减少 EventLog 事件来掩盖症状。

确定采用以下四层方案，并按顺序实施：

1. **先补齐可观测性**：加入低开销 signpost、主线程 heartbeat、限量 hang bundle 和进程外 `sample` 采集入口。下一次即使界面彻底失去响应，也能留下可定位的证据。
2. **把 projection fold 与 SwiftUI publication 分开**：所有 `message_delta` 仍按 `seq` 完整、逐条 fold；只把连续 delta 的 UI 快照发布限制为每个 session 最多约 20 Hz。任何非 delta 事件都是立即发布的 barrier。
3. **删除 geometry → `scrollTo` 的反馈边**：geometry 只负责观测“是否在底部”和内容高度，不再直接触发滚动。自动跟随由独立状态机、100 ms 固定窗口节流和一次性 rich-settle epoch 驱动。
4. **增加 viewport render admission**：保留现有 50 ms streaming-rich 产品合同；用户正在滚动时，不为新进入视口或已失效 revision 的行启动 Markdown parse / `DocumentView` mount。滚动停止且该行持续可见 150 ms 后，只提交最新 exact revision。

这四层中，第 2、3 层是根据本次日志和源码可以直接确认的主修；第 4 层是对主线程原生视图创建、测量风险的有界减载。是否进一步做长消息 block-level virtualization，必须等待真实 `sample` 命中相应 hot stack，不能在当前证据不足时直接修改 vendor。

## 1. 本次问题的证据边界

### 1.1 已确认

事故 session：

`~/Library/Application Support/Intatis/cowork_tf2lkjbh/events.jsonl`

已核对到：

- 共 734 条事件，文件约 305 KB。
- 其中 584 条是 `message_delta`。
- 第一条 SwiftUI fault 所在秒有 194 条 delta，下一秒还有 85 条。
- 2026-07-29 11:26:34.826，统一日志出现：
  - `onChange(of: IntatisThreadScrollSignature) action tried to update multiple times per frame.`
- 2026-07-29 11:26:35.997，统一日志出现：
  - `<OnScrollGeometryChange Modifier> tried to update multiple times per frame.`
- 2026-07-29 11:27:24 至 11:27:30，系统记录主线程 UI unresponsiveness 性能诊断。
- 2026-07-29 11:33:39，spindump 判定应用已连续约 2.1 秒不响应。
- 最终退出状态为 9，来源与 Xcode Stop / debugger kill 一致；不是已经证实的 crash、jetsam 或 watchdog kill。

源码中的对应放大链也已确认：

- `CoworkViewModel` 对每个 envelope 同时更新 thread、permission、stats、Cowork 全套 projection：
  - `Apps/IntatisMac/Sources/CoworkViewModel.swift:563`
  - `Apps/IntatisMac/Sources/CoworkViewModel.swift:624`
- `CodeViewModel` 也按每个 envelope 发布完整 items / permission / stats：
  - `Apps/IntatisMac/Sources/CodeViewModel.swift:136`
- Cowork 每次还会扫描、复制完整 items 并重建 presented items：
  - `Apps/IntatisMac/Sources/CoworkViewModel.swift:888`
- Cowork / Code 的最后正文长度进入 scroll signature，正文每增长一次就可能请求一次滚动：
  - `Packages/IntatisSharedUI/Sources/CoworkViews.swift:1762`
  - `Packages/IntatisSharedUI/Sources/CoworkViews.swift:1827`
  - `Packages/IntatisSharedUI/Sources/CodeViews.swift:221`
  - `Packages/IntatisSharedUI/Sources/CodeViews.swift:285`
- geometry 高度变化又会请求 `.richHeightCorrection`：
  - `Packages/IntatisSharedUI/Sources/CoworkViews.swift:1788`
  - `Packages/IntatisSharedUI/Sources/CodeViews.swift:231`
- 当前 scroll coordinator 只用一次 `Task.yield()` 合并同一主线程 turn，无法限制来自不同 EventLog delta 的持续请求：
  - `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift:181`

因此可以确定，这不是单纯“数据量大”，而是以下闭环在高频流式输出和用户滚动同时发生时被放大：

```text
message_delta burst
  → MainActor 逐事件 fold + 全量 @Published
  → SwiftUI 整棵 thread 反复 diff/layout
  → last-body signature 变化
  → scrollTo
  → geometry/content-height 变化
  → richHeightCorrection
  → 再次 scrollTo/layout
```

### 1.2 实施前判断：高概率放大器（已由后续 sample 结算）

Markdown parse 已经在并发执行区域，不应把“解析本身在主线程运行”写成已确认事实：

- `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/Parser/MarkdownParser.swift:50`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMicrosoftMarkdownPipeline.swift:470`

但 rich document 发布后，原生视图创建和布局仍发生在主线程：

- 一个长消息内部使用 eager `VStack` 展开全部 block：
  - `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/BlockView.swift:9`
- paragraph 会创建 `ParagraphNSView` 并同步执行 `sizeThatFits`：
  - `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/Paragraph/AppKit/ParagraphView+macOS.swift:21`
- 测量路径会创建 TextKit 栈并调用 `ensureLayout`：
  - `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/Paragraph/AppKit/ParagraphNSView.swift:96`

这解释了为何频繁 rich mount / measure 可能进一步占满 MainActor。这里记录的
是实施前判断；后续普通 Release 的可重复 hang 已成功取得进程外 sample，
`ParagraphView`、`PlatformViewLayoutEngine.sizeThatFits`、
`NSHostingView.minSize` 与 AttributeGraph 原生布局链均被命中，结算见第 14 节。

### 1.3 实施前未知项（当前状态见第 14 节）

- 卡死最后几秒的精确主线程调用栈。
- 当时最热的是 SwiftUI diff、`scrollTo`、AppKit/TextKit layout，还是三者共同占用。
- 194 delta/s 是 provider 原始粒度，还是上游还有可调整的 chunk 策略。

这些未知项不阻塞修复已确认的反馈环，但阻止我们现在就做高风险 vendor 重构。

## 2. 不可破坏的合同

实施时必须同时满足：

- EventLog 的 JSONL schema、canonical bytes、单调 `seq` 和 subscriber 顺序不变。
- 不在 reducer 之前丢弃、抽样或合并任何 delta；provider error / cancel 且没有 `message_completed` 时，partial 正文仍必须完整。
- permission、submission、task、Goal、turn terminal 等事件不得被流式 cadence 延迟。
- session 切换、Command-W 或关闭最后窗口不得 stop 进程级 runtime。
- 所有延迟任务都携带 exact `{session scope, presentation generation}`；A session 的旧任务不能写入 B。
- 用户滚离底部后，不得由新 delta、completion 或 rich 高度变化强行拉回底部。
- stale rich document 不得伪装成当前 exact revision。
- 不新增无边界的 document、native view 或 message-height cache。
- 不把 App Store sandbox 当作设计约束；本方案只针对 Developer ID 直接分发版，同时继续保留 Intatis 自有权限链、Workspace confinement、Seatbelt 和 Hardened Runtime。

## 3. 目标架构

```text
EventLog actor
  │  canonical Envelope，全量、严格 seq
  ▼
SessionProjectionPump actor
  ├─ 每条 envelope 精确 fold
  ├─ delta：50 ms fixed-window UI cadence
  ├─ non-delta：立即 barrier
  └─ snapshot {throughSeq, generation, dirtyFields}
  ▼
MainActor single commit
  ├─ 只发布 dirty domain
  ├─ equality guard
  └─ thread snapshot 交给 SwiftUI
  ▼
ThreadScrollCoordinator
  ├─ geometry observation only
  ├─ follow/suspended/detached 状态
  ├─ live-content 100 ms fixed-window scroll cadence
  └─ final-rich one-shot settle epoch
  ▼
Viewport render admission
  ├─ idle/visible：保留现有 streaming-rich
  ├─ interacting：禁止新 parse/mount
  └─ idle 150 ms：只恢复最新 exact revision
```

## 4. Projection Pump 的精确合同

### 4.1 Actor 边界

新增一个非 MainActor、可注入 Clock 的 `SessionProjectionPump`。它持有：

- `CodeProjection`
- Cowork 模式下的 `CoworkProjection`
- `PermissionProjection`
- `TurnStatsProjection`
- `lastAppliedSeq`
- `lastPublishedSeq`
- `publicationGeneration`
- 最多一个 scheduled publication
- dirty-field mask

EventLog 仍按当前方式先持久化、再 yield 每一个 canonical envelope。不得把现有 stream 改成 `.bufferingNewest(1)`；否则 fold 前可能丢正文和 barrier。

### 4.2 Delta 发布节奏

对连续 `message_delta` 采用每 session 一个 **50 ms fixed-window leading/trailing throttle**：

- 窗口中的每条 delta 都立即按 `seq` fold。
- 第一条 delta 可以立即发布，保证首字响应。
- 窗口中的后续 delta 只更新 accumulator。
- deadline 到达时发布最新 snapshot。
- 持续输出不能无限推迟 trailing publication；禁止 reset-on-every-token debounce。
- 每个 session 最多一个 timer，不按 agent 或 message 分裂 timer。

50 ms 是确定的初始合同，对应 UI snapshot 上限约 20 Hz。它比当前逐 token 发布显著降载，又不会把流式反馈变成肉眼可见的低频跳动。

### 4.3 Barrier

**任何非 `message_delta` 事件都是 barrier。**

遇到 barrier 时：

1. 先按 `seq` fold。
2. 取消旧 scheduled generation。
3. 立即发布包含该 barrier 的 snapshot。

这包括但不限于：

- `message_completed`
- provider / runtime error
- permission request / reviewed / resolved
- submission / retry
- tool / agent status
- task / Goal / turn terminal
- 未来新增、当前代码尚不认识为“可延迟”的事件

采用“非 delta 默认 barrier”可以 fail safe；未来新增 terminal 不会因为漏填白名单而被延迟。

### 4.4 MainActor 单点提交

Code / Cowork ViewModel 不再对每个 envelope 分散执行多次 `@Published`。统一通过：

`commitProjectionSnapshot(snapshot)`

提交时：

- 拒绝 generation 不匹配的 snapshot。
- 拒绝 `throughSeq <= lastCommittedSeq` 的迟到 snapshot。
- `.items` dirty 时才更新 canonical items / presented items。
- `.cowork` dirty 时才重建 agents、summary、project、Goal、Tasks。
- `.permission`、`.stats`、`.agentState` 独立发布。
- 新值与旧值相等时不再次触发 `@Published`。

纯 `message_delta` 期间，`CoworkProjection` 本身没有变化，所以不得继续重建整套 Cowork presentation。

### 4.5 生命周期

- stream 暂停在窗口中间：到原 deadline 后发布最新 partial。
- completion 与 timer 竞争：completion generation 获胜；旧 partial 不得覆盖 final。
- cancel / error 且没有 completion：trailing snapshot 保留完整 partial，terminal barrier 立即出现。
- session A → B → A：A 的 pump 继续 fold；重新 attach 时幂等 `flushNow()`，一次提交最新 snapshot。
- shutdown：停止 intake 后 `finishAndFlush()`，再失效 generation；它不改写 EventLog 的 shutdown 语义。

## 5. Scroll 状态机的精确合同

### 5.1 删除反馈边

`onScrollGeometryChange` 只能把以下观测值交给 coordinator：

- `isAtBottom`
- `contentHeight`
- 必要时的 viewport / phase 信息

它不得：

- 直接调用 `scrollTo`
- 创建一个新的滚动 Task
- 调用 `requestRichHeightCorrection`
- 直接写会再次改变当前 geometry 的 SwiftUI view state

这是本次修复最重要的硬边界。无论后续采用什么节流参数，都不能恢复 geometry → scroll 的直接闭环。

### 5.2 跟随状态

每个可见窗口、每个 exact presentation scope 独立持有：

| 状态 | 含义 | 自动滚动 |
|---|---|---|
| `followingBottom` | 用户位于底部并允许跟随 | 允许 |
| `gestureSuspended` | tracking / interacting / decelerating | 禁止 |
| `detachedByUser` | 用户滚离底部 | 禁止 |

规则：

- 用户手势开始时只执行一次幂等 cancel，清除 pending request。
- 手势结束后，只有 geometry 证明仍在底部才回到 `followingBottom`。
- 用户离开底部后保持 detached；流式内容和 completion 都不能自动恢复。
- 提供明确的 “Jump to latest” 控件；用户点击后滚到底部并重新进入 following。
- session / window / presentation generation 变化立即取消旧 pending。

### 5.3 Live-content 滚动 cadence

语义性的 thread snapshot 变化可以申请跟随滚动，但执行器采用 **100 ms fixed-window leading/trailing throttle**：

- 最大约 10 次自动滚动/秒。
- first 和 latest 都保留。
- 只有一个 serial executor、最多一个 pending request。
- 初版所有自动滚动关闭 animation，先消除 animation 与新 layout 叠加造成的额外状态。
- completion / error / terminal 可强制 flush，但 `scrollTo` 仍放到下一个 MainActor turn，不能在当前 layout callback 中执行。

正文 UTF-8 长度不得再被当作“开始一个新 layout epoch”的条件。

### 5.4 Rich settle epoch

rich document 的一次 exact final commit 或一次 width revision 可以打开一个 settle epoch；普通 streaming delta 不能打开新 epoch。

一个 epoch 的合同：

1. geometry 只累计最新高度，不滚动。
2. 高度变化小于 1 pt 视为噪声。
3. 连续 100 ms 无 material change 后视为 quiet。
4. 最迟 500 ms 达到 hard cap。
5. **先关闭 epoch，再申请一次非动画滚动。**
6. 同一 epoch 最多执行一次。

用户手势、detached 状态、session 切换都会关闭 epoch。关闭后的 geometry 变化不能重开同一个 epoch。

## 6. Markdown viewport admission

### 6.1 本次选择

本次不把所有 incomplete message 改成“直到完成前永久 raw-only”。现有 50 ms latest-only streaming-rich 行为已经是项目合同，在没有 hot stack 的情况下不应顺手改掉。

采用以下状态：

| Viewport 状态 | 行为 |
|---|---|
| `hidden` | 保持现状：取消 pending parse，释放 document |
| `visibleIdle` | 保持现有 50 ms latest-only streaming-rich |
| `visibleInteracting` | 禁止新的 parse 和 `DocumentView` mount；raw projection 继续有界更新 |
| `visibleIdleDwell` | idle 后等待 150 ms，只对仍可见、revision 未变的行提交一次最新请求 |

细节：

- 用户开始滚动时，不主动把所有当前 exact rich view 切成 raw，避免人为制造整页高度变化。
- 已显示的 rich document 只有在仍匹配当前 request 时才能继续显示；绝不展示 stale rich revision。
- 一旦正文 revision 前进而旧 document 不再 exact，该行回到现有 raw fallback；滚动期间不启动新的 rich parse / mount。
- 新进入视口的行在交互期间只显示 raw。
- idle 150 ms 后，只有仍在视口且 exact revision 未变化的行才恢复提交。
- 同一个 activation / revision 最多提交一次。
- 已 complete 的最终正文仍由 upstream barrier 立即、完整地进入 raw projection；rich hydration 可以等到 idle dwell。

这保留了正常静止阅读时的 streaming-rich 体验，同时切断用户滚动期间最昂贵的“进入视口 → parse → mount → measure”抖动。

### 6.2 本次明确不做

- 不新增 completed-document LRU。
- 不缓存 `NSView` / TextKit attachment。
- 不新增 message-height cache。
- 不在每一段上增加 `GeometryReader` 或逐段日志。
- 不直接把 vendor 的 `BlockView` 改成 `LazyVStack`。

缓存只能减少 off-main parse，不能消除 MainActor 上的原生视图创建和测量；native view 缓存还可能带来 stale attachment 与历史内存失控风险。

### 6.3 何时才做 block-level virtualization

只有满足以下条件才进入后续独立改造：

1. 外部 `sample` 或 Instruments 明确命中 `ParagraphNSView.makeNSView`、`sizeThatFits`、`ensureLayout` 或 eager block materialization。
2. 已完成单条超长 Markdown / code / table / math 的独立 fixture。
3. selection、copy、link、math、scroll range 和 VoiceOver 均有回归测试。
4. 连续运行超过 160 秒以及多次重复运行均证明 RSS / physical footprint 有稳定平台，而不是只看一个结束点。

最终 sample 命中了 paragraph / platform-view measurement，但没有证明 eager
block materialization 是持续 hot stack。因此本轮只修复已证实的 macOS
paragraph width ownership 和无界 historical-width memo，不实施 block-level
virtualization，也不增加 document、native-view 或 message-height cache。

## 7. 可观测性与下一次 hang 的取证能力

### 7.1 Signpost

使用 `OSSignposter` 记录区间和聚合计数，不记录正文：

- `ProjectionBatch`
  - received envelope count
  - delta count
  - throughSeq
  - dirty mask
  - fold / MainActor commit duration
- `MarkdownQueueWait`
- `MarkdownParse`
- `MarkdownPublish`
- `ScrollRequest`
  - reason
  - requested / executed / cancelled / stale
- `MainThreadStall`
  - measured delay bucket

禁止逐 delta、逐 geometry sample、逐 paragraph 写日志。否则诊断本身会变成新的负载。

### 7.2 主线程 heartbeat

实现一个进程级、后台 timer 驱动的 heartbeat：

- tick：250 ms。
- 同时最多一个尚未执行的 MainActor ping；禁止排队堆积。
- 延迟达到 500 ms：warning。
- 延迟达到 2 s：记录一次 stall incident。
- incident 有 cooldown，不能每 250 ms 重复落盘。
- app inactive、系统 sleep/wake、已知 modal、进程 termination 期间抑制误报。
- 后台线程绝不能同步等待 MainActor。

heartbeat 能证明“主线程多久没有执行”，但它不是调用栈采集器。

### 7.3 Hang bundle

诊断文件与 session EventLog 分离，建议保存到：

`~/Library/Logs/Intatis/HangDiagnostics/<timestamp>-<pid>/`

合同：

- 目录 `0700`，文件 `0600`。
- 原子写入。
- 最多保留 5 份或总计 20 MB，先到者生效。
- 默认仅本机保存，不自动上传。
- 用户显式导出时才打包。
- 只保存时间、计数、duration、signpost 摘要、版本、经过脱敏的 session hash 和可选外部 sample。

禁止写入：

- message body / delta
- tool argument / result
- permission preview
- reasoning
- provider response
- secret / token
- 完整个人路径、URL 或原始 session ID

### 7.4 进程外采样

界面卡死时，应用内按钮也无法工作，所以必须提供进程外入口。实施时优先增加一个 CLI 或仓内脚本，完成：

1. 精确解析 Intatis PID。
2. 调用 `/usr/bin/sample <pid> 10 1`。
3. 导出最近 5 分钟 Intatis subsystem 统一日志。
4. 收集本轮 heartbeat / signpost 摘要。
5. 写入上述 owner-only bundle。

`spindump` 可能需要额外系统权限，不作为默认成功前提。Xcode 调试器连接时系统自动 sample 可能被抑制，因此复现后应先运行进程外采样，再按 Xcode Stop。

### 7.5 FPS 的定位

FPS / animation hitch 只能说明界面不流畅，不能说明哪个调用栈阻塞。方案中：

- Debug 可提供 1 秒滚动窗口的 frame interval / hitch overlay。
- Shipping 不逐帧写日志。
- 正式定位使用 Instruments 的 Hangs、Time Profiler、SwiftUI 和 Animation Hitches，并与 signpost 对齐。

## 8. 实施顺序

### Phase 0：证据基线与观测

- 落地 signpost、heartbeat、bounded hang bundle。
- 落地进程外 sample 入口。
- 用当前 issue session 建立可重复基线。
- 不先改变 EventLog 或 renderer 数据合同。

完成门：

- 人工阻塞 MainActor 2 秒能产生唯一 stall incident。
- bundle 不包含消息正文和敏感字段。
- 卡死状态下可从另一个 Terminal 采样。

### Phase 1：Projection Pump

- 在 `IntatisConversation` 增加可测试的 projection actor / cadence state machine。
- Code / Cowork 改成 snapshot 单点提交。
- 加入 dirty-domain 和 equality guard。
- 保持 Chat 当前 strict snapshot / catch-up 链路不变。

完成门：

- 500 delta/s fixture 下 EventLog 与 reducer final 完全一致。
- SwiftUI thread snapshot publication 不超过约 22 次/秒（包含 leading、cadence 与 terminal 余量）。
- 纯 delta burst 不再发布 Cowork 非 thread projection。

### Phase 2：Scroll 状态机

- 删除 Cowork / Code 的 geometry → rich correction request。
- 加入 follow / suspended / detached。
- 加入 100 ms fixed-window executor。
- 加入一次性 rich settle epoch。
- 加入 “Jump to latest”。

完成门：

- 10,000 次 geometry 更新产生 0 次 geometry-triggered scroll。
- 500 delta/s 下自动滚动不超过约 11 次/秒。
- 用户滚离底部后，delta / completion / rich settle 都不拉回。

### Phase 3：Viewport admission

- 把 scroll interaction / idle dwell 作为只读环境状态传给消息 facade。
- 交互期间禁止新 rich admission。
- idle 150 ms 后只恢复最新 exact revision。
- 不增加 document / native view cache。

完成门：

- 活跃滚动期间，新进入视口行的 Markdown parse admission 和 native mount 都为 0。
- idle dwell 后每个 exact revision 最多一次 admission。
- final raw bytes 与 EventLog exact 一致。

### Phase 4：真实 UI 压测与发布门

- 真实 `ScrollView` + `LazyVStack` + AppKit renderer fixture。
- Release 配置、issue session、Instruments 与进程外 sample。
- 完成长时内存平台验证和 session/window 切换验证。

只有 Phase 0 至 4 全部通过，才能把本问题标记为“已修复”。仅通过 reducer 或 scheduler 单元测试不能这样宣称。

## 9. 计划修改范围

预期业务源码：

- `Apps/IntatisMac/Sources/CodeViewModel.swift`
- `Apps/IntatisMac/Sources/CoworkViewModel.swift`
- `Packages/IntatisConversation/Sources/` 下新增 projection pump / cadence 类型
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`
- `Packages/IntatisSharedUI/Sources/CodeViews.swift`
- `Packages/IntatisSharedUI/Sources/CoworkViews.swift`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMicrosoftMarkdownPipeline.swift`
- macOS 诊断 recorder / CLI 或 script 的精确落点在实施前按现有模块边界确定

预期测试：

- `Packages/IntatisConversation/Tests/`
- `Packages/IntatisSharedUI/Tests/`
- `Apps/IntatisMac/Tests/` 或现有 macOS UI fixture target
- CLI 诊断入口对应测试

实施完成后必须同步更新：

- `docs/CURRENT_STATE.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/TESTING.md`
- `docs/PROJECT_MAP.md`（若新增文件或命令）
- `docs/NEXT_TARGET.md`

## 10. 自动化验收矩阵

### 10.1 Projection

1. 单 message 在 1 秒内 500 delta，再 completion：
   - 501 个相关 durable envelope 全部存在。
   - pump final 等于直接 full replay。
   - completion 立即发布。
   - 旧 timer 不能用 partial 覆盖 final。
2. 持续 delta：
   - cadence 不被 reset debounce 饿死。
   - 每 50 ms 窗口持续前进。
3. error / cancel，无 completion：
   - partial 不丢字符。
   - terminal 立即出现。
4. 多 agent / message 交错：
   - fold 顺序等于 EventLog `seq`。
   - publication 上限按 session 计算，不是 agent 数 × 20 Hz。
5. permission / task / turn barrier：
   - FIFO、first-terminal、attempt 语义与 full replay 一致。
6. A → B → A：
   - A 的旧 timer / snapshot 无权写 B。
   - 回到 A 后一次 flush 到最新 `throughSeq`。

### 10.2 Scroll

1. 10,000 个 geometry 样本：
   - scroll execution 为 0。
2. 500 delta/s：
   - 自动滚动不超过 11 次/秒。
   - 最多一个 pending。
3. 用户 detached：
   - stream / completion / settle 都不滚动。
   - “Jump to latest” 明确恢复 following。
4. rich height 反复振荡：
   - 同一 epoch 最多一次 scroll。
   - width revision 才能开启新 epoch。
5. 多窗口：
   - projection 可共享 session cadence。
   - 每个窗口的 scroll state 独立。

### 10.3 Renderer

1. 滚动交互期间：
   - 新进入视口行 parse admission = 0。
   - 新 `DocumentView` mount = 0。
2. idle 150 ms：
   - 仅仍可见、exact revision 一致的行恢复。
3. stale parse completion：
   - 永不发布到新 revision 或新 session。
4. 1,249-delta 现有 fixture：
   - 继续验证 scheduler / render state。
   - 明确不把它称为真实 SwiftUI/AppKit UI 性能测试。
5. 完成、离屏、重入：
   - scheduler 最终 running = 0、pending = 0。
   - 无新增 cache，因此不存在 cache eviction 假通过。

### 10.4 真实 UI / 性能

至少建立：

- 100+ 顶层 rows。
- Markdown、长 code、table、math 和单条超长消息。
- 500 delta/s burst。
- 同时上下滚动 60 秒。
- width resize、A/B session 切换、多窗口。
- 单实例超过 160 秒 soak，并重复多次。

发布门：

- 无 `multiple times per frame` fault。
- heartbeat 无大于 2 秒的 stall。
- geometry-triggered scroll 计数恒为 0。
- projection / scroll cadence 在上限内。
- final content、completion、permission、stats 与 EventLog replay 一致。
- RSS / physical footprint 呈稳定平台，无持续单调增长。
- Release Instruments trace 没有新的主线程长阻塞。

## 11. 回滚与故障隔离

- 现有 `-IntatisPlainSafeMessages` 继续作为 renderer 紧急诊断开关，不作为正常产品路径。
- 增加一个仅诊断用的“禁用自动 thread follow”开关时，其安全行为必须是：
  - 停止自动滚动；
  - 保留手动 “Jump to latest”；
  - 绝不恢复 geometry → scroll。
- projection cadence 若出现语义回归，只允许临时关闭 UI publication coalescing；不得修改或抽样 EventLog。
- viewport admission 若出现显示回归，可以临时保持 raw fallback 到 idle；不得展示 stale rich document。

这些开关都必须显式可见、可诊断，不能悄悄改变 provider、权限或 durable event 语义。

## 12. 明确排除项

本轮方案不包含：

- 修改 provider 的原始 token / delta 生成协议。
- 修改 EventLog schema 或丢弃 durable delta。
- 依赖 Mac App Store sandbox 的替代实现。
- 为了“通过测试”降低 fixture 负载。
- 用 mock reducer 测试冒充真实 SwiftUI/AppKit 滚动测试。
- 在没有 sample 的情况下重写 vendor renderer。
- 新增无界缓存或把内存峰值转化为常驻内存。

## 13. 历史方案冻结记录（已由第 14–19 节取代）

本节是 2026-07-29 方案冻结时的原始审查记录，保留用于说明当时尚未改代码的
事实；实施后的最终审查、文件和验证结果以第 14–19 节为准。

### MODEL_CHECK_RESULT

当前主 Agent 模型：GPT-5 系列 Codex；运行面未提供更精确、可验证的模型 build 标识。

### PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 与预期匹配：是

### FILES_WRITTEN

- `codex-report/07_29_26-17_05-cowork-scroll-rendering-hang-remediation-plan.md`

未修改业务源码、测试源码、构建配置或其他项目文档。

### PROJECT_AUDIT_SUMMARY

本次实际检查了：

- 根级与项目级 `AGENTS.md`
- `docs/CURRENT_STATE.md`
- `docs/MACOS_DISTRIBUTION.md`
- `docs/PROJECT_MAP.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/OPEN_SOURCE_REUSE.md`
- `docs/TESTING.md`
- `docs/NEXT_TARGET.md`
- `docs/COWORK_PRINCIPLES.md`
- Code / Cowork ViewModel 的 EventLog subscription 和 projection publication
- Code / Cowork thread scroll signature 与 geometry callback
- `IntatisThreadScrollCoordinator`
- message facade、raw projection、Markdown scheduler / renderer lifecycle
- vendor `BlockView`、`ParagraphView`、`ParagraphNSView`
- 当前 issue session EventLog 和对应 macOS unified log
- 既有 session-layout、Markdown migration / validation、ChatGPT rendering lifecycle 报告

### DOCS_CONTENT_SUMMARY

本报告冻结了：

- 已确认根因与未知 hot stack 的边界。
- 50 ms projection cadence。
- 非 delta barrier。
- 100 ms scroll cadence。
- geometry observation-only。
- 100 ms quiet / 500 ms hard-cap 的 one-shot rich settle epoch。
- 150 ms viewport idle dwell。
- 无新缓存、无无证据 vendor 重写。
- signpost、heartbeat、hang bundle 和进程外采样。
- 自动化、真实 UI、长时内存和 Release Instruments 发布门。

### VALIDATION_RESULT

本报告写入后执行：

- `git diff --check`
- `git status --short`

本轮是方案文档任务，未运行构建或测试。

### UNCERTAINTIES

- 本次事故没有留下最终 hot stack；Markdown/AppKit 是源码可证的风险放大器，但不是已证明的唯一根因。
- macOS 在 debugger attachment 下抑制自动 sample 的具体条件位未找到公开、稳定的位定义，只能作为现象推断。
- 诊断 CLI / script 的最终文件落点，需要在实施时结合当前 target 边界确定。

### NEXT_RECOMMENDED_ACTION

下一步按 Phase 0 开始实施可观测性和可重复基线，然后依次实现 projection pump、scroll 状态机和 viewport admission。不得跳过真实 SwiftUI/AppKit 滚动 fixture，就直接把 reducer 单元测试通过宣称为问题已解决。

## 14. 实施后根因结算

### 14.1 可重复 production hang

最终不是依靠最初那份缺少 hot stack 的 Debug 事故日志猜根因。普通 Release、
默认 Microsoft rich renderer 和真实 session `cowork_tf2lkjbh` 可稳定在
zoom/restore 后进入无响应：

- PID 389、7637、12689 均出现接近单核 100% 的持续占用；最高观测 RSS 约
  2.7 GB。
- 进程外 sample 保存在：
  - `/private/tmp/intatis-final-production-zoom-hang-sample-20260730.txt`
  - `/private/tmp/intatis-final-production-inspector-off-zoom-hang-sample-20260730.txt`
- 外部采样 bundle 保存在：
  `/private/tmp/intatis-production-zoom-hang-diagnostics-v1/Intatis-HangDiagnostics/hang-1785386673173-389-d8f11b21`。
- sample 的主线程反复经过 SwiftUI/AttributeGraph、
  `PlatformViewLayoutEngine.sizeThatFits`、`NSHostingView.minSize` 和
  `ParagraphView` copy/init/destroy。
- 关闭 inspector 后仍可复现，排除 inspector 是必要条件。
- 同一二进制、同一 session 使用 `-IntatisPlainSafeMessages` 完成相同
  zoom/restore，未复现无响应。这个对照只用于归因，不是产品兜底修复。

事故 session 最终有 737 个 EventLog envelope；生产展示过滤后只有 13 个可见
顶层 row，最大可见 rich 正文约 1.3 KiB / 31 行。它不是“顶层消息太多导致
必然卡死”的证据。

### 14.2 已确认的直接反馈边

可重复 hang 的直接边界是 macOS paragraph 同时存在两个横向尺寸 owner：

1. `ParagraphNSView.intrinsicContentSize` 把测得的 glyph width 作为 intrinsic
   width 交给 AppKit。
2. `ParagraphView.sizeThatFits` 又把 glyph used width 返回 SwiftUI。
3. `ParagraphNSView.layout()` 在 bounds width 变化时反复
   `invalidateIntrinsicContentSize()`。
4. SwiftUI proposal、AppKit intrinsic width 和 TextKit wrap height 因而在
   zoom/restore 期间相互反推。
5. coordinator 以 width 为 key 的历史 dictionary 继续累积不同窗口宽度，
   放大 resize 期间的测量与驻留，但它不是启动反馈的唯一条件。

这与最初已经确认的 delta publication / scroll geometry 反馈环并不冲突：
projection 和 scroll 是 invalidation 放大器，paragraph 双重 width ownership
是后来用真实 sample 证实的持续原生布局边。

### 14.3 最终修复

- macOS `ParagraphNSView` 的 intrinsic width 改为
  `NSView.noIntrinsicMetric`，只保留与当前 target width 匹配的 intrinsic
  height。
- bounds width 变化只清除本地 height measurement 并合并调度 TextKit 2
  viewport layout，不再触发 width-driven intrinsic invalidation。
- `ParagraphView.sizeThatFits` 精确返回 SwiftUI 的有限正 proposal width 和
  TextKit measured height，不再返回 glyph used width。
- 每个 representable 只保留最近一个 exact-width height measurement；
  不 rounding、不 bucket、不保留历史 dictionary。测试冻结了
  `216.95 != 217.0`，因为相邻宽度可跨越换行边界。
- UIKit 继续沿用既有 bounded width-invalidation 合同，本轮没有把 macOS
  策略错误移植到 iOS。
- Code/Cowork 使用 session-scoped `SessionProjectionPump`；所有 envelope
  仍逐 `seq` fold，只有连续 delta 的展示 publication 使用 50 ms
  fixed-window cadence，任意非 delta 都是立即 barrier。
- window-local scroll coordinator 把 geometry 保持为 observation-only，
  live follow 使用 100 ms cadence，rich settle 是一次性 epoch；用户交互和
  session change 会关闭旧 epoch。
- 用户交互期间不启动新的 rich parse / native mount；idle 后每个仍可见 row
  等待 150 ms，并且只允许 exact revision 恢复。
- 加入低开销 performance counters、主线程 heartbeat、owner-only bounded
  hang bundle、CLI 进程外 sample 入口和 hash-pinned renderer watchdog。

没有改变 EventLog schema、provider delta、permission/turn terminal 语义或
runtime ownership；没有增加 document/native-view/message-height cache，也
没有把 plain-safe 变成默认产品路径。

## 15. Phase 0–4 实施结算

| Phase | 状态 | 结算证据 |
| --- | --- | --- |
| 0：可观测性 | 完成 | heartbeat、signpost/聚合计数、bounded hang bundle、CLI 外部 sample、watchdog runtime-log audit 与故障自测均落地 |
| 1：Projection Pump | 完成 | exact seq fold、50 ms leading/trailing、non-delta barrier、dirty snapshot、generation/throughSeq fence、A→B→A reattach flush |
| 2：Scroll 状态机 | 完成 | geometry observation-only、100 ms cadence、最多一个 executor + 一个 replaceable pending、detached/jump、one-shot rich settle |
| 3：Viewport admission | 完成 | 交互期 1,249 delta 的 rich admission/mount 为 0，150 ms per-row exact-revision dwell，stale completion 拒绝 |
| 4：真实 UI / 本问题回归门 | 完成 | 普通 Release 事故 session、106-row production `CodeShell` fixture、三次 180 秒 soak、60 秒主动滚动、zoom/restore、A→B→A、多窗口和 90 秒 Instruments |

## 16. 最终验证证据

### 16.1 自动化与严格编译

- vendor strict Release：
  `swift test --package-path Vendor/SwiftStreamingMarkdown -c release --disable-sandbox -Xswiftc -warnings-as-errors`
  通过，77 个 XCTest + 11 个 Swift Testing，0 failures。
- 根 full SwiftPM：1537 tests / 16 skipped / 0 failures。
- 最终聚焦矩阵：
  `SessionProjectionPumpTests|ThreadScrollCoordinatorTests|MessageRenderingTests|IntatisHangDiagnosticsTests|HangDiagnosticsCommandTests`
  为 85 tests / 0 failures。
- watchdog 使用 warnings-as-errors 编译；11 项 self-test 全部通过，覆盖 clean
  exit、exit race、wall/RSS/CPU fuse、process-group kill、telemetry
  fail-closed 与 lock contention。
- 本轮没有降低 fixture 负载、测试阈值或消息数量来换取通过。

Paragraph 专项测试覆盖：

- 10,000 次 width change 产生 0 次 width-driven intrinsic invalidation。
- 10,000 次 cache store 后仍只有一个 exact-width entry。
- 相邻 exact width 不 alias。
- query-before-layout 不复用 stale target width。
- 同一个 `NSHostingView` 运行 120 轮 A→B→A；360 个 native
  `ParagraphNSView` bounds observation 均有限且在 1 pt 容差内可逆。

### 16.2 产品构建矩阵

所有 macOS 构建均为当前 Developer ID/direct-distribution 产品
`IntatisMac` 的 unsigned 验证构建；没有构建遗留 App Store target。

| 产物 | 结果 | executable SHA-256 |
| --- | --- | --- |
| IntatisMac Debug | 通过 | `ab617fd6e9b2e69dba5f3ee521cedf9aa3d17427c9a8fc45b8c14b26da0160cd` |
| IntatisMac normal Release | 通过 | `84f29784f3b837392af3454960896afe8b66c621a9f3374737da05e1a224e267` |
| IntatisMac validation Release | 通过 | `a12dc747c79d061df8fdf592ce8852340685fa6b054fd87291e2c52c2deb2f03` |
| IntatisiOS Simulator Debug | 通过 | `4cd4b47573fecfeb12cfcff2e85437593719102bc62d98a3ab1e89ce5fce9a33` |
| IntatisiOS Simulator Release | 通过 | `65e184c903d558041770b50adca62b3e937c59c38e8466761eb56b2b31a592e5` |
| `intatis` CLI Release | 通过 | `5ad7c35a632f3b6a8af9c984e5ae60d5a042731927aa7b15a420b1edaaf33b09` |

normal Release 位于
`/private/tmp/intatis-renderer-final-normal-release-v1/Build/Products/Release/IntatisMac.app`。
仓内和该 app bundle 的 `NOTICE.md` 均为
`616f4fcaa1f7e92a5e46ee9182485a5b8da427155cdcfe025bfac7754ccd4589`，
字节一致。

### 16.3 普通 Release 真实产品路径

修复后的普通 Release、默认 rich renderer 和真实
`cowork_tf2lkjbh` 完成：

- session A→B→A；
- 5 次完整 zoom/restore；
- 8 次 scroll-up→bottom；
- 操作后 CPU 回落到 0、RSS 约 247 MB，进程睡眠且 UI 可立即响应；
- 隔离这些正常产品动作的 Unified Log 没有新的 runtime issue。

同一 PID 还打开第二窗口并加载相同 rich session。两个窗口分别保持不同的
滚动位置；第二窗口可从 bottom 滚到 top，关闭第二窗口后进程中只剩原第一
主窗口，CPU 为 0，1 秒 sample 的主线程在 `mach_msg2_trap` 等待事件。关闭
第二窗口后 Computer Use 的 AX server 自身超时，因此没有伪称再次读取了第一
窗口的精确 scrollbar 值；独立 coordinator 的取消隔离另由单元测试冻结。

### 16.4 三次 hash-pinned 180 秒 soak

三次均使用 validation executable
`a12dc747c79d061df8fdf592ce8852340685fa6b054fd87291e2c52c2deb2f03`，
真实 `CodeShell`、106 个顶层 row、长 Markdown/code/table/32 公式、17 条
message 的 exact 1,249 delta 流、自动 A→B→A 和 production
当时的 production `LazyVStack` 路径（该产品容器合同随后被第 20 节废止）。

| Run | elapsed / cycles | peak RSS / footprint | plateau RSS growth / footprint growth | CPU peak | runtime audit | 清理 |
| --- | --- | --- | --- | --- | --- | --- |
| soak-1, PID 54297 | 181.598 s / 43 | 117,473,280 / 45,024,120 B | +1,442,418 / +6,476,605 B | 29.85% | multi-update 0；heartbeat 0；invalid geometry 0 | 无 TERM/KILL；二次清理；零残留 |
| soak-2, PID 56283 | 180.315 s / 37 | 126,599,168 / 45,564,792 B | +4,871,941 / +3,398,897 B | 35.13% | multi-update 0；heartbeat 0；invalid geometry 0 | 无 TERM/KILL；二次清理；零残留 |
| soak-3, PID 60467 | 180.280 s / 42 | 121,716,736 / 46,269,304 B | -9,204,764 / +6,448,048 B | 32.77% | multi-update 0；heartbeat 0；AX-correlated invalid geometry 18 | 无 TERM/KILL；二次清理；零残留 |

每次都完成 exact delta 1,249、exact message 17、session switch 2，memory
plateau 通过。第三次在同一 PID 上交替执行 75 次 AX top/bottom；每次之间显式
等待 800 ms，动作等待合计 60 秒，完整交互墙钟窗口 106.32 秒。

第三次的 18 条 `Invalid view geometry` 必须保留原始事实：

- 它们确实记录在 Intatis PID 的 AppKit runtime issue 中，不能写成“app
  日志没有出现”。
- 三簇各为 3 组 width/height negative；全部在
  `ThemeWidgetControlViewService` 激活后约 0.17–2.99 ms 出现。
- 前两簇发生在显式 75 次滚动开始前，当时 Computer Use 正在做 AX 全树、
  ReplayKit screenshot / ScreenCapture；第三簇也紧随相同 ThemeWidget 激活。
- backtrace 中 Intatis image 只有 `main` offset，没有
  `ParagraphNSView`、`ParagraphView.sizeThatFits` 或 `CodeShell` 产品符号。
- 相同 final binary 的前两次无 AX 全树/截屏 soak 均为 0；第三次仍无
  heartbeat stall、无 multiple-updates-per-frame、资源平台稳定，并继续完成
  剩余交互和 clean exit。

因此把它分类为 **automation-correlated AppKit transient**，作为真实计数留在
报告中，但不归因于本轮 renderer layout。当前 watchdog 对 invalid geometry
只记录 telemetry；fail-closed 条件是 multiple-updates-per-frame、heartbeat、
资源、wall、fixture result 和清理，报告没有把 18 条说成“runtime audit
全零”。若以后增强 watchdog，应分别统计 AX/ThemeWidget-correlated 与
uncorrelated geometry，不能全局忽略所有 geometry warning。

### 16.5 Instruments

Time Profiler + Hangs 在 soak-2 的同一 PID 56283、同一 final validation
executable 上录制约 90.665 秒；期间执行 zoom 和滚动。证据：

- trace：
  `/private/tmp/intatis-final-soak-2-time-profiler-v6.trace`
- Potential Hangs XML：0 个数据 row，仅 schema；SHA-256
  `3e6a7b1c5896614835892637a92d58584bfb5a6d82213ce7fee01924b5b62b38`
- Hang Risks XML：0 个数据 row，仅 schema；SHA-256
  `1d766167930dbf238719821b29dfb310a0c3f122e925ea92dfba4b54d54c0dee`
- Time Profile XML：21,486 个 sample row，Intatis 主线程 19,347 个 1 ms
  Running sample，跨度 90.349 秒；SHA-256
  `28b818c72cc68c47ba4cf6a44caa12d213ca2fc48060816545f75b367d08561d`

布局不是“完全没有执行”：`PlatformViewLayoutEngine` 命中 2,586 个主线程
sample，但最长连续 4 ms；AttributeGraph + NSHosting +
PlatformViewLayoutEngine + sizeThatFits 的组合为 702 sample，最长连续 2 ms，
250 ms 窗最多 11 ms sampled CPU。NSHosting + sizeThatFits 最长短 burst
约 48 ms，250 ms 窗最多 70 ms sampled CPU。没有 Potential Hang、Hang Risk
或此前那种持续驻留的递归 hot stack。

Time Profiler 是统计采样；Release 优化/符号剥离也使
`ParagraphNSView`/`ParagraphView` 符号为 0 不能证明代码从未执行。发布判断
依赖 Hangs 表、持续时间、heartbeat、资源平台和真实交互的组合，不依赖一个
符号字符串零匹配。

## 17. 保留的边界与未知项

- 2026-07-18 三实例历史事故的最终 malloc retaining edge 仍是 `UNKNOWN`。
  本轮证明的是当前可重复 zoom/restore layout hang 已修复，不能倒推旧事故
  的所有内存边均已解释。
- fixture 以 2 ms nominal sleep 产生约 500 delta/s 的源节奏；单元测试用
  injected clock 机器证明 500 delta/秒的 cadence/上限，真实 UI fixture 没有
  单独持久化“实际 1 秒 burst elapsed”计数，因此报告只称其为 nominal
  2 ms cadence。
- Computer Use/AX 不是 VoiceOver 验收。真实 VoiceOver、真实
  selection/clipboard bytes、最低支持 macOS 和低端 iPhone/iPad 实机仍未做。
- 多窗口关闭后的第一窗口精确 scrollbar 未因 AX server timeout 重新读取；
  进程/window 数、空闲 sample、第二窗口滚动和 coordinator 单元测试均通过。
- 本轮没有进行 Developer ID 签名、公证或发布包安装验证；所有 product build
  是 `CODE_SIGNING_ALLOWED=NO` 的源码/链接验证。

这些项不重新打开本次“Cowork/Code rich paragraph resize/scroll hang”修复，
但会继续阻止把整个 renderer、辅助功能或发行流程描述成无条件 release-ready。

## 18. 实际写入范围

### 18.1 业务与测试

- projection：
  `Packages/IntatisConversation/Sources/SessionProjectionPump.swift`、
  `Packages/IntatisConversation/Tests/SessionProjectionPumpTests.swift`、
  `Apps/IntatisMac/Sources/CodeViewModel.swift`、
  `Apps/IntatisMac/Sources/CoworkViewModel.swift`
- scroll / viewport：
  `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`、
  `CodeViews.swift`、`CoworkViews.swift`、
  `MessageRendering/IntatisMessageContentView.swift`、
  `MessageRendering/IntatisMicrosoftMarkdownPipeline.swift`、
  `Tests/ThreadScrollCoordinatorTests.swift`、
  `Tests/MessageRenderingTests.swift`
- diagnostics / fixture：
  `Packages/IntatisCore/Sources/IntatisHangDiagnostics.swift`、
  `Packages/IntatisCore/Tests/IntatisHangDiagnosticsTests.swift`、
  `Apps/IntatisMac/Sources/IntatisProcessDiagnostics.swift`、
  `Apps/IntatisMac/Sources/RendererFixtureView.swift`、
  `Apps/IntatisMac/Sources/IntatisMacApp.swift`、
  `Apps/intatis-cli/Sources/HangDiagnosticsCommand.swift`、
  `Apps/intatis-cli/Sources/Commands.swift`、
  `Apps/intatis-cli/Sources/IntatisCLI.swift`、
  `Apps/intatis-cli/Tests/HangDiagnosticsCommandTests.swift`、
  `scripts/RendererValidationWatchdog.swift`
- vendor paragraph：
  `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/Paragraph/AppKit/ParagraphView+macOS.swift`、
  `ParagraphNSView.swift`、
  `Tests/MarkdownTextTests/ParagraphNSViewTests.swift`、
  `Tests/MarkdownTextTests/ViewEquatableContractTests.swift`

### 18.2 文档与归属

- 本报告
- `docs/CURRENT_STATE.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/TESTING.md`
- `docs/PROJECT_MAP.md`
- `docs/NEXT_TARGET.md`
- `NOTICE.md`
- `ThirdPartyNotices/MarkdownRendering.md`
- `Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md`

仓库中还有大量与 Skills、provider、MCP、模型历史等其他工作相关的既有未提交
改动；本轮没有回退、覆盖或清理它们。

## 19. 最终项目审查记录

### MODEL_CHECK_RESULT

当前主 Agent：GPT-5 系列 Codex。运行面没有提供更精确且可验证的模型 build
标识。

### PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 与预期匹配：是

### FILES_WRITTEN

见第 18 节。没有执行 Git add、commit、push、reset、clean 或回退。

### PROJECT_AUDIT_SUMMARY

实际读取并核对了项目常驻文档、Code/Cowork projection 与 scroll 链、
SharedUI rich admission、vendored AppKit paragraph、真实事故 EventLog、
Unified Log、进程外 sample、watchdog 结果、三轮 soak、普通 Release
多窗口状态和 Instruments 导出。源码与旧方案判断冲突时，以真实 sample 和
当前源码为准，并在第 14、16 节显式结算。

### DOCS_CONTENT_SUMMARY

项目文档已持久化以下合同：逐 seq exact fold、50 ms delta-only publication、
non-delta barrier、window-local observation-only scroll、100 ms cadence、
one-shot rich settle、150 ms exact-revision viewport dwell、macOS 单一
paragraph width owner、one-entry exact-width memo、外部 hang 采集，以及
Developer ID/direct-distribution 平台边界。

### VALIDATION_RESULT

通过：vendor strict Release、root full SwiftPM、85 项最终 focused、watchdog
11 项 self-test、IntatisMac Debug/normal Release/validation Release、
IntatisiOS Simulator Debug/Release、CLI Release、真实 production
A→B→A/zoom/scroll、多窗口、三次 180 秒 soak、60 秒主动滚动和 90 秒
Instruments。最终还执行 `git diff --check` 与 `git status --short`；其结果
为：`git diff --check` exit 0、无输出；`git status --short` 仍显示用户既有的
广泛未提交改动以及本问题的新增/修改文件。本轮没有清理、回退、暂存或提交
其中任何内容。

构建存在仓库既有的 unused-result、deprecated `onChange` 和部分 Sendable
warning，但没有构建错误；vendor strict warnings-as-errors 已通过。

### UNCERTAINTIES

见第 17 节。没有把统计采样、nominal rate、AX 自动化、单元测试或
plain-safe control 冒充对应的真实外部环境证据。

### NEXT_RECOMMENDED_ACTION

本问题不需要继续扩大修复范围。后续若专门做 renderer/辅助功能发布完善，
优先级依次是：真实 VoiceOver + clipboard bytes、AX/ThemeWidget geometry
分类 telemetry、最低支持 macOS、低端 iOS 实机，以及历史 2026-07-18
retaining-edge 的 malloc/heap 取证。

## 20. 进入 session 即卡死：最终消息容器结算

### 20.1 为什么前一轮修复后仍会卡

第 14 节的 macOS paragraph 单一 width owner 修复解决了可重复的
zoom/restore feedback edge，但没有消除消息级 `LazyVStack` 在混合
SwiftUI/AppKit、可变高度 rich row 上的虚拟化反馈。真实
`cowork_tf2lkjbh` 最终只有 13 个顶层展示 row，其中 5 个是 rich row，却仍能在
进入详情或上下滚动时持续占满一个 CPU core。

最终做了同一源码、同一 session、同一运行环境的四组隔离：

1. Microsoft rich + 消息级 `LazyVStack`：稳定进入卡死，CPU 接近 100%。
2. plain-safe + 同一消息级 `LazyVStack`：可进入并滚动。
3. Microsoft rich + eager `VStack`：可进入并滚动。
4. Microsoft rich + `LazyVStack`，仅关闭代码块/表格 selection：仍卡死。

因此 plain-safe 只作为定位对照，不是兜底修复；selection overlay 可能增加
成本，但不是该问题的必要条件。

卡死样本 `/private/tmp/intatis-entry-fix3-scroll-hang.sample.txt` 中，主线程
1509/1509 个样本停留在 run-loop observer，1484 次经过
`GraphHost.flushTransactions`，1478 次经过 AttributeGraph flush，1175 次命中
`AG::Subgraph::update`，959 次命中 SwiftUI `UpdateStack`。
`SelectionOverlay` 只在较低层次出现，bottom probe 和 scroll coordinator
不是 hot path。这个样本把直接问题结算为：

```text
message-granularity LazyVStack virtualization
  + mixed SwiftUI/AppKit rich native rows
  + variable row height / mount-unmount transactions
  → AttributeGraph transaction feedback
  → main-thread saturation and apparent app freeze
```

这不是 provider、权限审查、EventLog 解析、消息数量本身或单独 Markdown parse
导致的；这些组件可以提供输入或 invalidation，但不是该 A/B 中的必要差异。

### 20.2 最终产品修复

macOS Chat、Code、Cowork 的 rich transcript 现在统一使用：

- 最多 16 个顶层 row 的固定 history window；
- window 内使用 eager `VStack`，不再在消息粒度使用 `LazyVStack`；
- 超过 16 条时显示 Earlier / Newer / Latest 显式翻页；
- 每个 page 具有独立、稳定的 presentation scope、bottom anchor、scroll
  coordinator 与 rich admission generation；
- 用户停留在旧 page 时，新消息 append 不改变该 page，也不触发 auto-scroll；
- Send、Cowork Retry 和 Latest 明确回到最新 page；
- thinking/live-follow 只属于 latest page；
- 原 raw-first rich entry 门仍独立保留，4 条以上只是延后首次 rich mount，
  不再决定布局容器。

这不是把整个会话无界地放进 eager `VStack`。同时只保留 16 个顶层 row，
所以修复避免了原 lazy/native feedback，也不把几百条历史一次性 mount。
没有新增 completed-document、native-view、message-height cache；没有改变
EventLog、provider、permission、turn 或 runtime ownership。
`IntatisAdaptiveThreadStack` 只保留给共享 iOS/兼容路径，macOS 三个生产 rich
transcript 不再使用它。共享 iOS Chat 本轮未迁移，必须单独验证，不能由 macOS
结果推导通过。

### 20.3 自动化与真实产品复验

最终源码验证：

- `swiftc -frontend -parse`：全部本轮修改的源码/测试通过；
- `swift test --disable-sandbox --filter 'MessageRenderingTests|ThreadScrollCoordinatorTests'`：
  69 tests / 0 failures（41 + 28）；
- 最终重跑第一次在 manifest 编译前因受限 host 无权写
  `~/.cache/clang/ModuleCache` 退出；显式把
  `CLANG_MODULE_CACHE_PATH` / `SWIFTPM_MODULECACHE_OVERRIDE` 指向
  `/private/tmp` 后，同一命令完成上述 69/69。该首次退出没有进入源码编译或
  测试执行，不能记为产品测试失败；
- 新的原生 host 测试在同一 `NSHostingView` / `NSScrollView` 中对 16 个 rich row
  执行 4 轮 top↔bottom，确认两端可达，settle 后 `ParagraphNSView` identity
  稳定；
- 结构测试冻结 macOS Chat/Code/Cowork 都是
  `ForEach(historyWindow.items)` + bounded eager `VStack`，且 transcript
  范围内没有 `LazyVStack` / `IntatisAdaptiveThreadStack`；
- `IntatisMac` unsigned Debug build succeeded。

真实 Debug 产品使用原问题 session `cowork_tf2lkjbh`：

- 首次进入即保持响应；
- 原生 scrollbar 反复经过
  `1 → 0.807806 → 0.615613 → 0.423419 → 0.615613 → 0.807806 → 1`；
- A→B（55 条展示消息）→A 后继续上下滚动正常；
- B 显示 `Messages 40–55 of 55`，Earlier 后显示
  `Messages 24–39 of 55`，Newer / Latest / Jump to latest 可用，Latest 能回到
  `40–55`；
- 进入、滚动、翻页后的抽样 CPU 均为 0.0%；加载较大 B 后 RSS 达
  241,600 KiB，随后回落至 220,560 KiB，没有观察到此前持续线性增长；
- 本轮操作窗口没有生成新的 Intatis hang incident；
- 验收进程已关闭并通过进程列表确认无该 build 残留实例。

复验只导航、滚动和翻页，没有发 provider 请求，也没有修改任何 session
EventLog。

### 20.4 仍保留的限制

- 本 follow-up 没有重新执行 >160 秒 renderer soak；第 16 节的旧 soak 是旧
  lazy 容器的历史证据，不能冒充当前 bounded-window soak。
- 共享 iOS Chat 仍使用 UIKit/兼容容器，本轮没有真机或 Simulator 回归。
- 真实 VoiceOver、selection/clipboard bytes、最低支持 macOS 和历史
  2026-07-18 malloc retaining edge 仍为独立 `UNKNOWN`。
- 因而可以关闭用户报告的“进入/滚动该 Cowork session 即卡死”，但不能把整个
  renderer、辅助功能或发行流程写成无条件 release-ready。
