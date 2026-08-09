# ARCHITECTURE

文档状态：当前架构规范
最近核对：2026-08-09
产品基线：v0.40（build 40）

文中较早的 v0.x 只表示能力最初引入或兼容格式冻结的里程碑；除明确标为历史的段落外，
当前架构判断以本文件、源码和 `project.yml` 为准。

## macOS 发行架构边界

macOS 唯一发行 App 是 Developer ID 签名、公证和直接分发的 `IntatisMac`。
Mac App Store / App Sandbox 不再是产品架构分支；不得为了它裁剪本地
terminal、Git、global Skills、stdio MCP、浏览器 helper 或其他 Code/Cowork
能力。源码中的 `IntatisMacAppStore`、`.macAppStore` 与对应 entitlements
仅是遗留实现，不属于当前产品矩阵或默认验收。完整决策见
[`MACOS_DISTRIBUTION.md`](MACOS_DISTRIBUTION.md)。

这里取消的只是 Mac App Store App Sandbox 产品约束。PermissionEngine、
Capability/WorkspaceLease、PathConfinement、SecretScanner、durable execution、
managed terminal 的 workspace-scoped Seatbelt/default-network-deny、
Hardened Runtime、签名/公证与 iOS target 边界仍是当前架构。

## 2026-08-08 Cowork 自动权限审查授权上下文

automatic ask-class exact tool call 不再只把当前 `TaskContract.objective` 当作完整授权语义。
在 ToolRegistry 已解析 exact registration/normalized arguments/intent/action preview/lease membership、
deterministic gate 不是 hard deny，且 execution revalidation 通过后，`AgentLoop` 为该单一 tool call
执行一次 request-owned 的授权上下文报告：

```text
acting agent exact provider-facing request snapshot
  + current assistant tool-call batch
  + host-resolved exact action facts
  + temporary handles for genuinely visible canonical user messages
  -> same acting provider/model, tools=[]
  -> five-field untrusted PermissionAuthorizationReport + user handles
  -> host maps handles to same-session user_message EventLog seq
  -> always include current submission and close every visible user turn
     from the earliest cited instruction through the current instruction
  -> PermissionReviewCausalContext.authorizationContext
  -> PermissionReviewControlPlane independently replays/validates evidence
  -> reviewer sees separate report / canonical latest instruction /
     supporting-user-evidence blocks
```

`PermissionAuthorizationReport` 只由 requesting agent 的同一模型生成，字段为 authorization goal、
current progress、latest-instruction interpretation、exact-action justification 和 scope assessment；它是
未经信任的解释，不是授权。用户原文和 durable sequence 只来自 complete-known EventLog，模型只能返回
本次请求的临时 handle；report author 使用既有 `requestingAgent`，exact action/session/task/turn/toolCall/
arguments digest/gate/lease 使用既有 `ResolvedToolAuthorization` 与 review task 结构，协议不复制
`latestUserInstruction`、`reportAuthor` 或 `bindingDigest`。

报告请求不进入普通 `AgentLoop`、TaskGraph、scheduler、MessageBus、UI bubble 或后续 model history，也
不跨 tool call 缓存；同一 assistant batch 的每个 automatic ask-class call 各自生成并绑定报告。manual
permission、deterministic allow/deny 和 host-originated `agentAdmission` 不运行该 reporter。报告 generation、
严格 JSON、secret scan、handle mapping、complete-known replay、evidence closure、budget、timeout 或 cancel
任一步失败时，permission request 仍按既有 durable lifecycle 登记，但 control plane 在调用 reviewer provider
前以 typed `authorization_context_unavailable` deny；不得切换人工 fallback，也不得放宽 gate/capability/
workspace ceiling。旧 JSONL 缺少 additive optional wrapper 时继续解码；新的 live model-authored automatic
request 缺少完整 wrapper 必须 fail closed。

## 2026-08-02 本地诊断导出架构

```text
Settings 底部按钮
  -> NSSavePanel（用户明确选择本地目标）
  -> MainActor 冻结 app/build/OS/session-root 快照
  -> utility task 并行、限量读取已知诊断源
  -> EventLog 结构投影 + 全来源敏感信息清洗
  -> owner-only 临时目录与 manifest/error ledger
  -> /usr/bin/ditto 生成有界 ZIP
  -> owner-only 原子写入用户选择位置
```

导出是用户触发、纯本地、只读诊断流程；不存在 upload client、远端目的地或隐式
provider 请求。session canonical truth 不被复制：导出器对每个现存
`events.jsonl` 使用 no-follow/current-UID/single-link 检查和有界尾部读取，仅输出事件
类型、序号/时间/correlation 与允许的 typed 状态字段，所有正文、工具输入/输出、
路径、URL 和 secret 字段都以结构规则丢弃或脱敏。空 session（只有锁文件）不是采集
失败，也不产生虚假 warning。

每个采集器都有独立数量、时间与字节上限；输出超限保留最新的完整记录并标记
truncated。unified log、proxy、hang、crash 或某个 session 读取失败时，其他来源继续，
并把失败写入 `manifest.json` / `collection-errors.json`。临时目录、成员文件和最终 ZIP
均为 owner-only，拒绝 symlink/hardlink 形状；进程 runner 使用绝对可执行路径、最小
环境、并发 bounded stdout/stderr drain、timeout/cancel 和 TERM/KILL 清理。该功能不
新增或修改 EventLog schema，不进入 iOS target，也不改变 PermissionEngine 或运行时
权限决策。

## 2026-08-02 自动权限瞬时故障恢复边界

自动 reviewer 的 provider failure/timeout 对当前工具调用仍是 durable deny，不能直接
执行工具。若该 terminal 带 typed `automatic_reviewer_failure`，且 failure kind 精确为
`provider_failure` 或 `reviewer_timed_out`，`AgentLoop` 可让模型的第一个 exact retry
创建一个全新的 permission request/reviewer generation；fresh allow 只有 durable
settlement 与 authorization revalidation 成功后才能进入 execution prepare。这个额度
每个 denial signature 最多一次，后续失败重新进入普通 cached-denial/terminal fuse。
显式 user/policy/reviewer deny 以及 malformed、cancel、persistence、shutdown、lease 或
authorization failure 永远不使用该恢复路径。

OpenAI-compatible tool-calling stream 的“响应已开始”按 accepted non-error payload
判断，不按原始 socket bytes 判断。仅 error-only、retryable SSE frame 且此前没有接受
任何 payload 时可在 `ProviderRuntimePolicy.maxAttempts` 内重试；文本、tool delta、usage、
completion 或任意其他有效 payload 一经接受就不得重放。这是下文旧“首个 response
byte”简写在 tool-calling 路径上的精确解释；普通 Chat streaming 的既有策略不在本次
变更范围内。

## 2026-07-28 Code / Cowork replacement-history compaction

稳定模型线程不再无限回放所有历史 item。稳定 Code conversation 与 Cowork
`@main` 在 exact model context policy 可证明时，按 Codex 的本地
replacement-history 结构执行
pre-turn / mid-turn 压缩，同时保留 Intatis 的 EventLog-first 持久化：

```text
complete-known EventLog replay
  -> latest valid model_history_compacted checkpoint + surviving suffix
  -> normalize function-call/output pairs for request copy
  -> freeze the exact request-owned dynamic tool snapshot
  -> estimate total active context
  -> pre-turn: compact before current user/context is recorded
     or mid-turn: compact after tool outputs when another sample is required
  -> same exact provider/model, summary-only request, tools=[]
  -> summary (no synthetic output ceiling; known usable window or explicit
     token budget derives a requested + host-enforced bound)
  -> newest real-user suffix (<= 20k approximate tokens,
     dynamically reduced to fit the usable window)
     + current canonical contextual items when mid-turn
     + continuation summary as final user-role item
  -> reconstruct canonical prefix + replacement + exact frozen tools
  -> require estimated input <= 95% usable window
  -> EventLog appendModelHistoryCompaction CAS
  -> durable checkpoint commit
  -> live request history swap
  -> next provider dispatch
```

`model_history_compacted` 是 additive provider-facing checkpoint，不是 UI 气泡
或审计摘要。它包含完整 replacement items、summary、单调 window number 与
UUIDv7 first/previous/current lineage；Conversation/Code/Cowork UI projection
对该事件保持 no-op。Protocol 编码/解码边界验证 schema、v1 item shape、summary
和 UUIDv7，EventLog 在 per-agent CAS 后、WAL/JSONL 前验证完整连续 lineage，
且 generic append 无权写入该事件；projector 再验证 accepted user provenance、
contextual placement 与 checkpoint coverage。恢复器只接受可证明的最新链，
随后只重放其后的存活尾部。同一 agent 的历史 CAS 失配、unknown future event、
seq gap、损坏 payload 或持久化失败都会阻止 live swap 和后续 provider
dispatch。

user-role model item 明确分类为 `real_user`、`contextual` 或
`compaction_summary`。Skill 正文、任务 context 等 contextual item 可以进入
摘要输入，但不进入 20k 真实用户原文保留区；summary 永远是 replacement 最后一
项。Code direct history 使用 `taskID == nil` 和稳定 SubmissionID，Cowork
`@main` 使用 root task/submission/assignee/attempt provenance；task-scoped
worker、reviewer 与 GoalVerifier 不继承或压缩主线程历史。

model context policy 只来自 exact immutable inference route 的显式 metadata。
默认 total-scope auto threshold 是 raw/max context window 的 90%，usable hard
threshold 是 95%，两者实际取较早值；95% 同时是 checkpoint 落盘前对
canonical prefix + replacement + 下一普通请求已冻结 exact 工具 schema 的
postcondition。首轮 pre-turn 与工具执行后的 mid-turn 都先取得 request-owned
snapshot，用同一份 provider specs 判断/压缩并精确复用于对应普通 dispatch；
snapshot 失败不会回退 base registry。
20k real-user retention 只是上限，窗口较小时动态收缩；replacement window
未知且无显式 token budget 时，summary 请求不注入 output-token ceiling。
只有已知 usable window 或显式共享预算存在时才派生 provider request，host
同时在 append 单个 stream delta 前执行对应的 provider-neutral 实际输出
bound，并在 replacement 前以 `SecretScanner` 拒绝已知 secret-like material；
provider 忽略真实 constraint 或替换后仍超限都会 typed fail closed。
context overflow retry 永久保护连续 leading system/developer 前缀，且只从
mutable clone 删除最老逻辑项；tool-call batch 只连带删除紧邻 matching
outputs，不能按复用 call ID 跨 Turn 全局删除。
raw/max window 未知但 exact metadata 明确给出 `auto_compact_token_limit` 时，
只使用该显式 trigger，不虚构 95% hard window；窗口和显式 limit 都未知、route
歧义或 legacy binding 才关闭自动触发。压缩 usage 进入同一 Turn 的统计和共享
软预算，但压缩不消耗
`maxIterations`。当前未实现 `body_after_prefix`、
`comp_hash` 切模时 previous-model compact、remote compact、Codex 同构
world-state patch/rollback/fork；这些不能被当前主链表述为全量 Codex parity。

## 2026-07-27 Code / Cowork Skill capability

`IntatisSkills` 把 Skill 建模为有界上下文能力，不是新的执行权限。生产链路按
Codex 的 catalog → activation → progressive resources 三层组织，但由 Intatis
独立实现并继续服从现有安全边界：

```text
host-approved roots
  -> canonical bounded discovery + SKILL.md frontmatter validation
  -> secret/path/symlink/UTF-8/size checks
  -> immutable per-send / per-AgentInvocation SkillSnapshot
  -> bounded developer-role catalog (name/description/opaque skill_id/source)
  -> unique explicit $name => full frozen SKILL.md as user contextual fragment
     or model-selected activate_skill => ordinary frozen tool result
  -> read_skill_resource => one frozen UTF-8 resource
  -> ToolRegistry schema + registryVersion(snapshot digest)
  -> PermissionEngine + durable prepare/result/settlement
```

catalog 使用 developer role；完整 Skill 正文只在当前 turn 的显式无歧义
`$name` 中作为 user contextual fragment 注入，或由模型调用
`activate_skill` 后作为 tool result 返回。OpenAI Chat Completions 与 Responses
wire 都原样保留 `developer`；不支持该角色的兼容端点明确失败，不做
system/user 角色降级。catalog、正文和 resource 都不能覆盖 system policy、
identity、CapabilityLease、WorkspaceLease、PermissionEngine 或 provider
request 的 authoritative tool list。

一次 Code send 或 Cowork AgentInvocation 只生成一个 snapshot；同一 invocation
中的后续 provider/tool 轮次及 MCP catalog 组合继续使用该 exact snapshot。
registry version 含 snapshot digest，因此旧 response 不能绑定到更新后的 Skill
正文。Cowork 每个 agent 按自己的 canonical workspace 与 exact WorkspaceLease
独立发现；parent 已加载正文不传给 child。`@permission-reviewer` 和
GoalVerifier 不进入普通 AgentLoop，仍固定 `tools: []`，不会看到 catalog 或
Skill tools。

workspace roots 是从 agent workspace 到 current directory 的
`.agents/skills`（当前 host 的 current directory 等于该 exact workspace）。
DeveloperID/CLI 显式开启 Codex-compatible user/legacy/system/admin roots；
遗留 App Store target 的 workspace-only 分支不再构成产品约束。iOS 不链接
`IntatisSkills`。Skill tool 不增加 `ToolCapability`，不授予 filesystem、
shell、network、MCP、communication 或 delegation；Skill 中描述的任何动作仍
只能使用当次请求真实出现的普通工具。`read_file` 不作为 Skill 读取兜底，
resource 只能以 opaque Skill ID + relative frozen path 读取。

当前实现是本地、文本型第一阶段：没有 Skill 管理 UI、per-agent durable
enable/disable、plugin/remote Skill provider、filesystem watcher、二进制 asset
读取或直接执行 global Skill script。为与 AgentLoop 的 64 KiB durable tool
output 上限一致，单个 `SKILL.md` / UTF-8 resource 当前固定不超过 48 KiB。
同一 invocation 中所有 `activate_skill` / `read_skill_resource` 的返回正文按
共享、原子预算累计，默认总计不超过 192 KiB，重复或并行读取也会计费。
catalog metadata 预算由 exact inference route 一并冻结，使用 canonical
primary `contextWindowTokens`：Codex `context_window` 优先，缺失时可由显式
OpenCode `limit.context` 补位。该 primary 可知时采用 pinned Codex Core 的
`max(1, floor(primary × 2%))` approximate-token budget；两者都缺失或非法时
使用 8,000 字符。不会按 model slug、`max_context_window` 或自动压缩窗口猜
catalog 预算，也没有 ext/skills 路径的额外 4k cap。renderer
只把 Skill metadata 行计入该预算，trusted developer envelope 不计；冻结
snapshot 保存不含名称、路径或正文的 kept/omitted/truncated count metrics 与
warning，catalog 自身保留 omitted marker。metrics/warning 目前没有
App/CLI/EventLog consumer，renderer 也保持 Intatis 的公平截断实现，并非 Codex
逐字节同构。

可选 `agents/openai.yaml` 只解析有界的 `dependencies.tools` MCP 子集。无歧义
显式 `$name` 会先冻结首个 ordinary request 的完整 dynamic tool snapshot；
模型调用 `activate_skill` / `read_skill_resource` 时则使用将接收该调用结果的
request-owned snapshot。只有其中 exact server ID 与
transport-locator fingerprint 成对匹配，正文/资源才可披露；没有 MCP host、
无效 metadata、同名 server 改 endpoint 或 live/config-only 状态均 fail
closed。snapshot 只携带 server/tool identifiers 与不可逆 locator fingerprint，
不携带 endpoint、command、header、credential 或 query。Intatis 当前不实现
Codex 的 Install/Continue-anyway、OAuth、外部配置持久化和 runtime refresh，
这是有意保持的更窄边界，而不是隐式兜底。production availability 只从该请求
经过 capability/policy 过滤后的 `MCPAgentToolCatalogView.entries` 构造；server
必须至少贡献一个当前 agent-visible tool 才可能形成 assertion。低层 `.frozen`
factory 是 trusted host construction seam，不是自认证或网络握手证明；手工构造
它的 deterministic tests 不能冒充真实 MCP E2E。
Intatis 对目录 symlink 采取比 Codex 更严格的 fail-closed 策略；不能把当前
实现描述为全部 Codex feature parity。

`IntatisSkills` 另通过 SwiftPM resource bundle 发布 host-authored
`cowork-agent-orchestration`。`SkillDiscoveryConfiguration.standard` 把
`Bundle.module/BundledSkills` 作为 bundled root 交给既有 discovery；在允许
system roots 的 Developer ID / CLI host 中，它以 system-scope catalog entry
进入每次 Cowork AgentInvocation 的 frozen snapshot。iOS 不链接该 target，
permission reviewer 与 GoalVerifier 仍无 catalog/tool。Bundle 缺失时返回空 root，
不改为读取 workspace 同名文件。

可协调 agent 的固定 system prompt 以主动推进为默认：先建立本轮执行目标、交付物、约束与验证方式，
检查 bounded catalog 并激活/读取明确相关的 exact Skills；非简单任务在 tools 可用时维护最小
WorkTask DAG，并在开始时识别可并行、专业复核、多模态或不同 workspace 分支。满足 Skill 的收益门槛
后应尽早委派，在 child 运行时继续 coordinator 自己的关键路径，再核验报告、显式结算 WorkTask，
持续到结果经验证或只剩真实 blocker。普通请求的 execution objective 不等于 durable Goal；只有用户
明确要求持续/跨 run 目标时才能调用 Goal create 路径。主动性也不放宽 authoritative tool list、
CapabilityLease、WorkspaceLease、PermissionEngine、exact inference binding、最小 team/lease 或
child-report 非权威边界，普通 worker 的 system prompt 不包含 coordinator 行为。

只有可协调 agent 的 system prompt 会要求：在 direct、agent reuse/spawn、
WorkTask delegation、child inference profile 或 child lease 决策前，按 exact
name + `scope="system"` + `system:bundle-` source 选中 catalog entry，并以 opaque
`skill_id` 调用 `activate_skill`。这里 system prompt 只建立激活义务，不携带
Skill 正文或 routing table；正文仍只作为普通 frozen tool result 返回。缺失、
omitted 或 activation failure 时不接受同名 workspace/user 替代，而是采用
direct + exact-profile inheritance + read-only + no-child-coordination 的保守
fallback，除非任务本身明确必须新建 agent。

Skill 把调度意图分为 `cost-first`、默认 `cost-efficient-balanced` 与
`efficiency-first`，并优先最小 team/最小 lease。只有确实考虑不同 child profile
时才要求先调用 `list_inference_profiles`，再读取 dated
`references/model-routing.md`；实际 authority 始终是该次 host-approved exact
profile IDs 及其 configuration-declared capabilities，reference 不能推导
endpoint、credential、wire、capability、context limit 或权限。macOS/CLI host 从
既有 JSON model `capabilities` 生成 runtime-only
`InferenceProfileRoutingMetadata`；`list_inference_profiles` 只披露 safe profile
identity、model/variant 与这些声明，不披露 route 配置或 secret，也不把元数据写入
EventLog/binding。缺失声明显示 `unspecified`，不得按名称猜测。

reference 内的正式矩阵覆盖 OpenAI、Anthropic、Google、Meta、xAI、Mistral、
DeepSeek、Kimi、Z.ai、MiniMax、Qwen，并按 cost-first / balanced /
efficiency-first / multimodal companion 给出 dated family anchor。它先与
`list_inference_profiles` exact IDs、declared capabilities、active lifecycle 取交集
才可使用；stable 默认优先于 Preview，开放权重/第三方托管 route 的价格与 wire
能力必须来自实际 host。矩阵不能修改 JSON schema，也不能把 provider 品牌或模型名
转换成隐式 capability。

profile 选择顺序是 required capability → active/stable lifecycle → task adequacy →
较新 generation preference → 按调度模式权衡预计总成本/延迟。main 缺少任务所需
multimodal capability 时，必须搭配 exact listed、明确声明能力的副 agent；副 agent
默认 read-only 且无 coordination。若实际 attachment/artifact 不能进入该 child
invocation，分支必须报告 blocked。`delegate_task` 不负责切换 profile；不同 exact profile、
write-capable 或需要持久身份的 worker 必须走显式 `spawn_agent` 后再委派。
本能力不新增配置字段、UI、事件 schema、ToolCapability 或权限捷径。

## 2026-07-27 外部 MCP Server 客户端

Intatis 只实现连接外部 MCP Server 的客户端角色；没有 Intatis MCP
Server target、server transport、server OAuth、server executable、hosting
API 或产品入口。SDK 中保留的 sampling、elicitation 和 client-hosted Tasks
handler 是外部 server 向 client 发起的标准 request，由客户端宿主受控处理，
不构成 MCP Server。开发期 `IntatisMCPConformanceClient` 也只是 official
client conformance driver，不进入发行产品。

平台/target 边界如下：

| 产品 | External MCP client core | Streamable HTTP / OAuth | stdio | 产品表面 |
|---|---|---|---|---|
| `IntatisMac` | `IntatisMCP` | `IntatisCurlTransport` | `IntatisMCPStdio` + `IntatisMCPStdioGuard` | Code/Cowork 设置、会话内容与审批 |
| `intatis` CLI | `IntatisMCP` | 原生 HTTP/OAuth | `IntatisMCPStdio` + guard | 管理命令、Code/Cowork exact-session owner |
| `IntatisiOS` | 不链接 | 不链接 | 不链接 | 无 MCP runtime、transport 或产品 UI |

`IntatisMacAppStore` 的 HTTP-only linkage 仍可能存在于当前源码图，但它是
legacy/non-shipping target，不属于上表的产品架构或验收矩阵。

`IntatisProtocol` 中 SDK-independent、可旧日志解码的 MCP payload 仍可由共享
模块编译；这不等于 iOS 获得 MCP 客户端能力。

每次模型 dispatch 的主链是：

```text
global MCP catalog
  -> session attachment + exact per-Agent MCPGrant
  -> session-owned MCPSessionRuntimeOwner
  -> authority-isolated connection generation
  -> complete raw catalog snapshot
  -> lease/filter constrained Agent catalog view
  -> immutable AgentRequestToolSnapshot
  -> direct tools or Codex-compatible tool_search
  -> AgentLoop + three-layer PermissionEngine
  -> durable tool_execution_prepared
  -> exact live authority/grant/schema/catalog/binding revalidation
  -> external MCP call
  -> bounded/redacted result or ArtifactStore reference
  -> durable settlement
```

`MCPRawCatalogRevision`、`MCPAgentCatalogViewRevision`、`MCPBindingID` 与
`MCPConnectionGeneration` 各自表达不同事实。provider response 只能回到生成
它的 immutable snapshot route；catalog refresh、grant/lease/revision/authority
变化或 revocation 都不能把旧 call 重绑定到新连接。Cowork child grant 只能是
parent 与 child lease 的显式交集，worker 默认无 MCP；permission reviewer 与
GoalVerifier 永远无 MCP。

Streamable HTTP 使用原始 origin、request-time DNS 冻结与原生 libcurl socket
binding；默认 direct、无 cookie/cache、受控 redirect、无自动重放已发送
operation。响应头中的 `MCP-Session-Id` 在任何 JSON/SSE body 发布前同步校验并
注册进 session exact-value redactor。OAuth 绑定 exact origin/resource/account/
scope/generation，token refresh single-flight；macOS MCP secret 使用
Security.framework data-protection Keychain，CLI 使用 owner-only 认证加密
store，EventLog/catalog 只保存 opaque reference。

stdio 由 runtime-owned process owner 启动。macOS 以 Seatbelt 限定 workspace、
launch artifact 与 exact generation-local network gateway；Linux 使用 bwrap
与 seccomp/ptrace guard 跟踪 fork/clone/exec/connect，并由宿主完成 exact
sockaddr connect。gateway 的本地 `serve` 只处理有 generation credential 的
CONNECT egress tunnel，不解析 MCP JSON-RPC，因此不是 MCP Server。取消、
timeout、task terminal 与 runtime shutdown 都先 drain 子进程/transport，再
发布上层 terminal。

所有外部 server 文本、URI、MIME、cursor、icon/annotation 结构字段、JSON key
和 artifact bytes 都在 session boundary 清洗；macOS reader-facing catalog
还在展示 sink 前用同一 session redactor 再校验。text/binary/structured/
artifact、单次 result、provider request 与 turn 共享有界预算，sanitization
扩张按最终字节收费；失败不得先提交 loaded state 或部分 catalog。

## 2026-07-24 Session runtime 与展示生命周期隔离

macOS session 页面明确分成三层：

| 层 | owner / identity | 内容 | session 切换 |
|---|---|---|---|
| Runtime | 进程级 `AppSessionRuntimeManager` + exact `{SessionKind, SessionID}` | provider / AgentLoop / Orchestrator / projection / permission / workspace scope | 保留并继续运行 |
| Window presentation | 每个 `IntatisMacRootView` | mode、当前 session、inspector 显隐 | 只影响本窗口 |
| Session presentation | `IntatisThreadPresentationScope` + 该窗口 thread 的 `@StateObject` | ScrollView、bottom-follow、scroll generation、临时 geometry | scope 改变即销毁/重建 |

`IntatisThreadPresentationScope` 不写入 EventLog，也不是 runtime key。相同 session 在两个窗口中可共享 runtime，但每个窗口构造独立的 scroll coordinator；任一窗口的 cancel/deactivate 不会取消另一窗口的展示任务。Code / Cowork 详情和 thread subtree 以 scope 建立 SwiftUI identity，bottom sentinel 使用 `IntatisThreadBottomAnchorID(scope:)`，因此旧 session 的 anchor 或 task 无法命中新 session。

自动滚动是一条有 owner 的可取消状态机，而不是 main-queue 闭包。每个 coordinator 最多一个 pending request，携带 scope、generation、reason 与 bottom-following snapshot；scope 改变、用户开始滚动或新请求到达都会使旧 generation 失效。initial restore 与 live/rich correction 不动画，completion 可短动画。Scroll geometry 只区分是否在 24pt bottom tolerance 内及 material content-height change。raw item signature 或 content width 变化显式开启 layout epoch；一个 epoch 可以沿第一次 shrink 降低 baseline，并在第一次 regrowth correction 后永久关闭该 recovery window，防止 `800↔900` 高度振荡重新触发无界 scroll。用户主动离开底部后不再自动跟随。

Runtime manager 不再观察 retained ViewModel 的通用 `objectWillChange`。Chat / Code / Cowork 只把业务活动折叠为 exact-key `opening / idle / running / removing` presentation status，根窗口用 subject 更新对应字典项；manager 自身 `@Published state` 只表达 process-level running/quiescing/stopped。Cowork 另把 auxiliary operation/shutdown 纳入 `runtimeBusy` 以保护删除，但 recent-session recency 的 active→idle settlement 继续只观察 conversation/agent/Goal 活动，避免设置操作改变排序。删除由 manager 的 exact-key transaction 同时包住 runtime drain、调用方提供的 session-storage commit/abort、subscription 清理与最终 `runtimeRemoved`；通知只在磁盘结果确定后发布，`.removing` 期间的 activity/settlement 也不能覆盖状态。同 key 在 fence 释放前不能 reopen。

Chat 的历史与 live publication 也分层：

```text
EventLog.replayChecked strict snapshot
  -> compute liveFrom = lastSeq + 1
  -> register EventLog.stream(liveFrom)
  -> EventLog.replayChecked(liveFrom) strict catch-up
  -> merge/dedupe snapshot + catch-up by seq
  -> ChatHistoryProjectionBuilder actor folds merged snapshot once
  -> MainActor publishes one complete ChatProjectionState
  -> buffered/live envelopes above lastAppliedSeq apply incrementally
```

先登记 live stream、再做 strict catch-up、最后折叠 snapshot，既关闭恢复期间的事件丢失窗口，也隔离了 `stream(from:)` 为兼容旧调用者保留的 fail-soft replay；catch-up 与 stream 重叠的事件以 seq 去重。builder 同时折叠 conversation、artifact progress、artifact cards 和 turn stats。首次 strict snapshot/catch-up 失败在发布或消费 live 前 fail closed，并释放 subscription slot；macOS 再进入 cached session 时 manager 的幂等 `start()` 会重试。subscription generation 由其 owning Task 的 cancellation 管理，stop/shutdown 后旧 fold 不能回写。

## 2026-07-23 会话完成度与交互态投影

Recent-session 排序不是访问历史，也不是文件系统写入历史。面向 App 的 `SessionActivityHistoryStore` 一次读取每个 EventLog，同时统计 event count 并从尾部查找已完成工作：现行 turn 只以 `turn_outcome` 为准，没有现行终态的 legacy session 才回退到 assistant / agent `message_completed`。Cowork submission terminal 不单独提升 recency，避免恢复/对账补写被误算成新对话。选择、恢复、迁移、rename 或 lease/settings append 不得改变排序；运行中的新 turn 在 terminal 落盘前保留上一次完成位置。file signature cache 只降低重复读取成本，不把 mtime 解释为业务时间。后台 runtime manager 直接订阅 published data-plane activity，在 active→idle 边沿发布 exact session settlement，窗口只刷新对应 kind。

composer 的 Send 与 Stop 是同一个主操作槽位。工作态使用 SwiftUI 原生 destructive Button、系统 `stop.fill` 和红色 tint；Chat cancel 只覆盖当前 Chat operation，Code cancel 只覆盖当前 AgentLoop turn，Cowork 普通工作使用 orchestrator task cancellation，active durable Goal 使用 GoalRuntime 的 scoped pause/checkpoint。该动作不等于 session shutdown，不关闭 EventLog subscription、runtime owner 或 permission-review control plane。Thinking 秒数是纯 presentation phase state，由可见 spinner 行的生命周期界定，不进入 EventLog、Envelope 或模型上下文。

最近自查日期：2026-07-19

## 总体架构

Intatis 是 Apple-first、Swift-native 优先的本地 AI 工作区，三个产品面：Chat（普通多模态对话）/ Code（单 agent 本地工作区）/ Cowork（多 agent 本地工作区协作）。项目允许按 `docs/OPEN_SOURCE_REUSE.md` 选择性复用兼容许可证的公开源码，但 Intatis 继续拥有自己的产品身份、权限/lease/EventLog 控制面和 Apple 平台边界。Apple 应用与 SwiftPM 声明的最低系统为 macOS 26 / iOS 26。默认 `IntatisMac` 是 DeveloperID/non-sandbox 本地 workbench，提供全量 macOS 产品面；iOS 仍是 chat 子集。

```text
                    ┌─────────────────────────────────────┐
                    │      Intatis* 内核模块（共享）        │
                    │  Core / Protocol / Providers         │
                    │  Conversation / Artifacts / Multimodal│
                    │  Tools / Permission / AgentKernel     │
                    │  Cowork / SharedUI                   │
                    └──────────────┬──────────────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
   ┌────────▼─────────┐  ┌────────▼─────────┐  ┌─────────▼──────────┐
   │  IntatisMac       │  │  IntatisiOS       │  │  intatis-cli        │
   │  Chat/Code/Cowork │  │  Chat 子集        │  │  CLI                │
   │  (全量内核)        │  │  (无 workspace)   │  │                    │
   └───────────────────┘  └───────────────────┘  └────────────────────┘
```

## 主要链路

### Chat 链路（无工具，iOS/macOS chat 子集）

```text
macOS root sidebar or iOS drawer/top New Chat -> selected SessionID -> per-session EventLog
  -> Chat composer -> GoalInputParser (/goal metadata) -> ChatLoop.send()
  -> buildHistory() from current EventLog
  -> ProviderRegistry resolves selected provider/model from GUI catalog
     + current chat selection override (provider baseURL + chatEndpoint)
  -> append userMessage -> provider.stream
  -> message_delta / message_completed -> turnStats
  -> GUI folds TurnStatsProjection -> compact composer-local latest-turn stats
（无工具、无权限、无工作区）
```

macOS Chat 的图片输入在 composer 边界复用 Cowork 的附件实现，不增加 Agent 工具或工作区能力：

```text
paperclip / file drop
  -> shared security-scoped file reader
  -> session ArtifactStore add + read-back verification
  -> UserMessagePayload.attachments stores ArtifactID only
  -> ChatLoop resolves current and historical IDs
  -> provider ImageAttachment (base64 exists only in request memory)
```

选择的文件可在草稿菜单中逐项移除，也允许仅附件 Send。文件缺失、不可读或不是 provider 可接受的
`image/*` 时，新 `user_message` 落盘前即失败并保留草稿；历史轮同样从 ArtifactStore 重新解析，不能把
base64、security-scoped bookmark 或文件路径写进 EventLog。macOS Chat composer 不再提供独立的提示词
生图 action；`generate_image` / `edit_image` 仍是 Code/Cowork 的普通 Agent 工具，iOS Chat 也不因本链路
获得通用本地附件能力。

### Composer 语音输入链路（macOS Chat/Code/Cowork 与 iOS Chat）

```text
composer mic -> ComposerVoiceInputController
  -> exact top-level transcription_model (<provider>/<model-id>)
  -> recorded-file runtime plan (WAV, 16 kHz, mono, 120 s / 25 MiB)
  -> system microphone permission -> Flotis-derived AVAudioRecorder generation state machine
  -> second tap or 120-second limit stops recording
  -> ProviderRegistry resolves the frozen exact transcription route and credential
  -> disk-backed owner-only request body
     -> compatible/legacy/OpenAI adapter: multipart POST <baseURL>/audio/transcriptions
     -> exact OpenRouter adapter: JSON input_audio(base64) POST <baseURL>/audio/transcriptions
  -> append returned text to the current editable draft
  -> clean temporary audio/body on success, failure, cancellation, or runtime shutdown
```

该路径是用户直接触发的本地 composer 输入能力，不是 model-facing tool，因此不进入
`PermissionEngine`、WorkspaceLease 或 durable tool ticket；OS 麦克风权限仍是前置条件。录音开始时
冻结 registry 与 exact `transcription_model`，但 credential 只在真正转写时懒加载。配置缺失或 route
无效、adapter 不受支持时 fail closed，不回退到当前 Chat/Code/Cowork inference model。录音 runtime
沿用 Flotis 的 recorded-file 边界：默认 WAV/16 kHz/mono，不设置 AAC bitrate；generation 防止权限回调
或取消后的旧录音复活，stop 后验证普通非 symlink 文件且非空。录音最多 120 秒、上传前最多 25 MiB，
音频与 multipart/JSON body 都是随机 owner-only 临时文件，并清理超过 24 小时的本应用 stale 文件；
转写完成、失败、取消或 shutdown 后均删除。结果只合并到完成时的当前草稿，不自动 Send；用户真正
发送前，不产生 EventLog、ArtifactStore 或 session projection 写入。该能力复用既有配置文件/importer，
没有单独的设置页，也没有迁入 Flotis 的多模型对比、全局快捷键、review/clipboard 或输入法链路。

### Code 链路（单 agent，macOS 全量）

```text
Code composer -> GoalInputParser (/goal metadata) -> AgentLoop.send()
  -> append userMessage -> agent_status(thinking)
  -> ContextBuilder.initialMessages(history + cleaned user text)
  -> provider.stream -> toolCalls -> PermissionEngine -> tool execution
  -> message_delta / message_completed / tool events / turnStats -> EventLog
  -> GUI folds CodeProjection + TurnStatsProjection
  -> macOS Code inspector shows structured plan/workspace/Git-status-only/failure/turn state
```

### Managed terminal 链路（Code / Cowork / CLI，macOS shell-capable host）

```text
model tool_call exec_command / write_stdin
  -> ToolRegistry resolves one concrete terminal tool
  -> CapabilityLease + DeterministicPolicyGate + reviewer/responder
  -> durable tool_execution_prepared
  -> exact authorization + WorkspaceLease + root identity revalidation
  -> ProcessTerminalSessionManager
     -> non-TTY: sandboxed managed pipes
     -> tty=true: IntatisPTYLauncher forkpty -> controlling terminal
     -> macOS Seatbelt workspace allow-list + default network deny
     -> bounded continuous stdout/stderr drain + timeout/cancel TERM→KILL
  -> input echo/diagnostic scrub
  -> durable tool_execution_settled + model-visible observation
```

短命令在同一次 `exec_command` 返回终态；超过初始等待但仍运行的命令返回 opaque session ID。后续 `write_stdin` 可写字符、轮询、发送 EOF 请求或终止，但不是“已有 session 就免审”：每次调用仍有独立 tool authorization/durable ticket。危险命令检查还会在进程内按 session 保留当前输入行，覆盖跨调用文字、退格、换行与反斜线续行；光标移动、补全、历史、escape 控制和 shell keymap 改写因无法可靠重建结果而 fail closed，该状态不落盘。nonblocking input 若部分写入后失败，session 立即终止，禁止用已失真的状态继续交互。session owner 必须精确匹配 session、agent、task、attempt 与 canonical workspace identity；另一个 agent/task、root replacement 或失效 lease 无权接管。root identity watcher 即使先发现替换，也要等进程真正结束并自动生成一次性内存结果，不能因 model 未再 poll 而泄漏 session。

`ProcessTerminalSessionManager` 由 Code/CLI runtime 或 Cowork Orchestrator 持有，不属于 model。它持续读取输出，避免子进程因 pipe/PTY buffer 填满而卡死；内存只保留有界 head+tail，最新 tail 优先可见。进程结束后即使 model 未再次 poll，也会从 active table 移除并留下一个有时限、只可领取一次的内存结果。task completed/failed/cancelled、单 turn cancel、session deletion 与 app shutdown 都先终止并等待匹配 terminal sessions，再写上层 terminal 状态。该 session/result 当前不跨进程持久化；crash 后不会自动续接。

PTY launcher 是仓内小型 C target。所有 Swift 参数、argv/envp 分配都在调用前完成；`forkpty` child 只执行 async-signal-safe 范围内的 signal reset、FD close、chdir 和 `execve`，并通过 CLOEXEC pipe 向父进程报告精确启动阶段错误。固定初始窗口为 24×100；本轮没有加入 resize/SIGWINCH API。

权限面仍保留 raw `run_shell` 不可见。`CapabilityLease.runShell` 在 production 只映射到 `exec_command` / `write_stdin`；read-only worker、reviewer、iOS 或 platform shell disabled 时 registry 不注册它们。终端继承最小化后的开发工具环境和临时 HOME，常见 token/password/auth/proxy/database/JWT/access-key/session-key 变量被移除；执行边界无条件把 `WorkspaceLease.mandatoryTerminalDeniedPatterns` 合并回任何新、旧或显式空的 lease，Seatbelt 对这些 denied pattern 的 ASCII 字母按大小写无关匹配，因此 caller 不能移除工作区内的常见凭据路径。交互字节不写 EventLog，授权 identity 使用进程随机盐，当前或延迟回显在 tool observation 前清洗。

### 对话内容显示链路（Chat / Code / Cowork）

```text
EventLog raw message text + Envelope.ts (single source of truth)
  -> ConversationProjection / CodeProjection
     -> first message envelope pins a stable presentation timestamp
  -> Code/Cowork presentation gate
     -> default: user + real agent message + mediated agent-to-agent communication
        + task-only fallback + actionable error
        (same-task exact task_completed mirror is trace-only)
     -> backend debug opt-in: preserve the complete prior tool/patch/note trace
  -> role policy + IntatisMessageRendererMode
     -> user / system / structured special card: existing plain or dedicated view
     -> assistant / agent + plainSafe: no upstream parser/view
        -> history/activation/reentry/correction/truncation/final: exact raw SwiftUI Text
        -> append-only intermediate snapshots: 100 ms fixed-window leading/trailing latest-only Text projection
     -> assistant / agent + microsoft: IntatisMessageContentView(.richText)
        -> first paint/current semantic revision: exact raw SwiftUI Text
        -> pending/rejected/oversize append-only fallback: same persistent 100 ms raw projection
        -> syntax-agnostic admission: non-empty and UTF-8 <= 64 KiB
        -> per-view AsyncStream.bufferingNewest(1), 50 ms incomplete debounce
        -> process-wide output-free latest-only permit scheduler
           -> max 1 running parse globally / max 32 pending message keys
           -> max 1 running + 1 replaceable pending acquire per message view
           -> scheduler retains keys/generations/continuations only, never work/results/documents
        -> audited SwiftStreamingMarkdown derivative parser/layout
           -> code-aware LaTeX preprocessor masks protected Markdown literals
              and recognizes inline $...$ / \(...\) plus display $$...$$ / \[...\]
           -> MarkdownDocumentParser.parse(... sending) off MainActor
           -> request-local math catalog carries original TeX source into the
              attributed attachment model
           -> returned non-Sendable RenderableDocument owned by MainActor
        -> publish only if raw/mode/completion/appearance/config revision is still current
           -> exact current upstream DocumentView
           -> AppKit/UIKit TextKit 2 paragraph host renders a live
              MTMathUILabel attachment through exact iosMath 2.5.0 on MainActor
           -> stale/cancelled/rejected/oversize: keep the raw projection; final remains exact
```

Code/Cowork 在进入上述内容 facade 前先经过共享 presentation publication 层：

```text
EventLog ordered envelopes
  -> SessionProjectionPump actor
     -> every envelope folds exactly once in seq order
     -> consecutive message_delta:
        50 ms fixed-window leading/trailing presentation publication
     -> every non-delta event:
        immediate barrier publication
  -> exact {sessionID, generation, throughSeq} MainActor commit fence
  -> Code/Cowork presentation gate
```

`SessionProjectionPump` 只限制展示发布频率，不合并、抽样、丢弃或重排
EventLog 输入。permission、submission、task、Goal、stats 与 terminal 等非
delta 事件立即形成 barrier。session reattach 或切换使用 fresh generation；
旧 timer、snapshot 或较低 `throughSeq` 无权写入新 presentation。

Code/Cowork 的 presentation gate 只控制哪些 `CodeItem` 进入 SwiftUI 会话树、自动滚动签名和 Code inspector。默认隐藏 `.toolCall` / `.toolResult` / `.patch` / `.note`，避免把大型 JSON 风格工具过程当成长文本气泡排版；`.agentToAgent` 保持可见，因此媒介化的通用 agent 消息以及 `information_requested` / `information_replied` 会进入默认会话。`CodeProjection` 另以 agent single-flight 的 `task_started` 边界关联该 `{TaskID, attempt}` 最后一个完整 `message_completed`：只有同一 TaskID、同一 attempt、同一 agent 且正文与 `task_completed.result` 完全相同，才给后者附加非 wire 的 `.executionTrace` 展示来源，默认隐藏这个 scheduler lifecycle 镜像；没有匹配 message、attempt 不一致、正文不同、retry 未生成对应 message 或跨任务同文时，task result 继续作为 conversation fallback 显示。迟到旧 attempt 的 terminal 只清理自己的配对，不会清掉当前新 attempt。user、真实 agent message、媒介化 agent-to-agent communication 与 `.error` 仍显示，权限卡片/提交状态等专用结构化 UI 不受影响。完整 `task_completed` 事件、tool observation、AgentInvocation candidate result、agent 上下文、恢复与审计仍由 EventLog / projection 持有。后台启动参数 `-IntatisShowExecutionTrace` 或环境变量 `INTATIS_SHOW_EXECUTION_TRACE=1` 会恢复此前完整视图；该开关默认关闭、没有 UI 或 UserDefaults、进程启动时解析。

每个可见窗口独立持有 `IntatisThreadScrollCoordinator`。geometry callback
只观测 bottom proximity 与 material content height，不直接或同步间接调用
`scrollTo`。live-content follow 使用 100 ms fixed-window cadence；同一窗口
最多一个 executor request 和一个 replaceable pending request。rich settle
是 one-shot epoch，用户交互、detached 或 session switch 会关闭。交互期间
暂停新 rich parse/mount；idle 后每个仍可见 row 独立等待 150 ms，并只恢复
exact revision。

`ConversationProjection` 与 `CodeProjection` 同时把 assistant/agent 消息首次出现时的 `Envelope.ts` 固定在 presentation model；若历史只含 completion，则以 completion envelope 补齐，已经存在的时间不会被后续 streaming delta 或 completion 改写。SharedUI 只在 assistant/agent 名称旁显示这项元数据：相对当前时刻不足 24 小时为本地短时间，不足 7 天为本地化完整星期 + 短时间，其余为本地化中等日期（含年/月/日）+ 短时间，并遵循系统 locale、calendar、time zone 与 12/24 小时偏好。该字段不是 wire/schema 变化，EventLog 仍以既有 `Envelope.ts` 为唯一事实来源，用户与系统行不显示名称旁时间。

界面文案本地化同样停在 presentation boundary：两个 Apple App 的主 bundle 共用 English-source `Localizable.xcstrings`，显式提供 `en` / `zh-Hans`；静态 SwiftUI 文案由系统解析，先构造成普通 `String` 的动态标签通过 `IntatisLocalization` 从 `Bundle.main` 查表并以原 English key 回退。系统 Preferred Languages / App Language 负责进程启动时的 bundle localization，不在根 View 注入 locale，也不另存应用内语言状态。用户/模型正文、session 与 agent identity、provider/model ID、路径、EventLog、协议 token、工具参数和 model-facing prompt 不进入该层；否则同一 durable 数据会随界面语言被改写，破坏回放和安全边界。

macOS Chat/Code/Cowork 的顶层消息容器采用固定 history window，而不是消息粒度
virtualization：`IntatisThreadHistoryWindow` 每页最多 16 个 row，页内使用 eager
`VStack`，更多历史由 `IntatisThreadHistoryPager` 显式 Earlier/Newer/Latest。
请求 latest 时 upper bound 为 nil，append 会滑动最新窗口；显式历史页冻结其
requested upper bound，append 不改变该页。page scope 将 bottom anchor、
scroll coordinator、viewport admission 与 rich-settle generation 隔离，
thinking/live-follow 只属于 latest page；Send、Cowork Retry 和 Latest 都先
恢复最新 page。这个设计既不让 `LazyVStack` 反复 mount/unmount 混合
SwiftUI/AppKit rich native row，也不把整个会话无界 eager mount。4-row
`IntatisThreadRichEntryPolicy` 只控制首次 rich admission 是否等 initial
restore，不再选择容器。底部 16pt 留白仍属于带 ID 的 1pt bottom sentinel。
没有 completed-document、native paragraph view 或消息高度 cache。
`IntatisAdaptiveThreadStack` 只保留给共享 iOS/兼容路径；iOS Chat 尚未迁移，
必须独立验证。

`IntatisMessageRendererMode` 是 renderer-neutral 的产品熔断层，不是第二套 Markdown renderer。持久键仍为 `intatis.messageRendering.mode.v1`；无偏好默认 `.microsoft`，未知值 fail closed 到 `.plainSafe`。`-IntatisMicrosoftMarkdownMessages` / `-IntatisPlainSafeMessages` 是当前启动 override，plain-safe 在冲突时胜出；旧持久值 `rich` 与 `-IntatisRichTextMessages` 只映射到 `.microsoft` 以保留用户意图。应用内 Picker 与 iOS `Settings.bundle` 共用 `microsoft` / `plainSafe` values。运行中 mode 变化会撤销旧 view activation；raw `EventLog`、projection、provider 请求和 session schema 均不变。

`IntatisMessageContentView` 是很薄的显示/生命周期 adapter。Markdown grammar、AST、inline attributed content、代码块、table layout 与 code-aware delimiter integration 归经审计的 `SwiftStreamingMarkdown` 派生包，TeX parse/layout 归 exact iosMath 2.5.0；Intatis 产品 facade 不遍历或改写 AST，也不另写 Markdown parser、lexer、TeX 排版或 layout。Intatis 只决定消息角色是否允许 rich、是否低于 64 KiB、何时申请 parse permit、是否仍是最新 revision、上游 document 何时可替换 raw Text，以及整段 raw SwiftUI `Text` 何时允许重新投影。raw 投影是 Markdown 无关的 MainActor latest-only 状态机：一个 facade lifetime 内保留最新源，100 ms fixed-window leading/trailing throttle 不随每个 token 重置；activation/reentry、非 append correction/truncation 和 final 同步精确直出，timer 与 task generation 双重拒绝旧发布。75 ms 初始候选在正式 replay 中有 2/20 轮 interaction p95 超过冻结门，因此不能恢复。派生包基于 Microsoft v0.6.0 exact commit，升级到 `swift-markdown`/`swift-cmark` 0.8，使用 public `@concurrent ... sending` parse boundary；返回的 non-Sendable `RenderableDocument` 不越过 MainActor ownership。

iosMath 的 `MTMathUILabel`/attachment 是 AppKit/UIKit 对象：TextKit 2 attachment view provider 在 MainActor 读取 iosMath intrinsic size 并展示 live label；只有无效 TeX 或非有限/非正 geometry 才恢复 exact literal，不再有 Intatis 自设的固定 attachment 尺寸阈值。attachment file type 由唯一 MIME `application/vnd.vita0818.intatis-inline-math+json` 动态派生，并由 attachment subclass 直接返回 exact provider；不得给 public `.json` / `.data` 等宽泛 UTI 注册 process-global provider。AppKit 还必须清除默认 generic `attachmentCell`。`ParagraphNSView()` 显式建立 `NSTextContentStorage → NSTextLayoutManager → NSTextContainer`，强持有 root content storage；`setAttributedString` 整段替换后必须恢复 `primaryTextLayoutManager`，内容或有效宽度变化后在下一 main-queue turn 合并调用 `textViewportLayoutController.layoutViewport()`。这是 production live provider 真正实例化的生命周期合同，禁止通过 legacy `NSTextView.layoutManager` accessor 偷回 TextKit 1。macOS paragraph 的横向尺寸只有 SwiftUI proposal 一个 owner：`ParagraphNSView.intrinsicContentSize.width` 必须为 `NSView.noIntrinsicMetric`，`ParagraphView.sizeThatFits` 返回 exact proposal width 与 measured height。measurement memo 只保存最新一个 exact width，不得 rounding、bucketing 或累计 resize 历史；width change 可以清理 height memo并调度 TextKit 2 viewport layout，但不得产生 width-driven intrinsic invalidation。该 memo 只保存标量 measurement，不是 document、native view 或 attachment cache。`CATransaction.flush()` 只用于测试确定性跨过 AppKit transaction boundary，production 不 flush、sleep 或 spin。view 从当前 AppKit/UIKit appearance 解析 semantic color；SharedUI 将 `DynamicTypeSize` 映射为 typography revision并缩放 parse/display font config，避免旧色彩/旧字号发布。这里不创建 raster preview，也没有公式 bitmap cache。同步 formula parse/update 留在 UI owner，不能伪装成 Sendable work 放进 output-free permit scheduler。传递的 swift-markdown manifest 仍使用 Swift 5 language mode，iosMath 是 Objective-C target；因此不能把整张依赖图表述为 Swift 6 strict-clean。

当前公式面识别 `$...$` / `\(...\)` 行内形式和 `$$...$$` / `\[...\]` display 形式；display 内容可跨行。预处理器先通过首份 raw Markdown AST 保护 fenced/inline code、link/image/autolink 与 raw HTML，再以 request-local、随机 namespace 的 catalog 把原始 TeX 和 inline/display presentation 交给 attributed attachment。该路径不再设置每消息公式数量、单公式 UTF-8 或固定附件尺寸上限；原始 source 仍用于 literal fallback、selection/copy 与 accessibility。未闭合、转义、货币样式、不合规 candidate 或 iosMath 无法解析的 TeX 不得吞字。plain-safe 在任何 Markdown/math parser 或 view 构造前完全绕开该路径。64 KiB whole-message rich admission 与 1-running/32-pending parser scheduler 是语法无关的 facade 资源边界，不是公式限制。图片、citations、文字动画与语法高亮仍关闭；代码块显示完整可选择纯文本、语言标签、原生 Copy 与水平滚动，table copy/download actions 不进入 UI。链接点击只允许 `http`、`https`、`mailto`。因此本版本仍没有 JavaScriptCore/highlight.js 运行、远程图片请求或模型输出 `eval`。零 completed-document cache、零 paragraph native-view cache；这一选择减少旧历史 session 的常驻原生 view graph，之后只有得到测量证据才可重新引入 cache。

当前 Intatis dependency 声明已删除旧 MarkdownUI/NetworkImage/swift-cmark0.5/HighlightSwift 和 vendor highlight 资源；完整可构建 Microsoft derivative vendored 于 `Vendor/SwiftStreamingMarkdown`，根 `Package.swift` 使用仓内相对路径。派生包 exact-pins `swift-markdown` 0.8（传递 `swift-cmark` 0.8）以及只在 iOS/macOS 链接的 iosMath 2.5.0 commit `838cddc01fdd67efd530f8bb67959ad2715f9b06`；根与 vendor 两份 `Package.resolved` 已匹配。Microsoft MIT `LICENSE` 与永久 patch ledger 和源码一起由 Intatis 根 Git revision 固定；iosMath MIT、八套 unmodified math font 的 GUST/LPPL 或 OFL 条款、资源清单与用户批准另由 `ThirdPartyNotices/MathRendering.md` 固定。iosMath 自身无传递 package dependency；其 `fonts/` payload 是 8 OTF、8 math-table plist、5 license、4 README 与一个 conversion script，共 26 files / 7,234,424 bytes，完整 built `iosMath_iosMath.bundle` 加生成的根 `Info.plist` 后为 27 files。这套公式字体不改变产品 UI 字体选择。三个 exact-pinned remote dependency 在无缓存解析时仍需要网络，完全离线供应链不在本轮范围。

2026-07-18 事故前验证基线：renderer focused 37/37；完整 SwiftPM 755/14 skipped/0 failures；固定 fixture 为 17 messages / 1,249 deltas、SHA-256 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`。100 ms Plain 与 production-shaped `LazyVStack` Microsoft 各完成 5 cold + 20 replay、25/25 exact 并通过 interaction p95 ≤8 ms / max ≤50 ms 门；Plain cold/replay worst p95/max 为 6.152250/30.395208 ms、4.370458/29.591167 ms，Microsoft 为 4.020458/37.840875 ms、4.876292/36.596500 ms，Microsoft replay peak/residual RSS 最高 102.953/101.375 MiB。eager `VStack` cold 5/5、replay 20/20 p95 超门；当时 xctrace 17/17 exact、>250 ms hang 0、旧 lifecycle warning pattern 0。main/RSS/footprint/CPU 没有冻结 gate，普通 AttributeGraph sampling 也不能证明零 cycle。以下事故后段落是当前 release authority，并明确覆盖这组窄协议可能造成的 release-ready 推断；真实设备仍为 `UNKNOWN`。

事故后 renderer hardening 仍遵守同一所有权边界，没有新增 Intatis parser/layout：vendored `DocumentView` 和两平台 `ParagraphView` 恢复 upstream-equivalent 手写 `Equatable`。patch group 8 的双平台 width tracker 是历史基线；patch group 11 后 UIKit 继续使用该 bounded invalidation 合同，AppKit 改为 flexible intrinsic width、proposal-owned exact measurement、zero width-driven intrinsic invalidation 和 one-entry measurement memo。Intatis rich facade 不再给整棵 `DocumentView` 套第二个 SwiftUI `SelectionOverlay`，plain `Text`、native selectable paragraph、table/code SwiftUI leaf 各自拥有 selection。没有 document/native-view cache；单项 height memo 也不能单独证明 SwiftUI/TextKit 总 graph 内存有界。

2026-07-18 三实例 GUI/Computer Use `FAIL / ABORTED` 现在是历史 adverse evidence：Force Quit 对主实例显示 129.63 GB application memory；CPU diagnostic incident `FA228932-2C40-4AC2-A0C2-62EF41342B4A` 记录 160 秒内 90 秒 CPU 与 sampled footprint 109.16 MB→803.30 MB，重栈含 SwiftUICore/AttributeGraph/lazy layout/`ParagraphView`/`SelectionOverlay`。缺少 malloc stack/heap graph，根因/最终 retaining edge 仍为 `UNKNOWN`。2026-07-24 hash-pinned 单实例验证已通过同一 Microsoft renderer 的 math-disabled/enabled structure A/B，以及 math-one/thirty-two/history/stream isolation；Light/Dark `math-structure` Computer Use 各稳定运行约 47.47 秒并看到真实公式字形、literal code 与原始 TeX AX 描述，所有 run exit 0、未用 TERM/KILL且无残留。vendor 82/82、SharedUI 25/25、root 938/14 skipped/0 failures、macOS/iOS Debug/Release 与双端 bundle/notice/font inventory也通过。以上关闭“从未受控启动”和单美元公式不可见两个问题，但仍短于历史 160 秒窗口，也没有真实 clipboard/VoiceOver、malloc retaining-edge 或低端 iOS 真机证据；因此不能据此宣称历史事故根因已解决或 renderer 已 release-ready。

2026-07-30 当前 paragraph width-owner 修复另有独立 release authority：普通
Release 的真实问题 session 已完成 A→B→A、zoom/restore、滚动和多窗口；
同一 hash-pinned validation binary 的三次 180 秒 soak 均通过 memory
plateau、heartbeat、multiple-updates-per-frame 与清理门，其中两次未引入
AX 全树/截屏的 runtime invalid geometry 为 0。互动 soak 中 18 条 AppKit
negative geometry 均与系统 ThemeWidget/AX/ReplayKit 激活成簇相关，保留原始
count 但不归因于 paragraph/thread 产品布局。约 90 秒 Hangs/Time Profiler
的 Potential Hangs 与 Hang Risks 均为 0 row，没有持续递归 layout hot stack。
这关闭当前可重复 zoom/restore hang，不解释 2026-07-18 的历史 malloc
retaining edge，也不替代真实 VoiceOver/clipboard 或低端 iOS 实机。

同日后续的 session-entry/scroll A/B 进一步确定：即使 paragraph width owner
已修，macOS 消息级 `LazyVStack` 与混合 SwiftUI/AppKit 可变高度 rich row 仍会
触发 AttributeGraph transaction feedback。同一 13-row/5-rich-row session 中，
rich+lazy 卡死，plain+lazy 与 rich+eager 均正常，关闭代码块/表格 selection
不能消除卡死；sample 的主线程持续经过
`GraphHost.flushTransactions → AG::Subgraph::update → UpdateStack`。因此当前
生产 authority 是前述 16-row bounded eager pages。最终 69 项 focused test、
IntatisMac Debug build、真实 `cowork_tf2lkjbh` entry/scroll/A→B→A 和
55-message Earlier/Latest 通过；旧 lazy soak 只保留为历史证据，不验证当前
容器的长时表现。

### Provider 模型请求扩展

macOS 的 Intatis-owned OpenCode-compatible 配置把 `provider.<id>.models.<model>.options` 视为开放的 model-scoped JSON 请求扩展点。`AppConfig` 不解释厂商字段，而是保真为 `[String: JSONValue]`，按 model ID 挂到 `ProviderEndpoint.modelRequestOptions`；`provider.<id>.npm` 与 model object 内的 `provider.npm` 也分别保留为 provider adapter 与 model override。当前 OpenAI wire runtime 在构造 Chat/Code request body 时先加载这些扩展，再由 exact package adapter 解释已知选项，最后写入运行时字段。因此 routing、sampling、reasoning、response format 或未来厂商自定义嵌套对象无需为每个 provider 增加 Swift 配置字段。此处“开放 JSON”只描述兼容 `ProviderEndpoint` 路径；Cowork durable catalog 有独立的显式 allowlisted schema，不能用这一段推导 unknown option 可被持久化。

顶层 `model` 解析先在启用的 provider model map 中按完整字符串精确匹配；只有未命中时才解释为 `provider/model`。这使 `deepseek/deepseek-v4-pro` 一类本身含 `/` 的 endpoint model ID 与显式 `OpenRouter/deepseek/...` provider-qualified 形式可以共存，且多 provider 出现同名 model 时只有显式 selected provider 才能消除歧义。

`model`、`messages`、`tools`、`stream` 是 Intatis 运行时拥有的结构字段，配置不得覆盖；单次 runtime 明确设置的 `temperature`、reasoning effort、`max_tokens`、usage 选项也只在 exact adapter 支持的边界内覆盖配置默认。OpenAI-compatible Chat/Agent builder 还会对每个请求无条件移除配置提供的 `stream_options`、`n`、`best_of`、`num_return_sequences`、`candidate_count`。`@ai-sdk/openai-compatible` 与 `@openrouter/ai-sdk-provider` adapter 按 pinned OpenCode package 省略 `n`，依赖 API 默认的单候选行为，并且不把 parallel-safe tool metadata 自动翻译成 `parallel_tool_calls`；legacy Intatis wire 保留原来的显式 `n = 1` 与 call-level parallel 开关。只有 host `includeUsage` 可重建受控 `stream_options.include_usage`；host output ceiling 另会移除竞争 token aliases。provider-level `options.baseURL` / `apiKey` / `chatEndpoint` 仍分别属于 endpoint、secret 与 transport 配置，不会被盲目复制到请求 body。

控制面调用也遵守同一兼容性规则：Permission Reviewer、legacy `ModelPermissionReviewer`、GoalVerifier 与 chat/agent health check 默认保持 sampling/output 参数为 `nil`，不得为了“确定性”硬编码 `temperature=0` 或固定输出上限。只有用户/host 显式策略、Goal token budget 或真实 context-window postcondition 才可添加相应 request control。

开放配置与最终 wire 是两个边界：配置文件、immutable profile 和 UI 投影继续保留原始 key/value；最终 Chat Completions builder 按冻结的 `ProviderRequestAdapter` 执行 package-specific lowering，而不是应用跨 provider 的全局 camel/snake/nested 优先级。Intatis-owned custom provider 的选择顺序是显式 model `provider.npm` → provider `npm` → `@ai-sdk/openai-compatible`；只有字段真正缺失（`nil`）才进入下一层，显式空串或空白 package identity 必须原样保留并 fail closed。Intatis 不导入 OpenCode 的 models.dev catalog，因此没有其 built-in model metadata fallback。adapter 作为 connection/profile 语义进入 immutable revision；未知 package、以及当前 Chat 路径不支持的 `@ai-sdk/openai` 都在网络前 fail closed，不能按 endpoint 名称猜测或退回 compatible。

当前 reviewed Chat adapters 精确区分：

- `@ai-sdk/openai-compatible@2.0.41` 消费 `reasoningEffort` 并生成 `reasoning_effort`，camel 与 raw snake 同时存在时 camel 的生成值获胜；只有 raw `reasoning_effort` 而没有 camel 时，按该 SDK 的实际构造顺序最终不发送该字段。独立的 nested `reasoning` 对象仍可同时存在。`textVerbosity` 同理生成 `verbosity`，`strictJsonSchema` 是 SDK 控制项而不是 wire key，未知选项和 OpenRouter `provider` routing object 保持原结构。
- `@openrouter/ai-sdk-provider@2.9.0` 不把 `reasoningEffort` 转成 snake；host typed reasoning 使用 nested `reasoning.effort`，配置也应使用该 adapter 支持的 nested 结构。其 `provider.only` / `allow_fallbacks` / `require_parameters` 保持原结构。
- 缺失 adapter 的历史 Intatis endpoint/profile 解码为 `intatis:legacy-openai-wire`，保留旧请求语义与旧 fingerprint；新的 OpenCode-shaped App/CLI 配置总会冻结显式 adapter。

现有 Responses dialect 仍是 Intatis 自有兼容路径，不等于完整实现 `@ai-sdk/openai` Responses SDK；该边界不得据此宣传为所有 OpenCode npm provider 已支持。未来增加其他 package/wire 时，应独立实现并测试其协议映射，不得复用 compatible adapter 或静默丢弃未知配置。Chat 托管网络搜索在普通 Chat adapter 之外解析独立的 exact `hosted_web_search` capability 与 provider dialect：OpenAI native `web_search`、OpenRouter `openrouter:web_search` 和未来厂商映射互不等价，`responsesEndpoint`、compatible wire 或 provider/model 名称都不能自动证明支持。当前 planner 只会为普通 Chat adapter 已实现且 exact model 明确声明能力的 route 提供搜索；OpenRouter dialect 已进入运行时，OpenAI Responses encoder 已独立实现，但 `@ai-sdk/openai` 的普通 Chat adapter 仍未实现，因此该 exact adapter 继续在网络前 fail closed。完整合同见 `docs/CHAT_HOSTED_SEARCH.md`。

配置解析与 UI 展示是独立的只读投影。`AppConfig` 在内存保留完整 model object；`ModelConfigurationPresentation` 可从原始 model metadata 与 `options` 识别常见 reasoning/thinking effort、thinking level 或 token budget 的原始值，供模型列表显示灰色辅助标签。该识别覆盖 OpenRouter/OpenAI 常见 `reasoning.effort` / `reasoning_effort`、OpenCode/SDK 常见 `reasoningEffort` / `thinking.budgetTokens`、Anthropic 常见 `output_config.effort` / `thinking.budget_tokens` 等拼写，但只代表“配置中存在这个值”，不代表 Intatis 验证了目标模型支持它。投影不得改变 key/value、不得回写配置。`variants` 是同一 model 的命名请求参数预设：macOS 把基础项与未禁用 variants 摊平成菜单选择，持久化 provider/model/variant identity；选中 variant 后按 OpenCode/Remeda `mergeDeep` 语义覆盖基础 model `options`：只有两侧都是 plain object 时递归，array、scalar 与 null 由后层整体替换；发给 provider 的 model ID 不变。未显式选择 variant 时，UI 与请求都不得任选一个 variant 冒充活动配置。

### Cowork per-agent inference profile

Cowork 的 agent 推理配置不是 session-global `model` 字符串。`InferenceCatalog` 把 transport/credential trust boundary 与 model/options 分成 `InferenceConnectionDefinition` 和 `InferenceProfileDefinition`，二者都用 exact ID + revision 表示不可变定义。App/CLI mutable 配置经 reconciler 编译：语义相同复用旧 revision，语义变化追加 revision并保留旧定义；current reference 只供未来 binding 使用。`InferenceCatalogStore` 以 schema v1、owner-only 文件保存所有 revisions，corruption、未知 schema 或不安全权限 fail closed，不覆盖原文件。Reconcile 在稳定 owner-only sidecar 上取得 Darwin/Linux 跨进程独占 record lock，并以进程内互斥补足 POSIX lock 的 process-scoped 语义；完整旧值读取、revision allocation、snapshot 校验和原子替换都在同一临界区内。Lock 必须为当前用户所有、`0600`、普通单链接文件，并以 no-follow/close-on-exec 打开；不支持真实跨进程锁的平台和任何不安全 lock state 都 fail closed。

`AgentInferenceBinding` 安全快照固定 exact profile/connection revision、model/opaque durable variant、安全 route label/trust domain/egress classification 与 opaque definition digest；catalog exact resolve 会逐项复核这些值，而不只核对 revision/digest。macOS 用户配置中的 raw variant key 只保留在 local presentation metadata，durable `variantID` 使用 provider/model/variant tuple 的 opaque stable digest。fresh `@main` 使用 project 的未来-agent default；`spawn_agent` 未显式指定时精确继承调用者 binding，显式 profile 必须属于 host-approved map。已有 agent 永不动态跟随 default/current；恢复、入队和 provider dispatch 都必须 exact resolve，missing/mismatch/unsupported wire 不能 fallback。每个 `TaskContract` 冻结本次 invocation binding，运行中 catalog refresh 或 rebind 不改变它。Shipping runtime 的 resolver 必须一次返回 `ResolvedInferenceProfile(binding, model, provider)`；严格模式拒绝旧 provider-only factory，Orchestrator 统一核对 live agent model、binding 与 resolved tuple，不能由 app 分阶段拼装三者。

Profile 编译按 connection defaults → model base → variant → profile overrides 做 OpenCode-compatible deep merge：共享 plain object 递归，array/scalar/null 由后层替换；请求时 resolved profile options → package adapter lowering → 受限 invocation values → runtime clamp → runtime-owned structural fields。Connection 冻结 provider adapter，profile 冻结有效的 model override；任一 adapter 变化都会追加 immutable revision。Bound Cowork agent 的 reasoning/options 属于 profile，不能被 session-wide effort 隐式覆盖。Durable connection URL 必须是无 user-info/query/fragment 的绝对 HTTP(S) URL；durable options 使用显式 schema：只允许有界的 sampling/token/logprob 数值、少量布尔/安全 token 字符串，以及受限 `reasoning`、`thinking`、`output_config`、provider routing 子结构；unknown key、错误 shape/size/depth、secret/auth/header/query/URL/endpoint、runtime structural、stream 与 multi-candidate fields 在 catalog 编译时全部 fail closed。Secret value 只按 credential reference 在 provider 请求边界懒加载。Chat builder 随后对所有 request 无条件清除配置 `stream_options`/候选数量控制；新式 package adapter 省略 `n` 与自动 parallel 开关，legacy wire 保留旧显式控制。host output ceiling 另按 normalized key 清除大小写与常见分隔符变体的竞争 token aliases。Raw endpoint、credential、headers/query 和任意 options 不进入 agent/event/UI 安全投影。

Host 只能对没有 queued/running invocation 的 ordinary agent rebind。候选 exact binding 可先在锁外异步解析，但 admission lock 内会复核 host-approved map、idle/current state，随后先 durable append previous/new `agent_attached` snapshot，再更新内存 roster；catalog candidate update 与 attach/spawn/delegate/rebind 使用同一 admission lock。Permission target/authorization 携带目标 binding 的安全 route/trust/egress 快照与派生 `targetInferenceFingerprint`，并在 allow 后、durable prepare 后和执行前重新计算复核；如果 exact resolver 曾 suspension，返回后还会重跑同步的 catalog/roster/fingerprint 检查，从而在不跨外部 `await` 持锁的前提下关闭 TOCTOU。Ordinary attach 在 permission-review allow 后再次 exact-resolve，并在 admission lock 内比较 review 前、resolve 前和 commit 前的 host-approved catalog snapshot；fresh `bootstrapMainAgent` 不走模型 review，但会在 admission wait 前后分别检查空 roster/EventLog、锁外再次 exact-resolve，再在锁内复核 catalog 与 empty-session 事实后才 durable commit。AgentLoop 的 execution revalidation hook 在写 durable tool-execution prepare 前完成 exact resolve，并在 await 后再校验一次；失败时不能留下代表旧授权已获准执行的 prepared ticket。Reviewer 不能 rebind，普通 agent 不能自切换。

macOS Cowork 底部的模型选择器不是 live rebind 控件，而是 composer 的“下一次 `@main`”暂存值；当前 root/worker/Goal 仍在运行时也可继续选择。每次面向 `@main` 的普通 Send 或 durable `/goal` 都在按钮边界把当时的 secret-free exact binding 冻结到 `UserMessagePayload.mainAgentInferenceBinding`，再随同一 submitted intent 进入 outbox、原子 `user_message + queued`、恢复与 Retry；直接发给 ordinary worker 的消息不携带该字段。FIFO drain 只有在前一工作越过 task boundary 后才用 host-only rebind 把 live `@main` 对齐到该 submission 的冻结值，root admission 还会复核 live binding 全等；候选撤销、无法解析或并发变化都使该 submission fail closed，不得回退旧模型或 current default。这个路径不修改既有 worker、`@permission-reviewer`、Goal verifier、未来新 agent default 或已经冻结的当前任务。

Recovery 必须分别描述 GUI 与 CLI。GUI 完成 replay、main/reviewer 状态解析和 Goal 对账后，只调用 `startNewTasksKeepingRestoredTasksPaused()`：新提交可以调度，恢复出的 root tasks 继续 paused/interrupted，直至精确 submission Retry；composer 和本地 admission 不依赖 exact-main/reviewer readiness。CLI 则保留显式 `/auto|/default` 与 `resumePendingTasks()` 边界。普通 worker unresolved 不得把整个 scheduler 冻结：它自己的 queued invocation 会在 provider request 前 exact-resolution fail closed 并 durable 结算为 failed，撤销 task lease、清除 busy fence后才可显式 rebind；无关 agent 继续运行。历史 session 若缺少 durable `@main`，启动流程不能用今天的 default/workspace 自动创建：GUI 只能按 canonical settings 做 host-authorized exact recovery 并在 main 修复后重建 reviewer；CLI 只能通过专用 `/agent restore-main <path> <profile-id>`，再显式 `/auto` 启动控制面。Phase L 后冷启动 active Goal 只完成 reconcile 并 durable pause（或 budget-limit），不会自动创建 continuation；显式 Resume 才能进入 data plane。

Provider formatter 先对诊断文本脱敏；diagnostic sanitizer 会把完整普通 HTTP(S) URL 也替换成 `[REDACTED_URL]`，即使它不含 query credential，因为 endpoint 可能识别私有基础设施。`RuntimeErrorPresentation` 是任何 provider/custom runtime 错误进入 durable `ErrorPayload` 或 task-failure 事实前的最后公共边界，会再次执行 URL/secret-redact 并限长；普通 permission preview 使用的非 diagnostic sanitizer 不因此全局删除 URL。Inference resolve/config 错误同样只允许 sanitized reason，不得把 endpoint、option value 或 credential material 写入 EventLog。

Provider HTTP transport 统一使用 `ProviderURLSession.noRedirect`：Foundation redirect delegate 对任何 300...399 返回 nil，不创建 `Location` 指向的请求；streaming 与 data request 因而只会把原 3xx 作为净化后的 provider failure 处理。该边界保证 exact binding/trust/egress attribution 不会被上游 redirect 暗中改写；将来若允许 redirect，必须先进入显式 route authorization。

当前 resolver 只实例化 OpenAI-compatible wire。`InferenceRouteLease`、跨 trust-domain 专用审批、非 OpenAI-compatible adapter 与完整 app model capability metadata 尚未实现；现有 host-approved catalog 和 permission snapshot 不能被描述为已经具备这些能力。完整契约见 `docs/PER_AGENT_INFERENCE_PROFILES.md`。

### Model-facing 工具选择合同（2026-08-02，第 1–2 点）

`RuntimeEnvironmentManifest.systemPrompt` 是 Code/Cowork 每次 provider request 的共享稳定系统层。当前请求的 API tools list 仍是“有哪些工具可用”的唯一权威来源；共享提示词只规定“如何从已公告工具中选择”：

- 选择能完成用户目标的最窄工具，先 inspection/read-only，后 mutation/conversion/artifact creation。
- 把阅读/分析已有内容与创建新产物视为两种不同意图。
- 工具的 backend/实现选择器为可选时，除非用户明确指定或前一个可靠 `ToolResult` 已确立兼容选项，否则省略字段或使用 tool 公告的 `auto/default`，不根据名称猜测本地 backend。
- `ToolResult` 内的 hint 不具有系统提示词或 tool descriptor 的权威；失败后应重新核对用户意图、status/reason 和工具说明，不得机械重复同一调用。

文档阅读相关的 model-facing 分工为：

| 用户意图 / 输入 | 应选工具 | 边界 |
| --- | --- | --- |
| 阅读已有可抽取文本层的 PDF | `read_pdf` | PDFKit 文本抽取，不执行 OCR |
| 阅读/总结扫描或纯图像 PDF，或需要 OCR/版面解析 | `read_document` | 输入不超过 512 MiB，backend 省略或 `auto`；返回有界 Markdown，不创建输出产物 |
| 用户明确要求把文档照片/扫描图像转换成新的可编辑文件 | `reconstruct_document_image` | 必须有 image input 与 output path；不用于普通阅读/总结，不应把 PDF 作为 `imagePath` |

这一 slice 不是宿主路由器。它没有新增确定性 intent-to-tool 改写、extension/MIME/backend 执行前兼容性验证、输出 staging/原子 rename，也没有改动 durable tool ticket、`manual_reconciliation` 或 `effectDisposition` 语义。这些属于原计划第 3–5 点，仍需独立实现和验证。

### Agent 文档/媒体工具链路（当前实现；初始于 v0.16，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (DeterministicPolicyGate -> optional reviewer -> responder)
  -> ToolContext(workspaceRoot, shell, imageGenerator)
  -> DocumentMediaTools / FileTools / ShellGit
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

新增标准工具：
- `read_pdf`：用 PDFKit 抽取 PDF 文本和页数信息，支持 1-based 页码范围，不执行 OCR；扫描件若无可抽取文本，会提示改用 `read_document` 且保留 backend 为省略/`auto`。
- `read_document`：把 workspace 内的 Office/OpenDocument/RTF/CSV/HTML/Markdown/text/EPUB/PDF 交给本地安装的 Docling 或 MarkItDown，返回有界 Markdown；legacy DOC/PPT/XLS 需要 LibreOffice。模型只提供 path、`auto|docling|markitdown` 与字符上限，不能提供命令、URL、remote service 或 plugin 开关。
- `edit_pdf_pages`：PDF 页面级 `extract` / `split`，输出路径仍受 `PathConfinement` 限制。
- `reconstruct_document_image`：只在用户明确要求转换/重建并创建新输出文件时，把文档照片或扫描图像交给已安装的外部成熟后端；当前 wrapper 支持 `docling`、`marker_single`、`tesseract`，输出 Markdown/HTML/text。PDF 阅读不走该工具。
- `compile_latex`：调用已安装的 `tectonic`、`latexmk`、`xelatex` 或 `pdflatex` 编译 `.tex`，并确认 PDF 产物存在。
- `generate_image`：主 agent 从用户意图自主决定是否调用；model-facing schema 只包含 `prompt`、
  `outputPath`、可选 `size` 和 `count`，不暴露 provider/model 选择。宿主通过
  `ImageGenerationToolService` 从顶层 `image_model` 解析 exact provider/model，调用现有
  OpenAI-compatible image capability，并将返回图片写入工作区。缺少路由时明确返回未配置，
  不使用隐藏模型 fallback。
- `edit_image`：与 `generate_image` 共用上述宿主 route 和 service seam。model-facing schema
  只有 `imagePath`、`prompt`、`outputPath`；executor 在网络前确认输入是工作区内不超过 50 MiB
  的 PNG/JPEG/WebP regular file、文件签名与扩展名一致、输出是不同路径的 PNG。权限 intent 把
  输入标为只读、输出标为可写，并同时声明网络与模型成本；宿主调用 multipart
  `POST <baseURL>/images/edits`（单个 `image[]`）并原子写回输出。当前不支持 mask、多参考图或
  原地覆盖。

设计取舍：
- 当前不把 Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers 复制进仓库，也不新增 SwiftPM 第三方依赖；它们是可安装后端或后续集成方向。
- `read_document` / `reconstruct_document_image` / `compile_latex` 是 process-backed 工具，仍受
  host shell 能力、WorkspaceLease 和权限门约束；shell-disabled/read-only
  host 不得绕过 `DeterministicPolicyGate`。structured runner 默认断网、有界 timeout/output 并清理进程树；`read_document` 还禁用 Docling remote services/external plugins，并把 parser runtime 限定在受信系统路径或用户显式建立的 Intatis document runtime。
- `read_document` 的 path/普通文件/512 MiB/extension/backend 检查是 executor 内、parser 进程边界前的可证明 no-effect preflight；它们使用 `ToolExecutionRejectedWithoutSideEffect` 返回，AgentLoop 必须写 failed + `not_started` settlement 并允许模型修正输入，不得留下假的 unresolved ticket。这不改变 parser 进程真正开始后的保守副作用证据语义。
- Cowork read-write coordinator/worker lease 可获得 `read_document`；worker 默认 read-only 时只获得 `read_pdf`，不会默认获得文档 parser process、页面编辑、LaTeX 编译或生图能力。

### Agent Git control 工具链路（Codex-aligned 本地 Git 控制面，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (read-only allow; local git mutations ask/reviewer)
  -> ToolContext(git: GitService, workspaceRoot)
  -> ShellGit tools -> ProcessGitService parameterized git process
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

标准工具：
- `git_status`：读取 `git status --porcelain=v1`。
- `git_diff`：读取 unstaged unified diff。
- `git_diff_staged`：读取 staged unified diff。
- `git_info`：读取 repository root、当前 branch 或 detached HEAD、短 HEAD、默认分支、dirty 状态与 remote metadata。
- `git_recent_commits`：读取最近本地 commit 摘要，默认 10 条，最多 50 条。
- `git_diff_base`：读取当前 workspace 相对指定 base ref 的 unified diff。
- `git_branch`：显示当前分支与本地分支列表。
- `git_create_branch`：创建本地分支，不切换分支。
- `git_stage` / `git_unstage`：仅对 workspace-confined path 修改 Git index。
- `git_commit`：从 staged index 创建本地 commit；执行时禁用 hooks path 与 GPG signing，并在提交前拒绝 staged sensitive path。
- `git_apply_patch_check`：对 unified diff 做 apply preflight，不修改工作区。
- `git_apply_patch`：把 unified diff 应用到工作区；非 cached 正向 apply 使用 `git apply --3way`。
- `git_stage_patch` / `git_unstage_patch`：用 patch 级别修改 index，作为 Codex-style hunk/file stage/unstage 的底层能力。
- `git_revert_patch`：反向应用 unified diff；非 cached 真实 revert 会先 best-effort stage patch 已存在路径，再用 `git apply --3way -R`，降低 index mismatch；这是 destructive 工具，要求显式 `confirmRevert:true` 并走权限门。
- `git_worktree_list`：读取 `git worktree list --porcelain`。
- `git_worktree_create`：只在 workspace `.intatis/git-worktrees/<name>` 下创建受管 linked worktree；默认 detached HEAD，可显式指定新 branch。
- `git_worktree_remove`：只移除 `.intatis/git-worktrees/<name>` 下受管 worktree；这是 destructive 工具，要求 `confirmName` 精确匹配。
- `git_remotes`：列出已配置 remote，并遮蔽 remote URL 中的凭据/token。
- `git_fetch`：只从已配置 remote name 拉取；不接受 URL remote，默认不切工作区，`prune` 显式可选；这是 write + network 工具。
- `git_pull_ff`：只对当前 clean working tree 的当前分支执行 `git pull --ff-only <remote> <branch>`；要求 `confirmRemote` / `confirmBranch` 精确匹配；这是 write + network 工具。
- `git_push`：只把当前分支推送到已配置 remote name；要求 `confirmRemote` / `confirmBranch` 精确匹配，不支持 force push 或 URL remote；这是 destructive + network 工具。
- `git_switch`：只在 clean working tree 上切换到既有本地分支；要求 `confirmBranch` 精确匹配；这是 destructive 工具，不做 `checkout .` / discard。

设计取舍：
- 本轮对照 Codex App/Worktrees/CLI 官方文档与 openai/codex 开源实现后，Intatis 采用相同方向：Git 不是开放 shell，而是受限工具能力，围绕 read-only 状态、diff、patch preflight/apply/revert/stage、受管 worktree 和权限审批暴露。当前已落地 Git slice 没有复制 Codex 源码或文案；未来若选择性复用兼容许可证实现，必须按 `docs/OPEN_SOURCE_REUSE.md` 固定来源并适配现有安全边界。
- 继续使用 `GitService` 抽象 + 本地 `git` wrapper，不新增第三方依赖。
  libgit2/SwiftGit2 只有在出现独立产品需求时才重新评估，并先做许可证、
  native build、安全和维护成本审查；不得仅为已取消的 App Store 分发引入。
- `ProcessGitService` 不拼 shell 字符串，而是通过 `Process` 以参数数组调用 `git`；内部 Git 命令统一设置 `GIT_TERMINAL_PROMPT=0`、`GIT_OPTIONAL_LOCKS=0`、`core.hooksPath=/dev/null`、`core.fsmonitor=false`，本地 metadata/patch 命令用 5 秒 command timeout，remote fetch/pull/push 用 60 秒 timeout。动态 branch/ref/path/message/diff patch/remote name 不进入 shell。
- Git repository root 必须与 agent workspace root 一致。普通 repository 的 git metadata 必须在 workspace 内；`.intatis/git-worktrees/<name>` linked worktree 允许 `.git` file 指向 owning workspace repository 的 `worktrees/` metadata，但 workspace path 仍必须在 owner root 之内。
- `git_stage` / `git_unstage` 的 path 参数先经过 `PathConfinement`；patch 工具从 `diff --git` / `+++` / `---` 解析 changed paths，并在权限与执行前做 workspace confinement。工具 observation 只返回相对路径 metadata，patch 正文只作为工具 diff 结果，不当作长期 schema。
- Remote Git 只接受已配置 remote name，不接受 URL remote/refspec；工具输出会遮蔽 URL 凭据与常见 Git hosting token。`git_pull_ff` 与 `git_switch` 要求 clean working tree；`git_push` 不支持 force / force-with-lease。真实 remote auth 由用户本机 Git credential helper/SSH agent 决定，Intatis 不读取、存储或展示凭据。
- Cowork `ToolCapability.gitControl` 下 coordinator lease 默认可用本地 Git control；`ToolCapability.gitRemote` 下 coordinator lease 默认可用 remote Git control；worker lease 默认不暴露任何 Git 工具。旧 `runShell` lease 仍只暴露 `git_status` / `git_diff` / `git_info` / `git_recent_commits` / `git_diff_base` 这类 read-only 兼容工具。
- 仍未实现 merge/rebase/reset/clean、force-push、remote auth 管理、PR/CI/review workflow；这些后续必须单独做风险分级、UI/权限和测试设计。

### Agent 网络/浏览器工具链路（当前实现；初始于 v0.16，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (exec + network permission)
  -> web_fetch: URLSession HTTP(S)
  -> browser_*: ToolContext.browserBackend
       -> typed BrowserBackendInvocation
       -> BrowserBackendProcessRunner -> fixed Intatis-generated Node driver
       -> Playwright persistent context when available
       -> otherwise Node built-in WebSocket + Chrome DevTools Protocol fallback
       -> Chromium / Chrome / Microsoft Edge persistent profile
       -> workspace .intatis/browser profile/state/history
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

新增标准工具：
- `web_fetch`：轻量 HTTP(S) 获取，无浏览器登录态、JS 或 cookie。
- `browser_diagnostics`：检查本地 Node.js、Playwright 解析位置、浏览器 channel 探测和当前 profile/state/history/downloads 路径；即使 Playwright 缺失也应返回可行动诊断。
- `browser_profiles`：列出 workspace 内持久浏览器 profile 的安全 metadata（当前 URL/title、state/history/download 计数、目录统计、Chromium runtime marker 存在性），不读取 cookie/localStorage/profile 数据库、runtime marker 内容或下载内容。
- `browser_profile_delete`：显式删除一个 workspace-scoped persistent browser profile 的 profile data、state file、downloads 目录和 Intatis history metadata；这是 `.destructive` 工具，必须要求 `confirmProfile` 与目标 profile 匹配，并仍通过权限门；若删除前发现 active/lock runtime marker，只输出概括性提示，不列 marker 文件名或内容。
- `browser_history`：只读取 `.intatis/browser/history.jsonl` 中的非 secret 历史 metadata，支持 profile 和条数过滤，不读取 cookie/localStorage/profile 数据库。
- `browser_navigate` / `browser_snapshot` / `browser_handoff` / `browser_reload` / `browser_back` / `browser_forward`：用持久浏览器 profile 打开 URL、读取当前页、打开有界 headed 浏览器窗口供用户手动登录/接管、刷新当前页，或按 Intatis profile 导航栈前进/后退，返回页面 title、URL、可见文本、链接和可定位交互元素摘要。
- `browser_click` / `browser_type` / `browser_submit` / `browser_select_option` / `browser_press_key` / `browser_scroll` / `browser_wait`：通过 CSS selector、文本或 accessibility role/name 对当前浏览器页面点击、输入、提交当前或目标表单、选择下拉项、按键/快捷键、滚动页面/元素，或等待指定 selector/text/role 状态；动作后的 observation 也返回按钮、输入框、下拉框等交互元素的 role/name/selector/options 摘要，供下一步定位；会打开新 tab/window 的 click/type-submit/select/submit/press 动作会在 Playwright 路径用 page/popup 事件、在 CDP fallback 路径用真实鼠标点击 + target polling 跟随到新页面，并把最终页面写入 state/history；`browser_type` 会从工具 observation 中遮蔽本次输入值，并在 Swift 工具入口与 Playwright/CDP 后端 DOM 执行前拒绝疑似密码、2FA、token 或 API key 输入目标，要求改用 `browser_handoff` 让用户接管登录/验证。
- `browser_screenshot`：把当前页或指定 URL 渲染为 PNG 写入工作区路径，并通过 `changedFiles` 暴露产物。
- `browser_upload_file`：把 workspace 内文件附加到当前页面的 file input；Playwright 路径使用 `locator.setInputFiles`，CDP fallback 使用 `DOM.setFileInputFiles`。
- `browser_download`：点击预期会触发下载的元素，并把下载文件保存到 `.intatis/browser/downloads/<profile>`，通过 `changedFiles` 暴露下载路径；CDP fallback 使用真实鼠标事件触发，避免只靠 DOM `click()` 的非用户手势限制。
- `browser_downloads`：只列出 `.intatis/browser/downloads/<profile>` 下的文件 metadata（路径、大小、修改时间），不读取文件内容。
- `browser_search`：在持久 profile 中用 DuckDuckGo/Google/Bing 搜索。

设计取舍：
- 已调研 Chromium、Playwright、Chrome DevTools Protocol、Selenium、Browser Use、CEF；当前实现优先选择 Playwright wrapper 复用真实 Chromium/Chrome/Edge 内核和 profile 能力，在 Playwright 未安装时用 Node.js 内置 `WebSocket` 直连 Chrome DevTools Protocol 启动已安装 Chrome/Edge/Chromium persistent profile；Playwright 通过 BrowserContext page/popup 事件识别新页面，CDP fallback 通过 `/json/list` target 轮询和新 target WebSocket 切换识别新页面；Playwright/CDP 命令必须有有界 watchdog，避免真实浏览器流程无限挂起；不 vendoring Chromium/CEF，也不把 Playwright 源码复制进仓库。
- shipping macOS 浏览器 lane 不接收 raw shell command，也不复用通用
  `structuredShell` / `networkStructuredShell`：Swift 只把固定 JS 与
  base64-encoded typed arguments 交给可信 Node 路径，并在 spawn 前重验 canonical
  workspace identity、WorkspaceLease access rules 和 mandatory denied patterns。
  action 的写集必须完整声明 profile、downloads、state、history 与本次额外
  output/input path，且在创建目录前完成预检。macOS 不给 Chromium 进程树再套一层
  Intatis Seatbelt，因为继承的外层 sandbox 会让 Chromium helper 触发
  `forbidden-sandbox-reinit`；这不是关闭隔离，浏览器自身 native sandbox 必须保持
  启用，绝不添加 `--no-sandbox`。Linux 浏览器 lane 继续要求 Bubblewrap。
- 浏览器 Node 进程使用 sanitized environment、参数数组、bounded head/tail
  stdout/stderr pipe、timeout/cancellation 与 process-tree TERM/KILL。cleanup 在
  browser spawn 后立即安装，不以 DevTools port 已出现为前提；因此 startup abort、
  port timeout 和 consumer cancellation 都必须收口 client、child 与 active marker。
- browser action/state/history/backend-result URL 在 Swift 侧只接受 HTTP(S)，
  Playwright/CDP driver 还会在导航前独立复核；非 HTTP(S) backend result 在正文
  返回或持久化前终止。CDP 的旧 `DevToolsActivePort` 必须先严格 unlink（只忽略
  `ENOENT`），新文件须通过 current-launch timestamp、owner、regular/single-link、
  size 和 endpoint shape 校验；`/json/version` 的 browser WebSocket 与所有 page
  target WebSocket 必须是同 port 的 loopback endpoint；该规则同时覆盖
  `/json/list` 和无现有 page 时的 `/json/new` PUT/GET fallback，任何 target 都须
  在构造 `CDPClient` 前完成校验。
- 浏览器 profile、cookies、localStorage、下载目录、state、history metadata 放在 workspace `.intatis/browser/` 下：`profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json`、`history.jsonl`。`state/<profile>.json` 保存当前页面 metadata 以及 Intatis 管理的 `navigationStack` / `navigationIndex`，供跨工具调用的 back/forward 使用；这些 profile 可能包含登录态，不写入 OS Keychain，不应作为普通 artifact 展示、提交或跨 agent 原文转发；`browser_profiles` / `browser_history` 只暴露受控 metadata，`browser_profiles` 只检查少数 Chromium active/lock marker 的存在性来提示可能有浏览器进程占用，不读取 marker 内容或 profile 数据库；页面摘要可暴露交互控件定位 metadata，但不得打印 cookies/localStorage/profile DB、密码/token 或当前文本输入值。
- 同一进程内，Playwright/CDP-backed `browser_*` 命令按 workspace profile 路径串行化，避免多个 agent 同时打开或写入同一 persistent profile、state/history 或导航栈；不同 profile 不做全局互斥，仍可并行执行。`browser_back` / `browser_forward` 的目标 URL 选择和真实浏览器执行必须处在同一 profile 临界区内。
- `web_fetch` 是 `.network` 工具；`browser_profiles` / `browser_history` / `browser_downloads` 是 `.readOnly` metadata 工具；`browser_profile_delete` 是 `.destructive` 工具；`browser_diagnostics` 是 `.exec` 但不标记 network risk；页面导航、headed handoff、刷新、前进/后退、交互、表单提交、滚动、等待、截图、上传、下载和搜索类 `browser_*` 是 `.exec` 且 `risksNetwork == true`。`DeterministicPolicyGate` 必须先检查 exec/shell-disabled/read_only 边界，再进入网络审批，避免无 shell 能力的 host 被 network ask 误放行。
- Cowork coordinator lease 可用 `browse_web`；worker 默认不获得 `web_fetch` 或任何 `browser_*` 工具。

### Cowork 链路（多 agent 编排，macOS 全量）

Cowork 的 durable work model 分四层：`Goal`（用户最终目标）→ `WorkTask`（用户可见计划 DAG）→ `ContinuationRun`（宿主一次推进/恢复 checkpoint）→ 既有 `TaskContract` / `TaskGraph` / scheduler（AgentInvocation execution layer）。箭头表示 scope/linkage，不表示终态自动传播；invocation completed、WorkTask completed 与 Goal completed 是三次不同的权威判断。

```text
Cowork session open/new -> checked EventLog is canonical for settings, roster, leases and migrations
  -> SessionProjectionStore rebuilds/refreshes derived schema-v2 session.json
  -> SessionWorkspaceAccessStore restores session-owned workspace-access.plist bookmark capabilities
  -> App/CLI compiles mutable provider config -> reconciles immutable InferenceCatalog revisions
  -> checked replay EventLog -> restore roster/AgentInvocation graph/scheduler/mailboxes/leases/token usage
       + Goal/WorkTask/ContinuationRun projection
       + exact per-agent inference bindings; unresolved legacy/missing revision stays blocked
  -> restore workspace bookmarks and current durable projection
  -> brand-new empty session: one strict settings-first seven-event batch
       seq 0 session settings
       seq 1...3 distinct @main workspace/capability leases + agent registration
       seq 4...6 distinct @permission-reviewer workspace/capability leases + agent registration
       same exact inference binding; reviewer remains read_only/no-tools/no-communication/no-delegation/depth 0
       no model/provider request during bootstrap
  -> resolve @main exact profile; freeze reviewer/GoalVerifier identity, binding and route
       permission reviewer resolves a fresh wrapper per generation; GoalVerifier keeps its independent lifecycle
  -> non-empty recovery missing @main: host-authorized local recovery from canonical settings/roster facts
       GUI repairs @main before reviewer replacement; CLI uses dedicated /agent restore-main
  -> CoworkViewModel -> GoalInputParser + CoworkMentionRouter
       ordinary turn -> GoalRuntimeController.sendUserTurn -> durable ContinuationRun -> Orchestrator
       /goal -> GoalRuntimeController.createGoal -> host-driven Goal run loop
  -> AgentRegistry / MessageBus(log:, mediator:) / PermissionEngine
  -> attach(agent) -> log agent_attached
  -> production Orchestrator.runtime 先取得 session EventLogWriterLease；冲突则启动失败
  -> GUI/CLI startup 创建保留 control-plane agent @permission-reviewer（read_only + no tools）
  -> GUI send(text) 默认路由到 @main；显式 @mention 仅作高级定向入口
  -> 每条普通用户指令及每个 Goal run 先创建 scoped root TaskContract (AgentInvocation)，再进入 durable queue
  -> scheduler 对同一 agent single-flight、对不同 agent 按 policy 有界并行
  -> Code/Cowork 共用 headless AgentRuntime；为每次 run 构建 AgentLoop + BusMessenger + OrchestratorManager
       -> verify live AgentInferenceBinding == frozen TaskContract binding
       -> ProviderRegistry exact-resolves that agent's immutable profile/connection revision
       coordinator(canCoordinate=true) -> lease-based registry with workspace/doc/media/browser + coordination tools
       read-only worker -> lease-based registry with read/list/search/read_pdf + reply/request-delegation tools only
       read-write worker/coordinator -> may additionally receive read_document process capability
  -> AgentLoop.send() 循环（Code 默认 maxIterations 50；Cowork 默认 64；host 显式配置可覆盖）
       ContextBuilder.initialMessages (RuntimeEnvironmentManifest + static system + history + scoped context + current user)
       stable Cowork @main:
         strict replay -> AgentModelHistoryProjector
         -> legacy completed U/A bridge（仅旧 submission）
         -> durable model_history_item user/assistant/function-call/output
         -> prompt-copy normalize（missing output => aborted；orphan output => drop）
       task-scoped worker:
         no main transcript -> bounded ContextBundle only
       -> provider.stream -> message_delta
       -> toolCalls -> strict schema validation
       -> optional host preflight（`delegate_task` 只读解析准确 target，不改 roster/lease）
       -> ToolRegistry.resolveAuthorization
            -> immutable ResolvedToolAuthorization（registry/spec/tool/task/tool-call/lease/args digest/intent/replay/gate）
       -> PermissionEngine.decide
            askUser -> durable permission_request -> PermissionResponder
                default -> UI 卡片/终端确认
                Cowork auto -> PermissionReviewControlPlane FIFO/single-flight
                  -> digest/count + bounded redacted action preview -> @permission-reviewer no-tool JSON decision + non-empty reason
                  -> durable permission_review_settled -> typed allow/deny/failure；异常只 deny 当前调用，不进入 UI fallback
            allow -> revalidate same authorization + capability/workspace/target identity
              -> durable tool_execution_prepared -> revalidate same snapshot/root identity -> executor
              -> durable tool_result + tool_execution_settled
            ask_agent -> typed success/failure；admission/Mediator failure 不得 settle success
            delegate_task -> execute exact reviewed target；deny 不创建 proposed worker，执行时不重新选人
            collaboration attach request/settlement related events -> one appendAdmissionEvents batch
                -> MessageBus.deliver + Mediator returns child answer/report to caller as ToolObservation
       -> ToolObservation 回填 -> 重复直至无 tool call
       -> SideEffectEvidenceLedger 以 durable succeeded settlement 约束 completion，并跨重启恢复 review→resolved→prepared 窗口
       -> task_completed/task_failed/task_cancelled records attempt + optional TaskReportPayload
       -> task-scoped tool-spawned child agent is auto-detached after it has accepted a task and becomes idle
  -> Goal run scheduler barrier
       -> checkpoint ContinuationRun
       -> independent GoalVerifierControlPlane (no tools, no EventLog writes)
       -> host validates verifier references against host-derived validationEvidence
       -> append audit + complete / continue / blocked / budget-limited / usage-limited
       -> continue by creating the next run, or stop after no-progress guard
  -> 每次状态变更 append 到 EventLog
  -> GUI folds CoworkProjection + TurnStatsProjection
       + CoworkProjection 同时保留 live operational roster 与 EventLog-derived historical identity roster
       + CodeProjection 在 actor 内增量维护 typed per-agent all/visible indices
       + snapshot 只发布受影响的 AgentID，不把无界 CodeItem 数组送到 MainActor
       + 每个窗口按 selected AgentID 查询最多 16-row page，并只订阅该 agent 的 latest-only update
  -> macOS Cowork wide inspector shows permission review first, then historical agent catalog, real Goal and real Tasks; no Git UI
MessageBus.deliver -> Mediator.mediate
  -> SecretScanner.containsSecret -> block
  -> content.count > maxChars(4000) -> block "send a summary"
  -> ForwardingReviewer(可选)
  -> .forward (log agent_to_agent_message + permission_review allow)
```

图中的“异常只 deny 当前调用”同时受 Phase B request/generation 边界约束：每个 provider dispatch 都有独立 `{reviewTaskID, nonce}` generation，provider/timeout 竞争首 terminal；caller cancel 另有同步 token 与下游围栏。timeout/cancel 只影响当前 call，若已有 active generation 就 retire 该代，下一次 review fresh-resolve provider wrapper。timeout 与 claim 前 cancel settle deny；claim 后 cancel 可保留唯一 settlement，但 authorization delivery 仍 deny。旧代 late/duplicate output 无法写 EventLog、改变 health/authorization 或触发 tool execution。

关键不变量：
- 用户默认只与 `@main` 对话；`@main` 是项目负责人 agent，持有 coordinator capability lease，可读写主 workspace 并通过工具自动创建、委派、移除子 agent。
- `@main` 自身与任何 ordinary agent 仍只有一个真实 `workspaceRoot`，直接文件、文档、Git、
  browser-file 或 terminal 调用不得跨根。coordinator 的静态 system prompt 只允许在当前
  authoritative tool list 确实包含 `spawn_agent` 时采用外部目录恢复规则：预知目标在根外或
  收到 out-of-workspace denial 后，不再直接重试或尝试路径逃逸，而是以目标绝对目录
  创建默认 `read_only`、按需 `read_write` 且默认无协调权的子 agent，spawn 成功后再以
  `delegate_task` 分派目录内工作。`spawn_agent` / `delegate_task` 不可用或 workspace expansion
  被拒时必须报告 blocker，不能宣称完成；这条提示只改变恢复路径，不放宽 WorkspaceLease、
  bookmark、PathConfinement、PermissionEngine 或敏感/过宽目录 hard deny。
- 当前查看对象与执行/发送对象分离：每个 Cowork 窗口默认查看 `@main`，可在右侧 Agents 区域
  选择 ordinary agent 并只读查看其 transcript；该选择是 window-local presentation state，
  不改变 runtime ownership、scheduler、mailbox、Goal、权限、lease、agent status 或 composer
  默认路由。`@permission-reviewer` / GoalVerifier 是控制面，不得成为普通 conversation target。
- Cowork wide rail 的几何由 stable outer detail width 唯一解析：visible 时 rail 为 348pt、section
  为 318pt，独立留出 10pt primary-scroller clearance。thread 复用单一 ScrollView 根并先固定
  content/raw frame；selected agent、page、内容长度、空态、rich/raw admission 与 scrollbar
  可见性均不参与横向几何。passive rail section 各自使用系统 `Glass.clear` 的稳定 backdrop，
  以共享 canvas 的光为基底，不另建整栏 surface 或手绘光影；独立 status cards 不进入会融合或
  重组 shape 的 `GlassEffectContainer`。exact outer-detail canvas 是 thread 与 rail 的共同且唯一
  几何宿主：thread 作为 leading overlay，rail 作为 trailing overlay，二者都不以对方的 intrinsic
  size 作为 alignment guide；不读取 screen-global origin，也不做 window-position/backing-pixel
  translation。rail 的 Equatable snapshot 只含真正会改变 rail 结构/内容的输入，明确排除
  selected-agent conversation ID；selection 通过 rail 内独立轻量状态只重绘蓝色行 affordance 与
  accessibility value。每个 passive glass backdrop 又是 content-independent Equatable view，使用
  identity transition、无 inspector 隐式动画，并在 glass 之外以系统动态 separator 的单物理像素
  `strokeBorder` 锚定结构边界。Code/Cowork
  bottom anchor 由 `onScrollVisibilityChange` 观察，不使用 GeometryReader/PreferenceKey 坐标回写。
- `CoworkProjection.agentRoster` 只表示当前在线、可操作的 runtime roster；
  `historicalAgentRoster` 从同一 EventLog fold 保留 session 中所有曾 durable attach/spawn 的 identity。
  `historicalAgentOrder` 按 identity 第一次 durable admission 追加且不因状态、消息、detach 或 reattach
  改写；GUI 直接消费该顺序，不在每次 projection 更新时按名称或实时活动重新排序。
  detach 只移出 live roster，ordinary historical identity 仍留在同一 Agents 列表、以既有状态图标显示
  detached、可点击查看且当前选择不回退 `@main`。所有发送、委派、消息、ask、rebind、remove、
  workspace/capability 操作必须先检查 live roster；保留控制面 identity 始终 status-only。
- Agent transcript 归因必须来自 typed Event payload/correlation：user message 使用 `to`（缺失时
  只回退 durable main），model message/tool/patch 使用 typed agent，tool result 继承 call，
  submission error 继承 submission；A2A/information/delegation/task 事件可同时索引双方，但 canonical
  row 只保存一次。不得在点击路径按标题、正文、`@name` 文本或字符串前缀猜测归属。
- 点击和 live publication 的成本必须与总历史长度无关：canonical history/index 留在 projection
  actor；MainActor 只接收受影响 AgentID 和选中 agent 的最多 16-row page。每个 agent 保持独立
  page boundary；切换请求用 generation/cancellation fence，A→B→C 只允许 C 提交。非选中 agent
  的增量不得使当前 transcript subtree 失效。历史 Agents rail 使用 stable ID 的 lazy stack；
  roster presentation 必须先按 agent 聚合 task/lease/status，禁止对每个历史 agent 重扫全部 task/lease。
- Cowork thread 必须保持单一 ScrollView/ScrollViewReader 根，不得用 `.id(pageScope)` 在每次
  agent/page 变化时替换原生文档树；可见行按 0...15 稳定槽位复用。selection、page 或选中
  agent 内容改变时 rich admission 立即暂停，精确状态静止 300 ms 后才恢复；连续 streaming
  保持 raw text。该门只改变展示成本，不得丢弃 canonical content 或改变 EventLog。
- 每个 ordinary agent 的推理 binding 与 `PermissionProfile`、`CapabilityLease`、`WorkspaceLease` 相互独立。Project/session default 只创建未来 agent；已有 agent 保持 exact revision。`spawn_agent` 默认精确继承、显式 profile 需 host-approved；delegate 不改目标 binding；host rebind 只允许 idle agent 且 durable-first。legacy 无 binding、exact revision 缺失、definition mismatch、unsupported wire 或显式声明的必需能力不兼容均 fail closed，不可套用当前默认或相似 model。
- Reviewer 与 GoalVerifier 是控制面，不跟随普通 agent rebind；GUI/CLI 首次以 `@main` exact binding 冻结其 identity/route。Permission Reviewer 随后按该冻结 binding 为每个 generation 重新 exact-resolve provider wrapper；GoalVerifier 仍使用自己的独立 provider lifecycle。当前没有独立 route lease 或跨 trust-domain 专用审批，不能从 control-plane freeze 推导出这些尚未实现的能力。
- `Goal`、`WorkTask`、`ContinuationRun` 和 AgentInvocation 各自使用稳定 ID、revision/status 与追加事件；`CoworkProjection` 可从 EventLog 恢复四层关联。现有 `TaskContract` 类型名与 `task_*` 执行事件为旧日志兼容而保留，在产品语义中只代表 AgentInvocation，不得再投影成 Goal/WorkTask。
- `task_create/update/get/list` 管理 durable WorkTask；coordinator 可管理当前 run/Goal 范围，worker 只能读自身/依赖并更新绑定且归属自己的 WorkTask。DAG 校验 missing/self/cross-run/cycle、readiness、revision 和 result/evidence；依赖变更由 host graph 在同一 batch 重新计算被编辑节点与下游 readiness，投影拒绝与 DAG 不一致的 ready/pending/blocked 事件。WorkTask 进入 `in_progress` 后执行契约字段不可改。`delegate_task` 可绑定 WorkTask 并追加 invocation linkage，但 child report 只是 candidate result；legacy child delegation 与 causal mailbox wake 未显式绑定 WorkTask 时，仍从父 TaskContract 继承 Goal/ContinuationRun scope。
- write-capable WorkTask invocation admission 会比较同 workspace 内 active writers 的 `expectedArtifacts`：父/子路径视为重叠并拒绝第二个 writer；空、越界或不可规范化的声明按未知 write set 处理，对该 workspace 保守全局冲突。该检查是 scheduler admission 的补充，不能替代 WorkspaceLease/PermissionEngine，也不阻止只读 invocation 并行。
- `create_goal/get_goal/update_goal` 是受 schema、PermissionIntent 与 capability lease 约束的 control-plane tools；Goal create 还必须绑定明确用户意图。Cowork `/goal` 由宿主直接建立 durable Goal；普通 macOS/CLI 输入只在附件拼接前通过窄、确定性的中英文持续目标分类器后传 `explicitGoalIntent`，普通复杂请求、Goal 提及、一次性目标或引用示例都不提升权限。分类器只授予本轮 tool surface 的 create intent，仍不绕过 tool schema/lease/PermissionEngine/host authority。`update_goal` 进入 exact `@main` 的 main-only lease，普通 worker、spawn coordinator、task-scoped non-main 与 reviewer 不继承；它只能在已有独立 GoalVerifier/host audit 的 current revision 上提交 complete/blocked 转换，不能创建或修改证据，因此不构成 `@main` 自我认证。
- `finish_run` / `stop_run` 是模型可见、宿主执行的 current-run close tools，只进入 exact `@main`、issuer=nil、带 non-nil ContinuationRunID 的 root invocation，并要求 main-only `controlRun` capability；worker、child coordinator、mailbox task 与 reviewer 均不可见。模型参数只有 1–1000 字符 reason，不能选择 SessionID、RunID、GoalID、SubmissionID、root TaskID 或 close source。工具仍经过 schema、registry、lease、PermissionEngine、durable execution ticket；获准后 close installation 先成为 actor-local admission/authorization tombstone，EventLog 再在 complete-known history 与跨进程锁内为 exact RunID 安装 first-write `continuation_run_close_requested` claim，且 durable claim 必须早于等待既有 admission 与 exact-run drain。claim 不替代既有 run completed/cancelled checkpoint：Orchestrator 只 drain 同 RunID 的其余 task/message，允许当前 root 返回一次最终文本，并在 restore 时先兑现 fence；不同 run 不受影响。普通自然语言 final 不伪造显式 claim；root failure/cancel/timeout、用户 Stop 与 session shutdown 分别保留 runtime/user/hostLifecycle source，并在 provider/tool cleanup 前关闭精确 run。
- `rename_session` 也是普通 ToolCall，而不是隐藏标题模型或 UI 特例。模型参数只有 1–120 字符的 `name`；当前 SessionID/SessionKind 与 durable operation ID 由宿主分别从 runtime 和 execution ticket 注入。Code 单 agent 与 Cowork exact `@main` 可见，worker、spawn coordinator、其他 agent 与 reviewer 不可见；Chat 保持无工具。工具仍经过 strict schema、ToolRegistry、CapabilityLease（Cowork）、PermissionEngine、durable prepare/settle 与 `tool_result`，但 exact current-session intent 是 deterministic low-risk allow，不生成用户弹窗或 reviewer 请求。名称先 secret-scan，raw value 不进入 durable tool-call arguments；EventLog rename source/operation ID 使 exact executor retry 幂等。
- `GoalVerifierControlPlane` 与数据面 agent、`@permission-reviewer` 分离：使用独立 system/context 和无工具 provider 请求，不写 EventLog；默认不注入 sampling、output-token 或字符上限，显式 host policy 才可启用。WorkTask result/evidence 只是 agent-reported；host 从同一 Goal 下 durable 成功 tool-execution settlement 中，仅按 validation-tool allowlist 派生 `validationEvidence`，再校验 verifier 的 requirement/evidence 引用。malformed/tool call/缺完成标记/普通 provider failure/timeout/cancel 只返回 continue。Goal completion proof 必须非空、没有 remaining work/blocker、每条 requirement proven 且带 host-bound evidence，并按规范化文本逐项覆盖 Goal objective、全部 success criteria 与 constraints；重复 requirement 也必须按次数覆盖。只有该完整证明可驱动 Goal completed。
- Code 与 Cowork 不维护两套执行内核：二者使用同一个 Swift-native headless `AgentRuntime` 工厂，统一 registry、permission、completion、durable tool ticket 和单次请求参数。`RuntimeEnvironmentManifest` 在每次请求的首个 system message 中稳定声明 Intatis/Code 或 Cowork、外部动作只能通过 API tools、严格 JSON Schema 和 ToolResult 完成语义；动态 agent/workspace/task/lease/event 仍只进入有界 user-role untrusted context。
- 用户指令不是一段脱离任务图的直接 AgentLoop 调用：它必须成为 root `TaskContract`，经历 durable queue 与严格终态后 `send` 才返回。`created` / `assigned` / `queued` / `running` 不能被投影为完成；失败、取消和不完整 provider finish 必须保留原因与 attempt。
- Cowork final turn 在发布正常完成答案前先校验 side-effect evidence；只有校验通过时，最终 `message_completed`、final assistant model-history item、agent idle 与 `turn_outcome(completed)` 才在一个 EventLog batch 中提交。failed/interrupted outcome 是权威终态：`CodeProjection` 会把旧日志中先写出的 completed 气泡纠正为失败/未完成，`AgentModelHistoryProjector` 保留真实 user/tool history，但不把该轮失效的 final assistant 回灌下一次 provider request；同一 TurnID 的冲突终态 fail closed。
- root、delegation、mailbox wake、retry、agent attach/reviewer attach 与 crash requeue 都遵循 persistence-first admission：先写完执行所需的 roster/lease/task/queue 事件，再提交 registry/taskGraph/scheduler 内存状态。关键 admission 事件写入失败时不得运行 provider；已写入的半 admission task 立即补 `task_cancelled`，恢复时 orphan default lease 也不得进入可执行状态。
- `AgentScheduler` 的 claim 是短临界区；长 AgentLoop 在独立 task 中运行。同一 assignee 同时最多一个 claim，不同 assignee 受 `maxConcurrentTasks` 限制。actor reentrancy 不得绕过该 single-flight/claim 规则。
- 恢复期间 scheduler 保持暂停：先通过 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 验证 session identity、已知事件 payload、从 seq 0 到 durable tail 的连续性、unknown future type 与 WAL recovery，再折叠 `tool_execution_prepared/settled`；unknown future event 或 seq gap 都不能支撑“没有发生”或先后顺序证明，锁/读取/损坏/不完整历史也不得退化为空投影。只有明确 eligible 的 non-root/CLI read-only crash-recovery task 可随 running task 以 `attempt + 1` 重排；Phase A GUI restored root submission 不得自动重排；write/exec/network/destructive 或消息/委派/spawn/remove 等协作副作用若 prepared 未 settled，任务必须以 `manual reconciliation required` 失败，禁止自动重放。whole-task 显式 retry 也必须经过同一 complete-known-history gate，不能因旧程序看不懂新事件、seq gap 或日志读取失败把 non-replayable 证据当空。created/assigned 半入队、超过 maxAttempts、缺关键 lease 的任务也明确失败；queued task、未消费 mailbox、task graph、lease history 与 token 用量从同一已验证事件快照重建。GUI/CLI 先恢复 `@main` 与 reviewer（CLI 仅在用户显式 `/default` 时允许人工模式），再启动 Goal recovery。GUI 只为新提交释放 startup gate，恢复出的 root tasks 继续被 scheduler 排除并显示 interrupted，直至精确 submission Retry；CLI 仍保留自己的显式 resume 边界。历史 active Goal 只 reconcile/checkpoint/audit 后 durable pause，不自动创建 continuation。
- Durable tool recovery 以具体 outcome 而不是工具类别单独判定：`ToolExecutionSettledPayload.effectDisposition` 是 additive optional 字段；新成功写路径显式记录 `.committed`，legacy nil+succeeded 仅兼容视为已完成效果并仍阻断 whole-task retry，legacy failed/cancelled/denied nil 则保持 uncertain。只有受信写路径产生、且与唯一 exact prepare payload/sequence 匹配的 `.notStarted` 能证明 declared side effect 未跨 mutation boundary。生产 Orchestrator 的 WorkTask adapter 在 admission lock 内把首个 WorkTask EventLog append 之前的 preflight/permission/frozen-contract/graph rejection 转为 typed no-effect，AgentLoop 以同一 batch 写 model-visible failure 与 `settled.failed/not_started` 并继续该 Agent turn；任意公共 manager 的同名错误不自动升级。append 或其后的 persistence/lost-ack 错误绝不进入该转换。`task_update` 按 PATCH 解释；与 authoritative task 完全相同的合同字段先归一为 no-op，真实合同变化仍拒绝。post-prepare 但 pre-executor 的 authorization/workspace rejection 和 cancellation也可写 no-effect settlement，但 cancellation 仍中断 turn。executor 已进入后的 cancel/timeout/普通 error 保持 non-replayable unresolved。Projection 对每个 execution ID 只接受首个 prepare；重复 prepare即使 payload 相同也保留首记录并永久 ambiguous，冲突 terminal 同样保留首记录并永久 ambiguous，完全相同的重复 terminal 才是幂等。ambiguous、settlement payload mismatch、顺序错误与 `succeeded + not_started` 矛盾均视为无有效 settlement并进入 uncertain。Orchestrator restore 在 complete-known history、无 current Goal、exact 唯一 prepare、没有 settlement/ambiguity且 expected revision 为 JSON safe integer时，仍可用 pre-prepare durable revision 严格大于 expected 的 stale proof补 no-effect；也可在唯一未脱敏 raw args、参数 digest、prepared authorization、agent/TaskContract/capability lease/run/WorkTask snapshot 全部精确一致时，证明旧 worker snapshot-field guard 或旧 in-progress frozen-contract guard 必然在 append 前拒绝。任何 current Goal 都不做该兼容修复；redacted/missing/mismatched identity 和自由文本错误都不能构成证明，也不得从 prepare 后状态推断。显式 unknown 继续 uncertain；显式 committed、legacy nil+succeeded 与其他可能已执行的 disposition 仍阻断 whole-task replay。
- `GoalRuntimeController.start()` 与每次显式 continuation launch 都使用 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 观察 EventLog；known-event 损坏、unknown future event 或 seq gap 不能退化成空 session，也不能支撑 absence/order proof。它检查 uncertain non-replayable 集合：无有效 settlement、显式 unknown、`succeeded + not_started` 矛盾，以及 legacy failed/cancelled/denied nil；known committed 与 legacy nil+succeeded 不属于 unknown，但仍由 whole-task replay guard 管理。没有 current Goal 时，只有 complete-known history 同时证明 exact TaskContract 在 prepare 前存在、prepare 带正 attempt、同 attempt terminal event 在 prepare 后发生，才允许 terminal AgentInvocation 的 ticket 与普通新工作隔离；orphan terminal、attempt mismatch、unscoped、missing/nonterminal 或 corrupt/incomplete history均 fail closed。存在任何 current Goal 时 uncertain 集合必须为空。冷启动 `start()` 是 reconcile-only：active Goal 先经过 scoped barrier，恢复/checkpoint并结算未审计 checkpoint，然后 durable 写 paused；已到 token budget 则写 budget-limited。任何取消、checkpoint、pause 或结算持久化失败都 fail closed，不创建 continuation。只有用户显式 Resume 或同进程的明确 Goal Edit/Resume 动作才进入 launch gate；launch 会再次结算遗漏 checkpoint 后创建下一 run。Goal mutation 与 ordinary turn 共享串行 mutation gate，stop 有独立 single-flight lock；shutdown 是终局 fence，不得在失败尾部 resume data plane 或接纳新 turn。Pause/Edit/Clear 必须先安全停止当前 run并成功 durable checkpoint，失败时控制面变更 fail closed；Goal Edit 成功会清空旧 latest audit、blocker fingerprint、consecutive blocked/no-progress streak。completed/blocked/budget-limited/usage-limited 不自动续跑；active Goal 的连续 no-progress run 达阈值后保持 active 但停止自动循环，等待用户 steering/resume；默认阈值为 2，blocked 则要求同一 normalized blocker 至少连续 3 个 run。
- Goal continuation 每轮只由宿主建立一个 run；新建 Goal 会把该次 Send 冻结的 exact `@main` binding 保存为 additive optional `Goal.mainAgentInferenceBinding`，新式 Goal 的每次 continuation、Retry 与重启恢复都沿用这一值，legacy/model-created Goal 的 `nil` 只保留兼容语义。新 run 先原子 carry-forward 旧 run 的非终态 WorkTask，再向 `@main` 发送 `recordUserMessage=false` 的 scoped root invocation。carry-forward 会取消 source、为 target running run 分配新 WorkTask ID、重映射同批依赖并追加 `work_task_carried_forward`；session/Goal/run ownership 或外部非终态依赖不一致时 fail closed。scheduler barrier 与取消都只作用于同一 Goal/可选 run，并覆盖 queued、claimed、running execution；精确 Goal/run cancellation tombstone 在 root admission 入口、WorkTask carry-forward 后、admission lock 内和 durable queue append 后均检查，admission barrier 会等待在途创建，取消循环再 snapshot。已 durable 部分入队的 root task 必须先 settlement 为 cancelled，provider 才可保持未调用；terminal cancellation 落盘失败的 task 会被 quarantine 并从 result/idle waiters 的阻塞集合排除，但 tombstone 继续禁止 provider dispatch。run durable checkpoint 后才可 audit，每个 run 最多一次；production `settleGoalRunAudit` 在同一 admission lock/replay 下，以单个 append batch 提交 audit、run completed 与可选 Goal completed/blocked/budget-limited/usage-limited。verifier usage 以 scoped `turn_stats` 计入该 Goal/run。
- Goal token budget 只有用户显式设置才存在，达到后在安全 checkpoint 标记 budget-limited。普通 HTTP 429/rate-limit 与单次 `length` / `max_tokens` output limit 不代表账户配额耗尽；只有 typed `ProviderUsageLimitError` 会在 scoped `task_failed` 追加可选 `TaskFailureCode.providerUsageLimit`，且内存 hard-limit signal 只能在该失败事件成功持久化后发布。restore 只从该结构化 code、TaskContract Goal/run 归属、current non-completed Goal（包括 paused）和尚未 audit 的 run 重建 hard-limit signal，原子 Goal/run settlement 成功后才消费，绝不从错误自由文本分类；该信号单独标记 usage-limited，不冒充 blocked/completed/budget-limited。
- 任务执行受 task/default timeout、显式 cancel/cancelAll、maxAttempts 和 session 共享 soft token budget 约束。预算在 provider dispatch 前预留 input estimate + output slice，并把 output ceiling 映射到 OpenAI-compatible `max_tokens`；provider tokenizer、usage 或 ceiling 支持差异仍可能导致 settle 时 overrun，因此不得宣传为硬计费上限。provider watchdog 使用不等待迟到任务的 race；raw shell/process 另有 OS sandbox、默认断网和 TERM→KILL 有界清理。
- 动态层级通过 scheduler/message bus/task graph 表达，不允许 `AgentLoop` 同步递归调用另一个 `AgentLoop`。子 agent 默认是 worker，无 coordinator 工具；只有 `spawn_agent(canCoordinate:true)` 或未来显式 capability lease 授予时，子 agent 才可继续创建/调度下级 agent。
- `ask_agent` / `delegate_task` 工具必须通过 scheduler 运行目标 agent，并通过 `MessageBus.deliver` / `Mediator` 把子任务结果返回给调用方；`ask_agent` 保持兼容的直接答案，但 admission 或 Mediator 阻断返回 typed failure 并抛为工具失败，不能产生 succeeded execution settlement。`delegate_task` 的 `to` 可省略：review 前由 host 只读解析为精确现有 agent 或拟创建的 `worker-N`，authorization 记录 agent/workspace/model/access/canCoordinate/mayCreateWorker 与 target fingerprint；preflight 不改 roster。allow 后必须复核 exact target、lease 与 availability，执行只能使用 reviewed target，禁止 re-resolution/fallback；deny 不创建 worker。并发省略 `to` 的 delegation 必须在任何 mediation/admission await 前预留其 worker，完成或失败时释放，不能让多个独立调用因 actor reentrancy 选中同一 idle agent。调用方收到稳定 `task_id`、`agent_id` 与结构化 Task Report，不应只收到 queued ack，也不得通过直接嵌套 `AgentLoop` 取得结果。
- `ContextProjector` 为 task-scoped worker 构造 `ContextBundle`，包含全局摘要、任务契约、lineage、direct message、agent-local event、workspace/tool brief，以及 metadata-only 的 `taskGroupEvents`。任务组状态只能暴露任务 ID、状态、agent 和 current/parent/sibling/child/related 关系，不得把 sibling objective、expected deliverable、tool args、workspace private path 或 task result 投影给无关 worker。submission-bound task 以 accepted `user_message.seq` 为逻辑顺序，message/output/error 使用 submissionID，task/tool 通过 durable task correlation 归属；只投影更早 submission 的内容，当前旧 attempt、later submission、冲突或无归属 legacy content fail closed。稳定 `@main` 是明确例外：它从 `model_history_item` 恢复自己的长期 provider thread，`ContextBundle` 只作为追加的 untrusted task data；direct model history 已覆盖的 final answer/tool pair 不再以 bounded audit preview 重复注入。当前 `artifact_added` 没有 task/recipient/visibility 等显式分享元数据，因此事件投影对 `explicitlySharedArtifacts` fail closed。
- `spawn_agent` 由当前 coordinator agent 发起并记录 `requestedBy` ownership。外层 ToolCall 的 `PermissionIntent` 是 `agent.spawn`：目标目录是 `workspace` admission resource，不是文件 `touchedPath`，因此不会被误报成“write to workspace”；reviewer 会看到 agent/model/`requestedAccess`/`canCoordinate`/workspace-expansion 风险。新 agent 默认 `requestedAccess=read_only`，只有显式 `read_write` 且不超过调用者 WorkspaceLease ceiling 时才可获得写入能力；`canCoordinate` 独立控制 coordinator 工具，不能暗中提升 workspace access。获准后 executor 用一个 durable admission batch 建立 roster/workspace lease/capability lease/attached/spawned 状态，内部不得递归调用普通 `attach` 或产生第二次 PermissionEngine 决策；子 agent 后续每次文件、网络、exec 调用仍各自走 PermissionEngine。未承接任务的 tool-spawned agent 作为 team member 保留，等待后续 `delegate_task`、普通消息或显式 `remove_agent`；已承接任务的 tool-spawned、任务域内子 agent 在无 pending/running/issued task 和 pending mailbox message 后由 Orchestrator 自动 detach。用户/GUI 手动 attach 的 agent 不参与该自动回收。
- Session settings、agent/lease 登记与运行事件共用 EventLog 事实链；`session.json` 只是一份 secret-free 可重建投影。settings update 使用 revision/previousRevision CAS，unknown future session event 会阻止旧二进制覆盖投影。EventLog append 返回值与 subscriber 必须从实际编码 bytes 反解 canonical Envelope，不能让 decode-only 字段或 Date 精度造成运行时/重放分叉。legacy display name 必须先在 EventLog transaction 中追加 settings+marker，再 rebuild；Cowork/Chat/Code 实际入口都走这一顺序。显式 rename 可追加 source 与 operation ID：同一 ID 的 exact retry 返回原 transition，不追加事件；同一 ID 的冲突 payload fail closed；A→X、B→Y 后 retry-A 只返回当前 projection Y，不能覆盖 B。目录名和 `SessionID` 永远不变。
- Cowork Send 先冻结 `UserMessagePayload + SubmissionID`；协议字段 `mainAgentInferenceBinding` 为 additive optional，但新式 main-hosted message/Goal 必须在按钮按下瞬间取得 non-nil exact binding，否则保留草稿并拒绝本地 admission；只有 direct worker、Chat 与 legacy Cowork 允许 `nil`。因此连续排队的 A/B 可各自保留不同模型。`SubmittedIntentStore` 先写 session-owned outbox，再在一个 EventLog transaction 中 canonicalize 唯一 `user_message + queued(attempt 1)`；只有 canonical EventLog 可驱动 FIFO execution。FIFO 到达 main submission 时，Orchestrator 在同一 admission-lock hold 和单个 EventLog batch 中提交可选 `agent_attached` rebind 与该 root 的 `task_created + task_assigned + task_queued`，成功后才一起更新 live roster/taskGraph/scheduler，避免任何无关 delegation 先消费新 binding。状态按 one-based attempt 单调追加；retry 复用 root `TaskContract.submissionID`、原 submission 的 main binding 与同一 task，并把所需 rebind 与 retry queue event 原子提交，`recordUserMessage=false`。恢复的 queued/running submission 对用户显示 interrupted，restored task 继续被 scheduler 排除，直至该提交显式 Retry。
- Cowork draft/import 与 remote readiness 分离：输入框不受 reviewer、Goal、main inference、pending permission 或 `isWorking` 禁用；同一 frozen payload 保存期间只禁止重复 Send。附件先写 session ArtifactStore；image 可进入 provider adapter，其他文件和 Goal attachment 以明确 failure 保留在本地。
- Apple bookmark 是能力材料，不是 settings：只进入 session-owned schema-v1 binary `workspace-access.plist`，以 `0600`、no-follow lock、atomic replace/file+parent sync 保存。macOS `WorkspaceAccessLease` 必须从 bookmark 解析出的同一个 scoped URL 开始访问，在活跃 Code/Cowork view model 生命周期内保留，并在 teardown 后释放；canonical path 只用于 identity/精确匹配，不能替代 security-scoped URL。共享目录不能由单个 `agentName` last-writer 覆盖；删除 Agent/目录必须先 persist settings，再仅删除经剩余 settings + live roster 证明零引用的非-primary bookmark。primary 在 inspector、ViewModel 方法和 store 默认三层拒删；只有尚未成立的新建/重授权事务失败回滚可显式越过 store 防线。
- Legacy UserDefaults 只作迁移输入。共享旧 path→bookmark map 必须有 per-session ownership evidence 才能消费；迁移只有在 exact binding、全部必需 bookmark、primary 语义和 capability 文件都验证成功后才继续。符号链接 alias 必须在 scope 激活后与 canonical identity 比较，并先追加 canonical settings revision，再写稳定 migration marker/清理旧 key；marker 前中断可重试，marker 一旦存在也不能回退全局旧 map 使能力材料复活。
- Cowork session 可绑定一个或多个用户选择的工作目录；EventLog settings 只保存 secret-free path/agent/primary/future-profile/permission/token-budget metadata，bookmark bytes 只进入 session-owned capability plist。brand-new session 中，用户明确选择 primary workspace 后，固定七事件 bootstrap 同时记录 settings、`@main` 与 reviewer 的独立 leases/identities，不再让 reviewer 重复审批同一次选择；任何后续目录新增、普通 agent attach 或 spawn 仍依赖 workspace bookmark 与既有权限流，历史缺 main/reviewer 只能走上文专用 host recovery，不得复用 fresh bootstrap。
- `@main` agent 不可被 remove。
- Project Settings 新增目录只更新 project metadata；当前工具执行仍以 agent 单 `workspaceRoot` 为真实文件访问根。右侧 inspector 不提供 agent 删除或详情管理，按权限审查、未清理 agent 状态图标、Goal、Tasks 的顺序显示且不提供 Git UI；`@main` 与 `@permission-reviewer` 不可删除。
- `@permission-reviewer` 是自动权限审查保留身份和独立控制面：GUI/CLI 默认启用；CLI `/auto` 只用于重新启用，只有用户明确 `/default` 才进入人工模式；不能作为普通 send/delegate/message/ask 目标，也不会暴露给 `list_agents`。review queue 不占普通 scheduler 槽，采用 64 项上限的 FIFO/single-flight，deadline 从 submit 计时；request/task/root/parent/attempt/toolCall、参数 digest/count、bounded redacted `PermissionActionPreview`、paths/network/side-effect/gate/lease/TaskContract/causal context 通过结构化任务传递，automatic-review payload/prompt 不含 raw args。exact model-authored automatic ask-class call 还必须携带完整 `authorizationContext`：acting agent 的同模型/no-tools 报告是 untrusted interpretation，canonical latest/supporting user evidence 由宿主从 complete-known EventLog 解析并闭包覆盖中间用户指令；二者在 reviewer prompt 中分栏，缺失、冲突、secret-bearing 或不可证明时以 `authorization_context_unavailable` 在 reviewer provider 前 durable deny。reviewer 只返回 `allow` / `deny` 和非空有界 reason，risk 不能低于 deterministic gate；单次 deadline 默认为 120 秒。模型请求默认不注入 `temperature`、output-token 或字符上限；只有显式 host policy 才传递对应控制，optional completion estimate 只用于 soft usage accounting。pre-submit caller cancel 直接返回 typed deny且不创建 review lifecycle；timeout、truncated、malformed、tool call、provider error、persistence failure、self-review、hard deny 与已登记 review 在 terminal-claim 前被观察到的 cancel 均产生 typed failure 并 durable deny 当前调用，不转 GUI 人工等待；claim 后 cancel 保留唯一 settlement 但 authorization delivery deny。provider error 的 durable reason 使用共享 diagnostic sanitizer 限长并移除 secret/完整 URL。review request/settled 必须 durable-first，`allow` 只有 settled 成功后才可生效。每次 provider dispatch 都创建 exact generation，production provider factory 冻结 reviewer identity/binding 而逐代重新 resolve wrapper；provider/timeout 竞争同代首 terminal，caller cancel 由同步 request token、actor path 与 settlement/delivery/admission 围栏共同处理，late/duplicate result 被丢弃。timeout/cancel 只影响当前 call；若已有 active generation 就只 retire 该代，后续 request 可 fresh review；legacy `provider_still_stopping` 只解码旧日志。Phase A 后 reviewer 未就绪由 unavailable responder deny 真实 ask-class tool，但不禁用 composer 或阻止普通主请求；Cowork 对话页不再常驻 reviewer 状态横幅，workspace reauthorization 与 automatic-review retry 只在异常时出现在 Project Settings 的 Recovery 区。Cancel task 只取消数据面任务并保留 reviewer，session stop/显式 disable 才 quiesce/shutdown 控制面。disable quiesce 后若 durable detach 失败，resume 也必须使用 fresh generation，旧 allow 无效。
- `AgentLoop` 对 exact denial signature 的 fuse 区分 authoritative denial 与 typed transient reviewer infrastructure failure。前者继续只送审一次并缓存拒绝；后者只允许第一个 exact retry 生成 fresh RequestID/generation。首个失败调用没有执行权，fresh retry 也必须从 gate/authorization 重新开始；第二次失败不重新装填 fresh-review 额度。
- MessageBus 是唯一投递路径；Mediator 默认转发摘要不转发原始字节。
- typed message 只有在 Mediator 允许且事件持久化成功后才进入 mailbox。新 mailbox delivery 的 `TaskContract.mailboxMessageIDs` 冻结 1–8 个 exact ID；ContextProjector 只呈现该集合，batch 还必须保持同 sender/recipient/Goal-run/authority class。ordinary message 是 one-way，使用 read-only workspace 且 communication `.none`，不暴露 ACK 工具；information request 只获得 `reply_message` + `.replyOnly`，并且必须以 `inReplyTo` 精确终结 frozen RequestID，同一请求只接受一个 terminal reply（exact duplicate 幂等、冲突 reply 拒绝）；information reply receipt 不暴露 `reply_message`，而只允许向原 sender 发起 `request_information`。若内容需要继续讨论，receipt 必须把 reply MessageID 作为 `based_on`，创建 fresh RequestID、保留原 `conversationID`，因此一次 `information_replied` 只关闭当前 correlation，不关闭长期对话。receipt/ordinary message 不发送礼貌 ACK。`request_delegation` 另只可在原 default ceiling 内获得最多一次、深度 1 的 delegation。未呈现或未成功完成的消息保持 pending；失败只能在同一 TaskID 上按 `maxAttempts` 有界重试，已耗尽的 poison ID 不得换新 TaskID 重置次数，也不得阻塞后来未绑定的 ID。成功时 `task_completed`、可选 candidate WorkTask progress 与 exact `agent_message_consumed` 在一个 EventLog batch 中提交，随后才 ack 内存 mailbox；Goal/run cancellation 只能 durable `agent_message_discarded` 后 ack。legacy nil correlation/binding 继续可解码，只按 exact causal/scope/时间 lineage 保守匹配，不能据此扩大 live follow-up 权限。
- task-scoped capability/workspace lease 必须校验 task ID、工具/通信/委派 grant、workspace root、access 与 allow/deny path，并在 terminal state 撤销。WorkspaceLease 持久化 canonical root 的 device/inode identity；attach commit、权限等待后、durable prepare 后紧邻 executor、task lease 派生/retry 与 managed process 启动都必须重新核验，路径相同但目录身份改变或 legacy identity 缺失时 fail closed。retry 只能从原 lease audit history 克隆权限；历史缺失时 fail closed（当前拒绝 retry），禁止回退到 assignee 的默认 coordinator lease。
- `ContextProjector` 对每类事件设 count/character budget，只取最近且与 task/agent 相关的内容；dynamic task/message/event data 通过 user-role `UNTRUSTED_CONTEXT_DATA` 块进入请求并转义边界文本，不得拼入 system role。Cowork system prompt 使用静态身份说明，不嵌入动态 agent name/workspace path；Orchestrator 的 attach/spawn 边界拒绝控制字符、空白、超长和非安全 ASCII agent 名。消息只有在实际投影后才可写入 consumed event。
- 任何 model tool_call 到执行都必须过 PermissionEngine，无旁路；tool intent、permission resolution 与 execution prepare 任一关键审计写入失败时 executor 不得运行。
- production `ToolRegistry.standard` 与 Cowork lease registry 不暴露 raw `run_shell`；`.runShell` 仅保留为旧 lease 的 read-only Git compatibility 信号。底层 `ProcessShellRunner` 仍以 Seatbelt/bwrap 做 workspace+network confinement，供隔离测试与未来签名 helper/XPC 演进；结构化 Git/browser/document backend 使用独立 runner，不得借此恢复模型任意 shell。
- 自动权限审查不启动嵌套 AgentLoop；审查者 provider 只收到无工具 JSON 判断请求。`DeterministicPolicyGate` hard deny 仍在审查者之前终局。

### macOS 应用级 session runtime 生命周期

- `AppSessionRuntimeManager` 是进程级 runtime owner，使用 exact `{SessionKind, SessionID}` 缓存 Chat/Code/Cowork runtime，并发布 busy/status/removal。窗口级 `AppEnvironment` 只持有自己的 mode/session 展示选择；切换、History、Command-W、关闭最后窗口都不触发 runtime stop。Command-N 创建新窗口时仍连接同一个 manager，因此不会为已有 session 重复创建 runtime。
- 删除 session 先对 exact key 执行 runtime shutdown，再删除 durable session；manager 发出 removal 后，其他窗口清理对应 Code/Cowork detail 或切换到仍存在的 Chat session。只删除一个 session 不影响其他 session 的后台工作。
- AppKit termination 使用 `applicationShouldTerminate` 的 terminate-later 协议。manager 先进入 quiescing、关闭全部 runtime 的新操作 admission，再同时广播 stop，并由 `BoundedSessionRuntimeShutdown` 使用单调时钟等待 bounded deadline。已完成项记为 settled；超时项只记 timedOut，不能冒充工具/任务已经 durable settlement。应用最后只调用一次 termination reply。
- Chat/Code/Cowork shutdown 均取消并等待其拥有的 send/provider/tool/direct-operation task，再清理 permission waiter、EventLog subscription 与 workspace access lease。Cowork 所有公开 mutation 入口共同检查 admission fence，并登记到统一 operation registry，避免 shutdown snapshot 之后又出现未等待写入。
- Chat/Code/Cowork shutdown 也必须取消并等待各自的 composer voice operation，停止 recorder、释放
  进程级 microphone lease 并删除临时音频；窗口切换或 Command-W 仍不能隐式 shutdown 由 manager
  持有的 session runtime。
- 冷启动和 crash/force-quit 后重开不复用进程内 runtime，只从 durable state 构建新 runtime并 reconcile。恢复出的 running/stopping 显示 interrupted；active Goal 变 paused/budget-limited。继续执行必须由用户显式 Send、Retry 或 Resume 发起。

### 多模态链路

```text
MultimodalService.generateImage/transcribe/generateVideo(轮询 job)
  -> provider 调用 -> ArtifactStore 写入
  -> log: artifact_added / artifact_progress
```

上述 artifact-producing `MultimodalService.transcribe` 与 composer 语音草稿路径是两个边界：composer
voice 不创建 artifact，也不在用户 Send 前写 EventLog；其 exact route、临时文件与生命周期合同见
“Composer 语音输入链路”。

## 数据模型

| 类型 | 职责 | 持久化方式 | 关键字段约束 |
|---|---|---|---|
| `Envelope` | 事件信封 | JSONL 一行一个 | `seq` 单调递增且不可复用；`v:1`；`type` 只追加演进，未知未来事件可跳过但仍占用序号 |
| `EventLog` / `EventLogWriterLease` | session append-only 单写协调 | JSONL + `.lock` / `.writer.lock` / `.wal` / `.wal.tmp` sidecar | append/batch 在跨进程 exclusive flock 内重读尾 seq；多事件 batch 先同步并 rename WAL、同步父目录，再写/sync JSONL 与父目录，恢复按 exact prefix/suffix 判定 untouched/partial/full；所有 replay 在读取前先处理 WAL，兼容 replay 失败返回空，`replayChecked` / `isEmptyChecked` 对锁/读/known corruption/session mismatch fail closed；`replayForProjectionChecked` 另返回 durable tail/unknown-type metadata，只有 `hasCompleteKnownHistory` 才能支撑从 seq 0 起的 absence/order proof；production Cowork runtime 全生命周期持有 writer lease，第二个 runtime fail closed |
| `Event` | 事件 payload 联合 | 随 Envelope | 追加演进；兼容 replay 可跳过不可解码行，安全敏感调用必须用 checked API；合法未知未来 type 可跳过 payload 但仍占用 `seq`、算作非空，错误 session 不得进入当前日志 |
| `ModelHistoryItemPayload` / `ModelHistoryCompactedPayload` / `AgentModelHistoryProjector` | 稳定 Code conversation（`taskID == nil` + SubmissionID）与 Cowork `@main` root submission 的模型输入事实链；独立于 UI 气泡、任务结果和审计预览 | `model_history_item` append-only 事件 + `model_history_compacted` 完整 v1 replacement checkpoint；每次 provider dispatch 前从最新有效 checkpoint + suffix 严格重建 prompt snapshot；UI projections 对两种事件 no-op | 保存 user / final assistant / assistant function-call batch / function output 的有序结构，以及 summary/window lineage/typed replacement。用户项在首次 dispatch 前写入，call batch 在任何工具执行前原子写入，output 与 `tool_result` / settlement 同 batch；checkpoint durable commit 后才 live swap。failed/interrupted `turn_outcome` 只使同 TurnID 的 final assistant message 失效，真实 user、reasoning、call/output 与 tool-search 历史继续保留；completed 或无 outcome 的 legacy turn 保持原行为，冲突 outcome fail closed。缺 output 的 call 只在请求副本中补 `aborted`，orphan output 丢弃，EventLog 不被合成项改写；重复冲突 ID、错误 provenance、坏 lineage、未知 schema/future event 或 seq gap 均 fail closed。task-scoped worker 不读取主 thread history；legacy session 只桥接可证明的 completed root U/A 文本 |
| `SessionSettingsUpdatedPayload` / `SessionStorageMigratedPayload` | versioned session settings 全快照、显式 rename 与幂等迁移完成事实 | `session_settings_updated` / `session_storage_migrated` append-only 事件 | revision/previousRevision、session/kind/schema 必须严格连续且 overflow-safe；rename source/operation ID 为 additive optional metadata，operation first-write-wins、冲突 fail closed；Cowork settings 不授予 lease，append return/stream 使用落盘反解 canonical Envelope；legacy name/settings 与 canonical alias 必须 settings-first，migration ID 非空稳定且只有 verified migration 才能落 marker |
| `SessionProjectionDocument` / `SessionProjectionStore` | 可删除、可重建的 session 快速投影 | `<session>/session.json` schema v2，owner-only atomic replace + stable no-follow lock | `events.jsonl` 永远获胜；`projectedThroughSeq` 只表示已验证水位。refresh 用 full canonical fold 校验 incremental result，同水位/落后 cache corruption 不能覆盖 EventLog；unknown future event 时拒绝覆盖 |
| `SessionWorkspaceAccessDocument` / `SessionWorkspaceAccessStore` | session-owned Apple security-scoped bookmark 能力材料 | `<session>/workspace-access.plist` schema v1 binary plist，`0600` + no-follow lock + atomic replace | bookmark bytes 不进入 EventLog/session.json/UserDefaults/UI；session/path/schema/单一 primary 必须验证；shared capability 仅在 settings+roster 零引用时删除，primary 默认拒删并只允许显式事务回滚；alias 只在 scope 后 canonicalize；marker 后不得从 global legacy map 回填 |
| `UserMessagePayload` | 用户输入事件 | 随 `user_message` | `text` 是清洗后送入模型的文本；optional additive `attachments` 只保存 session `ArtifactStore` 的 ArtifactID，供 macOS Chat/Cowork 重放，绝不保存文件 bytes/base64/bookmark/path；`tags` / `goal` 是 v0.12 追加的可选元数据；`to` 可记录 Cowork 目标 agent；Cowork Phase A 的可选 `submissionID` 把同一 accepted intent 的消息、状态、root task 与重试关联；可选 `mainAgentInferenceBinding` 只冻结该 Cowork submission 在 Send 边界为 `@main` 选择的 secret-free exact binding，Chat、legacy Cowork 与 ordinary-worker direct message 为 `nil`；旧 JSONL 缺字段必须继续解码 |
| `SubmittedIntentStore` / `SubmissionStatusChangedPayload` | Cowork 用户一次 Send 的本地 durable admission 与可重试执行状态 | `<session>/submitted-intent-outbox.json` schema v1（owner-only atomic file）先保存冻结 payload，再用 EventLog transaction 写唯一 `user_message + submission_status_changed(queued, attempt 1)`；后续状态 append-only | `SubmissionID` 稳定且 first-write-wins；attempt 从 1 开始，只能单调 queued→running→terminal，禁止 orphan、跳号、回退或重写 terminal；EventLog acceptance 成功后才清 outbox，canonical replay 已存在时幂等对账；retry 复用同一 submission 和 exact root task，不重复 user message |
| `ArtifactStore` / `ArtifactRef` | session 内附件和生成物的 blob 与索引 | `<session>/artifacts/blobs/<id>.<safe-ext>` + owner-only `index.json`；stable owner-only flock 内 read/merge/atomic replace | root/blobs 必须是当前 UID 的真实目录且 leaf 不跟随 symlink；blob/index/lock 为单链接 `0600`，旧 `0644` 只在固定可信路径显式收紧，`0664`/symlink/hardlink fail closed；扩展名只允许短 ASCII 字母数字并固定在 exact ID path；rename 后无法证明 durable 时返回 `commitUncertain`，不得宣称 clean rollback |
| `TurnStatsPayload` / `TurnStatsProjection` | 每轮模型响应统计与 GUI 最近一轮投影 | 随 `turn_stats` 事件追加到 JSONL；GUI 只读投影 | token 字段来自 endpoint usage，可能为空；`cachedPromptTokens` / `contextWindowTokens` 是追加可选字段，旧 JSONL 缺字段必须继续解码；同一次 provider 响应的多个 usage chunk 按字段合并，Agent 工具循环的多个模型请求按请求累计；TTFT/total wall time 由 ChatLoop/AgentLoop 记录；GUI 显示不得依赖 transcript 文本解析 |
| `TurnID` / `TurnOutcomePayload` / `ExecutionFailureSource` | Chat/Code/Cowork 一次模型 turn 的 stable identity、terminal 与机器可读失败来源 | 新 turn 追加一个语义唯一的 `turn_outcome`；tool result、permission request/resolution 可选携带同一 turn/tool-call/request correlation | completed / interrupted / failed 分离；user denied/cancelled、turn cancelled、policy/reviewer/sandbox/runtime failure 不解析错误文本。人工 Decline 只终结当前 call，Cancel 才中断 turn且不得伪造 denied tool result；旧日志缺新字段继续解码 |
| `ErrorPayload` / `RuntimeErrorPresentation` / `RuntimeRecoveryAdvice` | provider、agent 与工具运行错误的用户可读投影 | 随 `error` 事件追加到 JSONL；恢复建议由 `ConversationProjection` / `CodeProjection` 从错误/失败工具结果派生，不另写事件 | 错误码由 shared runtime 映射生成；message 必须是裁剪后的可展示文本，不得包含完整 API 响应或 secret；恢复建议只说明 retry/config/endpoint/permission/tool-input 方向，不得包含 secret 或原始响应；若 partial assistant/agent delta 后发生错误，投影层只标记当前未完成消息为 response stopped 并保留 partial text，不新增事件 type |
| `ProviderHealthReport` | 当前 provider/model 的连接测试结果 | 不写入 EventLog；由设置页临时显示 | status、role、endpoint/model/wire、elapsed、first token、usage、code/message、裁剪 response preview；不得包含 secret 或完整响应体 |
| `ProviderRuntimePolicy` / `HTTPDataResponse` | provider 请求的 timeout / retry / backoff / rate-limit header 策略 | 不持久化；由 provider adapter 初始化默认值；HTTP headers 只用于当前请求诊断 | Chat streaming 默认 120 秒，Code/Cowork tool-calling Agent streaming 默认 180 秒，non-streaming image/transcription 默认 180 秒；均为最多 2 attempts。tool-calling streaming 在尚未接受任何非错误 payload 时可 retry，因此 error-only retryable SSE frame 不算 partial output；接受任何有效 payload 后不得 retry。non-streaming 对 retryable HTTP/网络/timeout 失败重试；`Retry-After` / rate-limit reset headers 可用数字秒、HTTP 日期或 `750ms` / `1m30s` 等 duration 字符串影响 retry delay 并进入错误说明；取消不 retry |
| `InferenceConnectionDefinition` / `InferenceProfileDefinition` / `InferenceCatalog` | Cowork per-agent 推理 route/profile 的 versioned immutable catalog | app/CLI App Support 下 `inference-catalog-v1.json`；保留所有历史 revision，current refs 只供未来 binding | connection 固定 wire/endpoint/credential reference/trust/defaults，URL 必须无 user-info/query/fragment；profile 固定 exact connection/model/variant/effective options/declared capabilities/safe label；语义变化必须追加 revision，不得原地改写；secret/auth/header/query/URL-like options 拒绝；store corruption/schema/owner-only permission 失败关闭；当前只有 OpenAI-compatible wire |
| `AgentInferenceBinding` / `ResolvedInferenceProfile` | agent、invocation 与 permission target 的 exact 安全绑定；一次 provider resolve 的原子结果 | binding 作为 `Agent`/`TaskContract`/agent lifecycle/turn stats/authorization 的 additive optional 字段；旧事件缺字段解码为 unresolved | 必须逐项核对 exact profile/connection revision、model/variant、安全 route label/trust domain/egress classification 与 opaque definition digest；不得 fallback current；安全投影不含 raw endpoint、credential、headers/query/options；secret 只在真实请求边界懒加载 |
| `Goal` / `GoalAuditSummary` | 用户拥有、可跨多轮和重启的 durable objective；保存 success criteria、constraints、状态、revision、可选显式 budget 与最新独立审计 | `goal_created/edited/paused/resumed/audit_completed/continuation_scheduled/progressed/blocked/budget_limited/usage_limited/completed/cleared` append-only 事件，由 `CoworkProjection` 折叠当前 Goal | 生产 mutation 收口到 Orchestrator host authority；默认无 token budget；Pause/Edit/Clear 先安全取消并 checkpoint，失败则不提交 mutation；Edit invalidates 旧 audit/blocker/progress streak；completed audit 必须无 remaining work/blocker、每项 proven+evidence，并精确覆盖 objective/criteria/constraints；每个 checkpointed run 最多一次 audit，且 audit/run completed/可选 Goal terminal 同 batch；单轮 `blocked_candidate` 不能直接 blocked |
| `WorkTask` / `WorkTaskGraph` / `TaskEvidence` | 用户可见计划 DAG 节点；显式 acceptance criteria、expected artifacts、owner、result/evidence、revision 与 invocation linkage | `work_task_created/updated/owner_changed/dependency_changed/ready/started/progressed/blocked/completed/failed/cancelled/invocation_linked/evidence_added/carried_forward` append-only 事件 | stable `wt_` ID；`task_…` 是 AgentInvocation namespace，若 lookup 确认不存在则工具返回 typed no-effect 引导，但真实可查的 legacy 非标准 WorkTask ID 仍兼容。update 必须使用最新 authoritative revision，terminal task 不做冗余 settle；task_create/update 的 permission preview 只含 bounded、脱敏的语义字段，完整参数只以 digest/count 参与 revalidation。依赖只能在同一 ContinuationRun，拒 self/missing/cycle/stale revision；`in_progress` 后执行契约不可改；completed 必须有非空 result，存在 acceptance criteria 时还需 agent-reported evidence，但这些字段不能直接证明 Goal。新 run 由 host 原子取消并克隆旧非终态任务、重映射依赖；AgentInvocation 结果仅为 candidate |
| `ContinuationRun` / `ContinuationRunCloseRequestedPayload` | 宿主推进普通 turn 或 durable Goal 的有界轮次/checkpoint/recovery 边界，以及模型/宿主关闭当前 run admission 的持久 claim | `continuation_run_created/started/checkpointed/close_requested/completed/cancelled/recovered` append-only 事件；close claim 由 `EventLog.claimContinuationRunClose` 在 complete-known history + 跨进程锁内 first-write | stable `run_` ID、session/可选 Goal、ordinal/status；close payload 的全部 identity/source 由 host 绑定，模型只能给 completed/stopped + reason；exact duplicate 幂等，冲突 durable history fail closed，首 claim 永久围栏该 RunID。host 只 drain exact run，不能在 AgentLoop 内递归续跑；恢复先兑现 close fence，再处理 mailbox/调度；普通 successful final 本身不伪造显式 claim |
| `TaskFailureCode` / `TaskFailedPayload.failureCode` | 需要跨重启保真的结构化 invocation 失败分类；当前含 provider account hard usage limit | `task_failed` payload 的可选追加字段；旧 JSONL 缺字段解码为 nil | 只由 typed `ProviderUsageLimitError` 写 `provider_usage_limit`；restore 还要核对 TaskContract Goal/run scope、current non-completed Goal（包括 paused）与 run 未审计；不得从 `error` 文本、普通 429 或 `length/max_tokens` 猜测 |
| `AgentMessagePayload` / `InformationRequestedPayload` / `InformationRepliedPayload` / consumed/discarded payloads | typed mailbox message 的 pending、一次请求/回复 correlation、成功呈现消费与取消丢弃生命周期 | send/request/reply 事件建立 pending；information request 使用 fresh RequestID，可选 `basedOn` 指向上一 reply，并以 stable `conversationID` 串联多轮；`agent_message_consumed` 或 `agent_message_discarded` 终结对应 message ID | 一个 request 只接受一个 terminal reply；reply receipt 不 ACK，实质追问创建 fresh request，不会因 `information_replied` 全局禁止后续通信。consumed 只能表示已投影且成功完成的 agent 轮次，并与 task completion 同批落盘；discarded 只表示其 Goal/run 已取消、消息未成功呈现。两者都必须 durable-first 才可 runtime ack；旧 run discarded message 不得在 restore 后复活；legacy 缺 correlation 字段继续解码为 nil |
| `ToolCapability` / `CapabilityLease` / `WorkspaceLease` | Cowork agent 可用工具与工作区能力边界 | grant/revoke 事件 + 当前内存索引；历史 grant 保留供 retry/replay | coordinator 可用本地 Git control、remote Git control、文档/媒体读写、生图与网络/浏览器能力；`renameSession`、`submitGoalVerdict`、`controlRun` 只进入 exact `@main` default lease，不能沿 coordinator/worker/task/spawn 派生，且 run tools 还要求 exact root invocation；worker 默认无 `gitControl` / `gitRemote`、只读 PDF 且无 `browse_web`。task-scoped lease 绑定 task ID、终态撤销；WorkspaceLease 还执行 root/access/allow/deny path 并持久化 canonical root device/inode identity，跨权限等待/prepare/retry/process 边界复核；最终工具执行仍必须过 `PermissionEngine` |
| `ResolvedToolAuthorization` / `PermissionActionPreview` / `PermissionApprovalResolution` | 从同一 registry registration 解析的 concrete tool、canonical permission、membership、lease/target/args identity、审查语义与 typed outcome | authorization 作为可选追加字段复制到 permission review/resolved 与 tool execution events；preview 只保存有界脱敏字段；旧 JSONL 缺字段继续解码 | live automatic review 必须有完整 snapshot，审查后与 executor 前复核同一 authorization；旧事件只用于兼容 replay，不能在 live 路径重新解释 alias 或扩大 membership。`write_file` / `apply_patch` 均为 `filesystem.edit`；automatic-review 只见 digest/count + preview，不能读取 raw args |
| `ToolCallPayload` argument audit | 记录模型提议的工具名与可安全持久化的参数显示；count/redacted 提供最小审计，只有已验证且未脱敏/未截断的 canonical args 才可带 digest | `argsDigest` / `argsCharacterCount` / `argsRedacted` 为 additive optional fields；旧 JSONL 只有 `args` 仍可解码 | 新 writer 必须在 `.tool_call` append 前完成分类：unknown/invalid 与全部 `spawn_agent` inference-control calls 只落 bounded redacted placeholder，不写 raw-value digest；其他 schema-valid args 也 secret-scrub/限长。endpoint/header/api_key 及其可离线猜测 hash 不得通过失败或未知调用先进入 EventLog |
| `PermissionReviewTask` / `PermissionReviewRequestedPayload` / `PermissionReviewSettledPayload` | reviewer 控制面工作单与 verdict | `permission_review_requested/settled` append-only 事件 | 结构化包含当前 task/attempt/tool/gate/lease/context、authorization、参数 digest/count 与 bounded redacted preview；reviewer 使用有界 FIFO/single-flight、submit-based deadline、单次 timeout/cancel 与可选 soft usage warning，模型参数/输出上限默认不注入；只返回 allow/deny + non-empty reason，risk 不得下调，异常为 typed failure；allow 必须 settled-first，恢复关闭 orphan request；旧 `permission_review` 保留兼容审计 |
| `PermissionRequestPayload` / `PermissionResolvedPayload` / `PermissionApprovalResolution` | 人工或自动 approval 的 durable request identity、显式动作与首终态 | AgentLoop 先 batch 写 `permission_request + blocked`；`registerPermissionRequest` 为 reconnect/transport 提供 RequestID first-write CAS；`settlePermissionRequest` 写唯一 `permission_resolved` | approval mode 为 manual/automaticReviewer；action 为 approve/decline/cancelTurn。完整已知历史与跨进程锁内 first terminal 获胜；exact duplicate 幂等返回原 Envelope，冲突 request、tool、turn、tool-call、authorization、action/decision 或 terminal fail closed。Projection 按登记顺序 FIFO，解决任意项不改变其余相对顺序 |
| `ToolExecutionPreparedPayload` / `ToolExecutionSettledPayload` | 副作用执行票据、completion evidence 与 crash reconciliation | `tool_execution_prepared/settled` append-only 事件；settled 可选 `effectDisposition` | prepare 必须在 executor 前并携带/复核与 review 相同 authorization；每个 execution ID 只允许一个 prepare，duplicate prepare/conflicting terminal 永久 ambiguous 并保留首记录。仅普通 read-only 默认 safe-to-replay；write/exec/network/destructive 和 collaboration/lifecycle 工具默认 requires-manual-reconciliation。新 success 显式 `.committed`；legacy nil+succeeded 只兼容为已完成并仍阻断 whole-task retry，legacy failure nil/显式 unknown/无效 settlement 保持 uncertain；只有 exact、无 ambiguity 的 typed `.notStarted` 证明副作用未开始，`succeeded + notStarted` 无效。SideEffectEvidenceLedger 从 permission/review/resolved/prepared/settled 恢复证据，只有匹配的 succeeded settlement 才能清除完成阻断 |
| `TaskContract` / `TaskReportPayload`（AgentInvocation execution layer） | 单次 root/child agent invocation 契约与结构化回报；不是用户可见 WorkTask | `task_created/assigned/queued/started/completed/failed/cancelled` 既有事件；queue/start/terminal 记录 attempt | 契约记录 kind、issuer/assignee/objective/roleHint/deliverable/lease、reply mode、timeout、maxAttempts，并以可选字段绑定 submission、WorkTask/ContinuationRun/Goal、exact inference binding 与 mailbox MessageIDs；`mailboxMessageIDs == nil` 仅表示 legacy/non-mailbox，new mailbox admission 必须冻结非空、去重、最多 8 项。Phase A root task 冻结 `submissionID`，main-hosted root admission 先要求 live `@main` 与 immutable submission 的 `mainAgentInferenceBinding` 全等，再把同一值冻结进 TaskContract；delegated/mailbox child 继承 submission scope。普通用户消息与每个 Goal run 均创建 root invocation。执行前 frozen binding 必须与 live roster 一致；完成只产生 candidate result；新 admission 使用当时 policy 并冻结 timeout，历史已落盘的 300 秒合同不得静默改写；追加字段保持旧 JSONL 可解码 |
| `AgentScheduler` / `CoworkExecutionPolicy` / `AgentExecutionBudget` | claim、并发、恢复、取消/超时、attempt 与 token 预算 | scheduler 从 task/message events 重建；token 用量从 `turn_stats` 重算 | 默认同 agent single-flight、跨 agent 最多 4 个任务并行、新 admission 每次 invocation 600 秒、最多 3 attempts；CapabilityLease 的默认 delegation `maxDepth=1` 保持不变。仅 eligible non-root/CLI read-only crash recovery 增加 attempt；GUI restored root submission 保持 paused/interrupted 直至 exact Retry；session-lifetime 共享 token meter 在 provider dispatch 前预留 input estimate + output slice，响应/失败/超时按 reported 或估算 usage settle，配置切换不丢 outstanding reservation；预算明确是 soft；取消不自动 retry |
| `ContextBundle.taskGroupEvents` | Cowork worker prompt 的共享任务状态摘要 | `ContextProjector` 从 task events 投影，随本轮模型请求临时进入 prompt，不单独持久化 | 只包含当前/父/兄弟/子/related task 的任务 ID、状态、agent 和关系；不得泄漏其他任务的 objective、expected deliverable、tool args、结果文本或私有路径 |
| `SessionSummary` / `SessionHistoryStore` | 最近会话摘要、显示名称与路径生成 | 扫描 app support root 下 `<session>/events.jsonl`，读取 EventLog-derived `<session>/session.json` | Chat/Code/Cowork 按 `sess_` / `code_` / `cowork_` 前缀区分；手工/model-tool Rename 都 EventLog-first，显示名称不改变 `SessionID`，model 无目标 session 参数；旧 metadata 只作兼容迁移输入；macOS/iOS 共用实现，平台层只传 root 与 `SessionID` |
| `CoworkSessionSettings` / `CoworkProjectInfo` | Cowork project-mode canonical metadata 与右侧 inspector 投影 | `session_settings_updated` in EventLog；`session.json` 为派生缓存；旧 `intatis.cowork.projectSettings.<sessionID>` 只作迁移输入 | 保存主 agent 名称、未来新 agent exact inference default、默认 permission profile、可选 token budget 与 secret-free workspace metadata；bookmark bytes 独立进入 `workspace-access.plist`；不得重写现有 agent或授予 lease；fresh bootstrap 固定七事件，历史 main/reviewer 走 host-authorized exact recovery；direct multi-root tool context 尚未实现 |
| `Agent` | agent 值类型 | lifecycle 事件 durable，运行时 roster 内存重建 | ordinary agent 的 `agentInferenceBinding` 是推理权威；兼容 `model` 不能覆盖 binding。`coordinationDepth` 是当前 coordinator 工具兼容 fuse；默认 permission profile `.reviewed`；自动权限审查者固定 `read_only` + `coordinationDepth=0` |
| `Capability` | provider 能力枚举 | 配置 | chat/tool_calling/vision/realtime/audio/image/video/embedding |
| `PlatformProfile` | 平台能力信封 | launch-time | 当前产品使用 `.iOS`（最受限）/`.macDeveloperID`；`.macAppStore` 仅保留 legacy source/decode compatibility；`current` 默认 `.iOS` |
| `PermissionProfile` | 每 agent 模式 | agent | manual/reviewed/autopilot/read_only/locked；硬 DENY 优先 |
| GUI provider catalog | GUI provider/model/variant 设置与 iOS 显式文件导入 | UserDefaults `intatis.providerCatalog.v1` + secret ref；当前聊天选择 `intatis.providerSelection.v1`；macOS 可由 `INTATIS_CONFIG` 显式指定文件、`~/.config/intatis/intatis.json` / `intatis.jsonc`、app support `intatis.json` / `intatis.jsonc` JSON/JSONC 覆盖；iOS 通过系统 Files picker 显式导入后写 app-owned `Intatis/imported-chat-configuration.json` schema-v1 protected snapshot；不自动发现 `opencode.json` 或 OpenCode app 配置；旧 `config.json` / direct `providers` 兜底兼容读取 | provider 持久化 `baseURL` / `chatEndpoint` / secret ref；model 持久化 id / 展示名；macOS variant 只持久化 identity，参数仍来自配置文件；iOS 导入保留 base model raw options/adapter/capabilities，但当前不导入 variants并明确警告；聊天页切换只改当前选择，不改写外部 JSON；明文 API key 不得进 UserDefaults 或 imported snapshot；旧 `intatis.baseURL`/`intatis.model` 仅迁移/兼容 |

## 同步 / 通信机制

- **进程内**：当前 GUI/CLI kernel 仍在单进程内运行；
  `Orchestrator`/`EventLog`/`MessageBus` 均为 `actor`。这是当前事实，不是仅限 v0.1 的规划。
- **JSON-RPC 2.0 词汇**已定义（`JSONRPC.swift`：Command→request、Envelope→event notification），但**尚未挂传输**。未来 `intatis agent --stdio` / `intatis daemon` 是规划中管道。`UNKNOWN` — 当前无 out-of-process 传输实现。
- **Provider 线协议**：OpenAI 兼容 HTTP/SSE（chat completion endpoint streaming）。`WireFormat.openai` 是唯一 shipped 格式；`ProviderEndpoint.chatEndpoint` 可覆盖默认 `baseURL + /chat/completions`，保留 `baseURL` 给 image/transcription 等后续路径。
- **Provider tool-call delta 兼容**：`OpenAIToolCalling` 仍输出既有 `ToolCall(id:name:arguments:)`，但解码更宽容：单工具调用可缺省 `index`，`index` 可是字符串，`function.arguments` 可是字符串或 JSON object/array/number/bool，非字符串值会被压缩编码回 JSON 字符串再交给既有工具参数解析。Chat/tool-calling streaming 会遍历同一 SSE chunk 的全部 choices，不再只消费 `choices.first`；如果首个 choice 为空但后续 choice 带 content、tool_calls 或 `finish_reason`，仍会输出对应 delta/tool calls 并完成流；如果多个 choice 同时给出 finish reason，`tool_calls` / `function_call` 优先于普通 `stop`，避免工具轮被错误标成文本完成。若 provider 以 `finish_reason:"tool_calls"` 或旧式 `finish_reason:"function_call"` 结束但没有发出完整 tool-call delta / tool name，或已出现 tool-call delta 但最终错误给出 `stop` 且仍缺 tool name，则抛出 provider tool-call stream 兼容错误，不把空工具调用合成为成功。非空累计 `function.arguments` 在发出 `ToolCall` 前必须能解码为 JSONValue，截断或非法 JSON 会作为 provider tool-call stream 兼容错误暴露；空 arguments 仍保留，以兼容无参工具。此行为不改变 EventLog schema，不绕过权限门。
- **Provider/runtime 错误反馈**：`ProviderErrorFormatting` 统一处理 OpenAI-compatible HTTP 非 2xx、streaming provider error payload、malformed SSE chunk、`URLError`/取消/transport error，并只保留裁剪后的 provider message 或 response preview；HTTP 非 2xx 响应体只有结构化 `error`/`message`/`detail`/`error_description` 才显示为 `Provider said`，HTML/纯文本代理错误页只显示 `Preview`。`ProviderEndpoint` 在 chat streaming、tool-calling streaming、image generation、transcription 发起网络前统一校验 Chat endpoint 或 Base URL 必须是带 host 的 `http`/`https` URL，非 HTTP、缺 scheme 或缺 host 归类为 `IntatisError.config`，不把 file URL 或底层 URLSession 失败泄漏到 UI。非流式 image/transcription 对 HTTP 2xx 响应也会校验成功 payload shape；如果 provider 返回错误 JSON、HTML、缺 `data[].b64_json`、坏 base64、缺 `text` 或其他不兼容结构，会抛出裁剪后的 `IntatisError.decoding`，提示检查 endpoint、provider path、model 与 response format；只有结构化 `error`/`message`/`detail`/`error_description` 才显示为 `Provider said`，普通 HTML/缺字段 JSON/坏 base64 只显示 `Preview`。`RuntimeErrorPresentation` 把 `IntatisError`/`URLError` 映射成 `ErrorPayload.code + message`，供 ChatLoop/AgentLoop 写入 append-only `error` 事件。`ConversationProjection` 与 `CodeProjection` 从该 payload 派生 `RuntimeRecoveryAdvice`，SharedUI 在 Chat / Code / Cowork 错误卡片中复用同一恢复建议视图。若错误发生在当前 assistant/agent partial delta 之后，投影层会把该未完成气泡标记为 stopped 并附加 partial-response 恢复建议，已输出文本继续保留；状态码提示覆盖 400/401/403/404/408/422/429/5xx 等常见接入问题，但真实 provider 格式仍需矩阵验证。
- **Provider runtime retry/timeout/rate-limit headers**：`ProviderRuntimePolicy` 由 OpenAI-compatible chat streaming、tool-calling streaming、image generation、transcription 共享，但按交互类型分流 timeout：Chat streaming 为 120 秒，Code/Cowork Agent streaming 与 non-streaming image/transcription 为 180 秒，均最多 2 attempts。URLRequest 会设置 request timeout；408/409/425/429/5xx 与短暂网络/timeout 错误可 retry。tool-calling streaming 在尚未接受任何非错误 provider payload 时可 retry；只含结构化 retryable error 的 SSE frame 不算模型 partial output。一旦接受文本、tool call、usage、completion 或其他有效 payload，失败会按错误反馈路径暴露且不得自动重放，避免重复输出或重复工具调用。Chat/tool-calling streaming 接受 `[DONE]` 或 chunk `finish_reason` 作为完成信号；`finish_reason` 不会立刻截断底层流，后续 usage chunk 仍会被读取，done 只投递一次；若底层流结束时没有任何完成信号，则抛出 completion-marker 兼容错误而不是合成成功。非流式 image/transcription 由 `ProviderRuntime.sendData` 统一重试并给 timeout 生成可行动错误。`HTTPDataResponse` 与 `URLSessionStreamingClient` 会保留 HTTP response headers；`ProviderErrorFormatting` 解析 `Retry-After`、`x-ratelimit-reset`、`x-ratelimit-reset-requests`、`x-ratelimit-reset-tokens`、`ratelimit-reset`，支持数字秒、HTTP 日期和 `750ms` / `1m30s` 等 duration 字符串，用于 retry delay 与用户可读说明，长等待由 policy cap。
- **Provider health check**：`ProviderRegistry.healthCheck(role:options:)` 复用当前 provider catalog、chat selection、secret resolver 与 `OpenAIWireProvider`，发起最小 chat/agent 流式请求，输出 `ProviderHealthReport`。chat 与 agent health check 均请求 `stream_options.include_usage`，并使用共享 `Usage` 合并规则处理 split usage chunk。报告显式区分 ok、timeout、partial stream、unknown endpoint、非法 provider URL、provider/transport/config 错误，并带 endpoint/model/wire/耗时/首 token/usage 与裁剪预览；兼容缺 `[DONE]` 但有 `finish_reason` 的 provider，只有完成信号缺失才标记 partial stream，并保留已收到的裁剪预览；macOS 与 iOS 设置页共用该 provider 层 API，只做不同布局，不写入 EventLog 或持久状态。
- **Goal 输入命令**：`GoalInputParser` 在 UI/ViewModel 层识别行首 `/goal`，要求后面有目标文本。Chat / Code 保留 v0.12 legacy 语义：剥离命令前缀，把清洗文本送入 provider，并在 `UserMessagePayload.tags = ["Goal"]` / `goal` 保存标签元数据供 bubble 投影。Cowork 的同一语法已升级为 durable Goal authority：创建 `Goal` 与首个 `ContinuationRun` 后由 host 驱动 scoped root AgentInvocation，不把它当成普通标签消息；仍在 mention 路由前后解析以接受 `/goal @Agent ...` 与 `@Agent /goal ...` 作为请求上下文，但 Goal continuation 始终由 `@main` 主持，因此 Goal Send 也冻结当时的 next-main exact binding，不能把生命周期、模型选择或终态 authority 下放给 mentioned agent。
- **工具执行反馈**：AgentLoop 对未知工具、权限拒绝、工具抛错分别写入结构化 `tool_result` observation，并在执行前追加 `agent_status(tool)`。模型给出的 raw arguments 在 `.tool_call` 持久化前先分类；unknown/invalid、作为 inference-control surface 的全部 `spawn_agent` inputs、含用户自定义标题的 `rename_session` inputs，以及永不允许落原文的 `write_stdin` inputs 只记录 bounded redacted placeholder + count/redacted，且不写 raw-value digest；`rename_session` 还在 authorization/prepare 前按结构化 `name` 做 secret scan。schema-valid 其他工具先 secret-scrub/限长，只有未脱敏/未截断的 canonical 参数才可附加 digest。稳定 `@main` 另把一次 assistant 返回的完整 function-call batch 作为一个 model-facing item 在任何工具执行前原子持久化；其参数只有在 registration/schema/secret/size 检查全部通过时才原样保留，否则写固定合法 JSON placeholder。每个已清洗、有界的 function output 与对应 audit result/execution settlement 同 batch，因而不存在“工具已经结算、模型历史还没写”的可取消窗口；只有完整 direct output 存在时才去除 ContextBundle 里的同一 audit result。UI/audit `tool_call` / `tool_result` 仍是独立记录，不能反向冒充模型历史。同一 turn 内空或重复 call ID 会改写为唯一 turn-local ID，并在后续关联位置一致使用。随后，已知工具在权限判断和执行前会校验参数必须是 JSON object，并满足 descriptor schema 的 required 字段、基础类型、数字 `minimum`/`maximum` 约束、字符串 `minLength`/`maxLength` 约束与 `additionalProperties:false` 未知字段规则，`read_file.maxBytes` 当前要求 `>= 1`，标准工具 path/query/command/diff 字符串当前要求非空，required 为空的无参工具可把空参数 / `null` 归一为 `{}`，坏 JSON、非对象、缺 required 字段、基础类型错误、数值越界、字符串过短/过长或未知字段会写入 `invalid tool input:` 的 `tool_result`，不生成 `permission_request`，也不执行工具。当前 shipped tools schema 默认声明 `additionalProperties:false`，因此模型给出的额外字段不能被 `try?` 默认值吞掉后进入权限或工具执行。`CodeProjection` 根据 `tool_call_id` 将结果标题回填为 `result · <toolName>`，把 `tool error:` / `permission denied:` / `unknown tool:` / `invalid tool input:` 标成失败项，并通过 `RuntimeRecoveryAdvice` 派生恢复建议。GUI 与 CLI 均消费事件投影/observation，不解析 assistant transcript。
- **Agent 文档/媒体工具**：`ToolRegistry.standard()` 暴露 PDF 阅读、PDF 页面编辑、文档照片/扫描件版面重建、LaTeX 编译和生图写入工作区。PDFKit 路径在 macOS 可直接工作；Linux 或无 PDFKit 平台会返回配置错误并提示使用外部 CLI 后端。shell-backed 文档重建和 LaTeX 编译不内置模型或 TeX 发行版，只调用已安装的成熟工具；缺少命令时返回可行动的配置错误。生图工具不直接知道 provider secret，只通过注入的 `ImageGenerationToolService` 使用现有 provider registry。
- **Chat 托管网络搜索**：macOS/iOS/CLI Chat 不展示搜索按钮、菜单项、开关、状态或 provider/model 路由提示。每次 Send 只冻结用户当前选择的 exact Chat provider/model/variant/request adapter；`ProviderRegistry.chatRuntimeRoute()` 先验证普通 Chat adapter，再同时要求 exact model 的 `hosted_web_search` 声明与受审 adapter dialect。满足时向当前模型提供对应能力并保持 `tool_choice: auto`，由当前模型自行决定是否搜索；明确不支持、未声明、无法确认或尚未适配时，在同一 route 上静默发送普通 Chat，不提示、不切换模型，也不调用通用 Intatis search tool、`web_fetch`、`browser_search`、本地浏览器、MCP 或第三方搜索后端。OpenAI Responses `web_search` 与 OpenRouter `openrouter:web_search` 分别编码；unknown/compatible/legacy/custom 接入点默认不声明搜索。该能力不进入 PermissionEngine/AgentLoop，也不扩大 iOS linkage。只有当前模型实际返回结构化 URL annotation 时才保存 optional additive citations，并在持久化与 SwiftUI `Link` 前执行既有双重校验。provider-specific structured unsupported 在首个有效 payload 前可触发一次同路由普通 Chat 重发；裸 404、自由文本和 partial payload 不可触发。精确合同见 `docs/CHAT_HOSTED_SEARCH.md`。
- **Agent 网络/浏览器工具**：`ToolRegistry.standard()` 暴露轻量 `web_fetch` 和 Playwright/CDP-backed `browser_*` 工具。浏览器工具依赖用户环境里已安装的 Node.js，并优先使用 Playwright + Chromium/Chrome/Edge channel；若 Playwright 不可解析，则通过 Node.js 内置 `WebSocket` 使用 Chrome DevTools Protocol 启动已安装 Chrome/Edge/Chromium。缺少后端时返回配置错误或 `browser_diagnostics` 的可行动诊断。profile/state/history/downloads 全部通过 `PathConfinement` 限定在 workspace `.intatis/browser/` 下，刷新、历史前进/后退、表单点击/输入/提交/下拉选择/按键/滚动/等待交互通过 locator 或当前焦点执行；click/download 的 CDP 路径使用真实鼠标事件，打开新页面的交互会跟随到新 tab/window 并把最终页面写回 state/history；截图只能写入工作区 PNG 路径，上传只能引用 workspace 内文件，显式下载只能写入 `.intatis/browser/downloads/<profile>`；`browser_profiles` 可报告 active browser / profile lock runtime marker 是否存在，但不得列内部 marker 文件名或读取内容；`browser_profile_delete` 只在目标 profile 与 `confirmProfile` 匹配时删除 `.intatis/browser/profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json` 并剪除对应 history metadata，删除前如果发现 marker 只给概括性提示；profile 可能包含 cookies 与登录态，不能当成普通日志、artifact 或 secret-free 文本处理。
- **macOS UI information architecture**：`IntatisMacRootView` 是 macOS Chat/Code/Cowork 的 shell。左侧继续由 `NavigationSplitView` 提供系统 sidebar 材质，内部使用一个连贯的自定义结构：`Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航、当前 mode 的 `Recent` session history/New 与底部 Settings；仅选中模式行使用 interactive Liquid Glass。Cowork New session 仍先要求用户选择主 workspace 并初始化 per-session project settings。主 thread header 显示 session durable display name（无 display name 时回退 immutable `SessionID`），不写死 Chat/Code/Cowork，也不承载 New/session/model 控件；Code/Cowork 使用紧凑 12pt 顶部留白，Cowork 不再在标题之前常驻 permission-reviewer 横幅。共享 `IntatisThreadComposer` 固定两排：第一排 model/profile 在左、最近一轮 Context/Input/Cached/Output/Time usage 在右；Chat/Code/Cowork 的选择器共用原生 `Menu` 语义与 40pt 高 interactive Liquid Glass 胶囊，关闭态只显示模型名，不显示 CPU/芯片图标、provider 或 variant/reasoning detail；弹出菜单内部仍按 provider 分组并保留 variant detail。第二排为 action、原生多行 `TextField`、可选 Cowork stop 与 Send；macOS Chat 与 Cowork 的 action 是同一个 shared paperclip/file-import/drop/draft-menu surface，Chat 不再显示独立提示词生图 action；Code 保留其既有 image action，iOS paperclip 仍是 Chat tools menu 而不是通用本地附件。action/stop/Send 使用同一个 40×40 原生圆形控件合同，输入容器单行最小高度同为 40，同行 spacing 为 8，外层保持 bottom alignment，因此多行输入只向上增长。没有 top accessories 时不创建空白第一排。消息本体不使用 agent 头像或通用 Agent badge，缺失的 agent 展示名回退 `Intatis`；正常完成的 assistant/agent 回复无外层卡片，通用 Agent message、`information_requested`、`information_replied` 与其他 agent-to-agent 记录沿用同一普通回答版式并以 exact `sender->recipient` 标识，用户消息、失败回复与 tool/error/permission/task 等结构化项保留容器；既有字体 token 不随本次视觉架构更新。Thread content 使用共享 responsive layout 计算 horizontal padding、显式 `contentWidth`、message gutter 与 bubble max width；对话行通过 `IntatisThreadBubbleRow` 在整行层面按 user trailing、assistant/agent leading 对齐。Chat 默认无右 inspector；Code/Cowork 的显隐都只由同一个稳定外层 `GeometryReader` 提供的未压缩 outer available width 与用户请求状态决定，不使用已经压缩后的 thread width 反推自身可见性。Code 继续用有界 `HStack` 展示 structured plan/workspace/Git-status-only/recent failure。Cowork 则把 rail 作为 detail 同一 canvas 上的 trailing overlay：不使用 divider 或整栏 `.bar` 背景，主 thread 复用一个固定 `ScrollView` 根并延伸至 detail 最右端，visible rail 固定 348pt、section 固定 318pt，正文通过 trailing scroll-content margin 给 cards 留位，使原生滚动条位于整个内容区最右端。rail subtree 由只含 rail input 的 Equatable boundary 隔离；每个 passive section 独立使用系统 `Glass.clear` 的稳定 backdrop，不用 `GlassEffectContainer` 组织这些必须保持固定位置的 status cards。第一位显示 compact pending permission 或最近权限结果，其后为 `Agents`、真实 `Goal`、真实 `Tasks`，不显示 Git。compact permission 只展示状态、tool、安全摘要与必要 action，不渲染 raw args 或默认详情；pending 且 outer width 足以容纳 rail 时临时固定为可见，窄到无法安全容纳时只在 composer 上方保留同一请求的完整 Material 权限卡兜底，二者不得重复。无 pending 时用户仍可隐藏 Cowork rail；任何窄屏或隐藏状态都不在 thread 顶部复制 Goal/Tasks，也不保留对应高度。Code/Cowork 的 bottom-anchor 恢复使用系统 `onScrollVisibilityChange`，不建立 GeometryReader/PreferenceKey 坐标回写；session controls 位于内容 header，不向 window toolbar 动态增删 item，也不嵌套 SwiftUI `.inspector` preference。Cowork header 不提供独立 MCP Content 快捷按钮，内容浏览位于 `Project Settings → MCP → Browse Content`；header 只用系统 compact 圆形 glass/bordered icon control 切换 status rail。Goal/Tasks 继续来自 durable projections；Cowork 的 Git UI 已移除，但本地 Git controls 仍只通过 Agent Git tools + PermissionEngine 执行。
- **UI 配色与跨平台设计语言**：macOS detail 由 `IntatisSystemCanvas` 使用 SwiftUI `.windowBackground`（macOS 13 fallback 为 `NSVisualEffectView.Material.windowBackground`）提供动态系统 window surface，`NavigationSplitView` sidebar 不再被自定义底色覆盖。`IntatisThreadStyle.intatisMac` / `.standard` 注入系统 `.primary` / `.secondary`、separator、accent 与错误语义；正常完成的 assistant/agent 正文直接继承系统 canvas，不叠 Material 或描边；用户消息、失败回复、数据卡片、权限和 artifact 等结构化内容层默认使用 `.regularMaterial`。composer、模型菜单、主要操作及确实需要融合的紧凑 action group 在 macOS 26 / iOS 26 使用 `glassEffect`、`GlassEffectContainer` 与 `.glass` / `.glassProminent`，旧系统走 Material / bordered control fallback；用户明确指定的 Cowork 紧凑 trailing status rail 是唯一内容层玻璃例外，权限、Agents、Goal、Tasks 各自使用独立原生 `Glass.clear` backdrop，不绘制固定灰框或自制玻璃，也不由一个会重组 shape 的 container 包住。macOS 与 iOS Chat composer 现在都采用共享两排结构：首排为关闭态只显示模型名的 interactive glass `Menu` 与可用 usage，第二排为当前产品面已有 action、输入、紧邻主操作左侧的 voice 和唯一 Send/Stop；iOS 仍只提供 paperclip Chat 功能菜单，不能伪造通用附件。iOS 将该排 `GlassEffectContainer` 的 merge spacing 固定为 0，保留 8pt 布局间距但禁止输入胶囊、voice 与 Send/Stop 物理融合；四个 icon action 都从 composer 专用 modifier 获得同一 40×40 外框，iOS 使用 `.small` 原生 control size，避免 `.regular` glass chrome 超出 40pt 并抬高中心线，macOS 继续使用本来就与 40pt 合拍的 `.regular`。主排继续 bottom alignment，保证多行输入只向上增长。macOS sidebar `Recent` 旁 `+` 使用 30×30 原生小型圆形 glass control；iOS 左抽屉使用同一品牌/模式/history/Settings 层级，并支持从 24pt 屏幕左缘、具有水平优势的右滑打开，避免抢占 transcript/TextField 的纵向或编辑手势。`IntatisTypography` 是两平台字体角色的单一实现：品牌、session 与页面级标题使用相同名义字号/字重的系统 serif，Chat 正文、输入和控件使用系统 sans，技术值使用系统 monospaced；iOS 只在这些共享名义值之上应用 Dynamic Type 缩放。Markdown/代码/公式继续保持 renderer 的语义字体。Glass 不铺页面或长内容。iOS 根视图与约 82% 抽屉继续使用系统容器背景，不复制参考应用固定渐变或另建平台私有底色。当前规范见 `docs/CURRENT_UI_COLOR_SYSTEM.md`；上一版方案独立保存在 `docs/UI_COLOR_SYSTEM.md`。
- **GUI token/turn stats**：ChatLoop 与 AgentLoop 每轮结束追加 `turn_stats`，包含 endpoint 返回的 prompt/completion/total token（若有）、可选 cached prompt tokens、可选 context window tokens、TTFT、总耗时和 model。OpenAI-compatible `prompt_tokens_details.cached_tokens` 会进入 `Usage.cachedPromptTokens`；未缓存 input 可由 prompt-cached 在 UI 层展示。ChatLoop、AgentLoop 与 ProviderHealthCheck 共用 `Usage` 规则：同一次响应内的 usage chunk 字段级合并，Agent 工具循环中多个模型请求再按请求累计。GUI 不解析消息文本计算 token，而是通过共享 `TurnStatsProjection` 折叠最近一轮统计；macOS Chat / Code / Cowork 与 iOS Chat 均复用 `IntatisComposerUsageStrip` 在 composer 第一排右侧显示低噪音 usage，第一排左侧保留 model/profile。endpoint 不返回 cached/context usage 时，只显示可证明字段，不虚构数值。
- **Chat/Code/Cowork session/history**：macOS `IntatisMacRootView` 通过 root-owned view models 和 `SessionHistoryStore.recentSessions(kind:)` 将当前 mode 的最近 sessions 投影到同一 sidebar navigation/session center；Chat 启动时优先恢复最近 Chat session，无历史时才使用 `sess_default`，Code/Cowork 在首次进入时创建对应 session。iOS `IOSAppEnvironment` 仍只恢复 Chat session，无历史时才使用 `sess_ios`。新建会话生成新的 `SessionID.new()`，打开独立 `EventLog` 与 artifact store，停止旧 view model 并重建当前 view model。恢复历史会话只切换到对应 `events.jsonl`，不会把新消息继续追加到旧的固定默认日志。macOS session row 的原生右键菜单支持 Rename/Delete；Code 与 Cowork `@main` 另可通过 `rename_session` 改当前会话，model 不提供 SessionID/kind。两条 Rename 路径都先追加 EventLog settings rename 事件并刷新派生 `<session>/session.json`，再通过 exact-session、revision/seq 有序的低频 publisher 更新所有窗口；不改目录名、`SessionID` 或既有 envelope。Delete 在二次确认后删除目标 session 目录及其 session-owned bookmark/settings/projection，不触碰绑定工作区内容，当前运行中的 session 禁止删除。路径与元数据规则在 `IntatisCore` 复用，平台层只传不同 application-support root。
- **Chat 自动命名**：该能力是 Chat 宿主 metadata 流，不是 Tool，也不进入 `ChatLoop`、`AgentLoop`、
  PermissionEngine、Code 或 Cowork。`ChatLoop.send` 只有在 assistant completion 与
  `turn_outcome(completed)` 均已 durable append 后返回该 terminal 的 seq；`ChatViewModel` 随后把
  本轮冻结的 exact `ResolvedChatRuntimeRoute` 与 completed seq 一起交给进程级
  `ChatSessionAutoTitleCoordinator` 做轻量 admission，并立即清除主 Chat busy/Stop。协调器后台用
  complete-known checked replay，但只投影 `seq <= completedThroughSeq` 的冻结 EventLog 前缀；因此
  后续轮次即使先于后台 prepare 落盘，也不会进入旧 route 的标题上下文。冻结前缀从 session 起点
  投影最早三个
  可证明串行的 completed Chat segment；任何 orphan、交错、legacy 未终结或 agent/task 归因都
  fail closed。标题 request 只含 Intatis 自有严格 System 指令，以及 user/assistant 正文字段合计最多
  6,000 个 Swift `Character` 的 untrusted JSON 对话数据（JSON 结构和转义另有编码开销），使用同一
  provider/model、`tools: []` 语义、无 web search/citation/附件、
  不写消息 EventLog 或 turn stats。每进程、每 SessionID 最多三个逻辑 generation，single-flight；
  preparation 与 pre-dispatch cancellation 不计次，只有同步创建 `provider.stream` 时才消费 attempt，
  `ChatProvider.stream` 的公共合同要求立即返回 request-owned stream 并把 consumer termination 传播给
  producer；阻塞式同步 provider 不属于该协议合同，任意 transport 的物理远端取消仍不作保证。
  每次 15 秒；前两次可精确返回 `NO_TITLE` 等待下一成功回合，第三次必须返回标题。stream 必须恰好
  一个 done 后正常 EOF，输出只做首尾 trim 与确定性 accept/reject，不做二次 AI/智能改写；通过
  1–48 Character、格式、敏感内容、URL/path/长编号/长标识验收后，
  `SessionProjectionStore.setAutomaticDisplayNameIfAbsent` 才在 EventLog 跨进程锁内为 Chat 追加一个
  source=nil 的 rename settings revision，并 rebuild/read-back `session.json` 后发布 exact commit。
  手工 Rename 在事务前或事务后都优先；自动 rename 不提升 recent activity。macOS 复用进程级
  exact-session revision/seq publisher 与 runtime delete/Quit drain；iOS 使用稳定 per-session watermark
  relay，因此 session A 的迟到 commit 只更新 A，不污染当前 B。所有标题失败静默，不改变主回合、
  `errorText`、Stop、输入能力或 UI 错误状态；iOS 被系统强杀不承诺异步 drain。
- **GUI provider catalog**：macOS `AppConfig` 与 iOS `IOSConfig` 使用 UserDefaults 主键 `intatis.providerCatalog.v1` 保存两层 mutable 配置。第一层 provider 存 `id` / 展示名 / `baseURL` / `chatEndpoint` / secret ref 元数据；第二层 model 存模型 id / 展示名。macOS Chat/Code 模型菜单把配置中的 variants 作为同一 model 的独立选择项；切换后只把 provider/model/variant identity 写入 `intatis.providerSelection.v1` 并重建 `ProviderRegistry`，Chat/Code 下一条请求使用新选择的基础 options + variant 覆盖。Cowork composer 复用同一份配置所编译的 secret-free `AppInferenceProfileOption` 列表，以 provider 分组显示“下一次 `@main`”的 exact 暂存项；三个产品面的弹出菜单均保留 provider 分组与 variant detail，但关闭态 label 只读取选中项的 model title。新 options 先交给 Orchestrator 更新 host-approved catalog，再发布到菜单，避免可见项与 admission catalog 竞态。工作中仍可选择，选择本身不 rebind，只有随后按下 Send 才把当时值冻结进该 submission；FIFO 执行边界把仅 `@main` 的 durable rebind 与对应 root queue admission 原子提交。既有 worker、当前/已冻结 task、控制面 agent 与未来新 agent 默认值均不跟随。Project Settings 的独立 exact-profile picker 仍只更新**未来新 agent 默认值**，逐 agent Rebind 继续用于显式修改其他空闲 ordinary agent。iOS 保持 provider/model 两层 Chat 选择。设置页编辑 Base URL 时自动生成 Chat endpoint；编辑 Chat endpoint 时清洗 `/chat/completions` 后缀回填 Base URL。旧 `intatis.baseURL` / `intatis.model` 仍作为迁移来源与兼容镜像。
- **iOS imported Chat config**：iOS 不扫描 `INTATIS_CONFIG`、macOS home 或 app-support 候选路径；用户只能从 Chat 左抽屉底部 Settings 进入设置页，再经系统 Files picker 显式选择 JSON/JSONC。共享 `ChatConfigurationImporter` 解析 OpenCode-compatible `provider` map 与 legacy direct `providers`，执行 1 MiB/数量/字符串/HTTP(S) URL 边界检查，并只投影 iOS Chat 所需 provider/model/endpoint/options/adapter/capabilities。成功后不保留 security-scoped 外部 URL，也不监视或重写原文件，而是在 app Application Support 的 `Intatis/imported-chat-configuration.json` 写 schema-v1、complete-file-protection app-owned snapshot。直接 `options.apiKey` 先迁入同样受保护的 `Intatis/auth.json`，snapshot 与 UserDefaults 只保留 secret reference；环境变量/文件引用保持引用但导入结果会提示在 iOS 重新验证或录入。variants 当前被忽略并明确告警；未知 adapter 保留 exact identity并让既有 adapter gate 在网络前 fail closed，绝不静默改成 compatible。iOS root 持有 thread-only Chat 的唯一 `NavigationStack`，顶部 sidebar/session/new、左抽屉、底部两排 composer 和 Settings sheet 属于同一导航层级；model label 在 composer 第一排有界，不能把第二排 controls 推出屏幕。该路径不会扩大 iOS 的 7-product Chat-only linkage。
- **Chat 搜索路由配置**：搜索运行时只有用户当前选择的 exact Chat route，不存在隐藏第二模型。`web_search_model` / `webSearchModel` 的后台路由语义已取消；兼容 decoder 可以接受并保留旧字段，但 runtime 忽略它，新生成配置不再主动写入，也不因字段存在显示警告或阻止普通 Chat。`responsesEndpoint`、URL、provider/model 名称同样不能证明兼容；能力来自受审声明和 exact adapter。设置表单、模型菜单和对话均不显示搜索状态或降级提示，durable stats/诊断关联当前实际执行的安全 provider/model identity。
- **Cowork inference catalog 同步**：macOS `AppInferenceCatalog` 将当前 provider/model/variant 配置编译为 connection/profile drafts，并由 `InferenceCatalogStore` reconcile immutable revisions；connection/trust identity 与 durable variant ID 均使用不暴露 raw URL/config key 的 opaque hash，egress 标为 `user-configured-external`。配置刷新只改变 host-approved candidates/current refs；已有 agent 继续引用原 revision，且 catalog update 与 admission/rebind 通过同一 admission lock 串行化。Refresh 失败时，初始启动 fail closed，已有有效 snapshot 的进程保留上一份有效 snapshot并显示 resolution 错误。CLI 的 `CLIConfig` / `CLIModernProviderConfig` 读取所有启用的 OpenAI-compatible route、model、variant，`CLIInferenceProfiles` 将其全部编译为 immutable profiles；每个 connection revision 保留自己的 exact env/file/auth/config credential reference，`CLIExactSecretResolver` 不会用 selected route 的 credential 替代其他 route 或旧 revision。Modern CLI 的 unqualified model 仅在全 catalog 唯一匹配时切到其 route；显式 reasoning 只能命中 configured variant/base effort，否则 config fail closed。Non-empty recovery 缺失 `@main` 时要求显式 `/agent restore-main`。GUI 将 exact resolution/reviewer health 作为执行状态而非 composer/本地 Send gate；CLI 仍以它们控制显式 data-plane resume。普通 worker unresolved 仍显示在 roster，但不全局暂停 scheduler：其 queued invocation 在 provider dispatch 前 durable fail closed，清除 busy fence 后才可显式 rebind，其他 agents 可继续运行。两端的 list/roster 只投影 safe label/identity/trust classification/resolution，不投影 endpoint、credential 或 options。
- **macOS advanced config**：macOS GUI 启动时先检查用户显式设置的 `INTATIS_CONFIG` 文件；未设置时按顺序只检查 Intatis-owned 路径：`~/.config/intatis/intatis.json` / `intatis.jsonc`、app support 的 `intatis.json` / `intatis.jsonc`，最后才兜底读取旧 Intatis `config.json` / `config.jsonc`。不会自动发现任何名为 `opencode.json` 的文件，也不读取 `~/.config/opencode/` 下的 OpenCode app 配置；OpenCode-compatible 只表示 JSON shape 兼容。找到可解码的 JSON/JSONC 后覆盖 UserDefaults provider catalog；聊天页当前选择覆盖层仍可覆盖 JSON 顶层 `model`。设置页的 Open Intatis Config 按钮会打开当前生效的 Intatis-owned 文件或 `INTATIS_CONFIG` 显式指定文件；若只发现旧 `config.json`，会从当前 catalog 生成新的 `~/.config/intatis/intatis.json` 模板并优先打开。保存设置时，用户本次主动输入的 API key 会写入同一个可编辑 provider JSON 的 `provider.<id>.options.apiKey`；写入用户 config 失败时回退到 app support `intatis.json`。创建的模板来自当前 provider catalog，只输出 OpenCode-compatible `$schema` / `enabled_providers` / `model` / `provider.<id>.npm` / `name` / `options.baseURL` / `options.apiKey` / `models`，`options.apiKey` 默认是 `{env:...}` 引用而非明文。支持兼容读取旧 direct `providers` 数组，也兼容读取 Intatis 扩展字段 `chatEndpoint` / `apiKeySource`；推荐新配置使用 `provider.<id>.options.baseURL`、`options.apiKey`（OpenCode-style 明文、`{env:NAME}` 或 `{file:path}` 均可由真实请求懒加载）、`models`，以及顶层 `model` 形如 `<provider>/<model-id>`。支持 OpenCode-compatible 的 `enabled_providers` / `disabled_providers` 过滤；`disabled_providers` 优先。省略 `options.apiKey` 时 provider 请求按 provider id 尝试 Intatis auth JSON 与当前 Intatis-owned OpenCode-compatible config，不再回落 OS Keychain。
- **Image model route**：macOS 与 modern CLI 兼容读取顶层 `image_model`，并兼容旧式 camelCase
  alias `imageModel`；新模板和保存路径只写 canonical `image_model`。其值为
  `<provider>/<model-id>`，只绑定宿主 `ResolvedModels.imageGen`，不会修改当前 Chat/Code/Cowork
  inference selection。显式引用的专用 image provider 可以使用空 `models` map：连接与 credential
  仍可解析，但不会生成 inference profile 或进入模型菜单。图片 model ID 也不要求重复登记在
  provider 的推理 `models` 中。`generate_image` / `edit_image` 执行时由宿主读取这一 exact
  route；字段缺失时 fail closed，模型不能通过工具参数覆盖它。当前 generation wire 调用
  OpenAI-compatible `POST <baseURL>/images/generations` 并请求 `response_format=b64_json`；edit
  wire 调用 multipart `POST <baseURL>/images/edits` 并发送单个 `image[]`。两者只接受
  `data[].b64_json`，不跟随输出 URL；mask 与多参考图尚未进入 tool schema。
- **provider config reference confinement**：从 provider JSON 产生的直接 `options.apiKey` secret ref 会绑定当前配置文件；历史 UserDefaults 中的 `providerConfig` 路径只有匹配 Intatis 自有候选或当前显式 `INTATIS_CONFIG` 时才可读取，其他路径由 resolver fail closed。
- **Cowork automatic permission review**：brand-new GUI/CLI Cowork session 以一个本地 durable 七事件 bootstrap 同时记录 settings、fixed `@main` 与 `@permission-reviewer`；初始化不产生模型审批或 provider 请求。恢复的非空 session 先恢复 durable settings/roster；若缺失 `@main`，GUI 从 canonical settings 走 host-authorized exact historical-main recovery，随后才 replacement/retry reviewer，CLI 使用专用 `/agent restore-main`。审查者固定 read_only、无工具 lease、无通信/委派、`coordinationDepth=0`，不会启动嵌套 `AgentLoop`；`AgentPermissionResponder` 把宿主解析的 `ResolvedToolAuthorization`、参数 digest/count、有界秘密脱敏 action preview 与紧凑 causal/lease metadata 放入 untrusted block 后交给独立 FIFO/single-flight 控制面。审查者只返回 `{"decision":"allow|deny","reason":"non-empty bounded reason"}`，且 risk 不得低于 gate；pre-submit caller cancel 返回 typed deny且不创建 review lifecycle；不可解析输出、空 reason、tool call、timeout、provider error、settled persistence failure 与已登记 review 在 terminal-claim 前被观察到的 cancel durable deny 当前调用；claim 后 cancel 保留唯一 settlement 但 authorization delivery deny。Phase B 将 producer lifecycle 收窄到 request generation：factory 逐代 exact-resolve，provider/timeout race 与 provider-backed terminal claim 校验 exact generation，pre-dispatch terminal 从 running/no-generation 状态唯一 claim；retired producer 不持有 EventLog/actor/authorization，下一 request 不继承 process-lifetime quarantine。`ToolCallingProvider.stream` 必须立即返回 request-owned stream，并传播 consumer termination，shipped OpenAI/URLSession 路径符合；同步永久阻塞的任意第三方实现不在该契约内。GUI 不做隐式人工 fallback；Phase A 后 reviewer 未就绪不锁定 composer，普通请求继续，只有 ask-class tool fail closed；对话页不常驻 reviewer 横幅，异常恢复入口位于 Project Settings 的 Recovery 区。CLI `/auto` 重新启用，只有用户明确 `/default` 才移除审查者并恢复终端人工确认。

示例（不含明文 secret）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "enabled_providers": ["OpenRouter", "Images"],
  "model": "OpenRouter/deepseek/deepseek-chat",
  "image_model": "Images/gpt-image-1",
  "provider": {
    "OpenRouter": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OpenRouter",
      "options": {
        "baseURL": "https://openrouter.ai/api/v1",
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "deepseek/deepseek-chat": { "name": "DeepSeek Chat" }
      }
    },
    "Images": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Images",
      "options": {
        "baseURL": "https://images.example.com/v1",
        "apiKey": "{env:IMAGE_API_KEY}"
      },
      "models": {}
    }
  }
}
```

## 安全机制

### 凭据存储
- GUI 不再读写 OS Keychain。`KeychainRef` 是历史命名的 secret ref；其中 `.keychain` 仅作旧配置兼容值，app resolver 会把它映射到配置/auth 文件查找，不调用 Security Keychain API。
- `ConfigSecretResolver` 可指向 `environment` / `file` / `authFile`。macOS `authFile` 默认先查 `~/.config/intatis/auth.json`，再兼容查 `~/.local/share/intatis/auth.json` 与 Intatis-owned OpenCode-compatible config 的 `provider.<id>.options.apiKey`；不默认读取 `~/.local/share/opencode/auth.json` 或 `~/.config/opencode/opencode.json`。也可用 `INTATIS_AUTH_FILE` 覆盖。iOS 默认落在 app container Application Support 的 `Intatis/auth.json`。UserDefaults catalog 只存 secret ref 元数据，不存 API key；macOS 设置页输入的 API key 写入当前可编辑 provider JSON，iOS 设置页输入的 API key 写入 auth JSON 并尝试设置 `0600`；真实 provider 请求懒加载 secret，并按 source/service/account 做进程内缓存。

### 工作区边界
- `PathConfinement.resolve`：拒 `..` 遍历与越界绝对路径。Tools 执行与权限门均使用。

### 权限 3 层门
1. `DeterministicPolicyGate`（纯函数、模型无关、runs first、`deny` 终局）：输入包含结构化 `PermissionIntent(action/resources/metadata/dataEffects/controlEffects/risks/replayPolicy)`。locked、敏感路径、路径越界、shell disabled、read-only lease 下真实 mutate/exec/network/destructive，以及 read-only parent 试图授予 child read-write workspace 都 hard deny；普通只读数据操作 allow；exact `rename_session` + `session.rename` + sole `tool:current_session` + no path/network/data/control effects 的调用作为 low-risk local metadata mutation allow，任何 near-miss 回到普通保守规则；其余需要审查的写入、网络、exec、destructive 和 agent/task/message/workspace 控制面操作返回 `pass`。WorkspaceLease 是权限 ceiling，不是“本次调用已经写文件”的判据。
2. reviewer（模型评审）只见 gate `pass`，只能收窄，**不能**覆盖硬 deny。非 Cowork host 可注入 `ModelPermissionReviewer`；production Cowork 不注入该 reviewer，而把同一次 `pass -> askUser` 请求交给 durable `PermissionReviewControlPlane`。同一调用不得同时配置两条模型审查路径。
3. `PermissionEngine`（组合）：`pass` 且无 in-engine reviewer → `askUser`，由当前 responder 处理。Cowork 自动模式 responder 只有 allow/deny、无人工 fallback；人工模式只能由用户显式切换。

自动权限审查不改变上述终局规则。因为 hard deny 不会产生 `permission_request`，`@permission-reviewer` 无法覆盖硬 deny。结构化 intent 与 authorization 以向后兼容的 optional 字段追加到 permission request/resolved、review task 与 tool execution prepare/settle 事件；旧 JSONL 缺字段时继续解码，但 live automatic-review 路径缺少完整 `ResolvedToolAuthorization` 必须 fail closed，不能借 legacy adapter 重新解释 alias。审查记录写入 `permission_review_requested/settled` 与兼容 `permission_review`，同一 `authorizationID` 必须贯穿最终 `permission_resolved`、prepared 与 settled，executor 仍以 durable settlement 和复核后的不可变 snapshot 为准。

Phase C 把 approval response 与 turn terminal 拆成两个层次。人工 `approve` 允许当前 call 进入 prepare/executor；`decline` 写当前 call 的 typed denied result并把 observation 回灌同一模型 turn；`cancelTurn` 只写 permission terminal，随后抛出 turn interruption，不制造 tool result。自动 reviewer 仍只产生 allow/deny，不出现 GUI 人工按钮。control plane 对同一 RequestID 的 exact duplicate/reconnect 共享 owner generation 与首 terminal，冲突 duplicate 关闭；owner cancellation 在 authorization delivery 前对所有共享 waiter fail closed。runtime stop/cancel 先 drain request-owned provider/tool child，再提交 task/turn terminal并恢复 caller，避免 terminal 早于清理。只有 wrapper 在目标启动前产生的可信 sandbox startup denial 才归类 `sandboxDenied/notStarted`；普通退出错误不重试、不升级权限。

### 秘密拦截
- `SecretScanner`：敏感路径/basename/扩展名、秘密内容标记（`-----BEGIN`、`PRIVATE KEY`、`AKIA`、`sk-`、`ssh-rsa`、`xoxb-`、`ghp_`、`AIza`…）、受保护配置路径。
- `Mediator`：agent 间转发时拦截秘密 + 超长原始转储（>4000 字符要求发摘要）。

### Sandbox / Entitlements
- `IntatisMac.DeveloperID.entitlements`：默认 `IntatisMac` 使用；非 sandbox、Hardened Runtime，本地 Code/Cowork 的 shell/git/browser 能力仍必须经过 `PlatformProfile.macDeveloperID` 与权限门。composer voice 只增加最小 `com.apple.security.device.audio-input=true`，真实录音仍需 `NSMicrophoneUsageDescription` 与用户 TCC 授权；该 entitlement 不代表启用 App Sandbox。
- managed terminal 在 macOS 额外套 Seatbelt：只允许 WorkspaceLease 映射出的文件访问，默认拒绝网络；只允许同一 sandbox 中的 fork/exec、process info 与 signal，不开放全局 `process*`，也不开放所有 `/dev/ttys*`。PTY 仅使用已继承的 controlling terminal descriptor。Linux 要求 bwrap，缺失时 fail closed；Linux PTY 当前不支持。
- `IntatisMac.AppStore.entitlements`：当前源码中的未使用 legacy artifact，不是
  未来版本规划或 release input；除非用户明确要求清理，不自动删除，也不为它
  新增功能或验证。

## 模式开关 / 内核切换

无 Rokurics 式新旧内核开关。Cowork 架构原则与当前必须保持的回归点见 `docs/COWORK_PRINCIPLES.md`；较早 `COWORK_*` 状态文档可能落后于当前源码。

## 与文档/源码的关系

- 仓内根 `ARCHITECTURE.md`（draft-0, 2026-06-11，中文）描述 Intatis 内核/Cowork 设计。本目录 `docs/ARCHITECTURE.md` 据实际源码重写并与之对照。
- Cowork 设计细节见 `docs/COWORK_AGENT_ARCHITECTURE.md` 等 7 个 COWORK_* 文档；原则提炼见 `docs/COWORK_PRINCIPLES.md`。
- 开源源码、公开 prompt、依赖、bundled runtime 与上游升级的准入规则见 `docs/OPEN_SOURCE_REUSE.md`；实际已经采用的上游必须登记在 `NOTICE.md`。截至 2026-07-12，OpenCode 仍为 research-only，尚未把其源码、公开 prompt、UI 资产或 runtime 加入 Intatis。
