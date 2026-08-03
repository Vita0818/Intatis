# CURRENT_STATE

文档状态：当前源码摘要
最近核对：2026-08-03
产品基线：v0.32（build 32）

## 版本与发行状态

- `HEAD` 与 `origin/main` 当前均为里程碑提交 `v0.32`。仓库没有 Git tag；commit 标题只作
  里程碑证据，产品版本事实源是 `project.yml`。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 已从长期滞留的 `0.12 (1)` 校准为
  `0.32 (32)`。两个仓库参考 Info.plist、README、文档入口和发行脚本使用同一基线。
- macOS 只发行 `IntatisMac` Developer ID/direct-distribution 产品；不做 Mac App Store。
  `IntatisMacAppStore` 仍是 legacy source target，不进入默认构建、测试或 release gate。
- 用户宿主终端已报告两个有效 codesigning identity，其中 Developer ID Application 可被发行
  脚本选取；`Intatis-Notary` Keychain profile 也已配置。v0.32 最终 App/DMG 尚未完成 Apple
  notarization、staple 与 Gatekeeper 全链路，因此仍不得描述为正式 release。

## 当前产品面

### macOS

macOS 是完整产品：Chat、Code、Cowork、Settings 和本地诊断导出。

- Chat 使用无工具 `ChatLoop`，支持 OpenAI-compatible streaming、provider/model/variant
  配置、透明 hosted web search、citations、会话历史、图片生成与 artifact 投影。
- Code 使用共享 headless `AgentRuntime.code`，提供工作区文件、patch、Git、managed
  terminal、Skills、外部 MCP、文档/媒体及浏览器工具。工具可见性、lease、权限和 durable
  execution ticket 在执行前逐层核对。
- Cowork 使用 `Orchestrator`、FIFO scheduler、MessageBus/Mediator、WorkTask/Goal、
  per-agent exact inference binding、独立 permission reviewer 与 goal verifier 控制面。
  AgentLoop 不同步递归调用另一个 AgentLoop。
- Settings 已收敛为渐进披露结构，保留 provider、模型、MCP、renderer、声明、配置和本地
  诊断 ZIP。诊断包尝试采集系统/App/session 诊断源，但排除原始会话、工具参数/结果、
  endpoint、credential、workspace、artifact、browser profile 与 bookmark；不远程上传。

### iOS

iOS 是结构性 Chat 子集，只链接 Core、Protocol、Providers、Conversation、Artifacts、
Multimodal 与 SharedUI。它支持 provider 配置导入、Chat/history、托管搜索、citations、
图片生成和当前系统原生界面，但不链接 Tools、Permission、AgentKernel、Cowork、MCP 或
本地 workspace/shell。

### CLI

Swift-native `intatis` 提供 Chat/Code/Cowork REPL、managed execution、Skills、per-agent
profiles 与外部 MCP client。macOS/Linux 的 stdio、sandbox、bwrap/guard 和 PTY 能力按
实际 host 支持情况 fail closed。

## 当前架构事实

- 根 SwiftPM 图包含 14 个公共 library products、3 个内部 C/guard targets、CLI、开发期
  MCP conformance executable 和 14 个 test targets。精确清单以 `Package.swift` 为准。
- `EventLog` 的 append-only JSONL 是 session canonical truth；`session.json` 是可重建的
  schema-v2 projection，artifact 使用独立 blob/index store。
- Chat/Code/Cowork 都从稳定 `TurnID` 和结构化事件投影 UI。App 窗口只持有选择；macOS
  runtime 由进程级 `AppSessionRuntimeManager` 按 exact session key 持有。
- Code/Cowork 的工具调用必须经过 ToolRegistry、CapabilityLease、WorkspaceLease、
  PathConfinement、DeterministicPolicyGate、ModelPermissionReviewer、PermissionEngine 和
  durable tool execution。明确 hard deny 不能被 reviewer 放宽。
- production registry 不暴露 raw `run_shell`；shell-capable host 使用 runtime-owned
  `exec_command` / `write_stdin` managed terminal，默认断网并保留进程清理与输入清洗。
- Skills 只提供冻结上下文，不授予权限；外部 MCP 是 client-only，HTTP/stdio transport、
  OAuth/callback/task 和 process ownership 仍受产品边界与权限控制。
- Provider catalog 保留 model options/variant/adapter 语义；credential 只从受控 reference
  懒加载，不进入 EventLog、projection、诊断包或文档。

## UI 与内容渲染

- macOS/iOS 当前使用系统语义表面和原生 Liquid Glass；正常 assistant/agent 正文直接落在
  conversation canvas，结构化状态、用户消息、错误、权限、Goal/Task 使用 Material 边界。
- iOS 与 macOS 已统一品牌/session/Settings 的 serif 标题和系统 sans 正文/控件，两端使用
  model/usage + action/input/Send-or-Stop 的两排 composer。
- rich text 使用仓内经审计的 Microsoft SwiftStreamingMarkdown thin derivative 与
  exact iosMath Apple-native 数学排版；plain-safe 仍是运行时救援路径。
- macOS Chat/Code/Cowork history 使用最多 16-row eager page 与显式分页，避免旧的 rich +
  lazy session-entry layout cycle。旧性能数字只保留在 Git/report 历史，不是当前 release
  readiness 证明。

## 持久化与安全边界

- session EventLog、workspace bookmark、artifact、browser profile、inference catalog 和
  provider/auth 配置各有独立 owner、权限和 schema 边界；bookmark bytes 不进 JSONL。
- SecretScanner、Mediator、Keychain/credential resolver、Hardened Runtime、managed
  terminal Seatbelt/default-network-deny 与 iOS linkage boundary 均保留。
- 旧 schema 与未知 future event 的兼容/fail-closed 规则不得因文档或版本更新而改变。
- 第三方代码、prompt、字体和依赖来源以 `NOTICE.md`、`ThirdPartyNotices/`、vendor ledger
  与 `docs/OPEN_SOURCE_REUSE.md` 为准。本轮版本/文档校准没有新增依赖。

## 最近验证状态

- 2026-08-03：`xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过。
- `IntatisMac` unsigned universal Release 构建通过；最终 bundle 为 `0.32 (32)`，可执行文件
  同时包含 `arm64` 与 `x86_64`。该构建用于源码与元数据验收，不是可分发签名产物。
- `IntatisiOS` generic Simulator Debug 构建通过；最终 bundle 为 `0.32 (32)`。两端构建仅有
  既有的 unused-result / deprecated `onChange` 警告，没有构建失败。
- `swift build` 在允许 Swift/Clang 写入用户缓存的宿主环境通过，覆盖 CLI 与 SwiftPM
  products；受限沙箱内的首次尝试仅因 module cache 无写权限而未进入源码编译。
- 上一轮外层 sandbox 外的 `IntatisToolsTests`：141 tests / 15 skipped / 0 failures。
- focused `IntatisAgentKernelTests`：169 tests / 0 failures。过期的 800-token soft-budget
  fixture 已改为保留充足真实 prompt 余量，同时继续验证 provider 忽略输出 ceiling 后的
  soft-budget overrun；生产 `requestTooLarge` 保护未修改，独立 admission/concurrency 回归仍保留。
- 完整 `swift test` 已在允许 Swift/Clang cache、process 与 loopback 测试的宿主环境通过；
  需要真实 browser/Git/provider/credential/network 的 opt-in 用例仍按声明跳过，不能冒充已验证。
- 直分发脚本已在用户宿主环境进入真实 Developer ID 构建/签名链路；一次开启代理/VPN的
  运行在 Apple notarization 网络阶段未完成，另一次先关闭代理/VPN的运行则在 SwiftPM
  克隆 `swift-system` 时因 GitHub 专用代理 `127.0.0.1:1082` 已停而失败。脚本现在支持
  `INTATIS_PAUSE_BEFORE_NOTARIZATION=1`：保持代理完成构建/签名，暂停后切换网络，并在不
  重建的情况下探测及重试 Apple notarization。
- Apple `notarytool history` 已确认两次 `Intatis-notary-upload.zip` 完整到达服务端，但查询时
  均长时间停在 `In Progress`；用户中断的是本地 `--wait`，没有取消服务端任务。旧脚本把
  JSON 结果重定向且无限等待，隐藏了实时状态，并在 Control-C 后删除临时签名 App。脚本现
  改为可见 upload + submission ID、默认 30 分钟有界 wait，以及 owner-only recovery state；
  超时/中断后可复用同一 App/DMG submission，不再重建或重复上传。旧的两条任务发生在持久
  recovery 加入前，即使之后 Accepted，也没有本地原 App 可直接完成 staple。最终 Accepted、
  staple 和 Gatekeeper 证据仍未取得。

## 当前已知缺口

1. 先等待现有两条 App submission 到达 terminal，期间不要继续重复上传；随后只运行一次
   新的可恢复两阶段流程，完成 App/DMG notarization、staple、codesign 与 Gatekeeper
   assessment，并记录最终 ZIP/DMG 和 SHA-256。在这些证据齐全前不能发布。
2. 真实 provider/key、第三方 MCP/OAuth、长时 browser/profile、VoiceOver/clipboard、低端
   iPhone/iPad 与长 soak 仍有环境矩阵空白；不得用离线 fixture 冒充。
3. macOS 27/Xcode 27 当前仍是 beta toolchain evidence；最低支持系统/设备的正式矩阵需要
   独立验证。

## 文档治理

当前文档入口和历史分类见 `docs/README.md`。`CURRENT_STATE.md` 从本轮开始只保留当前摘要；
已完成阶段、旧测试数字和事故调查留在 Git 历史及 dated reports，不再无限追加到这里。
