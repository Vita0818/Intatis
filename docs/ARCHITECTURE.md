# ARCHITECTURE

最近自查日期：2026-07-03

## 总体架构

Intatis 是 clean-room 本地 AI 工作区，三个产品面：Chat（普通多模态对话）/ Code（单 agent 本地工作区）/ Cowork（多 agent 本地工作区协作）。macOS 全量；iOS chat 子集。

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
Chat composer -> GoalInputParser (/goal metadata) -> ChatLoop.send()
  -> buildHistory() from EventLog
  -> ProviderRegistry resolves selected provider/model from GUI catalog
     + current chat selection override (provider baseURL + chatEndpoint)
  -> append userMessage -> provider.stream
  -> message_delta / message_completed -> turnStats
（无工具、无权限、无工作区）
```

### Code 链路（单 agent，macOS 全量）

```text
Code composer -> GoalInputParser (/goal metadata) -> AgentLoop.send()
  -> append userMessage -> agent_status(thinking)
  -> ContextBuilder.initialMessages(history + cleaned user text)
  -> provider.stream -> toolCalls -> PermissionEngine -> tool execution
  -> message_delta / message_completed / tool events -> EventLog
```

### Cowork 链路（多 agent 编排，macOS 全量）

```text
CoworkViewModel -> GoalInputParser + CoworkMentionRouter -> Orchestrator (actor)
  -> AgentRegistry / MessageBus(log:, mediator:) / PermissionEngine
  -> attach(agent) -> log agent_attached
  -> CLI /auto 可创建保留子 agent @permission-reviewer（read_only + no tools）
  -> send(text, to:@mention, userMessage metadata) -> 路由到目标 agent
  -> 为每次 run 构建 AgentLoop + BusMessenger + OrchestratorManager
       coordinator(canCoordinate=true) -> ToolRegistry.standard + [AskAgent/Spawn/List/Remove]
       worker -> ToolRegistry.standard 仅
  -> AgentLoop.send() 循环（maxIterations 默认 50）
       ContextBuilder.initialMessages (system + priorHistory 投影 + user)
       -> provider.stream -> message_delta
       -> toolCalls -> runTool -> PermissionEngine.decide
            askUser -> PermissionResponder
                default -> UI 卡片/终端确认
                CLI /auto -> AgentPermissionResponder -> @permission-reviewer no-tool JSON decision
       -> ToolObservation 回填 -> 重复直至无 tool call
  -> 每次状态变更 append 到 EventLog
MessageBus.deliver -> Mediator.mediate
  -> SecretScanner.containsSecret -> block
  -> content.count > maxChars(4000) -> block "send a summary"
  -> ForwardingReviewer(可选)
  -> .forward (log agent_to_agent_message + permission_review allow)
```

关键不变量：
- 两级层级，无递归 spawn；worker 默认无 coordinator 工具。
- `@main` agent 不可被 remove。
- `@permission-reviewer` 是自动权限审查保留身份：只能由 `/auto` 创建、`/default` 移除；不能作为普通 send/delegate/message/ask 目标，也不会暴露给 `list_agents` 工具。
- MessageBus 是唯一投递路径；Mediator 默认转发摘要不转发原始字节。
- 任何 model tool_call 到执行都必须过 PermissionEngine，无旁路。
- 自动权限审查不启动嵌套 AgentLoop；审查者 provider 只收到无工具 JSON 判断请求。`DeterministicPolicyGate` hard deny 仍在审查者之前终局。

### 多模态链路

```text
MultimodalService.generateImage/transcribe/generateVideo(轮询 job)
  -> provider 调用 -> ArtifactStore 写入
  -> log: artifact_added / artifact_progress
```

## 数据模型

| 类型 | 职责 | 持久化方式 | 关键字段约束 |
|---|---|---|---|
| `Envelope` | 事件信封 | JSONL 一行一个 | `seq` 单调递增；`v:1`；18 种 `type` |
| `Event` | 事件 payload 联合 | 随 Envelope | 追加演进；replay 时不可解码行跳过 |
| `UserMessagePayload` | 用户输入事件 | 随 `user_message` | `text` 是清洗后送入模型的文本；`tags` / `goal` 是 v0.12 追加的可选元数据；`to` 可记录 Cowork 目标 agent；旧 JSONL 缺字段必须继续解码 |
| `Agent` | agent 值类型 | 内存 | `coordinationDepth` 是当前 coordinator 工具兼容 fuse；默认 profile `.reviewed`；自动权限审查者固定 `read_only` + `coordinationDepth=0` |
| `Capability` | provider 能力枚举 | 配置 | chat/tool_calling/vision/realtime/audio/image/video/embedding |
| `PlatformProfile` | 平台能力信封 | launch-time | `.iOS`（最受限）/`.macAppStore`/`.macDeveloperID`；`current` 默认 `.iOS` |
| `PermissionProfile` | 每 agent 模式 | agent | manual/reviewed/autopilot/read_only/locked；硬 DENY 优先 |
| `Artifact` / `ArtifactRef` | blob + 索引 | blobs/<id>.<ext> + index.json | ISO-8601；pretty JSON |
| GUI provider catalog | GUI provider/model 设置 | UserDefaults `intatis.providerCatalog.v1` + secret ref；当前聊天选择 `intatis.providerSelection.v1`；macOS 可由 `INTATIS_CONFIG` / `~/.config/intatis/opencode.json` / `~/.config/intatis/intatis.json` JSON/JSONC 覆盖，也可直接读取 `~/.config/opencode/opencode.json`；旧 `config.json` 兜底兼容读取 | provider 持久化 `baseURL` / `chatEndpoint` / secret ref；model 持久化 id / 展示名；高级 JSON 推荐 OpenCode-compatible `model` + `enabled_providers` + `provider` map；聊天页切换只改当前选择，不改写外部 JSON；API key 不得进 UserDefaults；旧 `intatis.baseURL`/`intatis.model` 仅迁移/兼容 |

## 同步 / 通信机制

- **进程内**：v0.1 内核全进程内运行。`Orchestrator`/`EventLog`/`MessageBus` 均为 `actor`。
- **JSON-RPC 2.0 词汇**已定义（`JSONRPC.swift`：Command→request、Envelope→event notification），但**尚未挂传输**。未来 `intatis agent --stdio` / `intatis daemon` 是规划中管道。`UNKNOWN` — 当前无 out-of-process 传输实现。
- **Provider 线协议**：OpenAI 兼容 HTTP/SSE（chat completion endpoint streaming）。`WireFormat.openai` 是唯一 shipped 格式；`ProviderEndpoint.chatEndpoint` 可覆盖默认 `baseURL + /chat/completions`，保留 `baseURL` 给 image/transcription 等后续路径。
- **Goal 输入命令**：`GoalInputParser` 在 UI/ViewModel 层识别行首 `/goal`，要求后面有目标文本；解析成功后把命令前缀剥离，provider/agent 只收到清洗后的目标文本。事件层通过 `UserMessagePayload.tags = ["Goal"]` 与 `goal` 保存目标元数据，`ConversationProjection` / `CodeProjection` 将其投影到 `ChatMessageView` / `CodeItem`，SharedUI 与 macOS Chat bubble 显示 Goal 标签。Cowork 会在 mention 路由前后各解析一次，因此支持 `/goal @Agent ...` 与 `@Agent /goal ...`。
- **GUI provider catalog**：macOS `AppConfig` 与 iOS `IOSConfig` 使用 UserDefaults 主键 `intatis.providerCatalog.v1` 保存两层配置。第一层 provider 存 `id` / 展示名 / `baseURL` / `chatEndpoint` / secret ref 元数据；第二层 model 存模型 id / 展示名。Chat 对话页提供 provider 分组的模型菜单；切换后写入 `intatis.providerSelection.v1`，重建 `ProviderRegistry` 并更新 `ChatViewModel`，下一条请求使用新 provider/model。设置页编辑 Base URL 时自动生成 Chat endpoint；编辑 Chat endpoint 时清洗 `/chat/completions` 后缀回填 Base URL。旧 `intatis.baseURL` / `intatis.model` 仍作为迁移来源与兼容镜像。
- **macOS advanced config**：macOS GUI 启动时先检查 `INTATIS_CONFIG` 指定文件；未设置时按顺序检查 `~/.config/intatis/opencode.json` / `opencode.jsonc`、`~/.config/intatis/intatis.json` / `intatis.jsonc`、`~/.config/opencode/opencode.json` / `opencode.jsonc`、app support 的 `opencode.json` / `intatis.json`，最后才兜底读取旧 `config.json` / `config.jsonc`。找到可解码的 JSON/JSONC 后覆盖 UserDefaults provider catalog；聊天页当前选择覆盖层仍可覆盖 JSON 顶层 `model`，且不会改写外部 JSON。设置页的 Open JSON 按钮会打开当前生效的 OpenCode-compatible 文件或 `INTATIS_CONFIG` 指定文件；若只发现旧 `config.json`，会从当前 catalog 生成新的 `~/.config/intatis/opencode.json` 模板并优先打开。写入用户 config 失败时回退到 app support `opencode.json`。创建的模板来自当前 provider catalog，只输出 OpenCode-compatible `$schema` / `enabled_providers` / `model` / `provider.<id>.npm` / `name` / `options.baseURL` / `options.apiKey` / `models`，不包含明文 API key。支持兼容读取旧 direct `providers` 数组，也兼容读取 Intatis 扩展字段 `chatEndpoint` / `apiKeySource`；推荐新配置使用 `provider.<id>.options.baseURL`、`options.apiKey`（OpenCode 原生明文、`{env:NAME}` 或 `{file:path}` 均可由真实请求懒加载）、`models`，以及顶层 `model` 形如 `<provider>/<model-id>`。支持 OpenCode 的 `enabled_providers` / `disabled_providers` 过滤；`disabled_providers` 优先。省略 `options.apiKey` 时默认使用 Keychain；Keychain miss 时按 provider id 尝试 `~/.local/share/intatis/auth.json`、`~/.local/share/opencode/auth.json` 与当前 OpenCode-compatible config。
- **CLI Cowork auto permission review**：`intatis cowork` 的 Cowork REPL 支持 `/auto` 与 `/default`。`/auto` 用当前 default model 创建 `@permission-reviewer`，并把 Orchestrator 当前 responder 切到 `AgentPermissionResponder`；该 responder 汇总全局 `EventLog` 摘要、active agent roster、近期 user/task/tool/message/permission 事件，把当前 `PermissionRequestPayload` 包在 untrusted block 中发给审查者 provider。审查者必须返回 `{"decision":"allow|deny|ask_user","risk":"low|medium|high","reason":"..."}`；`ask_user`、不可解析输出或 provider error 均回退到原 responder。`/default` 移除审查者并恢复默认人工确认。GUI UI 未实现。

示例（不含明文 secret）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "enabled_providers": ["OpenRouter"],
  "model": "OpenRouter/deepseek/deepseek-chat",
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
    }
  }
}
```

## 安全机制

### 凭据存储
- `KeychainStore`（GUI）：generic-password item，service `com.intatis.app`/`com.intatis.ios`。迁移默认 provider 使用 account `default-openai`；新增 provider 使用独立 account（当前形如 `provider-<provider-id>`）。GUI 保存 API key 时默认写 Keychain。
- `KeychainRef` 现在是兼容命名的 secret ref，可指向 `keychain` / `environment` / `file` / `authFile`。macOS `authFile` 默认先查 `~/.local/share/intatis/auth.json`，再兼容查 `~/.local/share/opencode/auth.json` 与 OpenCode-compatible config 的 `provider.<id>.options.apiKey`；也可用 `INTATIS_AUTH_FILE` 覆盖；iOS 默认落在 app container Application Support。UserDefaults catalog 只存 secret ref 元数据，不存 API key；启动态和设置页用不返回 `kSecReturnData` 且跳过认证 UI 的存在性检查判断 key 是否存在，设置页仅用圆点占位表示已有 key；`KeychainSecretResolver` 仅在真实 provider 请求时懒加载 secret，并按 source/service/account 做进程内缓存。

### 工作区边界
- `PathConfinement.resolve`：拒 `..` 遍历与越界绝对路径。Tools 执行与权限门均使用。

### 权限 3 层门
1. `DeterministicPolicyGate`（纯函数、模型无关、runs first、`deny` 终局）：locked→deny；敏感路径→deny；路径越界→deny；read_only 下网络→deny；readOnly side-effect→allow；destructive→ask；exec→evaluateShell；write→evaluateWrite。
2. `ModelPermissionReviewer`（模型评审）：只见 gate `pass`；只能收窄为 deny/ask，**不能**覆盖硬 deny。
3. `PermissionEngine`（组合）：`pass` 且无 reviewer → `askUser`。

CLI `/auto` 不改变上述终局规则；它只替换 `askUser` 的回答者。因为 hard deny 不会产生 `permission_request`，`@permission-reviewer` 无法覆盖硬 deny。审查记录写入 `permission_review`，最终执行仍以 `permission_resolved` 为准。

### 秘密拦截
- `SecretScanner`：敏感路径/basename/扩展名、秘密内容标记（`-----BEGIN`、`PRIVATE KEY`、`AKIA`、`sk-`、`ssh-rsa`、`xoxb-`、`ghp_`、`AIza`…）、受保护配置路径。
- `Mediator`：agent 间转发时拦截秘密 + 超长原始转储（>4000 字符要求发摘要）。

### Sandbox / Entitlements
- `IntatisMac.AppStore.entitlements`：`app-sandbox=true`、`network.client=true`、`files.user-selected.read-write`、`files.bookmarks.app-scope`。**无 `run_shell`**。
- `IntatisMac.DeveloperID.entitlements`：非 sandbox、Hardened Runtime。

## 模式开关 / 内核切换

无 Rokurics 式新旧内核开关。Cowork 架构原则见 `docs/COWORK_PRINCIPLES.md`——当前实现与原则的差距见该文档"当前已知 Cowork 问题"。

## 与文档/源码的关系

- 仓内根 `ARCHITECTURE.md`（draft-0, 2026-06-11，中文）描述 Intatis 内核/Cowork 设计。本目录 `docs/ARCHITECTURE.md` 据实际源码重写并与之对照。
- Cowork 设计细节见 `docs/COWORK_AGENT_ARCHITECTURE.md` 等 7 个 COWORK_* 文档；原则提炼见 `docs/COWORK_PRINCIPLES.md`。
