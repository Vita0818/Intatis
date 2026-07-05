# Intatis 项目常驻上下文

本文件继承 `/Users/vita/Vitemis/AGENTS.md` 中的 Vitemis 通用 Agent 规则。若本文件与通用规则冲突，在不违反系统和用户指令的前提下，以更具体、更严格的项目规则为准。

本文是 AI Agent 每轮进入本仓库时的入口文件。执行任何代码修改、配置修改、构建脚本修改或测试源码修改之前，必须先按顺序阅读并核对下列文档：

0. `/Users/vita/Vitemis/AGENTS.md`
1. `docs/CURRENT_STATE.md`
2. `docs/PROJECT_MAP.md`
3. `docs/ARCHITECTURE.md`
4. `docs/DO_NOT_BREAK.md`
5. `docs/TESTING.md`
6. `docs/NEXT_TARGET.md`（如果存在）
6. `docs/COWORK_PRINCIPLES.md`（修改 Cowork / AgentKernel / MessageBus / 权限 / agent 编排前必读）

如果文档与源码、工程配置、测试或脚本冲突，必须以当前源码和配置为准，并在最终报告中明确指出冲突位置和采用源码为准的原因。

> 仓内现有 `docs/COWORK_AGENT_ARCHITECTURE.md` / `COWORK_TASK_CONTEXT_MODEL.md` / `COWORK_CURRENT_FINDINGS.md` / `COWORK_MIGRATION_PLAN.md` / `COWORK_AGENT_INVOCATION_MODEL.md` / `COWORK_V0_10_SMOKE.md` / `COWORK_V0_10_STATUS.md` 是 Cowork 设计文档与状态记录，可作为深入参考；`docs/COWORK_PRINCIPLES.md` 是其原则提炼。

## 工作目录检查

每轮开始先在项目根目录执行：

```sh
pwd
git rev-parse --show-toplevel
git status --short
```

要求：

- `pwd` 与 `git rev-parse --show-toplevel` 必须指向同一个仓库根目录：`/Users/vita/Vitemis/Intatis`。
- 如果当前目录不是 Git root，停止修改，只报告路径问题。
- 读取 `git status --short` 后，先区分用户已有改动与本轮计划改动；不得覆盖、回退或清理用户已有改动。

## 修改边界

本仓库是 clean-room 本地 AI 工作区（Swift 多 target，SwiftPM + XcodeGen），含三个产品面：Chat（普通多模态对话）/ Code（单 agent 本地工作区）/ Cowork（多 agent 本地工作区协作）。macOS 是全量产品；iOS 是 chat 子集。

未来常规任务可以按用户要求修改业务源码；但在只要求项目自查或文档更新的任务中，只允许修改：

- `AGENTS.md`
- `docs/` 下的项目说明文档

除非用户明确要求，不要修改：

- `Apps/`（IntatisMac / IntatisiOS / intatis-cli）
- `Packages/`（11 个 Intatis* 模块及其 Tests）
- `Package.swift`
- `project.yml`
- `Makefile`
- `NOTICE.md`

## 禁止事项

- 不执行破坏性 Git 操作：`git reset --hard`、`git clean -fd`、`git checkout .`、强制 push、删除用户未提交文件。
- 未经用户明文要求具体 Git 操作，不 add、不 commit、不 push、不创建 PR；编辑、整理、修复、验证或准备工作都不等于提交请求。
- 若用户要求提交，只提交当前 Git root 中与本任务相关的文件；不得递归进入、暂存、提交或推送子仓库、submodule、nested Git repo 或依赖 checkout。
- 不引入新依赖，不改构建脚本，不改测试源码，除非任务明确要求。v0.1 零第三方依赖；计划中的 SwiftGit2/libgit2 须先过许可证审查。
- 不把密钥、token、证书私钥、shared secret、账号密码、完整指纹、完整 API 响应、完整转写文本或个人隐私路径写入文档。
- 不绕过 3 层权限门（DeterministicPolicyGate / ModelPermissionReviewer / PermissionEngine）、PathConfinement 工作区边界、SecretScanner、Mediator 秘密拦截或 Keychain 凭据隔离。
- 不把 Cowork 实现为硬编码递归 agent 树（main/coordinator/worker/leaf 永久角色）；遵循 `docs/COWORK_PRINCIPLES.md`。
- 不让 `AgentLoop` 直接同步递归调用另一个 `AgentLoop`；用 mailbox / scheduler / event flow。
- 不让 worker 默认获得 coordinator 工具（spawn_agent / remove_agent / delegate_task）；能力须经 `CapabilityLease` 显式授予。
- 不破坏 clean-room 声明：不复制 Codex / Claude Code / DeepCode / OpenCode / ChatGPT / Claude 的源码、私有 prompt、UI 资产、图标、产品名或用户面文案。
- 不弱化平台边界：iOS 不得链接 shell/git/patch/local-agent workspace 模块，不得包含本地 workspace Agent 执行。
- 不把事件日志 JSONL schema、Envelope 格式、`seq` 单调性、ArtifactStore 索引格式当作一次性内部细节随意改动。

## 项目理解要求

修改前至少确认：

- 入口：`Apps/IntatisMac/Sources/IntatisMacApp.swift`（`@main struct IntatisMacApp`，全量 macOS）、`Apps/IntatisiOS/Sources/IntatisiOSApp.swift`（`@main struct IntatisiOSApp`，chat 子集）、`Apps/intatis-cli/Sources/IntatisCLI.swift`（CLI）。
- Chat 链路：`ChatViewModel` → `GoalInputParser`（行首 `/goal` 只生成可选 Goal 元数据，provider 收到清洗后的文本）→ `ChatLoop`（无工具）→ `EventLog`(JSONL append-only) → `ConversationProjection`。
- Code 链路：`CodeViewModel` → `GoalInputParser` → `AgentLoop`（maxIterations 50）→ `ContextBuilder` → `OpenAIWireProvider` → `runTool` → `PermissionEngine`（3 层门）→ `EventLog` → `CodeProjection`。
- Cowork 链路：`CoworkViewModel` → `GoalInputParser` + `CoworkMentionRouter`（支持 `/goal @Agent ...` 与 `@Agent /goal ...`）→ `Orchestrator`(actor) → `AgentLoop`（maxIterations 50）→ `ContextBuilder` → `OpenAIWireProvider` → `runTool` → `PermissionEngine`（3 层门）→ `EventLog`；`MessageBus` → `Mediator`（SecretScanner + 4000 字符上限 + reviewer）。CLI Cowork `/auto` 会创建保留子 agent `@permission-reviewer`（read_only、无工具 lease），并用 `AgentPermissionResponder` 汇总全局上下文后让其 provider 返回 JSON 权限决策；`/default` 关闭并移除该审查者。审查者不得作为普通 send/delegate/message/ask 目标，不得通过嵌套 `AgentLoop` 运行。
- 权限 3 层：`DeterministicPolicyGate`（纯函数、模型无关、deny 终局）→ `ModelPermissionReviewer`（只能收窄）→ `PermissionEngine`（`pass` 默认 `askUser`）。
- 平台边界：iOS 是 macOS 真子集（chat/multimodal/providers/artifacts，无 Tools/Permission/AgentKernel/Cowork）；`PlatformProfile.current` 默认 `.iOS`（最受限）。
- 持久化：`EventLog`（`~/Library/Application Support/Intatis/<session>/events.jsonl`，`seq` 单调；`UserMessagePayload.tags` / `goal` 为 v0.12 追加可选字段，旧 JSONL 必须继续可解码）、`ArtifactStore`（blobs + `index.json`）、`UserDefaults`（provider catalog 主键 `intatis.providerCatalog.v1`，provider 保存 `baseURL` + `chatEndpoint` + secret ref 元数据；聊天页当前选择用 `intatis.providerSelection.v1` 覆盖；兼容镜像 `intatis.baseURL`/`intatis.model`）、高级 macOS JSON/JSONC 配置（`INTATIS_CONFIG`、`~/.config/intatis/opencode.json` / `intatis.json`，并可直接读取 `~/.config/opencode/opencode.json`；旧 `~/.config/intatis/config.json` 只作兜底兼容读取，推荐 OpenCode-compatible 顶层 `model` + `enabled_providers` + `provider` map，覆盖 UserDefaults catalog 但可被聊天页当前选择覆盖）、Keychain（GUI，service `com.intatis.app`/`com.intatis.ios`，默认 account `default-openai`，新增 provider 使用独立 account；启动态/设置页只能做不返回 secret data 且跳过认证 UI 的存在性检查，设置页只能用圆点占位提示已有 key）。
- 安全：`KeychainStore`（generic-password，凭据引用 `KeychainRef`；`KeychainSecretResolver` 仅在真实 provider 请求中按 keychain/env/file/auth JSON/OpenCode-compatible config `options.apiKey` 懒加载 secret 并做进程内缓存；macOS auth JSON 默认先看 `~/.local/share/intatis/auth.json`，再兼容 `~/.local/share/opencode/auth.json`）、`PathConfinement`（拒 `..` 与越界）、`SecretScanner`、sandbox/entitlements（AppStore sandbox 无 shell；DeveloperID Hardened Runtime）。

不确定的模块必须标注 `UNKNOWN` 或 `需要后续确认`，不要编造。

## 文档索引

- `docs/PROJECT_MAP.md`：目录、target、入口、关键文件、生成物和脚本地图。
- `docs/ARCHITECTURE.md`：总体架构、主要链路、数据模型、权限与安全机制。
- `docs/CURRENT_STATE.md`：当前真实状态、已有能力、风险、工作区改动。
- `docs/TESTING.md`：环境、构建、测试、lint/format 与手动验证方式。
- `docs/DO_NOT_BREAK.md`：工程禁区、数据格式、协议、路径和回归要求。
- `docs/NEXT_TARGET.md`：临时下一目标记录；目标完成或不再有效后删除。
- `docs/COWORK_PRINCIPLES.md`：Cowork 架构原则（agent 身份/任务契约/能力租约/上下文投影/递归禁止/安全边界/实现顺序/测试期望）。

## 完成标准

完成任务前至少做到：

- 说明本轮实际阅读/检查过哪些源码、配置或测试。
- 只修改任务范围内文件。
- 保留用户已有改动。
- 运行与任务相称的检查；文档任务至少运行 `git diff --check` 与 `git status --short`。
- 将本轮已完成的持久性改动及时回写到相关项目文档；若无需更新文档，最终报告说明原因。
- 如未运行构建或测试，最终报告必须明确写"未运行构建/测试"。

## 最终报告格式

最终报告建议包含：

1. `MODEL_CHECK_RESULT`：当前模型名称；无法确认时写无法确认。
2. `PATH_CHECK_RESULT`：`pwd`、Git root、是否匹配预期。
3. `FILES_WRITTEN`：新增/修改文件。
4. `PROJECT_AUDIT_SUMMARY`：识别到的项目结构、主要模块和关键链路。
5. `DOCS_CONTENT_SUMMARY`：各文档内容摘要。
6. `VALIDATION_RESULT`：实际运行命令与结果。
7. `UNCERTAINTIES`：无法确认、需要人工确认的点。
8. `NEXT_RECOMMENDED_ACTION`：下一步建议；不要自动继续改业务源码。
