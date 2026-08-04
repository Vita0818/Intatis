# Cowork Agent 对话切换实施方案

- 日期：2026-08-03
- 状态：计划稿，尚未修改业务代码
- 目标：在 Cowork 右侧 Agents 区点击普通 agent 后，中间线程切换为该 agent 的独立工作对话；进入 session 时默认查看 main；用户可以在不停止其他 agent 的情况下自由查看任一普通 agent。
- 配套性能报告：codex-report/08_03_26-22_08-cowork-agent-thread-switch-performance-report.md

## 1. 这次准备交付什么

我准备交付的是一个“窗口内查看对象切换”功能，而不是改变 Cowork 的 agent 编排方式。

完成后，Cowork 页面会有以下行为：

1. 打开 Cowork session，右侧 @main 默认处于选中状态。
2. 中间线程默认只显示 main 的工作对话。
3. 点击右侧任一普通 agent，该 agent 的状态行立即进入选中态。
4. 中间线程随即切换到该 agent 的最新一页对话。
5. 其他 agent 继续在后台工作，scheduler、mailbox、任务和权限流程不被暂停。
6. 再点击 main 或其他 agent，可以立即切回对应对话。
7. 每个 agent 都有自己的 Earlier / Newer / Latest 历史页状态。
8. 当前 agent 被移除时，页面自动安全回退到 main。
9. permission reviewer 仍是控制面身份，只显示状态，不作为普通对话查看目标。

这个功能只改变“当前看谁”，不会默认改变“消息发给谁”。composer 仍遵守现有路由规则：没有显式 @mention 时发送给 main；有明确 mention 时发送给对应 agent。

## 2. 做完之后界面是什么样

### 2.1 初始状态

- 右侧 Agents 区保留现有 agent 名称、运行状态、模型/推理配置提示。
- @main 行增加明确选中样式。
- 中间标题或轻量上下文标识显示当前正在查看 @main。
- 中间线程展示 main 的最新对话页。
- Goal、Tasks、Permission 等 session 全局内容维持现有位置与含义。

### 2.2 点击 worker 后

假设右侧有 @main、@research、@writer：

- 用户点击 @research。
- @research 选中态在下一次可提交界面更新中出现。
- @main 取消选中。
- 中间线程替换为 @research 的对话，不与旧线程做 crossfade。
- @writer 和 @main 即使仍在流式工作，也不会把 @research 当前页面挤走或触发其正文重建。
- 右侧所有 agent 的轻量运行状态仍持续更新。

### 2.3 再切回某个 agent

- 第一次查看某个 agent 时，默认进入其 Latest 页。
- 如果用户在该 agent 内翻到了 Earlier 页，切走再切回时，可以恢复这个 agent 的数字页位置。
- 恢复的是轻量页面边界，不缓存旧 ScrollView、Markdown document、native view 或 row height。
- 如果用户点击 Latest，则重新进入该 agent 的实时跟随页。

### 2.4 agent 消失或不可选

- 普通 agent 被 detach/remove：如果它正被查看，立即取消其展示任务并回退 main。
- permission reviewer：继续在状态区可见，但不显示普通可点击选中态。
- main 暂时无法在 roster 中解析：页面显示明确错误/恢复状态，不能静默选择字母排序第一项。

## 3. “某个 agent 的对话”如何定义

我会在投影层按事件中的 typed identity 建立归属，不从 UI 标题或正文猜测。

某 agent 的对话包含：

- 用户明确发送给它的 user_message。
- 未指定目标且按 session 设置路由给 main 的 user_message，只进入 main 对话。
- 该 agent 产生的 message_delta / message_completed。
- 该 agent 发起的 tool_call，以及通过 toolCallID 关联到它的 tool_result。
- 它发给其他 agent 或其他 agent 发给它的 agent_message。
- 能通过 turn、task、submission 或 tool call 精确关联到它的错误、重试和终结状态。

agent-to-agent 消息会同时出现在通信双方的工作对话中，但底层正文只存一份；两个对话索引保存同一个消息引用。

下列内容保持 session 全局，不强行归到某个 agent：

- Permission 审批与审查状态。
- Goal 总状态。
- Tasks 总览。
- 无法从旧事件可靠判断 agent 的全局错误。
- session runtime、writer lease、provider 或恢复状态。

首版继续沿用现有 IntatisExecutionTracePresentation 的可见内容策略，不额外展开所有隐藏工具轨迹。首版也不新增 All Agents 聚合视图；当前需求的默认入口就是 main。

## 4. 我打算怎么做

整体分为八个阶段。每一阶段完成后都可以单独验证，避免一次同时改投影、UI、富文本和生命周期。

### 阶段 A：建立基线和诊断

先补齐功能实现需要的测量能力，不先改右侧点击：

- 建立多 agent、大历史、并发流式的 production-shaped Cowork fixture。
- 增加 agent switch request、commit、stale discard、page query、raw first paint 等诊断。
- 记录当前 CoworkShell 的 CPU、主线程、heartbeat、RSS/footprint 和 row mount 基线。
- 固定参考机器、fixture 内容和验收门。

交付物：

- 可重复的压力场景。
- 一份实现前基线。
- 后续每个阶段都能判断是否让 UI 更差。

### 阶段 B：给历史建立可靠的 agent 归属

复用现有 Event payload 中已经存在的 agent identity：

- user_message.to。
- message_delta.agent。
- message_completed.agent。
- tool_call.agent。
- agent_message.from / to。

在 Conversation projection 内增加 presentation-only 的归属模型，不修改旧 JSONL 的必要字段，也不从 title 解析 agent。

同时增加：

- messageID → item 的直接索引。
- toolCallID → agent/item 的直接索引。
- agentID → 有序消息引用。
- agentID → 按当前展示策略可见的有序消息引用。

交付物：

- 旧 session replay 后也能得到每个 agent 的完整有序工作对话。
- 新的流式 delta 不需要扫描整份 items 才能找到目标消息。
- A2A 消息在双方对话中可见且正文不重复存储。

### 阶段 C：建立有界页面读取接口

增加一个 actor-owned 的 Cowork agent thread store。UI 不再通过“整份 items → 点击后 filter”获取对话，而是请求：

- agentID。
- requestedUpperBound。
- limit，固定最大 16。

返回：

- 当前页最多 16 个 CodeItem。
- totalCount。
- lowerBound / upperBound。
- hasEarlier / hasLater。
- projectedThroughSeq / generation。
- 当前 agent 的 working/thinking 状态。

交付物：

- 无论 session 有 100 条还是 100,000 条事件，点击只读取一个最多 16 行的页面。
- 页面先按 agent 归属定位，再分页，不会错误地先取 session 最后 16 行。
- 点击不读取或 replay EventLog。

### 阶段 D：拆开全局状态与当前对话的发布

当前 CoworkViewModel 会发布完整 [CodeItem]。我会把展示热路径拆成：

- session 全局状态：roster、Goal、Tasks、Permission、agent counters。
- 当前窗口 selected-agent 的 bounded thread page。

只有当前被查看 agent 的消息变化，才允许发布中间线程页面。未选中的 agent 可以更新右侧运行状态，但不得触发当前 transcript 的正文发布。

交付物：

- agent A 流式输出时，查看 agent B 的中间线程不会反复重新求值。
- canonical EventLog 和 projection 仍精确接收所有事件。
- UI presentation 通知可以合并为最新状态，但 canonical event stream 不丢事件。

### 阶段 E：把右侧 Agents 状态行变成查看入口

修改 Cowork 右侧 compact status rail：

- 普通 agent 行成为可点击 Button，保留现有图标、名称、状态与 inference 提示。
- 增加 selected、hover、pressed 和键盘焦点语义。
- 使用稳定 agent ID 和 accessibility identifier。
- main 在窗口首次出现时显式成为 viewed agent。
- reviewer 保持 status-only。

我会把“当前查看对象”收敛为窗口内唯一来源，避免右侧选中态、中间线程和其他 agent 卡片各自维护不同 ID。

交付物：

- 鼠标点击、键盘激活和辅助功能操作都能选择 agent。
- 选中状态与中间线程始终一致。
- roster 重新排序不会改变当前选择。

### 阶段 F：接入中间线程切换生命周期

中间线程的 presentation scope 会包含：

- session identity。
- viewed agent identity。
- history page identity。

一次切换执行：

1. 立即更新 viewedAgentID 和 selection generation。
2. 取消旧 agent 的页面请求和 transcript subscription。
3. 让旧线程 onDisappear，停用 scroll coordinator、raw/rich dwell 和旧 publication。
4. 请求新 agent 的最多 16 行页面。
5. 核对 generation 后挂载 raw page。
6. 页面 idle 后再按现有规则进入 Markdown rich rendering。

不增加内容 crossfade，不同时挂载旧、新两棵富文本线程，不为每个 agent 保留隐藏 Tab。

交付物：

- 快速 A→B→C 切换后，最终只显示 C。
- A/B 的迟到页面、scroll callback 或 Markdown 结果不能写进 C。
- 同一窗口始终只有一棵可见 transcript tree。

### 阶段 G：补齐分页、实时状态和异常处理

- 每个 agent 保存独立 requestedUpperBound。
- Latest 页才显示该 agent 自己的 thinking/live follow。
- Earlier 页收到新消息时保持 upperBound，不自动跳到底。
- 点击 Latest、Send 和对应 agent 的 Retry 时按既有产品规则回到适当最新页。
- selected agent detach 时原子回退 main。
- session 切换、窗口关闭和 app shutdown 继续服从现有 AppSessionRuntimeManager 生命周期。

交付物：

- 多 agent 历史分页互不串页。
- 其他 agent 的 runningCount 不会让当前 agent 错误出现 thinking row。
- 切换查看对象不会停止或重启 runtime。

### 阶段 H：测试、性能验收和文档回写

完成单元、集成、GUI 和长时间压力验证后，再更新项目状态文档。

需要回写：

- docs/CURRENT_STATE.md。
- docs/ARCHITECTURE.md。
- docs/DO_NOT_BREAK.md。
- docs/TESTING.md。
- 必要时更新 docs/PROJECT_MAP.md。
- 新增最终实现与验证报告。

交付物：

- 功能行为、数据归属、性能边界和回归门成为项目正式合同。

## 5. 预计修改哪些代码

以下是后续实施范围，不是本轮已修改文件。

### Conversation / Projection

- Packages/IntatisConversation/Sources/CodeProjection.swift
  - 保留 typed agent attribution。
  - 增加 message/tool 快速索引。
  - 消除长历史中的高频 firstIndex 扫描。

- Packages/IntatisConversation/Sources/SessionProjectionPump.swift
  - 增量维护 per-agent thread index。
  - 提供 bounded page snapshot。
  - 将 selected transcript 更新与其他 projection domain 分开。

- 可能新增 CoworkAgentThreadIndex / CoworkAgentThreadPage 等内部类型文件。

### macOS presentation

- Apps/IntatisMac/Sources/CoworkViewModel.swift
  - 管理 session store 接入。
  - 提供窗口所需的 bounded page 和 selected-agent working 状态。
  - 避免完整 items 作为高频 Cowork transcript 发布面。

- Apps/IntatisMac/Sources/IntatisMacApp.swift
  - 将新的 presentation model/page 输入传给 CoworkShell。
  - 保持 runtime ownership 不变。

### Shared UI

- Packages/IntatisSharedUI/Sources/CoworkViews.swift
  - 右侧 agent row 点击和选中样式。
  - 默认 main。
  - 中间线程绑定 viewed agent 的 bounded page。
  - detach fallback、selected-agent thinking 和 accessibility。

- Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift
  - 确保 scope 包含 agent/page identity。
  - 继续使用最多 16 行 eager page。

- MessageRendering 文件原则上只复用现有 lifecycle/generation，不为本功能新增 renderer cache。

### Tests / Fixtures

- Conversation projection/index 单元测试。
- Session projection pump/page store 测试。
- SharedUI selection、paging、scope 和 stale generation 测试。
- macOS 多窗口/session lifecycle 集成测试。
- production renderer/CoworkShell 性能 fixture。

预计不需要改变：

- EventLog Envelope schema。
- 旧 JSONL 的解码合同。
- AgentLoop、MessageBus 或 scheduler 的编排模型。
- CapabilityLease、WorkspaceLease 和 PermissionEngine。
- composer 默认路由。
- iOS Chat 子集。

## 6. 具体测试清单

### 6.1 数据归属测试

- 默认 user_message 进入 main。
- 明确 @worker 的 user_message 只进入 worker。
- message_delta/completed 进入 payload.agent。
- tool_result 正确跟随 toolCallID。
- A2A 消息同时出现在 from/to，对应正文只保存一次。
- 无法归属的 legacy error 留在全局，不猜测。
- agent 重命名或 roster 重排不破坏历史归属。

### 6.2 页面测试

- 0、1、16、17、1,000 条 agent 消息的分页边界。
- Earlier / Newer / Latest 正确。
- 旧页 append 后 upperBound 不变。
- 先按 agent 定位再分页。
- 页面返回行数永远不超过 16。

### 6.3 UI 行为测试

- 初次打开明确选中 main。
- 点击普通 agent 后选中样式和中间线程一致。
- reviewer 不可作为普通查看目标。
- 快速 A→B→C 最终只显示 C。
- selected agent detach 后回到 main。
- 点击查看 worker 不改变 composer 默认 main 路由。
- 键盘和 VoiceOver 可识别 agent 行的按钮、状态与选中值。

### 6.4 生命周期测试

- 切换后旧 scroll callback 不生效。
- 切换后旧 raw/rich publication 不生效。
- 窗口关闭不停止 session runtime。
- 两个窗口可以查看同一 session 的不同 agent。
- session 删除仍先 drain exact runtime，并让窗口退出详情。

### 6.5 性能测试

执行配套性能报告中定义的：

- 8 个普通 agent。
- 每 agent 至少 1,000 个展示 item。
- 并发流式 burst。
- 1,000 次快速切换。
- 至少 180 秒单实例 soak。
- heartbeat、Hangs、Time Profiler、RSS/footprint 和 stale publication 检查。

## 7. 完成标准

只有同时满足下面各项，功能才算完成。

### 用户体验完成

- 打开 Cowork 默认看到 main。
- 右侧普通 agent 都可以点击。
- 点击后立即知道当前选中了谁。
- 中间只显示该 agent 的工作对话。
- 可以来回切换和翻阅各自历史。
- 其他 agent 继续正常工作。
- agent 被移除时不会留在空白或错误线程。

### 数据正确完成

- agent 对话归属来自 typed event identity。
- 旧 session replay 后也能正确切换。
- A2A、tool result、user target 和 main fallback 有自动测试。
- 不改变 EventLog canonical truth 和旧事件兼容。

### 生命周期完成

- runtime 与 presentation 保持分离。
- 每窗口选择独立。
- 旧 scope 结果全部被 generation 围栏拒绝。
- renderer onDisappear/deactivate 合同保持有效。

### 性能完成

- 点击和页面查询成本不随总历史线性增长。
- UI 一次只接收并挂载最多 16 行。
- 未选中 agent 的 delta 不发布当前 transcript。
- 同窗口不保留多棵 agent 富文本树。
- 快速切换、长时间 soak 无 heartbeat warning、无 hang、无持续单核 CPU。
- settled memory 随切换次数平台化。

### 项目完成

- 相关单元、集成、GUI 和性能验证通过。
- CURRENT_STATE、ARCHITECTURE、DO_NOT_BREAK、TESTING 已同步。
- 没有改变 iOS 平台边界、权限链或 agent 编排原则。

## 8. 明确不做的事情

首版不做：

- All Agents 聚合对话入口。
- 点击查看谁就自动把 composer 改发给谁。
- 每个 agent 的隐藏预渲染线程。
- transcript crossfade 或复杂转场。
- completed-document、native-view、message-height cache。
- EventLog schema 迁移。
- agent runtime 暂停/恢复逻辑调整。
- scheduler、mailbox、permission 或 capability 模型改造。
- iOS Cowork。

这样可以把本次交付严格限定为“安全、流畅地查看某个 agent 的工作”。

## 9. 实施后的完整使用示例

1. 用户进入 Cowork session。
2. 页面明确选中 @main，中间显示 main 最新 16 行。
3. @research 和 @writer 同时在后台工作，右侧状态继续变化。
4. 用户点击 @research。
5. @research 立即高亮，中间切到 research 最新页；writer 的 token 不让该页面重建。
6. 用户点 Earlier 查看 research 的旧工作。
7. 用户点击 @writer，看到 writer 最新页。
8. 用户再点 @research，回到 research 刚才的历史页位置。
9. 用户点 Latest，恢复 research 的实时跟随。
10. 用户输入普通消息，仍按现有规则发给 main；如需 research，显式使用 @research。
11. research 被移除时，窗口取消其旧任务并回到 @main。
12. 整个过程中其他 agent runtime 没有因查看切换而停止或重启。

## 10. MODEL_CHECK_RESULT

当前为 GPT-5 系列 Codex agent；无法从运行环境确认更精确的模型构建号。

## 11. PATH_CHECK_RESULT

- pwd：/Users/vita/Vitemis/Intatis
- Git root：/Users/vita/Vitemis/Intatis
- 路径匹配。

## 12. FILES_WRITTEN

本轮只新增：

- codex-report/08_03_26-22_14-cowork-agent-conversation-switch-implementation-plan.md

保留且未修改：

- codex-report/08_03_26-22_08-cowork-agent-thread-switch-performance-report.md

未修改任何业务源码、配置、测试或构建脚本。

## 13. VALIDATION_RESULT

- git diff --check：通过，exit 0。
- 新报告尾随空白扫描：无匹配。
- git status --short：只显示两份本任务报告为未跟踪文件，没有业务源码或其他文件改动。
- 文件时间与范围核对：上一份性能报告的修改时间早于本轮开始时间，本轮没有修改它。
- 本轮是文档计划任务，未运行构建或测试。

## 14. UNCERTAINTIES

- “切回 agent 时恢复其旧页”是本计划采用的默认交互；如果产品更希望每次都强制 Latest，可以在实施前调整为更简单的规则。
- 首版不提供 All Agents 聚合视图；若仍需保留当前全量混合线程作为入口，需要用户另行确认它在导航中的位置。
- legacy error/tool_result 若缺少可验证 correlation，只能保持 session-global；具体比例需要用真实旧 session fixture replay 后确认。
- 最终 raw first-paint 和 memory slope 数值以配套性能报告 Phase 0 冻结的参考机结果为准。

## 15. NEXT_RECOMMENDED_ACTION

如果认可这份功能形态，下一步从阶段 A 开始：只建立 fixture、诊断和基线，不直接修改右侧点击。基线冻结后再进入 typed attribution、bounded page store 和 UI 接入。
