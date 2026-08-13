# Cowork Session 内独立 Task、Run 中断与原子委派重构报告

> 日期：2026-08-13（Asia/Singapore）
> 范围：Cowork / AgentKernel / WorkTask / ContinuationRun / AgentInvocation / EventLog
> 状态：**已实施；本报告只记录最终合同、实际改动和验证结果**
> 原则：删除错误耦合，复用现有对象；不新增替代层级，不做旧版本 Session 迁移

## 1. 结论

事故的第一次失败是 provider TLS validation failure；第二次失败来自 Intatis 自己：旧 WorkTask 被绑定在旧 Run，新的 Run 无权继续它，而委派又在完整预检前先写入了 agent-to-agent message。宿主随后把这次内部半提交升级成整轮终止错误，导致当前 Turn 和新 Run 再次失败。

本次最终落地六项修正：

1. WorkTask 改为当前 Cowork Session 内的独立工作记录，不属于 Run、Goal、Agent 或 Turn。
2. provider、网络和运行时中断把当前 Run 终结为 `interrupted`；用户明确取消才是 `cancelled`。
3. Continue / Resume 使用新 Run；旧 Run 不复活，原 WorkTaskID 不复制。
4. 内部委派先完成全部预检，再用现有 EventLog batch 一次提交；预检失败是确定的 `not_started`，不留半条消息。
5. `spawn_agent` 删除 raw `model` 参数；省略 `inference_profile_id` 时继承当前 agent 的 exact binding，显式填写时只接受宿主批准的 profile ID。
6. 删除请求委派工具及其 capability、event、mailbox authority；普通工具错误结算后回给模型继续，不再升级成通用整轮终止错误。

没有增加 Conversation、TaskSpace、TaskAttempt、owner/claim/receipt、Run 血缘字段、reconciler agent 或新的恢复服务。

## 2. 最终边界

### 2.1 Session 是唯一工作边界

- WorkTask 只存在于创建它的 Cowork Session 的 EventLog/projection 中。
- 同一 Session 内，WorkTask 可跨 Turn 和 Run 继续使用。
- 不提供跨 Session 查询、共享、adoption、transfer 或全局 Task registry。
- EventLog 已提供 Session 命名空间，因此 WorkTask 不再增加 `sessionID` 字段。
- 删除 Session 时，WorkTask 随 Session 存储一起删除；这不是其他对象对 Task 的业务所有权。

### 2.2 Turn 已足够，不新增 Conversation

用户的一条命令及其回答继续使用现有 TurnID：

- Turn 是一次交互边界。
- Run 是一次执行生命周期。
- WorkTask 是 Session 内可持续存在的工作记录。
- 一个 Turn 可以不涉及 WorkTask；一个 WorkTask 可以跨多个 Turn。

没有新增 ConversationID、Conversation projection 或 Conversation/Task 关联。

### 2.3 Goal 与 WorkTask 独立

- WorkTask 不保存 `goalID`。
- Goal 暂停、完成、清除或预算变化不复制、取消、完成或归档 WorkTask。
- WorkTask 状态不反向决定 Goal 状态。
- GoalVerifier 不再把 WorkTask 终态当作 Goal completion barrier。
- 删除跨 Goal/Run 复制 WorkTask 的 carry-forward 路径。

Goal 本身的目标、预算、暂停和 verifier 状态机继续独立存在；本次没有重构 Goal，也没有新增 GoalTaskLink 或 membership。

### 2.4 不做旧版本 Session 迁移

本次实现只定义新格式 Session：

- 不迁移旧 `WorkTask.runID/goalID/owner`。
- 不保留 carry-forward、owner-changed 或 recovered Run 的新旧双写。
- 不增加 adoption、legacy alias、兼容开关或修复工具。
- 发布后若需要规避旧格式，产品选择是新建 Session。

这不妨碍同一当前版本 Session 的进程重启恢复：当前 EventLog 仍会重放，悬空的 active Run 会被终结为 `interrupted`，但不会恢复原调用栈或复活同一个 Run。

### 2.5 工具失败与重放边界

- 实时 executor error 写 `tool_result` 与 `tool_execution_settled(failed, unknown)`，作为 observation 返回同一 Agent turn。
- executor-entered cancellation 写 `cancelled/unknown` 后结束当前 turn。
- `doNotReplay` 只禁止旧 task attempt 自动重放，不生成单独的恢复状态或终止错误。
- 用户继续工作时创建新 Run；不恢复旧 Run，不新增 effect probe、后台队列、修复器或对账角色。

## 3. 最终模型

当前 Session 中继续只有既有概念：

```text
Cowork Session
├── Turn
├── ContinuationRun
├── WorkTask / WorkTaskGraph
├── Agent / AgentInvocation（TaskContract）
├── Goal（可选且独立）
└── EventLog
```

这些记录共享 Session 存储，但不形成新的永久父子层级。

### 3.1 WorkTask

WorkTask 保留任务自身事实：稳定 ID、标题、描述、状态、优先级、依赖、revision、时间、结果/evidence 与 invocation linkage。

已删除：

- `runID`
- `goalID`
- `owner`
- cross-run dependency 规则

没有增加替代归属字段。现有 `revision` 和 `expected_revision` 继续承担乐观并发控制。

WorkTask 的状态只由显式 Task 动作或成功的 delegation admission 改变。Run、Turn、Goal、provider、AgentInvocation 或应用生命周期的终态不会自动结算 WorkTask。

### 3.2 ContinuationRun

Run 表示一次执行窗口。状态保留既有集合并增加 terminal `interrupted`：

```text
created → running → checkpointed/completed/interrupted/cancelled
```

- `completed`：本 Run 正常完成。
- `interrupted`：provider、网络、运行时或进程生命周期导致执行中断。
- `cancelled`：用户或 exact `@main` 的明确 Stop/Cancel 意图。
- terminal Run 不能重新进入 `running`。
- Continue / Resume 创建新 Run，不写 `resumesRunID`、`parentRunID` 或 recovery branch。

### 3.3 AgentInvocation

AgentInvocation 继续使用既有 TaskContract / TaskID，表示某个 agent 的一次具体执行：

- `TaskContract.workTaskID` 是可选执行绑定，不是 WorkTask 归属。
- worker 对 WorkTask 的更新权限来自当前 invocation 的 exact 绑定和 CapabilityLease，不来自 owner。
- invocation 结果只是 WorkTask candidate；不会自动完成、失败或取消 WorkTask。
- 一个 WorkTask 可先后链接多个 terminal invocation，但同时只能有一个 active invocation。

### 3.4 Goal

Goal 继续通过自己的 durable 状态、GoalVerifier 和 host-derived validation evidence 判定完成。WorkTask result/evidence 仍可作为工作记录，但不是 Goal completion authority。

## 4. 实际实现

### 4.1 协议与 projection

- 从 `WorkTask`、创建/更新请求和 projection identity 中删除 Run、Goal、owner。
- 删除 owner-changed、carried-forward 和 recovered Run 事件及 payload。
- 增加 `continuation_run_interrupted`。
- `ContinuationRun.interrupted` 为 terminal，禁止回到 running。
- WorkTask dependency 只检查当前 Session graph 的存在性、自依赖、环和状态，不再检查 Run。
- worker capability 从 `update_owned_work_task` 改为 `update_bound_work_task`；provider-facing 工具名仍是稳定的 `task_update`。

### 4.2 WorkTask 访问与 UI

- manager 的 task_get/list/update 读取当前 Session projection，不再按当前 Run 或 Goal 过滤。
- worker 只能读取当前 invocation 绑定的 WorkTask及其依赖，并只更新这个绑定 Task 的窄字段。
- Cowork 右栏改为 `Session Tasks`，不显示 owner，也不因 Goal/Run 选择过滤 Task。
- Task 创建 schema 不再暴露 owner。

### 4.3 Goal 解耦

- GoalVerifier 输入和 prompt 删除 WorkTask ownership/terminal 摘要。
- Goal progress signature 使用 Goal-scoped AgentInvocation 与 durable validation-tool evidence，而不是 WorkTask 状态。
- Goal continuation prompt 不再携带 WorkTask ownership/carry-forward 历史。
- Goal/Run/Turn/invocation 终态不再传播 WorkTask 状态。

### 4.4 Run 中断与继续

- provider、网络、运行时失败及非显式生命周期停止写 `interrupted`。
- 用户或 exact main 的明确停止写 `cancelled`。
- 启动重放发现 `created/running` Run 时，只把旧 Run 写成 `interrupted`。
- 显式 Resume 在同一 Session 创建另一个 Run；旧 Run 保持 terminal。
- 新 Run 需要继续工作时 fresh-resolve 原 WorkTaskID，不 clone、不 carry-forward。

### 4.5 原子委派

`MessageBus.mediate` 现在是纯调解：允许时返回安全内容，拒绝时返回空；它不写 EventLog，也不投递 mailbox。

Orchestrator 先在 admission lock 外完成可能异步等待、但不写内部事实的 Mediator 与 exact provider 检查；然后取得现有 admission lock，重新复核 authorization、target/binding/lease、WorkTask revision/dependency/active invocation，并完成 TaskGraph、scheduler 和 WorkTaskGraph preflight。全部成立后，才用一次 EventLog batch 写入 message、mediation audit、delegation、lease、AgentInvocation、queue 和必要的 WorkTask started/linkage；batch 成功后再提交内存状态。

外部异步检查不占住 admission lock，最终可变状态复核和 durable commit 仍处于同一个 lock 边界。

因此预检失败时，EventLog 不会留下 message、lease、invocation、queue 或 WorkTask 半状态。

生产 `BusMessenger` 把这种提交前拒绝转换为 `ToolExecutionRejectedWithoutSideEffect`。AgentLoop 使用既有 `failed/not_started` settlement 把错误回灌给同一 Turn，不自动终止 Run。

### 4.6 委派目标与幂等身份

- `delegate_task.to` 只能解析为已经 attach 的 data-plane agent。
- 省略 `to` 或使用 `auto` 时，只从现有 idle attached workers 中选择；没有可用 worker就拒绝，并提示先在较早 tool-call round 使用 `spawn_agent`。
- `delegate_task` 不再隐式 proposed/spawn worker，不增加角色。
- executor 接收既有 durable `executionID`，从它确定同一 invocation TaskID；相同执行身份命中已存在 invocation，不再创建第二个 invocation 或重复 admission batch。
- 未提交的 preflight 可安全重新执行；append 后丢失确认结算为 unknown，不伪造 not_started，也不自动重放旧 attempt。
- delegate 工具只接受当前 snake_case 参数；没有为旧工具调用保留新增的 camelCase alias。

## 5. 行为合同

| 场景 | Run | WorkTask | 委派/恢复结果 |
| --- | --- | --- | --- |
| provider/TLS/network failure | interrupted | 不自动变化 | 用户继续时新建 Run |
| runtime/进程中断 | interrupted | 不自动变化 | 重放不复活旧 Run |
| 用户明确 Cancel/Stop | cancelled | 不自动变化 | 需要继续时仍是新 Run |
| Goal 暂停/完成/清除 | Goal 自己结算 | 不自动变化 | 不复制或归档 Task |
| ready Task 首次委派 | 当前 Run 不变 | 原子转 in_progress 并链接 invocation | 一次 batch |
| in_progress 且无 active invocation | 当前 Run 不变 | ID/revision 链连续 | 可重新委派 |
| dependency 未满足/target 未 attach/Mediator deny | 当前 Run 不变 | 不变 | `not_started`，零内部委派事实 |
| batch 已提交后 worker/provider 失败 | 可按 typed source interrupted | 保持 in_progress；invocation terminal | 新 Run 可再次委派原 ID |

## 6. 不变量

1. WorkTaskID 的 authority 来自当前 Session projection，不来自聊天历史。
2. WorkTask 不含 Run、Goal、Agent 或 Turn ownership。
3. terminal Run 不恢复；继续工作总是新 Run。
4. Goal 和 WorkTask 的状态机互不传播终态。
5. 委派的第一次 durable write 是完整 admission batch。
6. batch 前拒绝必须证明 `not_started`；batch 后未知不能按错误字符串猜测为安全重试。
7. worker 更新权只来自 current AgentInvocation binding。
8. `delegate_task` 不创建 worker；`spawn_agent` 是独立且显式的动作，且不接受 raw model。
9. 不存在请求委派工具、capability、event 或 mailbox authority；不新增 receipt、TaskAttempt、TaskSpace、Conversation 或通用 reconciler。
10. 本次不提供旧版本 Session migration 或双读/双写。
11. 普通工具错误必须结算并返回模型；`doNotReplay` 只控制旧 attempt 的自动重放。

## 7. 事故回归覆盖

已增加或改写的重点测试覆盖：

- WorkTask schema 无 owner，Task graph 无 Run/Goal ownership。
- invocation settlement 不修改独立 WorkTask；candidate 不自动 settle。
- dependency 未满足的 delegation 在预检失败后 EventLog 字节级投影不增加。
- Mediator 阻断后没有 message、delegation、lease、queue 或 roster 半状态。
- 没有 attached worker 时在权限审查/admission 前失败，不 proposed/spawn worker。
- 省略 `to` 时可以精确选择已有 attached idle worker并接受权限审查。
- 启动重放把悬空 active Run 写成 interrupted；显式 Resume 创建不同 RunID。
- interrupted Run 不能重新 running。
- GoalVerifier completion 不依赖 WorkTask terminal。
- `spawn_agent` schema 不含 `model`，仍含可选 `inference_profile_id`。
- worker 工具面不含请求委派工具，mailbox 只有 ordinary/information request/information reply 三类 authority。
- non-replayable executor error 结算为 failed/unknown 并允许模型继续输出；执行中取消结算为 cancelled/unknown。

## 8. 验证状态

本轮最终代码已通过：

- SwiftPM 全部相关 test products 编译。
- `IntatisProtocolTests`：107/107。
- `IntatisAgentKernelTests`：220/220。
- `IntatisCoworkTests`：364/364。
- `ToolExecutionProtocolTests`：5/5。
- `SpawnAgentPermissionTests`：11/11。
- `AgentLoopPolicyTests`：37/37。
- `CapabilityLeaseTests`：7/7。
- `MessageDelegationSplitTests`：9/9。
- `OrchestrationReliabilityTests`：44/44。
- `IntatisMac` Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过；只有仓库既有 warnings。

未把整仓 `swift test` 记为本轮通过；未运行真实 provider、credential/network、GUI 交互或 iOS App smoke。

## 9. 修改范围

主要实现位置：

- `Packages/IntatisProtocol/Sources/WorkTask.swift`
- `Packages/IntatisProtocol/Sources/ContinuationRun.swift`
- `Packages/IntatisProtocol/Sources/Event.swift`
- `Packages/IntatisProtocol/Sources/Envelope.swift`
- `Packages/IntatisProtocol/Sources/ToolExecution.swift`
- `Packages/IntatisProtocol/Sources/Leases.swift`
- `Packages/IntatisProtocol/Sources/TaskGoalEvents.swift`
- `Packages/IntatisConversation/Sources/*Projection.swift`
- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift`
- `Packages/IntatisAgentKernel/Sources/ContextBuilder.swift`
- `Packages/IntatisCowork/Sources/Orchestrator.swift`
- `Packages/IntatisCowork/Sources/MessageBus.swift`
- `Packages/IntatisCowork/Sources/CommunicationDelegationTools.swift`
- `Packages/IntatisCowork/Sources/CoordinatorTools.swift`
- `Packages/IntatisCowork/Sources/WorkTaskTools.swift`
- `Packages/IntatisCowork/Sources/GoalRuntimeController.swift`
- `Packages/IntatisCowork/Sources/GoalVerifierControlPlane.swift`
- `Packages/IntatisTools/Sources/TaskGoalManagement.swift`
- `Apps/IntatisMac/Sources/CoworkViewModel.swift`
- `Packages/IntatisSharedUI/Sources/CoworkViews.swift`
- 对应 Protocol、Conversation、Cowork 测试

本轮开始时工作树为空；本轮没有暂存或提交文件。

## 10. 完成记录

### MODEL_CHECK_RESULT

当前助手为 Codex；精确部署型号无法从本地仓库确认。

### PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 路径匹配。

### VALIDATION_RESULT

- 编译、构建与定向测试结果见第 8 节。
- 最终 `git diff --check` 与旧合同残留扫描见本轮交付记录。
- 本轮未暂存、提交或推送。

### UNCERTAINTIES

- 未为旧版本 Session 设计或验证迁移路径；这是明确非目标，不是待补架构。
- durable settlement 仍可记录既有的 `effectDisposition = unknown` 作为执行审计事实，但它不再生成额外恢复对象、面向用户的通用错误或整轮终止。

### NEXT_RECOMMENDED_ACTION

发布此版本后新建 Cowork Session 做真实 provider smoke；后续只根据真实失败补窄测试或修复，不预建新对象、字段、角色或服务。
