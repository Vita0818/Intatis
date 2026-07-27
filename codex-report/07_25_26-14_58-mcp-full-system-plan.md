# Intatis 外部 MCP Server 客户端完整系统规划、实现与证据

> **唯一权威入口**
>
> 本文件同时承担四个职责：冻结完整产品范围、说明当前真实实现、把 W0–W10
> 映射到源码与测试、逐项管理 31 个终态验收门。它不是“先做最小实验”的
> 草案，也不是第二份状态摘要。
>
> **最终整体验证状态：`IMPLEMENTED`；25/31 个确定性验收门 `PASS`，
> 6/31 个外部环境门 `I-ENV`；0 `UNKNOWN`；0 `IMPLEMENTATION_GAP`**
>
> 当前源码审计和最终重跑确认完整客户端范围已经实现。全量 SwiftPM、双 macOS
> target、iOS、CLI、official/extended conformance、W10 focused suites 和
> 双架构 Linux 静态构建均以最终源码结算为通过；签名发行、真实第三方
> server/OAuth 和匹配架构 Linux runtime 等未具备的外部证据继续明确保留为
> `I-ENV`，不冒充已完成。

## 1. 文档合同与状态词

### 1.1 权威顺序

出现冲突时按以下顺序判断当前事实：

1. 当前源码、`Package.swift`、`project.yml` 和 vendored manifest。
2. 当前测试、conformance manifest、构建脚本和实际命令结果。
3. `docs/CURRENT_STATE.md`、`PROJECT_MAP.md`、`ARCHITECTURE.md`、
   `DO_NOT_BREAK.md`、`OPEN_SOURCE_REUSE.md`、`TESTING.md`。
4. 本文件的说明性文字。

本文件必须跟随前 3 项更新，不能把已经实现的系统继续描述成未来计划，也不能
把没有运行的外部环境矩阵写成通过。

### 1.2 状态词

| 状态 | 含义 |
|---|---|
| `IMPLEMENTED` | 当前源码中存在生产实现和接线；不等于所有外部环境已经验收 |
| `EVIDENCE_PRESENT` | 当前仓库中存在针对该合同的测试、fixture、静态检查或 conformance driver |
| `PASS` | 当前源码、确定性测试、构建或 conformance 已对该验收门完成最终结算 |
| `I-ENV` | 实现和确定性证据存在，但真实平台、签名、账号、第三方 server 或发行环境不可用 |
| `UNKNOWN` | 当前源码和证据不足以做肯定结论；必须保留，不得猜测 |
| `IMPLEMENTATION_GAP` | 已确认源码缺少冻结范围中的能力，或最终验证发现真实代码失败 |

`ENVIRONMENT_LIMITED` 不是删减范围的理由，`IMPLEMENTATION_GAP` 也不能改写成
“以后再做”。最终验证发现的任何源码失败必须回到相应 W 波次修复并重跑。

## 2. MODEL_CHECK_RESULT

- 当前执行环境：Codex（GPT-5 系列）。
- 精确部署版本：运行环境未提供，无法确认。
- Codex 产品事实：使用 2026-07-27 由官方 OpenAI Docs connector 取得的
  Codex config reference 复核；该文档确认本地 Codex 客户端直接连接外部
  MCP Server，支持 stdio 与 Streamable HTTP、bearer/OAuth、server
  instructions、required server、tool allow/deny、启动/工具超时和
  `auto/prompt/writes/approve` 四种审批模式。
- 源码级 parity：继续使用本文固定的公开 Codex commit 与 patch commit；
  不使用私有源码、私有 prompt、ChatGPT 私有认证或内部插件控制面。

## 3. PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 路径匹配预期：是。
- 工作树在本目标开始前已有大量未提交改动；本目标保留这些改动，不执行清理、
  回退、暂存、提交或 push。

## 4. FILES_WRITTEN

本目标从规划、实现、故障修复到最终证据回写累计写入以下受控范围：

- `Package.swift`、`Package.resolved`、`project.yml`。
- `Vendor/MCPClientSDK/`、`ThirdPartyNotices/`、`NOTICE.md`。
- `Packages/IntatisMCP/`、`IntatisMCPStdio/`、`IntatisCurlTransport/`。
- `IntatisProtocol`、`IntatisTools`、`IntatisAgentKernel`、
  `IntatisConversation`、`IntatisCowork` 的 additive MCP 接线。
- macOS MCP 产品面、CLI MCP 产品面及其测试。
- `Tests/MCPConformance/`、`scripts/validate-linux-cli.sh`。
- `codex-report/07_25_26-14_58-mcp-full-system-plan.md` 以及相关项目文档。

最终故障收口还修正了 lazy transport 的 negotiated-version 转发顺序、
tools-only shipping connection 不应安装空 callback surface、HTTP
Session-ID-before-body 门、EventLog permission settlement 栈溢出、
resource 结构清洗和 CLI lazy owner 等在真实全链路中暴露的问题；对应回归
测试已经加入当前源码。未修改、清理或纳入独立
`Experiments/WebRendererParity/` 工作和
`07_26_26-13_16-chatgpt-web-rendering-session-lifecycle-study.md`。

## 5. 执行结论

Intatis 当前已经具备完整的**外部 MCP Server 客户端系统**，不是只有地基。

真实主链为：

```text
全局 immutable server catalog
→ session attachment / per-Agent MCPGrant
→ exact session MCP runtime owner
→ authority-isolated connection pool
→ initialize + negotiated capability/profile
→ raw catalog snapshot
→ Agent-visible filtered view
→ 每次 provider dispatch 的 AgentRequestToolSnapshot
→ AgentLoop / PermissionEngine / durable tool ticket
→ exact prepared MCP route
→ 外部 MCP Server
```

当前实现覆盖：

- 本地 stdio 与远程 Streamable HTTP。
- OAuth、bearer/header/env secrets、多账号和 generation fencing。
- tools、resources、resource templates、prompts、completions、roots。
- 动态 listChanged refresh、subscriptions、logging、progress、cancel、reconnect。
- sampling（含 tools）、form/URL elicitation。
- 2025-11-25 experimental MCP Tasks。
- Codex-compatible `tool_search`、BM25、deferred tools、schema cache。
- per-Agent grant、authority isolation、三层权限门和 durable execution。
- macOS DeveloperID、macOS App Store remote-only、macOS/Linux CLI 的真实
  target/linkage 边界。
- macOS 管理/会话内容面、完整 CLI 管理/运行面、安全 import/export。
- additive durable state、旧日志兼容和无 MCP 用户不回归。

当前源码审计和最终全量重跑没有发现冻结 W0–W10 范围中的已确认实现缺口：
最终实现缺口计数为 0。外部环境限制仍独立列示，不能用来扩大通过范围。

## 6. 冻结范围

### 6.1 同一完整交付必须包含

- `codex-compat` 与 `standard-extended` 两个 protocol profile。
- stdio 与 Streamable HTTP；明确不支持 legacy SSE。
- 配置、Test-before-save、connect、refresh、disconnect、OAuth 和诊断。
- server attachment 与 per-Agent grant 分层。
- required/optional server startup 语义。
- 精确 binding、connection reuse、revocation 与 execution-uncertain。
- 所有标准 discovery/content/callback/notification surface。
- macOS GUI 与 `intatis` CLI。
- 安全导入 `.mcp.json`、`.claude.json`。
- 开源 provenance、NOTICE、升级 replay、双架构 Linux gate。
- W0–W10 和本文全部 31 项验收门。

实施波次只表达依赖顺序，不是可独立交付的简化版本。W9 不是可删除扩展；默认
policy 关闭 sampling 或 experimental Tasks 也不能替代完整实现。

### 6.2 硬排除

- 不实现 Intatis 或 Codex 作为 MCP Server。
- 不创建 MCP server target、server binary、server listener、server actor、
  server protocol handler 或预留 hosting seam。
- 不实现 `codex mcp-server` 对应的产品路径；它是 Codex 的另一角色，与本目标
  无关。
- 不实现 Hosted ChatGPT Apps、ChatGPT session auth、`codex_apps` reserved
  server、selected/private plugin 控制面或 OpenAI 私有 form extension。
- 不实现 legacy SSE transport。
- 不加入 Knowledge/RAG、embedding、index 或 knowledge bridge。
- Chat 继续是无工具产品面。
- iOS 继续是 Chat 子集，不获得 MCP runtime、transport、管理面或本地
  workspace Agent。

### 6.3 名称相似但不违反 client-only

- client 接收 sampling、elicitation 和 Tasks callback，是 MCP client role
  必需的 server→client request handler，不是 hosting。
- `MCPServerContributor` 只能提交有界 server-definition proposal，不能保存、
  连接、认证、启动或授权。
- `MCPStdioExactNetworkGateway.serve(_:)` 是 host-owned authenticated HTTP
  CONNECT egress tunnel，不处理 MCP JSON-RPC。
- `IntatisMCPConformanceClient` 是仅供测试 runner 启动的客户端 driver，不是
  发行 product。

## 7. Codex 对齐基线

### 7.1 公开产品语义

公开 Codex MCP 文档固定了本目标必须对齐的用户语义：

- 本地客户端直接接入外部 MCP Server。
- stdio server 使用 command/args/env/cwd；远程 server 使用 Streamable HTTP。
- bearer token 与 OAuth 登录是远程认证路径。
- enabled、required、startup/tool timeout、enabled/disabled tools。
- server default 与 per-tool 的 `auto/prompt/writes/approve`。
- GUI/CLI 能添加、查看状态和认证；CLI 能 list/add/remove/login。
- required server 初始化失败时，非交互执行失败，而不是静默降级。
- server instructions、tools 和 context 都来自外部 server。

Intatis 对齐这些行为合同，但保持自己的存储、GUI、EventLog、lease、权限和
sandbox，不复制 Codex UI、品牌、TUI trade dress 或私有控制面。

公开产品入口：

- [Codex MCP 文档](https://learn.chatgpt.com/docs/extend/mcp)
- [Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)

### 7.2 固定源码证据

| 来源 | 固定身份 | 采用方式 | 用途 |
|---|---|---|---|
| OpenAI Codex | [`61a44880a85d2fd0d8770908dea5733495e571c8`](https://github.com/openai/codex/tree/61a44880a85d2fd0d8770908dea5733495e571c8) | `reference` + 已登记的局部 `derived` | MCP config/catalog/connection、resource tools、`tool_search` wire/history/schema cache |
| Codex binding 修复 | [`65f8bf68533332628b7fc213eade2a91d18d36ee`](https://github.com/openai/codex/commit/65f8bf68533332628b7fc213eade2a91d18d36ee) | `reference` | prepared call 与 catalog/binding version 精确绑定 |
| Gemini CLI | [`3818efbbfbf8ef029ef53a6ab1093db39971ce83`](https://github.com/google-gemini/gemini-cli/tree/3818efbbfbf8ef029ef53a6ab1093db39971ce83) | `reference` | listChanged 合并刷新和尾部补刷 |
| OpenCode | [`5e2a6257b22c0141a20c281f4c2a641311afe5a5`](https://github.com/anomalyco/opencode/tree/5e2a6257b22c0141a20c281f4c2a641311afe5a5) | `reference` | resource/prompt 内容与大小策略；明文 token/全环境继承只作为反例 |
| Grok Build | [`6e386420825bd44ae648c63e7c8cba12fcec9401`](https://github.com/xai-org/grok-build/tree/6e386420825bd44ae648c63e7c8cba12fcec9401) | `reference` | 大目录 search/use UX 与压力测试思路 |
| Swift MCP SDK | `0.12.1` / [`a0ae212ebf6eab5f754c3129608bc5557637e605`](https://github.com/modelcontextprotocol/swift-sdk/tree/a0ae212ebf6eab5f754c3129608bc5557637e605) | `vendored + derived` | client protocol/wire 基础与可审计 patch |

### 7.3 Codex baseline 与 Intatis 扩展

| 类别 | 内容 |
|---|---|
| `CODEX CURRENT BASELINE` | stdio、Streamable HTTP、bearer/OAuth、tools、resources、required、filters、四审批模式、server instructions、GUI/CLI 管理语义、`tool_search` |
| `INTATIS SECURITY HARDENING` | per-Agent grant、exact authority pool、three-layer permission、durable ticket、strict output budgets、SecretScanner、managed stdio exact network、owner-only stores |
| `MCP STANDARD EXTENSION` | prompts、completions、roots、subscriptions、sampling、provider-neutral URL elicitation、完整通知/刷新 |
| `MCP 2025-11-25 EXPERIMENTAL` | remote-server 与 client-hosted Tasks |
| `INTATIS HOST EXTENSION` | bounded `MCPServerContributor` proposal review |

不能把标准扩展冒充 Codex 已有能力，也不能把 Intatis 的安全加严说成 Codex
缺陷。对齐的是可验证合同，不是品牌或内部实现复制。

## 8. Protocol profiles

每个 server 保存独立 profile 和 max version。initialize 只能选择不超过该
上限的最高共同版本；requested、allowed、negotiated 三者均被持久化到
connection/binding 证据。

| Profile | 默认上限 | 实现覆盖 |
|---|---|---|
| `codex-compat` | `2025-06-18` | stdio、Streamable HTTP、tools、resources、OAuth、标准 form elicitation、logging/progress/cancel receive-and-log、required/optional、filters、parallel、四审批模式、`tool_search`、Codex 三个 resource tools |
| `standard-extended` | `2025-11-25` | `codex-compat` 全部，加 prompts、completions、roots、subscriptions、functional listChanged、sampling with tools、provider-neutral URL elicitation，以及显式 experimental Tasks |

约束：

- capability 协商是逐 server、逐 generation 的事实。
- 合法的 tools-only、resources-only 等部分能力 server 不因缺少无关可选能力
  被拒。
- `requiredCapabilities` 只检查已连接 server 必需能力，不能替代
  required/optional startup 语义。
- 只有 profile、wire version、capability 和 runtime policy 同时允许时才广告
  对应能力。
- legacy SSE 永远不自动回退。

实现与证据：

- [`MCPProtocolNegotiation.swift`](../Packages/IntatisMCP/Sources/MCPProtocolNegotiation.swift)
- [`SDKPatchCompatibility.swift`](../Packages/IntatisMCP/Sources/SDKPatchCompatibility.swift)
- [`Vendor/MCPClientSDK/PATCHES.md`](../Vendor/MCPClientSDK/PATCHES.md)
- [`SDKPatchCompatibilityTests.swift`](../Packages/IntatisMCP/Tests/SDKPatchCompatibilityTests.swift)
- [`MCPProtocolLifecycleTests.swift`](../Packages/IntatisMCP/Tests/MCPProtocolLifecycleTests.swift)

## 9. 平台与 target 边界

| Host | stdio | Streamable HTTP | target/linkage 事实 |
|---|---|---|---|
| macOS DeveloperID App | 支持 | 支持 | `IntatisMac` 链接 `IntatisMCP` + `IntatisMCPStdio` |
| macOS App Store App | 不支持 | 支持 | `IntatisMacAppStore` 链接 `IntatisMCP`，不链接 `IntatisMCPStdio`/guard |
| macOS `intatis` CLI | 支持 | 支持 | `IntatisCLI` 链接 core + stdio，持有 exact session owner |
| Linux `intatis` CLI | bwrap、guard 与全部策略可用时支持，否则 fail closed | 支持 | portable Crypto、Glibc/Musl、static CLI gate |
| iOS App | 不支持 | 不支持 | 不链接 MCP client runtime/transport/product UI |

iOS 仍会链接共享 `IntatisProtocol`；其中 SDK-independent MCP payload/value
类型只是跨平台 durable schema，不构成 iOS MCP API、连接能力或产品 surface。

链接证据：

- [`Package.swift`](../Package.swift)
- [`project.yml`](../project.yml)
- [`SDKClientOnlySurfaceTests.swift`](../Packages/IntatisMCP/Tests/SDKClientOnlySurfaceTests.swift)
- [`PROJECT_MAP.md`](../docs/PROJECT_MAP.md)

## 10. 模块与所有权

| 模块 | 当前职责 | 禁止反向拥有 |
|---|---|---|
| `IntatisMCP` | 配置/catalog/import、protocol negotiation、HTTP/OAuth、client session、content/callback/notification、tool binding/search、sampling/elicitation/tasks、output security、runtime/pool | App UI、Cowork scheduler、MCP server |
| `IntatisMCPStdio` | launch identity、direct exec/pipe、sandbox、exact network gateway、process ownership、TERM→KILL→drain | App Store/iOS product |
| `IntatisMCPStdioGuard` | Linux seccomp/ptrace execution/network mediation | Apple runtime policy |
| `IntatisCurlTransport` | macOS/Linux libcurl C boundary、exact resolve/socket policy | iOS、URLSession fallback |
| `IntatisMCPConformanceClient` | official/extended runner 启动的开发期 client driver；不是发行 product | 任何 server/hosting API |
| `IntatisProtocol` | SDK-independent IDs、grants、attachments、events/results/authorization payload | SDK concrete types、network/process |
| `IntatisTools` | instance registration、dynamic registry version、structured observation/result | MCP connection owner |
| `IntatisAgentKernel` | per-dispatch tool snapshot、exact prepared route、permission/durable execution integration | global catalog ownership |
| `IntatisConversation` | additive EventLog payload/projection/session state | transport |
| `IntatisCowork` | per-Agent grant projection、intersection delegation、reviewer/Goal zero MCP | global implicit sharing |
| macOS App | settings/session/agent access/content cards/OAuth/import，进程级 session owner | protocol implementation |
| CLI | complete management commands、lazy interactive owner、JSON output | App-only type dependency |

关键 owner：

- [`MCPSessionRuntimeOwner`](../Packages/IntatisMCP/Sources/MCPProductionRuntime.swift)
- [`MCPShippingSessionRuntime`](../Packages/IntatisAgentKernel/Sources/MCPEventLogHostAdapters.swift)
- [`AppSessionRuntimeManager`](../Apps/IntatisMac/Sources/SessionRuntimeManager.swift)
- [`MCPCLIInteractiveCodeHost`](../Apps/intatis-cli/Sources/MCPCLIProcessOwner.swift)

窗口、view model 或一次 AgentLoop 不是 MCP 长连接 owner。窗口切换和
Command-W 不关闭 session runtime；session delete 和 Command-Q 按 exact scope
停止 admission、取消并 drain。

## 11. 配置、catalog、import 与 durable state

### 11.1 全局 catalog

`MCPServerCatalogStore` 保存 owner-only、immutable revision 的 server definition：

- stable server ID 和 revision。
- profile/max version、required/enabled。
- stdio command/args/cwd/env refs/helper identities/exact network origins。
- HTTP canonical endpoint、proxy/trust/pin/egress policy。
- OAuth account/authority 和 opaque secret refs。
- enabled/disabled tools、server/per-tool approval mode。
- startup/tool timeout、result budget。
- source/provenance/import marker。

保存合同：

```text
parse / normalize
→ secret staging
→ launch/endpoint identity capture
→ isolated Test
→ precommit identity revalidation
→ user confirmation
→ immutable revision atomic save
```

引用中的旧 revision 只 tombstone；只有 settings、attachments 和 live roster 都
证明零引用时才能 purge。

源码：

- [`MCPConfiguration.swift`](../Packages/IntatisMCP/Sources/MCPConfiguration.swift)
- [`MCPServerCatalogStore.swift`](../Packages/IntatisMCP/Sources/MCPServerCatalogStore.swift)
- [`MCPPreparedConfiguration.swift`](../Packages/IntatisMCP/Sources/MCPPreparedConfiguration.swift)
- [`MCPPreparedDefinitionPrecommitVerifier.swift`](../Packages/IntatisMCP/Sources/MCPPreparedDefinitionPrecommitVerifier.swift)
- [`MCPCatalogOperationJournalStore.swift`](../Packages/IntatisMCP/Sources/MCPCatalogOperationJournalStore.swift)

### 11.2 显式 import/export

支持固定、版本化 parser：

- `.mcp.json`
- `.claude.json`

流程：

```text
用户选择文件
→ 只读解析与 unknown-field 报告
→ command/args/cwd/url/filter/timeout 预览
→ secret-like 字段只进入 secret staging
→ 冲突与最严格 policy 合并
→ isolated Test
→ 用户确认
→ immutable revision 原子保存
→ provenance/marker
```

禁止：

- 自动扫描、启动或删除其他应用配置。
- 自动读取其他应用凭据。
- 把 unknown field 当安全默认。
- 把 Hosted Apps/private plugin/auth 字段映射成普通 MCP 能力。
- export 明文 secret。

证据：

- [`MCPImport.swift`](../Packages/IntatisMCP/Sources/MCPImport.swift)
- [`MCPImportTests.swift`](../Packages/IntatisMCP/Tests/MCPImportTests.swift)
- [`MCPImportSurfaces.swift`](../Apps/IntatisMac/Sources/MCPImportSurfaces.swift)
- [`MCPCLIConfigurationArgumentsTests.swift`](../Apps/intatis-cli/Tests/MCPCLIConfigurationArgumentsTests.swift)

### 11.3 session durable state

当前不是“没有 MCP durable state”。Additive state 已实现：

- session attachment。
- per-Agent `MCPGrant`。
- control-plane request/terminal。
- connection/catalog/binding snapshot。
- tool authorization MCP facts。
- sanitized progress/diagnostic/content/task events。
- remote-server 与 client-hosted task state。

旧数据合同：

- 旧 JSONL 继续可解码。
- 缺失 MCP 字段默认空，不产生连接。
- `CapabilityLease.mcpGrants` 默认空。
- `session.json` 只保存 EventLog 可重建的派生摘要。
- iOS target 不因 schema 类型存在而获得运行能力。
- 冷启动只 replay/reconcile，不自动 connect、login、refresh 或 call。

协议证据：

- [`MCPEvents.swift`](../Packages/IntatisProtocol/Sources/MCPEvents.swift)
- [`MCPGrant.swift`](../Packages/IntatisProtocol/Sources/MCPGrant.swift)
- [`MCPIdentity.swift`](../Packages/IntatisProtocol/Sources/MCPIdentity.swift)
- [`MCPResults.swift`](../Packages/IntatisProtocol/Sources/MCPResults.swift)
- [`MCPProtocolTests.swift`](../Packages/IntatisProtocol/Tests/MCPProtocolTests.swift)

## 12. Runtime、authority 与精确 binding

### 12.1 authority

真实 connection authority 至少包含：

- session ID。
- server ID + immutable revision。
- protocol profile/max/negotiated version。
- transport identity。
- canonical WorkspaceLease/root identity。
- filesystem/read-write boundary。
- exact network/proxy/trust boundary。
- credential/OAuth account identity。
- Agent/grant/revocation fingerprint。
- executable/interpreter/script/helper identity。

不同 authority 永不共享 connection。即使两个 Agent 的当前字段相同，跨 Agent
默认也不复用；将来如增加性能复用，必须证明 authority 完全相同且不能改变
模型/权限可见事实。

### 12.2 exact reuse

只有以下条件同时成立才复用：

- exact config revision。
- exact authority、OAuth account 和 credential generation。
- startup complete。
- client open 且 generation 未 retired。
- required capability 已验证。
- grant/revocation 未变化。

任何 mismatch 创建新 generation。旧 catalog/view publication 不会偷换旧请求
持有的 connection set。

### 12.3 三层 catalog/binding

严禁混层：

1. raw server catalog：server 实际公布的完整目录。
2. Agent view：按 attachment、grant、filters、platform、policy 派生。
3. provider binding：某次 provider dispatch 冻结的 ToolSpec + prepared route。

[`AgentRequestToolSnapshot`](../Packages/IntatisAgentKernel/Sources/AgentRequestToolSnapshot.swift)
在**每次 provider dispatch**创建。provider response 只能使用自己持有的
snapshot；执行前复核：

- registry version。
- raw/view revision。
- binding ID/schema hash。
- connection generation。
- grant/lease/revocation fingerprint。
- account/profile/version。

任一不一致在发送 `tools/call` 前 fail closed。

### 12.4 required startup

每次 active invocation 冻结 required/optional view：

- required server 任一初始化失败，整个 invocation 在 provider dispatch 前失败。
- GUI 保留会话并显示错误，但不降级执行。
- `intatis exec`/非交互 CLI 非零退出。
- optional server 失败只撤下自身能力并显示状态。
- Retry、restore、attach 不隐式连接；只有 Send、Resume 或 explicit Connect
  创建 live generation。

证据：

- [`MCPRuntime.swift`](../Packages/IntatisMCP/Sources/MCPRuntime.swift)
- [`MCPProductionRuntime.swift`](../Packages/IntatisMCP/Sources/MCPProductionRuntime.swift)
- [`MCPConnection.swift`](../Packages/IntatisMCP/Sources/MCPConnection.swift)
- [`MCPSnapshot.swift`](../Packages/IntatisMCP/Sources/MCPSnapshot.swift)
- [`MCPRuntimeAuthorityTests.swift`](../Packages/IntatisMCP/Tests/MCPRuntimeAuthorityTests.swift)
- [`MCPShippingConnectionServicesRegistryTests.swift`](../Packages/IntatisAgentKernel/Tests/MCPShippingConnectionServicesRegistryTests.swift)

## 13. Control-plane admission、权限与 durable execution

启动本地 executable、连接远程 origin、OAuth、refresh 和 subscription 都是宿主
动作，不能只依赖模型工具权限。

[`MCPControlPlaneAdmission`](../Packages/IntatisMCP/Sources/MCPAdmission.swift)
为 Test/Connect/Refresh 等操作冻结：

- request ID、session/server/revision。
- actor/user source。
- launch artifact 或 canonical endpoint identity。
- authority/lease/network/credential fingerprint。
- explicit consent。
- durable request/terminal。

模型发起的 MCP tool call 继续走现有链：

```text
ToolRegistry
→ schema/args validation
→ DeterministicPolicyGate
→ ModelPermissionReviewer（只能收窄）
→ PermissionEngine / PermissionResponder
→ CapabilityLease + WorkspaceLease + MCPGrant
→ durable execution ticket
→ exact prepared MCP route
→ durable settlement/tool_result
```

四审批模式：

| mode | 语义 |
|---|---|
| `auto` | 通过全部 hard gates 后可自动执行，并可产生 exact-identity remembered approval |
| `prompt` | 每次交互确认 |
| `writes` | 非 read-only tool 请求确认 |
| `approve` | 必须显式批准 |

任何 mode 都不能越过 hard deny、lease、grant、revocation、platform boundary、
control-plane admission 或 durable precondition。worker 默认零 MCP；child 只能
取得父 grant 与自身 lease 的交集；`@permission-reviewer` 和 GoalVerifier 永远
为零 MCP。

## 14. 本地 stdio

MCP stdio 使用 direct exec + pipe，不使用 `/bin/sh -c`，不需要 PTY。

### 14.1 launch identity

[`ManagedPipeProcess`](../Packages/IntatisMCPStdio/Sources/ManagedPipeProcess.swift)
持有：

- canonical executable/interpreter/script identity。
- Test、save precommit、launch 前 exact revalidation。
- fixed argv/cwd。
- 独立 stdin/stdout/stderr。
- stdout 仅 MCP framing；stderr 只进有界清洗诊断。
- 最小环境和独立临时 HOME。
- process group、death ownership、TERM→KILL→drain。
- framing/partial-write/queue/stderr hard limits。

默认不允许任意 helper。获准 helper 必须命中 exact identity allow-list，并继承
同一 sandbox、network、process group 和 death cleanup。

### 14.2 filesystem sandbox

- DeveloperID/macOS：Seatbelt。
- Linux：bwrap 可用且完整 policy/guard 建立时才运行，否则 fail closed。
- read-only Agent 使用 read-only filesystem boundary。
- read-write 也只能写 WorkspaceLease 允许位置。
- credential/key/auth/config 路径不可移除地加入 deny。
- symlink/hardlink/special file/identity replacement fail closed。

### 14.3 exact network

“exact host/port 尚未实现”已经不是当前事实。

[`MCPStdioExactNetworkGateway`](../Packages/IntatisMCPStdio/Sources/MCPStdioNetworkGateway.swift)
实现：

- 只接受 canonical HTTPS origins。
- child 启动前一次解析 DNS 并冻结 sockaddr。
- generation-local 高熵 credential。
- 只监听 exact loopback port。
- 严格、无 body、唯一 credential 的 CONNECT parser。
- 只连接预先冻结且匹配 origin 的地址。
- concurrent tunnel、每方向 bytes、connect/header/idle timeout 上限。
- credential/proxy URL 注册到同一 redactor。

macOS Seatbelt 只允许该 generation 的 loopback gateway。Linux
`IntatisMCPStdioGuard`：

- `PTRACE_SEIZE` 并追踪 clone/fork/vfork。
- tracee 冻结和 exec identity gate。
- thread clone 要求 `CLONE_FILES`。
- 拒绝破坏 tracer/ownership 的 dumpable/ptracer/PDEATHSIG/subreaper 修改。
- 使用 leader `pidfd_open`/`pidfd_getfd` 和 host-owned fixed loopback sockaddr
  模拟获准 connect，跳过 tracee 原 syscall并注入结果。
- 支持 x86_64 与 aarch64。
- 直接 UDP、alternate loopback 和未列出 exec 均 retire generation。

这证明实现存在；当前 Darwin 主机不能替代匹配架构 Linux+bwrap/ptrace 运行
验收，后者保持 `ENVIRONMENT_LIMITED`。

### 14.4 受控与非受控退出

- turn/task/session/App shutdown 精确取消、关闭 pipe、TERM、KILL、wait/drain。
- partial write 或 framing 不确定立即 retire generation。
- App 突然 crash/机器掉电不能承诺绝对无孤儿；冷启动只能凭可证明 owner
  marker/death pipe/process identity reconcile，不能凭历史 PID 杀进程。

源码与测试：

- [`MCPStdioSandbox.swift`](../Packages/IntatisMCPStdio/Sources/MCPStdioSandbox.swift)
- [`MCPStdioNetworkGateway.swift`](../Packages/IntatisMCPStdio/Sources/MCPStdioNetworkGateway.swift)
- [`MCPStdioGuard.c`](../Packages/IntatisMCPStdio/ExecutionGuard/IntatisMCPStdioGuard.c)
- [`MCPManagedStdioTests.swift`](../Packages/IntatisMCP/Tests/MCPManagedStdioTests.swift)

## 15. Streamable HTTP

生产远程 transport 是 Intatis-owned state machine，不使用 URLSession 或上游
SDK transport fallback。

### 15.1 origin 与 I/O 边界

- 明确的 HTTP(S) endpoint；正式默认 HTTPS，localhost 开发例外必须显式。
- 拒绝 user-info。
- 固定 scheme/host/port/trust domain。
- `CURLOPT_RESOLVE`/等价 exact socket binding 防 DNS rebinding。
- 不跨 origin redirect；Authorization/cookie/client identity 不跨 origin。
- 不继承浏览器 cookie。
- proxy 是显式 policy，不使用不可见 ambient proxy。
- TLS pin、header/body/frame/stream/request hard limits。

### 15.2 protocol state machine

- 每个 client message 独立 POST。
- 接受 `application/json` 与 `text/event-stream`。
- notification/response 的 `202 Accepted` 空响应。
- 可选 GET SSE；405 只表示 GET stream 不支持。
- 每条 stream 独立 event ID、retry、resume 和 dedup。
- `MCP-Protocol-Version` 只在 initialize 成功后发送。
- `MCP-Session-Id` 绑定 exact generation 并按敏感值处理。
- 带 session ID 请求 404：retire 旧 session，未来操作新 initialize；已发送
  side-effecting call 记 execution uncertain，不重放。
- 正常关闭发送 DELETE；405 后仍关闭本地 generation。
- 多并行 SSE response 路由到 exact request/generation。

### 15.3 不自动重放

authorization challenge、session 404、network failure 或 reconnect 都不能自动
重放已 dispatch 的 `tools/call`。只读 discovery 在新 generation 上可以使用
新的 request identity 重发。无法证明副作用是否发生时返回 typed
`executionUncertain`。

证据：

- [`MCPStreamableHTTPTransport.swift`](../Packages/IntatisMCP/Sources/MCPStreamableHTTPTransport.swift)
- [`MCPCurlHTTPExecutor.swift`](../Packages/IntatisMCP/Sources/MCPCurlHTTPExecutor.swift)
- [`MCPHTTPPolicy.swift`](../Packages/IntatisMCP/Sources/MCPHTTPPolicy.swift)
- [`IntatisCurlTransport`](../Packages/IntatisCurlTransport)
- [`MCPStreamableHTTPTests.swift`](../Packages/IntatisMCP/Tests/MCPStreamableHTTPTests.swift)
- [`MCPCurlHTTPExecutorTests.swift`](../Packages/IntatisMCP/Tests/MCPCurlHTTPExecutorTests.swift)
- [`MCPHTTPPolicyTests.swift`](../Packages/IntatisMCP/Tests/MCPHTTPPolicyTests.swift)

## 16. OAuth、凭据与账号

### 16.1 OAuth

[`MCPOAuth.swift`](../Packages/IntatisMCP/Sources/MCPOAuth.swift)实现：

- RFC 9728 Protected Resource Metadata。
- RFC 8414 discovery，再到 OIDC discovery。
- OAuth 2.1 authorization code + PKCE。
- state、login generation、callback identity fencing。
- Client ID Metadata Documents；DCR 只有显式启用时才用。
- RFC 8707 resource binding。
- canonical origin/audience/scope。
- `WWW-Authenticate` scope step-up。
- single-flight refresh、refresh-token retention。
- account/authority isolation、logout/reset、token generation fence。
- loopback callback 仅 exact `127.0.0.1`/`::1`，有界 request，固定不反射响应。

OAuth 登录不顺带连接 server；Connect 也不隐式开始登录。旧 token 在 logout、
scope/account/authority 改变后立即无权用于新 binding。

### 16.2 两套凭据后端必须区分

普通模型 provider 当前继续使用 Intatis config/auth/env/file resolver；
`Apps/IntatisMac/Sources/Keychain.swift` 的历史命名不能用来描述 MCP。

MCP 使用：

- macOS App：Security.framework data-protection Keychain。
- macOS/Linux CLI：认证加密、owner-only `MCPCLIEncryptedSecretStore`。

catalog、EventLog、`session.json`、diagnostics、CLI history 只保存
`MCPSecretReference`、安全来源类型和身份摘要。Keychain/store 锁定、损坏、
source-binding mismatch 或密钥不可用时 fail closed；不存在明文降级。

证据：

- [`MCPSecretStore.swift`](../Packages/IntatisMCP/Sources/MCPSecretStore.swift)
- [`MCPSecretStoreTests.swift`](../Packages/IntatisMCP/Tests/MCPSecretStoreTests.swift)
- [`MCPAppOAuthIntegration.swift`](../Apps/IntatisMac/Sources/MCPAppOAuthIntegration.swift)
- [`MCPCLIOAuthIntegration.swift`](../Apps/intatis-cli/Sources/MCPCLIOAuthIntegration.swift)
- [`MCPOAuthTests.swift`](../Packages/IntatisMCP/Tests/MCPOAuthTests.swift)

签名 App 的真实 data-protection Keychain CRUD 需要 signed host；unsigned XCTest
不能替代该发行环境证据。

## 17. Tools、`tool_search` 与输出

### 17.1 tool catalog

- 完整分页、schema validation、qualified name。
- raw catalog 与 Agent view 分离。
- grant/filter/platform/policy 后才进入 provider snapshot。
- `ToolRegistration` 使用实例 descriptor。
- catalog/schema 变化生成新 registry/view/binding version。
- stale provider response 不能执行新 tool implementation。

### 17.2 Codex-compatible `tool_search`

- 小目录可 direct expose；大目录用 deferred tools。
- 默认 limit 8。
- Codex-compatible text fields、BM25、English tokenizer/stemmer/stop words。
- search result 带 raw/view revision、binding/schema/authority identity。
- stale search result fail closed。
- stdio schema cache 是有界 LRU，不是授权或连接事实。
- `tool_search_output` 保留 model history；loaded deferred tools 不重新进入后续
  顶层 `tools`。

实现：

- [`MCPBM25Index.swift`](../Packages/IntatisMCP/Sources/MCPBM25Index.swift)
- [`MCPToolSearch.swift`](../Packages/IntatisMCP/Sources/MCPToolSearch.swift)
- [`MCPStdioToolCatalogCache.swift`](../Packages/IntatisMCP/Sources/MCPStdioToolCatalogCache.swift)
- [`MCPToolBinding.swift`](../Packages/IntatisMCP/Sources/MCPToolBinding.swift)

### 17.3 P1：预算原子性

[`MCPToolResultAggregateBudget.reserveAtomically`](../Packages/IntatisMCP/Sources/MCPToolExecution.swift)
按固定锁序同时预留 provider-request 与 turn aggregate budget。

`MCPToolSearchTool.execute`：

1. 只做 `previewSearch`，不扩大 loaded state。
2. 同时编码 canonical text JSON 与 provider-native
   `ModelToolSearchOutput`。
3. 对两者合计最终字节收 single/provider/turn budget。
4. 只有 reservation 成功才 commit loaded tools。

因此 budget rejection 消耗零额度、loaded state 不变；两个并发调用不能各自
看到旧余额后共同超支。证据：

- [`testToolSearchCanonicalOutputIsBudgetedBeforeLoadedState`](../Packages/IntatisMCP/Tests/MCPToolBindingSearchTests.swift)
- `MCPToolSearchParityTests`
- `MCPToolResultConversionTests`

### 17.4 所有 tool result

- JSON schema、MIME、URI、content type 校验。
- text/image/audio/resource link/embed 保留 provenance。
- block、result、request、turn aggregate hard limits。
- sanitization 扩张按最终字节收费。
- 大内容写入 ArtifactStore，只给模型有界摘要与引用。
- binary secret heuristic 与 exact/derived SecretScanner。
- error/result/diagnostic 不保留 raw token、session ID 或敏感 URL。

## 18. Resources、Prompts、Completions、Roots 与 instructions

### 18.1 Resources

- resources list、templates、read、subscribe/unsubscribe。
- URI、MIME、size、provenance。
- listChanged 合并刷新、尾部补刷、atomic publication。
- disconnect/revoke 后撤目录和 subscription。
- Codex 三个模型侧 resource tools 使用精确名称：
  - `list_mcp_resources`
  - `list_mcp_resource_templates`
  - `read_mcp_resource`
- 三者使用固定 schema、`strict:false`、无 output schema、支持 parallel、
  返回文本 JSON；cursor 必须 server-scoped，不对单个 server 隐式全量翻页，
  跨 server 聚合顺序确定。

### 18.2 Prompts 与 completions

- prompt 只在用户显式选择/插入后进入对话。
- prompt arguments 和 completion 有 schema、大小与来源。
- 外部 prompt 不能静默提升为 system/developer 指令。

### 18.3 Roots

- roots 由 WorkspaceLease 投影，不从任意 server 输入扩大。
- root changes 产生新 authority/binding，并发送受协商能力约束的
  `roots/list_changed`。

### 18.4 Server instructions

公开 Codex 会把 server instructions 作为 server-wide guidance。Intatis 保持
Codex 用户语义，但进行安全加严：

- 明确显示来源和 server identity。
- 有界、清洗、可查看。
- 不能修改 lease、grant、permission 或 system policy。
- 用户/session policy 可以禁用。

实现与证据：

- [`MCPResourceCatalog.swift`](../Packages/IntatisMCP/Sources/MCPResourceCatalog.swift)
- [`MCPResourceTools.swift`](../Packages/IntatisMCP/Sources/MCPResourceTools.swift)
- [`MCPContentOperations.swift`](../Packages/IntatisMCP/Sources/MCPContentOperations.swift)
- [`MCPPromptsCompletionsRoots.swift`](../Packages/IntatisMCP/Sources/MCPPromptsCompletionsRoots.swift)
- [`MCPW7CatalogResourceTests.swift`](../Packages/IntatisMCP/Tests/MCPW7CatalogResourceTests.swift)

## 19. Callbacks、notifications、sampling、elicitation 与 Tasks

### 19.1 inbound notifications

按 negotiated capability 处理：

- logging。
- progress。
- cancelled。
- resource updated。
- tools/resources/prompts listChanged。
- task status。

高频事件只进有界 live projection；EventLog 只保存脱敏、低频、可恢复的里程碑。
late/duplicate/cross-generation/token 输入不能结算当前 request。
产品面不暴露任意 `send_custom_notification` primitive；只发送协议规定、与当前
capability/lifecycle 绑定的 typed notification。

### 19.2 cancel 分流

- `initialize`：retire/close generation，不伪造 ordinary cancel。
- 普通非 task request：能发送时用 `notifications/cancelled`，随后停止本地等待
  并 fence late result。
- task-augmented request/task：使用 `tasks/cancel`。
- side effect 已发送但终态不可证明：`executionUncertain`。

### 19.3 Sampling

- 独立 broker，不递归 `AgentLoop`。
- 不继承 Intatis ToolRegistry、历史、workspace tools 或 Cowork task。
- sampling tools/toolChoice、tool-use/result 成对校验。
- bounded rounds、parallel、tokens、cost、rate、timeout。
- 逐请求 permission/user policy。
- requesting server 执行 sampling tool；Intatis 不把这些 tool 名路由到自己的
  registry。

### 19.4 Elicitation

- `codex-compat`：标准 form elicitation。
- `standard-extended`：provider-neutral URL elicitation broker。
- form 禁止 secret/password/token 收集。
- URL origin、callback、timeout、user interaction 有界。
- 不实现 OpenAI 私有 form extension。

### 19.5 Experimental Tasks

完整实现两套严格隔离的状态机：

- remote-server task：外部 server 持有 task，Intatis poll/result/list/cancel。
- client-hosted task：server 发 request，Intatis client 返回 task identity 并
  管理终态。

它们都不是 Intatis Cowork `WorkTask`，不会自动映射、委派或递归 Agent。
profile/capability 未协商时不广告。

证据：

- [`MCPInboundCallbacks.swift`](../Packages/IntatisMCP/Sources/MCPInboundCallbacks.swift)
- [`MCPInboundNotifications.swift`](../Packages/IntatisMCP/Sources/MCPInboundNotifications.swift)
- [`MCPSamplingBroker.swift`](../Packages/IntatisMCP/Sources/MCPSamplingBroker.swift)
- [`MCPElicitationBroker.swift`](../Packages/IntatisMCP/Sources/MCPElicitationBroker.swift)
- [`MCPTaskStateMachines.swift`](../Packages/IntatisMCP/Sources/MCPTaskStateMachines.swift)
- [`MCPCallbackBrokerTests.swift`](../Packages/IntatisMCP/Tests/MCPCallbackBrokerTests.swift)
- [`MCPTaskWireTests.swift`](../Packages/IntatisMCP/Tests/MCPTaskWireTests.swift)
- [`MCPTaskStateMachineTests.swift`](../Packages/IntatisMCP/Tests/MCPTaskStateMachineTests.swift)
- [`MCPTaskAugmentedToolBindingTests.swift`](../Packages/IntatisMCP/Tests/MCPTaskAugmentedToolBindingTests.swift)

## 20. P1：外部错误与统一 redaction

raw SDK `MCPError`、JSON-RPC data、remote diagnostics 或 HTTP body 不能直接进入
模型、EventLog、ArtifactStore 或 UI。

[`MCPClientSession`](../Packages/IntatisMCP/Sources/MCPClientSession.swift)在
initialize、perform、task、notify、content 等 session boundary 把外部错误转为：

- bounded operation。
- typed `MCPSanitizedExternalErrorCategory`。
- 可选 JSON-RPC code。
- 经 exact session redactor 处理的短 summary。

它不保留 raw remote error object。HTTP Authorization、OAuth token、
`MCP-Session-Id`、stdio gateway credential/proxy URL 都注册到同一 redactor。
runtime activation/refresh diagnostic、EventLog adapter 和 product host 复用同一
session sanitizer。

精确测试：

- [`testExternalJSONRPCErrorsAreExactlyRedactedAtSessionBoundary`](../Packages/IntatisMCP/Tests/MCPProtocolLifecycleTests.swift)
- [`testRefreshDiagnosticUsesExactSessionRedactor`](../Packages/IntatisMCP/Tests/MCPRuntimeAuthorityTests.swift)

## 21. 产品面

### 21.1 macOS

已接入：

- global/project MCP settings。
- server add/edit/remove/test/status/doctor。
- session attachment。
- Agent access/grant/revoke。
- connect/disconnect/refresh/reload。
- OAuth login/logout/reset。
- import/export。
- call/resource/prompt/progress/task/elicitation cards。
- effective policy、required failure、diagnostics。

主要文件：

- [`MCPProductIntegration.swift`](../Apps/IntatisMac/Sources/MCPProductIntegration.swift)
- [`MCPProjectSettingsSurfaces.swift`](../Apps/IntatisMac/Sources/MCPProjectSettingsSurfaces.swift)
- [`MCPAppSessionSurfaces.swift`](../Apps/IntatisMac/Sources/MCPAppSessionSurfaces.swift)
- [`MCPConversationSurfaces.swift`](../Apps/IntatisMac/Sources/MCPConversationSurfaces.swift)
- [`MCPInteractionCenter.swift`](../Apps/IntatisMac/Sources/MCPInteractionCenter.swift)
- [`MCPConversationRuntimeHost.swift`](../Apps/IntatisMac/Sources/MCPConversationRuntimeHost.swift)

App Store target共享完整 macOS UI，但 stdio controls 由真实 linkage/platform
capability 排除，不靠“点了再报错”的运行时布尔兜底。

### 21.2 CLI

`intatis mcp` 覆盖：

- list、status、add、edit、remove、test、doctor。
- import、export。
- attach、detach、grant、revoke。
- connect、disconnect、refresh、reload。
- OAuth status、login、logout。
- machine-readable JSON。

interactive `/mcp` 提供 live status/connect/refresh/disconnect。

主要文件：

- [`MCPCLICommands.swift`](../Apps/intatis-cli/Sources/MCPCLICommands.swift)
- [`MCPCLILiveCommands.swift`](../Apps/intatis-cli/Sources/MCPCLILiveCommands.swift)
- [`MCPCLIProductRuntime.swift`](../Apps/intatis-cli/Sources/MCPCLIProductRuntime.swift)
- [`MCPCLIProcessOwner.swift`](../Apps/intatis-cli/Sources/MCPCLIProcessOwner.swift)

### 21.3 P1：无 MCP CLI

`MCPCLIInteractiveCodeHost` 构造时完全 inert：

- 不创建 MCP context/runtime/lease。
- 同一 EventLog 有 durable attachment 时才在 dispatch 前激活。
- 第一次显式 `/mcp` action 才创建 owner。
- `/clear` 关闭 exact old owner，再创建新的 lazy host。
- 无 attachment 的 shipping Code startup 不增加 MCP stdout。

证据：

- [`MCPCLIProcessOwnerTests.swift`](../Apps/intatis-cli/Tests/MCPCLIProcessOwnerTests.swift)
- [`MCPNoAttachmentRegressionTests.swift`](../Packages/IntatisAgentKernel/Tests/MCPNoAttachmentRegressionTests.swift)

## 22. Client-only 证明矩阵

| 检查面 | 当前证据 | 结论 |
|---|---|---|
| SwiftPM products | 根 manifest 只有 `IntatisMCP`/`IntatisMCPStdio` client libraries；无 MCP server product | client-only |
| Vendored SDK | [`UPSTREAM.md`](../Vendor/MCPClientSDK/UPSTREAM.md) 排除 `Server` actor、HTTP Server transports、InMemory/Network transport、server OAuth、upstream conformance executable/tests | client-only source closure |
| Patch ledger | [`CLIENT-ONLY-001/002`](../Vendor/MCPClientSDK/PATCHES.md) 固定 deny-list 和 remote server metadata 搬迁 | 无 server namespace/actor |
| Source/API scan | [`SDKClientOnlySurfaceTests`](../Packages/IntatisMCP/Tests/SDKClientOnlySurfaceTests.swift) 检查 source deny-list、resolved dependency graph、平台 linkage | `EVIDENCE_PRESENT` |
| Callbacks | 仅 client connection 上的 server→client request handler | 不监听/host MCP |
| `MCPServerContributor` | 只返回 bounded proposal document；无 catalog/transport/credential/grant service | 不是 server seam |
| stdio gateway | authenticated CONNECT proxy，只提供 outbound egress | 不是 MCP listener |
| conformance client | development-only executable target，不进入 App product | 不是发行 server |
| App/CLI 命令 | 管理“外部 server 定义与连接”；没有 `mcp-server` 命令 | 角色明确 |

任何后续 SDK 升级都必须重新跑 source/API deny-list 和 target graph，不能直接换回
上游同时包含 client/server 的 package surface。

## 23. 安全不变量

### 23.1 必须始终成立

- 外部文字、prompt、resource、instructions、diagnostic 均带来源并视为不可信。
- MCP 不创建第二套权限系统。
- MCP tool call 不绕过 ToolRegistry、PermissionEngine、lease 或 durable ticket。
- worker 默认零，reviewer/GoalVerifier 永远零。
- connection authority 不跨 workspace、Agent、credential 或 account。
- secret 不进入 catalog、EventLog、projection、export、CLI history、普通 error。
- result 和 search output 在状态变化前先原子预留预算。
- local stdio 不继承完整 host environment。
- exact network 不可证明时 fail closed。
- unknown side effect 不自动重放。
- cold restore 不自动连接、登录或执行。
- shutdown 先停止 admission，再取消和 drain。
- iOS/App Store linkage 不因 runtime flag 被扩大。

### 23.2 不可信内容进入模型

所有 external context 使用 SDK-independent
[`UntrustedExternalContext`](../Packages/IntatisProtocol/Sources/UntrustedExternalContext.swift)
或等价 provenance：

- server/revision/resource URI。
- content type/size/digest。
- trust classification。
- bounded sanitized body。

它不能写入 system/developer role，也不能修改工具、权限或 workspace boundary。

### 23.3 durable 与隐私

- EventLog 保存可审计 identity/decision/terminal，不保存 secret。
- diagnostics 保存类别、code、安全摘要，不保存 raw remote payload。
- stdout/stderr、SSE、progress、task result 都有大小/频率界限。
- late output 只有 exact generation/request token 才能被当前调用接收。
- ArtifactStore 前再次做 MIME、size、URI、binary-secret 和 exact redaction。

## 24. 生命周期与恢复

### 24.1 状态

connection generation 至少有：

```text
configured
→ starting
→ initialized
→ ready
→ reconnecting / retiring
→ stopped
```

目录 publication 与 connection lifecycle 分开；断线先撤下 future provider 能力，
再更新 UI。已经 dispatch 的调用有界等待；不确定则 `executionUncertain`。

### 24.2 reconnect

- 每 server 同时一个 reconnect task。
- bounded exponential backoff + jitter。
- 用户操作、revocation、logout、session stop 可取消 backoff。
- reconnect 创建新 request/generation identity。
- 从不自动重放 `tools/call`。

### 24.3 shutdown scopes

- turn cancel：按 request 类型分流 cancel，停止本地等待，fence late result。
- task terminal：只 drain exact task requests/subscriptions，不误关共享的同
  session connection。
- session delete：精确关闭该 session 全部 MCP resources 后才删除。
- Command-Q：关闭 admission，广播全部 runtime stop，有界 drain。
- crash reconcile：只依据可证明 durable/OS identity，不按历史 PID 猜测。

实现：

- [`MCPReliability.swift`](../Packages/IntatisMCP/Sources/MCPReliability.swift)
- [`MCPReliabilityTests.swift`](../Packages/IntatisMCP/Tests/MCPReliabilityTests.swift)
- [`SessionRuntimeManager.swift`](../Apps/IntatisMac/Sources/SessionRuntimeManager.swift)

## 25. 开源复用与供应链

### 25.1 SDK

官方 Swift MCP SDK 当前采用方式是 `vendored + derived`，不是普通 pinned remote
dependency：

- 上游 `0.12.1` / `a0ae212...`。
- 本地 package：`Vendor/MCPClientSDK`。
- client-only inventory：`UPSTREAM.md`。
- patches：CLIENT-ONLY、VERSION、INITIALIZE、TASKS、RESOURCES、HTTP、
  HOST-HTTP、HOST-OAUTH、PORTABLE-CRYPTO。
- 完整组合许可证和分发声明：
  `ThirdPartyNotices/MCPClient.md`、`ThirdPartyNotices/Licenses/`、`NOTICE.md`。

### 25.2 Codex `tool_search`

- 固定 Codex commit `61a44880...`。
- 公开 wire/history、搜索字段、schema cache 及 BM25 行为按 `derived` 登记。
- 没有采用 Codex MCP Server、UI、品牌、私有 prompt 或 Rust runtime。
- tokenizer/stemmer/deunicode/stop-words 来源、checksum、license 和 patch 见
  [`MCPToolSearch.md`](../ThirdPartyNotices/MCPToolSearch.md)。
- `Tests/MCPBM25ParityOracle` 只做 source-only 差分，不进入产品。

### 25.3 HTTP 与 Linux static closure

- macOS 使用 Apple SDK/system libcurl，不在 App bundle vendor Darwin libcurl。
- Linux static CLI 链接官方 Swift Static Linux SDK 中
  `libcurl + libssl + libcrypto + zlib`。
- artifact、SBOM、pkg-config、headers、source pins、双架构 archive hashes 和
  许可证见 [`MCPHTTPTransport.md`](../ThirdPartyNotices/MCPHTTPTransport.md)。
- Swift Crypto 4.5.1 是另一套 Linux-only CryptoKit-compatible dependency，
  其 BoringSSL 不能与 static SDK 的 BoringSSL 混写。
- 当前没有单 archive 的 signed source attestation 或 reproducible-build
  声明；header identity 不能夸大为 `.a` 的逐位可复现证明。

### 25.4 升级规则

每次 SDK/Codex/toolchain/static SDK 升级必须：

1. 固定 tag/commit/checksum。
2. 重读许可证/NOTICE/依赖。
3. 重放 client-only inventory 与全部 patches。
4. 重新检查无 server API/target/binary/seam。
5. 重跑 protocol/profile/conformance。
6. 重跑 tool-search Rust oracle/Swift parity。
7. 重跑 portable crypto KAT 和双架构 Linux build。
8. 重算 final artifacts hash。
9. 重新检查 macOS bundle/linkage、App Store/iOS 边界。

## 26. W0–W10 实现与证据矩阵

### W0：冻结事实、client-only SDK 与平台基线

- 状态：`PASS`
- 已实现：
  - 双 profile/version。
  - vendored client-only SDK 和 patch ledger。
  - Swift Crypto Linux boundary。
  - DeveloperID/App Store/CLI/iOS target graph。
  - NOTICE/provenance。
- 主要证据：
  - `Vendor/MCPClientSDK/{UPSTREAM,PATCHES}.md`
  - `Package.swift`、`project.yml`
  - `SDKClientOnlySurfaceTests`
  - `MCPPortableCryptoTests`
- 最终证据：根 SwiftPM、CLI、DeveloperID、App Store、iOS 和双架构 Linux
  静态交叉构建均以当前源码通过；发行签名和 Linux 实机运行另列 `I-ENV`。

### W1：稳定数据模型

- 状态：`PASS`
- 已实现：
  - IDs/revisions/authority/grants/attachments。
  - raw/view/binding 分层。
  - EventLog additive payload。
  - dynamic ToolRegistration/registry version。
  - structured result/provenance。
  - authorization MCP snapshot。
- 主要证据：
  - `IntatisProtocol/Sources/MCP*.swift`
  - `ToolProtocol.swift`
  - `MCPProtocolTests`
  - `MCPDynamicToolRegistryTests`
- 兼容：旧 JSONL、旧 lease、非 MCP tool 默认 nil/empty。

### W2：配置、catalog 与导入 staging

- 状态：`PASS`
- 已实现：
  - owner-only catalog、immutable revisions。
  - isolated Test-before-save。
  - source/provenance/conflict。
  - `.mcp.json`/`.claude.json` 固定 parser。
  - secret staging、sanitized export。
  - approval policy、attachment/grant durable state。
  - bounded contributor proposal。
- 主要证据：
  - `MCPConfigurationCatalogTests`
  - `MCPPreparedConfigurationTests`
  - `MCPImportTests`
  - `MCPServerContributorTests`

### W3：Session runtime 与 authority 隔离

- 状态：`PASS`
- 已实现：
  - session owner、authority pool、generation/revocation。
  - exact reuse predicate。
  - control-plane admission。
  - required startup fail-before-provider。
  - cold no-connect。
  - session/App drain。
- 主要证据：
  - `MCPRuntimeAuthorityTests`
  - `MCPShippingConnectionServicesRegistryTests`
  - App/CLI owner tests。

### W4：Managed stdio 与基础协议

- 状态：`I-ENV`
- 已实现：
  - direct pipe process。
  - launch identity。
  - Seatbelt/bwrap/guard。
  - exact network gateway。
  - minimal env/sensitive paths。
  - initialize/ping/cancel/shutdown。
- 主要证据：
  - `IntatisMCPStdio`
  - `MCPManagedStdioTests`
  - C strict compilation/static cross-build gate。
- 环境边界：
  - 当前最终源码的 `MCPManagedStdioTests`：40 executed、0 skipped、
    0 failures。
  - 匹配架构 Linux+bwrap/ptrace runtime：`ENVIRONMENT_LIMITED`。

### W5：Tools 全链路、精确 binding 与 `tool_search`

- 状态：`PASS`
- 已实现：
  - discovery/pagination/schema。
  - per-dispatch snapshot。
  - grant/filter。
  - permission/durable ticket。
  - exact prepared route。
  - result/artifact/secret/budget。
  - BM25/deferred tools/cache。
- 主要证据：
  - `MCPToolBindingSearchTests`
  - `MCPBM25CodexParityTests`
  - `AgentRequestToolSnapshotTests`
  - `MCPArtifactStoreToolSinkTests`
- P1 focused 结果：tool-search/result-conversion/request-snapshot/Responses parity
  四个 suites 共 33 executed、0 skipped、0 failures；包含 10,000 tools
  规模、BM25 metadata、grant scope、catalog replacement、budget 和
  loaded-state 合同。

### W6：Streamable HTTP、OAuth 与 secrets

- 状态：`I-ENV`
- 已实现：
  - POST JSON/SSE、GET、202、resume、session、404、DELETE。
  - exact origin/redirect/trust/proxy/egress。
  - OAuth discovery/PKCE/resource/scope/refresh/account。
  - macOS Keychain、CLI encrypted store。
  - no operation replay。
- 主要证据：
  - `MCPStreamableHTTPTests`
  - `MCPHTTPPolicyTests`
  - `MCPOAuthTests`
  - `MCPSecretStoreTests`
- 环境边界：真实第三方 OAuth AS/account/scope/resource 和 signed App Keychain
  E2E 未由当前环境证明。

### W7：动态目录与内容 surface

- 状态：`PASS`
- 已实现：
  - tools/resources/prompts listChanged coalescing。
  - atomic catalog publication。
  - resources/templates/read/subscriptions。
  - Codex resource tools。
  - prompts/completions/roots/instructions policy。
- 主要证据：
  - `MCPW7CatalogResourceTests`
  - `MCPInboundNotificationTests`
  - `MCPExternalContextAgentLoopTests`

### W8：完整产品管理面

- 状态：`I-ENV`
- 已实现：
  - macOS settings/session/agent/content surfaces。
  - CLI 管理/运行/OAuth/import/export。
  - four approval modes/effective policy。
  - doctor/status/diagnostics。
  - lazy no-MCP owner。
- 主要证据：
  - macOS `MCP*.swift`
  - CLI `MCPCLI*.swift`
  - `MCPCLIConfigurationArgumentsTests`
  - `MCPCLIProcessOwnerTests`
  - `MCPApprovalInteractionPolicyTests`
- 环境边界：真实第三方 server/account 的完整 GUI/CLI 人工流程未由当前环境
  证明。

### W9：Sampling、Elicitation 与 experimental Tasks

- 状态：`PASS`
- 已实现：
  - bounded nonrecursive sampling with tools。
  - form/URL elicitation。
  - remote-server/client-hosted task state machines。
  - poll/result/list/cancel/TTL。
  - Cowork Task 隔离。
- 主要证据：
  - `MCPCallbackBrokerTests`
  - `MCPInboundCallbackSessionTests`
  - `MCPTaskWireTests`
  - `MCPTaskStateMachineTests`
  - `MCPTaskAugmentedToolBindingTests`

### W10：可靠性、迁移与完整认证

- 状态：`I-ENV`
- 已实现：
  - reconnect/backoff、refresh storm、late/duplicate fencing。
  - bounded metrics/diagnostics。
  - crash/partial write/network fault fixtures。
  - import/no-MCP/reliability regression。
  - official/extended conformance harness。
  - provenance/upgrade matrix。
- 主要证据：
  - `MCPReliabilityTests`
  - `Tests/MCPConformance/run-w10.sh`
  - `scripts/validate-linux-cli.sh`
- 最终确定性结算：
  - official client conformance：23/23。
  - Intatis Tasks interoperability：3/3。
  - W10 七个 focused suites：102/102。
  - provenance/client-only/portable-crypto/static QA：全部通过。
- 环境边界：真实第三方 server/OAuth、匹配 Linux runtime、签名/公证发行和长期
  soak 不可由当前环境替代。

## 27. 31 个终态验收门

全表最终统一判定：25 个确定性门 `PASS`，6 个含不可替代外部证据的门
`I-ENV`，0 `UNKNOWN`，0 `IMPLEMENTATION_GAP`。`I-ENV` 门中的本地实现、
fixture、构建和静态证据均已通过，但不能替代对应真实环境。

| # | 验收门 | 当前状态 | 主要证据/边界 |
|---:|---|---|---|
| 1 | 双 profile/version/capability/conformance；部分 capability server 合法 | `PASS` | negotiation、SDK patch、official manifest |
| 2 | stdio/Streamable HTTP 真实 fixture connect/call；无 legacy SSE | `PASS` | stdio/HTTP suites |
| 3 | Test/Connect/Refresh exact admission、consent、durable terminal | `PASS` | `MCPAdmission`、host adapters |
| 4 | executable/interpreter/script identity 在 Test/save/launch 一致 | `PASS` | launch/precommit tests |
| 5 | 模型看到哪版工具，只执行哪版 | `PASS` | per-dispatch snapshot/binding tests |
| 6 | raw catalog、Agent view、provider binding 不混层 | `PASS` | snapshot/catalog publication |
| 7 | 不同 authority/Agent 不共享真实 connection | `PASS` | runtime authority tests |
| 8 | worker 默认零，reviewer/GoalVerifier 永远零 | `PASS` | lease/grant/Cowork tests |
| 9 | 所有 MCP tool call 经权限与 durable ticket | `PASS` | AgentKernel/EventLog adapters |
| 10 | 四审批模式完整，不能越过 hard gates | `PASS` | approval policy tests |
| 11 | local server 不能越 workspace/denied paths/exact network | `I-ENV` | macOS/fixture/static guard；Linux runtime 受限 |
| 12 | HTTP POST/GET/SSE/resume/session/404/DELETE generation 合同 | `PASS` | `MCPStreamableHTTPTests` |
| 13 | token 绑定 resource/audience/origin 且不进输出 | `I-ENV` | OAuth/redaction tests；真实 AS 受限 |
| 14 | App Keychain、CLI encrypted owner-only store，无明文 | `I-ENV` | CLI/tests；signed Keychain 受限 |
| 15 | 断线/撤权/logout/root 变化使旧 binding 失效 | `PASS` | authority/reliability tests |
| 16 | 不重试 unknown side effect；三类 cancel 分流 | `PASS` | HTTP/task/reliability tests |
| 17 | refresh 原子发布 raw catalog 再派生 view，无半新/僵尸 | `PASS` | dynamic refresh/W7 tests |
| 18 | tools/resources/prompts/results 有大小、secret、provenance | `PASS` | output security/content tests |
| 19 | prompt/instructions/external context 不提升权限或 role | `PASS` | untrusted context/AgentLoop tests |
| 20 | sampling、URL elicitation、experimental Tasks 完整且非递归/隔离 | `PASS` | callback/task suites |
| 21 | Codex `tool_search`、BM25、deferred/cache/resource tools parity | `PASS` | parity/oracle/tool-search suites |
| 22 | cold restore/attach/Retry 不连接；Send/Resume/Connect 才 live | `PASS` | runtime/CLI owner tests |
| 23 | `.mcp.json`/`.claude.json` 安全预览、迁移、确认、原子保存 | `PASS` | import/config tests |
| 24 | DeveloperID/CLI stdio+HTTP，App Store HTTP-only，iOS 无 runtime | `I-ENV` | source graph；signed final bundle 受限 |
| 25 | GUI/CLI 完成配置、测试、挂载、授权、认证、诊断、删除 | `I-ENV` | product sources/tests；真实第三方流程受限 |
| 26 | 产品语义对齐 Codex，视觉保持 Intatis 原生 | `PASS` | public docs/source mapping、product sources |
| 27 | 无 MCP Server、Hosted ChatGPT Apps、ChatGPT 私有 auth、reserved/private plugin、OpenAI 私有 form 或 Knowledge seam | `PASS` | client-only tests/target scan |
| 28 | 无 MCP 用户行为与数据不回归 | `PASS` | CLI inert + no-attachment AgentLoop tests |
| 29 | 固定上游、license、NOTICE、patch、fault/conformance、真实 E2E | `I-ENV` | provenance/fixtures 已有；真实 E2E/attestation 受限 |
| 30 | active invocation required failure 在 provider 前整体失败 | `PASS` | runtime/CLI required tests |
| 31 | connection 只按 exact identity/startup/open reuse；publication 不偷换 | `PASS` | authority/connection-set/binding tests |

### 27.1 Gate 27 的静态解释

Gate 27 的“无 MCP Server”不能用简单字符串 `Server` 或 `serve` 扫描判断。
正确判据是：

- 无 server target/product/binary/listener/actor/JSON-RPC handler。
- client callbacks 不监听外部连接。
- remote server metadata 只是 client decode value。
- contributor 无 privileged host service。
- CONNECT gateway 只出站。
- conformance executable 只做 client。

### 27.2 Gate 29 不能被误报

Gate 29 原文包含“真实 E2E 全部通过”，因此当前不能写 `PASS`。已完成的
provenance、patch、fault fixture 和 conformance harness 必须与下列
`ENVIRONMENT_LIMITED` 分开：

- 真实第三方 stdio/HTTP server。
- 真实 OAuth provider/account/scope/resource。
- matching-architecture Linux+bwrap/ptrace。
- signed DeveloperID/App Store archive、notarization、bundle/entitlement inventory。
- static SDK single-archive signed source attestation/reproducible build。

## 28. Conformance 与测试矩阵

### 28.1 固定配置事实

这些是 manifest/脚本声明的场景数量，不是本次最终运行结果：

- official runner：`@modelcontextprotocol/conformance@0.1.16`。
- official client scenarios：23。
  - `codex-compat`：5。
  - `standard-extended`：18。
- Intatis Tasks interoperability：3。
  - complete。
  - timeout。
  - cancel。
- `run-w10.sh` 在 official + extended 后运行 7 个 focused suites：
  - `MCPStreamableHTTPTests`
  - `MCPManagedStdioTests`
  - `MCPImportTests`
  - `MCPProtocolLifecycleTests`
  - `MCPTaskStateMachineTests`
  - `MCPTaskAugmentedToolBindingTests`
  - `MCPReliabilityTests`

23 是 official 总数；3 个 task 场景必须单列，不能写成“26 个 official”。

固定入口：

- [`scenario-manifest.json`](../Tests/MCPConformance/official/scenario-manifest.json)
- [`run-official.sh`](../Tests/MCPConformance/official/run-official.sh)
- [`run-extended.sh`](../Tests/MCPConformance/extended/run-extended.sh)
- [`run-w10.sh`](../Tests/MCPConformance/run-w10.sh)

### 28.2 必跑确定性、故障与规模矩阵

最终 runner 已覆盖以下确定性矩阵；“存在测试文件”仍不等于外部环境已经通过。

| 矩阵 | 必须覆盖的正反例 | 主要 suites | 当前结算 |
|---|---|---|---|
| 配置与存储 | revision、并发写、crash/corruption、owner-only、no-follow、symlink/hardlink、unknown schema、secret-free export | configuration/prepared/import/secret-store | `PASS` |
| launch identity | executable/interpreter/script/helper 的 Test/save/launch 一致、替换与 symlink swap | managed stdio | `PASS` |
| stdio process | initialize/ping/call、stderr flood、oversize/malformed/partial frame、queue overflow、hung/stubborn process、descendant cleanup | managed stdio | `I-ENV` |
| stdio sandbox | read-only/read-write、credential paths、minimal env、unlisted exec/fork/setsid、exact network、UDP/alternate loopback bypass | managed stdio + C guard | `I-ENV` |
| HTTP | JSON/SSE/202、GET 405、per-stream resume/dedup、session 404、DELETE 405、redirect/cookie/proxy/DNS rebinding、hard caps、no replay | HTTP/policy/curl | `PASS` |
| OAuth/secrets | discovery order、PKCE/state、resource/audience、scope step-up、refresh retention/single-flight、logout、source binding、tamper/no plaintext | OAuth/secret-store | `I-ENV` |
| catalog/binding | pagination、same-name schema change、stale generation/search result、atomic refresh、notification storm、exact reuse mismatch | binding/search/runtime/W7 | `PASS` |
| output security | exact/derived secret、session ID/token echo、binary secret、MIME/URI、sanitization expansion、single/request/turn budgets、Artifact spill | lifecycle/tool-result/artifact | `PASS` |
| content | resources/templates/read/subscription、prompt provenance、completion、roots change、instructions policy | W7/content/external-context | `PASS` |
| callbacks | sampling tools/toolChoice/multi-round/parallel、form secret reject、URL origin/callback、late/duplicate/cross-generation | callback/session | `PASS` |
| Tasks | exact wire、remote/client-hosted IDs、poll/result/list/cancel、TTL、timeout、ordinary-cancel rejection、Cowork isolation | task wire/state/binding + interop | `PASS` |
| 多 Agent | worker zero、reviewer/Goal zero、child intersection、different authority no reuse、revoke while active | AgentKernel/Cowork/runtime | `PASS` |
| 生命周期 | cold no-connect、required pre-dispatch failure、reconnect/backoff、turn/task/session/App shutdown、late result fence、crash reconcile | runtime/reliability/CLI owner | `PASS` |
| 无 MCP | legacy lease/log、provider request/wire/events、CLI stdout、lazy owner、Chat/iOS behavior | no-attachment/CLI/protocol | `PASS` |
| 规模与压力 | 1/10/100 servers、10/1,000/10,000 tools、large resource/result、slow/hung/crashing server、concurrent Agents、memory/queue bounds | BM25/search/reliability/fault fixtures | `I-ENV` |
| 产品与平台 | DeveloperID stdio+HTTP、App Store HTTP-only、CLI stdio+HTTP、iOS no runtime、GUI/CLI effective policy 一致 | target graph/product builds/manual matrix | `I-ENV` |

规模矩阵中的算法、queue、budget 与 fault fixtures 可在本地确定性运行；真实
100-server、第三方网络、长时间 memory plateau 和签名产品 soak 仍属于
`ENVIRONMENT_LIMITED`，不得把前者通过写成后者完成。

### 28.3 最终命令与结果

| 验证 | 命令/入口 | 最终结果 |
|---|---|---|
| Official client conformance | `Tests/MCPConformance/official/run-official.sh` | `PASS`：23/23，0 expected failures |
| Tasks interoperability | `Tests/MCPConformance/extended/run-extended.sh` | `PASS`：3/3（complete/timeout/cancel） |
| W10 aggregate | `Tests/MCPConformance/run-w10.sh` | `PASS`：official 23/23 + Tasks 3/3 + 7 suites 102/102 |
| Full SwiftPM tests | `swift test --disable-sandbox` | `PASS`：1362 executed、16 opt-in environment skips、0 failures |
| Root SwiftPM build | `swift build --disable-sandbox` | `PASS`，exit 0 |
| CLI product | `swift build --disable-sandbox --product intatis` | `PASS`，exit 0 |
| macOS DeveloperID Debug | `xcodebuild ... -scheme IntatisMac ... CODE_SIGNING_ALLOWED=NO build` | `PASS`，exit 0，arm64 |
| macOS App Store Debug | `xcodebuild ... -scheme IntatisMacAppStore ... CODE_SIGNING_ALLOWED=NO build` | `PASS`，exit 0，arm64 |
| iOS Simulator Debug | `xcodebuild ... -scheme IntatisiOS ... CODE_SIGNING_ALLOWED=NO build` | `PASS`，exit 0，x86_64+arm64 |
| Linux portable crypto | `swift test --filter MCPPortableCryptoTests` | `PASS`：4/4 |
| Linux aarch64 static CLI | `scripts/validate-linux-cli.sh` | `PASS`：static ELF，266,529,224 bytes |
| Linux x86_64 static CLI | `scripts/validate-linux-cli.sh` | `PASS`：static ELF，271,031,728 bytes |
| Linux aarch64 final SHA-256 | validation output | `8f03fbccb3b8d3301e04ff7e6aca635286771c414ed124407e0fc532718856a9` |
| Linux x86_64 final SHA-256 | validation output | `0a8071e5d01877c823d634f7a4613b267da64f159714939f10b61f8d65f06a20` |
| Managed stdio focused result | `MCPManagedStdioTests` | `PASS`：40/40，0 skipped，0 failures |
| P1 `tool_search` budget/loaded-state | exact tool-search/result-conversion tests | `PASS`：33/33，0 skipped，0 failures |
| P1 external error redaction | exact lifecycle/runtime tests | `PASS`：36/36，0 skipped，0 failures |
| P1 CLI no-MCP regression | CLI owner + AgentKernel regression | `PASS`：11/11，0 skipped，0 failures |
| P1 combined focused command | 8 exact suites | `PASS`：80/80，0 skipped，0 failures |
| Final test totals | settled runners | full SwiftPM 1362/16 skipped/0 failed；W10 23 + 3 + 102 全通过；不伪造跨重叠 runner 的“唯一总数” |
| Final release linkage/bundle | signed release artifacts | `ENVIRONMENT_LIMITED` |

本次最终源码实际执行的主命令：

```sh
Tests/MCPConformance/run-w10.sh
swift test --disable-sandbox
swift build --disable-sandbox
swift build --disable-sandbox --product intatis

swift test --disable-sandbox \
  --filter 'MCPToolSearchParityTests|MCPToolResultConversionTests|AgentRequestToolSnapshotTests|ResponsesToolSearchParityTests|MCPProtocolLifecycleTests|MCPRuntimeAuthorityTests|MCPCLIProcessOwnerTests|MCPNoAttachmentRegressionTests'

xcodebuild -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug \
  -derivedDataPath /private/tmp/intatis-mcp-mac-developerid \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build

xcodebuild -project Intatis.xcodeproj -scheme IntatisMacAppStore \
  -configuration Debug \
  -derivedDataPath /private/tmp/intatis-mcp-mac-appstore \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build

xcodebuild -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-mcp-ios \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build

INTATIS_SWIFT_BIN=/private/tmp/intatis-swiftly/toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift \
INTATIS_LINUX_SDKS_PATH=/private/tmp/intatis-swift-sdks \
INTATIS_LINUX_SDK_AARCH64=aarch64-swift-linux-musl \
INTATIS_LINUX_SDK_X86_64=x86_64-swift-linux-musl \
INTATIS_LINUX_VALIDATION_ROOT=/private/tmp/intatis-linux-mcp-validation \
scripts/validate-linux-cli.sh
```

最终产物补充证据：

- 工具链：Xcode 26.6 (17F113)、Apple Swift 6.3.3、macOS/iOS Simulator
  SDK 26.5；Linux 为 Swift 6.3.3 RELEASE static SDK
  `swift-6.3.3-RELEASE_static-linux-0.1.0`。
- DeveloperID Debug 主 dylib SHA-256：
  `518eb87c097a23189c01c575cbb3e5d7501496e077c5044d612700571cbb53dd`。
- App Store Debug 主 dylib SHA-256：
  `0b6cf6ecd6692ff88d5e71e447df022997b0c852fcde775afd8e3f5f65e39db7`。
- iOS Simulator Debug 主 dylib SHA-256：
  `10afba6a9471ca9652a19efe0a930b9160c727ad9838cc3eca440ee7c592d67c`。
- 三个 Apple build 均设置 `CODE_SIGNING_ALLOWED=NO`：它们是无分发签名的
  Debug 验证产物；linker-generated ad-hoc wrapper 不是 Developer ID 或
  App Store 签名。
- full SwiftPM 的 16 skips 为 1 个显式 opt-in Git smoke、13 个显式 opt-in
  browser smokes和 2 个仅允许 signed/unsandboxed host 的 Keychain CRUD；
  没有 MCP 源码测试 skip 或失败。
- Linux 双架构脚本只做静态交叉构建，最终明确输出
  `RUNTIME_EXECUTION=NOT_RUN host=Darwin/arm64 reason=cross_build_gate_only`；
  当前没有 bwrap、Docker、Podman、QEMU、Lima 或 Colima。

不能沿用早于最终源码状态的 Linux binary hash。

## 29. 环境限制与实现缺口分栏

### 29.1 当前已知环境限制

| 项目 | 当前边界 | 不能声称 |
|---|---|---|
| Darwin loopback | 外层 sandbox 可能对 bind/connect 返回 `EPERM`，测试只能 exact skip | 不能把 skip 写 pass，也不能写源码失败 |
| Linux runtime | 当前主机无 matching Linux VM/container、bwrap/ptrace runtime | static cross-build 不等于运行 |
| macOS Keychain | unsigned XCTest 不能完成真实 data-protection CRUD | query-shape test 不等于 signed App E2E |
| 第三方 MCP | 当前无用户指定的真实 stdio/HTTP server/account matrix | fixture 不等于第三方兼容 |
| OAuth | 当前无真实 AS/client registration/account/scope/resource | offline discovery/PKCE tests 不等于账号登录 |
| 发行 | 无 signed DeveloperID/App Store archive、notarization/final entitlements | unsigned Debug build 不等于发行 |
| Static SDK attestation | 有官方 checksum/SBOM/recipe/source/header identity | 无 single-archive signed source attestation/reproducible claim |
| 长期可靠性 | 有 bounded/fault/fixture tests | 无长期第三方 soak、机器掉电或全平台 kill matrix |

### 29.2 当前已确认实现缺口

- 当前源码审计与最终重跑：**0 个已确认冻结范围实现缺口，0 个原因不明项**。
- 最终验证过程中发现并修复了真实代码问题，包括 EventLog permission
  settlement 栈溢出、HTTP Session-ID-before-body、lazy transport
  negotiated-version 转发、tools-only 空 callback surface、CLI lazy owner、
  resource 结构清洗和 durable grant 等；所有相关回归与全量 runner 已在修复后
  重新通过。
- 剩余 6 个 `I-ENV` gate 只对应第 29.1 节明确列出的不可替代外部环境，不是
  实现缺口。

## 30. 项目文档回写要求

完整 MCP 系统的持久事实必须同步到：

- `docs/CURRENT_STATE.md`：当前实现、证据、风险。
- `docs/PROJECT_MAP.md`：targets、入口、测试。
- `docs/ARCHITECTURE.md`：runtime、authority、binding、transport、durable flow。
- `docs/DO_NOT_BREAK.md`：client-only、platform linkage、durable schema、
  exact binding、secret/network/stdio invariants。
- `docs/OPEN_SOURCE_REUSE.md`：vendored/derived/dependency provenance。
- `docs/TESTING.md`：完整 MCP validation commands 与环境边界。
- `docs/NEXT_TARGET.md`：不得继续保留“从 W0 开始”的过时目标。

截至本报告最终 QA：

- `PROJECT_MAP.md`、`ARCHITECTURE.md`、`DO_NOT_BREAK.md`、
  `OPEN_SOURCE_REUSE.md` 已同步当前 MCP 实现、平台和禁区。
- `CURRENT_STATE.md` 已同步最终 managed stdio 40/40、full SwiftPM、
  official/extended/W10、三套 Apple build 和双架构 Linux 静态产物结论。
- `TESTING.md` 已同步 External MCP client 完整验收入口、最终精确命令、计数、
  Apple 产物、Linux hashes 和运行环境边界。
- `NEXT_TARGET.md` 当前记录的是独立的 Codex-style Cowork model-history
  follow-up，不是 MCP W0–W10 的执行依据，也不表示 MCP 要重新开始。其独立
  backlog 是否继续由项目所有者另行决定。

本报告与上述项目文档共同按最终可见事实复核；唯一 MCP 规划、实现映射和证据
入口仍是本文件，没有拆出第二份 MCP 报告。

## 31. PROJECT_AUDIT_SUMMARY

本文件基于当前真实文件重新核对：

- 根 manifest 与 XcodeGen target graph。
- `Vendor/MCPClientSDK` manifest、UPSTREAM、PATCHES。
- `IntatisMCP`、`IntatisMCPStdio`、`IntatisCurlTransport` 源码。
- AgentKernel per-dispatch snapshot 与 EventLog host adapters。
- Protocol MCP payload/grant/result。
- macOS session/product/OAuth/import surfaces。
- CLI commands/product runtime/lazy owner。
- client-only、runtime authority、HTTP/OAuth、stdio、tool-search、resource、task、
  reliability 和 no-MCP tests。
- official scenario manifest、extended runner、W10 script、Linux script。
- CURRENT_STATE、PROJECT_MAP、OPEN_SOURCE_REUSE、TESTING。
- 2026-07-27 由官方 OpenAI Docs connector 取得的 Codex config reference。

报告采用源码为准，已经移除以下过时结论：

- “当前没有 MCP 客户端”。
- “只写规划、未改源码”。
- “stdio exact host/port 尚未实现”。
- “MCP 没有真实 Keychain/CLI store”。
- “AgentLoop 仍回查静态 registry”。
- “当前没有 MCP durable state”。
- “SDK 是普通 pinned dependency”。
- “下一步从 W0 开始”。

## 32. VALIDATION_RESULT

### 32.1 本报告自身

- `git diff --check`：通过。
- 最终临时占位与待结算状态标记扫描：均为 0。
- Markdown 围栏标记：12 行（6 组），成对闭合。
- 本地 Markdown 相对链接：102/102 解析到当前存在的文件或目录。
- 过时结论与 client/server 角色词扫描：只保留第 31 节中的“已移除旧结论”
  审计记录；没有把任何 callback、contributor、CONNECT gateway 或 conformance
  client 误写成 MCP Server。

### 32.2 产品最终验证

最终全量重跑已经结算：

- 实现：`IMPLEMENTED`。
- 31 门：25 `PASS` + 6 `I-ENV`。
- 结论：0 `UNKNOWN`，0 `IMPLEMENTATION_GAP`。
- full SwiftPM：1362 executed、16 explicit environment/opt-in skips、
  0 failures。
- W10：official 23/23、Tasks 3/3、7 focused suites 102/102。
- Apple：DeveloperID/App Store/iOS 三个当前源码 Debug build 均 exit 0。
- Linux：aarch64/x86_64 当前源码 static CLI 均通过静态/架构 gate，并发布本节
  所列新 hash；runtime 明确 `NOT_RUN`。

本结论不写 release-ready：签名、公证、真实第三方 server/OAuth、Linux 实机和
长期 soak 仍按 6 个 `I-ENV` gate 管理。

## 33. 后续升级与外部证据协议

后续 SDK、Codex、toolchain、transport 或产品接线变更时：

1. 重新执行第 25.4 节升级清单和第 28.3 节完整验证，不拆出第二份 MCP 报告。
2. 更新 31 门；外部环境仍缺失的保持 `I-ENV`，源码失败改
   `IMPLEMENTATION_GAP`，原因不明改 `UNKNOWN`，修复后重跑。
3. 写入新的 test totals、skips、failures、Apple/Linux binary hash，旧 hash
   不得沿用。
4. 保留 signed App、真实 OAuth、真实 Linux、第三方 server 和 attestation
   环境边界；不能因本地测试通过删除。
5. 同步 CURRENT_STATE、ARCHITECTURE、DO_NOT_BREAK、TESTING。

当前 W0–W10 已完成；下一项 MCP 工作只能是取得现存 `I-ENV` 的真实外部证据，
或在上游/产品需求变化后按本节执行完整升级，不重新开始 W0，也不另做简化客户端。
