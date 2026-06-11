# Intatis

一个 clean-room 的本地 AI 工作台：**Chat + Cowork + Code** 三合一，底层是同一个
headless Agent Kernel。完整设计见 [`ARCHITECTURE.md`](ARCHITECTURE.md)，clean-room
声明见 [`NOTICE.md`](NOTICE.md)。

本仓库当前包含 **v0.1（Chat）** 与 **v0.2（Code）**——一条 kernel 化的聊天脊柱，加上单 workspace、带权限闸的 coding agent。

---

## v0.1 包含什么

一个流式聊天 app，但从第一天起数据路径就是
`Composer → Command → Kernel（进程内）→ Provider → Event Log → projection → UI`，
**而不是**让视图直接调 API。正是这条纪律让 v0.2（Code）与 v0.3（Cowork）成为增量叠加而非重写
（ARCHITECTURE.md §7.1）。

已包含：

- OpenAI-compatible 流式聊天（SSE），且多端点 / 多 wire 的接缝已经就位
  （`WireFormat`、`ProviderEndpoint`、`ModelRef`）。
- append-only 的每会话事件日志（JSONL）作为唯一真相源，支持 replay + resume。
- Codex App 风格的三栏 SwiftUI 外壳（sidebar / thread / inspector）。
- API key 存入 Keychain。
- Artifact store 骨架（附件 / 转写）。

**v0.1 暂未包含**：多 Agent（v0.3）、多模态（v0.4）、iOS（v0.5）。

---

## v0.2 包含什么（Code）

单 workspace 的 coding agent：模型可调工具读写本地文件，每个工具调用先过确定性权限闸。

已包含：

- 工具：`read_file` / `list_files` / `search_text` / `write_file` / `apply_patch`（unified diff applier）/ `run_shell` / `git_status` / `git_diff`，每个都过**路径围栏**（`..`、越界、symlink 逃逸一律拒绝）。
- OpenAI function-calling：流式 `tool_calls` 按 index 累积装配。
- 确定性权限闸（A 层）：密钥 / `.env` / 越界 / `sudo` 等硬 `deny`；只读自动 `allow`；写 / patch / shell 默认回到用户确认（reviewer 是 v0.3）。
- 单 Agent 工具循环：`流式 → tool_call → 权限 → 执行 → observation → 续`，带迭代上限。
- Code 三栏界面：tool-call 卡、permission 卡（`apply_patch` 内联显示 diff，Approve/Reject 即 accept/reject）、patch / terminal 输出；workspace 选择（security-scoped）。

> **git 注意**：v0.2 的 `ProcessGitService` 通过 spawn `git` 实现，适用于 Developer-ID / `swift run` 开发。App Store 沙盒构建需换成进程内 libgit2 后端（已在 `GitService` 协议后留好接缝）。

---

## 目录结构

| 路径 | 模块 | 职责 |
|------|--------|------|
| `Packages/IntatisCore` | IntatisCore | ID、`SessionKind`、`SideEffect`、`PlatformProfile`、错误类型 |
| `Packages/IntatisProtocol` | IntatisProtocol | `Envelope`、`Event`、`Command`、JSON-RPC 词汇 |
| `Packages/IntatisProviders` | IntatisProviders | capability provider + OpenAI wire + SSE + registry |
| `Packages/IntatisArtifacts` | IntatisArtifacts | artifact store |
| `Packages/IntatisConversation` | IntatisConversation | 事件日志、projection、**无工具的 `ChatLoop`**、`CodeProjection` |
| `Packages/IntatisTools` | IntatisTools | 路径围栏 + 文件 / git / shell 工具（哑执行器）|
| `Packages/IntatisPermission` | IntatisPermission | 确定性权限闸 + SecretScanner + profiles |
| `Packages/IntatisAgentKernel` | IntatisAgentKernel | Agent + ContextBuilder + 工具循环 |
| `Packages/IntatisSharedUI` | IntatisSharedUI | SwiftUI 三栏外壳 + `ChatViewModel` + Code 视图 |
| `Apps/IntatisMac` | IntatisMac | macOS app：接线、Keychain、entitlements、Code 接线 |

单一根 `Package.swift`；模块 == target；target 依赖强制 ARCHITECTURE.md §2.1 的无环依赖图。

> **注意：** 这份代码是在没有本地 Swift 工具链的环境下编写的（沙盒里没有 Swift，且 SwiftUI
> 只能在 Apple 平台编译）。代码按可编译的方式组织，并带完整 XCTest 测试，但请**先在你的 Mac 上
> 跑 `swift build` / `swift test`**，并像对待任何"第一次编译"那样，预期需要修一些小问题。

---

## 构建、测试、运行（macOS 13+）

无 UI 的模块（Core / Protocol / Providers / Artifacts / Conversation）可直接命令行构建与测试：

```bash
swift build
swift test            # 运行下方的 XCTest 套件——无需联网
```

启动 GUI：

```bash
swift run IntatisMac
```

首次启动时，粘贴一个 OpenAI-compatible API key（存入 Keychain）。默认：端点
`https://api.openai.com/v1`，模型 `gpt-4o-mini`——可在
`Apps/IntatisMac/Sources/AppConfig.swift` 修改。

若需要正式签名的 `.app`（沙盒 / entitlements），把这些 package 包进一个 Xcode macOS App
target 并附上下面的 entitlements。上面的 SwiftPM 可执行文件用于开发调试。

---

## 分发：两个构建，一个 capability 开关

`run_shell` 是唯一被 App Store 沙盒卡死的操作（ARCHITECTURE.md §9.1）。因此：

| 构建 | `AppConfig.platformProfile` | Entitlements | Shell |
|-------|------------------------------|--------------|:---:|
| Mac App Store（沙盒） | `.macAppStore` | `IntatisMac.AppStore.entitlements` | ✗ |
| Developer-ID（公证） | `.macDeveloperID` | `IntatisMac.DeveloperID.entitlements` | ✓ |

v0.1（Chat）可顺利上架 App Store。v0.2 的 git 工具目前用 spawn `git`（开发用）；要在
App Store 沙盒内运行，需把 `GitService` 换成进程内 libgit2 后端（接缝已留好）。`run_shell`
在 `.macAppStore` profile 下被权限闸直接 `deny`。

---

## 测试覆盖

v0.1：

- **Core** —— profile 预设、ID 裸字符串编码、ID 生成。
- **Protocol** —— 每种事件类型的 `Envelope` round-trip；扁平 wire 形状；`Command`
  round-trip + method 字符串。
- **Providers** —— SSE 跨任意 chunk 边界重组；OpenAI 流式 → delta + done；registry
  解析 + 未知端点报错。
- **Artifacts** —— 添加 / 读取 / 重载后持久化；缺失 artifact 报错。
- **Conversation** —— append/replay/resume 的 seq 连续性；`replay(from:)`；stream
  先回放再实时；`ChatLoop` 流式 + projection；跨轮次历史。

v0.2：

- **Protocol（v0.2）** —— 新增 6 个事件 + 2 个命令 round-trip；`JSONValue` round-trip。
- **Providers（tool-calling）** —— 流式 `tool_calls` 跨 fragment 装配；纯文本流；消息 JSON 形状。
- **Tools** —— 路径围栏（越界 / 绝对 / `..` 折叠）；unified diff 解析 + 应用 + 不匹配拒绝；
  porcelain 解析；文件读写列搜；`apply_patch` 改文件；shell / git 注入 fake。
- **Permission** —— SecretScanner / ShellInspector；gate 各分支（读 allow、写 reviewed→pass、
  manual→ask、`.env`/越界/沙盒 shell/`sudo` deny、`ls` allow、locked deny）；engine 降级与
  reviewer 路由。
- **AgentKernel** —— 批准写执行并产事件；拒绝写不执行；只读工具免确认。
- **Conversation（Code）** —— `CodeProjection` 折叠 tool/result/patch/agent 事件。
