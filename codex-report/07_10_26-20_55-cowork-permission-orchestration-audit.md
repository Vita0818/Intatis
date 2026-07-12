# Cowork Permission Reviewer 与多 Agent 编排问题分层报告

## MODEL_CHECK_RESULT

GPT-5。

## PATH_CHECK_RESULT

- 当前目录：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者一致，符合项目要求。

## FILES_WRITTEN

- 报告：`codex-report/07_10_26-20_55-cowork-permission-orchestration-audit.md`
- 特殊审查控制面：`PermissionReviewControlPlane.swift`、`AgentPermissionResponder.swift`、`Orchestrator.swift`、GUI/CLI Cowork 接入与 `PermissionReview.swift`
- 通用执行与恢复边界：`AgentLoop.swift`、`AgentExecutionBudget.swift`、`EventLog.swift`、`Leases.swift`、`ToolExecution.swift`、`PathConfinement.swift`、`ShellGit.swift` 及相关结构化 process/browser/document runner
- 回归：`PermissionReviewControlPlaneTests.swift`、`AutomaticPermissionReviewTests.swift`、`OrchestrationReliabilityTests.swift`、`AgentLoopPolicyTests.swift`、`WorkspaceLeaseTests.swift`、`PathConfinementTests.swift`、`IntatisToolsTests.swift` 及协议/投影兼容测试
- 项目说明：`docs/CURRENT_STATE.md`、`docs/PROJECT_MAP.md`、`docs/ARCHITECTURE.md`、`docs/DO_NOT_BREAK.md`、`docs/TESTING.md`、`docs/NEXT_TARGET.md`、`docs/COWORK_PRINCIPLES.md`

> 仓库在本轮开始时已有大量用户未提交改动；上面只归纳本次权限/编排修复直接涉及的文件组，未覆盖、回退或清理其他改动。第 2 节起的原始 finding 文字保留作根因记录，不代表当前实现仍未修复。

## REMEDIATION_IMPLEMENTATION_STATUS

> 安全修复流程结论：`fixed`。下表是当前代码状态；第 2 节起保留的是修复前审计快照，用于记录根因与设计取舍，不表示这些缺陷仍然可达。最终合并后的 reviewer、AgentLoop、Orchestrator、workspace lease 与非 Tools 全套 XCTest，以及 macOS、iOS Simulator、CLI 构建均已通过。剩余项是需要真实 provider、设备或允许启动受管子进程的环境验证，不再是已知代码阻断。

| Finding | 当前状态 |
|---|---|
| S-01 / S-02 | 已实现独立 `PermissionReviewControlPlane` FIFO/single-flight、结构化 `PermissionReviewTask` 和 64 项有界队列，不占普通 scheduler 槽；排队即计入端到端 deadline；底层 provider timeout 后若仍未退出，后续审查先走人工 fallback，避免真实调用重叠；AgentLoop 传入 task/attempt/tool/path/side-effect/gate/lease/context |
| S-03 | 已实现 `permission_review_requested/settled`；allow 必须 settled 成功后返回，持久化失败 fail closed；重启时 orphan request 会补 deny/cancelled settlement |
| S-04 | GUI 已显示 disabled/enabling/enabled/fallback/failed，失败可重试；CLI disable 返回 disabled/already-disabled/failed，不再把落盘失败误报成成功 |
| S-05 | hard deny/self-review 终局，reviewer 只能收窄 deterministic 最大边界 |
| C-01 | production Code/Cowork registry 与新 coordinator lease 均已移除 raw `run_shell`；WorkspaceLease 持久化 canonical root 的 device/inode identity，并在 attach、权限请求前、批准后、durable prepare 后紧邻 executor、retry/派生 lease 与 process 启动前复核，目录替换时 fail closed；通用文件工具禁止读写 `.git/config` / `config.worktree`；保留 runner 使用 macOS Seatbelt / Linux bwrap（缺失时 fail closed）的 workspace allow-list、最小环境与默认 network deny |
| C-02 | tool intent、permission resolution、execution prepare 改为 durable-first；关键审计失败不执行工具 |
| C-03 | 新增 tool execution prepare/settle ticket；未决非幂等或协作副作用恢复时要求人工对账，不自动重放 |
| C-04 | provider timeout 使用不等待迟到任务的 bounded race；process 使用有界 capture 与 TERM→KILL 清理 |
| C-05 | EventLog append/batch 使用跨进程 flock + 锁内 seq CAS；production `Orchestrator.runtime` 自动持有 session writer lease |
| C-06 | detach 与 task/default lease revoke 改为 persistence-first batch，再提交内存状态 |
| C-07 | provider dispatch 前预留共享预算并传 output ceiling；因 provider 差异明确标为 soft token budget |

Per-agent provider/model routing 仍按原报告结论保留为未来通用 feature，不算本轮 defect。验证证据与尚未重跑项以 `docs/TESTING.md` / `docs/NEXT_TARGET.md` 为准。

## REMEDIATION_VERIFICATION

- 已通过（最终动态回归）：`PermissionReviewControlPlaneTests` 17/17、`AutomaticPermissionReviewTests` 12/12、`OrchestrationReliabilityTests` 28/28、`AgentLoopPolicyTests` 14/14、`WorkspaceLeaseTests` 4/4；`swift test --skip IntatisToolsTests` 共 401 项、0 failure。
- 已通过（构建）：IntatisMac Debug、IntatisiOS generic Simulator Debug（arm64 + x86_64）与 `intatis` CLI product build。
- 已通过（静态与分阶段证据）：生产 GUI/CLI 均从 `Orchestrator.runtime` 获取 session writer lease；生产 registry 无 `RunShellTool` / `run_shell`；关键 permission/tool execution 事件为强制持久化；raw-shell target 编译及前序独立真实 macOS confinement smoke 覆盖 workspace 外/符号链接拒绝、默认断网、cancel/timeout 和双流大输出。
- 已通过（独立只读复核）：最新快照未发现仍会阻止 `fixed` 的 P0/P1；复核覆盖 reviewer queue/durable verdict/quarantine、原子启停与恢复清理、AgentLoop 三次 root identity 复核、非可重放恢复、EventLog writer lease/seq CAS 及 Seatbelt/bwrap fail-closed。
- 环境限制：最终 `IntatisToolsTests` 在当前外层受限环境中完成编译与发现，但需要嵌套 `sandbox-exec` 或 loopback 的运行项会被宿主 sandbox 拒绝；修正测试夹具对 `/usr/bin/git` / `/usr/bin/python3` 的 `xcrun` 依赖后，外部运行审批额度又已耗尽，未能重跑最后三项 process/Git 窄回归。没有发现对应源码断言失败，且相关 target、测试 bundle 与三端产品均可编译。
- 仍需真实环境验证：真实 provider/key 与 GUI 人工流程、Linux bwrap、真实浏览器/设备和长时间 crash/recovery 压力矩阵。
- 原问题不再可达的静态证据：模型可见工具注册表不再注册 `run_shell`；自动 allow 必须在 `permission_review_settled` 成功后返回；工具执行必须先写 `tool_execution_prepared`；未决非可重放副作用在恢复时进入人工对账而非自动重放。
- 合法行为保留证据：结构化 Git/browser/document 工具仍在各自 capability 下注册；普通 read-only 恢复仍可重排；人工 permission fallback、GUI/CLI session 启动与旧 JSONL 可选字段兼容路径保留。

## 1. 报告目的

本报告把当前 Cowork 权限与多 Agent 编排问题严格拆成两个层面：

1. **Permission Reviewer 的特殊控制面问题**：只讨论 `@permission-reviewer` 作为保留特殊 Agent 的生命周期、上下文、执行方式、决策与审计。
2. **多 Agent 编排的共性问题**：讨论所有 Agent 都会遇到的 capability/workspace 边界、工具执行、持久化、恢复、取消、预算和模型路由。

这两个层面必须分开治理。Permission Reviewer 的专用修复不能掩盖底层执行边界问题；底层通用修复也不能替代 reviewer 自身的控制面建模。

## 2. 结论摘要

当前实现已经具备 Permission Reviewer 设计的主要外形：Cowork session 默认创建保留身份 `@permission-reviewer`，它是 read-only、无工具 lease，收到权限请求后读取上下文并返回 `allow`、`deny` 或 `ask_user`；hard deny 不会交给 reviewer，`ask_user` 会回退人工。

但 reviewer 目前不是一个完整的独立控制面 Agent。它实际上是嵌入 `PermissionResponder` 的一次性 provider 调用：没有正式的 PermissionReviewTask、没有 reviewer 专用队列和单飞约束、没有完整 TaskContract/lease 上下文、没有独立 timeout/token accounting，决策记录也不是 durable-first。

同时，多 Agent 共性层仍存在 raw shell 逃逸工作区、权限审计 fail-open、崩溃后重复副作用、非协作任务无法硬取消、EventLog 多写者冲突等问题。当前最高风险是一条**跨层组合链**，而不是单一 reviewer 缺陷：

```text
Reviewer 基于不完整权限事实给出 allow
        ↓
权限决定未保证先持久化
        ↓
通用执行层允许未沙箱化的 raw shell
        ↓
命令可访问工作区外的文件和网络
```

“main 与 permission reviewer 当前通常使用统一 provider/model”不再列为现有 P0 缺陷。它应归入未来通用的 per-agent provider/model routing 能力；即使 reviewer 改用不同模型，上述跨层问题仍然存在。

---

## 第一部分：Permission Reviewer 的特殊控制面问题

## 3. 当前已经实现的行为

### 3.1 默认生命周期

- GUI Cowork start 时先恢复 session，然后尝试启用 `@permission-reviewer`，再 bootstrap `@main`，最后恢复 pending tasks。
- CLI Cowork 同样先启用 reviewer，再 attach/恢复 `@main`。
- reviewer 是保留 AgentID，不能作为普通消息、委派、删除或执行目标。
- reviewer Agent 使用 `.readOnly` profile、空工具 capability lease、`coordinationDepth = 0`。

主要证据：

- `Apps/IntatisMac/Sources/CoworkViewModel.swift:179-207`
- `Apps/intatis-cli/Sources/Interactive.swift:253-296`
- `Packages/IntatisCowork/Sources/Orchestrator.swift:430-511`

### 3.2 决策流程

当前权限链路为：

```text
CapabilityLease / WorkspaceLease
        ↓
DeterministicPolicyGate
        ↓
PermissionEngine
        ↓
AgentPermissionResponder（自动 reviewer）
        ↓
allow / deny / ask_user
```

- capability 不存在、workspace lease 不匹配：在进入 reviewer 前拒绝。
- deterministic hard deny：终局拒绝，不发送 reviewer。
- 普通写入、shell、网络、破坏性操作：产生 `ask_user`，优先交给自动 reviewer。
- reviewer 返回 `ask_user`、无法解析或 provider error：回退人工 responder。

主要证据：

- `Packages/IntatisPermission/Sources/DeterministicPolicyGate.swift:11-110`
- `Packages/IntatisPermission/Sources/PermissionEngine.swift:21-41`
- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:30-77`

### 3.3 Reviewer 当前可见上下文

Reviewer 当前会收到：

- permission request id、requesting agent、tool、risk、gate reason、raw args；
- active agent roster；
- requesting agent scoped context；
- 最近的 user、task、tool、message、permission 等全局事件摘要。

动态内容被放在 user-role 的 untrusted block 中，review request 不携带工具。

主要证据：

- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:37-49`
- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:98-149`

## 4. Reviewer 特殊问题清单

### S-01（P1）：有独立身份，但没有独立控制面执行模型

`@permission-reviewer` 存在于 Agent registry 和 EventLog 中，但权限审查不经过 TaskGraph、AgentScheduler、mailbox 或专用 review queue。`AgentPermissionResponder` 直接调用 reviewer provider 并等待 JSON。

影响：

- 无法形成正式、可恢复的 PermissionReviewTask 生命周期；
- reviewer 不受 Agent 单飞约束；多个 Agent 可并发调用同一 reviewer/provider；
- reviewer 调用不计入正常 task timeout、attempt 和 session token budget；
- provider 若不响应 cancellation，permission wait 可能长期悬挂；
- reviewer 的运行状态不能通过统一任务投影解释。

证据：`Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:30-77`。

Reviewer 不应改成普通 AgentLoop，因为主任务会同步等待其结果；若普通 scheduler 并发上限为 1，main 占着唯一执行槽等待 reviewer，会形成死锁。正确方式是建立独立的 control-plane executor。

### S-02（P1）：Reviewer 缺少正式 PermissionReviewTask 和当前 TaskContract

构建 requester scoped context 时，当前明确传入 `taskContract: nil`：

- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:223-237`

`PermissionRequestPayload` 也没有携带完整的当前任务与租约证据。因此 reviewer 无法稳定知道：

- 当前 `taskID`、`rootTaskID`、parent task 和 attempt；
- 当前 TaskContract 的 objective、role、expected deliverable 和因果链；
- 实际生效的 CapabilityLease；
- WorkspaceLease root、read/write、allow/deny path rules；
- 工具归一化后的 touched paths 和 network classification；
- deterministic gate 的结构化结果，而不只是文本 reason/risk；
- 当前操作是否是 retry、mailbox wake 或用户 root task 的一部分。

在同一 Agent 连续处理多个 task 时，依靠 roster、最近事件和通用 agent context 可能把错误的任务上下文用于当前权限决定。

### S-03（P1）：Reviewer verdict 不是 durable-first

`recordReview` 使用 `try?` 写入 `.permissionReview`。即使审查记录落盘失败，解析得到的 `allow` 仍会返回给原 Agent：

- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:65-74`
- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift:85-95`

这使 reviewer 的决策不能作为可靠审计事实。对于自动批准路径，要求应当是：review request 和 reviewer verdict 均成功持久化后，原工具才允许进入执行阶段。

### S-04（P2）：启动失败与运行状态的 GUI 可观察性不足

GUI 调用 `enableAutomaticPermissionReview` 后丢弃返回结果；失败时会自动退回人工 responder，但用户未必能清楚知道当前 session 是否处于自动审查模式：

- `Apps/IntatisMac/Sources/CoworkViewModel.swift:345-365`

CLI 会明确输出成功或失败状态，因此 GUI/CLI 行为在可观察性上不一致。

### S-05（设计约束）：Reviewer 不能被理解为“可以批准真正越权”

Reviewer 应只判断**确定性权限上限以内**的操作是否符合任务上下文。以下情况不属于模型判断范围：

- capability 未授予；
- workspace lease 不覆盖目标；
- hard deny 命中；
- 执行期沙箱无法保证声明边界。

这些必须由确定性代码拒绝。Reviewer 的 `allow` 只能在预先限定好的安全 envelope 内生效。

## 5. Reviewer 建议目标架构

### 5.1 引入结构化 PermissionReviewTask

建议至少包含：

```text
reviewTaskID
sessionID
requestID
requestingAgentID
taskID / rootTaskID / parentTaskID
attempt
toolCallID
tool descriptor / normalized args
touchedPaths / risksNetwork / sideEffect
deterministic gate result
capability lease snapshot
workspace lease snapshot
task contract summary / user objective / causal chain
createdAt / deadline
```

### 5.2 建立 reviewer 专用控制面队列

建议新增独立 actor/executor：

```text
PermissionReviewQueue
  - reviewer 单飞或显式受限并发
  - 不占普通 AgentScheduler 数据面槽位
  - no tools
  - 禁止 reviewer 审查自身请求
  - 独立 timeout / cancellation watchdog
  - token/usage accounting
  - 不触发二次权限递归
```

### 5.3 决策必须 durable-first

推荐状态机：

```text
requested
→ reviewing
→ allowed | denied | ask_user | failed | timed_out | cancelled
```

只有 `allowed` 已成功落盘后，原工具才可以执行。`ask_user` 也必须先落盘，再交给 GUI/CLI 人工 responder。

---

## 第二部分：多 Agent 编排共性问题

## 6. 共性问题清单

### C-01（P0，发布阻断）：raw shell 绕过 WorkspaceLease 的执行期边界

`RunShellTool` 没有实现 `touchedPaths`，因此使用 Tool 默认的空路径列表。WorkspaceLease 与 DeterministicPolicyGate 看不到命令实际会访问哪些文件：

- `Packages/IntatisTools/Sources/ShellGit.swift:41-58`
- `Packages/IntatisTools/Sources/ToolProtocol.swift:164-173`
- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:332-361`

最终执行直接调用 `/bin/sh -c`，没有 OS 级文件系统或网络沙箱：

- `Packages/IntatisTools/Sources/ShellGit.swift:17-32`

字符串黑名单无法可靠识别 Python、Ruby、编码命令、间接路径或其他 shell 组合。无论 permission reviewer 使用什么模型，只要它能批准一个没有执行期边界的 raw shell，WorkspaceLease 就不是完整安全边界。

建议：

1. 在真实进程沙箱完成前，从默认 coordinator lease 移除 raw shell；或要求 raw shell 永远人工确认。
2. 优先使用参数化、可声明 touched paths/network 的结构化工具。
3. 若保留 shell，必须对 child process 实施工作区文件系统 allow-list、敏感目录 deny、默认 network deny 和进程组隔离。

### C-02（P1）：共享权限与工具执行链路 fail-open

以下事件大量使用 `try?`：

- toolCall；
- permissionRequest；
- permissionResolved；
- patchProposed；
- toolResult。

但日志失败后工具仍可能执行：

- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:456-557`
- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:761-800`

这不是 reviewer 特殊问题，而是 AgentKernel/Permission/EventLog 的共享执行问题。副作用前的 tool intent 和 permission resolution 必须强制持久化，失败时应 fail closed。

### C-03（P1）：崩溃恢复会重复非幂等副作用

恢复时，处于 `running` 的 task 会增加 attempt 并整体重新排队：

- `Packages/IntatisCowork/Sources/Orchestrator.swift:706-750`
- `Packages/IntatisCowork/Sources/Orchestrator.swift:772-799`

当前没有根据 toolCall/toolResult 对已经发生的工具副作用进行 reconciliation，也没有工具级 idempotency key。若副作用已经发生但 task terminal event 尚未写入，重启后可能重复文件写入、提交、上传、发送或外部网络操作。

建议非幂等任务在不确定状态下进入 `needs_reconciliation`，不得自动重放；或者建立持久化 execution ticket 和工具级幂等协议。

### C-04（P1）：timeout/cancel 依赖协作，无法终止阻塞进程

`withTaskTimeout` 超时后只取消 operation；结构化 task group 退出仍需等待不响应 cancellation 的子任务：

- `Packages/IntatisCowork/Sources/Orchestrator.swift:97-114`

`ProcessShellRunner` 使用阻塞的 `readDataToEndOfFile` 和 `waitUntilExit`，没有 cancellation handler 或进程组终止：

- `Packages/IntatisTools/Sources/ShellGit.swift:17-32`

`cancelAll` 又会等待所有 execution 完成：

- `Packages/IntatisCowork/Sources/Orchestrator.swift:1160-1173`

结果是挂住的 provider、shell 或工具可能永久占据 agent 槽并阻塞 GUI stop、session 切换和 CLI 退出。

### C-05（P1）：EventLog 缺少跨实例/跨进程单写者保护

EventLog actor 只能串行化当前实例。`nextSeq` 在初始化时读取一次，append 没有文件锁、session lease 或 CAS：

- `Packages/IntatisConversation/Sources/EventLog.swift:20-63`
- `Packages/IntatisConversation/Sources/EventLog.swift:99-120`

CLI 对同一个 workspace 使用稳定日志路径：

- `Apps/intatis-cli/Sources/Interactive.swift:46-65`

两个 CLI 或 app 实例同时打开同一 session 时，可能产生重复 seq、交错写入和两个调度器执行同一任务。需要进程级 session lock；长期可以考虑 SQLite/WAL 或单写者持久化服务。

### C-06（P2）：detach/revoke 未统一采用 durable-first

普通 `detach` 先从 registry 和 lease map 删除，再 best-effort 写 revoke/detached 事件：

- `Packages/IntatisCowork/Sources/Orchestrator.swift:349-392`

若日志失败，本轮运行看似删除成功，但重启 projection 仍可能恢复该 Agent 和默认 lease。自动回收 tool-spawned Agent 也会走此路径。

### C-07（P2）：session token budget 是事后检查，不是硬预算

Agent 在请求前只检查 `consumed < limit`，模型响应完成后才 charge。多个 Agent 可以同时通过检查，并在结算时才发现超额：

- `Packages/IntatisAgentKernel/Sources/AgentExecutionBudget.swift:14-39`
- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:185-227`

需要请求前原子预留、provider 输出上限和完成后结算返还，才能形成真正的 session budget。

## 7. Per-Agent 模型路由的正确归类

“同一 session 下，main、不同子 Agent、permission reviewer 可以各自使用不同 provider/model”应归类为通用产品能力，而不是 reviewer 特殊缺陷或当前 P0。

当前已有部分基础：

- `Agent` 具有 `model` 字段；
- spawn/manual attach 可以传入 model；
- AgentRequest 使用当前 Agent 的 model。

但 GUI Cowork 的 provider factory 当前仍统一解析 session 默认 provider，尚未形成完整的 per-agent provider/model 配置和路由：

- `Apps/IntatisMac/Sources/CoworkViewModel.swift:14-63`
- `Apps/IntatisMac/Sources/CoworkViewModel.swift:182-190`

建议未来引入通用配置，而不是为 reviewer 单独开特殊分支：

```text
AgentRuntimeConfig
  providerRef
  model
  reasoningEffort
  contextPolicy
  tokenBudget
  permissionProfile
```

`@main`、worker、coordinator 和 `@permission-reviewer` 均通过同一个 AgentRuntimeResolver 获取运行配置，各取所长。

## 8. 推荐实施顺序

### 第一阶段：修 Permission Reviewer 特殊控制面

1. 定义 `PermissionReviewTask` 及持久化事件。
2. 建立独立 control-plane review queue，避免普通 scheduler 死锁。
3. 投影精确 TaskContract、lease、gate、tool path/network 和 causal context。
4. 增加单飞、timeout、cancellation、usage/token accounting。
5. reviewer verdict durable-first，失败时 fail closed 或转人工。
6. GUI 明确显示 reviewer enabled/failed/fallback 状态。

### 第二阶段：修多 Agent 共性安全与可靠性

1. 禁止或真正沙箱化 raw shell。
2. 共享权限/工具执行日志改为 durable-first。
3. 引入工具执行幂等与 crash reconciliation。
4. 实现 provider/tool/process 硬 watchdog 和有界 shutdown。
5. 增加 EventLog session 单写者锁。
6. 修复 detach/revoke durability 和预算预留。

### 第三阶段：通用 per-agent provider/model routing

1. 引入 AgentRuntimeConfig/Resolver。
2. 支持 session 默认配置与 per-agent override。
3. UI/CLI 支持 main、worker、reviewer 独立选择。
4. 保留 capability、workspace、permission 和审计策略与模型选择解耦。

## 9. 验收标准

### Permission Reviewer

- 每次审查都有正式 reviewTaskID、taskID 和因果链。
- reviewer 获得当前 TaskContract 和实际 lease 快照。
- 同一 reviewer 的并发行为明确且有上限。
- reviewer provider 卡住时有硬 timeout，不阻塞 session shutdown。
- verdict 未成功持久化时，原工具绝不执行。
- `ask_user` 可恢复、可审计，GUI/CLI 状态一致。
- reviewer 无工具、不能审查自身、不能成为普通消息/委派目标。

### 通用编排

- WorkspaceLease 对所有执行路径都是真实边界，包括 shell/process。
- 崩溃后不会静默重复非幂等副作用。
- cancel/timeout 能终止 child process 和释放 scheduler 槽。
- 同一 session 不能被多个写者同时调度。
- detach/revoke 在重启后不会复活。
- token budget 在并发 Agent 下仍是硬上限或明确标注为软预算。

## PROJECT_AUDIT_SUMMARY

本报告检查了 Cowork GUI/CLI 启动、Orchestrator、AgentPermissionResponder、AgentScheduler、AgentLoop、PermissionEngine、DeterministicPolicyGate、CapabilityLease、WorkspaceLease、RunShellTool、ProcessShellRunner、EventLog、恢复/取消/预算与相关定向测试。

修复后的特殊控制面具备独立、有界、可持久恢复的 Permission Review 生命周期；通用编排层闭合了执行期 workspace identity、durable-first、非幂等恢复、强取消、单写者、撤销与 soft-budget 边界。原报告的 S-01～S-05、C-01～C-07 均已有对应实现与回归证据；per-agent provider/model routing 仍是独立通用 feature，不属于缺陷修复。

## VALIDATION_RESULT

最终验证包括 reviewer 17/17、automatic review 12/12、orchestration reliability 28/28、AgentLoop policy 14/14、workspace lease 4/4，以及排除依赖真实受管进程后端的 SwiftPM 401 项、0 failure。IntatisMac、IntatisiOS Simulator 与 CLI 均构建通过。生产工具面、唯一 runtime 构造器、entitlements、关键持久化顺序和 `git diff --check` 另做了静态核验。

Tools 测试 bundle 已编译；其最终 process/Git 运行态窄回归受当前宿主 sandbox/外部审批额度限制。此前真实 macOS process confinement smoke 已通过，未留下确认的源码失败。

## UNCERTAINTIES

- 未进行真实 provider/key prompt-injection 对抗和 GUI 人工视觉验证。
- Linux bwrap、真实设备/浏览器、长时间 crash/recovery 压力矩阵未运行。
- 同一 session 的跨进程写入由文件锁、seq CAS 与 writer lease 覆盖，但未进行两个真实 GUI/CLI 实例的破坏性压力实验。
- `ProcessGitService` 的配置静态审计与读取间，对绕过 Intatis 工具、由同一 OS 用户并发替换 Git config 的外部本地攻击者仍存在理论 TOCTOU；模型可见通用工具已禁止修改这些配置路径，当前威胁边界内不可达。若未来把本地同 UID 恶意进程纳入威胁模型，应把 Git 服务迁入更强的签名 helper/XPC 或使用 fd-pinned 配置读取。

## NEXT_RECOMMENDED_ACTION

该批安全与编排硬伤已修复。下一步只需在具备相应权限/设备的环境补跑真实 provider、macOS process/Git 窄回归、Linux bwrap、双实例 writer lease 与长时间恢复压力矩阵；这些是验证加固，不阻止当前状态记为 `fixed`。per-agent provider/model routing 继续作为独立通用 feature 处理。
