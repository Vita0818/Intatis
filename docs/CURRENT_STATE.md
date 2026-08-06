# CURRENT_STATE

文档状态：当前源码摘要
最近核对：2026-08-05
产品基线：v0.36（build 36）

## 版本与发行状态

- `HEAD` 与 `origin/main` 当前均为标题为 `v0.34` 的提交 `c4727c1`。仓库没有 Git tag；该
  commit 标题不是产品版本事实源，`project.yml` 把当前产品基线定义为 `0.36 (36)`。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 已推进为 `0.36 (36)`。两个仓库参考
  Info.plist、README、文档入口和发行脚本使用同一基线。
- 2026-08-05 已完成 macOS universal Release 与 iOS Simulator Debug 构建；本机
  `/Applications/Intatis.app` 已安装 `0.36 (36)` 的 ad-hoc Hardened Runtime 开发构建，旧
  `0.35 (35)` 位于废纸篓，可恢复。该本机安装不是 Developer ID 公证发行产物。
- macOS 只发行 `IntatisMac` Developer ID/direct-distribution 产品；不做 Mac App Store。
  `IntatisMacAppStore` 仍是 legacy source target，不进入默认构建、测试或 release gate。
- 用户宿主终端已报告两个有效 codesigning identity，其中 Developer ID Application 可被发行
  脚本选取；`Intatis-Notary` Keychain profile 也已配置。v0.36 最终 App/DMG 尚未完成 Apple
  notarization、staple 与 Gatekeeper 全链路，因此仍不得描述为正式 release。

## 当前产品面

### macOS

macOS 是完整产品：Chat、Code、Cowork、Settings 和本地诊断导出。

- Chat 使用无 Intatis Tools 的 `ChatLoop`，支持 OpenAI-compatible streaming、provider/model/
  variant 配置、provider-hosted search wire、citations、会话历史、图片生成与 artifact 投影。
  每次 Send 只按当前 exact route 的显式 capability 与 adapter dialect 可选地提供 hosted search；
  不支持、未知或未适配时在同一路由静默发送普通 Chat。
- Code 使用共享 headless `AgentRuntime.code`，提供工作区文件、patch、Git、managed
  terminal、Skills、外部 MCP、文档/媒体及浏览器工具。工具可见性、lease、权限和 durable
  execution ticket 在执行前逐层核对。
- Code/Cowork/CLI 的 `generate_image` 与 `edit_image` 已接入 macOS/CLI 高级配置顶层
  `image_model`。主 agent 根据用户意图决定是否调用普通工具；model-facing schema 不接受
  provider/model，宿主统一从配置解析。缺少 `image_model` 时明确返回未配置，不再使用隐藏的
  `dall-e-3` fallback。专用图片 provider 可以不声明任何推理模型，因而不会进入 Chat/Code/
  Cowork 模型菜单。`generate_image` 调用 OpenAI-compatible `images/generations`；`edit_image`
  接受工作区内单张 PNG/JPEG/WebP（最多 50 MiB）、prompt 与不同的 PNG 输出路径，经同一权限、
  WorkspaceLease、`PathConfinement` 和 durable tool execution 链调用 multipart `images/edits`，
  两者均只接受 `data[].b64_json` 输出。mask、多参考图与原地覆盖尚未支持。
- macOS Chat/Code/Cowork 与 iOS Chat 的 composer 已在 Send/Stop 左侧接入同一个语音输入按钮。
  第一次点击开始录音，第二次点击停止并通过顶层 canonical `transcription_model` 指定的 exact
  provider/model 调用 `audio/transcriptions`；转写结果追加到完成时仍然可编辑的当前草稿，不自动
  发送。单模型 recorded-file runtime 已按 Flotis 当前实现迁入：默认 WAV/16 kHz/mono，录音 generation、
  stale-file 清理、stop/file-size 校验、取消/cleanup 与 disk-backed upload body 均保留；不再强制设置
  AAC bitrate。compatible adapter 使用 multipart，exact OpenRouter adapter 使用 JSON-base64
  `input_audio`。字段缺失或 adapter 不受支持时明确失败，不使用当前 Chat 模型或固定模型 fallback。
  专用 transcription provider 可为空 `models`，不会进入推理模型菜单；没有新增设置页或第二套模型
  配置。录音只使用 owner-only、有时长/大小边界且必清理的临时文件，Send 前不进入 EventLog 或
  ArtifactStore。Flotis 的多模型对比、全局快捷键、review/clipboard 与输入法未迁入。macOS shipping
  target 同时保留 TCC usage description 与 Hardened Runtime 最小 audio-input entitlement；App
  Sandbox 和遗留 App Store target 均未改变。
- Cowork 使用 `Orchestrator`、FIFO scheduler、MessageBus/Mediator、WorkTask/Goal、
  per-agent exact inference binding、独立 permission reviewer 与 goal verifier 控制面。
  AgentLoop 不同步递归调用另一个 AgentLoop。右侧 Agents 区域中的 ordinary agent 可作为
  当前窗口的只读对话选择；列表保留 session 历史上所有 durable agent，detached identity 继续
  可点击并由原状态图标显示已移除，当前选择不会跳回 `@main`。新窗口默认显示 `@main`，
  `@permission-reviewer` 等控制面 identity 仍为不可选择的状态项。
- Cowork 中每个 agent 的文件、Git、文档、浏览器文件与 terminal 工具仍只作用于自己的单一
  `workspaceRoot`。具有 `spawn_agent` 的 coordinator 提示词会在预知目标位于根外或收到
  out-of-workspace denial 后停止直接重试，改为按目标绝对目录创建默认只读的子 agent，再用
  `delegate_task` 交付目录内工作；确需修改时才请求 `read_write`。工具不可用或扩展被拒时只报告
  所需目录/访问级别的 blocker，不伪称完成；Code 与普通 worker 不宣称该恢复能力。
- Cowork coordinator 的固定提示词以主动执行为默认：每轮先建立 execution objective、交付物、约束
  与验证方式，检查 catalog 并激活/读取明确相关的 exact Skills；非简单任务维护最小 WorkTask DAG，
  在开始时识别适合并行、专业复核、多模态或独立 workspace 的分支并在收益成立时尽早委派，child
  运行期间继续自己的关键路径，最终验证报告、结算 WorkTask 并持续推进到验证完成或真实 blocker。
  该行为不自动创建 durable Goal，也不改变最小团队、工具、lease、权限或 worker 能力边界。
- Settings 已收敛为渐进披露结构，保留 provider、模型、MCP、renderer、声明、配置和本地
  诊断 ZIP。诊断包尝试采集系统/App/session 诊断源，但排除原始会话、工具参数/结果、
  endpoint、credential、workspace、artifact、browser profile 与 bookmark；不远程上传。

### iOS

iOS 是结构性 Chat 子集，只链接 Core、Protocol、Providers、Conversation、Artifacts、
Multimodal 与 SharedUI。它支持 provider 配置导入、Chat/history、当前托管搜索 wire、
citations、图片生成、输入栏语音转写和当前系统原生界面，但不链接 Tools、Permission、AgentKernel、Cowork、
MCP 或本地 workspace/shell。其 Chat 与 macOS 共用同一个 exact-route hosted-search planner。

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

## Chat 托管搜索

- 搜索只属于当前所选 exact Chat route。该 route 明确支持时，向当前模型
  提供厂商对应能力并以 `tool_choice: auto` 让它自行决定是否搜索；不支持、未知或未适配时，当前
  模型静默发送普通 Chat，不显示提示或错误，不执行任何模型/服务/tool fallback。
- v0.31 引入的 `web_search_model` / `webSearchModel` 后台路由行为已取消。runtime 不读取它
  覆盖当前选择或发起额外模型请求；为旧配置兼容可继续 decode/preserve，但字段运行时无效、无
  警告，新生成配置不再主动加入。
- `Capability.hostedWebSearch` 与 MCP `toolSearch` 已分离；`ProviderRegistry.chatRuntimeRoute()` 先验证
  普通 Chat adapter，再按 exact model capability 与 exact adapter 规划 dialect。OpenRouter 使用
  `openrouter:web_search`，OpenAI Responses encoder 使用 `web_search`，compatible/legacy/custom
  默认关闭，因此不会再为了探测能力先发送可能失败的搜索请求。
- 只有 provider-specific 结构化 unsupported code/parameter 且首个有效 payload 尚未被接受时，
  provider 才允许在同一 provider/model/variant 上重发一次普通 Chat；裸 404、自由文本和 partial
  payload 都不会触发重放。完整合同与当前 adapter 边界见 `docs/CHAT_HOSTED_SEARCH.md`。

## UI 与内容渲染

- macOS/iOS 当前使用系统语义表面和原生 Liquid Glass；正常 assistant/agent 正文直接落在
  conversation canvas，结构化状态、用户消息、错误、权限、Goal/Task 使用 Material 边界。
- iOS 与 macOS 已统一品牌/session/Settings 的 serif 标题和系统 sans 正文/控件，两端使用
  model/usage + action/input/voice/Send-or-Stop 的两排 composer；voice 始终紧邻主操作左侧，
  不占用或复制唯一的 Send↔Stop 槽位。
- rich text 使用仓内经审计的 Microsoft SwiftStreamingMarkdown thin derivative 与
  exact iosMath Apple-native 数学排版；plain-safe 仍是运行时救援路径。
- macOS Chat/Code/Cowork history 使用最多 16-row eager page 与显式分页，避免旧的 rich +
  lazy session-entry layout cycle。旧性能数字只保留在 Git/report 历史，不是当前 release
  readiness 证明。
- Cowork 不再把完整 `CodeProjection.items` 发布给 MainActor，也不在点击时扫描/过滤完整
  历史。Conversation actor 在 fold 时维护 typed per-agent index；每个窗口只持有选中 agent
  的一个最多 16-row page、独立分页边界和 stale-request generation。非选中 agent 的增量
  不会刷新当前 transcript，查看选择也不改变 runtime、scheduler、mailbox、lease 或发送目标。
- Cowork roster 现分成 EventLog-derived historical identity catalog 与 live operational roster：
  前者驱动 stable-ID lazy Agents 列表和只读 conversation selection，后者独占 send/delegate/
  message/ask/rebind/remove、settings 与 workspace/capability 操作。presentation 会先按 agent
  线性聚合 task/lease/status，避免历史 agent 数量增长后形成 agent×task/lease 重扫。Agents
  使用 durable 首次 admission 的创建顺序；status、消息、detach 或 reattach 不会触发重排。
- Cowork thread header 只显示 session durable name。宽屏 rail 继续作为同一 conversation canvas
  的 trailing overlay；outer rail 固定 348pt、glass card 固定 318pt，并使用系统 `Glass.clear`
  降低独立光块感，不增加整栏背景、手绘阴影或渐变。Agents 使用更大的系统文字，选中态只保留
  accent 蓝色背景，不再叠加勾选图标；顶部 compact permission 只显示状态、tool、安全摘要与必要
  action，不展示 risk chip、raw arguments 或默认展开详情。
- Cowork thread header 不再提供独立 MCP Content 快捷按钮；内容浏览保留在
  `Project Settings → MCP → Browse Content`。右侧 status rail 显隐开关使用系统 compact 圆形
  glass/bordered icon control；这两项只改变 header chrome，不进入 rail overlay、固定宽度或
  render-boundary 输入。
- rail 现在是 thread 上不参与布局协商的 `.overlay(alignment: .trailing)`，并关闭 inspector
  transaction 的隐式动画。rail 由只包含 rail 输入的 Equatable render boundary 隔离；thread 的
  empty/loading/page/rich 状态不能重新物化 cards。每个 passive `Glass.clear` 都位于自己的稳定
  backdrop，独立 status cards 不再放入会融合/重组 shape 的 `GlassEffectContainer`；系统动态
  separator 的单物理像素 `strokeBorder` 继续作为轮廓锚点，不使用固定 RGB、渐变、投影或自绘高光。
- Code/Cowork 的 raw bottom-anchor 恢复不再通过 GeometryReader、屏幕全局坐标或
  `PreferenceKey` 回写布局；系统 `onScrollVisibilityChange` 只在 anchor 可见性真正变化时提交
  observation。窗口移动、focus 或全屏变化因此不会仅因 screen origin 改变而触发 thread 布局链。
- Cowork transcript 复用一个固定 ScrollView 根和最多 16 个稳定行槽。agent/page 切换及选中
  agent 的连续增量期间先显示轻量 raw text；同一选择和内容静止 300 ms 后才重新准入 rich
  Markdown，避免快速点击或 streaming 为每次更新挂载新的 AppKit 文本/选择子树。content/raw
  frame 在 ScrollView 扩展到 overlay 下方前固定，因此 Agent 内容、空态和 scroller 可见性都不会
  改变中栏或 composer 的水平边界。

## 持久化与安全边界

- session EventLog、workspace bookmark、artifact、browser profile、inference catalog 和
  provider/auth 配置各有独立 owner、权限和 schema 边界；bookmark bytes 不进 JSONL。
- SecretScanner、Mediator、Keychain/credential resolver、Hardened Runtime、managed
  terminal Seatbelt/default-network-deny 与 iOS linkage boundary 均保留。
- 旧 schema 与未知 future event 的兼容/fail-closed 规则不得因文档或版本更新而改变。
- 第三方代码、prompt、字体和依赖来源以 `NOTICE.md`、`ThirdPartyNotices/`、vendor ledger
  与 `docs/OPEN_SOURCE_REUSE.md` 为准。本轮版本/文档校准没有新增依赖。

## 最近验证状态

- 2026-08-05 Flotis 单模型语音 runtime 迁移：`ComposerVoiceInputTests` 6/6，覆盖 draft merge、
  WAV 16-bit PCM 及 WAV/M4A 均不注入 `AVEncoderBitRateKey`；
  `IntatisProvidersMultimodalTests` 22/22，覆盖 owner-only disk-backed multipart WAV、OpenRouter
  JSON-base64 `input_audio`、exact runtime route、严格 JSON Content-Type、timeout 与错误 payload。
  完整 `swift test`、XcodeGen、版本一致性检查、`IntatisMac` macOS Debug 和 `IntatisiOS` generic
  Simulator Debug unsigned build 均通过；两端最终 bundle 含麦克风 usage description。先前本地
  ad-hoc macOS Debug 签名包已读回 `com.apple.security.device.audio-input=true` 且 strict codesign
  verify 通过，但这不替代正式 Developer ID/Hardened Runtime/公证验证。未执行真实麦克风或线上
  transcription provider smoke，也未启动 App 做视觉检查，因而真实权限交互、设备录音、具体
  provider/model 可用性、计费和像素表现仍为 `UNKNOWN`。
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
- 2026-08-03 Cowork agent-thread 专项：Debug fixture 使用 8 个 selectable agent、每个 1,000
  条记录、4-agent 合计 500 canonical delta/s，先完成 1,000 次 rapid switch，再完成 180 秒
  10 Hz nominal soak（实际 1,486 次 timed switch）；Computer Use 观测为 0 main-thread warning、
  0 incident，结束时仍只挂载 16 条，`NSTextViewSharedData` 为 14、`GestureNode` 为 173。
  `vmmap` physical footprint 为 62.1 MiB、峰值 74.8 MiB；`ps` RSS 为约 156.6 MiB。两者口径
  不同，均未出现旧实现的线性增长。本 fixture 是 offline presentation stress，不替代真实
  provider/EventLog/低端设备长时矩阵。
- 2026-08-04 historical roster 修正：512 identity 投影用例在 detach 500 个后仍保留 512 个
  历史项且 live roster 仅 12 个；detached selection、512-ID presentation catalog、lazy/unfiltered
  rail 与 read-only operation fence 的定向测试通过，IntatisConversationTests 172/172、IntatisMac
  Debug unsigned 构建通过。Computer Use 实测 detach 当前 `@research` 后不跳回 main，离开再返回
  仍可查看 985–1,000 / 1,000；随后在 500 delta/s 下完成 1,000 rapid switches，0 warning / 0
  incident，仍只挂载 16 rows。
- 2026-08-04 rail lighting/fixed-geometry 修正：`ThreadLayoutTests`、
  `CoworkInferencePresentationTests` 与 `CoworkAgentThreadPresentationModelTests` 组合共 30 tests /
  0 failures；IntatisMac 与 IntatisiOS Simulator Debug unsigned build 通过。1372×768 原生 Light
  对照中，`@main` / `@research` 的 composer 像素边界一致，rail 均位于 x=1076…1365；8×1,000
  rows + 500 delta/s 下再次完成 1,000 rapid switches，0 warning / 0 incident、最多 16 rows。
  该次没有重跑 180 秒 soak、Dark、Reduce Transparency、Increase Contrast 或完整 SwiftPM suite。
- 2026-08-04 rail window-stability 第一版结论已被用户复现结果推翻，不再作为当前通过证据。
  后续真实 Test session 日志证明旧 `IntatisThreadViewportFramesPreferenceKey` 在全屏变化时仍会同帧
  重复更新；仅做像素相位修正不能解决问题，相关旧截图/数值只保留为历史排查记录。
- 2026-08-04 上述第二版 corrective pass 随后也被用户在新构建中稳定复现结果推翻：删除 viewport
  preference 与 shared glass container 仍不够，因为 trailing overlay 的几何宿主仍是会随 transcript
  更新的 `threadColumn`，且 `selectedAgentID` 仍在整个 rail 的 Equatable snapshot 中；每次点击都会
  让所有原生 glass section 重新进入更新周期。当前源码改为由 exact outer-detail canvas 分别托管
  leading thread 与 trailing rail，thread 不再是 rail 的 alignment guide；selection 从 rail snapshot
  中移除并通过独立轻量状态只更新蓝色行背景/无障碍 value；每个 `Glass.clear` backdrop 也成为
  content-independent Equatable view。`ThreadLayoutTests|CoworkInferencePresentationTests|
  CoworkAgentThreadPresentationModelTests` 31/31 通过，其中 production-shaped host 完成 360 次
  agent selection/mode/inspector/window-size 交错变化；IntatisMac macOS Debug 与 IntatisiOS generic
  Simulator Debug unsigned build 通过。按用户要求不使用 Computer Use 或截图采样，真实视觉是否消除
  数像素光学跳变仍需用户在新构建中确认，不能沿用前两版的截图/AX 结论。
- 同日 Codex managed sandbox 内的完整 `swift test --disable-sandbox --quiet` 仍只有
  `IntatisToolsTests` 的 process/Seatbelt/loopback 用例受宿主限制失败；单独完整
  `IntatisSharedUITests` 一次在 build 后无用例输出并被中止，当前修改直接覆盖的 SharedUI 定向
  用例均独立通过。不得把这次 sandbox 运行记成全量通过。
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
4. `@ai-sdk/openai` 的普通 Chat adapter 仍未实现，所以该 exact adapter 即使声明
   `hosted_web_search` 也会按既有规则在网络前 config fail closed；在普通 adapter 完成前不能把
   已有 OpenAI Responses search encoder 宣传为完整 native OpenAI route 支持。真实厂商 smoke 仍待
   用户凭据环境验证。

## 文档治理

当前文档入口和历史分类见 `docs/README.md`。`CURRENT_STATE.md` 从本轮开始只保留当前摘要；
已完成阶段、旧测试数字和事故调查留在 Git 历史及 dated reports，不再无限追加到这里。
