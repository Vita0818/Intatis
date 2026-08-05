# Intatis

当前版本：**v0.35**（build 35）
状态：pre-1.0；源码与构建可验证，v0.35 Developer ID 发行候选尚待完成最终公证验收。

Intatis 是 Apple-first、Swift-native 优先的本地 AI 工作区。macOS 提供 Chat、Code、
Cowork 三个产品面；iOS 是严格的 Chat 子集；CLI 提供 headless Code/Cowork 和外部 MCP
client。所有运行时能力围绕结构化 EventLog、共享 AgentKernel、显式工具注册和权限链
组织，而不是让 UI 直接调用模型或本地执行器。

当前文档入口见 [`docs/README.md`](docs/README.md)，版本规则见
[`docs/VERSIONING.md`](docs/VERSIONING.md)。历史 v0.1–v0.16 里程碑不代表当前产品版本。

## 当前产品面

### macOS

- Chat：OpenAI-compatible streaming、provider/model/variant 配置、透明 hosted web search、
  citations、会话历史、多模态产物和本地诊断导出。
- Code：单 workspace agent、文件/patch/Git、managed terminal、Skills、MCP、文档/媒体和
  浏览器工具；所有工具均经过 CapabilityLease、WorkspaceLease、PathConfinement 与权限链。
- Cowork：多 agent roster、FIFO scheduler、WorkTask/Goal、MessageBus/Mediator、per-agent
  exact inference binding、独立 permission reviewer 和 goal verifier 控制面。
- 设置：provider catalog、Intatis JSON/JSONC 配置、MCP、renderer fallback、第三方声明，
  以及只在本机生成且不上传的脱敏诊断 ZIP。

macOS 唯一发行 target 是 `IntatisMac`，通过 Developer ID、Apple notarization 和直接下载
分发。`IntatisMacAppStore` 是未删除的 legacy target，不属于产品或 release gate。

### iOS

iOS 只链接 Core、Protocol、Providers、Conversation、Artifacts、Multimodal 和 SharedUI。
它支持 Chat、provider 配置导入、会话历史、托管搜索、citations 和图片生成，但不链接
Tools、Permission、AgentKernel、Cowork、MCP 或本地 workspace/shell。

### CLI

`intatis` 支持 Chat/Code/Cowork REPL、managed execution、Skills、per-agent inference
profiles 和外部 MCP client。macOS/Linux 平台能力与 sandbox/guard 可用性按 host fail closed。

## 核心不变量

- `EventLog` JSONL 是 session canonical truth；projection 和 `session.json` 都可重建。
- Chat 无工具；Code/Cowork 的每个工具调用必须先经过 ToolRegistry、lease 和三层权限门。
- Cowork 不递归同步调用 `AgentLoop`；通信、委派和调度通过 mailbox/scheduler/event flow。
- secret 只从受控 credential reference 懒加载，不进入 EventLog、诊断包或仓库文档。
- iOS 是结构性子集，不靠运行时开关隐藏本地 agent 能力。
- 第三方源码和依赖必须固定 provenance、许可证并更新 `NOTICE.md`。

详细合同见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和
[`docs/DO_NOT_BREAK.md`](docs/DO_NOT_BREAK.md)。

## 仓库结构

```text
Apps/                 macOS、iOS 与 CLI 入口
Packages/             14 个公共库、内部 C/guard target 与测试
Vendor/               经审计并固定的第三方派生源码
ThirdPartyNotices/    许可证、来源与资源清单
Tests/                MCP conformance 与独立 parity fixtures
docs/                 当前规范和已标记的历史设计文档
scripts/              构建、验证、诊断和发行脚本
project.yml           XcodeGen 及产品版本唯一事实源
Package.swift         SwiftPM 产品、target 与测试图
```

精确 target 和入口见 [`docs/PROJECT_MAP.md`](docs/PROJECT_MAP.md)。

## 开发与验证

要求 Xcode 27 / Swift 6.x、XcodeGen，以及当前依赖可用。常用命令：

```sh
scripts/check-version-consistency.sh
swift test
xcodegen generate

xcodebuild -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

当前测试状态和环境限制以 [`docs/TESTING.md`](docs/TESTING.md) 为准，不以 README 中的
历史测试数量判断 release readiness。

## macOS 直接分发

正式发行需要本机 Keychain 中有效的 `Developer ID Application` identity，以及用户自行
保存的 `notarytool` profile：

```sh
INTATIS_NOTARY_PROFILE=<profile-name> scripts/package-macos-release.sh
```

如果 GitHub 需要代理/VPN、Apple notarization 又需要直连，使用两阶段模式：

```sh
INTATIS_PAUSE_BEFORE_NOTARIZATION=1 \
INTATIS_NOTARY_PROFILE=<profile-name> \
  scripts/package-macos-release.sh
```

保持代理/VPN 开启完成依赖解析、构建和签名；脚本明确提示后保持终端打开，关闭代理/VPN
再按 Return。它会先验证 Apple 可达性，失败时原地等待重试，不重新构建。上传进度和
submission ID 会直接显示；Apple 处理默认等待 30 分钟，仍为 `In Progress` 时保留签名
产物并打印 `INTATIS_RESUME_RELEASE_DIR` 恢复命令。恢复同一 submission，不要重复上传。

该脚本只有在 universal Release、Hardened Runtime、Developer ID 签名、App/DMG 公证、
staple、codesign 和 Gatekeeper assessment 全部通过后，才向 `dist/` 输出 ZIP、DMG 与
SHA-256 清单。不要把证书私钥、Apple 密码或 app-specific password 写入仓库或对话。

## 配置与数据

- macOS/CLI 高级配置读取 `INTATIS_CONFIG`、Intatis-owned JSON/JSONC 路径及兼容 fallback；
  不默认读取 OpenCode app 配置。
- session 数据默认位于用户 App Support 下，每个 session 使用 append-only EventLog。
- browser profile、workspace artifact、credential 和 bookmark 不应提交到 Git，也不会进入
  本地诊断 ZIP。
- 日志导出当前不做远程上传；Apple notarization 仅在用户显式运行发行脚本时发生。

## 许可证

Intatis 自有代码和第三方采用状态见 [`NOTICE.md`](NOTICE.md)、
[`ThirdPartyNotices/`](ThirdPartyNotices/) 与
[`docs/OPEN_SOURCE_REUSE.md`](docs/OPEN_SOURCE_REUSE.md)。
