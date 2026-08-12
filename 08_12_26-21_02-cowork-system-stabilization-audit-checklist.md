# Intatis Cowork 系统稳定化：问题清单、全链审计与重构门禁

> 日期：2026-08-12
>
> 仓库：`/Users/vita/Vitemis/Intatis`
>
> 报告性质：事故汇总、风险清单、只读审计计划与后续修复门禁
>
> 证据范围：当前源码与项目文档、脱敏后的 EventLog 事件、用户提供的截图、当前未提交工作树中的修补
>
> 重要限制：本文不是“已经修完”的证明，也不声称已经发现仓库中的全部缺陷。

## 1. 结论先行

当前暴露出来的并不是一个孤立 bug，而是一组跨越多个系统边界、会互相放大的缺陷：

1. 模型看到的工具合同与宿主真正执行的合同不完全一致。
2. 权限审查承担了部分本应由结构化 schema、角色能力或确定性宿主规则完成的工作。
3. 工具失败后的副作用状态没有在所有工具中统一、精确地分类。
4. 父任务、子代理、同步委派、超时与取消之间没有形成完整的结构化并发合同。
5. 底层已经拥有的错误来源和副作用信息，在投影与 UI 层被压扁成了误导性的通用文案。
6. 配置、prompt、Skill、provider wire schema、executor 和测试之间存在合同漂移。
7. 真实模型输出的不稳定性会触发这些薄弱边界，但“模型不够稳定”不能替代宿主侧的机械约束和恢复设计。

因此，后续不应继续按照“看到一张错误截图就局部打补丁”的方式推进。建议暂时冻结新的 Cowork 行为扩展，先建立全仓工具清单、统一不变量和真实事故回放，再按边界逐项修复。

必须保留的安全原则也要说清楚：

- 不能为了减少报错而直接关闭权限审查。
- 不能为了让任务显示完成而移除 side-effect completion fuse。
- 不能把不确定副作用一律标成可安全重试。
- 不能把 strict schema 全局降为非严格来掩盖 schema 不合法。
- 不能用更多 prompt 代替本来可以由 schema、capability projection 或宿主状态机机械保证的约束。

## 2. 证据分级

本文使用以下标签，避免把推测写成事实：

- **已证实**：源码和真实 EventLog 能共同还原因果链。
- **已排除**：现有证据足以排除该方向是本次事故根因。
- **当前工作树已有修补**：本地未提交工作树已经包含对应修改，但本文不把它视为已发布、已合并或已完成全量验证。
- **高风险待审**：已经看到同类结构性风险，但尚未完成全仓逐项证明。
- **UNKNOWN**：缺少原始输出、完整运行记录或穷举审计，不能给出确定结论。

## 3. 已发生事故总表

| 编号 | 表面现象 | 已证实根因 | 被排除项 | 当前状态 |
|---|---|---|---|---|
| INC-01 | OpenRouter、Moonshot、不同模型都在首轮请求返回 HTTP 400 | provider-facing strict tool schema 不自洽：sidecar 被加入 `properties`，却未加入 `required`，同时仍保留 `strict:true` | 网络中断、额度、计费、单一模型、单一上游故障 | 当前工作树已有修补；仍需全量 wire invariant 与真实 provider 矩阵 |
| INC-02 | `task_create` 报 owner 不存在，随后被标为需要人工 reconciliation | 模型在同一批调用里先引用未来 agent，再 `spawn_agent`；宿主前置 owner 校验正确拒绝，但通用副作用分类把零副作用 preflight failure 误判为 unknown | WorkTask 已经部分创建、网络失败 | 当前工作树已补模型合同和部分 `not_started` 边界；全工具副作用审计未完成 |
| INC-03 | `spawn_agent` 连续被 automatic reviewer 拒绝，显示 malformed verdict | reviewer 返回成功、非空 completion，但不符合本地严格 verdict parser；prompt 与 parser 的硬限制曾不一致 | sidecar 缺失、本地把独立 reasoning 字段主动拼进正文、网络失败 | 协议和测试仍需真实模型矩阵；原始 reviewer 正文不落盘，具体失败分支 UNKNOWN |
| INC-04 | reviewer 随着主 Agent 模型切换，DeepSeek 替代了原本更稳定的 Luna | 旧设计直接从 `@main` 派生/freeze reviewer binding，配置中的 `judge_model` 实际未被读取 | 用户显式选择了 reviewer UI 模型 | 当前工作树已实现独立 `permission_reviewer_model` 路由；尚未提交/发布 |
| INC-05 | worker 的 `task_update` 一次被 executor 拒绝、一次被 reviewer 拒绝，子任务最终失败 | worker 使用了过宽的通用更新 schema，发送全部 optional 字段并实际改变冻结合同；角色约束主要依赖文字和后置检查 | strict schema 强迫模型补齐全部字段、sidecar 格式错误、hard deterministic policy deny | executor 和 completion fuse 行为正确；模型面工具设计仍需重构 |
| INC-06 | UI 显示“600 秒超时”，但总耗时约 832 秒 | root deadline 到期后取消了 parent operation，但同步 `delegate_task` 等待使用 cancellation-unaware continuation；宿主为了 drain loser 一直等到 child 自然终态 | provider/network 600 秒超时 | 未修；需要明确 deadline 语义和结构化取消 |
| INC-07 | reviewer 的语义 DENY 显示成 `denied by policy`；Cowork 调度器超时显示成“Retry or switch provider” | reviewer DENY 在 control-plane/tool-result 的 `failureSource` 映射中被折叠，UI 又只消费该粗字段；timeout 建议另由错误字符串匹配产生 | 真正的 provider timeout、真正的 deterministic hard deny | 未修；属于错误分类和恢复建议设计问题 |
| INC-08 | 同一任务长时间反复 spawn/update/retry，失败不断放大 | schema 过宽、调用顺序合同、denial cache、completion fuse、deadline 和恢复提示共同作用；系统缺少针对“可纠正违约”的受控恢复路径 | 单一 provider 故障 | 高风险；需要事故回放和状态机级测试 |

## 4. 事故一：strict authorization sidecar 导致全上游 HTTP 400

### 4.1 已证实链路

Cowork automatic 模式会在 provider-facing 工具 schema 中加入：

```text
__intatis_authorization_context
```

旧实现把该字段加入对象的 `properties`，但刻意不加入 `required`，同时保留工具原有的 `strict:true`。对 OpenAI-compatible strict function schema，这会形成不合法组合：

```text
strict == true
properties.keys != required
```

当时至少涉及：

- `activate_skill`
- `read_skill_resource`
- `search_knowledge` 中原本可选的 `limit`

OpenRouter 和配置为 OpenAI-compatible adapter 的 Moonshot 共用同一套请求 encoder，所以更换模型和上游仍然得到相同 400。这也是为什么该问题发生在模型开始生成内容之前。

### 4.2 为什么“正常发一条消息”也会带工具 schema

这里必须区分 **工具声明** 和 **工具执行**：

- Cowork 的一次正常模型请求会携带当前 Agent 可见的 `tools` 目录。
- 这些 JSON Schema 是告诉模型“如果你决定调用工具，必须返回什么结构”。
- provider 先验证工具声明，再开始生成正文或 `tool_calls`。
- 模型真正返回某个 `tool_call` 后，Intatis 才在本地进入 gate、reviewer、durable ticket 和 executor。
- 工具执行本身没有被发送给 OpenRouter/Moonshot 代替本地执行。

因此，当 `__intatis_authorization_context` 出现在工具 schema 里时，它只是模型未来可能输出的一个 tool-call argument 合同，不代表 PermissionReviewer 已经运行。旧 schema 本身不合法，所以即使用户只发普通消息、模型还没选择任何工具，provider 也会在请求入口直接返回 400。

该 sidecar 的设计目的，是让 acting model 在同一个业务 tool call 里附带一句与 exact action 绑定的理由。宿主在本地剥离它，再把安全、完整的 business arguments 和这句 sidecar 交给独立 reviewer；它不应该进入业务 executor schema或 durable business arguments。

### 4.3 已排除的早期假设

- 不是 `developer` message role 导致的。`developer`/`system` 是模型消息角色；本事故的 provider 400 在工具 schema 验证层已有直接证据。
- 不是 7 月 31 日某次 role 调整单独导致的。用户在 8 月 11 日仍能正常使用，加上多个 adapter 收到同一坏工具目录，时间线和请求证据都不支持这一判断。
- 不是 PermissionReviewer 已经拒绝了普通用户消息。请求在任何 reviewer lifecycle 之前失败。
- 不是工具被“发给上游执行”。发送的是工具定义；执行仍在本地宿主边界。

### 4.4 设计判断

authorization context 作为 provider tool schema 的一部分并非本身不合理；问题在于：

- provider wire schema 宣称 strict；
- schema 又保留了 strict 协议不允许的 optional property 表示；
- 本地测试还锁住了这个错误组合；
- 真实 provider smoke 没覆盖 strict schema。

正确边界应是：

- 原 ToolDescriptor 和 executor business schema 不变；
- 只修改 request-owned provider copy；
- automatic 模式下 provider-facing sidecar 是 required string；
- 宿主只在真正进入 automatic ask 时验证和消费它；
- 所有 `strict:true` 对象递归满足 closed-object invariant；
- 请求在发网前先做 typed validation，不能让 provider 代替本地发现 schema 错误。

这里的 strict/non-strict 需要保持一个清晰边界：

- **non-strict**：schema 是模型调用工具时的结构指导，provider 不承诺输出完全满足它；真正校验仍在宿主。可选字段可以真正省略，但模型的结构服从率通常更低。
- **strict**：provider 对模型输出施加强结构约束，结构服从率更高；代价是 schema 必须满足 provider 的 strict 子集，通常要求 closed object 且所有 properties 都列入 required。
- **语义可选**：在 strict schema 中常用 nullable 表示“这个字段必须出现，但值可为 null”。它不等于 PATCH 中的“字段完全没有出现，所以不要修改”。

因此 strict 适合固定、完整的 command/result object，但不能不加设计地套在部分更新工具上。对 PATCH 工具，`null`、空数组、默认值和 omitted field 往往具有不同业务语义；如果强迫所有字段出现，就会诱导模型用占位值覆盖权威状态。可选方案是：

- 让 PATCH 工具保持 non-strict，并在本地做强校验；
- 按角色拆成字段很少的 strict command；
- 或设计显式 operation/sentinel，使“保持不变”和“清空”在 schema 中机械可区分。

本次最新会话里的 `task_update` 实际是 non-strict，business required 只有 `task_id` 和 `expected_revision`；模型发送全字段并不是 strict 强迫。这一点不能与最早的 strict-sidecar 400 混为一谈。

### 4.5 当前状态

当前未提交工作树已有相应修补和测试扩展，包括 strict sidecar、递归 strict schema 校验以及 `tool_search_output` 中延迟工具的装饰。本文没有重新证明这些修改已经覆盖所有 provider、namespace 和动态工具路径。

### 4.6 必须建立的回归门禁

- [ ] 对每个 provider-facing function/namespace 递归检查 strict invariant。
- [ ] 对静态工具、Skill 工具、Knowledge 工具、MCP 工具和 deferred tool-search 输出使用同一检查器。
- [ ] 在 HTTP body capture 层验证最终 wire payload，而不只验证中间 `ToolSpec`。
- [ ] OpenRouter 与 OpenAI-compatible 至少各跑一条真实 strict tool smoke。
- [ ] 禁止新增测试去断言 `strict:true + optional property` 是合法合同。

## 5. 事故二：未来 owner、错误调用顺序与副作用误判

### 5.1 已证实链路

会话 `cowork_q430fh27` 中，模型在同一个 assistant response 里先发送六个：

```text
task_create(owner = dpv-ch2 ... dpv-ch7)
```

之后才发送六个：

```text
spawn_agent(name = dpv-ch2 ... dpv-ch7)
```

混合工具批次由宿主按 provider 返回顺序串行执行。因此第一个 `task_create` 运行时，`dpv-ch2` 尚未 attach。`createWorkTask` 的 owner 校验在任何 WorkTask 事件 append 之前正确拒绝了请求。

真实 EventLog 证明该 exact invocation：

- 没有创建 WorkTask；
- 没有 attach agent；
- 没有发生部分持久化副作用；
- 只留下 prepared/failed 执行记录。

截图中的绿色 `task_create approved` 只表示权限决策已经 allow，不表示 executor 已经创建 WorkTask。权限审批发生在执行之前；随后 executor 仍可因 authoritative state/preflight 失败。

同样，`Response was not accepted as complete` 也不是上游拒收了模型正文。模型先返回了带工具调用的 assistant response，随后 authoritative turn 因工具失败而终结，Projection 才把先前生成的完成文本标为“不构成已接受完成”。

### 5.2 真正的设计问题

`owner 必须是当前已 attach 的 data-plane agent` 这个宿主约束本身合理。问题是它此前没有被完整投影到模型面：

- `task_create` descriptor 没明确说明 future/planned agent 不能作为 owner；
- Skill 同时要求先建任务图和后 spawn，却没有说明先建图时应该省略 owner；
- runtime prompt 没有明确“同一 tool-call batch 不是事务，也不是并发请求或并发保证”；
- 模型没有被要求等待前置调用的成功 `ToolResult` 后，再在下一轮使用新 identity/ID/state。

随后，`task_create` 被统一标记为 `requiresManualReconciliation`，普通 preflight error 跨过 executor boundary 后被保守地归为 unknown。这使一个可证明 `not_started` 的失败被误报为可能已有副作用。

### 5.3 正确模型合同

多 worker 的保守顺序应为：

1. 批量 `task_create`，全部省略 owner。
2. 等待所有成功 ToolResult，保存真实 WorkTask ID。
3. 批量 `spawn_agent`。
4. 等待所有成功 ToolResult，确认 agent 已 attach。
5. 对已确认的 task/agent pair 执行 `delegate_task`。

或者先成功 spawn，再在后续 tool-call round 创建带 owner 的任务。无论哪种方式，都不能在同一批里把 planned/future object 当作已经存在。

### 5.4 当前状态与剩余风险

当前工作树已补充通用因果合同、Skill 和 `task_create.owner` 描述，并为 `task_create`/`task_update` 的首个 WorkTask append 前拒绝建立更精确的 `not_started` 通道。

但这只是两个工具。此前只读盘点显示，仓库里约有六十个静态 mutating tools，另有动态 MCP 和 knowledge 工具路径采用 `requiresManualReconciliation`。这个数字是旧盘点估计，必须基于当前工作树重新生成；不能假设它们都已经正确区分：

- preflight rejected / not started；
- execution started but no commit proof；
- commit succeeded；
- commit result lost / unknown；
- partial side effect；
- fully reversible side effect。

当时 UI 还给出了普通 `Retry`，但 Orchestrator 在真正 admission 前会被 unresolved non-replayable execution fence 拦住。也就是说，该按钮既不能完成用户期待的重试，还可能使 submission attempt 与 task attempt 的相关性进一步复杂化。unknown/manual reconciliation 状态下不应展示普通 blind Retry。

## 6. 事故三：permission reviewer verdict 协议不稳定

### 6.1 已证实事实

当日 DeepSeek reviewer 的 provider 请求成功结束，返回了非空文本，没有 tool call，但本地 `PermissionReviewTextVerdictParser` 返回 nil。

当时 parser 的真实合同包括：

- exactly one final-line ASCII `ALLOW` 或 `DENY`；
- 前面必须有非空 reason；
- reason 不能超过 240 characters；
- 不接受 JSON；
- 不接受 code fence；
- 不接受多 marker 或变体 marker。

Cowork reviewer prompt 曾只要求“short nonempty reason”，没有告诉模型 240 characters 这个硬上限。所有 parser 分支又被折叠为同一个 `malformed_verdict`。

raw reviewer text 按隐私设计不写入 EventLog，因此无法从现有持久记录确定那次具体是：

- reason 过长；
- marker 缺失；
- marker 不在最后一行；
- 返回 JSON；
- code fence；
- 多 marker；
- 其他格式不符。

上述具体分支均为 **UNKNOWN**。

### 6.2 已排除项

- 本地 OpenAI-compatible adapter 只把 `delta.content` 作为正文，未知的 `reasoning` / `reasoning_content` 字段不会被主动拼进 reviewer text。
- 该次不是网络失败。
- 该次不是 sidecar 缺失或 malformed，因为它已经进入了 reviewer lifecycle。

### 6.3 模型稳定性确实有关，但不是唯一责任

历史真实会话表明，DeepSeek 在旧 JSON verdict 合同下也发生过输出不合规。最新事故语料又表明 Luna 也出现过多次 malformed verdict。因此：

- 模型的 instruction following 稳定性确实会影响成功率；
- 不能把 Luna 或任何模型写成“从不出错”；
- 宿主必须用最小、明确、可验证且可观测的协议；
- 真实模型矩阵不能被 canned-output 单元测试替代。

### 6.4 必须改进的边界

- parser 应返回 typed failure category，而不是只有 nil。
- EventLog 可以持久化无敏感内容的分类，例如 `missing_marker`、`multiple_markers`、`reason_too_long`、`json_not_allowed`，但仍不保存 raw reason 或 exact tool args。
- prompt、parser、测试 fixture 和 real-provider smoke 必须由同一 canonical contract 生成或校验。
- reviewer 的最终判决协议应尽量只让 marker 决定 allow/deny；reason 如果本来不持久化，不应因为非安全相关的冗长问题阻断整个授权，除非产品明确需要这一硬限制。

### 6.5 新会话能不能解决

新会话会清除旧会话自己的 history、denial cache、unresolved ticket 和控制面身份，因此可能暂时绕开某些 session-local 残留。但它不是这些根因的修复：

- 如果 reviewer model/profile 仍然不服从 verdict 合同，新会话仍会 malformed。
- 如果 provider-facing tool schema 仍然非法，新会话第一轮仍会 400。
- 如果 reviewer 仍按旧设计从 `@main` 派生，新会话只会重新继承当时的 main/default route。
- 如果工具 schema/角色约束仍然过宽，模型仍可在新会话发出同样的无效调用。

所以“开新会话”只是一种诊断隔离手段：它可以帮助区分 session-local 状态和全局 runtime/config/schema 缺陷，不能作为正式恢复方案。

### 6.6 malformed、语义 DENY 和缓存拒绝不是一回事

15:55 截图附近出现过三种容易被 UI 和模型说明混在一起的状态：

- live reviewer completion 不满足文本协议，形成 `malformed_verdict`；
- reviewer 成功返回协议合法的 `DENY`；
- 相同 bound invocation 命中 session-local duplicate/denial cache。

它们的根因和恢复方式不同。缓存只会复用已经形成的同调用终态，不会凭空制造最初的 malformed 或 semantic DENY。开新会话可以清除旧 session 的 cache/correlation，但不能修复 reviewer 模型服从性、parser/prompt 漂移或错误的 reviewer 配置。UI 必须分别展示这些来源，不能都压成 `denied by policy`。

## 7. 事故四：reviewer 模型错误地跟随 `@main`

### 7.1 旧行为

旧设计在 fresh bootstrap 和恢复重建 reviewer 时，直接复制或 freeze 当前 `@main` 的 exact inference binding。因此切换主 Agent 模型后，reviewer 可能在恢复时也变成该模型。

用户配置中的 `judge_model` 并不是实际受支持字段，仓库内没有生产读取链路，所以它无法固定 reviewer。

### 7.2 已确认的新合同

顶层配置新增：

```json
{
  "model": "OpenRouter/openai/gpt-5.6-luna",
  "permission_reviewer_model": "OpenRouter/openai/gpt-5.6-luna"
}
```

合同为：

- 不增加 UI 选项；
- `permission_reviewer_model` 使用 `<provider>/<model-id>` base profile；
- reviewer binding 在 host/config 层独立解析和冻结；
- reviewer 不跟随 UI 当前选择；
- reviewer 不跟随 session default；
- reviewer 不跟随 live/historical `@main`；
- reviewer 不跟随后续 main rebind；
- 字段缺失时，只允许在同一 JSON 配置文档解析阶段一次性继承顶层 `model`；
- 字段显式存在但为空、类型错误、route 不存在、provider 不可用或配置损坏时 fail closed；
- 不得把显式非法配置悄悄回退成 main。

### 7.3 当前状态

当前未提交工作树已经包含 macOS、CLI、Orchestrator、测试和文档的实现改动。此前完成的 focused checks 包括：

- `AutomaticPermissionReviewTests`
- `PerAgentInferenceProfileTests`
- `CLIProviderAdapterTests`
- `IntatisCLITests`
- `swift build`

这些结果说明改动在当时的工作树上通过了相应本地检查，但不等于：

- 已提交；
- 已发布；
- 已跑全量 test suite；
- 已跑真实 reviewer provider 矩阵；
- 已证明所有 config migration/write-back 边界都不会回退。

## 8. 事故五：worker `task_update`、有效 DENY 与完成失败

### 8.1 精确事件链

会话 `cowork_9nwnf26w` 中，第二个 worker 对自己的 WorkTask 连续发出两次错误更新。

第一次调用：

- `expected_revision=3`；
- `status=completed`；
- 带 result 和 evidence；
- 同时重新发送 title、description、acceptance criteria、expected artifacts、owner、dependencies、priority、retry 等所有 optional 字段；
- Luna reviewer 给出协议合法的 `ALLOW`；
- executor 在首个 WorkTask append 前拒绝；
- `effectDisposition=not_started`；
- 没有业务副作用。

真实差异至少包括两个 literal backslash：

```text
学分/学时      -> 学分\/学时
页码/表格位置  -> 页码\/表格位置
```

这使本来应该是重复的冻结字段，在 exact comparison 下成为 contract mutation。

随后 worker 执行 `task_get`，拿到了 authoritative revision 3，却发出第二次更差的更新：

- description 变成“占位”；
- acceptance criteria 变为空数组；
- expected artifacts 变为空数组；
- status 退回 `in_progress`；
- 仍带 result、evidence 和其他冻结字段。

第二次调用：

- deterministic gate 为 pass/medium；
- Luna reviewer 返回协议合法的语义 `DENY`；
- 不是 malformed verdict；
- 不是 hard deterministic policy deny；
- 没有 `tool_execution_prepared`，所以没有 executor 副作用。

能从持久记录确定的是：reviewer 输出协议合法并选择了 `DENY`。具体自由文本理由没有落盘，因此“它究竟依据哪一条语义理由拒绝”仍是 **UNKNOWN**。参数明显违反 worker 合同，可以说明这个 DENY 与宿主边界相容，但不能冒充 reviewer 的原始思考或逐字理由。

之后模型直接输出自然语言 final。SideEffectEvidenceLedger 仍持有 unresolved denied/failed `task_update`，因此 completion fuse 正确阻止了“假完成”，child invocation 以 `unresolved_denied_side_effects` 失败，WorkTask 保持 `in_progress`。

### 8.2 已排除项

- `task_update` 当时不是 strict tool；schema 没有强制模型补齐所有 optional 字段。
- sidecar strict 修补没有让 business optional 字段变成 required。
- 第一次不是 reviewer 拒绝，而是 executor preflight 拒绝。
- 第二次 reviewer 的输出协议有效，不是老的 malformed 问题。
- 两次请求都没有业务副作用。

### 8.3 设计问题

manager 和 worker 共享同一个宽 `task_update` 模型面 schema，但 worker 实际不能修改图结构、owner、priority、retry 和冻结 task contract。系统目前主要依赖：

- 工具 description；
- Skill/prompt；
- automatic reviewer；
- executor 后置 preflight；
- completion fuse。

这相当于先把模型不该碰的字段交给模型，再要求它稳定地记住不要碰。对于 deterministic internal settlement，这是脆弱设计。

### 8.4 推荐重构

把 model-facing 工具按角色/能力投影：

```text
manager task_update:
  允许 task graph、owner、priority、retry、contract 等管理字段

worker update_owned_work_task:
  task_id
  expected_revision
  progress_note
  permitted status transition
  result
  evidence
  authorization sidecar（仅 provider copy）
```

并建立以下宿主规则：

- worker 只能更新自己当前拥有的 WorkTask；
- schema 根本不暴露冻结合同字段；
- JSON Patch 语义：没有出现的字段就是不修改；
- 禁止用 placeholder、空数组或默认值表示“不修改”；
- exact owner、revision、allowed field set 和状态迁移全部可由宿主机械验证；
- 对这类可机械证明的 self-owned progress/result settlement，应评估改为确定性 allow，而不是让概率模型决定内部账本是否能结算；
- reviewer 继续用于真正需要语义判断或外部副作用的动作。

### 8.5 仍不确定项

literal backslash 的最初来源尚未完成全链审计。它可能来自模型输出、转义层、历史内容再编码或参数 canonicalization。现有证据只能证明 executor 收到的 canonical argument 中确实存在反斜杠，不能进一步断言是哪一层引入。

## 9. 事故六：600 秒 deadline 最后 832 秒才结算

### 9.1 已证实时间线

- root task 开始：约 19:54:07。
- root `executionTimeoutSeconds=600`，名义 deadline：约 20:04:07。
- 第二个 child 约 20:03:18 才开始，root 预算只剩约 49 秒。
- root 正同步等待 `delegate_task -> awaitSchedulerResult(child)`。
- 600 秒 timer 到期后，parent operation 被 cancel。
- child wait 使用 `withCheckedContinuation`，没有 cancellation handler。
- child scheduler execution 也没有因 parent timeout 自动停止。
- timeout wrapper 为了不在 loser 清理前落 terminal，继续 drain/join。
- child 直到约 20:08:00 自然失败，continuation 才恢复。
- root 随后才持久化 `Task timed out after 600 seconds`。
- UI 统计总耗时约 832.242 秒。

### 9.2 因果判断

这里必须按真实时间顺序归因：

- root 名义 deadline 约在 20:04:07 已经到达；
- 第一次 `task_update` 约在 20:06:16，第二次 reviewer DENY 约在 20:07:02；
- 所以 `task_update` 不可能是 root 越过 600 秒 deadline 的起因；
- 真正让 root 到 832 秒才完成结算的原因，是已经到期的 parent cancel 无法打断 `awaitSchedulerResult`，而 timeout wrapper 又等待 loser drain；
- 后续错误 `task_update` 只决定了独立 child 最终在 20:08 以 `unresolved_denied_side_effects` 失败；这个 child terminal 恰好释放了 parent waiter。

准确因果链是：

```text
root 进入 cancellation-unaware delegated-child wait
  -> 600 秒 deadline 先到，parent cancel 无法释放 waiter
  -> 独立 child 继续执行
  -> child 后续错误 task_update，最终 unresolved-side-effect failure
  -> child terminal 释放 parent waiter
  -> timeout wrapper 完成 drain，落盘早已触发的 root timeout
```

即使 child 以其他方式终结，只要 parent cancel 不能释放这个 waiter，root 仍必须等到 child terminal；`task_update` 不是 deadline overrun 的结构性根因。

### 9.3 需要产品明确的 deadline 合同

必须二选一，不能继续保持含糊：

#### 方案 A：root deadline 是总 wall-clock 预算

- 委派和等待 child 的时间计入 root deadline；
- parent timeout 必须取消 exact delegated invocation/run scope；
- 所有 scheduler wait、mailbox wait、permission wait、provider stream 和 continuation 都必须 cancellation-aware；
- loser drain 必须有明确的有界 cleanup deadline；
- terminal 必须在清理完成或被明确标为 cleanup-uncertain 后落盘。

#### 方案 B：orchestration deadline 不扣除 delegated child 执行时间

- root 在等待已委派 child 时暂停或重新派生预算；
- child 有自己独立的 deadline；
- UI 同时显示 active execution、delegated wait 和总 wall-clock；
- 不能继续用单个“600 秒”同时表达三种时间。

不论选择哪种方案，都不应该只把 600 改大。增加数值会延后复现，但不会修复 cancellation propagation。

## 10. 事故七：错误来源在 UI 被压扁

### 10.1 reviewer DENY 被显示成 policy deny

本次第二个 `task_update` 的真实路径是：

```text
DeterministicPolicyGate: pass / medium
Automatic reviewer: valid semantic DENY
Permission resolution source: automatic_reviewer
```

但 UI 只根据折叠后的 `failureSource=policy_denied` 显示：

```text
task_update call denied by policy
```

这使用户无法区分：

- deterministic hard deny；
- automatic reviewer semantic deny；
- reviewer malformed/failure；
- authorization revalidation failure；
- MCP policy deny。

更精确地说，durable `permission_resolved` event 仍保留了 `source=automatic_reviewer`，并不是 EventLog 一开始就丢掉来源。语义压缩发生在 control-plane/tool-result 映射把 reviewer semantic DENY 归入粗粒度 `failureSource=policy_denied`，UI 随后只消费这个粗字段来生成 toast。修复时应优先保留和投影已有 source，而不是误以为必须依靠 reviewer raw reason 才能区分。

### 10.2 Cowork scheduler timeout被显示成 provider/network failure

root 的失败是 Cowork task deadline + cancellation-unaware child wait，但 UI 根据 message 含有 `timed out` 做字符串分类，给出：

```text
Retry or switch provider
This looks transient or provider-side
```

这条建议对于本事故是错误的。更换 provider 不会修复 root/child deadline 合同。

### 10.3 正确错误链

错误类型必须从产生处一直保留到 UI：

```text
typed runtime error
  -> durable event code/source/effectDisposition/retryDisposition
  -> projection typed state
  -> UI copy + allowed recovery actions
```

禁止再以 `message.contains("timeout")`、通用 `policy_denied` 或普通字符串推断恢复动作。

## 11. 同一最新会话中更早的失败放大信号

在 worker 正式开始前，该会话已经出现大量非成功工具结果。此前脱敏盘点得到 49 个 tool result，其中 39 个非成功，主要包括：

- 21 次把 raw model 与 profile 组合使用的 spawn 调用；
- 5 次 raw model 被禁止；
- 4 次重复 denial cache 命中；
- 2 次 future-owner `task_create`；
- 7 次 Luna reviewer malformed verdict。

这一组数据非常重要：

- 问题不能归结为“DeepSeek 不稳定”；Luna 也会犯协议错误。
- 模型面配置/schema 的 ergonomics 会诱发重复无效调用。
- denial cache 和恢复提示可能让模型进入重复失败循环。
- 当系统已经积累多次纠正失败时，继续扩大上下文并重试会显著消耗时间和 token。
- 后续审计必须把“失败后如何恢复”作为一等合同，而不是只检查第一次调用。

## 12. 系统性风险清单

### P0：不完成就不应继续扩展 Cowork 行为

#### P0-1 模型面工具没有按角色与 capability 做最小投影

- manager、worker、reviewer 看到的工具面不应只靠 description 区分。
- 同一工具内部的字段权限也需要 capability-projected schema。
- 模型看不到的字段比“模型看到了但 prompt 说别填”更可靠。

#### P0-2 确定性内部结算依赖概率 reviewer

- worker 完成自己 WorkTask 的 result/evidence/progress 是内部账本动作。
- 如果 owner、revision、field set、transition 都可机械证明，应该优先确定性判断。
- reviewer 不应成为内部状态机能否前进的随机单点。

#### P0-3 副作用状态分类未全仓统一

- 目前部分工具拥有明确 `not_started` proof，很多工具没有。
- 通用 `requiresManualReconciliation` 可能把纯 preflight error 误报为 unknown。
- 也不能反过来把 persistence/lost-ack error 误报为 not started。

#### P0-4 parent/child deadline 与 cancellation 不闭合

- 需要完整列出所有 await boundary 和 continuation。
- parent cancellation 必须能到达 exact delegated child 或明确声明不能。
- task terminal 必须晚于必要清理，但等待不能无限无界。

#### P0-5 typed error 在持久化、投影和 UI 之间丢失

- 当前错误文案会把用户引向错误恢复动作。
- Retry、switch provider、manual reconciliation、resume 等按钮必须由 typed recovery disposition 驱动。

### P1：稳定性和可运维性缺口

#### P1-1 provider wire schema 缺少统一发网前验证

- strict object 必须递归闭合。
- namespace、deferred tool search、MCP 和 dynamic tools 不能各自实现一套不变量。
- provider adapter 差异必须有 capture-level tests。

#### P1-2 reviewer prompt/parser/test/live route 漂移

- prompt 曾漏写 parser 的硬限制。
- canned output 测试只证明 parser 自己，不证明真实模型服从。
- raw output 不落盘是正确隐私选择，但必须保留无敏感内容的 typed diagnostic。

#### P1-3 配置 missing、invalid 和 fallback 语义容易混淆

- `permission_reviewer_model` 已暴露这一类风险。
- parser、normalizer、writer、migration、UserDefaults fallback 和 restore 必须共享 presence-aware 语义。
- 显式非法不能经过 write-back 变成字段缺失，再在下次启动时 fail open。

#### P1-4 denial cache、side-effect ledger 与纠正调用的 key 设计待审

- 相同 business action 的真正纠正调用应该能够清除旧 unresolved evidence。
- 不同 args、revision 或 authority 不能被错误视为同一 action。
- duplicate denial cache 不能把可纠正的 schema/参数错误永久锁死。

#### P1-5 WorkTask、AgentInvocation、ContinuationRun 三层终态容易混淆

- invocation 失败不一定等于 WorkTask terminal。
- WorkTask `in_progress` 可能是正确的保守状态，但 UI 需要说明下一步是谁负责结算。
- root run timeout、child invocation failure 和 WorkTask state 不能显示成同一个失败概念。

#### P1-6 长会话上下文与协调成本失控

最新截图显示累计 context/cache 已非常大，root wall-clock 也超过 13 分钟。

需要审计：

- durable history 中哪些内容被重复投影；
- compaction 是否保留了无用失败循环；
- child report 是否过长；
- main 是否同步等待太多串行 child；
- provider usage 与真正业务进展的比值；
- 是否应对 coordinator、worker、reviewer 使用不同 context budgets。

#### P1-7 real-provider smoke 覆盖不足

- strict tool schema 曾只在真实上游暴露。
- reviewer protocol 的真实模型兼容没有稳定 gate。
- opt-in smoke 不能被文档写成“已经验证”。

### P2：展示与可诊断性

#### P2-1 UI toast 过度压缩来源

至少区分 deterministic policy、automatic reviewer、runtime validation、sandbox、provider 和 cancellation。

#### P2-2 timeout 显示缺少 deadline 与 settled 时间

应显示：

- deadline；
- deadline exceeded at；
- cleanup/settled at；
- 是否仍有 child/tool 在 drain。

#### P2-3 Retry 按钮未反映 reconciliation fence

如果 unresolved non-replayable execution 会在 admission 前拒绝，UI 不应继续提供一个看似可执行的普通 Retry。

## 13. 全仓只读审计清单

以下清单应先以只读方式完成，形成基线，再开始新的业务修补。

### 13.1 Tool Surface Matrix

对每一个 model-facing 或 host-only tool 记录：

- [ ] 注册位置与实际 shipping 产品面。
- [ ] 可见角色：main、coordinator、worker、reviewer、Code agent、CLI。
- [ ] capability lease 要求。
- [ ] 原 business schema。
- [ ] provider-facing schema。
- [ ] strict 值与递归 object invariant。
- [ ] optional、nullable、默认值、mutually exclusive 字段。
- [ ] authorization sidecar 注入和剥离位置。
- [ ] intent、data effects、control effects、risk。
- [ ] deterministic gate 路由。
- [ ] automatic/manual reviewer 路由。
- [ ] replay policy。
- [ ] 第一个不可逆副作用点。
- [ ] executor boundary 前后的 error 类型。
- [ ] timeout/cancellation 支持。
- [ ] durable prepared/settled/result 事件。
- [ ] side-effect ledger key。
- [ ] retry/reconcile/resume 行为。
- [ ] projection 和 UI 映射。
- [ ] 单元、集成、事故回放和真实 provider 测试。

### 13.2 Role/Capability Surface Matrix

- [ ] main 能看到哪些工具和字段。
- [ ] coordinator 能看到哪些工具和字段。
- [ ] worker 能看到哪些工具和字段。
- [ ] read-only worker 是否还暴露可变更字段。
- [ ] reviewer 是否严格无工具、无通信、无委派。
- [ ] capability lease 改变后，tool registry 是否实时且可证明地收窄。
- [ ] namespace/deferred tools 是否遵循相同角色投影。
- [ ] 模型 context 中的工具说明是否与实际 schema 同源。

### 13.3 Schema/Wire Matrix

- [ ] 所有 strict object 递归满足 `required == properties.keys`。
- [ ] 所有 strict object 递归满足 `additionalProperties:false`。
- [ ] sidecar、nullable、enum、array items、nested object 表示兼容目标 provider。
- [ ] tool namespace 展开后仍合法。
- [ ] `tool_search_output` 中动态发现的工具仍合法。
- [ ] 最终 HTTP body 与中间 ToolSpec 一致。
- [ ] OpenRouter、OpenAI-compatible 以及实际配置 provider 分别验证。

### 13.4 Side-Effect Boundary Matrix

每个 mutating tool 必须标出状态机：

```text
validated
  -> prepared
  -> started
  -> first irreversible effect
  -> committed
  -> settled
```

并逐项证明：

- [ ] 哪些失败一定是 `not_started`。
- [ ] 哪些失败已经 started 但可以证明无 effect。
- [ ] 哪些失败是 partial effect。
- [ ] 哪些失败是 commit succeeded / acknowledgement lost。
- [ ] 哪些失败必须 manual reconciliation。
- [ ] 哪些失败可自动 replay。
- [ ] 哪些工具具有幂等 key 或外部 idempotency key。
- [ ] 不使用错误字符串或宽泛 error case 推断副作用。

### 13.5 Wait/Timeout/Cancellation Graph

盘点所有：

- [ ] provider stream task。
- [ ] tool execution task。
- [ ] permission waiter。
- [ ] scheduler waiter。
- [ ] `delegate_task` waiter。
- [ ] mailbox/reply waiter。
- [ ] continuation。
- [ ] terminal/cleanup drain。
- [ ] managed terminal/process wait。
- [ ] document/browser/image backend wait。

每一条边记录：

- owner；
- cancellation source；
- cancellation handler；
- child propagation；
- deadline inheritance；
- bounded cleanup；
- late result fencing；
- terminal ordering。

### 13.6 Permission Routing Matrix

- [ ] hard deterministic deny 不得被 reviewer 放行。
- [ ] mechanical allow 不应无必要地进入概率 reviewer。
- [ ] semantic ask 才进入 reviewer。
- [ ] reviewer 的 exact binding、generation、nonce 和 invocation snapshot 可证明。
- [ ] reviewer malformed、timeout、cancel、provider failure 分别 typed。
- [ ] missing/malformed sidecar 不消耗 denial fuse。
- [ ] valid semantic DENY 与 policy hard deny 分开持久化和展示。
- [ ] duplicate/cached decision 不跨错误 revision 或 args 误复用。

### 13.7 EventLog → Projection → UI Error Matrix

对每类错误追踪：

- [ ] origin type/code/source。
- [ ] effect disposition。
- [ ] retry disposition。
- [ ] reconciliation disposition。
- [ ] durable event payload。
- [ ] projection state。
- [ ] UI headline/body/action。
- [ ] accessibility/diagnostic copy。

禁止：

- [ ] 用 message substring 决定 provider/network 分类。
- [ ] 把 automatic reviewer DENY 折叠成 generic policy deny。
- [ ] 在 unknown side effect 下展示普通 Retry。
- [ ] 把 root scheduler timeout说成 provider transient。

### 13.8 Config/Binding Matrix

- [ ] canonical JSON/JSONC key。
- [ ] missing 与 explicit null/invalid 区分。
- [ ] env/file indirection resolution。
- [ ] provider/model ID 含 `/` 时 exact-key 优先。
- [ ] normalize 后 presence 语义不丢。
- [ ] write-back/migration 不把 invalid 写成 absent。
- [ ] UserDefaults/legacy fallback 不覆盖 explicit-invalid。
- [ ] fresh bootstrap 与 restore 使用同一 frozen exact route。
- [ ] TOCTOU revalidation。
- [ ] UI/session/main rebind 不改变 reviewer。

### 13.9 Prompt/Skill/Descriptor Contract Matrix

- [ ] runtime prompt 只写通用因果规则。
- [ ] tool descriptor 写本工具动态约束。
- [ ] Skill 给出正确分轮示例。
- [ ] schema 机械排除模型不应发送的字段。
- [ ] executor 对模型违约 fail closed。
- [ ] 错误 ToolResult 提供可执行、最小纠正方式。
- [ ] prompt/parser/schema 关键常量同源或被测试锁定。

### 13.10 Recovery/Replay Matrix

- [ ] validation failure 可在同一 turn 纠正。
- [ ] preflight not-started failure 不触发 manual reconciliation。
- [ ] denied side effect 的成功替代调用能按精确 key 清除 ledger。
- [ ] stale revision 引导先读 authoritative state。
- [ ] 纠正调用不会被旧 denial cache 拦截。
- [ ] unknown side effect 必须先 reconcile，不能盲重放。
- [ ] Retry、Resume、Reconcile、Start Over 的产品语义互不混淆。

## 14. 必须建立的自动不变量

以下不变量应成为测试和发网前/执行前的程序约束，而不是只写在文档里。

### 14.1 工具面不变量

- worker 不得看到自己无权修改的字段。
- reviewer 工具列表必须为空。
- capability lease 与 provider-facing tool surface 一致。
- future object 不能通过需要 existing identity 的宿主 admission。

### 14.2 Schema 不变量

- 每个 strict object 递归 closed。
- request-owned decoration 不改变 business executor contract。
- PATCH 工具没有出现的字段不修改。
- placeholder/empty/default 不代表 omit。

### 14.3 副作用不变量

- 首个不可逆 effect 前的 deterministic rejection 必须结算 `not_started`。
- first-effect 之后的未知错误不得自动降为 `not_started`。
- 每个 prepared execution 最终必须 exact settle 或形成 typed unresolved reconciliation ticket。
- completion fuse 只由相同 authority/resource/action 的成功 evidence 清除。

### 14.4 并发不变量

- 同一 tool-call batch 仅允许互相独立的调用。
- host 不能依赖模型假设批次会并发或串行。
- 任何依赖前置 ToolResult 的调用必须在下一 model round。
- 所有 continuation/waiter 必须有 cancellation path 或显式 non-cancellable 合同。
- parent terminal 不能早于必要 child/tool cleanup。
- cleanup 也不能无界等待。

### 14.5 权限不变量

- deterministic hard deny 终局。
- reviewer 只能收窄，不能扩大 gate 权限。
- mechanically provable internal settlement 不应被概率 reviewer随机阻断，除非产品明确决定如此并接受相应可用性成本。
- reviewer generation 只能结算 exact bound invocation。
- raw sensitive reviewer input/output 不进入 durable history。

### 14.6 配置不变量

- explicit invalid 永远不等于 missing。
- reviewer route 只来自 frozen config binding。
- main/UI/session/rebind 永远不能隐式替换 reviewer route。
- write-back 后重新解析必须保持相同 fail-open/fail-closed 语义。

### 14.7 错误不变量

- UI 动作只来自 typed retry/reconcile disposition。
- provider/network、scheduler deadline、policy、reviewer 和 runtime validation 不能共享一个模糊 code。
- durable error source 必须能从 UI 诊断信息反查。

## 15. 真实事故回放语料库

需要把真实事故脱敏后固化为 deterministic replay fixtures。不得把用户原始文档、秘密、绝对个人路径或 raw reviewer reason放入测试仓库。

### Fixture A：strict sidecar wire rejection

输入：真实 Skill/Knowledge 工具经 ContextBuilder、sidecar decorator、OpenAI encoder。

断言：发网前拒绝任何 strict invariant 违规；合法 payload 在 OpenRouter/OpenAI-compatible capture 中保持一致。

### Fixture B：future owner tool-call batch

输入：`task_create(owner=future-agent)` 出现在 `spawn_agent(future-agent)` 之前。

断言：create 为 typed `not_started`，零 WorkTask event，错误反馈要求等待 successful ToolResult；后续可纠正，不进入 manual reconciliation。

### Fixture C：worker full-field `task_update`

输入：worker 重发所有 optional 字段，其中一个 frozen string 有 exact diff。

断言：provider schema最好根本不暴露这些字段；旧兼容路径也必须 preflight `not_started`，WorkTask 不变。

### Fixture D：worker minimal settlement

输入：owner worker 只提交 expected revision、allowed status、result、evidence。

断言：通过确定性验证并成功结算；清除相同 WorkTask/action 的 unresolved ledger。

### Fixture E：reviewer verdict variations

覆盖：valid ALLOW/DENY、missing marker、multiple marker、JSON、code fence、reason too long、provider reasoning field、empty content、tool call。

断言：每一类产生 typed diagnostic，raw text 不持久化，late/duplicate generation 不能结算新调用。

### Fixture F：root deadline during delegated child wait

输入：root 在 deadline 前同步委派一个超时 child。

断言：根据选定 deadline 合同传播 cancel 或暂停预算；terminal 时间、cleanup 和 child 状态可预测；绝不在 832 秒后才笼统声称“600 秒 provider timeout”。

### Fixture G：typed error presentation

输入：automatic reviewer DENY、hard policy DENY、scheduler timeout、provider timeout、not-started rejection、unknown effect。

断言：headline、diagnostic、可用按钮和 recovery advice 分别正确。

## 16. 建议修复阶段与退出门禁

### Phase 0：冻结和基线

工作：

- 暂停新的 Cowork 工具/角色/权限功能扩展。
- 保存当前未提交工作树和失败会话的脱敏证据清单。
- 建立独立审计分支或明确的 patch stack；不要把多个边界继续混在一个大 patch 中。

退出条件：

- 工作树来源和每组修改的目的可追踪。
- 所有已知事故都有 regression fixture 编号。

### Phase 1：全仓只读 inventory

工作：

- 生成 Tool Surface、Role/Capability、Side-Effect、Wait/Cancellation、Permission、Error、Config 七张矩阵。
- 重新统计当前工作树中 mutating tools 和 replay policies。
- 标出 UNKNOWN，不在审计阶段顺手改代码。

退出条件：

- 每个 shipping tool 都有 owner、schema、effect boundary、cancel、settlement 和 test 记录。
- 不再依赖“应该只有这些工具”的人工记忆。

### Phase 2：角色化工具面

工作：

- 拆分 manager full update 与 worker-owned settlement。
- 收窄 spawn/profile/model 参数表达。
- 让 registry/context/schema 从 capability projection 生成。

退出条件：

- worker 无法在 provider schema 中表达被冻结的 WorkTask mutation。
- 真实事故 Fixture C/D 通过。

### Phase 3：权限路由重构

工作：

- 明确 mechanical allow、semantic ask、hard deny 三条路。
- reviewer parser 返回 typed diagnostics。
- 固定独立 reviewer route 并做真实模型矩阵。

退出条件：

- 内部确定性 settlement 不再依赖概率 reviewer。
- reviewer malformed 不再是不可诊断的单桶错误。

### Phase 4：副作用状态机

工作：

- 为每类 executor 建立 typed effect boundary。
- 先覆盖高频 Cowork control-plane tools，再覆盖文件、Git、terminal、browser、document/image 和 dynamic MCP。
- 统一 replay/reconcile disposition。

退出条件：

- 所有 mutating shipping tools 都有 first-effect proof 或明确 UNKNOWN policy。
- 不再用 tool 名单或字符串特判副作用。

### Phase 5：结构化并发与 deadline

工作：

- 选择 root deadline 语义。
- 让 scheduler/delegate/mailbox/permission/provider/tool wait cancellation-aware。
- 建立有界 cleanup 和 late-result fence。

退出条件：

- Fixture F 通过。
- parent/child/task/turn terminal ordering 有模型检查或系统级测试。

### Phase 6：typed error 与 UI recovery

工作：

- 贯通 runtime → EventLog → Projection → UI typed errors。
- 删除字符串推断。
- Retry/Resume/Reconcile 按 effect/retry disposition展示。

退出条件：

- Fixture G 全通过。
- 不再建议用户用“switch provider”修复本地 scheduler deadline。

### Phase 7：provider/live matrix

工作：

- 对 shipping provider route 跑 strict tool 和 reviewer contract smoke。
- 区分 opt-in 未运行、真实通过、provider 不支持。
- 记录日期、model/profile 和协议版本，但不持久化凭据或原始敏感输出。

退出条件：

- 至少一个主 route 和一个兼容 route通过真实 strict tool/reviewer smoke。
- 文档不再把 skipped smoke 写成已验证。

### Phase 8：稳定化 soak 与 release go/no-go

工作：

- 跑完整 suite、针对历史 hang 的子套件、事故 replay 和长时 Cowork soak。
- 统计每任务失败调用率、reviewer malformed 率、manual reconciliation 率、deadline overrun、平均纠正轮数。

退出条件：

- P0 全部关闭或有明确 release waiver。
- 没有新 unknown side-effect regression。
- 长时 soak 中 root deadline 和 child terminal 可预测。

## 17. 每个修复 patch 的强制规则

以后每一个 patch 必须遵守：

1. 先写能稳定失败的 regression；不能先改实现再补一个只证明新实现的测试。
2. 一个 patch 只修一个不变量或一个边界，不把 schema、权限、持久化、UI 和配置同时大改。
3. 把完整路径写进审查说明：model schema → wire → authorization → executor → EventLog → projection → UI。
4. 明确第一副作用点，禁止用错误消息字符串推断。
5. 明确 cancel/timeout owner 和 terminal ordering。
6. 明确缺失、非法、未知和兼容 fallback 的差异。
7. 不以关闭 reviewer、completion fuse、strict 或 reconciliation fence 作为快速修复。
8. 不以“这个模型通常听话”作为正确性证明。
9. focused tests 通过后，再跑相关 package suite、产品 build、事故 replay；需要 provider 事实时必须跑 opt-in real smoke。
10. 文档只记录实际运行的验证；skip 必须写 skip。
11. patch 必须经过一次独立的 invariant review，而不只是看 diff 是否编译。
12. 未解决的 UNKNOWN 必须进入风险登记，不能在交付摘要中消失。

## 18. 预期审计交付物

- [ ] `tool-surface-matrix.md/json`
- [ ] `role-capability-surface-matrix.md`
- [ ] `side-effect-boundary-matrix.md`
- [ ] `wait-cancellation-graph.md`
- [ ] `permission-routing-matrix.md`
- [ ] `typed-error-and-recovery-taxonomy.md`
- [ ] `config-binding-fallback-matrix.md`
- [ ] 脱敏事故 replay fixtures
- [ ] repository-wide strict schema invariant suite
- [ ] mutating-tool effect-boundary invariant suite
- [ ] deadline/cancellation system tests
- [ ] real-provider compatibility matrix
- [ ] P0/P1 风险登记与 release go/no-go 报告

## 19. 关键源码触点

后续审计至少覆盖以下触点；这不是修改授权，也不是穷举列表：

- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift`
- `Packages/IntatisAgentKernel/Sources/AuthorizationSidecar.swift`
- `Packages/IntatisAgentKernel/Sources/ContextBuilder.swift`
- `Packages/IntatisProviders/Sources/OpenAIToolCalling.swift`
- `Packages/IntatisCowork/Sources/Orchestrator.swift`
- `Packages/IntatisCowork/Sources/WorkTaskTools.swift`
- `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`
- `Packages/IntatisPermission/Sources/PermissionReviewTextVerdict.swift`
- `Packages/IntatisConversation/Sources/CodeProjection.swift`
- `Packages/IntatisSharedUI/Sources/CodeViews.swift`
- `Packages/IntatisConversation/Sources/RuntimeErrorPresentation.swift`
- `Apps/IntatisMac/Sources/AppConfig.swift`
- `Apps/IntatisMac/Sources/CoworkViewModel.swift`
- `Apps/IntatisMac/Sources/IntatisMacApp.swift`
- `Apps/intatis-cli/Sources/CLIConfig.swift`
- `Apps/intatis-cli/Sources/CLIProviderCatalog.swift`
- `Apps/intatis-cli/Sources/CLIInferenceProfiles.swift`
- `Apps/intatis-cli/Sources/Interactive.swift`
- `Packages/IntatisSkills/Resources/BundledSkills/cowork-agent-orchestration/SKILL.md`

## 20. 当前未提交工作树说明

写本文时，工作树中已经存在多组业务源码、测试和文档修改，主要包括：

- strict authorization sidecar 与递归 strict schema 修补；
- `tool_search_output` 延迟工具装饰；
- `task_create` owner/调用顺序合同；
- `task_create`/`task_update` 部分 pre-first-append no-effect proof；
- 独立 `permission_reviewer_model` 配置和 runtime 路由；
- 相应 focused tests 和文档同步。

本文没有修改、回退、暂存或提交这些既存改动，也没有把它们视为最终发布状态。它们仍需要：

- 按 patch 目的拆分和审查；
- 事故 replay 验证；
- 相关 package/full suite；
- macOS 产品构建；
- 必要的真实 provider smoke；
- config migration 和恢复场景验证。

## 21. 需要产品或架构明确决定的问题

### DEC-01 root deadline 语义

总 wall-clock，还是 delegated child wait 不计入？必须明确一种，并让 runtime/UI/test 一致。

### DEC-02 worker settlement API

是新增 `update_owned_work_task`，还是按 capability 投影同名 `task_update` 的不同 schema？推荐优先选择独立、最小工具以降低歧义。

### DEC-03 mechanical settlement 是否绕过 model reviewer

推荐：在 exact owner、revision、field set 和 transition 都可证明时 deterministic allow；真正外部/语义风险才 ask reviewer。

### DEC-04 reviewer diagnostic 的隐私边界

推荐持久化 parser failure category 和有限元数据，不持久化 raw reason、exact args 或用户文档内容。

### DEC-05 durable typed error schema

需要决定是否扩展现有 EventLog payload。任何 schema 改动必须保持旧日志可解码并先更新 protocol tests。

### DEC-06 unknown side effect 下的 UI 行为

推荐只显示 Reconcile/Inspect，不显示普通 Retry；not-started 才允许安全重试。

## 22. 当前 UNKNOWN 与审计边界

- UNKNOWN：当前工作树中所有 mutating shipping tools 的精确数量；旧盘点约为六十个静态工具，必须重新生成。
- UNKNOWN：当日 DeepSeek malformed reviewer text 的具体 parser 失败分支；raw output按设计未落盘。
- UNKNOWN：worker argument 中 literal backslash 最初由哪一层引入。
- UNKNOWN：仓库中所有 cancellation-unaware continuation/waiter 的完整数量。
- UNKNOWN：所有 shipping provider 对当前 strict tool schema 和 reviewer plain-text contract 的真实兼容状态。
- UNKNOWN：当前未提交修补在完整测试矩阵和长时 Cowork soak 下是否稳定。
- UNKNOWN：是否还有未被当前事故触发的 effect-boundary、config fallback、projection 或 replay 缺陷。

## 23. 建议的下一步

不要立即继续修最新截图中的单点。下一步应是：

1. 冻结新的 Cowork 功能性改动。
2. 对当前未提交工作树建立清晰 patch inventory。
3. 完成 Phase 1 只读全仓矩阵。
4. 先把本文七个事故 fixture 固化成 failing regressions。
5. 优先重构 worker-owned WorkTask settlement 和 parent/child cancellation 两个 P0 边界。
6. 再统一副作用 taxonomy 和 typed UI recovery。
7. 最后才恢复功能扩展。

判断是否“没有继续埋雷”的标准，不是这几张截图不再复现，而是上述不变量被程序化、历史事故可自动回放、每个 mutating tool 的副作用与取消边界都可以回答且有测试证明。

## 24. 本报告自身的检查记录

- `MODEL_CHECK_RESULT`：仓库内无法确认当前服务端精确模型名称；当前会话运行于 Codex。
- `PATH_CHECK_RESULT`：`pwd` 与 Git root 均为 `/Users/vita/Vitemis/Intatis`，匹配预期。
- `FILES_WRITTEN`：仅新增本报告。
- `PROJECT_AUDIT_SUMMARY`：基于 Cowork → AgentKernel → Permission → Tool executor → EventLog → Projection/UI 全链进行事故归档。
- `DOCS_CONTENT_SUMMARY`：本文记录已证实事故、系统性风险、只读审计矩阵、不变量、回放语料、阶段门禁和待决架构问题。
- `VALIDATION_RESULT`：见最终交付说明；本文不以此前的 focused tests 代替本轮文档检查。
- `UNCERTAINTIES`：集中列于第 22 节。
- `NEXT_RECOMMENDED_ACTION`：先完成 Phase 1 只读全仓审计，不自动继续修改业务源码。
