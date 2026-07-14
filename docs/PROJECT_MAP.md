# PROJECT_MAP

最近自查日期：2026-07-12

本文描述当前仓库结构。判断依据来自 `Package.swift`、`project.yml`、`Makefile`、源码、测试文件和脚本。

## 目录结构总览

```text
Intatis/
├── .build/            SwiftPM 构建产物（gitignored）
├── .git/              Git 仓库（remote: github.com/Vita0818/Intatis；当前 session 进入 v0.16 Agent 文档/媒体 + 网络/浏览器工具，project.yml 仍标 0.12）
├── .gitattributes     LF 规范化
├── .gitignore         忽略 .build、Intatis.xcodeproj、*.env、.intatis 本地运行/受管 worktree 状态
├── .swiftpm/          SwiftPM 缓存
├── AGENTS.md          项目常驻上下文与操作协议入口
├── Apps/              app target
│   ├── IntatisMac/    全量 macOS app（默认 DeveloperID/non-sandbox workbench）+ entitlements
│   ├── IntatisiOS/    Chat-only iOS app（7-product 子集）
│   └── intatis-cli/   CLI
├── ARCHITECTURE.md    Intatis 架构设计（draft-0，2026-06-11，中文）
├── Makefile           build/test/release/install/app 便利 target
├── NOTICE.md          项目来源、当前上游采用状态 + 第三方依赖声明
├── Package.swift      SwiftPM manifest（11 lib + CLI + 10 test target）
├── Packages/          11 个库模块（各 Sources/ + Tests/，SharedUI 无 Tests）
├── README.md          Intatis readme
├── docs/              项目状态/架构/测试/禁区说明 + Cowork 设计文档
└── project.yml        XcodeGen spec（生成 Intatis.xcodeproj）
```

## Target / 模块

### 库 target（11）— `Packages/<Name>/Sources`

| Target | 类型 | 依赖 | 职责 |
|---|---|---|---|
| `IntatisCore` | lib | — | 类型化 ID、错误、工作区路径约束、平台能力信封、会话类型、`SessionHistoryStore` |
| `IntatisProtocol` | lib | Core | 结构化事件/线协议词汇（Event/Envelope/JSONRPC/Command/CoworkEvents/PermissionIntent/PermissionReview/ToolExecution/MultimodalEvents/TurnStats/JSONValue） |
| `IntatisProviders` | lib | Core, Protocol | OpenAI 兼容模型访问与只读配置展示投影（ProviderRegistry/Capability/Endpoints/ChatProvider/OpenAIWireProvider/OpenAIToolCalling/ModelConfigurationPresentation/SSE/HTTPDataClient/ImageGeneration/Transcription/VideoGeneration/ToolCalling） |
| `IntatisArtifacts` | lib | Core, Protocol | 文件-backed blob 存储 + JSON 索引 |
| `IntatisConversation` | lib | Core, Protocol, Providers, Artifacts | 事件溯源会话 + UI 投影（跨进程锁定的 EventLog JSONL / ChatLoop / GoalInputParser / Projection / CodeProjection / Cowork tool execution recovery projection / TurnStatsProjection） |
| `IntatisTools` | lib | Core, Protocol | 哑工具执行器（ToolProtocol/FileTools/PatchTool/PathConfinement/ShellGit/DocumentMediaTools/BrowserTools） |
| `IntatisPermission` | lib | Core, Protocol, Providers | 3 层权限门（PermissionTypes/PermissionEngine/DeterministicPolicyGate/ModelPermissionReviewer/SecretScanner） |
| `IntatisAgentKernel` | lib | Core, Protocol, Providers, Tools, Permission, Conversation, Artifacts | 共享 headless 单 agent runtime（AgentRuntime/RuntimeEnvironmentManifest/AgentLoop/ContextBuilder/ContextProjector/AgentExecutionBudget/PermissionResponder） |
| `IntatisCowork` | lib | Core, Protocol, Providers, Tools, Permission, Conversation, AgentKernel | 多 agent 编排（Orchestrator/AgentScheduler/MessageBus/Mediator/AgentRegistry/CoordinatorTools/AgentPermissionResponder/PermissionReviewControlPlane） |
| `IntatisMultimodal` | lib | Core, Protocol, Providers, Artifacts, Conversation | 图像/视频/转写 → artifacts |
| `IntatisSharedUI` | lib | Core, Protocol, Providers, Conversation, Artifacts | 跨平台 SwiftUI。**无 Tests** |

### App target

| Target | 类型 | 平台 | Bundle ID | 链接 |
|---|---|---|---|---|
| `IntatisMac` | application | macOS | `com.intatis.app` | 全部 11 个 product；默认 DeveloperID/non-sandbox workbench |
| `IntatisiOS` | application | iOS | `com.intatis.ios` | 7 个 chat 子集 product（无 Tools/Permission/AgentKernel/Cowork） |
| `intatis-cli` | executable | CLI（macOS/Linux） | — | Core, Protocol, Providers, Conversation, Tools, Permission, AgentKernel, Cowork |

### 测试 target（10）— `Packages/<Mod>/Tests`

`IntatisCoreTests`、`IntatisProtocolTests`（+V02/V03/V04）、`IntatisProvidersTests`（+Multimodal/ToolCalling）、`IntatisArtifactsTests`、`IntatisConversationTests`（+Code）、`IntatisToolsTests`、`IntatisPermissionTests`（+Reviewer）、`IntatisAgentKernelTests`、`IntatisCoworkTests`（含 `AutomaticPermissionReviewTests`）、`IntatisMultimodalTests`。`IntatisSharedUI` 无测试。`swift test` 无头。

## 关键文件

- 入口：`Apps/IntatisMac/Sources/IntatisMacApp.swift`、`Apps/IntatisiOS/Sources/IntatisiOSApp.swift`、`Apps/intatis-cli/Sources/IntatisCLI.swift`
- Cowork 链路：`Packages/IntatisCowork/Sources/Orchestrator.swift`（生产 `runtime` session writer lease、fresh empty session 固定 `@main` restricted bootstrap admission、普通 reviewed attach、真实 root task、原子 `delegate_task` worker reuse/create、单审批 `spawn_agent` admission batch、bounded scheduler/watchdog、non-idempotent crash reconciliation、durable-first detach/revoke、恢复/取消/超时/重试、mailbox wake、lease lifecycle、Task Report、idle recycle）、`AgentScheduler.swift`（queue/claim/single-flight/snapshot/mailbox）、`AgentPermissionResponder.swift`、`PermissionReviewControlPlane.swift`（reviewer 独立 FIFO/single-flight/timeout/soft usage warning/allow-deny durable verdict）、`CommunicationDelegationTools.swift`、`CoordinatorTools.swift`、`MessageBus.swift`、`Mediator.swift`、`AskAgentTool.swift`
- Cowork 任务协议/投影：`Packages/IntatisProtocol/Sources/Task.swift`、`TaskGraph.swift`、`Leases.swift`、`CoworkEvents.swift`、`PermissionIntent.swift`、`PermissionReview.swift`、`ToolExecution.swift`、`Event.swift`（task attempt/cancel、结构化 tool action/resource/effect/risk、permission review request/settled、tool execution prepare/settled、message consumed、lease revoke）、`Packages/IntatisConversation/Sources/CoworkProjection.swift`（任务/agent roster/mailbox/owner/report/attempt/retry/未决 tool execution 投影）、`EventLog.swift`（append-only replay、cross-process flock、batch append、session writer lease 与 crash-tail 防护）
- Agent 内核：`Packages/IntatisAgentKernel/Sources/AgentRuntime.swift`（Code/Cowork 共用的 headless registry/permission/loop 工厂）、`AgentLoop.swift`（严格 completion/finish reason、精确 permission review context、audit fail-closed、tool execution ticket、workspace lease、并行 collaboration calls、exact denied-call circuit breaker）、`AgentExecutionBudget.swift`（dispatch 前 reservation 的共享 soft token meter）、`Agent.swift`、`ContextBuilder.swift`（`RuntimeEnvironmentManifest` + untrusted user-role context）、`ContextProjection.swift`（task-scoped bounded projection）、`PermissionResponder.swift`、`ProviderImageGenerationToolService.swift`
- Cowork 编排可靠性回归：`Packages/IntatisCowork/Tests/OrchestrationReliabilityTests.swift`、`SchedulerMailboxTests.swift`、`TaskGraphSchedulerIntegrationTests.swift`、`ToolRegistryLeaseTests.swift`；Agent completion/lease/budget/context 回归：`Packages/IntatisAgentKernel/Tests/AgentLoopOutcomeTests.swift`、`AgentLoopPolicyTests.swift`、`ContextProjectionTests.swift`；协议/回放兼容：`Packages/IntatisConversation/Tests/CoworkProjectionRegressionTests.swift` 与 Protocol lease/task tests。
- Agent Shell / Git / 文档 / 媒体工具：`Packages/IntatisTools/Sources/ShellGit.swift`（raw `ProcessShellRunner` 在 macOS 使用 Seatbelt workspace allow-list + network deny，在 Linux 使用 bwrap 且缺失时 fail closed；production registry 不暴露 `run_shell`；structured backend runner 与 raw shell 分流；进程 timeout/cancel 使用 TERM→KILL 与有界输出；Git 仍走参数数组 backend）、`Packages/IntatisTools/Sources/DocumentMediaTools.swift`（`read_pdf` / `edit_pdf_pages` / `reconstruct_document_image` / `compile_latex` / `generate_image`）、`Packages/IntatisTools/Sources/ToolProtocol.swift`（production registry + raw/structured shell + git/image-generation service）、`Packages/IntatisProtocol/Sources/Leases.swift`（Cowork `ToolCapability.gitControl` / `gitRemote` 等授权）
- Agent 网络/浏览器工具：`Packages/IntatisTools/Sources/BrowserTools.swift`（`web_fetch` / `browser_diagnostics` / `browser_profiles` / `browser_profile_delete` / `browser_history` / `browser_navigate` / `browser_snapshot` / `browser_handoff` / `browser_reload` / `browser_back` / `browser_forward` / `browser_click` / `browser_type` / `browser_submit` / `browser_select_option` / `browser_press_key` / `browser_scroll` / `browser_wait` / `browser_screenshot` / `browser_upload_file` / `browser_download` / `browser_downloads` / `browser_search`，通过 URLSession 或已安装 Node.js + Playwright persistent context；Playwright 缺失时用 Node.js 内置 WebSocket + Chrome DevTools Protocol 驱动已安装 Chromium/Chrome/Edge profile；页面快照和动作结果返回可定位交互元素摘要，并可跟随 click/type-submit/select/submit/press 打开的新 tab/window；profile inventory 只列安全 metadata 和 runtime marker 存在性；profile 删除是显式 `.destructive` 清理工具，删除前只概括提示 runtime marker 状态；表单提交作为 exec+network browser action 暴露）、`Packages/IntatisPermission/Sources/DeterministicPolicyGate.swift`（exec+network/destructive 权限顺序）、`Packages/IntatisProtocol/Sources/Leases.swift`（`browse_web`）
- 权限门：`Packages/IntatisProtocol/Sources/PermissionIntent.swift`、`Packages/IntatisPermission/Sources/PermissionEngine.swift`、`DeterministicPolicyGate.swift`、`ModelPermissionReviewer.swift`、`SecretScanner.swift`；production Cowork 的唯一模型审查点是 `PermissionReviewControlPlane` responder，非 Cowork host 才可选择 in-engine reviewer
- 事件日志与输入投影：`Packages/IntatisConversation/Sources/EventLog.swift`、`GoalInput.swift`（`/goal` 命令解析）、`Projection.swift`、`CodeProjection.swift`
- macOS UI 信息架构：`Apps/IntatisMac/Sources/IntatisMacRootView.swift`（mode switch + mode history + settings sidebar；新建 Cowork session 选择主 workspace）、`Apps/IntatisMac/Sources/IntatisChatScreen.swift`（Chat/Code/Cowork composer accessory + 配置来源的模型/variant/推理标签）、`Packages/IntatisSharedUI/Sources/CodeViews.swift`（Code shell + inspector）、`Packages/IntatisSharedUI/Sources/CoworkViews.swift`（Cowork shell + project/agent inspector）、`Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`（mode tabs/session history/composer/stats reusable surfaces）、`Packages/IntatisSharedUI/Sources/ProviderModelMenu.swift`（provider 分组、真实 model ID + optional variant identity、模型名与灰色 detail）
- GUI token/turn stats：`Packages/IntatisProtocol/Sources/TurnStats.swift`、`Packages/IntatisProviders/Sources/ChatProvider.swift`（`Usage`）、`Packages/IntatisProviders/Sources/OpenAIWireProvider.swift` / `OpenAIToolCalling.swift`（OpenAI-compatible usage parsing）、`Packages/IntatisConversation/Sources/CodeProjection.swift`（`TurnStatsProjection`）、`Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`（`IntatisTurnStatsSummaryView`）、`Packages/IntatisSharedUI/Sources/ChatViewModel.swift`、`Apps/IntatisMac/Sources/CodeViewModel.swift`、`Apps/IntatisMac/Sources/CoworkViewModel.swift`
- Chat/Code/Cowork session/history：`Packages/IntatisCore/Sources/SessionKind.swift`（`SessionSummary` / `SessionHistoryStore`，含可选 `session.json` 显示名称与安全删除）、`Apps/IntatisMac/Sources/IntatisMacRootView.swift`（mode history、右键 Rename/Delete）、`Apps/IntatisMac/Sources/IntatisMacApp.swift`、`Apps/IntatisiOS/Sources/IntatisiOSApp.swift`。macOS 与 iOS 共享最近会话扫描和 `events.jsonl` / `artifacts` 路径生成；平台层只传不同 root 与 `SessionID`。重命名不改变目录名、`SessionID` 或 EventLog envelope。Cowork 额外使用 `Apps/IntatisMac/Sources/CoworkProjectSettings.swift` 按 session 持久化 project/workspace/default model/default permission/token budget metadata。
- Provider：`Packages/IntatisProviders/Sources/Endpoints.swift`（每 endpoint 按 model 保存任意 JSON `modelRequestOptions`，旧 Codable 缺字段默认空）、`ModelConfigurationPresentation.swift`（只读识别原始 reasoning/thinking effort/level/budget 供 UI 展示，不参与请求）、`OpenAIWireProvider.swift` / `OpenAIToolCalling.swift`（Chat/Agent 通用扩展 body 合并与运行时结构字段保护）、`ProviderRegistry.swift`
- GUI/CLI Cowork 恢复与自动权限审查：`Apps/IntatisMac/Sources/CoworkViewModel.swift`（session replay → orchestrator restore → reviewer/main bootstrap → resume、permission FIFO、cancel/retry、token budget、async stop 等待 `cancelAll`）、`Apps/IntatisMac/Sources/IntatisMacRootView.swift`（session/mode transition generation guard，切换前等待旧 Cowork stop）、`Apps/intatis-cli/Sources/Interactive.swift`（per-workspace durable Cowork log、restore/resume、退出/切 mode 前等待 `cancelAll`、`/auto` / `/default`、Code/Cowork image-generation service 注入）、`Apps/intatis-cli/Sources/Terminal.swift`（渲染 `permission_review`）
- Cowork macOS project mode：`Apps/IntatisMac/Sources/CoworkProjectSettings.swift`（per-session settings store + settings sheet）、`Apps/IntatisMac/Sources/CoworkViewModel.swift`（恢复后先注册 EventLog stream；fresh session 先 restricted bootstrap `@main`、再启用 reviewer；`projectSettings` / `project` projection、GUI no-mention 默认路由到 `@main`、project directory metadata add/remove、task objective → Goals 投影）、`Apps/IntatisMac/Sources/Workspace.swift`（workspace picker prompt + bookmark restore）、`Packages/IntatisSharedUI/Sources/CoworkViews.swift`（仅在实际 `@main` 已投影时启用 composer；右侧只显示 `Git Status`、未清理 agent 名字+状态图标、Goals 编号/完成删除线；默认不提供用户手动新建 agent 入口，子 agent 由 `@main` 通过 `spawn_agent` / `delegate_task` / `remove_agent` 管理）
- macOS Agent 文档/媒体/网络工具接入：`Apps/IntatisMac/Sources/CodeViewModel.swift`（Code AgentLoop 注入 provider-backed image generation）、`Apps/IntatisMac/Sources/CoworkViewModel.swift`（Cowork Orchestrator 按 agent 注入 provider-backed image generation；coordinator lease 可用全部文档/媒体和网络/浏览器工具，worker 默认只读 PDF 且无 `browse_web`）
- GUI provider/model catalog：`Apps/IntatisMac/Sources/AppConfig.swift`、`Apps/IntatisiOS/Sources/IOSConfig.swift`（provider 保存 Base URL + Chat endpoint + secret ref 元数据；model 保存 id + 展示名；macOS 外部配置额外把 `models.<id>.options` 与 `variants` 保真到内存，不写 UserDefaults；variant 作为同一 model 的请求参数预设，选择时只保存 identity 并以原始字段覆盖基础 options；当前聊天选择另存 `intatis.providerSelection.v1`，可覆盖高级 JSON 顶层 `model`；macOS 额外支持 `INTATIS_CONFIG` 显式指定文件、`~/.config/intatis/intatis.json` / `intatis.jsonc`、app support `intatis.json` / `intatis.jsonc` 高级 JSON/JSONC 覆盖与 OpenCode-compatible 内容模板创建，不自动发现任何 `opencode.json` 或 OpenCode app 配置，旧 `config.json` 和 direct `providers` 数组兼容读取；macOS 设置页保存本次输入的 key 到当前可编辑 provider JSON `provider.<id>.options.apiKey`）；设置 UI：`IntatisSettingsPanel`（macOS，含 Open Intatis Config 按钮）、`IOSRootView.settingsSheet`（iOS）；Chat 模型菜单：`IntatisChatScreen`（macOS）、`IOSRootView` toolbar（iOS）；配置文件 secret 桥接：`Apps/IntatisMac/Sources/Keychain.swift`、`Apps/IntatisiOS/Sources/Keychain.swift`（历史文件名；真实请求不读写 OS Keychain，只按 auth JSON / Intatis-owned OpenCode-compatible config `options.apiKey` / env / file 懒加载并缓存 secret）
- Cowork 设计文档：`docs/COWORK_AGENT_ARCHITECTURE.md`、`COWORK_TASK_CONTEXT_MODEL.md`、`COWORK_AGENT_INVOCATION_MODEL.md`、`COWORK_CURRENT_FINDINGS.md`、`COWORK_MIGRATION_PLAN.md`、`COWORK_V0_10_SMOKE.md`、`COWORK_V0_10_STATUS.md`
- 开源复用政策：`docs/OPEN_SOURCE_REUSE.md`（允许的复用形式、许可证准入、provenance、NOTICE、Apple-first 集成、OpenCode 当前 research-only 状态与上游升级规则）

## 生成物 / 产物

- SwiftPM 构建产物：`.build/`（含 release 可执行）
- Xcode 工程产物：`Intatis.xcodeproj`（xcodegen 生成，gitignored）
- App bundle：`IntatisMac.app` / `IntatisiOS.app`（Xcode 构建产物）

## 脚本与工具

| 脚本 | 用途 | 调用方式 |
|---|---|---|
| `Makefile` | build/test/release/install/app/clean 便利 target | `make build` / `make test` / `make app` 等 |
| `project.yml` | XcodeGen 工程规格 | `xcodegen generate`（`make app` 内调用） |

## 不确定项

- Intatis 仓与 Councis 仓共享同一 `ARCHITECTURE.md` 与 `Packages/` 结构。二者关系（Councis 是 Intatis 的 CLI 原型分支？独立产品？）`UNKNOWN` — 需用户确认。
- `Apps/intatis-cli/Sources/Interactive.swift` REPL 是否接入 `main()` `UNKNOWN`（Councis 仓调研显示疑似死代码，Intatis 仓需独立确认）。
