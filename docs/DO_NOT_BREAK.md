# DO_NOT_BREAK

本文列出不可破坏的工程禁区、数据格式、协议、路径和回归要求。修改前必须确认不违反下列任一条目。

## 工程禁区

- 不执行破坏性 Git 操作：`git reset --hard`、`git clean -fd`、`git checkout .`、强制 push、删除未提交文件。
- 未经用户明文要求具体 Git 操作，不 add、不 commit、不 push、不创建 PR；编辑、整理、修复、验证或准备工作都不等于提交请求。
- 若用户要求提交，只提交当前 Git root 中与本任务相关的文件；不得递归进入、暂存、提交或推送子仓库、submodule、nested Git repo 或依赖 checkout。
- 不引入新依赖，不改构建脚本，不改测试源码，除非任务明确要求。v0.1 零第三方依赖；计划中的 SwiftGit2/libgit2 须先过许可证审查。
- 不绕过 3 层权限门、`PathConfinement`、`SecretScanner`、`Mediator` 秘密拦截或配置文件凭据隔离。

## 数据格式禁区

- **事件日志 JSONL**：`~/Library/Application Support/Intatis/<session>/events.jsonl`。一行一个 `Envelope`：`{seq, ts, session, v:1, type, payload}`。`seq` 单调递增；追加演进；replay 时不可解码行跳过。18 种 event `type`。
- **Chat session/history**：Chat 不得回退为单一固定会话日志。New Chat 必须生成新的 `SessionID` 并打开独立 `<session>/events.jsonl` 与 `<session>/artifacts/`；History/Resume 只能切换到目标 session 的日志投影，不得把新消息继续追加到旧默认 `sess_default` / `sess_ios`。macOS/iOS 共享 `SessionHistoryStore` 路径与最近会话扫描逻辑，平台差异通过传入不同 root/session 参数表达。
- **Cowork project settings**：Cowork per-session project metadata 使用 UserDefaults `intatis.cowork.projectSettings.<sessionID>`，只能保存 sessionID、主 agent 名称、默认 provider/model id、默认权限 profile、可选 token budget、workspace path/bookmark/agent 归属等非 secret 元数据。不得把 API key、完整 provider 响应、完整转写文本或秘密文件内容写入该设置。恢复 workspace 访问必须依赖用户授权 bookmark；绑定/新增 workspace 必须继续通过既有 `agent.attach` 权限流和 workspace lease，不得只因 settings 中存在路径就绕过权限门。
- **user_message 兼容性**：`UserMessagePayload.text` 是送入模型的清洗后文本；v0.12 追加的 `tags` / `goal` 必须保持可选、追加式演进，不得让旧 JSONL 缺字段解码失败。`/goal` 只应产生 Goal 标签元数据，不得改写事件 type、Envelope shape 或 provider 线协议。
- **turn_stats 兼容性**：token/耗时统计必须继续通过 `turn_stats` append-only 事件传播。`cachedPromptTokens` / `contextWindowTokens` 等 usage 细节只能作为可选追加字段演进，旧 JSONL 缺字段必须继续解码。GUI 只能消费 `TurnStatsProjection` 或等价事件投影，不得解析 transcript 文本、SSE 原文或 UI 文案来推断 token。endpoint usage 为空是合法状态，GUI 应降级显示 TTFT/total wall time 或隐藏统计；cached/context 字段缺失时不得编造数值。同一次 provider 响应里的多个 usage chunk 应字段级合并，不能用后一个 nil 字段抹掉前值；Agent 工具循环中的多个模型请求应按请求累计，不能把同一响应里的补充 usage 重复相加。
- **ArtifactStore**：blobs 在 `<root>/blobs/<id>.<ext>`，索引在 `<root>/index.json`（`[ArtifactRef]`）。ISO-8601 日期，pretty JSON。
- **GUI config**：UserDefaults 规范主键为 `intatis.providerCatalog.v1`（mac/iOS 共用），保存 provider/model 两层元数据：provider `baseURL` + `chatEndpoint` + secret ref 元数据、model id + 展示名；当前聊天选择另存 `intatis.providerSelection.v1`，用于对话页即时切换 provider/model。Base URL 与 Chat endpoint 需要保持同步：Base URL 自动补 `/chat/completions` 生成 Chat endpoint；Chat endpoint 清洗 `/chat/completions` 后缀回填 Base URL。旧 `intatis.baseURL`、`intatis.model` 仅作为迁移来源/兼容镜像，不得作为唯一新状态。macOS 高级 JSON/JSONC 配置（`INTATIS_CONFIG` / `~/.config/intatis/opencode.json` / `~/.config/intatis/intatis.json` / `~/.config/opencode/opencode.json` / app support `opencode.json` 或 `intatis.json`，旧 `config.json` 兜底兼容读取）可覆盖 UserDefaults catalog，但聊天页当前选择可覆盖 JSON 顶层 `model` 且不得自动改写外部 JSON；推荐模板必须保持 OpenCode-compatible 顶层 `$schema` / `enabled_providers` / `model` + `provider` map，不得回退到直接输出内部 `providers` 数组。
- **Provider 线协议**：OpenAI 兼容 HTTP/SSE（`/chat/completions` streaming）。`WireFormat.openai` 是唯一 shipped 格式。
- **Provider tool-call delta 兼容**：tool-calling streaming 必须继续归一到既有 `ToolCall`，不得改事件 schema 或绕过权限门。解析器应保留对缺失单工具 `index`、字符串 `index`、非字符串 JSON `function.arguments` 的兼容；JSON arguments 必须作为 JSON 字符串进入工具参数解析，不得用描述性文本替代。Chat/tool-calling streaming 不得只消费 `choices.first`；同一 SSE chunk 中非首个 choice 的 content、tool_calls 与 `finish_reason` 也必须被处理，且多 choice 同时出现 `stop` 与 `tool_calls` / `function_call` 时不得把工具轮降级成普通文本完成。若 provider 以 `tool_calls` / 旧式 `function_call` finish reason 结束但未发出完整 tool-call delta 或缺 tool name，或已发出 tool-call delta 后错误以 `stop` 结束且仍缺 tool name，不得静默丢弃并合成成功，必须暴露 provider/tool-call 兼容错误。非空累计 `function.arguments` 必须在 provider 层确认可解码为完整 JSON；截断或非法 JSON 不得下放成泛化工具输入失败，空 arguments 可继续保留以兼容无参工具。
- **Provider / runtime 错误反馈**：HTTP 非 2xx、provider error payload、malformed SSE、transport/cancellation 等错误必须通过共享 provider/runtime 错误格式化进入 `ErrorPayload` 或 `tool_result`，并可由 `ConversationProjection` / `CodeProjection` 等投影层派生恢复建议；HTTP 非 2xx 响应体只有结构化 `error`/`message`/`detail`/`error_description` 可显示为 provider message，普通 HTML/纯文本代理错误页只能显示裁剪 preview；HTTP 2xx 但 image/transcription 响应结构不符合 OpenAI-compatible payload（如缺 `data[].b64_json`、坏 base64、HTML 响应或缺 `text`）时也必须变成裁剪后的 provider decoding 错误，不得泄漏底层 `DecodingError` 或完整响应体；partial assistant/agent delta 后的错误必须保留已输出文本，并从同一个 `error` 事件投影为 stopped/recovery advice，不得新增一次性事件 shape；不得把完整 API 响应、secret、未裁剪代理错误页或原始 SSE dump 写入事件日志、文档或 UI。
- **Provider endpoint URL 预校验**：OpenAI-compatible chat streaming、tool-calling streaming、image generation、transcription 在构建 `URLRequest` 时必须先确认 Chat endpoint 或 Base URL 是带 host 的 `http`/`https` URL；缺 scheme、缺 host 或 `file:` 等非 HTTP URL 必须作为 `config` 错误暴露，并可被 health check 报告，不得落到原始 URLSession/文件 URL 行为；错误文案不得包含 secret、完整 auth config 或原始响应 dump。
- **Provider retry/timeout/rate-limit headers**：Chat/tool-calling streaming、image generation、transcription 的 timeout/retry/backoff 必须走共享 `ProviderRuntimePolicy` / `ProviderRuntime`。流式请求不得在已经收到 response bytes 后自动 retry，因为这会重复 partial text 或 tool calls；收到 partial 后失败只能保留 partial 并解释停止原因。取消请求不得 retry，必须保持 `cancelled` 语义。OpenAI-compatible streaming completion 必须同时兼容 `[DONE]` 和 chunk `finish_reason`；看到 `finish_reason` 后不得立刻丢弃后续 usage chunk，且不得重复投递 done；若底层流结束时既无 `[DONE]` 也无 `finish_reason`，不得合成成功，必须抛出可投影的 completion-marker 兼容错误。HTTP `Retry-After` / rate-limit reset headers 可以用数字秒、HTTP 日期或 `750ms` / `1m30s` 等 duration 字符串影响 retry delay 和错误说明，但不得把完整 response headers、secret 或原始响应 dump 写入事件日志、文档或 UI。
- **Provider health check**：设置页 Test Provider/Health Check 必须调用共享 `ProviderRegistry.healthCheck(role:options:)` / `ProviderHealthReport`，不得在 macOS/iOS UI 里复制 provider-specific 判断。chat 与 agent health check 都应请求 usage，并复用 `turn_stats` 的 usage 合并语义。报告只能展示裁剪后的 response preview、endpoint/model/wire/耗时/usage/code/message，不得展示 secret、完整响应体或原始 SSE dump；timeout 与 partial stream 必须有明确状态；缺 `[DONE]` 但已有 `finish_reason` 的流不应误判为 partial；真正缺完成标记时应保留 preview 并报告 partial stream。
- **工具执行反馈**：工具失败仍应通过 `tool_result` observation 表达，且 GUI/CLI 应消费 `CodeProjection` / 事件投影；失败状态和恢复建议必须从结构化 `tool_result` / `ErrorPayload` 投影派生，不得通过解析 assistant transcript 文案来判断工具是否失败。已知工具的坏 JSON、非对象、缺 required 字段、基础类型错误参数、数字 `minimum`/`maximum` 约束违规、字符串 `minLength`/`maxLength` 约束违规，或被 `additionalProperties:false` schema 禁止的未知字段，必须在权限判断和工具执行前变成 `invalid tool input:` 结果；当前 shipped tool schemas 应保持 strict object shape，`read_file.maxBytes` 必须保持 `>= 1`，标准工具 path/query/command/diff 字符串必须保持非空约束，不得让坏参数通过 `try?` 默认值进入路径计算、权限请求或工具执行。
- **Agent 文档/媒体工具**：`read_pdf`、`edit_pdf_pages`、`reconstruct_document_image`、`compile_latex`、`generate_image` 必须继续作为普通 Agent 工具运行，不能绕过 schema 校验、`PermissionEngine`、`PathConfinement` 或 `tool_result` 事件记录。PDF 页面编辑、LaTeX 编译、生图写文件等写入必须只落在 agent workspace 内；文档重建和 LaTeX wrapper 调用已安装外部命令时必须仍受 shell 权限与平台能力约束。不得把 Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers 等外部项目源码复制进仓库；若未来引入依赖，必须先完成许可证和平台边界审查。工具输出不得把完整 OCR 文本、完整 provider 响应、secret、私密路径或未裁剪诊断写入文档或 UI；长文本应裁剪或作为用户明确选择的工作区文件存在。
- **Agent 网络/浏览器工具**：`web_fetch`、`browser_diagnostics`、`browser_profiles`、`browser_profile_delete`、`browser_history`、`browser_navigate`、`browser_snapshot`、`browser_handoff`、`browser_reload`、`browser_back`、`browser_forward`、`browser_click`、`browser_type`、`browser_submit`、`browser_select_option`、`browser_press_key`、`browser_scroll`、`browser_wait`、`browser_screenshot`、`browser_upload_file`、`browser_download`、`browser_downloads`、`browser_search` 必须继续作为普通 Agent 工具运行，不能绕过 schema 校验、`PermissionEngine`、`PathConfinement` 或 `tool_result` 事件记录。`web_fetch` 是网络工具；`browser_profiles`、`browser_history` 和 `browser_downloads` 是只读 metadata 工具；其他 `browser_*` 是 shell-backed exec 工具，其中页面导航/headed handoff/刷新/前进/后退/交互/表单提交/滚动/等待/截图/上传/下载/搜索仍标记 network risk，必须先满足平台 shell 能力，再进入网络审批。浏览器后端可优先走 Playwright，也可在 Playwright 缺失时走 Node.js 内置 `WebSocket` + Chrome DevTools Protocol fallback，但两条路径都必须使用 workspace-confined persistent profile。浏览器 profile/state/history/downloads 只能落在 workspace `.intatis/browser/` 下；同一进程内同一 workspace profile 的 Playwright/CDP-backed 浏览器命令必须串行执行，不得并发打开或写入同一 persistent profile/state/history，`browser_back` / `browser_forward` 的 state/history 读和真实执行不得拆开到锁外；不同 profile 不得退化为全局互斥。`state/<profile>.json` 可保存当前页面 metadata 和 Intatis 管理的 navigation stack/index，但不得保存 cookies/localStorage 或 secret；会打开新 tab/window 的浏览器交互应跟随到最终页面并写入 state/history，不能静默停留在来源页；CDP click/download 路径应使用真实鼠标事件而不是只依赖 DOM `click()`。截图输出只能是工作区内 PNG；上传文件必须先经 `PathConfinement` 限定在 workspace 内；显式下载只能写入 `.intatis/browser/downloads/<profile>` 并通过 `changedFiles` 暴露路径；`browser_profiles` 只能列 profile 名称、当前 URL/title、state/history/download 计数、目录统计和 active/lock runtime marker 是否存在，不得列出 profile 内部文件名、runtime marker 文件名，或读取 marker/database 内容；`browser_downloads` 只能列 metadata，不得读取或摘要下载文件内容。profile 可能包含 cookies、登录态、localStorage 和历史痕迹，不得打印、摘要、提交、当作普通 artifact 分享，或写入 UserDefaults/文档。页面快照和动作结果可以返回按钮、输入框、下拉框等交互控件的 role/name/selector/options 定位 metadata，但不得打印 cookies、localStorage、profile 数据库、密码/token 或当前文本输入框 value；`browser_submit` 只能提交当前 profile 页面中的当前或目标表单，不得用于默认代输密码、2FA、token 或绕过站点风控；`browser_handoff` 只能打开有界 headed 窗口供用户登录或接管，模型不得借此默认代输密码、2FA、token 或绕过站点风控；`browser_profiles` / `browser_history` 不得读取 cookie/localStorage/profile 数据库；`browser_type` 必须在 Swift 工具入口和 Playwright/CDP 后端 DOM 执行前拒绝疑似密码/2FA/token/API key 输入目标，并要求使用 `browser_handoff` 让用户接管；工具 observation 必须遮蔽本次输入值。不得把 Chromium、Playwright、CEF、Browser Use、Selenium 等外部项目源码复制进仓库；若未来引入依赖或嵌入 CEF/Chromium，必须先完成许可证、体积、沙盒和平台边界审查。
- **Agent 浏览器 profile 删除工具**：`browser_profile_delete` 是显式 `.destructive` 工具，必须继续要求 `confirmProfile` 与目标 `profile` 匹配，且只能删除 workspace `.intatis/browser/profiles/<profile>`、`.intatis/browser/downloads/<profile>`、`.intatis/browser/state/<profile>.json` 并剪除 `.intatis/browser/history.jsonl` 中对应 profile 的 metadata 行。删除前可检测少数 Chromium active/lock runtime marker 是否存在并输出概括提示，但不得列 marker 文件名或读取 marker 内容。不得删除 workspace 外路径、不得读取或输出 cookie/localStorage/profile 数据库/下载内容/内部文件名，不得在 worker 默认 lease 中暴露；read_only 下必须 hard deny，其他 profile 下必须进入用户/审查权限流。

## 协议禁区

- **Cowork 投递协议**：`MessageBus.deliver` 是唯一 agent 间投递路径。`Mediator.mediate` 必须先于转发运行。不得新增绕过 Mediator 的直投路径。
- **Coordinator 工具**：`spawn_agent` / `list_agents` / `remove_agent` / `ask_agent` 只对 `canCoordinate==true` 的 agent 暴露；worker 默认不得获得 coordinator 能力。`@main` agent 不可被 remove。
- **Cowork 文档/媒体工具 lease**：worker 默认只能获得安全的只读文档能力（当前为 `read_pdf`）；`edit_pdf_pages`、`reconstruct_document_image`、`compile_latex`、`generate_image` 等写入/执行/网络相关工具必须只通过 coordinator lease 或未来显式 `CapabilityLease` 授予，不能因调用 `ToolRegistry.standard()` 而泄漏给普通 worker。
- **Cowork 网络/浏览器工具 lease**：worker 默认不得获得 `browse_web`，也不得暴露 `web_fetch` 或任何 `browser_*`。网络/浏览器能力只能通过 coordinator lease 或未来显式 `CapabilityLease` 授予，且执行时仍必须通过 `PermissionEngine`。
- **Cowork project-mode agent 管理**：GUI 无 @mention 的用户消息必须默认发送给项目 `@main`，不得在已有多个 agent 时强迫用户手动选择目标。子 agent 应由 `@main` 通过 `spawn_agent` / `delegate_task` 等工具按任务需要创建和管理；`spawn_agent` 默认创建 worker（`coordinationDepth=0`），只有显式 `canCoordinate:true` 或未来明确 capability lease/任务契约授予时，子 agent 才可获得 coordinator 工具并继续管理下级 agent。右侧 inspector/settings 可以删除普通子 agent 作为人工干预，但不得删除 `@main` 或 `@permission-reviewer`；删除 agent 不得删除用户文件或清理未提交工作区，只能更新 Orchestrator roster 与非主 workspace metadata。
- **自动权限审查保留身份**：`@permission-reviewer` 只能由 CLI Cowork `/auto` 创建、`/default` 移除；它是 read_only、无工具 capability lease 的特殊子 agent，不得作为普通 send/delegate/message/ask 目标，不得暴露给 `list_agents` 工具，也不得由其他 agent 用 `spawn_agent` / `remove_agent` 管理。
- **权限协议**：硬 DENY 终局；`ModelPermissionReviewer` 只能收窄不能放行；CLI `/auto` 的 `AgentPermissionResponder` 只能回答已经产生的 `ask_user` 请求，不能覆盖 `DeterministicPolicyGate` hard deny；任何 model tool_call 到执行都必须过 `PermissionEngine`，无旁路。
- **JSON-RPC 词汇**：`Command`→request、`Envelope`→event notification 映射已定义，传输未挂。不得在未确认 out-of-process 传输设计前随意改词汇结构。

## 路径禁区

- **工作区根**：`PathConfinement.resolve` 拒绝 `..` 与越界绝对路径。
- **受保护配置路径**：lockfile / CI / Dockerfile / Makefile → 写操作必须 `ask`。
- **敏感路径**：`~/.ssh`、`~/Library/Keychains`、`~/.local/share/intatis/auth.json`、`~/.local/share/opencode/auth.json`、`~/.config/intatis/opencode.json`、`~/.config/opencode/opencode.json`、secret/token/key 目录 → 硬 deny。

## 回归要求

- iOS 必须保持 macOS 真子集：**不得**链接 Tools/Permission/AgentKernel/Cowork 或 shell/git/patch 模块。
- macOS UI 信息架构不得回退为三套 demo screen：mode selection 和 session history 属于左侧栏；model/context/token 控制属于 composer cluster；Chat 默认不显示右 inspector；Code/Cowork 右 inspector 只能消费 structured projections/view-model state，不能解析 assistant transcript；Cowork 右侧 Agent panel 应继续显示 project/workspace/agent name/role/model/permission/status/lease 等结构化状态；Chat/Code/Cowork 对话泡泡应保持整行 leading/trailing alignment 和响应式最大宽度约束，不得回退到只靠内部 spacer 推位置；Git 在当前 slice 只能显示状态，不得偷偷加入 commit/branch/PR/CI 工作流。
- `PlatformProfile.current` 默认 `.iOS`（最受限）：忘记设置的 target 不得意外启用 shell/workspace。
- `IntatisSharedUI` 用 `#if canImport(SwiftUI)`，不得引入 macOS 专属 API 而破坏 Linux/无头构建。
- `swift test` 无头：不得让测试 target 依赖 UI/app target。
- AppStore 构建无 `run_shell` entitlement：不得为 AppStore 配置启用 shell。
- AppStore 构建无 `run_shell` entitlement：shell-backed `reconstruct_document_image` / `compile_latex` / `browser_*` 不得在 AppStore profile 下绕过 `DeterministicPolicyGate` 执行；缺 shell 能力时应返回权限或配置错误，而不是尝试私有执行路径。

## 不可降级项

- `EventLog` append-only：`append` 是唯一 mutation；不得引入原地修改或删除。
- `seq` 单调性：不得回退或重排。
- `Mediator` 默认转发摘要、不转发原始字节：不得退化成透传完整内容。
- `SecretScanner` 标记集不得删减。
- Provider catalog 不存秘密本身：UserDefaults 与 `intatis.providerSelection.v1` 只能保存 provider/model/secret ref 元数据，不得保存明文 API key；UserDefaults/docs 不得出现明文 API key。Intatis 生成的 OpenCode-compatible provider 模板默认只能写 `options.apiKey` 的 `{env:NAME}` / `{file:path}` 等引用，不得在模板中写真实 key。macOS 设置页用户主动输入的 API key 必须写入当前可编辑 OpenCode-compatible provider JSON 的 `provider.<id>.options.apiKey`，iOS 设置页用户主动输入的 API key 仍写入 app container `Intatis/auth.json`（或 `INTATIS_AUTH_FILE` 指定文件）并应尝试设置 `0600`；不得写入 OS Keychain。真实 provider 请求可从 OpenCode-compatible config 的 `provider.<id>.options.apiKey`、auth JSON、env 或 file secret 懒加载 secret；如果 macOS 当前 provider catalog 来自 OpenCode-compatible config 且该 provider 直接声明了 `options.apiKey`，secret ref 必须绑定到该 provider config 文件本身，不得被同 provider id 的旧 auth JSON 抢先覆盖；macOS auth JSON/secret/config 文件可能含密钥，Agent 不得读取、打印、摘要或写入其内容。启动、`needsAPIKey`、设置 UI 占位符和真实 provider 请求均不得调用 OS Keychain 查询；真实 provider 请求读取 secret 后必须复用 resolver 进程内缓存，但 provider registry 刷新时可以清空该缓存以避免旧 key 继续生效；OpenAI-compatible `Authorization` header 必须只发送单层 `Bearer <token>`，并容错剥离用户误存的外层引号或 `Bearer ` 前缀。
- Clean-room 声明：不复制 Codex / Claude Code / DeepCode / OpenCode 等的源码、私有 prompt、图标、商标、品牌文案。
- Cowork 不得实现为硬编码递归 agent 树（见 `docs/COWORK_PRINCIPLES.md`）。
- `AgentLoop` 不得直接同步递归调用另一个 `AgentLoop`。
- 自动权限审查不得通过嵌套 `AgentLoop` 实现；审查者只能收到无工具 provider 请求并返回结构化 JSON 决策。

## 验证要求

- `make test`（`swift test`，无头）
- `make build`（`swift build`）
- 改 GUI/app：`make app`（xcodegen + Xcode）
- 改 Cowork/AgentKernel：必须加/更新对应测试（见 `docs/COWORK_PRINCIPLES.md` §8 测试期望）
- 文档任务：至少 `git diff --check` + `git status --short`
- 未运行构建/测试时，最终报告必须声明"未运行构建/测试"。
