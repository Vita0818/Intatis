# CURRENT_STATE

最近一次自查日期：2026-08-02

## 2026-08-02 iOS 与 macOS 设计语言统一及最新版图标

- iOS Chat shell 现在沿用 macOS 的同一视觉层级：抽屉为 `Intatis` 品牌标题、选中
  `Chat` 模式、`Recent` 会话/New 与底部 Settings；主区顶部只显示 sidebar、当前
  session 名称与 New，model 选择移入底部 composer。
- iOS composer 与 macOS 共用两排结构：第一排为关闭态只显示模型名的原生
  Liquid Glass `Menu`，有统计时在同排右侧显示 Context/Input/Cached/Output/Time；
  第二排保留 Chat-only paperclip 功能菜单、原生多行输入与唯一 Send/Stop 槽位。
- 字体合同已从上一轮 iOS 全局 serif 修正为与 macOS 一致的角色分工：仅品牌、session
  和 Settings 页面标题使用 Apple 系统 serif；正文、表单、按钮、菜单、输入及状态文字
  使用系统 sans。Markdown、代码与公式继续走共享 renderer 的语义字体，不新增字体资源。
- 根目录 2026-08-02 22:26:51 更新的 `Intatis.icon` 同时接入 `IntatisMac` 与
  `IntatisiOS`；iOS build 的 `Info.plist` 已声明 `CFBundleIconName=Intatis`，bundle
  含 iPhone/iPad 主图标，iPhone 17e Simulator 主屏幕已确认显示新版指针图标。
- focused `MessageRenderingTests|ThreadLayoutTests` 51/51、generic iOS Simulator Debug
  build 与 Light/Dark 运行态检查已通过；另检查了抽屉和 Settings。iOS 仍只链接
  Chat 子集，没有新增 Tools/Permission/AgentKernel/Cowork、workspace 或 shell 能力。

## 2026-08-02 macOS Settings 渐进披露收口

- macOS Settings 默认页现在只保留 provider 列表、Provider name、API key、Active
  model、Test Provider 与 Save；连接参数和模型编辑分别收进 `Connection` / `Models`
  原生 disclosure，切换 provider 时会自动收起，避免把低频配置与日常操作放在同一层。
- MCP、消息渲染、开源声明和 Intatis Config 入口统一收进 `Advanced settings`。原先常驻的
  renderer 说明、配置路径与诊断实现长文不再占据页面；必要信息保留在原生 help 中。
  Diagnostics 改为页面底部的轻量行，只显示“本地 ZIP、不上传”和导出按钮。
- 这是 presentation-only 收口：provider/model/MCP/config/diagnostic 功能、凭据解析、
  EventLog、PermissionEngine 与安全边界均未改变，也未新增依赖、配置 schema 或网络上传。
- Computer Use 对相同窗口的改前/改后构建做了运行态核对：默认 Settings 可访问元素约从
  62 个降到 33 个，`Connection`、`Models`、`Advanced settings` 展开后的原功能均可达；
  本轮完成深色模式视觉检查，浅色模式运行态仍待后续确认。Swift parse、localization JSON、
  focused `ThreadLayoutTests` 10/10、Developer ID `IntatisMac` Debug 与 generic iOS
  Simulator Debug unsigned build 均通过。

## 2026-08-02 macOS 本地诊断日志导出

- macOS 设置页最底部新增“生成并导出诊断日志”卡片。用户选择保存位置后，App
  在本机生成 ZIP；当前实现没有上传 endpoint、后台上传任务或网络发送步骤。
- 导出包覆盖当前可获得的诊断面：schema/version/系统与 App 构建摘要、最近 24 小时
  的 IntatisMac unified log、系统代理摘要、性能/内存指标、最近的 hang incident 与
  crash report，以及每个 session 的结构化脱敏 EventLog 投影。`manifest.json` 记录
  每个采集项、字节数、截断状态、失败项与 `remoteUploadPerformed=false`，因此“完整”
  表示所有已知诊断源均被尝试且遗漏可审计，不表示复制用户原始会话。
- 原始 `events.jsonl`、用户/模型正文、工具参数与结果、provider URL、凭据、配置/auth
  文件、workspace、artifact、浏览器数据和 security-scoped bookmark 均不会进入 ZIP。
  session 日志只保留诊断所需的事件头和 typed 状态字段，并对 secret、URL、邮箱与
  私有路径二次清洗；读取、暂存、压缩和最终文件均采用 bounded/owner-only/no-follow
  边界。单个来源失败不会丢失其余证据，而会写入 manifest/error 清单。
- 真实 Settings UI 已完成本地导出；首次验收发现两个只有 lock、没有
  `events.jsonl` 的空 session 被误报为 warning，现已改为安静跳过。专项 20 项测试、
  全量 SwiftPM tests、XcodeGen、`IntatisMac` 与 `IntatisiOS` generic Simulator
  Debug unsigned build 均通过；最终导出的 ZIP 为 owner-only `0600`。诊断 UI/服务
  仍只进入 macOS target。未进行远程上传（功能也尚未实现）。

## 2026-08-02 Cowork 内置调度 Skill 与 coordinator 激活契约

- `IntatisSkills` 现在随产品打包 system-scope
  `cowork-agent-orchestration` Skill。正文规定 direct / reuse / delegate / spawn
  的选择顺序、最小 agent 数量、read-only 默认 workspace lease、显式
  read-write 与 `canCoordinate: false` 默认值；profile 选择先做 exact capability
  hard gate，再排除停用/不稳定 route，在满足任务质量的候选里优先较新的 active
  generation，最后按模式权衡预计总成本与延迟。模型/价格等易变资料独立放在
  `references/model-routing.md`，只在确实考虑切换 child exact profile 时读取。
- routing reference 现含正式 provider × priority 矩阵，覆盖 OpenAI、Anthropic、
  Google、Meta、xAI、Mistral、DeepSeek、Kimi、Z.ai、MiniMax 与 Qwen。矩阵记录
  2026-08-02 可核对的 stable/Preview/open-weight/host-priced 差异及 cost / balanced /
  efficiency / multimodal anchor，但只是对用户 JSON 中 exact profile 的 dated
  shortlist；Preview 不因较新自动成为默认，开放权重模型没有统一 API 价格，任何
  matrix entry 都不能新增 route 或补全未声明 capability。
- 2026-08-02 的后续 owner correction 把 Meta anchor 从 Llama 4 全面替换为
  `Muse Spark 1.1`，同时保留 Meta Model API `Public Preview` 与公开 exact API ID/
  可比价格未知的事实；Google efficiency 路线明确纳入 `Gemini 3.1 Pro Preview`；
  DeepSeek 将完整版本名 `DeepSeek-V4-Flash-0731` 排在 V4-Pro 之上；官方 API 请求名
  `deepseek-v4-flash` 只作为该已记录 0731 版本的 wire alias，不再充当推荐名称；
  Qwen 的 Flash anchor 明确为 `Qwen3.6-Flash`，不存在 `Qwen3.7-Flash` 推断。
  所有四项仍只对当前 JSON 中 host-approved exact profile 排序，不能绕过 Preview/
  Public Beta 接受和 capability hard gate。
- 该 correction 已重新通过 Skill validator、bundled `IntatisSkillsTests` 29/29 与
  Developer ID `IntatisMac` generic macOS unsigned Debug build。最终 App bundle 的
  resource 已确认包含 Muse Spark 1.1、Gemini 3.1 Pro Preview、完整
  `DeepSeek-V4-Flash-0731`、Qwen3.6-Flash，并确认不含旧 Llama 4 Scout 或
  Qwen3.7-Flash。
- 该正式矩阵已通过 bundled Skill validator、`IntatisSkillsTests` 29/29（包含
  `SkillMCPDependencyTests`）和 Developer ID `IntatisMac` unsigned Debug 构建；最终
  App bundle 已直接确认包含矩阵标题、11 家 provider anchor、Preview guard 与
  Kimi/GLM/MiniMax/Qwen 新增条目。它仍未经过 11 家真实 endpoint/key 的网络 E2E，
  因此不能把文档推荐等同于当前用户配置中 route 可用性或实测质量排序。
- Cowork coordinator system prompt 会在第一次调度决定前要求激活 exact
  bundled catalog entry：名称必须精确匹配、`scope="system"`，且 source 必须以
  `system:bundle-` 开头，再用其 opaque `skill_id` 调用 `activate_skill`。系统提示词
  不内嵌 Skill 正文；同名 workspace/user Skill 不能替代。entry 缺失或激活失败时
  保守回退为优先直接执行、继承 exact profile、read-only、无 child coordination，
  且除非任务明确需要，不创建新 agent。
- 调度优先级分为 `cost-first`、默认 `cost-efficient-balanced` 与
  `efficiency-first`。厂商 reference 只是一份 2026-08-02 官方资料快照，不是
  benchmark、billing engine 或运行时 catalog；实际可选项仍只来自当前调用的
  `list_inference_profiles`，不允许模型构造 endpoint、credential、model options
  或未列出的 profile。该 tool 现在额外输出 host 从用户 JSON exact model profile
  投影的 declared capabilities；缺失时明确为 `unspecified`，不得按厂商名或 model
  名猜测。
- multimodal 任务要求对应 `vision_input` / `audio_input` / generation/editing 等
  exact capability。若 main profile 未声明，Skill 强制创建或复用声明所需能力的
  read-only、无协调权副 agent 来处理 modality-specific WorkTask；没有合格 profile
  或实际 attachment/artifact 无法传给副 agent 时必须报告 blocker，不能用文本猜测
  冒充完成。当前 root user image 进入 main request，但 delegated WorkTask 尚未形成
  通用 attachment-bytes handoff，因此“text-only main 自动把用户图片交给 vision
  child”的完整 E2E 仍是 `UNKNOWN/待实现`。
- 该能力仅进入 Developer ID macOS / CLI 的 Code/Cowork Skill 图，不改变
  EventLog schema、现有 provider JSON schema、UI 或 PermissionEngine。capability
  summary 是 runtime-only 安全元数据，不进入 binding/EventLog。macOS Debug app 已确认
  bundle 同时包含正文和 routing reference；iOS generic Simulator Debug 构建中
  没有 `IntatisSkills` target/resource，继续保持 chat-only 子集。
- bundled Skill validator、SwiftPM focused tests、SwiftPM build、XcodeGen、
  `IntatisMac` 与 `IntatisiOS` unsigned Debug build 均通过。完整 SwiftPM tests 在
  当前 managed 外层 sandbox 中仍由既有的 nested Seatbelt/process/loopback 限制
  失败；本次 refinement 的 Skill 29/29、Context 21/21、Cowork capability listing
  1/1、CLI JSON capability projection 1/1 均通过，macOS/iOS generic builds exit 0。
  未运行真实 provider、多 agent
  行为 E2E 或 UI/模拟器启动，因此模型是否在真实长任务中始终遵循路由建议仍为
  `UNKNOWN`。

## 2026-08-02 Icon Composer 图标与正式安装

- 根目录用户提供的 `Intatis.icon` 已作为 Apple Icon Composer 原始资源接入
  `IntatisMac` 和 `IntatisiOS`；`project.yml` 将它放入两个 shipping target 的
  resources build phase，并显式设置 `ASSETCATALOG_COMPILER_APPICON_NAME=Intatis`。
  遗留 `IntatisMacAppStore` 仍未接入。
- Xcode 27 Release build 已把该资源编译为 app 内的 `Intatis.icns` 与 `Assets.car`，
  生成的 `Info.plist` 同时含 `CFBundleIconFile=Intatis` 和
  `CFBundleIconName=Intatis`。产物仍是 `arm64 + x86_64` universal app，未改变业务
  源码、依赖、EventLog、权限或平台边界。
- 最新 Release 已安装并从 `/Applications/Intatis.app` 以单实例正常运行；替换前版本
  可从 `/private/tmp/Intatis.app.before-icon-20260802-1320` 恢复。安装包与 build 产物的
  executable、`Intatis.icns` 和 `Assets.car` 逐字节一致，
  `codesign --verify --deep --strict` 通过。
- 本机 `security find-identity -v -p codesigning` 仍返回 0 个有效 identity，因此当前
  安装使用 ad-hoc Hardened Runtime 签名，并保留 Developer ID entitlements；它不是
  已完成 Developer ID 签名、公证或 Gatekeeper 分发验收的公开发行包。图标为用户提供
  资源，本轮未独立审计其来源，未引入第三方依赖，`NOTICE.md` 不变。
- 该节原先记录“iOS 未接入图标”的状态，已被同日后续 iOS 设计统一实现取代；iOS
  Simulator bundle 与主屏幕安装态均已验证最新版资源。

## 2026-08-02 双端 Chat 托管网络搜索与 Agent 搜索边界

- macOS 与 iOS Chat 现在共用 provider-hosted Responses `web_search`，但不提供任何
  搜索按钮、菜单项、开关、状态或路由提示。每次 Send 都把 hosted search 作为透明
  Chat 能力交给 provider，并使用 `tool_choice: auto` 让模型按当前问题决定是否搜索；
  它不是 Intatis `ToolCall`，不进入 `AgentLoop`、`ToolRegistry` 或 `PermissionEngine`。
- 高级 JSON/JSONC 可选顶层 `web_search_model`，解析语义与正常 `model` 相同，使用
  exact `<provider>/<model-id>` 路由；省略时原子复用当前 Chat provider/model。provider
  可选 `responsesEndpoint` 覆盖托管搜索 endpoint。这两个字段由配置文件读取并在
  iOS 显式导入后的 app-owned snapshot 中保留，但不写入普通设置表单；显式配置了
  无效路由时 fail closed，不静默退回当前模型或无搜索回答。
- provider 返回的结构化 URL citations 继续以 optional additive
  `message_completed.citations` 落盘，macOS/iOS 共用校验、去重和原生链接展示。
  构建和离线测试不要求 API key；真实发送时仍使用所选搜索 provider 的既有凭据，
  且该 provider/model 必须实际支持 Responses hosted search。
- Code 与 Cowork 不复用 Chat 的透明 hosted-search 路径：它们继续把网络访问作为
  `browser_search` / `web_fetch` 等 Agent 工具，经 `ToolRegistry`、`browse_web`
  capability lease、`PermissionEngine` 与 durable tool execution 执行。Cowork
  coordinator 可持有该能力，普通 worker 默认不持有；本轮未复制或绕过这条工具链。
- 专项 Provider/Conversation、ToolRegistry/Cowork/AgentKernel 与 SharedUI 测试通过；
  Developer ID `IntatisMac` 和 `IntatisiOS` generic Simulator Debug unsigned build
  均成功。iOS 27.0 iPhone 17e 已实际安装并启动；Device Hub 中 paperclip 菜单只显示
  `Generate image from prompt`，AX tree 与截图均无搜索控件或搜索提示。设备和 App
  保持运行，未关闭或清理用户配置。
  本轮未向真实 provider 发送请求，因此真实 hosted-search E2E 仍为 `UNKNOWN`。

## 2026-08-02 Cowork 自动权限 502 / 重复拒绝回归

- 对截图对应 Cowork EventLog 的只读核对确认：`task_update` 的 deterministic gate
  已进入 automatic review，但 reviewer 的 OpenAI-compatible stream 收到 error-only
  SSE `502 / Network connection lost` 后直接失败；当前调用正确地 durable deny，且没有
  `tool_execution_prepared`，因此 executor 从未运行。模型随后给出语义相同的调用时，
  旧 `ToolDenialCircuitBreaker` 又把这次基础设施故障当成普通拒绝，从本地缓存直接
  deny，导致任务无法恢复。
- `OpenAIToolCalling` 现在以“已经接受非错误 provider payload”为流式重试边界：若
  当前 attempt 只收到结构化、可重试的 provider error frame，且此前没有接受文本、
  tool call、usage、completion 或其他有效 payload，可使用剩余 attempt；一旦接受任何
  有效 payload 就禁止自动重放，避免重复 partial output 或工具调用。
- `AgentLoop` 仍对 reviewer/provider/timeout 失败的当前调用 fail closed。只有 durable
  typed `automatic_reviewer_failure + provider_failure|reviewer_timed_out` 才允许模型的
  exact retry 消耗一次 fresh permission request；它使用新的 `RequestID` 与 reviewer
  generation，仍须经过完整 gate、durable settlement、authorization revalidation 与
  prepare。显式 user/policy/reviewer deny、malformed/cancel/persistence failure 等不会
  获得该例外，第二次瞬时失败也不会重新装填额度。重复 unresolved action 文案按展示
  文本去重，不再在最终错误中列出两次同一 `task_update`。
- 回归覆盖 `IntatisProvidersToolCallingTests` 29/29 与 `AgentLoopPolicyTests` 33/33；
  完整 `swift test` 退出码为 0，当前启用 suite 无失败；Developer ID `IntatisMac` Debug
  与 `IntatisiOS` generic Simulator Debug unsigned build 均成功。本轮未请求真实 provider、
  未执行被截图任务、未引入依赖或复用上游源码，`NOTICE.md` 不变。

## 2026-08-02 Cowork 权限优先的 Liquid Glass 右栏

- Cowork 宽屏 trailing status rail 已移除 `Git Status` 及其 workspace/path/status-only
  文案；这只删除 Cowork presentation，受 CapabilityLease 与 PermissionEngine 约束的
  Agent Git 工具没有删除或放宽。
- 待处理权限审查从 thread/composer 上方迁到右栏第一位。只要存在 pending request，
  宽屏 rail 会临时固定为可见；RequestID、FIFO、manual approve/decline/cancel-turn、
  automatic non-actionable 与 resolution notice 均继续消费原投影和 responder。窗口窄到
  无法安全容纳 rail 时，才在 thread 底部保留同一 `PermissionCard` 作为可操作兜底，
  不会同时重复两份。
- 权限、Agents、Goal 与 Tasks 由一个原生 `GlassEffectContainer` 组织；各 section 使用
  系统 `glassEffect`、连续圆角、SF Symbol 与动态语义文字，不再使用固定灰色卡片或
  自绘玻璃。权限卡支持由 rail 提供外层 glass，避免 Material 套 Material；窄屏兜底
  和 Code 既有 permission surface 仍保留低对比系统 Material。
- 宽屏 Cowork rail 现已作为 conversation detail 同一 canvas 的 trailing overlay：外层
  divider 与整栏 `.bar` 背板均移除，thread `ScrollView` 延伸至 detail 最右侧，并只以
  trailing scroll-content margin 为 glass cards 留出正文空间，因此原生滚动条位于整个
  内容区的最右端。rail 最右侧另保留不命中测试的透明边缘通道，overlay 不会截获该
  原生滚动条的鼠标操作。稳定 outer-width 显隐与 pending permission 固定规则不变。
- 通用 Agent message、`information_requested`、`information_replied` 与其他
  agent-to-agent 记录现在都使用普通 agent 回答版式，不再套结构化卡片；每条身份统一为
  exact `sender->recipient`，EventLog payload、Mediator、权限和调度语义没有变化。
- 本轮只改 SharedUI presentation/layout；EventLog、PermissionEngine、CoworkViewModel、
  Goal/WorkTask projection、Git tool registry、平台边界和第三方依赖均未改变。
- 当前验证通过：SharedUI build；`ThreadLayoutTests`、`PermissionProjectionTests` 与
  `PermissionReviewControlPlaneTests` 合计 61/61；Developer ID 产品 `IntatisMac`
  Release/Debug build；`IntatisiOS` generic Simulator Debug build；Light/Dark 宽屏和
  Light 窄屏只读视觉检查。最新 Release 已正式安装到 `/Applications/Intatis.app`；
  本机没有可用 Developer ID identity，因此安装包只做了 ad-hoc Hardened Runtime
  签名，尚不具备对外分发所需的 Developer ID、公证和 Gatekeeper 验收。

## 2026-08-02 iOS Chat 参考字体对齐

- 用户最终要求 iOS 原生界面使用 serif，而不是只对齐字号和字重。iOS App 根视图
  统一应用 Apple 系统 `.fontDesign(.serif)`，让首页、侧栏、composer、Settings
  及其原生表单控件继承系统 serif 与 Dynamic Type；没有引入、复制或打包第三方
  字体，macOS 根视图不受影响。
- Markdown/plain fallback、代码块、公式和第三方声明属于内容渲染，不额外执行
  iOS-only serif 改写；它们继续与 macOS 共用同一套 SharedUI/Microsoft Markdown
  字体合同。代码与公式保留各自专用字体，不把界面字体要求极端扩展到内容语义。
- 既有语义层级继续保留：顶部当前模型为 `.headline` semibold + `.primary`，侧栏
  `Intatis` 为 `.title2` semibold，`Recents` 为 `.headline` semibold，会话行和
  composer 输入为 `.body`。`Menu` 关闭态仍覆盖 accent tint，避免模型名变蓝。
- iOS composer 输入由共享的固定 15pt 改为系统 `.body`；该分支只作用于 iOS，
  macOS 继续保持原 15pt 合同。`Recents` 顶部间距从 34pt 收到 20pt，使文字基线
  与参考图一致；布局、功能入口、Chat-only 平台边界和网络搜索路径均未改变。
- 三张用户参考图为 402×874pt @3x，验收模拟器为 390×844pt @3x。参考图继续作为
  布局、字号和字重依据；其 app chrome 的 sans 字体族被用户明确的界面 serif
  要求覆盖。
  同密度成对检查首页与侧栏，并额外检查 Settings；修正后可见普通文字均为系统
  serif，未发现 app chrome 字体范围内的 P0/P1/P2 偏差。
- `IntatisiOS` generic Simulator Debug unsigned build 已通过；iOS 27.0 iPhone 17e
  的 Dark 首页、侧栏和 Settings 已用 Device Hub 实际检查。未发送消息或
  provider/网络请求，模拟器保持 Booted 且 Settings 留在前台供继续配置。真实长
  回复的最终像素仍待有内容的离线 fixture 或用户显式发送后复核，但其字体实现
  已恢复为与 macOS 完全相同的共享路径。

## 2026-08-01 iOS Chat 参考界面壳

- iOS Chat 已改为参考图对应的单页原生壳：顶部左侧为侧栏按钮，中间为当前
  model 菜单，右侧为新对话；空会话不显示 “Use models from your computer”、
  onboarding CTA 或 “Analyze this artwork” 一类建议卡片，也不再因为缺少 API
  key 自动弹出 Settings。构建、启动和浏览离线界面本身不要求 API key。
- 左侧抽屉约占紧凑宽度的 82%，使用动态系统背景和原生 glass controls；标题为
  `Intatis`，上方保留 Settings，主体为纯文本 Recents，会话切换后自动收起。
  底部按参考布局保留非交互搜索占位和 Chat 新对话胶囊；session 搜索本轮没有
  实现，不能把该占位写成可用功能。
- iOS composer 现在固定为一排：左侧 paperclip 菜单、中间原生多行输入、最右
  Send/Stop 唯一主操作位。paperclip 菜单只保留既有“根据 prompt 生成图片”；
  provider-hosted 网络搜索是无 UI 的透明 Chat 能力。
  任意照片/文件的选择、durable artifact 归档、历史恢复和 vision 请求闭环尚未
  接通；当前 paperclip 是现有 Chat 功能菜单，不得对外宣称通用附件发送已完成。
- `IntatisiOS` generic Simulator Debug unsigned build 已通过；Xcode 27 Device Hub
  中独立启动 iOS 27.0 iPhone 17e，实际检查了 Light/Dark 首页、侧栏开合、顶部
  model 菜单、顶部/侧栏新对话、Settings 与配置导入入口及 paperclip 菜单；最新
  2026-08-02 验收另确认菜单不含 web-search 项。未发送 provider 请求，真实
  endpoint/key 与通用附件 E2E 仍为
  `UNKNOWN`。验收设备保持 Booted，未执行 shutdown/close。

## 2026-08-01 iOS Chat 托管网络搜索

- iOS Chat 不展示搜索开关或搜索状态。每次 Send 都冻结
  `ChatWebSearchConfiguration`，并通过 provider 的 `/responses` 路由把托管
  `web_search` 作为可选能力发送；`tool_choice: auto` 让模型按需决定是否使用。
  该路径不引入 WebView、自绘浏览器或第三方 UI。
- `ChatLoop` 仍是无本地工具的 Chat runtime。搜索由远端 provider 执行，iOS
  target 依赖图仍只有 7 个 Chat 子集 products，不链接 Tools、Permission、
  AgentKernel、Cowork、MCP、shell/git/patch 或本地浏览器 runtime。
- Responses SSE 会折叠流式正文、usage 与 `url_citation`；来源按 URL 去重，只接受
  无 user-info 的 HTTP(S) URL。`message_completed` 以 legacy-compatible optional
  `citations` 保存结构化来源，投影后由 iOS 消息下方的 SwiftUI `Link` 原生打开；
  UI 在创建链接前再次验证 URL。
- 构建与 deterministic fake-SSE 测试不读取、创建或要求 API key。最终
  `IntatisProvidersTests` 150/150、`IntatisConversationTests` 160/160、
  `SubmissionProtocolTests` 3/3，`swift build --disable-sandbox`、localization
  catalog 的 en/zh-Hans compile、`xcodegen generate` 与 IntatisiOS generic
  Simulator Debug unsigned build 均通过。构建产物精确包含 Core / Protocol /
  Providers / Conversation / Artifacts / Multimodal / SharedUI 七个 Intatis 模块，
  不含 Tools / Permission / AgentKernel / Cowork / MCP。真实线上搜索仍要求所选
  provider/model 实际支持 Responses `web_search`；本轮未发真实网络请求，故该
  E2E 保持 `UNKNOWN`。

## 2026-07-31 Xcode 27 / macOS 27 Beta 兼容性

- 当前验证环境为 macOS 27.0 build `26A5388g`、Xcode 27.0 build
  `27A5228h`、Apple Swift 6.4 `swiftlang-6.4.0.27.1`。本机只安装这一份
  Xcode，没有旧 SDK 可做同机 A/B。
- Xcode 27 下 production-shaped 16-row `NSHostingView` 测试曾在前置 async
  Markdown case 后收不到首批 geometry/preference callback；timeout unwind
  随后触发 Apple `Gestures.InvalidTransition` 的
  `failed(deinit)` / `failed(removedFromContainer)` assertion。后者的栈完全
  位于 `Gestures`、`SwiftUICore`、AppKit selectable-text interaction 和
  `NSHostingView.deinit`，可高置信归类为 Apple Beta framework teardown
  回归；首个 timeout 则准确归类为 Xcode 27 async XCTest hosting 生命周期与
  Intatis rich renderer 夹具的交互兼容问题，不能写成系统 scroll/Preference
  API 全局失效。
- 测试 host 现在在 attach/display 后显式让 AppKit 主 run loop settle，释放
  时先替换为空 root、再次 settle，再拆 content view；不再直接释放尚未稳定的
  selectable text/gesture graph。production rich admission 另增加第二条精确
  证明：raw bottom restore 后更新一代的 native scroll geometry 同时证明
  at-bottom 和有限正 content height 时可以放行；restore 前 stale observation
  明确拒绝。没有 timeout 成功、fake callback、自动切 plain 或其他兜底。
- Swift 6.4 新暴露的 MainActor default argument、async `NSLock`、
  non-Sendable closure conversion 和 captured mutable lease warnings 已按并发
  语义整改。IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug
  在 Xcode 27 下均成功构建。
- focused `ThreadScrollCoordinatorTests` 为 30/30，
  `MessageRenderingTests` 为 41/41；完整 SwiftPM 所有 test bundle 退出 0，
  `swift build` 成功。Xcode 27 另有一个 test runner 限制：整
  `IntatisSharedUITests` target 的 108-selector `-XCTest` filter 可停在
  `XCTWaiter`，而无过滤 full run 和单 class filter 均通过，因此该大过滤命令
  不作为权威结果。
- 两个只使用 Apple API 的最小对照均通过，故不能声称所有原始 timeout
  排他性由新系统单方造成。完整归因、采样、修改和验证边界见
  [`codex-report/07_31_26-00_18-xcode-27-beta-compatibility-audit-and-fix.md`](../codex-report/07_31_26-00_18-xcode-27-beta-compatibility-audit-and-fix.md)。
  latest-build 的真实问题 session 手工 entry/scroll/resize 仍未在本轮执行。

## 2026-08-01 macOS workspace chrome 布局循环修复

- 2026-08-01 11:11 的 `IntatisMac` crash 是 main-thread AppKit
  `NSGenericException` / `EXC_BREAKPOINT`，栈从 `NSSplitView.layout`、
  `NSHostingView.layout` 进入 `ToolbarBridge.preferencesDidChange` 与
  `AppKitWindowController.updateToolbarBridge`。现场 RSS 约 219 MiB，故它不是
  OOM、provider 或 permission reviewer failure，而是 window chrome preference
  在 layout 过程中重入更新。
- 源码有两条可闭环的反馈边：Chat/Code/Cowork 切换会让 Code/Cowork wrapper
  动态增删 window `.toolbar` items；Code/Cowork 又用已被 `.inspector` 压缩的
  child width 决定同一个 inspector 是否存在。后者在 940/980pt 附近可形成
  show→压缩→hide→回宽→show 的自反馈，前者与根 `NavigationSplitView` 的
  AppKit toolbar/layout bridge 叠加后符合崩溃栈。
- Code/Cowork 现在不再发布 window `.toolbar` 或嵌套 `.inspector` preference。
  MCP、Project 与 inspector toggle 进入内容 header；右侧状态栏由同一个稳定
  outer `GeometryReader` 计算，显隐只读取未被右栏压缩的 available width 与
  用户请求状态，并对非有限宽度 fail closed 为 thread-only。Chat/Code/Cowork
  mode 变化不再改变 window toolbar item graph。
- 自动化实际通过：`ThreadLayoutTests` 10/10，其中 production-shaped
  `NSWindow + NavigationSplitView + CodeShell/CoworkShell` 连续 360 次 mode、
  860/1119/1120/1159/1160/1420pt resize 与 inspector 状态切换；另有 10,000
  次阈值确定性检查、-100...2000pt 的 0.5pt geometry sweep，以及
  NaN/±infinity。`ThreadScrollCoordinatorTests` 30/30、
  `MessageRenderingTests` 41/41；IntatisMac macOS Debug 与 IntatisiOS generic
  iOS Debug unsigned build 均成功。
- Computer Use 只读打开真实历史 Chat/Cowork，AX tree 中 window toolbar 只剩
  系统 `Hide Sidebar`，MCP/Project/Inspector 位于 Cowork 内容 header；没有发送
  消息、调用 provider 或修改 session。控制器随后拒绝额外 resize/click，故不把
  未执行的实机动作写成通过。
- 最新 Debug 进程 PID 80122 由独立 watchdog 驻留 200 秒，共 99 个样本，峰值
  RSS 229,376 KiB、峰值 CPU 0.4%，未异常退出或触发熔断。对应 Unified Log 对
  `DisplayCycle`、`Update Constraints`、multiple updates、invalid/negative
  geometry、`NSGenericException`、`ToolbarBridge` 与 AttributeGraph cycle 为
  0 命中；1 秒 `sample` 的主线程 872/872 样本都在 `mach_msg2_trap` 等待事件，
  没有活动 layout hot stack；没有新增 `IntatisMac` crash report，测试实例最终
  正常关闭且无残留。该证据跨过此前标记的 >160 秒缺口，但仍不能冒充多小时、
  多窗口、真实 streaming 中 resize 或未来 macOS 27 Beta framework build 的
  长时 release 证明。

## 2026-07-31 浏览器执行回归修复

- v0.19 把真实 `browser_*` 动作路由到通用
  `networkStructuredShell` 的 macOS deny-default Seatbelt。Microsoft Edge
  虽然被创建，但 Chromium helper 在继承外层 Seatbelt 后无法完成自身 sandbox
  初始化，主进程随后 abort，Node 最终只能报告
  `browser did not expose a DevTools port`。这不是网络工具未注册，也不是
  permission reviewer 超时。
- shipping macOS 浏览器动作现在走专用
  `BrowserBackendProcessRunner`：Swift 只接受 typed/opaque
  `BrowserBackendInvocation`，生成固定 Node driver 后直接以参数数组启动已安装的
  Node.js；不经过 `/bin/sh -c`，不接受模型提供的 shell 字符串，也不再让浏览器
  继承与 Chromium native sandbox 冲突的外层 Seatbelt。不得用
  `--no-sandbox` 规避冲突；Edge/Chrome/Chromium 的原生多进程 sandbox 保持启用。
  Linux 仍使用既有 Bubblewrap 路径。
- 该专用 lane 不绕过 Intatis 权限链：所有 action 仍先经过 schema、
  CapabilityLease、PermissionEngine 和 durable tool ticket；runner 在创建任何
  `.intatis/browser` 路径前，再按 exact root identity 与 WorkspaceLease
  预检 profile、downloads、state、history，以及本次 upload/screenshot path。
  read-only、窄 lease、denied pattern 或 workspace replacement 均在启动进程前
  fail closed。
- Node stdout/stderr 改为持续 drain 的 bounded head/tail pipe；CDP 在端口出现
  前失败也会立即进入 TERM/KILL、client close 与 active-browser 清理，不再留下
  orphan Edge 或用物理无界临时文件积累输出。diagnostics 仍使用通用 structured
  runner，真实浏览器动作与该通道明确分流。
- state/history、显式 action URL 与 backend result URL 现在在 Swift 侧只接受
  带 host 的 HTTP(S)，Playwright/CDP fixed driver 还会独立再验一次；伪造
  `file://` state 或 navigation stack 会在 browser backend spawn 前 fail
  closed。CDP 启动只忽略旧 `DevToolsActivePort` 不存在；其他 unlink 错误终止
  启动，新 marker 必须是本次启动后创建的 current-UID regular/single-link file，
  且其中 browser WebSocket path 必须与同端口 `/json/version` 返回的 loopback
  endpoint 精确一致，`/json/list` 与 `/json/new` PUT/GET 返回的 page target
  WebSocket 也必须在连接前指向同一 loopback port。
- 最终验证：真实 Edge/CDP navigate 1/1、search + profile persistence 2/2、
  upload/download 1/1、stale-port generation 1/1；伪造 state/history URL 2/2；
  final-source `/json/new` forged-endpoint 行为回归 1/1；此前完整
  `IntatisToolsTests` 97 tests、15 个 opt-in skips、0 failures；相关 AgentKernel
  浏览器任务 4/4、Permission gate 3/3；final-source Xcode 27
  `IntatisMac` macOS Debug build 成功。真实 Playwright、Chrome/Chromium、
  headed handoff 与多 profile 同时启动本轮仍为 `UNKNOWN`。完整根因、被否决方案、
  安全合同和命令见
  [`codex-report/07_31_26-15_35-browser-execution-regression-remediation.md`](../codex-report/07_31_26-15_35-browser-execution-regression-remediation.md)。

## 2026-07-28 macOS 分发决策

- macOS 唯一发行产品是 Developer ID 签名、公证和直接分发的 `IntatisMac`；
  不再规划或发布 Mac App Store 版本，也不再用 App Store App Sandbox 限制
  产品能力、依赖选择或验收矩阵。精确合同见
  [`docs/MACOS_DISTRIBUTION.md`](MACOS_DISTRIBUTION.md)。
- 当前源码中的 `IntatisMacAppStore`、`.macAppStore` profile 和对应
  entitlements 尚未删除，但只属于遗留实现，不是产品面、未来承诺或 release
  gate。下文 dated 记录中的旧 App Store build/hash/linkage 结果保留为历史
  事实，不表示仍需维护或重跑。
- 这项决定不移除 Intatis 自有安全：权限三层门、Capability/WorkspaceLease、
  PathConfinement、SecretScanner、durable execution、managed terminal 的
  workspace-scoped Seatbelt/default-network-deny、Hardened Runtime、签名和
  公证继续有效。iOS chat 子集及其系统 sandbox/linkage 边界也不变。

## 2026-07-28 Code / Cowork replacement-history compaction

- 稳定 Code conversation 与 Cowork `@main` 现在共用 durable replacement-history
  compaction；task-scoped worker、permission reviewer、GoalVerifier 与其他控制面
  agent 仍不读取或压缩主线程历史。pre-turn 在当前 user/context 写入前检查旧
  历史，mid-turn 只在工具结果后仍需继续采样时检查，最终回答不会额外触发一次
  无后续用途的压缩。pre-turn 先冻结首个真实 request-owned dynamic tool
  snapshot；工具执行后若仍需采样，则先冻结下一请求的 snapshot，再用同一份
  exact provider tool specs 完成阈值判断、95% replacement 校验和下一次普通
  dispatch，避免 MCP catalog/schema 变化形成 TOCTOU。
- 新增 additive `model_history_compacted` EventLog 事件。checkpoint 保存完整
  replacement items、continuation summary、单调 `windowNumber` 和 UUIDv7
  `first/previous/current` window chain；恢复从最新有效 checkpoint 为基底，只
  重放其后的存活尾部。`appendModelHistoryCompaction` 在跨进程锁内对
  complete-known history 和同一 agent 最新 model-history seq 做 CAS，先 durable
  commit、后 live swap；Protocol 在编码/解码边界拒绝坏 schema、空 summary、
  非 v1 replacement shape 与非 canonical UUIDv7，EventLog 在落盘/WAL 前校验
  完整同-agent lineage，并禁止 generic append 绕过专用入口。失败、未知 future
  event、seq gap、坏 lineage 或冲突 payload 均 fail closed。
- model-history user item 现在区分 `real_user`、`contextual` 与
  `compaction_summary`。显式 Skill 正文仍只在当前 Turn 激活，但会以 contextual
  项进入物理历史；压缩时它可参与摘要，却不会被误当作 20,000-token 真实用户
  原文保留。后续 Turn 再次需要 Skill 时仍从新的 invocation snapshot 重读，
  没有新增 sticky activation、Session ledger、TTL 或卸载状态机。
- context policy 只使用 exact profile 中显式的 `context_window` /
  `max_context_window` / `auto_compact_token_limit` /
  `effective_context_window_percent` / `comp_hash` 或 OpenCode
  `limit.context` 元数据，不按 model slug 猜窗口。默认 total-scope auto limit
  是 raw/max window 的 90%，usable hard trigger 是 95%，实际取较早阈值；窗口
  未知但存在显式 `auto_compact_token_limit` 时只使用该显式 trigger，不伪造
  95% hard window；窗口和显式 limit 都未知、route 歧义或 legacy route 时保持
  `.unspecified`。Code provider/model/policy 由同一次 immutable route
  resolution 原子取得，Cowork `@main` 使用冻结 exact inference binding。
- 20,000 approximate tokens 是 retained real-user 的上限，不是无条件保留量。
  hard usable window 可知时，compactor 会按 95% window、canonical
  system/developer/context 前缀和下一普通请求已冻结的 exact 工具 schema 动态
  缩小该预算；summary request 在 replacement window 未知且无显式 token
  budget 时不注入 output ceiling，只有已知 usable window 或显式共享预算才
  派生 provider request 与对应 host 流式上限。已知模式的
  secret-like summary、provider 忽略 ceiling，或完整 replacement request 的
  确定性估算仍超过已知 usable window，都会在 checkpoint 落盘前 typed fail
  closed。typed context overflow retry 永久保留连续 leading
  system/developer 前缀，只从 mutable clone 最旧端删逻辑 item group；
  assistant tool-call batch 只连带删除紧邻的 matching outputs，避免跨 Turn
  重复 call ID 误删或制造 orphan tool output。
- 本轮对照固定的 OpenAI Codex commit
  `bd2de422aa287b97b06ca6425a10935bcf1b3731`，并保留 Intatis 更强的
  EventLog-first 顺序；完整审计、六项批评判定、测试证据与明确不等价项见
  [`codex-report/07_28_26-10_17-codex-skill-lifecycle-and-history-compaction.md`](../codex-report/07_28_26-10_17-codex-skill-lifecycle-and-history-compaction.md)。
  replacement-history / Skill catalog / MCP dependency 聚焦矩阵 129/129
  通过；脱离外层 managed sandbox 后的完整 SwiftPM 为 1470
  tests / 16 个 opt-in 环境 skip / 0 failures。SwiftPM 全构建、XcodeGen、
  IntatisMac 与 IntatisiOS Simulator Debug 均构建成功；遗留
  `IntatisMacAppStore` 在本决策生效前也曾构建成功，但不再属于当前验收。
  真实 provider、历史图片重新装载、真正 process-kill/restart、GUI 多次压缩
  和长时 soak 仍为 `UNKNOWN`，不能由 fake provider 或进程内重建测试外推。

## 2026-07-27 Code / Cowork Skill capability

- 新增独立 `IntatisSkills` Swift target。它发现 workspace
  `.agents/skills`，并在 DeveloperID/CLI 显式策略下额外读取
  `~/.agents/skills`、`$CODEX_HOME/skills`（缺省 `~/.codex/skills`）、
  `.system` 与 `/etc/codex/skills`；iOS 不链接该模块。遗留
  `IntatisMacAppStore` 的 workspace-only 分支不是当前产品约束。
- 项目现在自带 `.agents/skills/intatis-skill-creator/`，供 Code/Cowork 在
  下一次 invocation 中创建、整理和验证项目 Skill。它以不同名称避开已发现的
  Codex `.system/skill-creator` 冲突，三个 helper 只依赖 Python 标准库，
  默认生成到 `.agents/skills`，不自行授予 shell、文件、网络、MCP、通信或
  委派能力。该目录是 OpenAI Codex `rust-v0.145.0` 固定 commit
  `25af12f7e61572b0bc18ddb1008be543b91519b0` 的 `vendored + derived`
  采用；来源、逐文件修改和 Apache-2.0 记录见
  `ThirdPartyNotices/OpenAICodexSkillCreator.md` 与 `NOTICE.md`。
- 每次 Code send / Cowork AgentInvocation 独立冻结 Skill metadata、完整
  `SKILL.md` 和有界 UTF-8 resources。模型先收到按 exact model metadata
  自适应且有界的 developer catalog；当前用户 turn 的唯一 `$name` 会把完整
  frozen body 作为 user
  contextual fragment，模型也可通过 `activate_skill` /
  `read_skill_resource` 渐进读取。没有 generic `read_file` 兜底。
- 两个 Skill tool 是普通 `ToolRegistry` registrations：snapshot digest
  进入 registry version，调用继续经过 schema、PermissionEngine、durable
  authorization/prepare/result/settlement 和 live lease revalidation；没有新增
  `ToolCapability`，也没有扩大文件、shell、网络、通信或委派权限。MCP
  composition 以已含 Skills 的 base registry 为输入。
- Cowork 的 snapshot 按 agent 自己的 workspace + exact WorkspaceLease
  构建，parent body 不自动传给 child；permission reviewer 与 GoalVerifier
  继续 `tools: []`。Code GUI、Cowork GUI、CLI Code（MCP/无 MCP）、CLI Cowork
  与 one-shot MCP Code exec 均接入同一结构。
- loader 有 frontmatter/name/description/depth/directory/entry/catalog/resource
  上限，拒绝秘密内容、敏感 resource path、无效 UTF-8、越界 workspace root
  和 symlink Skill 目录；单正文/资源限制 48 KiB，防止首次响应与 durable
  history 出现“声称完整但恢复截断”。同一 invocation 的 Skill tools 另共享
  默认 192 KiB 原子披露总预算，重复/并行调用同样计费。catalog 预算现在按
  pinned Codex Core 预算语义从 exact profile 的 canonical primary
  `contextWindowTokens` 取 2% approximate tokens：Codex `context_window`
  优先，字段缺失时允许显式 OpenCode `limit.context` 补位；两者都缺失/非法时
  才使用 8,000 字符。不会使用 `max_context_window` 或 compaction threshold
  猜值。预算只计
  metadata 行，不把 trusted developer envelope 混入；冻结 snapshot 同时保存
  count-only kept/omitted/truncated metrics 和 warning，model-visible catalog
  对省略项保留 marker。当前还没有 App/CLI/EventLog 的 metrics/warning 消费者，
  renderer 也不是 Codex 的逐字节复制，不能写成完整 catalog parity。
- Skill loader 现在解析有界、严格的 `agents/openai.yaml`
  `dependencies.tools` 子集，仅接受 MCP。实际显式选择或激活的 Skill 在披露
  正文/资源前，必须由对应 provider request 的 request-owned frozen MCP
  snapshot 承载 host-attested exact server ID 与 transport-locator fingerprint
  配对；
  endpoint/command/credential 不进入 model-visible metadata。无 MCP host、
  metadata 无效、server 同名但 endpoint 改变或 snapshot 不匹配均 typed
  fail closed，不会读取 process-global config 兜底。当前实现故意比 Codex
  更窄：production host 只从同一 request-owned、capability/policy-filtered
  agent-visible tool view 派生 server+locator assertion，server 至少贡献一个
  可见 tool entry 才能满足；不提供 Install/Continue anyway、OAuth、外部配置
  写入或 runtime refresh。低层 frozen snapshot 是 trusted host seam，不是
  自认证网络证据；相关 deterministic tests 不能冒充真实 MCP E2E。
- 当前严格拒绝目录 symlink，比 Codex 支持受控 symlink folder 的行为更窄；
  尚无 UI 管理、watcher、remote/plugin provider、二进制 asset 或 durable
  enable/disable。focused 验证为 Skills 19/19、Context 20/20、MCP dependency
  9/9、durable activation 2/2；包含 compaction、request snapshot 和 CLI
  metadata 的合并矩阵为 129/129。完整 SwiftPM 为 1483 tests / 16 个 opt-in
  环境 skip / 0 failures。SwiftPM 主图、CLI、Developer ID macOS 与 iOS
  Simulator Debug 均构建成功；旧 App Store build 只保留为历史记录，iOS
  不链接 Skill target。真实
  provider 对 developer catalog 的遵循、真实 MCP server 端到端、GUI 操作、
  Linux/musl 实机和长时多 Agent Skill workload 仍为 `UNKNOWN`。

## 2026-07-27 Cowork 长任务运行预算上调

- 新创建的 Cowork AgentInvocation 默认执行 timeout 已从 300 秒上调到 600 秒，单次 Cowork `AgentLoop` 默认最多工具循环从 50 上调到 64。默认并发仍为 4、最多 attempts 仍为 3，CapabilityLease 的默认 delegation `maxDepth=1` 未修改；这次不是扩大递归/委派层级。
- provider 请求按交互类型分流：普通 Chat streaming 继续保持 120 秒；Code/Cowork 的 tool-calling Agent streaming 使用 180 秒；non-streaming image/transcription 仍为 180 秒。最多 2 attempts、仅首个 response byte 前允许 streaming retry 的语义未改变。Cowork permission reviewer 与 GoalVerifier 的独立、更短控制面 deadline 未放宽。
- macOS Cowork 直接采用 64 次默认；CLI 在没有显式配置时按模式使用 Code 50 / Cowork 64，运行中切换 mode 也不会把 Code 的默认误带入 Cowork。显式 `INTATIS_MAX_STEPS` 或 legacy config `maxSteps` 仍覆盖两个 agent 模式，包括显式降低限制。
- timeout 会在 admission 时冻结进 `TaskContract`，因此历史已持久化的 300 秒 invocation 继续按 300 秒恢复，不迁移、不静默改写；600 秒只影响新 admission。managed terminal `exec_command` 自身未显式传参时仍有独立的 300 秒 timeout，这次没有混同或修改。
- 单元测试覆盖 Cowork policy 与新 root contract 600 秒、Code/Cowork 50/64 分流、CLI 默认与显式 override、Chat/Agent 120/180 分流、exact inference 180 秒及默认 delegation lease。focused 回归为 294 tests / 0 failures，完整 SwiftPM 为 1367 tests / 16 skipped / 0 failures；`intatis` CLI 与 IntatisMac unsigned Debug build 均通过。真实 provider、真实多 agent 长任务和 10 分钟 soak 状态仍为 `UNKNOWN`，不能用离线单元测试或构建冒充。

## 2026-07-29–30 Cowork 滚动/窗口缩放无响应：复现、根因与修复

- 2026-07-29 的原始 Debug 现场先出现
  `IntatisThreadScrollSignature` / `OnScrollGeometryChange` 同帧多次更新和
  主线程无响应，但当时没有留下最终 hot stack；因此该现场本身仍只能证明
  delta publication 与 scroll/layout feedback 是 invalidation amplifier。
- 后续使用普通 Release、真实 `cowork_tf2lkjbh` 和默认 Microsoft rich
  renderer 稳定复现 zoom/restore 后的界面无响应。进程外 sample 明确命中
  `ParagraphView` copy/destruction、`PlatformViewLayoutEngine.sizeThatFits`、
  `NSHostingView.minSize` 与 SwiftUI/AttributeGraph 原生布局链；同一二进制、
  同一 session 使用 `-IntatisPlainSafeMessages` 时 zoom/restore 正常。这确认
  可重复 hang 位于 rich native paragraph measurement，而不是 EventLog、
  provider、runtime 或纯滚动数据本身。
- 直接 feedback edge 是 macOS paragraph 的双重横向尺寸 owner：
  `ParagraphNSView` 以 intrinsic width 参与 AppKit 布局，
  `ParagraphView.sizeThatFits` 又把 TextKit glyph used width 返回 SwiftUI；
  连续窗口宽度变化时 `layout()` 同步 invalidates intrinsic size，使 proposal
  与 intrinsic size 相互反推。原历史宽度 dictionary 是 resize 期间的无界
  measurement/memory amplifier，但不单独记作 feedback 的启动边。
- macOS paragraph 现只提供 intrinsic height，intrinsic width 为
  `NSView.noIntrinsicMetric`；`sizeThatFits` 精确接受并返回 SwiftUI 的有限正
  proposal width，只使用 TextKit measured height。每个 representable 只保留
  最新一个 exact-width/height measurement，不 rounding、不累计历史宽度；
  内容或 line spacing 变化会 reset。bounds width 变化仍清理测量并调度
  TextKit 2 viewport layout，但不再发布 width-driven intrinsic invalidation。
  UIKit 合同未随本次 macOS 修复改变。
- projection 层仍逐 seq fold 全部 EventLog envelope；连续
  `message_delta` 只在 50 ms fixed-window 内合并 UI publication，非 delta
  是立即 barrier。scroll geometry 保持 observation-only，live follow 使用
  100 ms cadence，rich admission 在用户交互后等待每行 150 ms idle dwell。
- 修复后的真实 production app 完成 `A → B → A`、5 次 zoom/restore 操作
  和 8 次上下滚动，界面持续可响应；隔离这些正常产品动作的 runtime-issue
  检查为空。相同 final validation binary 另完成三次 180 秒 soak（43/37/42
  cycles，均 2 次 session switch、memory plateau 通过、无 heartbeat stall、
  无 multiple-updates-per-frame、无 TERM/KILL/残留）。第三次在同一 PID
  交替执行 75 次 AX top/bottom，显式动作等待累计 60 秒。
- 第三次 Computer Use 互动 soak 的 Intatis PID Unified Log 确实记录了
  18 条 AppKit negative-geometry runtime issue，不能写成“未进入 app 日志”。
  三簇均在系统 `ThemeWidgetControlViewService` 激活后 0.17–2.99 ms 出现，
  前两簇发生在显式滚动开始前的 AX 全树/ReplayKit 截图窗口；backtrace 没有
  `ParagraphNSView`、`ParagraphView.sizeThatFits` 或 `CodeShell` 产品符号。
  两次没有该 AX 全树/截屏交互的相同 final binary soak 均为 0，第三次也继续
  clean exit、资源平台稳定。因此保留原始计数并分类为
  automation-correlated AppKit transient，不归因于 renderer layout。
- 同一 final validation SHA 的约 90 秒 Time Profiler + Hangs 导出中
  Potential Hangs 和 Hang Risks 均为 0 row；只有短时正常布局 burst，没有
  先前持续驻留的 AttributeGraph/NSHosting/PlatformView/sizeThatFits hot
  stack。完整 hash、soak 数值和限制见对应 `codex-report`。
- 随后“进入 session 即卡死”的独立复现证明 paragraph width-owner 修复仍未
  消除消息级 lazy/native feedback：同一 `cowork_tf2lkjbh` 的
  rich + `LazyVStack` 会持续接近单核 100%，plain + 同一 lazy 正常，
  rich + eager 正常，关闭代码块/表格 selection 后 rich + lazy 仍卡。
  进程 sample 的主线程 1509/1509 在 run-loop observer，1484 次经过
  `GraphHost.flushTransactions`、1478 次经过 AttributeGraph flush、
  1175 次经过 `AG::Subgraph::update`。最终根因边界是消息粒度
  `LazyVStack` 对混合 SwiftUI/AppKit 可变高度 rich row 的 mount/layout
  transaction feedback；selection 只是次要成本，不是必要条件。
- macOS Chat/Code/Cowork 生产 transcript 现改为最多 16 个顶层 row 的固定
  history window，window 内为 eager `VStack`；更多历史通过
  Earlier/Newer/Latest 显式分页。page scope 隔离 bottom anchor、scroll
  coordinator 与 rich admission；旧页收到 append 时保持稳定且不
  auto-scroll，Send/Cowork Retry/Latest 回到最新页。4 条以上 raw-first
  admission defer 仍保留，但不再选择 lazy 布局。没有全局无界 eager、没有
  新 document/native-view/height cache，也没有 EventLog/provider/permission
  语义变化。共享 iOS Chat 本轮未迁移，仍需独立验证。
- 最终 focused `MessageRenderingTests|ThreadScrollCoordinatorTests` 为
  71/71；原生 `NSHostingView` 测试对 16 个 rich row 执行 4 轮
  top↔bottom，并冻结 paragraph identity。IntatisMac unsigned Debug build
  通过。真实问题 session 首次进入、反复滚动、A→B→A 和 55-message
  Earlier/Latest 翻页均响应；抽样 CPU 为 0.0%，没有新 hang incident。
  这关闭当前用户报告的 macOS session entry/scroll freeze，不替代 >160 秒
  current-container soak、VoiceOver/clipboard、iOS 真机或历史 malloc
  retaining-edge 取证。

## 2026-07-27 外部 MCP Server 客户端完整构建

- 唯一规划与证据入口为 [`codex-report/07_25_26-14_58-mcp-full-system-plan.md`](../codex-report/07_25_26-14_58-mcp-full-system-plan.md)。其中 W0–W10 的**外部 MCP Server 客户端**范围已经接入当前源码：client-only SDK、配置/import/catalog、session attachment、per-Agent `MCPGrant`、session-owned runtime、authority-isolated connection pool、stdio / Streamable HTTP、OAuth、完整 discovery、Codex-compatible `tool_search`、Resources、Prompts、Completions、Roots、Sampling、Elicitation、logging/progress/cancel/subscription、2025-11-25 experimental Tasks、macOS 管理/会话内容面和 CLI 管理/运行面。没有加入 Intatis MCP Server、Hosted Apps、私有 plugin/auth/form、Knowledge/RAG 或任何 server-facing 产品 seam。
- 当前发行平台边界是：`IntatisMac`（Developer ID/direct-distribution
  workbench）与 `intatis` CLI 支持 stdio + HTTP；`IntatisiOS` 不链接
  `IntatisMCP`、transport 或 MCP 产品 UI。共享 client core 在 `IntatisMCP`，
  本地进程 ownership 在独立 `IntatisMCPStdio`，原生 HTTP socket binding 在
  `IntatisCurlTransport`，Linux seccomp/ptrace 执行守卫在内部 C target
  `IntatisMCPStdioGuard`。源码中的 `IntatisMacAppStore` HTTP-only linkage
  只是遗留 target 事实，不再是架构或验收分支。
- 运行链已经落为 `global catalog → session attachment / per-Agent grant → exact session owner → authority pool → raw catalog snapshot → Agent-visible view → 每次 provider dispatch 的 AgentRequestToolSnapshot → AgentLoop / PermissionEngine / durable tool ticket → exact prepared MCP route`。`MCPRawCatalogRevision`、`MCPAgentCatalogViewRevision` 与 `MCPBindingID` 分离；同一 provider response 只能执行自己冻结的 route，authority、grant、schema、catalog、connection 或 revocation 任一失配都在发送前 fail closed。Cowork worker 默认零 MCP，child 只能取得交集 grant，`@permission-reviewer` 与 GoalVerifier 永远为零 MCP。
- MCP 凭据与普通模型 provider 配置是两套后端：macOS App 的 MCP bearer/header/env/OAuth secret 使用真实 Security.framework data-protection Keychain；CLI 使用认证加密、owner-only 的 `MCPCLIEncryptedSecretStore`。catalog、EventLog、`session.json`、诊断和 CLI history 只保存 opaque `MCPSecretReference`/身份摘要。普通模型 provider 仍使用 Intatis-owned config/auth/env/file resolver；旧文档中的“GUI 不使用 OS Keychain”只描述该 provider 路径，不适用于 MCP。
- MCP 输出在进入模型、EventLog 或 ArtifactStore 前同时经过 exact/derived secret redaction、二进制秘密检查、结构/MIME/URI 校验和 block/result/request/turn aggregate budget；sanitization 扩张也按最终字节收费。server 发起的 sampling/elicitation/tasks callbacks 与 logging/progress/cancel notifications 都由固定 connection authority/generation 的 bounded broker 接收，执行前仍需 grant/lease/权限/用户交互与 durable terminal；通知只持久化有界、脱敏、低频里程碑，迟到/重复/跨 generation/token 的输入无权结算当前请求。
- 自动化已经覆盖 client-only SDK surface、双 protocol profile、ToolRegistry exact binding、输出/Artifact budget、HTTP/OAuth、managed stdio、callback/notification、动态目录、tasks、可靠性与产品 owner。当前最终源码结算为：full SwiftPM 1362 tests / 16 个显式 opt-in 环境 skip / 0 failures；官方 `@modelcontextprotocol/conformance@0.1.16` client scenarios 23/23（`codex-compat` 5 + `standard-extended` 18）；Intatis Tasks interoperability 3/3；W10 七个 focused suites 102/102；managed stdio 40/40；P1 八个 MCP suites 80/80。根 SwiftPM、`intatis` CLI、Developer ID macOS 与 iOS unsigned Debug build 均通过；本决策前还执行过遗留 App Store target 的 HTTP-only link 验证，该结果只作为 dated provenance，不再进入当前产品矩阵。当前源码的 aarch64/x86_64 musl 静态 CLI 交叉构建也通过，SHA-256 分别为 `8f03fbccb3b8d3301e04ff7e6aca635286771c414ed124407e0fc532718856a9` 与 `0a8071e5d01877c823d634f7a4613b267da64f159714939f10b61f8d65f06a20`。以上不等于已完成 Developer ID 签名/公证发行、真实 Linux+bwrap 运行、真实第三方 server/OAuth 账号矩阵或签名 App Keychain E2E；这些环境证据仍明确保留为 `I-ENV`。

## 2026-07-26 独立 Web renderer parity 实验

- `Experiments/WebRendererParity/` 仍是不接入生产 target 的独立 Vite/React 行为实验，但主页面已从 source/projection 编辑器改为 neutral conversation renderer lifecycle lab。它使用 3 个完全合成且脱敏的本地 session fixture，每个 16 条消息，直接展示 GFM Markdown、hard breaks、literal raw HTML、无网络图片占位、安全 URL、KaTeX HTML+MathML 的 `\(...\)` / `\[...\]` / `$$...$$` 公式、只读 CodeMirror、unknown-language plain fallback 与 canonical copy；页面不使用第三方产品品牌、代码、样式、截图或资产。
- session 切换保留 outer shell，但以 exact `{sessionID, generation}` key 卸载旧 message subtree；旧消息不作为 hidden DOM 保留。独立 `ThreadResidencyStore` 把离开的 session 标成 30 秒 warm，快速切回取消旧 eviction，超时或 `Release warm` 后变 cold；warm 条目只保存本地 lifecycle metadata。当前会话初始只投影最新 12 条，向上按 10 条分页；近视口边界使用 900 CSS-pixel overscan，离屏消息以 measured-height placeholder 替换 Markdown/KaTeX/CodeMirror 子树。切换前会取消本地 stream generation；`Stress switch` 默认做 36 次有间隔切换。诊断面板/`window.rendererHarness` 只公开脱敏 session ID、generation、residency、DOM/message/math/editor 数、bounded math-cache 计数与已加载 grammar 名，不返回消息原文、parser、浏览器状态或 Intatis 数据。
- CodeMirror append-only streaming 已从“读取完整 doc 再整段替换”改为在现有 `EditorView` 上只插入 suffix；同内容不发 change，非 append 才 full replace。subtree unmount 会 `destroy()` editor 并减少 active-view 计数。KaTeX cache 仍是 renderer-realm 共享 LRU，但现在同时受 256 entries 与约 512 Ki characters 双重上限；动态 import 的 language grammar 会留在当前 JavaScript realm 并由诊断显式展示。它们与 warm thread metadata 分开计数，不把 DOM disconnect 冒充整个 realm 已回收。
- `Experiments/WebRendererParity/INTEGRATION_ASSESSMENT.md` 对比了实验、当次公开 Web build 观察与现役 `IntatisMessageContentView` → `IntatisMicrosoftMarkdownPipeline` → vendored `SwiftStreamingMarkdown` / iosMath 原生链路。结论保持：直接把 React/KaTeX/CodeMirror/session shell 经 `WKWebView` 接入 App 是 **NO-GO**；完整 Web 栈会扩大供应链、bundle、辅助功能、焦点/选择、Swift↔JavaScript、WebContent 和 EventLog resume 生命周期面。可复用的是 renderer/lifecycle 行为合同；production 仍保留 plain-safe、64 KiB admission、latest-only scheduler 与原生 `DocumentView`。
- 当前验证为 Vitest **46/46**、TypeScript + Vite production build 通过、266-package runtime+dev 安装图许可证扫描无拒绝项。构建主入口约 941.04 kB minified / 290.19 kB gzip，另有 lazy language chunks 与 KaTeX fonts；这是独立实验成本证据，不是 production 体积目标。先前 Microsoft Edge 的无截图 DOM 检查仍只证明原始 renderer 合同；本次 lifecycle 页面没有新增手工浏览器验收，不能冒充 App、SwiftUI/TextKit、VoiceOver、真实 selection/clipboard、长期 memory plateau 或 release 证据。
- 本轮没有修改 `Apps/`、`Packages/`、`Vendor/`、`Package.swift`、`project.yml`、`Makefile` 或 `docs/NEXT_TARGET.md`，也没有把 npm 依赖加入 SwiftPM/XcodeGen。实验继续只绑定 `127.0.0.1`，不读取 Intatis session、EventLog、凭据、工具、workspace lease 或 agent runtime；原有 exact lockfile 与局部 `THIRD_PARTY_NOTICES.md` 继续覆盖依赖，未新增第三方依赖。

## 2026-07-25 Cowork `@main` 持久模型历史（Codex CLI 对齐第一阶段）

- Cowork `@main` 不再把每次用户输入当成一条孤立的新请求，也不再从 UI 气泡、截短后的 `tool_call` 审计预览或 `task_completed.result` 猜测新式模型上下文。后续 submission 的 provider 请求从同一条 durable model-facing history 恢复先前的 user、assistant、tool call 与有界清洗后的 model-visible tool output，再追加当前用户消息。task-scoped worker 继续只收自己的 `ContextBundle`，不会拿到主对话全文。
- 新的 `model_history_item` 是 EventLog 中独立于 UI/audit 事件的 tagged record。用户 item 在首次 provider dispatch 前写入；一次 assistant 返回的完整 tool-call batch 在执行任何工具前原子写入；每个有界清洗后的 tool output 与对应 `tool_result` / execution settlement 在同一 EventLog batch 中落盘，再允许下一次 provider dispatch。流式 delta 只服务 UI，完成的 assistant item 只写一次；Conversation/Code/Cowork UI projection 对 model-history event 为 no-op，不会多显示一份气泡。新开 `AgentLoop` 使用同一份完整 EventLog 时可按 durable 顺序重建，不依赖进程内数组。
- prompt snapshot 按 Codex 的配对规则处理已经成为 prior history 的不完整工具对：有 call、无 output 时只在本次请求副本紧邻插入 `aborted`，不改写 EventLog；孤立 output 不发给模型；并行工具结果按原 assistant call 顺序回填。同一 submission 的 whole-task Retry 当前仍是 fresh invocation，不是 Codex 式 in-place turn resume。重复/冲突 item ID、同 turn 重复 call ID、冲突 output、错误 root/submission/agent binding、未知 schema version、unknown future event 或 seq gap 均在 provider dispatch 前 fail closed，不猜配。
- 旧 session 没有 `model_history_item` 时，只通过严格 legacy bridge 恢复已完成的 root user/final-assistant 文本；一旦某 submission 有 direct model history，该记录就是唯一模型事实源。`ContextBundle` 仍作为追加的非可信任务数据存在；已有 direct model tool pair 对应的 bounded audit preview 会被去重，legacy tool preview 则仍只作为非可信数据，绝不会提升为 assistant/tool role。
- 安全边界没有改成原样持久化所有工具输入：`write_stdin`、`spawn_agent`、`rename_session`、未知/非法、含秘密或超限的参数使用固定合法 JSON placeholder；`write_stdin` 原始字符不进入 EventLog。工具 observation 进入 model history 前再次做秘密清洗和限长。该 2026-07-25 阶段当时只证明跨 turn 与“新建 AgentLoop + 同一 EventLog”的 raw-history 恢复，尚未完成 replacement-history checkpoint；该主链现已由本文顶部的 2026-07-28 阶段完成。真实 App/process kill 后重开、provider-native reasoning 与历史图片重新装载仍未验证，不能宣称与 Codex 全部等价。
- 同一 AgentLoop 内空或重复的 provider call ID 现在会被改写为唯一 turn-local ID，并在 assistant call、工具审计、execution ticket、tool output 与后续 provider request 中一致使用，避免 OpenAI-compatible endpoint 每轮都回落 `call_0` 时破坏恢复。model history dispatch 还要求从 seq 0 到 durable tail 的 complete-known replay；unknown future event 或 seq gap 在 provider 前 fail closed。
- 本轮固定阅读官方 `openai/codex` commit `4c43465133428898aa84f0bfc02c306ed65fb66a` 的 ContextManager、normalize、rollout、resume reconstruction、compaction checkpoint 与对应测试。实现方式为 `reference`：没有复制、逐行翻译、vendor 或链接 Codex Rust 源码，`NOTICE.md` 无需变化。专项验证为 34 tests / 0 failures；最终完整 SwiftPM 为 1000 tests / 14 skipped / 0 failures，`swift build`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均通过，详细命令见 `docs/TESTING.md`。

## 2026-07-24 Code / Cowork 真实受控终端

- shell-capable 的 macOS Code、Cowork 与 CLI agent 现在拿到的不是一次性“代执行”接口，而是真实 `exec_command` / `write_stdin` 终端。短命令可直接等结果；长命令返回 opaque session ID，后续调用可继续读输出、写 stdin、发送 Ctrl-C、请求结束或强制终止。`tty=true` 使用真实 PTY，测试已证明 stdin/stdout 是终端、`/dev/tty` 可用且 Ctrl-C 能到达前台进程。
- 终端没有绕开 Intatis 原来的控制线。每次启动和后续输入都先过同一 ToolRegistry、CapabilityLease、PermissionEngine 和 durable execution ticket；terminal session 精确绑定 session、agent、task、attempt 与 WorkspaceLease。启动、交互和后台存活期间都会复核 canonical workspace identity；工作区被替换时，即使 model 不再轮询，也会继续等待进程退出并自动收口，task 结束、用户取消或 runtime shutdown 也会终止并等待相关进程。read-only worker、`@permission-reviewer`、iOS 和 host 明确禁用 shell 时看不到终端工具；raw `run_shell` 仍未进入 production registry。
- macOS 命令由 Seatbelt 约束在 WorkspaceLease 允许的路径内并默认断网；不再使用会限制大型构建产物的 8 MiB file-size limit。PTY 子进程由仓内小型 `IntatisPTYLauncher` C target 启动，`forkpty` 后只执行 C/POSIX signal、FD、chdir 与 exec 设置，避免在多线程 Swift 进程 fork 后继续运行 Swift runtime。父进程通过 close-on-exec error pipe 区分 chdir/exec 启动失败，输出持续 drain 到有界 head+tail buffer，完成但无人轮询的 session 会自动收口成一次性短期结果。
- 交互输入不会以原文或可离线猜测的固定摘要写入 EventLog、permission preview 或普通 tool args；授权 identity 使用进程随机盐，终端输出会对当前及延迟出现的输入回显再次清洗。危险命令检查会在内存里跨多次 `write_stdin` 保留当前输入行；普通文字、退格、换行、Ctrl-C 和纯重绘可还原，光标移动、补全、历史、escape 控制以及 shell keymap 改写直接拒绝，因此不能靠拆分输入或改写行编辑规则再补字绕过。输入 descriptor 若只接收一部分便报错，整个 session 会立即终止，不能带着不一致状态继续。继承环境保留 PATH/Swift/Xcode toolchain，但过滤 token、密码、认证、代理、数据库 URL、JWT、访问密钥、session key 等常见凭据变量，并给命令独立临时 HOME；终端执行边界还会不可移除地合并 `.netrc`、`.pgpass`、`.npmrc`、SSH/AWS/GPG/Keychain、provider auth/config 和常见 secret/key/certificate 文件清单，Seatbelt 对这些路径按 ASCII 大小写无关匹配。
- 本轮最终验证：`swift test` **984 tests / 14 skipped / 0 failures**；其中 `TerminalToolsTests` 25/25，另有 AgentLoop durable/privacy、shell permission、CapabilityLease、ToolRegistry 与 Cowork lifecycle 回归。IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug 均构建成功。macOS 实现可用；Linux PTY/默认 denied-pattern 映射、运行中的终端 resize/SIGWINCH、完整全屏 TUI 矩阵、App 被强制杀死后的跨进程 orphan 收口和终端 session 重启恢复仍为 `UNKNOWN` / 未完成。任意名字的自定义 secret 环境变量仍无法仅靠变量名过滤证明安全；极快自行 `setsid` 的后代追踪与工作区身份复核到进程启动之间的极窄替换窗口也需要后续继续验证。

## 2026-07-24 Session 切换布局风暴修复

- macOS Code / Cowork 的可见 thread 现在由纯展示层 `IntatisThreadPresentationScope(kind, sessionID)` 定义身份。根详情和 thread 子树都以该 scope 建立 SwiftUI identity；bottom sentinel 也使用 scope-specific ID。切换 session 会销毁上一棵 ScrollView / `@StateObject` 展示树，但不会停止由进程级 manager 持有的 runtime。
- Code / Cowork 不再用静态 bottom anchor、`DispatchQueue.main.async` 或无 owner 的延迟闭包自动滚动。每个窗口的可见 thread 各有一个 `IntatisThreadScrollCoordinator`：同一时刻最多保留一个可取消 generation，请求执行前复核 exact scope；初始恢复无动画，只有 completion 使用短动画。用户离开底部后 live/rich 更新不抢回滚动位置，回到底部后恢复跟随。rich document 后续增高只在仍处于 bottom-following 时做无动画校正；raw-content/width 明确开启 layout epoch，每个 epoch 只允许一次 shrink→regrow recovery，第二轮相同高度振荡被拒绝，相同高度和亚像素抖动也不会形成反馈循环。
- `AppSessionRuntimeManager` 已移除 retained runtime `objectWillChange → runtimeRevision → 根视图全局失效` 桥。窗口只订阅 exact `{SessionKind, SessionID}` 的 `opening / idle / running / removing` 展示状态；Cowork 的 `runtimeBusy` 汇总 agent、Goal、直接操作和 shutdown，而 recent-session settlement 仍只消费真正的对话工作边沿。删除现在由统一 `removeSession(..., deleteStorage:)` 事务完成，exact `removingKeys` 围栏覆盖 runtime drain、磁盘删除或 abort、observation 清理和最终跨窗口通知；围栏内 activity 不得把 `.removing` 覆盖回 idle，另一个窗口也不能在目录删除前 reopen 同 key。
- Chat 历史恢复现在先取得 strict replay snapshot，再登记从 `lastSeq + 1` 开始的 live stream，并在 subscriber 已注册后做第二次 strict catch-up；snapshot/catch-up/stream 按 seq 去重。历史由 actor builder 在主线程外一次折叠，主线程只发布一次完整的 messages / artifacts / progress / turn-stats 状态，随后才逐事件应用 live 增量。首次 strict replay/catch-up 失败会在建立错误 live publication 前 fail closed 并显示错误；切走再进入 cached macOS runtime 会幂等 `start()` 重试。stop、shutdown、重启、失败重试和 restore/live 边界均有确定性测试，已完成历史不再以逐事件或逐 token 的方式重新播放。
- 现有 Markdown / 代码 / 单美元 LaTeX renderer 的 stale-request、activation 和 width stability guard 保持不变。本轮 profile 在 presentation、scroll 和 runtime propagation 修复后没有再出现持续 SwiftUI / AttributeGraph 活动，因此没有进入计划中的 Paragraph / Table 条件补丁，也没有修改 vendor、依赖、NOTICE、EventLog schema、provider、权限或字体。
- 当时源码按 MCP 接入前的 11 个 SwiftPM test target 串行分片验证为 **955 tests / 14 skipped / 0 failures**；SharedUI 8 个 class 合计 70/70，其中本轮 `ThreadScrollCoordinatorTests` 8/8、`ChatHistoryReplayTests` 6/6。IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug 均构建成功。整包 serial runner 在收口过程中两次进入无摘要等待，parallel runner 的 3 个并发临时目录/timeout 失败均在串行 3/3 通过；最终 SharedUI 整 target 也出现 runner/lock 等待，但 8 个 class 独立全部通过。故权威自动化结果是 target/class 分片总和，不把未结算的一键命令伪记为 pass。
- 真实单实例 Computer Use 使用 2816 / 1575 / 758-event Cowork 历史做 32 次 A→B→C→A 点击切换：单次 action + AX capture 观测为约 0.73–1.14 秒；停止切换后 CPU 为 0.7%、RSS 约 275 MiB，`vmmap` footprint 约 141 MiB，1 秒 sample 的主线程 860/860 样本在事件等待而非 SwiftUI/AttributeGraph 布局。16 次与 32 次后的 footprint 分别约 142 / 141 MiB，没有复现事故现场约 2.6 GiB footprint 或单核持续占满。第二窗口选择 C 后关闭，第一窗口仍保持 A；关闭最后窗口后同一 PID 继续运行，只有 `Command-Q` 才退出。以上是本机 Debug、单实例、短时观测，不冒充长期 soak、真实后台 provider 工作或低端设备证据。

## 2026-07-24 macOS assistant / agent 正文全宽

- macOS Chat 以及 Code/Cowork 共用 thread row 现在按内容角色区分宽度：用户消息继续使用原有 trailing 气泡、`messageMaxWidth` 与左侧 gutter；正常 assistant/agent 正文和 Thinking waiting row 使用整个 `contentWidth`，不再在右侧保留气泡式空白。system message 继续使用原约束，tool/error/patch/permission/task 等结构化卡片继续使用各自容器和宽度策略。
- `IntatisMessageContentView`、Markdown/代码/公式 renderer、EventLog、projection、provider payload 和 iOS `MessageRow` 均未修改；更宽的 Markdown 表格、代码块和公式只是继承新的 macOS 父行宽度。新增 `ThreadLayoutTests` 冻结 full-width leading reply、trailing user cap/gutter 与其他 leading row 维持旧约束三项合同。
- 验证：Swift parse 通过；`ThreadLayoutTests` 3/3 与 `MessageRenderingTests` 25/25（合计 28/28）通过；`IntatisSharedUI` target、IntatisMac macOS Debug、IntatisiOS generic Simulator Debug 均构建成功。未启动 App 做本轮像素检查，因此宽窗口实际视觉与 Markdown 表格/代码块的最终行宽仍待用户运行态复核。

## 2026-07-23 会话完成时间、原位停止与 Thinking 计时

- Chat / Code / Cowork 的 recent sessions 现在由 `SessionActivityHistoryStore` 从各自 EventLog 的 durable terminal 事件计算最近完成时间并倒序排列：现行数据只使用 `turn_outcome`，旧数据才回退到 assistant / agent `message_completed`，避免 Cowork 恢复/对账补写 submission terminal 被误算成新工作。打开、选择、重命名、迁移、恢复或其他文件写入不会再凭 `events.jsonl` mtime 把会话顶到第一位；相同完成时间以 `SessionID` 稳定排序。扫描使用单次 Data read、newest-first terminal decode 和基于 file signature 的只读缓存；mtime 只用于缓存失效，绝不作为 recency。后台 runtime 直接订阅明确的 published activity 状态，只在 active→idle 时触发对应 mode 的 history 重扫。
- composer 的主操作位现在在 idle 时显示 Send，在 Chat / Code / Cowork agent 工作时原位替换为系统 `Button(role: .destructive)` + `stop.fill` 的红色 Stop；不再同时显示两个按钮，Return 也不能绕过 Stop 发起新请求。Chat 只取消当前消息/生图操作，Code 只取消当前 turn，Cowork 普通工作取消 active tasks，durable Goal 则走 scoped pause/checkpoint；session runtime、projection subscription 与 `@permission-reviewer` 均继续存活。caller cancellation 同时识别原生 `CancellationError` 与 provider-normalized `IntatisError.cancelled`，且流结束到 completed 落盘之间有最终 cancellation fence，用户 Stop 不会被伪记为 completed/failed。
- macOS Chat 与共享 Code / Cowork 的现有 Thinking spinner 前新增 phase-local 秒数，例如 `15s Thinking…`；`TimelineView` 每秒更新，phase identity 包含 exact session 与最新 raw trigger item，等待行消失、工具轮次切换或 session 切换都会重置计时。该显示不新增 EventLog、协议或 provider 字段。
- 本切片验证：Swift parse；SharedUI 与 AgentKernel SwiftPM build；Conversation/AgentLoop outcome+policy/Goal/orchestration/automatic-review/message-rendering focused **303/303**；XcodeGen；IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build；English/zh-Hans catalog compile；`git diff --check` 均通过。遵守 renderer NO-GO，未启动 App/fixture，实际像素、1 秒刷新、VoiceOver 与真实 provider/server cancellation timing 仍为 `UNKNOWN`。

## 当前真实状态总览

- Intatis 是 Apple-first、Swift-native 优先的本地 AI 工作区，当前 session 进入 v0.16 Agent 文档/媒体 + 网络/浏览器工具增强；三个产品面：Chat / Code / Cowork。项目政策现允许按 `docs/OPEN_SOURCE_REUSE.md` 选择性复用兼容许可证的公开源码、公开 model-facing prompt 与测试，但必须记录 provenance、更新 NOTICE、保持安全/平台边界；截至 2026-07-12，OpenCode 仍为 research-only，尚未把其源码、公开 prompt、UI 资产或 runtime 加入 Intatis。`project.yml` 的 `MARKETING_VERSION` 仍为 `0.12`（本轮未做版本号 bump）。
- 当前 SwiftPM 图包含 14 个 public library products、3 个内部 C targets、CLI、14 个 test targets 和 1 个仅开发期使用的 MCP conformance client executable。Apple 平台的 SwiftPM 与 XcodeGen deployment target 均已收敛为 macOS 26 / iOS 26，不再把旧系统 fallback 作为当前验收面。唯一发行 macOS App `IntatisMac` 是 Developer ID/direct-distribution workbench，提供完整 Chat / Code / Cowork、Skills 与 stdio/HTTP MCP；源码中的 `IntatisMacAppStore` 是遗留非产品 target；iOS 仍是 chat 子集且没有 Skill/MCP runtime、transport 或产品表面。
- 2026-07-18 已完成对话 renderer 的本地原子切换：`IntatisMessageRendererMode` 现役值为 `.microsoft` / `.plainSafe`，持久键仍是 `intatis.messageRendering.mode.v1`。无偏好默认 Microsoft；损坏或未知值 fail closed 到 plain-safe；旧持久值 `rich` 与旧启动参数 `-IntatisRichTextMessages` 只作迁移兼容并映射到 Microsoft。新启动参数为 `-IntatisMicrosoftMarkdownMessages`，`-IntatisPlainSafeMessages` 与其冲突时仍由 plain-safe 胜出。macOS、iOS 和离线 fixture 的 Picker 也使用 resolved binding，旧 `rich` 会显示为已选 Microsoft 而不是空 selection。plain-safe 在历史 message view 首次构造前生效，不进入上游 parser/view；raw-state 对初始历史、activation/reentry、correction/truncation 与 final 同步选择 exact raw `String`（空且未完成时显示 `…`），纯追加流式中间态经 100 ms fixed-window leading/trailing latest-only 投影，最终精确 flush。当前确定性测试证明 state/string 合同，不能冒充 OS 像素、selection 或 clipboard 字节证据。切换模式不读写或迁移 EventLog。
- iOS 原生 `Settings.bundle` 已同步为同一 key、`microsoft` / `plainSafe` values，并以 Microsoft 为默认值；macOS/iOS 应用内设置也使用同一合同。plain-safe 仍是永久救援熔断，不因新 renderer 成为默认而删除；该入口不引入 workspace/agent 能力，也不改变 iOS chat-only 平台边界。
- macOS / iOS 产品界面现以 English 为 development language，并通过两个 App 主 bundle 共用的 `Apps/SharedResources/Localizable.xcstrings` 提供 English 与简体中文。系统 Preferred Languages 或用户为 Intatis 单独选择的 App Language 会在进程启动时决定语言；应用不写 `AppleLanguages`，也不强制覆盖 SwiftUI locale。`IntatisLocalization` 只在展示边界处理动态按钮、状态、设置、错误和辅助说明；session/agent/provider/model 名称、文件与工作区路径、用户输入、模型输出、Markdown/公式/代码、EventLog、协议 raw value、tool payload 与 model-facing prompt 均保持原文。iOS 的 `Settings.bundle` 和 `NSMicrophoneUsageDescription` 另有独立 `en` / `zh-Hans` 表。此前仓库实际没有 Intatis 自身的中文资源，现有英文硬编码被保留为 English source/fallback，而不是覆写一套既有中文基线。
- 2026-07-22 本地化验收：共享 catalog 共 486 个 key，315 个直接动态查表 literal 零缺失，全部显式包含非空 `en` / `zh-Hans` 且格式占位符一致；IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug 构建通过，两个主 App bundle 均实际携带 `en.lproj` / `zh-Hans.lproj`，iOS 的 InfoPlist / Settings.bundle 专用表也完整。Foundation 路由验证为 `zh-CN` / `zh-Hans-CN` → `zh-Hans`、`en-SG` → `en`，未支持的语言回退 English。renderer release 仍为 NO-GO，因此本轮未启动 App 做运行态视觉检查。
- 现役 rich 路径使用仓内 `Vendor/SwiftStreamingMarkdown`：它是基于 Microsoft `SwiftStreamingMarkdown` `v0.6.0` / `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`、由 Intatis 维护的 vendored thin derivative；Markdown parser、AST、原生文本与表格布局均由该上游派生包负责，Intatis 不自建 Markdown parser/layout。初始 cutover 移除了 HighlightSwift、iosMath、Shimmer、macro/snapshot 测试依赖、Copilot 品牌资源及旧 regex LaTeX/语法高亮路径；2026-07-23 经重新审计后只以 Apple-platform exact dependency 形式恢复 iosMath 2.5.0。当前派生路径 code-aware 识别 `$...$` / `\(...\)` inline 与 `$$...$$` / `\[...\]` display（display 可跨行），不设公式数量、单式 UTF-8 或固定附件尺寸上限。图片、citations、文字动画和语法高亮仍未启用；代码保持原文与横向滚动，table copy/download actions 继续隐藏。Intatis facade 仍只维护角色/mode、64 KiB syntax-agnostic whole-message admission、50 ms 未完成消息防抖、100 ms raw latest-only 投影、最新 revision 发布门与安全链接策略。
- 流式背压为 process-wide output-free `IntatisLatestOnlyPermitScheduler`：全局最多 1 个 parse permit、32 个 pending message key；每个可见消息至多 1 个 running permit 与 1 个可替换 pending acquire，view 内 `AsyncStream.bufferingNewest(1)` 只保留最新 raw revision。scheduler 不保存/执行 parser work，也不保存 document/result；MainActor 只发布 raw/mode/completion/appearance/config 全部仍匹配的最新 `RenderableDocument`。plain-safe 与 rich pending/rejected/oversize 共用一个 facade-lifetime raw projection：append-only 中间态至多按 100 ms leading/trailing cadence改写整段 `Text`，activation/reentry/correction/truncation/final 绕过节流同步精确显示，generation + task-generation 双重阻止旧 timer 覆盖。75 ms 正式基线在 replay 20 轮中有 2 轮 interaction p95 超过 8 ms 冻结门，已拒绝并调到 100 ms 重验。没有 completed-document cache 或 paragraph native-view cache；链接只放行 `http` / `https` / `mailto`，远程/本地 Markdown 图片与语法高亮关闭。Microsoft 模式可识别 code-aware inline/display LaTeX；plain-safe 则在构造任何 Markdown/math parser 前原样显示。这里的 32 是 parser pending message key 背压，不是公式数量上限；iosMath native label 的同步 UI 更新不计入后台 Markdown parse permit，必须由单独的主线程与 GUI 性能门验证。
- Intatis 根清单已经移除旧 MarkdownUI、NetworkImage、swift-cmark 0.5、HighlightSwift/highlight.js 和旧 renderer 文件/资源；经审计的 Microsoft v0.6.0 thin derivative 现完整 vendored 于 `Vendor/SwiftStreamingMarkdown`，根 `Package.swift` 使用仓内相对路径，Microsoft MIT `LICENSE`、README、完整派生包回归测试和永久 patch/provenance ledger 与源码一起由 Intatis 根 Git revision 固定。导入明确排除了嵌套 `.git`、434 MB 构建缓存、probe、上游 agent/CI metadata，以及含 Microsoft bundle identity、Roboto 字体和未单独确认示例图的非产品 `Examples`。派生包 manifest 现除 `swift-markdown` 0.8 / `swift-cmark` 0.8 外，还 exact-pins Apple-only iosMath 2.5.0 commit `838cddc01fdd67efd530f8bb67959ad2715f9b06`；它没有传递 package 依赖，但会单独携带经批准的 8 套 OTF 数学字体、math-table 与许可证/readme 资源。根与 vendor 两份 `Package.resolved` 已匹配 exact iosMath pin；2026-07-24 macOS/iOS Release app 重建确认字体、license/readme/math-table/script 与仓内同 hash NOTICE 均进入最终 bundle。该供应链/资源闭环不等于运行时 release GO；long soak、真实 clipboard/VoiceOver 与真机门仍独立存在。
- 事故前窄协议/自动化基线：renderer focused 37/37（mode 11 + scheduler 6 + rendering/lifecycle/raw projection 20）；完整 SwiftPM 755 tests、14 skipped、0 failures。固定 17-message / 1,249-delta production-facade Release 协议中，100 ms Plain 与 production-shaped `LazyVStack` Microsoft 各完成 5 cold + 20 replay、25/25 final source rows exact，冻结的 interaction p95 ≤8 ms / max ≤50 ms 门均为 0 failures。Plain cold/replay worst p95 为 6.152250/4.370458 ms、max 30.395208/29.591167 ms；Microsoft 为 4.020458/4.876292 ms、max 37.840875/36.596500 ms，replay absolute peak/residual RSS 最高 102.953/101.375 MiB。eager `VStack` 对照 cold 5/5、replay 20/20 p95 超门；当时 xctrace 17/17 exact、>250 ms potential hang 0，target log 中旧 lifecycle warning pattern 0；较早 CU 还验证过 legacy `rich`、Rich/Plain 路由与历史恢复。以上均是随后 GUI 资源事故之前的历史证据，不能支持当前 release GO，也不能替代下两条事故/修复状态。最新 Cowork Goal/reviewer 错误仍与 Markdown 独立。真实低端 iPhone/iPad 矩阵继续为 `UNKNOWN`。
- 2026-07-18 GUI/Computer Use 事故现在保留为**历史 adverse evidence**，不能再称为最新结果：当时验收错误地同时保留三个 `Intatis Renderer Validation` 实例；Force Quit 对主实例显示 129.63 GB application memory（不是精确 RSS/footprint），CPU diagnostic incident `FA228932-2C40-4AC2-A0C2-62EF41342B4A` 在 160 秒窗口记录 90 秒 CPU，采样 footprint 109.16 MB→803.30 MB，重栈含 SwiftUICore/AttributeGraph/lazy layout/`ParagraphView`/`SelectionOverlay`。证据证明当时 validation process 的 renderer/UI lifecycle 发生失控增长，但没有 malloc stack/heap graph，最终 retaining edge 与根因仍为 `UNKNOWN`；不得把后续短时通过解释成已经找到了该事故根因，也不得单独归因于 parser、Microsoft、Computer Use 或 Apple framework leak。
- 事故后 patch group 8 恢复 `DocumentView` 与两平台 `ParagraphView` 的 upstream-equivalent 手写 `Equatable`，并从 rich 整棵 `DocumentView` 移除重复 SwiftUI selection overlay；plain、native paragraph、table/code leaf 仍保留 selection。该 patch 当时让 AppKit/UIKit 共用 bounded width-invalidation tracker；本次 patch group 11 只替换 macOS 的 width ownership：AppKit paragraph 不再声明 intrinsic width，精确接受 SwiftUI proposal，只保留一个 exact-width height measurement，且 bounds width 变化不再 intrinsic-invalidate。UIKit 继续保留 patch group 8 合同。2026-07-18 三实例事故的最终 retaining edge 仍为 `UNKNOWN`，不能由本次后来可重复的单实例 zoom/restore 根因反向替代。
- Release validation build 只在 `INTATIS_RENDERER_VALIDATION` 条件下编入分阶段 production-shaped fixture；`scripts/RendererValidationWatchdog.swift` 以单进程组、100 ms telemetry、wall/RSS/footprint/CPU/实例数硬阈值和 TERM→KILL 清理保护启动，并要求 bundle ID、fixture SHA、fixture binary marker、显式 executable SHA、显式 `--math disabled|single-dollar` 与 `--user-approved-gui` 全部匹配。2026-07-24 hash-pinned executable SHA-256 为 `ec56cec173c13e41edb4f53e3ff5fcb1ac3d35079d40f140c4503a4d99dde55f`。同一 Microsoft renderer 的 `math-structure` isolation A/B 均通过：disabled/单美元 enabled 的 peak RSS 分别为 70,909,952 / 70,942,720 bytes，peak footprint 11,649,768 / 11,682,536 bytes，peak rolling CPU 1.5962% / 1.4978%；这是各一次约 21 秒 containment 样本，不可解读为正式性能提升。`math-one`、`math-thirty-two`、`math-history`、`math-stream` 也各通过约 21 秒 isolation，所有 run exit 0、未用 TERM/KILL、二次清理成功且无残留。
- 2026-07-24 单美元历史实现（其 delimiter/32 个/8 KiB/1024×256 policy 已由 2026-07-31 patch group 12 supersede）：vendored parser 使用 code-aware request-local catalog，普通 `$...$` 当时只在每式 ≤8 KiB、每消息 ≤32 个时生成 attachment；标题、列表、引用和表格的最终 attributed output、copy/AX source、stream completion/replacement 均有回归。AppKit paragraph 现显式建立并保活 `NSTextContentStorage → NSTextLayoutManager → NSTextContainer` TextKit 2 网络；整段 `setAttributedString` 后恢复 `primaryTextLayoutManager`，内容或有效宽度变化后在下一 main-queue turn 合并调用 `layoutViewport()`，这是此前 attachment provider 已存在却显示为空的直接原因与最终修复。attachment 使用由唯一 MIME 派生的专用动态 UTI、subclass-owned provider，并在 AppKit 清除 generic `attachmentCell`。当时 AppKit/UIKit provider 均承载 live `MTMathUILabel`，MainActor preflight 上限为 1024×256 points，越界/无效则 exact literal fallback；不生成或缓存 production raster preview。formula view 跟随 semantic appearance，SharedUI render revision 纳入 Dynamic Type。
- 2026-07-31 当前公式实现：同一 request-local catalog 现在接受 `$...$` / `\(...\)` inline 和 `$$...$$` / `\[...\]` display，presentation 一直传到 scalar attachment payload 与 live iosMath label；display 可跨行。Intatis 派生层已移除公式条数、单式字节数和固定 attachment 尺寸上限；无效 TeX 或非有限/非正 intrinsic geometry 仍 exact-literal fallback，protected Markdown、currency 与 escape 仍不误识别。当前公式 focused 39/39、vendor strict Release 90/90、根 `MessageRenderingTests` 41/41 均通过；`IntatisSharedUI` target、XcodeGen、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 均成功。覆盖包含 64 个公式、12 KiB 单式、超过旧 1024pt 的有效 attachment 和四类 delimiter；本 patch group 未跑完整根 suite、Release app 矩阵或真实窗口，不能把当前自动化表述为 renderer release GO。
- 最终验证：`MessageRenderingTests` 25/25；vendor 75 XCTest + 7 Swift Testing = 82/82；vendor Release `-warnings-as-errors`；IntatisMac 与 IntatisiOS Simulator 的 Debug/Release；XcodeGen；双端最终 app bundle/NOTICE/font inventory 均通过。正式 macOS Release executable SHA-256 为 `ef966a5e76d77ef9eebf2394068133ecb3202e3910e7875522c47620ae53ee8c`；macOS/iOS Release bundle 均含 8 OTF、对应 5 份 license、4 份 README、8 math-table plist 与 script，仓内/双端 app `NOTICE.md` SHA-256 同为 `02778763b3743e591b3ccb30537f853d2d5a791b1002e032ff65ed5821c7b5b8`。Computer Use 对同一 validation executable 的 Light/Dark `math-structure` 各完成约 47.47 秒并通过：稳定截图实际显示 heading/paragraph/lists/blockquote/table 公式，code literal 保持 `$not_math$` / `$table_code$`，AX tree 暴露原始 TeX 语义；Light/Dark peak RSS 为 136,691,712 / 135,036,928 bytes，footprint 48,710,520 / 48,087,904 bytes，rolling CPU 11.5379% / 11.2088%，均 exit 0、无 TERM/KILL、无残留。截图/AX 不等同于真实 clipboard 或 VoiceOver 操作，长时 soak 与 iOS 真机仍是 release blocker。
- v0.12 GUI 设置已支持两层 provider/model catalog：provider 层保存 Base URL、Chat endpoint 与 secret ref 元数据；model 层保存模型 id 与展示名。Chat 对话页可直接按 provider 分组切换模型，选择写入 `intatis.providerSelection.v1` 并立即重建 `ProviderRegistry`，下一条请求使用新 provider/model。Base URL 与 Chat endpoint 输入框会互相同步；旧的 `/chat/completions` 误填到 Base URL 的配置会被清洗。**该普通模型 provider 配置路径**不读写 OS Keychain；macOS 设置页用户主动输入的 API key 会写入当前可编辑的 Intatis-owned OpenCode-compatible provider JSON `provider.<id>.options.apiKey`，iOS 设置页仍写入 app container `Intatis/auth.json`（可由 `INTATIS_AUTH_FILE` 覆盖），真实 provider 请求只从 auth JSON、Intatis-owned OpenCode-compatible config `options.apiKey`、环境变量或显式 secret 文件懒加载并进程内缓存；当 Intatis-owned OpenCode-compatible config 中 `provider.<id>.options.apiKey` 是直接值时，macOS 会把 secret ref 绑定到该 provider config 文件本身，避免同 provider id 的旧 auth JSON 抢先覆盖；provider registry 刷新会清空旧 secret cache，OpenAI-compatible Authorization header 会在发送前剥离误填的 `Bearer ` 前缀和外层引号。MCP 使用上方独立的 Keychain/CLI 加密 credential store，不经过本 provider resolver。macOS 高级用户可通过 `INTATIS_CONFIG` 或 Intatis 自有路径 `~/.config/intatis/intatis.json` / `intatis.jsonc`、app support `intatis.json` / `intatis.jsonc` 手写 JSON/JSONC 覆盖 provider catalog；默认不读取 OpenCode app 配置，也不按 `opencode.json` 文件名自动发现。高级配置内容采用 OpenCode-compatible shape：顶层 `$schema` / `enabled_providers` / `model` + `provider.<id>.npm/name/options.baseURL/options.apiKey/models`；`options.apiKey` 支持 OpenCode-style 明文、`{env:NAME}` 与 `{file:path}`。旧 `~/.config/intatis/config.json`、app support `config.json` 与旧 direct `providers` 数组仍作兜底兼容读取。设置页提供 Open Intatis Config 按钮，优先打开/创建 `intatis.json`；若只发现旧 `config.json`，会生成新的 Intatis-owned、OpenCode-compatible 模板。模板默认写入 `{env:...}` API key 引用，只有用户在设置页显式输入 key 时才写入明文 `options.apiKey`。
- iOS 设置页现提供系统 Files `Import Intatis Config` 入口，显式导入与 macOS 高级配置相同的 Intatis JSON/JSONC：OpenCode-compatible `provider` map 与旧 direct `providers` 数组均可解析，provider/model 选择、Base URL、Chat/Responses endpoint、raw model options、adapter identity 与 capability metadata 会进入 Chat-only 配置。导入器限制文件大小、provider/model 数量、字符串与 URL，并拒绝含 user-info 或非 HTTP(S) endpoint。外部文件不是 canonical truth，也不会被持续监视；成功导入后，iOS 在 app Application Support 的 `Intatis/imported-chat-configuration.json` 保存 schema-v1 app-owned protected snapshot，UserDefaults 仅保留不含 raw options/明文 key 的兼容 catalog/selection。`options.apiKey` 直接值会先迁入受保护的 `Intatis/auth.json`，再安装配置；`{env:...}` / `{file:...}` 引用保持引用但会在 UI 警告其 iOS 可用性需复核。model variants 当前不导入且明确警告；未知/未实现 npm adapter 保留 exact identity、显示警告并继续在网络前 fail closed。`ThreeColumnShell.threadOnly` 不再私自嵌套 `NavigationStack`，由 iOS root 持有唯一原生导航容器，因此已有凭据时 history、composer 第一排限宽 model menu、顶部/抽屉新建与抽屉底部 Settings 仍始终可见，配置导入不依赖“缺 key 自动弹设置”。该入口没有引入 Tools、Permission、AgentKernel、Cowork、shell 或 workspace runtime。
- macOS/CLI OpenCode-compatible 模型配置现在保真 `provider.<id>.npm`、model object 内的 `provider.npm` 与 `models.<model>.options` 任意 JSON。Intatis-owned custom provider 的 adapter 选择是 model override → provider npm → `@ai-sdk/openai-compatible` default；adapter 跟随 connection/profile immutable revision，未知或未实现 package 在网络前 fail closed。OpenCode-shaped options 按 shared-plain-object recursive、array/scalar/null replacement 的 `mergeDeep` 语义组合。这个开放、lossless 路径属于 Chat/Code 等兼容 `ProviderEndpoint` 配置；Cowork durable profile 仍必须先通过显式 allowlisted options schema。Request builder 最终拥有 `model` / `messages` / `tools` / `stream`，并移除配置 `stream_options` 与候选数量参数。新式 compatible/OpenRouter package adapter 按 pinned OpenCode package 省略 `n`，也不再从 parallel-safe tool metadata 自动生成 `parallel_tool_calls`；legacy Intatis wire 保留旧显式行为。顶层 `model` 先精确匹配完整 configured model ID，未命中才按 `provider/model` 拆分。model options 只在内存和 Intatis-owned 配置/immutable catalog 中保留，不镜像进 UserDefaults。
- 2026-07-28 对照 OpenCode 1.18.8 后重做 OpenRouter strict-routing 修复：旧实现把 OpenCode 的“配置保真”误解为 raw JSON 直接进入 HTTP body，又用全局 reasoning alias 优先级修补；真实 OpenCode 是配置保真 → npm adapter selection → AI SDK option lowering。现在 `@ai-sdk/openai-compatible@2.0.41` 才把 `reasoningEffort` 生成 `reasoning_effort`，并保留 `provider.only` / `allow_fallbacks` / `require_parameters`；专用 `@openrouter/ai-sdk-provider@2.9.0` 保持自己的 nested reasoning 语义，不能套 compatible 规则。显式空/空白 npm 不再被修正为 default，unknown package 在网络前 fail closed。23:56 的第二次真实重发已由 EventLog 证明使用最新 profile revision 4 / connection revision 2，因此不是模型菜单或旧 binding 未刷新；该请求仍在 531 ms 后收到 strict-routing 404。继续对照 pinned package 的完整 wire shape 后确认，Intatis 还会依据 Skill 工具的 parallel-safe metadata 自动合成 `parallel_tool_calls: true`，而 DeepSeek V4 Pro 的当前 OpenRouter endpoint metadata 不声明该参数；`require_parameters: true` 因而会过滤全部 endpoint。新式 compatible/OpenRouter adapter 现同时省略 package 不发送的 `n`，且不再从工具 metadata 合成 `parallel_tool_calls`；显式配置并经 exact adapter lowering 的值仍可保留，legacy Intatis wire 保持原行为。回归覆盖截图 exact body、Skill-like parallel-safe tool、camel/snake/nested 的 pinned-compatible 实际冲突行为、model-level OpenRouter override、unknown/empty npm、OpenRouter null cache-control、runtime nested reasoning、deep merge、CLI selected variant、schema-v1 反向编码与 adapter-driven immutable revision；Provider **147/147**、完整 SwiftPM **1485 / 16 skipped / 0 failures**、Developer ID `IntatisMac` Debug build通过。未读取或改写用户配置，未使用真实 key；修复后二进制尚未由用户重新启动并做真实 OpenRouter 重发，因此最终网络 E2E 仍为 **UNKNOWN**。
- macOS 配置目录投影保留完整 model object 的未知字段，并通过 provider-agnostic `ModelConfigurationPresentation` 只读识别常见 reasoning/thinking 控制：`reasoning_effort`、`reasoningEffort`、`reasoning.effort`、`output_config/outputConfig.effort`、thinking level，以及 reasoning/thinking token budget。识别出的原始 effort 值或 token 数只作为模型弹出菜单内部的灰色辅助文字；composer 关闭态选择按钮只显示模型名，不显示 CPU/芯片图标、provider 或 variant/reasoning detail。解析器不改写配置、不转换字段。OpenCode-compatible `variants` 已作为同一真实 model 的命名请求参数预设摊平成独立菜单项：保留一个无 variant 的基础项，追加未被 `disabled: true` 禁用的各 variant；选择后实际 model ID 不变，variant 与 model options 按 plain-object recursive、array/scalar/null replacement 的 deep merge 组合。`intatis.providerSelection.v1` 只保存 provider/model/variant identity，不复制参数，也不改写 JSON/JSONC；未选择 variant 时仍不会从多个 variant 中猜活动值。原生菜单像素/色彩与真实 provider body 观察仍待运行态人工确认。
- Cowork 已落地同一 session 内的 per-agent inference profile 第一阶段：`InferenceCatalog`/`InferenceCatalogStore` 保存 versioned immutable connection/profile revisions，store reconcile 的旧值读取、revision allocation、校验与原子替换由进程内互斥和 Darwin/Linux 稳定 owner-only sidecar 跨进程独占锁共同串行化；agent 以 `AgentInferenceBinding` 精确固定 profile revision、connection revision、model/opaque variant、安全 route label/trust domain/egress classification 与 opaque definition digest，exact resolver 会逐项复核这些字段；macOS raw variant config key 只用于本地 presentation selector，不进入 durable binding/EventLog。Catalog current/default 只给未来 agent 使用，不会动态改写现有 agent。fresh `@main` 使用当前 exact default，`spawn_agent` 未指定 profile 时精确继承调用者 binding，显式 profile 只能从 host-approved 列表选择；host 可对 idle agent 做 durable rebind，queued/running invocation、reviewer 和普通 agent 自切换均拒绝。Cowork 底部菜单是独立的 per-submission composer 路径：忙时可暂存下一次 `@main` binding，菜单点击不改 live roster，Send 才冻结 exact binding，FIFO 到达该 submission 的执行边界后才 main-only rebind。Catalog candidate 更新与 admission/rebind 共用 admission lock；跨异步 resolver suspension 后还会重检 approved map、roster 与 authorization fingerprint，阻止旧解析结果越过 catalog/agent 变化。恢复或请求前若 exact revision 缺失、binding 不一致、wire 不支持或已声明的必需能力不兼容会 fail closed，绝不回退当前默认；`TaskContract` 冻结每次 invocation 的 binding。Phase A 后 GUI 不再把 exact-resolved `@main` 或 reviewer readiness 当作 composer/本地 Send gate：新提交先 durable accept，route 不可用时在同一 submission 上失败；恢复出的旧 root tasks 保持 paused。CLI 仍在 Goal recovery 后通过显式 data-plane resume 边界启动待处理任务。ordinary worker unresolved 不会冻结其他 agents。该 worker 的 queued invocation 会在 provider request 前 exact-resolution fail closed 并 durable 结算为 failed，清除 queued/active fence 后 host 才可显式 rebind。Non-empty CLI session 缺失 `@main` 时不再用 today default 自动补建，只能由 host `/agent restore-main <path> <profile-id>` 显式选择 workspace/profile 后再 `/auto`。GUI Project Settings/roster/rebind 与 CLI `/profiles`、`/profile`、`/agent profile|rebind|restore-main` 已接入安全投影；endpoint、credential、headers/query 和 arbitrary options 不进入 roster/EventLog。当前 resolver 仍只有 OpenAI-compatible wire，也尚未实现独立 route lease、跨 trust-domain 专用审批或完整 app model capability metadata；详细契约见 `docs/PER_AGENT_INFERENCE_PROFILES.md`。
- Per-agent inference 安全收口还包括：binding/permission metadata 新增安全 `trustDomain` / `egressClassification`，macOS connection/trust identity 使用 opaque hash 且 egress 标记为 `user-configured-external`。CLI 已从 Intatis-owned OpenCode-compatible 配置编译所有启用 route/model/variant，每个 connection revision 使用自己的 exact env/file/auth/config credential reference，不能拿当前 selected route 的 key 替代；旧 exact revision 继续保留。Modern CLI unqualified model 只有唯一 route match 时才切到该 route；显式 reasoning 必须匹配 configured variant 或 base options 中已声明的同一 effort，否则 fail closed，不生成 synthetic profile。Spawn/delegate 的 target inference fingerprint 同时绑定安全 route/trust 分类并在审批后/prepare 后复核。Cowork durable options 采用显式 allowlisted schema；未知 key/shape、secret/auth/header/query/URL/endpoint、runtime structural、`stream_options` 和多候选字段全部 fail closed，而 Chat/Code `ProviderEndpoint` options 仍是任意 JSON lossless。OpenAI-compatible Chat/Agent builder 无条件移除配置 `stream_options` 和候选数量参数；新式 package adapter 省略 `n` 和 runtime 自动 parallel 开关，legacy wire 才保留显式 `n = 1`。只有 host `includeUsage` 可重建受控 usage shape；host output-token ceiling 另会清除竞争 token aliases。Provider diagnostics 先脱敏，完整普通 HTTP(S) URL 也会作为 private-infrastructure material 替换为 `[REDACTED_URL]`；`RuntimeErrorPresentation` 在进入 durable EventLog/task-failure 前再次使用 diagnostic sanitizer 做 URL/secret-redact 和限长。所有 provider transport 使用 no-redirect session，HTTP 30x 作为原 endpoint 的失败处理，不会向未进入 exact binding/trust review 的 `Location` 发起请求。
- 历史 UserDefaults 中若残留 `providerConfig` 绝对路径，secret resolver 只接受当前 Intatis 自有候选或本次进程显式 `INTATIS_CONFIG` 指定的文件；其他旧路径 fail closed，不得借兼容元数据重新读取 `opencode.json` 或第三方配置。
- Chat session/history 已从固定默认日志改为按 `SessionID` 打开独立 `EventLog` 与 artifact store。macOS 与 iOS 共用 `IntatisCore.SessionHistoryStore` 扫描最近会话、拼接 `events.jsonl` 与 `artifacts/` 路径；平台层只传不同 application-support root 和 session 参数。macOS 根侧栏提供模式内 New session 与 Chat/Code/Cowork 历史列表，且 history row 原生右键菜单支持 Rename/Delete：显示名称先作为 settings 事件追加到 EventLog，再刷新派生 `session.json`，不改 `SessionID`、目录名或既有 JSONL；删除经二次确认，只清理目标 session 目录及其中 session-owned projection/bookmark/settings，不触碰绑定工作区，运行中当前 session 禁止删除。iOS 顶部 New 与抽屉 `Recent` 旁 `+` 提供新建，抽屉 Recent 提供历史恢复；启动时优先恢复最近 Chat session，只有无历史时才兜底到 `sess_default` / `sess_ios`。
- 2026-07-21 已把显式会话改名接入普通模型工具 `rename_session({"name":"..."})`。宿主在构造 runtime 时固定当前 `EventLog` 与 `SessionKind`，schema 不接受 session ID/kind，因此不能跨会话改名；Code 的单 agent 与 Cowork exact `@main` 可见，Cowork worker、spawn 出的 coordinator、其他普通 agent 和 `@permission-reviewer` 均不可见，Chat 仍无工具。该调用经过 ToolRegistry、结构化 intent、`PermissionEngine`、durable prepare/settle 与 `tool_result`；只有 exact current-session intent 获 deterministic low-risk allow，near-miss/locked 状态不获此豁免。名称在任何 authorization/prepared 记录前做 secret scan，raw 名称不写 `tool_call`；EventLog rename 记录 source 与 durable execution ID，exact executor retry 幂等且不会覆盖更晚改名。手工 UI 与模型工具共用 EventLog-first backend，macOS 另用 exact-session、revision/seq 有序的低频通知同步所有窗口侧栏。未引入上游源码/依赖或自动标题模型，`NOTICE.md` 不变。
- `/goal` 现有两种明确语义：Chat / Code 保留 v0.12 Goal 标签兼容路径，发送清洗文本并在 `user_message.tags/goal` 保存可选元数据；Cowork 的 `/goal <目标>` 已升级为 durable Goal 入口，由宿主创建 Goal/ContinuationRun 并驱动 scoped root AgentInvocation，不再只是 user-message 标签。mention parser 仍接受 `/goal @Agent ...` 与 `@Agent /goal ...` 作为请求上下文，但 durable Goal continuation 固定由 `@main` 主持，mentioned agent 不获得 Goal 终态 authority。macOS/CLI 普通 Cowork 输入还会在拼接附件前经过确定性 `ExplicitGoalIntentClassifier`：只有中英文同时明确“创建/设为”且说明“持续/长期/持久”的窄语句才把 `explicitGoalIntent` 交给 `create_goal`；复杂请求、普通 goal 提及、一次性目标与引用示例都保持 ordinary turn，分类器本身不创建 Goal。
- v0.13 已把 CLI/内核已有的 `turn_stats` token/耗时统计投影到 GUI：ChatLoop/AgentLoop 每轮结束继续写入既有事件；macOS Chat / Code / Cowork 与 iOS Chat 通过共享 `TurnStatsProjection` 和 `IntatisTurnStatsSummaryView` 显示最近一轮的 token、TTFT 与总耗时。`TurnStatsPayload` 以追加可选字段支持 cached input 与 context window tokens；OpenAI-compatible `prompt_tokens_details.cached_tokens` 会进入 `Usage.cachedPromptTokens`，GUI 可显示 cached input、non-cached input、output、total，缺字段时退化为既有 prompt/completion/total 或耗时显示。若 endpoint 不返回 usage，不新增事件 type 或平台分叉实现。Chat 与 Agent 共用 `Usage` 合并逻辑：同一次 provider 响应里的拆分 usage chunk 按字段合并，Agent 工具循环中多个模型请求再按请求累计，避免兼容 provider 的 split usage 丢字段或重复计数。
- macOS UI 信息架构在 2026-07-23 按最新视觉反馈再次修正：`IntatisMacRootView` 继续由 `NavigationSplitView` 提供系统 sidebar 材质，内部为 `Intatis` 标题、带 SF Symbol 的 `Chat / Code / Cowork` 三行竖向模式导航、当前 mode 的 `Recent` session history/New 与底部 Settings；只有当前模式行使用 interactive Liquid Glass。该结构取代同日较早的单一 `List(selection:)` 与横向 segmented control 两次修订。Chat/Code/Cowork thread header 均显示当前 session 的 durable display name（缺失时才回退 immutable `SessionID`），不再写死产品 mode 名。对话消息不新增 agent 头像，通用 `Agent` 展示名回退为 `Intatis`，agent 名称旁不追加通用 Agent badge；名称右侧继续显示首个消息事件的稳定本地化时间。composer 固定两排：第一排 model/profile 左、`Context / Input / Cached / Output / Time` usage 右；Chat/Code/Cowork 的选择菜单共用 40pt 高 interactive Liquid Glass 胶囊与原生 `Menu` 语义。第二排为当前产品面已有的附件或图像 action 左、原生多行输入居中、可选 Cowork stop 与 Send 右；附件/图像 action/stop/Send 的原生 glass/bordered 圆按钮均为 40×40，单行输入容器最小高度 40、同行间距 8，多行输入只向上增长且按钮保持底边对齐，Send 使用 prominent。侧栏 `Recent` 旁 New `+` 是原生小型圆形 glass control，fitting size 为 30×30。没有新增 Chat/Code 附件能力，字体 token 与用户字体体系未改。Cowork selector 忙时仍可选择且只冻结下一次 `@main` Send；共享 iOS composer 没有 top accessories 时不生成空行。Chat 默认无右 inspector；Code/Cowork 继续使用 SwiftUI 原生 `.inspector`。Swift parse、原生控件 fitting-size probe、`swift build --target IntatisSharedUI`、`IntatisSharedUITests` 50/50、`PerAgentInferenceProfileTests` 20/20、XcodeGen、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 均通过。遵守 renderer NO-GO，本轮未启动 App/fixture；当前实际像素、键盘/焦点和 Light/Dark 运行态仍为 `UNKNOWN`，2026-07-21 `design-qa.md` 截图只保留为旧布局历史证据。
- 2026-07-31 对话 chrome 进一步收口，并在 2026-08-01 完成 session metadata 精简：权限审查卡改为紧凑、左对齐的低对比系统 Material，semantic risk 只落在小图标/chip，结构化 scope 与 patch 默认折叠；通用详情不读取 raw arguments。automatic reviewer 仍不可人工操作，manual approve/decline/cancel identifiers 与语义不变，resolved notice 同步收窄。Chat/Code/Cowork 与共享 iOS Chat 的用户气泡不再重复 `You`，assistant/agent/system identity 与时间仍保留；macOS sidebar 品牌块只保留 `Intatis`。active Chat/Code/Cowork thread header 只显示 durable session display name，不再在标题下重复 model/provider/host、workspace/state 或 agent/running 计数；sidebar Recent row 同样只显示 session name，不再显示 event/date/path/runtime metadata，但 selection、New、Rename/Delete 和 busy delete gate 不变。`ThreadLayoutTests` 6/6、IntatisMac Developer ID Debug build 通过。独立离线 fixture、真实历史 Chat 与 Cowork Recent 已用 Computer Use 验证；本 UI slice 未发送 provider 请求，也未改变 PermissionEngine、EventLog、session projection 或执行语义。
- 2026-07-22 assistant/agent 名称旁时间 slice 的本轮验证为：Conversation/Code projection + MessageRendering + ExecutionTrace 组合过滤实际执行 161 tests / 0 failures；`swift build --disable-sandbox`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug unsigned build 均通过。没有启动 App 或 renderer fixture；时间文本的 Light/Dark、不同系统 locale/12–24 小时偏好与跨 24 小时/7 天长期停留视觉切换仍待运行态人工复核。
- Code/Cowork 的 verbose execution trace 现由 `IntatisExecutionTracePresentation` 在 SharedUI 展示边界控制。默认不把 `.toolCall`、`.toolResult`、`.patch`、`.note` 投入会话 SwiftUI 树，但保留 `.agentToAgent`，因此媒介化通用 agent message、`information_requested` 与 `information_replied` 会直接展示；`CodeProjection` 还按同一 agent 当前 `{TaskID, attempt}` 跟踪最后一个完整 `message_completed`，只有同一 AgentInvocation 的 `task_completed.result` 与该消息正文完全相同时，才把后者标为 presentation-only execution trace，避免同一回答以两个 `.agent` 气泡显示。缺少匹配消息、attempt 不一致、正文不同、跨任务同文或 retry 后仅有 task result 时仍保留 task result 作为兼容兜底；迟到的旧 attempt terminal 也只会结算自己的展示配对，不会清除新 attempt。user、真实 agent message、agent-to-agent communication 与 actionable error 正常显示。EventLog、`task_completed`、scheduler/WorkTask candidate 语义、Agent 上下文、权限卡片和 durable tool execution 均保持完整不变。后台可用启动参数 `-IntatisShowExecutionTrace` 或环境变量 `INTATIS_SHOW_EXECUTION_TRACE=1` 显式恢复原完整调试视图；没有 UI 设置、UserDefaults 持久值或运行中切换。本次可见性调整的 `ExecutionTracePresentationTests` + `IntatisConversationCodeTests` 合计 21/21 通过；未启动 App，真实 Cowork 对话卡视觉仍待运行态验证。
- UI 配色已按 2026-07-15 用户修正迁移到系统原生表面 + Liquid Glass：不再以 `.white` / `.black` 冒充系统外观。macOS detail 由 `IntatisSystemCanvas` 使用动态 `.windowBackground`（macOS 13 为 `NSVisualEffectView.Material.windowBackground` fallback），sidebar 交还 `NavigationSplitView`；SharedUI 使用系统 `.primary` / `.secondary`、separator 与 accent。2026-07-22 起，正常 assistant/agent 正文直接继承 conversation canvas，用户消息、失败回复与结构化内容卡片默认使用 `.regularMaterial`。composer、模型菜单、主要 CTA、action group 和紧凑 agent 交互等功能层在 macOS 26 / iOS 26 使用原生 `glassEffect` / `GlassEffectContainer` / glass button；2026-08-02 起，用户明确指定的 Cowork 紧凑 trailing status rail 是唯一内容层玻璃例外，权限、Agents、Goal、Tasks 统一使用原生 Liquid Glass，但页面和长 transcript 仍不整片玻璃化。iOS Chat 保持原生系统根背景。当前规则与验收边界见 `docs/CURRENT_UI_COLOR_SYSTEM.md`；`docs/UI_COLOR_SYSTEM.md` 原样保留上一版香槟金 / 暖色 / 玻璃方案的历史底稿。2026-07-15 的完整视觉迁移基线仍有效；后续 conversation/rail 改动由最新 Swift/macOS/iOS build 与 `design-qa.md` 覆盖。
- v0.13 API/tool 稳定性第一批改动进行中：OpenAI-compatible streaming/chat、tool-calling streaming、image generation、transcription 的非 2xx / provider error payload / malformed SSE / transport error 会通过共享 provider/runtime 错误格式化生成更明确的 `ErrorPayload` 或 provider error；这些路径在发起网络前还会通过共享 `ProviderEndpoint` URL 预校验确认 Chat endpoint 或 Base URL 是带 host 的 `http`/`https` URL，非 HTTP、缺 scheme 或缺 host 会归类为 `config` 错误并进入 health check 报告，不落到原始 URLSession 错误；HTTP 非 2xx 响应体只有含 `error`/`message`/`detail`/`error_description` 等结构化字段时才标为 `Provider said`，普通 HTML/纯文本代理错误页只显示裁剪 `Preview`；image/transcription 即使收到 HTTP 2xx，若响应体不是预期的 OpenAI-compatible `data[].b64_json` 或 `text` 结构，也会通过共享格式化变成带结构化 provider message 或裁剪 preview 的 `decoding` 错误，而不是底层 `DecodingError`；普通 HTML、缺字段 JSON、坏 base64 只显示裁剪 preview。tool-calling stream decoder 现在可接受缺失的单工具 `index`、字符串形式 `index`，以及 JSON object/array/number/bool 形式的 `function.arguments`，并归一到既有 `ToolCall`。Chat/tool-calling streaming 现在不再只读取 `choices.first`，会遍历同一 SSE chunk 的全部 choices；当首个 choice 为空而后续 choice 才带 content、tool_calls 或 `finish_reason` 时，仍能输出文本/工具调用并正确完成。Chat/tool-calling streaming 同时接受 SSE `[DONE]` 与 OpenAI-compatible chunk `finish_reason` 作为完成信号；若 `finish_reason` 后还有 usage chunk，会继续读取并只发一次 done，health check 不再把这类缺 `[DONE]` 的兼容 provider 误判为 partial stream；若底层流结束时既无 `[DONE]` 也无 `finish_reason`，provider 会抛出明确的 completion-marker 兼容错误，Chat/Code 投影保留 partial text 并标记 stopped；若同一 chunk 多个 choice 中后续 choice 以 `tool_calls` 结束，会优先保留工具调用完成语义；只要 provider 已发出 tool-call delta 但缺 tool name，即使最后给的是 `stop`，或旧式 `function_call` 没有可解析 `tool_calls`，都会抛出 provider tool-call stream 兼容错误，不再把空工具调用静默当成功。AgentLoop 工具执行会记录 `agent_status(tool)`、unknown tool 可列出可用工具、权限拒绝会带最终原因；在权限判断和工具执行前，已知工具的参数必须是 JSON object，并通过 schema 的 required 字段、基础类型、数字 `minimum`/`maximum` 约束、字符串 `minLength`/`maxLength` 约束和 `additionalProperties:false` 未知字段规则校验，`read_file.maxBytes` 当前要求 `>= 1`，标准工具的 path/query/command/diff 字符串当前要求非空，required 为空的无参工具可把空参数 / `null` 归一为 `{}`，坏 JSON、非对象、缺 required 字段、基础类型错误、数值越界、字符串过短/过长或未知字段会写入 `invalid tool input:` 的 `tool_result`，不生成 `permission_request`，也不执行工具；当前 shipped tools schemas 默认声明 `additionalProperties:false`。tool error/permission denied/unknown tool/invalid tool input 在 Code projection 与 CLI 中可标记为失败结果。`RuntimeErrorPresentation`、`ConversationProjection` 与 `CodeProjection` 现在会从 `ErrorPayload` 与失败 `tool_result` 派生 `RuntimeRecoveryAdvice`，GUI 在 Chat / Code / Cowork 错误卡片内显示是否应 retry、改 provider 配置、检查 endpoint/model、重新授权或修正工具输入；如果 `message_delta` / `agent_delta` 后紧跟 `error`，Chat / Code 投影会把当前未完成 assistant/agent 气泡标记为 response stopped，并保留已经输出的 partial text；不新增事件 type，也不解析 assistant transcript。新增共享 `ProviderRegistry.healthCheck(role:options:)` / `ProviderHealthReport`，macOS 与 iOS 设置页均可对当前 provider/model 发起 Test Provider/Health Check，并显示超时、partial stream、endpoint/model/wire/耗时/首 token/usage 与裁剪预览；chat 与 agent health check 均请求 `stream_options.include_usage`，并按共享 usage 规则合并返回值。新增 `ProviderRuntimePolicy`，对 chat streaming、tool-calling streaming、image generation、transcription 统一设置 request timeout 与 retry/backoff；流式请求只在尚未收到任何响应字节时重试，避免重复 partial text/tool calls。HTTP `Retry-After` 与常见 rate-limit reset header 可用数字秒、HTTP 日期或 `750ms` / `1m30s` 等 duration 字符串进入 retry delay 与用户可见错误说明，长 server delay 由 policy cap。真实 provider/key 矩阵、真实 provider mid-stream 行为矩阵和更多 provider-specific rate-limit 变体仍未完成；Cowork 任务 replay/requeue 已实现，真实长任务恢复仍待真机验证。
- 本轮进一步收紧 provider tool-call 参数边界：`OpenAIToolCalling` 在发出 `ToolCall` 前会确认非空累计 `function.arguments` 可解码为完整 JSON；截断或非法 JSON 会抛出 provider tool-call stream 兼容错误，空 arguments 保持允许以兼容无参工具。
- 本轮针对 macOS Chat/Code 截图中的 HTTP 401 provider 鉴权失败做了 GUI/诊断修正：Code 在进入 `AgentLoop` 后不再由外层 `CodeViewModel` 追加第二条 `agent` 错误；Chat 在 `ChatLoop` 已把 provider 错误写入 `EventLog` 时不再额外保留 composer 红字，避免同一次 provider 失败同时显示事件错误卡和底部临时错误。OpenAI-compatible provider 发送 `Authorization` 前会规范化 API key 字符串，避免用户把 `Bearer <key>` 或带外层引号的 key 保存到设置/配置后被拼成无效 token；当 macOS 读取到 Intatis-owned OpenCode-compatible config 中直接写入的 `options.apiKey` 时，会把该 provider 的 secret ref 标记为 `providerConfig` 并只从当前 config 文件读取，避免旧 auth JSON 里的同名 provider key 覆盖同一份配置；macOS/iOS 切换 provider/model 或保存设置触发 `ProviderRegistry` 刷新时会清空 resolver 旧 secret cache，降低外部修正 key 后继续使用旧值的概率。macOS Settings 的 Test Provider 会连续显示 Chat 与 Code(agent) 两个 health check 报告，并在 provider 列表、API key 输入区显示非 secret 的 key source 类型（含 `provider config`），便于确认 Intatis 实际解析的是 provider config、auth file、env、secret file 还是 legacy keychain。iOS 仍保持 chat-only health check。
- Cowork 默认自动权限审查已改为真正的控制面：brand-new GUI/CLI session 用本地 settings-first 七事件合同同时登记 fixed `@main` 与保留身份 `@permission-reviewer`，不产生模型 `agent.attach` 审批或 provider 请求；非空恢复先重建 durable settings/roster，异常缺失 `@main` 时由 GUI 走 host-authorized exact historical-main recovery，再 replacement/retry reviewer，CLI 则使用专用 `/agent restore-main`。fresh bootstrap 只接受空 EventLog、空 roster、固定 identities，继续执行 canonical/sensitive-root 检查、root identity lease 与原子 durable admission，不能被普通 attach/spawn/tool 复用。审查者固定 read_only、空 capability、不可作为普通 message/delegate/task 目标，也不运行嵌套 `AgentLoop`。`PermissionReviewControlPlane` 使用独立 FIFO/single-flight、64 项队列上限、submit 起算 deadline 与单次 timeout/cancellation；单次 deadline 默认为 120 秒。reviewer 模型请求默认不注入 `temperature`、output-token 或字符上限；只有显式 host policy 才启用对应输出控制，optional completion estimate 只用于 provider 未报告 usage 时的 soft accounting，绝不发送上游。只接受 `allow` / `deny`，兼容输入 `ask_user` / `ask` 会规范化为 deny；pre-submit caller cancel 直接返回 typed deny、不创建 review lifecycle；timeout、malformed/tool-call、provider/persistence failure 与已登记 review 在 terminal-claim 前被观察到的 cancel durable deny 当前调用，claim 后 cancel 保留唯一 settlement 但最终 authorization delivery deny，均不转 GUI 人工等待。provider failure 的 durable reason 会经过 `RuntimeErrorPresentation` 做 URL/secret 脱敏与限长，不再丢失全部上游诊断。累计 reviewer token 默认无 session-lifetime cap；`allow` 只有 `permission_review_settled` durable 成功后返回，orphan request 在恢复时补 deny/cancelled settlement。Phase B 后每个 provider dispatch 使用 `{reviewTaskID, nonce}` generation，provider/timeout 竞争该代首 terminal；caller cancel 另由同步 request token、actor path 与 settlement/delivery/admission 围栏共同处理。production 每代按冻结的 reviewer exact binding 重新 resolve provider wrapper。timeout/cancel 只影响当前 call；若已有 active generation 就只 retire 该代，旧 producer 的 late/duplicate output 没有 EventLog/health/authorization 能力，下一次 review 可立即使用 fresh generation，无需进程重启；旧 `provider_still_stopping` 仅保留协议兼容解码。GUI Cancel task 只取消数据面任务；session stop/CLI 结束仍关闭 reviewer。Phase A 后 reviewer 未就绪不再锁定 composer；普通主请求继续，只有真实 ask-class tool 由 unavailable responder fail closed。2026-07-22 起 Cowork 对话页不常驻 reviewer 状态横幅，异常 workspace reauthorization / automatic-review retry 入口移至 Project Settings 的 Recovery 区；真实 pending `PermissionCard` 与 FIFO 不变。CLI `/auto` 重启 reviewer，只有用户明确 `/default` 才进入终端人工模式。`DeterministicPolicyGate` hard deny 仍是不可被模型放宽的终局。
- 2026-07-16 自动权限审查源码审计整改已本地落地：`ToolRegistry` 的同一 registration 现在同时提供 model schema、concrete tool identity、canonical permission、CapabilityLease membership、语义预览与 executor，`write_file` / `apply_patch` 统一为 `filesystem.edit`。`AgentLoop` 在送审前签发不可变 `ResolvedToolAuthorization`，绑定 registry/spec/tool、task/tool-call、lease fingerprint、参数 digest/count、intent、replay policy 与 deterministic gate；同一 authorization 贯穿 permission review requested/settled、permission resolved、tool execution prepared/settled，并在 review 后及 executor 前复核，live automatic review 缺失或漂移时在 provider/executor 前 fail closed。Cowork 自动审查 payload/prompt 不再持久化 raw args，只传 digest/count 与有界、秘密脱敏、decode 时再次清洗的 `PermissionActionPreview`；既有 `tool_call` 事件仍保留原协议参数，Code 人工权限模式也保持兼容。review verdict 必须带非空有界 reason，risk 只能维持或提高 gate risk；deny/failure 的 typed source/status/failure kind/reason 保真到 settled/resolved/tool result。`delegate_task(to:auto)` / 省略 `to` 会在 review 前只读解析精确 agent、workspace、model、access 与是否拟新建 worker，预检不改 roster；allow 后按 target fingerprint/lease/availability 复核且禁止重新选人或 fallback，deny 不创建 worker。`SideEffectEvidenceLedger` 会从 permission/review/resolved/prepared/settled 事件跨重启恢复同一 task 的副作用证据，覆盖 review-settled→resolved 与 resolved→prepared 崩溃窗口；必要副作用没有 durable succeeded settlement 时，模型终答不能把 invocation 宣告完成。`ask_agent` admission/Mediator failure 以 typed failure 抛出，不得写 succeeded settlement；reply delivery 的 typed outcome 先于 scheduler terminal record 发布，late waiter 不能把尚在 Mediator 审核或已被拦截的答案误判为 success。attach request 三联事件及其 allow/deny 关联事件通过单个 admission batch 提交；多事件 batch 先同步 `.wal` recovery journal，再同步 JSONL，初始化/下次 append 会回滚匹配的 partial batch、保留完整 batch，并对损坏或不匹配 journal fail closed。fresh bootstrap 使用 `isEmptyChecked`，权限 reviewer reconcile/process 与 Cowork AgentLoop 副作用证据恢复使用 `replayChecked`；Cowork restore 以及后来需要 absence/order proof 的 Goal/retry 路径已进一步使用 `replayForProjectionChecked()` + `hasCompleteKnownHistory`。锁/读取/已知事件损坏不会再被当作空日志，合法未知未来事件仍占用 `seq` 且会阻止 fresh bootstrap；需要完整投影证明的路径还会因 unknown future type 或 seq gap fail closed。此次未复制上游源码、未引入依赖，仍保持每次写入都审查。
- Code/Cowork 现在共用 Swift-native headless `AgentRuntime`：CodeViewModel 使用 `.code`，Orchestrator 每个 agent 使用 `.cowork`，统一 registry、PermissionEngine、completion、durable tool ticket、timeout/cancel 和单次 provider 参数。`RuntimeEnvironmentManifest` 稳定进入每次请求的首个 system message，声明 Intatis 模式、外部动作只能走 API tools、tools 列表权威、严格 JSON Schema 与 ToolResult 完成语义；动态 agent/workspace/task/lease/event 继续放在有界 user-role untrusted context。request snapshot 已覆盖 Code main、Cowork main/coordinator、worker 与 permission reviewer 的不同工具面。
- 2026-08-02 完成了 model-facing 工具选择合同的第 1–2 点：共享 `RuntimeEnvironmentManifest` 要求模型选择能完成任务的最窄工具、先读取/检查后变更/转换、区分“阅读内容”与“创建新产物”；可选 backend 默认省略或使用 tool 公告的 `auto/default`，`ToolResult` 中的 hint 只是非权威建议，失败后不得盲目重试。文档工具说明同步分工：可抽取文本层的 PDF 用 `read_pdf`，扫描/纯图像 PDF 的阅读与总结用 `read_document` 且 backend 默认 `auto`，只有用户明确要求把照片/扫描图像转换成新的可编辑文件时才用 `reconstruct_document_image`。旧 `read_pdf` 无文本提示已不再诱导模型把 PDF 传给图像重建工具。
- 上述范围只是系统提示词、tool descriptor 和失败 hint 合同；尚未实现宿主端确定性意图路由、跨工具/真实 backend 兼容性路由、输出临时分期/原子提交、或新的通用 typed no-effect/副作用证据链。因此它能降低模型选错工具的概率，但不能把第 3–5 点宣称为已闭合；除下文记录的 `read_document` 局部 no-effect preflight 外，现有 `manual_reconciliation` 与 durable execution 语义未改。
- Cowork durable work model 已从一个模糊 task 层拆成四层：`Goal`（用户目标，可跨 run）、`WorkTask`（用户可见计划 DAG）、`ContinuationRun`（宿主一次推进/checkpoint/recovery）以及现有 `TaskContract` / `TaskGraph` / scheduler（AgentInvocation execution layer）。`GoalID` / `WorkTaskID` / `ContinuationRunID` 使用稳定前缀；协议加入 append-only Goal/WorkTask/run 事件，`CoworkProjection` 可重放恢复。AgentInvocation completed 只形成 WorkTask candidate/linkage；WorkTask completed 必须显式 `task_update` 提交 result，并在有 acceptance criteria 时提交 evidence；Goal completed 只接受非空、无 remaining work/blocker、每项 proven 且带 evidence，并完整覆盖 objective、每条 success criterion 与每条 constraint（包括重复项）的独立 verifier audit。
- `WorkTaskGraph` 现校验 missing/self/cross-run/cyclic dependency、readiness、stale revision、状态迁移与完成证据；依赖重规划在同一 durable batch 中从 host graph 重新计算被编辑节点及其下游 readiness，投影只接受 DAG 一致的 pending/blocked/ready 迁移。执行进入 `in_progress` 后 title/description/criteria/expected artifacts/priority/dependencies 等执行契约不可再改。`task_update` 是 PATCH：调用方应只发送实际变化字段；为兼容模型返回完整快照，生产 Orchestrator 会在权限/冻结合同检查前把与 authoritative WorkTask 完全相同的合同字段归一为 no-op，但任何真实 owner/title/description/criteria/artifact/dependency/priority 变化仍 fail closed。Cowork coordinator 通过 strict `task_create/update/get/list` 管理当前 run/Goal 范围；worker 默认 lease 只有 `read_work_tasks` / `update_owned_work_task` / `read_goal`，只能更新自己当前绑定且拥有的 WorkTask，不能改 DAG/owner/priority/retry/cancel。`delegate_task` 可携带 WorkTask/run/Goal scope 并追加 invocation linkage；省略 `to` 的并发 auto delegation 会在 actor reentrancy 前原子预留不同 idle worker，防止两项独立工作误落到同一 agent 串行。未显式传 WorkTask 的 legacy delegation 与由 causal mailbox 触发的 wake invocation 也继承父任务 Goal/run scope，不把 child Task Report 自动当作 WorkTask 完成。write-capable invocation 还会按同 workspace active WorkTask 的 `expectedArtifacts` 拒绝父/子路径重叠；空/unsafe/unknown write set 保守视为 workspace-wide。进入新 run 前，host 会在一个 admission batch 中取消旧 run 的非终态 WorkTask、克隆到当前 running run 并重映射内部依赖；source/target session、Goal、run 状态与外部依赖关系不一致时 fail closed。
- Goal 生命周期的生产变更统一由 Orchestrator host authority 管理；模型 create 需要明确用户意图，普通 agent 无最终 Goal verdict 权限。`GoalRuntimeController` 对 start、ordinary turn、create/edit/pause/resume/clear、stop/shutdown 使用 single-flight/mutation/stop gates；pending durable stop 必须先重试成功，新 Goal/run 才能启动。start 被取消时若 continuation 已创建，会先 scoped cancel、等待执行退出并 durable checkpoint，再向调用者返回 false；shutdown 后拒绝新的 ordinary turn，失败尾部与 stale watcher event 也必须按最新 durable revision/status 复核，不能复活或误停新 run。每轮 scoped root invocation 之后，host 只等待同一 Goal/run 的 queued、claimed 与 running execution，并以精确 Goal/run cancellation tombstone + admission barrier 循环取消；root admission 在创建前、durable queue 后与 provider dispatch 前都重新检查取消，半 admission task 会先 durable cancelled，取消落盘失败的任务进入 scheduler/idle barrier quarantine，避免无关 Cowork 工作阻塞 verifier 或 Pause 竞态漏跑 provider。Pause/Edit/Clear 必须先成功取消当前 run 并 durable checkpoint，任一步失败都不提交控制面变更；编辑成功会清除旧 audit、blocker fingerprint 与 progress streak，防止旧目标证明污染新 revision。run 必须先 durable checkpoint，且每个 run 最多接受一次 audit；生产结算用单个 admission batch 依次追加 `goal_audit_completed`、`continuation_run_completed` 和可选 Goal terminal event，持久化失败不会留下半完成终态。Orchestrator restore 持有独立 startup scheduler suspension。GUI 完成 session/Goal 对账后调用 `startNewTasksKeepingRestoredTasksPaused()`：允许 Phase A 之后的新提交调度，但恢复出的 root tasks 继续 paused/interrupted，直至精确 Retry；GUI 的 composer 与本地 admission 不等待 `@main`/reviewer ready。CLI 保留独立的显式 `/auto|/default` 与 `resumePendingTasks()` 边界。Phase L 后 `GoalRuntimeController.start()` 只做 replay/recovery/checkpoint/audit 对账；历史 active Goal 会 durable pause（已达到预算则 budget-limited），不创建新 continuation、不调用 provider，只有用户显式 Resume 才能继续。
- `GoalVerifierControlPlane` 与 `@permission-reviewer` 完全分离，使用独立 no-tools provider 请求，不写 EventLog。WorkTask 的 result/evidence 明确是 agent-reported，不能直接证明 Goal；host 只把同一 Goal 下 durable、成功 `tool_execution_settled` 且命中 validation-tool allowlist 的结果派生为 `validationEvidence`，并要求 verifier 返回的 requirement/evidence 精确引用这些 host-bound 证据。malformed、tool-call、缺完成标记、timeout/cancel 与普通 provider failure 均 fail safe 为 continue。普通 429/rate-limit 仍按 retry policy 处理；只有结构化 `ProviderUsageLimitError` 会在 scoped `task_failed.failureCode = provider_usage_limit` 成功持久化后发布内存 hard-limit signal，并在 restore 后按 Goal/run contract 为 current non-completed Goal（包括 paused）保留，直到原子 run settlement 成功才消费为 `usageLimited`，不从自由文本猜测。`length` / `max_tokens` 仍是单次 output-limit 失败，不等同账户 usage limit；Goal 自身显式 token budget 达到后则是独立 `budgetLimited`。blocked 需要同一 blocker 跨配置阈值连续出现，单轮 `blocked_candidate` 不足以终止。
- Cowork project-mode slice 已按 Main-led 模式本地落地：macOS 新建 Cowork session 时先选择用户授权工作目录；canonical `CoworkSessionSettings` 以 EventLog 全快照保存主 agent、未来-agent exact inference default、默认 permission profile、可选 token budget 与 secret-free workspace metadata，旧 `CoworkProjectSettings` UserDefaults key 只作迁移输入，bookmark bytes 只在 session-owned `workspace-access.plist`。fresh session 以 settings-first 七事件同时 durable 登记 fixed `@main` 与 read-only/no-tools reviewer，不重复模型审批或调用 provider；历史缺 main/reviewer 使用专用 host-authorized exact recovery，后续 workspace/agent 扩展仍走普通权限流。GUI 在 bootstrap 前先注册 EventLog stream，首个实际 `@main` durable projection 触发侧栏 history 重扫；Phase A 后 composer 始终可编辑，main/reviewer/Goal/permission/working 状态只影响提交后的 FIFO 执行或状态展示，不再成为输入 gate。`CoworkSessionView` 的启动 task 以 session ID 为 identity。用户 composer 默认把无 @mention 的普通指令冻结为发给 `@main` 的 durable submitted intent，并同时冻结点击 Send 时暂存的 next-main exact binding；`@main` 持有 coordinator capability lease，可读写主 workspace、调用 `spawn_agent` / `delegate_task` / `remove_agent` 等工具自动组织子 agent。Project Settings sheet 继续支持 workspace/settings/rebind，并在异常时承接 workspace reauthorization / automatic-review retry；当前工具执行仍以 agent 的单 `workspaceRoot` 为真实文件访问根，多目录 direct multi-root tool context 仍是后续工作。
- v0.16 Cowork agent 生命周期补强已本地落地：`spawn_agent` 记录 `requestedBy` ownership，并在外层 ToolCall 审批后用一个 durable admission batch 提交 roster/leases/attached/spawned，内部不再递归普通 `attach` 或触发第二次权限审批；`delegate_task.to` 可省略，优先复用同 workspace idle worker，不存在时原子创建 `worker-N`，再等待 scheduler 驱动的子 agent 完成并返回稳定 `task_id`、`agent_id` 与结构化 `TaskReportPayload`。tool-spawned、任务域内的子 agent 在无 pending/running/issued task 且 mailbox 无待处理消息后自动 detach 回收；`ask_agent` 保持直接答案兼容，用户/GUI 手动 attach 的 agent 不参与自动回收。exact repeated denied tool call 只进入 reviewer 一次，随后快速拒绝并在第三次相同尝试以 `repeated_denied_tool_call` 终止本轮。fake-provider/XCTest 闭环与 macOS GUI bootstrap 已验证；真实外部 provider 的完整多工具 E2E 仍 UNKNOWN。
- Cowork 多 agent 编排可靠性与权限执行硬伤已闭合：每条用户指令仍先进入真实 root `TaskContract`，scheduler 保持 same-agent single-flight 与跨 agent 有界并行。权限 request/resolution、tool intent、`tool_execution_prepared`、tool result 与 `tool_execution_settled` 都采用 durable-first；任何副作用前的关键审计写入失败都不会调用 executor。崩溃恢复只自动重放普通 read-only 工具；write/exec/network/destructive 以及消息、委派、spawn/remove 等协作副作用若留下未 settled execution ticket，原 running task 会以明确的 `manual reconciliation required` 失败，不再盲目整任务重放；即使 non-replayable ticket 已 settled success，整 task retry 也会拒绝重复该副作用。普通 running task 才能在新 attempt 的 queue 事件成功持久化后重排。detach、默认 lease revoke 与 task lease revoke 均先持久化完整 batch 再改内存，renew history 只包含已成功落盘的 revoke。EventLog 每次 append/batch 使用跨进程文件锁并在锁内重读尾 seq；生产 `Orchestrator.runtime` 必须先取得长期 session writer lease，第二个 GUI/CLI runtime 无法调度同一 session。WorkspaceLease 固定 canonical root 的 device/inode identity；attach commit、每次 AgentLoop 工具权限前、permission await 后、durable prepare 后紧邻 executor、task lease 派生/retry 与 managed process 启动都会重新核验，目录被 rename/replace 或旧 JSONL lease 缺 identity 时 fail closed。通用文件工具拒绝读写 `.git/config` 与 `config.worktree`，结构化 Git 服务再做独立配置审计。provider timeout 改为不等待迟到任务的 bounded race。P0 raw `run_shell` 已从 production Code/Cowork registry 移除；协议级 `.runShell` capability 仅映射到受管 `exec_command` / `write_stdin` 以及兼容的 read-only Git inspection，不再映射裸 shell 工具。底层 runner 仍使用 OS sandbox、默认断网、最小环境、进程树 TERM→KILL 与有界 stdout/stderr，作为测试与未来签名 helper/XPC 的防御实现，结构化 Git/browser/document backend 不受影响。共享 session token budget 使用 session-lifetime meter，在 provider dispatch 前预留 input+output slice，并向 OpenAI-compatible 请求传 `max_tokens`；配置开关不丢失 outstanding reservation，因 provider tokenizer/usage/ceiling 支持差异，UI 与文档明确称其为 soft token budget。真实 provider、Linux bwrap、长期运行与真机矩阵仍需设备验证。
- `task_update` 的 preflight 拒绝现已与“执行结果未知”分开：只有生产 `OrchestratorWorkTaskManager` 会让 Orchestrator 在 acquire admission 后、首个 WorkTask EventLog append 前的明确边界把权限、冻结合同、参数、状态或 graph validation 拒绝签发为 typed no-effect；任意其他 `WorkTaskManager` 的同名错误不能自行获得该证明。EventLog append 及其后的错误（包括已提交但 acknowledgement 丢失）位于证明边界之外，继续保持 unknown/manual reconciliation。AgentLoop 原子追加 model-visible `tool_result` 与 `tool_execution_settled(outcome=failed,effectDisposition=not_started)`，同一 Agent turn 可先 `task_get` 再决定是否重试；新产生的成功 settlement 一律显式写 `effectDisposition=committed`。工具整体仍保持 `requires_manual_reconciliation`，普通 timeout、executor 内 cancel、网络/进程/协作写入异常继续保守。Projection 把一个 execution ID 绑定到首个 prepare：第二个 prepare 即使 payload 相同也永久标为 ambiguous，冲突 terminal 同样保留首记录并永久 ambiguous（完全相同的重复 terminal 仍幂等）；只有无 ambiguity、顺序正确且完整 prepare payload 匹配的 settlement 才有效，`succeeded + not_started` 是无效矛盾并进入 uncertain。显式 unknown、legacy failed/cancelled/denied nil 和无有效 settlement 都进入 uncertain；legacy nil+succeeded 只为兼容识别成“效果已完成”，但与显式 committed/unknown 一样仍阻止整 task 重放。Orchestrator restore 先以 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 取得完整已知历史；无 current Goal 的旧日志修复仍接受 prepare 前 durable revision 严格大于 expected 的 stale proof，并新增一条 exact durable-argument proof：唯一未脱敏 `tool_call` 的 SHA-256 必须同时匹配 prepared authorization，TaskContract、agent、capability lease、run 与 WorkTask snapshot 必须精确绑定，且旧 worker snapshot-field guard 或旧 in-progress frozen-contract guard 必然在 append 前拒绝。修复不解析错误字符串、不借用重复 call/prepare ID、不从 prepare 后 latest state 倒推；redacted/missing/mismatched args、租约或绑定继续 fail closed。存在任何 current Goal 时不自动修旧 ticket，避免绕过显式 reconciliation/Resume 生命周期。Goal startup 与进程内 continuation launch、whole-task retry 也使用同一 complete-known-history gate；unknown future event type 或 seq gap 不能支撑 absence/order proof，必须 fail closed。无 Goal 的 task-local 放行仍须证明 exact TaskContract 在 prepare 前存在、正 attempt 与同 attempt terminal event 在 prepare 后发生；orphan、attempt mismatch、corrupt/incomplete history、unscoped/missing/nonterminal 与任何 current Goal 的 uncertain ticket 均 fail closed。
- MessageBus/mailbox 已接入实际调度：结构化 `agent_message` / information request/reply 先经 Mediator 持久化，再进入 recipient mailbox；恢复时未消费消息会合成 mailbox wake task。每轮只投影并确认实际呈现的最多 8 条消息，剩余消息继续触发下一轮，不再一次性清空；delivery provider 失败会在同一 task ID 上按 `maxAttempts` 有界重试，消费事件写入失败时消息仍保持 pending 并可至少一次重投。Goal/run scoped cancel 会在 communication admission lock 内阻止迟到发送；若非协作 sender 已把消息 durable 写入，则追加专用 `agent_message_discarded` 后才从 mailbox ack，不能伪造 `agent_message_consumed`，旧 run 消息因此不会在 restore 后复活或挡住新 run。task-scoped capability/workspace lease 会按 task ID、工具/通信/委派授权、workspace root、read-only、allow/deny path 规则执行并在终态撤销；retry 从 lease audit history 克隆原权限，缺失历史时 fail closed，不回退到 agent 默认 coordinator 权限。restore 只恢复仍在 roster 内 agent 的默认 lease 和 active task lease，不恢复半完成 admission 遗留的 orphan lease。
- Cowork task context 现在按预算选择最近且相关的 global brief、lineage、task-group metadata、direct message 与 agent-local event；无关 sibling 只暴露状态 metadata。`artifact_added` 当前没有 task/recipient/visibility 等显式分享元数据，因此 `ContextProjector` 对 `explicitlySharedArtifacts` fail closed，不再把全会话 artifact ID 注入 worker。所有事件、任务字段与 agent 消息都作为带边界转义和长度限制的 user-role untrusted data 注入；Cowork system prompt 不再拼接动态 agent name/workspace path，Orchestrator 的 attach/spawn 边界只接受不超过 64 字符的安全 ASCII agent 名。EventLog 恢复序号时会从合法 envelope header 读取未知未来 event 已占用的 `seq`，避免旧版本续写复用。已消费消息不再重复投影。
- 本轮修复 Cowork 委派反馈闭环：`ask_agent` 与 `delegate_task` 的工具路径不再只返回 queued ack，而是通过既有 scheduler 执行目标 agent，目标完成后经 `MessageBus.deliver` / `Mediator` 转发结果，并把转发后的内容作为 tool observation 回填给上级 agent 的下一轮模型请求。这样主 agent 可在同一个工具循环中看到子 agent 交付物并综合回复用户；若 Mediator 阻断结果，则上级 agent 收到明确阻断提示。该实现仍不让 `AgentLoop` 直接同步递归调用另一个 `AgentLoop`，worker 默认工具面仍由 `CapabilityLease.worker` 限制。已用 fake provider 覆盖 worker 调用 `list_files` 后将观察结果汇报给 main 的路径；真实 GUI/provider E2E 仍为 UNKNOWN。
- v0.16 Agent 文档/媒体工具 slice 已本地落地：`ToolRegistry.standard()` 包含 `read_pdf`、`read_document`、`edit_pdf_pages`、`reconstruct_document_image`、`compile_latex`、`generate_image`。`read_document` 把 workspace 内 DOC/DOCX、PPT/PPTX、XLS/XLSX、OpenDocument、RTF、CSV、HTML、Markdown、text、EPUB 与 PDF 交给本地 Docling 或 MarkItDown，统一返回有界 Markdown；legacy DOC/PPT/XLS 还要求 LibreOffice。它只接受 path/backend/output bound，不接受 shell、URL、remote service 或 plugin 参数，使用默认断网的 structured runner、512 MiB 输入上限、500,000 字符输出上限、timeout/cancel/process-tree cleanup，并只从系统受信路径或用户显式建立的 `~/Library/Application Support/Intatis/document-runtime` 读取 parser runtime。PDF 阅读和页面级抽取/拆分在 macOS 上通过系统 PDFKit 实现；扫描件/照片重建 wrapper 支持 `docling`、`marker_single`、`tesseract`；LaTeX wrapper 支持 `tectonic`、`latexmk`、`xelatex`、`pdflatex`；生图通过 `ImageGenerationToolService` 桥接 provider。所有工具仍经 schema、`PermissionEngine`、`PathConfinement`、WorkspaceLease 与 durable `tool_result`；`read_document` 属于 exec capability，只进入 read-write worker/coordinator（含 exact `@main`）lease，read-only worker 仍只有 `read_pdf`。仓库未引入或打包这些 Python/CLI 项目，`NOTICE.md` 不变。
- 2026-08-02 对 `read_document` 做了局部热修，未扩展为通用路由/分页工程：输入上限从 250 MiB 调整为 512 MiB，可覆盖已复现的 329,384,679-byte（约 314.1 MiB）扫描 PDF。path confinement、文件可用性/普通文件、尺寸、extension 与 backend 值校验都发生在本地 parser 进程启动前，并改用既有 `ToolExecutionRejectedWithoutSideEffect`。因此这些 preflight 失败会 durable 结算为 `effectDisposition=not_started`，不再误报 `manual_reconciliation`；parser 真正启动后的 timeout/进程失败仍保留现有保守语义。
- 2026-08-02 起，Cowork exact `@main` 的 fresh/default/task lease 包含 `submit_goal_verdict`，因此模型工具面会出现 `update_goal`；普通 worker、spawn coordinator、task-scoped non-main 与 `@permission-reviewer` 均显式移除该 capability。恢复旧 session 时不原地改历史 lease，而是 durable revoke/replace 当前 default（被历史 task 引用的旧 lease保持冻结）。该入口只能提交 `complete` / `blocked` 与 expected revision：`complete` 仍要求独立 GoalVerifier 产生并由 host 绑定 validation evidence 的完整 audit，`blocked` 仍要求同一 verified blocker 连续至少三轮；`@main` 不能用它创建 audit、pause/resume/edit/clear 或改预算。
- v0.16 前的开源调研结论：PDF 页面变换优先参考 qpdf/Poppler 类工具，OCR/searchable PDF 参考 OCRmyPDF + Tesseract，PDF/图片到 Markdown/HTML/JSON 的版面识别优先参考 Docling、Marker、PaddleOCR，LaTeX 编译优先参考 Tectonic，专用生图后端可对接 ComfyUI 或 Hugging Face Diffusers；当前实现选择“内置轻量 wrapper + 复用已安装成熟后端”，避免复制外部项目源码或引入新依赖。
- v0.16 Agent 网络/浏览器工具 slice 已本地落地：`ToolRegistry.standard()` 新增 `web_fetch`、`browser_diagnostics`、`browser_profiles`、`browser_profile_delete`、`browser_history`、`browser_navigate`、`browser_snapshot`、`browser_handoff`、`browser_reload`、`browser_back`、`browser_forward`、`browser_click`、`browser_type`、`browser_submit`、`browser_select_option`、`browser_press_key`、`browser_scroll`、`browser_wait`、`browser_screenshot`、`browser_upload_file`、`browser_download`、`browser_downloads`、`browser_search`。`web_fetch` 走 URLSession 做轻量 HTTP(S) 获取；浏览器工具不内嵌 Chromium 源码，而是通过已安装 Node.js 优先调用 Playwright 驱动 Chromium/Chrome/Microsoft Edge persistent context，Playwright 缺失时 fallback 到 Node.js 内置 `WebSocket` + Chrome DevTools Protocol 驱动已安装 Chrome/Edge/Chromium。Playwright wrapper 与 CDP fallback 都有命令级 watchdog；CDP fallback 还对 CDP send、`Browser.close` 和浏览器子进程退出设置有界等待/强制终止，避免真实浏览器流程卡死。工具支持 `channel` 选择 `chromium` / `chrome*` / `msedge*`，支持 profile 名称、headless/headed、运行时诊断、profile metadata 查询、历史 metadata 查询、导航、搜索、页面快照、headed 用户接管/登录、刷新、前进/后退、点击、输入、提交表单、下拉选择、按键/快捷键、滚动、动态等待、新 tab/window 跟随、PNG 截图、workspace 文件上传、显式下载和下载 metadata 查询；页面快照和动作结果会返回按钮、输入框、下拉框等交互控件的 role/name/selector/options 摘要，帮助下一步定位；打开新页面的 click/type-submit/select/submit/press 会跟随最终页面并回写 state/history，CDP fallback 的 click/download 使用真实鼠标事件而不是只用 DOM `click()`。登录态/cookies/localStorage/浏览器 profile 保存在工作区 `.intatis/browser/profiles/<profile>`，当前页面 metadata 与 Intatis 管理的 `navigationStack` / `navigationIndex` 保存在 `.intatis/browser/state/<profile>.json`，非 secret 历史 metadata 保存在 `.intatis/browser/history.jsonl`，下载产物保存在 `.intatis/browser/downloads/<profile>`；同一进程内同一 workspace profile 的 Playwright/CDP-backed 浏览器命令按 profile 路径串行化，避免多个 agent 同时写同一 persistent profile、state/history 或导航栈，不同 profile 仍可并行。`browser_back` / `browser_forward` 的 state/history 读与真实浏览器执行处于同一 profile 临界区。这些 profile 可能含登录态，不能打印、摘要、提交或当作普通 artifact 分享；交互摘要不得打印 cookies/localStorage/profile 数据库、密码/token 或当前文本输入框 value；`browser_handoff` 只打开有界 headed 窗口供用户手动登录/接管，返回时回写页面快照和 state/history；`browser_profiles` 只读 profile 名称、当前 URL/title、state/history/download 计数和目录统计，不列 profile 内部文件名且不读取 cookie/localStorage/profile 数据库；`browser_history` 只读受控 metadata，不读取 cookie/localStorage/profile 数据库；`browser_back` / `browser_forward` 只读取 state/history metadata 选择目标 URL，再用真实 profile 打开页面；`browser_downloads` 只列下载文件 metadata，不读取文件内容；`browser_submit` 通过当前表单或目标 form/control/submitter 执行页面表单提交，仍是 exec+network browser action；`browser_type` 会在工具 observation 中遮蔽本次输入值，并在 Swift 工具入口与 Playwright/CDP 后端 DOM 执行前拒绝疑似密码、2FA、token 或 API key 输入目标，要求改用 `browser_handoff` 让用户接管登录/验证。所有浏览器工具仍经过 AgentLoop schema 校验、PermissionEngine、PathConfinement；shell-backed browser 工具同时标记 network risk，并修正 `DeterministicPolicyGate` 让 exec 工具先检查 shell-disabled/read_only 边界，再进入网络审批，避免无 shell 能力的 host 被网络标记误放行。Cowork coordinator lease 可用网络/浏览器工具，worker 默认不获得 `browse_web`。
- 本轮追加 `browser_profile_delete` 和 `browser_submit`，作为普通 Agent 工具进入 `ToolRegistry.standard()` 和 Cowork coordinator `browse_web` lease；`browser_profile_delete` 是 `.destructive` 工具，要求 `confirmProfile` 与目标 `profile` 匹配，只删除 workspace `.intatis/browser/profiles/<profile>`、`downloads/<profile>`、`state/<profile>.json` 并剪除对应 `history.jsonl` metadata 行；`browser_submit` 是 exec+network 表单提交工具，可提交当前表单或按 selector/text/role/name 定位 form/control/submitter 后提交。worker 默认仍看不到任何 `browser_*`，read_only 下由权限门 hard deny；工具 observation 不读取或输出 cookie/localStorage/profile 数据库、下载内容或内部文件名。
- v0.16 网络/浏览器调研结论：Chromium 是成熟开源浏览器项目；Playwright 已明确支持 Chromium/Firefox/WebKit、AI agent/MCP/CLI 场景，以及 Chrome/Edge channel；Chrome DevTools Protocol 是 Chromium/Chrome/Blink 浏览器的底层工具协议；Selenium 是更通用的 W3C WebDriver 生态；Browser Use 证明 Playwright 可作为 AI agent 浏览自动化层；CEF 是后续若要把 Chromium 真正嵌入 macOS app 的候选。当前实现选择 Playwright wrapper + CDP fallback，是为了先得到真实 Chromium/Chrome/Edge 内核和持久 profile 能力，同时避免 vendoring Chromium/CEF。
- 本轮按 Codex Git/Cloud 模型继续扩展 Git control：`ToolRegistry.standard()` 现在包含 `git_status`、`git_diff`、`git_diff_staged`、`git_info`、`git_recent_commits`、`git_diff_base`、`git_branch`、`git_create_branch`、`git_stage`、`git_unstage`、`git_commit`、`git_apply_patch_check`、`git_apply_patch`、`git_stage_patch`、`git_unstage_patch`、`git_revert_patch`、`git_worktree_list`、`git_worktree_create`、`git_worktree_remove`、`git_remotes`、`git_fetch`、`git_pull_ff`、`git_push`、`git_switch`。实现仍不引入第三方依赖，`ProcessGitService` 通过参数数组调用 `git`，内部命令设置 `GIT_TERMINAL_PROMPT=0`、`GIT_OPTIONAL_LOCKS=0`、`core.hooksPath=/dev/null` 与 `core.fsmonitor=false`；本地 metadata/patch 命令 5 秒 timeout，remote fetch/pull/push 60 秒 timeout。repository root 必须等于 agent workspace root，普通 repo metadata 不能逃出 workspace，受管 linked worktree 只能位于 `.intatis/git-worktrees/<name>` 并指向 owning workspace repo 的 `worktrees/` metadata。path/patch 工具均经 `PathConfinement`，patch 工具会从 unified diff 解析 changed paths 后再预检或执行；非 cached `git_apply_patch` 使用 `git apply --3way`，非 cached `git_revert_patch` 会先 best-effort stage patch 已存在路径再 `git apply --3way -R`；`git_revert_patch` / `git_worktree_remove` / `git_push` / `git_switch` 是 destructive 工具并要求显式确认。remote Git 只接受已配置 remote name，不接受 URL remote/refspec，输出遮蔽 URL 凭据/token；`git_pull_ff` 只做 clean 当前分支 `--ff-only`；`git_push` 不支持 force；真实 remote auth 由本机 Git credential helper/SSH agent 处理，Intatis 不读取或保存凭据。Cowork `ToolCapability.gitControl` 下 coordinator lease 默认获得本地 Git control，`ToolCapability.gitRemote` 下 coordinator lease 默认获得 remote Git control，worker lease 默认不获得任何 Git 工具；旧 `runShell` lease 仅暴露 read-only Git 工具作为兼容。未实现 merge/rebase/reset/clean/force-push/remote auth 管理/PR/CI，也未引入 libgit2/SwiftGit2。
- 本轮 Git control 调研结论：Codex 官方 App/Worktrees/CLI 文档与 openai/codex 开源实现共同指向“受限 Git 工具 + patch/worktree/权限门”，而非开放 shell；Codex 内部 Git helper 倾向参数数组调用、禁用 hooks、read-only metadata、patch preflight/apply 和 worktree 隔离。Intatis 本轮只复用公开行为模式，不复制 Codex 源码或文案。libgit2 是最适合未来 in-process Git backend 的成熟基础，但需要许可证与 native build 审查；SwiftGit2 是可参考的 Swift binding，但成熟度/维护状态需进一步核查；isomorphic-git、go-git、JGit、gitoxide 更适合各自语言生态，不适合直接引入本 Swift zero-dependency slice；GitButler/Jujutsu 对 stacked/parallel branch 和 undo/workflow 设计有参考价值，但 GitButler 许可证不适合直接依赖或复制源码。
- Cowork 架构原则已定义（见 `docs/COWORK_PRINCIPLES.md` 与仓内 7 个 COWORK_* 文档），但当前实现与原则有已知差距。
- 真机 + 真实 key 的端到端验证状态 `UNKNOWN`。

## 2026-07-19 Phase S：会话状态与工作区授权持久化

- `events.jsonl` 现在是 session 状态的唯一权威事实源。`session_settings_updated` 以完整、版本化快照保存 Chat/Code/Cowork 显示名称及 Cowork project settings，`session_storage_migrated` 保存稳定、幂等的迁移完成标记；Cowork settings 的 `defaultProviderID` 只为旧数据解码保留，新事件编码不再写入这一可能暴露私有 route 文本的兼容字段。EventLog append 的返回值与 subscriber 都来自实际编码 JSONL 的反解结果，运行中、stream、replay 与磁盘不会因 decode-only 字段或日期精度产生 settings revision 漂移。
- `<session>/session.json` 已升级为 schema v2 的 secret-free 派生投影，包含 `projectedThroughSeq`、显示名称、Cowork settings revision、agent 登记、workspace/capability 摘要与已完成迁移。它使用 owner-only 原子替换、稳定跨进程锁和父目录同步；读取/refresh 会以完整 EventLog fold 为校验权威，同水位或落后但被篡改的 cache 也不能覆盖 EventLog。删除或损坏该文件后可从 EventLog 重建；遇到当前版本不能理解的未来 session event 时拒绝覆盖，不能假装已完整投影。
- Apple security-scoped bookmark bytes 只保存在 session-owned `<session>/workspace-access.plist`。该文件是 schema v1 binary plist、owner-only `0600`，使用 no-follow 跨进程锁、原子写、文件与父目录同步；EventLog、`session.json`、UserDefaults 和 UI 投影都不保存 bookmark bytes。macOS 以 `WorkspaceAccessLease` 在实际使用期持有同一个 security-scoped URL 的 start/stop 生命周期，并以 canonical identity 做精确匹配；Code/Cowork view model 在整个使用期保留 lease，切换或 teardown 后释放。共享 path 不再由最后一个 `agentName` 覆盖；移除 Agent/目录先持久化 settings，随后只清理剩余 settings 与 live roster 都不再引用的非-primary capability，任何身份不确定性都保守保留。primary 在 UI、ViewModel 方法和 plist store 三层默认不可删除，只有新建/重授权事务失败回滚能显式请求底层清理。
- brand-new Cowork session 的初始化是一个严格的七事件合同，连续 `seq 0...6` 依次为：settings、`@main` workspace lease、`@main` capability lease、`@main` agent 登记、`@permission-reviewer` workspace lease、reviewer capability lease、reviewer agent 登记。两者使用同一 exact inference binding，但 agent identity、workspace lease 与 capability lease 均不同；reviewer 固定 `read_only`、空工具、无通信/委派、`coordinationDepth=0`。初始化只建立本地 durable state，不调用模型/provider。
- 历史 UserDefaults 只作为一次性迁移输入。共享旧 path→bookmark map 只有在该 session 存在 legacy ownership evidence 时才可消费；迁移必须精确解析原 binding、验证所有必需 workspace/bookmark/primary 语义。符号链接旧 path 只在 bookmark scope 已启用后做 alias→canonical identity 验证，并先把 canonical path 作为 settings revision 写入 EventLog，再写 durable marker，之后才清理旧 settings/bookmark/path key；marker 前崩溃可重试，marker 存在后不会再从全局旧 map 补回已删除的 session plist。
- GUI 恢复历史 session 时以 EventLog settings/roster 为准；缺失 `@main` 可由宿主从 canonical settings 做本地、显式、exact-bound 的历史主 agent 恢复，reviewer Retry 会先修复主 agent再重建控制面 reviewer。CLI `/agent restore-main` 走专用历史恢复入口，不再伪装成普通 `attach`。登记恢复本身不调用 provider；recovered root tasks 继续保持 paused/interrupted，只有显式 Retry 才运行；历史 active Goal 只对账并 durable pause，只有显式 Resume 才运行。
- Rename 已改为 EventLog-first：legacy 名称先只读捕获，再在一个 EventLog transaction 中追加 settings + marker，最后刷新 `session.json`；append 失败或 batch 已提交但 rebuild 前中断都可重试，目录名、`SessionID` 与旧 envelope 不变。历史 main 恢复的初检与最终 CAS 复用 `SessionProjectionStore` 的严格 revision fold，非法 revision 链 fail closed，revision 溢出不会崩溃。
- 最终验证：Phase S + 终审回归 focused suites **137/137**；独立 scratch 目录完整 SwiftPM **785 tests executed / 14 skipped / 0 failures**；`swift build`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均通过。Computer Use 先前验证新建/重启、capability 缺失、错误目录拒绝与 exact original directory 重授权；最终最新 build 再次恢复 `cowork_mire6j2d`，确认 reviewer enabled、`2 agents · 0 running`、Project Settings、未发送草稿 enable/clear，并在最后补丁后确认 primary Trash disabled。退出后 EventLog 37 条、最后 `seq 36`，`session.json.projectedThroughSeq == 36`，初始七事件未改写，且无 user/task/permission-review-request；`session.json` 与 plist 均为 `0600`。没有发送真实 provider 请求；当时未覆盖的 App Sandbox symlink picker 已随 Mac App Store 产品面退役，不再是当前 follow-up；shared-worker removal UI 仍未覆盖。
- Phase S 当时没有解决 composer、reviewer request isolation 或 app/runtime lifecycle；Phase A、Phase B 与 Phase L 现已分别实施。状态可恢复只意味着可以重建和对账，仍不意味着旧任务应自动续跑。

## 2026-07-20 Phase A：Cowork composer 与 durable submitted intent

- Cowork 草稿编辑已与 reviewer、Goal、`@main` inference、pending permission 和 `isWorking` 解耦；Send 只要求本地文本或附件存在，且不会在同一次持久化尚未完成时重复提交。持久化期间新输入属于下一份草稿，前一次回调只清除与 frozen payload 完全相同的文本/附件。
- `SubmissionID`、message/output/error correlation、`submission_status_changed` 和 root `TaskContract.submissionID` 以 additive 兼容字段落入协议/EventLog。`SubmittedIntentStore` 先保存 first-write-wins outbox，再以同一 EventLog transaction 追加唯一 `user_message + queued(attempt 1)`；状态机 one-based、单调，拒绝 orphan/跳号/terminal rewrite。
- 面向 `@main` 的普通消息与 durable `/goal` 还把 Send 瞬间的 `UserMessagePayload.mainAgentInferenceBinding` 冻结进同一 immutable payload；选择器在 current task/agent 工作时仍可更新，但不会修改当前 live binding。连续 A/B 提交各自保留自己的 exact binding，outbox/replay/Retry 不读取后来菜单值；direct ordinary-worker message 保持 `nil`，不会触发 main rebind。
- `<session>/submitted-intent-outbox.json` schema 1 是 EventLog 不可写时的可见、session-owned fallback；owner-only、no-follow、跨进程锁、原子替换/fsync/读回验证。它不能直接驱动 execution，canonical append 成功后清理。
- 附件先进入 session ArtifactStore；index/blob/lock 使用 owner-only durable file、跨实例 merge lock、路径与扩展名校验，历史安全 regular file可显式收敛到 `0600`。当前 remote adapter 只支持 image；其他类型和 Goal attachments 明确失败但不丢本地文件。
- submitted intent 使用 FIFO；active Goal 期间后续提交保持 queued。每个 main-hosted submission 到达空闲执行边界时，Orchestrator 才在一个 admission-lock hold / EventLog batch 内原子提交可选 `@main` rebind 与对应 root created/assigned/queued，live roster 只在 batch 成功后更新；profile 撤销或解析失败会结算该 submission，不回退 current/default。新式 Goal 另把同一 frozen binding 保存到 durable `Goal`，所有 continuation/Retry/重启恢复继续使用它。reviewer unavailable 只 deny 后续 ask-class tool，普通 main request 不以 reviewer ready 为前置条件。
- retry 复用同一 submission 与 exact durable root task，不重复 user message；恢复的 queued/running submission 显示 interrupted 并要求显式 Retry，新提交可在 restored tasks 仍 paused 时继续执行。ContextProjector 按 accepted submission 顺序隔离历史，排除当前旧 attempt、later submission 与无归属 legacy content。
- Phase A 当前范围只覆盖 Cowork 输入链路，Code 仍保留既有单-agent busy 策略。Phase B 已完成 permission reviewer request/generation isolation；active Goal 冷启动、session 切换/后台运行和 Command-Q/crash 语义已由 Phase L 独立完成。

## 2026-07-20 Phase C：权限响应、工具调用与 turn 终态

- 新增稳定 `TurnID`、`ExecutionFailureSource`、`ToolCallOutcome`、`TurnOutcome` 与 `turn_outcome` 事件。user deny/cancel、policy deny、reviewer timeout/failure、sandbox deny 与 runtime failure 不再依赖错误字符串推断；所有字段均为 additive/legacy-decodable，旧 JSONL 缺字段继续按保守兼容路径投影。
- `PermissionApprovalResolution` 明确区分 `approve`、`decline` 与 `cancel_turn`，权限请求记录 manual/automatic approval mode，并贯穿 turn、tool-call、request 与 authorization identity。`EventLog.registerPermissionRequest` 对同一 RequestID first-write-wins；`settlePermissionRequest` 在 complete-known history 和同一跨进程锁内完成首终态 CAS。完全相同的 request/terminal duplicate 幂等复用原 Envelope，冲突 payload、tool、turn、tool-call、authorization、action/decision 或 terminal 全部 fail closed。
- AgentLoop 中 `Decline Call` 只给当前 call 写 typed denied `tool_result`，模型可继续本轮；`Cancel Turn` 先 durable settle permission，再以 interrupted 终结 turn，禁止注入伪造的 denied tool result。Chat、Code 与 Cowork 新 turn 都追加 completed/failed/interrupted terminal；provider 自己抛 `CancellationError` 但 caller task 未取消时归为 runtime failure，不能冒充用户取消。
- `PermissionReviewControlPlane` 对 active/completed 同 RequestID 的 exact duplicate 共享同一 owner generation 与 terminal；冲突 duplicate fail closed。duplicate waiter 自身取消只影响该 waiter；owner 在 durable allow 后、authorization delivery 前取消时，所有共享 delivery 都 fail closed。权限 projection 以 request arrival FIFO 展示，任意中间项 terminal 后只移除该项，不重排其余请求；同进程重显复用同一 durable identity。
- macOS/CLI 人工模式使用明确的 `Approve Call`、`Decline Call`、`Cancel Turn`；自动模式卡片只显示 reserved reviewer 的进行中状态，不提供人工按钮。Code/Cowork view model 的 waiter、取消与 teardown 使用结构化 resolution，不再用一个布尔值混合批准、拒绝和取消。
- Shell/structured-process 只有在受信 wrapper 启动标记证明目标尚未进入、且诊断匹配 sandbox wrapper startup failure 时才产生 `WorkspaceSandboxDeniedError`；目标程序伪造相同 stderr、普通 nonzero 或一般 EPERM 不得误分类。AgentLoop 将该路径结算为 `denied + sandbox_denied + not_started`，不执行无沙箱自动重试。timeout/cancel 使用 structured child ownership；Orchestrator task cancel/stop 先等待 provider/tool cleanup，再持久化 terminal 并恢复 caller。
- 验证：Phase C 八个 focused suite 合计 **126/126**；完整 SwiftPM 在独立 scratch 中执行 **895 tests / 14 skipped / 0 failures**；XcodeGen、IntatisMac macOS Debug、IntatisiOS Simulator Debug build 均成功。Computer Use 使用独立 bundle ID 与 DEBUG-only 离线 fixture，验证批准、拒绝当前调用、取消整个 turn，以及自动审查无人工按钮；fixture 不创建 provider、EventLog、credential resolver、responder 或 executor。真实 endpoint cancellation/服务端停止时序与 Linux bwrap 实机仍为 `UNKNOWN`。

## 2026-07-20 Phase L：应用级 session runtime 生命周期

- macOS 新增进程级 `AppSessionRuntimeManager`，按 exact `{SessionKind, SessionID}` 持有 Chat/Code/Cowork runtime。每个窗口只保留自己的 mode/session 展示选择；切换 mode/session、Command-W 或关闭最后窗口只改变展示/订阅，不再调用 stop。manager 发布 runtime 状态与 removal，跨窗口删除会先精确 drain 目标 runtime，并让仍展示该 session 的窗口退出失效详情。
- Chat、Code 与 Cowork 都有 idempotent shutdown admission fence：先拒绝新工作，再取消并等待已登记的 send/provider/tool/direct-operation task，解决 permission waiter、关闭 subscription，最后释放 workspace security scope。Cowork 的 workspace/agent/settings/Goal/permission 入口均在 quiesce 后 fail closed，避免 Command-Q 或删除期间产生 manager 未等待的新写入。
- Command-Q 由 app delegate 进入 terminate-later：manager 同时向全部 runtime 广播 stop，使用单调时钟和 bounded deadline 等待；正常完成返回 settled，超过 deadline 返回 timed-out 并允许退出，不伪造 durable settlement。普通窗口关闭不触发这一流程。
- 冷启动只做 EventLog replay/recovery/reconcile。active Goal 被 durable pause（预算已用尽时保持 budget-limited）；历史 running/stopping 由恢复投影标记 interrupted。App 重开、crash/force-quit 后重开都不自动调用 provider；继续工作必须来自明确的 Send、Retry、Resume，CLI 则仍要求显式 `/auto|/default` data-plane 边界。
- 自动化：新增 `BoundedSessionRuntimeShutdownTests` 5/5；更新 `GoalRuntimeControllerTests` 后 focused 34/34，覆盖 active→paused、budget-limited、pause persistence failure fail closed 与显式 resume。完整 SwiftPM 为 **903 tests / 14 skipped / 0 failures**；最终 macOS Debug 与 iOS Simulator Debug build 均通过。
- Computer Use 使用独立 bundle ID 和 DEBUG-only 离线 lifecycle fixture 验证：A/B 同时后台推进、切换/History/Command-W 不停止、Command-N 复用同一 manager runtime、Command-Q 双 session 各停一次并结算、正常重开不续跑、精确进程强杀后 running→interrupted、显式 Resume 单独继续，以及 700 ms deadline 下不合作 B 保持 stopping、重开转 interrupted。fixture 不创建生产 provider、EventLog、credential、workspace 或工具 executor；它证明应用 ownership/退出/reopen 合同，不证明真实远端服务端何时物理停止。

## 已有能力

| 能力 | 入口 / 关键类型 | 测试覆盖 | 手动验证 | 真机验证 |
|---|---|---|---|---|
| 外部 MCP Server 客户端 | `IntatisMCP` / `IntatisMCPStdio` / `IntatisCurlTransport` / `MCPServerCatalogStore` / `MCPSessionRuntimeOwner` / `MCPAgentRequestToolSnapshotSource` / macOS MCP Center / CLI `/mcp` 与 `intatis mcp` | full SwiftPM 1362/16 skipped/0 failed；official 23/23；Tasks 3/3；W10 focused 102/102；P1 80/80 | Developer ID `IntatisMac` 与 CLI：stdio/HTTP；iOS：无 MCP。macOS/CLI 管理、import、OAuth、content、tasks 与 lazy session owner 均有确定性/fixture 覆盖；遗留 App Store HTTP-only target 不再是产品矩阵 | 匹配架构 Linux+bwrap、签名 App Keychain、真实第三方 stdio/HTTP/OAuth、Developer ID 签名/公证发行仍 `I-ENV` |
| IntatisMac chat | `IntatisMacApp` / `ChatViewModel` / `ChatLoop` | `IntatisConversationTests` | UNKNOWN | UNKNOWN |
| IntatisMac cowork | `CoworkViewModel` / `SubmittedIntentStore` / `Orchestrator` / `AgentLoop` | `IntatisCoworkTests` / `IntatisAgentKernelTests` / `IntatisConversationTests` | Phase A Computer Use 已验证 reviewer failed 时 composer 可编辑、Send durable accept、route failure/Retry 卡片、继续编辑，以及附件 durable import/attachment-only Send eligibility（附件草稿未发送）；未发真实 provider | UNKNOWN |
| Cowork durable Goal/WorkTask | `Goal` / `WorkTaskGraph` / `ContinuationRun` / `CoworkProjection` / `WorkTaskTools` / `GoalVerifierControlPlane` / `GoalRuntimeController` / Orchestrator Goal authority | `TaskGoalProtocolTests` / `TaskGoalProjectionTests` / `WorkTaskRuntimeTests` / `GoalManagerRuntimeTests` / `GoalVerifierControlPlaneTests` / `GoalRuntimeControllerTests` | deterministic XCTest 覆盖 full completion proof、atomic settlement、scoped barrier/cancel、scope inheritance、carry-forward、checkpoint reconcile 与 typed usage-limit；本轮完整 build/test 与 Computer Use 结果见最终报告 | 真实 provider 多 run / process-kill restart UNKNOWN |
| IntatisMac Cowork project mode | `CoworkSessionSettings` / `SessionProjectionStore` / `SessionWorkspaceAccessStore` / `CoworkViewModel.project` / `CoworkShell` inspector / `AppSessionRuntimeManager` | Phase S + 终审回归 focused 137/137；Phase A/B/C/L 各有独立 focused/full 证据；Phase L full 903/14 skipped/0 failures | Swift/macOS/iOS builds 通过；Computer Use 已覆盖新建、Project Settings、重启/重授权、reviewer 状态、primary 保护，以及 Phase L 双 session/窗口/正常退出/强杀/deadline 生命周期；未发送 provider 请求 | 真实 provider 服务端取消、真实生产 EventLog 的进程强杀边界、symlink/shared-worker UI 仍 UNKNOWN |
| Cowork per-agent inference profiles | `InferenceCatalog` / `InferenceCatalogStore` / `AgentInferenceBinding` / `ProviderRegistry.agentInference` / `Orchestrator.rebindAgentInferenceProfile` / `AppInferenceCatalog` / `CLIInferenceProfiles` | `InferenceProfileProtocolTests` / `InferenceCatalogTests` / `InferenceCatalogStoreResolverTests` / `PerAgentInferenceProfileTests` / `CoworkInferencePresentationTests` | exact immutable revision、32-way 独立 store 并发 revision 保留/无碰撞、lock integrity、strict no-fallback、atomic binding/model/provider tuple、provider-only strict factory 拒绝、spawn inheritance、host-approved explicit profile、delegate target snapshot、busy/idle durable rebind 与安全 UI projection 已有 focused 覆盖；本文档子任务未单独运行测试，最终自动化/构建/Computer Use 结果见本轮总报告 | 真实同 session 多 endpoint/model/effort、credential rotation、长期恢复 UNKNOWN；当前仅 OpenAI-compatible wire，route lease/跨 trust-domain 专用审批/完整 capability validation 未实现 |
| IntatisMac multimodal | `MultimodalService` | `IntatisMultimodalTests` | UNKNOWN | UNKNOWN |
| 对话 Microsoft Markdown / plain-safe | `IntatisMessageRendererMode` / `IntatisMessageContentView` / `IntatisMicrosoftMarkdownPipeline` / `IntatisLatestOnlyPermitScheduler` / `IntatisThreadHistoryWindow`；`Vendor/SwiftStreamingMarkdown`；iOS `Settings.bundle` | 当前公式 focused 39/39、vendor strict Release 90/90、根 `MessageRenderingTests` 41/41；SharedUI target、XcodeGen、macOS/iOS Simulator Debug build 通过；history-window/scroll focused 69/69 与此前完整 root 仍是各自记录的历史基线 | macOS Chat/Code/Cowork 使用 16-row bounded eager history pages，已在真实问题 session 完成 entry/scroll/A→B→A/Earlier/Latest；rich 路径含 code-aware inline/display LaTeX、无公式专属数量/字节/固定尺寸上限的 live TextKit 2 attachment、projection pump、window-local scroll/viewport admission与单一 paragraph width owner | 本次未跑完整 root、Release app 矩阵或真实窗口；旧 lazy soak 不等于 current-container soak；共享 iOS Chat、真实 clipboard/VoiceOver、最低支持 macOS、低端设备与 2026-07-18 历史 retaining edge 仍 `UNKNOWN`，因此不把整个 renderer描述为无条件 release-ready |
| IntatisiOS chat | `IntatisiOSApp` / `IOSAppEnvironment` / `ChatViewModel` / Responses `web_search` / `MessageCitation` | Providers、Conversation、ChatHistoryReplay、localization 与 iOS Simulator Debug build 通过 | 搜索能力无按钮/菜单/开关；Device Hub 已确认 paperclip 菜单只剩生图项；真实 provider/model 搜索 E2E 未运行 | UNKNOWN |
| 权限 3 层门 | `PermissionEngine` / `DeterministicPolicyGate` / `ModelPermissionReviewer` | `IntatisPermissionTests` / `ReviewerTests` | UNKNOWN | UNKNOWN |
| Provider OpenAI 兼容 | `OpenAIWireProvider` / `SSE.swift` | `IntatisProvidersTests` | UNKNOWN | UNKNOWN |
| API 错误反馈 | `ProviderErrorFormatting` / `RuntimeErrorPresentation` / `ConversationProjection` / `OpenAIWireProvider` / `OpenAIToolCalling` | `IntatisProvidersTests` / `IntatisConversationTests` | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（63 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），macOS/iOS Xcode Debug build 通过；真实 provider/key UNKNOWN | UNKNOWN |
| Provider health check / 设置页 Test Provider | `ProviderHealthCheck` / `ProviderRegistry.healthCheck` / `IntatisSettingsPanel` / `IOSRootView.settingsSheet` | `IntatisProvidersTests` | Provider focused tests 通过（63 tests, 0 failures），full SwiftPM tests 通过（275 tests, 0 failures），macOS/iOS Xcode build 通过；真实 provider/key UNKNOWN | UNKNOWN |
| Provider runtime retry/timeout/rate-limit headers | `ProviderRuntimePolicy` / `ProviderErrorFormatting` / `HTTPDataResponse` / `OpenAIWireProvider` / `OpenAIToolCalling` / `OpenAIImageProvider` / `OpenAITranscriptionProvider` | `IntatisProvidersTests` | Provider focused tests 通过（63 tests, 0 failures），full SwiftPM tests 通过（275 tests, 0 failures）且 macOS/iOS Xcode Debug build 通过；真实 provider/key UNKNOWN | UNKNOWN |
| 工具执行反馈 | `AgentLoop` / `CodeProjection` / `RuntimeRecoveryAdvice` / `Terminal` / `CodeViews` | `IntatisAgentKernelTests` / `IntatisConversationTests` / `IntatisCoworkTests` | full SwiftPM tests 通过（275 tests, 0 failures），AgentKernel focused tests 通过（22 tests, 0 failures，含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流），Cowork focused tests 通过（79 tests, 0 failures），Tools focused tests 通过（9 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），macOS/iOS Xcode Debug build 通过；GUI 手动 UNKNOWN | UNKNOWN |
| Agent Git control | `ShellGit.swift` / `GitService` / `git_status` / `git_diff` / `git_diff_staged` / `git_info` / `git_recent_commits` / `git_diff_base` / `git_branch` / `git_create_branch` / `git_stage` / `git_unstage` / `git_commit` / `git_apply_patch_check` / `git_apply_patch` / `git_stage_patch` / `git_unstage_patch` / `git_revert_patch` / `git_worktree_list` / `git_worktree_create` / `git_worktree_remove` / `git_remotes` / `git_fetch` / `git_pull_ff` / `git_push` / `git_switch` / `ToolCapability.gitControl` / `ToolCapability.gitRemote` | `IntatisToolsTests` / `IntatisAgentKernelTests` / `IntatisPermissionTests` / `CapabilityLeaseTests` / `ToolRegistryLeaseTests` | 本轮实现 remote Git 基础工具：只接受已配置 remote name，不接受 URL remote/refspec；remote 输出遮蔽 URL 凭据/token；fetch 是 write+network；pull 只做 clean 当前分支 `--ff-only` 且要求确认；push 是 destructive+network high-risk、要求确认且不支持 force；switch 只在 clean working tree 切换既有本地分支。当前代码已补 fake service / registry / lease / permission / remote confirmation / force-argument schema tests。验证通过：`swift build --scratch-path /private/tmp/intatis-git-remote-build`；`swift test --scratch-path /private/tmp/intatis-git-remote-tests --filter 'IntatisToolsTests|IntatisAgentKernelTests|IntatisPermissionTests|CapabilityLeaseTests|ToolRegistryLeaseTests'`（136 tests / 14 skipped / 0 failures）。本轮未对当前仓库执行真实 remote fetch/pull/push；`INTATIS_REAL_GIT_SMOKE=1` opt-in XCTest 仍为上一轮覆盖真实临时 Git repo 的 stage/commit/recent/info、patch check/apply/revert 后 clean、`.intatis/git-worktrees` create/info/remove。真实复杂仓库、submodule、merge conflict、commit hooks、detached HEAD、非 repo、真实 patch conflict、真实远端 fetch/pull/push/auth、GUI/provider E2E Git 矩阵 UNKNOWN；merge/rebase/reset/clean/force-push/remote auth 管理/PR/CI 未实现 | UNKNOWN |
| Agent 文档/媒体工具 | `DocumentMediaTools.swift` / `ProviderImageGenerationToolService` / `ToolRegistry.standard()` / `ToolCapability` leases | `IntatisToolsTests` / `IntatisAgentKernelTests` / `IntatisCoworkTests` / `CapabilityLeaseTests` | 上一轮 Tools focused tests 通过基线（55 tests, 12 skipped, 0 failures，含网络/浏览器可选 smoke skip）；AgentKernel focused tests 通过（22 tests, 0 failures，含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流）；Cowork focused tests 通过（81 tests, 0 failures）；CapabilityLease focused tests 通过（3 tests, 0 failures）；full SwiftPM tests 通过（331 tests, 12 skipped, 0 failures）；`swift build` 通过；IntatisMac / IntatisiOS simulator Xcode Debug build 通过；真实 Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers 安装矩阵、真实 provider 生图、真机手动 UNKNOWN | UNKNOWN |
| Agent 网络/浏览器工具 | `BrowserTools.swift` / `WebFetchTool` / `BrowserDiagnosticsTool` / `BrowserProfilesTool` / `BrowserProfileDeleteTool` / `BrowserHistoryTool` / `BrowserNavigateTool` / `BrowserSnapshotTool` / `BrowserHandoffTool` / `BrowserReloadTool` / `BrowserBackTool` / `BrowserForwardTool` / `BrowserClickTool` / `BrowserTypeTool` / `BrowserSubmitTool` / `BrowserSelectOptionTool` / `BrowserPressKeyTool` / `BrowserScrollTool` / `BrowserWaitTool` / `BrowserScreenshotTool` / `BrowserUploadFileTool` / `BrowserDownloadTool` / `BrowserDownloadsTool` / `BrowserSearchTool` / `ToolCapability.browseWeb` | `IntatisToolsTests` / `IntatisPermissionTests` / `IntatisCoworkTests` / `CapabilityLeaseTests` | 上一轮 Tools focused tests 通过基线（55 tests, 12 skipped, 0 failures，覆盖 concurrent profile state/history metadata、同一 workspace profile 命令串行化 fake-shell overlap、metadata-only profile inventory、确认保护的 profile 删除与 history pruning、headed handoff payload/state/history、workspace 文件上传、显式下载 changedFiles、下载 metadata 只读列表、搜索结果文本/链接/history、交互控件摘要输出、打开新页面 observation/state/history metadata、browser_type 凭据目标拒绝、web_fetch local HTTP/truncation/non-HTTP URL 覆盖、表单提交 payload/history、下拉选择历史、按键历史、滚动历史、等待历史、reload 历史、back/forward navigation stack 与历史、zero-delta 拒绝和 key 控制字符拒绝）；真实浏览器 smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-test --filter IntatisToolsTests/testRealBrowserBackendSmokeWhenEnabled` 通过（1 test, 0 failures），验证 Playwright 缺失时 `BrowserNavigateTool` 可 fallback 到 Edge/CDP 并访问 `https://example.com`；真实 search smoke `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-clang-module-cache INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-browser-search-real --filter IntatisToolsTests/testRealBrowserSearchWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可用持久 profile 打开 DuckDuckGo 搜索页并写入 search history metadata；真实 profile smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-test --filter IntatisToolsTests/testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled` 通过（1 test, 0 failures），验证同一 Edge/CDP profile 的持久 cookie、localStorage 状态与 history metadata 跨两次工具调用保留；真实浏览器 upload/download smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-real-test --filter IntatisToolsTests/testRealBrowserUploadDownloadWhenEnabled` 通过（1 test, 0 failures），验证真实 file input 上传、Blob 下载写入 `.intatis/browser/downloads/io-smoke`、`changedFiles` 与 downloads metadata；真实 submit smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-submit-real-smoke --filter IntatisToolsTests/testRealBrowserSubmitWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可在本地 HTTP 表单页提交并到达结果页、写入 submit history metadata；真实 popup/new-page smoke `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-clang-module-cache INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-popup-real-smoke2 --filter IntatisToolsTests/testRealBrowserPopupNewPageWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可用真实鼠标事件点击 target=_blank 链接、跟随新页面并写入 state/history；真实 select/press smoke 此前通过（1 test, 0 failures，需允许启动浏览器/脱离 sandbox），验证 Edge/CDP 可执行下拉选择和 Enter key dispatch；本轮把该 smoke 扩展为交互摘要断言后，重跑请求被 sandbox escalation 自动审批拒绝，真实 CDP 交互摘要断言仍 UNKNOWN；真实 scroll/wait smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-scroll-test2 --filter IntatisToolsTests/testRealBrowserScrollAndWaitWhenEnabled` 通过（1 test, 0 failures，需允许启动浏览器和本地 HTTP 服务/脱离 sandbox），验证 Edge/CDP 可滚动页面并等待动态文本出现；真实 profile isolation smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-isolation-test2 --filter IntatisToolsTests/testRealBrowserProfilesRemainIsolatedWhenEnabled` 通过（1 test, 0 failures），验证两个 Edge/CDP profile 的 cookie、localStorage marker 与 history metadata 互相隔离；真实 back/forward smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-history-test --filter IntatisToolsTests/testRealBrowserBackForwardWhenEnabled` 通过（1 test, 0 failures），验证 loopback HTTP 页面上的 navigation stack 前进/后退；真实 dynamic feed/task smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-real-feed-task-smoke --filter IntatisToolsTests/testRealBrowserDynamicFeedAndOnlineTaskWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可在本地动态信息流中 scroll/wait、进入任务表单、输入非敏感文本并提交到完成页、写入 navigate/scroll/wait/click/type/submit history metadata；真实 handoff smoke `INTATIS_REAL_BROWSER_HANDOFF_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-handoff-test --filter IntatisToolsTests/testRealBrowserHandoffWhenEnabled` 通过（1 test, 0 failures，需允许启动浏览器/脱离 sandbox），验证 Edge/CDP 可打开有界 headed persistent profile 并回写 state/history；新增真实不同 profile 并发启动 opt-in smoke 仅完成编译和默认 skip 验证，真实 Edge/CDP 并发启动未运行；Permission focused tests 通过（37 tests, 0 failures）、AgentKernel focused tests 通过（22 tests, 0 failures，含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流）、CapabilityLease focused tests 通过（3 tests, 0 failures）、ToolRegistryLease focused tests 通过（6 tests, 0 failures）、MessageDelegationSplit focused tests 通过（8 tests, 0 failures）、CoworkEndToEnd focused tests 通过（3 tests, 0 failures）、Cowork focused tests 通过（81 tests, 0 failures）、full SwiftPM tests 通过（331 tests, 12 skipped, 0 failures）、`swift build` 通过、IntatisMac / IntatisiOS simulator Xcode Debug build 通过；generic iOS 设备 build 因未配置 development team 签名失败，未作为源码失败处理；本机抽样 `node --version` 为 v26.3.0，`require('playwright')` 当前不可解析，`/Applications/Microsoft Edge.app` 存在，Google Chrome/Chromium app 未发现；真实 Playwright 运行、第三方站点登录、社交媒体、代办网站、真实第三方网站下载/上传/表单提交、长期 profile 清理/污染和真实同时启动多 profile 管理 UNKNOWN；sequential profile isolation 已通过，同进程同 profile 串行化真实浏览器并发矩阵仍待验证 | UNKNOWN |
| GUI 多 provider/model 设置 | `AppConfig` / `IOSConfig` / `IntatisSettingsPanel` / iOS Settings sheet / Chat model menu | 无专门测试；app target 构建覆盖 | Xcode 构建通过；真实 key UNKNOWN | UNKNOWN |
| macOS UI 信息架构 | `IntatisMacRootView` / `IntatisChatScreen` / `CodeViews` / `CoworkViews` / `ThreadSurfaces` | app target 构建覆盖；相关 token usage tests；Computer Use visual QA | 2026-07-21：纵向 mode navigation、session-name header、无消息 agent 头像/通用 Agent badge、独立 usage 行、composer 内 model/profile/attachment 与宽屏原生 inspector 已在最新 Debug app 中确认；`swift build`、macOS/iOS Xcode Debug build、`CoworkInferencePresentationTests` 4/4 通过；参考图与运行态截图联合比较记录为 `passed`，见 `design-qa.md`。既有 bubble alignment/响应式宽度合成覆盖仍保留 | Light appearance 的同状态最新截图、真实 provider context-window 上限与真机矩阵仍 UNKNOWN |
| Chat/Code/Cowork session/history | `SessionHistoryStore` / `SessionProjectionStore` / `SessionWorkspaceAccessStore` / `AppSessionRuntimeManager` / window-local `AppEnvironment` / `IOSAppEnvironment` / macOS root sidebar history / iOS Chat History UI | `SessionStateProtocolTests` / `SessionProjectionStoreTests` / `IntatisCoreTests` / `BoundedSessionRuntimeShutdownTests` + app target 构建 | Phase S focused 137/137；Phase L Goal 34/34、shutdown 5/5、当前 full 903/14 skipped/0 failures，macOS/iOS build 通过；Computer Use 已覆盖新建/重授权及双 session/窗口/quit/reopen/强杀/deadline synthetic 矩阵；Rename EventLog-first，`session.json` 可重建，bookmark session-owned、primary 默认不可删除 | 真实生产 session 在 provider/tool mutation 边界的强杀/掉电与 symlink/shared-worker GUI 矩阵仍 UNKNOWN |
| macOS 高级 JSON provider 配置 | `AppConfig.fileProviderCatalog` / `AppConfig.prepareEditableConfigFile` / `ConfigSecretResolver` | 无专门测试；macOS app target 构建覆盖 | Xcode 构建通过；真实 config/auth JSON UNKNOWN | UNKNOWN |
| `/goal`：Chat/Code 标签 + Cowork durable Goal | `GoalInputParser` / `ConversationProjection` / `CodeProjection` / `CoworkProjection` / Goal host controller | `IntatisConversationTests` / `TaskGoalProtocolTests` / `TaskGoalProjectionTests` / Cowork Goal tests | Chat/Code legacy metadata 与 Cowork durable state 分层；GUI/CLI 手动以本轮最终验证为准 | 真实 provider多轮 UNKNOWN |
| GUI token/turn stats | `Usage` / `TurnStatsPayload` / `TurnStatsProjection` / `ChatViewModel` / `CodeViewModel` / `CoworkViewModel` / `IntatisTurnStatsSummaryView` | `IntatisProvidersTests` / `IntatisConversationTests` / `IntatisAgentKernelTests` + app target 构建覆盖 | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（63 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），AgentKernel focused tests 通过（22 tests, 0 failures，含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流），macOS/iOS Xcode 构建通过；真实 endpoint usage UNKNOWN | UNKNOWN |
| GUI/CLI Cowork 自动权限审查与 Phase C turn 语义 | `ToolRegistry` / `ResolvedToolAuthorization` / `PermissionReviewProviderFactory` / `PermissionReviewControlPlane` / `AgentPermissionResponder` / `TurnOutcome` / `EventLog.registerPermissionRequest` / `settlePermissionRequest` / `Interactive.swift` | Phase B 原八 suite；Phase C 的 `TurnOutcomeProtocolTests` / `PermissionSettlementTransactionTests` / `PermissionProjectionTests` / `AgentLoopOutcomeTests` / `SandboxDenialOutcomeTests` / `WorkspaceSandboxDenialTests` / `PermissionReviewControlPlaneTests` / `OrchestrationReliabilityTests` | Phase B focused **164/164**；Phase C focused **126/126**；Phase C 当时完整 SwiftPM **895 tests / 14 skipped / 0 failures**，其后 Phase L 当前全量为 **903 / 14 / 0**；Swift/macOS/iOS build 通过。Computer Use 离线 fixture 验证 Approve/Decline/Cancel 三个不同结果和 automatic non-actionable；未发送 provider 请求 | 真实 provider verdict 质量、endpoint cancel 后服务端物理停止时序、process-kill/FileHandle fault injection 与 Linux bwrap 实机仍 UNKNOWN |
| 事件日志 | `EventLog`（JSONL append-only + multi-event WAL） | `IntatisConversationTests` | multi-event WAL 覆盖完整/部分/损坏/错配/live-reader 恢复；legacy/strict replay 均先恢复未决 WAL，checked replay 校验 session、单调 seq 与 known payload，安全关键读取失败关闭；selected 67/67（主测试类 29/29）通过 | 真实进程强杀、掉电与底层 write/sync/truncate/rename/remove fault injection UNKNOWN；单事件首次创建日志的广义 power-loss durability 未纳入本轮范围 |
| Artifact 存储 | `ArtifactStore` / `DurableOwnerOnlyFile` | `IntatisArtifactsTests`（14） | owner-only/no-follow/atomic read-merge-write、并发实例/进程、legacy `0644` adoption 与 unsafe mode/symlink/hardlink 拒绝已自动验证；Phase A UI 已验证本地附件导入 | 掉电、orphan GC、旧实例实时 refresh 与 `commitUncertain` 后索引对账仍 UNKNOWN |

## 未完成 / 进行中

- **Cowork 原则后续项**（见 `docs/COWORK_PRINCIPLES.md` §6）：旧审计中的 root AgentInvocation、受控并行、durable recovery/cancel/timeout/budget、mailbox、lease enforcement、bounded untrusted context 与严格终态已由当前源码和回归补齐；本轮又加入 Goal/WorkTask/ContinuationRun 分层、独立 GoalVerifier 与 exact per-agent inference binding。仍未实现的是 direct multi-root tool context、独立 inference route lease/跨 trust-domain 专用审批、非 OpenAI-compatible wire adapter、完整 app model capability metadata，以及 EventLog-derived context/recovery 索引等长 session 性能优化；真实多上游/多 profile、App 被杀后 host continuation、GUI/CLI 长 Goal 恢复仍需真机验证。
- **Intatis 自有 Agent/daemon JSON-RPC out-of-process 传输未挂**：`JSONRPC.swift` 的 Command/Envelope 词汇与未来 `intatis agent --stdio` / `intatis daemon` 管道仍未接线。这是 Intatis 自有 Agent runtime 的独立后续项，**不是**外部 MCP stdio/HTTP client 的缺口；MCP client transport 已由 `IntatisMCPStdio` / `IntatisMCP` 实现。
- **SwiftGit2/libgit2 集成**：规划用于 sandbox 内 in-process git，许可证待审查。
- **Provider role 细分**：GUI 当前把 Chat / Agent / image / transcription role 绑定到选中 provider；Chat 使用独立 `chatEndpoint`，image/transcription 仍从 provider `baseURL` 拼路径且模型使用默认 id（`dall-e-3` / `whisper-1`），尚未提供独立 role-specific 设置 UI。
- **文档/媒体工具真实后端矩阵**：v0.16 已提供 Agent 可调用 wrapper 与本地 fake/小样本测试，但真实 Docling/Marker/Tesseract/Tectonic/qpdf/ComfyUI/Diffusers 安装、真实照片版面还原质量、真实 provider 生图、真机 GUI 手动验证仍为 UNKNOWN。扫描 PDF 的文字读取依赖 OCR/重建后端，不应把 PDFKit 文本抽取误认为 OCR。
- **网络/浏览器工具真实后端矩阵**：v0.16 已提供 Agent 可调用 wrapper、诊断/profile metadata/历史/headed handoff/截图/上传/下载/表单提交/下拉选择/按键/滚动/等待/新页面跟随/交互控件摘要工具、persistent profile 存储、fake-shell 测试和默认跳过的真实浏览器 smoke；本机抽样 Node.js v26.3.0 可用，`/Applications/Microsoft Edge.app` 存在，Playwright module 当前不可解析，Google Chrome/Chromium app 未发现。已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-test --filter IntatisToolsTests/testRealBrowserBackendSmokeWhenEnabled` 验证 `BrowserNavigateTool` 可在 Playwright 缺失时 fallback 到 Edge/CDP 并访问 `https://example.com`；已通过 `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-clang-module-cache INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-browser-search-real --filter IntatisToolsTests/testRealBrowserSearchWhenEnabled` 验证 Edge/CDP 可用持久 profile 打开 DuckDuckGo 搜索页并写入 search history metadata；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-test --filter IntatisToolsTests/testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled` 验证同一 Edge/CDP profile 的持久 cookie、localStorage 状态和 history metadata 可跨两次工具调用保留；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-real-test --filter IntatisToolsTests/testRealBrowserUploadDownloadWhenEnabled` 验证 data URL 页面中的真实 file input 上传、Blob 下载、`.intatis/browser/downloads/<profile>` 写入、`changedFiles` 与 downloads metadata；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-submit-real-smoke --filter IntatisToolsTests/testRealBrowserSubmitWhenEnabled` 验证 Edge/CDP 可在本地 HTTP 表单页提交并到达结果页、写入 submit history metadata；已通过 `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-clang-module-cache INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-popup-real-smoke2 --filter IntatisToolsTests/testRealBrowserPopupNewPageWhenEnabled` 验证 Edge/CDP 可用真实鼠标事件点击 target=_blank 链接、跟随新页面并把 popup URL 写入 state/history；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-test-codex --filter IntatisToolsTests/testRealBrowserSelectAndPressKeyWhenEnabled` 在脱离 sandbox 后验证 Edge/CDP 可对 data URL 表单执行下拉选择和 Enter key dispatch；本轮把该 smoke 扩展为交互摘要断言后，重跑请求被 sandbox escalation 自动审批拒绝，真实 CDP 交互摘要断言仍为 UNKNOWN；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-scroll-test2 --filter IntatisToolsTests/testRealBrowserScrollAndWaitWhenEnabled` 在脱离 sandbox 后验证 Edge/CDP 可在本地 HTTP 页面中滚动并等待动态文本出现；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-isolation-test2 --filter IntatisToolsTests/testRealBrowserProfilesRemainIsolatedWhenEnabled` 验证两个 Edge/CDP profile 的 cookie、localStorage marker 与 history metadata 互相隔离；已通过 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-real-feed-task-smoke --filter IntatisToolsTests/testRealBrowserDynamicFeedAndOnlineTaskWhenEnabled` 验证 Edge/CDP 可在本地动态信息流中 scroll/wait、进入任务表单、输入非敏感文本并提交到完成页、写入 navigate/scroll/wait/click/type/submit history metadata；已通过 `INTATIS_REAL_BROWSER_HANDOFF_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-handoff-test --filter IntatisToolsTests/testRealBrowserHandoffWhenEnabled` 在脱离 sandbox 后验证 Edge/CDP 可打开有界 headed persistent profile 并回写 state/history。本轮新增同一进程内同一 workspace profile 的浏览器命令串行化，防止多 agent 同时写同一 persistent profile/state/history，并新增 browser_type 凭据目标拒绝、metadata-only profile inventory（含 active/lock runtime marker 存在性但不读内容/文件名）、确认保护的 profile 删除（删除前仅输出 marker 概括提示）、打开新页面 observation/state/history 覆盖、`browser_search` fake-shell 结果文本/链接/history 覆盖、`browser_submit` fake-shell payload/history 覆盖，并新增 AgentLoop 动态信息流浏览（navigate/scroll/wait）fake-shell 权限流覆盖；配套 fake-shell 测试已通过（`swift test --filter IntatisToolsTests`：55 tests, 12 skipped, 0 failures；full `swift test`：331 tests, 12 skipped, 0 failures；`swift test --filter IntatisAgentKernelTests`：22 tests, 0 failures，含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流）。真实 Playwright + Chromium/Chrome 运行、第三方站点登录、社交媒体浏览、复杂网站代办、验证码/2FA、真实第三方网站下载、真实第三方网站文件上传、真实第三方网站表单提交、真实交互网站矩阵、长期 session 污染、真实外部进程占用下的 profile 清理行为和真实同时启动多 profile 管理仍为 UNKNOWN；sequential profile isolation 已通过；本轮一次真实 simultaneous Edge/CDP profile launch smoke 曾卡住并已停止。真实 profile smoke 为避免 macOS Edge profile 目录删除阻塞，仅清理本地测试站点，未验证长期 profile cleanup 策略；当前 marker 诊断只能帮助识别可能占用，不等于已验证长期清理策略。当前没有把 Chromium/CEF 嵌入 App UI，也没有 BrowserUse 式高级 planner/memory。
- **本轮浏览器并发 smoke 状态**：新增默认跳过的 `testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled`，用 `INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE=1` 才会同时启动两个不同 Edge/CDP profile 并访问本地页面。本轮仅验证了该测试的编译与默认 skip path；真实 Edge/CDP 并发启动因脱离 sandbox escalation 被当前环境使用量限制拒绝而未运行。当前 `swift build --disable-sandbox --scratch-path /private/tmp/intatis-build-concurrency` 通过；`swift test --disable-sandbox --scratch-path /private/tmp/intatis-real-profile-concurrency-skip --filter IntatisToolsTests/testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled` 通过（1 skipped）；`swift test --disable-sandbox --scratch-path /private/tmp/intatis-tools-concurrency-suite --filter IntatisToolsTests` 已编译并执行 56 tests / 13 skipped，但在既有 `testWebFetchLocalHTTPAndTruncation` 因当前 sandbox 无法 bind loopback socket 失败，不能作为源码回归判断。真实同时启动多 profile 管理仍为 UNKNOWN。
- **API/tool 稳定性目标未完成**：当前第一批覆盖更清楚的 provider/transport/SSE/tool failure 反馈、provider endpoint URL 网络前预校验、image/transcription 2xx 异常响应结构归一化、tool-call delta 容错归一、非首个 choice 的 Chat content / tool_calls / `finish_reason` 兼容、`finish_reason` / `[DONE]` 双完成信号兼容和 finish 后 usage 保留、缺 completion marker 的流式 EOF 错误、`tool_calls` / 旧式 `function_call` / 错误 `stop` 结束态下缺完整工具调用时的显式兼容错误、多 choice 中工具调用 finish reason 优先保留、usage chunk 字段级合并与 Agent 工具循环跨请求累计、工具参数执行前 JSON object / required 字段 / 基础类型 / 数字范围 / 字符串长度 / `additionalProperties:false` 未知字段校验与无参工具空参数兼容、共享 provider health check（chat/agent 均请求 usage）、首字节前流式 retry / 非流式 retry+timeout、`Retry-After` / rate-limit reset header 解析（含数字秒、HTTP 日期和 duration 字符串）、Chat/Code partial stream stopped 投影说明，以及 Chat 错误/失败工具结果的投影层恢复建议；尚未完成真实 provider mid-stream 行为矩阵、跨 provider 真实矩阵、GUI permission history 与完整恢复 UI；Cowork durable replay/requeue 已有本地回归覆盖，真实长任务恢复仍待真机验证。
- 已补充 provider 层非空 tool-call arguments 完整 JSON 校验，但这仍只覆盖本地 fake stream；真实 provider 在中途断流、代理缓冲和多工具并发参数碎片上的行为矩阵仍是 UNKNOWN。
- v0.16 文档/媒体工具理论代码完成并通过本地构建/测试；由于未接入真机真实 key、真实 CLI 后端样本矩阵和专用生图服务，端到端质量仍需人工验证。
- v0.16 网络/浏览器工具理论代码完成并通过 focused 测试、Edge/CDP smoke 和 headed handoff smoke；按本 session 用户最新口径（理论代码完成即可，真机/真实矩阵缺口可转后续验证项）可将 v0.16 网络/浏览器工具目标标记完成。真实 Playwright/Chrome/Chromium、第三方站点登录、社交媒体/复杂网站、真实第三方网站下载/上传/表单提交、长期 profile 清理/污染和真实同时启动多 profile 管理仍需人工验证。

## 风险

- **MCP 环境认证边界**：当前源码、确定性测试、official/extended conformance、三个 macOS/iOS scheme 的未签名构建和双架构 musl 静态交叉构建均不能替代真实发行环境。匹配架构 Linux 上的 CLI 启动、bwrap/seccomp/ptrace、DNS/TLS/HTTP/OAuth/stdio 和 descendant cleanup 尚未执行；macOS SwiftPM unsigned host 无法证明 data-protection Keychain CRUD，需由签名 App 验证。当前受限宿主不能绑定 loopback 的场景只允许 exact skip，不能记作产品通过或失败。
- **MCP 真实互操作与发行缺口**：尚未完成用户实际选择的第三方 stdio/HTTP servers、真实 OAuth authorization server/account/scope-step-up、proxy/TLS enterprise policy与长时间断线重连矩阵；也未完成 Developer ID archive 的签名、Hardened Runtime/entitlement 最终读取、公证、最终 bundle/link inventory 和可复现发行认证。现有 23+3 conformance 与本地 fixtures 证明冻结协议合同，不应外推为“全部第三方 server 已认证”。
- **Cowork 真实运行矩阵缺口**：root AgentInvocation、WorkTask DAG、GoalVerifier、并发、恢复、取消/超时、重试、mailbox、lease 与 scoped context 已有 deterministic/fake-provider/持久化回归；真实 provider 中途断流、长耗时工具的协作取消、Goal 跨多 ContinuationRun、App 被系统终止后 host continuation，以及多 agent 长 Goal 的真机 GUI/CLI E2E 仍为 UNKNOWN。
- **真机验证缺口**：大量能力有测试但真机端到端状态 UNKNOWN。
- **provider catalog 真实互操作缺口**：多 provider/model 设置与 macOS 高级 JSON/JSONC 配置已构建通过，但 OpenAI / OpenRouter / Ollama / vLLM / DeepSeek 等真实 base URL + chat endpoint + key + model id 的手动矩阵验证仍是 UNKNOWN；旧 direct `providers` 数组 schema 继续兼容读取，新 Intatis config 模板使用 OpenCode-compatible 顶层 `enabled_providers` + `model` + `provider` map，但默认文件始终是 Intatis-owned `intatis.json/jsonc`，不会自动读取 `opencode.json` 或用户现有 OpenCode 全局 config。当前只保证 OpenAI-compatible HTTP/SSE provider；非 OpenAI-compatible provider 配置可被解析但不代表线协议已支持。
- **per-agent inference 真实矩阵与路由授权缺口**：exact revision、trust/egress 复核、严格恢复、精确继承、host-approved explicit selection、catalog/admission TOCTOU 收口、GUI 本地 admission 与执行 readiness 解耦、CLI 显式 startup/data-plane gate、unresolved-worker invocation isolation、idle-only durable rebind、CLI 多 route/model/variant + exact credential reference/explicit restore-main/selection fail-closed、macOS opaque durable variant ID 与安全投影已有本地实现和测试覆盖；真实同 session 多 endpoint/credential/model/effort 并发、长期恢复、credential rotation 与 GUI/CLI 网络 E2E 仍为 UNKNOWN。当前没有独立 `InferenceRouteLease` 或跨 trust-domain 专用审批，app compiler 也未提供完整 model capability metadata；不能把 host-approved catalog + 现有 permission target snapshot 宣称为这些能力。
- **错误反馈仍需真实 endpoint 验证**：本地 fake stream/http tests 可覆盖状态码、provider error payload、HTTP 非 2xx HTML 代理错误页 preview、malformed SSE、非 HTTP provider endpoint 网络前拒绝、HTTP 2xx 但 image/transcription 响应结构不匹配、tool-call 缺失/字符串 index 与 JSON arguments、截断/非法 tool-call arguments、非首个 choice 的 content/tool_calls/finish_reason、多 choice 中 `tool_calls` finish reason 优先、`tool_calls` 结束但缺 tool name、tool-call delta 后错误 `stop` 结束态、旧式 `function_call` 结束态、split usage chunk 合并、Agent 多请求 usage 累计、数字秒/HTTP 日期/duration-style rate-limit reset header，以及坏 JSON / 非对象 / 缺 required 字段 / 基础类型错误 / 数值越界 / 字符串长度违规 / 未知字段工具参数的执行前拒绝；真实 provider 的限流格式、代理错误页、长连接中断、usage 缺失/重复/累计语义和更多 tool-call delta 差异仍需人工矩阵验证。
- **配置文件密钥风险**：Intatis-owned OpenCode-compatible `options.apiKey` 与 auth JSON 可保存 OpenCode-style 明文、`{env:NAME}` 或 `{file:path}`；macOS 设置页会按用户主动输入把 key 写入可编辑 provider JSON，iOS auth JSON 会尝试设置为 `0600`。若用户把 secret 写入普通 JSON 文件，应由用户自行管理文件权限与同步/备份风险，Agent 不得读取或打印这些文件内容。
- **自动权限审查真实模型风险**：`@permission-reviewer` 现在由 GUI/CLI Cowork session 默认创建，测试覆盖本地 fake provider 的 allow/deny、timeout、cancel、malformed、provider error、soft budget、durable failure、generation retirement 与 late result。2026-07-31 已用现有凭据对 `openai/gpt-5.6-luna` 的 exact agent/tool-calling route 完成一次无工具短提示 smoke，并完成一次真实 `PermissionReviewControlPlane` provider factory → stream → verdict parse → durable requested/settled smoke；两次请求都证明 `require_parameters=true` 下省略 synthetic `temperature`/output ceiling 可以成功，后一次没有执行被审查工具。这仍只是一条真实 verdict 样本，不证明长期误判率、长尾延迟、启动失败和远端 cancel 行为，后者仍需人工验证。自动模式不再回退原 `PermissionResponder`：`ask_user`、不可解析输出或 provider error 只拒绝当前调用；因此真实模型质量差时可能增加安全拒绝，但不会把 scheduler 卡入隐式人工等待。Phase B 只保证符合 `ToolCallingProvider.stream` request-owned/nonblocking/termination-propagating 契约的 adapter；shipped OpenAI/URLSession 路径符合本地 ownership，任意同步永久阻塞的第三方实现仍需专用 transport，不能由 `Task.detached` 冒充隔离。
- **Phase C taxonomy 的作用域**：permission、tool call 与 turn terminal 已有 typed outcome/failure source，但 submission admission 和部分 setup failure 的 `OrchestratorSendResult` 仍主要携带有界字符串。不得把 Phase C 误写为全系统所有错误均已结构化，也不得用这些剩余字符串决定权限扩大、sandbox retry 或副作用重放。
- **Intatis 与 Councis 仓关系**：二仓共享 ARCHITECTURE.md 与 Packages 结构，关系未明示（Councis 是 Intatis CLI 原型分支？独立产品？）。`UNKNOWN`。
- **开源 provenance 覆盖**：Intatis 已从严格 clean-room 政策切换为允许合规选择性复用；`NOTICE.md` 与 `docs/OPEN_SOURCE_REUSE.md` 只约束当前 Intatis 仓。Councis 若复用 Intatis 模块或未来上游源码，其 NOTICE/provenance 是否同步仍未明示，`UNKNOWN`。

## 工作区状态

- 2026-07-23 最新 UI 小改：macOS Chat/Code/Cowork composer 的模型选择按钮关闭态统一为模型名 + 原生下拉指示，不再显示 CPU/芯片图标、provider 前缀或 variant/reasoning detail；弹出菜单内部的 provider 分组、variant 明细与 exact selection callback 保持不变。Cowork 在窄窗口或用户隐藏 inspector 时不再渲染 Goal/Tasks 顶部副本，宽屏可见 inspector 及其 durable Goal/Tasks actions 保持不变。Swift parse、`IntatisSharedUI` build、`CoworkInferencePresentationTests` 4/4、`PerAgentInferenceProfileTests` 20/20、XcodeGen、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 均通过；完整 `IntatisSharedUITests` 尝试在完成测试 bundle 构建后于有界等待内没有产出 test-case 结果，已中止，不能计为通过或失败。遵守 renderer NO-GO，未启动 App/fixture；979/980pt、手动隐藏 inspector、长模型名及 Light/Dark 的实际像素仍为 `UNKNOWN`。

v0.16 本地工作区已有 GUI provider/model catalog、macOS 系统 split-view sidebar 内的 `Intatis` 标题 + 带图标的竖向三模式导航 + mode-specific `Recent` history + 30×30 New `+` + 底部 Settings、session display-name header、两排 composer（40pt、关闭态仅模型名的 model/profile glass 菜单左 + usage 右；已有 action 左 + 输入 + 可选 stop/Send 右）、第二排 40pt 统一原生圆形控件与底边对齐、Chat/Code 底部 provider/model/variant 切换菜单、Cowork 底部“下一次 `@main`”exact model/profile 选择菜单、Code/Cowork 原生结构化 inspector、Main-led Cowork project settings（per-session workspace/model/profile/token-budget metadata）、新 Cowork session 主 workspace 绑定与 `@main` bootstrap、默认用户指令路由到 `@main`、`@main` 工具驱动的子 agent spawn/delegate/remove、显式 `canCoordinate` 下级 coordinator、Project Settings sheet 新增/移除项目目录 metadata与异常恢复入口、Cowork 宽屏 permission-first Liquid Glass inspector 内置顶的权限审查及 `Agents` / durable `Goal` / durable `Tasks`（不再显示 Git；窄屏只为 pending permission 保留可操作兜底，且不复制 Goal/Tasks）、Chat/Code/Cowork 对话行 row-level leading/trailing alignment 与窄窗口响应式宽度计算、正常 assistant/agent 回复无外层卡片、用户/失败/结构化内容保留 Material、Code/Cowork 紧凑 session header、Cowork 无常驻 reviewer 顶部横幅、macOS 高级 JSON/JSONC provider 配置、Open Intatis Config、auth JSON/Intatis-owned OpenCode-compatible config/env/file secret 加载、Chat/Code/Cowork session/history 分离与恢复、Chat/Code legacy Goal 标签、Cowork durable `/goal`、GUI token/耗时统计、API/tool/provider 错误反馈与恢复建议、文档/媒体/网络/浏览器工具、Git control，以及 GUI/CLI Cowork 自动权限审查。Cowork 底部菜单直接消费现有 catalog reconcile 产出的 secret-free profile options；忙时仍可暂存，选择本身不改 live agent，Send 时冻结进当前 immutable submission，FIFO 到该提交的执行边界后才把仅 `@main` 的 host rebind 与本次 root admission 原子持久化。新式 main/Goal Send 缺 exact binding 会保留草稿并 fail closed，durable Goal continuation 继续沿用 Goal Send 的 binding。它不改 Chat/Code 的全局选择、不改 future-agent default，也不重绑既有 worker、当前任务或控制面 agent。本轮没有修改字体、权限、EventLog/schema 或平台边界；最终状态和验证以 `git status --short` 与本轮最终报告为准。

2026-07-16 工作区新增 per-agent inference profile 第一阶段：Core/Protocol exact IDs 与 binding、Providers immutable catalog/store/exact resolver、Cowork strict invocation/spawn/delegate/rebind、macOS/CLI catalog 接入与 SharedUI 安全投影均已落地；后续安全收口加入 Cowork durable options 显式 schema、safe route/trust/egress exact 校验、catalog update/admission lock + resolver suspension 后重检、AgentLoop durable prepare 前 execution revalidation、所有 OpenAI-compatible Chat/Agent request 的单候选强制，以及 CLI 多 route/model/variant 与 exact credential references。终审追加普通 diagnostic URL redaction、HTTP 30x no-follow、non-empty CLI missing-main 显式 restore、modern CLI model/reasoning selection fail-closed、GUI/CLI main/control-plane-only startup gate + ordinary unresolved-worker invocation isolation、macOS opaque durable variant ID，以及 ordinary attach review-await / bootstrap admission-wait exact revalidation。新增 focused tests 覆盖协议兼容、catalog/store/resolver（含 32 个独立 reconciler 并发 revision allocation 与 sidecar lock 完整性）、两 agent 独立解析、busy/idle rebind、attach/bootstrap 与 spawn/rebind TOCTOU、UI 脱敏；CLI offline self-test 覆盖两 route/model、variant overlay、旧 revision 与 credential isolation。在终审追加项前，本轮基线为 per-agent focused 62/62、CLI `intatis selftest`、全量 SwiftPM 734 tests / 14 skipped / 0 failures、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 通过；当时 Computer Use 验证旧 session unresolved `@main` fail-closed、Phase A 前的 composer/Send 禁用、Project future default 与逐 agent `Legacy`/Rebind menu，未保存 rebind、未请求 provider。终审追加项的最终复跑与 Computer Use 结果以本轮总体验证报告为准；真实多上游网络路由仍为 UNKNOWN。

2026-07-16 per-agent inference profile 最终收口又把 reviewed delegation 的 authorization、catalog snapshot、caller leases、target exact binding/model/workspace/fingerprint 贯穿到 Mediator/resolve await 后的最终 admission lock；reservation 阻止并发 rebind，`create_proposed` 使用同一 authorization 完成 spawn 前后复核并在 admission 失败时回滚。最终独立审计无 P0/P1；PerAgent 20/20、AgentInvocationNonRecursive 11/11、相关 delegation/reliability/WorkTask 53/53，完整 SwiftPM 747 tests / 14 skipped / 0 failures，CLI selftest、macOS Debug 与 iOS Simulator Debug build 均成功。Computer Use 重启最新 macOS 产物后再次确认旧 session unresolved `@main` fail closed、Phase A 前的 composer/Send disabled、Project future default + `@main Legacy` + host-approved Rebind menu；未保存、未发送、未请求真实 provider。仅 OpenAI-compatible wire、真实多上游 E2E、独立 inference route lease/跨 trust-domain 专用审批与完整 capability metadata 仍为后续边界。

本轮新增 Cowork agent 生命周期闭环：`TaskCompletedPayload` / `TaskFailedPayload` 追加可选 `TaskReportPayload`，`CoworkProjection` 保存 report summary 与 tool-spawned owner；`delegate_task` 的 tool observation 变成 mediated Task Report，`ask_agent` 仍返回直接答案；Orchestrator 会在 task-scoped tool-spawned agent idle 后自动 detach，并保留手动 attach 的 agent。验证：`xcrun xctest -XCTest AgentInvocationNonRecursiveTests .build/debug/IntatisPackageTests.xctest` 通过 5 tests；`xcrun xctest -XCTest SpawnAgentPermissionTests .build/debug/IntatisPackageTests.xctest` 通过 6 tests；`swift build` 通过。`swift test --filter AgentInvocationNonRecursiveTests` 在 SwiftPM 外层进程测试完成后未及时退出，改用 XCTest bundle 取得确定退出码。

最新 Cowork agent 机制改进：`ContextBundle` 增加 metadata-only 的 `taskGroupEvents`，worker prompt 现在能看到当前/父/兄弟/子/related task 的任务 ID、状态、agent 与关系，但不会投影 sibling objective、expected deliverable、tool args、私有 workspace path 或 result/report detail；`list_agents` 输出扩展为 name/model/lease role/compact task state/folder，便于 coordinator 读取共享任务状态且不暴露任务内容；`spawn_agent` 创建但尚未承接 task 的 team member 不再被 scheduler drain 立即自动回收，只有承接过 task 且 idle 的 tool-spawned agent 才自动 detach。验证：`swift test --filter ContextProjectionTests` 通过 4 tests；`swift test --filter SchedulerMailboxTests` 通过 7 tests；`swift test` 通过 336 tests、13 skipped、0 failures。sandbox 内 SwiftPM manifest 编译仍因用户级 clang/Swift module cache 不可写失败，本轮 SwiftPM 测试均按权限规则在 sandbox 外重跑；真实 GUI/provider/team 长任务验证仍 UNKNOWN。

2026-07-12 Cowork 最小闭环升级验证仍是旧六事件 bootstrap 的历史证据；其 `seq 0...5` / 6 events 合同已被 2026-07-19 Phase S 的 settings-first 七事件合同取代，不能再作为当前 fresh-session schema。旧记录当时确认了 reviewer enabled、`2 agents · 0 running` 与未发送 composer 输入；当前权威 Computer Use 结果见上方 Phase S 段落。真实 DeepSeek/OpenRouter 多工具 E2E 仍为 UNKNOWN；确定性 fake-provider 继续覆盖 main 委派、自动创建 worker、task admission 失败后的 worker 回滚、worker tool result、TaskReport、main synthesis 与 root terminal。

最新新增 v0.16 Agent 网络/浏览器工具：`web_fetch`、`browser_diagnostics`、`browser_profiles`、`browser_profile_delete`、`browser_history`、`browser_navigate`、`browser_snapshot`、`browser_handoff`、`browser_reload`、`browser_back`、`browser_forward`、`browser_click`、`browser_type`、`browser_submit`、`browser_select_option`、`browser_press_key`、`browser_scroll`、`browser_wait`、`browser_screenshot`、`browser_upload_file`、`browser_download`、`browser_downloads`、`browser_search` 已进入标准工具 registry 和 Cowork coordinator capability lease；worker 默认不暴露 `browse_web`。浏览器工具优先通过 Playwright persistent context 使用 Chromium/Chrome/Edge 后端，Playwright 不可用时通过 Node.js 内置 `WebSocket` + Chrome DevTools Protocol fallback 到已安装 Chrome/Edge/Chromium，profile/state/history/downloads 保存在 workspace `.intatis/browser`，不写 OS Keychain；`browser_handoff` 打开有界 headed persistent profile 供用户手动登录/接管，超时后回写 state/history 并返回页面快照；页面快照和动作结果会返回按钮、输入框、下拉框等交互控件的 role/name/selector/options 摘要，帮助下一步定位，并会在打开新 tab/window 时跟随到最终页面；同时避免打印 cookies/localStorage/profile 数据库、密码/token 或当前文本输入框 value；`browser_profiles` 只列 profile 名称、当前 URL/title、state/history/download 计数、目录统计和 active/lock runtime marker 存在性，不读取 profile 数据库、marker 内容或下载内容；`browser_profile_delete` 删除前如发现 runtime marker 只输出概括性提示，不列 marker 文件名或内容；`browser_history` 只暴露 history metadata，`browser_back` / `browser_forward` 使用 `state/<profile>.json` 的 `navigationStack` / `navigationIndex` 选择目标 URL 并在同一 profile 临界区内用真实 profile 打开页面，`browser_screenshot` 只写工作区 PNG，`browser_upload_file` 只能引用 workspace 内文件，`browser_download` 只写 `.intatis/browser/downloads/<profile>` 并返回 changedFiles，`browser_downloads` 只列下载 metadata，`browser_type` observation 遮蔽本次输入值并拒绝疑似密码/2FA/token/API key 输入目标（Swift 工具入口 + Playwright/CDP DOM guard），`browser_submit` 支持当前或目标表单提交，`browser_select_option` 支持 value/label/index 下拉选择，`browser_press_key` 支持目标 locator 或当前焦点按键/快捷键，`browser_scroll` 支持页面/元素滚动，`browser_wait` 支持 passive wait 或 selector/text/role 状态等待；`browser_reload` 刷新当前 profile 的 state URL。Playwright wrapper 与 CDP fallback 已增加命令级 watchdog，且同一进程内同一 workspace profile 命令按 profile 路径串行化，不同 profile 仍可并行；CDP fallback 还包含 send/close/process 有界超时，并用真实鼠标事件触发 click/download，降低真实浏览器退出卡死和非用户手势失败风险。`DeterministicPolicyGate` 已修正 exec+network 工具的检查顺序，确保 shell-disabled/read_only 先 hard deny，再处理网络审批。此前 v0.16 文档/媒体工具 `read_pdf`、`edit_pdf_pages`、`reconstruct_document_image`、`compile_latex`、`generate_image` 已进入标准工具 registry、Code/Cowork/CLI AgentLoop 和 Cowork capability lease；`generate_image` 通过 provider-backed `ImageGenerationToolService` 写工作区文件。上一轮网络/浏览器工具本地通过基线为 Tools focused 55 tests（12 skipped，新增同 profile 串行化 fake-shell overlap 测试、metadata-only profile inventory、确认保护的 profile 删除、runtime marker 存在性/脱敏输出、打开新页面 observation/state/history、`browser_search` 结果文本/链接/history 和 `browser_submit` payload/history，含交互控件摘要、browser_type 凭据目标拒绝 fake-shell 测试和 web_fetch local HTTP/truncation/non-HTTP URL 测试）/ full SwiftPM 331 tests（12 skipped）/ `swift build` / 真实 Edge-CDP `BrowserNavigateTool` smoke 1 test / 真实 Edge-CDP DuckDuckGo search smoke 1 test / 真实 Edge-CDP profile 持久 cookie+localStorage+history smoke 1 test / 真实 Edge/浏览器 upload-download smoke 1 test / 真实 Edge-CDP local HTTP form-submit smoke 1 test / 真实 Edge-CDP popup/new-page smoke 1 test / 真实 Edge-CDP select+press-key smoke 1 test（此前脱离 sandbox 通过；交互摘要断言重跑被 escalation 审批拒绝）/ 真实 Edge-CDP scroll+wait smoke 1 test（脱离 sandbox）/ 真实 Edge-CDP profile isolation smoke 1 test / 真实 Edge-CDP back-forward smoke 1 test / 真实 Edge-CDP dynamic-feed + online-task smoke 1 test / 真实 Edge-CDP headed handoff smoke 1 test（脱离 sandbox）/ Permission focused 37 tests / AgentKernel focused 22 tests（含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流） / CapabilityLease focused 3 tests / ToolRegistryLease 6 tests / MessageDelegationSplit 8 tests / CoworkEndToEnd 3 tests / Cowork focused 81 tests / IntatisMac + IntatisiOS simulator Xcode Debug build；本轮只新增真实不同 profile 并发启动 opt-in smoke 的编译/默认 skip 验证，尚未取得真实 Edge/CDP 并发启动通过。本机 Node v26.3.0 可用、Microsoft Edge app 存在，Playwright module 当前不可解析且 Google Chrome/Chromium app 未发现，第三方站点登录、社交媒体/复杂网站、真实第三方网站下载/上传/表单提交、真实交互网站矩阵、长期 profile 清理/污染和真实同时启动多 profile 矩阵仍 UNKNOWN；sequential profile isolation 已通过，同进程同 profile 串行化真实浏览器并发矩阵仍待验证。

## 2026-07-12 权限意图与子 Agent admission 修复

- 权限输入已从单一 `SideEffect` 扩展为结构化 `PermissionIntent`：包含 action、resource、metadata、data/control effects、risk 与 replay policy。`AgentLoop` 在 lease check、gate/reviewer、permission request/resolved 与 durable tool execution prepare/settle 中使用同一份 intent；EventLog 字段均为 additive optional，旧 JSONL 继续解码。
- `spawn_agent` 现在以 `agent.spawn` 控制面动作审查，目标目录是 workspace admission resource，不再作为文件 `touchedPaths`，因此不会再显示“permission denied: write to workspace”。外层 spawn 只有一次审批，获准后 Orchestrator 以 durable admission batch 原子建立 child roster/workspace/capability leases，内部不再进入普通 attach 审批。
- child 默认 `requestedAccess=read_only`；显式 `read_write` 才授予 data-plane 写工具，且 read-only issuer 不能向 child 提升为 read-write。`canCoordinate` 与 workspace access 独立：只读 coordinator 仍可使用协调工具但没有 apply-patch 等写能力；read-write worker 可做 Code 工作但没有 spawn/delegate coordinator 能力。task-scoped lease 从 assignee default lease 克隆同一 ceiling，不再用“是否 coordinator”推断读写权。
- agent/task/message/workspace attach 控制面工具已有独立 action/control effect；文件、Git、浏览器、命令工具通过工具 override 或兼容 adapter 产生具体 resource。WorkspaceLease 只作为最大权限 ceiling，不再把“拥有 workspace”误当作“本次调用正在写文件”。子 agent 后续文件/网络/exec 工具调用仍逐次过 PermissionEngine。
- `DeterministicPolicyGate` 对需要模型判断的允许候选返回 `pass`：非 Cowork 可使用唯一 in-engine `ModelPermissionReviewer`；production Cowork 保持该位置为空，把同一请求交给 durable `PermissionReviewControlPlane`，避免双 reviewer。自动控制面只 allow/deny；timeout/cancel/malformed/provider/persistence failure fail closed，旧 fallback execution/race 已删除，soft token budget 行为不变。
- 当前验证：`swift test --filter Permission` 通过 109 tests、0 failures；完整 `swift test` 通过 506 tests、14 skipped、0 failures；最终 IntatisMac macOS Debug Xcode build 通过。真实 provider 对结构化 spawn 审批文案与真机 GUI E2E 仍为 UNKNOWN。

## 2026-07-12 Code/Cowork 模型等待态 UI 修复

- Chat 原有首 token 前的 `ProgressView` 仍保留；Code 与 Cowork 现在通过 SharedUI 的 `IntatisThreadThinkingRow` 共用同样的旋转 `Thinking…` 状态。等待态会进入消息滚动区并参与自动滚动。
- 显示条件不是整个任务生命周期：用户消息后或工具结果后、尚未出现下一段可见模型输出时显示；文字流开始、工具调用已经可见、权限卡阻塞或错误出现时收起。Cowork 还要求存在真实 running task，避免 attach/remove 等管理操作误显示为模型思考。
- 本轮 `swift build`、全量 `swift test`（506 tests、14 skipped、0 failures）与 IntatisMac macOS Debug Xcode build 通过；尚未做真实 provider 延迟下的人工动画/时序观察。

## 2026-07-12 macOS Session 重命名与删除

- Chat / Code / Cowork 的 macOS 侧栏 history row 已提供原生右键 context menu：`Rename…` 打开名称输入 sheet，`Delete…` 使用 destructive action 并再次确认。
- Rename 先把 1–120 字符显示名称作为 `session_settings_updated(changeKind: renamed)` 追加到目标 EventLog，再刷新可重建的 `session.json`；不会修改目录名、`SessionID`、既有 EventLog envelope 或旧 JSONL。旧 metadata 只在没有 canonical rename 事件时作为兼容迁移输入。
- Delete 只允许 `SessionHistoryStore` app-support root 的单个直接子目录，已有 traversal 回归；当前 session 若仍在 Chat/Code/Cowork 执行则禁止删除。空闲的当前 Chat 会先切到其他/新 session，当前 Code/Cowork 会先停止运行时；删除后清理 session-scoped workspace bookmark/path 和 Cowork project settings，但不删除绑定工作区内容。
- 当前验证：Core focused 19 tests、全量 SwiftPM 511 tests（14 skipped、0 failures）及 IntatisMac macOS Debug Xcode build 通过。真实右键菜单、sheet/alert 交互与删除后视觉刷新仍待运行态人工确认。

## 文档与源码冲突

| 冲突位置 | 冲突内容 | 采用源码为准的原因 | 建议 |
|---|---|---|---|
| `codex-report/07_14_26-intatis-task-goal-final-design.md` §7.2 / 验收检查项 vs 最终 Goal verifier 实现 | 报告把 workspace summary 与 WorkTask results/evidence 列为 verifier 输入，并允许普通只读/验证工具；最终源码进一步收紧为严格 no-tools verifier，且 WorkTask evidence 仅是 agent-reported | `GoalVerifierControlPlane.swift` 的独立请求没有工具面；`GoalRuntimeController.swift` 只从同一 Goal 的 durable 成功 allowlisted tool settlement 派生 host-bound `validationEvidence`，从而避免 agent 自报 evidence 直接证明 Goal 完成 | 以当前源码与回归测试的安全收紧为准；后续若扩大 verifier 输入或工具面，必须重新威胁建模并保持 EventLog/权限边界 |
| 较早的 `docs/COWORK_*` 设计/状态记录 vs 当前实现 | 旧记录可能仍把 root task、scheduler recovery、mailbox、lease enforcement 或 bounded context 标为未实现 | 本轮源码、协议事件与回归测试已经落地这些机制 | 以当前源码及 `docs/COWORK_PRINCIPLES.md` §6 的现行回归点为准；旧文档只作历史参考 |
