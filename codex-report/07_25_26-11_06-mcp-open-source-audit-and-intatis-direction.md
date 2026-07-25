# Intatis MCP 开源源码调研与落地方向

> **状态更新（2026-07-25）**：本报告保留为固定版本的开源源码调研记录。它原先提出的“只规划第一阶段”已经被用户否决，凭据部分也误把当前 Intatis 描述成使用 OS Keychain。完整终态、正确的当前凭据事实和 W0–W12 实施规划，以 [`07_25_26-14_58-mcp-full-system-plan.md`](./07_25_26-14_58-mcp-full-system-plan.md) 为准。下文保留的 Phase 0–3 只代表当时的早期草案，不再是执行范围。

## MODEL_CHECK_RESULT

- 当前模型：Codex（GPT-5 系列）。
- 精确部署版本：运行环境未提供，无法确认。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 路径匹配预期：是。
- 写入前工作树已有较多未提交改动；本轮没有覆盖、回退或整理这些改动。

## FILES_WRITTEN

- `codex-report/07_25_26-11_06-mcp-open-source-audit-and-intatis-direction.md`

## 先说结论

我们现在要解决的，不是“Intatis 能不能保存一段 MCP 配置”，而是：

> Agent 能真正连接 MCP 服务器、看见它被允许使用的工具，并且能够实际调用；同时，工具版本、Agent 权限、本地进程、工作区范围、取消和退出都仍由 Intatis 控制。

我建议以 **Codex CLI 为主线**，但不要原样复制它的全部实现。

最合适的组合是：

- 用官方 Swift MCP SDK 处理 MCP 协议本身。
- 参考 Codex CLI 管理服务器、连接、工具目录和连接换代。
- 继续使用 Intatis 自己的 CapabilityLease、WorkspaceLease、PermissionEngine、durable tool ticket、EventLog 和生命周期管理。
- 从 Gemini CLI 借“服务器通知工具发生变化后，合并刷新”的做法。
- 从 OpenCode 借资源读取和结果大小控制的产品做法。
- 从 Grok Build 借“大量工具先搜索、再调用”的后期方案。

下面这个闭环仍然是将来验证工具调用主链的一个有用子集：

```text
本地 stdio MCP server
→ initialize
→ tools/list
→ Agent 看到获准工具
→ tools/call
→ 现有权限审查
→ 真实执行
→ EventLog 记录
→ 取消或退出时关闭 server
```

但它不再代表规划范围。远程 HTTP、OAuth、资源、提示词、完整 MCP client features、动态目录、多 Agent 管理面、Native Knowledge/RAG、迁移和完整测试都已经纳入新的总体规划。

## 我想解决什么问题

| 问题 | 现在如果不解决会怎样 | 希望做到的结果 |
|---|---|---|
| MCP 连接由谁长期持有 | 每轮 Agent 都可能重新连接，或者退出后遗留进程 | 一个 Code/Cowork 会话持有 MCP 总管；真实连接按工作区、网络、凭据等 authority 隔离；退出统一关闭 |
| 模型看到的工具与最后调用的工具可能不是同一版 | 服务器更新了同名工具后，模型按旧说明调用，却实际落到新工具 | 模型看到哪一版，就只能调用哪一版；对不上就拒绝 |
| 子 Agent 应该看到哪些 MCP 工具 | 如果默认继承全部工具，普通 worker 会意外获得主 Agent 的能力 | 默认一个都看不到；CapabilityLease 明确授予哪个服务器/工具，才看到哪个 |
| 本地 MCP server 是一个真实程序 | 它可能读取宿主文件、环境变量或访问网络 | 必须在 Intatis 的工作区和沙箱边界内运行，默认断网 |
| MCP server 会断线、重连和更新工具 | 旧工具可能继续留在模型目录里 | 断线后，新请求立即看不到旧工具；刷新完成后再发布一个完整新版本 |
| 调用仍要经过现有权限系统 | 如果 MCP 另开一条执行通道，会绕过现有安全和恢复合同 | MCP 工具与内置工具走同一套权限、票据、记录和取消流程 |
| MCP 输出可能很大或含敏感内容 | 大结果撑爆上下文，秘密进入日志或模型 | 限制大小、清洗秘密，过大内容保存成 artifact，只回摘要 |
| MCP 与 RAG 容易被混成一件事 | 会把“能读取 resource”误说成“已经有知识检索” | MCP 负责连接；Native Knowledge/RAG 负责索引、更新、搜索和引用；MCP knowledge server 只是两者之间的一种适配 |

最终希望得到一句很容易验证的话：

> 一个会话管理自己的 MCP runtime；每个 Agent 只看到租约给它的工具，不同 authority 不共用连接；模型看到哪版就只能执行哪版；所有调用继续走现有权限和耐久票据；本地 MCP 在沙箱里；断线马上从后续请求撤下旧工具；配置变化只影响下一版。

这里的“撤下”是指：以后发给模型的新请求中不再出现这些工具，不是只在界面上把服务器状态改成红色。

## 本轮读了哪些公开实现

| 项目 | 固定源码版本 | 主要用途 |
|---|---|---|
| Codex CLI | [`4c43465133428898aa84f0bfc02c306ed65fb66a`](https://github.com/openai/codex/tree/4c43465133428898aa84f0bfc02c306ed65fb66a) | 主参考：配置、连接、工具目录、连接换代、审批、关闭 |
| Gemini CLI | [`3818efbbfbf8ef029ef53a6ab1093db39971ce83`](https://github.com/google-gemini/gemini-cli/tree/3818efbbfbf8ef029ef53a6ab1093db39971ce83) | 工具/资源/提示词变化通知与合并刷新；子 Agent 独立目录 |
| OpenCode | [`5e2a6257b22c0141a20c281f4c2a641311afe5a5`](https://github.com/anomalyco/opencode/tree/5e2a6257b22c0141a20c281f4c2a641311afe5a5) | 资源读取、模板、结果截断和断线处理 |
| Grok Build | [`6e386420825bd44ae648c63e7c8cba12fcec9401`](https://github.com/xai-org/grok-build/tree/6e386420825bd44ae648c63e7c8cba12fcec9401) | 大工具目录的 `search_tool` / `use_tool` 模式 |
| 官方 Swift MCP SDK | `0.12.1` / [`a0ae212ebf6eab5f754c3129608bc5557637e605`](https://github.com/modelcontextprotocol/swift-sdk/tree/a0ae212ebf6eab5f754c3129608bc5557637e605) | Swift 原生协议、客户端、stdio/HTTP、OAuth 等基础能力 |
| MCP 规范 | [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25) | 生命周期、工具、资源、提示词、授权和通知的正式定义 |

这些版本只用于本报告的源码事实。未来真要复制、翻译或引入代码时，仍要重新固定版本、检查许可证和依赖，并按 Intatis 的开源复用规则记录来源。

## Codex CLI：最应该参考的主线

### 它已经做成了什么

Codex CLI 已经不是“预留了 MCP 接口”，而是有一套真实可用的 MCP 客户端：

```text
读取配置
→ 合并多个服务器来源
→ 启动 stdio 或连接 Streamable HTTP
→ MCP initialize
→ 读取工具目录
→ 筛选并暴露给模型
→ 审批
→ 调用工具
→ 限制结果大小
→ 关闭连接和本地子进程
```

具体来说，它已经包含：

- stdio 和 Streamable HTTP 两类服务器。
- enabled / required、启动超时、调用超时。
- 服务器级和工具级 allow/deny。
- OAuth、Keyring 和凭据存储选择。
- optional server 失败时保留其他健康服务器；required server 失败时让整个启动失败。
- 连接配置、OAuth 身份和连接状态都没变化时复用原连接。
- 每次刷新生成一套新的完整连接和工具目录，旧请求仍可持有旧连接。
- 本地子进程使用独立 process group，退出时先 TERM，仍未结束再 KILL。
- 工具很多时可以不全部直接暴露，而是延迟到工具搜索。
- MCP 返回结果和事件记录都有大小上限。

核心源码：

- [配置字段与校验](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/config/src/mcp_types.rs)
- [服务器来源合并](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/codex-mcp/src/catalog.rs)
- [每个 task/thread 的 MCP runtime](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/codex-mcp/src/runtime.rs)
- [连接启动、复用、状态和关闭](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/codex-mcp/src/connection_manager.rs)
- [工具目录与准备好的调用](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/codex-mcp/src/connection_manager/tool_catalog.rs)
- [调用版本的锁定](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/codex-mcp/src/binding.rs)
- [MCP 工具执行与审批](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/core/src/mcp_tool_call.rs)
- [stdio server 启动和进程清理](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/rmcp-client/src/stdio_server_launcher.rs)

### Codex 做得最好的地方

Codex 的关键思路是：**不要让一个正在执行的调用随着全局 MCP 目录变化而偷偷换对象。**

它的 `PreparedMcpCall` 会保存：

- 具体连接。
- 具体服务器配置。
- 具体工具说明。
- 具体目录版本。

取得这个对象后，如果目录已经换代，它会在副作用发生前拒绝旧调用；准备和调用过程中，刷新也不能插进来把它换掉。这部分设计和测试非常值得 Intatis 参考。

Codex 为这项工作留下了明确提交记录：

- [`Bind MCP calls to captured catalog revisions (#34588)`](https://github.com/openai/codex/commit/65f8bf68533332628b7fc213eade2a91d18d36ee)

### 但 Codex 仍有两个不能照抄的缺口

#### 缺口一：模型看到的版本，还没有一路锁到真正调用

Codex 在模型请求开始时，确实把当时的 MCP binding、工具清单和路由器保存进 `StepContext`：

- [`step_context.rs L12-L27`](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/core/src/session/step_context.rs#L12-L27)

但执行普通 MCP 工具时，handler 会先刷新，然后重新读取 runtime 的“当前 binding”，再按工具名查找：

- [`mcp_tool_call.rs L143-L147`](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/core/src/mcp_tool_call.rs#L143-L147)

这会留下一个小但真实的窗口：

```text
模型看到旧版 search
→ MCP server 刷新
→ 新目录里仍有一个同名 search
→ handler 从当前目录按名字找到新版 search
```

如果工具已经删除，Codex 会拒绝；但如果同名工具仍在，新的 schema、annotations、配置和连接有机会替代模型原先看到的那一版。

Intatis 应该补上这一点：

> MCP tool call 只能从本次模型请求冻结的 binding 中解析。连接失效或权限收紧时可以拒绝，但绝不能按名字回退到“现在最新的同名工具”。

#### 缺口二：本地 stdio MCP server 没自动进入 shell 那套沙箱

Codex 的本地 launcher 做了很多正确的进程管理：

- 清空环境后按白名单加入变量。
- 独立 process group。
- kill-on-drop。
- TERM / KILL 清理。

见：

- [`stdio_server_launcher.rs L245-L305`](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/rmcp-client/src/stdio_server_launcher.rs#L245-L305)

但它的 remote-executor stdio 路径明确设置：

- `sandbox: None`
- `enforce_managed_network: false`

见：

- [`stdio_server_launcher.rs L507-L520`](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/rmcp-client/src/stdio_server_launcher.rs#L507-L520)

也就是说，Codex 做好了“进程怎么启动、怎么收尾”，但不能由此推断这个 MCP server 自动获得了文件和网络隔离。

Intatis 不应该让 Swift SDK 或一个裸 `Process` 自己启动 server。它必须经过 Intatis 自己的：

```text
WorkspaceLease
+ Seatbelt
+ 默认断网
+ 明确环境变量
+ 敏感路径拒绝规则
+ process group
+ cancel/drain
```

### 另外两个需要补强的地方

普通 MCP server 发出的 `tools/list_changed`、`resources/list_changed`、`prompts/list_changed`，Codex 当前主要是记录日志，没有发现通用的自动重新读取并发布目录流程：

- [`logging_client_handler.rs L80-L90`](https://github.com/openai/codex/blob/4c43465133428898aa84f0bfc02c306ed65fb66a/codex-rs/rmcp-client/src/logging_client_handler.rs#L80-L90)

此外，Codex 的启动取消、task shutdown 和进程清理很清楚；但没有看到每次 `tools/call` 都把 Intatis 所需要的“调用级取消身份”一路明确传到 server。Intatis 实现时应把调用取消、超时和迟到结果处理写成明确合同。

## Gemini CLI：主要借它的刷新方式

Gemini CLI 最值得借的是：服务器连续发很多变化通知时，不马上反复刷新，而是合并成一次；如果刷新过程中又来了通知，再补一次尾部刷新。失败时也有受控重试。

- [变化通知、合并刷新和尾部刷新](https://github.com/google-gemini/gemini-cli/blob/3818efbbfbf8ef029ef53a6ab1093db39971ce83/packages/core/src/tools/mcp-client.ts#L388-L488)
- [完整刷新过程](https://github.com/google-gemini/gemini-cli/blob/3818efbbfbf8ef029ef53a6ab1093db39971ce83/packages/core/src/tools/mcp-client.ts#L490-L797)

它还让 subagent 拥有独立的工具、提示词和资源 registry，并能给某个 Agent 单独挂 MCP：

- [Agent 专属 MCP registry](https://github.com/google-gemini/gemini-cli/blob/3818efbbfbf8ef029ef53a6ab1093db39971ce83/packages/core/src/agents/local-executor.ts#L166-L188)
- [Agent 结束时解除 MCP](https://github.com/google-gemini/gemini-cli/blob/3818efbbfbf8ef029ef53a6ab1093db39971ce83/packages/core/src/agents/local-executor.ts#L734-L744)

但不能复制它的默认行为：未配置 `toolConfig` 时，subagent 会复制父级全部可复制工具，其中也可能包括 MCP 工具：

- [默认继承父工具](https://github.com/google-gemini/gemini-cli/blob/3818efbbfbf8ef029ef53a6ab1093db39971ce83/packages/core/src/agents/local-executor.ts#L247-L266)

Intatis 应该反过来：

```text
新 Agent 的 MCP 视图默认为空
→ CapabilityLease 明确授予 server/tool/resource/prompt
→ 才把对应内容加入该 Agent 的目录
```

`@permission-reviewer` 永远是空 MCP 目录。

Gemini 还会从 workspace 目录生成 MCP roots 并通知变化：

- [workspace roots](https://github.com/google-gemini/gemini-cli/blob/3818efbbfbf8ef029ef53a6ab1093db39971ce83/packages/core/src/tools/mcp-client.ts#L1838-L1900)

Intatis 可以借这个能力，但 roots 只能来自当前 WorkspaceLease，不能直接把应用看到的所有 workspace 都交给 MCP server。

## OpenCode：主要借资源产品形态

OpenCode 已经把 MCP resources 做成模型可用的显式工具：

- 列出资源。
- 列出资源模板。
- 读取资源。
- 对读取做权限检查。
- 对大结果做截断。
- 识别二进制 MIME。
- 对结果设置 10 MB 上限。

见：

- [`session/tools.ts L136-L385`](https://github.com/anomalyco/opencode/blob/5e2a6257b22c0141a20c281f4c2a641311afe5a5/packages/opencode/src/session/tools.ts#L136-L385)

MCP prompts 则被加载为用户可选命令，而不是静默塞入模型上下文：

- [`command/index.ts L105-L131`](https://github.com/anomalyco/opencode/blob/5e2a6257b22c0141a20c281f4c2a641311afe5a5/packages/opencode/src/command/index.ts#L105-L131)

这个产品边界适合 Intatis：

- resource 要显式 list/read。
- prompt 只由用户主动选择。
- 外部内容始终标为不可信内容，不能变成宿主指令。

OpenCode 断线后会移除 client、tools 和 instructions，并通知模型：

- [`mcp/index.ts L442-L471`](https://github.com/anomalyco/opencode/blob/5e2a6257b22c0141a20c281f4c2a641311afe5a5/packages/opencode/src/mcp/index.ts#L442-L471)

但有两点不适合复制：

- 本地 MCP 默认继承完整 `process.env`：[源码](https://github.com/anomalyco/opencode/blob/5e2a6257b22c0141a20c281f4c2a641311afe5a5/packages/opencode/src/mcp/index.ts#L340-L357)。
- OAuth credentials 和 client secrets 写进 owner-only 明文 JSON：[源码](https://github.com/anomalyco/opencode/blob/5e2a6257b22c0141a20c281f4c2a641311afe5a5/packages/opencode/src/mcp/auth.ts#L9-L31)。

Intatis 必须使用受控的 secret reference/token-store 接口，不能把 secret 原文写入普通配置、EventLog 或项目文档。当前源码实际使用 `ConfigSecretResolver` 和 Intatis owner-only auth/config 文件，并不调用 OS Keychain；OAuth token 后端应由 W0 比较安全性、GUI/CLI/Linux、备份和迁移后给出推荐，若会改变整体凭据产品政策再交给用户决定。

## Grok Build：等工具很多以后再借

Grok Build 没有把全部 MCP schema 一次性塞给模型，而是给模型两个稳定工具：

```text
search_tool  查找可能需要的工具
use_tool     按 server__tool 调用精确工具
```

- [用户文档](https://github.com/xai-org/grok-build/blob/6e386420825bd44ae648c63e7c8cba12fcec9401/crates/codegen/xai-grok-pager/docs/user-guide/07-mcp-servers.md#L194-L195)
- [`use_tool` 实现](https://github.com/xai-org/grok-build/blob/6e386420825bd44ae648c63e7c8cba12fcec9401/crates/codegen/xai-grok-tools/src/implementations/use_tool/mod.rs)

它还会限制模型直接收到的结果大小，并把完整结果另存。

这个方向很适合几十个服务器、几百个工具的情况，但不应该成为第一阶段。第一阶段直接暴露少量已获准工具更容易验证；目录真的变大后，再加搜索层。

Grok Build 的新 subagent 继承策略已有 All / None / Named / Except：

- [subagent MCP inheritance](https://github.com/xai-org/grok-build/blob/6e386420825bd44ae648c63e7c8cba12fcec9401/crates/codegen/xai-grok-shell/src/agent/subagent/mod.rs#L1350-L1394)

Intatis 只能采用 `None` 或显式 `Named` 的思想，不能采用默认 All。

## 官方 Swift MCP SDK：适合作为协议依赖，但不能接管宿主

官方 Swift SDK `0.12.1` 已实现 MCP 2025-11-25，包含：

- Client。
- stdio transport。
- Streamable HTTP。
- tools / resources / prompts / completions。
- cancellation / progress。
- roots / sampling / elicitation。
- OAuth 2.1、PKCE、discovery、refresh 和自定义 token storage。

它很适合让 Intatis 不必自行维护 JSON-RPC 和 MCP 协议细节。

但它不会替 Intatis 完成下面这些事：

- 不会替 Intatis 决定哪个 Agent 能看到哪个工具。
- 不会替 Intatis 生成 CapabilityLease。
- 不会替 Intatis 运行三层权限门。
- 不会替 Intatis 写 durable tool ticket 和 EventLog。
- 不会替 Intatis保证模型看到的工具版本与执行版本相同。
- 不会替 Intatis 把本地 server 放进 Seatbelt。

尤其是 `StdioTransport` 只包装输入/输出文件描述符，本身不负责启动进程：

- [`StdioTransport.swift`](https://github.com/modelcontextprotocol/swift-sdk/blob/a0ae212ebf6eab5f754c3129608bc5557637e605/Sources/MCP/Base/Transports/StdioTransport.swift)

这正好允许 Intatis 自己拥有 process launcher 和 sandbox，然后把受控的 stdin/stdout 交给 SDK。

需要提前确认的代价是：

- SDK 使用 Swift tools 6.1。
- 主 MCP target 依赖 `swift-system`、`swift-log`，Apple 平台还使用 EventSource。
- Intatis 根 `Package.swift` 当前是 Swift tools 5.9，且 v0.1 保持极少第三方依赖。

因此，官方 Swift MCP SDK 是首选协议依赖，但必须先做 SwiftPM、平台、传递依赖和许可证兼容 probe。

我的建议是允许，但只放进 macOS Code/Cowork/CLI 路径，不进入 iOS target；同时固定版本、检查所有依赖许可证、记录 provenance 并更新 `NOTICE.md`。

如果不允许这个依赖，也可以自研客户端，但完整目标已经包含 HTTP、OAuth、resources、prompts、roots、sampling、elicitation 和 MCP tasks；自研不应被误写成只实现四个方法的长期方案，维护成本会明显更高。

## Intatis 现在已经有的基础

Intatis 不需要从零开始。

### 1. 每轮已经冻结模型工具清单

[`AgentLoop.swift`](../Packages/IntatisAgentKernel/Sources/AgentLoop.swift) 在一次 turn 开始后先生成：

```swift
let specs = context.toolSpecs(registry)
```

然后在本轮循环中使用这份 `specs`。这已经比“每次工具调用都重新读取当前目录”更保守。

MCP 接入后要把这条规则继续加强：`specs` 对应的不只是 schema，还要保留同一份可执行 MCP binding。

### 2. 工具授权已经保存了大量精确事实

[`ToolProtocol.swift`](../Packages/IntatisTools/Sources/ToolProtocol.swift) 中的 `ToolRegistry` 已经记录并复查：

- registry version。
- 具体工具 ID。
- 工具说明和 schema 指纹。
- 标准化参数摘要。
- CapabilityLease。
- WorkspaceLease。
- Agent / task / attempt 等调用身份。

MCP 不应该绕过这套结构。它只需要把：

```text
MCP server ID
+ connection generation
+ tool schema hash
```

加入同一份授权身份。

当前 `ToolRegistry.adding()` 会保留原 `registryVersion`。未来动态加入 MCP 工具时，必须生成一个包含 MCP 目录版本的新 registry version，不能继续假装还是原来的静态目录。

### 3. Cowork 已经按 Agent 的租约构造工具目录

[`Orchestrator.swift`](../Packages/IntatisCowork/Sources/Orchestrator.swift) 的 `toolRegistry(for:agentID:includesTerminal:)` 已按 CapabilityLease 决定每个 Agent 能看到哪些工具。

MCP catalog 应先经过同一份 lease 过滤，再加入该 Agent 的 registry。不能先把服务器的所有工具交给模型，再寄希望于执行阶段拦截。

### 4. 本地终端已经有正确的宿主形态

当前 Code/Cowork managed terminal 是 session-owned，能够在 turn 取消、task terminal 和 runtime shutdown 时清理进程；macOS DeveloperID 路径还会使用 WorkspaceLease 和 Seatbelt。

MCP stdio server 不需要 PTY，但应该复用同样的宿主原则，新增一个受控的 pipe-process launcher：

- session owned。
- exact owner。
- exact workspace。
- sandbox first。
- default no network。
- process group cleanup。
- bounded output and timeout。

### 5. 目前缺少的是 session-owned MCP runtime

[`AgentRuntime.swift`](../Packages/IntatisAgentKernel/Sources/AgentRuntime.swift) 当前是一个包含静态 ToolRegistry 和 PermissionEngine 的值类型，不适合自己持有长连接。

建议增加独立、长期存在的 `McpRuntime`，由 Code/Cowork session runtime manager 持有：

```text
AppSessionRuntimeManager
└─ Code/Cowork session
   ├─ ManagedTerminalRuntime
   └─ McpRuntime
      ├─ server connections
      ├─ current catalog revision
      ├─ old in-flight bindings
      └─ shutdown/drain
```

不要让每个 `AgentLoop` 创建和销毁一套 MCP 连接。

## 建议的最终调用链

```mermaid
flowchart LR
    C["Session-owned McpRuntime"] --> R["完整目录版本"]
    R --> L["按 Agent 的 CapabilityLease 过滤"]
    L --> B["冻结本次模型请求的 MCP binding"]
    B --> M["模型看到获准工具"]
    M --> A["模型发起 tool call"]
    A --> V["核对同一 binding / schema / Agent / task / attempt"]
    V --> P["PermissionEngine"]
    P --> D["durable tool ticket"]
    D --> S["沙箱内 MCP server"]
    S --> E["清洗、截断、EventLog"]
```

必须一直成立的规则：

1. **一个会话持有一个 MCP 总管，不等于所有 Agent 共用一条连接。** WorkspaceLease、roots、读写、网络、凭据或 callback policy 不同，就必须使用不同连接/进程；只有 authority 完全相同时才可考虑显式复用。
2. **模型看到哪版就调用哪版。** 同名新版工具不能替换本次请求里的旧工具。
3. **权限收紧优先。** 旧 binding 可以因为连接死亡、server 被禁用或租约收紧而拒绝，但不能因为配置放宽而自动获得更多能力。
4. **MCP 不是旁路。** schema 校验、PermissionEngine、durable ticket、执行前复查和 EventLog 一项都不能少。
5. **server annotations 只是提示。** `readOnlyHint`、`destructiveHint` 等来自 server 自己，不能被当作真实授权事实。
6. **本地 server 默认断网。** 需要网络的 server 必须有显式 capability 和可审查的 host 范围。
7. **断线立即影响新请求。** 新 turn 不再看到旧工具；已经开始的调用只能用原 binding 完成或拒绝。
8. **刷新要整批发布。** 先在后台完成 tools/resources/prompts 的 staging，成功后一次性发布新 revision，不能让模型看到半新半旧目录。
9. **reviewer 永远没有 MCP。** 它不能因为主 Agent 安装了 MCP 就获得外部工具。
10. **取消要有明确终点。** timeout、turn cancel、task terminal 和 app shutdown 都要结束调用、忽略迟到结果并清理本地进程。

## 旧版分阶段草案（已被完整规划取代）

以下 Phase 0–3 只保留为历史记录，不能作为当前实施范围或“后续先留白”的依据。完整范围、模块、UI/CLI、OAuth、sampling、elicitation、MCP tasks、Native Knowledge/RAG、迁移和验收条件见新的[完整系统规划](./07_25_26-14_58-mcp-full-system-plan.md)。

### Phase 0：第一版可用闭环

只做：

1. 本地 stdio。
2. `initialize`、`tools/list`、`tools/call`。
3. session-owned `McpRuntime`。
4. Starting / Ready / Failed / Disabled 状态。
5. 每次模型请求冻结 exact MCP binding。
6. CapabilityLease 默认零 MCP；按 server/tool 显式授予。
7. reviewer 零 MCP。
8. 所有调用走现有 PermissionEngine、durable ticket 和 EventLog。
9. WorkspaceLease、Seatbelt、默认断网、环境白名单、敏感路径拒绝。
10. timeout、cancel、process group 和 session shutdown drain。
11. server 断线后，从新目录中原子移除它的工具。

第一阶段验收不是“UI 能显示一个绿色连接点”，而是：

> 一个真实 MCP server 在 Intatis 沙箱内启动；Agent 能调用它；未获租约的 Agent 看不到它；目录换代不能把旧调用改调到同名新工具；退出会话后没有遗留进程。

### Phase 1：远程连接和动态刷新

- Streamable HTTP。
- bearer secret reference。
- 通过抽象 `MCPTokenStore` 保存 OAuth 凭据；它是明确的 secret-bearing store，具体使用 OS Keychain、加密文件或 owner-only 文件须由兼容与风险验证决定，不能把 token 写进普通 catalog/EventLog/projection/log/export。
- tools/resources/prompts 三类 list-changed 通知。
- Gemini 式通知合并、尾部刷新和有限重试。
- required / optional server。
- 手动 reconnect 和有限退避。
- transport、认证身份或环境变化时才重连。
- 只改 allow/deny 时复用连接，只发布新的 Agent 视图。

### Phase 2：资源和提示词

- resources list/read/templates。
- resource 读取权限。
- MIME 和大小上限。
- 大内容存 artifact。
- 外部资源始终标为不可信。
- roots 只来自当前 WorkspaceLease。
- prompts 只能由用户主动选择，不能静默注入。

### Phase 3：大目录和当时设想的外部 RAG

- Grok 式 `search_tool` / `use_tool`。
- 大结果 spill 到 artifact。
- 只读 MCP knowledge server。
- 外部 RAG 通过该 server 接入。

这只是 MCP knowledge server 的接入方式，不等于完整 RAG。新的总体规划已经把 Native Knowledge 单独设计为有索引、generation、freshness、search/read 和 citation 的系统；外部 MCP knowledge server 是可选适配器。

当时设想的最简单边界是：

```text
Intatis 负责 MCP、权限、租约和记录
→ 某个只读 MCP server 负责检索
→ 返回带来源的片段或 artifact
```

这样可以先换不同检索实现，而不改 AgentKernel。

## 旧草案中的早期实施边界

以下条目只说明当时设想的早期实现顺序，不表示完整系统不做这些能力：

- 不一次实现整个 MCP 规范。
- 不同时做 stdio、HTTP、OAuth、resources、prompts 和 RAG。
- 不给子 Agent 默认继承父 Agent 的 MCP。
- 不给 permission reviewer 任何 MCP。
- 不把 server annotations 当成 PermissionEngine 的授权结论。
- 不让 Swift SDK 自己决定怎么启动本地进程。
- 不让本地 server 继承完整 `process.env`。
- 不把 bearer token、OAuth secret 或环境变量原文写进 EventLog。
- 不把 Codex Rust MCP client 作为常驻 helper 塞进 Apple 产品。
- 不因为 MCP server 连接失败而退回裸 shell 或扩大 workspace 范围。
- 不在第一阶段做 `search_tool` / `use_tool`；工具目录足够大时再加。

## 复用边界

| 来源 | 建议方式 | 原因 |
|---|---|---|
| 官方 Swift MCP SDK | `dependency`，待审批 | 用成熟 Swift 实现处理协议和 transport，Intatis 保留宿主权 |
| Codex catalog / binding / connection tests | 先作为 `reference` | 设计最接近目标，但 Rust runtime 和 Codex 业务耦合较深 |
| Codex 某些算法若逐行翻译 | 标为 `derived` | 必须固定 commit、记录来源并更新 `NOTICE.md` |
| Gemini 的 list-changed 合并刷新 | `reference` | 借状态机和测试场景，不需要复制 TypeScript runtime |
| OpenCode 的资源读取产品形态 | `reference` | 借交互和限制，不复制环境/凭据做法 |
| Grok 的 search/use | `reference`，后期 | 只在目录变大后需要 |

本轮没有复制、翻译或引入任何上游源码，也没有修改 `NOTICE.md`。

## 早期闭环测试子集

这不是完整测试矩阵。完整规划已经补齐配置、HTTP/OAuth、resources/prompts/roots、sampling/elicitation/tasks、生命周期、Knowledge/RAG、迁移、压力和真实 E2E。

| 场景 | 必须看到的结果 |
|---|---|
| 一个正常 server、一个失败 server | optional 失败不影响正常 server；required 失败按配置阻止启动 |
| 同名工具换代 | 旧模型请求不能改调新版同名工具 |
| server 删除工具 | 新 turn 立即看不到；旧调用完成或明确拒绝 |
| 通知风暴 | 合并刷新，最终只发布一份完整目录版本 |
| 断线 | 新 turn 立即撤下该 server 工具，不保留僵尸目录 |
| 子 Agent 默认权限 | 看不到任何 MCP |
| 子 Agent 获得指定 lease | 只看到被授予的 server/tool |
| permission reviewer | 始终看不到 MCP |
| 本地进程环境 | 不含未允许 secret 和完整宿主环境 |
| 默认网络 | server 不能联网；显式授予后只允许批准范围 |
| roots | 与当前 WorkspaceLease 完全一致 |
| 权限到执行 | binding、schema、参数、Agent、task、attempt 前后一致 |
| 取消和超时 | 调用停止，迟到响应无效，本地进程按合同清理 |
| App/session shutdown | 所有连接和 process group 被 drain，不遗留 server |
| 大结果 | 截断或保存 artifact，不撑爆模型上下文 |
| 敏感结果 | SecretScanner 生效，EventLog 不出现 secret 原文 |
| resource 读取 | 有权限、取消、大小和 MIME 检查，内容标为不可信 |
| 配置变动 | allow/deny 只生成新视图；transport/auth/env 变化才重连 |

## 原报告遗漏的决定

官方 Swift MCP SDK `0.12.1` 是否作为 macOS Code/Cowork/CLI 的新依赖，仍需要兼容和许可证 probe 后确认。

我的建议：**允许**。

条件是：

- 不进入 iOS target。
- 固定版本。
- 核对 Apache-2.0/MIT 许可证变化和全部传递依赖。
- 记录 provenance。
- 更新 `NOTICE.md`。
- SDK 只负责协议和 transport。
- 进程、沙箱、权限、租约、版本绑定、凭据和 EventLog 继续由 Intatis 负责。

它不是唯一决定。当前还需要用 W0 证据确定 MCPTokenStore 后端、legacy SSE、OAuth callback、App Store 远程能力、sampling 费用/模型策略和 Knowledge 数据来源。跨 Agent 连接默认不复用，已经不再作为待选项。完整列表见新的[完整系统规划](./07_25_26-14_58-mcp-full-system-plan.md)。

## PROJECT_AUDIT_SUMMARY

本轮核对到的 Intatis 接入点：

- [`AgentLoop.swift`](../Packages/IntatisAgentKernel/Sources/AgentLoop.swift)：每个 turn 已先生成一份稳定的模型工具清单。
- [`AgentRuntime.swift`](../Packages/IntatisAgentKernel/Sources/AgentRuntime.swift)：当前持有静态 registry，不适合作为 MCP 长连接 owner。
- [`ToolProtocol.swift`](../Packages/IntatisTools/Sources/ToolProtocol.swift)：已有 registry version、schema 指纹、参数摘要、CapabilityLease、WorkspaceLease 和调用身份复查。
- [`Orchestrator.swift`](../Packages/IntatisCowork/Sources/Orchestrator.swift)：已有按 Agent lease 构造工具目录的正确入口。
- [`CodeViewModel.swift`](../Apps/IntatisMac/Sources/CodeViewModel.swift)：已有 session runtime shutdown 和 terminal drain 形态。
- 当前 managed terminal 已证明 Intatis 能给 Agent 一个真实进程环境；MCP 应增加受控 pipe-process runtime，而不是另开一条裸进程路径。

## VALIDATION_RESULT

- `git diff --check`：通过，没有 tracked diff whitespace error。
- `rg -n '[[:blank:]]+$' <report>`：无匹配，报告没有行尾空白。
- Markdown fenced code block：22 个，成对闭合。
- 本地相对引用：6 个唯一文件，包含 5 个源码文件和新的完整规划，全部存在。
- GitHub 源码引用：34 个唯一 URL，全部固定到本报告列出的 commit，或固定到报告单列的 Codex MCP binding commit。
- `git status --short`：确认本报告为新增未跟踪文件；写入前已经存在的业务源码、测试、文档和另一份报告改动均保持原状。

未运行构建或测试，因为本轮只新增调研报告，没有修改业务源码、配置、构建脚本或测试源码。

## UNCERTAINTIES

- 官方 Swift MCP SDK `0.12.1` 的 Swift 6.1 与依赖引入是否符合 Intatis 当前版本和零/少依赖政策，需要用户决定并在实施前实际做一次 package 兼容验证。
- OAuth 登录窗口、callback、多账号和 token-store 已进入完整规划，但具体产品选择仍需确认。
- 远程 Streamable HTTP 已进入完整终态，不再作为“是否规划”的问题。
- Codex、Gemini、OpenCode 和 Grok Build 都在持续变化；实现开始前需要重新固定上游 commit。
- 本轮是固定公开源码的只读审计，没有运行这些上游 CLI，也没有做真实 server、断线、App kill 或跨重启验证。

## NEXT_RECOMMENDED_ACTION

先评审并冻结新的[完整系统规划](./07_25_26-14_58-mcp-full-system-plan.md)，不要直接把本报告的旧 Phase 0 当作当前任务。规划确认后先执行 W0 的 SDK、许可证、平台、网络和凭据事实验证，再按完整的 W1–W12 依赖顺序拆解源码任务。
