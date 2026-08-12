# Cowork 自动权限审查：同次工具调用 Evidence Sidecar 详细设计报告

日期：2026-08-11

设计状态：源码实现完成，focused、沙箱外完整 SwiftPM 与 macOS/iOS build gate 已通过；真实 provider/UI smoke 未运行

源码基线：Git HEAD 53f3320d640916596664e06cb71bfba43b160dd2，提交标题 v0.47

版本说明：仓库没有对应 Git tag；v0.47 是本报告的开发基线提交标题。当前工作树产品版本为
MARKETING_VERSION / CURRENT_PROJECT_VERSION = 0.48 / 48。

报告范围：Cowork automatic ask-class permission review。本文不修改 Chat、Code、人工权限模式、
DeterministicPolicyGate、WorkspaceLease、CapabilityLease 或 durable tool execution 的基本边界。

实现状态声明：当前工作树已经完成 same-call string sidecar、Reporter live dispatch 移除、transient reviewer
input、permission-request receipt、plain-text verdict、manual reserved-key fence、dedicated host admission、
duplicate/recovery invocation revalidation、durable non-echo 与 in-engine reviewer misconfiguration fence。2026-08-12
corrective focused 验证为 7 个 suite、162 tests / 0 failures；本次 strict-schema correction 的受影响目标
`IntatisAgentKernelTests` 217/217、`IntatisKnowledgeTests` 118/118、`IntatisCoworkTests` 364/364、
`IntatisCLITests` 45/45（8 skipped）通过。真实 provider sidecar/UI smoke 尚未运行；
live 路径没有固定 sidecar byte ceiling，也没有 `review_input_too_large` admission。

> **2026-08-12 实现校正（覆盖本文所有冲突的旧设计措辞）**
>
> - `__intatis_authorization_context` 当前是 request-owned provider schema 中 required 的单一 String；任何
>   `strict:true` function 的 decorated schema 均须满足 `required == properties.keys` 与
>   `additionalProperties:false`；装饰器递归验证并在发网前 typed fail closed。`tool_search` 本身保持原样，
>   provider-bound `tool_search_output` 中的 deferred function/namespace children 同样装饰而 durable output
>   不变。原 ToolDescriptor/business required/executor schema 不变；宿主仅在
>   deterministic gate 到达 automatic ask 时消费并验证该值，deterministic allow/deny 忽略其语义。
> - live reviewer 收到完整 safe business arguments、完整 same-generation String 和 mechanical host facts；
>   不收到 TaskContract objective/role/deliverable、causal userGoal、raw/current 用户消息、assistant/history、
>   PDF 或图片原文。任务语义只来自 acting model 自己写入的 String。
> - valid sidecar 只留在同一 turn 的 acting-model 内存 history 作为格式示例；EventLog、durable model history、
>   permission identity 和 executor 都只看到 stripped business arguments。
> - missing/malformed/secret-bearing sidecar 只产生 failed/runtimeFailed `tool_result`，不创建 permission lifecycle、
>   不调用 reviewer、不消耗 denial fuse；同 business args 的 missing → missing → valid 必须仍可送审。binding
>   mismatch 另按 authorization snapshot failure typed fail closed。
> - 下文关于七字段 sidecar、`evidence.reference`、pre-request `permission_resolved`、跨重启恢复这类拒绝、
>   “只给一次纠正机会”的段落，是被本校正取代的历史方案，不描述当前 live 实现。

## 1. 执行结论

本报告选定的目标不是继续修补 v0.47 的 PermissionAuthorizationContextReporter，也不是让宿主从
EventLog 中按固定条数和字符数机械拼装权限上下文。选定方案是：

> 主模型在产生业务工具调用的同一次 provider generation 中，可以同时产生该调用的一条权限说明
> sidecar。宿主在 automatic ask 边界要求并绑定它，然后把完整安全业务参数、这条未信任说明和机械
> 权限事实交给独立权限审查模型。主模型不再被第二次调用，完整对话、PDF 和图片也不再为了授权报告
> 重新发送。

权威流程如下：

~~~text
用户请求、历史回答、PDF、图片、ToolResult
        │
        ▼
主模型：一次正常推理
        ├── 业务 Tool Call：工具名 + 完整参数
        └── 同一 Tool Call 内的一条 authorization context String
                └── 为什么这个 exact action 服务当前任务的简短说明
        │
        ▼
宿主拆包、校验、规范化并绑定
        ├── business arguments：进入 gate、authorization、review 和 executor
        └── model sidecar：只作为主模型生成的语义证据
        │
        ▼
DeterministicPolicyGate / capability / workspace preflight
        ├── hard deny：终局拒绝
        ├── deterministic allow：沿既有快速路径
        └── ask/pass-to-review：进入独立 reviewer
        │
        ▼
权限审查模型：精确动作 + 完整安全参数 + sidecar String + 机械宿主事实
        │
        ▼
短理由 + ALLOW 或 DENY
        │
        ▼
durable settlement → authorization/workspace revalidation
        → durable tool execution prepare → executor
~~~

这套信息流有两个模型调用，但只有一个主模型调用：

1. 第一次是正常主模型推理，它同时产生工具调用和 sidecar。
2. 第二次是独立权限审查模型，只负责最终 allow/deny。

严禁在两者之间再次调用主模型生成授权报告。

## 2. 已确认的设计决策

| 决策 | 结论 |
| --- | --- |
| 主模型何时整理上下文 | 与业务 Tool Call 同一次 generation |
| 是否再次调用主模型 | 否 |
| Sidecar 放在哪里 | 同一个业务 function call 的 JSON arguments 中，使用宿主保留字段 |
| 谁负责选择和总结语义证据 | 发出工具调用的主模型 |
| 宿主是否重新总结对话 | 否；宿主只校验 String、secret、身份和绑定 |
| Reviewer 是否收到完整聊天记录 | 否 |
| Reviewer 是否收到完整 PDF/图片 | 否；默认收到主模型摘要与引用 |
| Reviewer 是否收到工具参数 | 是；收到规范化后的完整安全 business arguments，而非仅 digest/preview |
| 是否允许固定 36 条消息上限 | 否 |
| 是否允许 420/700/1200 字符前缀裁切后继续审查 | 否 |
| 有图片是否直接拒绝 | 否 |
| Reviewer 是否使用 provider-native structured output | 否 |
| Reviewer 输出合同 | 普通文本短理由，最后一行 ALLOW 或 DENY |
| Risk、lease、路径和工具身份由谁决定 | 宿主 |
| Sidecar 能否扩大 hard deny 或 lease | 不能 |
| Sidecar 缺失时怎么办 | ask-class 调用不进入 reviewer；返回可纠正 tool-input failure，不消耗 reviewer fuse |
| 重复修改 sidecar 能否绕过同一动作的拒绝 | 不能；熔断身份只看业务动作 |

## 3. 实施前 v0.47 基线的真实机制

实施前以干净 HEAD 53f3320 为基线检查了生产路径。下面记录的是 v0.47 基线当时的事实，用于解释
为什么要替换 Reporter；它不是当前工作树的 live 机制。

### 3.1 v0.47 ToolCall 没有独立 sidecar 通道

Packages/IntatisProviders/Sources/ToolCalling.swift 中：

- ToolSpec.parameters 已经是 provider-facing JSON Schema。
- ToolCall 只有 id、name、arguments、kind、namespace、status 和 execution。
- ToolCall.arguments 是 raw JSON string。

因此，现有 OpenAI-compatible provider wire 没有可以直接承载 permission metadata 的 sibling 字段。
若要保持 provider-neutral，最小可行方式就是在现有 arguments JSON 中增加一个宿主保留属性，收到后
再拆包。

### 3.2 v0.47 Reporter 是第二次主模型调用

Packages/IntatisAgentKernel/Sources/AgentLoop.swift 在 v0.47 中于主模型已经返回工具调用后构造
PermissionAuthorizationReportingTurn，其中包含：

- 本次主模型的完整 request.messages；
- assistantText；
- 整个 tool-call batch；
- 可见用户消息；
- current submission。

当权限 gate 进入 automatic ask-class 路径时，AgentLoop 再调用
PermissionAuthorizationContextReporter。

Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift 当时又把：

~~~text
turn.providerMessages
+ 一个新的 developer reporting prompt
~~~

发送给同一个 acting provider/model，并暴露 output-only
submit_permission_authorization function。

这就是 v0.47 完整对话、PDF tool output 和其他大上下文被再次发送的直接来源。

### 3.3 v0.47 Reporter 输出合同与 provider 行为不匹配

Reporter 只接受：

- 无任何 prose；
- 恰好一个 function call；
- function 名必须是 submit_permission_authorization；
- function arguments 必须满足严格报告 JSON；
- 必须有可信 completion marker 和成功 finish reason。

但 v0.47 AgentRequest 没有 request-scoped required tool choice；Responses adapter 使用 tool_choice:auto，
Chat Completions 同样没有为该报告请求强制指定唯一 function。因此模型在 auto 模式下输出正文、
不调用函数或输出不同形状，都是 provider 合同允许但 Reporter 会拒绝的结果。

### 3.4 v0.47 Reporter 按 ask-class call 重复运行

同一 assistant batch 有多个 ask-class tool calls 时，每个 call 都重新：

1. 复制完整 provider messages；
2. 调用 acting model；
3. 生成一份报告；
4. 单独计费和等待。

这会同时放大 token、延迟、超时概率和格式失败概率。

### 3.5 v0.47 Reviewer 看不到完整业务参数

Cowork PermissionRequest 当时把 arguments 持久化为：

~~~text
digest=<sha256>; characters=<count>
~~~

最终 reviewer 主要看到：

- normalized argument digest/count；
- PermissionIntent；
- bounded action preview；
- paths/network/side effect；
- gate/lease/TaskContract；
- acting-agent authorization report；
- host-selected user evidence。

因此 reviewer 并没有看到与 executor 完全一致的 canonical business arguments。

### 3.6 v0.47 媒体处理是全局拒绝

如果冻结的 acting provider messages 中包含图片，automatic ask-class call 会在 reviewer 前直接以
mediaAuthorizationUnsupported 拒绝。它没有区分图片是否与当前工具调用相关。

### 3.7 v0.47 最终 Reviewer 仍依赖文本 JSON

PermissionReviewControlPlane 当时要求 reviewer 返回 compact JSON：

~~~json
{"decision":"allow|deny","reason":"short reason"}
~~~

宿主再从第一个左花括号到最后一个右花括号抽取 JSON。通用 ModelPermissionReviewer 也仍使用 JSON
输出合同。v0.47 并没有 provider-native response schema 或 required function guarantee。

## 4. 为什么不保留 v0.47 方案

v0.47 设计的问题不是“报告字段还不够好”，而是报告生成时机错误。

主模型产生工具调用时已经拥有最完整、最新的任务上下文。工具调用结束后再要求同一模型重读整段
上下文并解释自己，额外引入了：

- 第二次大输入；
- 与原 generation 不同的模型状态；
- 报告与具体 tool call 的后置绑定；
- output-only function compatibility；
- 每个 call 独立重试；
- 报告阶段本身成为权限可用性的单点故障。

继续调整 Reporter 的 prompt、字符上限、JSON parser 或 tool choice，都不能消除这些结构性成本。

## 5. 为什么不采用纯宿主裁切

我们也明确否决“删除 Reporter 后，由宿主从 EventLog 中挑最近 N 条消息并做固定字符裁切”的方案。

宿主可以可靠判断身份、顺序、路径、lease 和工具事实，但它无法可靠判断：

- 哪段历史回答解释了当前动作；
- PDF 中哪一段让主模型决定执行某个命令；
- 图片中什么内容影响了动作选择；
- 哪个 ToolResult 表明当前已经完成到哪一步；
- 长对话中哪条自然语言约束仍然与当前动作有关。

固定数量或前缀裁切还会产生新的不连续行为：

- 第 37 条用户消息让整个自动审查不可用；
- 一条长消息末尾的撤销语句被截掉；
- 上一轮回答只剩开头，丢失实际计划；
- 图片一律拒绝；
- PDF 一律只剩 hash；
- reviewer 得到宿主认为“安全”但语义残缺的材料。

因此，宿主不能代替主模型做语义证据整理。

## 6. 目标角色与信任边界

### 6.1 用户

用户提供任务、约束、纠正、撤销、文档和图片。用户授权仍受 deterministic policy、capability 和
workspace ceiling 限制。

### 6.2 发出工具调用的主模型

主模型拥有完整任务上下文，并负责在同一次 generation 中：

- 选择业务工具；
- 生成精确业务参数；
- 总结与当前动作有关的对话；
- 选择它认为相关的用户、assistant、ToolResult、PDF 和图片证据；
- 解释为什么现在需要该动作；
- 声明动作范围和不确定项。

主模型不负责：

- 决定最终 allow/deny；
- 声明 risk；
- 声明 capability/lease 已满足；
- 声明路径已获授权；
- 生成 ToolCallID、TurnID、RequestID 或 authorization ID；
- 产生 hidden reasoning/CoT。

### 6.3 宿主

宿主负责不可交给模型的事实：

- ToolCall 与 sidecar 的结构拆分；
- exact turn/generation/call binding；
- business schema validation 和 canonicalization；
- registry/tool identity；
- CapabilityLease 和 WorkspaceLease；
- resolved paths/network/side effect/intent；
- deterministic hard deny；
- args digest、authorization ID 和 replay policy；
- reviewer request 生命周期；
- durable settlement；
- allow 后重新验证和 durable execution prepare。

当前宿主只校验 evidence 的结构、source 枚举以及 `reference`/summary/relevance 非空；`reference` 本身仍是
未经信任的 model-authored string，没有 lookup 可证明它来自主模型可见输入。下文 EvidenceID provenance
是后续增强设计，不是当前实现。宿主也不重新判断主模型的语义总结是否“正确”。

### 6.4 权限审查模型

Reviewer 是独立控制面模型，只回答：

> 结合精确动作、完整安全参数、主模型压缩的上下文证据和宿主边界事实，这个动作是否符合用户任务、
> 是否必要、是否明显扩大范围或包含不可接受的语义风险？

Reviewer 不能改变 hard deny、lease、workspace、risk 或 executor identity。

### 6.5 Executor

Executor 永远只收到剥离 sidecar 后、经过原工具 schema 验证的 canonical business arguments。

## 7. Provider-facing Sidecar 合同

### 7.1 保留字段

本设计使用：

~~~text
__intatis_authorization_context
~~~

它只存在于 provider-visible tool schema 和主模型返回的 function arguments 中。它不是业务工具参数，
也不进入 executor。

### 7.2 当前结构

~~~json
{
  "path": "reports/summary.md",
  "content": "...actual business argument...",
  "__intatis_authorization_context": "The source review is complete; writing only reports/summary.md produces the requested deliverable."
}
~~~

### 7.3 Sidecar 字段语义

sidecar 是一个 nonempty String，不再包含嵌套字段。它只需说明相关意图/进展/证据，以及为什么这个 exact
action 有必要；不复制用户消息、PDF/图片原文或完整工具结果，也不声明 risk、lease、authority 或 verdict。

### 7.4 不允许出现在 Sidecar 中的内容

- ALLOW、DENY 或 ask_user 决策；
- 模型自报 risk；
- 模型自报 capability/lease membership；
- 模型自报 path authorization；
- authorization ID、RequestID 或持久化 seq；
- hidden reasoning 或 chain-of-thought；
- 完整 PDF、完整图片/base64、完整 transcript；
- 明文 token、密码、私钥、authorization header；
- 为了绕过既有拒绝而修改的虚假动作描述。

### 7.5 大小控制原则与当前缺口

Sidecar 必须简洁，但不能使用“截前 N 字符后继续”的方式处理。

目标规则是：

- provider prompt 要求主模型主动压缩；
- 宿主按 exact route 的 reviewer context budget 检查完整序列化 sidecar；
- 完整 sidecar 能装入预算才接受；
- 超预算时整份标记 oversized，返回 typed failure；
- 不允许截一半、删尾部或只留前缀后继续权限审查。

具体 token/byte 上限必须通过真实 provider smoke 和 reviewer context window 决定，本文不伪造一个未经
测量的固定数字。当前 `AuthorizationSidecarCodec` 只有调用方显式传入 `maximumSidecarBytes` 时才会返回
`oversized`；live `AgentLoop` 没有传入该 ceiling，因此当前没有固定 sidecar byte admission。现状仍保证不把
sidecar 静默裁切后继续审查，但不能宣称 live oversized failure 已接线。

## 8. EvidenceID 与来源引用（后续设计，当前未实现）

### 8.1 目的

未来若实现 provenance lookup，引用必须至少能够证明：

- 该来源确实存在；
- 该来源在本次主模型 provider request 中可见；
- 引用没有跨 session、turn 或 provider generation；
- document/image 引用指向真实 artifact；
- ToolResult 引用来自真实 call。

宿主不验证摘要是否忠实重述原文；那属于主模型解释和 reviewer 判断的剩余风险。

### 8.2 建议类型

| 前缀 | 来源 |
| --- | --- |
| U | canonical user submission |
| A | assistant/model-history item |
| T | tool call 或 ToolResult |
| D | document artifact |
| P/C | document page 或 chunk |
| I | image artifact 或 region |

未来 EvidenceID 应是 request-scoped opaque handle，并绑定：

~~~text
SessionID
+ TurnID
+ provider generation
+ provider-visible input item
+ content/artifact digest
~~~

模型不能直接填写 EventLog seq，也不能引用另一个 agent 不可见的 main-thread 私有消息。

### 8.3 如何让主模型看见引用

未来宿主可在主 provider dispatch 前为可见 input items 建立轻量 manifest。它只映射输入项与 EvidenceID，
不复制正文。优先使用 provider item metadata；不支持 metadata 的 route 可注入一个很短的 developer
manifest。

当前工作树没有该 manifest、lookup 或 cross-generation provenance validator。sidecar 的 `reference` 不能
作为 host-validated user/document/image/ToolResult 证据，只能作为 reviewer 可见的模型自述。

## 9. 各类上下文如何流动

| 来源 | 主模型看到什么 | Sidecar 中如何表示 | Reviewer 收到什么 | 信任级别 |
| --- | --- | --- | --- | --- |
| 用户消息 | 原本 provider-visible 的用户上下文 | 目标摘要、相关证据 summary/ref | 主模型压缩后的内容 | 模型生成的授权解释 |
| 先前 assistant 回答 | 原本 provider-visible history | 当前进展、计划和相关摘要 | Sidecar summary/ref | 非权威模型陈述 |
| ToolResult | 原本 provider-visible tool output | outcome、进展和相关事实摘要 | Sidecar summary/ref + 宿主 outcome facts | 宿主 outcome 权威，语义摘要非权威 |
| PDF/文档 | 主模型正常任务上下文中的文档内容 | document/page/chunk ref + 摘要 | Sidecar summary/ref | 非权威数据解释 |
| 图片 | 主模型正常视觉上下文 | image/region ref + 视觉摘要 | Sidecar summary/ref | 非权威视觉解释 |
| 工具参数 | 主模型自己生成 | 不复制进 sidecar | 完整 canonical safe business arguments | 精确动作事实 |
| Gate/lease/path | 主模型不决定 | 不允许模型声明 | 宿主结构化事实 | 权威 |

### 9.1 用户消息

不再由宿主按最近 36 条、每条 700/1200 字符进行选择和前缀裁切。主模型负责把它认为与当前动作有关
的用户请求、修正和撤销信息压缩进 context_summary/evidence/scope。

这意味着 reviewer 依赖主模型是否忠实保留重要约束。该风险是本设计明确接受的产品取舍，而不是宿主
可以证明消除的风险。

### 9.2 先前 assistant 回答

不再固定取前 420 字符。主模型可以总结：

- 前一轮提出了什么计划；
- 当前动作是计划中的哪一步；
- 哪些步骤已经完成；
- 为什么需要继续。

Assistant 内容不能声明用户授权，但可以解释进展和动作必要性。

### 9.3 PDF/文档

不再把整份 PDF 为 Reporter 重发一次，也不再把 PDF 完全丢弃成 hash/count。

主模型已经在正常任务推理中看过文档，因此由它在 sidecar 中给出：

- 文档引用；
- 页码/chunk 引用（如果可用）；
- 与当前动作有关的摘要；
- 文档内容如何影响当前动作。

文档本身不能扩大 CapabilityLease、WorkspaceLease 或 hard deny。用户说“按照文档操作”时，文档可
定义操作步骤，但不能凭文档中的文字自动授权读取秘密、越界写入、任意网络外发或危险命令。

### 9.4 图片

不再因为主模型上下文中出现任何图片就拒绝整个 ask-class call。

主模型在 sidecar 中说明：

- 使用了哪张图片或哪个区域；
- 看到了什么；
- 为什么这与当前动作有关；
- 是否存在视觉不确定性。

Reviewer 默认基于主模型压缩的视觉证据判断。未来可增加 multimodal reviewer 作为更强模式，但它
不是本流程成立的前置条件。

### 9.5 ToolResult

ToolResult 的 durable outcome、ToolCallID 和 structured result identity 仍由宿主提供。主模型可以在
sidecar 中解释该结果对当前进展意味着什么。Reviewer 不需要重新接收所有历史 ToolResult 原文。

## 10. Business Arguments 必须完整进入 Reviewer

### 10.1 不再只发 digest/preview

Reviewer 要判断的是精确动作。对 ask-class call，reviewer provider request 必须获得：

- exact tool name；
- 剥离 sidecar 后的 canonical business arguments；
- resolved paths；
- network target；
- PermissionIntent；
- side effect 和 replay policy；
- registry/capability/workspace/gate facts。

Digest/count 只用于绑定和审计，不能替代实际参数。

### 10.2 参数不允许静默裁切

命令、URL、路径、patch、query、目标 agent 和其他会改变动作语义的字段不能只发送前缀。

目标行为是在 canonical arguments 超过 reviewer route 可容纳的上下文时：

- 不发送部分参数；
- 不让 reviewer 根据 digest 猜；
- 返回 typed review_input_too_large；
- 要求主模型拆分动作、改用 artifact/path 引用，或进入显式人工模式。

当前 control plane 会完整发送已通过 secret 检查的 canonical arguments，但没有 route-derived input-size
admission，也不会生成 `review_input_too_large`。因此该段是待实现规则；当前只保证不先裁切 exact args 再
让 reviewer allow。

### 10.3 Secret-bearing 参数

本设计不把明文凭据发送给 reviewer。正确工具合同应使用 KeychainRef 或其他 opaque credential
reference，让 reviewer 看到：

- 将使用哪个 credential reference；
- 目标 origin/server；
- 操作类型和数据流向；

而不是看到 secret value。

如果模型把明文 secret 写进业务参数，automatic review 不应通过正则替换后继续执行。应返回 typed
secret-bearing-input failure，并要求改用安全引用或显式人工流程。

write_stdin 等天然可能承载密码或一次性验证码的工具，应继续使用结构化、非明文字节的权限表示；
不能为了“完整参数”破坏既有秘密边界。

### 10.4 Transient reviewer input

完整 canonical arguments 的 reviewer transient 副本不应因为需要 reviewer 而永久写入
PermissionRequestPayload。

建议新增仅存在于当前进程和当前 review generation 的内部结构：

~~~swift
struct PermissionReviewInvocationInput: Sendable {
    let turnID: TurnID
    let toolCallID: String
    let canonicalBusinessArguments: String
    let modelAuthorizationContext: ModelAuthorizationContext
    let businessArgumentsDigest: String
}
~~~

`permission_request.context` 保存 digest/count、sidecar generation/snapshot/digest/status receipt 和宿主
authorization facts；`PermissionReviewTask` 不复制 receipt。raw sidecar 永不落盘，reviewer transient exact-args
副本不进入 permission lifecycle；stripped business call 仍可按既有 bounded/schema-valid/secret-safe 规则进入
model history 与 `.tool_call`。若进程在 review 完成前崩溃，transient input 不从这些 history 重建；当前
request 恢复为 deny。

## 11. 拆包、规范化和绑定顺序

### 11.1 Provider schema decoration

原 ToolDescriptor 和 execution registry 保持业务 schema 不变。只装饰 request-owned provider-facing
ToolSpec：

1. 复制原 JSON Schema。
2. 在 properties 中加入 __intatis_authorization_context。
3. 将它加入 decorated copy 的 `required`，使 acting model 每次 automatic Cowork function call 都输出 sidecar。
4. 保留原业务字段、原 ToolDescriptor/business required/executor schema 与 strict 值；若 strict 为 true，
   decorated copy 必须满足全部 properties 均 required、`additionalProperties:false`。
5. 不改变 registry version、descriptor fingerprint 或 capability membership。

### 11.2 收到 ToolCall 后

顺序必须固定：

1. 等主 provider generation 收到可信 completion。
2. 完成现有 ToolCallID 去重/规范化。
3. 对每个 call 单独解析顶层 arguments JSON object。
4. 提取并验证 sidecar。
5. 从 object 中删除保留字段。
6. 对剩余对象 sorted-key canonical encode。
7. 使用原 ToolDescriptor schema 验证 business arguments。
8. 只用 business arguments 计算 touched paths、network、intent、preview 和 authorization identity。
9. 将 sidecar 与 exact call/turn/generation/business digest 绑定。
10. Gate 决定是否进入 reviewer。

### 11.3 内部值类型

~~~swift
struct PreparedPermissionToolCall: Sendable {
    let providerCall: ToolCall
    let executableCall: ToolCall
    let modelAuthorizationContext: ModelAuthorizationContext?
    let sidecarStatus: SidecarStatus
    let canonicalBusinessArgumentsDigest: String
}
~~~

### 11.4 Sidecar 绝不能影响业务动作身份

Sidecar 必须从下列内容中排除：

- normalized business args digest/count；
- authorizationArgumentIdentity；
- descriptor fingerprint；
- registry identity；
- touched paths；
- network risk；
- PermissionIntent；
- action preview；
- replay policy；
- denial/retry signature；
- executor ToolArgs。

否则模型只修改一段“理由”，就可能把同一被拒动作伪装成新动作。

## 12. 多 Tool Call 与并发

Sidecar 是 per-call，不是 per-assistant-batch：

~~~text
ToolCall A → Arguments A + Sidecar A → Review A
ToolCall B → Arguments B + Sidecar B → Review B
~~~

绑定使用：

~~~text
SessionID
+ TurnID
+ TaskID
+ uniqued ToolCallID
+ provider generation
+ registry snapshot
+ canonical business args digest
+ sidecar digest
~~~

禁止：

- 按数组位置把 sidecar 与 call zip；
- 用 assistantText 作为整个 batch 的公共授权报告；
- 把 A 的 sidecar 用于 B；
- 缓存 sidecar 跨 call、turn 或 generation 使用；
- 只改 sidecar 文案获得新的同动作审查机会。

现有允许并行的 collaboration calls 必须直接携带 PreparedPermissionToolCall，不能把 calls 和 sidecars
拆成两个独立数组传递。

## 13. Gate 与 Sidecar 缺失语义

### 13.1 Hard deny

Capability 不存在、WorkspaceLease 不匹配、sensitive path、dangerous shell 或其他 deterministic hard
deny 仍然终局。Sidecar 无论多合理都不能让 hard deny 进入 reviewer。

### 13.2 Deterministic allow

普通确定性 read-only allow 可以保留既有快速路径。Sidecar 可以存在但不作为执行前置条件，因为该
动作不需要自动 reviewer。

### 13.3 Ask/pass-to-review

只有需要 reviewer 的 call 才要求有效 sidecar。

当前 live 路径把 sidecar 缺失、malformed 或含 secret 与 binding 无效分开处理。

前三类是 acting-model tool-input error：

1. 不创建 permission_request；
2. 不调用 reviewer；
3. 不执行工具；
4. 只写 failed/runtimeFailed `tool_result`；
5. 不消耗 permission denial fuse，相同 business args 后续补成 valid sidecar 仍可送审。

这次纠正是异常恢复，不是 Reporter：宿主不会重新发送一份专门的报告请求，也不会调用
submit_permission_authorization。

`SideEffectEvidenceLedger` 只在当前 turn 内防止模型把未执行动作说成完成；restart 不恢复一条从未发生的
权限拒绝。binding 无法与 exact call/generation/business digest 对齐时则另按 authorization snapshot failure
typed fail closed。整个 turn 仍受 AgentLoop iteration 上限约束。

manual/nonautomatic 模式不装饰 provider schema，也不接收 transient input；若模型仍发送宿主保留字段，
AgentLoop 在业务 schema/executor 前写 redacted audit 和
`authorization_context_mode_mismatch` tool result。保留字段绝不作为 MCP/业务工具的额外参数传下去。

`oversized` 只有未来给 live codec 传入 route-derived ceiling 后才可触发；EvidenceID/reference provenance
validation 当前尚未实现，不能把任意 nonempty `reference` 的真假作为这一前置失败条件。

如果某个 model/provider route 持续不能生成 sidecar，应把它标记为 automatic-sidecar-incompatible，
而不是每次权限请求都重复失败。

## 14. Reviewer 最终输入

Reviewer request 固定为两条消息：system + user，tools 为空。

建议 user message 分为四块。

### 14.1 HOST_ACTION_FACTS

~~~text
session / turn / task / tool-call binding
exact tool identity
canonical action
PermissionIntent
side effect
resolved paths
network facts
gate decision/risk/reason
capability/workspace lease facts
replay policy
~~~

这些由宿主生成，模型不能覆盖。

### 14.2 EXACT_BUSINESS_ARGUMENTS

放入完整、规范化、可安全发送的 business arguments。不得用 digest、preview 或截断字符串代替。

### 14.3 MODEL_AUTHORIZATION_CONTEXT

放入主模型同次 generation 生成的 sidecar，并明确标记：

~~~text
MODEL-AUTHORED CONTEXT
UNTRUSTED INTERPRETATION
NOT A HOST AUTHORIZATION FACT
~~~

Reviewer 使用它理解用户意图、历史进展、PDF/图片和动作必要性，但不能用它扩大宿主边界。

### 14.4 EXECUTION_BOUNDARIES

~~~text
hard deny is final
reviewer may only allow or deny this exact action
risk comes from host
allow must be durably settled before delivery
authorization/workspace are revalidated before execution
~~~

Reviewer 不收到：

- acting providerMessages；
- 完整 transcript；
- 第二份主模型 prompt；
- 完整 PDF；
- 图片/base64；
- 所有历史 ToolResult；
- EventLog 全量 replay；
- hidden reasoning；
- 模型自报 risk/lease/identity；
- Reporter handles 和 legacy authorization context closure。

### 14.5 Invocation 交付与唯一无 sidecar 入口

`PermissionResponder.requestResolution(_:invocation:)` 是 automatic mode 的协议要求；实现方没有显式支持该
overload 时默认 fail closed，不能把 invocation 静默丢弃后调用旧入口。

- live active duplicate 只有 `PermissionRequestPayload` 与完整 transient invocation 都 exact 相等才可共享
  同一个 owner generation；缺失或更换 invocation 不能 hitchhike；
- cached terminal 被再次请求时仍用本次 invocation 重算 receipt/args/context/authorization binding；
- restart 恢复出的 automatic allow 永远不重新交付，因为原 live job 和 transient input 已不存在；
- ordinary model-authored tool 不允许无 invocation；
- 唯一例外是 host-originated `agent.attach`。它只能由 `Orchestrator` 经专用
  `requestHostAgentAdmissionResolution` 提交，并核对 exact task kind、tool/action、policy、tool call、
  execution ID、authorization fingerprint、WorkspaceLease，以及 permission request 之前已经 durable 的
  `agent_attach_requested + workspace_lease_requested`。只把 `TaskContract.kind` 写成 `agentAdmission` 不构成
  豁免。

## 15. Reviewer 输出协议

最终 reviewer 不再依赖 JSON、response_format 或 function call。

目标协议：

~~~text
<非空、简短的审计理由>
ALLOW
~~~

或：

~~~text
<非空、简短的审计理由>
DENY
~~~

解析规则：

- 最后一个非空行必须是精确 ASCII ALLOW 或 DENY；
- 全文只能有一个独立 verdict marker；
- marker 前必须有非空理由；
- 不接受 JSON、code fence、ALLOW.、Unicode 同形字或多个 marker；
- 不接受 reviewer tool call；
- 必须收到可信 provider completion marker；
- length/max-token stop、timeout、cancel、provider error、无 done 均 deny 当前调用；
- risk 永远使用 host deterministic gate risk；
- 理由超出审计预算时整份 verdict malformed，不做前缀裁切。

这个协议使用普通文本生成，不要求 provider-native structured output。

对 live bound invocation，parser 接受 reviewer reason 只是为了验证完整 verdict；该自由文本可能复述
EXACT_BUSINESS_ARGUMENTS 或 MODEL_AUTHORIZATION_CONTEXT，因此不能进入 EventLog、permission settlement 或
tool-result。生产 control plane 只持久化固定宿主文案：allow 为
`automatic reviewer allowed the bound tool invocation`，deny 为对应 denied 文案。live bound review 的 provider
failure diagnostic 也固定为 generic host text，不能把可能含序列化 request body 的 upstream diagnostic 写回
durable state。无 transient input 的专用 host admission 不包含 exact args/sidecar，因此仍按其独立合同处理。

## 16. 失败与恢复矩阵

| 失败 | 行为 |
| --- | --- |
| 主 ToolCall arguments 不是 JSON object | 沿现有 invalid tool input 失败 |
| Manual/nonautomatic call 携带保留字段 | redacted `authorization_context_mode_mismatch`；不进入 business tool |
| Sidecar 缺失且 gate 需要 review | failed/runtimeFailed tool_result；不进入权限生命周期或 denial fuse，可继续纠正 |
| Sidecar 不是 nonempty String | failed/runtimeFailed tool_result；不进入 reviewer 或 denial fuse |
| Sidecar 超预算 | 后续项：live route-derived ceiling 尚未接线；未来应 typed sidecar_oversized，且不裁切 |
| Sidecar 含明文 secret | failed/runtimeFailed tool_result；不落盘、不外发、不进入 denial fuse |
| Business args schema 错误 | 沿现有 business argument validation 失败 |
| Business args 超出 reviewer context | 后续项：当前没有 `review_input_too_large` admission；不得用部分参数替代完整参数后继续 allow |
| Hard deny | 终局 deny，不进入 reviewer |
| Reviewer provider 建立失败 | durable deny 当前调用 |
| Reviewer timeout/cancel | durable deny 当前调用 |
| Reviewer 无 completion marker | durable deny 当前调用 |
| Reviewer 返回 tool call/JSON/多 marker | malformed verdict，durable deny |
| Settlement 持久化失败 | 不交付 allow |
| Settlement 后 caller cancel | 保留唯一 settlement，但最终 authorization delivery deny |
| Allow 后 authorization/workspace 变化 | execution 前 revalidation deny |
| Crash 导致 active review 的 transient args/sidecar 丢失 | orphan review 恢复为 deny，不重发完整主上下文 |
| Active/cached duplicate 缺失或更换 invocation | identity/binding conflict deny；不能共享旧 generation/terminal |
| Restart recovered automatic allow | 不重新交付；缺原 live job/transient authority |
| 仅伪造 agentAdmission kind | dedicated host-admission validation deny |
| Cowork 误注入 in-engine reviewer | 结果 typed fail closed；但错误配置可能已经多发一次 reviewer request |
| 实际 reviewer deny 后只改 sidecar 重试 | denial fuse 仍视为同一 business action |
| Missing/malformed/secret 后同 args 重试 | 不进入 reviewer fuse；补成 valid sidecar 后可正常送审 |

## 17. 持久化、模型历史与隐私

### 17.1 EventLog

automatic permission lifecycle 只新增保存：

- business args digest/count；
- sidecar digest；
- sidecar status；
- exact ToolCallID/TurnID/TaskID binding；
- ResolvedToolAuthorization；
- reviewer requested/settled；
- permission resolved；
- execution prepared/settled。

raw sidecar 永不保存，也不因为 automatic review 把 reviewer transient exact-args 副本写入 permission event。
这不删除既有业务审计：剥离 sidecar 后的 business call 仍可按 bounded/schema-valid/secret-safe 规则进入
`model_history_item(functionCallBatch)` 与 `.tool_call`。

pre-request missing/malformed/secret-bearing sidecar 不创建 `permission_request` 或 `permission_resolved`；它只写
failed/runtimeFailed `tool_result`，不调用 reviewer、不消耗 denial fuse。live bound reviewer 的自由 reason 与
provider diagnostic 不持久化，只写固定宿主结论，避免 transient input 通过回显绕回 EventLog。

边界必须准确表述：codec 只保证 reserved sidecar field/transient review packet 不落盘。如果 acting model 把
相同内容同时写成普通 assistant prose，该文本仍按既有 message/model-history 规则持久化；这不是 sidecar
剥离能够识别的语义副本。acting provider 在 malformed response/error 中回显输入时，也仍走通用 bounded/
URL/secret diagnostic sanitizer；当前没有针对所有 provider-specific error shapes 的 sidecar-aware proof。

### 17.2 主模型历史

Provider 原始 call 含 valid sidecar 时，同一 turn 的 acting-model 内存 history 保留它作为下一调用的格式示例；
durable model history 只保存剥离后的 business call，并保持原 call ID 与 ToolResult 配对。这样：

- 下一轮主模型仍能理解工具调用；
- sidecar 不会作为普通历史反复进入上下文；
- 原工具 schema 仍能验证；
- secret/malformed sidecar 不会持久化；
- restart 不会把旧 sidecar 当成新授权依据。

### 17.3 Legacy 协议

v0.47 已持久化的 PermissionAuthorizationReport、
PermissionAuthorizationContext 和 authorizationContextUnavailable 必须继续 Codable decode。

新 live 路径不再写入这些报告，不得删除旧字段导致历史 JSONL 无法读取。旧类型应标记 legacy
decode-only。

### 17.4 Usage

移除 Reporter 后：

- 不再有 PermissionAuthorizationUsageLedger；
- turn stats 不再计入第二次 acting-model report usage；
- reviewer usage 继续独立记账；
- 每个 ask-class call 的主模型额外成本只是 sidecar 输出 token。

## 18. Provider 与工具 schema 兼容

### 18.1 为什么不需要 response_format

主模型本来就必须生成业务 function arguments JSON。Sidecar 只是该对象中的一个保留属性，因此：

- 不新增 reporter-only function；
- 不需要 forced tool choice；
- 不需要 response_format；
- 不需要 provider-native JSON schema output；
- Chat Completions 和 Responses 共用现有 ToolSpec.parameters。

### 18.2 additionalProperties:false

多数原工具 schema 拒绝未知字段。因此 sidecar 必须：

- 只加入 provider-facing decorated schema；
- 在进入原 ToolDescriptor validation 前剥离；
- 不能直接传给原 registration.validateArguments；
- 不能进入 executor。

### 18.3 strict tools

不能为了 sidecar 把现有 strict:true 降为 false。当前实现把 required string sidecar 加入 decorated
`required`，并由离线 invariant 覆盖真实 shipped Skill/Knowledge strict descriptors：每个 strict object 的
`required` 必须精确等于 `properties.keys`，且 `additionalProperties:false`。具有业务默认值的其他 strict
property（当前 `search_knowledge.limit`）采用 provider-required integer-or-null，null 映射宿主默认值；
sidecar 本身不 nullable。真实 route 是否接受该标准形状仍须通过 opt-in smoke 验证，不能按 model 名称猜测。

### 18.4 namespace 与 deferred tool search

Decorator 必须处理：

- 普通 function ToolSpec；
- namespaceTools 内的 nested function；
- tool_search 之后动态暴露的 deferred business tool schema。

tool_search 本身是工具发现控制项，不是业务动作，不需要 permission sidecar；最终实际业务 function
call 必须携带。

### 18.5 保留字段冲突

如果本地或 MCP 工具已经声明 __intatis_authorization_context：

- 不得覆盖；
- 不得静默改名；
- 该工具必须 fail setup 或标记 automatic-sidecar-incompatible；
- 冲突必须在 provider dispatch 前可观察。

## 19. 三种方案比较

### 方案 1：保留 v0.47 二次 Reporter

优点是报告结构已经存在，acting model 能看到完整上下文。

主要问题是它需要第二次主模型调用、复制完整历史、按 call 重复、依赖 auto function output，而且报告
与产生工具调用的原 generation 分离。

结论：不采用。

### 方案 2：删除 Reporter，宿主机械选取证据

优点是确定性、容易审计，也不需要再次调用主模型。

主要问题是宿主不理解对话、PDF、图片和历史回答的语义相关性，只能依赖消息数量、前缀字符和固定
事件类型，容易同时造成信息丢失和永久误拒。

结论：不采用。

### 方案 3：同次 Tool Call Evidence Sidecar

主模型在做出动作决策的同一次 generation 中压缩上下文；宿主只处理结构和硬边界；reviewer 独立
判断。它避免第二次大输入，也避免宿主假装理解自然语言上下文。

主要剩余风险是主模型可能遗漏、偏向或错误总结证据。该风险已被用户明确接受；Reviewer、hard gate、
lease 和 execution revalidation 仍保留，但 Reviewer 无法证明主模型没有遗漏一条自然语言撤销指令。

结论：采用。

## 20. 安全与工程权衡

| 维度 | 预期方向 | 依据 | 主要原因 | 验证方法 |
| --- | --- | --- | --- | --- |
| 安全硬边界 | 保持 | 源码推导 | gate、lease、path、durable execution 不变 | hard-deny/lease/revalidation 回归 |
| 语义授权准确性 | 预期改善但不可证明 | 设计推断 | 主模型比字符串裁切更理解上下文；仍可能遗漏 | 对话/PDF/图片正反例 eval |
| Token 成本 | 明显下降 | 源码推导 | 删除完整 providerMessages 的第二次 acting call | 统计 provider dispatch 和 tokens |
| 延迟 | 下降 | 源码推导 | 少一次主模型 provider round trip | p50/p95 ask-class latency |
| 内存 | 小幅增加 | 设计推断 | 单次 PreparedPermissionToolCall 和 transient args | batch/large-args RSS |
| 可靠性 | 改善 | 源码推导 | 移除 Reporter strict function 单点故障 | 真实 route sidecar compliance smoke |
| 可运维性 | 改善 | 设计推断 | typed sidecar failures 比 context=nil 可诊断 | EventLog/metrics failure taxonomy |
| 迁移复杂度 | 中高 | 源码推导 | tool schema、history、MCP deferred、reviewer 都受影响 | 分阶段编译/测试/旧日志 replay |
| 隐私 | 改善但有 exact-args 例外 | 设计推断 | 不再二次发送全历史；reviewer需收到完整安全参数 | secret/large-input egress tests |
| 回滚 | 可控 | 设计推断 | 可回到显式人工模式；不应恢复 Reporter | feature flag/manual fallback exercise |

“预期”不是实测数据。当前仍没有真实 sidecar token、latency 或 route-compliance 测量；真实 provider smoke
尚未运行。

## 21. 当前实际实现触点

### 21.1 Provider/ToolSpec 层

实际实现位于 `Packages/IntatisAgentKernel/Sources/AuthorizationSidecar.swift`：它在 request-owned `ToolSpec`
copy 上装饰 ordinary/namespace/deferred function schema，保留 `tool_search` 与原 execution descriptor，并在
provider 返回后拆分 sidecar/business view。Providers 与 MCP 的基础 wire/type 没有为此新增 sibling metadata。
EvidenceID manifest 与 route capability/size admission 尚未实现。

### 21.2 AgentKernel

- Packages/IntatisAgentKernel/Sources/AgentLoop.swift
- Packages/IntatisAgentKernel/Sources/AuthorizationSidecar.swift
- 删除 Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift

职责：

- same-generation sidecar extraction；
- provider/business 双视图；
- canonical business args；
- per-call binding；
- typed correction + pre-request `permission_resolved/tool_result` durable batch；
- manual/nonautomatic reserved-key fence；
- accidental in-engine reviewer fail-closed fence；
- transient review input；
- model history strip；
- 移除 Reporter usage。

### 21.3 Permission/Cowork Control Plane

- Packages/IntatisPermission/Sources/ModelPermissionReviewer.swift
- Packages/IntatisPermission/Sources/PermissionReviewTextVerdict.swift
- Packages/IntatisCowork/Sources/AgentPermissionResponder.swift
- Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift

职责：

- exact args + sidecar reviewer packet；
- bound-responder default deny 与 active/cached/recovered invocation revalidation；
- dedicated host-agent-admission entry + durable admission evidence validation；
- legacy authorization context 不再成为 live prerequisite；
- plain-text verdict；
- live reviewer reason/provider diagnostic 固定为宿主文案；
- host-owned risk；
- durable settlement 和 cancellation 保持。

### 21.4 Protocol

- Packages/IntatisProtocol/Sources/PermissionReview.swift

原则：

- raw sidecar 永不持久化，reviewer transient exact-args 副本不进入 permission lifecycle；
- `PermissionRequestContext.reviewInvocationEvidence` 只做 additive generation/snapshot/digest/status receipt，
  `PermissionReviewTask` 不复制 receipt；
- stripped business call 继续服从既有 model-history/tool-call 持久化规则；
- legacy v0.47 JSONL 必须继续 decode；
- 不随意改变 Envelope/EventLog 语义。

### 21.5 测试与文档

当前工作树已更新或替换：

- Provider wire parity tests；
- AgentLoop tool argument/history tests；
- Reporter tests 删除或替换；
- Permission reviewer/parser tests；
- AutomaticPermissionReviewTests；
- PermissionReviewControlPlaneTests；
- MCP namespace/tool_search tests；
- docs/ARCHITECTURE.md；
- docs/CURRENT_STATE.md；
- docs/DO_NOT_BREAK.md；
- docs/COWORK_PRINCIPLES.md；
- docs/PROJECT_MAP.md；
- docs/TESTING.md。

上述文档现在记录工作树中的实现事实、focused/full SwiftPM 与 macOS/iOS Debug build 验证结果、首次
工作区沙箱环境失败，以及真实 provider smoke 未运行和 EvidenceID/route-derived size admission 两个缺口。

## 22. 实施进度

### 阶段 1：Sidecar 协议与纯函数（已实现）

- 定义 ModelAuthorizationContext、ModelAuthorizationEvidence 和 SidecarStatus。
- 实现 provider ToolSpec decorator。
- 实现 raw arguments → sidecar + business object extractor。
- 建立 collision、strict、namespace 和 deferred 合同测试。
- 证明 sidecar 的有无和文案不会改变 business digest/intent/path。

### 阶段 2：AgentLoop 双视图（已实现）

- 在 uniqued ToolCall 后建立 PreparedPermissionToolCall。
- business args 进入原 normalize/authorization/executor。
- sidecar 只进入 reviewer input。
- 更新 durable model history，剥离 sidecar。
- 实现一次 typed correction 和同动作熔断。

### 阶段 3：移除 Reporter（已实现）

- 删除 Reporter provider dispatch。
- 删除 providerMessages/reporting turn/usage ledger。
- 删除 submit_permission_authorization output function。
- 保留 legacy protocol decode。
- 验证 ask-class 每次少一次 acting provider request。

### 阶段 4：Reviewer 输入与 verdict（已实现）

- 添加 transient exact-args review input。
- Reviewer prompt 使用四个固定区块。
- 移除 live authorizationContext prerequisite。
- 两条 reviewer 路径共享 plain-text parser。
- Risk 完全收回宿主。

### 阶段 5：媒体、文档与 EvidenceID（部分实现）

- 已实现：图片不再触发 blanket deny。
- 已实现：PDF/图片不会为 Reporter 全量重发，主模型可在 sidecar 中提供模型自述摘要。
- 未实现：为 user/assistant/tool/document/image 输入建立 request-scoped EvidenceID manifest。
- 未实现：reference provenance lookup 与 cross-turn/generation/agent 验证。

### 阶段 6：离线回归与 App build 已完成；真实 provider/UI smoke 未运行

- focused 7-suite gate 共 162 tests / 0 failures；完整明细见第 23.8 节；
- `swift build --disable-sandbox --disable-automatic-resolution` 通过；
- 完整 `swift test --disable-sandbox --disable-automatic-resolution` 第一次在 Codex 工作区沙箱内因既有
  WebKit/Seatbelt/terminal 环境限制失败；该次还暴露一个仍按旧 Reporter 行为编写的 reliability fixture，
  fixture 随本轮流程修正。不能把第一次运行写成源码全绿；
- 随后在用户批准的工作区沙箱外，用相同完整 `swift test` 命令重跑并 exit 0；独立 xctest 复核
  `IntatisCoworkTests` 362/362、`IntatisAgentKernelTests` 210/210；新增 focused
  `OrchestrationReliabilityTests.testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer` 1/1；
- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.40 (build 40)`；`IntatisMac` macOS Debug unsigned 与
  `IntatisiOS` generic Simulator Debug unsigned build 均 exit 0，仅有仓库既有 warnings；
- Chat Completions、Responses/OpenRouter exact route 的真实 provider sidecar smoke 尚未运行；本轮也没有
  运行 UI/manual switch smoke 或真实大 PDF/长上下文 cost/latency 测量。

## 23. 测试矩阵

### 23.1 Provider wire

- Chat Completions tool schema 包含 sidecar。
- Responses tool schema 包含 sidecar。
- strict function 的 sidecar 在 `required` 中，且所有 properties 均 required、additionalProperties=false。
- 不存在 reporter-only tool。
- 不设置 response_format。
- 不依赖 forced reporter tool_choice。
- fragmented JSON arguments 可正确重组。
- namespace children 递归装饰。
- deferred business tools 在 tool_search 后仍被装饰。
- strict route 支持/不支持均有 typed 行为。
- 保留字段冲突不覆盖业务 schema。

### 23.2 拆包与业务不变量

- Sidecar present/absent/不同文案时 business canonical args 完全一致。
- Digest/count/intent/paths/network/preview/authorization identity 一致。
- additionalProperties:false 的原 schema 在剥离后通过。
- Executor 永远看不到保留字段。
- Sidecar 不进入 denial signature。
- Empty-business-object tool 拆包后仍得到合法空对象。

### 23.3 主模型 Sidecar

- 用户消息摘要。
- 上一轮 assistant 计划摘要。
- ToolResult 进展摘要。
- PDF page/chunk 摘要。
- 图片视觉摘要。
- scope/uncertainty。
- 多证据、多来源。
- 当前可验证：secret、control characters 与结构错误。
- 后续 EvidenceID gate：伪造 EvidenceID、跨 agent 私有引用。
- 后续 route-derived size gate：完整 sidecar 超预算。

### 23.4 多工具批次

- 一个 assistant generation 返回两个以上 calls。
- 每个 call 有独立 sidecar。
- A malformed 不污染 B。
- A deny 不把 sidecar 用于 B。
- parallel 和 serial path。
- duplicate/empty provider call ID 经 uniquing 后仍正确绑定。
- cancellation 和 fresh generation 不复用旧 sidecar。

### 23.5 Reviewer

- Reviewer 收到 exact canonical business arguments。
- Reviewer 不收到 providerMessages。
- Reviewer 不收到整份 PDF/图片。
- Reviewer 收到主模型压缩的 PDF/图片证据。
- Hard deny 不到 reviewer。
- Sidecar 不能覆盖 gate/lease。
- Plain ALLOW/DENY 正例。
- JSON、code fence、多 marker、无 marker、无 completion、length stop 反例。
- Host risk 不受模型文本影响。
- Live reviewer reason 与 provider diagnostic 不进入 durable settlement/tool-result。
- Active/cached duplicate 必须携带 exact invocation；recovered allow 不重新交付。
- Dedicated host agent-admission 正例与伪造 task kind/identity/prior-events 反例。
- Injected in-engine reviewer 不能取得 Cowork execution authority。

### 23.6 持久化与恢复

- EventLog 不出现 raw sidecar。
- EventLog 不因 review 永久保存 exact secret-bearing args。
- Sidecar digest/status 可审计。
- Durable model history 保存剥离后的 business args。
- Old v0.47 events 继续 decode。
- Crash 后 orphan review deny，不重放旧 allow。
- Pre-request missing/malformed/secret-bearing sidecar 只有 failed/runtimeFailed tool_result，没有 permission lifecycle。
- permission_review_settled 先于 allow delivery。
- tool_execution_prepared 先于 executor。

### 23.7 成本与稳定性

- 每个 ask-class call 的 acting provider dispatch 从两次降为一次。
- Reporter token usage 归零。
- 长对话不因固定消息数拒绝。
- PDF 不重复进入 reporter request。
- 图片不会仅因存在而 blanket deny。
- 真实 route sidecar compliance。
- sidecar missing → missing → valid 的相同 business args 可进入 reviewer 并成功。
- missing/malformed/secret-bearing 不进入 reviewer denial fuse；整轮仍受 AgentLoop iteration 上限约束。

本节是完整测试矩阵，不表示这些项目已经全部运行；真实 route sidecar compliance 当前明确未运行。

### 23.8 本轮实际验证结果

| Suite / command | 结果 |
| --- | --- |
| `PermissionReviewControlPlaneTests` | 47/47 |
| `AgentLoopPolicyTests` | 37/37 |
| `AutomaticPermissionReviewTests` | 35/35 |
| `DurableMultimodalAgentLoopTests` | 9/9 |
| `AuthorizationSidecarTests` | 12/12 |
| `IntatisPermissionReviewerTests` | 10/10 |
| `PermissionReviewProtocolTests` | 12/12 |
| focused 合计 | 162 tests / 0 failures |
| `OrchestrationReliabilityTests.testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer` | 1/1 |
| `swift build --disable-sandbox --disable-automatic-resolution` | exit 0 |
| 完整 `swift test --disable-sandbox --disable-automatic-resolution`（Codex 工作区沙箱内首次） | WebKit/Seatbelt/terminal 环境限制失败；并暴露、随后修复一个旧 Reporter reliability fixture |
| 同一完整 `swift test`（用户批准的工作区沙箱外重跑） | exit 0 |
| 独立 `IntatisCoworkTests.xctest` | 362/362 |
| 独立 `IntatisAgentKernelTests.xctest` | 210/210 |
| `xcodegen generate` | exit 0 |
| `scripts/check-version-consistency.sh` | exit 0；`0.40 (build 40)` |
| `IntatisMac` macOS Debug unsigned build | exit 0；仅既有 warnings |
| `IntatisiOS` generic Simulator Debug unsigned build | exit 0；仅既有 warnings |
| opt-in real provider sidecar smoke | 未运行 |
| UI/manual permission switch smoke | 未运行 |

首次沙箱内失败与最终沙箱外通过属于不同环境证据，二者都必须保留；最终通过不能抹掉首次环境限制，
首次失败也不能被误写成当前源码在允许其既有 WebKit/process/terminal 测试边界的宿主环境仍失败。

## 24. 验收标准

实现只有同时满足以下条件才可视为完成：

1. 正常成功路径只有一次主模型 provider generation。
2. 该 generation 的每个 ask-class ToolCall 都携带并绑定自己的 sidecar。
3. 不存在 PermissionAuthorizationContextReporter live dispatch。
4. Reviewer 收到与 executor 一致的完整安全 canonical business arguments。
5. Reviewer 收到主模型的一条 untrusted String 说明；宿主不另行发送或截取对话/PDF/图片/ToolResult。
6. Reviewer 不收到 acting providerMessages、完整 transcript、整份 PDF 或全量图片。
7. Sidecar 与 business args 在任何 authorization/execution identity 上严格分离。
8. Hard deny、CapabilityLease、WorkspaceLease、PathConfinement 不受影响。
9. Sidecar 缺失不会变成隐藏的 authorization_context_unavailable；会产生明确可纠正的 typed failure。
10. Missing/malformed/secret-bearing sidecar 不进入 denial fuse；相同 business args 补正后仍可送审。
11. 多 call batch 不串 sidecar。
12. 图片存在不再自动拒绝。
13. 不存在固定 36 条消息或 420/700/1200 字符裁切证据后继续审查的 live 合同。
14. Reviewer verdict 不依赖 JSON/function/response_format。
15. Reviewer allow 必须 durable settled 后才能交付。
16. Allow 后仍完成 authorization/workspace revalidation 和 durable execution prepare。
17. v0.47 历史 JSONL 继续解码。
18. Manual/nonautomatic reserved field 在业务执行前 redacted fail closed。
19. Pre-request missing/malformed/secret-bearing sidecar 只写 failed/runtimeFailed `tool_result`，没有 permission lifecycle。
20. Active/cached/recovered delivery 复验 exact invocation，recovered allow 不重新交付。
21. Invocation-free host agent admission 只能走专用入口，并核对 exact durable admission evidence。
22. Live reviewer reason/provider diagnostic 不把 transient input 回显进 durable state。
23. Cowork 误注入 in-engine reviewer 的结果 fail closed，不能替代 control plane。
24. Focused suites、SwiftPM build 与允许既有 process/WebKit/terminal 测试边界的完整 suite 通过。

当前状态：上述源码实现与 offline 验收已经完成。focused 162/162、SwiftPM build，以及本次 strict-schema
correction 涉及的 AgentKernel 217/217、Knowledge 118/118、Cowork 364/364、CLI 45/45（8 skipped）均通过。
本次完整 SwiftPM test 在 Tools 223/223 后挂于既有 SharedUI async waiter并人工中断；此前沙箱外完整 test、
XcodeGen、版本一致性、macOS/iOS Debug unsigned build 的历史通过证据仍按第 23.8 节保留。真实 provider
sidecar smoke 和 UI/manual switch smoke 明确未运行，它们是当前线上 route/交互证据缺口，不能从 offline
suite 或 build 外推。route-derived sidecar byte ceiling 和 `review_input_too_large` admission 仍是明确后续能力，
不得写成已实现。

## 25. 余留风险与明确接受的取舍

### 25.1 主模型可能遗漏或错误总结

这是选定方案最重要的剩余风险。Reviewer 只看到主模型压缩后的自然语言上下文，不可能证明主模型
没有漏掉一条较早的撤销或限制。

本设计选择接受该风险，因为：

- 主模型是做出动作决策时上下文最完整的语义主体；
- 重新调用主模型代价和故障率过高；
- 宿主机械裁切不能真正理解语义；
- deterministic gate、lease、path 和 execution boundary 仍然终局；
- Reviewer 仍能识别明显越权、无关、过宽或危险动作。

若未来需要更强安全模式，可以增加 host-selected canonical user anchor 或 multimodal reviewer，但不能
悄悄改变本报告选定的默认信息流。

### 25.2 Reviewer 可能相信错误的 PDF/图片摘要

PDF 和图片摘要来自主模型，不是原始证据的第二次独立解析。该取舍换取：

- 不重发整个 PDF；
- 不要求 reviewer 必须 multimodal；
- 不因图片存在而完全失去自动审查；
- 显著降低 token 和延迟。

高风险部署可选择更严格的人工模式或未来的 exact attachment review。

### 25.3 Exact args 与隐私

Reviewer 需要完整参数才能判断精确动作，但这扩大了相对于 digest-only 的参数出站范围。因此必须：

- 使用同一用户配置的 reviewer binding；
- 禁止明文 secret；
- 使用 credential references；
- reviewer transient exact-args 副本不进入 permission lifecycle；stripped business call 仍按既有安全规则
  持久化；
- 当前没有 input-size admission；未来一旦由真实 route budget 派生 ceiling，必须对 oversized args 整份
  fail closed，不能截断后继续；
- 为相关 egress 增加可观察性。

### 25.4 仍存在的 P2 / 信任边界

1. **普通 assistant 文本不是 sidecar channel。** raw reserved field 会被剥离，但 acting model 可以自行把
   相同摘要复述为 ordinary assistant prose；该文本继续按既有消息/model-history 规则持久化。当前没有
   可靠的语义去重器，也不应假装字符串匹配能证明两段文本等价。
2. **Malformed acting-provider error preview 仍走通用边界。** sidecar codec 只处理成功解析到的 tool-call
   arguments；provider-specific malformed payload、partial prose 或 error preview 依赖全局 bounded/URL/secret
   sanitizer。本轮为 reviewer provider diagnostic 增加 fixed host text，但没有证明所有 acting-provider adapter
   错误形状都不会回显输入，后续需要 adversarial adapter/error fixture。
3. **不能凭空发明固定 byte ceiling。** 当前 live codec 没有固定 sidecar ceiling，也没有
   `review_input_too_large`。未来必须从 exact route context window、host prompt overhead、safe completion reserve
   与 adapter encoding 共同推导，超限时整份 fail closed，不能恢复 420/700/1200 字符式裁切。
4. **误配 in-engine reviewer 仍可能多调用一次。** `AgentLoop` 在 `PermissionEngine.decideDetailed` 返回的
   `reviewerConsulted` 上检测并拒绝，所以错误注入的 reviewer 可能已经收到一次请求；shipping 默认 engine
   不配置该 reviewer，因此这不是正常路径，但仍是应通过 construction-time assertion 进一步消除的 P2 配置风险。
5. **Evidence reference 不是 provenance。** 当前只验证 nonempty string，不存在 request-scoped manifest/
   EvidenceID lookup；reviewer 看到的是主模型自述，不能把 reference 当作宿主证明的原始消息、PDF page、
   图片区域或 ToolResult identity。

## 26. 回滚策略

如果 sidecar 实现在线上不稳定：

- 禁用 automatic sidecar reviewer；
- 显式切回人工 permission responder；
- 保留 deterministic hard deny 和 durable execution；
- 不恢复 v0.47 的二次 Reporter；
- 不恢复全量 providerMessages 重发；
- 不把 malformed sidecar 当作 allow。

回滚不需要删除 legacy Codable 字段，也不需要重写 EventLog。

## 27. 最终确认用的单句流程

> 主模型只推理一次：它在同一个业务 Tool Call 中同时输出完整工具参数和一条简短 sidecar；宿主拆开
> 二者，使用完整 business arguments 做确定性权限与身份校验，并把精确动作、完整安全参数、这条未信任
> String 和机械 gate/lease/binding 事实交给独立权限审查模型；宿主不另行发送用户消息、assistant history、
> TaskContract 语义字段、PDF 或图片原文。审查模型只返回短理由加 ALLOW 或 DENY；allow 先持久化，再经
> authorization/workspace 重验和 durable execution prepare 后执行。过程中绝不第二次调用主模型，
> 绝不重发完整对话/PDF，绝不靠固定字符裁切拼权限上下文，也不因图片存在而直接拒绝。

## 28. 当前实施与下一步

实现已经从 v0.47 基线落到当前工作树：同次 sidecar、双视图拆包、Reporter live dispatch 移除、transient
reviewer input、permission-request receipt、plain-text verdict、媒体 blanket deny 移除、manual reserved-key
fence、correctable tool-input sidecar failure、dedicated host admission、duplicate/recovery revalidation、fixed durable reason/
diagnostic 与 in-engine misconfiguration fail-closed 均已有生产源码和 regression coverage。

验证结论是：focused 162/162、SwiftPM build、`IntatisMac` macOS Debug unsigned build、本次受影响的
AgentKernel 217/217、Knowledge 118/118、Cowork 364/364、CLI 45/45（8 skipped）均通过。当前完整 SwiftPM test 在 Tools 223/223 后挂于既有
SharedUI async waiter并人工中断，不能记为本次全量通过；此前完整 test、XcodeGen、版本一致性与
macOS/iOS Debug unsigned build 的通过证据，以及早先 WebKit/Seatbelt/terminal 环境失败历史，仍保留在
第 23.8 节。

下一步只应在获得对应授权/环境后补真实 provider sidecar compliance、UI/manual switch smoke，以及
大输入 route budget 测量。EvidenceID provenance lookup、route-derived sidecar byte ceiling 与
`review_input_too_large` admission 是明确后续项；ordinary assistant text 复述、acting-provider malformed error
preview 和 injected in-engine reviewer extra-call 也是已记录 P2，除非用户扩大范围，否则不得在本轮文档中
伪装成已解决。
