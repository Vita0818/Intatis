# Intatis Cowork 同 Session Per-Agent Inference Profile 调研报告

## MODEL_CHECK_RESULT

当前模型：GPT-5 系列 Codex；运行环境没有提供可核实的更细服务端型号。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者一致，符合预期仓库根目录。
- 报告创建前 `git status --short` 为空，没有需要避让的用户既有工作区改动。

## FILES_WRITTEN

- 新增：`codex-report/07_16_26-17_53-per-agent-inference-profile-research.md`
- 未修改 `Apps/`、`Packages/`、测试、构建配置、`NOTICE.md` 或 `docs/` 权威项目文档。

## 1. 结论先行

本轮修正后的结论是：

> Intatis 要建设的不是“同一 session 内不同 agent 使用不同 model ID”，而是“同一持久 Cowork session 内，每个 agent 固定绑定一个可版本化、可恢复、可审计、受权限约束的完整推理请求配置与路由”。

这个配置至少需要同时区分：

- 同一模型、不同 reasoning effort、thinking level 或 thinking budget；
- 同一模型、不同 temperature、verbosity、service tier、tool behavior 或其他 provider-specific options；
- 同一模型 ID、不同 provider connection、credential reference 或 endpoint；
- 同一 endpoint、不同网关路由、fallback 或上游选择参数；
- 不同 API surface、wire adapter、deployment 或 transport policy；
- 将来不同的请求 endpoint、协议适配器和模型能力集合。

因此，单独增加 `providerID + modelID`，或者把当前 variant 字段搬进 Agent，都不足以定义这个能力。更合适的核心抽象是版本化的 `InferenceProfileRef`，由它引用连接、模型和完整的非秘密请求语义。

公开先例呈现出清楚的分层：

1. **框架层已有成熟运行时先例。** OpenAI Agents SDK、AutoGen 和 Google ADK 都能让同一 workflow/team 中的不同 agent 持有独立模型对象、client、endpoint 和生成配置。
2. **产品层只有部分或接近先例。** OpenCode 最接近；Codex、Claude Code、Roo Code、Cline、Aider 各自覆盖了一部分。
3. **没有在本轮检查的公开一手资料中找到端到端完整先例。** 尚未找到一个成熟产品同时实现：用户可见的持久 agent roster、每 agent 完整请求 profile、多 endpoint/wire、精确恢复、权限/数据出境审查、配置版本冻结和无秘密审计。

所以这不是没有技术先例的功能，但 Intatis 要产品化的完整契约仍然跨得较大。准确的创新边界不是“第一个多模型多 agent”，而是：

> 把框架级的 per-agent model client/configuration，升级为本地持久 session 中的一等身份、路由、权限和恢复对象。

## 2. 问题定义与比较口径

### 2.1 Intatis 所说的“同一 session”

Intatis 的 Cowork session 具有比多数上游示例更强的语义：

- 一个持久 `SessionID`；
- 一个 append-only EventLog，负责审计与恢复；
- 一个可投影的 agent roster；
- 多个相同 headless AgentRuntime；
- scheduler、mailbox、Goal、WorkTask、ContinuationRun 和 AgentInvocation；
- CapabilityLease、WorkspaceLease、PermissionEngine 和 durable tool execution；
- App/CLI 重启后仍需解释和恢复同一 session。

上游项目使用的 “session” 并不完全同义：

- OpenAI Agents SDK 的 Session 主要保存共享对话历史；
- AutoGen 主要以 Team 和 agent container 表达一次协作运行；
- Google ADK 的 Session 保存 state/events；
- OpenCode 使用父子 session tree；
- Codex 使用 thread/agent tree。

本报告只把它们当作“同一顶层协作运行中存在多个 agent”的功能类比，不把术语相同误写成持久化语义相同。

### 2.2 本报告用五个维度判断完整度

| 维度 | 本报告要求 |
|---|---|
| 配置范围 | 不只 model ID，还包括 reasoning、variant、任意请求参数、endpoint/client/API surface |
| agent 所有权 | 配置属于具体 agent，而不是每轮临时读取全局当前选择 |
| 并发隔离 | 同一时刻两个 agent 的请求配置不能串扰或覆盖 |
| 持久恢复 | 重启后仍能恢复同一 profile revision，不能静默落到新默认值 |
| 权限与审计 | route/endpoint 是数据出境目标；绑定、变更和实际调用可审计但不泄露秘密 |

### 2.3 非目标

本报告不建议：

- 把工具能力、WorkspaceLease 或 PermissionProfile 合并进 inference profile；
- 让 AgentLoop 同步递归调用另一个 AgentLoop；
- 让模型在 `spawn_agent` 中直接输入任意 URL、Authorization header 或原始 JSON；
- 把 provider-specific reasoning 字段强行归一成一个通用四值枚举；
- 让 session 默认模型变成所有 agent 的动态指针；
- 通过隐式 fallback 在 profile 不可恢复时继续向另一个 endpoint 发送数据。

## 3. 调研范围、方法与固定版本

本轮只使用官方公开文档和官方公开仓库源码，没有使用私有 prompt、泄露材料、反编译内容、第三方品牌资产或非公开实现。

| 项目 | 固定版本 | 关注点 |
|---|---|---|
| OpenAI Agents SDK Python | [`697a46c`](https://github.com/openai/openai-agents-python/tree/697a46c4baa268d78d31c44244144967e57786b9) | per-agent Model/client/settings、Session 和 RunState 恢复 |
| OpenAI Codex | [`03bb3b1`](https://github.com/openai/codex/tree/03bb3b12367397e14a8facc2e018d645ff4d8e83) | child model/reasoning/service tier、role provider |
| Microsoft AutoGen | [`027ecf0`](https://github.com/microsoft/autogen/tree/027ecf0a379bcc1d09956d46d12d44a3ad9cee14) | per-agent ChatCompletionClient、Team state |
| Google ADK Python | [`221bad9`](https://github.com/google/adk-python/tree/221bad92b8ed659fc0d34c610d5b3bc469e0bac5) | per-agent BaseLlm/generation config、Session |
| OpenCode | [`1754480`](https://github.com/anomalyco/opencode/tree/17544802c38a4d35834275526ccf38be1cdcfbf4) | agent provider/model/variant/options、custom baseURL、child task |
| Cline | [`a41129a`](https://github.com/cline/cline/tree/a41129a5dbda29c4e6b84968a2a798039ba32ab3) | SDK model config、configured-agent inheritance |
| Roo Code Docs | [`a676c41`](https://github.com/RooCodeInc/Roo-Code-Docs/tree/a676c4173ae60348095efaebfd1292a9617622c0) | API Configuration Profile、child inheritance |
| Aider | [`5dc9490`](https://github.com/Aider-AI/aider/tree/5dc9490bb35f9729ef2c95d00a19ccd30c26339c) | architect/editor/weak model pipeline |
| Claude Code public repository | [`c39cb0f`](https://github.com/anthropics/claude-code/tree/c39cb0f14bfe8bb519bae5bfc55add6867c5e2ab) | public subagent model definitions和官方 workflow |

本报告的开源复用分类是 `reference`：

- 没有复制、逐行翻译、vendor 或依赖任何上游源码；
- 没有引入新 runtime 或第三方依赖；
- 因此本轮不需要修改 `NOTICE.md`；
- 如果后续实际复制实现或测试，仍必须重新执行文件级许可证、provenance、依赖和 NOTICE 审查。

## 4. 案例对照

| 案例 | per-agent model | per-agent reasoning/options | per-agent endpoint/client | exact revision 恢复 | 本报告定位 |
|---|---|---|---|---|---|
| OpenAI hosted multi-agent | 否 | 否 | 否 | 不适用 | 反例：共享一次请求配置 |
| OpenAI Agents SDK | 是 | 是 | 是 | 否 | 最强框架运行时先例 |
| AutoGen | 是 | 是 | 是 | 否 | 完整 client 组合先例 |
| Google ADK | 是 | 是 | 是 | 否 | 完整 model object/config 先例 |
| OpenCode | 是 | 是 | 通过 provider 间接支持 | 未冻结 | 最接近产品形态 |
| Codex | 是 | 部分 | 通过 role/provider 间接支持 | 未找到完整证据 | 部分产品先例 |
| Claude Code / Roo / Cline / Aider | 部分 | 部分或继承 | 多为全局/父级 | 未找到 | 辅助对照 |

### 4.1 OpenAI hosted multi-agent：明确反例

OpenAI 的 hosted Responses multi-agent 文档明确说明：root agent 和 hosted subagents 共享这次请求配置中的 model 与 tools。Hosted agent 不是每个都拥有独立 client/config 的本地 Agent 对象。

来源：[OpenAI hosted multi-agent 官方文档](https://developers.openai.com/api/docs/guides/responses-multi-agent)。

这意味着不能笼统地说“OpenAI multi-agent 已经支持每 agent 独立模型”。必须区分：

- **hosted multi-agent**：共享请求 model/tools，不满足 Intatis；
- **client-side Agents SDK**：每 Agent 可有完整 Model/client/settings，满足运行时差异化。

### 4.2 OpenAI Agents SDK：最强的完整运行时先例

Agents SDK 的 `Agent` 自身拥有：

- `model: str | Model | None`；
- `model_settings`。

来源：[Agent 定义](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/agent.py#L305-L320)。

如果 Agent 绑定具体 Model 实例，该 Model 又可以绑定独立的 `AsyncOpenAI` client，因此每个 Agent 可以改变：

- model ID；
- Responses 或 Chat Completions API surface；
- base URL；
- API credential/client；
- transport；
- agent-specific request settings。

官方示例直接把自定义 `base_url` client 包入一个 Agent 的 `OpenAIChatCompletionsModel`：

- [自定义 endpoint 示例](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/examples/model_providers/custom_example_agent.py#L17-L50)
- [Chat Completions Model 保存独立 client](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/models/openai_chatcompletions.py#L51-L70)

SDK 的 RunState 测试还直接构造了两个绑定不同 FakeModel 和 settings 的 agent，并在 handoff 后暂停、恢复到第二个 agent：

- [不同 agent/model 的 handoff 与恢复测试](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/tests/test_run_state.py#L610-L677)

`ModelSettings` 的范围也远超“模型 + 思考强度”，包括：

- temperature、top_p、frequency/presence penalties；
- tool choice、parallel tool calls；
- max tokens；
- reasoning、verbosity；
- store、metadata、cache/context management；
- extra query/body/headers；
- provider-specific `extra_args`。

来源：[ModelSettings](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/model_settings.py#L86-L200)。

但它有两个对 Intatis 很重要的限制。

第一，run-level override 可以压过 agent：

1. `RunConfig.model` concrete Model；
2. `RunConfig.model` 字符串，由 run provider 解析；
3. agent concrete Model；
4. agent model 字符串，由 run provider 解析。

run-level 非空 `model_settings` 也会覆盖 agent 对应字段。

来源：

- [turn preparation](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/run_internal/turn_preparation.py#L134-L167)
- [RunConfig](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/run_config.py#L211-L226)

Intatis 不应让普通 session-wide UI selection 或 registry refresh 拥有这种无声覆盖权。

第二，Session/RunState 没有持久化完整 agent 配置。Agents SDK 支持多个 agent 使用同一 Session 历史，但 RunState 序列化当前 agent 时主要保存 name/identity；恢复时调用方必须重新提供完整 initial Agent graph，再从中解析引用。

来源：

- [多个 agent 共用 Session](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/docs/sessions/index.md#L553-L571)
- [RunState agent identity 序列化](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/run_state.py#L707-L725)
- [RunState 恢复依赖 initial Agent graph](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/run_state.py#L2398-L2435)

结论：这是成熟的运行时组合先例，不是跨重启固定 profile 的完整产品先例。

### 4.3 AutoGen：每 agent 完整 client，但状态不冻结 client blueprint

AutoGen 的 `AssistantAgent` 持有完整 `ChatCompletionClient`，不是只保存 model 字符串。Team participant 可以各自构造和序列化 agent/client 组件配置。

来源：

- [AssistantAgent](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/agents/_assistant_agent.py)
- [RoundRobinGroupChat](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_round_robin_group_chat.py)

其 OpenAI client 配置覆盖：

- model；
- base URL；
- Azure endpoint/deployment/API version；
- headers、retry；
- reasoning effort、temperature、top_p、max tokens；
- 每次调用的 extra create args。

来源：

- [OpenAI client config](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-ext/src/autogen_ext/models/openai/config/__init__.py)
- [runtime client](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-ext/src/autogen_ext/models/openai/_openai_client.py)

同一 Team 中各 agent 还拥有独立 model context：

- [ChatAgentContainer](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_chat_agent_container.py)

但 Team 的 `save_state()` 主要保存 agent context、buffer、manager 和 turn state。调用方仍需先按当前代码/config 重建 Team，再 load state。endpoint、model 或 reasoning 已变化时，旧上下文可能在新 client 下继续。

来源：[BaseGroupChat state](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_base_group_chat.py)。

结论：证明 per-agent full client/config 可组合，未解决 Intatis 所需的 revision-stable recovery。

### 4.4 Google ADK：每 LlmAgent 独立 model/config，Session 不保存 agent graph

Google ADK 的每个 `LlmAgent` 都可以拥有：

- `model: str | BaseLlm`；
- 独立 `generate_content_config`。

未显式配置时才从父 agent 继承。

来源：[LlmAgent](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/agents/llm_agent.py)。

每次调用会从当前 `invocation_context.agent` 取得 canonical model，并深拷贝该 agent 的 generation config：

- [request construction](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/flows/llm_flows/basic.py)
- [runtime dispatch](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/flows/llm_flows/base_llm_flow.py)

Gemini BaseLlm 可携带 base URL/client kwargs；LiteLlm 可携带 provider/model、`api_base`、自定义 provider/client 和任意 kwargs：

- [Gemini model](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/models/google_llm.py)
- [LiteLlm](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/models/lite_llm.py)

但 ADK Session 只保存 id、state、events 和更新时间，不保存 root agent graph、BaseLlm、endpoint、请求配置或 credential ref：

- [Session](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/sessions/session.py)

结论：同样是强运行时先例、弱配置恢复先例。

### 4.5 OpenCode：最接近产品形态的案例

OpenCode 的 Agent 信息原生包含：

- `providerID`；
- `modelID`；
- `variant`；
- arbitrary options。

来源：

- [Agent 数据结构与配置解析](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/opencode/src/agent/agent.ts)
- [Agent 文档](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/web/src/content/docs/agents.mdx)

请求参数大致按以下层次合并：

```text
provider defaults
  -> model options
  -> agent options
  -> selected variant
```

来源：[请求参数合并](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/opencode/src/session/llm/request.ts)。

自定义 provider 支持任意 provider ID 和 baseURL，因此可以：

- 定义两个不同 provider connection；
- 让它们使用相同 model ID；
- 把两个 agent 绑定到不同 provider；
- 最终请求不同 endpoint。

来源：[自定义 provider 与 baseURL](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/web/src/content/docs/providers.mdx)。

这使 OpenCode 成为本轮找到的最接近真实产品先例。

但仍有关键差距：

- baseURL 属于可变 provider registry，不是 agent 内不可变的 endpoint snapshot；
- child task 创建和恢复会从当前 config/parent 重新计算 effective model/profile；
- 没有看到 agent 对 profile revision 的一等持久绑定；
- 没有看到 endpoint/trust-domain 变化进入精确的数据出境授权。

来源：[Child task 模型继承与恢复](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/opencode/src/tool/task.ts)。

### 4.6 Codex：per-child model/reasoning/provider 已部分成立

当前 Codex 的 spawn 已暴露：

- model；
- reasoning effort；
- service tier。

但 full-history fork 明确禁止 agent type/model/reasoning override；fresh 或 partial fork 才允许。

来源：[multi-agent V2 spawn](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs)。

Codex role 文件会被解析为完整 `ConfigToml` layer，而不是只有 role prompt：

- [agent role config parsing](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/core/src/config/agent_roles.rs#L191-L263)

如果 role 显式设置 `model_provider`，它会替换父 agent provider；没有设置才保留当前 provider：

- [role provider/model/reasoning overlay](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/core/src/agent/role.rs#L32-L81)

测试验证了 child role 同时得到不同 model、provider 和 reasoning：

- [multi-agent role override test](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/core/src/tools/handlers/multi_agents_tests.rs#L995-L1050)

Codex provider definition 本身包含 base URL、env credential、query params、headers、retry/timeout，因此切 provider 可合理推导为切换已注册 endpoint：

- [model provider info](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/model-provider-info/src/lib.rs#L86-L106)

需要严格区分证据强度：

- **已证实**：per-child model、reasoning、service tier，以及 role 驱动 provider 切换；
- **合理推导**：若该 provider 注册了不同 baseURL，请求将去不同 endpoint；
- **尚未找到一等支持**：spawn 时直接选择任意完整请求 profile、variant、transport、credential ref；
- **尚未找到可靠证据**：重启后按 child 的精确 profile revision 恢复且拒绝静默 fallback。

### 4.7 Claude Code、Roo Code、Cline、Aider：各自只覆盖一部分

#### Claude Code

公开资料证明 subagent 可选择不同 model，官方 code-review workflow 也真实混用不同模型级别：

- [公开 subagent model 定义](https://github.com/anthropics/claude-code/blob/c39cb0f14bfe8bb519bae5bfc55add6867c5e2ab/plugins/plugin-dev/skills/agent-development/SKILL.md)
- [官方混合模型 code-review workflow](https://github.com/anthropics/claude-code/blob/c39cb0f14bfe8bb519bae5bfc55add6867c5e2ab/plugins/code-review/commands/code-review.md)

但 thinking/effort 主要继承 session，`ANTHROPIC_BASE_URL` 等上游设置属于进程/session 环境。公开核心源码不足以证明每 agent 独立 endpoint/options。

#### Roo Code

Roo 的 API Configuration Profile 是完整请求配置，并具有 task-sticky 语义；但 Orchestrator child task 明确继承父 profile，不是不同 mode 自动选择不同 profile：

- [API Configuration Profiles 与 child inheritance](https://github.com/RooCodeInc/Roo-Code-Docs/blob/a676c4173ae60348095efaebfd1292a9617622c0/docs/features/api-configuration-profiles.mdx)

#### Cline

Cline SDK 的完整 CoreModelConfig 可包含 provider、model、base URL、headers、thinking/reasoning 和预算；但 built-in configured-agent 只定义 provider/model，其余字段由父配置整体 spread 后局部覆盖：

- [CoreModelConfig](https://github.com/cline/cline/blob/a41129a5dbda29c4e6b84968a2a798039ba32ab3/sdk/packages/core/src/types/config.ts)
- [configured-agent config](https://github.com/cline/cline/blob/a41129a5dbda29c4e6b84968a2a798039ba32ab3/sdk/packages/core/src/extensions/tools/team/configured-agent-config.ts)
- [父配置继承后局部覆盖](https://github.com/cline/cline/blob/a41129a5dbda29c4e6b84968a2a798039ba32ab3/sdk/packages/core/src/extensions/tools/team/configured-agent-tool.ts)

这种“复制父配置，再只换 provider/model”的方式，如果下游没有再次按新 provider 归一化或过滤，可能把旧 provider 的 headers/options 带入新请求；本报告没有验证 Cline 最终 wire body 是否会清洗这些字段。Intatis 不应采用这种依赖下游补救的继承方式。

#### Aider

Aider 的 Architect、Editor 和 Weak model 可以是不同模型，构成同一工作流中的真实多模型流水线：

- [Architect/Editor 双模型流程](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/architect_coder.py)

但这些是固定流水线角色，不是持久 agent；reasoning 与 base URL 仍偏向 main/global 配置：

- [CLI reasoning/baseURL](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/main.py)

## 5. 能力先例与产品创新边界

可以把现有案例按三层理解。

### 5.1 已经成熟的部分

- 每个 agent 持有不同 model object；
- 每个 model object 持有不同 client/base URL/credential；
- 每个 agent 拥有独立 generation settings；
- handoff/team runtime 在不同 agent 之间切换对应配置；
- 同一 workflow 中并发或顺序使用多个 provider/model。

OpenAI Agents SDK、AutoGen 和 Google ADK 已充分证明这些机制可行。

### 5.2 产品中已经部分出现的部分

- OpenCode 的 provider/model/variant/options；
- Codex 的 child model/reasoning/service tier 和 role provider；
- Claude Code 的 subagent model；
- Roo 的 task-sticky API Profile；
- Aider 的多模型 pipeline。

### 5.3 本轮没有找到完整先例的部分

- 一个用户可见且持久的 session roster；
- roster 中每个 agent 绑定精确 profile revision；
- 同 model ID 可经不同 endpoint/credential/API surface；
- global config 变化不影响已有 agent；
- restart/replay 后不静默漂移；
- endpoint/profile 进入 CapabilityLease 或等价授权；
- permission target/fingerprint 包含 route/profile；
- 事件和统计记录安全的 profile identity；
- credential rotation 不改变 route identity；
- gateway fallback/actual upstream 有清楚的可观测语义；
- profile mismatch 时 fail closed。

因此，报告只能说“本轮没有找到”，不能绝对断言市场上不存在未公开实现或未纳入样本的产品。

## 6. Intatis 当前实现审计

### 6.1 已有基础

Intatis 已经具备构建该能力的大部分底层零件。

#### ProviderEndpoint 已表达连接和 model-scoped options

`Packages/IntatisProviders/Sources/Endpoints.swift:77` 的 `ProviderEndpoint` 包含：

- id；
- baseURL；
- chatEndpoint；
- apiKeyRef；
- wire；
- `modelRequestOptions`。

`ModelRef` 在同文件约第 179 行包含 endpoint + model。

这说明 Intatis 已能在 provider catalog 中定义多个 endpoint，并按 model 携带任意 JSON 请求参数。

但目前 shipped `WireFormat` 只有 `.openai`。Anthropic/Gemini 仍只是扩展点，不能把“配置可解析”写成“线协议已支持”。

#### ProviderRegistry 能按 ModelRef 解析 provider

`Packages/IntatisProviders/Sources/ProviderRegistry.swift:96` 的 `agentProvider(for:)` 已能：

- 根据 endpoint ID 查 ProviderEndpoint；
- 懒加载 secret；
- 根据 wire 构造 provider。

所以底层 resolver 已有按 endpoint + model 工作的基础，问题主要在 Cowork 没有把 agent 的完整 binding 传到它。

#### AgentRequest 已表达一部分生成配置

`Packages/IntatisProviders/Sources/ToolCalling.swift:65` 的 `AgentRequest` 包含：

- model；
- messages；
- tools；
- temperature；
- reasoningEffort；
- includeUsage；
- maxOutputTokens。

#### wire adapter 已有明确合并边界

`Packages/IntatisProviders/Sources/OpenAIToolCalling.swift:304` 从 endpoint model options 开始构造请求，再写入 runtime model/messages/tools/stream/reasoning/max tokens。

`Packages/IntatisProviders/Sources/OpenAIWireProvider.swift:180` 会先移除 options 中的 model/messages/tools/stream，避免任意配置覆盖结构字段。

这套机制适合继续保留，只需把“从哪个 endpoint 和哪组 effective options 开始”改为 agent-owned profile resolution。

#### AppConfig 已支持 opaque options 和 variants

`Apps/IntatisMac/Sources/AppConfig.swift:648` 当前会：

1. 读取 model base requestOptions；
2. 只对全局当前 selected provider/model；
3. 浅合并 selected variant options。

这证明现有 variant 已经是“同一真实 model 的命名请求参数预设”，可作为未来 inference profile 的输入，而不应被改写成另一个 model ID。

### 6.2 当前全局耦合与缺口

| 缺口 | 当前证据 | 后果 |
|---|---|---|
| Agent 只拥有 ModelID | `Packages/IntatisAgentKernel/Sources/Agent.swift:8-23` | 无法表达 endpoint、variant、reasoning revision |
| Cowork provider resolver 忽略 agent | `Apps/IntatisMac/Sources/CoworkViewModel.swift:211-215` | 所有 agent 实际使用同一 session default provider |
| 显式 reasoning 是 Orchestrator/AgentRuntime 级 | `Packages/IntatisCowork/Sources/Orchestrator.swift:301`、`:4601-4605` | 同一 endpoint/model 的不同 agent 无法拥有独立 thinking 设置；session-wide 显式 reasoningEffort 还会统一覆盖对应请求字段 |
| variant 依赖全局 selected catalog | `Apps/IntatisMac/Sources/AppConfig.swift:648-658` | 同模型不同 variant 无法同时存在 |
| registry 可热更新给 active VM | `Apps/IntatisMac/Sources/CoworkViewModel.swift:198-199`、`Apps/IntatisMac/Sources/IntatisMacRootView.swift:129-131` | 全局配置变化可能改变未来请求 |
| attach/spawn 事件主要记录 model | `Packages/IntatisProtocol/Sources/CoworkEvents.swift:75-158` | replay 无法恢复 endpoint/options revision |
| spawn 工具只接受可选 raw model | `Packages/IntatisCowork/Sources/CoordinatorTools.swift:15-31` | 模型身份过窄，也没有 route/egress identity |
| TurnStats 只记录 model 字符串 | `Packages/IntatisProtocol/Sources/TurnStats.swift:15` | 成本、延迟和失败无法按 profile/connection 归因 |

### 6.3 当前 `profile` 已经有其他明确含义

需要特别防止术语碰撞：

- `Agent.profile` 是 `PermissionProfile`；
- `CoworkProjectSettings.defaultProfile` 也是默认 PermissionProfile；
- Agent attach event 中的 `profile: String` 保存权限 profile；
- BrowserTools 还有 persistent browser profile。

因此新字段不能继续叫泛化的 `profile`。建议所有新类型和事件字段都显式使用：

- `inferenceProfileID`；
- `inferenceProfileRevision`；
- `inferenceConnectionID`；
- `agentInferenceBinding`。

权限继续使用 `permissionProfile`，浏览器继续使用 `browserProfile`。

### 6.4 当前 session 设置不是 agent-local 设置

`Apps/IntatisMac/Sources/CoworkProjectSettings.swift:27-49` 当前保存：

- session default provider ID；
- session default model ID；
- default permission profile；
- token budget。

Composer 中出现 provider/model 菜单，只证明用户能改变 session 当前选择或默认值，不代表 roster 中每个 agent 有独立 picker。

`docs/CURRENT_STATE.md` 也明确把每 agent 独立 provider/model 配置列为未完成能力。

## 7. 建议的数据模型

### 7.1 不把所有东西塞进 Agent

建议拆成四层。

```text
InferenceConnectionDefinition
  connectionID
  wireAdapter / API surface
  baseURL / chatEndpoint / deployment
  credentialRef
  transport policy
  trust domain / egress classification

InferenceProfileDefinition
  profileID
  revision
  connectionID
  modelID
  optional variantID
  non-secret provider options
  reasoning / thinking configuration
  routing / fallback semantics
  declared model capabilities

AgentInferenceBinding
  inferenceProfileID
  exact revision
  safe identity fingerprint

ResolvedInferenceProfile
  resolved connection snapshot
  concrete ToolCallingProvider
  modelID
  effective non-secret request options
  host capability/compatibility result
```

### 7.2 为什么连接和 profile 要分开

Provider vendor、请求连接和实际物理上游不是同一概念。

例如：

- 同一家 provider 可以有两个 baseURL、两个部署或两组凭据；
- 一个 OpenRouter/企业 gateway endpoint 可以路由多个实际上游；
- 同一 endpoint 可以通过不同 body/query 参数选择路由；
- 相同 model ID 可以出现在两个不同连接。

因此建议使用 `InferenceConnectionID` 表示 Intatis 可以保证的请求目的地和协议边界，不使用含义模糊的 provider vendor 名称作为安全身份。

如果 gateway 内部重新路由，Intatis通常只能证明：

- 请求发往哪个 connection/endpoint；
- 发送了哪些安全可记录的 routing options；
- provider 响应报告了什么实际 model/upstream metadata。

除非有可信 attestation，不能声称知道 gateway 背后的物理上游。

### 7.3 reasoning 不应只有一个通用枚举

当前 `ReasoningEffort` 只有 minimal/low/medium/high，无法完整表达：

- xhigh、max；
- nested `reasoning.effort`；
- `thinking.level`；
- token-based thinking budget；
- provider-specific adaptive thinking；
- 同时存在的 verbosity 或 service tier。

建议保留两层：

1. 可选的 typed presentation，用于 UI 显示和兼容性提示；
2. 原始、非秘密、provider-specific request options，作为线请求事实。

UI 可以识别常见键，但不能改写或猜测未选择的 variant。

### 7.4 profile definition、agent binding、runtime resolution 必须分层

这三层不能混成一个可变对象：

- catalog/profile definition 是可管理配置；
- AgentInferenceBinding 是 session 内持久身份；
- ResolvedInferenceProfile 是单次调用的运行时对象，包含懒加载 credential 后的 provider。

AgentLoop 应拿到一个原子 resolved bundle，而不是分别调用：

```text
providerFor(agent)
agent.model
sessionReasoningEffort
globalVariantOptions
```

否则 provider、model 和 options 仍可能来自不同 revision。

## 8. 配置合并与宿主强制字段

### 8.1 建议的 profile 构造优先级

在创建一个不可变 profile revision 时，建议按以下顺序解析：

```text
connection defaults
  -> model base options
  -> named variant options
  -> explicit inference profile overrides
```

解析结果成为该 profile revision 的有效非秘密配置。之后全局 catalog 当前选择变化不应改变它。

### 8.2 每次调用时的优先级

单次请求应按以下顺序构造：

```text
resolved profile effective options
  -> narrow host invocation values
  -> budget/capability clamps
  -> runtime-owned structural fields written last
```

宿主最终拥有或限制：

- resolved model ID；
- messages；
- tools；
- stream；
- includeUsage；
- output token ceiling；
- timeout/cancel；
- permission/capability-derived tool surface；
- protocol-required fields。

任意 profile options 不能覆盖：

- Authorization/credential；
- messages；
- tool schemas；
- stream；
- permission decisions；
- WorkspaceLease 或 CapabilityLease；
- host output/budget ceiling。

### 8.3 MVP 不允许动态 task/agent raw overrides

第一阶段不建议暴露：

- 每 task 原始 JSON override；
- 模型生成的 endpoint；
- 模型生成的 headers/query；
- 任意 fallback chain。

模型可见的 `spawn_agent` 最多接受一个宿主批准的 `inference_profile_id`。省略时应完整继承父 AgentInferenceBinding，而不是分别继承 model、provider 和 reasoning。

## 9. Session 固定、恢复与配置漂移

### 9.1 session default 只能是创建模板

建议把 Cowork 设置中的默认值演进为：

```text
defaultInferenceProfileRef
```

它只用于：

- 创建 fresh main；
- 创建未显式选择 profile 的新 agent；
- 用户明确执行 rebind。

它不能在请求时动态决定所有现有 agent 的 provider/model/options。

### 9.2 创建 agent

创建时：

1. 宿主解析 profile ID；
2. 校验 revision、连接、能力和允许的 route；
3. 生成安全 target fingerprint；
4. 完成 spawn/attach 权限审查；
5. durable 写入 agent + exact AgentInferenceBinding；
6. scheduler 才能运行该 agent。

省略 profile 时，child 精确继承父 binding，包括 revision，而不是重新读取当前 session default。

### 9.3 修改 profile

profile 变化应是显式控制面动作，例如：

```text
agent_inference_rebind_requested
agent_inference_rebound
agent_inference_rebind_failed
```

是否需要独立事件名仍需结合 Event/EventLog schema RFC 决定，但必须满足：

- additive optional 演进；
- 旧 JSONL 继续解码；
- approved target 与执行 target revalidation；
- 正在执行的 AgentInvocation 不被中途换 route；
- change 只对安全边界后的下一次 invocation 生效。

### 9.4 global catalog 更新

Chat 菜单切换、config 文件刷新或 ProviderRegistry 重建：

- 可以改变新 agent 的默认 profile；
- 可以新增 profile revision；
- 不能偷偷改变 existing agent binding；
- 不能让旧 agent 指向同 ID 的新定义。

如果 profile ID 不变而定义变化，必须生成新 revision，或拒绝加载这种破坏不可变性的修改。

### 9.5 credential rotation

credential value 与 route identity 应分开：

- Agent/EventLog 只持有 profile/connection identity；
- credential 继续按 ref 懒加载；
- secret value 轮换通常不要求 agent rebind；
- credentialRef、endpoint、wire 或 routing policy 改变则应产生新 connection/profile revision。

### 9.6 重启恢复

恢复时：

1. 从 EventLog/projection 得到 AgentInferenceBinding；
2. 在 versioned profile store 或 session-safe snapshot 中解析 exact revision；
3. 验证 connection/profile revision 和能力；
4. 再恢复 scheduler data plane。

如果 revision：

- 不存在；
- 内容不匹配；
- 指向未知 wire；
- credential ref 无法安全解析；
- 模型能力与工具面不兼容；

则 agent 应进入类似 `configurationUnresolved` 状态，禁止 provider 调用，等待用户显式 rebind。

不得回退到：

- 当前全局默认；
- 当前 session default；
- 父 agent 当前 profile；
- 同 model ID 的任意另一个 endpoint。

### 9.7 versioned profile 的存储未决

要实现精确恢复，必须选择至少一种策略：

1. 保留不可变的 versioned profile catalog，旧 revision 不被覆盖；或
2. 在 session 范围保存经过安全校验的非秘密 profile snapshot。

当前任意 model options 可能包含敏感扩展值，不能直接把完整 options 复制进 EventLog。正式 RFC 必须先定义：

- 哪些字段允许 durable；
- 哪些字段只能是 secret reference；
- profile store 的生命周期；
- revision canonicalization；
- 私有 endpoint/path 的安全展示和日志规则。

在这项设计完成前，不应假装 `profileID + hash(current config)` 已能可靠恢复。

### 9.8 legacy session

旧事件只有 model/permission profile，无法证明历史请求使用的精确 endpoint、variant 或 options。

兼容策略应：

- 保持旧事件可解码；
- 将缺失 inference binding 明确标为 legacy；
- 如果无法从 session 固定数据无歧义恢复，就进入 legacy/unresolved；
- 由用户显式确认一次性 rebind；
- 不把当前默认值伪装成历史精确事实。

### 9.9 provider-native conversation handle

未来若支持 `previous_response_id`、conversation ID、live session、reasoning cache 等上游状态：

- 至少按 `(agentID, inferenceProfileRevision)` 隔离；
- endpoint/API surface/profile 改变时必须失效；
- 不得把一个 Intatis session 共用一个上游 handle；
- Intatis EventLog/ContextProjection 继续是 canonical history。

## 10. 权限、数据出境与秘密边界

### 10.1 endpoint 变化是数据出境变化

把同一 workspace context 发往：

- 本地 Ollama；
- OpenAI direct；
- OpenRouter；
- 企业 gateway；
- 用户自定义公网 endpoint；

不是单纯 UI 模型偏好，而是不同的信任域和数据接收方。

因此建议新增 `InferenceRouteLease`，或在现有 CapabilityLease 中表达允许的 inference profile/connection IDs。

### 10.2 spawn/delegate 的精确目标必须扩大

当前 delegation/spawn 权限目标已经包含 model 身份。未来必须纳入：

- inference profile ID + revision；
- connection ID；
- model ID；
- safe route/trust label；
- capability compatibility；
- 是否发生跨 trust-domain 变化。

审批后、实际调用前还要 revalidate exact fingerprint，防止：

- catalog 在审批后更新；
- profile ID 被原地改写；
- endpoint 被替换；
- variant/options 被改变；
- provider fallback 指向未审批 route。

### 10.3 模型不能创建任意 route

模型面对的 API 应是：

```text
spawn_agent(name, folder, inference_profile_id?)
```

而不是：

```text
spawn_agent(base_url, api_key, headers, raw_options, ...)
```

可选 profile 列表由宿主根据：

- 用户配置；
- InferenceRouteLease；
- agent coordinator capability；
- workspace/data classification；
- model/tool capability；

确定性生成。

### 10.4 secrets 和日志

以下内容不得进入 EventLog、permission reviewer prompt、TurnStats 或普通报告：

- API key；
- Authorization header；
- secret file 内容；
- resolved credential；
- 可能含秘密的 raw extra headers/body/query；
- 完整私有配置响应。

EventLog 只记录：

- profile ID/revision；
- connection ID；
- model ID；
- variant ID；
- safe tuning summary；
- safe route/trust label；
- provider 返回的安全 usage/actual model metadata。

不要对含秘密的 raw options 做普通 fingerprint 后写入日志，因为低熵 secret 或结构仍可能泄漏。应优先使用显式 immutable revision，或只对规范化的非秘密子集计算 fingerprint。

### 10.5 fallback 必须显式

跨 provider/endpoint fallback 会改变数据接收方。第一阶段建议：

- 不允许隐式跨 connection fallback；
- connection 内 retry 可以保留；
- 同一 profile 的 gateway 内 routing 语义必须明确；
- 若将来允许 fallback chain，它本身属于 profile identity 和授权目标。

### 10.6 控制面模型单独处理

`@permission-reviewer` 和 GoalVerifierControlPlane 是保留的 no-tools 控制面，不是普通 worker。

它们可以有独立 provider/profile，但应使用单独的宿主配置：

```text
ControlPlaneInferenceBindings
```

不应：

- 出现在普通 worker picker；
- 被普通 agent message/delegate/rebind；
- 继承 worker 的 InferenceRouteLease；
- 占普通 scheduler slot；
- 因 worker profile 切换而改变。

## 11. 建议的分阶段落地

### Phase 0：先写设计 RFC

在修改业务源码前锁定：

- 类型与命名；
- profile store/version retention；
- session snapshot；
- merge precedence；
- safe logging schema；
- route lease/permission target；
- legacy migration；
- control-plane profile；
- provider-native handle invalidation。

### Phase 1：协议和持久身份，不改变 provider 能力

- 增加 additive optional inference binding 字段；
- 保持旧 JSONL 解码；
- 建立 immutable profile revision；
- main/new agent 绑定 session default profile；
- recovery mismatch fail closed；
- 仍只支持当前 OpenAI-compatible wire。

### Phase 2：per-agent runtime resolution

- Orchestrator provider closure真正按 agent binding 解析；
- AgentLoop 接收原子 ResolvedInferenceProfile；
- reasoning/options 从 profile 获取；
- 移除 Cowork session-wide reasoning 对 agent 请求的无声覆盖；
- 确保并发请求不共享可变 options。

### Phase 3：spawn/rebind/UI

- `spawn_agent` 使用 approved `inference_profile_id`；
- 省略时精确继承父 binding；
- project settings 使用 defaultInferenceProfileRef；
- roster 显示安全 profile label；
- rebind 是显式 durable control-plane action；
- permission preview 显示安全 route/profile 摘要。

### Phase 4：更多 wire/API surface

- 在 profile/capability 模型稳定后增加 Anthropic、Gemini 或 Responses adapter；
- attach/spawn 时做 tool calling、vision、context、streaming 能力检查；
- provider 差异不能绕过 PermissionEngine、EventLog 或 tool execution durability；
- 非 Swift runtime 不隐式进入 iOS target。

## 12. 必需测试矩阵

### 12.1 配置身份和并发

1. 同 connection、同 model，agent A 使用 low，agent B 使用 high，并发请求 body 精确不同且不串扰。
2. 同 model ID，经两个 connection/endpoint/credential ref 请求。
3. 同 endpoint/model，不同 named variant/options。
4. 同 gateway endpoint，不同显式 routing options。
5. 不同 wire/API surface 的 capability validation。
6. profile options 不能覆盖 model/messages/tools/stream/Authorization。

### 12.2 创建、继承与变更

7. child 未指定 profile 时完整继承 parent ID + revision。
8. child 显式选择已授权 profile，不修改 parent/sibling。
9. 未授权 profile 在 spawn admission 前拒绝。
10. rebind 只影响边界后的下一 invocation，不修改 in-flight request。
11. global catalog/default/Chat variant 改动不改变已有 agents。
12. 同 profile ID 内容原地变化被拒绝或形成新 revision。

### 12.3 恢复

13. 重启/replay 恢复相同 profile revision。
14. profile revision 缺失时 configurationUnresolved，不向默认 endpoint 发请求。
15. legacy model-only JSONL 继续解码，并清楚标记 legacy/unresolved。
16. credential value rotation 在 ref 不变时可恢复，不把 secret 写入事件。
17. endpoint/profile 改变后 provider-native conversation handle 被清除。
18. crash recovery 不把旧 invocation 在新 profile 下重放。

### 12.4 权限和安全

19. permission target/fingerprint 包含 profile revision + connection trust identity。
20. 审批后 catalog/profile mutation 会在执行前 revalidation 失败。
21. 模型不能通过 raw tool args 注入 endpoint/header/credential。
22. EventLog、review prompt、stats、error 不包含 secret/raw sensitive options。
23. 跨 trust-domain rebind 需要明确审批，deny 后不 fallback。
24. reviewer/verifier profile 不出现在普通 worker 可选列表。

### 12.5 观测、成本与限流

25. usage、成本、TTFT、失败按 agent + profile revision + connection 归因。
26. 如果 provider 返回 actual model/upstream metadata，安全地与 requested profile 分开记录。
27. 同 connection 的 rate limit/retry 不污染另一 connection。
28. profile capability 不支持 tool calling 时在 provider 请求前拒绝。

### 12.6 GUI/CLI

29. roster 能区分相同 model ID 的不同 profile label。
30. GUI/CLI restart 后显示相同 binding，而不是当前全局模型。
31. 修改 session default 只影响后续新 agent。
32. unresolved/rebind 状态可见且 composer/scheduler 行为明确。

## 13. 编码前必须决定的未决问题

| 问题 | 建议默认值 |
|---|---|
| profile revision 存储在哪里 | versioned immutable store 或 session-safe snapshot；不能只引用当前 mutable config |
| arbitrary options 是否可持久化 | 只允许明确的非秘密子集；秘密必须改为 ref |
| task 是否可临时 override profile | MVP 不允许 |
| 现有 agent 何时可 rebind | idle/safe checkpoint 后，显式 durable action |
| profile 不可用时是否 fallback | 不 fallback，configurationUnresolved |
| gateway fallback 如何表达 | profile identity 的显式组成部分 |
| reviewer/verifier 是否使用独立 profile | 可以，但使用保留 control-plane bindings |
| endpoint URL 是否写 EventLog | 默认只写 connection ID 和 safe label |
| credential rotation 是否 bump revision | secret value rotation不 bump；ref/route变化 bump |
| legacy session 如何迁移 | 保持解码，无法证明时用户显式 rebind |

## 14. 证据索引

### OpenAI

- [Hosted multi-agent 官方文档](https://developers.openai.com/api/docs/guides/responses-multi-agent)
- [Agents SDK Agent](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/agent.py)
- [Agents SDK ModelSettings](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/model_settings.py)
- [Agents SDK custom model provider](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/examples/model_providers/custom_example_agent.py)
- [Agents SDK RunState](https://github.com/openai/openai-agents-python/blob/697a46c4baa268d78d31c44244144967e57786b9/src/agents/run_state.py)
- [Codex multi-agent V2 spawn](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs)
- [Codex role overlay](https://github.com/openai/codex/blob/03bb3b12367397e14a8facc2e018d645ff4d8e83/codex-rs/core/src/agent/role.rs)

### Frameworks

- [AutoGen AssistantAgent](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/agents/_assistant_agent.py)
- [AutoGen OpenAI client](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-ext/src/autogen_ext/models/openai/_openai_client.py)
- [AutoGen Team state](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_base_group_chat.py)
- [Google ADK LlmAgent](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/agents/llm_agent.py)
- [Google ADK Session](https://github.com/google/adk-python/blob/221bad92b8ed659fc0d34c610d5b3bc469e0bac5/src/google/adk/sessions/session.py)

### Product-adjacent cases

- [OpenCode Agent](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/opencode/src/agent/agent.ts)
- [OpenCode request merge](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/opencode/src/session/llm/request.ts)
- [OpenCode custom providers](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/web/src/content/docs/providers.mdx)
- [OpenCode child task](https://github.com/anomalyco/opencode/blob/17544802c38a4d35834275526ccf38be1cdcfbf4/packages/opencode/src/tool/task.ts)
- [Cline configured-agent](https://github.com/cline/cline/blob/a41129a5dbda29c4e6b84968a2a798039ba32ab3/sdk/packages/core/src/extensions/tools/team/configured-agent-tool.ts)
- [Roo API Configuration Profiles](https://github.com/RooCodeInc/Roo-Code-Docs/blob/a676c4173ae60348095efaebfd1292a9617622c0/docs/features/api-configuration-profiles.mdx)
- [Aider Architect coder](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/architect_coder.py)
- [Claude Code public agent-development skill](https://github.com/anthropics/claude-code/blob/c39cb0f14bfe8bb519bae5bfc55add6867c5e2ab/plugins/plugin-dev/skills/agent-development/SKILL.md)

## PROJECT_AUDIT_SUMMARY

本轮核对的 Intatis 关键链路包括：

- provider/endpoint/model/options：`Endpoints.swift`、`ProviderRegistry.swift`、`ToolCalling.swift`、`OpenAIWireProvider.swift`、`OpenAIToolCalling.swift`；
- agent request：`Agent.swift`、`AgentRuntime.swift`、`AgentLoop.swift`；
- Cowork session/provider：`CoworkProjectSettings.swift`、`CoworkViewModel.swift`、`Orchestrator.swift`、`CoordinatorTools.swift`；
- persistence/observability：`CoworkEvents.swift`、`TurnStats.swift`；
- GUI provider/model/variant：`AppConfig.swift`。

当前事实是：

- Intatis 已能在 catalog 中配置多个 endpoint、model options 和 variants；
- ProviderRegistry 已能按 ModelRef 解析 endpoint；
- production Cowork 尚未按 agent 解析完整 inference binding；
- reasoning/variant/provider resolution 仍存在 session/global coupling；
- EventLog 还不能精确恢复 per-agent endpoint/options revision；
- 当前只有 OpenAI-compatible wire 真正 shipped；
- `profile` 已被权限和浏览器语义占用，新增类型必须显式命名。

## DOCS_CONTENT_SUMMARY

本轮按项目入口要求复核了：

- `/Users/vita/Vitemis/AGENTS.md`
- `AGENTS.md`
- `docs/CURRENT_STATE.md`
- `docs/PROJECT_MAP.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/OPEN_SOURCE_REUSE.md`
- `docs/TESTING.md`
- `docs/NEXT_TARGET.md`
- `docs/COWORK_PRINCIPLES.md`

与本报告相关的文档约束是：

- Cowork 不得改造成同步递归 AgentLoop；
- agent 身份、任务、能力租约和上下文投影保持分层；
- endpoint/profile 不能绕过 CapabilityLease、WorkspaceLease、PermissionEngine 和 exact-target authorization；
- EventLog 只能 additive 演进，旧 JSONL 必须继续解码；
- secret 不得进入事件、报告或普通配置镜像；
- OpenCode 当前仍是 research-only；
- `NEXT_TARGET.md` 的 active target 不因本报告改写；
- per-agent provider/model picker 当前仍是未实现能力。

本轮只新增研究报告，不改变持久项目行为或权威项目状态，因此没有更新 `docs/`。如果后续形成正式设计决策，应将稳定结论写入新的 RFC/设计文档，并同步 CURRENT_STATE、ARCHITECTURE、DO_NOT_BREAK、PROJECT_MAP、TESTING 和 NEXT_TARGET。

## VALIDATION_RESULT

- 已执行工作目录检查：`pwd`、`git rev-parse --show-toplevel`、`git status --short`。
- 已检查报告命名和现有 `codex-report/` 格式。
- 已核对上述仓内源码、项目文档和固定版本上游证据。
- 已执行 `git diff --check`，无 whitespace error。
- 因报告是 untracked 新文件，另执行 `git diff --no-index --check /dev/null <report>`；除“新文件必然不同”对应的退出码 1 外，没有 whitespace error。
- 已检查尾随空白和占位符，均未发现。
- 已执行 `git status --short`，仅出现 `?? codex-report/07_16_26-17_53-per-agent-inference-profile-research.md`。
- 未运行构建/测试。本轮只新增 Markdown 调研报告，不修改业务源码、测试或构建配置。

## UNCERTAINTIES

- Claude Code 等闭源产品的内部持久化实现无法从公开资料确认。
- 本轮样本不能证明市场上绝对不存在未公开或未纳入调研的完整产品。
- gateway 后的实际物理上游通常无法由客户端单方面证明。
- profile revision 的持久存储位置、secret-free schema 和 retention policy 需要正式 RFC 决定。
- current arbitrary model options 可能包含敏感扩展值；在完成 schema/sanitization 设计前不能直接持久化。
- 非 OpenAI-compatible wire、真实多 endpoint 长任务、跨重启 profile 恢复和 GUI/CLI E2E 当前均为 `UNKNOWN`。
- reviewer/verifier 是否允许用户配置独立 inference profile，以及允许到什么范围，需要后续确认。

## NEXT_RECOMMENDED_ACTION

下一步建议只做一件事：编写正式的 `Per-Agent Inference Profile RFC`，先锁定以下决策，再进入业务源码实现：

1. `InferenceConnectionDefinition`、`InferenceProfileDefinition`、`AgentInferenceBinding` 和 `ResolvedInferenceProfile` 的最小字段；
2. profile revision/versioned store 或 session-safe snapshot；
3. exact merge precedence 和宿主强制字段；
4. InferenceRouteLease、permission target 和数据出境语义；
5. additive EventLog/legacy migration；
6. spawn/inherit/rebind/recovery 状态机；
7. control-plane reviewer/verifier bindings；
8. 第一阶段只支持 OpenAI-compatible wire 的测试矩阵。

不要在这些决策确定前只给 `Agent` 添加 provider/model/variant 字段；那会保留当前全局配置漂移和恢复歧义。
