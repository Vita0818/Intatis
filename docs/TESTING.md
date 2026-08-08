# TESTING

文档状态：当前验证矩阵
最近核对：2026-08-08
产品基线：v0.40（build 40）

历史测试数量、性能数字和事故复验保留在 Git 历史及 dated reports；它们不能替代当前
working tree 的验证。这里只记录现行命令、release gate 和最近一次真实结果。

## 环境与产品边界

- 当前 Apple 构建环境：Xcode 27 / Swift 6.x / XcodeGen。
- macOS 默认只验证 Developer ID/direct-distribution `IntatisMac`。
- `IntatisMacAppStore` 是 legacy target，除非用户明确点名，否则不构建、不修复，也不作为
  release gate。
- iOS 验证只覆盖 Chat 子集，不得链接 Tools、Permission、AgentKernel、Cowork 或 MCP。
- SwiftPM 测试中的 sandbox、managed terminal Seatbelt、Linux bwrap/guard、权限与路径
  围栏仍是产品安全边界，不能因为不做 App Store 而跳过。

## 版本一致性

```sh
xcodegen generate
scripts/check-version-consistency.sh
# 或仅运行同一门槛：make version
```

必须同时满足：

- `project.yml`：`MARKETING_VERSION=0.40`，`CURRENT_PROJECT_VERSION=40`；
- macOS/iOS 参考 Info.plist：`0.40 (40)`；
- 生成的 `Intatis.xcodeproj`：相同版本；
- README、文档索引、CURRENT_STATE 和 PROJECT_MAP：相同当前基线；
- 最终 App bundle：`CFBundleShortVersionString=0.40`、`CFBundleVersion=40`。

旧设计文档、依赖版本、协议 schema 和 dated reports 中的其他 v0.x 不属于该一致性检查。

## SwiftPM 基线

```sh
swift build
swift test
```

外层 managed sandbox 若阻止 nested Seatbelt、process spawn 或 loopback bind，应在允许的真实
host 环境重跑，不能把 sandbox 环境失败直接改写成产品失败，也不能把跳过冒充通过。

高风险改动至少补充对应 focused suite：

```sh
swift test --filter IntatisProvidersTests
swift test --filter IntatisConversationTests
swift test --filter IntatisToolsTests
swift test --filter IntatisPermissionTests
swift test --filter IntatisAgentKernelTests
swift test --filter IntatisCoworkTests
swift test --filter IntatisSharedUITests
```

修改 Cowork automatic permission authorization context 时，至少运行：

```sh
swift test --filter PermissionReviewProtocolTests
swift test --filter PermissionAuthorizationContextReporterTests
swift test --filter PermissionReviewControlPlaneTests
swift test --filter AutomaticPermissionReviewTests
```

必须覆盖 legitimate `continue`/省略指令映射、acting-provider request snapshot 与 `tools: []`、
canonical current user message、earliest-cited→current evidence closure、intervening revoke/scope change、
main/worker projection 隔离、同 assistant batch 多 call 独立报告、usage/no-history、legacy optional decode，
以及 malformed/secret/unknown handle/timeout/cancel/unknown future event/缺 context 的 durable typed deny。
另须证明 hard deny 与 manual flow 不触发 reporter，report 不能改变 exact authorization、gate、capability/
workspace ceiling，reviewer provider 只在完整 host validation 后被调用。

MCP、browser、managed terminal、OAuth、real provider 和设备测试中明确标为 opt-in 的项目，
必须在具备相应 runtime/credential/网络的环境单独执行。

## Apple App 构建

```sh
xcodegen generate

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Release -destination 'platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

构建后读取最终 bundle，而不是静态源码 plist：

```sh
plutil -extract CFBundleShortVersionString raw -o - <App>/Contents/Info.plist
plutil -extract CFBundleVersion raw -o - <App>/Contents/Info.plist
lipo -archs <App>/Contents/MacOS/IntatisMac
```

macOS Release 必须同时包含 `arm64` 和 `x86_64`；iOS 仍须通过 target dependency/link
inventory 证明没有本地 workspace stack。

## Developer ID 直接分发

预检：

```sh
zsh -n scripts/package-macos-release.sh
security find-identity -v -p codesigning
xcrun notarytool --version
```

正式执行：

```sh
INTATIS_NOTARY_PROFILE=<profile> scripts/package-macos-release.sh
```

如果访问 GitHub 必须开启代理/VPN，而 Apple notarization 必须关闭它，则运行：

```sh
INTATIS_PAUSE_BEFORE_NOTARIZATION=1 \
INTATIS_NOTARY_PROFILE=<profile> \
  scripts/package-macos-release.sh
```

保持代理/VPN 开启直到脚本完成依赖解析、构建和 App 签名并显示切换网络提示；随后保持
终端和脚本运行，关闭代理/VPN，再按 Return。脚本在原地循环验证 `notarytool history`，
成功后才提交 App；失败不会丢弃已签名的 staged App，也不要求重新下载依赖。该模式要求
交互式终端，非交互 release job 不得设置 `INTATIS_PAUSE_BEFORE_NOTARIZATION=1`。

上传后终端必须显示 Apple submission ID 和实时状态。默认 wait deadline 是 30 分钟；仍为
`In Progress` 时脚本必须保留 owner-only recovery 目录并打印 exact resume 命令，不能再次
提交同一 App。可用 `INTATIS_NOTARY_TIMEOUT=<正整数>[s|m|h]` 修改单次等待时长。恢复命令为：

```sh
INTATIS_NOTARY_PROFILE=<profile> \
INTATIS_RESUME_RELEASE_DIR=<脚本打印的绝对路径> \
  scripts/package-macos-release.sh
```

恢复测试必须确认：App/DMG submission ID 复用、无第二次 `submit`；repository version 和
recovery App metadata/architecture/signature/entitlements 重新验证；超时、Control-C、TERM、
网络失败和 Invalid 保留 recovery；最终 ZIP/DMG/manifest 全部落盘后才清理 recovery。当前
真实旧运行发生在这套持久恢复机制加入前，不能用它冒充已完成 recovery E2E。

发行脚本必须在输出 `dist/` 前完成：

1. v0.40/build 40 一致性检查；
2. `IntatisMac` universal Release；
3. Developer ID Application + secure timestamp + Hardened Runtime；
4. signed entitlements 不含 App Sandbox；
5. App notarization Accepted、staple/validate、strict codesign、Gatekeeper assessment；
6. 带 `/Applications` 拖放入口的 Developer ID signed DMG；
7. DMG notarization、staple/validate、codesign、Gatekeeper assessment；
8. ZIP/DMG SHA-256 清单。

任一门槛失败都不得发布 ad-hoc、unsigned、未公证或未通过 Gatekeeper 的包。

## 数据、权限与恢复回归

涉及 EventLog、session projection、权限、Cowork、terminal 或生命周期时，必须覆盖：

- 旧 JSONL 仍可解码，`seq` 单调，append/batch first-write/first-terminal 语义不变；
- permission RequestID/FIFO/correlation、manual decline 与 cancel-turn 语义不混淆；
- tool authorization、durable ticket、executor result 和 turn outcome 关联完整；
- current-run close 只向 exact `@main` root 暴露，模型不得提供 identity；in-flight tombstone 必须先挡住
  重入 admission/authorization，RunID first-write claim 必须早于旧 admission wait 与 cleanup/drain 落盘，
  只 drain 同 run、保留 typed source，恢复不得复活 closed run，普通 final 不伪造 claim；
- mailbox ordinary message 不 ACK；information request 只接受一个 exact `inReplyTo` terminal reply；
  information reply receipt 只能用 fresh RequestID + `based_on` 延续同 conversation，不能形成 ACK 环；
- path escape、symlink/hardlink、secret、credential path、workspace lease fail closed；
- 只有持有 coordinator lease 的 Cowork prompt 才主动建立 execution objective、检查并激活明确相关的
  exact Skills、为非简单工作维护最小 WorkTask DAG、在收益成立时尽早委派并继续自己的关键路径，
  最终验证 child report 与结果；普通请求不自动创建 durable Goal，一步两步工作不仪式化 spawn，
  worker、authoritative tool list、lease 与 PermissionEngine 边界不变；
- Cowork coordinator prompt 在 `spawn_agent` 可用时把预知的根外目录或 out-of-workspace denial
  路由为 exact-directory child + `delegate_task`，默认只读、写入显式；Code/worker prompt 不宣称
  coordinator 能力，工具缺失/扩展拒绝只报告 blocker，直接越界仍 fail closed；
- runtime stop 先 drain provider/tool/process，再释放 waiter/subscription/scope；
- Cowork worker 默认无 coordinator tools，reviewer/verifier 不进入普通 scheduler；
- iOS target closure 不出现 Tools/Permission/AgentKernel/Cowork/MCP。

精确不变量见 `docs/DO_NOT_BREAK.md`。

## UI 与可访问性回归

当前至少检查：

- macOS/iOS Light 与 Dark；
- Chat/Code/Cowork session 切换、16-row paging、Earlier/Newer/Latest；
- Cowork 默认查看 `@main`；右侧 ordinary agent 点击后只出现该 agent 内容；
  detach 当前 agent 后它仍留在同一列表、状态图标变为 detached、选择和历史页不跳回 main，
  且所有运行时操作禁用；`@permission-reviewer` 为 status-only；两个窗口选择互不覆盖；切走再
  返回仍恢复各 agent 自己的 Earlier/Newer/Latest boundary；查看 worker 时 composer 仍路由 `@main`；
- long rich response、Markdown/table/code/math 和 plain-safe fallback；
- composer 单行/多行、model menu、usage、Send/Stop；
- Cowork wide rail、narrow permission fallback、Goal/Tasks/Agents；
- wide rail 连续切换 agent、应用失焦/回焦、窗口移动与进入/退出全屏；系统日志中不得出现
  `IntatisThreadViewportFramesPreferenceKey tried to update multiple times per frame`，源码不得恢复
  viewport GeometryReader/PreferenceKey 坐标回写；
- Settings disclosure、provider test、本地诊断 ZIP；
- Dynamic Type、Reduce Transparency、Increase Contrast、VoiceOver 和 clipboard/selection。

截图或 Computer Use 只能证明对应 viewport/appearance 的视觉行为，不能替代 EventLog、
权限、bundle、签名或长时性能验证。

### Cowork agent-thread 性能门禁

Debug-only `CoworkAgentConversationFixtureView` 通过启动参数
`-IntatisCoworkAgentConversationFixture` 使用真实 `CoworkShell`，但不打开 EventLog、provider、
workspace、permission runtime 或 credential。Computer Use 无法传入启动参数时，DEBUG 构建也可用
以 `.CoworkAgentConversationFixture` 结尾的独立 bundle identifier 启动同一 fixture；该入口不进入
Release。固定负载为 8 个 selectable agent × 每个 1,000 rows、4-agent 合计 500 canonical
delta/s（50 ms projection coalescing）、最多 16 visible rows。

专项验收至少执行：

1. `Run 1,000 switches`，确认最终 selection/内容一致且 warning/incident 均为 0；
2. `Run 180s soak`，nominal 10 selected-agent changes/s；记录实际 timed switches；
3. 结束后保持窗口打开并静置到 rich document 恢复，再记录 RSS、`vmmap -summary` 与
   `heap` 中 `NSTextViewSharedData` / `Gestures.GestureNode<()>` 数量；
4. 再手动验证一个 streaming agent、一个静态 agent、Earlier 页，以及切走再返回的 per-agent
   boundary；确认 reviewer 没有 conversation button。

通过条件：全过程 UI 可访问，main-thread warning/incident 为 0；可见 page 始终 ≤16；RSS/physical
footprint 和 native text/gesture objects 不随切换次数线性增长；停止后 rich view 数量回到一个
bounded visible page 的量级。`heap`/`vmmap` 会短暂停顿目标进程，只在自动 soak 完成后采样，
避免把外部采样暂停误计为产品 heartbeat incident。该 offline fixture 只证明 presentation
pipeline，不替代真实 EventLog I/O、provider、VoiceOver、最低支持设备或多小时运行。

## Chat 托管搜索验收矩阵

`docs/CHAT_HOSTED_SEARCH.md` 是当前产品合同。相关业务源码修改至少必须用离线 request fixture
和 Chat integration tests 证明：

- OpenAI Responses request fixture 只生成该 dialect 的 `web_search` + `tool_choice: auto`；
  OpenRouter exact route 明确声明 `hosted_web_search` 时只生成
  `openrouter:web_search` + `tool_choice: auto`，两者不得共用硬编码 tool type。
- `@ai-sdk/openai` 普通 Chat adapter 尚未实现期间，registry 必须在网络前维持既有 config error，
  不能仅凭已有 OpenAI search encoder 跳过普通 adapter gate。
- 当前 Chat route 不支持、未知、adapter 尚未实现，或只有 `responsesEndpoint`/URL/名称 heuristic
  时，发送同一 Chat route 的普通 request，body 不含 hosted-search 字段，且不会先发送失败请求。
- 配置包含任意有效、无效或未知 `web_search_model` / `webSearchModel` 时，runtime 都不得解析或
  调用该 route，不得覆盖当前模型，也不得新增 UI 警告；新生成配置 fixture 不再写入该字段。
- 用户切换 provider/model/variant 后，下一次 Send 只按新的 exact selection 重新规划；不得沿用
  上一 route 的 capability，也不得产生不同 provider/model 的请求。
- 普通与搜索分支都保留 exact model/variant options；`provider.only`、`allow_fallbacks`、
  `require_parameters` 不得被删除或放宽。搜索不支持时只移除搜索字段。
- 模型拥有搜索能力但未调用时正常完成且 citations 为空；实际返回结构化 annotation 时才写
  additive citations，非法 URL、正文猜测来源和空 Sources UI 继续被拒绝。
- typed provider-specific “hosted search unsupported” 在任何有效 payload 前只允许在同一
  provider/model/variant 上一次普通 Chat 重发。任意 404、自由文本匹配、不同 provider/model
  fallback、partial payload 后重放必须被测试拒绝。
- unsupported/unknown 分支不产生 toast、banner、错误卡、状态、提示词或 Settings 项，也不注册/
  调用通用 Intatis search tool、`web_fetch`、`browser_search`、MCP、shell 或本地浏览器。
- macOS/iOS 共用相同 planner 语义；iOS target closure 仍没有 Tools、Permission、AgentKernel、
  Cowork 或 MCP。Chat cancellation、TurnID、EventLog 与旧 citation decode 不因分支改变。

真实 provider smoke 只能作为 adapter fixture 之外的补充，不能用单一厂商成功替代上述 exact
adapter/capability 矩阵。2026-08-05 已新增并通过 provider focused tests，覆盖独立 capability、
当前 route/legacy route ignore、compatible 静默普通 Chat、OpenAI/OpenRouter tool shape、strict
routing options、结构化 unsupported 同路由一次降级、裸 404 拒绝降级、partial payload 后禁止重放
及 citation 安全解析。macOS/iOS app build 与完整回归结果以本文件“最近一次真实结果”为准。

## macOS Chat/Cowork composer 图片附件验收矩阵

涉及 macOS Chat 或 Cowork composer 附件时，至少验证：

- 两者实际组合同一个 paperclip accessory 与 file-import/drop modifier；按钮、导入进度、附件数量
  菜单、逐项移除和 accessibility 文案只允许产品面名称不同，不复制两套交互实现；macOS Chat 不再
  出现独立的提示词生图 action；
- 系统文件选择和 URL drop 支持多选；security-scoped access 成对开启/关闭，文件先保存到当前
  session ArtifactStore，再按 ID、MIME、字节读回一致后才进入 draft；导入失败不污染已有草稿；
- Send 在按钮边界冻结文本和附件 ID；纯附件消息可发送。只有对应 `user_message` 已 durable append
  后才能清除同一份冻结草稿，route/附件解析失败或 append 前取消必须保留草稿；
- `UserMessagePayload.attachments` 只保存 ArtifactID；EventLog、projection、错误和 UI 不得保存或
  显示 base64、bookmark、文件路径。当前轮与后续历史轮都从同一 session ArtifactStore 解析图片，
  不能只在第一次 provider request 传图；
- provider 输入只接受 `image/*`。缺失、不可读或不支持的 artifact 必须产生 typed、可行动且不泄密的
  错误，并在新 `user_message` append 前 fail closed；非图片文件仍可 durable 保存和移除，但不能
  被静默当作图片发送；
- Chat 投影和 macOS/shared user bubble 至少显示附件数量；旧 artifact event、旧缺少 `attachments`
  字段的 JSONL 和纯文本消息继续解码/回放；
- Code 的既有 image action、Agent `generate_image` / `edit_image` 权限链与 iOS Chat tools menu 不得
  被改写；iOS 不得因共享 VM 或 ArtifactStore 注入而出现本地文件/照片附件入口；
- 至少运行共享附件 store/resolver tests、ChatLoop 当前轮+历史轮 rehydration test、完整 SwiftPM
  tests、`IntatisMac` macOS Debug 与 `IntatisiOS` generic Simulator Debug unsigned build。文件选择、
  拖放和真实视觉命中仍需 macOS 手动 smoke 单独记录，不能从单元测试或编译外推。

## 图片工具与 `image_model` 配置验收矩阵

涉及 macOS/modern CLI 图片路由时，至少验证：

- 顶层 canonical `image_model` 的 `<provider>/<model-id>` 精确解析到
  `ResolvedModels.imageGen`，不改变当前 Chat/Code/Cowork inference selection；
- 专用图片 provider 可使用空 `models`，连接仍保留，但不生成 inference profile 或进入模型菜单；
- 图片 model ID 不需要作为推理 model 重复登记；model-facing `generate_image` 与
  `edit_image` schema 都不包含 provider/model 字段；
- 缺少 `image_model` 时 `models.imageGen == nil`，两个工具执行都明确报未配置，不能出现
  `dall-e-3` 或其他 hidden fallback；
- provider wire 继续只接受合法 HTTP(S) Base URL；生成调用 OpenAI-compatible
  `/images/generations`，编辑调用 multipart `/images/edits`，两者都验证
  `data[].b64_json`；
- `edit_image` 必须在任何网络请求前验证输入/输出均位于 workspace、输入是受支持且魔数匹配的
  PNG/JPEG/WebP 普通文件、输入不超过 50 MiB、输入输出不相同且输出扩展名是 `.png`；
- 两个工具的文件写入都经过 permission、workspace lease 与 `PathConfinement`；Cowork
  read-only worker 与 reviewer 不得看到 `edit_image`。当前首版只支持单张输入图，不支持 mask、
  多参考图或原地覆盖。

## 输入栏语音与 `transcription_model` 配置验收矩阵

涉及 macOS Chat/Code/Cowork 或 iOS Chat 语音输入时，至少验证：

- 顶层 canonical `transcription_model` 的 `<provider>/<model-id>` 精确解析到
  `ResolvedModels.transcription`，不改变 Chat/Code/Cowork inference selection；缺字段时为 `nil`，
  不得使用当前 Chat model、`whisper-1` 或其他 hidden fallback；
- 显式 transcription-only provider 可使用空 `models`，连接和 credential reference 仍保留，但不
  进入模型菜单；macOS 高级 JSON/JSONC 和 iOS Files import 均保留同一个 exact route，不新增设置页；
- Chat/Code/Cowork/iOS Chat 的 mic 位于唯一 Send/Stop 左侧：第一次点击开始录音，第二次点击停止
  并转写；其 compact control 必须以显式 40pt 外层 frame + 圆形 `contentShape` 命中屏幕上完整
  圆形按钮，不能退化成只有内部字形可点；结果追加而不是覆盖完成时的当前草稿，空结果不改变
  草稿且永不自动 Send；
- 录音开始前验证 recorded-file runtime 并冻结 registry/route，credential 只在转写边界懒加载；
  compatible/legacy/OpenAI adapter 使用 disk-backed multipart `/audio/transcriptions`，exact OpenRouter
  adapter 使用 JSON-base64 `input_audio` 同 endpoint；不得按 provider 名称或 URL 猜测方言；
- 默认录音必须是 WAV/16 kHz/mono；WAV 为 16-bit little-endian PCM，M4A 兼容设置也不得包含
  `AVEncoderBitRateKey`。临时音频与 upload body 均为 owner-only 随机文件，最多录制 120 秒，读取/
  上传前限制为 25 MiB；空文件、symlink、非普通文件、非法扩展与超限内容在请求前拒绝；
- 成功、失败、取消、VM/runtime shutdown 后均停止 recorder、释放 process-wide microphone lease 并
  删除音频/body；取消或迟到的 TCC callback 不得复活旧 generation；
- 用户 Send 前不得产生 EventLog、ArtifactStore 或 projection 写入；macOS/iOS bundle 均包含
  `NSMicrophoneUsageDescription`，English/简体中文说明可用；
- 不迁入多模型对比、第二设置页、全局快捷键、review/clipboard 或输入法 target；至少运行 draft
  merge、recorder settings、multipart/OpenRouter JSON/config route focused tests、完整 SwiftPM tests、
  `IntatisMac` macOS Debug 与 `IntatisiOS` generic Simulator Debug unsigned build。真实麦克风权限与
  线上 provider smoke 必须单独记录，不能从离线测试或编译外推。

## 最近一次真实结果

2026-08-08 `v0.40 (40)` 版本推进、shipping target 构建与本机开发安装的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.40 (build 40)`；
- `IntatisMac` unsigned universal Release 构建退出 0，最终 bundle 为 `0.40 (40)`，bundle
  identifier 为 `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`；
- `IntatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.40 (40)`；
  两个构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- 安装前使用 `IntatisMac.DeveloperID.entitlements` 对 staging App 完成 ad-hoc Hardened Runtime
  签名；读回 microphone input=true、JIT=false、library validation 未关闭且无 App Sandbox，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已安装上述 `0.40 (40)` 开发构建，无 quarantine xattr；安装后
  可执行文件与 staging 副本的 SHA-256 均为
  `617c5b50a5e20e580c0a5a7d2059bc2337b19e92de66dd0779f8ada2d5a44cbe`。安装前的
  `0.36 (36)` 已移至
  `/Users/vita/.Trash/Intatis-before-install-20260808-163949.app`，可恢复；
- 本轮没有重跑 SwiftPM 单元测试，也没有启动 App 做 UI/真实 provider smoke；紧随其后的
  Cowork permission authorization context 完整测试证据覆盖同一业务源码。未运行 Developer ID
  正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，因此这是本机开发安装证据，不是正式
  release 证据。

2026-08-08 Cowork automatic permission authorization context 修复的直接证据：

- `PermissionReviewProtocolTests`：11 tests / 0 failures；验证 additive optional wrapper、旧事件
  缺字段解码，以及协议没有增加 model-supplied author/latest-user/digest；
- `PermissionAuthorizationContextReporterTests`：7 tests / 0 failures；覆盖 `continue` 语义、同一
  acting provider/model 的 exact request prefix、`tools: []`、canonical evidence closure、worker
  scope 隔离、unknown handle、secret-bearing output、completion marker、timeout、caller cancel 与
  request-owned stream termination；
- `AutomaticPermissionReviewTests`：31 tests / 0 failures；`PermissionReviewControlPlaneTests`：
  40 tests / 0 failures；覆盖合法 report 与 canonical EventLog 原文分栏、缺失/malformed context、
  omitted intervening revocation、unknown future event、每个 tool call 独立 report、hard deny 不调用
  reporter，以及 reviewer provider 前的 typed durable deny；
- `testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer`：1 test / 0 failures；确认 session
  cancel 会 drain 原始 inference、request-owned report 与 reviewer，不会释放 denial 后继续第三次
  inference 或执行文件写入；完整 `IntatisCoworkTests`：346 tests / 0 failures；
- managed sandbox 中第一次完整 `swift test --disable-sandbox` 因外层 Seatbelt 拒绝既有 browser/
  LaTeX/Git/process 子进程启动而失败；在允许真实子进程边界的宿主环境用同一 working tree 重跑后，
  14 个 XCTest target 合计 1727 tests / 19 conditional skips / 0 failures。`swift build
  --disable-sandbox` 与 `git diff --check` 均通过；
- 本次未修改 App/UI、Xcode 工程或平台 target，因此未另跑 macOS/iOS App build；未执行真实
  provider/credential/network smoke，不能从 scripted provider 测试外推线上模型质量。

2026-08-08 Cowork current-run 终态控制与 correlation-scoped mailbox 修复的直接证据：

- 新增 `finish_run` / `stop_run`、host-bound RunController、`continuation_run_close_requested`
  first-write claim、in-flight admission/authorization tombstone、restore/drain fence，以及 information
  request/reply 的 `conversationID` / `basedOn` 协议和 authority-class 窄租约；普通 message/reply
  receipt 均不 ACK，实质追问使用 fresh RequestID；
- run control、mailbox correlation、协议 round-trip、EventLog CAS/projection、tool registry/legacy lease
  migration、prompt、bundled Skill、permission 与 non-replayable mailbox side-effect focused tests 均通过；
  完整 `IntatisCoworkTests` 为 341 tests / 0 failures；完整 `swift test` 退出 0，其中
  `IntatisAgentKernelTests` 175 tests、`IntatisSharedUITests` 141 tests，所有已运行 target 均为
  0 failures；
- `cowork-agent-orchestration` 通过仓内 `quick_validate.py`；`xcodegen generate` 通过；
  `scripts/check-version-consistency.sh` 输出 `Intatis version is consistent: 0.38 (build 38)`；
- `IntatisMac` macOS Debug unsigned build 与 `IntatisiOS` generic Simulator Debug unsigned build
  均退出 0；读回两个最终 bundle 均为 `0.38 (38)`。构建只报告仓库既有的 unused-result /
  deprecated `onChange` warning；
- 按 `computer-use` Skill 通过 Sky 分别尝试按刚构建 App 的绝对路径、bundle ID 启动，并尝试列举
  apps；所有调用都在服务启动层返回 `Sky Computer Use service startup request failed`，因此本轮没有把 UI 启动、真实 provider
  自主调用工具或长时多 agent 会话标为已验证。未安装 App，未运行 Developer ID 正式签名、
  公证、staple、Gatekeeper 或 DMG/ZIP 打包。

2026-08-07 `v0.38 (38)` 版本推进的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.38 (build 38)`；
- `IntatisMac` unsigned universal Release 构建退出码为 0，最终 bundle 为 `0.38 (38)`，
  可执行文件包含 `x86_64 arm64`；
- `IntatisiOS` generic Simulator Debug unsigned build 退出码为 0，最终 bundle 为
  `0.38 (38)`；两个构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- 本轮是版本元数据与当前文档变更，未运行 SwiftPM 单元测试；未安装 v0.38 App，
  `/Applications/Intatis.app` 读回仍为 `0.36 (36)`。也未运行 Developer ID 正式签名、
  公证、staple、Gatekeeper 或 DMG/ZIP 打包。

2026-08-07 Cowork terminal/mailbox reconciliation 修复的直接证据：

- 报告要求的 TaskContract、AgentLoop policy、model history、context projection、CodeProjection、
  MessageBus/delegation、orchestration reliability、WorkTask runtime 与 permission reviewer focused
  tests 均通过；完整 `swift test --skip-build` 最终退出 0，其中 `IntatisCoworkTests` 327 tests、
  `IntatisSharedUITests` 141 tests、`IntatisAgentKernelTests` 175 tests，均为 0 failures。真实
  Git/browser/Keychain 等显式 opt-in host smoke 仍按设计 skipped；
- `xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过，版本一致为 `0.36 (36)`；
  `IntatisMac` macOS Debug、`IntatisiOS` generic Simulator Debug unsigned build 均退出 0；
- `IntatisMac` unsigned universal Release 通过；最终 bundle identifier 为
  `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`。临时 staging App 使用仓库
  Developer ID entitlements 完成 ad-hoc Hardened Runtime 签名，embedded entitlements 为
  audio input=true、JIT=false、library validation 未关闭，`codesign --verify --deep --strict`
  通过；
- `/Applications/Intatis.app` 已替换为该构建，版本、bundle identifier、架构和可执行文件
  SHA-256 均与 staging 产物一致，且没有 `com.apple.quarantine` xattr。旧安装保存在废纸篓
  `Intatis-before-install-20260807-1627.app`，可恢复；新进程的实际可执行路径已核对为
  `/Applications/Intatis.app/Contents/MacOS/IntatisMac`；
- 对截图对应的 `cowork_rqx6cgvb` 事故日志做了只读回放审计：仍为连续 `seq 0...4564`
  （4565 行），冷启动后 mtime 仍为 `2026-08-07 13:09:04 +0800`，没有自动 provider 重跑或
  追加事件。事故链保留 `seq 2873 message_completed`、`2874 model_history_item`、
  `2878 failed turn_outcome`、`2879 task_failed`；新增 projection/history 回归证明前两项会被
  后续 authoritative failure 分别标为未完成和从 provider history 排除；
- 推荐的 Computer Use 已按 skill 通过 `node_repl + @oai/sky` 多次尝试（含 kernel reset 和
  app path/bundle ID 两种目标），均在 Computer Use service startup 阶段失败。fallback
  `screencapture` 被 Screen Recording 拒绝，System Events 也被 Apple Events 权限拒绝，因此本轮
  **没有把失败卡片的真实窗口像素/AX 文本冒充为已验证**；只确认安装包成功启动、进程路径正确、
  冷启动未改写事故日志。此限制不影响上述单元、全量、构建、签名与持久化证据，但运行时视觉
  卡片仍需在具备 Computer Use/Screen Recording 权限的环境补做。

本轮没有运行 Developer ID 正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包；以上是本机
开发安装证据，不是正式 release 证据。遗留 `IntatisMacAppStore` 未构建。

2026-08-07 v0.36 阶段未提交工作树 macOS 本机开发安装的直接证据：

- `xcodegen generate` 与 `scripts/check-version-consistency.sh`：通过，版本一致为 `0.36 (36)`；
- `IntatisMac` unsigned universal Release：通过；最终 bundle identifier 为
  `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`；
- 使用仓库 Developer ID entitlements 对临时 App 完成 ad-hoc Hardened Runtime 签名；embedded
  entitlements 已读回 microphone input=true、JIT=false、library validation 未关闭，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已替换为上述当前工作树构建，版本仍为 `0.36 (36)`，无 quarantine
  xattr；安装后可执行文件与临时验证产物的 SHA-256 一致。旧的同版本 App 已以 timestamped
  `Intatis-before-install-*.app` 移入废纸篓作为可恢复备份；
- 本轮没有运行 Developer ID 正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，也没有自动启动
  App；因此这是本机开发安装证据，不是正式 release 或运行时 UI smoke 证据。

2026-08-07 macOS Chat/Cowork composer 图片附件复用的直接证据：

- `ComposerAttachmentTests`：2 tests / 0 failures；覆盖 security-scoped URL reader、ArtifactStore
  保存/精确 bytes 读回、image provider input 解析，以及非图片文件“本地保留但发送前 typed 拒绝”；
- `testChatLoopPersistsAndRehydratesImageAttachmentsAcrossTurns`：1 test / 0 failures；验证
  `UserMessagePayload.attachments` 只持久化 ArtifactID，并在下一轮把历史图片和当前图片分别恢复到
  provider request；
- 完整 `swift test`：通过（exit 0）；真实 Git/browser/Keychain 等显式 opt-in host smoke 仍按设计
  skipped，构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- `xcodegen generate`：通过；`IntatisMac` macOS Debug unsigned build：通过；`IntatisiOS` generic
  Simulator Debug unsigned build：通过；
- 未执行 macOS 文件选择/拖放/视觉命中手动 smoke，也未执行真实 provider/credential/network 图片
  对话，因此这里只证明共享 UI/runtime 编译、durable attachment/replay 单元回归与 iOS linkage 边界，
  不外推真实 provider 对全部 image MIME 的线上支持。

2026-08-05 `v0.36 (36)` 版本、shipping target 构建与本机安装的直接证据：

- `xcodegen generate`：通过；`scripts/check-version-consistency.sh`：通过并输出
  `Intatis version is consistent: 0.36 (build 36)`；
- `IntatisMac` unsigned universal Release：通过；最终 bundle 为 `0.36 (36)`，可执行文件包含
  `x86_64 arm64`。安装前以仓库 Developer ID entitlements 完成 ad-hoc Hardened Runtime 签名，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已替换为上述 `0.36 (36)` 开发构建，bundle identifier 为
  `com.Vita0818.IntatisMac` 且无 quarantine xattr；旧 `0.35 (35)` 已移入废纸篓作为可恢复备份；
- `IntatisiOS` generic Simulator Debug unsigned build：通过；最终 bundle 为 `0.36 (36)`；
- 本轮没有运行 Developer ID 签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，因此这只是本机
  开发安装证据，不是正式 release 证据。完整离线图片工具测试仍见紧随其后的专项结果。

2026-08-05 `image_model` / `generate_image` / `edit_image` 配置路由的直接证据：

- `CLIProviderAdapterTests`：4 tests / 0 failures；新增用例验证 image-only provider 的空
  `models` 不影响 Chat selection、`image_model` 精确映射到独立 opaque endpoint/model，以及字段
  缺失时无隐藏 fallback；
- `IntatisProvidersMultimodalTests`：17 tests / 0 failures；覆盖 image provider registry、
  `images/generations` JSON、`images/edits` multipart reference、DALL-E 2 的显式 base64 response、
  `b64_json` decode、非法 URL、provider payload error、timeout/retry 与 no-image-model nil route；
- `IntatisToolsTests`：144 tests / 15 skipped / 0 failures；覆盖 `edit_image` schema/registry、单图
  preflight、输入/输出权限资源分离、无副作用拒绝与宿主 service 注入；
- `IntatisAgentKernelTests`：171 tests / 0 failures；其中 provider image service 用例验证编辑调用使用
  configured image model 而非 Chat model，并把结果写回 workspace；
- `CoworkEndToEndTests`、`MessageDelegationSplitTests`、`ToolRegistryLeaseTests`：合计 28 tests /
  0 failures；覆盖 coordinator/read-write worker 的 `generateMedia` 暴露以及 read-only worker 的
  `edit_image` 抑制；
- `IntatisMac` macOS Debug unsigned build：通过；构建和上述离线测试均不需要 API Key；
- 当前尚未执行真实 provider/credential/network 图片生成或编辑 smoke，因此不声称任何具体线上
  模型、provider 方言、size/count/quality 组合或计费路径已通过。首版编辑只支持单张输入图；mask、
  多参考图和原地覆盖仍未实现。

2026-08-05 Flotis 单模型 recorded-file runtime 迁移后的 composer voice /
`transcription_model` 直接证据：

- `ComposerVoiceInputTests`：6 tests / 0 failures；除空草稿、已有草稿、尾部空白和空转写 no-op
  外，精确验证默认 WAV 为 16-bit little-endian PCM，且 WAV/M4A 设置都不注入
  `AVEncoderBitRateKey`；
- `IntatisProvidersMultimodalTests`：22 tests / 0 failures；覆盖 owner-only disk-backed multipart
  WAV、exact OpenRouter JSON-base64 `input_audio`、25 MiB recorded-file runtime、严格 JSON
  `Content-Type`、timeout/retry 与安全错误 payload；原有 modern/iOS importer focused tests 继续验证
  `transcription_model` 精确保留、transcription-only provider 空 `models`、exact route 与无 hidden
  fallback；
- 完整 `swift test`：退出码 0；真实 provider、credential、browser、Keychain 等显式 opt-in 用例仍
  按各自声明跳过，不将其记为真实环境通过；
- `xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过，后者输出
  `Intatis version is consistent: 0.36 (build 36)`；`IntatisMac` macOS Debug unsigned build 与
  `IntatisiOS` generic Simulator Debug unsigned build 均通过，两端只有既有 deprecated `onChange` /
  unused-result 等 warning；
- 最终 macOS/iOS App bundle 都含 `NSMicrophoneUsageDescription` 与 English/简体中文
  `InfoPlist.strings`。macOS Developer ID target 的说明为“turn voice into editable message drafts”；
  shipping entitlements 另含最小 `com.apple.security.device.audio-input=true`，App Sandbox 仍关闭；
  本地 ad-hoc Debug 签名包的 embedded entitlements 已读回该值且
  `codesign --verify --deep --strict` 通过。ad-hoc 不证明正式 Developer ID/Hardened Runtime 或公证；
  遗留 `IntatisMacAppStore` target 未修改、未构建；
- 当前未启动 App、未授予真实麦克风权限，也未以真实 credential/network 调用线上
  `audio/transcriptions`，因此录音设备、具体 provider 方言、模型可用性、计费与运行态像素仍为
  `UNKNOWN`，需要下一步手动 smoke；本轮未执行签名、公证、staple、Gatekeeper 或发行打包。

2026-08-05 Cowork coordinator 主动推进与外部目录恢复提示词的直接证据：

- `ContextProjectionTests`：22 tests / 0 failures；验证 coordinator 会先建立 execution objective、
  检查 bounded Skill catalog、只在用户明确要求持续/跨 run 目标时创建 durable Goal、为非简单工作
  建立最小 WorkTask 图、尽早委派有收益的分支并继续自己的关键路径，同时保留最小 team/lease；也验证
  coordinator 在工具真实可用时
  停止根外直接重试，使用 exact-directory `spawn_agent`、默认 `read_only`、按需
  `read_write`、随后 `delegate_task`，工具/扩展失败则报告 blocker；同一用例验证 worker 与
  Code 默认提示词不宣称 `spawn_agent`；
- `ToolRegistryLeaseTests`：16 tests / 0 failures；验证 Orchestrator 按 coordinator task lease
  生成的真实 provider request 同时含主动推进规则、`spawn_agent` 工具与上述恢复规则，worker lease
  边界不变；
- `IntatisSkillsTests`：29 tests / 0 failures；验证产品内置 `cowork-agent-orchestration` Skill 包含主动
  执行循环，同时继续保留 capability hard gate、最小团队与 exact profile 路由约束；
- `intatis-skill-creator/scripts/quick_validate.py`：`Skill is valid`；目录名/frontmatter、结构、文本安全
  与资源引用校验通过；
- `IntatisAgentKernelTests`：170 tests / 0 failures；`IntatisCoworkTests`：320 tests / 0 failures；
- SwiftPM 测试过程完成受影响源码/CLI package 的 Debug 编译。本次未改 App/UI、协议、权限实现或
  Xcode 工程，未另跑 macOS/iOS app build；也未执行真实模型的外部目录行为 smoke，因此这里只
  证明稳定提示词、工具表面与 lease 集成，不把任一模型一定遵循提示词写成确定性保证。

2026-08-05 Chat 托管搜索路由修订的直接证据：

- `IntatisProvidersTests`：171 tests / 0 failures；覆盖 exact route capability、OpenAI/OpenRouter
  request shape、strict routing options、legacy search route ignore、静默普通 Chat、窄化的同路由
  fallback、partial-response replay guard、两类 citation annotation，以及无效 legacy 搜索字段不
  阻止 Chat/有效 legacy 搜索字段不污染可见模型列表；
- `IntatisConversationTests`：173 tests / 0 failures；
- `IntatisCLITests`：28 tests / 2 opt-in real-provider tests skipped / 0 failures；
- `IntatisSharedUITests`：133 tests / 0 failures；
- `IntatisMac` macOS Debug unsigned build：通过；`IntatisiOS` generic Simulator Debug unsigned
  build：通过。iOS 首次独立依赖解析遇到 GitHub proxy 503，复用已成功解析并缓存的同一
  working-tree dependencies 后构建通过，该网络失败不计为源码失败；
- 未执行真实 provider/credential/network smoke，因此这里只证明离线 wire fixture、planner、
  integration 与两端编译，不声称任何具体厂商当前线上 endpoint 已通过。

2026-08-03 版本校准后的直接证据：

- `xcodegen generate`：通过；
- `scripts/check-version-consistency.sh`：通过，输出 `0.32 (build 32)`；
- `IntatisMac` unsigned universal Release：通过；最终 bundle 为 `0.32 (32)`，可执行文件为
  `x86_64 arm64`。这是代码与元数据验收，不是签名发行产物；
- `IntatisiOS` generic Simulator Debug：通过；最终 bundle 为 `0.32 (32)`；
- 两端构建有既有的 unused-result 与 deprecated `onChange` 警告，无构建错误；
- `swift build`：在允许 Swift/Clang 写入用户缓存的宿主环境通过；受限沙箱内首次尝试因
  module cache 无写权限而未进入源码编译，不计为产品失败；
- release script `zsh -n`：通过；无证书 preflight 按预期在任何正式输出前失败；
- 临时非发行探针：App runtime signing command、XML entitlements、UDZO DMG、DMG signing
  command 和 strict codesign 通过，临时目录已删除；
- `IntatisToolsTests`（外层 sandbox 外）：141 tests / 15 skipped / 0 failures；
- `testSharedSoftTokenBudgetReservesBeforeDispatchAndReportsProviderOverrun` 原始 fixture 已先
  稳定复现为 `requestTooLarge(limit: 800, estimatedInput: 889)`，证明生产 pre-dispatch
  保护正常；测试随后改为使用有充足 prompt 余量的命名预算常量，继续精确验证 provider
  忽略 output ceiling 后超支 1 token 的 soft-budget 语义；
- 修正后的 focused 用例：1 test / 0 failures；`IntatisAgentKernelTests`：169 tests /
  0 failures；
- 完整 `swift test`：通过。真实 browser/Git/provider/credential/network 等显式 opt-in
  用例仍按设计 skipped，不计为已执行的真实环境验证；
- Cowork agent-thread Computer Use：8 × 1,000 rows + 500 delta/s 下，1,000 rapid switches 与
  180 秒 soak（1,486 timed switches）均通过，0 warning / 0 incident；结束后 14 个
  `NSTextViewSharedData`、173 个 `GestureNode`，`vmmap` 62.1 MiB physical / 74.8 MiB peak，
  `ps` RSS 约 156.6 MiB；
- 2026-08-04 historical-roster 增量：`CoworkProjectionRegressionTests` 8/8、
  `CoworkAgentThreadPresentationModelTests` 10/10、`CoworkInferencePresentationTests` 6/6、
  `IntatisConversationTests` 172/172；Computer Use 实测 detach 当前 agent 后保持选择、离开再返回
  仍可读，并在 500 delta/s 下追加完成 1,000 rapid switches，0 warning / 0 incident、16 rows。
  当前 Codex managed sandbox 的完整 suite 只因 `IntatisToolsTests` process/Seatbelt/loopback 限制
  失败；一次完整 `IntatisSharedUITests` target 在 build 后无测试输出并被中止，相关定向用例已独立
  通过；
- 2026-08-04 rail lighting/fixed-geometry 增量：
  `ThreadLayoutTests|CoworkInferencePresentationTests|CoworkAgentThreadPresentationModelTests`
  30/30；IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug unsigned build 通过。
  原生 Light fixture 在同一 1372×768 viewport 中切换 `@main` / `@research`，composer 水平像素
  run 完全一致，rail 两态均为 x=1076…1365；旧 `.regular` glass card 的一次性 QA sample
  为 240/255，新系统 `Glass.clear` sample 为 244/255。该数值只用于同机同窗对照，不是颜色 token。
  8×1,000 rows + 500 delta/s 下再次完成 1,000 rapid switches，0 warning / 0 incident、≤16 rows。
  本次未重跑 180 秒 soak、Dark、Reduce Transparency、Increase Contrast、VoiceOver 或完整
  SwiftPM suite；不得从该 Light fixture 外推这些矩阵。
- 2026-08-04 rail window-stability 第一版的 31/31 与截图数据只保留为历史记录；用户随后仍稳定
  复现跳动，真实 Test session 也记录到 viewport preference 同帧重复更新，因此该结论已作废。
- 第二版 corrective pass（删除 GeometryReader/PreferenceKey 坐标链、改用
  `onScrollVisibilityChange`、拆除 shared glass container）的 85/85、360-cycle host 与当时的 AX/
  视觉结论已经被用户在新构建中的稳定复现推翻，不得继续当作 rail 不跳动的通过证据。当前第三版
  必须额外验证：outer-detail canvas 而非 `threadColumn` 直接拥有 trailing rail；selection 不在 rail
  render snapshot；蓝色 selection child 可独立更新；`Glass.clear` backdrop 是 content-independent
  Equatable view；transaction 同时关闭 animation 与 disablesAnimations。当前
  `ThreadLayoutTests|CoworkInferencePresentationTests|CoworkAgentThreadPresentationModelTests`
  31/31 通过，production-shaped host 包含 360 次交错 selection/mode/inspector/window-size 循环；
  IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug unsigned build 通过。按用户要求不使用
  Computer Use 或截图差分，因此最终几像素光学稳定性保留为用户新构建手动验收项，不能由自动化外推。
- 用户普通终端的 `security find-identity -v -p codesigning` 已报告两个有效 identity，发行
  脚本也已进入真实 Developer ID 签名和 App 上传；Codex 托管沙箱无法读取登录 Keychain，
  因而在沙箱内仍返回 `0 valid identities found`，不能覆盖宿主证据。两次 App submission
  已被 Apple 接收但查询时均为 `In Progress`；尚无 Accepted、staple 或 Gatekeeper 证据。

## Release GO 条件

只有以下条件同时满足才能写 release GO：

- 当前 working tree 相关 tests/builds 通过，已知失败有明确处置；
- 最终 App/ZIP/DMG 元数据为 `0.40 (40)`；
- Developer ID、notarization、staple、codesign、Gatekeeper 全部通过；
- NOTICE/ThirdPartyNotices 和最终 bundle resource/link inventory 一致；
- 关键真实环境矩阵完成，未完成项以明确的风险接受记录处理。
