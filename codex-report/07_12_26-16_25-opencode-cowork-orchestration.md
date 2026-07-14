# OpenCode / Claude Code 编排调研与 Intatis Cowork 修复建议

## MODEL_CHECK_RESULT

当前模型：GPT-5（无法从运行环境确认更细的公开版本标识）。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 路径匹配预期：是
- 工作树在本报告创建和本次修订前均已有多项未提交改动；本报告没有覆盖、回退或清理这些改动。

## FILES_WRITTEN

- `codex-report/07_12_26-16_25-opencode-cowork-orchestration.md`

## POLICY_REVISION

本报告最初按 Intatis 的严格 clean-room 政策编写。2026-07-12 项目政策已升级为 Apple-first、Swift-native 优先，并允许按 `docs/OPEN_SOURCE_REUSE.md` 选择性复制、翻译、修改或运行兼容许可证的公开实现。本修订版据此把“禁止复制源码”改为“可以合规复用源码，但不能照搬不兼容的运行语义、品牌资产或安全默认值”。

截至本次修订，OpenCode 仍是 `research-only`：尚未把其源码、公开 prompt、UI 资产或 runtime 加入 Intatis。后续每批复用必须固定上游 commit、核对具体文件/依赖许可证并更新 `NOTICE.md`。

本报告随后又根据 2026-07-12 的产品方向讨论修订：Cowork 的默认权限审批目标明确为全自动；累计 token 预算不再被视为权限硬边界；第一阶段以“新建 session 到任务明确终态”的最小可用闭环为目标，OpenCode 调研与源码复用只作为加速该闭环的工程手段。

## SUMMARY

结论是：Intatis 对 Cowork 的核心判断基本正确，但最终实现不应完整复制 OpenCode 或 Claude Code 中的任何一种架构。更适合 Intatis 的组合是：

- 用 OpenCode 的思路定义可靠的单 agent session/runtime。
- 用 Claude Code Agent Teams 的思路定义共享任务、mailbox 和多 session 控制平面。
- 用 Intatis 自己的 EventLog、CapabilityLease、WorkspaceLease、PermissionEngine 和 scheduler 提供可恢复、可审计、自动审批的本地执行语义。

从产品定位上看，Intatis 不是三个彼此独立的聊天页面，而是一个本地 Agent runtime/scheduler：

```text
Chat    = provider / streaming 基线
Code    = 单 AgentRuntime 的可见调试与执行表面
Cowork  = Orchestrator 管理多个相同 AgentRuntime 的协作表面
```

对应的系统类比是：

```text
ToolCall         = system call
AgentRuntime     = process
CapabilityLease = capability table
WorkspaceLease  = mount / access boundary
EventLog         = WAL + audit + recovery source
Orchestrator     = scheduler / control plane
UI               = projection / console，不是事实源
```

模型负责意图、规划和工具选择；Intatis 负责校验、授权、执行、持久化、调度和恢复。

产品目标不是让用户操作一套 agent 管理后台，而是让用户选择项目、描述目标，随后由 `@main` 自动组织受限 worker 和真实工具完成工作。用户不应被要求手动创建普通 worker、理解 lease/task graph、反复批准权限，或通过猜测侧栏和输入框状态判断任务是否已经启动。

第一阶段的成功标准是一个可重复的 Cowork 最小闭环，而不是功能数量：新 session 出现在侧栏，`@main` 与 reviewer 正常挂载，composer 可输入，首个模型请求带有正确环境和工具，main 能委派，worker 能执行并汇报，main 能综合结果，root task 最终明确 completed/failed/cancelled，composer 解锁，重启后可解释并恢复持久状态。

## OPEN_SOURCE_EVIDENCE

### 1. OpenCode 把创建子 agent 实现为普通工具调用

OpenCode 当前活跃官方仓库是 [`anomalyco/opencode`](https://github.com/anomalyco/opencode)。旧的 `opencode-ai/opencode` 已归档，因此本报告以当前仓库 `dev` 分支为主要源码依据。

OpenCode 的 `TaskTool` 使用与 read、edit、bash 等工具相同的工具定义机制。模型调用 `task` 后，执行路径大致为：

1. 对 `task/<subagent_type>` 做权限判断。
2. 查找目标 agent 类型。
3. 创建带 `parentID` 的子 session。
4. 派生子 session 的权限。
5. 对子 session 调用同一套 prompt/runtime。
6. 把子 agent 的最终文本作为 task result 返回父 session。
7. 后台执行时，在完成后向父 session 注入合成 task result。

源码依据：[`packages/opencode/src/tool/task.ts`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/task.ts)。

这验证了 Intatis 的设计哲学：创建、恢复和调度 agent 可以是模型可见的普通工具调用，差异仅在 executor 由宿主应用处理。

### 2. 子 agent 是真实 session，而不是特殊函数回调

OpenCode 创建子 agent 时会为其建立具有 `parentID`、agent 类型、模型与权限配置的子 session。子 agent 继续使用同一个 session prompt/runtime，而不是维护另一套简化执行器。

这支持以下 Intatis 方向：

```text
Code UI ───────▶ AgentRuntime × 1
Cowork UI ─────▶ Orchestrator ─────▶ AgentRuntime × N
```

Cowork 中的 main、worker 或 specialist 都应运行同一种 headless Code runtime。角色属于当前 TaskContract，而不应固化为另一套 AgentLoop 类型。

### 3. 工具能力不仅写在 system prompt，还动态写入工具定义

OpenCode 的工具 registry 会：

- 枚举当前可见的 built-in/custom/MCP 工具。
- 为每个工具提供 description 和 JSON Schema。
- 根据模型选择 edit/apply-patch 等工具变体。
- 对 `task` 工具动态追加当前 agent 有权调用的子 agent 类型及其说明。

源码依据：[`packages/opencode/src/tool/registry.ts`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/registry.ts)。

因此“告诉模型它有哪些工具”不能只依赖 system prompt。Intatis 每次请求至少要同时保证：

- system message 中有稳定的 Intatis 运行环境和行为约束。
- API `tools` 中有本轮真实可用的工具以及严格 Schema。
- 协调工具 description 中动态列出允许的 agent 类型、限制和调用语义。
- 动态任务、workspace、agent、lease 信息放在有边界的 user-role untrusted context 中。

### 4. OpenCode 会注入运行环境，并按模型家族选择基础 prompt

OpenCode 会在 system context 中加入模型、工作目录、workspace root、Git 状态、平台和日期，并根据模型家族选择不同的基础 prompt。

源码依据：[`packages/opencode/src/session/system.ts`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/system.ts)。

这支持 Intatis 增加自己的 `RuntimeEnvironmentManifest`，也说明 DeepSeek Flash 等较弱模型可能需要小型、Intatis-specific 的 model-family prompt overlay。OpenCode 公开仓库中由兼容许可证覆盖的 model-facing prompt 可以作为派生复用候选，但必须固定 commit、记录来源、移除 OpenCode 品牌/支持链接，并重新适配 Intatis 的工具名、权限与安全语义；产品文案、名称和 UI 品牌不复用。

### 5. 权限是工具级规则，而不是单独的“agent 系统”

OpenCode 的 permission service 使用 `allow`、`deny`、`ask` 规则匹配工具名和参数 pattern；TaskTool 同样调用普通的 `ctx.ask`。权限通过后，创建 session、设置 `parentID` 等内部实现步骤不会各自再发起一轮模型审批。

源码依据：[`packages/opencode/src/permission/service.ts`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/permission/service.ts)。

这直接支持 Intatis 的修正：一个已获准的 `spawn_agent` 或 `delegate_task` 应当只有一个外部权限决定。内部的 registry mutation、workspace lease 建立、roster 更新、event batch append 和 scheduler enqueue 不应递归进入 PermissionEngine。

### 6. OpenCode 当前会显式派生子 agent 权限

OpenCode 曾出现子 agent 丢失父级限制的问题。当前 `deriveSubagentSessionPermission` 会传播父 session 的 deny 与 `external_directory` 规则，并在子 agent 未显式允许时默认禁止 `task` 和 `todowrite`。

源码依据：[`packages/opencode/src/agent/subagent-permissions.ts`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/agent/subagent-permissions.ts)。

对 Intatis 的含义是：

- 子 agent 能力只能等于或小于 CapabilityLease 授权范围。
- 父级 hard deny 和 workspace 边界必须向下传播。
- worker 默认不能持有 coordinator 工具。
- 允许继续委派必须是显式、task-scoped 的能力。
- agent 消息不能改变权限或代替权限审批。

### 7. Claude Code Agent Teams 更接近 Cowork 控制平面

Claude Code 主程序不是完整开源项目，因此本报告只使用其官方公开文档作行为对照，不把闭源实现当作源码事实。

官方文档描述的 Agent Teams 包含：

- 一个主 session 作为 team lead。
- 多个独立 session 作为 teammates。
- 一个共享 task list。
- 一个 mailbox/message system。
- task dependency 自动解锁。
- 独立 transcript 和上下文窗口。

来源：[Claude Code Agent Teams 官方文档](https://code.claude.com/docs/en/agent-teams)。

官方并行 agent 文档也明确把各种 worker 视为 session，并区分 subagent、agent view、agent teams 和 dynamic workflow 的协调方式。来源：[Claude Code Run agents in parallel](https://code.claude.com/docs/en/agents)。

这与 Intatis 已有的 Orchestrator、TaskGraph、AgentScheduler、MessageBus 和 EventLog 更接近，也说明 Cowork 不应退化为主 AgentLoop 同步调用多个子函数。

### 8. 权限审查者应属于控制面，不是普通 teammate

Claude Code 的公开 hook 机制把 `PreToolUse` 和 `PermissionRequest` 放在工具执行前，并允许 verifier 做 allow/deny/ask 等决定；deny 原因会作为工具错误反馈给模型。来源：[Claude Code Hooks reference](https://code.claude.com/docs/en/hooks)。

Claude Code 官方文档还明确说明：agent 消息不能批准 pending permission，也不能修改另一个 agent 的权限设置。来源：[Claude Code Subagents](https://code.claude.com/docs/en/sub-agents)。

这支持 Intatis 当前原则：`@permission-reviewer` 是独立权限控制面，不进入普通 task pool，不接受普通 delegate/message，不占 worker scheduler slot，也不能通过 agent 消息改变权限。

## REUSE_BOUNDARIES

### 1. 不照搬 OpenCode 的同步嵌套执行方式

OpenCode 的前台 TaskTool 会在工具 executor 中直接调用子 session 的 `prompt()`。这种实现对单进程工具壳很直观，但与 Intatis 的明确原则冲突：`AgentLoop` 不得同步递归调用另一个 `AgentLoop`。

Intatis 应保留下列路径：

```text
ToolCall
  -> schema / lease / permission
  -> durable prepare
  -> Intatis orchestration executor
  -> append task/agent/mailbox events
  -> scheduler 唤醒目标 AgentRuntime
  -> TaskReport / message event 返回调用者
  -> durable settle
```

OpenCode 对应源码可以在 MIT 与 provenance 要求下选择性复用或翻译，但进入 Intatis 时必须把同步 `ops.prompt()` 递归改造成 scheduler/mailbox/event flow，不能因为复用了成熟实现就保留与 Intatis durability 原则冲突的执行方式。

### 2. 不把 `ask` 式人工等待带入全自动审批模式

OpenCode 的默认 `ask` 会等待外部 UI 回复。Intatis 的核心产品特征是全程自动权限审批，因此自动模式必须有清晰终态：

```text
allow | deny
```

在自动模式中，reviewer timeout、取消、输出不可解析、provider error 或 persistence failure 都应让**当前工具调用** durable deny/fail closed；不能静默转为 GUI 人工等待并让整个 scheduler 卡住。人工模式如果保留，只能是用户明确切换的独立模式，不能成为自动模式的错误兜底。

“预算耗尽”不能和上述运行错误简单并列。累计 token 预算是资源管理问题，不是权限安全边界。实施本报告前的源码仍有 reviewer session-lifetime token meter 和 `ask_user` 人工 fallback；它们属于需要演进的旧实现，不是本报告定义的目标语义。最小闭环阶段，reviewer 应保留单次请求 timeout、最大输出和队列容量等有界保护，但不应因一个不可恢复的 session 累计 token 上限而永久停止审批。达到资源阈值时应记录度量、压缩上下文、滚动额度或明确失败当前调用，不得把整个 Cowork session 卡成不可用状态。

### 3. 有条件复用源码与公开 prompt，不复用品牌和私有材料

OpenCode 根仓库使用 MIT License，因此具体源码、测试和由该许可证覆盖的公开 model-facing prompt 可以在文件/依赖许可证核对后复制、翻译和修改，并用于闭源商业产品。每批复用都必须记录上游 URL、固定 commit、目标文件、许可证和本地修改，实际引入时更新 `NOTICE.md`。

仍然禁止使用泄露/私有源码或 prompt，也不复制 OpenCode 或其他产品的名称、Logo、图标、截图、UI 资产、商标性外观或品牌文案。许可证允许复制代码不等于获得品牌授权。

### 4. 不把 agent 层级硬编码成永久角色树

OpenCode 的 primary/subagent 配置适合工具壳，但 Intatis 已定义更通用的模型：Agent Identity 持久、角色属于 TaskContract、能力属于临时 Lease。不能重新固化 main/coordinator/worker/leaf 永久递归树。

## SOURCE_REUSE_UPGRADE_MAP

为降低语言迁移和上游升级成本，建议按文件/模块分批采用，而不是 fork 整个 OpenCode monorepo：

| OpenCode 候选 | Intatis 目标 | 推荐复用形式 | 必须保留/改写 |
|---|---|---|---|
| `session/system.ts` 与 provider prompt selection | `RuntimeEnvironmentManifest` / `ContextBuilder` | `derived`：选择性翻译环境组装和模型分流逻辑 | 保留 Swift-native；重写 Intatis 身份、工具名、权限说明；不保留 OpenCode 品牌文案 |
| `tool/registry.ts` | `ToolRegistry` / lease-filtered descriptors | `derived` + 上游行为测试 | 复用动态 agent/tool description 思路；继续由 CapabilityLease 决定真实工具面 |
| `tool/task.ts` | `CoordinatorTools` / atomic `delegate_task` | 选择性翻译参数、session metadata 与结果注入逻辑 | 删除同步 child `prompt()`；改为 durable prepare → scheduler/mailbox → TaskReport → settle |
| `agent/subagent-permissions.ts` | Capability/Workspace lease derivation | 翻译规则与测试边界 | Intatis hard deny、workspace identity、task-scoped revoke 比上游更严格，不能降级 |
| `permission/service.ts` | reviewer 前的规则匹配与 deny feedback | 复用匹配算法或测试，不整体替换 PermissionEngine | 保留三层门、自动 reviewer、durable review request/settled 和 fail-closed |
| session/task tests | request snapshot、model compatibility、delegation regression | 移植测试意图；必要时翻译 fixture | 记录上游测试来源；断言改为 Intatis EventLog/Lease/TaskGraph 语义 |
| OpenCode TypeScript runtime | 可选 macOS external runtime adapter | 仅在确有收益时作为 `external-runtime` 评估 | 需要 Node/Bun、签名、Hardened Runtime、超时/取消/进程清理；不得进入 iOS |
| OpenCode TUI/Desktop UI、名称、图标、截图 | 无 | 不采用 | Intatis 保持 SwiftUI/AppKit 和独立产品身份 |

每批升级的固定流程：

```text
pin upstream commit
  -> audit target files / LICENSE / NOTICE / transitive dependencies
  -> classify reuse mode
  -> create provenance entry
  -> adapt to Swift + Intatis security/event semantics
  -> add request/behavior regression tests
  -> update NOTICE
  -> record local patch/translation delta for future upstream sync
```

这种形式允许优先拿到 OpenCode 已验证的请求构造、工具描述、task/session 和 permission 边界，又避免把 Bun/TypeScript 整仓强行塞进 Apple-native 内核。

## REVISED_INTATIS_PLAN

### 1. 提取统一的 AgentRuntime

建立一个可复用的 headless runtime 配置/工厂，使 Code 和 Cowork 共享：

- ContextBuilder / ContextProjector
- ToolRegistry 与 Schema
- AgentLoop completion semantics
- PermissionEngine
- durable tool execution prepare/settle
- timeout、cancel、budget 与恢复语义

CodeViewModel 只拥有一个 runtime；Cowork Orchestrator 持有多个 runtime，不复用 CodeViewModel 本身。

### 2. 建立稳定的 RuntimeEnvironmentManifest

第一次请求以及后续每次模型请求都应可靠包含：

- 当前运行在 Intatis 的 Chat/Code/Cowork 哪种模式。
- 所有外部动作必须通过工具完成。
- 只有 API `tools` 中出现的工具才真实可用。
- Tool arguments 必须严格满足 JSON Schema。
- 不得声称已经执行未产生 ToolResult 的动作。
- 当前 agent 的任务、完成条件、失败协议和汇报协议。

动态 workspace path、TaskContract、agent identity、CapabilityLease 和近期事件只放在有界、转义的 user-role untrusted block，不能拼入稳定 system prompt。

### 3. 所有 Intatis-native 操作进入统一 ToolRegistry

建议工具面分为：

```text
agent
  spawn_agent
  list_agents
  remove_agent

task
  delegate_task
  list_tasks
  cancel_task
  retry_task

message
  send_message
  request_information
  reply_message

goal
  create_goal
  list_goals
  update_goal
  complete_goal
```

这些工具与文件、网络、浏览器工具使用相同的 ToolDescriptor、JSON Schema、side-effect classification、permission decision、execution ticket、ToolResult 和 audit 结构。区别只在 executor 路由到 Intatis Orchestrator。

### 4. 让 `delegate_task` 成为常用的原子协调工具

弱模型如果每次都必须正确执行：

```text
spawn_agent -> 等待挂载 -> delegate_task
```

很容易出现重复 spawn、空闲 worker、挂载竞态和权限循环。

因此建议：

- `delegate_task` 优先复用合适的 idle agent。
- 没有可用 agent 时，在预算和并发上限内原子创建 worker。
- 一次完成 worker 选择、TaskContract 创建、lease 派生、assignment 和 queue。
- 返回稳定的 `taskID`、`agentID` 和状态。
- `spawn_agent` 继续保留，用于模型明确需要长期 teammate 或预热 specialist 的场景。

这不会破坏“一切都是工具调用”，而是减少模型必须自己管理的中间状态。

### 5. 每个外部 ToolCall 只做一次权限决定

正确语义应为：

```text
ToolCall
  -> Schema validation
  -> CapabilityLease / WorkspaceLease validation
  -> DeterministicPolicyGate
  -> automatic reviewer
  -> durable execution prepared
  -> executor
  -> tool result + settled
```

`spawn_agent` 获准后，executor 内部原子执行：

- agent name/path canonicalization
- roster/limit/cycle validation
- workspace/capability lease 派生
- agent spawned/attached/lease events batch append
- registry commit
- scheduler visibility

内部 `attach` 不得再调用 PermissionEngine。只有用户或模型之后发起的独立 workspace attach 才是新的受审 ToolCall。

### 6. 自动 reviewer 只返回 allow/deny

全自动模式下：

- deterministic hard deny 永远是终局。
- reviewer 只能在剩余边界内 allow 或 deny。
- timeout/cancel/malformed/provider error/persistence failure 对当前调用 fail closed，并产生可行动的结构化失败原因。
- reviewer 不进入普通 agent roster 操作面。
- reviewer context 应是紧凑 permission metadata，而不是重复注入整个 Cowork context bundle。
- exact repeated denied call 应在进入 reviewer 前快速拒绝，避免无意义消耗 provider 调用和 token。
- 自动模式不得因 reviewer 异常进入 GUI 人工等待；如保留手动模式，必须由用户显式切换，且与自动模式状态清楚分离。

### 6.1 将预算从权限硬边界中分离

预算至少分为三类，不能共用一个“耗尽即停机”的语义：

1. **安全硬边界**：workspace confinement、hard deny、并发上限、单次进程 timeout、递归/循环限制。这些不能因长任务放宽。
2. **单次调用边界**：reviewer/agent 每次 provider 请求的 timeout、最大输出和取消。这些用于限制一次失控调用，失败只影响当前调用并保留 durable 原因。
3. **长任务资源预算**：session/task token、迭代和成本额度。它们应默认为 soft budget，用于观测、上下文压缩、checkpoint 和 continuation，而不应直接关闭权限控制面。

最小闭环阶段不需要先完成复杂额度模型。建议暂时取消 reviewer 的 session-lifetime 硬 token cap，或把它改成足够高且可滚动的软计量；继续保留短小的单次审查输出上限与 timeout。普通 agent 达到 soft budget 后，应持久化进度并产生可恢复的 continuation attempt，而不是把任务伪装成 completed，也不是让 reviewer 永久失效。更精细的用户额度、不同模型成本与自动续段策略放到闭环可靠后实现。

### 7. 使用共享 EventLog，但保持 agent transcript 隔离

OpenCode/Claude Code 都强调子 agent 拥有独立上下文和 transcript。Intatis 不必改为多个物理 JSONL；可以继续使用一个 Cowork EventLog，并按以下键投影：

```text
sessionID / agentID / taskID / attempt / causalChain
```

main 默认只收到 TaskReport、显式消息和共享 artifact metadata，不吸收 worker 的全部工具日志和私有上下文。

### 8. 强化 scheduler 的可用终态

需要补齐：

- bounded worker pool，默认 2–4，硬上限继续受全局 policy 控制。
- 限制无任务的 tool-spawned idle agent 数量。
- 相同 denied management call 不无限重试。
- 连续协调失败触发 circuit breaker，使 root task 明确 failed，而不是永久 running。
- task terminal 后 composer 必须解锁。
- UI 提供 Cancel current task / recover session 的结构化入口。
- session history 由 live projection 节流刷新，不依赖一次性扫描。

### 9. Goal 必须成为真实协议对象

目前仅从 task objective 推断 Goals 不足以表达长期目标。应增加 goal tools、events 和 projection，使目标可以创建、更新、完成和恢复；Goal 仍必须通过普通工具调用进入同一权限与审计路径。

### 10. 增加模型兼容性测试

在归因 DeepSeek Flash 能力之前，先用 fake provider/request snapshot 验证：

- 首个 system message 是否正确。
- API tools 是否包含全部允许工具及严格 Schema。
- 动态工具 description 是否列出允许的 agent 类型。
- main/worker/reviewer 是否收到正确且不同的工具面。
- 模型能否完成 strict JSON tool call。
- 模型能否消费 ToolResult 后继续调用第二个工具。
- 模型能否在 deny 后停止重复相同请求。
- 模型能否在完成后给出明确终态。

再运行一个无真实副作用的 Agent Compatibility Test，区分：

```text
request construction bug
provider wire compatibility bug
model tool-calling capability不足
model multi-step planning不足
backend scheduler/permission failure
```

## EXPECTED_END_TO_END_FLOW

完成后的 Cowork 正常链路应为：

```text
New Cowork Session
  -> user selects workspace
  -> @main restricted bootstrap
  -> @permission-reviewer control-plane mount
  -> composer enabled
  -> user task becomes root TaskContract
  -> main inspects workspace with tools
  -> main calls atomic delegate_task for bounded work units
  -> scheduler creates/reuses workers
  -> workers run the same AgentRuntime with scoped context + worker leases
  -> workers call allowed tools
  -> workers return mediated TaskReports
  -> main synthesizes final result
  -> goals/tasks become terminal
  -> idle tool-spawned workers recycle
  -> root task completes or fails explicitly
  -> composer unlocks
  -> restart can replay the same durable state
```

这个闭环的 MVP 不要求一次解决无限长任务或完整成本模型，但必须保证预算不会成为隐藏死锁：soft budget 可以记录和提示；任何真正停止都必须形成 durable terminal/continuation 状态和可读原因，不能表现为 reviewer 消失、main 无限重试或 composer 永久锁定。

## IMPLEMENTATION_RESULT_2026-07-12

本报告定义的第一阶段 Cowork 最小闭环已经落到本地源码：

- Code 与 Cowork 共享 Swift-native headless `AgentRuntime`；`RuntimeEnvironmentManifest` 在首个 system message 稳定声明 Intatis mode、API tools 权威性、严格 JSON Schema 与 ToolResult 完成语义。
- request snapshot 覆盖 Code main、Cowork main/coordinator、worker 与 permission reviewer；worker/reviewer 的真实工具面继续由 lease 收窄。
- `spawn_agent` 的目标 path 进入外层 `touchedPaths`，一个 ToolCall 只做一次权限决定；executor 使用一个 durable admission batch 建立 roster/leases/attached/spawned，不再递归普通 `attach`。
- `delegate_task.to` 可省略；Orchestrator 会优先复用同 workspace idle worker，否则在 delegation budget 内原子创建 `worker-N`，并返回稳定 `task_id`、`agent_id` 与 TaskReport；如果后续 task admission 失败，本次新建 worker 会被回滚。
- 自动 reviewer 只返回 allow/deny；ask_user/ask、timeout、cancel、malformed/tool call、provider error 与 persistence failure 只 durable deny 当前调用，不转 GUI 人工等待。累计 token 默认不设 session-lifetime cap；显式阈值仅产生 soft warning。
- exact repeated denied ToolCall 只进入 reviewer 一次，随后快速拒绝，并在第三次相同尝试以结构化 terminal error 结束本轮。
- GUI 只有在 `@main` 与自动 reviewer 就绪后才开放 composer；reviewer 失败时锁定并可 Retry，运行中可 Cancel task。CLI 只有用户明确 `/default` 才进入人工审批。

验证结果：全量 SwiftPM 494 tests、14 skipped、0 failures；IntatisMac macOS Debug Xcode build 成功。Computer Use 新建 `cowork_54xwnbgl` 后，EventLog 连续持久化 `@main`（read_write）与 `@permission-reviewer`（read_only/无工具）的 leases + attach；重启后 session 出现在侧栏，页面显示 reviewer enabled / 2 agents / 0 running，composer 可编辑并成功输入未发送文本。

本轮没有复制或翻译 OpenCode 源码，因此无需新增上游 provenance/NOTICE 条目；OpenCode 继续保持 research-only。为避免未经单独授权的外部 provider 数据传输或费用，本次 GUI 未点击 Send；真实 DeepSeek/OpenRouter 多工具 E2E 仍是下一验证项，而非已知本地闭环缺陷。

## PROJECT_AUDIT_SUMMARY

本次报告与当前项目文档一致的关键点：

- Chat 是无工具 provider loop。
- Code 是单 AgentLoop/AgentRuntime 本地工作区执行面。
- Cowork 通过 Orchestrator、scheduler、MessageBus、TaskGraph 和 EventLog 编排多个 agent。
- `@permission-reviewer` 是独立控制面，不是普通 worker。
- fresh session 的 `@main` workspace bootstrap 不应被 reviewer 重审。
- 当前自动 reviewer 已移除运行时 `ask_user` fallback 语义，兼容输入会规范化为 deny；累计 token meter 只作可选 soft warning，默认不设 session-lifetime cap。
- worker 默认不能获得 coordinator 工具。
- `AgentLoop` 不得同步递归调用另一个 `AgentLoop`。
- EventLog 是 durable source of truth，UI 必须消费 projection。
- iOS 继续保持 Chat 子集，不链接 Tools/Permission/AgentKernel/Cowork。

## DOCS_CONTENT_SUMMARY

- `docs/CURRENT_STATE.md`：记录当前 v0.16 能力、Cowork 自动权限审查、fresh `@main` bootstrap、TaskReport、idle recycle、durable tool ticket 和真实验证缺口。
- `docs/PROJECT_MAP.md`：描述 11 个内核模块、App/CLI 入口、Cowork/AgentKernel/Permission/EventLog 关键文件与测试 target。
- `docs/ARCHITECTURE.md`：定义 Chat、Code、Cowork 链路、权限三层门、持久化、安全、平台边界与工具执行模型。
- `docs/DO_NOT_BREAK.md`：规定 append-only EventLog、路径/secret/权限边界、Git 限制、iOS 子集和回归要求。
- `docs/TESTING.md`：规定文档任务至少执行 `git diff --check` 与 `git status --short`；Cowork/AgentKernel 源码修改必须运行相称测试。
- `docs/NEXT_TARGET.md`：当前目标是把 Intatis 做成真实 model-backed 本地 AI workbench；Cowork 仍需真实 provider、长任务恢复与产品化验证。
- `docs/COWORK_PRINCIPLES.md`：规定 TaskContract、Scoped Context、CapabilityLease、TaskGraph/Scheduler、MessageBus、无嵌套 AgentLoop、自动 reviewer 控制面，以及开源复用不得削弱这些边界。
- `docs/OPEN_SOURCE_REUSE.md`：规定许可证准入、源码/公开 prompt 复用形式、provenance、NOTICE、Apple-first 集成与 pinned-upstream 升级流程。

## VALIDATION_RESULT

本报告创建及本次修订前均执行：

```text
pwd
git rev-parse --show-toplevel
git status --short
```

结果：路径与 Git root 均为 `/Users/vita/Vitemis/Intatis`；工作树已有多项与本次报告修订无关的未提交改动，本次未覆盖或清理。

本次修订后执行：

```text
git diff --check
git status --short
```

最初创建/修订报告时是文档任务，未运行构建或测试。随后按本报告实施第一阶段时实际运行：

```text
swift build --disable-sandbox --scratch-path /private/tmp/intatis-upgrade-build
swift test --disable-sandbox --scratch-path /private/tmp/intatis-upgrade-full-tests
xcodebuild -project Intatis.xcodeproj -scheme IntatisMac -configuration Debug -destination platform=macOS -derivedDataPath /private/tmp/intatis-upgrade-derived-data CODE_SIGNING_ALLOWED=NO build
git diff --check
git status --short
```

其中全量测试为 494 tests、14 skipped、0 failures；Xcode build 成功。macOS Seatbelt/进程组相关测试在外层受限沙箱内会因 nested `sandbox-exec` 被拒，按权限规则在 sandbox 外重跑后全部通过。

## UNCERTAINTIES

- Claude Code 主程序没有可供本报告审查的完整官方开源实现，因此 Claude 部分仅以官方公开文档为依据。
- OpenCode `dev` 分支持续变化，本报告描述的是 2026-07-12 调研时可见的实现，不应视为永久 API 契约。
- 本报告尚未为计划复用的每个 OpenCode 文件固定 commit 或完成文件头、NOTICE、传递依赖审计；在实际复制/翻译前必须完成，当前只能标为候选映射。
- fake-provider request snapshot 已证明 Intatis 构造的首个 system message、tools 与 strict Schema 符合源码意图；真实 DeepSeek Flash 的服务端接收/遵循程度仍需外部 provider E2E。
- DeepSeek Flash 的具体失败比例、复杂工具调用可靠性和多轮协调能力仍需兼容性测试，不能只凭当前 Cowork 失败归因于模型。
- 已运行真实 macOS GUI 的 session/bootstrap/sidebar/restart/main+reviewer/composer 验证；未发送外部 provider 请求，因此真实 provider 多工具链仍未验证。
- reviewer 与普通 agent 的 soft budget、checkpoint、continuation 和成本控制最终数据模型尚未确定；最小闭环只要求预算不造成权限控制面永久失效或 UI 死锁。

## NEXT_RECOMMENDED_ACTION

第一阶段的本地源码、fake-provider 闭环、全量测试、macOS 构建以及 GUI bootstrap/sidebar/composer 验证已经完成。下一步不应重复拆 Runtime 或继续扩展 Cowork 外观，而应验证真实模型链路：

1. 在用户明确同意外部数据传输与费用后，用当前 DeepSeek/OpenRouter 配置运行一个包含文件读取、自动 `delegate_task`、worker TaskReport、main synthesis 和 root terminal 的 GUI Cowork 任务。
2. 在任务运行中验证 Cancel task，并在完成或中断后重启 App，核对 EventLog projection、sidebar、roster、task terminal 与未决 tool ticket 恢复。
3. 若 request snapshot 正确而某个模型仍频繁误用工具，再针对该 model family 增加小型 prompt overlay；不要把模型能力问题重新硬编码成永久 agent 角色。
4. 需要复用 OpenCode 实现时，先固定 upstream commit，审计目标文件与传递依赖许可证，建立 provenance/NOTICE，再只移植可适配 Intatis Permission/Lease/EventLog 与 Apple-first 边界的部分。

真实 provider E2E 通过后，再设计更完整的长任务 checkpoint/continuation 与成本额度模型；这些不是当前最小闭环的阻断项。
