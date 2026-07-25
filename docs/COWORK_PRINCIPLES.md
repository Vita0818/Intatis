# COWORK_PRINCIPLES

本文提炼自仓内 `docs/COWORK_AGENT_ARCHITECTURE.md` / `COWORK_TASK_CONTEXT_MODEL.md` / `COWORK_CURRENT_FINDINGS.md` / `COWORK_MIGRATION_PLAN.md` / `COWORK_AGENT_INVOCATION_MODEL.md` / `PER_AGENT_INFERENCE_PROFILES.md` 及原 `AGENTS.md` 的英文原则。它是 Cowork 架构的原则基准，**不是**当前完成度声明。修改 Cowork / AgentKernel / MessageBus / 权限 / agent 编排前必读。

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
Agent Identity          持久本地身份（id/displayName/exact inference binding/workspace lease/mailbox/status）
Task Contract           每 AgentInvocation 分派的角色与交付物
Scoped Context          worker 按作用域投影；稳定 @main 保有自己的持久模型 thread
Capability Lease        能力按租约授予，非永久继承
Task Graph + Scheduler  任务图 + 调度器驱动协作
```

### 2.1 Agent Identity
Agent 是持久本地身份。应含 `id` / `displayName` / exact `AgentInferenceBinding` / `workspace lease or default workspace` / `local memory or mailbox` / `status`。兼容 `model` 字段不能覆盖 exact binding。**不应**含永久 "leaf" 或 "coordinator" 角色。

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
    let agentInferenceBinding: AgentInferenceBinding? // legacy decode 可为空；strict live runtime 必须解析
    let contextScopes: Set<ContextScope>
}
```
好的 task contract 回答：为什么创建、谁指派、交付什么、相关任务/agent、血缘，并冻结本次 invocation 使用的 exact inference binding。运行中的 task 不得被 future-agent default、catalog current refresh 或 host rebind 改写。

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

稳定 `@main` 是明确例外，但例外也不是“读取全部 UI 日志”。它必须拥有一条独立、可恢复、按模型真实输入结构保存的 thread history：user、final assistant、完整 function-call batch 与对应 output 按原顺序进入下一次 provider 请求。流式 delta、UI bubble、截短后的审计参数、`task_completed.result` 与普通 `ContextBundle` 都不能充当这条历史的事实源。崩溃后缺失的 tool output 只在请求副本中标成 `aborted`，孤立 output 不发送；task-scoped worker 仍只得到自己的 bounded context，不能继承 `@main` 的完整 thread。

### 2.3a Inference Binding

推理配置属于 agent identity 的 durable route snapshot，但与权限/工具/工作区 lease 正交。`AgentInferenceBinding` 必须指向 versioned immutable connection/profile revision，并固定 model、opaque durable variant、安全 route label/trust domain/egress classification 与 opaque definition digest；macOS/CLI raw variant config key 只属于 local presentation selector，不能进入 binding/EventLog。同一个 model ID 的不同 effort、connection、credential reference 或 endpoint 是不同 profile。Catalog current/default 只是未来 agent 的创建模板，不能成为已有 agent 的动态指针。

- fresh `@main` 使用 host 当前选择的 exact default；恢复必须使用 durable roster binding。
- `spawn_agent` 未指定 profile 时精确继承 issuer binding；显式 profile 必须 host-approved，不能让模型直接提交 raw endpoint/model/options。
- `delegate_task` 不改变目标 binding，权限 target 必须包含其安全快照并在执行前复核。
- rebind 是 host-only、idle-only、durable-first 的显式状态迁移，只影响未来 invocation；reviewer 不参与普通 rebind。
- Cowork composer 的底部 selector 只暂存下一次 `@main`，选择本身不是 rebind，当前 task/agent 工作时仍可修改。每次 Send 把当时的 exact binding 冻结进 immutable submitted intent；新式 main/Goal Send 不得接受 `nil`。FIFO 到该 submission 的空闲执行边界后，必须在同一 admission lock / EventLog batch 中原子提交可选 main rebind 与对应 root/retry queue，成功后才更新 live roster；durable Goal 的后续 continuation/恢复继续使用 Goal Send 的 binding。Direct worker message 不携带该字段；失败不得 fallback，也不得改 worker、reviewer、GoalVerifier 或 future-agent default。
- legacy 无 binding、missing revision、definition mismatch、unsupported wire 或显式能力不兼容一律 fail closed，不得回退 current/default/同名 model。
- GUI 与 CLI 的 recovery gate 不得混写。GUI 把 `@main` exact resolution 与 reviewer/control-plane readiness 作为提交后的执行状态，不作为 composer 编辑或本地 admission 条件；完成 Goal 对账后只为新工作释放 scheduler，恢复出的 root tasks 保持 paused/interrupted，直至精确 submission Retry。CLI 则保留显式 `/auto|/default` 与 data-plane resume 边界。active Goal 冷启动只 reconcile 并 durable pause（或 budget-limit），显式 Resume 才创建 continuation。non-empty CLI session 缺失 `@main` 时只能由 host `/agent restore-main <path> <profile-id>` 显式恢复，不能套用 today default。ordinary worker unresolved 不得冻结全局 scheduler：它自己的 queued invocation 必须在 provider request 前 durable fail closed 并清除 active/queued fence，其他 agents 继续运行，随后 host 才可在该 worker idle 时 rebind。
- Modern CLI unqualified model 只有唯一 route match 时才选择该 route；explicit reasoning 必须命中 configured variant/base effort，否则 fail closed，不能合成 synthetic profile。
- reviewer 与 GoalVerifier 是控制面；首次 exact `@main` resolution 冻结其 identity、binding 与 route，data-plane rebind 不能静默 retarget。Permission Reviewer 的 provider wrapper 按该冻结 binding 逐 generation 重新解析；GoalVerifier 保留独立 provider lifecycle。
- binding、EventLog、permission preview、roster/UI 只显示安全 identity/revision/model/variant/route label/trust/egress 分类与不可逆 digest；不得暴露 raw endpoint、credential、headers/query/options 或完整实际 digest。Permission target fingerprint 必须绑定这些安全分类并在 review/prepare/executor 边界复核。
- Cowork durable profile options 只接受显式 allowlisted schema；unknown key、错误 shape/size/depth、secret/auth/header/query/URL/endpoint-like container、runtime structural/stream/multi-candidate fields 全部 fail closed。Chat/Code 兼容 `ProviderEndpoint` 仍可 lossless 保留 arbitrary model JSON，但所有 OpenAI-compatible Chat/Agent request 都必须移除配置 `stream_options`/候选控制并固定 `n = 1`；host output-token ceiling 另移除竞争 aliases。Provider/custom runtime diagnostic 在成为 durable 事实前必须统一把完整 HTTP(S) URL 与 secret 脱敏并限长；ordinary permission preview 不使用该 URL-wide diagnostic rule。所有 provider transport 对 HTTP 30x 都 fail closed，不得自动跟随到未进入 exact binding/trust review 的 endpoint。

Inference catalog 的 immutable revision 也需要可并发恢复：reconcile 的完整旧值读取、revision allocation、snapshot 校验和原子替换必须在同一 mutation lock 内；同进程多个 store instance 与多个进程都不能丢失历史 revision 或分配碰撞。跨进程锁必须锚定稳定、owner-only、no-follow 的普通单链接 sidecar inode；未知平台或不安全 lock state fail closed，不得无锁降级。

Provider resolution 也必须是原子的：shipping resolver 一次返回 exact binding、model 与 provider；Orchestrator 统一与 live agent/task snapshot 复核。Strict runtime 不能走 provider-only factory，也不能允许 app 在多个 mutable lookup 间拼接 route tuple；任一 binding/model/route/trust/egress mismatch 必须在 durable admission 或真实 provider request 前关闭。Catalog candidate update 与 attach/spawn/delegate/rebind 共享 admission lock；如果 exact resolver 在锁外 `await` suspension，返回后必须重检 approved map、roster/current binding 与 fingerprint。AgentLoop execution revalidation hook 还必须在 durable prepare 前 resolve，并在 await 后再次校验，不能让旧授权越过 catalog/roster TOCTOU。Ordinary attach 的 permission-review await 也不能成为豁免：allow 后、durable admission 前必须再次 exact-resolve，并比较 review/resolve/commit 三个 catalog snapshot。Fresh `bootstrapMainAgent` 没有模型 review，但 admission wait 前后必须分别复核 empty-session facts，以锁外二次 resolve + 锁内 catalog/empty-session recheck 关闭同类竞态。

当前 shipped resolver 只有 OpenAI-compatible wire，且没有独立 `InferenceRouteLease`、per-task route approval、跨 trust-domain 专用审批或完整 app model capability metadata。不能把 `CapabilityLease`、`WorkspaceLease`、host-approved catalog 或现有 permission snapshot 宣称为上述未实现能力。详细契约见 `docs/PER_AGENT_INFERENCE_PROFILES.md`。

### 2.4 Capability Lease
工具应按 capability lease 暴露。普通 worker task 不应收到 coordinator 工具（`spawn_agent` / `remove_agent` / `delegate_task`）。若 task 需委派，经 `CapabilityLease.delegation` 显式授予。子 agent 不应仅因被 spawn 就获得 coordinator 能力。Git、文档/媒体与网络/浏览器工具同样按 lease 收窄：新 spawn 的 worker 默认 `read_only`，只能获得安全只读能力；用户/上级显式请求 `read_write` 且不超过 issuer WorkspaceLease ceiling 时，worker 可获得不含 coordinator 工具的 Code/data-plane 写入能力。`canCoordinate` 与 workspace access 正交：只读 coordinator 可调度但不能写 workspace，read-write worker 可执行文件工作但不能 spawn/delegate 下级。

真实终端也遵循这一条。`runShell` capability 在 production 只暴露 runtime-owned `exec_command` / `write_stdin`，不能暴露 raw `run_shell`；read-only worker、reviewer 与禁用 shell 的 host 不获得它。terminal session 必须精确绑定 session/agent/task/attempt/WorkspaceLease，后续 stdin/轮询不是对首次审批的无限续期，而是新的 ToolCall、permission decision 与 durable execution ticket。task terminal 或 lease/root identity 变化必须先结束匹配 session，不能让旧 agent/session ID 继续控制进程。

`rename_session` 是普通工具协议中的 session-local metadata 能力，但不是普通 coordinator 能力。它只进入 exact `@main` 的 default capability lease；worker、spawn 出的 coordinator、task-scoped non-main lease 与 reviewer 都必须移除，不能通过 intersection/继承意外流下去。模型只提供名称，宿主绑定当前 session/kind 和 durable execution ID；不存在跨 session 目标解析。

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
恢复时不能默认把所有 running 任务整段重放。每个实际 tool executor 调用前必须先持久化 execution ticket，结果持久化后再 settle；只有明确 eligible 的 non-root/CLI recovery task 内的普通 read-only 调用可自动重放；GUI restored root 不适用。write/exec/network/destructive 与通信、委派、spawn/remove 等协作副作用处于“prepared 但未 settled”时，任务必须进入人工对账失败态，不能自动增加 attempt。只有明确 eligible 的 non-root/CLI read-only running task 才可在新 attempt 的 queue 事件成功落盘后重排；Phase A GUI restored root submission 始终 paused/interrupted，必须 exact Retry；半完成 admission、耗尽 attempts 或缺失关键 lease 也必须明确失败。执行应有 bounded timeout/cancel、attempt 和明确标为 soft 的 session token budget；模型缺完成标记、迭代耗尽或不完整 finish reason 都是失败。

这里的判断单位是“这一次具体调用是否可能已经产生副作用”，不是只看工具静态类别。write 类工具继续默认 non-replayable；只有拥有 mutation boundary 的受信实现或 prepare 前 durable state 能证明该边界未被跨越时，才能追加可选 `effectDisposition=not_started` 的失败/取消 settlement。typed ordinary failure 可作为 observation 回灌同一 Agent turn；pre-executor cancellation 结算后仍中断 turn；legacy repair 只对账 EventLog，不存在当前 turn。新成功 settlement 必须显式标为 `committed`；legacy nil+succeeded 仅兼容成已完成效果并继续阻断 whole-task retry。生产 Orchestrator 的 `task_update` stale revision 是当前首个精确 no-effect case；公共 manager 的同名错误、普通 error、timeout、executor 内 cancellation、legacy failure nil/unknown 都不能套用。Projection 对 execution ID 坚持一次 prepare：第二个 prepare 即使相同也永久 ambiguous，冲突 terminal 同样保留首记录并永久 ambiguous；只有完全相同 terminal 可幂等，`succeeded + not_started` 是无效矛盾并进入 uncertain。旧日志修复必须先由 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 证明历史完整，并且只能发生在无 current Goal、exact 唯一 prepare、没有任何 settlement/ambiguity、JSON safe integer 与 prepare 前 monotonic revision proof 同时成立时，不得解析自由文本或用 prepare 后状态猜测。Goal startup/进程内 launch、Orchestrator restore 与 whole-task retry 都必须使用同一 complete-known-history gate；unknown future type 或 seq gap 不能支持 absence/order proof。任务级确定错误应局部终结，不应无条件升级成整个 session 不可输入；无 Goal 的隔离仍须证明 exact contract-before-prepare、正 attempt 与 exact-attempt terminal-after-prepare，无法归属、损坏/不完整历史、非终态任务与任何 current Goal 的 uncertain 副作用保持 fail closed。

Permission Reviewer 是独立控制面，不是普通 worker：使用结构化 `PermissionReviewTask`、有界 FIFO/single-flight、独立 timeout/cancellation/单次输出上限，不占数据面 scheduler 槽，也不得递归运行 `AgentLoop`。deadline 从 submit 计时，queue full/timeout fail closed；自动模式只有 `allow` / `deny`。pre-submit caller cancel 直接返回 typed deny且不创建 review lifecycle；timeout、truncated、malformed、tool call、provider/persistence failure 与已登记 review 在 terminal-claim 前被观察到的 cancel durable deny 当前调用，不得隐式切到 GUI 人工 fallback；claim 后 cancel 保留唯一 settlement 但最终 authorization delivery deny。review request 与 verdict 都必须 durable-first；`allow` 只有 settled audit 成功后才可返回，自审或 hard deny 都不得放行，恢复时 orphan request 必须显式关闭。每个 provider dispatch 使用 exact `{reviewTaskID, nonce}` generation；provider/timeout 竞争同代首 terminal，provider-backed terminal claim 必须匹配该 generation，pre-dispatch terminal 则从 running/no-generation 状态唯一 claim。caller cancel 由同步 request token、actor path 与 settlement/delivery/admission 围栏共同处理。timeout/cancel 只影响当前 call；若已有 active generation 就只 retire 该代，下一 request fresh-resolve provider wrapper；旧代 late/duplicate result 无 EventLog/health/authorization 能力。provider factory 冻结 reviewer identity/exact binding，且不得捕获 Orchestrator；`ToolCallingProvider.stream` 必须立即返回 request-owned stream，并传播 consumer termination，同步永久阻塞实现不在契约内。累计 token 仅可作为 soft warning/度量，默认不得用不可恢复的 session-lifetime cap 永久关闭 reviewer。用户取消当前数据面任务不得顺带关闭常驻 reviewer；只有 session stop、显式 disable 或控制面自身安全故障才进入 quiesce/shutdown。停用 reviewer 先 quiesce，再持久化 revoke/detach；迟到 allow 或落盘失败不得被误报成成功停用，detach 失败 resume 后仍必须用 fresh generation。terminal claim 后 cancel/quiesce 可使最终 authorization delivery deny，但不得重写唯一 reviewer settlement 或执行工具。reviewer 只可在 deterministic gate 的最大权限边界内收窄，不能批准真正越权；人工模式只能由用户显式切换。legacy `provider_still_stopping` 只作旧 EventLog 解码，不得重新成为 live permission-review state。

每个 ask-class request 还必须有稳定 RequestID、TurnID 与 toolCallID，并在 responder/UI/transport 可见前 durable register。EventLog 在完整已知历史与跨进程锁内实现 request first-write、settlement first-terminal；exact duplicate/reconnect 幂等共享原 owner generation/terminal，冲突 payload 或终态 fail closed。人工 action 必须显式区分 approve、decline、cancel-turn：decline 是 call-scoped，写 typed denied tool result 后允许同一 turn 继续；cancel-turn 是 turn-scoped，只写 permission terminal并结束为 interrupted，不能制造 user-denied tool result。automatic mode 从最早通用 request event 起不可人工操作或 fallback。pending projection/CLI responder 保持 FIFO，结算中间项不能改变其他请求相对顺序。取消/停止先 drain provider/tool child，再清 waiter、关闭 reviewer与发布 terminal。

Goal Verifier 是另一条独立控制面，职责仅是判定 Goal 是否已有充分证据完成。它不是 Permission Reviewer，也不是普通 agent：使用独立 system/context、无工具 provider 请求、有界 timeout/cancel/output，不能写 EventLog 或执行 workspace 动作。WorkTask result/evidence 是 agent-reported，不是完成证明；只有 host 从同一 Goal 的 durable 成功 tool-execution settlement 经 validation-tool allowlist 派生的 `validationEvidence` 才能作为 completion proof。malformed、tool call、缺完成标记、provider/usage failure、timeout/cancel 必须 fail safe 为 `continue`，不能误报 Goal 完成。只有 host 校验 verifier 返回的 requirement/evidence 与这些 host-bound evidence 一致后，才可追加 Goal audit/completed 事件。

Goal 生命周期必须由 host 串行化：start、ordinary turn、Goal mutation 与 stop/shutdown 分别有 single-flight/mutation/stop gate；pending durable stop 未结算前不得启动新 run，start 取消后若已创建 continuation，必须先 scoped cancel、等待退出并 checkpoint 才返回失败。restore 必须持续暂停 scheduler，直到 roster/reviewer/main 与 Goal recovery/reconcile 完成。GUI 随后只释放新工作并继续围栏 restored roots；CLI 才执行显式 data-plane resume。Cowork `/goal` 是明确 host action；普通自然语言只有在窄、确定性的中英文持续目标分类器命中时才可为本轮提供 create intent，复杂请求、Goal 提及、一次性目标、引用示例或附件内容不得提升权限。

模型可见的 agent/task/message/goal/session 操作与文件、网络、文档工具遵循同一个 ToolCall 协议。WorkTask CRUD、Goal create/update 与 session rename 都必须先过 schema、lease（Cowork）与 PermissionEngine；`rename_session` 的 exact current-session/no-path/no-network/no-data-effect intent 可由 deterministic gate 低风险放行，但 near-miss 与 locked 状态不能借此绕过。worker 默认只能读取 Goal/相关 WorkTask，并更新自己当前绑定的 WorkTask，不能改 DAG/owner/priority/retry/cancel、提交 Goal verdict或改 session 名称。一个外部 ToolCall 只能有一个权限决定；`spawn_agent` / 原子 `delegate_task` 获准后，内部 roster、lease、mailbox、task graph 与 scheduler admission 必须作为 executor 的 durable transaction 完成，不能再次递归进入 PermissionEngine。Code 与 Cowork agent 共用 headless `AgentRuntime`；首个 system message 必须稳定声明 Intatis 模式、API tools 权威性、严格 JSON Schema 与 ToolResult 完成语义，动态 workspace/task/lease/goal/run 数据仍放在 user-role untrusted context。

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

Cowork 可以采用项目制：一个 session 绑定一个或多个用户选择的工作目录，并有一个 `@main` 主 agent。用户默认只向 `@main` 下达项目任务；`@main` 通过工具创建、委派、调取、删除子 agent，并管理任务、上下文、未来-agent inference default、权限 profile、token budget 等 project metadata。但 project/session settings 只是本地元数据与 UI 投影；future default 不得重写现有 agent，也不得替代 task contract、exact inference binding、capability lease、workspace lease 或权限门。

Session 状态遵循一个事实源、两个不同性质的本地投影：

```text
events.jsonl              canonical settings / migration / agent+lease registration / runtime events
session.json              schema-v2 secret-free rebuildable projection; EventLog always wins
workspace-access.plist    schema-v1 session-owned opaque bookmark capability; never copied into either text store
```

- settings、显示名、迁移标记必须 EventLog-first；append 返回值和 subscriber 也必须发布从实际落盘 bytes 反解的 canonical Envelope。legacy display name 必须在任何 schema-v2 rebuild 前捕获，并在同一 transaction 中先追加 settings+marker；`session.json` 同水位也要用完整 EventLog fold 校验，不能因 cache 看起来“更新”就信任它。模型改名记录必须保存 source 与宿主提供的 durable execution ID；同 operation exact retry 不能追加，冲突 payload fail closed，旧 operation retry 只返回 latest projection而不能覆盖更晚 rename。raw 名称在 authorization/prepared 前 secret-scan，不能进入 durable tool-call args/digest。
- bookmark 是能力材料，不是项目文案或普通设置。它必须以 binary plist、`0600`、no-follow lock、原子替换与 file/parent sync 保存；macOS 在实际 Code/Cowork 使用期持有同一 scoped URL 的 `WorkspaceAccessLease`，不能只保存 canonical path 后立即停止 security scope。共享 path 必须按 settings + live roster 做引用判断，不能 last-writer-wins；primary 在 UI、业务方法和 store 默认拒删，只有尚未成立的新建/重授权事务失败回滚可显式清理。
- UserDefaults/旧 path map 只作迁移输入。只有 session 自己存在 ownership evidence，且 exact binding、全部必需 bookmark、primary 语义与 capability 文件都验证成功，才可追加稳定 migration marker并清理旧 key；symlink alias 必须先 resolve bookmark、启用 scope、验证 canonical identity，再把 canonical settings 写入 EventLog，最后写 marker。候选发现可跳过无关 stale evidence，但真正选中的 source 必须再次严格 resolve。marker 后禁止从 global map 恢复能力材料。
- Session settings 本身不授予 capability/workspace lease，也不触发 provider。可恢复“登记”不等于可恢复“执行”；普通 recovered root task 不得因 projection 重建而自动续跑，active Goal 也只能在冷启动对账后 durable pause。运行中的 app 内 session 切换/Command-W 不等于 Stop；Command-Q 才对全部 runtime 发起 bounded stop，crash/reopen 只显示 reconciled interrupted/paused 状态。继续执行必须是用户显式 Send、Retry 或 Resume。

工作区扩展**绝非**只读。创建或附加 agent 到新目录是能力/工作区扩展，必须经权限。唯一例外是 brand-new session 的初始 bootstrap：用户在 New Cowork Session 文件选择器或 CLI workspace 参数中明确选定 primary workspace 后，这次显式选择本身授权一个严格 settings-first 七事件合同，连续 `seq 0...6` 依次登记 settings、`@main` workspace/capability/agent、`@permission-reviewer` workspace/capability/agent。两者共享 host-selected exact inference binding，但 identity、workspace lease 与 capability lease 必须不同；reviewer 固定 read-only、空工具、无 communication/delegation、depth 0。该路径还必须要求空 EventLog、空 roster、敏感/过宽根目录拒绝、canonical identity 与 durable-first；初始化不调用模型/provider，也不能被普通 attach/spawn/tool/recovery 复用。

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

managed terminal 不能成为这条规则的例外。macOS process/PTY 必须在 WorkspaceLease 对应的 OS sandbox 内运行并默认断网；交互输入也要经过危险命令 hard deny。输出要持续有界 drain，stdin 原文/无盐固定摘要/延迟回显不能进入 EventLog 或 agent 间消息；取消、失败、task terminal 与 runtime shutdown 必须先 drain terminal process tree，再发布上层终态。Linux 缺少可证明的 sandbox/PTY backend 时应 fail closed。

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
- session-global provider/model selection makes existing agents drift together
- recovery silently substitutes a current/default model for an unresolved exact binding
- session settings/bookmarks are split across UserDefaults/global path maps without one canonical session authority
- session.json can override EventLog or become the only source of a rename
- fresh bootstrap omits canonical settings or relies on a model request before local registration
- legacy shared bookmark fallback can resurrect deleted session capability material after migration
- EventLog append can publish a pre-encoding object that diverges from replayed canonical bytes
- legacy display-name migration can rebuild schema-v2 projection before preserving the old name
- historical-main recovery can accept a malformed settings revision chain outside the strict canonical fold
- shared workspace metadata can overwrite the only owner and revoke a still-referenced bookmark
- shared primary workspace can become removable while roster restoration is still pending
- symlink alias migration can compare protected paths before enabling the bookmark security scope

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
- EventLog-derived context/recovery index remains a future long-session performance optimization；task-scoped worker request context 必须始终有界。稳定 `@main` 当前为避免再次丢历史而重放完整 model thread，在 replacement-history compaction 完成前长度暂时无硬上限；这是显式 active gap，不能用最近 N 条或自制摘要悄悄截断，也不能把当前状态宣传为 bounded long-session solution
- composer/edit-dialog permission UX (Phase A), reviewer request/generation isolation (Phase B), permission/tool/turn outcome semantics (Phase C), and App/runtime ownership plus quit semantics (Phase L) are implemented as separate changes; Phase S persistence must not be described as solving any of them
- application runtime ownership stays exact-session scoped: windows own presentation, the app manager owns runtimes; switching/Command-W never implies stop, exact deletion drains only that session, Command-Q closes admission and uses bounded concurrent shutdown, and cold reopen never auto-dispatches provider work
- immutable inference revisions and exact agent/task bindings must never be collapsed back to mutable current/default pointers
- future-agent default changes must not rewrite existing agents; implicit spawn inherits exactly, explicit profile stays host-approved, and rebind remains host-only/idle-only/durable-first
- permission/control-plane audit must retain a safe target-binding snapshot without leaking endpoint, credential or options
- non-OpenAI-compatible wires, route leases/cross-trust-domain approval, complete capability metadata and real multi-upstream E2E remain explicit future work rather than implied current behavior
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
11. Add versioned immutable inference catalog + exact per-agent binding before adding multi-wire, route-lease or fallback policy; do not retrofit a mutable session-global model pointer into agent identity.
12. Keep session state EventLog-first, `session.json` rebuildable, bookmark capability session-owned, legacy migration provenance-bound, and fresh bootstrap fixed at seven local events before changing composer/reviewer/lifecycle behavior.
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
read-write shell-capable worker sees managed exec_command/write_stdin, while read-only worker/reviewer/disabled host sees neither and no production registry exposes raw run_shell
terminal session ownership includes exact session/agent/task/attempt/workspace identity; another owner, a replaced root, revoked lease, task terminal, cancel, or shutdown cannot retain control
write_stdin is independently authorized, cannot bypass dangerous-command hard deny through split input or mutable line editing, cursor/completion/history/escape/keymap changes fail closed, partial-write uncertainty terminates the session, and neither raw input nor delayed echo is persisted
terminal execution unions the mandatory credential-path floor into every current or legacy WorkspaceLease and enforces denied patterns case-insensitively at the OS sandbox boundary
managed terminal uses a real controlling PTY when requested, continuously bounds/drains output, preserves newest tail, cleans descendants, and does not cap normal build-artifact file size
delegation cycle is rejected
workspace expansion requires permission
fresh-session bootstrap attaches fixed @main with a host-selected exact inference binding, without model review, and cannot be reused after any durable session state exists
fresh-session bootstrap writes exactly seven ordered events (settings, main workspace/capability/agent, reviewer workspace/capability/agent), uses distinct identities/leases, and never calls a provider
session settings protocol round-trips/legacy-decodes additively, rejects wrong session/kind/schema/revision/migration IDs, and canonical encoding omits legacy defaultProviderID
session.json schema-v2 refresh is EventLog-wins against same-watermark and lagging corruption, serializes concurrent writers, refuses unknown future session events, and is safely rebuildable
workspace-access.plist is schema-v1 binary owner-only 0600, validates session/path/single primary, preserves primary on bookmark refresh, and rejects unsafe lock/write states
security-scoped workspace access is retained for the whole active Code/Cowork lifetime and reauthorization accepts only the exact canonical historical path
legacy settings/bookmark migration requires per-session provenance plus all-required capability verification, writes an idempotent marker before cleanup, and never resurrects global fallback after that marker
historical missing-main recovery uses canonical settings and a dedicated host-authorized path; reviewer replacement happens only after main repair; neither path calls the provider or resumes interrupted work
session rename appends the EventLog settings transition before refreshing session.json and never changes SessionID/directory
agent-to-agent event records caller, target, task, and causal chain
automatic permission reviewer cannot override hard deny
automatic permission reviewer can be enabled/disabled without becoming a normal worker
permission request identity is first-write-wins and conflicting RequestID reuse fails closed
permission settlement is first-terminal-wins under concurrency; exact duplicates are idempotent and conflicting terminals cannot overwrite the first
legacy outcome/action/mode/correlation fields decode conservatively, while each new Chat/Code/Cowork turn records one semantic terminal turn outcome
manual decline emits one denied tool result and continues the same turn; cancel-turn interrupts without a fabricated denied tool result
pending permission projection and CLI response handling stay FIFO, including middle-item settlement, and automatic requests expose no manual action
turn abort drains provider/tool execution before clearing approval waiters, shutting down the reviewer, publishing terminal state, or returning to the caller
trusted sandbox startup denial is typed and not-started when provable, but never automatically widens authority, removes the sandbox, or retries
user turn creates a root task and waits for one terminal event
same agent is single-flight while different agents respect the concurrency limit
eligible non-root/CLI read-only crash recovery increments attempt; GUI restored root submissions stay paused/interrupted until exact submission Retry; exhausted/interrupted admission fails explicitly
tool execution projection accepts only one prepare per execution ID, permanently quarantines duplicate prepares/conflicting terminals while retaining the first records, and rejects succeeded/not-started contradictions
new successful settlements are explicitly committed; legacy nil+succeeded remains a completed effect that blocks whole-task retry, while legacy failed/cancelled/denied nil and explicit unknown remain uncertain
Orchestrator restore, Goal startup/in-process launch, and whole-task retry require complete known projection history; unknown future event types and seq gaps fail closed for absence/order proofs
legacy stale task_update repair requires no current Goal, one exact unambiguous prepare, no settlement, a JSON-safe expected revision, and durable pre-prepare revision proof
no-Goal uncertain-ticket isolation requires exact contract/positive-attempt/terminal ordering; any current Goal requires an empty uncertain set
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
inference catalog reuses semantically equal revisions, appends on semantic change, retains old revisions, and rejects unsafe/corrupt/insecure definitions without overwriting the store
Cowork durable options accept only the explicit bounded schema; unknown/shape/secret/auth/header/query/URL/endpoint/structural/stream/multi-candidate fields fail closed, while Chat/Code arbitrary ProviderEndpoint options remain lossless
every OpenAI-compatible Chat/Agent request strips config stream_options/candidate controls and forces n=1; host includeUsage alone rebuilds the usage shape and a host token ceiling also strips competing token aliases
legacy inference fields decode as unresolved; exact resolver never falls back to current/default and fails before secret/network access on missing/mismatched revisions
same model with different variants/connections/credential references remains isolated across two agents in one session
implicit spawn inherits the issuer's complete exact binding; explicit profile is host-approved and raw model/profile ambiguity is rejected
TaskContract freezes inference binding; live roster mismatch fails before provider dispatch
busy rebind is rejected; host-only idle rebind persists previous/new binding before memory change and affects only future invocations
Cowork bottom selector stays available while work is active, stages only the next @main binding, and each Send freezes an independent exact value that survives FIFO/outbox/replay/retry; direct worker messages carry none and no fallback or control-plane/default retarget is allowed
delegate authorization snapshots the target's exact safe inference binding including route/trust/egress classification and revalidates its derived fingerprint after review and prepare
catalog update and admission/rebind share a lock; spawn/rebind and AgentLoop pre-prepare execution revalidation reject catalog/roster changes that occur while an async exact resolver is suspended
ordinary attach revalidates the exact approved profile after permission-review await; bootstrapMain revalidates exact profile plus empty-session facts around its admission wait before durable admission
reviewer/GoalVerifier provider stays frozen when a data-plane agent is rebound
CLI compiles multiple routes/models/variants, retains old exact revisions, and resolves each connection revision with its own credential reference rather than the selected route's key
CLI selects an unqualified model's route only when unique, rejects missing reasoning variants, and requires explicit restore-main for a non-empty session with no durable @main
GUI local admission remains available regardless of exact-main/reviewer readiness and only new work is released after recovery; CLI retains explicit data-plane resume; an unresolved ordinary worker durably fails only its own queued invocation before provider dispatch, clears its busy fence, and does not pause other agents
macOS raw variant config keys never enter durable bindings/events; diagnostic URLs are redacted and provider HTTP 30x redirects are never followed
roster/UI/CLI inference presentation never exposes raw endpoint, credential, options, secret-shaped labels, or a complete actual digest
provider/custom runtime diagnostics are secret-redacted again before durable ErrorPayload/task failure persistence
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
