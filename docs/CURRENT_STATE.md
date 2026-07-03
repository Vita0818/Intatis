# CURRENT_STATE

最近一次自查日期：2026-07-03

## 当前真实状态总览

- Intatis 是 clean-room 本地 AI 工作区，当前进入 v0.12 本地工作区；三个产品面：Chat / Code / Cowork。`project.yml` 的 `MARKETING_VERSION` 已同步为 `0.12`。
- 11 个 Intatis* 内核模块代码就绪，10 个测试 target 有覆盖。macOS 全量、iOS chat 子集。
- v0.12 GUI 设置已支持两层 provider/model catalog：provider 层保存 Base URL、Chat endpoint 与 secret ref 元数据；model 层保存模型 id 与展示名。Chat 对话页可直接按 provider 分组切换模型，选择写入 `intatis.providerSelection.v1` 并立即重建 `ProviderRegistry`，下一条请求使用新 provider/model。Base URL 与 Chat endpoint 输入框会互相同步；旧的 `/chat/completions` 误填到 Base URL 的配置会被清洗。GUI 保存 API key 时仍默认写入 Keychain；macOS 高级用户可通过 `INTATIS_CONFIG`、`~/.config/intatis/opencode.json` / `intatis.json` 或现有 `~/.config/opencode/opencode.json` 手写 JSON/JSONC 覆盖 provider catalog。高级配置推荐 OpenCode-compatible shape：顶层 `$schema` / `enabled_providers` / `model` + `provider.<id>.npm/name/options.baseURL/options.apiKey/models`；`options.apiKey` 支持 OpenCode 原生明文、`{env:NAME}` 与 `{file:path}`。旧 `~/.config/intatis/config.json`、app support `config.json` 与旧 direct `providers` 数组仍作兜底兼容读取。设置页提供 Open JSON 按钮，优先打开/创建 `opencode.json`，若只发现旧 `config.json` 会生成新的 OpenCode-compatible 模板；模板不含明文 API key。启动态/设置页只做不读取 Keychain secret data 的存在性检查，真实 provider 请求懒加载 secret 并在进程内缓存；Keychain miss 时可按 provider id 兼容查找 `~/.local/share/intatis/auth.json`、`~/.local/share/opencode/auth.json` 与当前 OpenCode-compatible config。
- v0.12 已支持 `/goal` 输入命令：Chat / Code / Cowork composer 识别行首 `/goal <目标>`，发送给模型的是清洗后的目标文本，`user_message` 事件额外保存 `tags:["Goal"]` 与 `goal` 字段，UI 在用户消息上显示 Goal 标签。Cowork 同时支持 `/goal @Agent ...` 与 `@Agent /goal ...`，最终事件还会通过既有 `to` 字段记录目标 agent。
- v0.12 CLI Cowork 已支持自动权限审查：用户在 Cowork REPL 输入 `/auto` 后，`Orchestrator` 创建保留子 agent `@permission-reviewer`（read_only、无工具 capability lease、不可作为普通任务目标）；之后其他 agent 的权限请求由 `AgentPermissionResponder` 汇总全局事件日志、agent roster、任务/工具/消息上下文后调用该审查者的 provider 产出 JSON 决策。输入 `/default` 关闭并移除该审查者。该实现不启动嵌套 `AgentLoop`，且 `DeterministicPolicyGate` hard deny 仍终局；GUI 自动审查 UI 尚未设计。
- Cowork 架构原则已定义（见 `docs/COWORK_PRINCIPLES.md` 与仓内 7 个 COWORK_* 文档），但当前实现与原则有已知差距。
- 真机 + 真实 key 的端到端验证状态 `UNKNOWN`。

## 已有能力

| 能力 | 入口 / 关键类型 | 测试覆盖 | 手动验证 | 真机验证 |
|---|---|---|---|---|
| IntatisMac chat | `IntatisMacApp` / `ChatViewModel` / `ChatLoop` | `IntatisConversationTests` | UNKNOWN | UNKNOWN |
| IntatisMac cowork | `CoworkViewModel` / `Orchestrator` / `AgentLoop` | `IntatisCoworkTests` / `IntatisAgentKernelTests` | UNKNOWN | UNKNOWN |
| IntatisMac multimodal | `MultimodalService` | `IntatisMultimodalTests` | UNKNOWN | UNKNOWN |
| IntatisiOS chat | `IntatisiOSApp` / `IOSAppEnvironment` | 无（SharedUI 无测试） | UNKNOWN | UNKNOWN |
| 权限 3 层门 | `PermissionEngine` / `DeterministicPolicyGate` / `ModelPermissionReviewer` | `IntatisPermissionTests` / `ReviewerTests` | UNKNOWN | UNKNOWN |
| Provider OpenAI 兼容 | `OpenAIWireProvider` / `SSE.swift` | `IntatisProvidersTests` | UNKNOWN | UNKNOWN |
| GUI 多 provider/model 设置 | `AppConfig` / `IOSConfig` / `IntatisSettingsPanel` / iOS Settings sheet / Chat model menu | 无专门测试；app target 构建覆盖 | Xcode 构建通过；真实 key UNKNOWN | UNKNOWN |
| macOS 高级 JSON provider 配置 | `AppConfig.fileProviderCatalog` / `AppConfig.prepareEditableConfigFile` / `KeychainSecretResolver` | 无专门测试；macOS app target 构建覆盖 | Xcode 构建通过；真实 config/auth JSON UNKNOWN | UNKNOWN |
| `/goal` 目标标签 | `GoalInputParser` / `ChatLoop` / `AgentLoop` / `Orchestrator` / `ConversationProjection` / `CodeProjection` | `IntatisConversationTests` / `IntatisCoworkTests` | SwiftPM focused tests 通过；GUI 手动 UNKNOWN | UNKNOWN |
| CLI Cowork 自动权限审查 | `Orchestrator.enableAutomaticPermissionReview` / `AgentPermissionResponder` / `Interactive.swift` `/auto` `/default` | `AutomaticPermissionReviewTests` | SwiftPM focused tests 通过；真实 provider/key UNKNOWN | UNKNOWN |
| 事件日志 | `EventLog`（JSONL append-only） | `IntatisConversationTests` | UNKNOWN | UNKNOWN |
| Artifact 存储 | `ArtifactStore` | `IntatisArtifactsTests` | UNKNOWN | UNKNOWN |

## 未完成 / 进行中

- **Cowork 原则差距**（见 `docs/COWORK_PRINCIPLES.md` §6）：部分旧审计项已由当前实现补齐（task contract / capability lease / self-call / 非递归调度 / workspace expansion 权限等），但原则文档仍是架构基准而非完成度声明；需继续以源码和测试核对实际完成度。
- **JSON-RPC out-of-process 传输未挂**：词汇已定义，`intatis agent --stdio` / `intatis daemon` 是规划中管道，当前内核全进程内运行。
- **SwiftGit2/libgit2 集成**：规划用于 sandbox 内 in-process git，许可证待审查。
- **Interactive.swift REPL 接入状态** `UNKNOWN`：需确认 `main()` 是否触达。
- **Provider role 细分**：GUI 当前把 Chat / Agent / image / transcription role 绑定到选中 provider；Chat 使用独立 `chatEndpoint`，image/transcription 仍从 provider `baseURL` 拼路径且模型使用默认 id（`dall-e-3` / `whisper-1`），尚未提供独立 role-specific 设置 UI。

## 风险

- **Cowork 实现与原则漂移**：原则文档定义了 TaskContract/CapabilityLease/ContextProjector 等抽象，但当前实现尚未完全落地，易误判完成度。
- **真机验证缺口**：大量能力有测试但真机端到端状态 UNKNOWN。
- **provider catalog 真实互操作缺口**：多 provider/model 设置与 macOS 高级 JSON/JSONC 配置已构建通过，但 OpenAI / OpenRouter / Ollama / vLLM / DeepSeek 等真实 base URL + chat endpoint + key + model id 的手动矩阵验证仍是 UNKNOWN；旧 direct `providers` 数组 schema 继续兼容读取，新 Open JSON 模板使用 OpenCode-compatible 顶层 `enabled_providers` + `model` + `provider` map，并可直接读取用户现有 OpenCode 全局 config。当前只保证 OpenAI-compatible HTTP/SSE provider；非 OpenAI-compatible provider 配置可被解析但不代表线协议已支持。
- **Keychain ACL 首次读取提示**：启动和设置页不应再触发系统认证；旧 Keychain item 在首次真实 provider 请求读取 secret 时仍可能由 macOS 要求一次授权，授权后同一进程内由 `KeychainSecretResolver` 缓存，重复请求不应再次读取 Keychain。
- **高级 JSON 密钥文件风险**：OpenCode-compatible `options.apiKey` 可通过 OpenCode 原生明文、`{env:NAME}` / `{file:path}` 绕过 Keychain，旧 `apiKeySource` 扩展也仍可用；若用户把 secret 写入普通 JSON 文件，应由用户自行管理文件权限与同步/备份风险，Agent 不得读取或打印这些文件内容。
- **自动权限审查真实模型风险**：`@permission-reviewer` 只在 CLI `/auto` 后创建，测试覆盖本地 fake provider 决策；真实 provider 的误判率、延迟和失败回退仍需人工验证。审查者返回 `ask_user`、输出不可解析或 provider 出错时会回退到原 `PermissionResponder`。
- **Intatis 与 Councis 仓关系**：二仓共享 ARCHITECTURE.md 与 Packages 结构，关系未明示（Councis 是 Intatis CLI 原型分支？独立产品？）。`UNKNOWN`。
- **clean-room 覆盖**：`NOTICE.md` 以 Intatis 名义声明，Councis 复用 Intatis 模块时是否覆盖未明示。

## 工作区状态

v0.12 本地工作区已有 GUI provider/model catalog、Chat 对话页 provider/model 切换菜单、macOS 高级 JSON/JSONC provider 配置、Open JSON 生成 `~/.config/intatis/opencode.json` OpenCode-compatible 模板、现有 `~/.config/opencode/opencode.json` 读取、Keychain/OpenCode auth/config fallback 存在性检查/缓存代码改动、`/goal` 命令、Goal 标签投影，以及 CLI Cowork `/auto` 自动权限审查 / `/default` 关闭实现与对应测试/文档。仓库仍有多项未提交/未跟踪改动，最终状态以 `git status --short` 为准。

## 文档与源码冲突

| 冲突位置 | 冲突内容 | 采用源码为准的原因 | 建议 |
|---|---|---|---|
| `docs/COWORK_*` 设计文档 vs 当前实现 | 设计文档描述 TaskContract/CapabilityLease/ContextProjector 等抽象，部分尚未实现 | 源码是实际实现 | 差距已记录在 `docs/COWORK_PRINCIPLES.md` §6 |
