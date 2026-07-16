# Intatis Cowork 自动权限审查：Codex 与成熟开源实现源码审计

## MODEL_CHECK_RESULT

当前模型：GPT-5 系列 Codex；具体内部变体无法确认。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者一致，符合预期仓库根目录。
- 开始调研前工作区已有对话渲染、工程配置、NOTICE、项目文档等未提交改动；本报告没有覆盖、回退或整理这些既有改动。

## FILES_WRITTEN

- 新增本报告：`codex-report/07_15_26-21_19-auto-permission-review-oss-audit.md`
- 未修改业务源码、测试、构建配置、`NOTICE.md` 或 `docs/` 项目状态文档。

## 1. 结论先行

前一版 Intatis 方案只学到了“独立权限审查者”的外形，没有学到成熟实现最关键的权限事实分层。

本次源码审计后的核心结论是：

> 审查模型不应判断“某个具体工具是否属于 agent 的 CapabilityLease”。工具存在性、别名归一、工具到 capability 的映射、lease membership、WorkspaceLease、路径边界和 hard deny 都必须由宿主运行时确定性完成。模型审查者只判断一项已经被宿主解析清楚的具体动作，是否符合用户授权、任务意图和语义风险边界。

因此，“审查者应该和主管处于同一级别并拥有完全相同的上下文”不是 Codex 的实现方式，也不是本次故障的正确修复方向。Codex 的 Guardian 刻意拥有更窄的上下文和更少的能力；它与主管共享的是同一份宿主确认过的准确动作事实，而不是完整 transcript，也不是两套可能漂移的字符串工具清单。

Intatis 最近一次误拒绝的本质是：

```text
CapabilityLease 中的抽象能力：apply_patch
宿主根据该能力实际暴露的具体工具：write_file、apply_patch
reviewer 收到的本次工具名：write_file
reviewer 同时看到的原始 capability 字符串：apply_patch
reviewer 被要求拒绝 lease-inconsistent 请求
结果：模型把两个层级的名称误判为不一致并拒绝
```

这不是 reviewer 缺少主管的完整上下文，而是宿主把本应已经确定的授权映射重新交给模型推理。

## 2. 调研范围与固定版本

本报告只使用公开官方文档和公开仓库源码，没有使用私有 prompt、泄露材料、反编译内容或第三方品牌资产。调研基线固定如下：

| 项目 | 固定版本 | 本次关注点 |
|---|---|---|
| OpenAI Codex | [`1bbdb32789e1f79932df44941236ea3658f6e965`](https://github.com/openai/codex/commit/1bbdb32789e1f79932df44941236ea3658f6e965) | Guardian auto-review、ToolRuntime、ApprovalAction、沙箱边界、理由回传 |
| OpenCode | [`04bdf7732bae0cbb2ab3e003d65bddb8d56edacf`](https://github.com/anomalyco/opencode/commit/04bdf7732bae0cbb2ab3e003d65bddb8d56edacf) | 确定性 `allow/ask/deny`、canonical permission、`--auto` |
| Cline | [`50d1578a7ea3a9004319a81993c9ffe48cc4dd2d`](https://github.com/cline/cline/commit/50d1578a7ea3a9004319a81993c9ffe48cc4dd2d) | 单一 Tool Map、policy 与 executor 的同源工具身份 |
| Goose | [`9aa03bff206b234827fe63eb5937457c3c1cb5a4`](https://github.com/aaif-goose/goose/commit/9aa03bff206b234827fe63eb5937457c3c1cb5a4) | `SmartApprove` 的窄职责、规则优先、LLM 失败降级 |

当前工作只是 `reference` 研究，没有复制、翻译、vendor 或依赖任何上游源码。若后续实际复制或逐行翻译，必须重新完成文件级许可证、NOTICE、传递依赖和 provenance 审查，并按 `docs/OPEN_SOURCE_REUSE.md` 更新 `NOTICE.md`。

## 3. Codex 的真实自动权限审查

### 3.1 Auto-review 不会授予或扩张权限

Codex 官方文档把 auto-review 定义为沙箱边界上的自动审查者：它替代原本需要用户手动判断的 boundary request，但不授予新权限，也不扩大当前 sandbox。已经在沙箱内允许的普通动作不会进入 Guardian。[Codex Auto-review 文档](https://learn.chatgpt.com/codex/sandboxing/auto-review) 和 [OpenAI Alignment 说明](https://alignment.openai.com/auto-review/) 都明确了这一边界。

这意味着 Codex 的顺序不是：

```text
模型提出工具名 -> Guardian 猜它是否有这个工具 -> 执行
```

而是：

```text
模型提出工具调用
  -> 宿主查找真实 ToolRuntime
  -> 宿主完成策略、沙箱和资源预检
  -> 宿主确认这是一项需要边界审批的准确动作
  -> 构造强类型 ApprovalAction
  -> Guardian 判断用户授权与语义风险
  -> 宿主执行或拒绝
```

### 3.2 ToolSpec、运行时和执行器来自同一事实源

Codex 的 `ToolRouter` 同时持有 model-visible specs 和 host registry；tool spec 与 handler 在同一构造过程注册，模型不能看到一套工具、执行器再使用另一套手工映射。[`router.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/tools/router.rs#L35-L77) 和 [`spec_plan.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/tools/spec_plan.rs#L155-L196) 展示了这个同源关系。未注册工具由宿主直接拒绝，不会送给 Guardian 猜测。

这正是 Intatis 应吸收的第一个原则：具体工具身份、模型 schema、permission adapter 和 executor 不能分别维护。

### 3.3 宿主先构造强类型的准确动作

Codex 给 Guardian 的不是模糊 capability 名称，而是强类型审批动作。当前源码分别表达：

- Shell/Exec：命令、工作目录、sandbox 和额外权限、理由、TTY；
- ApplyPatch：工作目录、准确文件集合和 patch；
- Network：host、protocol、port、触发来源；
- MCP：准确 server/tool、arguments、annotations、account；
- RequestPermissions：所请求的权限 profile。

这些结构见 [`approval_request.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/guardian/approval_request.rs#L16-L78)。同一个 `ToolRuntime` 先执行 approval hooks，再产生该工具的 `approval_action`；Guardian 不重新推断工具属于哪个 runtime。[`approvals.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/tools/approvals.rs#L180-L289)

### 3.4 Guardian 是更窄的控制面，不是主管副本

Guardian 使用单独的 review session，默认 read-only、`approval never`，并关闭 MCP、skills/memory、apps/plugins、web、collaboration、多 agent 和 hooks 等大部分能力。[`review_session.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/guardian/review_session.rs#L788-L830)

它收到的是压缩后的相关 transcript 加当前准确 action，而不是主管的完整上下文和完整工具面。[`prompt.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/guardian/prompt.rs#L83-L121)

所以正确的不变量是：

```text
主管与 reviewer 的对话上下文可以不同；
主管与 reviewer 对“当前动作是什么、宿主已经确认了什么”的事实必须相同。
```

### 3.5 Guardian 判断的是风险和授权，不是 capability membership

Guardian 只会在宿主已经识别出 boundary-crossing action 后介入。它考虑用户意图、环境、安全性、影响范围和必要性；它不能放行 deterministic hard deny，也不能扩大 sandbox。

Codex 没有让 Guardian通过类似下面的规则判断能力：

```text
requested tool = write_file
capability strings = [apply_patch]
请模型判断这两个名字是否代表同一授权
```

这种映射属于宿主 ToolRuntime，而不是语义审查。

### 3.6 拒绝理由被保留并反馈给主管

Codex 会把 Guardian rationale 记录为结构化 assessment，并把具体拒绝原因返回主 agent；拒绝文本还明确要求不要通过改写同一动作来规避审查。[`review.rs`](https://github.com/openai/codex/blob/1bbdb32789e1f79932df44941236ea3658f6e965/codex-rs/core/src/guardian/review.rs#L51-L94)

官方实现还包含连续拒绝/近期拒绝 circuit breaker 和准确动作的后续用户 override 路径。超时、明确拒绝和 circuit breaker 不是同一个模糊的 `permission denied` 状态。

## 4. OpenCode：完全确定性的权限规则

OpenCode 当前没有额外 LLM 权限审查者。它使用宿主规则产生 `allow`、`ask` 或 `deny`：最后一条匹配规则决定结果，默认是 `ask`。[`permission/index.ts`](https://github.com/anomalyco/opencode/blob/04bdf7732bae0cbb2ab3e003d65bddb8d56edacf/packages/opencode/src/permission/index.ts#L28-L38)

值得借鉴的点：

1. 宿主用 canonical `edit` permission 覆盖具体 edit/write/apply-patch 工具，不要求审批者根据名称猜映射；完全被拒绝的工具可直接从模型工具面移除。[`permission/index.ts`](https://github.com/anomalyco/opencode/blob/04bdf7732bae0cbb2ab3e003d65bddb8d56edacf/packages/opencode/src/permission/index.ts#L204-L220)
2. `apply_patch` 会先解析实际 patch、文件路径和元数据，再产生 permission request，获准后才执行。[`apply_patch.ts`](https://github.com/anomalyco/opencode/blob/04bdf7732bae0cbb2ab3e003d65bddb8d56edacf/packages/opencode/src/tool/apply_patch.ts#L193-L248)
3. `--auto` 只自动回答原本会进入 `ask` 的请求；显式 `deny` 在事件产生前已经终局，auto 不能覆盖。[权限文档](https://dev.opencode.ai/docs/permissions/)

不应照搬的部分：OpenCode 的 permission policy 不是 Intatis 的 OS sandbox、WorkspaceLease 和 durable execution ticket；个别旧版 rule/memory 的 last-match 行为也可能让后续 allow 覆盖前面的 deny。Intatis 应保留 hard-deny-first 和现有平台安全边界。

## 5. Cline：工具身份的单一事实源

Cline 最值得借鉴的是 RuntimeBuilder 和 AgentRuntime 的同源工具模型：

- RuntimeBuilder 生成实际 `AgentTool[]`，先确定性归一别名，再按准确工具名过滤。[`runtime-builder.ts`](https://github.com/cline/cline/blob/50d1578a7ea3a9004319a81993c9ffe48cc4dd2d/sdk/packages/core/src/runtime/orchestration/runtime-builder.ts#L56-L145)
- 同一份 `Map<toolName, AgentTool>` 同时用于模型 tools schema、policy 查询和执行器查找。[`agent-runtime.ts`](https://github.com/cline/cline/blob/50d1578a7ea3a9004319a81993c9ffe48cc4dd2d/sdk/packages/agents/src/agent-runtime.ts#L501-L516)
- Auto-approve 按准确工具名、类别、MCP 设置和用户配置确定性判断，不调用第二个 LLM。[`sdk-tool-policies.ts`](https://github.com/cline/cline/blob/50d1578a7ea3a9004319a81993c9ffe48cc4dd2d/apps/vscode/src/sdk/sdk-tool-policies.ts#L13-L100)
- 未知工具、缺少 callback、异常和失败路径都 fail closed，并把具体原因返回调用链。

不应照搬的部分：Cline 某些 SDK policy 对未列出的工具采用较宽松默认值。Intatis 的 unknown/unmapped capability 必须保持 ask 或 deny，不得 default auto-approve。

## 6. Goose：LLM 审查必须保持窄职责

Goose 确实存在额外 LLM `SmartApprove`，但其职责比 Intatis 当前 reviewer 窄得多：

1. 用户的准确工具规则优先；
2. 工具 annotation 和已有只读缓存其次；
3. 强制人工审批规则再次收紧；
4. 只有未知、未标注的工具才交给 LLM 判断它是否严格只读。

宿主的优先顺序见 [`permission_inspector.rs`](https://github.com/aaif-goose/goose/blob/9aa03bff206b234827fe63eb5937457c3c1cb5a4/crates/goose/src/permission/permission_inspector.rs#L130-L216)。多个 inspector 组合时只能收紧，不能由后面的判断放宽前面的拒绝。[`tool_inspection.rs`](https://github.com/aaif-goose/goose/blob/9aa03bff206b234827fe63eb5937457c3c1cb5a4/crates/goose/src/tool_inspection.rs#L213-L252)

Goose 的反例同样重要：当前 judge prompt 声称会考虑参数，但实际实现主要传工具名，并按工具名缓存判断。[`permission_judge.rs`](https://github.com/aaif-goose/goose/blob/9aa03bff206b234827fe63eb5937457c3c1cb5a4/crates/goose/src/permission/permission_judge.rs#L89-L115) Intatis 不应复制这种“按工具名缓存语义安全性”的做法，因为同一个工具对不同路径、命令、diff、network target 的风险可能完全不同。

## 7. 四个项目的共同规律

| 维度 | Codex | OpenCode | Cline | Goose | 对 Intatis 的含义 |
|---|---|---|---|---|---|
| 工具是否存在 | 宿主 registry | 宿主 registry | 单一 Tool Map | 宿主 Tool collection | reviewer 不参与 |
| 工具到权限映射 | ToolRuntime/强类型 action | canonical permission | tool/category policy | exact rule/annotation | 必须确定性完成 |
| hard deny | Guardian 前终局 | auto 前终局 | policy 前置 | inspector 只能收紧 | 模型不能覆盖 |
| LLM reviewer | 只审边界动作 | 无 | 无 | 只判未知工具是否只读 | 职责必须窄 |
| reviewer 上下文 | 精简 transcript + exact action | 不适用 | 不适用 | 窄 tool facts | 无需复制主管完整上下文 |
| 参数/资源 | 命令、路径、patch、网络目标等准确事实 | preflight 后 ask | 由实际 Tool 实例处理 | 当前实现偏弱 | Intatis 必须按具体调用审查 |
| 失败处理 | fail closed，理由保真 | deny/ask 明确 | fail closed | LLM 失败回退更严格路径 | 状态与理由不可丢失 |

共同规律可以压缩成一句话：

> 宿主负责事实和权限边界，模型最多负责语义判断；模型不能成为工具注册表、capability resolver 或路径授权器。

## 8. Intatis 当前已经做对的部分

以下设计不应因本次问题被推翻：

- `DeterministicPolicyGate` 在模型前运行，hard deny 终局；
- `PermissionReviewControlPlane` 与普通 scheduler 分离，不运行嵌套 `AgentLoop`；
- reviewer 固定 read-only、空 capability、只返回 allow/deny；
- request/settled durable-first，allow 只有 settled 成功后生效；
- timeout、cancel、malformed、provider 和 persistence failure fail closed；
- WorkspaceLease、root identity、PathConfinement 和 durable tool execution ticket 在 reviewer 之外继续约束执行；
- exact repeated denied ToolCall 已有 circuit breaker；
- `PermissionIntent.defaultAction` 已经把 `write_file` 与 `apply_patch` 部分归一为 `filesystem.edit`。

最后一点说明当前代码已经出现 canonical action 的雏形，但它还不是完整的授权绑定：review task 仍同时暴露 `tool=write_file` 和原始 `capability_lease=[apply_patch]`，system prompt 仍要求 reviewer 拒绝 `lease-inconsistent` 请求。模型仍可能重新解释这两个名称的关系。

## 9. Intatis 当前真正的问题

### 9.1 Capability 名称和具体 Tool 名称处于不同抽象层

当前 `ToolCapability.applyPatch` 不是单个具体工具。`Orchestrator.toolRegistry(for:)` 在该 capability 存在时同时注册：

```swift
WriteFileTool()
ApplyPatchTool()
```

因此 `write_file` 出现在模型工具面，本身已经是宿主成功解析 `.applyPatch` lease 的结果。reviewer 再根据原始字符串 `apply_patch` 判断 `write_file` 是否获授权，是重复且不可靠的二次授权判断。

### 9.2 reviewer 收到的是两套事实表示，没有收到宿主结论

当前 `PermissionReviewTask` 包含 concrete tool、`PermissionIntent`、CapabilityLease 和 WorkspaceLease；但缺少一个不可歧义的宿主结论，例如：

```text
tool_registry_lookup = found
concrete_tool_id = filesystem.write_file.v1
canonical_capability = filesystem.edit
capability_membership = allowed
membership_source = <lease id/version>
```

在没有这些事实时，prompt 用 `lease-inconsistent` 作为拒绝条件，等于要求 reviewer 自行补完 registry mapping。

### 9.3 reviewer 的真实拒绝理由没有到达主 Agent

`PermissionReviewControlPlane` 会把 reviewer reason 写入 `permission_review_settled`，但 `AgentPermissionResponder.requestApproval` 只返回 `PermissionDecision`。随后 `AgentLoop` 根据原始 gate outcome 重新生成：

```text
permission denied: <gate reason>
```

外层失败处理又可能再加一次 `permission denied:`。因此会出现：

```text
reviewer/event log 知道：write_file 被误认为不在 capability lease
主管只知道：permission denied: permission denied: modify workspace resource
```

这就是“审查者知道、主管不知道”的直接原因：详细理由被持久化在 review settlement，但 responder 接口只传回一个枚举，AgentLoop 又用 gate 文案覆盖了 reviewer 文案。

### 9.4 reviewer 的职责定义过宽

当前 reviewer 同时被要求判断：

- 请求是否与用户目标相关；
- 是否有语义风险；
- 是否符合 capability lease；
- 是否符合 workspace lease；
- 是否存在 self-review 或 hard deny。

其中后四类大部分是宿主可以确定性判断的事实。模型只应承担前两类中无法由规则确定的部分。

### 9.5 必要副作用失败后，任务终态仍可能被错误叙述为完成

最近的实际会话中，目标文件没有创建，但上层仍给出了完成式回复。这说明权限拒绝除了理由保真外，还需要与任务成功条件联动：如果所需写入没有成功 settlement，agent 不得把相应交付声明为已完成。这个问题属于 AgentInvocation/WorkTask completion evidence，不应通过放宽权限来掩盖。

## 10. 推荐的目标架构

### 10.1 五阶段权限流水线

```text
1. Tool resolution
   model ToolCall -> 唯一 ToolRegistry -> concrete ToolRuntime

2. Deterministic authorization
   schema/args -> canonical tool/capability -> CapabilityLease
   -> WorkspaceLease/PathConfinement -> hard deny or eligible action

3. Immutable action snapshot
   生成 ResolvedToolAuthorization / ApprovalAction

4. Optional semantic review
   仅 eligible ask/boundary action -> reviewer
   reviewer 只判断 user authorization、task necessity、semantic risk

5. Durable execution
   decision settlement -> revalidate leases/root -> prepare ticket
   -> executor -> tool result + settled -> evidence/projection
```

### 10.2 唯一 Tool Registry

每个具体工具只注册一次，并由同一记录产生：

- model-visible JSON schema；
- concrete tool ID/name；
- canonical capability；
- side-effect/permission-intent adapter；
- executor handler；
- replay policy；
- 可选 approval-action builder。

建议的概念结构：

```swift
struct RegisteredTool {
    let id: ToolID
    let descriptor: ToolDescriptor
    let requiredCapabilities: Set<ToolCapability>
    let makePermissionIntent: (ToolArgs, ToolContext) throws -> PermissionIntent
    let makeApprovalAction: (ValidatedToolCall, AuthorizationFacts) -> ApprovalAction
    let execute: (ValidatedToolCall, ToolContext) async throws -> ToolObservation
}
```

这里不是要求从零编写解析或执行引擎，而是把 Intatis 已有的工具 wrapper、descriptor、permission adapter 和 executor 绑定到同一个注册对象。

### 10.3 不可变 `ResolvedToolAuthorization`

在送审前，宿主应产生一份不可变、可持久化或可由事件准确重建的动作快照，至少包含：

```text
snapshot/schema/registry version
descriptor/spec hash
session / agent / task / root / parent / attempt / tool-call IDs
concrete tool ID and public tool name
canonical permission action
required capability IDs
capability membership decision + lease ID/version
workspace lease ID/version/access/root identity
normalized arguments digest and bounded/redacted representation
exact resources: paths / patch / command / host / port / MCP tool
data/control effects, risks, replay policy
deterministic policy decision/reason/version
task objective and compact causal context
```

同一快照应成为以下环节的共同输入或共同引用：

- permission request；
- automatic reviewer；
- `permission_review_requested/settled`；
- `permission_resolved`；
- `tool_execution_prepared/settled`；
- executor 的执行前 revalidation；
- GUI/CLI 的权限与失败投影。

### 10.4 reviewer 的新职责

reviewer 应明确收到：

```text
宿主已经确认：
- 工具存在；
- 当前 agent 的 lease 包含所需 canonical capability；
- 当前 workspace/path 没有越过 hard boundary；
- 该动作属于 deterministic gate 允许送审的类别。

reviewer 只需判断：
- 该准确动作是否得到用户当前目标授权；
- 动作是否对完成任务必要且范围最小；
- 是否存在欺骗、秘密获取、破坏性或语义风险；
- 是否应拒绝并说明理由。
```

reviewer 不应再通过比较 `write_file` 与 `apply_patch` 字符串判断 lease membership。

### 10.5 reviewer 不需要主管的完整上下文

建议继续保留独立、no-tools、只读控制面。输入应是：

- 当前准确 `ApprovalAction`；
- 用户目标和当前 task contract 的紧凑投影；
- 与该动作直接相关的近期事件；
- 必要时由宿主执行的只读证据查询结果。

不应把完整 session transcript、所有 agent 私有上下文或完整模型工具列表灌入 reviewer。上下文越大并不会修复身份映射，反而增加 prompt injection、信息泄漏、延迟和误判面。

### 10.6 结构化 verdict 和理由保真

建议 responder 不再只返回 `PermissionDecision`，而返回结构化结果：

```swift
struct PermissionResolution {
    let decision: PermissionDecision
    let source: PermissionDecisionSource
    let reason: String
    let risk: PermissionRisk
    let reviewerTaskID: PermissionReviewTaskID?
    let actionSnapshotID: String
}
```

规则：

- reviewer 的 bounded reason 原样进入 settlement、resolution 和 tool result；
- UI 可根据 source 区分 gate hard deny、reviewer deny、timeout、malformed、cancel、persistence failure；
- 只在最终展示层增加一次统一前缀；
- 不允许出现 `permission denied: permission denied: ...`；
- 不用 gate 的泛化 reason 覆盖 reviewer 的具体 reason。

## 11. 审查触发范围：需要单独做产品决定

Codex 只审查越过 sandbox boundary 的动作，沙箱内原本允许的普通动作不送 Guardian。Intatis 当前原则是普通文件写入、exec、network、destructive 进入 ask/reviewer。

这里有两个可行策略：

### 策略 A：保留 Intatis 的严格逐次审查

- 继续让每次 workspace write 进入 reviewer；
- 但 reviewer 只判断用户授权和语义风险；
- capability membership、路径和 workspace access 全部由宿主提前确定。

优点是保持当前安全语义，改动边界较小；缺点是延迟、成本和误拒绝面仍高。

### 策略 B：Codex-aligned boundary review

- 用户已明确授权的 workspace 内、符合 lease 和 deterministic policy 的常规动作直接执行；
- 只有越过既定边界、提高权限、敏感路径、网络、exec、destructive 或高风险动作进入 reviewer。

优点是审批量和模型误判显著减少；缺点是改变当前“普通写入也 ask”的产品承诺，必须经用户明确批准并重新做威胁模型与回归。

本报告不擅自选择或修改这一策略。无论选 A 还是 B，工具到 capability 的 membership 都不应由 reviewer 判断。

## 12. 开源复用建议

用户希望优先复用成熟开源实现而不是自行编写核心。对权限系统而言，最合理的复用边界不是把另一个项目的整个 runtime 拉入 Intatis，而是选择性派生以下成熟结构和测试模式：

| 可复用方向 | 优先参考 | 复用方式建议 |
|---|---|---|
| 强类型 ApprovalAction schema | Codex | 固定 commit 后派生 Swift data model；保留来源与许可证 |
| Guardian prompt contract | Codex | 只复用公开 model-facing contract 的通用部分；去除品牌并映射 Intatis 术语 |
| 单一 registry 生成 spec/handler | Codex、Cline | 选择性派生 registry pattern，接入现有 Swift Tool wrappers |
| canonical permission mapping | OpenCode | 参考/派生映射与测试，不继承其默认策略 |
| rule-first、LLM-last precedence | Goose | 参考行为和回归测试；不复制 tool-name-only cache |
| denial/circuit-breaker tests | Codex、Intatis 现有测试 | 派生精确动作、重复拒绝、理由保真的测试矩阵 |

不能直接照搬：

- OpenCode 的 app-level policy 不能替代 macOS sandbox、WorkspaceLease 或 durable ticket；
- Cline 的宽松未列出工具默认值不能进入 Intatis；
- Goose 的 tool-name-only judge/cache 不能进入 Intatis；
- 任一上游的默认网络、文件或 exec 权限都不能绕过 Intatis 三层权限门；
- Rust/TypeScript runtime 不应作为不可审计的第二事实源隐式进入 iOS target。

实际复制前必须再次核对每个目标文件、根 LICENSE、NOTICE 和传递依赖。本报告没有完成“可直接复制哪些文件”的许可证批次审计，因此目前只能作为架构与候选复用清单，不能被视作已获准复制。

## 13. 建议实施顺序

如果后续获准修改代码，建议按以下顺序进行，避免先改 prompt 掩盖架构错误：

1. **先补故障回归**：固定 `.applyPatch -> write_file/apply_patch` 的宿主映射，证明 reviewer 不得因名称不同误拒绝。
2. **收敛 Tool Registry**：让 model schema、capability mapping、permission-intent builder 和 executor 从同一注册记录产生。
3. **加入 ResolvedToolAuthorization**：在 review 前完成 deterministic membership 和资源解析。
4. **收窄 reviewer contract**：删除 reviewer 对 capability membership 的自由推理职责，只审 user authorization/necessity/risk。
5. **改 responder 结果类型**：端到端保留 reviewer reason 和失败来源，消除双前缀。
6. **统一 durable snapshot 引用**：requested、settled、resolved、prepared、settled execution 引用同一动作身份。
7. **补完成证据约束**：必要副作用未成功时，AgentInvocation/WorkTask 不得宣告相应交付完成。
8. **最后再决定审查量**：由用户选择保留严格逐次审查，还是迁移到 Codex boundary-only 模式。

## 14. 必需回归测试

### 14.1 Tool/capability 单一事实源

- `.applyPatch` lease 生成的 registry 同时包含 `write_file` 和 `apply_patch`；
- 两个 concrete tools 的 canonical capability 都是同一个 `filesystem.edit`；
- model-visible schema、permission resolver 和 executor lookup 使用同一个 concrete tool ID；
- unknown/unregistered/unleased tool 在 reviewer 前拒绝，reviewer 调用次数为零；
- registry/version/spec hash 不匹配时 fail closed。

### 14.2 reviewer 输入与职责

- reviewer 收到 concrete tool、准确资源和宿主 `membership=allowed` 结论；
- reviewer 不收到需要自行解释的 capability alias 冲突；
- `write_file` 不会因 capability 名为 `apply_patch` 而误拒绝；
- 同一 tool 对不同 path/diff/command 使用不同 action snapshot；
- hard deny 永远不会进入 reviewer；
- reviewer 无工具、不能 self-review、不能扩大权限。

### 14.3 理由与终态

- reviewer deny reason 原样出现在 settled、resolved、tool result 和主管下一轮上下文；
- timeout、cancel、malformed、provider failure、persistence failure 有不同结构化 source/reason；
- UI 只添加一次展示前缀；
- required write 未成功 settlement 时，任务不能回报文件已创建；
- 第三次完全相同 denied action 终止当前 agent run，改参数或改资源形成新 action identity。

### 14.4 兼容与持久化

- 旧 JSONL 缺 action snapshot 字段继续解码；
- additive optional 字段不改变旧 Envelope/type/seq 规则；
- crash 位于 review requested/settled、permission resolved、execution prepared/settled 各边界时都能 fail closed；
- reviewer reason 不包含完整 secret、完整模型输出或未裁剪参数；
- iOS target 不链接 Permission/AgentKernel/Cowork 新类型。

## 15. 不确定性与限制

- Codex、OpenCode、Cline 和 Goose 都是活跃项目；本报告只对表中固定 commit 负责，不能把浮动 `main` 的未来行为当成已审计事实。
- 本次没有运行 Intatis 的真实 provider 自动 reviewer，因此无法量化修正前后的误拒绝率、延迟或 token 成本。
- 最近会话的现象证明了当前名称漂移和理由丢失，但没有在本轮重新发送任何真实 provider 请求，避免产生外部费用和状态变化。
- Cline 与 Goose 本次只做公开源码架构研究，没有完成后续直接复制所需的文件级许可证批次审计。
- “普通 workspace 写入是否仍逐次送审”是产品安全策略，不能由一次技术修复自行改变。

## PROJECT_AUDIT_SUMMARY

- Intatis 当前已有三层权限门、独立 durable Cowork reviewer、CapabilityLease/WorkspaceLease、PathConfinement、root identity 复核和 durable tool execution ticket，基础安全方向正确。
- `Orchestrator.toolRegistry(for:)` 已由 capability 生成具体工具面，但 reviewer prompt 仍把 concrete tool 与 raw capability 字符串同时交给模型重新判断一致性。
- `PermissionIntent.defaultAction` 已部分归一 `write_file` / `apply_patch` 为 `filesystem.edit`，但缺少宿主签发的 membership 结论和 registry identity。
- `PermissionReviewControlPlane` 持久化具体 reviewer reason，`AgentPermissionResponder` 却只把 decision 返回 `AgentLoop`，造成详细原因在主 agent 路径中丢失。
- 当前最合适的外部参考组合是：Codex 的 `ApprovalAction + Guardian` 分层、Cline 的单一 Tool Map、OpenCode 的 canonical permission/deny-first，以及 Goose 的 rule-first/LLM-last。

## DOCS_CONTENT_SUMMARY

- 本报告记录了四个固定上游版本、源码证据、项目间对比、Intatis 最近误拒绝的原因、建议目标架构、复用边界、实施顺序和回归矩阵。
- 没有更新 `docs/CURRENT_STATE.md`、`docs/ARCHITECTURE.md`、`docs/DO_NOT_BREAK.md` 或 `docs/NEXT_TARGET.md`，因为本轮没有改变实现或当前项目状态；在用户确认目标方案并实际落地后，再同步这些权威状态文档。

## VALIDATION_RESULT

实际运行结果：

- `git diff --check`：通过，无 whitespace error。
- `git status --short`：确认本轮只新增本报告；其余渲染源码、工程配置、NOTICE、项目文档和另一份渲染调研报告均为本轮开始前已经存在的工作区改动，未被本报告覆盖或整理。

本轮为文档研究任务，未运行构建/测试。

## UNCERTAINTIES

- 具体模型内部变体无法确认。
- 真实 provider reviewer 的误判率与响应时延仍为 `UNKNOWN`。
- Cline/Goose 候选源码的直接复用许可证批次审计尚未执行；当前仅为 reference。
- boundary-only 与严格逐次 write review 的最终产品选择需要用户确认。

## NEXT_RECOMMENDED_ACTION

先由用户确认两项设计选择，再进入代码阶段：

1. 是否采用本报告的“宿主确定 authorization facts，reviewer 只审语义风险”分层；
2. 是否继续保持所有普通 workspace write 都送审，还是后续另做 Codex-aligned boundary-only 策略设计。

确认后，下一步应先写失败回归和 `ResolvedToolAuthorization` 设计，不应先靠修改 reviewer prompt 临时规避 `write_file` / `apply_patch` 名称问题。
