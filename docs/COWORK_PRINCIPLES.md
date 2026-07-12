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

## 2. 五大顶层抽象

Cowork 应围绕五个抽象构建：

```text
Agent Identity          持久本地身份（id/displayName/model/workspace lease/mailbox/status）
Task Contract           每 task 分派的角色与交付物
Scoped Context          上下文按作用域投影，非全量原始 transcript
Capability Lease        能力按租约授予，非永久继承
Task Graph + Scheduler  任务图 + 调度器驱动协作
```

### 2.1 Agent Identity
Agent 是持久本地身份。应含 `id` / `displayName` / `model` / `workspace lease or default workspace` / `local memory or mailbox` / `status`。**不应**含永久 "leaf" 或 "coordinator" 角色。

### 2.2 Task Contract
角色按 task 分派。Task contract 应告诉 agent 它为何存在于当前工作流、预期交付什么。建议 shape：
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
工具应按 capability lease 暴露。普通 worker task 不应收到 coordinator 工具（`spawn_agent` / `remove_agent` / `delegate_task`）。若 task 需委派，经 `CapabilityLease.delegation` 显式授予。子 agent 不应仅因被 spawn 就获得 coordinator 能力。Git、文档/媒体与网络/浏览器工具同样按 lease 收窄：worker 默认只能获得安全的只读能力（当前为 `read_pdf`），Git stage/commit/branch、remote fetch/pull/push/switch、页面编辑、OCR/版面重建、LaTeX 编译、生图、网络访问、浏览器 profile 操作等写入/执行/网络能力必须经 coordinator lease 或未来显式 lease 授予。

Lease 不只是工具列表：task-scoped lease 必须核对 task ID、communication/delegation grant，并在终态撤销；WorkspaceLease 必须执行 root、read-only/read-write、allow/deny path，并固定 canonical root 的文件系统 identity。任何可能跨 await 的授权都不能只在入口校验：attach commit、权限等待后、durable prepare 后紧邻 executor、派生/retry 与 process 启动前必须复核 identity；同路径目录被替换或 legacy lease 无 identity 时 fail closed。retry 只可从原 lease 的持久审计记录克隆，缺失历史时收窄到 worker，禁止按 agent 默认角色扩大权限。

### 2.5 Task Graph + Scheduler
协作经任务图与消息总线发生。`AgentLoop` 不得直接同步递归调用另一个 `AgentLoop`——用 mailbox / scheduler / event flow。

Scheduler 必须把“claim”和“执行”分开：claim 是短状态转换，同一 agent 只允许一个 running task；不同 agent 只能在显式并发上限内并行。用户输入也必须先成为 root task，不能绕开 task graph 直接跑一个不可恢复的 AgentLoop。

Task lifecycle 是 durable state machine：
```text
created -> assigned -> queued -> running -> completed | failed | cancelled
failed | cancelled -> queued  only through an explicit bounded retry attempt
```
恢复时不能默认把所有 running 任务整段重放。每个实际 tool executor 调用前必须先持久化 execution ticket，结果持久化后再 settle；只有普通 read-only 调用可自动重放。write/exec/network/destructive 与通信、委派、spawn/remove 等协作副作用处于“prepared 但未 settled”时，任务必须进入人工对账失败态，不能自动增加 attempt。没有未决非幂等副作用的 running 任务才可在新 attempt 的 queue 事件成功落盘后重排；半完成 admission、耗尽 attempts 或缺失关键 lease 也必须明确失败。执行应有 bounded timeout/cancel、attempt 和明确标为 soft 的 session token budget；模型缺完成标记、迭代耗尽或不完整 finish reason 都是失败。

Permission Reviewer 是独立控制面，不是普通 worker：使用结构化 `PermissionReviewTask`、有界 FIFO/single-flight、独立 timeout/cancellation/session-lifetime budget，不占数据面 scheduler 槽，也不得递归运行 `AgentLoop`。deadline 从 submit 计时，queue full/timeout fail closed，人工 fallback 也必须遵守同一串行生命周期。review request 与 verdict 都必须 durable-first；`allow` 只有 settled audit 成功后才可返回，持久化失败、超时、取消、自审或 hard deny 都不得放行，恢复时 orphan request 必须显式关闭。停用 reviewer 先 quiesce，再持久化 revoke/detach，迟到 allow 或落盘失败不得被误报成成功停用。reviewer 只可在 deterministic gate 的最大权限边界内收窄，不能批准真正越权。

## 3. 通信 vs 委派

区分通信与委派：

```text
Communication:                Delegation:
send_message                   request_delegation
request_information            delegate_task
reply_message
```

**不要**长期用一个模糊的 `ask_agent` 操作覆盖所有用途。

MessageBus 投递采用持久化的至少一次语义：先通过 Mediator，再持久化 typed message，然后进入 mailbox。只有确实投影给 agent 且该轮成功完成的 message ID 才能写 consumed event；消费确认必须先持久化再从运行时 mailbox 移除。恢复后未消费消息必须重新触发 wake task，单轮批量应有上限。

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

工作区扩展**绝非**只读。创建或附加 agent 到新目录是能力/工作区扩展，必须经权限。

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

新增或删除项目工作目录是 session/project metadata 变更；真正派生工作 agent 应由 `@main` 或被显式授予协调权的 agent 通过调度器和工具完成。新建子 agent 默认只获得普通 worker 能力；除非 task contract/capability lease 明确授予（例如显式协调授权），不得让子 agent 继承 `@main` 的 `spawn_agent` / `remove_agent` / `delegate_task` 等 coordinator 工具。`@main` 和自动权限审查者不应作为普通删除对象。

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
- task-scoped tool-spawned children must be recycled only when idle
- cancellation is cooperative; provider/tool implementations need their own bounded cancellation/watchdog behavior
- real-provider crash/restart and long-running multi-agent GUI/CLI matrices remain device-level validation work
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
agent-to-agent event records caller, target, task, and causal chain
automatic permission reviewer cannot override hard deny
automatic permission reviewer can be enabled/disabled without becoming a normal worker
user turn creates a root task and waits for one terminal event
same agent is single-flight while different agents respect the concurrency limit
running task recovery increments attempt; exhausted/interrupted admission fails explicitly
cancel, timeout, maxIterations, missing completion marker, and incomplete finish reason never complete
only actually presented mailbox messages are consumed; remaining batches survive replay
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

## 10. Clean-room 规则

不复制 Codex / Claude Code / DeepCode / OpenCode / ChatGPT / Claude 或类似产品的源码、私有 prompt、UI 资产、图标、产品名或用户面文案。用通用术语：
```text
local agent workspace
clean-room agent kernel
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
