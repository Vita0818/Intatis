# COWORK_PRINCIPLES

本文提炼自仓内 `docs/COWORK_AGENT_ARCHITECTURE.md` / `COWORK_TASK_CONTEXT_MODEL.md` / `COWORK_CURRENT_FINDINGS.md` / `COWORK_MIGRATION_PLAN.md` / `COWORK_AGENT_INVOCATION_MODEL.md` 及原 `AGENTS.md` 的英文原则。它是 Cowork 架构的原则基准，**不是**当前完成度声明。修改 Cowork / AgentKernel / MessageBus / 权限 / agent 编排前必读。

## 1. 核心原则

不要把 Cowork 实现为硬编码递归 agent 树（`main`/`coordinator`/`worker`/`leaf` 永久角色）。

```text
Agent identity is persistent.
Role belongs to a task.
Permissions are temporary leases.
Context is scoped and projected.
Collaboration happens through a task graph and message bus.
AgentLoop must never directly recurse into another AgentLoop.
```

含义：一个 agent 可在一个任务里 coordinate、在另一个任务里 count files、在第三个任务里 review code。其当前行为由它收到的 task contract 与 capability lease 决定，而非硬编码类型。

## 2. 四层工作模型与五大协作抽象

Cowork 的用户目标、可见计划、宿主续跑和单次 agent 执行是四个不同层级，不得再用同一个 `Task` 词汇或同一终态代替：

```text
Goal             用户拥有、可跨多轮/重启持续的最终目标
WorkTask         Goal 或普通 run 内用户可见、可验证的计划 DAG 节点
ContinuationRun  宿主为一次推进/恢复建立的有界执行轮次
AgentInvocation  现有 TaskContract + TaskGraph + AgentScheduler 的一次 agent 执行
```

- `AgentInvocation` 完成只产生候选结果，不能自动把关联 `WorkTask` 标成完成。
- `WorkTask` 完成必须由 `task_update` 显式提交 result，并在有 acceptance criteria 时提交 evidence；依赖、revision 与状态转换由 `WorkTaskGraph` 校验。
- `Goal` 完成必须经过独立 `GoalVerifier` 对 success criteria 与 host-derived `validationEvidence` 的审计；WorkTask result/evidence 只是 agent-reported，不能由 main/worker、`TaskContract` 终态、WorkTask 数量或 UI 文案自行宣告完成。
- `ContinuationRun` 是 host-driven continuation 的 checkpoint/recovery 边界，不是递归 `AgentLoop`。一个 Goal 可跨多个 run；一个 WorkTask 可关联多个 invocation。
- `TaskContract` 这个既有源码类型保留兼容，但在产品/架构语义里称为 **AgentInvocation execution contract**；不得把它重新投影成 Goal 或 WorkTask。

上述四层与以下五个协作抽象正交。Cowork 仍围绕这些边界构建：

```text
Agent Identity          持久本地身份（id/displayName/model/workspace lease/mailbox/status）
Task Contract           每 AgentInvocation 分派的角色与交付物
Scoped Context          上下文按作用域投影，非全量原始 transcript
Capability Lease        能力按租约授予，非永久继承
Task Graph + Scheduler  任务图 + 调度器驱动协作
```

### 2.1 Agent Identity
Agent 是持久本地身份。应含 `id` / `displayName` / `model` / `workspace lease or default workspace` / `local memory or mailbox` / `status`。**不应**含永久 "leaf" 或 "coordinator" 角色。

### 2.2 Task Contract（AgentInvocation 层）
角色按 AgentInvocation 分派。Task contract 应告诉 agent 它为何存在于当前工作流、预期交付什么；它不是用户可见 WorkTask。建议 shape：
```swift
struct TaskContract {
    let id: TaskID
    let issuerAgentID: AgentID?
    let assigneeAgentID: AgentID
    let objective: String
    let roleHint: String
    let expectedDeliverable: String
    let parentTaskID: TaskID?
    let relatedTaskIDs: [TaskID]
    let relatedAgentIDs: [AgentID]
    let workspaceLease: WorkspaceLease?
    let capabilityLease: CapabilityLease
    let contextScopes: Set<ContextScope>
}
```
好的 task contract 回答：为什么创建、谁指派、交付什么、相关任务/agent、血缘。

### 2.3 Scoped Context
每个 agent 应知道**为什么**它在运行。收到 task 时，其上下文应含：
```text
global objective summary
issuer / assigning agent
its task contract
its role hint for this task
its expected deliverable
its workspace lease
its allowed capabilities
related agents/tasks
lineage showing why it was created
```
**不要**默认给 agent 整个原始全局 transcript。用 scoped projection：
```text
global brief
task group context
task-local context
agent-local history
explicitly shared artifacts
workspace-relevant observations
```

### 2.4 Capability Lease
工具应按 capability lease 暴露。普通 worker task 不应收到 coordinator 工具（`spawn_agent` / `remove_agent` / `delegate_task`）。若 task 需委派，经 `CapabilityLease.delegation` 显式授予。子 agent 不应仅因被 spawn 就获得 coordinator 能力。Git、文档/媒体与网络/浏览器工具同样按 lease 收窄：新 spawn 的 worker 默认 `read_only`，只能获得安全只读能力；用户/上级显式请求 `read_write` 且不超过 issuer WorkspaceLease ceiling 时，worker 可获得不含 coordinator 工具的 Code/data-plane 写入能力。`canCoordinate` 与 workspace access 正交：只读 coordinator 可调度但不能写 workspace，read-write worker 可执行文件工作但不能 spawn/delegate 下级。

Lease 不只是工具列表：task-scoped lease 必须核对 task ID、communication/delegation grant，并在终态撤销；WorkspaceLease 必须执行 root、read-only/read-write、allow/deny path，并固定 canonical root 的文件系统 identity。任何可能跨 await 的授权都不能只在入口校验：attach commit、权限等待后、durable prepare 后紧邻 executor、派生/retry 与 process 启动前必须复核 identity；同路径目录被替换或 legacy lease 无 identity 时 fail closed。retry 只可从原 lease 的持久审计记录克隆，缺失历史时收窄到 worker，禁止按 agent 默认角色扩大权限。

### 2.5 Task Graph + Scheduler
协作经任务图与消息总线发生。`AgentLoop` 不得直接同步递归调用另一个 `AgentLoop`——用 mailbox / scheduler / event flow。

这里必须区分两张图：`WorkTaskGraph` 是用户可见计划 DAG，校验依赖、revision、完成 result/evidence；既有 `TaskGraph` 是 AgentInvocation 执行图，配合 scheduler 管理 queue/claim/attempt。两者可以通过稳定 ID 关联，但任何一方的终态都不能推导另一方终态。

Scheduler 必须把“claim”和“执行”分开：claim 是短状态转换，同一 agent 只允许一个 running invocation；不同 agent 只能在显式并发上限内并行。普通用户输入也必须先成为 root AgentInvocation，不能绕开执行图直接跑一个不可恢复的 AgentLoop；Goal 则由宿主创建 ContinuationRun，再把该轮 root invocation 放入同一 scheduler。

Task lifecycle 是 durable state machine：
```text
created -> assigned -> queued -> running -> completed | failed | cancelled
failed | cancelled -> queued  only through an explicit bounded retry attempt
```
恢复时不能默认把所有 running 任务整段重放。每个实际 tool executor 调用前必须先持久化 execution ticket，结果持久化后再 settle；只有普通 read-only 调用可自动重放。write/exec/network/destructive 与通信、委派、spawn/remove 等协作副作用处于“prepared 但未 settled”时，任务必须进入人工对账失败态，不能自动增加 attempt。没有未决非幂等副作用的 running 任务才可在新 attempt 的 queue 事件成功落盘后重排；半完成 admission、耗尽 attempts 或缺失关键 lease 也必须明确失败。执行应有 bounded timeout/cancel、attempt 和明确标为 soft 的 session token budget；模型缺完成标记、迭代耗尽或不完整 finish reason 都是失败。

Permission Reviewer 是独立控制面，不是普通 worker：使用结构化 `PermissionReviewTask`、有界 FIFO/single-flight、独立 timeout/cancellation/单次输出上限，不占数据面 scheduler 槽，也不得递归运行 `AgentLoop`。deadline 从 submit 计时，queue full/timeout fail closed；自动模式只有 `allow` / `deny`，timeout、cancel、truncated、malformed、tool call、provider/persistence failure 只 durable deny 当前调用，不得隐式切到 GUI 人工 fallback。review request 与 verdict 都必须 durable-first；`allow` 只有 settled audit 成功后才可返回，自审或 hard deny 都不得放行，恢复时 orphan request 必须显式关闭。累计 token 仅可作为 soft warning/度量，默认不得用不可恢复的 session-lifetime cap 永久关闭 reviewer。用户取消当前数据面任务不得顺带关闭常驻 reviewer；只有 session stop、显式 disable 或控制面自身安全故障才进入 quiesce/shutdown。停用 reviewer 先 quiesce，再持久化 revoke/detach，迟到 allow 或落盘失败不得被误报成成功停用。reviewer 只可在 deterministic gate 的最大权限边界内收窄，不能批准真正越权；人工模式只能由用户显式切换。

Goal Verifier 是另一条独立控制面，职责仅是判定 Goal 是否已有充分证据完成。它不是 Permission Reviewer，也不是普通 agent：使用独立 system/context、无工具 provider 请求、有界 timeout/cancel/output，不能写 EventLog 或执行 workspace 动作。WorkTask result/evidence 是 agent-reported，不是完成证明；只有 host 从同一 Goal 的 durable 成功 tool-execution settlement 经 validation-tool allowlist 派生的 `validationEvidence` 才能作为 completion proof。malformed、tool call、缺完成标记、provider/usage failure、timeout/cancel 必须 fail safe 为 `continue`，不能误报 Goal 完成。只有 host 校验 verifier 返回的 requirement/evidence 与这些 host-bound evidence 一致后，才可追加 Goal audit/completed 事件。

Goal 生命周期必须由 host 串行化：start、ordinary turn、Goal mutation 与 stop/shutdown 分别有 single-flight/mutation/stop gate；pending durable stop 未结算前不得启动新 run，start 取消后若已创建 continuation，必须先 scoped cancel、等待退出并 checkpoint 才返回失败。restore 必须持续暂停 scheduler，直到 roster/reviewer/main 与 Goal recovery/reconcile 完成且宿主显式 resume 成功。Cowork `/goal` 是明确 host action；普通自然语言只有在窄、确定性的中英文持续目标分类器命中时才可为本轮提供 create intent，复杂请求、Goal 提及、一次性目标、引用示例或附件内容不得提升权限。

模型可见的 agent/task/message/goal 操作与文件、网络、文档工具遵循同一个 ToolCall 协议。WorkTask CRUD 与 Goal create/update 也是 control-plane effects，必须先过 schema、lease 与 PermissionEngine；worker 默认只能读取 Goal/相关 WorkTask，并更新自己当前绑定的 WorkTask，不能改 DAG/owner/priority/retry/cancel 或提交 Goal verdict。一个外部 ToolCall 只能有一个权限决定；`spawn_agent` / 原子 `delegate_task` 获准后，内部 roster、lease、mailbox、task graph 与 scheduler admission 必须作为 executor 的 durable transaction 完成，不能再次递归进入 PermissionEngine。Code 与 Cowork agent 共用 headless `AgentRuntime`；首个 system message 必须稳定声明 Intatis 模式、API tools 权威性、严格 JSON Schema 与 ToolResult 完成语义，动态 workspace/task/lease/goal/run 数据仍放在 user-role untrusted context。

## 3. 通信 vs 委派

区分通信与委派：

```text
Communication:                Delegation:
send_message                   request_delegation
request_information            delegate_task
reply_message
```

**不要**长期用一个模糊的 `ask_agent` 操作覆盖所有用途。

MessageBus 投递采用持久化的至少一次语义：先通过 Mediator，再持久化 typed message，然后进入 mailbox。只有确实投影给 agent 且该轮成功完成的 message ID 才能写 consumed event；消费确认必须先持久化再从运行时 mailbox 移除。若 owning Goal/run 在成功呈现前取消，迟到 durable message 必须以专用 discarded event durable 结算后再 ack，不能伪装成 consumed。恢复后既未 consumed 也未 discarded 的消息必须重新触发 wake task，单轮批量应有上限；旧 run discarded message 不得复活或阻塞新 run。

## 4. 递归与循环规则

`AgentLoop` 不得直接同步嵌套调用另一个 `AgentLoop`。用 mailbox / scheduler / event flow。

拒绝或守卫：
```text
caller == target self-call
A → B → A cycles
unbounded delegation chains
duplicate task creation
unbounded agent spawning
```

数值 depth guard 可作为安全保险丝存在，但**不得**是核心角色模型。

## 5. 工作区与安全规则

Cowork 可以采用项目制：一个 session 绑定一个或多个用户选择的工作目录，并有一个 `@main` 主 agent。用户默认只向 `@main` 下达项目任务；`@main` 通过工具创建、委派、调取、删除子 agent，并管理任务、上下文、权限 profile、token budget 等 project metadata。但 project/session settings 只是本地元数据与 UI 投影，不得替代 task contract、capability lease、workspace lease 或权限门。

工作区扩展**绝非**只读。创建或附加 agent 到新目录是能力/工作区扩展，必须经权限。唯一例外是 brand-new session 的初始 bootstrap：用户在 New Cowork Session 文件选择器或 CLI workspace 参数中明确选定 primary workspace 后，这次显式选择本身授权固定 `@main` 在该 canonical root 建立默认 workspace/capability lease；该路径必须同时要求空 EventLog、空 roster、固定 `@main` 身份、敏感/过宽根目录拒绝和 admission batch durable-first，不能被普通 attach/spawn/tool/recovery 复用。初始 `@permission-reviewer` 可随后用其固定 read_only + 空工具 lease 挂载；两者之间不得再让模型审批同一次 primary-workspace 选择。

不得让 model 静默附加到：
```text
/
~
/Users
~/.ssh
~/Library/Keychains
secret/token/key directories
```

所有文件访问必须经工作区约束与权限策略。

新增或删除项目工作目录是 session/project metadata 变更；真正派生工作 agent 应由 `@main` 或被显式授予协调权的 agent 通过调度器和工具完成。新建子 agent 默认只获得普通 worker + read-only workspace；`requestedAccess=read_write` 和 `canCoordinate=true` 是两个独立、显式、不可超过 issuer lease 的授权维度。除非 task contract/capability lease 明确授予，不得让子 agent 继承 `@main` 的 `spawn_agent` / `remove_agent` / `delegate_task` 等 coordinator 工具。`@main` 和自动权限审查者不应作为普通删除对象。

自动权限审查若启用，审查者也必须是受控子 agent：
```text
created automatically on GUI/CLI Cowork session startup when possible
/auto only re-enables it; /default disables it
reserved identity, not a normal task/message/delegation target
read-only profile and no tool capability lease
no nested AgentLoop; reviewer receives no-tool provider judgement request
reviewer sees global context plus requesting-agent scoped context
hard deny remains final before the reviewer can see anything
```

## 6. 历史审计问题与当前回归点

```text
已消除或已有回归覆盖：
- first-level child agents may still get coordinator tools
- ask_agent allows self-call
- ask_agent creates nested AgentLoop execution
- spawn_agent has been treated too much like read-only
- there is no task contract / capability lease yet
- production user turns bypass the task graph instead of creating root tasks
- actor reentrancy allows uncontrolled same-agent or cross-agent execution
- no durable running-task recovery, cancellation, timeout, attempt, retry, or token accounting
- MessageBus events are disconnected from a consumable/recoverable mailbox
- task-scoped lease fields are descriptive but unenforced or leak after terminal state
- task context grows without request budgets or places dynamic event data in system role
- max-iteration/incomplete provider responses can be reported as completed

仍需持续关注：
- priorHistory/global context projection must stay scoped for task runs
- MessageBus payload/report shape must stay structured enough for replay
- delegate_task must return a mediated Task Report, not a queued ack
- AgentInvocation completion must remain only a WorkTask candidate result; WorkTask and Goal completion need their own explicit authorities
- host-driven Goal continuation must checkpoint/recover through ContinuationRun events and must never become a nested AgentLoop
- GoalVerifier must remain independent from the acting agents and Permission Reviewer; agent-reported WorkTask evidence is non-authoritative, and Goal completion requires host-derived validation evidence from durable successful validation-tool settlements
- task-scoped tool-spawned children must be recycled only when idle
- cancellation is cooperative; provider/tool implementations need their own bounded cancellation/watchdog behavior
- real-provider crash/restart and long-running Goal/WorkTask multi-agent GUI/CLI matrices remain device-level validation work
- EventLog-derived context/recovery index remains a future long-session performance optimization; request context itself must remain bounded even before such an index exists
```

处理 Cowork 时把上述条目当作回归清单；若源码与本清单冲突，以当前源码和 `docs/DO_NOT_BREAK.md` 的更具体禁区为准。

## 7. 实现顺序

除非另有指示，按此顺序：
```text
1. Immediate safety patch:
   - worker cannot spawn by default
   - ask self-call rejected
   - spawn_agent not read-only
   - worker prompt does not advertise coordinator powers

2. Introduce TaskContract.
3. Introduce ContextProjector.
4. Introduce CapabilityLease / WorkspaceLease.
5. Split message and delegation APIs.
6. Replace nested AgentLoop calls with scheduler/mailbox.
7. Add task graph cycle detection.
8. Expand semantic event schema and tests.
9. Add Goal / WorkTask / ContinuationRun above the existing AgentInvocation layer without renaming old durable event types.
10. Add host-driven continuation and an independent GoalVerifier; never let an agent self-certify Goal completion.
```

## 8. 测试期望

修改 Cowork 或 AgentKernel 时，添加或更新以下测试：
```text
child cannot spawn without capability
child cannot ask itself
worker prompt does not advertise coordinator powers
task contract appears in context
context projection hides unrelated raw global transcript
capability lease controls tool registry
worker receives only read-only document/media tools and no git-control/git-remote/browser/network tools by default
delegation cycle is rejected
workspace expansion requires permission
fresh-session bootstrap attaches fixed @main without model review and cannot be reused after any durable session state exists
agent-to-agent event records caller, target, task, and causal chain
automatic permission reviewer cannot override hard deny
automatic permission reviewer can be enabled/disabled without becoming a normal worker
user turn creates a root task and waits for one terminal event
same agent is single-flight while different agents respect the concurrency limit
running task recovery increments attempt; exhausted/interrupted admission fails explicitly
cancel, timeout, maxIterations, missing completion marker, and incomplete finish reason never complete
Goal / WorkTask / ContinuationRun IDs remain stable and all new events round-trip/replay without breaking legacy TaskContract JSON
WorkTask DAG rejects missing/cross-run/self/cyclic dependencies, stale revisions, invalid transitions, and completion without required result/evidence
dependency replanning recomputes host-derived readiness atomically, and projection never trusts a DAG-inconsistent ready transition
concurrent delegate_task(to:auto) reserves distinct eligible workers before any await and releases every reservation on every exit path
task_create/update/get/list obey capability leases; a worker can update only its bound owned WorkTask and cannot rewrite the graph
write-capable WorkTask admission rejects overlapping expected-artifact ancestors/descendants and treats unknown write sets as workspace-wide
delegate_task preserves the WorkTask/run/goal binding and records invocation linkage without treating its result as WorkTask completion
Cowork /goal creates a durable Goal; Chat/Code keep legacy Goal metadata behavior unless separately migrated
ordinary natural-language Goal creation intent is narrow, deterministic, attachment-independent, and never bypasses schema/lease/permission/host authority
ContinuationRun checkpoints/recovery are host-driven; restart never nests or recursively calls AgentLoop
startup keeps the scheduler suspended through Goal recovery; pending stop, shutdown, and cancelled start cannot leak a live continuation
cancellation persistence failure quarantines the task before provider dispatch and resolves scoped/global idle plus result waiters within a bounded path
GoalVerifier receives no tools, cannot write EventLog, accepts only host-derived validation evidence from durable successful allowlisted tool settlements, and fails safe to continue on malformed/tool-call/timeout/cancel/provider/usage errors
Goal completes only after a non-empty all-proven audit; the same normalized blocker must recur across the configured run threshold before blocked
Goal/Tasks UI is derived from CoworkProjection, including revision/result/evidence/dependencies/invocation links, rather than TaskContract objective or transcript text
only actually presented mailbox messages are consumed; cancelled-run messages are durably discarded, and remaining batches survive replay
late scoped mailbox sends after cancellation are durably discarded rather than consumed, including across restore and a later run
task-scoped capability/workspace leases are enforced, revoked, and safely renewed on retry
dynamic task/message/event text stays in a bounded, escaped user-role context block
unknown future events do not cause EventLog sequence reuse
```

## 9. 平台边界

macOS 是全量 Intatis 产品。iOS 是 macOS 的真子集：
```text
iOS supports Chat, multimodal, providers, artifacts, session history.
iOS must not include local workspace Agent execution.
iOS must not link shell/git/patch/local-agent workspace modules.
```
**不得**弱化此边界。

## 10. 开源复用与产品身份规则

Intatis 允许按 `docs/OPEN_SOURCE_REUSE.md` 选择性复制、翻译、修改或运行兼容许可证的公开 agent/runtime 实现，包括 OpenCode 等项目中经过文件级许可证和 provenance 核对的源码、公开 model-facing prompt 与测试。复用不能改变本原则定义的 TaskContract、Scoped Context、CapabilityLease、WorkspaceLease、TaskGraph/Scheduler、MessageBus 和无嵌套 `AgentLoop` 边界；上游实现若与这些原则冲突，必须适配后再进入 Intatis，不能因“来自成熟项目”而直接放行。

永久禁止使用泄露/私有源码或 prompt，也不复制第三方产品名称、Logo、图标、截图、UI 资产、商标性外观或品牌文案作为 Intatis 产品身份。直接复制或逐行翻译必须记录上游 URL、固定 commit、许可证和本地修改，并更新 `NOTICE.md`。Apple 平台继续 Swift-native 优先；非 Swift runtime 只能作为受控、可审计的 macOS 隔离组件评估，不得进入 iOS workspace Agent target。

产品与协议继续使用 Intatis 自己的通用术语：
```text
local agent workspace
native agent kernel
multi-agent cowork thread
task graph
capability lease
scoped context
```

## 11. 变更纪律

大变更时：
```text
read docs first
state the intended module boundary
avoid broad rewrites
make the smallest coherent patch
add tests
report remaining risks
```
不要在修 Cowork 编排时顺手加无关功能。

---

> 本原则文档是架构基准。当前代码实现进度见 `docs/CURRENT_STATE.md`；与原则的差距见上述"当前已知 Cowork 问题"。
