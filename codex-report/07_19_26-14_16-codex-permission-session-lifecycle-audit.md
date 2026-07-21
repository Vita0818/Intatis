# Intatis 采用 OpenAI Codex 作为会话存储、权限与多 Agent 推理配置模板的源码审计报告

原始日期：2026-07-19；讨论与实施状态最后更新：2026-07-20

性质：源码审计、讨论结论、Phase S / Phase A / Phase B / Phase T / Phase C 实施状态与后续方案

上游基线：OpenAI Codex commit [`0fb559f0f6e231a88ac02ea002d3ecd248e2b515`](https://github.com/openai/codex/tree/0fb559f0f6e231a88ac02ea002d3ecd248e2b515)

Task/tool outcome 补充审计基线：OpenCode [`a19b52e85bf2630b86157030e2cf7c9fc20ce552`](https://github.com/anomalyco/opencode/tree/a19b52e85bf2630b86157030e2cf7c9fc20ce552)、OpenAI Codex [`bf3c1972b7d045c0a3a48dff91f381070f8f69e1`](https://github.com/openai/codex/tree/bf3c1972b7d045c0a3a48dff91f381070f8f69e1)；Claude Code 只采用官方公开 task/agent/hook 行为，核心 runtime 没有可复制的完整开源实现。

## MODEL_CHECK_RESULT

当前执行环境为 Codex / GPT-5 系列 Agent；本地环境无法读取或独立验证更精确的服务端 deployment 标识。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 结论：当前目录与预期仓库根目录一致。

## FILES_WRITTEN

- 本报告：`codex-report/07_19_26-14_16-codex-permission-session-lifecycle-audit.md`
- 同步更新项目常驻文档：`AGENTS.md`、`docs/CURRENT_STATE.md`、`PROJECT_MAP.md`、`ARCHITECTURE.md`、`DO_NOT_BREAK.md`、`TESTING.md`、`NEXT_TARGET.md` 与 `COWORK_PRINCIPLES.md`。
- Phase S 修改了 IntatisProtocol、IntatisConversation、IntatisCore、IntatisCowork、macOS App 与 CLI 的相关业务源码。
- Phase A 继续修改了提交协议、EventLog/投影、Cowork runtime、macOS composer/附件入口与相应测试，并新增 owner-only submitted-intent outbox。
- Phase B 修改了 permission reviewer 控制面、生产 provider resolution、CLI 状态文案、provider stream 契约与相应的并发/集成/legacy-decode 测试；完整文件清单以本轮 Git diff 和项目最终报告为准。
- Phase T 修改了 tool execution settlement 协议与投影、AgentLoop no-effect error path、`task_update` stale conversion、Orchestrator legacy reconciliation、Goal startup 的最小 task scope，以及相应协议/AgentKernel/Conversation/Cowork 测试。
- Phase C 修改了 permission/tool/turn outcome 协议、EventLog RequestID first-write/first-terminal transaction、PermissionProjection/CodeProjection、ChatLoop/AgentLoop、review control-plane duplicate/reconnect ownership、GUI/CLI 人工动作、sandbox startup denial 分类、structured timeout/cancel cleanup，并新增 DEBUG-only 离线 permission fixture 与相应协议/Conversation/AgentKernel/Cowork/Tools 测试。
- 本轮没有 add、commit、push 或创建 PR。

## SUMMARY

本轮调研的核心结论是：**Intatis 应把 OpenAI Codex 当作全局配置与 session 存储分层、输入提交、权限审批、工具调用和取消语义的公开源码模板，但不应整体移植其 Rust runtime，也不应丢弃 Intatis 已经更强的 EventLog、durable tool execution 与 per-agent inference profile 设计。**

截至本报告本次更新，**Phase S、Phase A、Phase B、Phase T、Phase C 与 Phase L 均已完成各自当前范围的源码实施**。Phase S 解决“同一 session 的设置、Agent 登记、workspace access 与运行历史分散、无法由 session 目录可靠重建”；Phase A 解决“本地编辑/发送被 reviewer、Goal、主 Agent 和运行状态错误锁住，以及提交失败后内容可能没有明确 durable 身份”；Phase B 解决“一次 permission-review provider timeout/cancel 会把后续审批隔离到进程重启”；Phase T 解决“`task_update` 已知 stale/no-effect 失败被错误当成未知写入，留下永不 settled 的 ticket，并由 Goal startup 再升级成 session 级停摆”；Phase C 解决“Decline/Cancel 混成一个布尔值、permission duplicate/terminal 缺少 durable CAS、turn/tool failure 依赖文本推断、取消可能早于 cleanup 返回，以及 sandbox denial 被误当普通 runtime 或自动重试”；Phase L 解决“窗口/session 切换隐式停止 runtime、Command-Q 缺少全局有界关停、冷启动 active Goal 自动续跑，以及 crash/reopen 没有统一 reconcile-only 语义”。这些都不是把产品改成 Codex runtime 的外壳：Intatis 仍拥有 Swift UI、EventLog、Agent runtime、三层权限门、sandbox、lease 与工具执行。实现依据是公开行为契约和 Intatis 现有架构；没有复制 OpenCode/Codex 源文件、测试、prompt、UI 或品牌资产，也没有引入新的第三方依赖。

Phase C 完成后的权限与 turn 关系为：每个新 Chat/Code/Cowork turn 使用稳定 `TurnID` 并写入 typed terminal `turn_outcome`；permission request 携带 approval mode、turn/tool-call/request/authorization correlation。`EventLog.registerPermissionRequest` 对 RequestID first-write-wins，`settlePermissionRequest` 在 complete-known history 与跨进程锁内执行 first-terminal CAS；exact duplicate/reconnect 幂等复用首记录，冲突 payload、identity、action/decision 或 terminal fail closed。人工 `Approve Call` 允许当前 call，`Decline Call` 只写 typed denied tool result 并让模型继续，`Cancel Turn` 则 durable settle 后中断整个 turn，不制造“用户拒绝”的假 tool result。automatic request 从通用 request 投影开始即不可人工操作。user/policy/reviewer/sandbox/runtime/cancel 具有机器可读来源；只有可信 wrapper 证明目标未开始的 sandbox startup denial 才结算 `sandbox_denied/not_started`，当前不自动 retry 或移除 sandbox。provider/tool child 必须在 task/turn terminal 和 caller return 前完成 cancel/drain。

Phase T 完成后的核心边界是：静态 `write` 分类只决定默认保守程度，不再替代具体调用 outcome。一个 `executionID` 只能对应首张 prepare；任何重复 prepare（即使 payload 相同）都会永久标记 ambiguous 并保留首张。完全相同的 duplicate settlement 幂等保留首条，冲突 terminal 则永久 ambiguous；`succeeded + not_started` 也是无效组合并按 uncertain 处理。新的成功执行显式写 `.committed`，旧日志中的 `succeeded + nil` 只作为兼容的“已完成效果”解释。只有 production Orchestrator adapter 对 exact task / expected revision / actual revision 都匹配的 `task_update.stale_revision` 才能声明 typed no-effect；任意其他 manager、普通 timeout、executor 内 cancel、网络/进程/协作写入 error 都不能使用该证明。prepare 后、executor 前观察到 cancellation 时会先写 `cancelled/not_started`，但仍抛出取消并中断本轮。旧日志修复只在没有 current Goal、ticket 仍是 exact current record、从未出现任何 settlement、durable history 不 ambiguous、expected revision 是 JSON safe integer、唯一非空 task resource 与 typed intent 可验证，且 prepare 前 projection 已证明 `actualRevision > expectedRevision` 时发生。restore/legacy repair、Goal startup、显式 Goal launch 和 whole-task retry一律使用 `replayForProjectionChecked().hasCompleteKnownHistory`；unknown future event 或 `seq` gap 都不能支撑 absence/order proof，必须 fail closed。没有 current Goal 时，也只有这份 complete-known history 能证明 exact contract 先于 prepare、正数 attempt 精确一致、对应 terminal event 晚于 prepare的 uncertain ticket，才不会阻断整个 session 的普通新工作；同一 task 仍禁止重放。任何 current Goal 都不运行旧 ticket 修复，遇到 uncertain ticket继续 fail closed；Phase L 后冷启动只对账并 durable pause，不会借恢复自动创建 continuation。

Phase B 完成后的权限审查关系为：

- 每个 review dispatch 都分配 `{reviewTaskID, nonce}` 组成的进程内 generation；production Orchestrator 按冻结的 reviewer identity 与 exact inference binding 为每一代重新解析一个 provider wrapper。
- provider 与 timeout 在 exact-generation 的 request-scoped race 中竞争；caller cancel 可以终结当前 race，并由独立的同步 cancellation token、actor cancellation path、caller-task post-await fence 与下游 admission fence 共同兜底。只有匹配 generation 的首个 terminal result 可获胜；旧代的迟到或重复输出没有 EventLog、health 或 authorization 能力。
- timeout 或 caller cancel 只影响当前 permission action/call；若已进入 provider dispatch，就 retire 当前 active generation。pre-submit caller cancel 直接返回 typed deny，不创建伪造的 review lifecycle；已登记 review 的取消在 terminal claim 前被观察到时 settlement 为 deny，在 claim 后才到达时唯一 reviewer verdict 可保留，但最终 authorization delivery 仍为 deny。下一次 review 可立即使用 fresh generation，无需重启 App、重开 session 或切换人工模式。
- `allow` 仍以 `permission_review_settled` 成功落盘为提交点；若 terminal claim 后、settled append 返回前发生 cancel/quiesce，durable reviewer verdict 与最终 authorization delivery 是两层状态：日志可保留唯一 reviewer verdict，但调用方得到 deny，工具不执行，也不会写第二个 settlement。
- 旧 JSONL 中的 `provider_still_stopping` 继续兼容解码，但不再是 permission reviewer 的当前运行时恢复路径。Goal Verifier 仍有自己的隔离实现，属于另一个控制面，不在 Phase B 授权范围内。

Phase A 完成后的输入关系为：

- 草稿编辑始终是本地 UI 行为；reviewer failed、Goal active、主 Agent unresolved、pending permission 或已有任务运行都不会禁用 Cowork 输入框。
- 点击 Send 先冻结文本、附件、目标和可选 Goal 元数据，分配稳定 `SubmissionID`，再写入 session EventLog；EventLog 临时不可写时使用 session-owned、owner-only 的可见 outbox，只有两处都无法保存时才保留原草稿并报告失败。
- canonical admission 以同一 transaction 写入唯一 `user_message` 与 attempt 1 的 `queued`；后续状态只能按 one-based attempt 单调演进。retry 复用同一 submission 和 root task，不再插入第二条用户消息。
- 远端执行按 FIFO drain。route、attachment、credential/provider/runtime 等问题成为提交卡片上的 queued/failed/retryable 状态，不再作为输入框或 Send 的硬门；普通主模型请求也不再等待 reviewer ready，只有真实 ask-class tool 会因 reviewer 不可用而 fail closed。
- 历史进程遗留的 queued/running root task 打开后保持 paused/interrupted，必须由用户显式 Retry。Phase L 又把历史 **active Goal** 改为 reconcile-only startup：完成恢复/checkpoint/audit 后 durable pause（达到预算则 budget-limited），只有用户显式 Resume 才继续。

Phase S 完成后的权威关系为：

- provider/model/endpoint catalog 与 credential 仍是全局配置；secret 不进入 session。
- `events.jsonl` 是 session 的唯一 canonical truth；`session.json` 是可删除、可重建、经过 canonical fold 校验的 schema 2 投影。
- Cowork 的完整 session settings、当前 Agent 登记、workspace/capability lease 摘要和迁移标记由 EventLog 重建；Chat/Code 只共享 session display-name 投影，不被误扩成 Cowork 的完整 roster/settings 模型。
- Code 与 Cowork 的 security-scoped workspace access 由各自 session 的 `workspace-access.plist` schema 1 二进制文件保存，文件权限为 owner-only `0600`；bookmark 原始字节不写入 EventLog 或 `session.json`。
- 新 Cowork session 以一个严格的七事件 batch 同时登记 settings、main 和 `@permission-reviewer`；两者初始使用同一精确 inference binding，但 identity/lease 独立，登记过程不发任何模型 API 请求。

针对最初“历史 session 无法编辑、权限全部失败、应用表现为卡住”的问题，审计确认了两个可能参与事故的高风险路径，但尚未证明事故发生时具体是哪一个 predicate 或 request 首先生效。这里必须按阶段读：第 1 条是 **Phase A 修改前**的输入链路，现已移除；第 2 条是 **Phase B 修改前**的 reviewer 隔离路径，也已替换：

1. Phase A 前，Intatis 的本地文本编辑受自动权限 reviewer、Goal recovery、主 Agent inference、live pending permission 和工作状态共同 gating；这些条件中的某些状态会直接禁用 `TextField`。Phase A 后，共享 Cowork composer 固定保持可编辑，这条不再是当前行为。
2. Phase B 前，自动 reviewer 在已经取得 `providerActivity` 后，如果底层 provider call timeout 或 cancel，会保留同一 session 的 activity 标记并隔离到进程重启；后续 review 返回 `previousCallStillStopping`。Phase B 已移除这条进程级 registry/runtime 路径，改为 generation retirement、fresh provider resolution 和 late-result guard。

后续讨论又确认了三个与故障修复相关、但根因不同的边界：

3. “登记 Agent”只是把身份、工作目录、精确模型 binding、工具与权限范围写入本地 session；它不是启动远端 Agent，也不应产生模型 API 请求。主 Agent 与权限审查者可以在新 session 创建时同时登记，初始使用相同的精确模型配置，但 reviewer 仍保持无工具、只读和独立安全身份。
4. Intatis 当前把全局 provider 配置、UI selection、compiled inference catalog、Cowork session settings、workspace bookmark、EventLog 与 session metadata 分散在 JSON/JSONC、UserDefaults 和 session 目录。Codex 的成熟做法是把全局配置/秘密、每个 session 的 canonical JSONL、可重建 SQLite 投影严格分层；Intatis 应采用这一职责划分，同时保留已有 JSON/JSONC、EventLog Envelope、`seq` 和“一 session 一目录”的 Apple-first 结构。
5. 审计时切换 Cowork session 会停止原 view model 和 runtime，但产品预期是应用仍在运行时只切换页面/session 不停止后台任务；Command-Q 才统一停止，正常重开应只对账而不自动继续。Phase L 已以应用级 runtime ownership 独立实施该语义，没有混入输入、权限或存储阶段；历史 active Goal 的启动自动续跑也已改为 durable pause + 显式 Resume。

但需要严格区分：

- 上述两条是审计时从旧源码证实的故障路径，不等同于已经还原本次事故因果链；composer gating 已由 Phase A 修正，permission-reviewer process-lifetime quarantine 已由 Phase B 替换。
- 本次实际事故究竟由哪一个 review request 首先 timeout/cancel，尚未用该 session 的运行日志精确定位，因此不能把具体首发请求写成定论。

Codex 的关键边界则非常清楚：

- 用户输入的 admission 不依赖 reviewer readiness；已有 regular turn 活跃时，新输入也可能被 steer 进当前 turn，而不是创建第二个 turn。
- reviewer 是工具越权边界上的内部子会话：Responses WebSocket 开启时可以后台预热，否则在首次审批时懒创建。
- 单次 reviewer 故障通常只 fail closed 当前 tool call；达到 rejection circuit-breaker 阈值时可以中断当前 turn，但不会把整个 session 永久隔离。
- `Decline` 只拒绝当前工具调用，模型收到失败 tool result 后可以继续；`Cancel` 中断整个当前 turn，不能伪装成普通拒绝结果。
- composer 草稿属于本地 UI 状态，审批弹层只临时覆盖显示，不销毁草稿，也不把 reviewer 健康度作为编辑前置条件。
- pending approval 使用稳定 correlation ID，先登记再发出，首个 terminal response 获胜，迟到或重复响应被忽略，turn 切换时按严格顺序清理。

本报告在讨论后进一步收紧了输入边界：**不仅编辑不等待 reviewer，用户点击 Send 也不应以 reviewer、Goal、主 Agent、provider 预热或网络 readiness 为 UI 前置条件。**点击 Send 表示先冻结文本/附件并接受本地提交意图；随后才做本地 EventLog 验证、session 状态重建、exact inference resolution 与 API dispatch。若执行条件不满足，提交内容必须保留为明确的待执行/失败状态并允许重试，不能静默丢失，也不能要求用户重新输入。

在原始目标——同一 session 内不同 Agent 使用不同模型、思考强度、上游和未来不同 endpoint——上，当前 Codex 已经提供了重要的参考实现：child 可指定 model、reasoning effort、service tier；named role 可以覆盖完整 provider 配置，包括不同 provider/base URL/wire API。与此同时，Intatis 现有的 immutable `AgentInferenceBinding`、connection/profile revision、secret-free EventLog identity，以及 strict production runtime 的 reviewer 独立 binding，比 Codex 更适合该目标，应保留并继续完善，而不是退回到 Codex 的 parent-provider 继承模型。

## 0. 讨论后重新划分的问题：相关，但不是同一件事

我们讨论中反复碰到的是同一片 session / Cowork 状态代码，因此看起来像“都在改同一个方面”；实际上至少有四个不同问题，授权范围和验收方式不能混写：

| 阶段 | 原问题 | 新做法 | 本报告状态 |
|---|---|---|---|
| Phase S | 设置、Agent 登记、workspace capability、历史事件分散，恢复时要从多个隐式位置猜 | 全局 provider/credential 继续全局；session 设置、登记与运行状态以 EventLog 为权威，bookmark capability 单独 session-owned | 已实施 |
| Phase A | reviewer/Goal/main/permission/working 状态直接锁住输入框或阻止 Send，错误路径可能 silent return/丢草稿 | 编辑永远本地；Send 先冻结并 durable accept `SubmissionID`，随后 FIFO 执行；失败显示在同一提交上并显式 Retry | 已实施（Cowork 输入链路） |
| Phase B | reviewer provider timeout/cancel 可能把同 session 隔离到整个进程重启 | request/generation scoped 隔离、fresh provider resolution、late result guard、只 deny 当前 ask-class tool | 已实施 |
| Phase T | 已知 pre-effect `task_update.stale_revision` 被工具级 write policy 误判为未知副作用，ticket 未 settled；Goal startup 又把历史 task ticket 升级为 session gate | 单 prepare/一致 terminal 投影；成功显式 committed；production adapter 的 exact stale 证明回灌 typed no-effect；legacy repair 与 task-local isolation 只接受 complete-known history | 已实施（ambiguous/unknown history 与 current Goal 均 fail closed） |
| Phase L | view 切换会 stop runtime；正常退出、crash、重开和后台多 session 的 ownership 不符合产品预期；active Goal 仍有启动续跑例外 | app-level session runtime manager；窗口只持有选择；切换/Command-W 不停止，Command-Q bounded stop，重开只对账且不自动继续 | 已实施 |

“登记”在本文中只表示写入本地 session 事实，例如工作目录、精确模型 binding、工具/权限范围与 Agent 身份；它不表示唤醒远端对象，也不应产生 API 请求。为避免误解，本文不再用“挂载”描述这个动作。

因此，Phase S 与 Phase A 确实相关：二者都需要可靠 session identity 和 EventLog；但 Phase S 解决“事实保存在哪里”，Phase A 解决“用户输入何时被接受、何时才允许远端执行”。Phase B 解决权限审查请求自身的故障隔离，Phase T 解决具体 tool execution outcome 的结算与作用域，Phase L 才解决进程和多 session 生命周期。把这些合并成一次大换 runtime，既扩大风险，也会让完成状态无法验证。

## 1. 调研范围、方法与证据等级

### 1.1 范围

本报告回答十类问题：

1. Codex 如何划分 session、turn、composer、reviewer 和 tool execution 的生命周期。
2. Codex 如何处理 permission approval、sandbox escalation、decline、cancel、timeout、重连和迟到响应。
3. Codex 如何在同一父 session 下为不同 child Agent 选择不同 model、reasoning、service tier、provider 与 endpoint。
4. Codex 如何分离全局配置、凭据、session canonical JSONL 与可重建 SQLite state，Intatis 当前存储分散在哪里。
5. Intatis 当前实现与这些成熟契约的差异，以及最小风险的修正顺序。
6. Phase S 已经实施的 session 存储、迁移、历史恢复边界与验证结果。
7. Phase A 已经实施的 Cowork 草稿编辑、submitted-intent admission、附件保存、FIFO 执行、历史 interrupted 展示与显式 retry 边界。
8. Phase B 已经实施的 permission-review request generation、provider producer ownership、timeout/cancel retirement、late-result rejection、fresh retry 与 durable authorization delivery 边界。
9. Phase T 已经实施的 task/tool error terminality、no-effect 证明、whole-task retry、legacy ticket reconciliation 与 session/Goal startup 作用域。
10. Phase L 已经实施的应用级 exact-session runtime ownership、窗口/session 切换、Command-Q bounded shutdown、冷启动 active-Goal pause 与 crash/reopen 对账边界。

本轮没有尝试复制任何产品 UI，也没有使用泄露或私有源码。原 session/reviewer 审计仍固定到 Codex `0fb559f0...`；Phase T 另行固定并直接阅读 OpenCode `a19b52e...` 与 Codex `bf3c197...` 的公开源码。Claude Code 核心 runtime 不完整开源，只使用其官方 Agent Teams/Subagents/Hooks 等公开行为契约，不能写成源码事实。

### 1.2 证据标签

| 标签 | 含义 |
|---|---|
| 已证实 | 当前固定 commit 或 Intatis 当前工作树中存在明确源码/测试证据 |
| 已实现 | Phase S / Phase A / Phase B / Phase T / Phase C / Phase L 当前工作树中已有实现，并由各阶段记录的测试、构建或 Computer Use 结果验证 |
| 推断 | 由已证实代码路径推导，但尚未由本次事故日志还原具体触发序列 |
| 建议 | 面向 Intatis 的目标设计，不代表已经实现 |

### 1.3 方法限制

- 本轮没有编译或运行 OpenAI Codex；上游内容只用于公开行为契约审计。
- Phase S、Phase A、Phase C 与 Phase L 均有各自的测试、构建和 Computer Use 记录，具体见 `VALIDATION_RESULT`；Phase B/T 的证据边界也分别记录。没有运行真实 provider 请求。Phase S UI 轮使用测试 session/workspace；Phase A UI 轮有意在历史验证 session `cowork_1p6ky6ga` 追加一条本地测试提交及其 queued/failed 状态；Phase L 只使用 `/private/tmp` synthetic ledger，不读取或改写生产 session。
- 原 session/reviewer 审计中的 Codex 链接固定到 commit `0fb559f0f6e231a88ac02ea002d3ecd248e2b515`；Phase T 的 Codex task/outcome 链接另固定到 commit `bf3c1972b7d045c0a3a48dff91f381070f8f69e1`。二者不能混称为同一审计基线，后续上游行为也可能变化。
- Phase T 的 task/tool outcome 链接另固定到 OpenCode `a19b52e85bf2630b86157030e2cf7c9fc20ce552` 与 Codex `bf3c1972b7d045c0a3a48dff91f381070f8f69e1`；两份 checkout 只用于读取/对照，没有参与 Intatis 构建。Claude Code 部分没有把公开 repository 外壳或文档冒充核心实现源码。
- Intatis 文件行号以 2026-07-20 当前工作树为准；各 Phase 实现状态以本报告更新时的当前工作树和分阶段验证记录为准。Phase T 自身最终 hardening 执行六个相关 suite 共 128 tests / 0 failures，随后 `swift build --disable-sandbox` 成功；Phase L 后续又完成独立 full SwiftPM、macOS/iOS build 与 Computer Use，但仍没有运行真实 provider 或真实 legacy session mutation 演练。
- 本轮根据后续讨论补充读取了当前 Codex 官方手册的 config/state 章节，并以固定 commit 源码核对实际落盘实现；没有继续扩展到 Gemini CLI。
- 多 session 后台常驻、页面切换、关闭窗口、正常 Command-Q 与 crash/force-quit 的应用生命周期一直作为相关但独立的 Phase L 授权实施；它没有被混写成 Phase A 的提交级围栏。Phase L 当前源码和离线验收已完成，真实 provider/server cancellation 与生产数据 process-kill 边界仍单独标为未验证。

## 2. 总体架构判断：采用行为契约，不移植整套 runtime

推荐把 Codex 当作以下状态机的参考：

```text
local draft editing
  → user submits local intent
  → persist or visibly retain the submitted text/attachments
  → rebuild/validate local session execution state
  → resolve the exact main-agent route
  → main API request starts
  → model requests tool
  → deterministic policy gate
  → optional reviewer / user approval
  → sandboxed execution
  → tool result returns to the same turn
  → turn completes or is explicitly cancelled
```

这里最重要的不是 Rust 类型或某个具体函数，而是各层之间的独立性：

- 本地 draft 不依赖网络、provider、reviewer 或 runtime。
- 用户能否点击 Send 只依赖本地文本/附件是否构成有效提交；main/Goal/provider readiness 属于提交后的执行状态，不能成为输入面的硬门。
- 普通模型请求不依赖权限 reviewer；reviewer 的本地登记也不等于 reviewer API request。
- reviewer 只在工具调用进入 ask/approval 边界时被需要。
- 一次工具审批失败不应把整个会话永久变成不可用。
- permission outcome、tool execution outcome 与 turn cancellation 是不同事件，不能压成同一个布尔值。

Intatis 不适合整体搬运 Codex runtime，原因包括：

- Intatis 是 Apple-first、Swift-native 多 target 工程。
- Intatis 已经有 append-only EventLog、durable permission requested/settled、durable tool prepare/settle、CapabilityLease、WorkspaceLease、PathConfinement、SecretScanner 和 Mediator 等更严格边界。
- Codex 的部分 approval 协调使用进程内 map/oneshot；这可以参考相关性和清理顺序，但不能替代 Intatis 的持久化语义。
- Intatis 的 per-agent inference identity 已经按 immutable revision 设计，适合本地重建、审计和未来多 endpoint；直接换成 Codex 当前的 live config overlay 会倒退。

## 3. Codex 的 session、turn 与 reviewer 边界

### 3.1 用户输入 admission 不等待 reviewer

Codex 的 `turn_start_inner` 依次完成 thread 加载、输入能力检查、输入大小校验、turn settings 应用和 `Op::UserInput` 提交，然后返回 `TurnStatus::InProgress`。该路径没有 Guardian/reviewer readiness 前置条件。若一个 regular turn 已经活跃，`Op::UserInput` 还可能走 `steer_input` 注入现有 turn；因此这里证实的是“输入请求可独立于 reviewer 被接受”，而不是每次调用都一定创建一个新 turn。

证据：[`turn_processor.rs#L473-L616`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/request_processors/turn_processor.rs#L473-L616)

这意味着 Codex 的基本规则是：**能不能接收普通用户输入，取决于主 thread/turn 能力；能不能批准某个工具，是另一个稍后发生的问题。**

### 3.2 通用 startup prewarm 不构成 turn admission 的硬门

`session_startup_prewarm` 是通用 model/WebSocket startup prewarm；Guardian initialization 只是其中一个 detached `tokio::spawn` 分支，失败只记录 warning，并且在 WebSocket responses 未启用时不会运行该分支。现有测试验证的是 `TurnStarted` 不等待**通用 startup prewarm** 完成，并不是一条专门模拟 reviewer readiness 的测试。

证据：

- [`session_startup_prewarm.rs#L185-L197`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session_startup_prewarm.rs#L185-L197)
- [`session_startup_prewarm.rs#L251-L275`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session_startup_prewarm.rs#L251-L275)
- [`session/tests.rs#L353-L404`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session/tests.rs#L353-L404)

结合 3.1 的输入 admission 路径和 3.3 的 Guardian 按需创建逻辑，可以得出：Guardian prewarm 是首个审批的延迟优化，不应成为 session 本地登记、历史消息展示、composer 编辑或普通输入 admission 的硬门。

### 3.3 Guardian 是可选预热、否则懒创建的受限 review 子会话

Guardian 仅在 approval policy 为 `OnRequest` 或 `Granular`，且 `approvals_reviewer == AutoReview` 时参与路由。

证据：[`guardian/review.rs#L165-L181`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review.rs#L165-L181)

其 review session manager 的关键行为包括：

- 维护一个可缓存 trunk；Responses WebSocket 开启时可以可选后台预热，否则首次 review 按需创建。
- reuse key 覆盖有效 model、provider、config、permissions、cwd 等，配置变化会使旧 trunk 失效。
- trunk 同时只允许一个 review；繁忙时从最近 committed snapshot 创建临时 fork，而不是全局阻塞所有 review。
- prompt cache key 按父 thread 隔离。

证据：

- reuse key：[`guardian/review_session.rs#L153-L205`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review_session.rs#L153-L205)
- prompt cache key：[`guardian/review_session.rs#L209-L221`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review_session.rs#L209-L221)
- trunk 管理：[`guardian/review_session.rs#L299-L490`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review_session.rs#L299-L490)
- ephemeral fork：[`guardian/review_session.rs#L600-L653`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review_session.rs#L600-L653)

Guardian 自身被显著降权：read-only permission profile、approval policy `never`，禁用 MCP、动态 skills/plugin 注入、memories、apps/plugins、collaboration 和 web search，并限制 provider retry。这里“禁用动态 skills”不代表完全不继承父指令：Guardian 会复制父 session 的 `LoadedUserInstructions`。在存在 environment 时，其固定工具白名单是 `exec_command`、`write_stdin` 和 `view_image`；父 exec-policy 不继承，而 managed-network approved hosts 会同步。

Intatis 初期不应照搬 tool-enabled Guardian。当前 no-tools reviewer 与“不允许 reviewer 嵌套 AgentLoop”分别是工具面和执行模型的两个独立安全约束，二者都应保留，不能把其中一个当作另一个的替代。

证据：

- review config：[`guardian/review_session.rs#L993-L1075`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review_session.rs#L993-L1075)
- 父指令继承：[`codex_delegate.rs#L75-L121`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/codex_delegate.rs#L75-L121)
- 工具白名单：[`tools/spec_plan.rs#L578-L604`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/spec_plan.rs#L578-L604)
- exec-policy 隔离：[`session/mod.rs#L536-L557`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session/mod.rs#L536-L557)

### 3.4 单次 reviewer 失败通常只影响当前 action

Guardian 对单次 timeout、解析失败、session/prompt/provider failure 采取 fail closed：当前待审工具调用被拒绝。单次故障不会因此把整个 thread/session 永久锁死。

证据：[`guardian/review.rs#L277-L595`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review.rs#L277-L595)

Guardian 最多尝试三次，并共享一个 90 秒绝对 deadline。只有解析失败和少数带结构化错误码的瞬态 session/provider error 会 retry；缺 assessment payload、普通 provider error、timeout 和 cancel 不 retry。timeout/cancel 会 interrupt 并最多 drain 五秒；drain 失败会丢弃该 trunk，但仍不会永久 quarantine session。

证据：

- retry 规则：[`guardian/review.rs#L879-L951`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review.rs#L879-L951)
- interrupt/drain：[`guardian/review_session.rs#L895-L976`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review_session.rs#L895-L976)

Codex 另有 per-turn circuit breaker：模型明确返回 `deny` 连续三次，或最近 50 次 review 中累计十次，会中断当前 turn。prompt/session/parse fail-closed、timeout 和 cancel 会按 non-denial 记账并重置连续 deny 计数；因此协议层的 denied 结果不等于 breaker 的 model-denial 计数。breaker 状态按 turn 隔离，不是 process-lifetime session quarantine。

证据：

- [`guardian/mod.rs#L47-L133`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/mod.rs#L47-L133)
- [`guardian/review.rs#L375-L523`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review.rs#L375-L523)
- [`guardian/tests.rs#L133-L218`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/tests.rs#L133-L218)

### 3.5 Guardian 输出契约并非严格 schema

Codex 为 Guardian 提供 Responses JSON schema，但 `strict` 明确为 `false`。解析器可以从外围 prose 中提取 JSON，只有 `outcome` 必填；bare `allow` 会默认 low risk/unknown authorization，宿主也没有再次校验 risk 与 outcome 是否一致。这是 Intatis 不应照搬的宽松点：reviewer 输出应保持严格 schema、有限枚举、缺字段 fail closed，并对 allow 进行 authorization snapshot revalidation。

证据：

- non-strict schema：[`session/turn.rs#L1095-L1110`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session/turn.rs#L1095-L1110)
- 解析与默认值：[`guardian/prompt.rs#L585-L683`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/prompt.rs#L585-L683)

## 4. Codex 的 tool approval 与 sandbox 状态机

### 4.1 完整顺序

Codex 的核心流程是：

```text
approval requirement
  → approval hook / Guardian / user decision
  → select sandbox and materialize permissions
  → first execution attempt
  → only exact sandbox denial may request one controlled retry
  → return result to the same call_id
```

证据：[`tools/orchestrator.rs#L136-L497`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/orchestrator.rs#L136-L497)

关键约束：

- deterministic policy 的 `Forbidden` 是当前 call 的终局拒绝。
- approval denied 是当前 call 的拒绝。
- 普通非零退出、timeout 或 setup failure 不会被当成 sandbox escalation 循环。
- 只有被 executor 明确报告、或由 stderr/stdout 关键字启发式分类为 `SandboxErr::Denied` 的失败，才可能进入第二次尝试，且最多一次；这不是完全精确的分类器。
- retry 仍受 policy 约束，但不保证每次重新审批：非 strict 模式下，一个已经批准的调用可以走 `bypass_retry_approval`；strict auto-review 与 network retry 等路径才要求重新 review。

Intatis 应保留当前三层权限门和 durable prepare/settle；应借鉴的是状态顺序、失败作用域和 retry 上限。如果 Intatis 决定所有 retry 都重新跑 reviewer，那是比 Codex 更严格的新契约，必须在测试和用户延迟预期中明确，而不能描述成 Codex 当前行为。

相关证据：

- sandbox denial 启发式：[`sandboxing/denial.rs#L5-L56`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/sandboxing/src/denial.rs#L5-L56)
- retry approval 分支：[`tools/orchestrator.rs#L227-L497`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/orchestrator.rs#L227-L497)

### 4.2 非致命工具失败回灌模型

Codex 把非 fatal tool error 转为同一个 `call_id`、`success=false` 的 tool output，再交回模型继续当前 turn。这是“拒绝工具但不锁死对话”的关键。

证据：

- [`tools/parallel.rs#L75-L89`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/parallel.rs#L75-L89)
- [`tools/parallel.rs#L205-L235`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/parallel.rs#L205-L235)

### 4.3 approval cache 的边界

Codex 只缓存 `ApprovedForSession`；一次性 approve、deny、timeout 和 cancel 不进入 session cache。cache key 包含 environment、规范化 command、cwd、sandbox/additional permissions，避免将不同环境的审批错误复用。

证据：[`tools/sandboxing.rs#L65-L116`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/sandboxing.rs#L65-L116)

## 5. `Decline` 与 `Cancel` 是两个不同的协议动作

这是 Intatis 后续修正中必须建立的显式契约。

| 用户/系统结果 | Codex core 结果 | 作用域 | 后续行为 |
|---|---|---|---|
| Decline | `ReviewDecision::Denied` | 当前 tool call | 产生失败 tool result，模型可继续当前 turn |
| Cancel | `ReviewDecision::Abort` | 当前 turn | 中断 turn，不生成伪造的普通拒绝结果 |
| Reviewer timeout | timed out / denied | 当前 tool call | fail closed，并把失败反馈给模型 |
| Policy forbidden | rejected | 当前 tool call | 不执行，模型看到失败 |

协议与 app-server 映射：

- [`app-server-protocol/item.rs#L57-L99`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L57-L99)
- [`bespoke_event_handling.rs#L1967-L2015`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/bespoke_event_handling.rs#L1967-L2015)
- [`session/handlers.rs#L371-L412`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session/handlers.rs#L371-L412)

已有端到端测试证明：

- Decline 后 command 被标为 declined，但 turn 正常完成：[`turn_start.rs#L2390-L2536`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/tests/suite/v2/turn_start.rs#L2390-L2536)
- Cancel 后 turn 为 interrupted：[`turn_start_zsh_fork.rs#L326-L458`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/tests/suite/v2/turn_start_zsh_fork.rs#L326-L458)

这里的 Cancel 是 approval decision 到 `ReviewDecision::Abort` 的映射。单独的 `turn/interrupt` RPC 还存在终态竞态：请求提交时 turn 可能已经自然完成，因此 pending interrupt 既可能在 `TurnAborted` 上应答，也可能在 `TurnComplete` 上收口；“interrupt 请求被接受”不等于最终状态无条件为 `Interrupted`。证据：[`turn_processor.rs#L1413-L1475`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/request_processors/turn_processor.rs#L1413-L1475)、[`bespoke_event_handling.rs#L184-L199`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/bespoke_event_handling.rs#L184-L199)。

另一个需要显式建模的边界是：Codex unified-exec 会主动保存 live process，使 turn interrupt 不会因最后一个 `Arc` 被释放而自动终止 background terminal process。Intatis 不能把“turn cancelled”误当作“所有外部进程已经停止”，必须依赖 durable execution ticket、明确的 process cancellation/cleanup 与 settled 事件。证据：[`process_manager.rs#L452-L470`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/unified_exec/process_manager.rs#L452-L470)。

Intatis 当前并非只有一个模糊状态：`PermissionApprovalSource`、`PermissionApprovalFailureKind`、`PermissionReviewStatus` 和 `ToolExecutionOutcome` 已经区分 reviewer timeout/cancel/provider failure、持久化失败，以及 execution failed/cancelled/denied；`providerStillStopping` 只为旧 EventLog 兼容解码保留，不再是 permission reviewer live failure。真实缺口主要是 user decline 与 turn cancel 的协议拆分，以及 sandbox denial 与普通 runtime/setup failure 的进一步细分。

建议把现有类型映射到至少以下对外语义，而不是另起一套不兼容枚举：

```text
userDenied
userCancelled
turnCancelled
policyDenied
reviewerTimedOut
reviewerFailed
sandboxDenied
runtimeFailed
```

其中 `userDenied`、`policyDenied`、`reviewerTimedOut`、`reviewerFailed`、`sandboxDenied` 和 `runtimeFailed` 默认都是 call-scoped；`userCancelled` 或 `turnCancelled` 才是 turn-scoped。现有类型证据：`Packages/IntatisProtocol/Sources/ToolAuthorization.swift:424-450`、`Packages/IntatisProtocol/Sources/PermissionReview.swift:280-288`、`Packages/IntatisProtocol/Sources/ToolExecution.swift:33-38`。

## 6. pending approval、断线重连与清理顺序

Codex 并不使用一个 `threadId + turnId + itemId + approvalId + environment` 复合 map key。core waiter 在 active `TurnState` 内以 effective approval ID 为键；app-server callback map 则以 JSON-RPC `RequestId` 为键。`threadId`、`turnId`、`itemId/approvalId` 和 environment 属于请求 payload/routing context，其中 `threadId` 也用于筛选 replay。其成熟点不是“内存 map”本身，而是以下协议约束：

1. request 必须先登记，再发给 UI，避免超快响应先于 waiter 建立。
2. 首个 response 原子获胜；迟到或重复响应只记录，不再次执行工具。
3. app-server 在 `TurnStarted`、`TurnCompleted`、`TurnAborted` 时会取消该 thread 的全部 pending server requests；core waiter 则在 active task abort/收尾后统一释放。
4. interrupt 时先 cancel 并 await tool/turn task，再释放 approval waiter，避免在 `TurnAborted` 之前产生伪 rejection。
5. 在同一个仍存活的 app-server 进程中，只要 callback map 尚在且 thread 仍 loaded/running，客户端断线不会立即丢弃 pending callback，重连并重新显示 thread 时可以重放同一 request。Codex 这里不保证进程重启、cold resume 或 durable recovery。

证据：

- core 先登记后发出：[`session/mod.rs#L2149-L2236`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/session/mod.rs#L2149-L2236)
- app-server 首响应获胜：[`outgoing_message.rs#L287-L423`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/outgoing_message.rs#L287-L423)
- turn transition 清理：[`bespoke_event_handling.rs#L153-L199`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/bespoke_event_handling.rs#L153-L199)
- response 处理：[`bespoke_event_handling.rs#L1940-L2062`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/src/bespoke_event_handling.rs#L1940-L2062)
- abort 清理顺序：[`tasks/mod.rs#L497-L559`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tasks/mod.rs#L497-L559)
- pending approval interrupt 测试：[`turn_interrupt.rs#L223-L349`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/tests/suite/v2/turn_interrupt.rs#L223-L349)
- 同进程 reconnect/replay 测试：[`thread_resume.rs#L3537-L3680`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/app-server/tests/suite/v2/thread_resume.rs#L3537-L3680)

Intatis 应把同样的相关性和幂等约束落在 durable EventLog 上，至少携带 `sessionID + turnID + callID + reviewID/generation`，而不是照搬进程内 map。

## 7. composer 的正确边界

Codex TUI 中 composer 对象一直存在；approval modal 只是临时替代底部显示。用户刚输入时，approval prompt 会延迟到短暂 idle 后再出现，期间按键继续进入 composer；继续输入会重置 deadline。remote resolution 可以删除尚未显示或已埋在 view stack 中的请求，而不会发送新的 cancel/deny。

证据：

- composer 保持存在：[`bottom_pane/mod.rs#L203-L220`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/tui/src/bottom_pane/mod.rs#L203-L220)
- recent typing 与 FIFO promotion：[`bottom_pane/mod.rs#L536-L581`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/tui/src/bottom_pane/mod.rs#L536-L581)
- modal/composer key routing：[`bottom_pane/mod.rs#L583-L700`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/tui/src/bottom_pane/mod.rs#L583-L700)
- approval enqueue：[`bottom_pane/mod.rs#L1375-L1411`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/tui/src/bottom_pane/mod.rs#L1375-L1411)
- 交互测试：[`bottom_pane/mod.rs#L2100-L2259`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/tui/src/bottom_pane/mod.rs#L2100-L2259)

Codex 自身也有一个不应复制的小问题：delayed promotion 明确保持 FIFO，但已经显示的 overlay 对后续请求使用 `Vec::push` + `pop`，实际可能表现为 LIFO。Intatis 应统一 FIFO。

## 8. 同一 session 内不同 Agent 的 inference 配置

### 8.1 Codex 已支持的维度

当前 Codex `spawn_agent` schema 暴露：

- `model`
- `reasoning_effort`
- `service_tier`
- `fork_turns`

证据：

- [`multi_agents_spec.rs#L14-L145`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/handlers/multi_agents_spec.rs#L14-L145)
- [`multi_agents_v2/spawn.rs#L39-L220`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs#L39-L220)

child 的基础配置来自父 Agent 当前生效的 live config，包括 provider、model、reasoning、approval policy、permission profile 和 cwd；随后再应用 child/role override。

证据：[`multi_agents_common.rs#L166-L300`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/handlers/multi_agents_common.rs#L166-L300)

### 8.2 named role 可以切换 provider 与 endpoint

Codex 的 `agent_type` 会加载完整 role `ConfigToml` 作为高优先级配置层：

- role 不写 provider 时保留当前 provider。
- role 明确写 `model_provider` 时可以切换 provider。
- role 应用后，runtime approval policy、approvals reviewer、cwd 和 permission profile 会从 live parent 重新施加，防止 inference 配置顺带削弱安全边界。

证据：

- [`agent/role.rs#L1-L83`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/agent/role.rs#L1-L83)
- [`agent/role.rs#L129-L227`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/agent/role.rs#L129-L227)
- [`multi_agents_common.rs#L216-L241`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/handlers/multi_agents_common.rs#L216-L241)

`ConfigToml` 可包含 `model_provider` 和 `model_providers`；`ModelProviderInfo` 可表达 base URL、env key/auth、wire API、query params、HTTP headers、retry/timeout 和 websocket support。因此，不同上游 endpoint 在结构上已经成立，只是 Codex 没有把任意 URL/header 直接暴露给每次 `spawn_agent` 调用。

证据：

- [`config_toml.rs#L154-L288`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/config/src/config_toml.rs#L154-L288)
- [`model-provider-info/src/lib.rs#L86-L141`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/model-provider-info/src/lib.rs#L86-L141)
- role 切换到 `ollama` 的测试：[`multi_agents_tests.rs#L919-L975`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/handlers/multi_agents_tests.rs#L919-L975)

这支持 Intatis 已选择的安全接口：模型可请求宿主预先批准、不可变的 `inference_profile_id`，但不应在 spawn 参数中直接接受任意 base URL、header 或 credential。

### 8.3 对旧报告的纠正

旧报告 `codex-report/07_16_26-17_53-per-agent-inference-profile-research.md` 基于更早的 Codex commit `03bb3b1`，其中写道：full-history fork 禁止 agent type/model/reasoning override。

该表述**对本次审计的当前 commit 已不成立**：当前源码与测试证明，full-history V2 fork 可以在保留完整上下文的同时使用 configured 或 explicit model/reasoning override；当前仍被禁止的是 full-history fork 搭配 `agent_type` override。

证据：

- full-history model/reasoning 测试：[`subagent_notifications.rs#L994-L1107`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/tests/suite/subagent_notifications.rs#L994-L1107)
- `agent_type` 限制：[`multi_agents_v2/spawn.rs#L66-L76`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs#L66-L76)

本报告不回写旧报告，只记录这一版本差异。后续若旧报告继续作为设计依据，应单独更新其中该段结论并保留两次审计的 commit provenance。

### 8.4 Codex Guardian 的 provider 仍有局限

Codex 的 `[auto_review]` 配置目前只有 policy，没有独立 Guardian provider/endpoint 字段。Guardian 始终克隆当前父 provider route，只选择 catalog/provider 建议的 review model、调整 reasoning effort 和 retry 上限；model override 不会切换 provider 或 endpoint。

证据：

- [`config_toml.rs#L560-L564`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/config/src/config_toml.rs#L560-L564)
- [`guardian/review.rs#L683-L769`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/review.rs#L683-L769)
- Bedrock provider 继承测试：[`guardian/tests.rs#L3111-L3141`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/guardian/tests.rs#L3111-L3141)

所以 Codex 支持 reviewer 使用不同 model/reasoning，但当前没有独立 Guardian provider/endpoint 配置。Intatis strict production runtime 中 reviewer 的精确 `AgentInferenceBinding` 更一般，应保留。

## 9. Codex 的全局配置、session JSONL 与派生状态分层

### 9.1 Codex 实际不是“把所有设置塞进一个 session 文件”

Codex 当前公开实现把不同责任分开落盘：

| 层 | Codex 当前做法 | 责任边界 |
|---|---|---|
| 全局配置 | `$CODEX_HOME/config.toml`，可叠加 profile、project 与命令行配置 | provider、model、feature、approval/sandbox 默认值等用户配置 |
| 全局秘密 | `auth.json` 或系统 keyring，具体取决于 credential store 配置 | token/credential；不进入 session rollout |
| 全局输入历史 | `$CODEX_HOME/history.jsonl` | 供 composer 召回的用户输入历史；每条只关联 session、时间和文本，不是 session canonical history |
| 每 session canonical 记录 | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl` | session metadata、turn context、消息、模型输出、工具与其他 rollout item 的追加记录 |
| 派生查询状态 | `state_5.sqlite`、`thread_history_1.sqlite` | thread metadata/history 的 SQLite 镜像、索引与查询加速，可由 rollout 对账或重建 |

证据：

- 官方手册：[`codex-manual.md`](https://developers.openai.com/codex/codex-manual.md)
- rollout 文件创建与追加：[`rollout/src/recorder.rs`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/rollout/src/recorder.rs)
- session 目录布局：[`rollout/src/list.rs#L420`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/rollout/src/list.rs#L420)
- composer 输入历史：[`message-history/src/lib.rs`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/message-history/src/lib.rs)
- SQLite 文件与状态模块：[`state/src/lib.rs#L105-L106`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/state/src/lib.rs#L105-L106)

因此，Codex 的 `history.jsonl` 不能被误解成“每个 session 的对话历史”。真正能重建 session 的是 rollout JSONL；SQLite 是面向检索和 UI 的状态镜像，不应反过来成为比 rollout 更高的事实来源。

### 9.2 session 里记录的是“创建元数据 + 每轮上下文 + 事件项”

Codex 的 `SessionMeta` 记录 session 级元数据，例如 session/thread ID、创建时间、当前工作目录、originator/source、model provider 与 Git 信息；`TurnContextItem` 记录每轮实际生效的工作目录、approval/sandbox/permission profile、model、reasoning effort 等。`RolloutLine` 再为每条持久化项增加时间戳和顺序信息。

这说明“当前工作目录、模型、权限”不是远端 Agent 的某种唤醒状态，而是本地可记录、可重建、每轮还可更新的执行上下文：

- session 级不常变化的信息放在创建元数据或当前投影中；
- 每次实际执行所采用的精确上下文写进 append-only history；
- UI 所需的“当前值”由历史投影得到；
- 重新打开历史 session 的登记/投影步骤只是读取并重建本地状态，本身不应调用模型 API。Phase L 后 active Goal 也只在启动控制器中 reconcile 并 durable pause；显式 Resume 才创建 continuation，因此“登记”没有远端唤醒语义。

证据：

- [`protocol.rs#L3070-L3197`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/protocol/src/protocol.rs#L3070-L3197)
- [`protocol.rs#L3276-L3399`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/protocol/src/protocol.rs#L3276-L3399)

Intatis 应复用的是这套**职责分层与重建原则**，不是逐字复制 Codex 的 TOML、目录名、Rust enum 或 rollout schema。

### 9.3 Phase S 前的持久化责任确实过于分散

Phase S 实施前的源码显示：

- provider catalog、聊天页当前 provider/model/variant selection 与兼容镜像分散在 JSON/JSONC 和 `UserDefaults`；credential 通过 Keychain、环境变量、文件或 auth JSON 懒加载。
- 每个 session 已有 `events.jsonl`、`artifacts/` 与 `session.json` 路径，但 Cowork 项目设置和 workspace security-scoped bookmark 仍依赖全局 `UserDefaults`。
- EventLog 已经是动态运行记录的 durable append-only 事实来源，旧 `session.json` 主要承担列表/显示 metadata，尚不能独立说明当前 Cowork settings、Agent 登记和 lease 摘要。

因此，问题不是用了 JSON 还是 `UserDefaults`，而是同一个 session 的设置、workspace access、Agent 登记和动态运行记录没有统一归属与可验证的投影边界。历史 session 可能出现“消息能读到，但运行设置要去全局默认值和旧偏好里拼装”的状态。

### 9.4 Phase S 已实现的落盘结构与作用范围

Phase S 保留 Intatis 现有兼容路径，没有为了模仿 Codex 改成 TOML、日期目录或 SQLite 权威源：

```text
全局
  ~/.config/intatis/intatis.json 或 intatis.jsonc
    provider/model/endpoint catalog、全局默认选择、非秘密 options
  Keychain / auth.json / env / credential file
    API credential 与 secret
  UserDefaults
    纯 UI 偏好、当前 selection mirror、一次性 legacy migration 输入

每个 session
  ~/Library/Application Support/Intatis/<sessionID>/
    events.jsonl              # canonical truth
    session.json              # schema 2、secret-free、可重建投影
    workspace-access.plist    # schema 1、binary plist、owner-only 0600
    artifacts/
```

完成后的责任边界为：

- `events.jsonl` 继续保留 Envelope、单调 `seq`、append/batch、writer lease 和旧事件兼容解码，是唯一 canonical truth。
- EventLog append 的返回值与 subscriber 不再发布编码前的内存对象，而是发布从实际 JSONL bytes 反解出的 canonical Envelope；因此 decode-only `defaultProviderID`、ISO-8601 日期精度等编码归一化不会让运行中 settings 与重放结果分叉或制造重复 revision。
- `session.json` schema 2 保存 `sessionID`、kind、display name、`projectedThroughSeq`、settings revision、Cowork settings、Agent 登记、workspace/capability lease 摘要和完成的迁移标记；它不保存 secret 或 bookmark bytes，可安全删除并由 EventLog 重建。
- projection refresh 不信任仅凭 watermark 看似“最新”的 cache。每次以完整 canonical EventLog fold 为校验 oracle；同 watermark、落后或内容被伪造的 `session.json` 都不能反向覆盖 EventLog。遇到当前版本不认识的未来事件时拒绝覆写投影，避免旧客户端错误宣称理解了新历史。
- `session.json` 采用 owner-only `0600` 临时文件、`fsync`、原子 rename、父目录 `fsync` 和跨进程文件锁写入；投影和 EventLog 的并发更新以事务/锁内 revision 校验保持单调。
- `workspace-access.plist` schema 1 是二进制 plist，只包含 session ID、规范化 path、opaque security-scoped bookmark bytes 与单一 primary 标记。文件使用 `0600`、`O_NOFOLLOW` 锁/临时文件、原子 rename、读回验证和目录 `fsync`；bookmark bytes 不进入 EventLog、`session.json`、日志或错误文本。
- bookmark 生命周期由 session-owned `WorkspaceAccessLease` 管理：以实际获得 security scope 的 URL 成对 start/stop，运行期持有 lease。共享 workspace 不再采用 `agentName` last-writer-wins；删除 Agent/目录时先持久化 settings，再仅清理经剩余 settings + live roster 证明为零引用的非-primary capability，任何身份或清理不确定性都保守保留 bookmark。primary 在 UI、ViewModel 方法和 plist store 三层默认不可删除，只有新建/重授权事务失败时可显式回滚刚写入的 capability。
- 旧 settings 若保存了符号链接 spelling，只能在 bookmark resolve 并启用 security scope 后证明 alias 与 canonical directory 相同；随后先把 canonical path 追加回 EventLog settings，再写 migration marker/清理旧 key。重新授权也以同一 scope-first identity 检查为准，不能用“用户选了另一个目录”静默改绑历史 session。
- `defaultProviderID` 只为旧数据兼容解码而保留；canonical settings encoding 明确省略它。session 保存的是 secret-free immutable `AgentInferenceBinding`/model identity，provider catalog、endpoint 和 credential 继续按全局配置解析。

范围也被明确收窄：Cowork 使用完整 settings、roster 与 lease projection；Chat 和 Code 只共享 EventLog-first 的 display-name 投影；Code 与 Cowork 使用 session-owned workspace access。Phase S 没有把 Cowork roster/settings 模型强行扩散到 Chat。

### 9.5 新 session、历史 session、重命名与迁移规则

新 Cowork session 现在以一个原子 batch 严格追加七条、且顺序固定的本地事件：

1. `session_settings_updated`；
2. main workspace lease；
3. main capability lease；
4. main Agent attached；
5. reviewer read-only workspace lease；
6. reviewer empty-tool capability lease；
7. `@permission-reviewer` attached。

main 与 reviewer 初始使用**同一个精确 inference binding**，但 Agent ID、workspace lease 与 capability lease 各自独立；reviewer 仍是 read-only、无工具、无通信/委派能力的控制面身份。七事件登记只写本地状态，测试使用 capturing/counting provider 证明没有 main/reviewer 模型请求，也不会通过“预热”偷偷联网。

打开历史 session 时，不是“再次登记远端 Agent”，而是：

```text
read session.json as an untrusted fast hint
  → replay and canonically fold events.jsonl
  → validate/reconstruct settings, Agent registrations and lease summaries
  → reacquire the exact session-owned workspace access
  → render history
  → wait for an explicit user submission before main-model API activity
```

`session.json` 缺失、落后、同 watermark 内容冲突或损坏时，EventLog 获胜并重建投影。若历史 EventLog 中 main 登记缺失，GUI 只在宿主已经解析并核对 canonical settings、精确 binding、permission profile 和 workspace 后执行本地历史 main recovery；CLI 的 `/agent restore-main` 也走专用恢复入口，而不是普通 `attach`。登记恢复本身只补本地事件、不发模型请求，也不让今天的全局默认值静默改变历史 session。Phase A 让普通 recovered root submission 保持 paused，只有同一提交上的显式 Retry 才会继续；Phase L 又让 active Goal 只 reconcile 后 durable pause，只有显式 Resume 才继续。

session 重命名同样是 EventLog-first：先追加版本化 `session_settings_updated` rename snapshot，再重建 `session.json`；不再把直接改派生 JSON 当成权威写入。

legacy migration 采用可追溯、可重试、fail-closed 的顺序：

1. 旧 per-session Cowork settings 和 workspace bookmark 只作为迁移输入；共享 legacy path map 只有存在该 session 的明确 ownership provenance 时才允许使用。
2. settings 必须解析到历史 session 的精确 binding/path，workspace 必须解析为原 canonical directory；不完整、冲突、越权或错误目录都不猜测、不静默改绑。
3. bookmark 先写入 session-owned `workspace-access.plist` 并读回验证；若旧 path 是已经验证的 alias，先把 canonical path 作为新 settings revision 写入 EventLog，再追加稳定 migration ID 的完成标记并重建投影。
4. 只有 bookmark 与 marker 都 durable 成功后才清理对应 legacy key；任一步失败都保留可见的重新授权/重试路径。
5. 一旦 EventLog 已有 migration marker，后续恢复不得再次回退到全局 legacy map；即使用户删除 session plist，也必须明确要求重新授权，不能让旧全局数据“复活”已删除的能力材料。
6. migration marker 和 settings revision 使重试幂等；secret 始终只保留全局 reference，不复制明文。

## 10. Intatis 当前已经做对的部分

### 10.1 per-agent inference identity

Intatis 已有的设计比 Codex live config overlay 更适合持久化与审计：

- `Packages/IntatisProtocol/Sources/InferenceProfile.swift:4-54`：`AgentInferenceBinding` 是 durable、secret-free 的精确 identity，包含 profile/connection revision、model、variant、安全 route metadata 和 immutable fingerprint。
- `Packages/IntatisProviders/Sources/InferenceCatalog.swift:6-120`：connection 与 profile 都按 immutable revision 建模，endpoint、wire adapter、credential reference、trust 和 arbitrary request options 都能进入精确解析。
- `Packages/IntatisAgentKernel/Sources/Agent.swift:9-38`：每个 Agent 持有自己的 binding。
- `Packages/IntatisProtocol/Sources/Task.swift:82-135`：task contract 在 admission 时冻结 binding，避免执行途中静默切换上游。
- `Packages/IntatisCowork/Sources/Orchestrator.swift:5723-5743`：运行时核对 task binding 与 live agent binding，按 Agent 解析 provider，并保持 capability/workspace lease 与 inference profile 独立。

这套结构已经能表达：

- 同一 model，不同 reasoning/thinking 参数；
- 不同 model；
- 同 provider，不同 connection revision；
- 不同 provider、base URL、chat endpoint 或 wire adapter；
- 将来不同 API surface、credential reference、trust domain 与 egress classification。

### 10.2 reviewer 的独立安全身份

`Packages/IntatisCowork/Sources/Orchestrator.swift:1430-1491` 在 strict bootstrap 中强制精确 inference binding，并为保留 reviewer 设置 read-only workspace、空 tool/communication/delegation lease。兼容/测试构造仍允许 `nil`，因此“精确 binding”是 strict production runtime 的保证，而不是所有 initializer 的静态不变量。这仍比让 reviewer 隐式继承普通 coordinator 能力安全，也比 Codex 当前“父 provider + review model override”更灵活。

### 10.3 durable permission/tool/turn lifecycle

Intatis 的 permission request/review/settlement、tool execution prepare/settle、typed `turn_outcome` 和 EventLog replay 是需要保留的产品资产。Phase C 又把 RequestID first-write/first-terminal、exact duplicate idempotence、conflict fail-closed 与 turn/tool correlation 收进同一 durable 边界。Codex 的内存 waiter/map 只应提供状态机参考，不应替代这些 durable 契约。

## 11. Intatis 当前故障的结构性原因

### 11.1 Phase A 前：本地编辑与提交被错误绑定到远端/控制面 readiness

Phase A 前的源码同时存在 reviewer/Goal/main inference/pending permission/`isWorking`/main roster 等多层 composer 与 `send()` guard。这套 gating **能够直接产生**用户观察到的“历史 session 输入框不可点击”，但事故现场没有留下足够证据证明当时首先生效的是 reviewer `.enabling/.failed`、Goal、main inference、`isWorking`、live pending permission 还是缺失 main Agent。因此本报告仍把具体首发 predicate 标为未知，不倒推伪造事故时间线。

Phase A 已移除这类输入面硬绑定：

- `CoworkShell` 给共享 composer 固定 `isInputDisabled: false`；pending permission、后台工作、Goal 与 reviewer banner 都只作为状态展示。
- Send 按钮只看本地文本/附件是否非空，以及当前 frozen payload 是否正在被持久化；用户在持久化期间继续输入的内容属于下一份草稿，不会被完成回调误清空。
- `CoworkViewModel.send()` 不再 guard reviewer/Goal/main/provider readiness，而是先解析本地语法、冻结 `UserMessagePayload + SubmissionID` 并交给 `SubmittedIntentStore`。
- canonical EventLog admission 成功后才清除“完全相同的那份”草稿；若 canonical append 失败但 outbox 成功，提交以可见 outbox 卡片保留；若二者都失败，原草稿不清空。
- reviewer unavailable 时安装 fail-closed responder；普通 main 请求可以继续，只有后来真实发生的 ask-class tool request 被明确 deny。

这里仍有一个刻意保留的小门：同一 frozen payload 正在写 EventLog/outbox 时，Send 暂时不可重复点击，以防同一 UI 动作生成两个 submission；这不是 reviewer/runtime readiness gate，输入框仍可编辑，新增文本也不会被前一次完成回调删除。

本文所说的**本地状态重建**，只指从 EventLog、session 快照和全局 catalog 得到内存里的工作目录、Agent 登记、Goal/任务和精确 inference route；不是唤醒远端 Agent，也不是用户拖附件或编辑时发 API。

Phase A 使用的边界是：

| 能力 | 依赖项 | 不应依赖 |
|---|---|---|
| `canEditDraft` | session view 与本地 UI state | reviewer、provider、Goal、main Agent、pending permission、网络、`isWorking` |
| `canSubmitIntent` | 本地文本/附件构成有效提交；本地能保留该提交 | reviewer、Goal、main binding、provider 预热、网络、pending permission |
| `canStartRemoteExecution` | canonical EventLog 可追加、session state 已重建、exact route/credential 可解析、任务 admission 合法 | reviewer 是否预热、另一条 tool approval |
| `canExecuteTool(callID)` | 当前 call 的 policy、review、lease、sandbox、durable ticket | 其他 session 的 reviewer 健康度 |
| `permissionReviewAvailability` | reviewer/control-plane health | 不应作为 composer 或普通提交 gate |

这里的“Send 不设 readiness 硬门”不等于绕过执行验证。Send 的第一步是冻结并接受本地提交；只有后续 route/runtime/tool 条件成立才发模型 API。若不成立，当前实现把提交留在可见的 queued/failed 状态并按失败类型决定是否给出 Retry，不能 silent return 或清空内容。当前 Cowork remote attachment adapter只接受 image；其他文件仍会先 durable 保存，再以 `attachment_type_unsupported` 非重试失败明确显示，不会静默丢弃。

### 11.2 审计时的 process-lifetime reviewer 隔离（Phase B 前行为，现已替换）

Phase B 前，`PermissionReviewControlPlane.runProvider` 先调用共享 `providerActivity.tryBegin()`；已有 activity 时返回 `previousCallStillStopping`。已经取得 activity 的 provider call 一旦 timeout/cancel，就不再清除标记；`PermissionReviewProviderActivityRegistry` 又按 session coordination key 跨 control-plane 生命周期共享该状态，因此关闭/重新开启 reviewer 或重开 Cowork view 都不能恢复，只有进程重启可以恢复。

这套旧实现的安全动机合理：不能让一个无法确认停止的旧 provider stream 与新审批无关联地共用状态。但它把“一次无法证明停止”扩大成“同一 session 在整个进程生命周期失去自动审批”，与“只拒绝当前 ask-class tool”的产品语义冲突。

Phase B 已删除 permission reviewer 的 `providerActivity` 与跨 control-plane registry，并不再在运行时生成 `previousCallStillStopping`。该旧枚举值只保留在协议中用于历史 EventLog 兼容解码；Goal Verifier 仍有同名但独立的 provider-activity 逻辑，不能把两条控制面混为一谈。

**历史推断仍成立但未被证明**：旧路径与用户看到的“后续权限全部失败”高度一致；但本次事故具体是哪一个 request 首先 timeout/cancel、当时使用哪个 provider、producer 是否忽略 cancellation，现有历史 EventLog 没有给出足够证据。Phase B 修复了代码中可确认的放大路径，不把事故首发因果写成已复现事实。

### 11.3 Phase B 的 generation、terminal 与 provider ownership

当前实现不是简单删除 overlap guard，而是把相关性和终态边界收窄到每个 request：

- `PermissionReviewProviderGenerationID` 由 `reviewTaskID + UUID nonce` 组成；Job 必须从 `.running` 进入 `.reviewing(exactGeneration)`。provider 与 timeout 携带同一 generation 并在 request-scoped race 中竞争；caller cancel 可终结该 race，但关键保证还来自独立的 request-owned 同步 token 与 settlement/delivery/admission 围栏，不能把它简化成单一 race。
- `PermissionReviewProviderRace` 在同一把锁内校验 generation 与 first-terminal；retired generation 的 late/duplicate result 只能返回 `false`，且 race 不持有 actor、EventLog、health 或 authorization 状态。
- `persistTerminal` 在 append 前只允许一次 `.terminalClaimed`：provider-backed terminal 必须匹配当前 exact generation；尚未 dispatch provider 的 validation/hard-deny/queue-expiry/cancel 路径则从 `.running`、无 generation 状态唯一 claim。不匹配、重复或 stale terminal 一律 deny。`allow` 只有 `permission_review_settled` 成功落盘后才可能交付。
- production Orchestrator 通过 `PermissionReviewProviderFactory` 冻结 reviewer identity/exact binding，但每一代重新 exact-resolve provider wrapper；factory 只捕获不可变 Agent 与 resolver seam，不捕获 Orchestrator，避免 responder/control-plane retain cycle。
- timeout/cancel 只影响当前 permission action/call；若已经存在 active provider generation，就立即 retire 该代，并让当前 authorization delivery fail closed。pre-submit cancel 直接返回 typed deny且不创建 review lifecycle；已登记 review 的取消在 terminal claim 前被观察到时 durable settle 为 deny，claim 后才到达时遵循下一条的 verdict/delivery 分层。下一 request 不继承 health quarantine，可创建 fresh generation；下一次成功 review 会把 transient degraded health 恢复为 healthy。
- caller cancel 由 request-owned、lock-backed token 在 cancellation handler 内同步置位，不等待后续 actor hop；已经取消后才进入 `submitResolution` 的调用会直接返回 `caller_cancellation/caller_cancelled`，不会误报为 control-plane shutdown。`submitResolution` 在回到原 caller task 后再次检查 cancellation。Orchestrator 的直接 `agent.attach` admission 会在 review await 后检查一次，并在异步 inference 复核、admission lock 与 roster/catalog/workspace 重检完成后、原子 durable allow batch 取得提交所有权之前再检查一次。这个最后检查点是取消与 attach commit 的线性化边界：检查前已观察到取消就 durable deny；检查后开始的取消不能倒写已经取得原子提交所有权的 admission。因此暂停 settlement、post-review resolver suspension、caller cancel 与 late allow 的先后不再靠调度运气决定授权结果。
- cancel/quiesce 若发生在 terminal claim 后、settled append 返回前，系统不写第二个 settlement；reviewer verdict 与最终 authorization delivery 分层，调用方仍得到 deny，AgentLoop 的 caller-cancellation gate 继续阻止工具执行。

`ToolCallingProvider.stream` 同时明确了实现契约：必须立即返回 request-owned stream，把网络/阻塞工作放入 request-scoped producer，并把 consumer termination 传给 producer。当前 OpenAI tool-calling adapter 与 `URLSessionStreamingClient` 均为每请求 continuation/task，`onTermination` 会取消对应 task；production factory 又为每代重新解析 wrapper。`Task.detached` 只避免继承 control-plane actor executor，**不**承诺隔离一个在 `stream()` 调用本身永久同步阻塞的任意第三方实现；这种实现违反 provider 协议，若未来必须支持，应使用有界专用线程或进程 transport，而不能宣称 detached task 已解决。

### 11.4 相关但独立：审计时 session 切换会停止工作（Phase L 已修复）

审计时 `Apps/IntatisMac/Sources/IntatisMacRootView.swift` 在选择/重开另一 Cowork session 时会停止原 `CoworkViewModel`；`CoworkViewModel.stop()` 又会取消 runtime/全部工作。因此，当时源码行为与已经确认的产品预期不同：**只切换页面、模式或 session，不应终止仍在运行的任务。**

同时已经确认以下目标语义：

- 应用进程仍存活时，切换页面/session 或只关闭窗口，不代表取消任务；后台 session 继续运行。
- 用户按 Command-Q 正常退出时，等价于对所有运行 session 发出明确停止，完成必要的 cancellation/settle 持久化后退出。
- 正常退出后重新打开，不自动继续上次未完成任务。
- crash/force-quit 后重开只做对账并显示 paused/interrupted，不自动继续；是否重试由用户明确触发。

Phase L 已把 runtime ownership 从 view 生命周期提升到进程级 `AppSessionRuntimeManager`：窗口只持有展示选择；session/mode 切换、History、Command-W 与关闭最后窗口均不 stop；Command-Q 才关闭 admission、并发 stop 全部 runtime并等待 bounded deadline。正常重开与 crash/force-quit 后重开只 replay/reconcile，active Goal durable pause，running/stopping 显示 interrupted，明确 Resume/Retry/Send 才继续。该修改仍保持为独立阶段，没有倒写 Phase S/A/B/C 的验收含义。

### 11.5 `task_update` stale ticket：已知 no-effect 被误判为未知副作用（Phase T 已修复）

最近一次“消息提交后没有继续”的直接源码链与 reviewer 无关：`task_update` 使用 stale `expected_revision`，`WorkTaskGraph.update` 在任何 WorkTask 事件追加和内存 commit 之前拒绝；但旧 AgentLoop 只看工具 descriptor 的 `requires_manual_reconciliation`，把这个确定的 pre-effect failure 与 timeout/网络/进程写入后报错归为同一类，写了 `tool_result` 却故意不写 `tool_execution_settled`。Orchestrator 随后把精确 invocation durable failed；`GoalRuntimeController.start()` 又先检查整个 session 的 unresolved non-replayable ticket，再判断是否存在 current Goal，于是一个已经局部失败的旧 task 能把 submitted-intent drain 的数据面 readiness 一直挡住。

三家实现给出的可复用共识不是“删掉审计票据”，而是把 terminality、状态条件与作用域拆开：

- OpenCode 把每次 tool call 的 `running → completed/error` 作为明确终态，失败也会 settle 当前调用；foreground `task` 路径等待 child，child 出错时该 task tool 以 error 失败并把 model-visible tool error 交回父会话，显式 `task_id` 才表示复用同一个 child session。它的 todo 更新是整表 transaction，没有 revision/CAS，因此不能直接复制为 Intatis WorkTask 语义。源码证据：[`session/processor.ts#L165-L204`](https://github.com/anomalyco/opencode/blob/a19b52e85bf2630b86157030e2cf7c9fc20ce552/packages/opencode/src/session/processor.ts#L165-L204)、[`tool/task.ts#L136-L165`](https://github.com/anomalyco/opencode/blob/a19b52e85bf2630b86157030e2cf7c9fc20ce552/packages/opencode/src/tool/task.ts#L136-L165)、[`tool/task.ts#L317-L347`](https://github.com/anomalyco/opencode/blob/a19b52e85bf2630b86157030e2cf7c9fc20ce552/packages/opencode/src/tool/task.ts#L317-L347)、[`session/todo.ts#L29-L50`](https://github.com/anomalyco/opencode/blob/a19b52e85bf2630b86157030e2cf7c9fc20ce552/packages/opencode/src/session/todo.ts#L29-L50)。
- Codex 的 `update_plan` 解析/模式错误使用 `RespondToModel` 回到当前模型，而不是把 thread 永久置坏；新的 Agent Job state 用 SQL 条件更新，只接受 still-running 且属于 exact reporting thread 的结果。更新未命中时，`report_agent_job_result` 把 `accepted: false` 作为 model-visible JSON 返回，因此迟到/重复结果被局部拒绝，而不是升级为 thread 级故障。源码证据：[`tools/handlers/plan.rs#L68-L105`](https://github.com/openai/codex/blob/bf3c1972b7d045c0a3a48dff91f381070f8f69e1/codex-rs/core/src/tools/handlers/plan.rs#L68-L105)、[`state/runtime/agent_jobs.rs#L430-L529`](https://github.com/openai/codex/blob/bf3c1972b7d045c0a3a48dff91f381070f8f69e1/codex-rs/state/src/runtime/agent_jobs.rs#L430-L529)、[`report_agent_job_result.rs#L58-L97`](https://github.com/openai/codex/blob/bf3c1972b7d045c0a3a48dff91f381070f8f69e1/codex-rs/core/src/tools/handlers/agent_jobs/report_agent_job_result.rs#L58-L97)。Codex 没有与 Intatis 一样的通用 durable prepared/unsettled side-effect ledger，所以只能借鉴 conditional acceptance 和 item scope，不能照搬持久化格式。
- Claude Code 的核心 runtime 没有可审计的完整开源实现；官方公开行为中，Agent Teams 的 teammate 是独立 Claude Code instance/session，而 subagent 使用独立上下文并在完成后把结果返回父会话。PreToolUse hook 在工具执行前运行，deny reason 可反馈给模型，`defer` 保留待处理调用。这里只采用这些行为边界，不声称知道其内部 crash ledger。参考：[Agent Teams](https://code.claude.com/docs/en/agent-teams)、[Subagents](https://code.claude.com/docs/en/sub-agents)、[Hooks](https://code.claude.com/docs/en/hooks)。

Intatis 最终没有复制/翻译上述源码，而是保留自身更严格的 EventLog ticket，并独立实现其交集：

1. `ToolExecutionSettledPayload` 新增 optional `effectDisposition`；旧 JSONL 缺字段时解码为 `nil`。新的成功执行显式写 `.committed`；legacy `succeeded + nil` 只为兼容而解释成已完成效果，仍阻止 whole-task replay。`succeeded + .notStarted` 自相矛盾，不是 no-effect 证明而是 invalid/uncertain。
2. Cowork projection 为每个 `executionID` 永久保留第一张 prepare；第二张 prepare 即使 payload 完全相同也把该 ID 标为 ambiguous，因为第一轮 executor 可能已经运行。第一条 settlement 同样保留：完全相同的 duplicate settlement 视为幂等，任何冲突 terminal 把历史永久标为 ambiguous。ambiguous history、settlement 与首张 prepare 不匹配或 `seq` 早于 prepare 时，`validatedSettlement` 一律为空，不能放松 recovery/retry gate。
3. 只有 production `OrchestratorWorkTaskManager` adapter 才会在 `WorkTaskGraphViolation.staleRevision` 的 task ID、expected revision 与 authoritative actual revision 全部精确匹配当前请求时，转换为共享 no-effect rejection；任意其他 `WorkTaskManager` 不能伪造这个证明。AgentLoop 以一个 batch 写 `tool_result + settled.failed/not_started`，把“先 `task_get` 再重试”的错误交回模型继续当前 turn。durable prepare 之后、executor 之前的 authorization/workspace rejection 也使用 no-effect settlement；该边界观察到 cancellation 时先写 `cancelled/not_started`，随后仍抛出 `CancellationError` 中断本轮。
4. 一旦 executor 已进入，CancellationError、timeout、普通 write/network/process/collaboration error 仍保持 unresolved/manual reconciliation；工具 descriptor 没有被粗暴改成 `safe_to_replay`。
5. Cowork projection 只从 whole-task retry blockers 排除有效的非 success `.notStarted`。无有效 settlement、ambiguous history、显式 `.unknown`、`succeeded + .notStarted`，以及 outcome 为 failed/cancelled/denied 且 disposition 为 legacy nil 的调用都属于 uncertain；legacy succeeded/nil 虽不属于 uncertain，仍表示调用已产生完成效果并阻止 replay。
6. 对旧日志只做狭窄单调 proof，而且只在没有 current Goal 时运行：execution 必须仍是 projection 中 exact current record、durable history 不 ambiguous、整个 executionID 从未出现任何 settlement；工具/side-effect/replay policy、typed update/cancel intent 与唯一非空 task resource 必须匹配；`expectedRevision` 必须是非负、有限整数并落在 JSON safe integer 范围；prepare 前的 durable WorkTask revision 必须严格大于 expected revision。缺一项都不修复；错误自由文本和 prepare 后 latest state 不作为证据，current Goal 永不走这条 legacy repair。
7. Orchestrator restore/legacy repair、Goal startup、进程内 `launchCurrentGoalIfEligible` 与 whole-task retry reconciliation 都先读取 `replayForProjectionChecked()` 并要求 `hasCompleteKnownHistory`。普通 checked decode 能跳过的 unknown future event，或 durable header 中暴露的 `seq` gap，都意味着当前 binary 无法证明某事件不存在或先后顺序完整，因此这些安全路径全部 fail closed。没有 current Goal 时，也只有 complete-known history 能证明 exact TaskContract 创建早于 prepare、正数 attempt 精确一致、同 attempt terminal 晚于 prepare，才允许普通新 turn；同一 task 仍禁止 replay。存在 current Goal 时，任何 uncertain ticket 都保持严格 gate，且不会先由 legacy repair 消除。

这里“结算”的精确定义是：为某次 prepared execution 追加 terminal `tool_execution_settled`，说明这一次调用已结束，以及 declared side effect 是 committed、unknown 还是 proven not-started。投影只承认首张 prepare 下不 ambiguous、terminal 内容一致、settlement `prepared` 与首张 prepare 完全匹配、且 `seq` 不早于 prepare 的记录；重复相同 terminal 只幂等保留首条，冲突 terminal 永久 ambiguous。它不表示 WorkTask completed，不表示用户任务成功，也不删除错误；它只是让系统在有有效结算时不再把这次调用解释为“可能仍在执行”。

## 12. 采用、保留与明确不复制的内容

| 类别 | 决策 | 说明 |
|---|---|---|
| 本地提交不依赖 readiness | 采用 | Send 先冻结/保留文本附件，再做本地状态重建和远端执行检查 |
| reviewer lazy API / optional prewarm | 采用 | reviewer 可与主 Agent 一起本地登记；API 只在真实 permission ask 时需要 |
| reviewer failure call-scoped | 已采用（Phase B 已实施） | 单次 timeout/failure 只 fail closed 当前 call；retire exact generation，下一次 review fresh resolve；terminal-claim 后取消可保留唯一 verdict，但 authorization delivery deny；model deny 达 breaker 阈值时才中断当前 turn |
| Decline 与 Cancel 分离 | 已采用（Phase C 已实施） | 分别对应 call continuation 与 turn interruption；Cancel 不制造 denied tool result |
| approval correlation、首响应获胜、迟到忽略 | 已采用（Phase C 已实施） | 落在 Intatis EventLog RequestID first-write / first-terminal CAS 与 FIFO projection 上 |
| composer 草稿独立 | 采用 | reviewer/pending permission/`isWorking` 不能禁用本地输入 |
| 全局配置、session JSONL、派生索引分层 | 采用 | 复用责任边界，不照抄 Codex 路径与 schema |
| `events.jsonl` canonical、`session.json` 投影 | 采用并强化 Intatis | 保留 Envelope、单调 `seq` 与旧数据兼容 |
| sandbox denial 精确分类 | 只采用分类边界，不采用自动 retry | Intatis 保留自己的三层权限门与 sandbox backend；可信 startup denial 写 typed denied/not-started，当前不扩大权限、不移除 sandbox、不 retry |
| immutable per-agent inference binding | 保留 Intatis | 比 Codex live config overlay 更适合本地重建与多 endpoint |
| reviewer 独立 inference binding | 保留 Intatis strict runtime | 初始可与主 Agent 相同，但 identity 与 lease 仍独立 |
| durable request/settled 与 prepare/settle | 保留 Intatis | 不换成进程内 oneshot/map |
| shared Cowork EventLog | 保留 Intatis | 不改成 Codex child thread tree |
| Codex `config.toml` 和日期目录 | 不复制 | Intatis 保留 JSON/JSONC 和一 session 一目录的兼容路径 |
| Codex SQLite 作为新权威 | 不复制 | 若引入只能是可重建投影 |
| tool-enabled Guardian | 暂不复制 | 当前 no-tools reviewer 更符合项目安全原则 |
| `ToolError::Rejected` 混合分类 | 不复制 | Codex 源码已有 TODO；Intatis 应从一开始拆分原因 |
| TUI overlay LIFO 不一致 | 不复制 | Intatis 保持全链路 FIFO |
| reviewer 只能继承父 provider | 不复制 | 会削弱 Intatis 的独立控制面路由能力 |
| role/profile 携带 capability/permission | 禁止 | inference 与 security lease 必须正交 |
| Codex runtime/app-server 整体套壳 | 不采用 | 选择性翻译公开状态机、测试和数据职责；Apple 产品面仍由 Intatis 掌控 |

Codex 当前把用户 decline 与部分 runtime/setup rejection 都汇入 `ToolError::Rejected`，可能导致 UI 把非用户故障显示成 `Declined`；源码已有拆分 TODO。Intatis 已有较细的 reviewer/execution failure 类型，应保留这些区分，并继续补齐 user decline、turn cancel、sandbox 与 runtime/setup failure，而不是重新压平。

证据：[`tools/events.rs#L405-L430`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/events.rs#L405-L430)

若直接翻译或修改 Codex 的公开源码/测试，必须固定上游 commit、逐文件核对 Apache-2.0/依赖许可证、记录 provenance 并更新 `NOTICE.md`；仅根据行为契约独立实现时也应在设计记录中保留上游证据。不能复制品牌 UI、私有 prompt 或未公开实现。

## 13. 目标状态与当前实现边界

### 13.1 新 session 登记与历史 session 本地重建（Phase S 已实现）

新 session：

```text
create session directory
  → append initial settings + main/reviewer registrations in one durable batch
  → main and reviewer initially share the same exact inference binding
  → apply different identities and security leases
  → render the empty session
  → no model API request yet
```

历史 session：

```text
open session directory
  → read snapshot hint and replay EventLog
  → reconstruct settings, Agent registrations, leases, tasks and pending states
  → render history and an editable composer immediately
  → recovered queued/running submissions remain interrupted until explicit Retry
```

Phase S 已把“登记”和 EventLog 重建落实为本地动作；Phase A 又移除了 composer/Send readiness gate，并为 restored root task 加入 submission/task 级 pause fence。补回缺失 main、恢复 bookmark、展示 reviewer failure 或读取 outbox 本身不调用模型。

Phase L 已消除原先的生命周期例外：`GoalRuntimeController.start()` 对历史 active Goal 只执行 strict replay、recovery、checkpoint/audit reconcile，随后 durable pause（达到预算则 budget-limited），不自动 launch continuation。因而普通登记、投影、草稿、submitted-intent、recovered root task 和 active Goal 冷启动都不发 main/reviewer API；显式 Resume、Retry 或 Send 才进入数据面。

### 13.2 Send 之后才开始 API 交互

完整顺序应是：

```text
edit text / drag attachments locally
  → user clicks Send
  → freeze an immutable submitted-intent payload
  → append to canonical EventLog, or retain in a visible local outbox if canonical append is temporarily impossible
  → rebuild/validate local session execution state
  → resolve exact main-agent inference route and credential reference
  → issue main-model API request
  → only if the model requests an ask-class tool, issue reviewer API request
```

这符合普通 API 产品的目标直觉：在用户明确发送前，不应因为编辑、拖文件或历史 session 的登记/投影/Goal 对账而自动向 main/reviewer 请求推理。用户明确发起的独立操作，例如主动测试连接、手动刷新模型目录，必须有明确 UI 语义，不能伪装成 session 本地状态重建。Phase L 后 active Goal 也只有显式 Resume 才续跑。

Phase A 当前的提交后表现：

- EventLog 可写但目标 Agent 不存在或 exact inference unresolved：submission 进入 `route_unavailable` failed/retryable，原 payload 保持不变。
- credential/provider/network/task 失败：submission 记录关联失败；在未耗尽 task attempt 且无安全阻断时，Retry 使用同一 submission 与 exact root task，不重复 `user_message`。
- Goal submission 携带附件：当前明确返回 `goal_attachments_unsupported`，文件仍保存在 session ArtifactStore；不会忽略附件后假装成功。
- 普通 Cowork 非 image 附件：明确返回 `attachment_type_unsupported` 非重试失败；image 从 owner-only blob 读回并恢复为 provider attachment。
- canonical EventLog 暂时不可写：`submitted-intent-outbox.json` schema 1 以 `0600`、锁、原子替换、fsync 与读回校验保留 first-write-wins payload；它只用于可见等待，不绕过 canonical admission 驱动执行。
- canonical admission 使用同一 EventLog transaction 追加唯一 `user_message` 与 attempt 1 `queued`，outbox 副本随后清理；状态 fold 拒绝 attempt 0、跳号、低 attempt、同 attempt terminal rewrite 和孤儿状态。

### 13.3 reviewer request isolation

每个 review 至少需要：

- 稳定 `reviewID`；
- `sessionID + turnID + callID + generation`；
- 单一 terminal state；
- deadline/cancellation token；
- 独立或可证明终止的 transport ownership；
- late result commit guard；
- 执行工具前再次核对 request 仍为 approved-and-live；
- request/settled 全部 durable append。

timeout 或 failure 的默认动作：

1. durable settle 当前 review 为 deny/timeout/failure；
2. 当前 tool call 返回明确失败 result；
3. 旧 generation 的 late output 永久无权改变状态；
4. 下一个 call/turn 可创建新 reviewer session；
5. 只有确有系统级安全不变量无法维持时才升级成 session lock，并必须提供不重启应用的显式恢复路径。

### 13.4 inference profile admission

继续使用宿主批准的 immutable `inference_profile_id`：

- spawn 时只接受 profile ID 或继承父 binding；
- profile resolution 可以得到 model、reasoning/thinking、service tier、provider、base URL、endpoint、wire format 和非秘密 options；
- credential 仍按 reference 懒加载，不进入 tool schema、prompt 或 EventLog；
- role 可以选择 inference profile，但不能携带或覆盖 PermissionProfile、CapabilityLease、WorkspaceLease；
- task admission 冻结 exact binding；本地状态重建时必须按 immutable revision/fingerprint 重新验证。

## 14. 分阶段实施状态与后续计划

### Phase S：session 存储契约与兼容迁移（已完成）

这一阶段不改多 session 生命周期，也不引入 SQLite 权威源。

已完成：

1. 固定全局 provider/endpoint catalog、全局 credential、session EventLog、schema 2 投影和 schema 1 bookmark store 的责任表。
2. 增加版本化 `session_settings_updated`、`session_storage_migrated` 与 Cowork settings/workspace payload；`defaultProviderID` 只兼容解码、不进入 canonical encoding。
3. 新 Cowork session 严格以七事件 batch 同时登记 settings、main 和 reviewer；初始 exact binding 相同，identity/lease 不同，无模型调用。
4. 将 Cowork settings 与 Code/Cowork workspace bookmark 迁入 session ownership；legacy 只作 provenance 受限的迁移输入，并以 durable marker 阻止回退复活。
5. 实现 EventLog-wins projection rebuild/refresh、EventLog-first rename、历史 main 本地恢复、精确 path 重新授权和 fail-closed migration。
6. 完成协议、投影、workspace store、Cowork bootstrap/recovery、GUI/CLI 路径、旧数据兼容和无模型调用测试，并通过 macOS Computer Use 检查新建与恢复 UI/磁盘状态。

验收结果：任意 Phase S Cowork session 目录单独存在时，除全局 provider catalog/credential 外，足以确定其当前 settings、Agent 登记、workspace/capability 摘要与运行历史；删除或伪造 `session.json` 后可由 EventLog 正确重建。workspace capability bytes 单独保存在 owner-only session plist 中。

需要强调：**Phase S 只解决存储归属、投影、迁移和登记/恢复，不等于整个报告已经全部解决。Phase A、Phase B 与 Phase L 后来分别独立实施；不能把其中任何一项倒算成 Phase S 的能力。**

### Phase A：composer、本地提交与执行 admission 解耦（已实施，范围为 Cowork 输入链路）

已完成：

1. `SubmissionID` 和 optional message/output/error correlation 字段以 additive、legacy-decodable 方式进入协议；root `TaskContract` 冻结同一 submission identity。
2. `SubmittedIntentStore` 先写 session-owned outbox，再以 EventLog transaction canonicalize 唯一 `user_message + queued(attempt: 1)`；payload first-write-wins，冲突 fail closed。
3. `submission_status_changed` 提供 queued/running/completed/failed/cancelled、one-based attempt 与 bounded failure；Code/Cowork projection 只接受合法单调状态。
4. Cowork composer 永远可编辑，Send 只依赖本地文本/附件和“当前是否正在保存同一次点击”；reviewer、Goal、main inference、pending permission 与 `isWorking` 不再禁用输入。
5. 任意本地文件先写入 session ArtifactStore 并读回验证；当前 provider adapter 支持 image，其他类型和 Goal attachments 明确失败且保留原文件。
6. canonical submissions 使用 host FIFO；active Goal 持有数据面期间后续提交保持 queued，避免 continuation run 间隙误放行。普通主请求不以 reviewer ready 为 gate；reviewer 不可用只 deny ask-class tool。
7. retry 沿用 stable submission 和 exact root task，`recordUserMessage: false`；completed task 只补齐 submission terminal 状态，已执行/未决非幂等副作用仍由现有 durable replay policy fail closed。
8. 历史 queued/running submission 显示 interrupted/retryable；restored root task 不进入 scheduler，只有同一提交的显式 Retry 才解除。新提交仍可执行，不必先恢复旧任务。
9. Context projection 用 root submission correlation 选择精确用户目标，并按 submission/task/tool correlation 排除当前提交旧 attempt 与逻辑上更晚提交的输出；不能证明归属的 unscoped 内容在 submission-bound context 中 fail closed。

本阶段选择 **FIFO**，不采用 Codex 的 active-turn steer 语义：用户可以一边工作运行一边编辑并提交下一条，但后台只按 admission 顺序启动；active Goal 离开 `.active` 前不会运行下一条普通提交。

验收结论：Cowork 历史 session 即使 reviewer failed、Goal/main binding unresolved、已有工作运行或存在 pending permission，输入框仍可编辑；点击 Send 后内容先被明确接受并保留，随后才成功执行、排队或显示失败，不存在原先的 silent readiness guard。

不在本阶段内：Code mode 仍保留其既有单-agent busy 输入策略；active Goal 的进程重开语义后来由 Phase L 独立完成；reviewer request isolation 已由独立 Phase B 完成。本文不会把 SharedUI 的局部复用夸大成三个 mode 全部采用相同提交状态机。

### Phase B：reviewer request isolation 与可恢复性（已实施）

1. reviewer 本地登记与 reviewer API 调用继续解耦；登记/恢复只建立本地 identity、lease 与 responder，不产生模型请求，provider 仅在真实 permission ask 时消费 stream。
2. 用 `{reviewTaskID, nonce}` request-scoped generation、Job state 与 terminal claim 替代 permission reviewer 的 process-lifetime session quarantine。
3. production 每代重新 exact-resolve provider wrapper；request-scoped race 拥有 provider/timeout tasks 并在首 terminal 后取消二者，旧 producer 只持有旧 request/race，不能触达新代状态。
4. pre-submit caller cancel 直接返回 typed deny且不创建 review lifecycle；timeout、provider-factory failure与已登记 review 在 terminal claim 前被观察到的 cancel 将当前 review settle 为 deny；claim 后 cancel 保留唯一 settlement 但阻断 authorization delivery。它们都只影响当前 call；若已有 active provider generation 则只 retire 该代，下一 call 可创建 fresh generation，无需重启或关闭/重开 session。
5. late/duplicate output 同时按 review ID/generation 与 first-terminal guard 丢弃，不能追加 settlement、返回 allow 或触发 tool execution。
6. caller cancellation 使用同步 request token + caller-task post-await fence；已经取消后才进入 control plane 的请求直接分类为 caller cancellation。直接 `agent.attach` 在 review 返回后以及最终 durable admission 线性化点前各有一道 host cancellation fence，不再依赖 cancellation handler 的异步 actor hop先于 settlement 或 post-review inference 复核恢复。
7. disable 的 quiesce、durable detach 失败后的 resume、terminal-claim 后 cancel、settlement append suspension、pre-submit caller cancel、caller-cancelled attach、post-review inference resolution 中取消和 late allow 均有确定性 barrier/ack 回归；review verdict 与最终 authorization delivery 的两层语义已固定。
8. `ToolCallingProvider.stream` 现在要求立即返回 request-owned、termination-propagating stream；shipped OpenAI/URLSession 路径符合该契约。任意同步永久阻塞的第三方 provider 不在该契约内，不能由 `Task.detached` 冒充安全隔离。

### Phase T：tool outcome settlement 与 task-local recovery（已实施）

这一阶段只修复“已知没有产生副作用，却被当成结果未知”的执行票据，以及该票据对无 Goal session 的错误放大；不重写通用 task/runtime 生命周期。

1. 在既有 `ToolExecutionSettledPayload` 上增加 additive optional `effectDisposition`，取值为 `not_started`、`committed` 或 `unknown`。新成功执行显式写 `.committed`；旧 JSONL 缺字段继续解码为 `nil`，其中 legacy succeeded/nil 仅兼容解释为已完成效果。`succeeded + not_started` 无效并按 uncertain 处理。
2. projection 对每个 `executionID` 只保留首张 prepare；任何重复 prepare（包括完全相同 payload）都会永久 ambiguous。第一条 terminal settlement 也永久保留：相同 duplicate settlement 幂等，冲突 terminal 永久 ambiguous。只有不 ambiguous、settlement 匹配首张 exact prepare 且 `seq` 不早于 prepare，才可能成为有效结算。
3. 增加共享 typed `ToolExecutionRejectedWithoutSideEffect`。只有 production `OrchestratorWorkTaskManager` adapter 可在 `task_update` 的 task ID、expected revision 与 authoritative actual revision 全部匹配时，把 `stale_revision` 转成它；任意其他 manager 不能通过错误文本或自造 violation 声明 no-effect。
4. AgentLoop 对 typed no-effect rejection 以单个 EventLog batch 追加 model-visible `tool_result` 与 `tool_execution_settled(failed, not_started)`，随后把失败 observation 返回模型；prepare 后、executor 前的 authorization/workspace rejection 也明确结算为 `not_started`。同一边界观察到 cancellation 时写 `cancelled/not_started` 后仍抛出取消并中断本轮，不继续模型 turn。一旦工具 executor 已被调用，cancel、timeout 和普通 write/network/process/collaboration error 仍保持 unresolved/manual reconciliation。
5. 无有效 settlement、ambiguous history、显式 unknown、`succeeded + not_started`，以及 legacy failed/cancelled/denied + nil 都属于 uncertain；legacy succeeded + nil 虽不属于 uncertain，也仍阻止 whole-task replay。静态 `write` descriptor 没有被降级成 safe-to-replay。
6. Orchestrator restore 对旧 `task_update` ticket 只做可证明的兼容修复，而且仅在没有 current Goal 时运行：要求 exact current record、无 ambiguous history、整个 executionID 从未出现任何 settlement、manual/write `task_update`、typed update/cancel intent、唯一非空 task resource、非负且有限的 JSON safe integer `expectedRevision`，以及 prepare 前 durable `actualRevision > expectedRevision`；不解析错误文本、不使用 prepare 后最新状态。current Goal 不修复，uncertain 继续 fail closed。
7. restore/legacy repair、Goal startup、进程内 Goal launch 与 whole-task retry 都使用 `replayForProjectionChecked()` 并要求 `hasCompleteKnownHistory`。unknown future event 或 `seq` gap 无法支持 absence/order proof，全部 fail closed。没有 current Goal 时，还要求 exact TaskContract 在 prepare 前创建、positive exact attempt 与同 attempt terminal-after-prepare；同一 task 仍禁止 retry。unscoped、missing/mismatched、nonterminal、terminal-before-prepare 或非正 attempt，以及任何 current Goal，都继续 fail closed。

验收结论：新的 stale update 当场结算并回到模型，不再形成永久 pending ticket；新成功执行显式 committed；只有 complete-known、single-prepare、zero-settlement、non-ambiguous 且满足 prepare 前单调证明的旧 stale ticket 才在 restore 时补结算。重复 prepare、冲突 terminal、unknown future event、`seq` gap、不能证明的历史或 executor 后故障都不猜测、不自动重放。Phase T 没有借机扩张 current Goal 或 runtime ownership；这些后来由独立 Phase L 只收口冷启动 pause/显式 Resume 和 app ownership，仍没有放宽 unknown-side-effect gate。

### Phase C：审批结果与 turn 终止语义（已实施）

1. 新增稳定 `TurnID`、`ExecutionFailureSource`、`ToolCallOutcome`、`TurnOutcome` 和 append-only `turn_outcome`。Chat/Code/Cowork 新 turn 明确记录 completed/interrupted/failed；旧 JSONL 缺少新字段或事件继续兼容解码。
2. `PermissionApprovalResolution` 把人工响应拆为 `approve`、`decline`、`cancel_turn`，并显式记录 manual/automatic reviewer mode。Decline 只为当前 call 写 typed denied `tool_result`，模型可继续；Cancel Turn 先 durable settle permission，再中断整个 turn，不向模型注入伪造的“用户拒绝”结果。automatic reviewer 仍只有 allow/deny，GUI 不提供人工 action。
3. permission request 在 responder/UI/transport 可见前 durable register并携带 turn/tool-call/request/authorization correlation。`EventLog.registerPermissionRequest` 在跨进程锁内 first-write-wins；`settlePermissionRequest` 要求 complete-known history并在同一锁内 first-terminal compare-and-append。exact duplicate 幂等返回原 Envelope；冲突 request、tool、turn、tool-call、authorization、action/decision 或 terminal fail closed。
4. `PermissionReviewControlPlane` 对 active/completed 同 RequestID 的 exact duplicate/reconnect 共享 owner generation 和 terminal；冲突 duplicate 不替换原 owner。duplicate waiter 自身取消只影响自身；owner 在 durable allow 后、delivery 前取消时，所有共享 authorization delivery 均 fail closed。
5. PermissionProjection 与 CLI responder 使用 FIFO；结算任意中间项只移除该项，不改变其他 pending request 的相对顺序。同一 durable request 重显复用相同 identity/payload，不重新执行 provider 或工具。
6. failure source 结构化为 user deny/cancel、turn cancel、policy deny、reviewer timeout/failure、sandbox deny 与 runtime failure。provider 自己抛 `CancellationError` 而 caller task 未取消时归 runtime failure，不能冒充用户取消。
7. sandbox denial 只在受信 wrapper startup marker 证明目标尚未进入、且 wrapper diagnostic 匹配时成立；目标伪造相同 stderr、普通 exit-nonzero 与一般 EPERM 都不误分类。可证明未开始的路径写 `denied + sandbox_denied + not_started`，当前不自动 retry、不扩大权限、不移除 sandbox。
8. timeout/cancel 使用 structured child ownership；Orchestrator 的单 task cancel 与全局 stop 都先取消并等待数据面/provider/tool cleanup，再持久化 terminal、清理 waiter/关闭 reviewer并恢复 caller。没有 detached/non-cooperative AgentLoop 被包装器提前遗留。

验收结论：Phase C 已完成本地协议、EventLog 线性化、投影、runtime、GUI/CLI 与 deterministic tests；不等于已经实现网络型 remote approval transport。Phase L 后来独立完成应用级多 session runtime ownership，但真实 provider cancellation 的服务端物理停止时序、process-kill pending approval 重放和 Linux bwrap 实机仍为 `UNKNOWN`。

### Phase D：per-agent inference 的剩余跨上游验证（基础已实现，完整 E2E 未完成）

Intatis 当前已经有 secret-free、不可变的 `AgentInferenceBinding`、版本化 connection/profile/catalog resolution、Agent 级 binding 与显式 rebind；main 与 reviewer 也可登记为安全身份独立、初始 inference 配置相同的两个 Agent。因此“每个 Agent 能保存并解析精确 inference 身份”不再是未实现项。Phase D 剩余的是把这套基础扩展并验证到真实多上游、非 OpenAI wire API 与 full-history fork，而不是重新发明 binding：

1. 验证同一 session 下相同 model、不同 reasoning effort。
2. 验证不同 Agent 使用不同 provider/base URL/chat endpoint。
3. 验证 full-history fork 在保留上下文时可选择不同 model/reasoning profile。
4. 验证 role/profile 无权修改 permission/capability/workspace lease。
5. 修订旧研究报告中已过时的 full-history fork 结论，并保留旧/新 commit 差异。

### Phase L：应用级 session runtime 生命周期（已实施）

1. `AppSessionRuntimeManager` 以 exact `{SessionKind, SessionID}` 在进程级持有 Chat/Code/Cowork runtime；窗口级环境只持有自己的 mode/session 展示选择。Cowork runtime 创建 single-flight，provider registry 更新广播到已存在 runtime。
2. session/page/mode 切换、History、Command-W 与关闭最后窗口只改展示/订阅，不隐式 stop/cancel；Command-N 新窗口连接同一 manager。manager 发布 runtime status/removal，删除只 drain exact runtime，并让其他窗口退出已删除详情。
3. Chat/Code/Cowork shutdown 均为 idempotent admission fence：先拒绝新工作，再取消并等待已登记的 send/provider/tool/direct-operation task，随后解决 permission waiter、关闭 EventLog subscription、释放 workspace security scope。Cowork 的 settings/workspace/agent/Goal/permission 等公开 mutation 统一登记，quiesce 后不能产生遗漏写入。
4. Command-Q 使用 AppKit terminate-later；manager 先 quiesce，再同时广播所有 runtime stop，并用 `BoundedSessionRuntimeShutdown` 的单调 bounded deadline 收集 settled/timedOut。超时后允许进程退出，但不能把仍 stopping 的 runtime 伪造为 settled；termination reply 只发送一次。
5. 冷启动 `GoalRuntimeController.start()` 是 reconcile-only：strict replay/recovery/checkpoint/audit 后将 active Goal durable pause，预算耗尽时保持 budget-limited；失败则 fail closed。历史 queued/running root submission 仍 interrupted/显式 Retry；crash 时的 running/stopping 由恢复投影显示 interrupted。只有显式 Send、Retry、Resume 或 CLI data-plane command 才继续。
6. `Apps/intatis-cli/Sources/Interactive.swift` 不再在启动时无条件 resume；普通消息只打开新任务边界，`/auto|/default` 和 `/goal resume` 是历史数据面显式恢复动作。
7. 建立独立测试与 Computer Use 矩阵，覆盖窗口关闭、多 session 并行、正常退出/重开、精确进程强杀、单 session 显式 Resume 和不合作 runtime 的 deadline。

Phase L 仍保持与 Phase S/A/B/C 分离；它触及相同 session/runtime 数据，但没有重解释 EventLog、submitted intent、permission 或 tool settlement 合同。

## 15. 测试契约与 Phase S / Phase A / Phase B / Phase T / Phase C / Phase L 验证证据

### 15.1 composer、本地提交与状态重建

- 打开任意历史 session：先只读/对账本地状态；recovered root submission 不自动发 main/reviewer API，active Goal durable pause且只有显式 Resume 才继续。
- reviewer failed：输入可编辑；Send 被接受；普通主模型请求可继续，只有真实 ask-class tool 才受 reviewer failure 影响。
- main inference unresolved：输入可编辑；Send 被接受并保留为 execution-blocked/retryable，不静默 return。
- Goal/任务状态仍在重建：输入可编辑；Send payload 被保留，远端执行等待或明确失败。
- pending permission：输入可编辑，审批解决前后草稿字节级一致。
- `isWorking == true`：仍可编辑下一条；submit 后按确定的 FIFO 策略处理。
- 文本和附件在 Send 时冻结；后续 UI 编辑不会改变已经提交的 payload。
- provider/network failure 后重试沿用同一 submission identity，不重复插入用户消息。
- canonical EventLog 不可写时，不显示伪成功；local outbox/unsaved 状态保留原内容。
- outbox payload first-write-wins；wrong session、symlink/hardlink/unsafe owner/mode、重复 identity 与 conflicting payload fail closed。
- attempt 必须从 1 开始并单调；跳号、低 attempt、同 attempt terminal rewrite、orphan status 不改变用户可见投影。
- historical restored task 在新 work 可运行时仍保持 paused；显式 Retry 只运行 exact task，provider 计数增加一次，原 submission 的 `user_message` 仍只有一条。
- A → B → retry A 的真实 ContextProjector 路径不向 A 注入 A 旧 attempt 或逻辑上更晚的 B 输出；无法证明 submission 归属的内容 fail closed。

### 15.2 Phase B permission isolation 与 Phase C turn 合同（均已实施）

Phase B 的 generation/provider ownership 与 Phase C 的 response/turn outcome 是两层独立合同。Phase B focused 数字不计入 Phase A；Phase C 也有自己的 focused/full/UI 证据，不能用前一阶段数字代替。当前代码已实现 Decline/Cancel 分离、typed failure、RequestID first-write/first-terminal、duplicate/reconnect idempotence、FIFO 与 cleanup-before-terminal；“remote”在这里指可由未来 transport 复用的 durable CAS primitive，不代表仓内已经存在网络 approval server。

- reviewer timeout/cancel：只 fail closed 当前 call；claim 前取消 settle deny，claim 后取消保留唯一 verdict 但 delivery deny；下一次 review 使用 fresh generation，旧 allow 到达后不得改变 settlement 或授权副作用。
- reviewer provider/factory failure：不得把整个 session 标成永久不可用；下一代可恢复。
- replacement control plane 不继承 retired generation；disable quiesce 后若 detach 落盘失败并 resume，必须使用 fresh generation。
- terminal claim 后、settlement append 返回前取消：只允许一个 durable reviewer settlement，最终 authorization delivery deny；控制面测试验证 delivery，Orchestrator attach 集成验证不会登记目标 Agent，AgentLoop 另有 permission-await 后 cancellation fence。
- Decline：同一 `call_id` 产生 `success=false` tool result，模型可继续并完成 turn。
- Cancel：turn 进入 interrupted，不向模型注入伪造的“用户拒绝”tool result。
- late/duplicate approval：不执行工具，不改变 terminal state。
- 同进程重新显示：重放完全相同的 pending review identity/payload。
- interrupt cleanup：execution task 先停，approval waiter 后释放；事件顺序稳定。
- runtime/setup failure：UI 永远不能显示成 user declined。
- 多审批：FIFO；remote resolution 可删除任意项而不改变剩余顺序。

### 15.3 sandbox 与 durable execution

- 普通 exit-nonzero、一般 EPERM 或目标程序伪造 wrapper-like stderr 不得分类为 sandbox denial，也不触发 escalation retry。
- 只有可信 wrapper startup marker 证明目标尚未进入、且诊断匹配 sandbox wrapper startup failure 时，才返回 typed `sandboxDenied`；AgentLoop 以 `denied/not_started` 结算当前 call。当前实现不自动 retry、不扩大权限、不移除 sandbox。
- denied-read 不得通过无 sandbox retry 绕过。
- allow 只有 durable settled 成功后才能驱动 execution。
- cancel/timeout 后任何 late allow 都不能使工具执行。

### 15.4 per-agent inference profile

- same provider/model + different reasoning/options。
- different model + same provider。
- different provider/base URL/wire adapter。
- profile revision/fingerprint 不匹配时 fail closed。
- task frozen binding 与 live agent binding 不一致时拒绝 admission/execution。
- credential 不进入 EventLog、prompt、tool schema 或错误文本。
- inference role/profile 无法改变 capability、permission 和 workspace lease。

### 15.5 session 存储与迁移（Phase S 已实现并通过）

- 验证新 session 的 main/reviewer 登记处于同一个严格七事件 durable batch，初始 exact binding 相同、lease/identity 不同，并且 provider 调用计数为零。
- 验证全局 provider/endpoint catalog 和 credential 不复制进 session；`defaultProviderID` 旧字段可解码但 canonical re-encode 后消失，bookmark bytes 只存在于专用 plist。
- 验证 `session.json.projectedThroughSeq` 落后、缺失、损坏、同 watermark 伪造或 lagging cache 被篡改时，由完整 EventLog canonical fold 重建且 EventLog 获胜。
- 验证未知未来事件会阻止旧客户端覆写投影，unsupported schema/session mismatch/无效 settings history fail closed。
- 验证旧 EventLog/Envelope 继续可解码，Chat/Code 的 display name 更新不要求 Cowork settings，rename 通过 EventLog-first revision 演进。
- 验证 legacy display name 在 EventLog settings+marker 提交前不会被 schema-v2 rebuild 覆盖；append 失败以及 batch 已提交但 rebuild 前中断都可幂等重试。
- 验证 EventLog append 返回值、subscriber、checked replay 与实际 JSONL bytes 使用同一 canonical Envelope，不因 decode-only provider 字段或日期精度产生 settings revision 漂移。
- 验证 `workspace-access.plist` schema/version/session/path/单 primary 约束、二进制编码、owner-only 权限、并发锁、原子写入、读回验证、primary refresh，以及默认拒删 primary/仅显式事务回滚允许删除。
- 验证 legacy settings/bookmark 迁移的 provenance、精确 path、幂等 marker、失败保留、成功后清理，以及 marker 存在后不得回退到全局旧 map。
- 验证历史 session 缩减/缺失 main 时可用 canonical settings 做宿主授权的本地恢复，profile/path/binding 不一致时拒绝；登记恢复本身不发模型请求，普通 recovered root submission 保持 paused；active Goal 冷启动 pause/显式 Resume 由 Phase L 自动化另行覆盖。
- 验证历史 main 恢复的初检和最终 CAS 都复用 `SessionProjectionStore` 的严格 revision fold；`rev1 → rev3` 等非法链 fail closed，`Int.max` revision 不会整数溢出崩溃。
- 静态/构建与独立终审复核共享 workspace 的引用安全清理、primary 的 UI/方法/store 三层保护，以及符号链接 legacy path 的首次 scope-first alias→canonical、无关 stale evidence 不阻断收敛和 marker 前崩溃重试；这些 App Sandbox 交互矩阵尚未建立独立 GUI 自动化。
- 未来若引入 SQLite，仍只能作为可删除、可重建投影；Phase S 没有引入 SQLite。

### 15.6 Phase A 自动化与构建验证

Phase A 的定向验证覆盖：提交协议/legacy decode、TaskContract submission correlation、outbox crash-safe admission、合法状态机、Code/Cowork 投影、ArtifactStore owner-only/并发写入、精确 ContextProjector 边界、AgentLoop retry history、mention route、Orchestrator restore pause/exact retry、automatic reviewer fail-closed，以及 macOS app compilation。最终命令、测试数量和结果统一列在 `VALIDATION_RESULT`，避免把中途失败重跑或旧 Phase S 数字冒充最终结果。

这些测试使用 fake/capturing provider，只验证“何时会/不会发起 provider request”、请求上下文与调用次数；没有使用真实 endpoint/key，因此不评价真实模型输出质量、网络重连或 provider cancellation 行为。

### 15.7 Phase T tool settlement 与 task-local recovery

- 协议：typed `not_started` / `committed` round-trip；旧 settled event 缺 `effectDisposition` 时继续解码为 `nil`。新成功执行显式 committed，legacy succeeded/nil 仅兼容解释为已完成，`succeeded + not_started` 无效且 uncertain。
- 投影：每个 executionID 保留首张 prepare；相同或不同 duplicate prepare 都永久 ambiguous。完全相同的 duplicate settlement 幂等保留首条，冲突 terminal 永久 ambiguous；ambiguous、mismatched/earlier settlement 均不能证明 `not_started`。无有效 settlement、显式 unknown、legacy failed/cancelled/denied + nil 与 success/not_started 都进入 uncertain；legacy succeeded/nil 仍阻断 whole-task replay。
- AgentLoop：typed no-effect failure 同批持久化 result/settlement、下一模型请求只收到一次错误；pre-executor cancel 结算为 `cancelled/not_started` 后仍抛出取消并中断；executor-entered cancel 与普通 non-replayable error 保持 unresolved；成功路径写 `succeeded/committed`。
- WorkTask：只有 production Orchestrator adapter 在 task ID / expected / actual revision 精确匹配时，把 `task_update.stale_revision` 转为 typed no-effect rejection；消息携带 authoritative revision 并要求先 `task_get` 再重试，任意 manager 不能伪造 no-effect，其他错误类型不被吞掉。
- complete-known history：restore/legacy repair、Goal startup、进程内 launch 与 whole-task retry 都使用 `replayForProjectionChecked().hasCompleteKnownHistory`；unknown future event 与 `seq` gap 不能提供 absence/order proof，均 fail closed。
- legacy restore：仅无 current Goal 时，exact current record、无 ambiguous history、executionID 从未出现 settlement、typed intent、唯一非空 task resource、JSON safe integer expected revision 与 prepare 前 `actualRevision > expectedRevision` 全部成立才补 settlement；复用 execution ID、duplicate prepare、任意既有 settlement、越界数值、current Goal、`actualRevision < expectedRevision` 等对照保持不修复。
- Goal startup：无 Goal 时要求 complete-known history、contract-before-prepare、positive exact attempt、terminal-after-prepare；terminal/nonterminal/missing/unscoped/mismatched、unknown future event 与 seq-gap 等正反例均覆盖。存在 current Goal 时不做 legacy repair，任何 uncertain effect 仍 fail closed。
- 六个 suite 的合并 focused 回归实际执行 **128 tests / 0 failures**：`ToolExecutionProtocolTests` 5、`ToolExecutionProjectionTests` 8、`AgentLoopPolicyTests` 29、`WorkTaskRuntimeTests` 13、`GoalRuntimeControllerTests` 31、`OrchestrationReliabilityTests` 42。这些是相关 suite 总数，不冒充 128 个全部为 Phase T 新增测试。

### 15.8 Computer Use 的真实 macOS UI 与磁盘验证

Computer Use 分两轮验证。第一轮是 **Phase S 实施验证轮，发生在 Phase A 之前**，使用当时的 Debug app 验证了三条用户可见路径：

1. 新建 Cowork session，选择测试 workspace 后，UI 显示 main 与 `@permission-reviewer` 两个已登记身份，reviewer 为受限控制面身份；未输入、未点击 Send，也没有出现模型生成或 permission review 请求。
2. 关闭当前展示再从历史列表恢复同一 session，UI 按 session-owned settings/bookmark 恢复原 workspace 和 roster，没有要求用今天的默认 provider/model 重建，也没有启动普通 recovered root task；该 Phase S 样本没有 active Goal，active-Goal 冷恢复由 Phase L 的 controller tests 与离线 lifecycle fixture 分别验证。
3. 在 App 退出后临时移走该测试 session 的 `workspace-access.plist`：再次打开时 UI 明确显示 reviewer 无法启动、`Reauthorize Workspace`、`1 agents · 0 running`。当时的旧实现会禁用 composer；这正是 Phase A 要删除的历史行为，不能再当作当前契约。选择错误目录不会重建 capability，选择精确原目录后才重建 schema 1 primary entry，并恢复 reviewer/roster。临时 bookmark 备份在新文件读回验证后已删除，未留下第二份 capability 副本。

首次创建后立即检查该测试 session 的磁盘状态：`events.jsonl` 开头恰好是预期七事件，当时最后 `seq == 6`，`session.json` 为 schema 2 且 `projectedThroughSeq == 6`。最终修复后的最新 Debug app 再次恢复该 session 时，UI 仍显示 `@permission-reviewer enabled`、`2 agents · 0 running`，Project sheet 中 session、binding、Reviewed 与 primary path 均正确；输入未发送草稿会启用 Send，清空后恢复禁用，期间事件数不变。最后一轮 primary 删除防线补丁后又用最新 build 打开 Project sheet，primary 行 Trash 明确 disabled，Help 为 `Primary workspace is kept with @main`，未保存设置、未发送消息。关闭 app 后 EventLog 共 37 条、最后 `seq == 36`，投影同样为 36；新增内容仍只有预期 reviewer revoke/detach/grant/attach 生命周期，开头七事件原样保留，并且始终没有 user/task/permission-review-request 事件。`session.json` 与 schema-1 binary `workspace-access.plist` 均为 `0600`，primary path 正确。UI 与最终磁盘投影一致。

第二轮使用 **Phase A 最新 Debug app** 验证当前契约。打开 reviewer 明确失败、主 inference profile 无法解析的历史验证 session `cowork_1p6ky6ga` 后：

1. reviewer failure banner 保持可见，但 `thread.composer.input` 可编辑；输入本地草稿后 Send 可用。
2. 点击 Send 后，同一提交出现稳定状态卡：先 durable accept，再以 `route_unavailable`、retryable failure 显示 `Needs attention` 与 Retry；composer 在失败后仍可继续编辑第二份草稿。
3. reviewer 不可用时仍可打开附件选择器并把本地文本文件 durable import 到 ArtifactStore；UI 显示 `1 attached`，attachment-only Send 可用。随后从当前草稿移除，且没有点击这一次附件草稿的 Send，因此这里只证明 artifact import 与 Send eligibility，不构成 submitted-intent admission，也没有发送给 provider。
4. 磁盘上只新增同一 `SubmissionID` 的三个 canonical 事件：`user_message`、attempt 1 `queued`、attempt 1 `failed(route_unavailable, retryable)`；没有 task、permission-review、tool 或 model-output 事件，session outbox 已完成 reconciliation 后消失。这证明“点击 Send 接受本地意图”与“能否登记/解析远端执行条件”已经解耦。

这轮 UI 验证没有真实 provider 请求。它有意向上述历史验证 session 追加了三条测试提交事件；导入附件产生的 content-addressed blob 可能保留为未引用 artifact，这也暴露了 ArtifactStore 后续需要 orphan/GC 策略的事实。

### 15.9 Phase C outcome、并发与隔离 UI 验证

- 八个 focused suite 合并执行 **126 tests / 0 failures**：`TurnOutcomeProtocolTests`、`PermissionSettlementTransactionTests`、`PermissionProjectionTests`、`AgentLoopOutcomeTests`、`SandboxDenialOutcomeTests`、`WorkspaceSandboxDenialTests`、`PermissionReviewControlPlaneTests` 与 `OrchestrationReliabilityTests`。
- 覆盖 additive/legacy decode、manual/automatic mode、approve/decline/cancel-turn、RequestID first-write 与 first-terminal CAS、exact duplicate/reconnect、conflicting duplicate fail-closed、FIFO middle settlement、Decline 后 provider 继续、Cancel 无伪 tool result、provider self-cancellation 归 runtime failure、可信 sandbox startup denial/no retry、owner/duplicate waiter cancellation，以及 provider/tool cleanup 先于 task terminal/caller return。
- 独立 scratch 的完整 `swift test --disable-sandbox --scratch-path /private/tmp/intatis-phase-c-full` 执行 **895 tests / 14 skipped / 0 failures**。首次在 managed sandbox 内启动时因 Swift/Clang module cache 不可写而失败；按环境规则允许 SwiftPM 使用其模块缓存后完整复跑通过，因此不会把首次环境失败写成源码失败。
- `xcodegen generate`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均成功。
- Computer Use 使用独立 bundle ID 的 DEBUG-only `-IntatisPhaseCPermissionFixture`。Manual 模式真实点击生产 `PermissionCard` 的 `Approve Call`、`Decline Call`、`Cancel Turn`，分别得到 `write_file approved`、`write_file call declined`、`Turn cancelled`；Automatic 模式显示 reserved reviewer 与 `Automatic review in progress…`，三个 manual action 不存在。fixture 声明且源码保证不创建 provider、EventLog、credential resolver、responder 或 executor，所以这只验收 UI 语义与 automatic non-actionability，不冒充端到端审批执行。
- 首次以 LaunchServices app-path 重新定位 validation bundle 时没有保留 fixture 参数，显示了普通产品根界面；未点击、未发送、未修改设置即退出。正式验收使用 exact executable args 启动并以独立 bundle ID 读取/操作；结束后进程正常退出。

### 15.10 Phase L runtime ownership、退出与冷恢复验证

- `GoalRuntimeControllerTests` **34/34**：覆盖冷启动 active Goal 完成对账后 durable paused、预算耗尽时 budget-limited、pause append 失败 fail closed、不调用 provider，以及用户显式 Resume 后才创建 continuation。
- `BoundedSessionRuntimeShutdownTests` **5/5**：覆盖 exact `{SessionKind, SessionID}` first-wins、并发 stop 广播、单调 deadline、不合作 child 不阻塞返回、settled/timedOut 报告与 concurrent caller single-flight。
- 独立 scratch 完整 SwiftPM 命令为 `env CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-phase-l-full-validation-clang SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-phase-l-full-validation-swiftpm swift test --disable-sandbox --scratch-path .build/phase-l-full-validation`，结果 **903 tests / 14 skipped / 0 failures**；构建 49.88 秒，测试 18.514 秒。
- IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug（`CODE_SIGNING_ALLOWED=NO`，独立 DerivedData）均构建成功。最终 Cowork app-only quiesce/admission hardening 后又单独重建 macOS Debug 成功；最后修改没有触及 iOS/package 源码。
- Computer Use 使用独立 bundle ID `com.vita.IntatisPhaseLDirectValidation` 与 DEBUG-only `-IntatisPhaseLLifecycleFixture`。fixture 仅在显式 `/private/tmp` root 写 synthetic ledger，使用 fake A/B runtime；不创建生产 `AppEnvironment`、EventLog、provider、credential、workspace、PermissionEngine 或工具 executor。
- UI 矩阵通过：A 运行时切换 B 和 History，A ticks 继续且 stop count 不变；A/B 可同时运行；Command-W 后进程存活且两者 ticks 继续；Command-N 后 starts 仍为 1，证明新窗口复用 manager runtime；Command-Q 后 A/B 各 stop/settle 一次并退出；正常重开 ticks 冻结，只有 Explicit Resume A 使 A 单独继续。
- crash 矩阵通过：按 exact executable path、命令行和 launch time 确认 PID 后发送 `SIGKILL`；ledger 保留 A=`running`，重开后显示 A=`interrupted`、B=`settled` 且 ticks 不增长，Explicit Resume A 才继续。
- deadline 矩阵通过：B 使用 actor-owned continuation barrier 模拟不合作 shutdown，Command-Q 配置 700 ms deadline并在 3 秒内退出；A=`settled`，B 保留 `stopping`，没有伪造 settlement；重开把 B 对账为 `interrupted`。最终 exact process check 确认 validation executable 无残留。
- 该 fixture 证明 app owner/window/quit/reopen/deadline 状态机，不证明真实 provider 在本地 cancel 后何时停止服务端计算，也不替代真实生产 EventLog、workspace tool mutation 各崩溃点的 fault-injection。

## 16. 风险与不确定性

### 已知风险

- Phase A 已增加 stable submission、outbox、状态机和 exact-task retry；后续事件演进若绕过 `SubmittedIntentStore`、同一 EventLog transaction 或 `TaskContract.submissionID`，仍可能重新引入重复消息/重复执行。
- Phase C 已把 permission/tool/turn 的 user/policy/reviewer/sandbox/runtime/cancel outcome 结构化；但 submission admission 与一部分 setup 层的 `OrchestratorSendResult` 仍主要承载字符串。不能把 Phase C 的局部 taxonomy 夸大成所有 runtime/setup error 都已 typed，后续收口仍不得依赖自由文本决定权限或副作用重放。
- submission-bound ContextProjector 对无法证明 submission/task 归属的 legacy unscoped 内容 fail closed；这避免跨提交泄漏，但可能使非常旧的 Cowork 日志在新 retry prompt 中缺少一部分上下文。
- 任意附件已可本地 durable 保存，但当前 Cowork provider adapter 只发送 image；非 image 和 Goal attachments 会明确失败，不应被产品文案误写成“所有附件均可远端处理”。
- Phase S 已建立 `projectedThroughSeq`、canonical fold 和 EventLog-wins；后续任何 schema 演进若绕过这些入口，仍可能重新制造双权威。
- legacy 迁移的 fail-closed/provenance/marker 路径已有自动化和新测试 session 验证，但尚未对用户真实历史目录做批量迁移演练；遇到异常旧数据必须保留重新授权和重试，不得猜测。
- 共享 worker 删除与真实 App Sandbox 符号链接目录选择已完成源码复核和 macOS 构建，但本轮 Computer Use 没有创建多个共享目录 worker，也没有构造 sandbox 内 symlink legacy fixture；这两条仍需专项 UI/人工矩阵，不能由普通目录重新授权结果代替。
- main/reviewer 同批登记不等于共享安全权限；若只复制整个 Agent 对象，可能误把 main 的 tool/capability lease 给 reviewer。
- Phase B 已移除 permission reviewer 的 process-lifetime quarantine，并用 generation/terminal/fresh-provider 边界阻止迟到 allow 与重复执行；未来重构若重新共享跨请求 continuation、transport mutable state 或移除 generation claim，会重新引入同类风险。
- production OpenAI/URLSession 路径符合 request-owned stream/cancellation 契约；任意未来 provider adapter 若在 `stream()` 内同步永久阻塞、跨 request 复用 continuation 或不隔离 mutable response state，将违反协议。需要支持此类实现时必须增加 bounded dedicated thread/process transport，不能依赖 `Task.detached`。
- 旧 EventLog 对 Phase C outcome/action/mode/correlation 的兼容解码已通过；未来扩展现有 taxonomy 仍只能通过新事件或 additive optional 字段演进，不能重解释既有 wire value。
- RequestID first-write/first-terminal 依赖 complete-known EventLog history；未来 transport 若绕过 `registerPermissionRequest` / `settlePermissionRequest`、把冲突 duplicate 当重试或在 unknown/gapped history 上推断 absence，会重新引入重复授权/执行风险。仓内目前提供的是 durable transport boundary primitive，不是网络 approval server。
- Phase T 的 `not_started` 是可授权重试的强断言；任何新工具若滥用 `ToolExecutionRejectedWithoutSideEffect`，会把真实 unknown side effect 错误降级。新增使用点必须证明 mutation boundary 尚未跨越，并为 executor-entered/cancel/timeout 与 invalid `succeeded + not_started` 对照建立测试，不能只依据错误名称或描述文本。
- 重复 prepare 代表同一 executionID 可能对应多个 executor attempt，冲突 terminal 代表结果不可唯一解释；两者都永久 ambiguous，后续看似正常的 settlement 也不得解除 gate。exact duplicate settlement 只能幂等保留首条，不能覆盖历史。
- 旧 `task_update` 自动修复只在无 current Goal 时运行，并依赖 complete-known history、exact current record、无 ambiguous history、executionID 零 settlement、prepare 前的 typed intent、唯一非空 task resource、JSON safe integer expected revision 与 durable monotonic WorkTask revision；缺任何一项就保持 unresolved。terminal task-scoped unknown ticket 在无 Goal 时还必须由 `replayForProjectionChecked().hasCompleteKnownHistory` 证明 contract/attempt/terminal 时序，才只是不再冻结整个 session。unknown future event 或 `seq` gap 都不能证明“没有别的事件”；所属 task 仍禁止重放，当前尚未实现按文件/资源冲突范围自动 quarantine 后续操作。
- 多 Agent endpoint/profile 不能把任意 URL 或 secret 直接开放给模型；必须继续通过宿主批准、版本化 catalog 解析。
- “显式 Send/Retry/Resume 前不发模型 API”已覆盖草稿、附件导入、登记、recovered root submission 与 active Goal 冷启动；连接测试、目录刷新等独立网络动作仍必须有明确 UI 语义，并与对话推理清楚区分。
- Phase L 的 bounded quit 在 deadline 到达后会允许进程退出；这保证 Command-Q 不永久卡死，却不把 timed-out runtime 伪造为 settled。若未来 adapter 在 cancellation 后仍持有外部写能力，必须依赖其自身进程/transport sandbox 与下一次 EventLog reconcile，不得用延长 UI deadline 掩盖所有权缺陷。
- `AppSessionRuntimeManager` 的 exact key、窗口本地 selection、removal 广播与 Cowork operation admission fence 是同一生命周期合同；未来重构若重新让 view 持有唯一 runtime、在 session switch 调 stop，或让 quiesce 后 mutation 未登记，将重新引入后台任务丢失或退出后迟到写入。

### 尚未确认

- 本次用户实际卡死 session 的首个 reviewer timeout/cancel 对应 request ID、turn ID 和 provider。
- 本次事故实际使用的 provider adapter、其远端连接在 cancel 后何时物理终止，以及服务端是否仍继续计算；历史日志不足，仍为 `UNKNOWN`。当前仓内 shipped OpenAI/URLSession 客户端的本地 cancellation ownership 已由源码确认，但没有真实 endpoint E2E。
- 未点击 Send 的普通 draft 仍是 view-local 状态，不承诺跨 session/app 重启保存；submitted intent 已用 EventLog/outbox 跨进程保存。两者必须继续保持不同语义。
- Phase A 已选择 FIFO，而不是 steer；未来若改为 steer 必须作为新的协议/UX 变更，不能复用同一 submission 状态后静默改变执行顺序。
- 真实 provider/network failure 的完整 retryability 分类、provider cancellation 能力和长期 outbox fault injection 尚未做真实 E2E。
- 尚未拿用户真实 legacy session 做 Phase T restore 演练，因此不能声称那条历史 ticket 一定满足 proof-based 自动修复条件；缺 intent/resource/revision 证据时会按设计保持 unresolved。
- 真实 process-kill 发生在 `tool_execution_prepared`、executor entry、WorkTask append 与 settlement 各边界时的磁盘矩阵尚未执行；当前证据来自 deterministic fake/gated tests。
- 真实 provider 在本地 cancellation 后何时停止服务端计算，以及真实生产 session 在 provider/tool/workspace mutation 各精确崩溃点的 reopen 状态矩阵仍未实机验证；Phase L 的离线 fixture 不能替代这些证据。
- 长时间真实 workspace 下的多窗口、多 session 并行、macOS 内存压力/睡眠唤醒与 security-scoped bookmark 生命周期仍需要设备级 soak；当前 manager/lease 代码、构建与 synthetic Computer Use 已通过，但这些场景仍为 `UNKNOWN`。

## VALIDATION_RESULT

已执行：

- Phase S + 终审回归 focused tests：137 个通过，0 失败。
- Phase A focused tests：122 个通过，0 失败，覆盖 submission/outbox/projection/context/artifact/orchestration/reviewer 边界。
- SwiftPM full test：在独立 scratch 目录执行 824 个测试，其中 14 个 skipped，0 失败。
- 第一次 Phase A full run 在既有 Tools process 段长时间无新输出且尚无失败时被有界中止；相邻两个 process runner 测试随后分别 1/1 通过，最终完整复跑得到上述 824/14/0，故不把中止轮冒充失败或通过。
- `swift build --disable-sandbox`：通过。
- `xcodegen generate`：通过。
- macOS `IntatisMac` Debug build：通过。
- iOS `IntatisiOS` simulator build：通过。
- Computer Use：通过。Phase S 实施轮覆盖新建、恢复、缺 bookmark fail-closed、错误目录拒绝、精确目录重新授权和 primary 删除防线；Phase A 最新轮覆盖 reviewer failed 时 composer 仍可编辑、文本 Send durable accept、route failure 状态卡、Retry、继续编辑，以及附件的 durable ArtifactStore import/attachment-only Send eligibility。附件草稿未点击 Send；EventLog 的 `user_message → queued → failed` 只来自前一条文本 submission，outbox 已 reconciliation，没有 task/permission/model 输出。
- Phase C focused：八个 outcome/permission/projection/sandbox/reviewer/orchestration suite 合并 **126 tests / 0 failures**。
- Phase C 阶段完整 SwiftPM：独立 scratch 执行 **895 tests / 14 skipped / 0 failures**。首次 managed-sandbox module-cache 权限失败已按环境规则复跑，不计为源码失败。
- Phase C 当前构建：`xcodegen generate`、IntatisMac macOS Debug、IntatisiOS Simulator Debug 均成功。
- Phase C Computer Use：独立 validation bundle/离线 fixture 的 Approve Call、Decline Call、Cancel Turn 与 automatic non-actionable 均通过；fixture 无 provider/EventLog/credential resolver/responder/executor，未发送模型请求。首次 LaunchServices 重新定位未保留 fixture 参数时只显示普通根界面，未进行点击/发送/设置修改即关闭。
- Phase L focused：`GoalRuntimeControllerTests` **34/34**，`BoundedSessionRuntimeShutdownTests` **5/5**。
- Phase L 当前完整 SwiftPM：独立 scratch 执行 **903 tests / 14 skipped / 0 failures**。
- Phase L 当前构建：IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug 均成功；最终 app-only hardening 后 macOS Debug 再次成功。
- Phase L Computer Use：独立 bundle/离线 fixture 的双 session 后台运行、session/History 切换、Command-W、Command-N 复用、正常 Command-Q/reopen、exact PID `SIGKILL`/interrupted reconcile、显式单 session Resume 与 700 ms uncooperative-runtime deadline 均通过；最终无验证进程残留。fixture 不创建真实 provider/EventLog/credential/workspace/tool executor，未发送模型请求。
- `git diff --check`：通过，无 whitespace error。

Phase B 本轮新增验证：

- 八个权限/编排 suite 合并执行 **164 tests / 0 failures**：`ToolRegistryLeaseTests` 13、`PermissionReviewProtocolTests` 10、`PermissionReviewControlPlaneTests` 29、`AutomaticPermissionReviewTests` 30、`AgentLoopPolicyTests` 27、`AgentInvocationNonRecursiveTests` 11、`SpawnAgentPermissionTests` 10、`OrchestrationReliabilityTests` 34。
- 确定性覆盖 timeout/cancel 后 fresh generation、旧代 late allow 无效、replacement 不继承旧隔离、provider factory 单次失败恢复、真实工具第一次 timeout 不执行/第二次 fresh allow 只执行一次、terminal claim 后 cancellation、pre-submit caller cancel 不误报 shutdown、caller-cancelled attach 不登记 Agent、post-review inference resolution 暂停期间取消不能提交 attach，以及 disable-quiesce/detach-failure/resume 竞态；late-producer 检查均等待显式 finished ack，不依赖固定 sleep。
- `swift build --disable-sandbox`、`xcodegen generate`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均成功。
- 本轮完整 SwiftPM 先在外层沙箱内遇到既有 Tools nested Seatbelt/loopback 限制；允许脱离外层沙箱后这些 process 测试已经开始通过，但完整 run 在既有 `IntatisToolsTests` structured-process 段再次长时间无输出，被有界中止，因此不能写成 full pass 或 Phase B 源码失败。卡点附近 `testStructuredProcessShellRunnerStillSupportsToolBackendCommands` 单独 1/1 通过。
- Computer Use 启动本轮最新 macOS Debug app，恢复 reviewer failed/disabled 历史 Cowork session，确认 banner 明确显示“input remains available; ask-class tools fail closed”；空 composer 时 Send disabled，写入未发送本地草稿后 Send enabled，清空后再次 disabled。没有点击 Send、Retry、Reauthorize 或 provider 调用。

Phase T 本轮新增验证：

- 合并执行 `ToolExecutionProtocolTests`、`ToolExecutionProjectionTests`、`AgentLoopPolicyTests`、`WorkTaskRuntimeTests`、`GoalRuntimeControllerTests` 与 `OrchestrationReliabilityTests`，共 **128 tests / 0 failures**。
- 其中各 suite 总数分别为 5、8、29、13、31、42；覆盖 legacy optional-field decode、新成功显式 committed、`succeeded + not_started` invalid/uncertain、duplicate prepare 永久 ambiguous、duplicate identical settlement 幂等、conflicting terminal ambiguous、typed no-effect/model continuation、pre-executor settlement + turn cancellation、executor-entered cancellation、production adapter stale conversion、任意 manager 不得伪造 no-effect、zero-settlement/non-ambiguous legacy repair，以及 restore/Goal startup/进程内 launch/whole-task retry 对 unknown future event、seq gap 与 incomplete order proof 的 fail-closed。
- 执行命令：`SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-phase-t-swiftpm-cache CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-phase-t-clang-cache swift test --disable-sandbox --filter 'ToolExecutionProtocolTests|ToolExecutionProjectionTests|AgentLoopPolicyTests|WorkTaskRuntimeTests|GoalRuntimeControllerTests|OrchestrationReliabilityTests'`。
- 最终源码后执行 `swift build --disable-sandbox`，构建成功。Phase T 未运行 full SwiftPM、Xcode/UI、真实 provider 请求或真实 legacy session restore 演练；不能把其他阶段的这些验证记录归到 Phase T。

没有运行真实 provider 请求，也没有迁移用户的真实 legacy session。Phase A UI 验证曾有意向上述历史验证 session 追加三条测试提交事件；Phase B UI 验证只改写并清空本地草稿，没有提交事件；Phase L 只写 `/private/tmp` synthetic fixture ledger。“登记/冷恢复不发模型请求”由 provider-counting 自动化测试、Goal controller tests 和 fixture 边界共同覆盖。

## UNCERTAINTIES

最重要的不确定性仍是事故的具体首发日志。报告确认旧代码曾存在“provider call 内 timeout/cancel 后的 session/process 级 reviewer quarantine”路径，并已由 Phase B 替换；composer 多条件 gating 则是已确认并由 Phase A 移除的旧路径。报告没有把尚未读取到的 runtime request ID、事故当时实际 gating predicate、真实 provider cancellation 行为或时间线冒充为已证实事实。

Phase S 已经固定并实现 `workspace-access.plist` 的文件名、schema 1 binary plist、`0600`、原子写入、读回验证、stale refresh 与精确 path 重新授权策略。Phase A 已固定 `submitted-intent-outbox.json` schema 1 和 FIFO；Phase B 已固定 reviewer generation、terminal claim、fresh provider factory 与 legacy decode 边界；Phase T 已固定 typed no-effect 与 unknown-side-effect 的分界；Phase C 已固定 user-decline/turn-cancel、RequestID first-write/first-terminal、FIFO、typed failure、sandbox no-retry 与 cleanup-before-terminal；Phase L 已固定 app-level exact runtime ownership、切换/Command-W 不停止、Command-Q bounded shutdown、冷启动 reconcile-only 与显式 Resume，因此这些不再是 `UNKNOWN`。仍未定稿或未实机验证的是网络 remote approval transport、真实 provider cancellation 的服务端停止时序、process-kill pending approval/tool mutation replay、Linux bwrap、任何 current Goal 的 unknown-ticket 资源级 reconciliation，以及未来是否需要可删除的全局 SQLite 投影。

旧报告在旧 commit 上的历史准确性本轮也未重新验证；这里只能确定其 full-history fork 结论不适用于当前审计 commit。

## NEXT_RECOMMENDED_ACTION

Phase S、Phase A、Phase B、Phase T、Phase C 与 Phase L 已完成当前范围。不要把 Phase L 的冷启动 pause/显式 Resume 夸大成已经解决 current-Goal unknown-side-effect 资源级自动 reconciliation；后者仍必须 fail closed，也没有授权在本轮继续扩张。

下一步只有在用户明确授权后再选：若验证历史 ticket，先只读检查 legacy session 的 ticket/projection，再决定是否满足 proof-based settlement；若验证权限/生命周期链，优先做隔离测试账号下的真实 provider/remote transport/process-kill pending approval/tool mutation E2E，不得使用用户生产 session 或真实密钥作为默认测试材料；若推进产品能力，则 Phase D 的真实多上游仍应独立设计、独立授权。当前不自动继续改业务源码。
