# ARCHITECTURE

## 2026-07-24 Session runtime 与展示生命周期隔离

macOS session 页面明确分成三层：

| 层 | owner / identity | 内容 | session 切换 |
|---|---|---|---|
| Runtime | 进程级 `AppSessionRuntimeManager` + exact `{SessionKind, SessionID}` | provider / AgentLoop / Orchestrator / projection / permission / workspace scope | 保留并继续运行 |
| Window presentation | 每个 `IntatisMacRootView` | mode、当前 session、inspector 显隐 | 只影响本窗口 |
| Session presentation | `IntatisThreadPresentationScope` + 该窗口 thread 的 `@StateObject` | ScrollView、bottom-follow、scroll generation、临时 geometry | scope 改变即销毁/重建 |

`IntatisThreadPresentationScope` 不写入 EventLog，也不是 runtime key。相同 session 在两个窗口中可共享 runtime，但每个窗口构造独立的 scroll coordinator；任一窗口的 cancel/deactivate 不会取消另一窗口的展示任务。Code / Cowork 详情和 thread subtree 以 scope 建立 SwiftUI identity，bottom sentinel 使用 `IntatisThreadBottomAnchorID(scope:)`，因此旧 session 的 anchor 或 task 无法命中新 session。

自动滚动是一条有 owner 的可取消状态机，而不是 main-queue 闭包。每个 coordinator 最多一个 pending request，携带 scope、generation、reason 与 bottom-following snapshot；scope 改变、用户开始滚动或新请求到达都会使旧 generation 失效。initial restore 与 live/rich correction 不动画，completion 可短动画。Scroll geometry 只区分是否在 24pt bottom tolerance 内及 material content-height change。raw item signature 或 content width 变化显式开启 layout epoch；一个 epoch 可以沿第一次 shrink 降低 baseline，并在第一次 regrowth correction 后永久关闭该 recovery window，防止 `800↔900` 高度振荡重新触发无界 scroll。用户主动离开底部后不再自动跟随。

Runtime manager 不再观察 retained ViewModel 的通用 `objectWillChange`。Chat / Code / Cowork 只把业务活动折叠为 exact-key `opening / idle / running / removing` presentation status，根窗口用 subject 更新对应字典项；manager 自身 `@Published state` 只表达 process-level running/quiescing/stopped。Cowork 另把 auxiliary operation/shutdown 纳入 `runtimeBusy` 以保护删除，但 recent-session recency 的 active→idle settlement 继续只观察 conversation/agent/Goal 活动，避免设置操作改变排序。删除由 manager 的 exact-key transaction 同时包住 runtime drain、调用方提供的 session-storage commit/abort、subscription 清理与最终 `runtimeRemoved`；通知只在磁盘结果确定后发布，`.removing` 期间的 activity/settlement 也不能覆盖状态。同 key 在 fence 释放前不能 reopen。

Chat 的历史与 live publication 也分层：

```text
EventLog.replayChecked strict snapshot
  -> compute liveFrom = lastSeq + 1
  -> register EventLog.stream(liveFrom)
  -> EventLog.replayChecked(liveFrom) strict catch-up
  -> merge/dedupe snapshot + catch-up by seq
  -> ChatHistoryProjectionBuilder actor folds merged snapshot once
  -> MainActor publishes one complete ChatProjectionState
  -> buffered/live envelopes above lastAppliedSeq apply incrementally
```

先登记 live stream、再做 strict catch-up、最后折叠 snapshot，既关闭恢复期间的事件丢失窗口，也隔离了 `stream(from:)` 为兼容旧调用者保留的 fail-soft replay；catch-up 与 stream 重叠的事件以 seq 去重。builder 同时折叠 conversation、artifact progress、artifact cards 和 turn stats。首次 strict snapshot/catch-up 失败在发布或消费 live 前 fail closed，并释放 subscription slot；macOS 再进入 cached session 时 manager 的幂等 `start()` 会重试。subscription generation 由其 owning Task 的 cancellation 管理，stop/shutdown 后旧 fold 不能回写。

## 2026-07-23 会话完成度与交互态投影

Recent-session 排序不是访问历史，也不是文件系统写入历史。面向 App 的 `SessionActivityHistoryStore` 一次读取每个 EventLog，同时统计 event count 并从尾部查找已完成工作：现行 turn 只以 `turn_outcome` 为准，没有现行终态的 legacy session 才回退到 assistant / agent `message_completed`。Cowork submission terminal 不单独提升 recency，避免恢复/对账补写被误算成新对话。选择、恢复、迁移、rename 或 lease/settings append 不得改变排序；运行中的新 turn 在 terminal 落盘前保留上一次完成位置。file signature cache 只降低重复读取成本，不把 mtime 解释为业务时间。后台 runtime manager 直接订阅 published data-plane activity，在 active→idle 边沿发布 exact session settlement，窗口只刷新对应 kind。

composer 的 Send 与 Stop 是同一个主操作槽位。工作态使用 SwiftUI 原生 destructive Button、系统 `stop.fill` 和红色 tint；Chat cancel 只覆盖当前 Chat operation，Code cancel 只覆盖当前 AgentLoop turn，Cowork 普通工作使用 orchestrator task cancellation，active durable Goal 使用 GoalRuntime 的 scoped pause/checkpoint。该动作不等于 session shutdown，不关闭 EventLog subscription、runtime owner 或 permission-review control plane。Thinking 秒数是纯 presentation phase state，由可见 spinner 行的生命周期界定，不进入 EventLog、Envelope 或模型上下文。

最近自查日期：2026-07-19

## 总体架构

Intatis 是 Apple-first、Swift-native 优先的本地 AI 工作区，三个产品面：Chat（普通多模态对话）/ Code（单 agent 本地工作区）/ Cowork（多 agent 本地工作区协作）。项目允许按 `docs/OPEN_SOURCE_REUSE.md` 选择性复用兼容许可证的公开源码，但 Intatis 继续拥有自己的产品身份、权限/lease/EventLog 控制面和 Apple 平台边界。Apple 应用与 SwiftPM 声明的最低系统为 macOS 26 / iOS 26。默认 `IntatisMac` 是 DeveloperID/non-sandbox 本地 workbench，提供全量 macOS 产品面；iOS 仍是 chat 子集。

```text
                    ┌─────────────────────────────────────┐
                    │      Intatis* 内核模块（共享）        │
                    │  Core / Protocol / Providers         │
                    │  Conversation / Artifacts / Multimodal│
                    │  Tools / Permission / AgentKernel     │
                    │  Cowork / SharedUI                   │
                    └──────────────┬──────────────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
   ┌────────▼─────────┐  ┌────────▼─────────┐  ┌─────────▼──────────┐
   │  IntatisMac       │  │  IntatisiOS       │  │  intatis-cli        │
   │  Chat/Code/Cowork │  │  Chat 子集        │  │  CLI                │
   │  (全量内核)        │  │  (无 workspace)   │  │                    │
   └───────────────────┘  └───────────────────┘  └────────────────────┘
```

## 主要链路

### Chat 链路（无工具，iOS/macOS chat 子集）

```text
macOS root sidebar or iOS toolbar history/New Chat -> selected SessionID -> per-session EventLog
  -> Chat composer -> GoalInputParser (/goal metadata) -> ChatLoop.send()
  -> buildHistory() from current EventLog
  -> ProviderRegistry resolves selected provider/model from GUI catalog
     + current chat selection override (provider baseURL + chatEndpoint)
  -> append userMessage -> provider.stream
  -> message_delta / message_completed -> turnStats
  -> GUI folds TurnStatsProjection -> compact composer-local latest-turn stats
（无工具、无权限、无工作区）
```

### Code 链路（单 agent，macOS 全量）

```text
Code composer -> GoalInputParser (/goal metadata) -> AgentLoop.send()
  -> append userMessage -> agent_status(thinking)
  -> ContextBuilder.initialMessages(history + cleaned user text)
  -> provider.stream -> toolCalls -> PermissionEngine -> tool execution
  -> message_delta / message_completed / tool events / turnStats -> EventLog
  -> GUI folds CodeProjection + TurnStatsProjection
  -> macOS Code inspector shows structured plan/workspace/Git-status-only/failure/turn state
```

### Managed terminal 链路（Code / Cowork / CLI，macOS shell-capable host）

```text
model tool_call exec_command / write_stdin
  -> ToolRegistry resolves one concrete terminal tool
  -> CapabilityLease + DeterministicPolicyGate + reviewer/responder
  -> durable tool_execution_prepared
  -> exact authorization + WorkspaceLease + root identity revalidation
  -> ProcessTerminalSessionManager
     -> non-TTY: sandboxed managed pipes
     -> tty=true: IntatisPTYLauncher forkpty -> controlling terminal
     -> macOS Seatbelt workspace allow-list + default network deny
     -> bounded continuous stdout/stderr drain + timeout/cancel TERM→KILL
  -> input echo/diagnostic scrub
  -> durable tool_execution_settled + model-visible observation
```

短命令在同一次 `exec_command` 返回终态；超过初始等待但仍运行的命令返回 opaque session ID。后续 `write_stdin` 可写字符、轮询、发送 EOF 请求或终止，但不是“已有 session 就免审”：每次调用仍有独立 tool authorization/durable ticket。危险命令检查还会在进程内按 session 保留当前输入行，覆盖跨调用文字、退格、换行与反斜线续行；光标移动、补全、历史、escape 控制和 shell keymap 改写因无法可靠重建结果而 fail closed，该状态不落盘。nonblocking input 若部分写入后失败，session 立即终止，禁止用已失真的状态继续交互。session owner 必须精确匹配 session、agent、task、attempt 与 canonical workspace identity；另一个 agent/task、root replacement 或失效 lease 无权接管。root identity watcher 即使先发现替换，也要等进程真正结束并自动生成一次性内存结果，不能因 model 未再 poll 而泄漏 session。

`ProcessTerminalSessionManager` 由 Code/CLI runtime 或 Cowork Orchestrator 持有，不属于 model。它持续读取输出，避免子进程因 pipe/PTY buffer 填满而卡死；内存只保留有界 head+tail，最新 tail 优先可见。进程结束后即使 model 未再次 poll，也会从 active table 移除并留下一个有时限、只可领取一次的内存结果。task completed/failed/cancelled、单 turn cancel、session deletion 与 app shutdown 都先终止并等待匹配 terminal sessions，再写上层 terminal 状态。该 session/result 当前不跨进程持久化；crash 后不会自动续接。

PTY launcher 是仓内小型 C target。所有 Swift 参数、argv/envp 分配都在调用前完成；`forkpty` child 只执行 async-signal-safe 范围内的 signal reset、FD close、chdir 和 `execve`，并通过 CLOEXEC pipe 向父进程报告精确启动阶段错误。固定初始窗口为 24×100；本轮没有加入 resize/SIGWINCH API。

权限面仍保留 raw `run_shell` 不可见。`CapabilityLease.runShell` 在 production 只映射到 `exec_command` / `write_stdin`；read-only worker、reviewer、iOS 或 platform shell disabled 时 registry 不注册它们。终端继承最小化后的开发工具环境和临时 HOME，常见 token/password/auth/proxy/database/JWT/access-key/session-key 变量被移除；执行边界无条件把 `WorkspaceLease.mandatoryTerminalDeniedPatterns` 合并回任何新、旧或显式空的 lease，Seatbelt 对这些 denied pattern 的 ASCII 字母按大小写无关匹配，因此 caller 不能移除工作区内的常见凭据路径。交互字节不写 EventLog，授权 identity 使用进程随机盐，当前或延迟回显在 tool observation 前清洗。

### 对话内容显示链路（Chat / Code / Cowork）

```text
EventLog raw message text + Envelope.ts (single source of truth)
  -> ConversationProjection / CodeProjection
     -> first message envelope pins a stable presentation timestamp
  -> Code/Cowork presentation gate
     -> default: user + real agent message/task-only fallback + actionable error only
        (same-task exact task_completed mirror is trace-only)
     -> backend debug opt-in: preserve the complete prior tool/patch/note/agent-to-agent trace
  -> role policy + IntatisMessageRendererMode
     -> user / system / structured special card: existing plain or dedicated view
     -> assistant / agent + plainSafe: no upstream parser/view
        -> history/activation/reentry/correction/truncation/final: exact raw SwiftUI Text
        -> append-only intermediate snapshots: 100 ms fixed-window leading/trailing latest-only Text projection
     -> assistant / agent + microsoft: IntatisMessageContentView(.richText)
        -> first paint/current semantic revision: exact raw SwiftUI Text
        -> pending/rejected/oversize append-only fallback: same persistent 100 ms raw projection
        -> syntax-agnostic admission: non-empty and UTF-8 <= 64 KiB
        -> per-view AsyncStream.bufferingNewest(1), 50 ms incomplete debounce
        -> process-wide output-free latest-only permit scheduler
           -> max 1 running parse globally / max 32 pending message keys
           -> max 1 running + 1 replaceable pending acquire per message view
           -> scheduler retains keys/generations/continuations only, never work/results/documents
        -> audited SwiftStreamingMarkdown derivative parser/layout
           -> code-aware single-dollar preprocessor masks fenced/inline code
              and preserves literal/unsupported dollar forms
           -> MarkdownDocumentParser.parse(... sending) off MainActor
           -> inline math catalog carries original TeX source into the
              attributed attachment model
           -> returned non-Sendable RenderableDocument owned by MainActor
        -> publish only if raw/mode/completion/appearance/config revision is still current
           -> exact current upstream DocumentView
           -> AppKit/UIKit TextKit 2 paragraph host renders a live
              MTMathUILabel attachment through exact iosMath 2.5.0 on MainActor
           -> stale/cancelled/rejected/oversize: keep the raw projection; final remains exact
```

Code/Cowork 的 presentation gate 只控制哪些 `CodeItem` 进入 SwiftUI 会话树、自动滚动签名和 Code inspector。默认隐藏 `.toolCall` / `.toolResult` / `.patch` / `.note` / `.agentToAgent`，避免把大型 JSON 风格工具过程当成长文本气泡排版。`CodeProjection` 另以 agent single-flight 的 `task_started` 边界关联该 `{TaskID, attempt}` 最后一个完整 `message_completed`：只有同一 TaskID、同一 attempt、同一 agent 且正文与 `task_completed.result` 完全相同，才给后者附加非 wire 的 `.executionTrace` 展示来源，默认隐藏这个 scheduler lifecycle 镜像；没有匹配 message、attempt 不一致、正文不同、retry 未生成对应 message 或跨任务同文时，task result 继续作为 conversation fallback 显示。迟到旧 attempt 的 terminal 只清理自己的配对，不会清掉当前新 attempt。user、真实 agent message 与 `.error` 仍显示，权限卡片/提交状态等专用结构化 UI 不受影响。完整 `task_completed` 事件、tool observation、AgentInvocation candidate result、agent 上下文、恢复与审计仍由 EventLog / projection 持有。后台启动参数 `-IntatisShowExecutionTrace` 或环境变量 `INTATIS_SHOW_EXECUTION_TRACE=1` 会恢复此前完整视图；该开关默认关闭、没有 UI 或 UserDefaults、进程启动时解析。

`ConversationProjection` 与 `CodeProjection` 同时把 assistant/agent 消息首次出现时的 `Envelope.ts` 固定在 presentation model；若历史只含 completion，则以 completion envelope 补齐，已经存在的时间不会被后续 streaming delta 或 completion 改写。SharedUI 只在 assistant/agent 名称旁显示这项元数据：相对当前时刻不足 24 小时为本地短时间，不足 7 天为本地化完整星期 + 短时间，其余为本地化中等日期（含年/月/日）+ 短时间，并遵循系统 locale、calendar、time zone 与 12/24 小时偏好。该字段不是 wire/schema 变化，EventLog 仍以既有 `Envelope.ts` 为唯一事实来源，用户与系统行不显示名称旁时间。

界面文案本地化同样停在 presentation boundary：两个 Apple App 的主 bundle 共用 English-source `Localizable.xcstrings`，显式提供 `en` / `zh-Hans`；静态 SwiftUI 文案由系统解析，先构造成普通 `String` 的动态标签通过 `IntatisLocalization` 从 `Bundle.main` 查表并以原 English key 回退。系统 Preferred Languages / App Language 负责进程启动时的 bundle localization，不在根 View 注入 locale，也不另存应用内语言状态。用户/模型正文、session 与 agent identity、provider/model ID、路径、EventLog、协议 token、工具参数和 model-facing prompt 不进入该层；否则同一 durable 数据会随界面语言被改写，破坏回放和安全边界。

Chat/Code/Cowork 的顶层消息容器统一通过 `IntatisAdaptiveThreadStack` 选择布局：当前可见顶层行不超过 4 条时使用 eager `VStack`，避免“少量行 + 单个超高 rich row”下 `LazyVStack` 的估算滚动范围把后半段压缩到最后锚点；从第 5 条起仍使用 `LazyVStack`，因此 17 行 production-shaped renderer fixture 继续覆盖生产 lazy 路径。底部 16pt 留白属于带 ID 的 1pt bottom sentinel 自身，`scrollTo(..., anchor: .bottom)` 因而指向视觉上的真实底部。该容器选择不缓存 Markdown document、原生 paragraph view 或测量高度，rich view 的不可见释放语义不变。

`IntatisMessageRendererMode` 是 renderer-neutral 的产品熔断层，不是第二套 Markdown renderer。持久键仍为 `intatis.messageRendering.mode.v1`；无偏好默认 `.microsoft`，未知值 fail closed 到 `.plainSafe`。`-IntatisMicrosoftMarkdownMessages` / `-IntatisPlainSafeMessages` 是当前启动 override，plain-safe 在冲突时胜出；旧持久值 `rich` 与 `-IntatisRichTextMessages` 只映射到 `.microsoft` 以保留用户意图。应用内 Picker 与 iOS `Settings.bundle` 共用 `microsoft` / `plainSafe` values。运行中 mode 变化会撤销旧 view activation；raw `EventLog`、projection、provider 请求和 session schema 均不变。

`IntatisMessageContentView` 是很薄的显示/生命周期 adapter。Markdown grammar、AST、inline attributed content、代码块、table layout 与 code-aware delimiter integration 归经审计的 `SwiftStreamingMarkdown` 派生包，TeX parse/layout 归 exact iosMath 2.5.0；Intatis 产品 facade 不遍历或改写 AST，也不另写 Markdown parser、lexer、TeX 排版或 layout。Intatis 只决定消息角色是否允许 rich、是否低于 64 KiB、何时申请 parse permit、是否仍是最新 revision、上游 document 何时可替换 raw Text，以及整段 raw SwiftUI `Text` 何时允许重新投影。raw 投影是 Markdown 无关的 MainActor latest-only 状态机：一个 facade lifetime 内保留最新源，100 ms fixed-window leading/trailing throttle 不随每个 token 重置；activation/reentry、非 append correction/truncation 和 final 同步精确直出，timer 与 task generation 双重拒绝旧发布。75 ms 初始候选在正式 replay 中有 2/20 轮 interaction p95 超过冻结门，因此不能恢复。派生包基于 Microsoft v0.6.0 exact commit，升级到 `swift-markdown`/`swift-cmark` 0.8，使用 public `@concurrent ... sending` parse boundary；返回的 non-Sendable `RenderableDocument` 不越过 MainActor ownership。

iosMath 的 `MTMathUILabel`/attachment 是 AppKit/UIKit 对象：TextKit 2 attachment view provider 在 MainActor 做 bounded preflight 并展示 live label，1024×256 points 之外或无效布局恢复 exact literal。attachment file type 由唯一 MIME `application/vnd.vita0818.intatis-inline-math+json` 动态派生，并由 attachment subclass 直接返回 exact provider；不得给 public `.json` / `.data` 等宽泛 UTI 注册 process-global provider。AppKit 还必须清除默认 generic `attachmentCell`。`ParagraphNSView()` 显式建立 `NSTextContentStorage → NSTextLayoutManager → NSTextContainer`，强持有 root content storage；`setAttributedString` 整段替换后必须恢复 `primaryTextLayoutManager`，内容或有效宽度变化后在下一 main-queue turn 合并调用 `textViewportLayoutController.layoutViewport()`。这是 production live provider 真正实例化的生命周期合同，禁止通过 legacy `NSTextView.layoutManager` accessor 偷回 TextKit 1。`CATransaction.flush()` 只用于测试确定性跨过 AppKit transaction boundary，production 不 flush、sleep 或 spin。view 从当前 AppKit/UIKit appearance 解析 semantic color；SharedUI 将 `DynamicTypeSize` 映射为 typography revision并缩放 parse/display font config，避免旧色彩/旧字号发布。这里不创建 raster preview，也没有公式 bitmap cache。同步 formula parse/update 留在 UI owner，不能伪装成 Sendable work 放进 output-free permit scheduler。传递的 swift-markdown manifest 仍使用 Swift 5 language mode，iosMath 是 Objective-C target；因此不能把整张依赖图表述为 Swift 6 strict-clean。

第一版公式面只打开普通 paired `$...$` 行内形式。预处理器先保护 fenced/inline code，再以 request-local、随机 namespace 的 catalog 把原始 TeX 交给 attributed attachment；固定上限是每条消息 32 个公式、单个公式 8 KiB UTF-8，任一上限超出时该消息的全部 candidate 都保持 literal，不做部分 attachment。原始 source 同时用于 literal fallback、selection/copy 与 accessibility。未闭合/转义/货币样式与不合规 candidate 不得吞字，`$$...$$`、`\(...\)`、`\[...\]` 保持普通 Markdown/文本语义。plain-safe 在任何 Markdown/math parser 或 view 构造前完全绕开该路径。图片、citations、文字动画、block math 与语法高亮仍关闭；代码块显示完整可选择纯文本、语言标签、原生 Copy 与水平滚动，table copy/download actions 不进入 UI。链接点击只允许 `http`、`https`、`mailto`。因此本版本仍没有 JavaScriptCore/highlight.js 运行、远程图片请求或模型输出 `eval`。零 completed-document cache、零 paragraph native-view cache；这一选择减少旧历史 session 的常驻原生 view graph，之后只有得到测量证据才可重新引入 cache。

当前 Intatis dependency 声明已删除旧 MarkdownUI/NetworkImage/swift-cmark0.5/HighlightSwift 和 vendor highlight 资源；完整可构建 Microsoft derivative vendored 于 `Vendor/SwiftStreamingMarkdown`，根 `Package.swift` 使用仓内相对路径。派生包 exact-pins `swift-markdown` 0.8（传递 `swift-cmark` 0.8）以及只在 iOS/macOS 链接的 iosMath 2.5.0 commit `838cddc01fdd67efd530f8bb67959ad2715f9b06`；根与 vendor 两份 `Package.resolved` 已匹配。Microsoft MIT `LICENSE` 与永久 patch ledger 和源码一起由 Intatis 根 Git revision 固定；iosMath MIT、八套 unmodified math font 的 GUST/LPPL 或 OFL 条款、资源清单与用户批准另由 `ThirdPartyNotices/MathRendering.md` 固定。iosMath 自身无传递 package dependency；其 `fonts/` payload 是 8 OTF、8 math-table plist、5 license、4 README 与一个 conversion script，共 26 files / 7,234,424 bytes，完整 built `iosMath_iosMath.bundle` 加生成的根 `Info.plist` 后为 27 files。这套公式字体不改变产品 UI 字体选择。三个 exact-pinned remote dependency 在无缓存解析时仍需要网络，完全离线供应链不在本轮范围。

2026-07-18 事故前验证基线：renderer focused 37/37；完整 SwiftPM 755/14 skipped/0 failures；固定 fixture 为 17 messages / 1,249 deltas、SHA-256 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`。100 ms Plain 与 production-shaped `LazyVStack` Microsoft 各完成 5 cold + 20 replay、25/25 exact 并通过 interaction p95 ≤8 ms / max ≤50 ms 门；Plain cold/replay worst p95/max 为 6.152250/30.395208 ms、4.370458/29.591167 ms，Microsoft 为 4.020458/37.840875 ms、4.876292/36.596500 ms，Microsoft replay peak/residual RSS 最高 102.953/101.375 MiB。eager `VStack` cold 5/5、replay 20/20 p95 超门；当时 xctrace 17/17 exact、>250 ms hang 0、旧 lifecycle warning pattern 0。main/RSS/footprint/CPU 没有冻结 gate，普通 AttributeGraph sampling 也不能证明零 cycle。以下事故后段落是当前 release authority，并明确覆盖这组窄协议可能造成的 release-ready 推断；真实设备仍为 `UNKNOWN`。

事故后 renderer hardening 仍遵守同一所有权边界，没有新增 Intatis parser/layout：vendored `DocumentView` 和两平台 `ParagraphView` 恢复 upstream-equivalent 手写 `Equatable`；AppKit/UIKit paragraph 用独立有效宽度 tracker，只在首次有效宽度或真实宽度变化时刷新 intrinsic size，invalid/zero width 清 tracker 而不失效；`valid -> zero -> same valid` 会重新测量一次。Intatis rich facade 不再给整棵 `DocumentView` 套第二个 SwiftUI `SelectionOverlay`，plain `Text`、native selectable paragraph、table/code SwiftUI leaf 各自拥有 selection。零 paragraph cache 只说明 package 自己不持有 cache，不能证明 SwiftUI/TextKit 总 graph 内存有界。

2026-07-18 三实例 GUI/Computer Use `FAIL / ABORTED` 现在是历史 adverse evidence：Force Quit 对主实例显示 129.63 GB application memory；CPU diagnostic incident `FA228932-2C40-4AC2-A0C2-62EF41342B4A` 记录 160 秒内 90 秒 CPU 与 sampled footprint 109.16 MB→803.30 MB，重栈含 SwiftUICore/AttributeGraph/lazy layout/`ParagraphView`/`SelectionOverlay`。缺少 malloc stack/heap graph，根因/最终 retaining edge 仍为 `UNKNOWN`。2026-07-24 hash-pinned 单实例验证已通过同一 Microsoft renderer 的 math-disabled/enabled structure A/B，以及 math-one/thirty-two/history/stream isolation；Light/Dark `math-structure` Computer Use 各稳定运行约 47.47 秒并看到真实公式字形、literal code 与原始 TeX AX 描述，所有 run exit 0、未用 TERM/KILL且无残留。vendor 82/82、SharedUI 25/25、root 938/14 skipped/0 failures、macOS/iOS Debug/Release 与双端 bundle/notice/font inventory也通过。以上关闭“从未受控启动”和单美元公式不可见两个问题，但仍短于历史 160 秒窗口，也没有真实 clipboard/VoiceOver、malloc retaining-edge 或低端 iOS 真机证据；因此不能据此宣称历史事故根因已解决或 renderer 已 release-ready。

### Provider 模型请求扩展

macOS 的 Intatis-owned OpenCode-compatible 配置把 `provider.<id>.models.<model>.options` 视为开放的 model-scoped JSON 请求扩展点。`AppConfig` 不解释厂商字段，而是保真为 `[String: JSONValue]`，按 model ID 挂到 `ProviderEndpoint.modelRequestOptions`；当前 OpenAI-compatible wire adapter 在构造 Chat/Code 的兼容 request body 时先加载这些扩展，再写入运行时字段。因此 routing、sampling、reasoning、response format 或未来厂商自定义嵌套对象无需为每个 provider 增加 Swift 字段。此处“开放 JSON”只描述兼容 `ProviderEndpoint` 路径；Cowork durable catalog 有独立的显式 allowlisted schema，不能用这一段推导 unknown option 可被持久化。

顶层 `model` 解析先在启用的 provider model map 中按完整字符串精确匹配；只有未命中时才解释为 `provider/model`。这使 `deepseek/deepseek-v4-pro` 一类本身含 `/` 的 endpoint model ID 与显式 `OpenRouter/deepseek/...` provider-qualified 形式可以共存，且多 provider 出现同名 model 时只有显式 selected provider 才能消除歧义。

`model`、`messages`、`tools`、`stream` 是 Intatis 运行时拥有的结构字段，配置不得覆盖；单次 runtime 明确设置的 `temperature`、`reasoning_effort`、`max_tokens`、usage 选项也覆盖同名配置默认。OpenAI-compatible Chat/Agent builder 还会对每个请求无条件移除配置提供的 `stream_options`、`n`、`best_of`、`num_return_sequences`、`candidate_count`，固定 `n = 1`，并且只允许 host `includeUsage` 重建受控 `stream_options.include_usage`；host output ceiling 另会移除竞争 token aliases。provider-level `options.baseURL` / `apiKey` / `chatEndpoint` 仍分别属于 endpoint、secret 与 transport 配置，不会被盲目复制到请求 body。未来新增非 OpenAI wire adapter 时，应消费同一个 Chat/Code model-scoped JSON，但按该 wire 的协议完成映射，不得静默丢弃未知配置；Cowork durable option 则必须先进入该 wire 明确支持的 catalog schema。

配置解析与 UI 展示是独立的只读投影。`AppConfig` 在内存保留完整 model object；`ModelConfigurationPresentation` 可从原始 model metadata 与 `options` 识别常见 reasoning/thinking effort、thinking level 或 token budget 的原始值，供模型列表显示灰色辅助标签。该识别覆盖 OpenRouter/OpenAI 常见 `reasoning.effort` / `reasoning_effort`、OpenCode/SDK 常见 `reasoningEffort` / `thinking.budgetTokens`、Anthropic 常见 `output_config.effort` / `thinking.budget_tokens` 等拼写，但只代表“配置中存在这个值”，不代表 Intatis 验证了目标模型支持它。投影不得改变 key/value、不得回写配置。`variants` 是同一 model 的命名请求参数预设：macOS 把基础项与未禁用 variants 摊平成菜单选择，持久化 provider/model/variant identity；选中 variant 后按原字段名和值浅覆盖基础 model `options`，但不改变发给 provider 的 model ID。未显式选择 variant 时，UI 与请求都不得任选一个 variant 冒充活动配置。

### Cowork per-agent inference profile

Cowork 的 agent 推理配置不是 session-global `model` 字符串。`InferenceCatalog` 把 transport/credential trust boundary 与 model/options 分成 `InferenceConnectionDefinition` 和 `InferenceProfileDefinition`，二者都用 exact ID + revision 表示不可变定义。App/CLI mutable 配置经 reconciler 编译：语义相同复用旧 revision，语义变化追加 revision并保留旧定义；current reference 只供未来 binding 使用。`InferenceCatalogStore` 以 schema v1、owner-only 文件保存所有 revisions，corruption、未知 schema 或不安全权限 fail closed，不覆盖原文件。Reconcile 在稳定 owner-only sidecar 上取得 Darwin/Linux 跨进程独占 record lock，并以进程内互斥补足 POSIX lock 的 process-scoped 语义；完整旧值读取、revision allocation、snapshot 校验和原子替换都在同一临界区内。Lock 必须为当前用户所有、`0600`、普通单链接文件，并以 no-follow/close-on-exec 打开；不支持真实跨进程锁的平台和任何不安全 lock state 都 fail closed。

`AgentInferenceBinding` 安全快照固定 exact profile/connection revision、model/opaque durable variant、安全 route label/trust domain/egress classification 与 opaque definition digest；catalog exact resolve 会逐项复核这些值，而不只核对 revision/digest。macOS 用户配置中的 raw variant key 只保留在 local presentation metadata，durable `variantID` 使用 provider/model/variant tuple 的 opaque stable digest。fresh `@main` 使用 project 的未来-agent default；`spawn_agent` 未显式指定时精确继承调用者 binding，显式 profile 必须属于 host-approved map。已有 agent 永不动态跟随 default/current；恢复、入队和 provider dispatch 都必须 exact resolve，missing/mismatch/unsupported wire 不能 fallback。每个 `TaskContract` 冻结本次 invocation binding，运行中 catalog refresh 或 rebind 不改变它。Shipping runtime 的 resolver 必须一次返回 `ResolvedInferenceProfile(binding, model, provider)`；严格模式拒绝旧 provider-only factory，Orchestrator 统一核对 live agent model、binding 与 resolved tuple，不能由 app 分阶段拼装三者。

Profile 编译的浅合并顺序为 connection defaults → model base → variant → profile overrides；请求时 resolved profile options → 受限 invocation values → runtime clamp → runtime-owned structural fields。Bound Cowork agent 的 reasoning/options 属于 profile，不能被 session-wide effort 隐式覆盖。Durable connection URL 必须是无 user-info/query/fragment 的绝对 HTTP(S) URL；durable options 使用显式 schema：只允许有界的 sampling/token/logprob 数值、少量布尔/安全 token 字符串，以及受限 `reasoning`、`thinking`、`output_config`、provider routing 子结构；unknown key、错误 shape/size/depth、secret/auth/header/query/URL/endpoint、runtime structural、stream 与 multi-candidate fields 在 catalog 编译时全部 fail closed。Secret value 只按 credential reference 在 provider 请求边界懒加载。OpenAI-compatible builder 随后对所有 Chat/Agent request 无条件清除配置 `stream_options`/候选控制并强制 `n = 1`，host output ceiling 另按 normalized key 清除大小写与常见分隔符变体的竞争 token aliases。Raw endpoint、credential、headers/query 和任意 options 不进入 agent/event/UI 安全投影。

Host 只能对没有 queued/running invocation 的 ordinary agent rebind。候选 exact binding 可先在锁外异步解析，但 admission lock 内会复核 host-approved map、idle/current state，随后先 durable append previous/new `agent_attached` snapshot，再更新内存 roster；catalog candidate update 与 attach/spawn/delegate/rebind 使用同一 admission lock。Permission target/authorization 携带目标 binding 的安全 route/trust/egress 快照与派生 `targetInferenceFingerprint`，并在 allow 后、durable prepare 后和执行前重新计算复核；如果 exact resolver 曾 suspension，返回后还会重跑同步的 catalog/roster/fingerprint 检查，从而在不跨外部 `await` 持锁的前提下关闭 TOCTOU。Ordinary attach 在 permission-review allow 后再次 exact-resolve，并在 admission lock 内比较 review 前、resolve 前和 commit 前的 host-approved catalog snapshot；fresh `bootstrapMainAgent` 不走模型 review，但会在 admission wait 前后分别检查空 roster/EventLog、锁外再次 exact-resolve，再在锁内复核 catalog 与 empty-session 事实后才 durable commit。AgentLoop 的 execution revalidation hook 在写 durable tool-execution prepare 前完成 exact resolve，并在 await 后再校验一次；失败时不能留下代表旧授权已获准执行的 prepared ticket。Reviewer 不能 rebind，普通 agent 不能自切换。

macOS Cowork 底部的模型选择器不是 live rebind 控件，而是 composer 的“下一次 `@main`”暂存值；当前 root/worker/Goal 仍在运行时也可继续选择。每次面向 `@main` 的普通 Send 或 durable `/goal` 都在按钮边界把当时的 secret-free exact binding 冻结到 `UserMessagePayload.mainAgentInferenceBinding`，再随同一 submitted intent 进入 outbox、原子 `user_message + queued`、恢复与 Retry；直接发给 ordinary worker 的消息不携带该字段。FIFO drain 只有在前一工作越过 task boundary 后才用 host-only rebind 把 live `@main` 对齐到该 submission 的冻结值，root admission 还会复核 live binding 全等；候选撤销、无法解析或并发变化都使该 submission fail closed，不得回退旧模型或 current default。这个路径不修改既有 worker、`@permission-reviewer`、Goal verifier、未来新 agent default 或已经冻结的当前任务。

Recovery 必须分别描述 GUI 与 CLI。GUI 完成 replay、main/reviewer 状态解析和 Goal 对账后，只调用 `startNewTasksKeepingRestoredTasksPaused()`：新提交可以调度，恢复出的 root tasks 继续 paused/interrupted，直至精确 submission Retry；composer 和本地 admission 不依赖 exact-main/reviewer readiness。CLI 则保留显式 `/auto|/default` 与 `resumePendingTasks()` 边界。普通 worker unresolved 不得把整个 scheduler 冻结：它自己的 queued invocation 会在 provider request 前 exact-resolution fail closed 并 durable 结算为 failed，撤销 task lease、清除 busy fence后才可显式 rebind；无关 agent 继续运行。历史 session 若缺少 durable `@main`，启动流程不能用今天的 default/workspace 自动创建：GUI 只能按 canonical settings 做 host-authorized exact recovery 并在 main 修复后重建 reviewer；CLI 只能通过专用 `/agent restore-main <path> <profile-id>`，再显式 `/auto` 启动控制面。Phase L 后冷启动 active Goal 只完成 reconcile 并 durable pause（或 budget-limit），不会自动创建 continuation；显式 Resume 才能进入 data plane。

Provider formatter 先对诊断文本脱敏；diagnostic sanitizer 会把完整普通 HTTP(S) URL 也替换成 `[REDACTED_URL]`，即使它不含 query credential，因为 endpoint 可能识别私有基础设施。`RuntimeErrorPresentation` 是任何 provider/custom runtime 错误进入 durable `ErrorPayload` 或 task-failure 事实前的最后公共边界，会再次执行 URL/secret-redact 并限长；普通 permission preview 使用的非 diagnostic sanitizer 不因此全局删除 URL。Inference resolve/config 错误同样只允许 sanitized reason，不得把 endpoint、option value 或 credential material 写入 EventLog。

Provider HTTP transport 统一使用 `ProviderURLSession.noRedirect`：Foundation redirect delegate 对任何 300...399 返回 nil，不创建 `Location` 指向的请求；streaming 与 data request 因而只会把原 3xx 作为净化后的 provider failure 处理。该边界保证 exact binding/trust/egress attribution 不会被上游 redirect 暗中改写；将来若允许 redirect，必须先进入显式 route authorization。

当前 resolver 只实例化 OpenAI-compatible wire。`InferenceRouteLease`、跨 trust-domain 专用审批、非 OpenAI-compatible adapter 与完整 app model capability metadata 尚未实现；现有 host-approved catalog 和 permission snapshot 不能被描述为已经具备这些能力。完整契约见 `docs/PER_AGENT_INFERENCE_PROFILES.md`。

### Agent 文档/媒体工具链路（v0.16，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (DeterministicPolicyGate -> optional reviewer -> responder)
  -> ToolContext(workspaceRoot, shell, imageGenerator)
  -> DocumentMediaTools / FileTools / ShellGit
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

新增标准工具：
- `read_pdf`：用 PDFKit 抽取 PDF 文本和页数信息，支持 1-based 页码范围；扫描件若无可抽取文本，会提示使用 OCR/版面重建工具。
- `edit_pdf_pages`：PDF 页面级 `extract` / `split`，输出路径仍受 `PathConfinement` 限制。
- `reconstruct_document_image`：把文档照片、扫描件或 PDF 交给已安装的外部成熟后端，当前 wrapper 支持 `docling`、`marker_single`、`tesseract`，输出 Markdown/HTML/text。
- `compile_latex`：调用已安装的 `tectonic`、`latexmk`、`xelatex` 或 `pdflatex` 编译 `.tex`，并确认 PDF 产物存在。
- `generate_image`：通过 `ImageGenerationToolService` 调用现有 provider image capability，将返回图片写入工作区。

设计取舍：
- 当前不把 Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers 复制进仓库，也不新增 SwiftPM 第三方依赖；它们是可安装后端或后续集成方向。
- `reconstruct_document_image` / `compile_latex` 是 shell-backed 工具，仍受平台 shell 能力和权限门约束；AppStore sandbox 无 `run_shell` 时不得绕过 `DeterministicPolicyGate`。
- Cowork coordinator lease 可用全部文档/媒体工具；worker 默认只获得只读 `read_pdf`，不会默认获得页面编辑、LaTeX 编译或生图能力。

### Agent Git control 工具链路（Codex-aligned 本地 Git 控制面，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (read-only allow; local git mutations ask/reviewer)
  -> ToolContext(git: GitService, workspaceRoot)
  -> ShellGit tools -> ProcessGitService parameterized git process
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

标准工具：
- `git_status`：读取 `git status --porcelain=v1`。
- `git_diff`：读取 unstaged unified diff。
- `git_diff_staged`：读取 staged unified diff。
- `git_info`：读取 repository root、当前 branch 或 detached HEAD、短 HEAD、默认分支、dirty 状态与 remote metadata。
- `git_recent_commits`：读取最近本地 commit 摘要，默认 10 条，最多 50 条。
- `git_diff_base`：读取当前 workspace 相对指定 base ref 的 unified diff。
- `git_branch`：显示当前分支与本地分支列表。
- `git_create_branch`：创建本地分支，不切换分支。
- `git_stage` / `git_unstage`：仅对 workspace-confined path 修改 Git index。
- `git_commit`：从 staged index 创建本地 commit；执行时禁用 hooks path 与 GPG signing，并在提交前拒绝 staged sensitive path。
- `git_apply_patch_check`：对 unified diff 做 apply preflight，不修改工作区。
- `git_apply_patch`：把 unified diff 应用到工作区；非 cached 正向 apply 使用 `git apply --3way`。
- `git_stage_patch` / `git_unstage_patch`：用 patch 级别修改 index，作为 Codex-style hunk/file stage/unstage 的底层能力。
- `git_revert_patch`：反向应用 unified diff；非 cached 真实 revert 会先 best-effort stage patch 已存在路径，再用 `git apply --3way -R`，降低 index mismatch；这是 destructive 工具，要求显式 `confirmRevert:true` 并走权限门。
- `git_worktree_list`：读取 `git worktree list --porcelain`。
- `git_worktree_create`：只在 workspace `.intatis/git-worktrees/<name>` 下创建受管 linked worktree；默认 detached HEAD，可显式指定新 branch。
- `git_worktree_remove`：只移除 `.intatis/git-worktrees/<name>` 下受管 worktree；这是 destructive 工具，要求 `confirmName` 精确匹配。
- `git_remotes`：列出已配置 remote，并遮蔽 remote URL 中的凭据/token。
- `git_fetch`：只从已配置 remote name 拉取；不接受 URL remote，默认不切工作区，`prune` 显式可选；这是 write + network 工具。
- `git_pull_ff`：只对当前 clean working tree 的当前分支执行 `git pull --ff-only <remote> <branch>`；要求 `confirmRemote` / `confirmBranch` 精确匹配；这是 write + network 工具。
- `git_push`：只把当前分支推送到已配置 remote name；要求 `confirmRemote` / `confirmBranch` 精确匹配，不支持 force push 或 URL remote；这是 destructive + network 工具。
- `git_switch`：只在 clean working tree 上切换到既有本地分支；要求 `confirmBranch` 精确匹配；这是 destructive 工具，不做 `checkout .` / discard。

设计取舍：
- 本轮对照 Codex App/Worktrees/CLI 官方文档与 openai/codex 开源实现后，Intatis 采用相同方向：Git 不是开放 shell，而是受限工具能力，围绕 read-only 状态、diff、patch preflight/apply/revert/stage、受管 worktree 和权限审批暴露。当前已落地 Git slice 没有复制 Codex 源码或文案；未来若选择性复用兼容许可证实现，必须按 `docs/OPEN_SOURCE_REUSE.md` 固定来源并适配现有安全边界。
- 继续使用 `GitService` 抽象 + 本地 `git` wrapper，不新增第三方依赖。libgit2/SwiftGit2 仍是未来 sandbox 内 in-process backend 候选，但需先做许可证、native build、App Store/DeveloperID 边界审查。
- `ProcessGitService` 不拼 shell 字符串，而是通过 `Process` 以参数数组调用 `git`；内部 Git 命令统一设置 `GIT_TERMINAL_PROMPT=0`、`GIT_OPTIONAL_LOCKS=0`、`core.hooksPath=/dev/null`、`core.fsmonitor=false`，本地 metadata/patch 命令用 5 秒 command timeout，remote fetch/pull/push 用 60 秒 timeout。动态 branch/ref/path/message/diff patch/remote name 不进入 shell。
- Git repository root 必须与 agent workspace root 一致。普通 repository 的 git metadata 必须在 workspace 内；`.intatis/git-worktrees/<name>` linked worktree 允许 `.git` file 指向 owning workspace repository 的 `worktrees/` metadata，但 workspace path 仍必须在 owner root 之内。
- `git_stage` / `git_unstage` 的 path 参数先经过 `PathConfinement`；patch 工具从 `diff --git` / `+++` / `---` 解析 changed paths，并在权限与执行前做 workspace confinement。工具 observation 只返回相对路径 metadata，patch 正文只作为工具 diff 结果，不当作长期 schema。
- Remote Git 只接受已配置 remote name，不接受 URL remote/refspec；工具输出会遮蔽 URL 凭据与常见 Git hosting token。`git_pull_ff` 与 `git_switch` 要求 clean working tree；`git_push` 不支持 force / force-with-lease。真实 remote auth 由用户本机 Git credential helper/SSH agent 决定，Intatis 不读取、存储或展示凭据。
- Cowork `ToolCapability.gitControl` 下 coordinator lease 默认可用本地 Git control；`ToolCapability.gitRemote` 下 coordinator lease 默认可用 remote Git control；worker lease 默认不暴露任何 Git 工具。旧 `runShell` lease 仍只暴露 `git_status` / `git_diff` / `git_info` / `git_recent_commits` / `git_diff_base` 这类 read-only 兼容工具。
- 仍未实现 merge/rebase/reset/clean、force-push、remote auth 管理、PR/CI/review workflow；这些后续必须单独做风险分级、UI/权限和测试设计。

### Agent 网络/浏览器工具链路（v0.16，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (exec + network permission)
  -> web_fetch: URLSession HTTP(S)
  -> browser_*: ToolContext.shell -> installed Node.js
       -> Playwright persistent context when available
       -> otherwise Node built-in WebSocket + Chrome DevTools Protocol fallback
       -> Chromium / Chrome / Microsoft Edge persistent profile
       -> workspace .intatis/browser profile/state/history
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

新增标准工具：
- `web_fetch`：轻量 HTTP(S) 获取，无浏览器登录态、JS 或 cookie。
- `browser_diagnostics`：检查本地 Node.js、Playwright 解析位置、浏览器 channel 探测和当前 profile/state/history/downloads 路径；即使 Playwright 缺失也应返回可行动诊断。
- `browser_profiles`：列出 workspace 内持久浏览器 profile 的安全 metadata（当前 URL/title、state/history/download 计数、目录统计、Chromium runtime marker 存在性），不读取 cookie/localStorage/profile 数据库、runtime marker 内容或下载内容。
- `browser_profile_delete`：显式删除一个 workspace-scoped persistent browser profile 的 profile data、state file、downloads 目录和 Intatis history metadata；这是 `.destructive` 工具，必须要求 `confirmProfile` 与目标 profile 匹配，并仍通过权限门；若删除前发现 active/lock runtime marker，只输出概括性提示，不列 marker 文件名或内容。
- `browser_history`：只读取 `.intatis/browser/history.jsonl` 中的非 secret 历史 metadata，支持 profile 和条数过滤，不读取 cookie/localStorage/profile 数据库。
- `browser_navigate` / `browser_snapshot` / `browser_handoff` / `browser_reload` / `browser_back` / `browser_forward`：用持久浏览器 profile 打开 URL、读取当前页、打开有界 headed 浏览器窗口供用户手动登录/接管、刷新当前页，或按 Intatis profile 导航栈前进/后退，返回页面 title、URL、可见文本、链接和可定位交互元素摘要。
- `browser_click` / `browser_type` / `browser_submit` / `browser_select_option` / `browser_press_key` / `browser_scroll` / `browser_wait`：通过 CSS selector、文本或 accessibility role/name 对当前浏览器页面点击、输入、提交当前或目标表单、选择下拉项、按键/快捷键、滚动页面/元素，或等待指定 selector/text/role 状态；动作后的 observation 也返回按钮、输入框、下拉框等交互元素的 role/name/selector/options 摘要，供下一步定位；会打开新 tab/window 的 click/type-submit/select/submit/press 动作会在 Playwright 路径用 page/popup 事件、在 CDP fallback 路径用真实鼠标点击 + target polling 跟随到新页面，并把最终页面写入 state/history；`browser_type` 会从工具 observation 中遮蔽本次输入值，并在 Swift 工具入口与 Playwright/CDP 后端 DOM 执行前拒绝疑似密码、2FA、token 或 API key 输入目标，要求改用 `browser_handoff` 让用户接管登录/验证。
- `browser_screenshot`：把当前页或指定 URL 渲染为 PNG 写入工作区路径，并通过 `changedFiles` 暴露产物。
- `browser_upload_file`：把 workspace 内文件附加到当前页面的 file input；Playwright 路径使用 `locator.setInputFiles`，CDP fallback 使用 `DOM.setFileInputFiles`。
- `browser_download`：点击预期会触发下载的元素，并把下载文件保存到 `.intatis/browser/downloads/<profile>`，通过 `changedFiles` 暴露下载路径；CDP fallback 使用真实鼠标事件触发，避免只靠 DOM `click()` 的非用户手势限制。
- `browser_downloads`：只列出 `.intatis/browser/downloads/<profile>` 下的文件 metadata（路径、大小、修改时间），不读取文件内容。
- `browser_search`：在持久 profile 中用 DuckDuckGo/Google/Bing 搜索。

设计取舍：
- 已调研 Chromium、Playwright、Chrome DevTools Protocol、Selenium、Browser Use、CEF；当前实现优先选择 Playwright wrapper 复用真实 Chromium/Chrome/Edge 内核和 profile 能力，在 Playwright 未安装时用 Node.js 内置 `WebSocket` 直连 Chrome DevTools Protocol 启动已安装 Chrome/Edge/Chromium persistent profile；Playwright 通过 BrowserContext page/popup 事件识别新页面，CDP fallback 通过 `/json/list` target 轮询和新 target WebSocket 切换识别新页面；Playwright/CDP 命令必须有有界 watchdog，避免真实浏览器流程无限挂起；不 vendoring Chromium/CEF，也不把 Playwright 源码复制进仓库。
- 浏览器 profile、cookies、localStorage、下载目录、state、history metadata 放在 workspace `.intatis/browser/` 下：`profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json`、`history.jsonl`。`state/<profile>.json` 保存当前页面 metadata 以及 Intatis 管理的 `navigationStack` / `navigationIndex`，供跨工具调用的 back/forward 使用；这些 profile 可能包含登录态，不写入 OS Keychain，不应作为普通 artifact 展示、提交或跨 agent 原文转发；`browser_profiles` / `browser_history` 只暴露受控 metadata，`browser_profiles` 只检查少数 Chromium active/lock marker 的存在性来提示可能有浏览器进程占用，不读取 marker 内容或 profile 数据库；页面摘要可暴露交互控件定位 metadata，但不得打印 cookies/localStorage/profile DB、密码/token 或当前文本输入值。
- 同一进程内，Playwright/CDP-backed `browser_*` 命令按 workspace profile 路径串行化，避免多个 agent 同时打开或写入同一 persistent profile、state/history 或导航栈；不同 profile 不做全局互斥，仍可并行执行。`browser_back` / `browser_forward` 的目标 URL 选择和真实浏览器执行必须处在同一 profile 临界区内。
- `web_fetch` 是 `.network` 工具；`browser_profiles` / `browser_history` / `browser_downloads` 是 `.readOnly` metadata 工具；`browser_profile_delete` 是 `.destructive` 工具；`browser_diagnostics` 是 `.exec` 但不标记 network risk；页面导航、headed handoff、刷新、前进/后退、交互、表单提交、滚动、等待、截图、上传、下载和搜索类 `browser_*` 是 `.exec` 且 `risksNetwork == true`。`DeterministicPolicyGate` 必须先检查 exec/shell/AppStore/read_only 边界，再进入网络审批，避免 shell-disabled 环境被 network ask 误放行。
- Cowork coordinator lease 可用 `browse_web`；worker 默认不获得 `web_fetch` 或任何 `browser_*` 工具。

### Cowork 链路（多 agent 编排，macOS 全量）

Cowork 的 durable work model 分四层：`Goal`（用户最终目标）→ `WorkTask`（用户可见计划 DAG）→ `ContinuationRun`（宿主一次推进/恢复 checkpoint）→ 既有 `TaskContract` / `TaskGraph` / scheduler（AgentInvocation execution layer）。箭头表示 scope/linkage，不表示终态自动传播；invocation completed、WorkTask completed 与 Goal completed 是三次不同的权威判断。

```text
Cowork session open/new -> checked EventLog is canonical for settings, roster, leases and migrations
  -> SessionProjectionStore rebuilds/refreshes derived schema-v2 session.json
  -> SessionWorkspaceAccessStore restores session-owned workspace-access.plist bookmark capabilities
  -> App/CLI compiles mutable provider config -> reconciles immutable InferenceCatalog revisions
  -> checked replay EventLog -> restore roster/AgentInvocation graph/scheduler/mailboxes/leases/token usage
       + Goal/WorkTask/ContinuationRun projection
       + exact per-agent inference bindings; unresolved legacy/missing revision stays blocked
  -> restore workspace bookmarks and current durable projection
  -> brand-new empty session: one strict settings-first seven-event batch
       seq 0 session settings
       seq 1...3 distinct @main workspace/capability leases + agent registration
       seq 4...6 distinct @permission-reviewer workspace/capability leases + agent registration
       same exact inference binding; reviewer remains read_only/no-tools/no-communication/no-delegation/depth 0
       no model/provider request during bootstrap
  -> resolve @main exact profile; freeze reviewer/GoalVerifier identity, binding and route
       permission reviewer resolves a fresh wrapper per generation; GoalVerifier keeps its independent lifecycle
  -> non-empty recovery missing @main: host-authorized local recovery from canonical settings/roster facts
       GUI repairs @main before reviewer replacement; CLI uses dedicated /agent restore-main
  -> CoworkViewModel -> GoalInputParser + CoworkMentionRouter
       ordinary turn -> GoalRuntimeController.sendUserTurn -> durable ContinuationRun -> Orchestrator
       /goal -> GoalRuntimeController.createGoal -> host-driven Goal run loop
  -> AgentRegistry / MessageBus(log:, mediator:) / PermissionEngine
  -> attach(agent) -> log agent_attached
  -> production Orchestrator.runtime 先取得 session EventLogWriterLease；冲突则启动失败
  -> GUI/CLI startup 创建保留 control-plane agent @permission-reviewer（read_only + no tools）
  -> GUI send(text) 默认路由到 @main；显式 @mention 仅作高级定向入口
  -> 每条普通用户指令及每个 Goal run 先创建 scoped root TaskContract (AgentInvocation)，再进入 durable queue
  -> scheduler 对同一 agent single-flight、对不同 agent 按 policy 有界并行
  -> Code/Cowork 共用 headless AgentRuntime；为每次 run 构建 AgentLoop + BusMessenger + OrchestratorManager
       -> verify live AgentInferenceBinding == frozen TaskContract binding
       -> ProviderRegistry exact-resolves that agent's immutable profile/connection revision
       coordinator(canCoordinate=true) -> lease-based registry with workspace/doc/media/browser + coordination tools
       worker -> lease-based registry with read/list/search/read_pdf + reply/request-delegation tools only
  -> AgentLoop.send() 循环（maxIterations 默认 50）
       ContextBuilder.initialMessages (RuntimeEnvironmentManifest + static system + history + scoped context + current user)
       stable Cowork @main:
         strict replay -> AgentModelHistoryProjector
         -> legacy completed U/A bridge（仅旧 submission）
         -> durable model_history_item user/assistant/function-call/output
         -> prompt-copy normalize（missing output => aborted；orphan output => drop）
       task-scoped worker:
         no main transcript -> bounded ContextBundle only
       -> provider.stream -> message_delta
       -> toolCalls -> strict schema validation
       -> optional host preflight（`delegate_task` 只读解析准确 target，不改 roster/lease）
       -> ToolRegistry.resolveAuthorization
            -> immutable ResolvedToolAuthorization（registry/spec/tool/task/tool-call/lease/args digest/intent/replay/gate）
       -> PermissionEngine.decide
            askUser -> durable permission_request -> PermissionResponder
                default -> UI 卡片/终端确认
                Cowork auto -> PermissionReviewControlPlane FIFO/single-flight
                  -> digest/count + bounded redacted action preview -> @permission-reviewer no-tool JSON decision + non-empty reason
                  -> durable permission_review_settled -> typed allow/deny/failure；异常只 deny 当前调用，不进入 UI fallback
            allow -> revalidate same authorization + capability/workspace/target identity
              -> durable tool_execution_prepared -> revalidate same snapshot/root identity -> executor
              -> durable tool_result + tool_execution_settled
            ask_agent -> typed success/failure；admission/Mediator failure 不得 settle success
            delegate_task -> execute exact reviewed target；deny 不创建 proposed worker，执行时不重新选人
            collaboration attach request/settlement related events -> one appendAdmissionEvents batch
                -> MessageBus.deliver + Mediator returns child answer/report to caller as ToolObservation
       -> ToolObservation 回填 -> 重复直至无 tool call
       -> SideEffectEvidenceLedger 以 durable succeeded settlement 约束 completion，并跨重启恢复 review→resolved→prepared 窗口
       -> task_completed/task_failed/task_cancelled records attempt + optional TaskReportPayload
       -> task-scoped tool-spawned child agent is auto-detached after it has accepted a task and becomes idle
  -> Goal run scheduler barrier
       -> checkpoint ContinuationRun
       -> independent GoalVerifierControlPlane (no tools, no EventLog writes)
       -> host validates verifier references against host-derived validationEvidence
       -> append audit + complete / continue / blocked / budget-limited / usage-limited
       -> continue by creating the next run, or stop after no-progress guard
  -> 每次状态变更 append 到 EventLog
  -> GUI folds CoworkProjection + TurnStatsProjection
  -> macOS Cowork wide inspector shows Git status, active agents, real Goal and real Tasks
MessageBus.deliver -> Mediator.mediate
  -> SecretScanner.containsSecret -> block
  -> content.count > maxChars(4000) -> block "send a summary"
  -> ForwardingReviewer(可选)
  -> .forward (log agent_to_agent_message + permission_review allow)
```

图中的“异常只 deny 当前调用”同时受 Phase B request/generation 边界约束：每个 provider dispatch 都有独立 `{reviewTaskID, nonce}` generation，provider/timeout 竞争首 terminal；caller cancel 另有同步 token 与下游围栏。timeout/cancel 只影响当前 call，若已有 active generation 就 retire 该代，下一次 review fresh-resolve provider wrapper。timeout 与 claim 前 cancel settle deny；claim 后 cancel 可保留唯一 settlement，但 authorization delivery 仍 deny。旧代 late/duplicate output 无法写 EventLog、改变 health/authorization 或触发 tool execution。

关键不变量：
- 用户默认只与 `@main` 对话；`@main` 是项目负责人 agent，持有 coordinator capability lease，可读写主 workspace 并通过工具自动创建、委派、移除子 agent。
- 每个 ordinary agent 的推理 binding 与 `PermissionProfile`、`CapabilityLease`、`WorkspaceLease` 相互独立。Project/session default 只创建未来 agent；已有 agent 保持 exact revision。`spawn_agent` 默认精确继承、显式 profile 需 host-approved；delegate 不改目标 binding；host rebind 只允许 idle agent 且 durable-first。legacy 无 binding、exact revision 缺失、definition mismatch、unsupported wire 或显式声明的必需能力不兼容均 fail closed，不可套用当前默认或相似 model。
- Reviewer 与 GoalVerifier 是控制面，不跟随普通 agent rebind；GUI/CLI 首次以 `@main` exact binding 冻结其 identity/route。Permission Reviewer 随后按该冻结 binding 为每个 generation 重新 exact-resolve provider wrapper；GoalVerifier 仍使用自己的独立 provider lifecycle。当前没有独立 route lease 或跨 trust-domain 专用审批，不能从 control-plane freeze 推导出这些尚未实现的能力。
- `Goal`、`WorkTask`、`ContinuationRun` 和 AgentInvocation 各自使用稳定 ID、revision/status 与追加事件；`CoworkProjection` 可从 EventLog 恢复四层关联。现有 `TaskContract` 类型名与 `task_*` 执行事件为旧日志兼容而保留，在产品语义中只代表 AgentInvocation，不得再投影成 Goal/WorkTask。
- `task_create/update/get/list` 管理 durable WorkTask；coordinator 可管理当前 run/Goal 范围，worker 只能读自身/依赖并更新绑定且归属自己的 WorkTask。DAG 校验 missing/self/cross-run/cycle、readiness、revision 和 result/evidence；依赖变更由 host graph 在同一 batch 重新计算被编辑节点与下游 readiness，投影拒绝与 DAG 不一致的 ready/pending/blocked 事件。WorkTask 进入 `in_progress` 后执行契约字段不可改。`delegate_task` 可绑定 WorkTask 并追加 invocation linkage，但 child report 只是 candidate result；legacy child delegation 与 causal mailbox wake 未显式绑定 WorkTask 时，仍从父 TaskContract 继承 Goal/ContinuationRun scope。
- write-capable WorkTask invocation admission 会比较同 workspace 内 active writers 的 `expectedArtifacts`：父/子路径视为重叠并拒绝第二个 writer；空、越界或不可规范化的声明按未知 write set 处理，对该 workspace 保守全局冲突。该检查是 scheduler admission 的补充，不能替代 WorkspaceLease/PermissionEngine，也不阻止只读 invocation 并行。
- `create_goal/get_goal/update_goal` 是受 schema、PermissionIntent 与 capability lease 约束的 control-plane tools；Goal create 还必须绑定明确用户意图。Cowork `/goal` 由宿主直接建立 durable Goal；普通 macOS/CLI 输入只在附件拼接前通过窄、确定性的中英文持续目标分类器后传 `explicitGoalIntent`，普通复杂请求、Goal 提及、一次性目标或引用示例都不提升权限。分类器只授予本轮 tool surface 的 create intent，仍不绕过 tool schema/lease/PermissionEngine/host authority。普通 coordinator/worker 没有提交最终 Goal verdict 的 authority。
- `rename_session` 也是普通 ToolCall，而不是隐藏标题模型或 UI 特例。模型参数只有 1–120 字符的 `name`；当前 SessionID/SessionKind 与 durable operation ID 由宿主分别从 runtime 和 execution ticket 注入。Code 单 agent 与 Cowork exact `@main` 可见，worker、spawn coordinator、其他 agent 与 reviewer 不可见；Chat 保持无工具。工具仍经过 strict schema、ToolRegistry、CapabilityLease（Cowork）、PermissionEngine、durable prepare/settle 与 `tool_result`，但 exact current-session intent 是 deterministic low-risk allow，不生成用户弹窗或 reviewer 请求。名称先 secret-scan，raw value 不进入 durable tool-call arguments；EventLog rename source/operation ID 使 exact executor retry 幂等。
- `GoalVerifierControlPlane` 与数据面 agent、`@permission-reviewer` 分离：使用独立 system/context 和无工具 provider 请求，不写 EventLog。WorkTask result/evidence 只是 agent-reported；host 从同一 Goal 下 durable 成功 tool-execution settlement 中，仅按 validation-tool allowlist 派生 `validationEvidence`，再校验 verifier 的 requirement/evidence 引用。malformed/tool call/缺完成标记/普通 provider failure/timeout/cancel 只返回 continue。Goal completion proof 必须非空、没有 remaining work/blocker、每条 requirement proven 且带 host-bound evidence，并按规范化文本逐项覆盖 Goal objective、全部 success criteria 与 constraints；重复 requirement 也必须按次数覆盖。只有该完整证明可驱动 Goal completed。
- Code 与 Cowork 不维护两套执行内核：二者使用同一个 Swift-native headless `AgentRuntime` 工厂，统一 registry、permission、completion、durable tool ticket 和单次请求参数。`RuntimeEnvironmentManifest` 在每次请求的首个 system message 中稳定声明 Intatis/Code 或 Cowork、外部动作只能通过 API tools、严格 JSON Schema 和 ToolResult 完成语义；动态 agent/workspace/task/lease/event 仍只进入有界 user-role untrusted context。
- 用户指令不是一段脱离任务图的直接 AgentLoop 调用：它必须成为 root `TaskContract`，经历 durable queue 与严格终态后 `send` 才返回。`created` / `assigned` / `queued` / `running` 不能被投影为完成；失败、取消和不完整 provider finish 必须保留原因与 attempt。
- root、delegation、mailbox wake、retry、agent attach/reviewer attach 与 crash requeue 都遵循 persistence-first admission：先写完执行所需的 roster/lease/task/queue 事件，再提交 registry/taskGraph/scheduler 内存状态。关键 admission 事件写入失败时不得运行 provider；已写入的半 admission task 立即补 `task_cancelled`，恢复时 orphan default lease 也不得进入可执行状态。
- `AgentScheduler` 的 claim 是短临界区；长 AgentLoop 在独立 task 中运行。同一 assignee 同时最多一个 claim，不同 assignee 受 `maxConcurrentTasks` 限制。actor reentrancy 不得绕过该 single-flight/claim 规则。
- 恢复期间 scheduler 保持暂停：先通过 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 验证 session identity、已知事件 payload、从 seq 0 到 durable tail 的连续性、unknown future type 与 WAL recovery，再折叠 `tool_execution_prepared/settled`；unknown future event 或 seq gap 都不能支撑“没有发生”或先后顺序证明，锁/读取/损坏/不完整历史也不得退化为空投影。只有明确 eligible 的 non-root/CLI read-only crash-recovery task 可随 running task 以 `attempt + 1` 重排；Phase A GUI restored root submission 不得自动重排；write/exec/network/destructive 或消息/委派/spawn/remove 等协作副作用若 prepared 未 settled，任务必须以 `manual reconciliation required` 失败，禁止自动重放。whole-task 显式 retry 也必须经过同一 complete-known-history gate，不能因旧程序看不懂新事件、seq gap 或日志读取失败把 non-replayable 证据当空。created/assigned 半入队、超过 maxAttempts、缺关键 lease 的任务也明确失败；queued task、未消费 mailbox、task graph、lease history 与 token 用量从同一已验证事件快照重建。GUI/CLI 先恢复 `@main` 与 reviewer（CLI 仅在用户显式 `/default` 时允许人工模式），再启动 Goal recovery。GUI 只为新提交释放 startup gate，恢复出的 root tasks 继续被 scheduler 排除并显示 interrupted，直至精确 submission Retry；CLI 仍保留自己的显式 resume 边界。历史 active Goal 只 reconcile/checkpoint/audit 后 durable pause，不自动创建 continuation。
- Durable tool recovery 以具体 outcome 而不是工具类别单独判定：`ToolExecutionSettledPayload.effectDisposition` 是 additive optional 字段；新成功写路径显式记录 `.committed`，legacy nil+succeeded 仅兼容视为已完成效果并仍阻断 whole-task retry，legacy failed/cancelled/denied nil 则保持 uncertain。只有受信写路径产生、且与唯一 exact prepare payload/sequence 匹配的 `.notStarted` 能证明 declared side effect 未跨 mutation boundary。生产 Orchestrator 的 WorkTask adapter 在 append/commit 前把字段完整匹配的 `stale_revision` 转为 typed rejection，AgentLoop 以同一 batch 写 model-visible failure 与 `settled.failed/not_started` 并继续该 Agent turn；任意公共 manager 的同名错误不自动升级。post-prepare 但 pre-executor 的 authorization/workspace rejection 和 cancellation也可写 no-effect settlement，但 cancellation 仍中断 turn。executor 已进入后的 cancel/timeout/普通 error 保持 non-replayable unresolved。Projection 对每个 execution ID 只接受首个 prepare；重复 prepare即使 payload 相同也保留首记录并永久 ambiguous，冲突 terminal 同样保留首记录并永久 ambiguous，完全相同的重复 terminal 才是幂等。ambiguous、settlement payload mismatch、顺序错误与 `succeeded + not_started` 矛盾均视为无有效 settlement并进入 uncertain。Orchestrator restore 只有在 complete-known history、无 current Goal、exact 唯一 prepare、没有任何 settlement/ambiguity、expected revision 为 JSON safe integer，且 prepare 前 durable WorkTask revision 已严格更大时才补 no-effect settlement；任何 current Goal 都不做该兼容修复，且绝不从自由文本或 prepare 后状态推断。显式 unknown 继续 uncertain；显式 committed、legacy nil+succeeded 与其他可能已执行的 disposition 仍阻断 whole-task replay。
- `GoalRuntimeController.start()` 与每次显式 continuation launch 都使用 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 观察 EventLog；known-event 损坏、unknown future event 或 seq gap 不能退化成空 session，也不能支撑 absence/order proof。它检查 uncertain non-replayable 集合：无有效 settlement、显式 unknown、`succeeded + not_started` 矛盾，以及 legacy failed/cancelled/denied nil；known committed 与 legacy nil+succeeded 不属于 unknown，但仍由 whole-task replay guard 管理。没有 current Goal 时，只有 complete-known history 同时证明 exact TaskContract 在 prepare 前存在、prepare 带正 attempt、同 attempt terminal event 在 prepare 后发生，才允许 terminal AgentInvocation 的 ticket 与普通新工作隔离；orphan terminal、attempt mismatch、unscoped、missing/nonterminal 或 corrupt/incomplete history均 fail closed。存在任何 current Goal 时 uncertain 集合必须为空。冷启动 `start()` 是 reconcile-only：active Goal 先经过 scoped barrier，恢复/checkpoint并结算未审计 checkpoint，然后 durable 写 paused；已到 token budget 则写 budget-limited。任何取消、checkpoint、pause 或结算持久化失败都 fail closed，不创建 continuation。只有用户显式 Resume 或同进程的明确 Goal Edit/Resume 动作才进入 launch gate；launch 会再次结算遗漏 checkpoint 后创建下一 run。Goal mutation 与 ordinary turn 共享串行 mutation gate，stop 有独立 single-flight lock；shutdown 是终局 fence，不得在失败尾部 resume data plane 或接纳新 turn。Pause/Edit/Clear 必须先安全停止当前 run并成功 durable checkpoint，失败时控制面变更 fail closed；Goal Edit 成功会清空旧 latest audit、blocker fingerprint、consecutive blocked/no-progress streak。completed/blocked/budget-limited/usage-limited 不自动续跑；active Goal 的连续 no-progress run 达阈值后保持 active 但停止自动循环，等待用户 steering/resume；默认阈值为 2，blocked 则要求同一 normalized blocker 至少连续 3 个 run。
- Goal continuation 每轮只由宿主建立一个 run；新建 Goal 会把该次 Send 冻结的 exact `@main` binding 保存为 additive optional `Goal.mainAgentInferenceBinding`，新式 Goal 的每次 continuation、Retry 与重启恢复都沿用这一值，legacy/model-created Goal 的 `nil` 只保留兼容语义。新 run 先原子 carry-forward 旧 run 的非终态 WorkTask，再向 `@main` 发送 `recordUserMessage=false` 的 scoped root invocation。carry-forward 会取消 source、为 target running run 分配新 WorkTask ID、重映射同批依赖并追加 `work_task_carried_forward`；session/Goal/run ownership 或外部非终态依赖不一致时 fail closed。scheduler barrier 与取消都只作用于同一 Goal/可选 run，并覆盖 queued、claimed、running execution；精确 Goal/run cancellation tombstone 在 root admission 入口、WorkTask carry-forward 后、admission lock 内和 durable queue append 后均检查，admission barrier 会等待在途创建，取消循环再 snapshot。已 durable 部分入队的 root task 必须先 settlement 为 cancelled，provider 才可保持未调用；terminal cancellation 落盘失败的 task 会被 quarantine 并从 result/idle waiters 的阻塞集合排除，但 tombstone 继续禁止 provider dispatch。run durable checkpoint 后才可 audit，每个 run 最多一次；production `settleGoalRunAudit` 在同一 admission lock/replay 下，以单个 append batch 提交 audit、run completed 与可选 Goal completed/blocked/budget-limited/usage-limited。verifier usage 以 scoped `turn_stats` 计入该 Goal/run。
- Goal token budget 只有用户显式设置才存在，达到后在安全 checkpoint 标记 budget-limited。普通 HTTP 429/rate-limit 与单次 `length` / `max_tokens` output limit 不代表账户配额耗尽；只有 typed `ProviderUsageLimitError` 会在 scoped `task_failed` 追加可选 `TaskFailureCode.providerUsageLimit`，且内存 hard-limit signal 只能在该失败事件成功持久化后发布。restore 只从该结构化 code、TaskContract Goal/run 归属、current non-completed Goal（包括 paused）和尚未 audit 的 run 重建 hard-limit signal，原子 Goal/run settlement 成功后才消费，绝不从错误自由文本分类；该信号单独标记 usage-limited，不冒充 blocked/completed/budget-limited。
- 任务执行受 task/default timeout、显式 cancel/cancelAll、maxAttempts 和 session 共享 soft token budget 约束。预算在 provider dispatch 前预留 input estimate + output slice，并把 output ceiling 映射到 OpenAI-compatible `max_tokens`；provider tokenizer、usage 或 ceiling 支持差异仍可能导致 settle 时 overrun，因此不得宣传为硬计费上限。provider watchdog 使用不等待迟到任务的 race；raw shell/process 另有 OS sandbox、默认断网和 TERM→KILL 有界清理。
- 动态层级通过 scheduler/message bus/task graph 表达，不允许 `AgentLoop` 同步递归调用另一个 `AgentLoop`。子 agent 默认是 worker，无 coordinator 工具；只有 `spawn_agent(canCoordinate:true)` 或未来显式 capability lease 授予时，子 agent 才可继续创建/调度下级 agent。
- `ask_agent` / `delegate_task` 工具必须通过 scheduler 运行目标 agent，并通过 `MessageBus.deliver` / `Mediator` 把子任务结果返回给调用方；`ask_agent` 保持兼容的直接答案，但 admission 或 Mediator 阻断返回 typed failure 并抛为工具失败，不能产生 succeeded execution settlement。`delegate_task` 的 `to` 可省略：review 前由 host 只读解析为精确现有 agent 或拟创建的 `worker-N`，authorization 记录 agent/workspace/model/access/canCoordinate/mayCreateWorker 与 target fingerprint；preflight 不改 roster。allow 后必须复核 exact target、lease 与 availability，执行只能使用 reviewed target，禁止 re-resolution/fallback；deny 不创建 worker。并发省略 `to` 的 delegation 必须在任何 mediation/admission await 前预留其 worker，完成或失败时释放，不能让多个独立调用因 actor reentrancy 选中同一 idle agent。调用方收到稳定 `task_id`、`agent_id` 与结构化 Task Report，不应只收到 queued ack，也不得通过直接嵌套 `AgentLoop` 取得结果。
- `ContextProjector` 为 task-scoped worker 构造 `ContextBundle`，包含全局摘要、任务契约、lineage、direct message、agent-local event、workspace/tool brief，以及 metadata-only 的 `taskGroupEvents`。任务组状态只能暴露任务 ID、状态、agent 和 current/parent/sibling/child/related 关系，不得把 sibling objective、expected deliverable、tool args、workspace private path 或 task result 投影给无关 worker。submission-bound task 以 accepted `user_message.seq` 为逻辑顺序，message/output/error 使用 submissionID，task/tool 通过 durable task correlation 归属；只投影更早 submission 的内容，当前旧 attempt、later submission、冲突或无归属 legacy content fail closed。稳定 `@main` 是明确例外：它从 `model_history_item` 恢复自己的长期 provider thread，`ContextBundle` 只作为追加的 untrusted task data；direct model history 已覆盖的 final answer/tool pair 不再以 bounded audit preview 重复注入。当前 `artifact_added` 没有 task/recipient/visibility 等显式分享元数据，因此事件投影对 `explicitlySharedArtifacts` fail closed。
- `spawn_agent` 由当前 coordinator agent 发起并记录 `requestedBy` ownership。外层 ToolCall 的 `PermissionIntent` 是 `agent.spawn`：目标目录是 `workspace` admission resource，不是文件 `touchedPath`，因此不会被误报成“write to workspace”；reviewer 会看到 agent/model/`requestedAccess`/`canCoordinate`/workspace-expansion 风险。新 agent 默认 `requestedAccess=read_only`，只有显式 `read_write` 且不超过调用者 WorkspaceLease ceiling 时才可获得写入能力；`canCoordinate` 独立控制 coordinator 工具，不能暗中提升 workspace access。获准后 executor 用一个 durable admission batch 建立 roster/workspace lease/capability lease/attached/spawned 状态，内部不得递归调用普通 `attach` 或产生第二次 PermissionEngine 决策；子 agent 后续每次文件、网络、exec 调用仍各自走 PermissionEngine。未承接任务的 tool-spawned agent 作为 team member 保留，等待后续 `delegate_task`、普通消息或显式 `remove_agent`；已承接任务的 tool-spawned、任务域内子 agent 在无 pending/running/issued task 和 pending mailbox message 后由 Orchestrator 自动 detach。用户/GUI 手动 attach 的 agent 不参与该自动回收。
- Session settings、agent/lease 登记与运行事件共用 EventLog 事实链；`session.json` 只是一份 secret-free 可重建投影。settings update 使用 revision/previousRevision CAS，unknown future session event 会阻止旧二进制覆盖投影。EventLog append 返回值与 subscriber 必须从实际编码 bytes 反解 canonical Envelope，不能让 decode-only 字段或 Date 精度造成运行时/重放分叉。legacy display name 必须先在 EventLog transaction 中追加 settings+marker，再 rebuild；Cowork/Chat/Code 实际入口都走这一顺序。显式 rename 可追加 source 与 operation ID：同一 ID 的 exact retry 返回原 transition，不追加事件；同一 ID 的冲突 payload fail closed；A→X、B→Y 后 retry-A 只返回当前 projection Y，不能覆盖 B。目录名和 `SessionID` 永远不变。
- Cowork Send 先冻结 `UserMessagePayload + SubmissionID`；协议字段 `mainAgentInferenceBinding` 为 additive optional，但新式 main-hosted message/Goal 必须在按钮按下瞬间取得 non-nil exact binding，否则保留草稿并拒绝本地 admission；只有 direct worker、Chat 与 legacy Cowork 允许 `nil`。因此连续排队的 A/B 可各自保留不同模型。`SubmittedIntentStore` 先写 session-owned outbox，再在一个 EventLog transaction 中 canonicalize 唯一 `user_message + queued(attempt 1)`；只有 canonical EventLog 可驱动 FIFO execution。FIFO 到达 main submission 时，Orchestrator 在同一 admission-lock hold 和单个 EventLog batch 中提交可选 `agent_attached` rebind 与该 root 的 `task_created + task_assigned + task_queued`，成功后才一起更新 live roster/taskGraph/scheduler，避免任何无关 delegation 先消费新 binding。状态按 one-based attempt 单调追加；retry 复用 root `TaskContract.submissionID`、原 submission 的 main binding 与同一 task，并把所需 rebind 与 retry queue event 原子提交，`recordUserMessage=false`。恢复的 queued/running submission 对用户显示 interrupted，restored task 继续被 scheduler 排除，直至该提交显式 Retry。
- Cowork draft/import 与 remote readiness 分离：输入框不受 reviewer、Goal、main inference、pending permission 或 `isWorking` 禁用；同一 frozen payload 保存期间只禁止重复 Send。附件先写 session ArtifactStore；image 可进入 provider adapter，其他文件和 Goal attachment 以明确 failure 保留在本地。
- Apple bookmark 是能力材料，不是 settings：只进入 session-owned schema-v1 binary `workspace-access.plist`，以 `0600`、no-follow lock、atomic replace/file+parent sync 保存。macOS `WorkspaceAccessLease` 必须从 bookmark 解析出的同一个 scoped URL 开始访问，在活跃 Code/Cowork view model 生命周期内保留，并在 teardown 后释放；canonical path 只用于 identity/精确匹配，不能替代 security-scoped URL。共享目录不能由单个 `agentName` last-writer 覆盖；删除 Agent/目录必须先 persist settings，再仅删除经剩余 settings + live roster 证明零引用的非-primary bookmark。primary 在 inspector、ViewModel 方法和 store 默认三层拒删；只有尚未成立的新建/重授权事务失败回滚可显式越过 store 防线。
- Legacy UserDefaults 只作迁移输入。共享旧 path→bookmark map 必须有 per-session ownership evidence 才能消费；迁移只有在 exact binding、全部必需 bookmark、primary 语义和 capability 文件都验证成功后才继续。符号链接 alias 必须在 scope 激活后与 canonical identity 比较，并先追加 canonical settings revision，再写稳定 migration marker/清理旧 key；marker 前中断可重试，marker 一旦存在也不能回退全局旧 map 使能力材料复活。
- Cowork session 可绑定一个或多个用户选择的工作目录；EventLog settings 只保存 secret-free path/agent/primary/future-profile/permission/token-budget metadata，bookmark bytes 只进入 session-owned capability plist。brand-new session 中，用户明确选择 primary workspace 后，固定七事件 bootstrap 同时记录 settings、`@main` 与 reviewer 的独立 leases/identities，不再让 reviewer 重复审批同一次选择；任何后续目录新增、普通 agent attach 或 spawn 仍依赖 workspace bookmark 与既有权限流，历史缺 main/reviewer 只能走上文专用 host recovery，不得复用 fresh bootstrap。
- `@main` agent 不可被 remove。
- Project Settings 新增目录只更新 project metadata；当前工具执行仍以 agent 单 `workspaceRoot` 为真实文件访问根。右侧 inspector 不提供 agent 删除或详情管理，只显示 Git status、未清理 agent 状态图标与目标表；`@main` 与 `@permission-reviewer` 不可删除。
- `@permission-reviewer` 是自动权限审查保留身份和独立控制面：GUI/CLI 默认启用；CLI `/auto` 只用于重新启用，只有用户明确 `/default` 才进入人工模式；不能作为普通 send/delegate/message/ask 目标，也不会暴露给 `list_agents`。review queue 不占普通 scheduler 槽，采用 64 项上限的 FIFO/single-flight，deadline 从 submit 计时；request/task/root/parent/attempt/toolCall、参数 digest/count、bounded redacted `PermissionActionPreview`、paths/network/side-effect/gate/lease/TaskContract/causal context 通过结构化任务传递，automatic-review payload/prompt 不含 raw args。reviewer 只返回 `allow` / `deny` 和非空有界 reason，risk 不能低于 deterministic gate；默认预留 1024 completion tokens。pre-submit caller cancel 直接返回 typed deny且不创建 review lifecycle；timeout、truncated、malformed、tool call、provider error、persistence failure、self-review、hard deny 与已登记 review 在 terminal-claim 前被观察到的 cancel 均产生 typed failure 并 durable deny 当前调用，不转 GUI 人工等待；claim 后 cancel 保留唯一 settlement 但 authorization delivery deny。review request/settled 必须 durable-first，`allow` 只有 settled 成功后才可生效。每次 provider dispatch 都创建 exact generation，production provider factory 冻结 reviewer identity/binding 而逐代重新 resolve wrapper；provider/timeout 竞争同代首 terminal，caller cancel 由同步 request token、actor path 与 settlement/delivery/admission 围栏共同处理，late/duplicate result 被丢弃。timeout/cancel 只影响当前 call；若已有 active generation 就只 retire 该代，后续 request 可 fresh review；legacy `provider_still_stopping` 只解码旧日志。Phase A 后 reviewer 未就绪由 unavailable responder deny 真实 ask-class tool，但不禁用 composer 或阻止普通主请求；Cowork 对话页不再常驻 reviewer 状态横幅，workspace reauthorization 与 automatic-review retry 只在异常时出现在 Project Settings 的 Recovery 区。Cancel task 只取消数据面任务并保留 reviewer，session stop/显式 disable 才 quiesce/shutdown 控制面。disable quiesce 后若 durable detach 失败，resume 也必须使用 fresh generation，旧 allow 无效。
- MessageBus 是唯一投递路径；Mediator 默认转发摘要不转发原始字节。
- typed message 只有在 Mediator 允许且事件持久化成功后才进入 mailbox。mailbox delivery 每轮只确认 ContextProjector 实际呈现的 message IDs（当前上限 8）；未呈现/未成功完成的消息保持 pending，恢复后合成 wake task，保证至少一次投递而非静默丢失。delivery 失败在同一 task ID 上按 `maxAttempts` 有界重试；消费事件持久化失败时先不 ack，允许至少一次重投。Goal/run cancellation 与 send/request/reply/delegation 共用 admission lock 和 tombstone 复核；取消期间迟到且已 durable 的 message 必须追加 `agent_message_discarded` 再 ack，不能伪装成 consumed，ContextProjection/CoworkProjection 在 replay 时把 consumed/discarded 都视为 mailbox terminal。
- task-scoped capability/workspace lease 必须校验 task ID、工具/通信/委派 grant、workspace root、access 与 allow/deny path，并在 terminal state 撤销。WorkspaceLease 持久化 canonical root 的 device/inode identity；attach commit、权限等待后、durable prepare 后紧邻 executor、task lease 派生/retry 与 managed process 启动都必须重新核验，路径相同但目录身份改变或 legacy identity 缺失时 fail closed。retry 只能从原 lease audit history 克隆权限；历史缺失时 fail closed（当前拒绝 retry），禁止回退到 assignee 的默认 coordinator lease。
- `ContextProjector` 对每类事件设 count/character budget，只取最近且与 task/agent 相关的内容；dynamic task/message/event data 通过 user-role `UNTRUSTED_CONTEXT_DATA` 块进入请求并转义边界文本，不得拼入 system role。Cowork system prompt 使用静态身份说明，不嵌入动态 agent name/workspace path；Orchestrator 的 attach/spawn 边界拒绝控制字符、空白、超长和非安全 ASCII agent 名。消息只有在实际投影后才可写入 consumed event。
- 任何 model tool_call 到执行都必须过 PermissionEngine，无旁路；tool intent、permission resolution 与 execution prepare 任一关键审计写入失败时 executor 不得运行。
- production `ToolRegistry.standard` 与 Cowork lease registry 不暴露 raw `run_shell`；`.runShell` 仅保留为旧 lease 的 read-only Git compatibility 信号。底层 `ProcessShellRunner` 仍以 Seatbelt/bwrap 做 workspace+network confinement，供隔离测试与未来签名 helper/XPC 演进；结构化 Git/browser/document backend 使用独立 runner，不得借此恢复模型任意 shell。
- 自动权限审查不启动嵌套 AgentLoop；审查者 provider 只收到无工具 JSON 判断请求。`DeterministicPolicyGate` hard deny 仍在审查者之前终局。

### macOS 应用级 session runtime 生命周期

- `AppSessionRuntimeManager` 是进程级 runtime owner，使用 exact `{SessionKind, SessionID}` 缓存 Chat/Code/Cowork runtime，并发布 busy/status/removal。窗口级 `AppEnvironment` 只持有自己的 mode/session 展示选择；切换、History、Command-W、关闭最后窗口都不触发 runtime stop。Command-N 创建新窗口时仍连接同一个 manager，因此不会为已有 session 重复创建 runtime。
- 删除 session 先对 exact key 执行 runtime shutdown，再删除 durable session；manager 发出 removal 后，其他窗口清理对应 Code/Cowork detail 或切换到仍存在的 Chat session。只删除一个 session 不影响其他 session 的后台工作。
- AppKit termination 使用 `applicationShouldTerminate` 的 terminate-later 协议。manager 先进入 quiescing、关闭全部 runtime 的新操作 admission，再同时广播 stop，并由 `BoundedSessionRuntimeShutdown` 使用单调时钟等待 bounded deadline。已完成项记为 settled；超时项只记 timedOut，不能冒充工具/任务已经 durable settlement。应用最后只调用一次 termination reply。
- Chat/Code/Cowork shutdown 均取消并等待其拥有的 send/provider/tool/direct-operation task，再清理 permission waiter、EventLog subscription 与 workspace access lease。Cowork 所有公开 mutation 入口共同检查 admission fence，并登记到统一 operation registry，避免 shutdown snapshot 之后又出现未等待写入。
- 冷启动和 crash/force-quit 后重开不复用进程内 runtime，只从 durable state 构建新 runtime并 reconcile。恢复出的 running/stopping 显示 interrupted；active Goal 变 paused/budget-limited。继续执行必须由用户显式 Send、Retry 或 Resume 发起。

### 多模态链路

```text
MultimodalService.generateImage/transcribe/generateVideo(轮询 job)
  -> provider 调用 -> ArtifactStore 写入
  -> log: artifact_added / artifact_progress
```

## 数据模型

| 类型 | 职责 | 持久化方式 | 关键字段约束 |
|---|---|---|---|
| `Envelope` | 事件信封 | JSONL 一行一个 | `seq` 单调递增且不可复用；`v:1`；`type` 只追加演进，未知未来事件可跳过但仍占用序号 |
| `EventLog` / `EventLogWriterLease` | session append-only 单写协调 | JSONL + `.lock` / `.writer.lock` / `.wal` / `.wal.tmp` sidecar | append/batch 在跨进程 exclusive flock 内重读尾 seq；多事件 batch 先同步并 rename WAL、同步父目录，再写/sync JSONL 与父目录，恢复按 exact prefix/suffix 判定 untouched/partial/full；所有 replay 在读取前先处理 WAL，兼容 replay 失败返回空，`replayChecked` / `isEmptyChecked` 对锁/读/known corruption/session mismatch fail closed；`replayForProjectionChecked` 另返回 durable tail/unknown-type metadata，只有 `hasCompleteKnownHistory` 才能支撑从 seq 0 起的 absence/order proof；production Cowork runtime 全生命周期持有 writer lease，第二个 runtime fail closed |
| `Event` | 事件 payload 联合 | 随 Envelope | 追加演进；兼容 replay 可跳过不可解码行，安全敏感调用必须用 checked API；合法未知未来 type 可跳过 payload 但仍占用 `seq`、算作非空，错误 session 不得进入当前日志 |
| `ModelHistoryItemPayload` / `AgentModelHistoryProjector` | 稳定 `@main` root submission 的模型输入事实链；独立于 UI 气泡、任务结果和审计预览 | `model_history_item` append-only 事件；每次 provider dispatch 前从 EventLog 严格重建 prompt snapshot；UI projections 对该事件 no-op | 保存 user / final assistant / assistant function-call batch / function output 的有序结构；用户项在首次 dispatch 前写入，call batch 在任何工具执行前原子写入，output 与 `tool_result` / settlement 同 batch。缺 output 的 call 只在请求副本中补 `aborted`，orphan output 丢弃，EventLog 不被合成项改写；重复冲突 ID、错误 root/submission/agent/attempt 绑定、未知 schema、unknown future event 或 seq gap 均 fail closed。task-scoped worker 不读取主 thread history；legacy session 只桥接可证明的 completed root U/A 文本 |
| `SessionSettingsUpdatedPayload` / `SessionStorageMigratedPayload` | versioned session settings 全快照、显式 rename 与幂等迁移完成事实 | `session_settings_updated` / `session_storage_migrated` append-only 事件 | revision/previousRevision、session/kind/schema 必须严格连续且 overflow-safe；rename source/operation ID 为 additive optional metadata，operation first-write-wins、冲突 fail closed；Cowork settings 不授予 lease，append return/stream 使用落盘反解 canonical Envelope；legacy name/settings 与 canonical alias 必须 settings-first，migration ID 非空稳定且只有 verified migration 才能落 marker |
| `SessionProjectionDocument` / `SessionProjectionStore` | 可删除、可重建的 session 快速投影 | `<session>/session.json` schema v2，owner-only atomic replace + stable no-follow lock | `events.jsonl` 永远获胜；`projectedThroughSeq` 只表示已验证水位。refresh 用 full canonical fold 校验 incremental result，同水位/落后 cache corruption 不能覆盖 EventLog；unknown future event 时拒绝覆盖 |
| `SessionWorkspaceAccessDocument` / `SessionWorkspaceAccessStore` | session-owned Apple security-scoped bookmark 能力材料 | `<session>/workspace-access.plist` schema v1 binary plist，`0600` + no-follow lock + atomic replace | bookmark bytes 不进入 EventLog/session.json/UserDefaults/UI；session/path/schema/单一 primary 必须验证；shared capability 仅在 settings+roster 零引用时删除，primary 默认拒删并只允许显式事务回滚；alias 只在 scope 后 canonicalize；marker 后不得从 global legacy map 回填 |
| `UserMessagePayload` | 用户输入事件 | 随 `user_message` | `text` 是清洗后送入模型的文本；`tags` / `goal` 是 v0.12 追加的可选元数据；`to` 可记录 Cowork 目标 agent；Cowork Phase A 的可选 `submissionID` 把同一 accepted intent 的消息、状态、root task 与重试关联；可选 `mainAgentInferenceBinding` 只冻结该 Cowork submission 在 Send 边界为 `@main` 选择的 secret-free exact binding，Chat、legacy Cowork 与 ordinary-worker direct message 为 `nil`；旧 JSONL 缺字段必须继续解码 |
| `SubmittedIntentStore` / `SubmissionStatusChangedPayload` | Cowork 用户一次 Send 的本地 durable admission 与可重试执行状态 | `<session>/submitted-intent-outbox.json` schema v1（owner-only atomic file）先保存冻结 payload，再用 EventLog transaction 写唯一 `user_message + submission_status_changed(queued, attempt 1)`；后续状态 append-only | `SubmissionID` 稳定且 first-write-wins；attempt 从 1 开始，只能单调 queued→running→terminal，禁止 orphan、跳号、回退或重写 terminal；EventLog acceptance 成功后才清 outbox，canonical replay 已存在时幂等对账；retry 复用同一 submission 和 exact root task，不重复 user message |
| `ArtifactStore` / `ArtifactRef` | session 内附件和生成物的 blob 与索引 | `<session>/artifacts/blobs/<id>.<safe-ext>` + owner-only `index.json`；stable owner-only flock 内 read/merge/atomic replace | root/blobs 必须是当前 UID 的真实目录且 leaf 不跟随 symlink；blob/index/lock 为单链接 `0600`，旧 `0644` 只在固定可信路径显式收紧，`0664`/symlink/hardlink fail closed；扩展名只允许短 ASCII 字母数字并固定在 exact ID path；rename 后无法证明 durable 时返回 `commitUncertain`，不得宣称 clean rollback |
| `TurnStatsPayload` / `TurnStatsProjection` | 每轮模型响应统计与 GUI 最近一轮投影 | 随 `turn_stats` 事件追加到 JSONL；GUI 只读投影 | token 字段来自 endpoint usage，可能为空；`cachedPromptTokens` / `contextWindowTokens` 是追加可选字段，旧 JSONL 缺字段必须继续解码；同一次 provider 响应的多个 usage chunk 按字段合并，Agent 工具循环的多个模型请求按请求累计；TTFT/total wall time 由 ChatLoop/AgentLoop 记录；GUI 显示不得依赖 transcript 文本解析 |
| `TurnID` / `TurnOutcomePayload` / `ExecutionFailureSource` | Chat/Code/Cowork 一次模型 turn 的 stable identity、terminal 与机器可读失败来源 | 新 turn 追加一个语义唯一的 `turn_outcome`；tool result、permission request/resolution 可选携带同一 turn/tool-call/request correlation | completed / interrupted / failed 分离；user denied/cancelled、turn cancelled、policy/reviewer/sandbox/runtime failure 不解析错误文本。人工 Decline 只终结当前 call，Cancel 才中断 turn且不得伪造 denied tool result；旧日志缺新字段继续解码 |
| `ErrorPayload` / `RuntimeErrorPresentation` / `RuntimeRecoveryAdvice` | provider、agent 与工具运行错误的用户可读投影 | 随 `error` 事件追加到 JSONL；恢复建议由 `ConversationProjection` / `CodeProjection` 从错误/失败工具结果派生，不另写事件 | 错误码由 shared runtime 映射生成；message 必须是裁剪后的可展示文本，不得包含完整 API 响应或 secret；恢复建议只说明 retry/config/endpoint/permission/tool-input 方向，不得包含 secret 或原始响应；若 partial assistant/agent delta 后发生错误，投影层只标记当前未完成消息为 response stopped 并保留 partial text，不新增事件 type |
| `ProviderHealthReport` | 当前 provider/model 的连接测试结果 | 不写入 EventLog；由设置页临时显示 | status、role、endpoint/model/wire、elapsed、first token、usage、code/message、裁剪 response preview；不得包含 secret 或完整响应体 |
| `ProviderRuntimePolicy` / `HTTPDataResponse` | provider 请求的 timeout / retry / backoff / rate-limit header 策略 | 不持久化；由 provider adapter 初始化默认值；HTTP headers 只用于当前请求诊断 | streaming 默认 2 attempts + request timeout；只在首个响应字节前失败时 retry。non-streaming image/transcription 对 retryable HTTP/网络/timeout 失败重试；`Retry-After` / rate-limit reset headers 可用数字秒、HTTP 日期或 `750ms` / `1m30s` 等 duration 字符串影响 retry delay 并进入错误说明；取消不 retry |
| `InferenceConnectionDefinition` / `InferenceProfileDefinition` / `InferenceCatalog` | Cowork per-agent 推理 route/profile 的 versioned immutable catalog | app/CLI App Support 下 `inference-catalog-v1.json`；保留所有历史 revision，current refs 只供未来 binding | connection 固定 wire/endpoint/credential reference/trust/defaults，URL 必须无 user-info/query/fragment；profile 固定 exact connection/model/variant/effective options/declared capabilities/safe label；语义变化必须追加 revision，不得原地改写；secret/auth/header/query/URL-like options 拒绝；store corruption/schema/owner-only permission 失败关闭；当前只有 OpenAI-compatible wire |
| `AgentInferenceBinding` / `ResolvedInferenceProfile` | agent、invocation 与 permission target 的 exact 安全绑定；一次 provider resolve 的原子结果 | binding 作为 `Agent`/`TaskContract`/agent lifecycle/turn stats/authorization 的 additive optional 字段；旧事件缺字段解码为 unresolved | 必须逐项核对 exact profile/connection revision、model/variant、安全 route label/trust domain/egress classification 与 opaque definition digest；不得 fallback current；安全投影不含 raw endpoint、credential、headers/query/options；secret 只在真实请求边界懒加载 |
| `Goal` / `GoalAuditSummary` | 用户拥有、可跨多轮和重启的 durable objective；保存 success criteria、constraints、状态、revision、可选显式 budget 与最新独立审计 | `goal_created/edited/paused/resumed/audit_completed/continuation_scheduled/progressed/blocked/budget_limited/usage_limited/completed/cleared` append-only 事件，由 `CoworkProjection` 折叠当前 Goal | 生产 mutation 收口到 Orchestrator host authority；默认无 token budget；Pause/Edit/Clear 先安全取消并 checkpoint，失败则不提交 mutation；Edit invalidates 旧 audit/blocker/progress streak；completed audit 必须无 remaining work/blocker、每项 proven+evidence，并精确覆盖 objective/criteria/constraints；每个 checkpointed run 最多一次 audit，且 audit/run completed/可选 Goal terminal 同 batch；单轮 `blocked_candidate` 不能直接 blocked |
| `WorkTask` / `WorkTaskGraph` / `TaskEvidence` | 用户可见计划 DAG 节点；显式 acceptance criteria、expected artifacts、owner、result/evidence、revision 与 invocation linkage | `work_task_created/updated/owner_changed/dependency_changed/ready/started/progressed/blocked/completed/failed/cancelled/invocation_linked/evidence_added/carried_forward` append-only 事件 | stable `wt_` ID；依赖只能在同一 ContinuationRun，拒 self/missing/cycle/stale revision；`in_progress` 后执行契约不可改；completed 必须有非空 result，存在 acceptance criteria 时还需 agent-reported evidence，但这些字段不能直接证明 Goal。新 run 由 host 原子取消并克隆旧非终态任务、重映射依赖；AgentInvocation 结果仅为 candidate |
| `ContinuationRun` | 宿主推进普通 turn 或 durable Goal 的有界轮次/checkpoint/recovery 边界 | `continuation_run_created/started/checkpointed/completed/cancelled/recovered` append-only 事件 | stable `run_` ID、session/可选 Goal、ordinal/status；host 驱动 scheduler，不能在 AgentLoop 内递归续跑；scoped barrier/cancel 覆盖 queued/claimed/running 并以精确 run tombstone 阻止在途 admission；恢复先取消 interrupted run、checkpoint，再保守结算 unaudited checkpoint，之后只有 active Goal 可创建新 run |
| `TaskFailureCode` / `TaskFailedPayload.failureCode` | 需要跨重启保真的结构化 invocation 失败分类；当前含 provider account hard usage limit | `task_failed` payload 的可选追加字段；旧 JSONL 缺字段解码为 nil | 只由 typed `ProviderUsageLimitError` 写 `provider_usage_limit`；restore 还要核对 TaskContract Goal/run scope、current non-completed Goal（包括 paused）与 run 未审计；不得从 `error` 文本、普通 429 或 `length/max_tokens` 猜测 |
| `AgentMessagePayload` / `AgentMessageConsumedPayload` / `AgentMessageDiscardedPayload` | typed mailbox message 的 pending、成功呈现消费与取消丢弃生命周期 | send/request/reply 事件建立 pending；`agent_message_consumed` 或 `agent_message_discarded` 终结对应 message ID | consumed 只能表示已投影且成功完成的 agent 轮次；discarded 只表示其 Goal/run 已取消、消息未成功呈现。两者都必须 durable-first 才可 runtime ack；旧 run discarded message 不得在 restore 后复活 |
| `ToolCapability` / `CapabilityLease` / `WorkspaceLease` | Cowork agent 可用工具与工作区能力边界 | grant/revoke 事件 + 当前内存索引；历史 grant 保留供 retry/replay | coordinator 可用本地 Git control、remote Git control、文档/媒体读写、生图与网络/浏览器能力；`renameSession` 只进入 exact `@main` default lease，不能沿 coordinator/worker/task/spawn 派生；worker 默认无 `gitControl` / `gitRemote`、只读 PDF 且无 `browse_web`。task-scoped lease 绑定 task ID、终态撤销；WorkspaceLease 还执行 root/access/allow/deny path 并持久化 canonical root device/inode identity，跨权限等待/prepare/retry/process 边界复核；最终工具执行仍必须过 `PermissionEngine` |
| `ResolvedToolAuthorization` / `PermissionActionPreview` / `PermissionApprovalResolution` | 从同一 registry registration 解析的 concrete tool、canonical permission、membership、lease/target/args identity、审查语义与 typed outcome | authorization 作为可选追加字段复制到 permission review/resolved 与 tool execution events；preview 只保存有界脱敏字段；旧 JSONL 缺字段继续解码 | live automatic review 必须有完整 snapshot，审查后与 executor 前复核同一 authorization；旧事件只用于兼容 replay，不能在 live 路径重新解释 alias 或扩大 membership。`write_file` / `apply_patch` 均为 `filesystem.edit`；automatic-review 只见 digest/count + preview，不能读取 raw args |
| `ToolCallPayload` argument audit | 记录模型提议的工具名与可安全持久化的参数显示；count/redacted 提供最小审计，只有已验证且未脱敏/未截断的 canonical args 才可带 digest | `argsDigest` / `argsCharacterCount` / `argsRedacted` 为 additive optional fields；旧 JSONL 只有 `args` 仍可解码 | 新 writer 必须在 `.tool_call` append 前完成分类：unknown/invalid 与全部 `spawn_agent` inference-control calls 只落 bounded redacted placeholder，不写 raw-value digest；其他 schema-valid args 也 secret-scrub/限长。endpoint/header/api_key 及其可离线猜测 hash 不得通过失败或未知调用先进入 EventLog |
| `PermissionReviewTask` / `PermissionReviewRequestedPayload` / `PermissionReviewSettledPayload` | reviewer 控制面工作单与 verdict | `permission_review_requested/settled` append-only 事件 | 结构化包含当前 task/attempt/tool/gate/lease/context、authorization、参数 digest/count 与 bounded redacted preview；reviewer 使用有界 FIFO/single-flight、submit-based deadline、单次 timeout/cancel/output ceiling 与可选 soft usage warning；只返回 allow/deny + non-empty reason，risk 不得下调，异常为 typed failure；allow 必须 settled-first，恢复关闭 orphan request；旧 `permission_review` 保留兼容审计 |
| `PermissionRequestPayload` / `PermissionResolvedPayload` / `PermissionApprovalResolution` | 人工或自动 approval 的 durable request identity、显式动作与首终态 | AgentLoop 先 batch 写 `permission_request + blocked`；`registerPermissionRequest` 为 reconnect/transport 提供 RequestID first-write CAS；`settlePermissionRequest` 写唯一 `permission_resolved` | approval mode 为 manual/automaticReviewer；action 为 approve/decline/cancelTurn。完整已知历史与跨进程锁内 first terminal 获胜；exact duplicate 幂等返回原 Envelope，冲突 request、tool、turn、tool-call、authorization、action/decision 或 terminal fail closed。Projection 按登记顺序 FIFO，解决任意项不改变其余相对顺序 |
| `ToolExecutionPreparedPayload` / `ToolExecutionSettledPayload` | 副作用执行票据、completion evidence 与 crash reconciliation | `tool_execution_prepared/settled` append-only 事件；settled 可选 `effectDisposition` | prepare 必须在 executor 前并携带/复核与 review 相同 authorization；每个 execution ID 只允许一个 prepare，duplicate prepare/conflicting terminal 永久 ambiguous 并保留首记录。仅普通 read-only 默认 safe-to-replay；write/exec/network/destructive 和 collaboration/lifecycle 工具默认 requires-manual-reconciliation。新 success 显式 `.committed`；legacy nil+succeeded 只兼容为已完成并仍阻断 whole-task retry，legacy failure nil/显式 unknown/无效 settlement 保持 uncertain；只有 exact、无 ambiguity 的 typed `.notStarted` 证明副作用未开始，`succeeded + notStarted` 无效。SideEffectEvidenceLedger 从 permission/review/resolved/prepared/settled 恢复证据，只有匹配的 succeeded settlement 才能清除完成阻断 |
| `TaskContract` / `TaskReportPayload`（AgentInvocation execution layer） | 单次 root/child agent invocation 契约与结构化回报；不是用户可见 WorkTask | `task_created/assigned/queued/started/completed/failed/cancelled` 既有事件；queue/start/terminal 记录 attempt | 契约记录 kind、issuer/assignee/objective/roleHint/deliverable/lease、reply mode、timeout、maxAttempts，并以可选字段绑定 submission、WorkTask/ContinuationRun/Goal 和 exact inference binding；Phase A root task 冻结 `submissionID`，main-hosted root admission 先要求 live `@main` 与 immutable submission 的 `mainAgentInferenceBinding` 全等，再把同一值冻结进 TaskContract；delegated/mailbox child 继承 submission scope。普通用户消息与每个 Goal run 均创建 root invocation。执行前 frozen binding 必须与 live roster 一致；完成只产生 candidate result；追加字段保持旧 JSONL 可解码 |
| `AgentScheduler` / `CoworkExecutionPolicy` / `AgentExecutionBudget` | claim、并发、恢复、取消/超时、attempt 与 token 预算 | scheduler 从 task/message events 重建；token 用量从 `turn_stats` 重算 | 同 agent single-flight、跨 agent 有界并行；仅 eligible non-root/CLI read-only crash recovery 增加 attempt；GUI restored root submission 保持 paused/interrupted 直至 exact Retry；session-lifetime 共享 token meter 在 provider dispatch 前预留 input estimate + output slice，响应/失败/超时按 reported 或估算 usage settle，配置切换不丢 outstanding reservation；预算明确是 soft；取消不自动 retry |
| `ContextBundle.taskGroupEvents` | Cowork worker prompt 的共享任务状态摘要 | `ContextProjector` 从 task events 投影，随本轮模型请求临时进入 prompt，不单独持久化 | 只包含当前/父/兄弟/子/related task 的任务 ID、状态、agent 和关系；不得泄漏其他任务的 objective、expected deliverable、tool args、结果文本或私有路径 |
| `SessionSummary` / `SessionHistoryStore` | 最近会话摘要、显示名称与路径生成 | 扫描 app support root 下 `<session>/events.jsonl`，读取 EventLog-derived `<session>/session.json` | Chat/Code/Cowork 按 `sess_` / `code_` / `cowork_` 前缀区分；手工/model-tool Rename 都 EventLog-first，显示名称不改变 `SessionID`，model 无目标 session 参数；旧 metadata 只作兼容迁移输入；macOS/iOS 共用实现，平台层只传 root 与 `SessionID` |
| `CoworkSessionSettings` / `CoworkProjectInfo` | Cowork project-mode canonical metadata 与右侧 inspector 投影 | `session_settings_updated` in EventLog；`session.json` 为派生缓存；旧 `intatis.cowork.projectSettings.<sessionID>` 只作迁移输入 | 保存主 agent 名称、未来新 agent exact inference default、默认 permission profile、可选 token budget 与 secret-free workspace metadata；bookmark bytes 独立进入 `workspace-access.plist`；不得重写现有 agent或授予 lease；fresh bootstrap 固定七事件，历史 main/reviewer 走 host-authorized exact recovery；direct multi-root tool context 尚未实现 |
| `Agent` | agent 值类型 | lifecycle 事件 durable，运行时 roster 内存重建 | ordinary agent 的 `agentInferenceBinding` 是推理权威；兼容 `model` 不能覆盖 binding。`coordinationDepth` 是当前 coordinator 工具兼容 fuse；默认 permission profile `.reviewed`；自动权限审查者固定 `read_only` + `coordinationDepth=0` |
| `Capability` | provider 能力枚举 | 配置 | chat/tool_calling/vision/realtime/audio/image/video/embedding |
| `PlatformProfile` | 平台能力信封 | launch-time | `.iOS`（最受限）/`.macAppStore`/`.macDeveloperID`；`current` 默认 `.iOS` |
| `PermissionProfile` | 每 agent 模式 | agent | manual/reviewed/autopilot/read_only/locked；硬 DENY 优先 |
| GUI provider catalog | GUI provider/model/variant 设置 | UserDefaults `intatis.providerCatalog.v1` + secret ref；当前聊天选择 `intatis.providerSelection.v1`；macOS 可由 `INTATIS_CONFIG` 显式指定文件、`~/.config/intatis/intatis.json` / `intatis.jsonc`、app support `intatis.json` / `intatis.jsonc` JSON/JSONC 覆盖；不自动发现 `opencode.json` 或 OpenCode app 配置；旧 `config.json` 兜底兼容读取 | provider 持久化 `baseURL` / `chatEndpoint` / secret ref；model 持久化 id / 展示名；variant 只持久化 identity，参数仍来自配置文件；高级 JSON 内容采用 OpenCode-compatible `model` + `enabled_providers` + `provider` map；聊天页切换只改当前选择，不改写外部 JSON；API key 不得进 UserDefaults；旧 `intatis.baseURL`/`intatis.model` 仅迁移/兼容 |

## 同步 / 通信机制

- **进程内**：v0.1 内核全进程内运行。`Orchestrator`/`EventLog`/`MessageBus` 均为 `actor`。
- **JSON-RPC 2.0 词汇**已定义（`JSONRPC.swift`：Command→request、Envelope→event notification），但**尚未挂传输**。未来 `intatis agent --stdio` / `intatis daemon` 是规划中管道。`UNKNOWN` — 当前无 out-of-process 传输实现。
- **Provider 线协议**：OpenAI 兼容 HTTP/SSE（chat completion endpoint streaming）。`WireFormat.openai` 是唯一 shipped 格式；`ProviderEndpoint.chatEndpoint` 可覆盖默认 `baseURL + /chat/completions`，保留 `baseURL` 给 image/transcription 等后续路径。
- **Provider tool-call delta 兼容**：`OpenAIToolCalling` 仍输出既有 `ToolCall(id:name:arguments:)`，但解码更宽容：单工具调用可缺省 `index`，`index` 可是字符串，`function.arguments` 可是字符串或 JSON object/array/number/bool，非字符串值会被压缩编码回 JSON 字符串再交给既有工具参数解析。Chat/tool-calling streaming 会遍历同一 SSE chunk 的全部 choices，不再只消费 `choices.first`；如果首个 choice 为空但后续 choice 带 content、tool_calls 或 `finish_reason`，仍会输出对应 delta/tool calls 并完成流；如果多个 choice 同时给出 finish reason，`tool_calls` / `function_call` 优先于普通 `stop`，避免工具轮被错误标成文本完成。若 provider 以 `finish_reason:"tool_calls"` 或旧式 `finish_reason:"function_call"` 结束但没有发出完整 tool-call delta / tool name，或已出现 tool-call delta 但最终错误给出 `stop` 且仍缺 tool name，则抛出 provider tool-call stream 兼容错误，不把空工具调用合成为成功。非空累计 `function.arguments` 在发出 `ToolCall` 前必须能解码为 JSONValue，截断或非法 JSON 会作为 provider tool-call stream 兼容错误暴露；空 arguments 仍保留，以兼容无参工具。此行为不改变 EventLog schema，不绕过权限门。
- **Provider/runtime 错误反馈**：`ProviderErrorFormatting` 统一处理 OpenAI-compatible HTTP 非 2xx、streaming provider error payload、malformed SSE chunk、`URLError`/取消/transport error，并只保留裁剪后的 provider message 或 response preview；HTTP 非 2xx 响应体只有结构化 `error`/`message`/`detail`/`error_description` 才显示为 `Provider said`，HTML/纯文本代理错误页只显示 `Preview`。`ProviderEndpoint` 在 chat streaming、tool-calling streaming、image generation、transcription 发起网络前统一校验 Chat endpoint 或 Base URL 必须是带 host 的 `http`/`https` URL，非 HTTP、缺 scheme 或缺 host 归类为 `IntatisError.config`，不把 file URL 或底层 URLSession 失败泄漏到 UI。非流式 image/transcription 对 HTTP 2xx 响应也会校验成功 payload shape；如果 provider 返回错误 JSON、HTML、缺 `data[].b64_json`、坏 base64、缺 `text` 或其他不兼容结构，会抛出裁剪后的 `IntatisError.decoding`，提示检查 endpoint、provider path、model 与 response format；只有结构化 `error`/`message`/`detail`/`error_description` 才显示为 `Provider said`，普通 HTML/缺字段 JSON/坏 base64 只显示 `Preview`。`RuntimeErrorPresentation` 把 `IntatisError`/`URLError` 映射成 `ErrorPayload.code + message`，供 ChatLoop/AgentLoop 写入 append-only `error` 事件。`ConversationProjection` 与 `CodeProjection` 从该 payload 派生 `RuntimeRecoveryAdvice`，SharedUI 在 Chat / Code / Cowork 错误卡片中复用同一恢复建议视图。若错误发生在当前 assistant/agent partial delta 之后，投影层会把该未完成气泡标记为 stopped 并附加 partial-response 恢复建议，已输出文本继续保留；状态码提示覆盖 400/401/403/404/408/422/429/5xx 等常见接入问题，但真实 provider 格式仍需矩阵验证。
- **Provider runtime retry/timeout/rate-limit headers**：`ProviderRuntimePolicy` 由 OpenAI-compatible chat streaming、tool-calling streaming、image generation、transcription 共享。URLRequest 会设置 request timeout；408/409/425/429/5xx 与短暂网络/timeout 错误可 retry。流式请求只在尚未收到任何 response bytes 时 retry；一旦收到 partial text/tool-call bytes，失败会按错误反馈路径暴露，不自动重放请求，避免重复输出或重复工具调用，随后由 Chat/Code 投影标记当前 partial stream stopped。Chat/tool-calling streaming 接受 `[DONE]` 或 chunk `finish_reason` 作为完成信号；`finish_reason` 不会立刻截断底层流，后续 usage chunk 仍会被读取，done 只投递一次；若底层流结束时没有任何完成信号，则抛出 completion-marker 兼容错误而不是合成成功。非流式 image/transcription 由 `ProviderRuntime.sendData` 统一重试并给 timeout 生成可行动错误。`HTTPDataResponse` 与 `URLSessionStreamingClient` 会保留 HTTP response headers；`ProviderErrorFormatting` 解析 `Retry-After`、`x-ratelimit-reset`、`x-ratelimit-reset-requests`、`x-ratelimit-reset-tokens`、`ratelimit-reset`，支持数字秒、HTTP 日期和 `750ms` / `1m30s` 等 duration 字符串，用于 retry delay 与用户可读说明，长等待由 policy cap。
- **Provider health check**：`ProviderRegistry.healthCheck(role:options:)` 复用当前 provider catalog、chat selection、secret resolver 与 `OpenAIWireProvider`，发起最小 chat/agent 流式请求，输出 `ProviderHealthReport`。chat 与 agent health check 均请求 `stream_options.include_usage`，并使用共享 `Usage` 合并规则处理 split usage chunk。报告显式区分 ok、timeout、partial stream、unknown endpoint、非法 provider URL、provider/transport/config 错误，并带 endpoint/model/wire/耗时/首 token/usage 与裁剪预览；兼容缺 `[DONE]` 但有 `finish_reason` 的 provider，只有完成信号缺失才标记 partial stream，并保留已收到的裁剪预览；macOS 与 iOS 设置页共用该 provider 层 API，只做不同布局，不写入 EventLog 或持久状态。
- **Goal 输入命令**：`GoalInputParser` 在 UI/ViewModel 层识别行首 `/goal`，要求后面有目标文本。Chat / Code 保留 v0.12 legacy 语义：剥离命令前缀，把清洗文本送入 provider，并在 `UserMessagePayload.tags = ["Goal"]` / `goal` 保存标签元数据供 bubble 投影。Cowork 的同一语法已升级为 durable Goal authority：创建 `Goal` 与首个 `ContinuationRun` 后由 host 驱动 scoped root AgentInvocation，不把它当成普通标签消息；仍在 mention 路由前后解析以接受 `/goal @Agent ...` 与 `@Agent /goal ...` 作为请求上下文，但 Goal continuation 始终由 `@main` 主持，因此 Goal Send 也冻结当时的 next-main exact binding，不能把生命周期、模型选择或终态 authority 下放给 mentioned agent。
- **工具执行反馈**：AgentLoop 对未知工具、权限拒绝、工具抛错分别写入结构化 `tool_result` observation，并在执行前追加 `agent_status(tool)`。模型给出的 raw arguments 在 `.tool_call` 持久化前先分类；unknown/invalid、作为 inference-control surface 的全部 `spawn_agent` inputs、含用户自定义标题的 `rename_session` inputs，以及永不允许落原文的 `write_stdin` inputs 只记录 bounded redacted placeholder + count/redacted，且不写 raw-value digest；`rename_session` 还在 authorization/prepare 前按结构化 `name` 做 secret scan。schema-valid 其他工具先 secret-scrub/限长，只有未脱敏/未截断的 canonical 参数才可附加 digest。稳定 `@main` 另把一次 assistant 返回的完整 function-call batch 作为一个 model-facing item 在任何工具执行前原子持久化；其参数只有在 registration/schema/secret/size 检查全部通过时才原样保留，否则写固定合法 JSON placeholder。每个已清洗、有界的 function output 与对应 audit result/execution settlement 同 batch，因而不存在“工具已经结算、模型历史还没写”的可取消窗口；只有完整 direct output 存在时才去除 ContextBundle 里的同一 audit result。UI/audit `tool_call` / `tool_result` 仍是独立记录，不能反向冒充模型历史。同一 turn 内空或重复 call ID 会改写为唯一 turn-local ID，并在后续关联位置一致使用。随后，已知工具在权限判断和执行前会校验参数必须是 JSON object，并满足 descriptor schema 的 required 字段、基础类型、数字 `minimum`/`maximum` 约束、字符串 `minLength`/`maxLength` 约束与 `additionalProperties:false` 未知字段规则，`read_file.maxBytes` 当前要求 `>= 1`，标准工具 path/query/command/diff 字符串当前要求非空，required 为空的无参工具可把空参数 / `null` 归一为 `{}`，坏 JSON、非对象、缺 required 字段、基础类型错误、数值越界、字符串过短/过长或未知字段会写入 `invalid tool input:` 的 `tool_result`，不生成 `permission_request`，也不执行工具。当前 shipped tools schema 默认声明 `additionalProperties:false`，因此模型给出的额外字段不能被 `try?` 默认值吞掉后进入权限或工具执行。`CodeProjection` 根据 `tool_call_id` 将结果标题回填为 `result · <toolName>`，把 `tool error:` / `permission denied:` / `unknown tool:` / `invalid tool input:` 标成失败项，并通过 `RuntimeRecoveryAdvice` 派生恢复建议。GUI 与 CLI 均消费事件投影/observation，不解析 assistant transcript。
- **Agent 文档/媒体工具**：`ToolRegistry.standard()` 暴露 PDF 阅读、PDF 页面编辑、文档照片/扫描件版面重建、LaTeX 编译和生图写入工作区。PDFKit 路径在 macOS 可直接工作；Linux 或无 PDFKit 平台会返回配置错误并提示使用外部 CLI 后端。shell-backed 文档重建和 LaTeX 编译不内置模型或 TeX 发行版，只调用已安装的成熟工具；缺少命令时返回可行动的配置错误。生图工具不直接知道 provider secret，只通过注入的 `ImageGenerationToolService` 使用现有 provider registry。
- **Agent 网络/浏览器工具**：`ToolRegistry.standard()` 暴露轻量 `web_fetch` 和 Playwright/CDP-backed `browser_*` 工具。浏览器工具依赖用户环境里已安装的 Node.js，并优先使用 Playwright + Chromium/Chrome/Edge channel；若 Playwright 不可解析，则通过 Node.js 内置 `WebSocket` 使用 Chrome DevTools Protocol 启动已安装 Chrome/Edge/Chromium。缺少后端时返回配置错误或 `browser_diagnostics` 的可行动诊断。profile/state/history/downloads 全部通过 `PathConfinement` 限定在 workspace `.intatis/browser/` 下，刷新、历史前进/后退、表单点击/输入/提交/下拉选择/按键/滚动/等待交互通过 locator 或当前焦点执行；click/download 的 CDP 路径使用真实鼠标事件，打开新页面的交互会跟随到新 tab/window 并把最终页面写回 state/history；截图只能写入工作区 PNG 路径，上传只能引用 workspace 内文件，显式下载只能写入 `.intatis/browser/downloads/<profile>`；`browser_profiles` 可报告 active browser / profile lock runtime marker 是否存在，但不得列内部 marker 文件名或读取内容；`browser_profile_delete` 只在目标 profile 与 `confirmProfile` 匹配时删除 `.intatis/browser/profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json` 并剪除对应 history metadata，删除前如果发现 marker 只给概括性提示；profile 可能包含 cookies 与登录态，不能当成普通日志、artifact 或 secret-free 文本处理。
- **macOS UI information architecture**：`IntatisMacRootView` 是 macOS Chat/Code/Cowork 的 shell。左侧继续由 `NavigationSplitView` 提供系统 sidebar 材质，内部使用一个连贯的自定义结构：`Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航、当前 mode 的 `Recent` session history/New 与底部 Settings；仅选中模式行使用 interactive Liquid Glass。Cowork New session 仍先要求用户选择主 workspace 并初始化 per-session project settings。主 thread header 显示 session durable display name（无 display name 时回退 immutable `SessionID`），不写死 Chat/Code/Cowork，也不承载 New/session/model 控件；Code/Cowork 使用紧凑 12pt 顶部留白，Cowork 不再在标题之前常驻 permission-reviewer 横幅。共享 `IntatisThreadComposer` 固定两排：第一排 model/profile 在左、最近一轮 Context/Input/Cached/Output/Time usage 在右；Chat/Code/Cowork 的选择器共用原生 `Menu` 语义与 40pt 高 interactive Liquid Glass 胶囊，关闭态只显示模型名，不显示 CPU/芯片图标、provider 或 variant/reasoning detail；弹出菜单内部仍按 provider 分组并保留 variant detail。第二排是当前产品面已有的 attachment/image action、原生多行 `TextField`、可选 Cowork stop 与 Send；action/stop/Send 使用同一个 40×40 原生圆形控件合同，输入容器单行最小高度同为 40，同行 spacing 为 8，外层保持 bottom alignment，因此多行输入只向上增长。没有 top accessories 时不创建空白第一排。消息本体不使用 agent 头像或通用 Agent badge，缺失的 agent 展示名回退 `Intatis`；正常完成的 assistant/agent 回复无外层卡片，用户消息、失败回复与 tool/error/permission/task 等结构化项保留容器；既有字体 token 不随本次视觉架构更新。Thread content 使用共享 responsive layout 计算 horizontal padding、显式 `contentWidth`、message gutter 与 bubble max width；对话行通过 `IntatisThreadBubbleRow` 在整行层面按 user trailing、assistant/agent leading 对齐。Chat 默认无右 inspector；Code/Cowork 宽屏使用 SwiftUI 原生 `.inspector`，Code 展示 structured plan/workspace/Git-status-only/recent failure，Cowork 只在可见 inspector 中展示 `Git Status`、`Agents`、真实 `Goal`、真实 `Tasks`；窄屏或用户隐藏 inspector 时不在 thread 顶部复制 Goal/Tasks，也不保留对应高度。Goal/Tasks 继续来自 durable projections；Git rail 只读展示状态，本地 Git controls 仍只通过 Agent Git tools + PermissionEngine 执行。
- **UI 配色架构**：macOS detail 由 `IntatisSystemCanvas` 使用 SwiftUI `.windowBackground`（macOS 13 fallback 为 `NSVisualEffectView.Material.windowBackground`）提供动态系统 window surface，`NavigationSplitView` sidebar 不再被自定义底色覆盖。`IntatisThreadStyle.intatisMac` / `.standard` 注入系统 `.primary` / `.secondary`、separator、accent 与错误语义；正常完成的 assistant/agent 正文直接继承系统 canvas，不叠 Material 或描边；用户消息、失败回复、数据卡片、权限和 artifact 等结构化内容层使用 `.regularMaterial`。composer、模型菜单、主要操作、紧凑 action group / agent pill 等功能层在 macOS 26 / iOS 26 使用 `glassEffect`、`GlassEffectContainer` 与 `.glass` / `.glassProminent`，旧系统走 Material / bordered control fallback；composer 首排选择菜单是共享 40pt interactive glass 胶囊，第二排 attachment、image action、stop 与 Send 使用 40pt 圆形原生 glass/bordered control，Send 使用 prominent；sidebar `Recent` 旁 `+` 使用 30×30 原生小型圆形 glass control。Glass 不铺页面或长内容。iOS 根视图继续使用系统容器背景，不另建平台私有底色。当前规范见 `docs/CURRENT_UI_COLOR_SYSTEM.md`；上一版方案独立保存在 `docs/UI_COLOR_SYSTEM.md`。
- **GUI token/turn stats**：ChatLoop 与 AgentLoop 每轮结束追加 `turn_stats`，包含 endpoint 返回的 prompt/completion/total token（若有）、可选 cached prompt tokens、可选 context window tokens、TTFT、总耗时和 model。OpenAI-compatible `prompt_tokens_details.cached_tokens` 会进入 `Usage.cachedPromptTokens`；未缓存 input 可由 prompt-cached 在 UI 层展示。ChatLoop、AgentLoop 与 ProviderHealthCheck 共用 `Usage` 规则：同一次响应内的 usage chunk 字段级合并，Agent 工具循环中多个模型请求再按请求累计。GUI 不解析消息文本计算 token，而是通过共享 `TurnStatsProjection` 折叠最近一轮统计；macOS Chat / Code / Cowork 复用 `IntatisComposerUsageStrip` 在 composer 第一排右侧显示低噪音 usage，第一排左侧保留 model/profile。iOS Chat 继续使用共享统计表面；没有 top accessories 时共享 composer 不产生空白行。endpoint 不返回 cached/context usage 时，只显示可证明字段，不虚构数值。
- **Chat/Code/Cowork session/history**：macOS `IntatisMacRootView` 通过 root-owned view models 和 `SessionHistoryStore.recentSessions(kind:)` 将当前 mode 的最近 sessions 投影到同一 sidebar navigation/session center；Chat 启动时优先恢复最近 Chat session，无历史时才使用 `sess_default`，Code/Cowork 在首次进入时创建对应 session。iOS `IOSAppEnvironment` 仍只恢复 Chat session，无历史时才使用 `sess_ios`。新建会话生成新的 `SessionID.new()`，打开独立 `EventLog` 与 artifact store，停止旧 view model 并重建当前 view model。恢复历史会话只切换到对应 `events.jsonl`，不会把新消息继续追加到旧的固定默认日志。macOS session row 的原生右键菜单支持 Rename/Delete；Code 与 Cowork `@main` 另可通过 `rename_session` 改当前会话，model 不提供 SessionID/kind。两条 Rename 路径都先追加 EventLog settings rename 事件并刷新派生 `<session>/session.json`，再通过 exact-session、revision/seq 有序的低频 publisher 更新所有窗口；不改目录名、`SessionID` 或既有 envelope。Delete 在二次确认后删除目标 session 目录及其 session-owned bookmark/settings/projection，不触碰绑定工作区内容，当前运行中的 session 禁止删除。路径与元数据规则在 `IntatisCore` 复用，平台层只传不同 application-support root。
- **GUI provider catalog**：macOS `AppConfig` 与 iOS `IOSConfig` 使用 UserDefaults 主键 `intatis.providerCatalog.v1` 保存两层 mutable 配置。第一层 provider 存 `id` / 展示名 / `baseURL` / `chatEndpoint` / secret ref 元数据；第二层 model 存模型 id / 展示名。macOS Chat/Code 模型菜单把配置中的 variants 作为同一 model 的独立选择项；切换后只把 provider/model/variant identity 写入 `intatis.providerSelection.v1` 并重建 `ProviderRegistry`，Chat/Code 下一条请求使用新选择的基础 options + variant 覆盖。Cowork composer 复用同一份配置所编译的 secret-free `AppInferenceProfileOption` 列表，以 provider 分组显示“下一次 `@main`”的 exact 暂存项；三个产品面的弹出菜单均保留 provider 分组与 variant detail，但关闭态 label 只读取选中项的 model title。新 options 先交给 Orchestrator 更新 host-approved catalog，再发布到菜单，避免可见项与 admission catalog 竞态。工作中仍可选择，选择本身不 rebind，只有随后按下 Send 才把当时值冻结进该 submission；FIFO 执行边界把仅 `@main` 的 durable rebind 与对应 root queue admission 原子提交。既有 worker、当前/已冻结 task、控制面 agent 与未来新 agent 默认值均不跟随。Project Settings 的独立 exact-profile picker 仍只更新**未来新 agent 默认值**，逐 agent Rebind 继续用于显式修改其他空闲 ordinary agent。iOS 保持 provider/model 两层 Chat 选择。设置页编辑 Base URL 时自动生成 Chat endpoint；编辑 Chat endpoint 时清洗 `/chat/completions` 后缀回填 Base URL。旧 `intatis.baseURL` / `intatis.model` 仍作为迁移来源与兼容镜像。
- **Cowork inference catalog 同步**：macOS `AppInferenceCatalog` 将当前 provider/model/variant 配置编译为 connection/profile drafts，并由 `InferenceCatalogStore` reconcile immutable revisions；connection/trust identity 与 durable variant ID 均使用不暴露 raw URL/config key 的 opaque hash，egress 标为 `user-configured-external`。配置刷新只改变 host-approved candidates/current refs；已有 agent 继续引用原 revision，且 catalog update 与 admission/rebind 通过同一 admission lock 串行化。Refresh 失败时，初始启动 fail closed，已有有效 snapshot 的进程保留上一份有效 snapshot并显示 resolution 错误。CLI 的 `CLIConfig` / `CLIModernProviderConfig` 读取所有启用的 OpenAI-compatible route、model、variant，`CLIInferenceProfiles` 将其全部编译为 immutable profiles；每个 connection revision 保留自己的 exact env/file/auth/config credential reference，`CLIExactSecretResolver` 不会用 selected route 的 credential 替代其他 route 或旧 revision。Modern CLI 的 unqualified model 仅在全 catalog 唯一匹配时切到其 route；显式 reasoning 只能命中 configured variant/base effort，否则 config fail closed。Non-empty recovery 缺失 `@main` 时要求显式 `/agent restore-main`。GUI 将 exact resolution/reviewer health 作为执行状态而非 composer/本地 Send gate；CLI 仍以它们控制显式 data-plane resume。普通 worker unresolved 仍显示在 roster，但不全局暂停 scheduler：其 queued invocation 在 provider dispatch 前 durable fail closed，清除 busy fence 后才可显式 rebind，其他 agents 可继续运行。两端的 list/roster 只投影 safe label/identity/trust classification/resolution，不投影 endpoint、credential 或 options。
- **macOS advanced config**：macOS GUI 启动时先检查用户显式设置的 `INTATIS_CONFIG` 文件；未设置时按顺序只检查 Intatis-owned 路径：`~/.config/intatis/intatis.json` / `intatis.jsonc`、app support 的 `intatis.json` / `intatis.jsonc`，最后才兜底读取旧 Intatis `config.json` / `config.jsonc`。不会自动发现任何名为 `opencode.json` 的文件，也不读取 `~/.config/opencode/` 下的 OpenCode app 配置；OpenCode-compatible 只表示 JSON shape 兼容。找到可解码的 JSON/JSONC 后覆盖 UserDefaults provider catalog；聊天页当前选择覆盖层仍可覆盖 JSON 顶层 `model`。设置页的 Open Intatis Config 按钮会打开当前生效的 Intatis-owned 文件或 `INTATIS_CONFIG` 显式指定文件；若只发现旧 `config.json`，会从当前 catalog 生成新的 `~/.config/intatis/intatis.json` 模板并优先打开。保存设置时，用户本次主动输入的 API key 会写入同一个可编辑 provider JSON 的 `provider.<id>.options.apiKey`；写入用户 config 失败时回退到 app support `intatis.json`。创建的模板来自当前 provider catalog，只输出 OpenCode-compatible `$schema` / `enabled_providers` / `model` / `provider.<id>.npm` / `name` / `options.baseURL` / `options.apiKey` / `models`，`options.apiKey` 默认是 `{env:...}` 引用而非明文。支持兼容读取旧 direct `providers` 数组，也兼容读取 Intatis 扩展字段 `chatEndpoint` / `apiKeySource`；推荐新配置使用 `provider.<id>.options.baseURL`、`options.apiKey`（OpenCode-style 明文、`{env:NAME}` 或 `{file:path}` 均可由真实请求懒加载）、`models`，以及顶层 `model` 形如 `<provider>/<model-id>`。支持 OpenCode-compatible 的 `enabled_providers` / `disabled_providers` 过滤；`disabled_providers` 优先。省略 `options.apiKey` 时 provider 请求按 provider id 尝试 Intatis auth JSON 与当前 Intatis-owned OpenCode-compatible config，不再回落 OS Keychain。
- **provider config reference confinement**：从 provider JSON 产生的直接 `options.apiKey` secret ref 会绑定当前配置文件；历史 UserDefaults 中的 `providerConfig` 路径只有匹配 Intatis 自有候选或当前显式 `INTATIS_CONFIG` 时才可读取，其他路径由 resolver fail closed。
- **Cowork automatic permission review**：brand-new GUI/CLI Cowork session 以一个本地 durable 七事件 bootstrap 同时记录 settings、fixed `@main` 与 `@permission-reviewer`；初始化不产生模型审批或 provider 请求。恢复的非空 session 先恢复 durable settings/roster；若缺失 `@main`，GUI 从 canonical settings 走 host-authorized exact historical-main recovery，随后才 replacement/retry reviewer，CLI 使用专用 `/agent restore-main`。审查者固定 read_only、无工具 lease、无通信/委派、`coordinationDepth=0`，不会启动嵌套 `AgentLoop`；`AgentPermissionResponder` 把宿主解析的 `ResolvedToolAuthorization`、参数 digest/count、有界秘密脱敏 action preview 与紧凑 causal/lease metadata 放入 untrusted block 后交给独立 FIFO/single-flight 控制面。审查者只返回 `{"decision":"allow|deny","reason":"non-empty bounded reason"}`，且 risk 不得低于 gate；pre-submit caller cancel 返回 typed deny且不创建 review lifecycle；不可解析输出、空 reason、tool call、timeout、provider error、settled persistence failure 与已登记 review 在 terminal-claim 前被观察到的 cancel durable deny 当前调用；claim 后 cancel 保留唯一 settlement 但 authorization delivery deny。Phase B 将 producer lifecycle 收窄到 request generation：factory 逐代 exact-resolve，provider/timeout race 与 provider-backed terminal claim 校验 exact generation，pre-dispatch terminal 从 running/no-generation 状态唯一 claim；retired producer 不持有 EventLog/actor/authorization，下一 request 不继承 process-lifetime quarantine。`ToolCallingProvider.stream` 必须立即返回 request-owned stream，并传播 consumer termination，shipped OpenAI/URLSession 路径符合；同步永久阻塞的任意第三方实现不在该契约内。GUI 不做隐式人工 fallback；Phase A 后 reviewer 未就绪不锁定 composer，普通请求继续，只有 ask-class tool fail closed；对话页不常驻 reviewer 横幅，异常恢复入口位于 Project Settings 的 Recovery 区。CLI `/auto` 重新启用，只有用户明确 `/default` 才移除审查者并恢复终端人工确认。

示例（不含明文 secret）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "enabled_providers": ["OpenRouter"],
  "model": "OpenRouter/deepseek/deepseek-chat",
  "provider": {
    "OpenRouter": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OpenRouter",
      "options": {
        "baseURL": "https://openrouter.ai/api/v1",
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "deepseek/deepseek-chat": { "name": "DeepSeek Chat" }
      }
    }
  }
}
```

## 安全机制

### 凭据存储
- GUI 不再读写 OS Keychain。`KeychainRef` 是历史命名的 secret ref；其中 `.keychain` 仅作旧配置兼容值，app resolver 会把它映射到配置/auth 文件查找，不调用 Security Keychain API。
- `ConfigSecretResolver` 可指向 `environment` / `file` / `authFile`。macOS `authFile` 默认先查 `~/.config/intatis/auth.json`，再兼容查 `~/.local/share/intatis/auth.json` 与 Intatis-owned OpenCode-compatible config 的 `provider.<id>.options.apiKey`；不默认读取 `~/.local/share/opencode/auth.json` 或 `~/.config/opencode/opencode.json`。也可用 `INTATIS_AUTH_FILE` 覆盖。iOS 默认落在 app container Application Support 的 `Intatis/auth.json`。UserDefaults catalog 只存 secret ref 元数据，不存 API key；macOS 设置页输入的 API key 写入当前可编辑 provider JSON，iOS 设置页输入的 API key 写入 auth JSON 并尝试设置 `0600`；真实 provider 请求懒加载 secret，并按 source/service/account 做进程内缓存。

### 工作区边界
- `PathConfinement.resolve`：拒 `..` 遍历与越界绝对路径。Tools 执行与权限门均使用。

### 权限 3 层门
1. `DeterministicPolicyGate`（纯函数、模型无关、runs first、`deny` 终局）：输入包含结构化 `PermissionIntent(action/resources/metadata/dataEffects/controlEffects/risks/replayPolicy)`。locked、敏感路径、路径越界、shell disabled、read-only lease 下真实 mutate/exec/network/destructive，以及 read-only parent 试图授予 child read-write workspace 都 hard deny；普通只读数据操作 allow；exact `rename_session` + `session.rename` + sole `tool:current_session` + no path/network/data/control effects 的调用作为 low-risk local metadata mutation allow，任何 near-miss 回到普通保守规则；其余需要审查的写入、网络、exec、destructive 和 agent/task/message/workspace 控制面操作返回 `pass`。WorkspaceLease 是权限 ceiling，不是“本次调用已经写文件”的判据。
2. reviewer（模型评审）只见 gate `pass`，只能收窄，**不能**覆盖硬 deny。非 Cowork host 可注入 `ModelPermissionReviewer`；production Cowork 不注入该 reviewer，而把同一次 `pass -> askUser` 请求交给 durable `PermissionReviewControlPlane`。同一调用不得同时配置两条模型审查路径。
3. `PermissionEngine`（组合）：`pass` 且无 in-engine reviewer → `askUser`，由当前 responder 处理。Cowork 自动模式 responder 只有 allow/deny、无人工 fallback；人工模式只能由用户显式切换。

自动权限审查不改变上述终局规则。因为 hard deny 不会产生 `permission_request`，`@permission-reviewer` 无法覆盖硬 deny。结构化 intent 与 authorization 以向后兼容的 optional 字段追加到 permission request/resolved、review task 与 tool execution prepare/settle 事件；旧 JSONL 缺字段时继续解码，但 live automatic-review 路径缺少完整 `ResolvedToolAuthorization` 必须 fail closed，不能借 legacy adapter 重新解释 alias。审查记录写入 `permission_review_requested/settled` 与兼容 `permission_review`，同一 `authorizationID` 必须贯穿最终 `permission_resolved`、prepared 与 settled，executor 仍以 durable settlement 和复核后的不可变 snapshot 为准。

Phase C 把 approval response 与 turn terminal 拆成两个层次。人工 `approve` 允许当前 call 进入 prepare/executor；`decline` 写当前 call 的 typed denied result并把 observation 回灌同一模型 turn；`cancelTurn` 只写 permission terminal，随后抛出 turn interruption，不制造 tool result。自动 reviewer 仍只产生 allow/deny，不出现 GUI 人工按钮。control plane 对同一 RequestID 的 exact duplicate/reconnect 共享 owner generation 与首 terminal，冲突 duplicate 关闭；owner cancellation 在 authorization delivery 前对所有共享 waiter fail closed。runtime stop/cancel 先 drain request-owned provider/tool child，再提交 task/turn terminal并恢复 caller，避免 terminal 早于清理。只有 wrapper 在目标启动前产生的可信 sandbox startup denial 才归类 `sandboxDenied/notStarted`；普通退出错误不重试、不升级权限。

### 秘密拦截
- `SecretScanner`：敏感路径/basename/扩展名、秘密内容标记（`-----BEGIN`、`PRIVATE KEY`、`AKIA`、`sk-`、`ssh-rsa`、`xoxb-`、`ghp_`、`AIza`…）、受保护配置路径。
- `Mediator`：agent 间转发时拦截秘密 + 超长原始转储（>4000 字符要求发摘要）。

### Sandbox / Entitlements
- `IntatisMac.DeveloperID.entitlements`：默认 `IntatisMac` 使用；非 sandbox、Hardened Runtime，本地 Code/Cowork 的 shell/git/browser 能力仍必须经过 `PlatformProfile.macDeveloperID` 与权限门。
- managed terminal 在 macOS 额外套 Seatbelt：只允许 WorkspaceLease 映射出的文件访问，默认拒绝网络；只允许同一 sandbox 中的 fork/exec、process info 与 signal，不开放全局 `process*`，也不开放所有 `/dev/ttys*`。PTY 仅使用已继承的 controlling terminal descriptor。Linux 要求 bwrap，缺失时 fail closed；Linux PTY 当前不支持。
- `IntatisMac.AppStore.entitlements`：保留给未来 AppStore/chat-only sandbox 版本；`app-sandbox=true`、`network.client=true`、`files.user-selected.read-write`、`files.bookmarks.app-scope`。**无 `run_shell`**。

## 模式开关 / 内核切换

无 Rokurics 式新旧内核开关。Cowork 架构原则与当前必须保持的回归点见 `docs/COWORK_PRINCIPLES.md`；较早 `COWORK_*` 状态文档可能落后于当前源码。

## 与文档/源码的关系

- 仓内根 `ARCHITECTURE.md`（draft-0, 2026-06-11，中文）描述 Intatis 内核/Cowork 设计。本目录 `docs/ARCHITECTURE.md` 据实际源码重写并与之对照。
- Cowork 设计细节见 `docs/COWORK_AGENT_ARCHITECTURE.md` 等 7 个 COWORK_* 文档；原则提炼见 `docs/COWORK_PRINCIPLES.md`。
- 开源源码、公开 prompt、依赖、bundled runtime 与上游升级的准入规则见 `docs/OPEN_SOURCE_REUSE.md`；实际已经采用的上游必须登记在 `NOTICE.md`。截至 2026-07-12，OpenCode 仍为 research-only，尚未把其源码、公开 prompt、UI 资产或 runtime 加入 Intatis。
