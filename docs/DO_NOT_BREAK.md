# DO_NOT_BREAK

本文列出不可破坏的工程禁区、数据格式、协议、路径和回归要求。修改前必须确认不违反下列任一条目。

## 工程禁区

- 不执行破坏性 Git 操作：`git reset --hard`、`git clean -fd`、`git checkout .`、强制 push、删除未提交文件。
- 未经用户明文要求具体 Git 操作，不 add、不 commit、不 push、不创建 PR；编辑、整理、修复、验证或准备工作都不等于提交请求。
- 若用户要求提交，只提交当前 Git root 中与本任务相关的文件；不得递归进入、暂存、提交或推送子仓库、submodule、nested Git repo 或依赖 checkout。
- 不引入新依赖，不改构建脚本，不改测试源码，除非任务明确要求。v0.1 零第三方依赖；计划中的 SwiftGit2/libgit2 须先过许可证审查。
- 不绕过 3 层权限门、`PathConfinement`、`SecretScanner`、`Mediator` 秘密拦截或 Keychain 凭据隔离。

## 数据格式禁区

- **事件日志 JSONL**：`~/Library/Application Support/Intatis/<session>/events.jsonl`。一行一个 `Envelope`：`{seq, ts, session, v:1, type, payload}`。`seq` 单调递增；追加演进；replay 时不可解码行跳过。18 种 event `type`。
- **user_message 兼容性**：`UserMessagePayload.text` 是送入模型的清洗后文本；v0.12 追加的 `tags` / `goal` 必须保持可选、追加式演进，不得让旧 JSONL 缺字段解码失败。`/goal` 只应产生 Goal 标签元数据，不得改写事件 type、Envelope shape 或 provider 线协议。
- **ArtifactStore**：blobs 在 `<root>/blobs/<id>.<ext>`，索引在 `<root>/index.json`（`[ArtifactRef]`）。ISO-8601 日期，pretty JSON。
- **GUI config**：UserDefaults 规范主键为 `intatis.providerCatalog.v1`（mac/iOS 共用），保存 provider/model 两层元数据：provider `baseURL` + `chatEndpoint` + secret ref 元数据、model id + 展示名；当前聊天选择另存 `intatis.providerSelection.v1`，用于对话页即时切换 provider/model。Base URL 与 Chat endpoint 需要保持同步：Base URL 自动补 `/chat/completions` 生成 Chat endpoint；Chat endpoint 清洗 `/chat/completions` 后缀回填 Base URL。旧 `intatis.baseURL`、`intatis.model` 仅作为迁移来源/兼容镜像，不得作为唯一新状态。macOS 高级 JSON/JSONC 配置（`INTATIS_CONFIG` / `~/.config/intatis/opencode.json` / `~/.config/intatis/intatis.json` / `~/.config/opencode/opencode.json` / app support `opencode.json` 或 `intatis.json`，旧 `config.json` 兜底兼容读取）可覆盖 UserDefaults catalog，但聊天页当前选择可覆盖 JSON 顶层 `model` 且不得自动改写外部 JSON；推荐模板必须保持 OpenCode-compatible 顶层 `$schema` / `enabled_providers` / `model` + `provider` map，不得回退到直接输出内部 `providers` 数组。
- **Provider 线协议**：OpenAI 兼容 HTTP/SSE（`/chat/completions` streaming）。`WireFormat.openai` 是唯一 shipped 格式。

## 协议禁区

- **Cowork 投递协议**：`MessageBus.deliver` 是唯一 agent 间投递路径。`Mediator.mediate` 必须先于转发运行。不得新增绕过 Mediator 的直投路径。
- **Coordinator 工具**：`spawn_agent` / `list_agents` / `remove_agent` / `ask_agent` 只对 `canCoordinate==true` 的 agent 暴露；worker 默认不得获得 coordinator 能力。`@main` agent 不可被 remove。
- **自动权限审查保留身份**：`@permission-reviewer` 只能由 CLI Cowork `/auto` 创建、`/default` 移除；它是 read_only、无工具 capability lease 的特殊子 agent，不得作为普通 send/delegate/message/ask 目标，不得暴露给 `list_agents` 工具，也不得由其他 agent 用 `spawn_agent` / `remove_agent` 管理。
- **权限协议**：硬 DENY 终局；`ModelPermissionReviewer` 只能收窄不能放行；CLI `/auto` 的 `AgentPermissionResponder` 只能回答已经产生的 `ask_user` 请求，不能覆盖 `DeterministicPolicyGate` hard deny；任何 model tool_call 到执行都必须过 `PermissionEngine`，无旁路。
- **JSON-RPC 词汇**：`Command`→request、`Envelope`→event notification 映射已定义，传输未挂。不得在未确认 out-of-process 传输设计前随意改词汇结构。

## 路径禁区

- **工作区根**：`PathConfinement.resolve` 拒绝 `..` 与越界绝对路径。
- **受保护配置路径**：lockfile / CI / Dockerfile / Makefile → 写操作必须 `ask`。
- **敏感路径**：`~/.ssh`、`~/Library/Keychains`、`~/.local/share/intatis/auth.json`、`~/.local/share/opencode/auth.json`、`~/.config/intatis/opencode.json`、`~/.config/opencode/opencode.json`、secret/token/key 目录 → 硬 deny。

## 回归要求

- iOS 必须保持 macOS 真子集：**不得**链接 Tools/Permission/AgentKernel/Cowork 或 shell/git/patch 模块。
- `PlatformProfile.current` 默认 `.iOS`（最受限）：忘记设置的 target 不得意外启用 shell/workspace。
- `IntatisSharedUI` 用 `#if canImport(SwiftUI)`，不得引入 macOS 专属 API 而破坏 Linux/无头构建。
- `swift test` 无头：不得让测试 target 依赖 UI/app target。
- AppStore 构建无 `run_shell` entitlement：不得为 AppStore 配置启用 shell。

## 不可降级项

- `EventLog` append-only：`append` 是唯一 mutation；不得引入原地修改或删除。
- `seq` 单调性：不得回退或重排。
- `Mediator` 默认转发摘要、不转发原始字节：不得退化成透传完整内容。
- `SecretScanner` 标记集不得删减。
- Provider catalog 不存秘密本身：UserDefaults 与 Intatis 生成的 Open JSON 模板只允许保存 secret ref 元数据，`intatis.providerSelection.v1` 只能保存 provider/model id，UserDefaults/docs 不得出现明文 API key；Intatis 生成的 OpenCode-compatible 模板可写 `options.apiKey` 的 `{env:NAME}` / `{file:path}` 引用，但不得写真实 key。为兼容用户复制的其他 agent 壳子配置，真实 provider 请求可从外部 OpenCode-compatible config 的 `provider.<id>.options.apiKey` 懒加载 OpenCode 原生明文、env 或 file secret；macOS auth JSON/secret/config 文件可能含密钥，Agent 不得读取、打印、摘要或写入其内容。启动态、`needsAPIKey`、设置 UI 占位符只能做不返回 secret data 且跳过认证 UI 的存在性检查，不能调用会读取密钥内容的 Keychain 查询；设置 UI 可用圆点占位提示 key 存在，但不得显示、记录或持久化密钥内容。真实 provider 请求读取 secret 后必须复用 resolver 进程内缓存，避免每次发消息重复触发 Keychain 认证。
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
