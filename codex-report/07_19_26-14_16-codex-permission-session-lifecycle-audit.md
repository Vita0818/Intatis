# Intatis 采用 OpenAI Codex 作为会话、权限与多 Agent 推理配置模板的源码审计报告

日期：2026-07-19

性质：只读源码调研与修正方案，不包含业务源码修改

上游基线：OpenAI Codex commit [`0fb559f0f6e231a88ac02ea002d3ecd248e2b515`](https://github.com/openai/codex/tree/0fb559f0f6e231a88ac02ea002d3ecd248e2b515)

## MODEL_CHECK_RESULT

当前执行环境为 Codex / GPT-5 系列 Agent；本地环境无法读取或独立验证更精确的服务端 deployment 标识。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 结论：当前目录与预期仓库根目录一致。

## FILES_WRITTEN

- `codex-report/07_19_26-14_16-codex-permission-session-lifecycle-audit.md`

本报告之外未修改业务源码、测试、工程配置或项目说明文档。

## SUMMARY

本轮调研的核心结论是：**Intatis 应把 OpenAI Codex 当作会话生命周期、权限审批、工具调用和取消语义的行为模板，但不应整体移植其 Rust runtime，也不应丢弃 Intatis 已经更强的持久化与 per-agent inference profile 设计。**

针对当前“历史 session 无法编辑、权限全部失败、应用表现为卡住”的问题，源码层面已经确认两个可能参与事故的高风险路径，但尚未证明事故发生时具体是哪一个 predicate 或 request 首先生效：

1. Intatis 的本地文本编辑受自动权限 reviewer、Goal recovery、主 Agent inference、live pending permission 和工作状态共同 gating；这些条件中的某些状态会直接禁用 `TextField`。
2. 自动 reviewer 在已经取得 `providerActivity` 后，如果底层 provider call timeout 或 cancel，当前实现会保留同一 session 的 activity 标记并隔离到进程重启；后续 review 会返回 `previousCallStillStopping`。排队期或 dispatch 前的 timeout/cancel 不走这条隔离路径。

但需要严格区分：

- 上述两条是已经从当前源码证实的故障路径，不等同于已经还原本次事故因果链。
- 本次实际事故究竟由哪一个 review request 首先 timeout/cancel，尚未用该 session 的运行日志精确定位，因此不能把具体首发请求写成定论。

Codex 的关键边界则非常清楚：

- 用户输入的 admission 不依赖 reviewer readiness；已有 regular turn 活跃时，新输入也可能被 steer 进当前 turn，而不是创建第二个 turn。
- reviewer 是工具越权边界上的内部子会话：Responses WebSocket 开启时可以后台预热，否则在首次审批时懒创建。
- 单次 reviewer 故障通常只 fail closed 当前 tool call；达到 rejection circuit-breaker 阈值时可以中断当前 turn，但不会把整个 session 永久隔离。
- `Decline` 只拒绝当前工具调用，模型收到失败 tool result 后可以继续；`Cancel` 中断整个当前 turn，不能伪装成普通拒绝结果。
- composer 草稿属于本地 UI 状态，审批弹层只临时覆盖显示，不销毁草稿，也不把 reviewer 健康度作为编辑前置条件。
- pending approval 使用稳定 correlation ID，先登记再发出，首个 terminal response 获胜，迟到或重复响应被忽略，turn 切换时按严格顺序清理。

在原始目标——同一 session 内不同 Agent 使用不同模型、思考强度、上游和未来不同 endpoint——上，当前 Codex 已经提供了重要的参考实现：child 可指定 model、reasoning effort、service tier；named role 可以覆盖完整 provider 配置，包括不同 provider/base URL/wire API。与此同时，Intatis 现有的 immutable `AgentInferenceBinding`、connection/profile revision、secret-free EventLog identity，以及 strict production runtime 的 reviewer 独立 binding，比 Codex 更适合该目标，应保留并继续完善，而不是退回到 Codex 的 parent-provider 继承模型。

## 1. 调研范围、方法与证据等级

### 1.1 范围

本报告只回答四类问题：

1. Codex 如何划分 session、turn、composer、reviewer 和 tool execution 的生命周期。
2. Codex 如何处理 permission approval、sandbox escalation、decline、cancel、timeout、重连和迟到响应。
3. Codex 如何在同一父 session 下为不同 child Agent 选择不同 model、reasoning、service tier、provider 与 endpoint。
4. Intatis 当前实现与这些成熟契约的差异，以及最小风险的修正顺序。

本轮没有尝试复制 Codex 产品 UI，也没有使用任何泄露或私有源码。所有外部结论均来自 OpenAI 官方公开仓库，并固定到同一个 commit。

### 1.2 证据标签

| 标签 | 含义 |
|---|---|
| 已证实 | 当前固定 commit 或 Intatis 当前工作树中存在明确源码/测试证据 |
| 推断 | 由已证实代码路径推导，但尚未由本次事故日志还原具体触发序列 |
| 建议 | 面向 Intatis 的目标设计，不代表已经实现 |

### 1.3 方法限制

- 本轮为源码审计，没有编译或运行 OpenAI Codex。
- 本轮没有运行 Intatis 的真实 provider 请求，也没有修改或重放用户历史 session。
- Codex 链接全部固定到 commit `0fb559f0f6e231a88ac02ea002d3ecd248e2b515`，后续上游行为可能变化。
- Intatis 文件行号以 2026-07-19 当前工作树为准；工作树存在既有未提交改动，本轮没有覆盖或清理它们。

## 2. 总体架构判断：采用行为契约，不移植整套 runtime

推荐把 Codex 当作以下状态机的参考：

```text
local draft editing
  → user submits message
  → main turn starts
  → model requests tool
  → deterministic policy gate
  → optional reviewer / user approval
  → sandboxed execution
  → tool result returns to the same turn
  → turn completes or is explicitly cancelled
```

这里最重要的不是 Rust 类型或某个具体函数，而是各层之间的独立性：

- 本地 draft 不依赖网络、provider、reviewer 或 runtime。
- 普通模型请求不依赖权限 reviewer。
- reviewer 只在工具调用进入 ask/approval 边界时被需要。
- 一次工具审批失败不应把整个会话永久变成不可用。
- permission outcome、tool execution outcome 与 turn cancellation 是不同事件，不能压成同一个布尔值。

Intatis 不适合整体搬运 Codex runtime，原因包括：

- Intatis 是 Apple-first、Swift-native 多 target 工程。
- Intatis 已经有 append-only EventLog、durable permission requested/settled、durable tool prepare/settle、CapabilityLease、WorkspaceLease、PathConfinement、SecretScanner 和 Mediator 等更严格边界。
- Codex 的部分 approval 协调使用进程内 map/oneshot；这可以参考相关性和清理顺序，但不能替代 Intatis 的持久化语义。
- Intatis 的 per-agent inference identity 已经按 immutable revision 设计，适合恢复、审计和未来多 endpoint；直接换成 Codex 当前的 live config overlay 会倒退。

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

结合 3.1 的输入 admission 路径和 3.3 的 Guardian 按需创建逻辑，可以得出：Guardian prewarm 是首个审批的延迟优化，不应成为 session attach、历史消息展示、composer 编辑或普通输入 admission 的硬门。

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

Intatis 当前并非只有一个模糊状态：`PermissionApprovalSource`、`PermissionApprovalFailureKind`、`PermissionReviewStatus` 和 `ToolExecutionOutcome` 已经区分 reviewer timeout/cancel/provider failure/still stopping、持久化失败，以及 execution failed/cancelled/denied。真实缺口主要是 user decline 与 turn cancel 的协议拆分，以及 sandbox denial 与普通 runtime/setup failure 的进一步细分。

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
5. 在同一个仍存活的 app-server 进程中，只要 callback map 尚在且 thread 仍 loaded/running，客户端断线不会立即丢弃 pending callback，重新 attach/resume 可以重放同一 request。Codex 这里不保证进程重启、cold resume 或 durable recovery。

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

## 9. Intatis 当前已经做对的部分

### 9.1 per-agent inference identity

Intatis 已有的设计比 Codex live config overlay 更适合持久化与审计：

- `Packages/IntatisProtocol/Sources/InferenceProfile.swift:4-54`：`AgentInferenceBinding` 是 durable、secret-free 的精确 identity，包含 profile/connection revision、model、variant、安全 route metadata 和 immutable fingerprint。
- `Packages/IntatisProviders/Sources/InferenceCatalog.swift:6-120`：connection 与 profile 都按 immutable revision 建模，endpoint、wire adapter、credential reference、trust 和 arbitrary request options 都能进入精确解析。
- `Packages/IntatisAgentKernel/Sources/Agent.swift:9-38`：每个 Agent 持有自己的 binding。
- `Packages/IntatisProtocol/Sources/Task.swift:82-135`：task contract 在 admission 时冻结 binding，避免执行途中静默切换上游。
- `Packages/IntatisCowork/Sources/Orchestrator.swift:5141-5239`：运行时核对 task binding 与 live agent binding，按 Agent 解析 provider，并保持 capability/workspace lease 与 inference profile 独立。

这套结构已经能表达：

- 同一 model，不同 reasoning/thinking 参数；
- 不同 model；
- 同 provider，不同 connection revision；
- 不同 provider、base URL、chat endpoint 或 wire adapter；
- 将来不同 API surface、credential reference、trust domain 与 egress classification。

### 9.2 reviewer 的独立安全身份

`Packages/IntatisCowork/Sources/Orchestrator.swift:1361-1455` 为保留 reviewer 设置 read-only workspace、空 tool/communication/delegation lease；当 `requiresInferenceBindings == true` 时还强制精确 inference binding。兼容/测试构造仍允许 `nil`，因此“精确 binding”是 strict production runtime 的保证，而不是所有 initializer 的静态不变量。这仍比让 reviewer 隐式继承普通 coordinator 能力安全，也比 Codex 当前“父 provider + review model override”更灵活。

### 9.3 durable permission/tool lifecycle

Intatis 的 permission review request/settled、tool execution prepare/settle 和 EventLog replay 是需要保留的产品资产。Codex 的内存 waiter/map 只应提供状态机参考，不应替代这些 durable 契约。

## 10. Intatis 当前故障的结构性原因

### 10.1 本地编辑被错误绑定到远端/控制面 readiness

当前代码有多层硬绑定：

- `Apps/IntatisMac/Sources/CoworkViewModel.swift:255-287`：`start()` 立即把 reviewer 置为 enabling；runtime 启动失败同时把 reviewer 标成 failed。
- `Apps/IntatisMac/Sources/CoworkViewModel.swift:316-337`：历史 session restore 先执行 `ensureAutomaticPermissionReview`，再 bootstrap/恢复主 Agent，随后才尝试恢复数据面。
- `Apps/IntatisMac/Sources/CoworkViewModel.swift:729-742`：`resumeRuntimeIfReady()` 以 reviewer ready 为第一道 guard。
- `Apps/IntatisMac/Sources/CoworkViewModel.swift:985-994`：`send()` 硬要求 reviewer ready 和 Goal runtime ready。
- `Apps/IntatisMac/Sources/IntatisMacApp.swift:571-573`：`isComposerAvailable` 同时要求 reviewer、Goal 和 main inference ready。
- `Packages/IntatisSharedUI/Sources/CoworkViews.swift:539-542`、`:1660-1679`：pending permission、working、composer availability 和 main Agent 状态都会直接设置 `isInputDisabled`。

因此当前实际公式是：`isWorking || !isComposerAvailable || permissionBlocksComposer || !hasMainAgent` 时禁用输入；而 `isComposerAvailable` 又要求 reviewer ready、Goal ready 和 main inference ready。这里还有两个重要限定：`.degraded` reviewer 仍被 `isAutomaticPermissionReviewReady` 视为 ready，且只有 `.livePending`/`.resolving` permission 会触发 `permissionBlocksComposer`，历史 `.needsRerun` 本身不会阻塞输入。

这套 gating **能够直接产生**用户观察到的“历史 session 输入框不可点击”，但本轮没有从事故现场状态证明当时究竟是 reviewer `.enabling/.failed`、Goal、main inference、`isWorking`、live pending permission 还是缺失 main Agent 触发了禁用。

正确边界应是：

| 能力 | 依赖项 | 不应依赖 |
|---|---|---|
| `canEditDraft` | session view 与本地 UI state | reviewer、provider、Goal、main Agent、pending permission、网络 |
| `canDispatchMessage` | main binding/provider/runtime；必要时 Goal recovery | reviewer 是否预热、是否存在另一条 tool approval |
| `canExecuteTool(callID)` | 当前 call 的 policy、review、lease、sandbox、durable ticket | 其他 session 的 reviewer 健康度 |
| `permissionReviewAvailability` | reviewer/control-plane health | 不应作为 composer enablement gate |

### 10.2 provider call 内的 timeout/cancel 会升级成 session/process 级 reviewer 隔离

`Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:702-785` 的 `runProvider` 先调用共享 `providerActivity.tryBegin()`。如果已有 activity，直接返回 `previousCallStillStopping`。只有已经进入 `runProvider` 并成功取得该 activity 后发生的 provider timeout/cancel 才会留下这一标记；排队超时、dispatch 前超时或提前取消不会触发该隔离。

当 provider result 为正常 output/failed 时，`providerActivity.end()` 会被调用；但 cancellation 的代码注释明确认为消费者 task 结束不能证明实现方 producer 已停止，因此不会清除 activity。timeout/cancel 后 health state 会写明：

- 当前 session 的 automatic review 被 quarantined；
- 需要 restart Intatis 才能恢复；
- 后续调用会收到 previous call still stopping。

`PermissionReviewProviderActivityRegistry` 又按 coordination key 跨 control-plane 生命周期共享 activity；关闭/重新开启 reviewer 或重开 Cowork view 都不会重置，进程重启才是恢复边界。证据位于同一文件 `:1437-1485`。

这套防重叠设计的安全动机是合理的：不能让一个无法确认停止的旧 provider stream 与新审批并发。但它把“一次无法证明停止”升级成了“同一 session 在整个进程生命周期永久失去自动审批”，可用性范围过大。

**推断**：这条路径与用户看到的“后续权限全部失败”高度一致；但 `.degraded` reviewer 在 ViewModel 中仍算 ready，因此 quarantine 本身不能单独证明输入框为何被锁，必须再有 10.1 中其他 gating predicate 生效。

**尚未证实**：本次具体事故的第一个 timeout/cancel request ID、provider stream 是否真的忽略 cancellation，以及发生时间，仍需以后从 EventLog/运行日志精确还原。

### 10.3 移除 overlap guard 前必须证明跨 generation 隔离

当前每次 `runProvider` 已有独立 race；同一 race terminal result 确定后，迟到 output 会被忽略。因此，本节不是在断言当前源码已经发生 verdict 错配或重复 settle。

但也不能为了恢复可用性直接删除 `providerActivity` 或 quarantine 并允许无法证明停止的旧 producer 与新 review 共用 transport/state。若新实现没有跨 generation 相关性和 terminal guard，理论上可能出现：

- 旧 verdict 错配到新 call；
- late allow 修改已经终止的 request；
- 同一 tool execution 被重复 settle；
- cancel 后仍执行工具。

这些是修改并发模型时的设计风险假设，不是本次事故的已证实后果。正确替代方案仍应提供 request-scoped generation、独立 transport/producer ownership、terminal state 幂等、迟到结果丢弃和执行前再次核验。

## 11. 采用、保留与明确不复制的内容

| 类别 | 决策 | 说明 |
|---|---|---|
| turn 不依赖 reviewer readiness | 采用 | 普通输入、历史 session attach 与主推理链路不等待 reviewer |
| reviewer lazy start / optional prewarm | 采用 | 只在真实 permission ask 时成为硬依赖 |
| reviewer failure call-scoped | 采用 | 单次 timeout/failure durable deny 当前 call；明确 model deny 达 breaker 阈值时才中断当前 turn |
| Decline 与 Cancel 分离 | 采用 | 分别对应 call continuation 与 turn interruption |
| approval correlation、首响应获胜、迟到忽略 | 采用 | 但落在 Intatis EventLog/durable state 上 |
| composer 草稿独立 | 采用 | reviewer/pending permission 不能禁用本地输入 |
| sandbox denial 最多一次受控 retry | 采用其状态机 | 保留 Intatis 自己的三层权限门与 sandbox backend |
| immutable per-agent inference binding | 保留 Intatis | 比 Codex live config overlay 更适合恢复与多 endpoint |
| reviewer 独立 inference binding | 保留 Intatis strict runtime | 比 Codex parent-provider 继承更一般；兼容/测试构造可为 nil |
| durable request/settled 与 prepare/settle | 保留 Intatis | 不换成进程内 oneshot/map |
| shared Cowork EventLog | 保留 Intatis | 不改成 Codex child thread tree |
| tool-enabled Guardian | 暂不复制 | 当前 no-tools reviewer 更符合项目安全原则 |
| `ToolError::Rejected` 混合分类 | 不复制 | Codex 源码已有 TODO；Intatis 应从一开始拆分原因 |
| TUI overlay LIFO 不一致 | 不复制 | Intatis 保持全链路 FIFO |
| reviewer 只能继承父 provider | 不复制 | 会削弱 Intatis 的独立控制面路由能力 |
| role/profile 携带 capability/permission | 禁止 | inference 与 security lease 必须正交 |

Codex 当前把用户 decline 与部分 runtime/setup rejection 都汇入 `ToolError::Rejected`，可能导致 UI 把非用户故障显示成 `Declined`；源码已有拆分 TODO。Intatis 已有较细的 reviewer/execution failure 类型，应保留这些区分，并继续补齐 user decline、turn cancel、sandbox 与 runtime/setup failure，而不是重新压平。

证据：[`tools/events.rs#L405-L430`](https://github.com/openai/codex/blob/0fb559f0f6e231a88ac02ea002d3ecd248e2b515/codex-rs/core/src/tools/events.rs#L405-L430)

## 12. 推荐目标状态

### 12.1 session restore

推荐顺序：

```text
open session
  → replay EventLog and render history
  → create local draft/composer state and enable editing immediately
  → concurrently recover main binding, Goal state, runtime, reviewer metadata
  → allow Send when main/Goal admission requirements are satisfied
  → start/resolve reviewer only when a tool reaches permission ask
```

恢复失败应表现为局部 banner：

- main inference unresolved：可以编辑，Send 禁用或排队，显示明确原因。
- Goal recovery pending：可以编辑，Send 可暂存或禁用，显示恢复状态。
- reviewer failed：可以编辑，也可发送普通消息；只有遇到需审批工具时 fail closed 当前 call。
- pending permission：可以继续编辑草稿；是否允许并行发送新 turn 由产品并发策略决定，但不应让文本框失焦或不可用。

### 12.2 reviewer request isolation

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

### 12.3 inference profile admission

继续使用宿主批准的 immutable `inference_profile_id`：

- spawn 时只接受 profile ID 或继承父 binding；
- profile resolution 可以得到 model、reasoning/thinking、service tier、provider、base URL、endpoint、wire format 和非秘密 options；
- credential 仍按 reference 懒加载，不进入 tool schema、prompt 或 EventLog；
- role 可以选择 inference profile，但不能携带或覆盖 PermissionProfile、CapabilityLease、WorkspaceLease；
- task admission 冻结 exact binding；恢复时必须按 immutable revision/fingerprint 重新验证。

## 13. 分阶段实施计划

### Phase A：composer 与 session liveness

这是最小、最紧急的修复面。

1. 新增或明确 `canEditDraft`，只由本地 view 生命周期决定。
2. 将 `IntatisThreadComposer.isInputDisabled` 与 reviewer、Goal、main inference、pending permission、`isWorking` 解耦。
3. 单独计算 `canDispatchMessage`，只影响 Send button/submit action。
4. 历史 session replay 完成后立即可浏览和编辑；控制面恢复并行进行。
5. reviewer/Goal/main inference failure 以 banner 或 accessory 状态显示，不清空草稿。

验收标准：任意历史 session 即使 reviewer failed、Goal recovering、main binding unresolved 或存在 pending permission，输入框仍可聚焦、编辑和保存草稿。

### Phase B：reviewer request isolation 与可恢复性

1. reviewer 从 session startup 硬门改为 permission ask 时 lazy resolve/start；prewarm 只作优化。
2. 用 request-scoped generation 和 terminal-state guard 替代 process-lifetime session quarantine。
3. 为无法证明停止的 provider producer 提供隔离 transport 或明确 detach/retire 机制。
4. timeout/failure 只 settle 当前 review；未来 call/turn 能创建 fresh reviewer context。
5. late/duplicate output 按 review ID/generation 丢弃，不能触发 allow 或 tool execution。

### Phase C：生命周期与错误语义

1. 建立 `Decline → call denied/turn continues` 与 `Cancel → turn interrupted` 的显式协议。
2. 拆分 user denial、policy denial、reviewer timeout/failure、sandbox denial、runtime failure 和 turn cancel。
3. pending request 先 durable register 再 publish；首 terminal response 原子获胜。
4. turn abort 先 cancel/await execution，再 settle/清理 approval waiters。
5. reconnect/resume 重放同一个 pending review identity；remote resolution 幂等。
6. 全部审批队列使用 FIFO。

### Phase D：per-agent inference 与回归测试收口

1. 验证同一 session 下相同 model、不同 reasoning effort。
2. 验证不同 Agent 使用不同 provider/base URL/chat endpoint。
3. 验证 full-history fork 在保留上下文时可选择不同 model/reasoning profile。
4. 验证 role/profile 无权修改 permission/capability/workspace lease。
5. 修订旧研究报告中已过时的 full-history fork 结论，并保留旧/新 commit 差异。

## 14. 必须建立的测试契约

### 14.1 composer 与恢复

- 历史 session + reviewer failed：输入可编辑，草稿不丢。
- main inference unresolved：输入可编辑，Send 不可用并显示准确原因。
- Goal recovering：输入可编辑；恢复完成后同一草稿可发送。
- pending permission：输入可编辑，审批解决前后草稿字节级一致。
- session 切换/返回：各 session 草稿按产品定义独立恢复。

### 14.2 permission 与 turn

- reviewer timeout：只 durable deny 当前 call；下一 turn/session action 仍可继续。
- reviewer provider failure：不得把整个 session 标成永久不可用。
- Decline：同一 `call_id` 产生 `success=false` tool result，模型可继续并完成 turn。
- Cancel：turn 进入 interrupted，不向模型注入伪造的“用户拒绝”tool result。
- late/duplicate approval：不执行工具，不改变 terminal state。
- reconnect：重放完全相同的 pending review identity/payload。
- interrupt cleanup：execution task 先停，approval waiter 后释放；事件顺序稳定。
- runtime/setup failure：UI 永远不能显示成 user declined。
- 多审批：FIFO；remote resolution 可删除任意项而不改变剩余顺序。

### 14.3 sandbox 与 durable execution

- 普通 exit-nonzero 不触发 escalation retry。
- 明确或启发式分类为 sandbox denial 的失败最多 retry 一次，并单测防止普通非零退出误入 retry。
- retry 仍经过 deterministic gate 与 lease 校验；若 Intatis 选择每次都重新 reviewer，须把它作为比 Codex 更严格的显式契约测试。
- denied-read 不得通过无 sandbox retry 绕过。
- allow 只有 durable settled 成功后才能驱动 execution。
- cancel/timeout 后任何 late allow 都不能使工具执行。

### 14.4 per-agent inference profile

- same provider/model + different reasoning/options。
- different model + same provider。
- different provider/base URL/wire adapter。
- profile revision/fingerprint 不匹配时 fail closed。
- task frozen binding 与 live agent binding 不一致时拒绝 admission/execution。
- credential 不进入 EventLog、prompt、tool schema 或错误文本。
- inference role/profile 无法改变 capability、permission 和 workspace lease。

## 15. 风险与不确定性

### 已知风险

- 将 composer 解锁后，如果 Send 的 gating 没有同步拆分，可能出现 UI 看似可发送但 submit 被静默 guard；必须提供准确状态文案。
- 移除 process-lifetime reviewer quarantine 而没有证明跨 generation/transport isolation，会引入迟到 allow 或重复执行的设计风险；这不是对当前代码已发生该故障的断言。
- 如果 reviewer lazy start 仍共享不可取消的底层 provider stream，单纯重建 actor/control plane 不足以实现隔离。
- 旧 EventLog 兼容性必须保留，新增 outcome taxonomy 应通过可选字段或兼容事件演进完成。
- 多 Agent endpoint/profile 不能把任意 URL 或 secret 直接开放给模型；必须继续通过宿主批准、版本化 catalog 解析。

### 尚未确认

- 本次用户实际卡死 session 的首个 reviewer timeout/cancel 对应 request ID、turn ID 和 provider。
- 当前 provider adapter 中哪些实现能证明 cancellation 后 producer 已终止，哪些不能。
- composer draft 当前是否已有跨 session 持久化机制；如果没有，Phase A 需要明确只保证 view 生命周期，还是增加 durable draft。
- concurrent turn 与 pending approval 是否是产品允许的行为；无论最终策略如何，本地编辑都应独立。

## VALIDATION_RESULT

已执行：

- `git diff --check`：通过，无 whitespace error。
- 针对本报告的 Markdown 标题、必需字段与行尾空白检查：通过。
- `git status --short -- codex-report/07_19_26-14_16-codex-permission-session-lifecycle-audit.md`：显示该报告为本轮新增、未暂存文件，符合预期。

本轮未运行构建或测试，因为任务范围仅为只读调研报告，没有修改业务源码、测试或工程配置。

## UNCERTAINTIES

最重要的不确定性是事故的具体首发日志。报告已经确认代码中存在“provider call 内 timeout/cancel 后的 session/process 级 reviewer quarantine”路径与 composer 多条件 gating，但没有把尚未读取到的 runtime request ID、当时实际 gating predicate、provider cancellation 行为或时间线冒充为已证实事实。

旧报告在旧 commit 上的历史准确性本轮也未重新验证；这里只能确定其 full-history fork 结论不适用于当前审计 commit。

## NEXT_RECOMMENDED_ACTION

下一步建议只实施 **Phase A：composer 与 session liveness**，并配套最小 UI/ViewModel 单元测试；不要同时重写整个权限系统。Phase A 完成且真实历史 session 验证通过后，再进入 Phase B 的 reviewer request isolation。

在开始 Phase B 前，应先从实际故障 session 的 EventLog/运行日志还原第一个 reviewer timeout/cancel，确认具体 provider adapter 的 cancellation 行为。这样可以决定需要 request generation guard、独立 transport，还是 provider adapter 级 producer termination 修复，避免用猜测替换现有安全隔离。
