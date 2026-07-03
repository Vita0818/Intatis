# TESTING

最近自查日期：2026-07-03

## 环境

- 操作系统 / 平台：macOS 13+（库与 CLI）；iOS 16+（IntatisiOS）；CLI 理论支持 Linux（`#if canImport(SwiftUI)` 守卫）
- 工具链版本：Swift 5.9
- 依赖管理：SwiftPM（`Package.swift`）+ XcodeGen（`project.yml` → `Intatis.xcodeproj`）。v0.1 **零第三方依赖**。
- 凭据 / 配置：Keychain（service `com.intatis.app`/`com.intatis.ios`，默认 account `default-openai`，新增 provider 独立 account；启动态/设置页只做不返回 secret data 的存在性检查，设置页用圆点占位提示已有 key；真实 provider 请求懒加载并进程内缓存 secret，Keychain miss 时 macOS 兼容 auth JSON 与 OpenCode-compatible config `options.apiKey`）+ UserDefaults（规范主键 `intatis.providerCatalog.v1`，provider 保存 `baseURL` + `chatEndpoint` + secret ref 元数据；聊天页当前选择保存到 `intatis.providerSelection.v1`；旧 `intatis.baseURL`、`intatis.model` 为迁移/兼容镜像）+ macOS 高级 JSON/JSONC 配置（`INTATIS_CONFIG` / `~/.config/intatis/opencode.json` / `~/.config/intatis/intatis.json` / `~/.config/opencode/opencode.json`，旧 `config.json` 兜底兼容读取；auth JSON 默认 `~/.local/share/intatis/auth.json`，并兼容 `~/.local/share/opencode/auth.json`）

## 构建

### SwiftPM（库 + CLI）

```sh
swift build                 # Debug
make build                  # 同上
swift build -c release      # Release
make release                # 同上
make install                # 符号链接到 BINDIR
```

### XcodeGen（.app bundle）

```sh
make app                    # xcodegen generate && open Intatis.xcodeproj
```

## 测试

```sh
swift test                  # 全部无头 XCTest
make test                   # 同上
swift test --filter IntatisCoworkTests
swift test --filter AutomaticPermissionReviewTests
swift test --filter IntatisPermissionTests/ReviewerTests
swift test --filter IntatisConversationTests
```

- 测试 target（10）：`Packages/<Mod>/Tests/`。`IntatisSharedUI` 无测试。
- `swift test` 无头：无测试 target 依赖 UI/app target。

## Lint / Format

仓内无显式 lint/format 配置。`UNKNOWN` — 是否有 SwiftFormat/SwiftLint 需后续确认。建议至少 `swift build` 通过。

## 手动验证矩阵

| 场景 | 步骤 | 预期 | 状态 |
|---|---|---|---|
| IntatisMac chat | `make app` → Xcode 运行 IntatisMac → chat 发消息 | 流式回复 | UNKNOWN（需真机 + key） |
| IntatisMac cowork | Xcode 运行 IntatisMac → cowork → @mention | agent 间路由 + 权限卡片 | UNKNOWN |
| IntatisMac multimodal | Xcode 运行 → 图像/转写 | artifact 写入 + 事件 | UNKNOWN |
| IntatisMac 多 provider/model 设置 | 设置页新增 provider → 填 Base URL 或 Chat endpoint/API key → 新增/选择 model → 保存 → Chat/Code/Cowork 新请求 | Base URL 与 Chat endpoint 互相同步；metadata 写入 UserDefaults catalog；API key 写入对应 Keychain account；已有 key 显示圆点占位；新请求使用选中 provider/model/chat endpoint | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisMac 高级 JSON provider 配置 | 设置页点击 Open JSON → 编辑生成/打开的 `~/.config/intatis/opencode.json`、现有 `~/.config/opencode/opencode.json`（或 `INTATIS_CONFIG` 指定文件），按 OpenCode-compatible `enabled_providers` + `model` + `provider` map 配置 provider/model，并用 `options.apiKey` 的 OpenCode 原生明文、`{env:NAME}` 或 `{file:path}` 指向 secret → 重启或保存后发 chat | JSON/JSONC catalog 覆盖 UserDefaults；旧 `config.json` 与 direct `providers` 数组仍可读取但 Open JSON 优先生成/打开 `opencode.json`；模板含 `$schema` / `enabled_providers` / `npm` / `options.baseURL` / `models` 且不含明文 API key；真实请求按 env/file/Keychain/auth JSON/OpenCode config 取 secret；未把 key 写入 UserDefaults | 构建通过；真实文件/key UNKNOWN |
| IntatisMac Chat 模型切换 | Chat 页打开模型菜单 → 选择另一个 provider/model → 发送下一条消息 | 菜单按 provider 分组；选择写入 `intatis.providerSelection.v1`；`ProviderRegistry` 立即重建；下一条 chat 使用新 provider/model；高级 JSON 文件不被自动改写 | 构建通过；真实 endpoint/key UNKNOWN |
| `/goal` Chat 标签 | Chat 输入 `/goal ship v0.12` → 发送 | 用户消息显示 Goal 标签；消息正文为 `ship v0.12`；provider 收到清洗后的目标文本；事件 `user_message.payload.tags == ["Goal"]` 且 `goal == "ship v0.12"` | SwiftPM focused tests 通过；GUI 手动 UNKNOWN |
| `/goal` Code 标签 | Code 输入 `/goal inspect workspace` → 发送 | Code 用户气泡显示 Goal 标签；AgentLoop 收到清洗后的目标文本；事件保留 Goal 元数据 | SwiftPM focused tests 通过；GUI 手动 UNKNOWN |
| `/goal` Cowork mention | Cowork 输入 `/goal @Alpha inspect` 或 `@Alpha /goal inspect` | 两种写法都路由到 @Alpha；用户事件 `to == Alpha`，显示 Goal 标签，agent 收到 `inspect` | SwiftPM focused tests 覆盖 Orchestrator payload；GUI 手动 UNKNOWN |
| CLI Cowork `/auto` 自动权限审查 | `intatis cowork` → 输入 `/auto` → 触发需要权限的写入/attach → 输入 `/default` | `/auto` 创建 `@permission-reviewer`；权限请求先生成 `permission_review`；allow 时工具执行，ask_user/错误时回退终端确认；`/default` 移除审查者；hard deny 不调用审查者 | `AutomaticPermissionReviewTests` 通过；真实 provider/key 手动 UNKNOWN；GUI UI 未实现 |
| IntatisMac Keychain 提示 | 已有 key 时启动 app → 打开设置页 → 连续发送两条 chat | 启动和设置页不弹 Keychain 认证；旧 Keychain item 首次真实请求至多弹一次系统授权；同一进程内重复请求不应再次读取 Keychain | 构建通过；真机手动 UNKNOWN |
| IntatisiOS chat | Xcode 运行 IntatisiOS → chat | 流式回复，无工具/shell | UNKNOWN |
| IntatisiOS 多 provider/model 设置 | iOS Settings sheet 新增 provider/model → 填 Base URL 或 Chat endpoint/API key → 保存 → 发 chat | iOS 仍只链接 chat 子集；Base URL 与 Chat endpoint 互相同步；已有 key 显示圆点占位；新请求使用选中 provider/model/chat endpoint | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisiOS Chat 模型切换 | Chat toolbar 模型菜单 → 选择另一个 provider/model → 发送下一条消息 | iOS 仍只链接 chat 子集；选择写入 `intatis.providerSelection.v1`；下一条 chat 使用新 provider/model | 构建通过；真实 endpoint/key UNKNOWN |
| iOS 子集边界 | 检查 IntatisiOS 链接的 product | 不含 Tools/Permission/AgentKernel/Cowork | 已确认（project.yml） |
| 权限门硬 deny | worker 尝试 spawn_agent | 被拒 | 已有测试覆盖 |
| Cowork 循环 | A→B→A 委派 | 被拒 | UNKNOWN — 见 COWORK_PRINCIPLES §8 |

## 验证边界声明

- 文档任务：至少运行 `git diff --check` 与 `git status --short`；**未运行构建/测试**，须声明。
- 代码任务：按改动风险运行相称的 `make test` / `make build` / `make app`；改 Cowork/AgentKernel 必须加测试（见 `docs/COWORK_PRINCIPLES.md` §8）。

## 常见问题

- **Linux 构建**：`IntatisSharedUI` 用 `#if canImport(SwiftUI)` 守卫，包应能在 Linux 无头构建。
- **Cowork 原则 vs 实现**：当前实现与 `docs/COWORK_PRINCIPLES.md` 原则有已知差距（见该文档 §6"当前已知 Cowork 问题"）。改动前先核对差距清单。
