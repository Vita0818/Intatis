# Cowork 多 Agent 对话切换：不卡死优先的性能审计与设计报告

- 日期：2026-08-03
- 状态：只读审计与方案报告，尚未实施
- 核心目标：在 Cowork 右侧 Agents 区点击某个普通 agent 后，中间线程只查看该 agent 的工作；默认明确显示 main；无论 session 总历史和单 agent 历史有多大，点击、连续切换和后台流式输出都不得卡死 UI。
- 优先级：流畅性和资源有界高于切换动画、预热富文本或“点击后立即把全部历史装进视图”。

## 1. MODEL_CHECK_RESULT

当前为 GPT-5 系列 Codex agent；无法从运行环境确认更精确的模型构建号。

## 2. PATH_CHECK_RESULT

- pwd：/Users/vita/Vitemis/Intatis
- Git root：/Users/vita/Vitemis/Intatis
- 两者匹配项目预期。
- 开始审计时 git status --short 为空；没有需要规避的用户既有工作区改动。

## 3. FILES_WRITTEN

本轮只新增本报告：

- codex-report/08_03_26-22_08-cowork-agent-thread-switch-performance-report.md

未修改 Apps、Packages、Package.swift、project.yml、测试源码或构建脚本。

## 4. 结论先行

这个需求不能实现成“点击 agent 后，对当前全部 items 做一次 filter，然后把结果交给 SwiftUI”。这种做法在小数据上看起来正确，但历史越大，点击成本、数组复制、相等比较、视图 diff、富文本挂载和布局成本会一起增长；连续点击时还会叠加过期任务，最终重现此前 Cowork/Code 富文本线程的高 CPU、AttributeGraph 反馈循环或内存增长问题。

正确的性能合同应是：

1. 点击成本只与当前页大小有关，不与 session 总消息数或该 agent 总消息数有关。
2. 中间线程一次只接收并挂载最多 16 个顶层 row，而不是接收某 agent 的全部历史再由视图分页。
3. 同一窗口任何时刻只存在一棵可见 agent 线程树；切换时旧树立即失活并释放富文本 document/native view，不做双树 crossfade，也不在后台保留每个 agent 的隐藏线程。
4. agent 归属在事件投影时增量建立 typed index；点击只从 index 取一个有界页面，不读 EventLog、不 replay、不扫描标题字符串。
5. 只有当前被查看 agent 的 token/delta 可以发布到中间线程；其他 agent 继续工作时，只更新右侧轻量状态，不得让当前 transcript 重新求值。
6. 点击先立即提交选中高亮和 raw page；Markdown 富文本必须继续服从 viewport idle dwell、单解析并发和 generation 取消。富文本绝不能阻塞切换可见结果。

按这个合同，目标复杂度是：agent 点击 O(P)，其中 P 最大为 16；而不是 O(N)，其中 N 是 session 全部历史。

## 5. 用户可见产品合同

### 5.1 默认与选择

- 新进入 Cowork session 时，默认选择 projectSettings.mainAgentName 对应的 main，而不是 agents 数组第一项。
- 点击右侧 Agents 状态行，立即更新选中态，并把中间线程切换为该 agent 的对话。
- 选择是窗口级 presentation state，不改变 session runtime，不停止其他 agent，也不改变 scheduler/mailbox。
- 选择只改变“看谁”，不得暗中改变 composer 的发送目标。现有未显式 mention 时发给 main 的规则保持不变；如果未来要做“查看即发送给该 agent”，必须作为另一项显式产品决策。
- 每个窗口可独立选择 agent；两个窗口查看同一 session 时可以分别查看不同 agent。

### 5.2 哪些内容属于某个 agent

不能通过 UI title（例如 agent · @name）做字符串匹配。归属必须来自事件里的 typed identity：

- user_message：归入 payload.to；to 缺失时按该 session 的 projectSettings.mainAgentName 归入 main。
- message_delta / message_completed：归入 payload.agent。
- tool_call / tool_result：tool_call 按 payload.agent 归入；tool_result 通过 toolCallID 关联回同一个 agent。
- agent_message：同时属于 from 与 to 两侧的工作视图，但正文只存一份，两个 agent index 只保存轻量引用。
- 与 task/turn/submission 有明确关联的 error、retry、状态事件：跟随其归属 agent。
- 无法可靠归属的 session 全局事件：留在全局状态面，不能猜测 agent。

默认线程仍使用当前 IntatisExecutionTracePresentation 的展示策略：普通用户/agent 对话可见，隐藏的工具细节不应因为 agent 切换而突然全部展开。若产品后续需要“仅对话”和“完整工作轨迹”两种模式，应在投影层建立两个明确 lane，不能在每次点击时扫描并过滤全历史。

### 5.3 始终全局的内容

权限审批、Goal、Tasks、session 错误和右侧 agent 运行状态仍属于 session 全局控制面，不随查看对象消失。permission reviewer 是保留控制面 agent，建议继续只显示状态且不可作为普通对话选择目标。

如果当前选中的普通 agent 被移除或 detach，窗口必须原子回退到 main，并取消旧 agent 的页面查询、scroll callback 和 rich publication。

## 6. 当前代码事实与风险

以下结论以当前源码为准。

| 区域 | 当前事实 | 对本需求的性能影响 |
| --- | --- | --- |
| CoworkShell | CoworkViews.swift:537 保存整份 displayedItems；初始化时在 615 行通过 IntatisExecutionTracePresentation.displayedItems(items) 对输入整数组过滤 | 如果再在点击时做 agent filter，会在 UI 路径重复 O(N) 扫描和分配 |
| 默认 agent | CoworkViews.swift:663-665 在没有 selectedAgentID 时退回 agents.first | agent roster 在 CoworkViewModel.swift:1207 起按名字排序，第一项不保证是 main，默认合同必须显式绑定 main |
| 右侧 Agents | CoworkViews.swift:854-909 的 agentStatusRow 当前是静态 HStack | 可以增加点击语义，但点击处理本身必须只改轻量 selection/generation |
| 线程窗口 | CoworkViews.swift:1767 起使用 eager VStack；ThreadSurfaces.swift:1316 固定 capacity = 16 | 这是必须保留的安全边界；agent page 必须在进入视图前就已经不超过 16 行 |
| 页面作用域 | CoworkViews.swift:1943 起由当前 presentationScope 生成 history window scope | 新作用域必须包含 session + agent + page，防止旧 agent 的 scroll/rich callback 写入新页面 |
| 工作指示 | CoworkViews.swift:1931-1935 使用全局 isWorking 和 summary.runningCount | 切换后应改成 selected-agent-specific，否则其他 agent 工作会让当前查看线程错误显示 thinking 并触发无关更新 |
| ViewModel 发布 | CoworkViewModel.swift:221 把完整 [CodeItem] 作为 @Published items | 任意一次 items 发布都会触发 Cowork ViewModel 的 objectWillChange；即使视图最终只展示 16 行，仍可能让整个 CoworkShell 重新求值 |
| 主线程整数组处理 | CoworkViewModel.swift:753-755 比较并替换 canonicalItems；1071 起 refreshPresentedItems 复制、扫描、建 Set、拼 outbox，再做数组比较 | 当前高频快照路径已经与总历史规模相关；不能在此基础上再叠加 agent 全量派生数组 |
| Projection snapshot | SessionProjectionPump.swift 的 CoworkSessionProjectionSnapshot 可携带完整 [CodeItem] | 线程 dirty 时向 UI 交付整数组，不适合作为超大多 agent 历史的最终 presentation API |
| typed 归属 | Event.swift 的 UserMessagePayload.to、MessageDeltaPayload.agent、MessageCompletedPayload.agent、ToolCallPayload.agent，以及 CoworkEvents.swift 的 AgentMessagePayload.from/to 已存在 | 不需要改 EventLog wire schema；应在 fold 时保留归属，不要在 UI 反向解析标题 |
| CodeItem | CodeProjection.swift:7 起的 CodeItem 没有专门的 agent identity 字段；agentIndex 和 toolName 仍有 firstIndex/扫描 | 需要 presentation-only attribution/index；同时应消除流式 delta 对长数组反复线性查找 |
| 富文本生命周期 | IntatisMessageContentView.swift:257 起 onDisappear 会 deactivate；Markdown facade 限制 64 KiB、1 running、32 pending、50 ms incomplete debounce、150 ms viewport dwell、100 ms raw projection cadence | 切换必须触发 exact disappear/deactivate，并延续这些边界；不能为“秒开”保留多 agent 原生视图缓存 |

这里最重要的不是某一次 filter 花了多少毫秒，而是多条线性工作会相乘：

session snapshot → 完整 items 数组 → @Published 全局失效 → agent filter → display filter → history resolve → SwiftUI diff → rich row mount/layout。

当后台多个 agent 同时流式输出时，这条链可能以现有固定窗口发布节奏反复发生。即使用户正在看 agent A，agent B/C/D 的 delta 也会让 A 的页面重新计算；这正是需要切断的失效传播。

## 7. 已有卡死事故给出的硬约束

本仓库已有两份直接相关的事故/方案报告：

- codex-report/07_29_26-17_05-cowork-scroll-rendering-hang-remediation-plan.md
- codex-report/07_24_26-13_57-session-switch-layout-storm-remediation-plan.md

结合 docs/ARCHITECTURE.md 与 docs/DO_NOT_BREAK.md，当前正式结论是：

- 真实 session 中，消息粒度 LazyVStack 配合 SwiftUI/AppKit 混合、富文本可变高度 row，已经出现 AttributeGraph transaction feedback 和持续高 CPU。
- 当时即使可见顶层 row 数并不大，也不能证明 lazy virtualization 安全；问题来自 mount/unmount、测量、滚动锚点和 native paragraph 布局之间的反馈。
- 生产合同已经冻结为：每页最多 16 个顶层 row、页内 eager VStack、Earlier/Newer/Latest 显式分页；不得恢复消息级 LazyVStack，也不得把全历史改成无界 eager。
- 不得新增 completed-document cache、paragraph native-view cache 或 message-height cache 来“加速”切换。它们会把不可见历史的原生图留在内存里，历史 retaining edge 仍是 UNKNOWN。
- runtime 保持 warm 与 renderer 保持 warm 是两件事。切换展示对象时 runtime 可以继续运行，但旧 presentation tree 必须按 scope/generation 取消并释放。
- 历史 GUI adverse evidence包含持续单核 CPU和显著内存增长；最终 retaining edge 没有被形式化定位。因此本功能必须按“容易重新触发事故”的高风险 UI 改动验收，不能只做正常数据的手点测试。

此外，2026-07-29 最终修复后的完整大于 160 秒 soak 仍是现有验证缺口。新增 agent 切换不能以较短 happy-path 运行代替长时间验证。

## 8. 明确禁止的实现方式

### 8.1 点击时在 MainActor 全量 filter

禁止：

agent click → vm.items.filter(agent) → displayedItems.filter(...) → SwiftUI。

它的点击成本是 O(N)，还会产生新数组、Equatable 比较和大量 ARC 工作。N 足够大时，即使富文本本身没有问题也会卡住主线程。

### 8.2 把全量 filter 简单搬到 Task.detached

这只是把卡顿变成后台 CPU/内存风暴。用户快速点击 A→B→C 时会创建多个 O(N) 任务；取消不保证底层扫描立刻停止，过期结果还可能争相回主线程。必须从数据结构上做到有界查询，并使用 generation 丢弃过期结果。

### 8.3 先取 session 最后 16 行，再按 agent filter

顺序错误。最后 16 个 session 事件可能全部属于别的 agent，从而错误显示“无消息”。必须先通过增量 agent index 定位该 agent 的有序消息，再取其 16 行页面。

### 8.4 每个 agent 预建一个隐藏线程

禁止用 TabView/ZStack/opacity 保留每个 agent 的 ScrollView、Markdown document、AppKit paragraph view 或 scroll coordinator。这样点击看似快，但 agent 数和历史增长时，内存与布局工作近似按 agent 倍增，正好绕过现有 onDisappear 释放合同。

### 8.5 crossfade 或带布局动画的切换

首版不要做 transcript crossfade、matched geometry 或同时存在 old/new tree 的 transition。切换瞬间只能有一棵线程树；选中 pill 可以有轻量状态反馈，但内容树用非动画 exact replacement。

### 8.6 点击后 replay EventLog

EventLog 是 canonical truth，不是 UI 点击查询数据库。每次点击读 JSONL/replay 会让延迟随 session 年龄增长，还会与持续 append 竞争。agent index 必须在 session projection 生命周期内增量维护。

### 8.7 从 title/body 猜 agent

标题是展示文案，会本地化、重命名或改变格式。字符串归属不仅慢，还会错分 user target、tool result 和 agent-to-agent 消息。

## 9. 推荐的性能优先数据边界

### 9.1 一份 canonical body，多份轻量索引

在 projection/pump 的 actor 隔离域内维护 CoworkAgentThreadIndex：

- canonicalItems：消息正文只保存一份。
- messageID → item index：流式 delta 直接 O(1) 定位，不再 firstIndex 扫描。
- toolCallID → agent/item：tool_result O(1) 回归属。
- agentID → ordered item references：每个 agent 只保存 Int/稳定 ID 引用。
- agentID → displayable ordered references：按当前 presentation policy 预先维护，避免点击再扫隐藏 tool trace。

agent-to-agent 消息可进入两个 agent 的 reference list，但正文不复制。总体空间仍为 O(N) 级；双边消息最多增加轻量引用，而不是增加两份 Markdown body/document。

### 9.2 Actor-owned bounded page API

中间线程不再接收完整 [CodeItem]，而只接收类似下面的有界快照：

- agentID
- generation / projectedThroughSeq
- items：最多 16
- lowerBound / upperBound / totalCount
- hasEarlier / hasLater
- selected agent 的 working/thinking 状态

page(agentID, requestedUpperBound, limit: 16) 的查询成本应是 O(16)，不受总历史影响。点击不改变 canonical projection，也不复制整份历史。

### 9.3 窄化高频发布

Cowork runtime/pump 继续精确 fold 所有事件，但 UI 发布拆为两类：

- 全局低频/结构化状态：roster、tasks、goal、permission、agent counters。
- selected-agent transcript：仅当前窗口选中 agent 的 bounded page。

非选中 agent 的 delta 不得发布 selected transcript page。它可以更新右侧该 agent 的轻量 running/unread 指标，但不能触发当前 16-row 内容树重建。

presentation 通知可以使用 latest-only / bufferingNewest(1)，前提是 actor store 始终持有最新 canonical in-memory page，消费者醒来后重新读取最新值。EventLog 的 canonical event stream 本身不能丢事件，也不能改为 newest-only。

### 9.4 每窗口的轻量 PresentationModel

每个 Cowork 窗口持有独立的 CoworkAgentThreadPresentationModel：

- selectedAgentID，初始显式 main。
- selectionGeneration，单调递增。
- 每 agent 的 requestedUpperBound，可选且只保存数字。
- 当前 bounded page。
- 当前 selected-agent subscription/task。

可以缓存每个 agent 的页码/upperBound/count 等轻量 metadata；不能缓存其 SwiftUI subtree、Markdown document、native view、row height 或 scroll coordinator。

## 10. 一次点击的正确生命周期

建议把一次切换定义为下面的严格状态机：

1. 用户点击普通 agent 行。
2. 同步只做轻量工作：提交选中高亮、递增 selectionGeneration、记录目标 agentID。
3. 取消旧 agent 的 page request 和 transcript subscription；旧 presentation scope 失活。
4. transcript root 以 session + agent + page 的新 scope 做非动画替换。旧 row 的 onDisappear 立即取消 raw/rich dwell、scroll callback，并释放 published document。
5. 从 actor index 请求最多 16 行。若查询跨 actor，先显示轻量 skeleton/empty state；不能阻塞 MainActor 等待。
6. 结果返回时核对 exact generation。任何旧 agent/旧页结果一律丢弃，不能发布。
7. 先挂载 exact raw page；恢复 bottom anchor 或该 agent 的数字页位置。
8. 只有滚动进入 idle 且当前 generation 仍有效，才在既有 150 ms viewport dwell 后允许 rich admission；继续服从 process-wide 1 running / 32 pending 和 64 KiB exact raw fallback。
9. 用户再次点击时立刻回到第 2 步，不等待旧 Markdown parse 完成。已经开始、无法物理中断的后台 parse 可以自然结束，但其 publication 必须被 generation 围栏拦截。

切换不触碰 AppSessionRuntimeManager 所持有的 Cowork runtime，不取消 agent 工作，也不 replay session。它只是销毁一棵 presentation tree 并挂载另一棵有界 tree。

## 11. 复杂度与资源预算

P 表示页面容量，固定 P ≤ 16；N 表示 session 全部展示候选；Na 表示某 agent 全部候选。

| 操作 | 必须达到 | 不接受 |
| --- | --- | --- |
| 点击 agent 的同步 MainActor 工作 | O(1) 状态提交 | O(N) / O(Na) filter、sort、copy、Set、全数组 equality |
| 获取第一页/任意页 | O(P) | replay EventLog 或扫描全 agent 历史 |
| 挂载顶层 row | ≤ 16 / window | 某 agent 全历史、每 agent 各一棵隐藏 tree |
| 正文存储 | 一份 O(N) canonical body | agent-to-agent 正文复制多份 |
| agent membership | O(N) 轻量 ID/Int 引用 | 复制 [CodeItem] 全对象到每个 agent |
| 非选中 agent token | 0 次 selected transcript publication | 让当前中间线程每 token 重算 |
| pending selection query | 每窗口最多 1 个逻辑请求 | 快速点击形成未受控任务队列 |
| native rich tree | 每窗口仅当前页可见树 | completed-document/native-view/height cache |
| 旧 scope 回调 | 0 次成功 publication | 旧 scroll/rich/page 结果写入新 agent |

即使未来 agent 数超过当前常规上限，这些预算也不应变化；右侧 rail 自身可以小规模展示 roster，但 transcript 成本必须与 agent 总数解耦。

## 12. 不可协商的验收门

### 12.1 结构性硬门

以下不依赖机器性能，任一失败即不应合并：

- 每窗口最多 16 个顶层 transcript row。
- 页内继续使用 eager VStack；无消息级 LazyVStack、无 adaptive lazy/eager 切换。
- 每窗口同一时刻只有一棵 agent transcript root。
- 点击路径无全历史 filter/copy/sort/Set/equality，无 EventLog read/replay。
- session + agent + page 使用稳定且互异的 presentation scope。
- 旧 generation 的 page、scroll、raw、rich publication 数为 0。
- 非选中 agent delta 导致的 selected transcript publication 数为 0。
- 连续点击时每窗口最多一个有效 page request/subscription。
- reviewer 不进入普通对话选择；agent detach 能精确回退 main。
- composer target、permission、Goal、Tasks 和 runtime 生命周期无行为回归。

### 12.2 交互时间门

沿用仓库已有正式 interaction 门，并给 agent switch 增加可观测阶段：

- 点击 handler 的同步 MainActor work：p95 ≤ 8 ms，single max ≤ 50 ms。
- selected highlight：下一次可提交 frame 可见。
- bounded raw page 可见：建议首轮 gate 为 p95 ≤ 50 ms、single max ≤ 100 ms；应在 Phase 0 的固定参考机和 fixture 上冻结，不得在实现完成后为迁就结果放宽。
- 任何一次 500 ms heartbeat warning：0。
- 任何一次 2 s incident/hang bundle：0。
- SwiftUI “multiple updates per frame”目标日志：0。
- 连续切换停止后，CPU 必须回落到 idle 区间，不能长期占满一个核心。

### 12.3 内存门

由于历史 retaining edge 仍是 UNKNOWN，不应只看一次 peak：

- 记录 RSS、physical footprint、mounted native document/paragraph count。
- 先完成 500 次切换，再完成 1,000 次切换；比较 settled baseline，而不是切换瞬时峰值。
- 500→1,000 次区间必须呈平台化，不能随切换次数近似线性增长。
- 建议候选门：每 100 次切换的 settled footprint slope 小于初始 baseline 的 1%，且置信区间包含 0；最终数值应在 Phase 0 按参考机器冻结。
- 切走 agent 后，其 document/view 数必须回到 0；只允许保留轻量 index/page metadata。

## 13. 必须建立的压力场景

不能只用几十条纯文本验证。建议新增 production CoworkShell fixture，至少包含：

- 8 个普通 agent，加 1 个 status-only permission reviewer。
- 每个普通 agent 1,000 个可展示 item，总计至少 8,000 条；另加隐藏 tool trace 和双边 agent_message。
- Markdown、长代码块、table、math、接近 64 KiB 富文本，以及超过 64 KiB 的 exact raw 文本。
- 4 个 agent 同时流式输出，聚合 500 delta/s 的可重复 burst。
- 固定序列快速切换 1,000 次：包含约 10 Hz 连点、A→B→A、随机 agent、点击当前 agent。
- 至少 180 秒单实例 soak，覆盖并超过历史 160 秒风险窗口。
- 当前页为 latest、Earlier 旧页、Newer、回 Latest；旧页收到 append 时 upperBound 保持不变。
- 两个窗口打开同一 session，分别选择不同 agent。
- inspector 宽/窄、permission pinned、Goal/Tasks 更新同时发生。
- 正在查看的 agent 被 detach，验证 exact fallback main。

必须在真正的 CoworkShell、真实 CodeItemRow 和 Microsoft renderer 上运行；只测 mock Text list 不能覆盖 AttributeGraph/AppKit 风险。

## 14. 诊断与可观测性

应扩展现有 IntatisPerformanceDiagnostics，而不是依赖肉眼感受。建议新增不含正文和真实 agent 名称的安全指标：

- agentSwitch.request / commit / staleDiscard
- agentSwitch.mainActorDuration
- agentPage.queryDuration / returnedRowCount / totalCount
- agentPage.selectedPublication / nonSelectedSuppressed
- agentThread.oldScopeDeactivated
- agentThread.mountedTopLevelRows
- agentThread.activeRichDocuments / pendingRichAdmissions
- agentThread.rawFirstPaint
- agentThread.staleScrollCallback / staleRichPublication

用安全 session hash、agent ordinal、generation 和计数关联，不记录消息内容、私密路径或 provider 响应。

验收时同时使用：

- 现有 250 ms heartbeat、500 ms warning、2 s incident bundle。
- os_signpost / Points of Interest。
- Instruments Hangs、Time Profiler、Allocations/Leaks。
- 父进程 hard watchdog，保证单实例、超时终止和无残留。

## 15. 建议实施顺序

本轮不实施。后续应按下列顺序推进，每阶段独立测量，不能一次性同时改 projection、UI 和 renderer：

### Phase 0：先冻结基线与失败证据

- 建 production fixture、switch driver、计数器和 signpost。
- 用当前“无 agent transcript 切换”的 UI 记录 CPU、heartbeat、memory baseline。
- 冻结参考机、fixture hash、时间门和 footprint slope 门。

### Phase 1：只建立 typed attribution 与增量 index

- 从现有 Event payload 保留 agent identity。
- 增加 messageID/toolCallID O(1) lookup。
- 验证 user target、main fallback、A2A 双侧归属、tool result 关联和 legacy event。
- 不改 EventLog schema，不改 UI。

### Phase 2：建立 bounded page store 与窄订阅

- actor-owned page API 每次最多返回 16 行。
- selected-agent latest-only presentation signal；canonical fold 仍 exact。
- 从 Cowork visible UI 热路径移除完整 @Published items 的高频依赖。
- 证明非选中 agent delta 不发布当前 transcript。

### Phase 3：接入右侧点击与 presentation lifecycle

- 默认显式 main；普通 agent 可点；reviewer 不可点。
- scope 包含 agent；无 content transition。
- detach fallback、每 agent upperBound、两窗口独立选择。
- selected-agent-specific thinking，composer routing 保持原样。

### Phase 4：长时间性能验收

- 跑第 13 节全部压力矩阵和 Instruments。
- 任一 stale publication、heartbeat warning、持续单核、row 超 16 或 settled memory 正斜率，都先停下修复，不能通过增加 cache 掩盖。
- 通过后再同步 CURRENT_STATE、ARCHITECTURE、DO_NOT_BREAK、TESTING 和对应 UI/性能报告。

## 16. 后续实现可能涉及的文件

这不是本轮修改清单，只是审计定位：

- Packages/IntatisProtocol/Sources/Event.swift
- Packages/IntatisProtocol/Sources/CoworkEvents.swift
- Packages/IntatisConversation/Sources/CodeProjection.swift
- Packages/IntatisConversation/Sources/SessionProjectionPump.swift
- Apps/IntatisMac/Sources/CoworkViewModel.swift
- Apps/IntatisMac/Sources/IntatisMacApp.swift
- Packages/IntatisSharedUI/Sources/CoworkViews.swift
- Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift
- Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift
- Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMicrosoftMarkdownPipeline.swift
- 对应 Conversation、SharedUI、macOS integration 和 renderer fixture 测试

不建议先从 CoworkViews.swift 加一个 filter 试做；必须先完成 Phase 0/1/2 的有界数据边界。

## 17. PROJECT_AUDIT_SUMMARY

本轮确认：

- Cowork runtime 与窗口 presentation 已有分离基础，切换查看对象不需要重启 agent runtime。
- 当前 UI 已有 16-row eager history window、稳定 page scope、scroll coordinator 和富文本 viewport admission，可作为新功能的安全基础。
- 当前完整 [CodeItem] 仍会经 CoworkViewModel/SessionProjectionSnapshot 发布，且 CodeItem 缺少明确 agent attribution；这是大历史下最关键的数据边界缺口。
- 右侧 compact Agents rail 当前只展示状态，已有 selectedAgentID 主要服务其他 agent 界面，尚未成为 transcript 的筛选来源。
- raw Event payload 已具备绝大多数 typed attribution，核心改造可以保持 EventLog 向后兼容。

## 18. DOCS_CONTENT_SUMMARY

本轮实际核对了：

- /Users/vita/Vitemis/AGENTS.md
- docs/VERSIONING.md
- docs/CURRENT_STATE.md
- docs/MACOS_DISTRIBUTION.md
- docs/PROJECT_MAP.md
- docs/ARCHITECTURE.md
- docs/DO_NOT_BREAK.md
- docs/OPEN_SOURCE_REUSE.md
- docs/TESTING.md
- docs/NEXT_TARGET.md
- docs/COWORK_PRINCIPLES.md
- codex-report/07_29_26-17_05-cowork-scroll-rendering-hang-remediation-plan.md
- codex-report/07_24_26-13_57-session-switch-layout-storm-remediation-plan.md
- codex-report/07_26_26-13_16-chatgpt-web-rendering-session-lifecycle-study.md 的相关 renderer/session lifecycle 章节

这些材料共同要求：保留 session/runtime 连续性，同时严格限制 presentation tree、历史窗口、富文本 cache、异步 generation 和主线程 invalidation。

## 19. VALIDATION_RESULT

本报告完成后实际运行：

- git diff --check：通过，exit 0。
- 因报告是未跟踪新文件，另运行尾随空白扫描；无匹配。
- git status --short：只显示本报告为未跟踪文件；没有其他工作区改动。
- 人工范围核对：只新增本报告。

本轮没有修改业务源码，因此未运行构建/测试。真正实现前必须先按 Phase 0 建立性能 fixture；实现完成后不能只跑单元测试，必须完成长时间 GUI/renderer 压力验收。

## 20. UNCERTAINTIES

- 历史高内存事故的最终 retaining edge 仍为 UNKNOWN；不能宣称只要保持 16 行就必然零风险。
- 当前生产设备上的 agent 历史规模分布、最低目标 Mac 和允许的 raw first-paint p95 尚未形成产品级冻结数据；本报告给出的 50/100 ms 与 1%/100 switches 是建议初始门，应在 Phase 0 固定参考机器后冻结。
- legacy event 中可能存在缺少 agent correlation 的 error/tool result；需要 fixture replay 后决定是归为 session-global，还是能通过 turn/task/toolCallID 精确补全。不得猜测。
- 尚未验证一个 session 多窗口共享同一 actor page store 时的最佳 ownership；原则已确定为共享 canonical store、窗口独立 selection，但具体生命周期需要结合 AppSessionRuntimeManager 测试确认。

## 21. NEXT_RECOMMENDED_ACTION

下一步不要直接改右侧 Button 或在 CoworkShell 里加 filter。先只做 Phase 0：建立 8,000+ items、并发流式和 1,000 次切换的 production fixture、计数器与基线报告。只有当“点击路径 O(16)、非选中 agent 零 transcript publication、单窗口一棵 rich tree”能够被自动测量后，再进入 typed index 和 bounded page store 实现。
