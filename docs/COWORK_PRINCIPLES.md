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
工具应按 capability lease 暴露。普通 worker task 不应收到 coordinator 工具（`spawn_agent` / `remove_agent` / `delegate_task`）。若 task 需委派，经 `CapabilityLease.delegation` 显式授予。子 agent 不应仅因被 spawn 就获得 coordinator 能力。

### 2.5 Task Graph + Scheduler
协作经任务图与消息总线发生。`AgentLoop` 不得直接同步递归调用另一个 `AgentLoop`——用 mailbox / scheduler / event flow。

## 3. 通信 vs 委派

区分通信与委派：

```text
Communication:                Delegation:
send_message                   request_delegation
request_information            delegate_task
reply_message
```

**不要**长期用一个模糊的 `ask_agent` 操作覆盖所有用途。

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

自动权限审查若启用，审查者也必须是受控子 agent：
```text
created only by explicit user mode switch (/auto in CLI)
reserved identity, not a normal task/message/delegation target
read-only profile and no tool capability lease
no nested AgentLoop; reviewer receives no-tool provider judgement request
hard deny remains final before the reviewer can see anything
```

## 6. 当前已知 Cowork 问题（来自只读审计）

```text
first-level child agents may still get coordinator tools
ask_agent allows self-call
ask_agent creates nested AgentLoop execution
priorHistory uses global conversation projection
spawn_agent has been treated too much like read-only
MessageBus payload is too thin
there is no task contract / capability lease yet
```

处理 Cowork 时优先消除这些问题。

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
delegation cycle is rejected
workspace expansion requires permission
agent-to-agent event records caller, target, task, and causal chain
automatic permission reviewer cannot override hard deny
automatic permission reviewer can be enabled/disabled without becoming a normal worker
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
