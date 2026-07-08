# ARCHITECTURE

最近自查日期：2026-07-07

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
macOS root sidebar or iOS toolbar history/New Chat -> selected SessionID -> per-session EventLog
  -> Chat composer -> GoalInputParser (/goal metadata) -> ChatLoop.send()
  -> buildHistory() from current EventLog
  -> ProviderRegistry resolves selected provider/model from GUI catalog
     + current chat selection override (provider baseURL + chatEndpoint)
  -> append userMessage -> provider.stream
  -> message_delta / message_completed -> turnStats
  -> GUI folds TurnStatsProjection -> compact composer-local latest-turn stats
（无工具、无权限、无工作区）
```

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

### Agent 文档/媒体工具链路（v0.16，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (DeterministicPolicyGate -> optional reviewer -> responder)
  -> ToolContext(workspaceRoot, shell, imageGenerator)
  -> DocumentMediaTools / FileTools / ShellGit
  -> ToolObservation(output, changedFiles)
  -> tool_result event -> CodeProjection / CoworkProjection / CLI
```

新增标准工具：
- `read_pdf`：用 PDFKit 抽取 PDF 文本和页数信息，支持 1-based 页码范围；扫描件若无可抽取文本，会提示使用 OCR/版面重建工具。
- `edit_pdf_pages`：PDF 页面级 `extract` / `split`，输出路径仍受 `PathConfinement` 限制。
- `reconstruct_document_image`：把文档照片、扫描件或 PDF 交给已安装的外部成熟后端，当前 wrapper 支持 `docling`、`marker_single`、`tesseract`，输出 Markdown/HTML/text。
- `compile_latex`：调用已安装的 `tectonic`、`latexmk`、`xelatex` 或 `pdflatex` 编译 `.tex`，并确认 PDF 产物存在。
- `generate_image`：通过 `ImageGenerationToolService` 调用现有 provider image capability，将返回图片写入工作区。

设计取舍：
- 当前不把 Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers 复制进仓库，也不新增 SwiftPM 第三方依赖；它们是可安装后端或后续集成方向。
- `reconstruct_document_image` / `compile_latex` 是 shell-backed 工具，仍受平台 shell 能力和权限门约束；AppStore sandbox 无 `run_shell` 时不得绕过 `DeterministicPolicyGate`。
- Cowork coordinator lease 可用全部文档/媒体工具；worker 默认只获得只读 `read_pdf`，不会默认获得页面编辑、LaTeX 编译或生图能力。

### Agent 网络/浏览器工具链路（v0.16，Code / Cowork / CLI）

```text
provider tool_call -> AgentLoop schema validation
  -> PermissionEngine (exec + network permission)
  -> web_fetch: URLSession HTTP(S)
  -> browser_*: ToolContext.shell -> installed Node.js
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
- 浏览器 profile、cookies、localStorage、下载目录、state、history metadata 放在 workspace `.intatis/browser/` 下：`profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json`、`history.jsonl`。`state/<profile>.json` 保存当前页面 metadata 以及 Intatis 管理的 `navigationStack` / `navigationIndex`，供跨工具调用的 back/forward 使用；这些 profile 可能包含登录态，不写入 OS Keychain，不应作为普通 artifact 展示、提交或跨 agent 原文转发；`browser_profiles` / `browser_history` 只暴露受控 metadata，`browser_profiles` 只检查少数 Chromium active/lock marker 的存在性来提示可能有浏览器进程占用，不读取 marker 内容或 profile 数据库；页面摘要可暴露交互控件定位 metadata，但不得打印 cookies/localStorage/profile DB、密码/token 或当前文本输入值。
- 同一进程内，Playwright/CDP-backed `browser_*` 命令按 workspace profile 路径串行化，避免多个 agent 同时打开或写入同一 persistent profile、state/history 或导航栈；不同 profile 不做全局互斥，仍可并行执行。`browser_back` / `browser_forward` 的目标 URL 选择和真实浏览器执行必须处在同一 profile 临界区内。
- `web_fetch` 是 `.network` 工具；`browser_profiles` / `browser_history` / `browser_downloads` 是 `.readOnly` metadata 工具；`browser_profile_delete` 是 `.destructive` 工具；`browser_diagnostics` 是 `.exec` 但不标记 network risk；页面导航、headed handoff、刷新、前进/后退、交互、表单提交、滚动、等待、截图、上传、下载和搜索类 `browser_*` 是 `.exec` 且 `risksNetwork == true`。`DeterministicPolicyGate` 必须先检查 exec/shell/AppStore/read_only 边界，再进入网络审批，避免 shell-disabled 环境被 network ask 误放行。
- Cowork coordinator lease 可用 `browse_web`；worker 默认不获得 `web_fetch` 或任何 `browser_*` 工具。

### Cowork 链路（多 agent 编排，macOS 全量）

```text
Cowork session open/new -> CoworkProjectSettingsStore loads/saves per-session project settings
  -> restore workspace bookmarks + bootstrap @main through agent.attach if needed
  -> CoworkViewModel -> GoalInputParser + CoworkMentionRouter -> Orchestrator (actor)
  -> AgentRegistry / MessageBus(log:, mediator:) / PermissionEngine
  -> attach(agent) -> log agent_attached
  -> CLI /auto 可创建保留子 agent @permission-reviewer（read_only + no tools）
  -> GUI send(text) 默认路由到 @main；显式 @mention 仅作高级定向入口
  -> 为每次 run 构建 AgentLoop + BusMessenger + OrchestratorManager
       coordinator(canCoordinate=true) -> lease-based registry with workspace/doc/media/browser + coordination tools
       worker -> lease-based registry with read/list/search/read_pdf + reply/request-delegation tools only
  -> AgentLoop.send() 循环（maxIterations 默认 50）
       ContextBuilder.initialMessages (system + priorHistory 投影 + user)
       -> provider.stream -> message_delta
       -> toolCalls -> runTool -> PermissionEngine.decide
            askUser -> PermissionResponder
                default -> UI 卡片/终端确认
                CLI /auto -> AgentPermissionResponder -> @permission-reviewer no-tool JSON decision
            ask_agent / delegate_task -> enqueue TaskContract -> scheduler runs target agent
                -> MessageBus.deliver + Mediator returns child answer/report to caller as ToolObservation
       -> ToolObservation 回填 -> 重复直至无 tool call
       -> task_completed/task_failed records optional TaskReportPayload
       -> task-scoped tool-spawned child agent is auto-detached after it becomes idle
  -> 每次状态变更 append 到 EventLog
  -> GUI folds CoworkProjection + TurnStatsProjection
  -> macOS Cowork inspector shows only Git status, active agent status icons, and goal table
MessageBus.deliver -> Mediator.mediate
  -> SecretScanner.containsSecret -> block
  -> content.count > maxChars(4000) -> block "send a summary"
  -> ForwardingReviewer(可选)
  -> .forward (log agent_to_agent_message + permission_review allow)
```

关键不变量：
- 用户默认只与 `@main` 对话；`@main` 是项目负责人 agent，持有 coordinator capability lease，可读写主 workspace 并通过工具自动创建、委派、移除子 agent。
- 动态层级通过 scheduler/message bus/task graph 表达，不允许 `AgentLoop` 同步递归调用另一个 `AgentLoop`。子 agent 默认是 worker，无 coordinator 工具；只有 `spawn_agent(canCoordinate:true)` 或未来显式 capability lease 授予时，子 agent 才可继续创建/调度下级 agent。
- `ask_agent` / `delegate_task` 工具必须通过 scheduler 运行目标 agent，并通过 `MessageBus.deliver` / `Mediator` 把子任务结果返回给调用方；`ask_agent` 保持兼容的直接答案，`delegate_task` 返回结构化 Task Report tool observation。调用方不应只收到 queued ack，也不得通过直接嵌套 `AgentLoop` 取得结果。
- `spawn_agent` 由当前 coordinator agent 发起并记录 `requestedBy` ownership。tool-spawned、任务域内的子 agent 在无 pending/running/issued task 和 pending mailbox message 后由 Orchestrator 自动 detach；用户/GUI 手动 attach 的 agent 不参与该自动回收。
- Cowork session 可绑定一个或多个用户选择的工作目录；per-session settings 只保存路径/bookmark/model/profile/token-budget metadata，不保存 secret，真实访问仍依赖 workspace bookmark 与 `agent.attach` 权限流。
- `@main` agent 不可被 remove。
- Project Settings 新增目录只更新 project metadata；当前工具执行仍以 agent 单 `workspaceRoot` 为真实文件访问根。右侧 inspector 不提供 agent 删除或详情管理，只显示 Git status、未清理 agent 状态图标与目标表；`@main` 与 `@permission-reviewer` 不可删除。
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
| `TurnStatsPayload` / `TurnStatsProjection` | 每轮模型响应统计与 GUI 最近一轮投影 | 随 `turn_stats` 事件追加到 JSONL；GUI 只读投影 | token 字段来自 endpoint usage，可能为空；`cachedPromptTokens` / `contextWindowTokens` 是追加可选字段，旧 JSONL 缺字段必须继续解码；同一次 provider 响应的多个 usage chunk 按字段合并，Agent 工具循环的多个模型请求按请求累计；TTFT/total wall time 由 ChatLoop/AgentLoop 记录；GUI 显示不得依赖 transcript 文本解析 |
| `ErrorPayload` / `RuntimeErrorPresentation` / `RuntimeRecoveryAdvice` | provider、agent 与工具运行错误的用户可读投影 | 随 `error` 事件追加到 JSONL；恢复建议由 `ConversationProjection` / `CodeProjection` 从错误/失败工具结果派生，不另写事件 | 错误码由 shared runtime 映射生成；message 必须是裁剪后的可展示文本，不得包含完整 API 响应或 secret；恢复建议只说明 retry/config/endpoint/permission/tool-input 方向，不得包含 secret 或原始响应；若 partial assistant/agent delta 后发生错误，投影层只标记当前未完成消息为 response stopped 并保留 partial text，不新增事件 type |
| `ProviderHealthReport` | 当前 provider/model 的连接测试结果 | 不写入 EventLog；由设置页临时显示 | status、role、endpoint/model/wire、elapsed、first token、usage、code/message、裁剪 response preview；不得包含 secret 或完整响应体 |
| `ProviderRuntimePolicy` / `HTTPDataResponse` | provider 请求的 timeout / retry / backoff / rate-limit header 策略 | 不持久化；由 provider adapter 初始化默认值；HTTP headers 只用于当前请求诊断 | streaming 默认 2 attempts + request timeout；只在首个响应字节前失败时 retry。non-streaming image/transcription 对 retryable HTTP/网络/timeout 失败重试；`Retry-After` / rate-limit reset headers 可用数字秒、HTTP 日期或 `750ms` / `1m30s` 等 duration 字符串影响 retry delay 并进入错误说明；取消不 retry |
| `ToolCapability` / `CapabilityLease` | Cowork agent 可用工具能力边界 | 内存 agent lease；事件只记录 agent/task/工具结果 | coordinator 可用文档/媒体读写、生图与网络/浏览器能力；worker 默认只读 PDF 且无 `browse_web`，不得默认获得 `edit_pdf_pages`、`compile_latex`、`generate_image`、`browser_*` 等写入/执行/网络能力；lease 只控制工具暴露，最终执行仍必须过 `PermissionEngine` |
| `TaskContract` / `TaskReportPayload` | Cowork 任务契约与子任务结构化回报 | `task_created/assigned/queued/started/completed/failed` 事件；`report` 是 v0.16 追加可选字段 | 任务契约记录 issuer/assignee/objective/roleHint/expectedDeliverable/lease metadata；`delegate_task` 完成后把 `TaskReportPayload` 经 MessageBus/Mediator 回传给上级 agent；旧 JSONL 缺 `report` 必须继续解码 |
| `SessionSummary` / `SessionHistoryStore` | 最近会话摘要与路径生成 | 扫描 app support root 下 `<session>/events.jsonl` | Chat/Code/Cowork 按 `sess_` / `code_` / `cowork_` 前缀区分；macOS/iOS 共用实现，平台层只传 root 与 `SessionID` |
| `CoworkProjectSettings` / `CoworkProjectInfo` | Cowork project-mode session metadata 与右侧 inspector 投影 | UserDefaults `intatis.cowork.projectSettings.<sessionID>`；GUI 运行时投影 | 保存主 agent 名称、默认 provider/model、默认 permission profile、可选 token budget、workspace path/bookmark/agent 归属；不保存 secret；恢复时按 bookmark 恢复访问并通过既有 `agent.attach` 生成 `@main` workspace lease；project info 只读投影 agent/workspace 状态；direct multi-root tool context 尚未实现 |
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
- **Provider tool-call delta 兼容**：`OpenAIToolCalling` 仍输出既有 `ToolCall(id:name:arguments:)`，但解码更宽容：单工具调用可缺省 `index`，`index` 可是字符串，`function.arguments` 可是字符串或 JSON object/array/number/bool，非字符串值会被压缩编码回 JSON 字符串再交给既有工具参数解析。Chat/tool-calling streaming 会遍历同一 SSE chunk 的全部 choices，不再只消费 `choices.first`；如果首个 choice 为空但后续 choice 带 content、tool_calls 或 `finish_reason`，仍会输出对应 delta/tool calls 并完成流；如果多个 choice 同时给出 finish reason，`tool_calls` / `function_call` 优先于普通 `stop`，避免工具轮被错误标成文本完成。若 provider 以 `finish_reason:"tool_calls"` 或旧式 `finish_reason:"function_call"` 结束但没有发出完整 tool-call delta / tool name，或已出现 tool-call delta 但最终错误给出 `stop` 且仍缺 tool name，则抛出 provider tool-call stream 兼容错误，不把空工具调用合成为成功。非空累计 `function.arguments` 在发出 `ToolCall` 前必须能解码为 JSONValue，截断或非法 JSON 会作为 provider tool-call stream 兼容错误暴露；空 arguments 仍保留，以兼容无参工具。此行为不改变 EventLog schema，不绕过权限门。
- **Provider/runtime 错误反馈**：`ProviderErrorFormatting` 统一处理 OpenAI-compatible HTTP 非 2xx、streaming provider error payload、malformed SSE chunk、`URLError`/取消/transport error，并只保留裁剪后的 provider message 或 response preview；HTTP 非 2xx 响应体只有结构化 `error`/`message`/`detail`/`error_description` 才显示为 `Provider said`，HTML/纯文本代理错误页只显示 `Preview`。`ProviderEndpoint` 在 chat streaming、tool-calling streaming、image generation、transcription 发起网络前统一校验 Chat endpoint 或 Base URL 必须是带 host 的 `http`/`https` URL，非 HTTP、缺 scheme 或缺 host 归类为 `IntatisError.config`，不把 file URL 或底层 URLSession 失败泄漏到 UI。非流式 image/transcription 对 HTTP 2xx 响应也会校验成功 payload shape；如果 provider 返回错误 JSON、HTML、缺 `data[].b64_json`、坏 base64、缺 `text` 或其他不兼容结构，会抛出裁剪后的 `IntatisError.decoding`，提示检查 endpoint、provider path、model 与 response format；只有结构化 `error`/`message`/`detail`/`error_description` 才显示为 `Provider said`，普通 HTML/缺字段 JSON/坏 base64 只显示 `Preview`。`RuntimeErrorPresentation` 把 `IntatisError`/`URLError` 映射成 `ErrorPayload.code + message`，供 ChatLoop/AgentLoop 写入 append-only `error` 事件。`ConversationProjection` 与 `CodeProjection` 从该 payload 派生 `RuntimeRecoveryAdvice`，SharedUI 在 Chat / Code / Cowork 错误卡片中复用同一恢复建议视图。若错误发生在当前 assistant/agent partial delta 之后，投影层会把该未完成气泡标记为 stopped 并附加 partial-response 恢复建议，已输出文本继续保留；状态码提示覆盖 400/401/403/404/408/422/429/5xx 等常见接入问题，但真实 provider 格式仍需矩阵验证。
- **Provider runtime retry/timeout/rate-limit headers**：`ProviderRuntimePolicy` 由 OpenAI-compatible chat streaming、tool-calling streaming、image generation、transcription 共享。URLRequest 会设置 request timeout；408/409/425/429/5xx 与短暂网络/timeout 错误可 retry。流式请求只在尚未收到任何 response bytes 时 retry；一旦收到 partial text/tool-call bytes，失败会按错误反馈路径暴露，不自动重放请求，避免重复输出或重复工具调用，随后由 Chat/Code 投影标记当前 partial stream stopped。Chat/tool-calling streaming 接受 `[DONE]` 或 chunk `finish_reason` 作为完成信号；`finish_reason` 不会立刻截断底层流，后续 usage chunk 仍会被读取，done 只投递一次；若底层流结束时没有任何完成信号，则抛出 completion-marker 兼容错误而不是合成成功。非流式 image/transcription 由 `ProviderRuntime.sendData` 统一重试并给 timeout 生成可行动错误。`HTTPDataResponse` 与 `URLSessionStreamingClient` 会保留 HTTP response headers；`ProviderErrorFormatting` 解析 `Retry-After`、`x-ratelimit-reset`、`x-ratelimit-reset-requests`、`x-ratelimit-reset-tokens`、`ratelimit-reset`，支持数字秒、HTTP 日期和 `750ms` / `1m30s` 等 duration 字符串，用于 retry delay 与用户可读说明，长等待由 policy cap。
- **Provider health check**：`ProviderRegistry.healthCheck(role:options:)` 复用当前 provider catalog、chat selection、secret resolver 与 `OpenAIWireProvider`，发起最小 chat/agent 流式请求，输出 `ProviderHealthReport`。chat 与 agent health check 均请求 `stream_options.include_usage`，并使用共享 `Usage` 合并规则处理 split usage chunk。报告显式区分 ok、timeout、partial stream、unknown endpoint、非法 provider URL、provider/transport/config 错误，并带 endpoint/model/wire/耗时/首 token/usage 与裁剪预览；兼容缺 `[DONE]` 但有 `finish_reason` 的 provider，只有完成信号缺失才标记 partial stream，并保留已收到的裁剪预览；macOS 与 iOS 设置页共用该 provider 层 API，只做不同布局，不写入 EventLog 或持久状态。
- **Goal 输入命令**：`GoalInputParser` 在 UI/ViewModel 层识别行首 `/goal`，要求后面有目标文本；解析成功后把命令前缀剥离，provider/agent 只收到清洗后的目标文本。事件层通过 `UserMessagePayload.tags = ["Goal"]` 与 `goal` 保存目标元数据，`ConversationProjection` / `CodeProjection` 将其投影到 `ChatMessageView` / `CodeItem`，SharedUI 与 macOS Chat bubble 显示 Goal 标签。Cowork 会在 mention 路由前后各解析一次，因此支持 `/goal @Agent ...` 与 `@Agent /goal ...`。
- **工具执行反馈**：AgentLoop 对未知工具、权限拒绝、工具抛错分别写入结构化 `tool_result` observation，并在执行前追加 `agent_status(tool)`；已知工具在权限判断和执行前会校验参数必须是 JSON object，并满足 descriptor schema 的 required 字段、基础类型、数字 `minimum`/`maximum` 约束、字符串 `minLength`/`maxLength` 约束与 `additionalProperties:false` 未知字段规则，`read_file.maxBytes` 当前要求 `>= 1`，标准工具 path/query/command/diff 字符串当前要求非空，required 为空的无参工具可把空参数 / `null` 归一为 `{}`，坏 JSON、非对象、缺 required 字段、基础类型错误、数值越界、字符串过短/过长或未知字段会写入 `invalid tool input:` 的 `tool_result`，不生成 `permission_request`，也不执行工具。当前 shipped tools schema 默认声明 `additionalProperties:false`，因此模型给出的额外字段不能被 `try?` 默认值吞掉后进入权限或工具执行。`CodeProjection` 根据 `tool_call_id` 将结果标题回填为 `result · <toolName>`，把 `tool error:` / `permission denied:` / `unknown tool:` / `invalid tool input:` 标成失败项，并通过 `RuntimeRecoveryAdvice` 派生恢复建议。GUI 与 CLI 均消费事件投影/observation，不解析 assistant transcript。
- **Agent 文档/媒体工具**：`ToolRegistry.standard()` 暴露 PDF 阅读、PDF 页面编辑、文档照片/扫描件版面重建、LaTeX 编译和生图写入工作区。PDFKit 路径在 macOS 可直接工作；Linux 或无 PDFKit 平台会返回配置错误并提示使用外部 CLI 后端。shell-backed 文档重建和 LaTeX 编译不内置模型或 TeX 发行版，只调用已安装的成熟工具；缺少命令时返回可行动的配置错误。生图工具不直接知道 provider secret，只通过注入的 `ImageGenerationToolService` 使用现有 provider registry。
- **Agent 网络/浏览器工具**：`ToolRegistry.standard()` 暴露轻量 `web_fetch` 和 Playwright/CDP-backed `browser_*` 工具。浏览器工具依赖用户环境里已安装的 Node.js，并优先使用 Playwright + Chromium/Chrome/Edge channel；若 Playwright 不可解析，则通过 Node.js 内置 `WebSocket` 使用 Chrome DevTools Protocol 启动已安装 Chrome/Edge/Chromium。缺少后端时返回配置错误或 `browser_diagnostics` 的可行动诊断。profile/state/history/downloads 全部通过 `PathConfinement` 限定在 workspace `.intatis/browser/` 下，刷新、历史前进/后退、表单点击/输入/提交/下拉选择/按键/滚动/等待交互通过 locator 或当前焦点执行；click/download 的 CDP 路径使用真实鼠标事件，打开新页面的交互会跟随到新 tab/window 并把最终页面写回 state/history；截图只能写入工作区 PNG 路径，上传只能引用 workspace 内文件，显式下载只能写入 `.intatis/browser/downloads/<profile>`；`browser_profiles` 可报告 active browser / profile lock runtime marker 是否存在，但不得列内部 marker 文件名或读取内容；`browser_profile_delete` 只在目标 profile 与 `confirmProfile` 匹配时删除 `.intatis/browser/profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json` 并剪除对应 history metadata，删除前如果发现 marker 只给概括性提示；profile 可能包含 cookies 与登录态，不能当成普通日志、artifact 或 secret-free 文本处理。
- **macOS UI information architecture**：`IntatisMacRootView` 是 macOS Chat/Code/Cowork 的 shell。左侧栏固定 `Intatis` 标题、横向 mode switch、mode-specific session history 与 Settings；New session 动作在 history 区域内，Cowork New session 会先要求用户选择主 workspace 并初始化 per-session project settings。主 thread header 保持标题/副标题，不承载 New/session/model 控件。`IntatisThreadComposer` 支持 composer accessory，macOS Chat/Code/Cowork 把 provider/model menu、context label 与 turn stats 放在输入区旁；Cowork composer 默认把无 @mention 指令交给 `@main`。Thread content 使用共享 responsive layout 计算 horizontal padding、显式 `contentWidth`、message gutter 与 bubble max width；Chat/Code/Cowork 的 message list 均以 `contentWidth` 固定列宽后再在可用区域内居中；对话泡泡通过 `IntatisThreadBubbleRow` 在整行层面按 user trailing、assistant/agent leading 对齐，短消息也在自身 max-width 框内按角色对齐，而不是只靠 bubble 内部 spacer 推位置。Chat 默认无右 inspector；Code 使用右 inspector 展示 structured plan/workspace/Git-status-only/recent failure/last turn；Cowork 右 inspector 只保留三块：`Git Status` status-only、`Agents` 中未清理 agent 的名字与状态图标、`Goals` 中由 task objective 自动生成的目标表，完成项以勾选图标和删除线声明完成。Git 在此层只读展示状态，不实现 commit/branch/PR/CI 工作流。
- **GUI token/turn stats**：ChatLoop 与 AgentLoop 每轮结束追加 `turn_stats`，包含 endpoint 返回的 prompt/completion/total token（若有）、可选 cached prompt tokens、可选 context window tokens、TTFT、总耗时和 model。OpenAI-compatible `prompt_tokens_details.cached_tokens` 会进入 `Usage.cachedPromptTokens`；未缓存 input 可由 prompt-cached 在 UI 层展示。ChatLoop、AgentLoop 与 ProviderHealthCheck 共用 `Usage` 规则：同一次响应内的 usage chunk 字段级合并，Agent 工具循环中多个模型请求再按请求累计。GUI 不解析消息文本计算 token，而是通过共享 `TurnStatsProjection` 折叠最近一轮统计；macOS Chat / Code / Cowork 与 iOS Chat 复用 `IntatisTurnStatsSummaryView` 显示单行低噪音统计。endpoint 不返回 cached/context usage 时，显示退化为 prompt/completion/total 或耗时信息。
- **Chat/Code/Cowork session/history**：macOS `IntatisMacRootView` 通过 root-owned view models 和 `SessionHistoryStore.recentSessions(kind:)` 展示当前 mode 的最近 sessions；Chat 启动时优先恢复最近 Chat session，无历史时才使用 `sess_default`，Code/Cowork 在首次进入时创建对应 session。iOS `IOSAppEnvironment` 仍只恢复 Chat session，无历史时才使用 `sess_ios`。新建会话生成新的 `SessionID.new()`，打开独立 `EventLog` 与 artifact store，停止旧 view model 并重建当前 view model。恢复历史会话只切换到对应 `events.jsonl`，不会把新消息继续追加到旧的固定默认日志。路径规则在 `IntatisCore` 复用，macOS/iOS 只传不同 application-support root。
- **GUI provider catalog**：macOS `AppConfig` 与 iOS `IOSConfig` 使用 UserDefaults 主键 `intatis.providerCatalog.v1` 保存两层配置。第一层 provider 存 `id` / 展示名 / `baseURL` / `chatEndpoint` / secret ref 元数据；第二层 model 存模型 id / 展示名。Chat 对话页提供 provider 分组的模型菜单；切换后写入 `intatis.providerSelection.v1`，重建 `ProviderRegistry` 并更新 `ChatViewModel`，下一条请求使用新 provider/model。设置页编辑 Base URL 时自动生成 Chat endpoint；编辑 Chat endpoint 时清洗 `/chat/completions` 后缀回填 Base URL。旧 `intatis.baseURL` / `intatis.model` 仍作为迁移来源与兼容镜像。
- **macOS advanced config**：macOS GUI 启动时先检查 `INTATIS_CONFIG` 指定文件；未设置时按顺序检查 `~/.config/intatis/opencode.json` / `opencode.jsonc`、`~/.config/intatis/intatis.json` / `intatis.jsonc`、`~/.config/opencode/opencode.json` / `opencode.jsonc`、app support 的 `opencode.json` / `intatis.json`，最后才兜底读取旧 `config.json` / `config.jsonc`。找到可解码的 JSON/JSONC 后覆盖 UserDefaults provider catalog；聊天页当前选择覆盖层仍可覆盖 JSON 顶层 `model`。设置页的 Open JSON 按钮会打开当前生效的 OpenCode-compatible 文件或 `INTATIS_CONFIG` 指定文件；若只发现旧 `config.json`，会从当前 catalog 生成新的 `~/.config/intatis/opencode.json` 模板并优先打开。保存设置时，用户本次主动输入的 API key 会写入同一个可编辑 provider JSON 的 `provider.<id>.options.apiKey`；写入用户 config 失败时回退到 app support `opencode.json`。创建的模板来自当前 provider catalog，只输出 OpenCode-compatible `$schema` / `enabled_providers` / `model` / `provider.<id>.npm` / `name` / `options.baseURL` / `options.apiKey` / `models`，`options.apiKey` 默认是 `{env:...}` 引用而非明文。支持兼容读取旧 direct `providers` 数组，也兼容读取 Intatis 扩展字段 `chatEndpoint` / `apiKeySource`；推荐新配置使用 `provider.<id>.options.baseURL`、`options.apiKey`（OpenCode 原生明文、`{env:NAME}` 或 `{file:path}` 均可由真实请求懒加载）、`models`，以及顶层 `model` 形如 `<provider>/<model-id>`。支持 OpenCode 的 `enabled_providers` / `disabled_providers` 过滤；`disabled_providers` 优先。省略 `options.apiKey` 时 provider 请求按 provider id 尝试 auth JSON 与当前 OpenCode-compatible config，不再回落 OS Keychain。
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
- GUI 不再读写 OS Keychain。`KeychainRef` 是历史命名的 secret ref；其中 `.keychain` 仅作旧配置兼容值，app resolver 会把它映射到配置/auth 文件查找，不调用 Security Keychain API。
- `ConfigSecretResolver` 可指向 `environment` / `file` / `authFile`。macOS `authFile` 默认先查 `~/.config/intatis/auth.json`，再兼容查 `~/.local/share/intatis/auth.json`、`~/.local/share/opencode/auth.json` 与 OpenCode-compatible config 的 `provider.<id>.options.apiKey`；也可用 `INTATIS_AUTH_FILE` 覆盖。iOS 默认落在 app container Application Support 的 `Intatis/auth.json`。UserDefaults catalog 只存 secret ref 元数据，不存 API key；macOS 设置页输入的 API key 写入当前可编辑 provider JSON，iOS 设置页输入的 API key 写入 auth JSON 并尝试设置 `0600`；真实 provider 请求懒加载 secret，并按 source/service/account 做进程内缓存。

### 工作区边界
- `PathConfinement.resolve`：拒 `..` 遍历与越界绝对路径。Tools 执行与权限门均使用。

### 权限 3 层门
1. `DeterministicPolicyGate`（纯函数、模型无关、runs first、`deny` 终局）：locked→deny；敏感路径→deny；路径越界→deny；exec→evaluateShell（shell disabled / read_only hard deny；exec+network ask）；非 exec 网络在 read_only 下 deny、其他模式 ask；readOnly side-effect→allow；destructive→ask；write→evaluateWrite。
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
