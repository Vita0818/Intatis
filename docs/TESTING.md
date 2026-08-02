# TESTING

## 当前 macOS 产品验证边界

macOS 默认只验证 Developer ID/direct-distribution `IntatisMac`。不再构建、
修复或以 `IntatisMacAppStore` 作为日常回归、架构验收或 release gate；只有
用户明确点名遗留 target 时才单独运行。完整规则见
`docs/MACOS_DISTRIBUTION.md`。

本文较早 dated 小节中保留的 App Store build、hash、link inventory 和未覆盖
项是当时真实执行记录，不得篡改成“从未发生”，但它们不再是当前测试命令或
待办。App Store 产品约束的取消不影响 SwiftPM 测试中的 sandbox、测试宿主
sandbox、managed terminal Seatbelt、Linux bwrap、权限门或工作区围栏验证。

## 2026-08-02 macOS Settings 渐进披露验证

本轮只调整 macOS Settings 的信息层级；没有改诊断包内容、执行远程上传或发送 provider
请求。执行：

```sh
swiftc -parse Apps/IntatisMac/Sources/IntatisChatScreen.swift
jq empty Apps/SharedResources/Localizable.xcstrings

CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-settings-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-settings-swiftpm-cache \
swift test --disable-sandbox \
  --scratch-path /private/tmp/intatis-diagnostic-export-build \
  --filter ThreadLayoutTests
# passed：10 tests / 0 failures

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-settings-final-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-settings-final-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# both succeeded；仅有仓内既有 warning
```

Computer Use 使用隔离 bundle 对相同 Settings 窗口做改前/改后检查。默认可访问元素约从
62 个降到 33 个；`Connection`、`Models`、`Advanced settings` 均实际展开并确认原控件
仍可达。改前截图位于
`/Users/vita/.codex/visualizations/2026/08/02/019fc095-48a0-7af2-8afd-3db996a76c92/settings-diagnostic-audit/01-before-top.png`
和 `02-before-bottom.png`；最终默认态与 Advanced 展开态分别为同目录
`07-after-final.png`、`08-after-advanced-final.png`。本轮只完成深色模式运行态视觉检查；
浅色模式、Reduce Transparency 与 Increase Contrast 仍为 `UNKNOWN`。

## 2026-08-02 本地诊断日志导出验证

本轮验证 macOS Settings 本地导出；没有实现或测试远程上传，也没有向 provider 发送
请求。执行：

```sh
swift test --scratch-path /private/tmp/intatis-diagnostic-export-build \
  --filter 'IntatisDiagnosticExportTests|IntatisHangDiagnosticsTests'
# passed：20 tests / 0 failures（4 项导出 + 16 项 hang sanitizer）

swift test --scratch-path /private/tmp/intatis-diagnostic-export-build
# exit 0；所有默认启用 suite 通过，opt-in real-browser tests 按预期 skipped

xcodegen generate
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-diagnostic-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# both succeeded；仅有仓内既有 warning；诊断服务仍未进入 iOS target
```

Computer Use 真实验收确认 Settings 最底部出现本地化导出卡片，保存面板可选择目标，
并成功生成 `0600` ZIP。首次包逐项检查包含 manifest、README、15 个 session 的
redacted log、最近 24 小时 unified log、proxy、performance、5 个 hang 与 6 个 crash；
未发现原始会话短语、工具数据、HTTP URL、邮箱、常见 token、`/Users`、`/Volumes`
或临时私人路径。首次 UI 包的两个 warning 仅来自没有 `events.jsonl` 的空 session；
修复后重新构建并生成最终 `0600` ZIP，源码路径现安静跳过这类目录。由于同时运行的
已安装版与 Debug 版具有相同 bundle ID，最终 AX 状态回读不稳定；ZIP 落盘、专项测试、
源码条件和无残留日志采集进程均已分别确认。

## 2026-08-02 Icon Composer Release 构建与正式安装

本轮只验证根目录 `Intatis.icon` 接入唯一发行 target `IntatisMac`，以及真实
`/Applications` 安装；没有构建遗留 `IntatisMacAppStore`。工具版本为 Xcode 27.0
（27A5228h）与 XcodeGen 2.45.4。执行：

```sh
xcodegen generate
# succeeded；project.pbxproj 将 Intatis.icon 识别为 wrapper.icon，且只进入
# IntatisMac Resources；Debug/Release 均使用 app icon name Intatis

xcodebuild -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-icon-release-dd \
  CODE_SIGNING_ALLOWED=NO build
# BUILD SUCCEEDED；仅有仓内既有 warning

security find-identity -v -p codesigning
# 0 valid identities found

codesign --force --deep --sign - --options runtime \
  --entitlements Apps/IntatisMac/IntatisMac.DeveloperID.entitlements \
  /private/tmp/intatis-icon-release-dd/Build/Products/Release/IntatisMac.app

codesign --verify --deep --strict --verbose=4 \
  /private/tmp/intatis-icon-release-dd/Build/Products/Release/IntatisMac.app
# valid on disk；satisfies its Designated Requirement
```

产物检查确认：`Info.plist` 含 `CFBundleIconFile=Intatis` 与
`CFBundleIconName=Intatis`；`Contents/Resources/Intatis.icns` 为有效 macOS icon，
且同目录存在 `Assets.car`；可执行文件为 `arm64 + x86_64` universal。安装时把旧版
完整移动到 `/private/tmp/Intatis.app.before-icon-20260802-1320`，再用 `ditto` 将
新 Release 写入 `/Applications/Intatis.app`。安装后的 executable、`Intatis.icns`
和 `Assets.car` 均与 build 产物 `cmp` 一致，严格 codesign 校验再次通过。

首次检查发现安装前旧实例与 `open -n` 新实例同时存在；两者均通过应用自身的正常
Quit 流程退出，随后用普通 `open /Applications/Intatis.app` 干净重启。最终只存在
一个进程，命令路径和 `lsof` executable 均为
`/Applications/Intatis.app/Contents/MacOS/IntatisMac`，持续运行检查通过。

当前包为 ad-hoc + Hardened Runtime，不是 Developer ID/notarized 发行包；
`spctl --assess --type execute -vv` 在当前 macOS 27 beta 返回 Code Signing subsystem
internal error，因此 Gatekeeper 对外分发验收不能标为通过。图标为用户提供资源；
本轮未独立审计其来源，也未更改依赖或 `NOTICE.md`。

## 2026-08-02 双端 Chat 托管搜索与 Agent 工具搜索

本轮验证 macOS/iOS Chat 的 hosted-search route，以及 Code/Cowork 保持
`browser_search` / `web_fetch` 工具权限边界。构建和 deterministic 测试均不需要
API key；未向真实 provider 发送请求。

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-web-search-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-web-search-swiftpm-cache \
swift test --disable-sandbox \
  --filter 'ChatConfigurationImportTests|IntatisProvidersTests|IntatisConversationTests'
# passed；ChatConfigurationImportTests 7/7，Conversation 160/160，新增 route tests passed

swift test --disable-sandbox --filter \
  'ToolRegistryLeaseTests|MessageDelegationSplitTests|IntatisAgentKernelTests.testAgentLoopRunsBrowserSearchThroughPermissionFlow|IntatisToolsTests.testBrowserSearchReportsResultTextLinksAndHistory'
# passed；ToolRegistryLease 16/16，MessageDelegationSplit 9/9，
# Cowork selected 25/25，Tools 1/1，AgentKernel 1/1

swift test --disable-sandbox --filter \
  'ThreadLayoutTests|MessageRenderingTests|ChatHistoryReplayTests'
# 57 tests / 0 failures

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-web-search-hidden-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-web-search-hidden-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# both succeeded；仅有仓内既有 warning

xcrun simctl install booted \
  /private/tmp/intatis-web-search-hidden-ios-dd/Build/Products/Debug-iphonesimulator/IntatisiOS.app
xcrun simctl launch booted com.Vita0818.Intatis
# iPhone 17e / iOS 27.0 launched
```

Device Hub 实际打开 paperclip 菜单后，截图确认只剩 `Generate image from prompt`；
顶层 AX tree 和本地化资源也不存在 Chat 搜索控件或提示。验收后已收起菜单，但没有
关闭 App、Device Hub 或 Booted simulator，也没有 uninstall/erase 或清理用户配置。
Provider request fixture 另确认透明能力发送 `web_search` 且 `tool_choice == auto`。
真实 Responses provider/model、凭据、网络结果与 citation 点击 E2E 仍为 `UNKNOWN`。

## 2026-08-02 Cowork 自动权限瞬时故障回归

截图对应的真实 Cowork EventLog 只读审计确认，reviewer 的 error-only SSE 502 在旧实现
中因“已收到原始字节”而跳过 provider retry；模型的第二个 exact `task_update` 又被
denial cache 本地拒绝。修复前新增的两条回归均稳定失败：provider 用例直接抛出
`Network connection lost code=502`，AgentLoop 用例只有 1 个 permission request、
0 个 execution prepare 且目标文件不存在。

修复后执行：

```sh
swift test --filter IntatisProvidersToolCallingTests
# 29 tests / 0 failures

swift test --filter AgentLoopPolicyTests
# 33 tests / 0 failures

swift test
# exit 0；所有当前启用 suite 无失败；opt-in browser/Git/Keychain host smokes 按设计 skip

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-automatic-permission-fix-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-automatic-permission-fix-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# both succeeded；仅有仓内既有 warning
```

回归同时证明：error-only retry 使用第二个 transport attempt；接受 partial text 后相同
502 不 retry；typed reviewer provider failure 后 exact retry 使用两个不同 RequestID，
首个失败调用没有 prepare，fresh allow 后只产生一个 prepare/一次文件写入；普通 deny
仍只进入 reviewer 一次并在第三次 exact call 终止；Cowork 最终 unresolved action 文案
只出现一次。没有调用真实 provider，也没有重放或修改用户截图中的 durable task。

## 2026-08-02 Cowork permission-first Liquid Glass rail

本轮只改 Cowork presentation/layout 与共享 permission card 的可选宿主表面；没有改
RequestID/FIFO、responder、EventLog、PermissionEngine、Goal/WorkTask projection 或
Git tool registry。执行结果：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-cowork-rail-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-cowork-rail-swiftpm-cache \
swift build --disable-sandbox --target IntatisSharedUI
# succeeded

CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-cowork-rail-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-cowork-rail-swiftpm-cache \
swift test --disable-sandbox \
  --filter 'ThreadLayoutTests|PermissionProjectionTests|PermissionReviewControlPlaneTests'
# 61 tests / 0 failures（10 + 16 + 35）

xcodegen generate
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-cowork-rail-macos-release-dd \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-cowork-rail-macos-debug-dd \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-cowork-rail-ios-debug-dd \
  CODE_SIGNING_ALLOWED=NO build
# all succeeded；仅有仓内既有 warning
```

Computer Use 只读检查了真实 `Test` Cowork session：Light/Dark 宽屏均为权限结果、
Agents、Tasks 的原生 glass rail，完全没有 Git；Light 窄屏 rail 与占位均消失。当前
durable session 没有 live pending request，因此没有重新触发 provider/tool 来制造
pending；pending rail pinning、窄屏唯一 Material fallback 和 action 语义由同一生产
`PermissionCard` 路径及上述 layout/permission suites 覆盖。没有发送消息、调用
provider、点击 permission action 或修改 session durable state。

Release app 已复制到 `/Applications/Intatis.app`；替换前版本可从
`/private/tmp/Intatis.app.before-cowork-rail-20260802` 恢复。当前机器
`security find-identity -v -p codesigning` 返回 0 个有效 identity，故安装包只做
ad-hoc Hardened Runtime 签名；`codesign --verify --deep --strict` 通过，但 Developer ID、
公证与 Gatekeeper 分发验收仍未完成。视觉截图与成对比较见根 `design-qa.md`。

## 2026-08-01 workspace chrome layout-cycle 回归

原始 crash report 的 main thread 经过
`NSSplitView.layout -> NSHostingView.layout -> ToolbarBridge.preferencesDidChange`，
并在 AppKit update-constraints/layout transaction 中抛出
`NSGenericException`。本轮回归必须同时证明 window toolbar item graph 稳定、
inspector 不以自身压缩后的 child width 决定显隐，以及真实 App 进程没有进入
空闲 CPU/layout loop；只做 build 或打开一次窗口不算通过。

实际执行：

```sh
swift test --disable-sandbox --filter ThreadLayoutTests
# 10 tests / 0 failures；含 360 次 production-shaped NSWindow mode/resize/inspector stress

swift test --disable-sandbox --filter ThreadScrollCoordinatorTests
# 30 tests / 0 failures

swift test --disable-sandbox --filter MessageRenderingTests
# 41 tests / 0 failures

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-toolbar-layout-fix-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/intatis-toolbar-layout-fix-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# both succeeded

xcrun swiftc -parse <touched Swift files>
git diff --check
# both succeeded
```

`ThreadLayoutTests` 的结构门还读取 production source，要求 Code/Cowork 与其
macOS session wrapper 不含 window `.toolbar` 或 nested `.inspector`，并要求
新的 stable-outer-width policy 仍被实际调用。geometry 测试覆盖
-100...2000pt、0.5pt 步进、NaN/±infinity 和 10,000 次相同阈值重复解析。

真实 App 验证使用
`/private/tmp/intatis-toolbar-layout-fix-dd/Build/Products/Debug/IntatisMac.app`。
Computer Use 只读确认 Chat 与 Cowork window toolbar 只暴露系统
`Hide Sidebar`，Cowork 的 MCP/Project/Inspector action 位于内容 header；没有
发送消息或触发 provider。控制器之后拒绝继续 resize/click，因此额外 GUI
模式/尺寸往返由上述真实 `NSWindow` production-view stress 覆盖，不能伪记为
Computer Use 动作。

最新 Debug executable SHA-256 为
`51e037caf850814127a6e26a270b84e16200f08f27876ff9d14dd3b05695fc5b`，承载应用
代码的 `IntatisMac.debug.dylib` SHA-256 为
`92645fed8803f3b15187893962eafbc11bd1beba1bb94372ef88f488c3da1ae0`。PID 80122
由 `/private/tmp/intatis-layout-soak-watchdog.zsh` 监控 200 秒：99 samples、
max RSS 229,376 KiB、max CPU 0.4%、正常存活。结束后的 1 秒 `sample` 中主线程
872/872 samples 位于 `mach_msg2_trap`；指定 Unified Log 布局异常关键词为零，
且 `~/Library/Logs/DiagnosticReports` 没有产生新 `IntatisMac` crash。验证后发送
TERM 正常退出并确认零残留。临时 telemetry/sample 在
`/private/tmp/intatis-layout-soak-80122.tsv` 与
`/private/tmp/intatis-layout-soak-80122.sample.txt`，不属于仓库产物。

该矩阵补上此前 >160 秒 current-container soak 缺口，但原事故在约 1 小时
50 分后发生；在 macOS 27 Beta 上，多小时、多窗口、真实 streaming/permission
review 同时 resize 与 VoiceOver 仍须保留为外部长期验证，不得由本次 200 秒 idle
soak 冒充。

## 2026-07-31 Cowork `task_update` preflight/no-effect 回归

本轮新增以下 focused 覆盖：

- worker 对自己绑定的 `in_progress` WorkTask 提交完整快照时，完全相同的
  title/description/criteria/artifacts/owner/dependencies/priority 归一为 no-op，
  status/result/evidence 正常完成；
- coordinator 真实改变 frozen owner 时，production adapter 返回 typed
  no-effect rejection，EventLog 与内存 WorkTask 均不变；
- EventLog 已 append 后模拟 lost acknowledgement 时，不得误分类为
  `ToolExecutionRejectedWithoutSideEffect`；
- legacy worker snapshot-field 与 manager frozen-contract 悬空 ticket 只有在
  raw args SHA-256、prepared authorization、agent/TaskContract/capability
  lease/run/WorkTask snapshot 全部精确匹配时才补 `failed/not_started`；
  tampered digest 保持 unresolved。

计划命令为：

```sh
swift test --filter WorkTaskRuntimeTests
swift test --filter OrchestrationReliabilityTests
```

当前宿主内第一次运行在 SwiftPM manifest 前因用户级 module cache 不可写失败；
把 Clang/SwiftPM cache 改到 `/private/tmp` 后，SwiftPM 自身的嵌套
`sandbox-exec` 又被外层托管沙箱拒绝。沙箱外执行申请随后因审批服务用量限制
被拒，故本节不能记录为 tests passed。源码仍需在可运行 SwiftPM 的宿主上执行
上述两组 focused tests，并补 `swift build`；本轮只记录后续静态解析与
`git diff --check` 的实际结果。

## 2026-07-31 浏览器执行回归修复验证

权威回归路径是 shipping `BrowserBackendProcessRunner`，不是 fake shell。
本机为 Node.js + Microsoft Edge/CDP fallback；Playwright module 不可解析。

```sh
INTATIS_REAL_BROWSER_SMOKE=1 swift test --disable-sandbox \
  --filter IntatisToolsTests.testRealBrowserBackendSmokeWhenEnabled
# 1 test / 0 failures

INTATIS_REAL_BROWSER_SMOKE=1 swift test --disable-sandbox \
  --filter IntatisToolsTests.testRealBrowserSearchWhenEnabled
INTATIS_REAL_BROWSER_SMOKE=1 swift test --disable-sandbox \
  --filter IntatisToolsTests.testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled
# 2 tests / 0 failures

INTATIS_REAL_BROWSER_SMOKE=1 swift test --disable-sandbox \
  --filter IntatisToolsTests.testRealBrowserUploadDownloadWhenEnabled
# 1 test / 0 failures

INTATIS_REAL_BROWSER_SMOKE=1 swift test --disable-sandbox \
  --filter IntatisToolsTests.testRealCDPBrowserIgnoresStaleDevToolsActivePortWhenEnabled
# 1 test / 0 failures

swift test --disable-sandbox --filter Forged
# browser forged-state/history tests 2 / 0 failures

swift test --disable-sandbox \
  --filter IntatisToolsTests/testCDPNewPageFallbackValidatesReturnedWebSocketEndpointBeforeConnect
# final-source /json/new forged WebSocket behavior: 1 / 0 failures

swift test --disable-sandbox --filter IntatisToolsTests.IntatisToolsTests
# pre-final full run: 97 executed / 15 opt-in skipped / 0 failures
# final-source suite adds the targeted test above; a complete 98-test rerun is pending

swift test --disable-sandbox --filter IntatisAgentKernelTests.testBrowser
# browser search/form/dynamic-feed/profile-delete focused paths: 4 / 0 failures

swift test --disable-sandbox --filter IntatisPermissionTests.testBrowser
# 3 tests / 0 failures

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-browser-regression-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# succeeded
```

除真实 happy path 外，Tools suite 还必须覆盖：custom structured/network runner
不能劫持 production browser lane；read-only、窄 allowed rule、denied pattern 和
workspace root replacement 必须在创建 `.intatis/browser` 或启动进程前失败；
profile/download/state/history 与 upload/screenshot path 必须完整进入 touched
paths；大 stdout/stderr 必须保持 bounded；端口出现前的 browser abort 也必须
回收进程。伪造 `file://` state/history 必须在 backend 0-call 的情况下拒绝；
预置 stale `DevToolsActivePort` 的真实 Edge/CDP smoke 必须连接本代 endpoint；
`/json/new` PUT/GET 返回的 target WebSocket 必须在 `CDPClient` 连接前经过同一
loopback/port gate。真实 Playwright、Chrome/Chromium、headed handoff、多
profile 同时启动仍为 `UNKNOWN`。

## 2026-07-31 Xcode 27 / macOS 27 Beta 兼容验证

当前基线：

```text
macOS 27.0 (26A5388g)
Xcode 27.0 (27A5228h)
Apple Swift 6.4 (swiftlang-6.4.0.27.1)
```

本轮实际执行：

```sh
swift test --disable-sandbox --filter ThreadScrollCoordinatorTests
# 30 tests / 0 failures

swift test --disable-sandbox --filter MessageRenderingTests
# 41 tests / 0 failures

swift test --disable-sandbox --quiet
# 所有 test bundle exit 0 / 0 failures；既有 opt-in environment skips 保留

swift build --disable-sandbox
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-xcode27-compat-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-xcode27-compat-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# both succeeded
```

Xcode 27 下不要用 `--filter IntatisSharedUITests` 作为整 target 的权威命令。
该 filter 会把当前 108 个 selector 一次性传给 `xctest -XCTest`；本轮复现到
runner 主线程长期停在 `XCTWaiter`、工作线程空闲。无过滤完整运行与上面的单
class filters 正常。出现该形态时应有界终止并按 class 分片，不得把 runner
等待记作 App 卡死、测试通过或源码失败。

macOS 原生 hosting tests 必须在 key window attach/display 后让 AppKit 主
run loop 完成首批 SwiftUI transaction；teardown 时先把
`NSHostingView.rootView` 换成空 view、再次 settle，再清空 content view。
这防止 Xcode 27 在仍有 selectable-text/gesture interaction 的 graph 上触发
Apple `Gestures.InvalidTransition` teardown assertion。测试仍须使用
production-shaped `onScrollGeometryChange` 和真实 rich native view，不能用
伪 callback 或 timeout 放行代替。

全新 scratch 的依赖复核若在 clone 前报
`127.0.0.1:1082` connection failure，应先分类为本机 Git HTTPS 代理不可用；
使用已解析的 exact-pinned 本地 checkout 验证，不得修改依赖锁定来绕过。
完整证据见
`codex-report/07_31_26-00_18-xcode-27-beta-compatibility-audit-and-fix.md`。

## 2026-07-28 Code / Cowork replacement-history compaction

修改 model-history wire schema、checkpoint append、projector、compactor、context
policy 或 Code stable-conversation / Cowork stable-`@main` 接线时，至少覆盖
以下聚焦矩阵：

```sh
swift test --disable-sandbox --filter \
  'AgentModelContextPolicyTests|AgentModelHistoryCompactorTests|CodeModelHistoryCompactionTests|ContextProjectionTests|IntatisSkillsTests|SkillMCPDependencyTests|ModelHistoryCompactionAgentLoopTests|ModelHistoryCompactionEventLogTests|ModelHistoryProjectionTests|ModelHistoryProtocolTests|SkillDurableActivationTests|AgentRequestToolSnapshotTests|CLIConfigRuntimeBudgetTests|CLIModelContextMetadataTests'
# 129 tests / 0 skipped / 0 failures
```

2026-07-28 最终分组为：

| Suite | tests |
| --- | ---: |
| `AgentModelContextPolicyTests` | 10 |
| `AgentModelHistoryCompactorTests` | 13 |
| `CodeModelHistoryCompactionTests` | 1 |
| `ContextProjectionTests` | 20 |
| `IntatisSkillsTests` | 19 |
| `SkillMCPDependencyTests` | 9 |
| `ModelHistoryCompactionAgentLoopTests` | 12 |
| `ModelHistoryCompactionEventLogTests` | 9 |
| `ModelHistoryProjectionTests` | 14 |
| `ModelHistoryProtocolTests` | 11 |
| `SkillDurableActivationTests` | 2 |
| `AgentRequestToolSnapshotTests` | 6 |
| `CLIConfigRuntimeBudgetTests` | 2 |
| `CLIModelContextMetadataTests` | 1 |
| **合计** | **129** |

该矩阵覆盖 90/95 policy、20k 上限与 UTF-8 截断、无真实约束时不注入 summary
ceiling、按 usable window/显式预算动态派生上限、压缩后 postcondition、provider 忽略 ceiling 零
checkpoint、typed context overflow、tool-call batch 与 matching outputs 成组
裁剪、Protocol shape/UUIDv7、EventLog per-agent CAS/lineage/generic-append gate/
large-checkpoint WAL、projector provenance/coverage/fresh-loop replay、稳定
Code conversation 与 Cowork `@main` 时机、worker 不压缩，以及 Skill contextual 不进入 real-user
retention。新增 catalog cases 还覆盖 canonical primary window
（`context_window` 优先、缺失时显式 `limit.context` 补位）的 2% token
budget、未知窗口 8,000-character fallback、envelope 不计费、omission/truncation
metrics/warning；MCP cases 覆盖严格 machine metadata、request-owned exact
server + locator assertion pairing、同名 endpoint 变化、无 host fail-closed、machine
metadata 不可由 resource tool 披露，以及 Code/Cowork 首个 request snapshot
复用。availability pairing 与 task-scoped worker cases 使用 trusted
caller-frozen fixture；它们不证明 production MCP connection-set builder 或
真实 server/reconnect。fresh-loop replay 是新建 `AgentLoop` 后复用同一个
`EventLog` 对象，不是 reopen 新实例或 process restart。

最终源码验证：

```sh
swift test --disable-sandbox -q
# 1483 tests / 16 opt-in environment skips / 0 failures

swift build --disable-sandbox
# succeeded

xcodegen generate
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-compaction-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-compaction-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# 当前产品图均 succeeded；macOS 图仍有既有 unused try? 与 Swift 6 actor-isolation
# warnings，均未升级为 build error
```

本分发决策生效前，遗留 `IntatisMacAppStore` 也在同一源码状态构建成功；该
事实只保留为历史 provenance，不再加入上面的默认命令。

Swift 编译器在 managed 外层 sandbox 内无法写
`~/.cache/clang/ModuleCache`，并且完整套件的 Seatbelt、process、Git 与
loopback cases 会被宿主额外限制。因此最终聚焦、全量与构建结果均来自显式允许
脱离该外层 sandbox 的最终源码；不能把沙箱内的 cache denial 或本轮较早源码
状态下 1436 tests / 35 skipped / 45 failures 的环境性诊断冒充最终源码失败，
也不能为了迎合宿主而弱化产品 sandbox。

以上 deterministic fake provider 与进程内 replay 证明结构、顺序和故障边界，
不证明真实 provider 的 tokenizer/usage、summary 质量或 overflow shape，也不
证明真正 process-kill 后恢复、GUI 多次 compact、600 秒 invocation 或长期
soak；未跑时继续标为 `UNKNOWN`。

## Code / Cowork Skill capability

修改 Skill discovery、prompt 角色、snapshot、动态工具、MCP 组合或 Cowork
接线时，至少验证 loader 安全边界、wire role、durable 工具链和每 Agent
workspace 隔离：

```sh
swift test --disable-sandbox --filter IntatisSkillsTests
# IntatisSkillsTests 20 + SkillMCPDependencyTests 9 = 29 tests / 0 failures

swift test --disable-sandbox --filter ContextProjectionTests
# 21 tests / 0 failures

swift test --disable-sandbox --filter SkillMCPDependencyTests
# 9 tests / 0 failures

swift test --disable-sandbox --filter SkillDeveloperRoleTests
# 2 tests / 0 failures

swift test --disable-sandbox --filter SkillDurableActivationTests
# 2 tests / 0 failures

swift test --disable-sandbox \
  --filter IntatisCoworkTests/testEachAgentInvocationBuildsSkillsFromItsOwnWorkspace
# 1 test / 0 failures

swift build --disable-sandbox
swift build --disable-sandbox --product intatis
# both succeeded

swift test --disable-sandbox --quiet
# 1483 tests / 16 opt-in environment skips / 0 failures

xcodegen generate
xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-skill-mac-dd \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-skill-ios-dd \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
# 当前产品图均 succeeded；只有仓内既有 warnings
```

2026-08-02 产品内置 Cowork 调度 Skill 还必须运行：

```sh
python3 .agents/skills/intatis-skill-creator/scripts/quick_validate.py \
  Packages/IntatisSkills/Resources/BundledSkills/cowork-agent-orchestration

swift test --disable-sandbox --filter \
  'IntatisSkillsTests|ContextProjectionTests|PerAgentInferenceProfileTests.testProfileListUsesDeclaredCapabilitiesAndDoesNotGuessMissingMetadata|CLIModelContextMetadataTests'
```

本轮 validator 通过；`IntatisSkillsTests` 20/20、同一 test product 中的
`SkillMCPDependencyTests` 9/9、`ContextProjectionTests` 21/21 均通过。新增回归
证明 bundled root 被 `.standard` discovery 采用、entry 是 system scope、正文可经
exact `activate_skill` 读取、routing reference 可经 `read_skill_resource` 读取，且
只有 coordinator prompt 要求 exact bundled activation，普通 worker 不含该要求。
`swift package --disable-sandbox ... dump-package`、`swift build --disable-sandbox`
与 `swift build --disable-sandbox --product intatis` 通过；首次 fresh scratch 尝试
仅因受限网络代理无法下载既有 `swift-system` dependency，随后使用仓库现有
dependency cache 完成验证。

`xcodegen generate`、Developer ID `IntatisMac` macOS Debug 与 `IntatisiOS`
generic Simulator Debug unsigned build 均通过。macOS `.app` 的
`Intatis_IntatisSkills.bundle` 已逐文件确认包含 `SKILL.md` 和
`references/model-routing.md`；iOS DerivedData 的 `Build/Products` 无任何
`IntatisSkills` 产物。本轮没有 UI 改动，因此未启动模拟器/App；也未运行真实
provider 或多 agent 行为 E2E。

同日 capability/newness/cost/multimodal routing refinement 再次通过 validator；
focused suites 为 `IntatisSkillsTests` 29/29（含 MCP dependency tests）、
`ContextProjectionTests` 21/21、capability-safe profile listing 1/1、CLI JSON exact
profile capability projection 1/1。`IntatisMac` generic macOS 与 `IntatisiOS`
generic Simulator unsigned Debug builds 均 exit 0，只有仓内既有 warnings；macOS
最终 `.app` bundle 已确认包含更新后的 “Mandatory multimodal companion” 与 dated
routing reference，iOS products 仍无 `IntatisSkills`。本次是 Cowork backend/Skill
改动，未启动 GUI 或 iOS 模拟器；iOS 本身无 Cowork target，不能用 iOS 模拟器验收
该调度规则。真实 provider + text-only main + vision child 的 attachment handoff E2E
尚未运行，且当前通用 child attachment-bytes 传递仍未闭环。

同日正式 recommendation matrix 扩展还要求 bundled resource 回归断言同时覆盖
`Formal recommendation matrix`、11 家 provider 名称、Preview guard 与
“matrix cannot add a profile”边界。实际运行 Skill validator 通过；
`swift test --disable-sandbox --filter IntatisSkillsTests` 命中并通过
`IntatisSkillsTests` 20/20 与 `SkillMCPDependencyTests` 9/9，共 29/29；Developer ID
`IntatisMac` generic macOS unsigned Debug build 成功。最终 `.app` 中的
`Intatis_IntatisSkills.bundle` 已直接检查，确认包含正式矩阵、11 家 provider、
`Kimi K3`、`GLM-5.2`、`MiniMax M3` 与 `Qwen3.8-Max-Preview`。该变更只涉及 bundled
Skill/resource、测试断言与文档，不新增 JSON schema、UI 或 iOS linkage；因此没有
启动 App/iOS 模拟器，也没有发送 11 家真实 provider 请求。

同日 owner correction 的 bundled resource 回归还必须证明：Meta 使用
`Muse Spark 1.1` 且不再出现 `Llama 4 Scout`；Google 明确包含
`Gemini 3.1 Pro Preview`；DeepSeek 的推荐名称必须完整写成
`DeepSeek-V4-Flash-0731`，并明确区分它与 wire alias `deepseek-v4-flash`，同时声明其
为 V4-Pro 的当前上位 agent 推荐；Qwen 包含 `Qwen3.6-Flash` 且不存在
`Qwen3.7-Flash`。这些名称断言不替代 runtime exact profile/capability/lifecycle
检查。

实际重跑结果：Skill validator 通过；`IntatisSkillsTests` 20/20 与同一 test product
中的 `SkillMCPDependencyTests` 9/9，共 29/29；Developer ID `IntatisMac` generic
macOS unsigned Debug build 成功。最终 `.app` bundled resource 的四项正向字符串均
存在，`Llama 4 Scout|Qwen3.7-Flash` 反向搜索无匹配。未启动 GUI/iOS 模拟器，也未
向 Meta、Google、DeepSeek 或 Qwen 发送真实 provider 请求。

随后针对 DeepSeek exact-version spelling 的修正再次通过 Skill validator、
focused bundled-resource test 1/1 与增量 `IntatisMac` generic macOS unsigned Debug
build。最终 `.app` resource 已确认使用完整 `DeepSeek-V4-Flash-0731`，同时保留
wire alias `deepseek-v4-flash` 的说明；泛化表项 `DeepSeek V4` 反向搜索无匹配。

当前 managed 外层 sandbox 下的完整 `swift test --disable-sandbox` 退出 1；单独
复跑失败 target 为 `IntatisToolsTests` 138 tests、15 skipped、45 failures
（33 unexpected）。日志为既有 `sandbox_apply: Operation not permitted`、
`WorkspaceSandboxDeniedError`、loopback bind denial 及其进程/pid/cleanup 级联，
与本轮不依赖 Tools process runner 的 Skill/Context focused suites 分离。不得把
该结果写成 full-suite pass，也不得为迎合宿主而放宽产品 Seatbelt、process 或
network 边界。

项目级 `intatis-skill-creator` 自身使用 Python 标准库，修改其正文、reference
或 helper 时还要运行：

```sh
python3 .agents/skills/intatis-skill-creator/scripts/quick_validate.py \
  .agents/skills/intatis-skill-creator

env PYTHONPYCACHEPREFIX=/private/tmp/intatis-skill-pycache \
  python3 -m py_compile \
  .agents/skills/intatis-skill-creator/scripts/init_skill.py \
  .agents/skills/intatis-skill-creator/scripts/quick_validate.py \
  .agents/skills/intatis-skill-creator/scripts/generate_openai_yaml.py
```

还应在临时目录运行 initializer，验证成功创建、重复目录拒绝，以及未完成
`TODO` skeleton 会被 validator 拒绝。该验证只证明本地 Skill 文件和 helper；
不证明真实 provider 会选择/遵循 Skill，也不证明 GUI、真实 MCP、网络或长时
多 Agent 行为。

2026-07-28 的实际安装验证中，项目 Skill 自校验与三个 helper 的
`py_compile` 均成功；临时目录 initializer 成功创建完整 skeleton，重复目录和
未完成 `TODO` skeleton 均按预期退出 1；将生成的
`agents/openai.yaml` 扩到 17,000 bytes 后，validator 也按预期以独立
16 KiB metadata 上限退出 1。随后
`swift test --disable-sandbox --filter IntatisSkillsTests` 实际匹配并通过
`IntatisSkillsTests` 19/19 与 `SkillMCPDependencyTests` 9/9，共
28 tests / 0 failures。首次受限宿主运行因用户级 Clang ModuleCache 不可写而
在 manifest 编译前失败；允许编译器写正常用户 cache 后同一命令通过，这不是
产品 App Sandbox 结果。

同一历史验证曾构建遗留 `IntatisMacAppStore`；当前不再要求重跑。

在 managed 外层 sandbox 中，完整套件的 process、loopback 与嵌套
`sandbox-exec` tests 可能被宿主拦截；2026-07-27 早期 Skill slice 的首次受限
运行因此结算为 1389 tests / 35 skipped / 45 failures（33 unexpected）。当前
最终源码在允许执行产品自身 sandbox/process tests 的环境下是上面的
1470 / 16 / 0。不得把前者说成当前源码通过，也不得为了迎合宿主去弱化产品
sandbox。

focused tests 必须证明：单文件 48 KiB、snapshot resource/diagnostic/scan
bounds、秘密与 symlink 拒绝、canonical primary window
（`context_window` / explicit `limit.context`）的 2% approximate-token
catalog / 未知窗口 8,000-character fallback、公平截断、count-only
omission/truncation warning/metrics、显式激活整批拒绝、默认 192 KiB
invocation-local 共享披露预算、`developer` role 不降级、registry digest、
permission + durable prepare/settle、parent/child workspace isolation，以及
iOS target 不链接 Skills。若改 MCP dependency，还必须覆盖 machine metadata
解析边界、generic resource 不可披露、request-owned availability、exact
server+locator 配对、endpoint 变化与无 MCP host fail closed。它们不证明真实
provider 会正确服从 catalog，不证明真实 MCP production builder/server/
reconnect 或 install/OAuth/config refresh、GUI 操作或 Linux/musl 的真实
filesystem 行为；未跑时必须继续标为 `UNKNOWN`。

2026-07-27 的 iOS DerivedData `Build/` 中不存在任何 `IntatisSkills` target
产物，最终 `.app` 也没有 `INTATIS_SKILL` / `activate_skill` /
`read_skill_resource` 字符串；Developer ID DerivedData 存在
`IntatisSkills` target 产物。旧 App Store DerivedData 的历史产物不再是当前
linkage 验收项。

## Cowork 长任务运行预算

修改 Cowork task timeout、Agent provider request timeout 或 AgentLoop iteration
budget 时，至少验证 Chat/Agent 分流、Code/Cowork 分流、CLI mode 切换和 durable root
contract：

```sh
swift test --disable-sandbox --quiet \
  --filter 'IntatisProvidersTests|InferenceCatalogStoreResolverTests|IntatisAgentKernelTests|OrchestrationReliabilityTests|CLIConfigRuntimeBudgetTests|CapabilityLeaseTests'
# 294 tests / 0 failures

swift test --disable-sandbox --quiet
# 1367 tests / 16 skipped / 0 failures

swift build --disable-sandbox --product intatis
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-cowork-long-budget-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# succeeded；仅有仓内既有 warning
```

这些测试证明离线 policy、admission、配置分流和产品编译，不证明真实 provider
在 180 秒窗口内会成功返回，也不证明真实 10 分钟多 Agent 任务或长期资源稳定性。
后两项未跑时必须继续标记为 `UNKNOWN`。

## External MCP client 完整验收

外部 MCP 客户端改动不能只跑一个 transport 或 fixture。最终验收至少覆盖：

```sh
# SwiftPM 主图与 14 个 test targets
swift build --disable-sandbox
swift build --disable-sandbox --product intatis
swift test --disable-sandbox

# client-only SDK/source/linkage、Codex tool_search、W7、W9、HTTP/OAuth、
# managed stdio、portable crypto、CLI owner 等可按失败域聚焦重跑
swift test --disable-sandbox --filter SDKClientOnlySurfaceTests
swift test --disable-sandbox --filter MCPToolSearchParityTests
swift test --disable-sandbox --filter MCPW7CatalogResourceTests
swift test --disable-sandbox --filter MCPW9StandardExtensionsTests
swift test --disable-sandbox --filter MCPStreamableHTTPTests
swift test --disable-sandbox --filter MCPOAuthTests
swift test --disable-sandbox --filter MCPManagedStdioTests
swift test --disable-sandbox --filter MCPPortableCryptoTests
swift test --disable-sandbox --filter IntatisCLITests

# pinned official client conformance + Intatis Tasks interoperability + W10 suites
Tests/MCPConformance/run-w10.sh
```

`swift test --disable-sandbox` 只关闭 SwiftPM 自己的构建 sandbox，不会让嵌套的
`sandbox-exec`、loopback socket、Keychain 或子进程自动获得 Codex/CI 宿主
权限。若日志明确显示 `sandbox_apply: Operation not permitted`、loopback bind
`EPERM` 或 unsigned Keychain host，应在有相应能力的 runner 重跑；不得修改
产品 sandbox、网络策略或 Keychain 代码来迎合受限测试宿主。最终报告必须把
“确定性实现通过”与“外部环境证据受限”分开。

当前 Apple 产品图必须分别使用独立 DerivedData 验证；macOS 只包含 Developer
ID/direct-distribution `IntatisMac`：

```sh
xcodebuild -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-mcp-mac-developerid \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build

xcodebuild -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-mcp-ios \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
```

构建成功后还要检查：

- DeveloperID/CLI 能解析 external MCP stdio + HTTP 客户端符号；
- iOS target graph/bundle 不含 `IntatisMCP`、Curl/stdio transport 或 MCP UI；
- 发行产品不含 `IntatisMCPConformanceClient`；
- entitlements、`Localizable.xcstrings`、NOTICE/ThirdPartyNotices 与 SDK
  provenance/patch ledger 一致；
- `scripts/validate-linux-cli.sh` 在最终 Swift source state 上重新生成
  aarch64/x86_64 静态 ELF 与 SHA-256，不能沿用较早源码的 hash。

official conformance runner 当前固定 `@modelcontextprotocol/conformance@0.1.16`。
计数必须区分 official client scenarios 与 Intatis 自有扩展：official 为
`codex-compat` 5 + `standard-extended` 18；3 个 Tasks interoperability
scenario 另列，不能称为 official。

### 2026-07-27 最终源码结算

以下三 target/hash/Mach-O 内容是 2026-07-27 的历史执行事实；其中
`IntatisMacAppStore` 已退出当前产品和验收矩阵，不得从本段推导需要继续构建。

- `swift test --disable-sandbox`：1362 tests、16 个显式 opt-in 环境 skip、
  0 failures。16 个 skip 分别是 1 个真实 Git smoke、13 个真实 browser
  smokes和 2 个仅允许 signed/unsandboxed host 的 Keychain CRUD；没有 MCP
  源码测试 skip。
- `Tests/MCPConformance/run-w10.sh`：official 23/23、Tasks interoperability
  3/3、七个 focused suites 102/102，全部 0 failures；managed stdio 是
  40/40。
- P1 聚焦命令覆盖 `MCPToolSearchParityTests`、
  `MCPToolResultConversionTests`、`AgentRequestToolSnapshotTests`、
  `ResponsesToolSearchParityTests`、`MCPProtocolLifecycleTests`、
  `MCPRuntimeAuthorityTests`、`MCPCLIProcessOwnerTests` 和
  `MCPNoAttachmentRegressionTests`：80/80、0 skipped、0 failures。真实本机
  loopback 的 CLI `connect → status → refresh → disconnect` 未跳过，lazy
  transport negotiated-version 顺序和无 MCP lazy owner 均通过。
- `swift build --disable-sandbox` 与
  `swift build --disable-sandbox --product intatis` 均 exit 0。
- Xcode 26.6 (17F113)、Apple Swift 6.3.3、macOS/iOS Simulator SDK 26.5
  下，`IntatisMac`、`IntatisMacAppStore`、`IntatisiOS` 三个当时源码中的 Debug
  build 均 exit 0。主 dylib SHA-256 分别为
  `518eb87c097a23189c01c575cbb3e5d7501496e077c5044d612700571cbb53dd`、
  `0b6cf6ecd6692ff88d5e71e447df022997b0c852fcde775afd8e3f5f65e39db7`
  和
  `10afba6a9471ca9652a19efe0a930b9160c727ad9838cc3eca440ee7c592d67c`。
  这些命令设置 `CODE_SIGNING_ALLOWED=NO`；linker-generated ad-hoc wrapper
  不是 Developer ID 分发签名，旧 App Store target 的结果也不是发行证据。
- 最终 Mach-O/target graph 复核：DeveloperID 含 `IntatisMCP` +
  `IntatisMCPStdio`，支持 stdio+HTTP；App Store 含 `IntatisMCP` 但无
  `IntatisMCPStdio` 符号，为 HTTP-only；iOS 无 `IntatisMCP`、
  `IntatisMCPStdio`、`IntatisTools` 符号或 MCP 产品面。
- 受限 Codex filesystem sandbox 首次无法写
  `~/.cache/clang/ModuleCache`；上述 SwiftPM 权威结果来自随后获准的真实本机
  环境。该宿主错误发生在 manifest/test 前，不是源码失败。

## 2026-07-26 独立 conversation renderer lifecycle lab

该实验不进入 SwiftPM、XcodeGen 或 App bundle；验证命令必须在独立目录运行：

```sh
cd /Users/vita/Vitemis/Intatis/Experiments/WebRendererParity
npm test
# 4 files, 46 tests, 0 failures

npm run licenses
# 266 packages, rejected = []

npm run build
# TypeScript + Vite succeeded
# main JS 941.04 kB minified / 290.19 kB gzip
```

自动化冻结的合同包括：GFM/hard-break/source position、literal raw HTML、URL/image policy、KaTeX HTML+MathML 与错误回退、代码内公式隔离、known/unknown language、canonical copy、CodeMirror Strict Mode cleanup、500 ms streaming tail、append suffix 不重建 editor、30 秒 warm eviction、快速切回取消 timer、manual release/dispose/no-op、stable external-store snapshot、outer shell 复用、旧 session message subtree disconnect、newest-12/older-10 pagination、stream 在 session generation 切换前取消，以及 CodeMirror view 随旧 subtree 销毁。

手工运行只允许：

```sh
npm run dev
# only http://127.0.0.1:4173
```

浏览器验收应读取 DOM、accessibility roles、computed styles、canonical clipboard 和 bounded `window.rendererHarness`，不能以截图作为渲染/释放证据。至少检查：页面只存在一个 `[data-message-subtree]`；保存的旧 subtree 在切换后 `isConnected === false`；30 秒内切回取消旧 eviction；超时或 `Release warm` 后 resident 变 cold；离屏消息不保留 Markdown/KaTeX/CodeMirror child；active editor view 数与 `.cm-editor` DOM 一致；math cache 不超过 256 entries / 512 Ki characters；remote Markdown image 不创建 `<img>` 或网络请求；所有资源仍来自 localhost。

本实验的通过不替代 native `MessageRenderingTests`、SwiftUI/TextKit、VoiceOver、真实 selection/clipboard、最低 macOS/iOS、长期 memory plateau 或 release 验证。当前没有做新 lifecycle 页的手工浏览器验收，且没有运行 Swift build/test，因为本轮没有修改或接线 production Swift target。

## 2026-07-25 Cowork `@main` 持久模型历史

本轮专项命令使用独立 module cache，并复用仓内已解析的 SwiftPM dependencies：

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-codex-history-cache/clang \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-codex-history-cache/swiftpm \
  swift test --disable-sandbox \
  --filter 'ModelHistoryAgentLoopTests|ModelHistoryProjectionTests|ModelHistoryProtocolTests|SubmittedIntentHistoryTests|ContextProjectionTests|IntatisCoworkTests.testMainProviderRequestCarriesCompletedConversationAcrossTurns|IntatisCoworkTests.testDirectWorkerRootRemainsTaskScopedAcrossTurns'
# 34 tests, 0 failures
```

覆盖内容包括：U1/A1/U2 跨 turn 顺序；重建 `AgentLoop` 后 user/assistant/function-call/function-output 仍按原结构进入请求；assistant call batch 先于工具执行事实落盘；tool result/settlement/model output 连续同 batch 写路径；missing output → prompt-only `aborted`；orphan output 删除；并行 output 按原 call 顺序恢复；latest retry attempt 选择；冲突 item ID、wrong agent/target、unknown future event 与 seq gap 在 provider 前 fail closed；跨工具轮重复 `call_0` 唯一化；只有完整 direct output 才删除 ContextBundle audit result；task-scoped worker 不继承主 thread；`write_stdin` 原始字符不进入 EventLog。

最终完整验证使用相同的独立 module cache：

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-codex-history-cache/clang \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-codex-history-cache/swiftpm \
  swift test --disable-sandbox
# 1000 tests, 14 skipped, 0 failures

env CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-codex-history-cache/clang \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-codex-history-cache/swiftpm \
  swift build --disable-sandbox
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intatis-model-history-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-model-history-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# succeeded

git diff --check
# passed
```

第一次在受限外层环境运行 full suite 时，既有 process/browser/network 环境测试受到宿主限制，进程已中止；随后获准使用测试本身的 sandbox 配置完成上述权威 full run，1000 项没有源码测试失败。两个 Xcode build 只有既有的 `try?` 返回值未使用、iOS 17 `onChange(of:perform:)` 弃用等警告。

该 2026-07-25 结果当时即使通过 full suite 和双端构建，也不表示完整 Codex
等价；它当时尚未证明 replacement-history compaction。该主链已由上面的
2026-07-28 独立实现与验证取代。provider-native reasoning、历史图片重新装载、
同一中断 submission 原地 resume、rollback/fork、真实 provider 长会话和真实
App/process kill 后重开仍未由任一离线段落证明。

## 2026-07-24 managed terminal 最终验证

本轮为 macOS Code/Cowork/CLI 加入真实持久终端与 PTY，最终源码状态验证如下：

```sh
swift test
# 984 tests, 14 skipped, 0 failures

swift test --filter TerminalToolsTests
# 25 tests, 0 failures

swift test --filter 'TerminalToolsTests|TerminalAgentLoopTests|ShellPermissionTests|ProcessShellRunner|CapabilityLeaseTests|ToolRegistryLeaseTests|AgentLoopPolicyTests|OrchestrationReliabilityTests'
# 首轮 136 项中仅新增环境测试的期望写法失败；修正测试后单项、专项与最终 full suite 均通过

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination platform=macOS \
  -derivedDataPath /private/tmp/intatis-managed-terminal-final3-mac-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# succeeded

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/intatis-managed-terminal-final3-ios-dd \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
# succeeded
```

`TerminalToolsTests` 的 25 项覆盖真实 cwd/写文件、跨调用 stdin、TTY stdin/stdout/controlling `/dev/tty`、Ctrl-C、Swift toolchain 与 secret environment 过滤、owner isolation、空/自定义 WorkspaceLease 也不能移除的大小写无关凭据路径底线、timeout descendant cleanup、12 MiB build artifact、bounded newest-tail output、延迟输入回显清洗、完成未 poll 自动收口、workspace root replacement、sandbox 内命令不能 signal unsandboxed XCTest host、跨多次输入的危险命令、zsh 光标/escape/keymap 改写拒绝、随机盐 authorization identity 和 registry/schema opt-in。`TerminalAgentLoopTests` 证明 prepare/settle 进入 EventLog 但 stdin 原文/摘要不落盘；权限测试证明 `write_stdin` 不能绕过危险命令 hard deny。

本轮未做真实 provider 驱动的长时间 Agent coding session、全屏 TUI/resize/SIGWINCH、App `kill -9` 后 orphan 检查、Linux bwrap/PTY、跨进程 terminal session 恢复或长期资源 soak；任意名字的自定义 secret 环境变量、极快自行 `setsid` 的后代与工作区复核到 spawn 之间的替换窗口也没有被证明完全覆盖。一次临时的“填满 stdin pipe”压力用例未能形成稳定可重复的结果，已中止且没有保留为通过测试；当前能确认的是任意 stdin 写入错误都会封死并清理 session。这些仍为 `UNKNOWN`，不能用单元测试或 Debug 构建冒充已完成。

## 2026-07-30 Cowork projection / scroll / paragraph resize hang remediation

- 修复前普通 Release、默认 rich renderer 和真实 `cowork_tf2lkjbh` 可在
  zoom/restore 后进入无响应；进程外 sample 命中 `ParagraphView`、
  `PlatformViewLayoutEngine.sizeThatFits` 和 `NSHostingView.minSize`。
  相同二进制的 plain-safe control 正常。
- vendor 当前回归为 77 XCTest + 11 Swift Testing，0 failures。新增覆盖：
  10,000 次连续 width change 产生 0 次 width-driven intrinsic invalidation；
  10,000 次 cache store 后仍只有 1 个 exact-width entry；相邻 width 不 alias；
  intrinsic height 不复用 stale width；`NSHostingView` 120 轮 A→B→A、
  360 个 observation 均为有限且可逆尺寸。
- projection/scroll/viewport focused tests 冻结逐 seq exact fold、50 ms
  delta publication 与 non-delta barrier、session/generation/throughSeq fence、
  100 ms live-follow cadence、10,000 geometry update 为零 scroll、detached/jump
  语义，以及交互期间零 rich admission 与每行 150 ms exact-revision dwell。
- 修复后的 production app 使用默认 rich renderer 完成真实 A→B→A、
  5 次 zoom/restore 与 8 次上下滚动，隔离窗口 runtime-issue 检查为空。
- final validation executable SHA-256 为
  `a12dc747c79d061df8fdf592ce8852340685fa6b054fd87291e2c52c2deb2f03`。
  三次同 SHA 的 180 秒 soak 均通过：
  - PID 54297：181.598 秒 / 43 cycles，peak RSS 117,473,280 B，
    footprint 45,024,120 B；plateau growth +1,442,418 / +6,476,605 B。
  - PID 56283：180.315 秒 / 37 cycles，peak RSS 126,599,168 B，
    footprint 45,564,792 B；plateau growth +4,871,941 / +3,398,897 B。
  - PID 60467：180.280 秒 / 42 cycles，peak RSS 121,716,736 B，
    footprint 46,269,304 B；plateau growth -9,204,764 / +6,448,048 B。
  三次都完成 2 次 session switch、exact 1,249 delta / 17 message，且无
  heartbeat stall、无 multiple-updates-per-frame、无 TERM/KILL 或残留。
- 第三次 soak 在同一 PID 执行 75 次 AX top/bottom，800 ms 显式动作间隔
  累计 60 秒。该次 Intatis PID 的 Unified Log 有 18 条 AppKit
  negative-geometry runtime issue；它们每簇均紧随系统
  `ThemeWidgetControlViewService` 激活，前两簇在显式滚动开始前的 AX
  全树/ReplayKit 截图阶段，stack 没有 paragraph/thread 产品符号。两次无该
  AX 路径的同 SHA soak 均为 0。因此报告保留 count=18，并分类为
  automation-correlated transient；不能再写“只有 6 条”或“未进入 app
  runtime issue”。watchdog 当前只把 invalid geometry 记为 telemetry，
  fail-closed gate 是 multi-update、heartbeat、资源/wall、fixture result
  与清理。
- soak-2 同一 PID 的 Time Profiler + Hangs 录制约 90.665 秒。导出的
  Potential Hangs / Hang Risks 均为 schema-only、0 row；19,347 个 Intatis
  主线程 1 ms sample 中，NSHosting + sizeThatFits 最长短 burst 约 48 ms，
  没有持续递归 hot stack。三个 XML SHA-256 依次为
  `3e6a7b1c5896614835892637a92d58584bfb5a6d82213ce7fee01924b5b62b38`、
  `1d766167930dbf238719821b29dfb310a0c3f122e925ea92dfba4b54d54c0dee`、
  `28b818c72cc68c47ba4cf6a44caa12d213ca2fc48060816545f75b367d08561d`。
- 最终 focused 五套 85/85、root full 1537 tests / 16 skipped / 0 failures；
  normal IntatisMac Release executable SHA-256 为
  `84f29784f3b837392af3454960896afe8b66c621a9f3374737da05e1a224e267`。
  仓内与 app bundle `NOTICE.md` 均为
  `616f4fcaa1f7e92a5e46ee9182485a5b8da427155cdcfe025bfac7754ccd4589`。

完整命令、平台构建 hash、多窗口证据、soak result 路径和 Instruments
方法/限制记录于
`codex-report/07_29_26-17_05-cowork-scroll-rendering-hang-remediation-plan.md`；
任何旧 executable 的 soak/trace 只作历史证据。

## 2026-07-24 Session 切换布局风暴修复

自动化覆盖：

- `ThreadScrollCoordinatorTests` 8/8：scope/anchor 隔离、scope change cancel、100-request latest-generation coalesce、用户离底/回底、初始与完成动画策略、双窗口 coordinator 独立、bottom tolerance/亚像素 jitter，以及首次 shrink→regrow 接受、同 epoch 第二轮振荡拒绝、新 epoch 才重开 recovery。
- `ChatHistoryReplayTests` 6/6：completed history 单次 publication + live incremental、artifact/progress/stats 一次恢复、fold 中间追加事件 exactly once、stop 与 shutdown 拒绝 stale publication、restart 可重新恢复，以及首次 strict replay 失败时 128 条历史零逐条发布/追加事件不误消费/第二次一次恢复 129 条。
- 最终源码按 test target 串行分片：Core 31、Protocol 72、Providers 104、Artifacts 14、Conversation 132、Tools 98（14 skipped）、Permission 43、AgentKernel 82、Cowork 306、Multimodal 3、SharedUI 70；合计 **955 tests / 14 skipped / 0 failures**。SharedUI 的 8 个 class 分别为 ChatHistory 6、CoworkInference 4、ExecutionTrace 7、MarkdownScheduler 6、MessageRendererMode 11、MessageRendering 25、ThreadLayout 3、ThreadScroll 8。
- 不能隐藏的 runner 事实：收口过程中的两次 one-shot serial full run 分别在约 5 分钟和 84.21 秒无摘要后有界中止；一次 parallel full 在 9.515 秒尝试 955 项并因共享临时目录/timeout 竞争出现 3 failures，三个用例随后串行 3/3 通过；最终 SharedUI 整 target 在一个 runner 中 120 秒无摘要，但 8 个 class 独立 70/70。最终权威自动化结论来自 11 target / SharedUI class 分片，不把未结算的一键进程记为 pass。所有中止后均确认无 `swift-test` / `xctest` / `IntatisPackageTests` 残留。
- `xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intatis-session-switch-mac-dd CODE_SIGNING_ALLOWED=NO build`：通过。
- `xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/intatis-session-switch-ios-dd CODE_SIGNING_ALLOWED=NO build`：通过；只有两个既有 iOS 17 `onChange(of:perform:)` 弃用警告。
- 静态零匹配：Code/Cowork/manager/root 相关文件中不再出现 `DispatchQueue.main.async`、旧 `bottomAnchorID`、`runtimeRevision`、`runtimeObservations` 或 `objectWillChange.sink`。`git diff --check` 通过。

Computer Use 使用 exact Debug app path、一个 Intatis 实例和用户现有只读历史，没有发送消息、触发 provider、删除 session 或修改工作区：

- Cowork A/B/C 分别约 2816 / 1575 / 758 events；执行 32 次 A→B→C→A 点击切换，Computer Use 单次 click + accessibility capture 为约 0.73–1.14 秒，停止后 App 可立即交互。
- 16 次/32 次后 `vmmap` physical footprint 约 142 / 141 MiB；32 次后 `ps` 为 0.7% CPU、约 275 MiB RSS。1 秒 `sample` 的主线程 860/860 样本在 `mach_msg2_trap` 等待事件，没有活动 SwiftUI / AttributeGraph layout 栈。该值是 Debug 短时观测，不是冻结性能阈值。
- completed Cowork B/C 首次展示落在底部；手动把 B 上滚到 AX scrollbar 约 0.659 后，后续 state capture 保持该位置，没有被 rich correction 抢回。超大 A 的 AX scrollbar 比例会随 AppKit accessibility range 重算，不能把该比例当成像素级底部证明；其最后可见消息和交互保持稳定。
- 第二窗口选择 C，关闭前台窗口后第一窗口仍显示 A；同一 PID 保持运行。再关闭最后窗口，`list_apps` 与 `ps` 仍确认进程存活；最后 `Command-Q` 才退出且没有残留测试 App。
- Chat 的 1499-event completed history 一次出现，AX 同时暴露 headings、lists、inline/display formula descriptions；没有观察到逐 token 重播。

仍未由本轮 Computer Use 覆盖：真实后台 provider/agent 正在产出 token 时的多窗口切换、permission review 正在等待时删除、>160 秒单实例 soak、低端设备与 VoiceOver/clipboard。Phase L 的既有 offline lifecycle fixture 和本轮单元测试覆盖所有权/有界退出，但不得冒充这些真实外部矩阵。

## 2026-07-24 macOS assistant / agent 正文全宽

- 布局合同：assistant/agent 与 Thinking 使用 full-width leading row；用户消息继续 trailing，并保留既有 `messageMaxWidth` / gutter；system 与结构化卡片不随本次扩大。
- `xcrun swiftc -parse Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift Packages/IntatisSharedUI/Tests/ThreadLayoutTests.swift`：通过。
- `swift test --disable-sandbox --filter 'ThreadLayoutTests|MessageRenderingTests'`：**28 tests / 0 failures**（布局 3/3，Markdown/LaTeX 渲染 25/25）。沙箱内首次尝试因用户级 Clang module cache 不可写而在 manifest 阶段失败；获批脱离沙箱后完整编译并通过，前一次不是源码测试失败。
- `swift build --disable-sandbox --target IntatisSharedUI`：通过。
- IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug：均以独立 DerivedData 增量复核成功。未启动 App，本轮宽窗口像素、长 Markdown 表格/代码块和真实滚动高度变化保持 `UNKNOWN`。

## 2026-07-23 session recency / native Stop / Thinking elapsed

源码验证范围：

- recent-session projection 必须以 durable terminal events 为排序依据，并确认选择、rename、migration/recovery 或其他 mtime 写入不参与排序；相同完成时间按 SessionID 稳定排序。
- Chat / Code / Cowork 工作态只显示同槽位 native destructive red Stop，Return 不得触发 Send。验证 Chat current-operation cancel、Code current-turn cancel、Cowork ordinary active-task cancel 与 Goal scoped pause；不得关闭 session runtime 或 permission reviewer。
- macOS Chat 与 Code/Cowork 的 Thinking phase 显示 `0s…15s…`，首个可见内容/权限或工具阶段/terminal 后停止，下一次 Thinking 从 0 开始；VoiceOver 文案应包含秒数。

自动化结果：

- `xcrun swiftc -parse` 覆盖本轮修改的 Core / Conversation / AgentKernel / SharedUI / macOS / iOS Swift 文件，通过。
- `swift build --disable-sandbox --target IntatisSharedUI` 与 `--target IntatisAgentKernel` 通过。
- focused `IntatisConversationTests|AgentLoopOutcomeTests|AgentLoopPolicyTests|GoalRuntimeControllerTests|OrchestrationReliabilityTests|AutomaticPermissionReviewTests|MessageRenderingTests`：**303 tests / 0 failures**。
- `xcodegen generate`、IntatisMac macOS Debug build、IntatisiOS generic Simulator Debug build 均通过。
- String Catalog `jq`、English / zh-Hans `xcstringstool compile` 与两份 compiled `.strings` 的 `plutil -lint` 均通过；`git diff --check` 通过。

遵守 renderer release NO-GO，本轮未启动 App 或 fixture。真实 1 秒刷新节奏、控件像素、VoiceOver 与真实 provider/server cancellation timing 保持 `UNKNOWN`。

## 2026-07-24 单美元数学最终验证（历史）

本节冻结当日实现和证据；其中单美元-only、32 个、8 KiB 和
1024×256-point policy 已由 2026-07-31 patch group 12 supersede。

- Vendor：`swift test --disable-sandbox` 为 75 XCTest + 7 Swift Testing = **82/82**；`swift build -c release --disable-sandbox -Xswiftc -warnings-as-errors` 通过。Paragraph 源码临时 diagnostic 标识与 legacy `.layoutManager` 属性访问均为零匹配。
- SharedUI/root：`MessageRenderingTests` **25/25**；根 `swift test --skip-build --disable-sandbox` **938 tests / 14 skipped / 0 failures**。一次前序 full rerun 在 XCTest 等待态无输出后被中止并确认无残留；随后新 xctest 进程 17.061 秒完整通过，二者都必须保留在报告中。
- Products：`xcodegen generate`；IntatisMac macOS Debug/Release；IntatisiOS generic Simulator Debug/Release 均 `BUILD SUCCEEDED`。正式 macOS Release executable SHA-256 为 `ef966a5e76d77ef9eebf2394068133ecb3202e3910e7875522c47620ae53ee8c`。
- Supply chain：两份 lockfile 均固定 iosMath 2.5.0 / `838cddc01fdd67efd530f8bb67959ad2715f9b06`。macOS/iOS Release bundle 各含 8 OTF 与完整 26-file `fonts/` payload；仓内与双端 app `NOTICE.md` SHA-256 均为 `02778763b3743e591b3ccb30537f853d2d5a791b1002e032ff65ed5821c7b5b8`。iOS Debug/Release `Settings.bundle/Root.plist` 均通过 `plutil -lint`。
- Isolation A/B：hash-pinned validation executable `ec56cec173c13e41edb4f53e3ff5fcb1ac3d35079d40f140c4503a4d99dde55f` 下，同一 Microsoft `math-structure` 的 math-disabled/enabled 各运行约 21 秒并通过；peak RSS 70,909,952 / 70,942,720 bytes，footprint 11,649,768 / 11,682,536 bytes，rolling CPU 1.5962% / 1.4978%。`math-one`、`math-thirty-two`、`math-history`、`math-stream` 也均通过；所有 run exit 0、无 TERM/KILL、二次清理成功、无残留。单样本数值只作 containment observation，不是 release performance threshold。
- Computer Use：Light/Dark `math-structure` 各约 47.47 秒通过。稳定截图显示 heading、paragraph、unordered/ordered list、blockquote、table 中的 live 数学字形；`$not_math$` / `$table_code$` 仍为 literal；AX tree 描述原始 TeX。Light/Dark peak RSS 为 136,691,712 / 135,036,928 bytes，footprint 48,710,520 / 48,087,904 bytes，rolling CPU 11.5379% / 11.2088%，无 TERM/KILL 或残留。截图/AX 不等同于真实 clipboard/VoiceOver 操作。
- 未关闭门：历史事故的 malloc retaining edge 仍 `UNKNOWN`；还缺 >160 秒 long soak、真实 selection/clipboard/VoiceOver 操作和低端 iPhone/iPad 实机。故可描述为“实现、构建、短时 containment 与 Light/Dark 可见性通过”，不可描述为 renderer release-ready。

## 2026-07-31 common LaTeX delimiter / no-local-cap 验证

- 当前必须覆盖 `$...$` / `\(...\)` inline 与 `$$...$$` / `\[...\]`
  display；display 内容可跨行，protected Markdown、currency、escape、
  malformed/invalid TeX 仍 exact literal。
- 公式回归必须包含多于旧 32 个阈值、单式大于旧 8 KiB 阈值，以及有效
  intrinsic width 大于旧 1024pt 阈值；这些 case 必须继续生成 attachment，
  不得退回整条消息 literal。
- `swift test --disable-sandbox --filter InlineMath` 当前为 **39/39**，
  0 failures。
- vendor Release strict-concurrency + warnings-as-errors 全量为 **79 XCTest
  + 11 Swift Testing = 90/90**；根工程 `MessageRenderingTests` 为
  **41/41**；`swift build --disable-sandbox --target IntatisSharedUI`、
  `xcodegen generate`、IntatisMac macOS Debug 与 IntatisiOS generic
  Simulator Debug build 均通过。
- 本 patch group 未运行根工程完整 test suite、双端 Release build 或
  user-approved 真实窗口/fixture；以上自动化不能冒充 renderer release GO。

最近自查日期：2026-07-31

## 环境

- 操作系统 / 平台：macOS 26+（IntatisMac 与 Apple 平台 SwiftPM product）；iOS 26+（IntatisiOS）；CLI 理论支持 Linux（`#if canImport(SwiftUI)` 守卫）
- 根工程语言/清单合同：`Package.swift` 使用 `swift-tools-version: 5.9`，XcodeGen 的 `SWIFT_VERSION` 为 5.9；这不是当前编译器版本。渲染派生包单独要求 Swift tools 6.2 / Swift language mode 6。当前依赖/公式审计使用 Swift 6.3.3 / Xcode 26.6；传递的 `swift-markdown` 仍声明 Swift 5 language mode，iosMath 含 Objective-C target，因此不得把整个依赖图描述为 Swift 6 strict-clean。
- 依赖管理：SwiftPM（`Package.swift`）+ XcodeGen（`project.yml` → `Intatis.xcodeproj`）。对话渲染当前使用仓内 `Vendor/SwiftStreamingMarkdown` 中 Microsoft `SwiftStreamingMarkdown` v0.6.0 basis 的薄派生包，依赖为 exact `swift-markdown` 0.8 revision `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`、传递 `swift-cmark` 0.8 revision `924936d0427cb25a61169739a7660230bffa6ea6`，以及仅 Apple 平台的 exact iosMath 2.5.0 revision `838cddc01fdd67efd530f8bb67959ad2715f9b06`。根与 vendor 两份 `Package.resolved` 已匹配上述 iosMath pin。MarkdownUI、NetworkImage、HighlightSwift/highlight.js、Shimmer、macro/snapshot testing 与旧 regex 数学路径不在主依赖图/产物中；只选择性恢复了 iosMath。派生包源码、测试、Microsoft MIT license 与 patch ledger 由 Intatis 根 Git revision 一起固定；三个 remote dependency 在无缓存时仍需从各自 exact revision 取得。
- 凭据 / 配置：UserDefaults（规范主键 `intatis.providerCatalog.v1`，provider 保存 `baseURL` + `chatEndpoint` + secret ref 元数据；macOS 聊天页当前 provider/model/variant identity 保存到 `intatis.providerSelection.v1`，iOS 保存 provider/model identity；旧 `intatis.baseURL`、`intatis.model` 为迁移/兼容镜像）+ 配置文件 secret（macOS 设置页把用户主动输入的 API key 写入当前可编辑 Intatis-owned OpenCode-compatible config `provider.<id>.options.apiKey`；iOS 默认写入 app container `Intatis/auth.json`，可由 `INTATIS_AUTH_FILE` 覆盖；真实 provider 请求也可从 Intatis-owned OpenCode-compatible config `provider.<id>.options.apiKey`、auth JSON、`{env:NAME}`、`{file:path}` 懒加载并缓存 secret）+ macOS 高级 JSON/JSONC 配置（`INTATIS_CONFIG` 显式指定文件 / `~/.config/intatis/intatis.json` / `intatis.jsonc` / app support `intatis.json` 或 `intatis.jsonc`，旧 Intatis `config.json` 兜底兼容读取；不自动发现 `opencode.json`，也不读取 OpenCode app 配置；Chat/Code `ProviderEndpoint` 对 `provider.<id>.models.<model>.options` 保持任意 JSON lossless，所选 `variants.<variant>` 原始字段覆盖基础 options，参数不镜像 UserDefaults；Cowork durable catalog 只接受显式 allowlisted option schema）。GUI 不再读写 OS Keychain。

> Per-agent inference 环境说明：macOS app 与 CLI 在各自 App Support 下维护 `inference-catalog-v1.json`；测试应注入临时 store URL，不读取或改写用户真实 catalog/credential 文件。Catalog 与稳定 sidecar lock 文件必须 owner-only；corruption/schema/permission/lock-integrity failure 用副本或临时 fixture 验证，不能破坏用户现有文件。Store 并发测试必须使用多个独立 store instance 同时 reconcile 同一路径，验证所有 immutable revisions 保留且 revision 唯一，不能只测单 actor 内串行调用。CLI multi-route 测试必须为每条 route 使用不同临时 credential reference，并证明 resolver 不会用 selected route 的 key 替代其他 route 或旧 revision。

> 配色验证说明：`docs/CURRENT_UI_COLOR_SYSTEM.md` 是当前系统原生表面 + Liquid Glass 视觉基线；`docs/UI_COLOR_SYSTEM.md` 只保留上一版配色底稿。配色变更至少需要静态搜索确认没有固定 `.white` / `.black`、采样 RGB 或自绘玻璃表面，编译 macOS 与 iOS touched targets，并在运行态分别检查 Light / Dark 下的 Chat、Code、Cowork：window / sidebar / Material 应随系统动态解析，Glass 主要出现在导航和交互功能层；用户明确指定的 Cowork 紧凑 trailing status rail 是唯一内容层例外，仍必须使用系统原生 `GlassEffectContainer` / `glassEffect`，页面和长 transcript 不应整片玻璃化。正常 assistant/agent 正文应直接继承 canvas、无外层 Material/描边；用户、失败与其余结构化卡片仍需可辨边界。macOS UI 另需核对系统 split-view sidebar 内的 `Intatis` 标题 + 带图标竖向三模式导航（仅选中行使用玻璃）+ mode-specific history/30×30 New `+` + 底部 Settings、session-name header、Code/Cowork 紧凑顶部留白、Cowork 无常驻 reviewer 横幅、无消息 agent 头像/通用 Agent badge、两排 composer（40pt、关闭态仅模型名的 model/profile glass 菜单左 + usage 右；已有 action 左 + 输入 + 可选 stop/Send 右）、第二排 40pt 等高原生圆形按钮/输入框、多行时底边对齐，以及宽屏系统 inspector。还需在 `979pt` 或更窄的 Cowork 确认没有 rail、Goal/Tasks 顶部副本或空白占位，并在 pending permission 时只出现一个 composer 上方 Material 兜底卡；在 `980pt` 及以上确认 rail 依次显示权限审查、Agents、Goal、Tasks 且无 Git，pending 时 rail 固定可见；无 pending 时覆盖宽屏手动隐藏 inspector。当前最低系统已为 macOS 26 / iOS 26，无需验收更旧系统 fallback。
>
> 2026-07-15 系统原生表面 + Liquid Glass 迁移基线：`swift build`、全量 SwiftPM 605 tests（14 skipped，0 failures）、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均通过；Computer Use 已在本轮 app 中逐页检查 Chat / Code / Cowork 的 Light / Dark window、sidebar、内容 Material 与功能层玻璃。视觉检查使用 DEBUG-only `-IntatisAppearanceLight` / `-IntatisAppearanceDark` 进程参数，不修改全局系统 Appearance。
>
> 2026-07-23 原生 `List` sidebar 与随后横向 segmented sidebar 两次修订，均已被当前竖向 icon 模式导航取代。当前修订的 Swift parse、原生 control fitting-size probe（Recent `+` 30×30、共享 model/profile glass label 40pt 高）、`swift build --target IntatisSharedUI`、`IntatisSharedUITests` 50/50、`PerAgentInferenceProfileTests` 20/20、XcodeGen、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 均通过。遵守 renderer NO-GO，本轮没有启动 App 或 fixture；当前像素、sidebar 键盘/焦点、Light/Dark、Reduce Transparency 与真实窄宽布局仍为 `UNKNOWN`。2026-07-21 `design-qa.md` 只保留为历史视觉证据。
>
> 2026-07-23 模型关闭态 label / Cowork compact Goal/Tasks 移除修订：三个 Swift 文件 parse、`IntatisSharedUI` build、`CoworkInferencePresentationTests` 4/4、`PerAgentInferenceProfileTests` 20/20、XcodeGen、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 通过。完整 `IntatisSharedUITests` 尝试在 bundle build 完成后于有界等待内未输出 test-case 结果，已中止，因此本次不能把该完整 suite 记录为 pass/fail。renderer NO-GO 下仍未启动 App/fixture；`979pt` 无 Goal/Tasks、`980pt` 默认 inspector、宽屏手动隐藏 inspector、长模型名与 Light/Dark 像素均为 `UNKNOWN`。

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

- 默认 `IntatisMac` 是 DeveloperID/non-sandbox 本地 workbench：`project.yml` 指向 `Apps/IntatisMac/IntatisMac.DeveloperID.entitlements`，`AppConfig.platformProfile` 为 `.macDeveloperID`。生成并构建后可用 `codesign -d --entitlements - <DerivedData>/Build/Products/Debug/IntatisMac.app` 确认没有 `com.apple.security.app-sandbox`。
- `IntatisMac.AppStore.entitlements` 和 `IntatisMacAppStore` 只属于尚未删除的
  legacy source，不是未来版本、默认 build 或 release 输入；iOS 仍是 chat
  子集，不链接 Tools/Permission/AgentKernel/Cowork。

### English / 简体中文本地化

本地化变更至少要同时验证 source catalog、动态 key 和最终 App bundle，不能只看 Xcode 中是否出现语言：

```sh
xcrun xcstringstool compile Apps/SharedResources/Localizable.xcstrings --output-directory /private/tmp/intatis-l10n-catalog --language en --language zh-Hans
plutil -lint Apps/IntatisiOS/Resources/{en,zh-Hans}.lproj/InfoPlist.strings
plutil -lint Apps/IntatisiOS/Resources/Settings.bundle/{en,zh-Hans}.lproj/Root.strings
xcodegen generate
```

- 每个产品 key 必须有非空 `en` / `zh-Hans` value；格式 value 的占位符类型、数量和重复次数必须与 key 相同。
- 构建后精确检查主 App 自身的 `en.lproj/Localizable.strings` 与 `zh-Hans.lproj/Localizable.strings`，不要误命中 vendored Markdown bundle 自带的语言资源。iOS 还要检查 `Settings.bundle/{en,zh-Hans}.lproj/Root.strings` 和主 bundle 的 `InfoPlist.strings`。
- 语言路由用系统/App Language 或 `Bundle.preferredLocalizations(from:forPreferences:)` 做确定性检查；不要在同一测试进程里改 `AppleLanguages` 后复用已经初始化的 `Bundle.main`。
- 运行态检查至少覆盖 English 与简体中文各一次启动，并确认用户/模型正文、session/agent 名、provider/model ID、路径与代码没有被翻译。renderer 当前仍为 release NO-GO 时，不得为了语言验收擅自启动 renderer fixture；未做 GUI 检查须明确记录为 `UNKNOWN`。

## 测试

```sh
swift test                  # 全部无头 XCTest
make test                   # 同上
swift test --filter IntatisCoworkTests
swift test --filter AutomaticPermissionReviewTests
swift test --filter PermissionReviewControlPlaneTests
swift test --filter PermissionReviewProtocolTests
swift test --filter ToolRegistryLeaseTests
swift test --filter ToolExecution
swift test --filter AgentLoopPolicyTests
swift test --filter AgentInvocationNonRecursiveTests
swift test --filter SpawnAgentPermissionTests
swift test --filter OrchestrationReliabilityTests
swift test --filter ProcessShellRunner
swift test --filter IntatisPermissionTests/ReviewerTests
swift test --filter IntatisConversationTests
swift test --filter IntatisProvidersTests
swift test --filter IntatisConversationCodeTests
swift test --filter IntatisAgentKernelTests
swift test --filter CoworkEndToEndTests
swift test --filter IntatisToolsTests
swift test --filter IntatisPermissionTests
swift test --filter CapabilityLeaseTests
swift test --filter TaskGoalProtocolTests
swift test --filter TaskGoalProjectionTests
swift test --filter WorkTaskRuntimeTests
swift test --filter GoalManagerRuntimeTests
swift test --filter GoalVerifierControlPlaneTests
swift test --filter GoalRuntimeControllerTests
swift test --filter BoundedSessionRuntimeShutdownTests
swift test --filter ExplicitGoalIntentClassifierTests
swift test --filter MessageRenderingTests
swift test --filter ExecutionTracePresentationTests
swift test --filter InferenceProfileProtocolTests
swift test --filter InferenceCatalogTests
swift test --filter InferenceCatalogStoreResolverTests
swift test --filter PerAgentInferenceProfileTests
swift test --filter CoworkInferencePresentationTests
swift test --filter SessionStateProtocolTests
swift test --filter SessionProjectionStoreTests
swift test --filter AutomaticPermissionReviewTests
swift test --filter TurnOutcomeProtocolTests
swift test --filter PermissionSettlementTransactionTests
swift test --filter PermissionProjectionTests
swift test --filter AgentLoopOutcomeTests
swift test --filter SandboxDenialOutcomeTests
swift test --filter WorkspaceSandboxDenialTests
```

- 测试 target（11）：`Packages/<Mod>/Tests/`，包含 `IntatisSharedUITests` 的 `MessageRendererModeTests` / `MessageRenderingTests` / `CoworkInferencePresentationTests` / `ExecutionTracePresentationTests`。
- `swift test` 仍可无头运行：无测试 target 依赖 app target；`IntatisSharedUITests` 会 import SharedUI，但不打开 app 窗口。
- `ExecutionTracePresentationTests` 当前 7 项，覆盖默认隐藏、后台 launch argument、truthy/false/unknown environment parsing、默认保留 conversation/`.agentToAgent`/error、已配对 task lifecycle mirror 隐藏、task-only fallback 保留，以及 debug opt-in 完整恢复旧 transcript。`IntatisConversationCodeTests` 当前 15 项，另覆盖投影及 main/worker 同-task exact 配对、跨大 seq/intervening stats、正文不同、跨任务同文、task-only、retry 不继承旧配对、旧 attempt terminal 迟到时按 exact `{TaskID, attempt}` 隔离，以及四类 Agent 通信 exact `sender->recipient` identity/body/timestamp。2026-08-02 最新运行把这两组与 `ThreadLayoutTests` 组合执行 **32 tests / 0 failures**；layout 回归另冻结 Cowork zero-divider 宽度守恒、trailing overlay、scroll-content margin 与最右透明边缘不命中测试的源码合同。命令使用仓库已有依赖与 `/private/tmp` module cache；SwiftPM 用户级 cache 只产生只读 warning，不影响构建或测试。此前完整 `IntatisConversationTests` 127/127、`swift build --disable-sandbox`、`xcodegen generate` 与 IntatisMac macOS Debug（`CODE_SIGNING_ALLOWED=NO`）build 通过。真实 `cowork_9mdz9qkh` 只读检查确认 seq 15/1553/1557 的 task/message/task terminal 同属 `task_h3p3lvij`/`main`/attempt 1，两个 2478-character result 的 SHA-256 相同。最新 App 构建与运行态视觉结果见本轮后续验证记录及根目录 `design-qa.md`。
- assistant/agent 名称旁时间变更至少运行 `IntatisConversationTests`、`IntatisConversationCodeTests`、`MessageRenderingTests`、`ExecutionTracePresentationTests` 与 touched app builds。静态检查要确认 Chat/Code projection 使用首个 `Envelope.ts` 且 streaming completion 不覆盖，Chat/Code/Cowork 只在 assistant/agent header 消费；格式验收按滚动边界检查 `<24h` 仅时间、`24h..<7d` 星期+时间、`>=7d` 年月日+时间，并在系统 locale/time-zone/12–24 小时设置下确认本地化。renderer 仍为 NO-GO 时不得为了这项元数据启动 App/fixture；源码构建通过不等于 Light/Dark 运行态视觉通过。
- 2026-07-22 assistant/agent 名称旁时间当前验证：`swift test --disable-sandbox --filter 'IntatisConversationTests|IntatisConversationCodeTests|ExecutionTracePresentationTests|MessageRenderingTests'` 实际执行 **161 tests / 0 failures**；`swift build --disable-sandbox`、IntatisMac macOS Debug、IntatisiOS Simulator Debug（均 `CODE_SIGNING_ALLOWED=NO`）通过。第一次全新 scratch 测试没有进入编译：依赖 checkout 需要网络而当前代理不可达；改用仓库已有 exact-pinned `.build/checkouts` 后通过。未启动 App/renderer fixture；运行态时间文案与跨阈值静止页面自动重绘仍为 UNKNOWN。
- Per-agent inference profile 的五个 focused suite 分别覆盖 additive protocol/legacy decode、immutable catalog/revision/options 安全、owner-only store + exact resolver、strict Cowork invocation/spawn/rebind，以及 SharedUI 安全投影。Store 回归包含 32 个独立 reconciler 的并发 revision allocation/历史保留，以及 lock owner、`0600`、no-follow 符号链接拒绝和不安全既有 lock fail closed。Strict runtime 回归必须同时证明 provider-only factory 不能开启 exact-binding mode、resolved binding/model/provider tuple 不一致及 safe route/trust/egress mismatch 在 durable admission/provider request 前拒绝、macOS/CLI 使用 atomic resolver seam。Durable connection 回归必须拒绝带 user-info、query 或 fragment 的 base/chat HTTP(S) URL；durable options 回归必须覆盖 allowlisted sampling/reasoning/thinking/output/provider routing shape，以及 unknown key、错误 shape/size/depth、secret/auth/header/query/URL/endpoint、structural/stream/multi-candidate fields 的 fail-closed；Chat/Code `ProviderEndpoint` arbitrary JSON lossless 需单独保留。Request builder 回归必须证明所有 OpenAI-compatible Chat/Agent 请求都会清除配置 `stream_options`/多候选字段；新式 compatible/OpenRouter adapter 必须省略 `n` 和 metadata-derived `parallel_tool_calls`，legacy wire 仍显式 `n = 1`，只有 host `includeUsage` 可重建受控 usage shape，output ceiling 会按 normalized key 清除大小写与常见分隔符变体的 token aliases。Orchestrator 回归还要覆盖 catalog update 与 admission/rebind 串行化、spawn/rebind 在 suspended exact resolver 返回后的 approved-map/roster/fingerprint 重检，以及 `@main`/control-plane-only startup gate + ordinary unresolved-worker invocation isolation：坏 worker 的 queued invocation 必须在 provider request 前 durable failed、清除 busy fence，其他 agent 仍可运行，随后才能显式 rebind。AgentKernel/Event protocol 回归还必须验证 unknown/invalid 与全部 `spawn_agent` inference-control raw args 在 `.tool_call` 前替换为 bounded redacted placeholder，valid non-control args secret-scrub/限长，digest/count/redacted fields additive round-trip/legacy decode，且 malicious endpoint/header/api_key 字符串不出现在 JSONL。CLI `intatis selftest` 还要覆盖 multi-route/model/variant、旧 revision、exact credential isolation、unqualified unique-model route 与 missing reasoning variant fail-closed；另做 non-empty missing-main recovery smoke，确认只接受显式 `/agent restore-main <path> <profile-id>`。macOS 测试要证明 raw variant config key 不进入 durable binding/EventLog。Provider/protocol/conversation 回归还必须覆盖 complete HTTP(S) diagnostic URL → `[REDACTED_URL]`，以及 HTTP 30x 在 transport 层不跟随 redirect、直接 fail closed。若改到 Orchestrator admission、permission target、scheduler 或 app/CLI integration，还必须补跑 `IntatisCoworkTests`、`IntatisAgentKernelTests`、权限/authorization 相关 suites、`swift build` 和 touched Xcode/CLI target，不能只跑上述五组。
- 2026-07-14 Task/Goal final-design 最终验证：`TaskGoalProtocolTests|TaskGoalProjectionTests|ExplicitGoalIntentClassifierTests|WorkTaskRuntimeTests|GoalManagerRuntimeTests|GoalVerifierControlPlaneTests|GoalRuntimeControllerTests|OrchestrationReliabilityTests|MessageDelegationSplitTests` 聚焦过滤运行 **121 tests / 0 failures**。完整 `swift test --disable-sandbox --quiet` 执行 **605 tests / 14 skipped / 34 failures（9 unexpected）**；失败全部位于既有 `IntatisToolsTests` process/loopback 场景，输出为当前宿主拒绝嵌套 `sandbox-exec`（exit 71）或 loopback bind，Task/Goal 与其余 suite 无失败。`swift build --product intatis`、IntatisMac macOS Debug Xcode build 与 IntatisiOS Simulator Debug Xcode build 均成功，CLI `--help` 显示 durable Cowork `/goal` 入口。竞态/恢复回归覆盖 readiness 重算、并发 auto-worker 原子 reservation、取消持久化失败 quarantine、late scoped mailbox durable discard、persistent startup scheduler gate、mutation/pending-stop/shutdown fence、post-launch start cancellation、host-derived validation evidence、typed provider hard usage limit 与完整 Goal Edit reset。Computer Use 成功启动本轮构建的 IntatisMac、恢复 Cowork、打开 Project sheet，并在 composer 输入未发送的 `/goal` 草稿确认发送按钮启用，随后清空；未向真实 provider 发送请求，因此有活动 durable Goal 时的 Goal/Tasks 按钮与长期恢复视觉 flow 仍为 UNKNOWN。
- 2026-07-16 自动权限审查源码审计整改最终验证：`ToolRegistryLeaseTests` 12/12、`PermissionReviewProtocolTests` 8/8、`PermissionReviewControlPlaneTests` 26/26、`AutomaticPermissionReviewTests` 19/19、`AgentLoopPolicyTests` 27/27、`AgentInvocationNonRecursiveTests` 11/11、`SpawnAgentPermissionTests` 10/10、`OrchestrationReliabilityTests` 33/33，8 个 suite 合计 **146 tests / 0 failures**；`IntatisConversationTests` selected run **67/67**（其中主测试类 29/29），独立终审复跑权限/Conversation 相关组合 **164 tests / 0 failures**。覆盖同一 registry registration 的 schema/tool/canonical permission/membership/executor、`write_file`/`apply_patch` 等价 `filesystem.edit`、snapshot registry/spec/args/lease drift fail closed、review prompt secret redaction 与 field/character bounds、空 reason、risk downgrade、review-settled→resolved 与 resolved→prepared 重启窗口、denied/invalid write completion guard、后续同资源成功 edit 清证据、auto delegate 审批前 exact `worker-N` 且 deny 不创建 worker、`ask_agent` 请求或返回路径被 Mediator 拦截时均无 succeeded settlement且 scheduler terminal 不早于 reply delivery settlement，以及 attach batch WAL 的完整/部分/损坏/错配/live-reader 恢复、wrong-session/known-corrupt checked replay 失败关闭。完整 `swift test --disable-sandbox` 执行 **678 tests / 14 skipped / 36 failures（9 unexpected）**：34 条断言来自当前 outer sandbox 阻止既有 `IntatisToolsTests` nested `sandbox-exec` / loopback，另 2 条来自用户现有 `MessageRenderingTests.testBundledHighlightJSEngineReturnsTheExactSource` 在该 XCTest 环境返回 nil；权限专项、Conversation/EventLog 新增回归与其余 suite 全部通过。最终使用 `/private/tmp` module cache 的 `swift build --disable-sandbox` 成功。此前本轮 IntatisMac macOS Debug 与 IntatisiOS Simulator Debug Xcode build 均成功；最终重跑因托管 outer sandbox 阻止 SwiftPM manifest 的嵌套 `sandbox-exec` 而停在 package graph，日志没有源码编译诊断，unsandboxed xcodebuild 自动审批被拒绝。Computer Use 使用现有本轮 macOS 产物恢复 `Test Dijkstra`，确认 `@permission-reviewer enabled`、`2 agents · 0 running`，空 composer 禁用 Send、未发送草稿启用 Send、清空后再次禁用；没有发送 provider 请求。

- 2026-07-16 per-agent inference profile **终审前基线**：focused run **62/62** 通过；offline CLI `intatis selftest` 通过；完整 SwiftPM **734 tests / 14 skipped / 0 failures**；IntatisMac macOS Debug 与 IntatisiOS Simulator Debug Xcode build 均通过。Computer Use 启动当时最新 Debug app，验证旧 session 的 unresolved `@main` fail-closed、Phase A 前的 composer/Send disabled，以及 Project sheet 的 future default profile 和逐 agent `Legacy`/Rebind menu；没有保存 rebind，也没有发送 provider 请求。其后新增 URL diagnostic redaction、30x fail-closed、CLI restore/selection、main-only startup gate + unresolved-worker invocation isolation、opaque variant ID 与 attach/bootstrap TOCTOU 收口；这些新增项的最终数字/Computer Use 不能沿用该基线，以本轮总体验证记录为准。
- 2026-07-16 per-agent inference profile **最终复验**：独立终审未发现剩余 P0/P1；最新 delegation TOCTOU 专项为 `PerAgentInferenceProfileTests` **20/20**、`AgentInvocationNonRecursiveTests` **11/11**、`MessageDelegationSplitTests|OrchestrationReliabilityTests|WorkTaskRuntimeTests` **53/53**，并确定性覆盖 reuse-existing 在 suspended Mediator 后的 rebind/catalog mutation，以及 create-proposed 在 suspended spawn resolution 后的 catalog mutation；两者均不产生未审 task/provider request。另有 unknown-tool EventLog 脱敏、durable connection URL query/fragment 拒绝、normalized token-ceiling aliases 三项 **3/3**。最终完整 `swift test --disable-sandbox --scratch-path /private/tmp/intatis-root-tests` 为 **747 tests / 14 skipped / 0 failures**，offline CLI `intatis selftest` 通过，`xcodegen generate`、IntatisMac macOS Debug 和 IntatisiOS Simulator Debug build 均成功。Computer Use 明确重启最新 IntatisMac 产物并恢复 `Test Dijkstra`：unresolved `@main` 保持 fail closed，Phase A 前的 composer/Send disabled；Project sheet 显示 future default profile 与 `@main Legacy`，Rebind menu 列出 host-approved profiles；随后取消 menu/sheet，未保存、未发送、未请求真实 provider。

- 2026-07-19 Phase S 最终验证：`SessionStateProtocolTests|SessionProjectionStoreTests|IntatisConversationTests|IntatisCoreTests|AutomaticPermissionReviewTests` combined focused run **137/137**；独立 scratch 目录完整 SwiftPM **785 tests executed / 14 skipped / 0 failures**；`swift build`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均成功。除原 settings/projection/bookmark/seven-event/recovery 覆盖外，终审回归还验证 legacy display-name append 失败与 commit-before-rebuild 中断、EventLog return/stream/replay/raw JSON canonical 一致、非法 settings revision CAS fail-closed、revision overflow-safe，以及 primary bookmark 默认不可删除/仅显式事务回滚可清理。App 层静态/构建复核 shared workspace 零引用清理、primary 的 UI/方法/store 三层保护、scope-first symlink alias→canonical settings-before-marker 迁移和 Cowork 实际入口先迁移 legacy name。Computer Use 先前验证新建/重启、缺 plist、错误目录拒绝与 exact original directory 重授权；最终最新 build 又恢复 `cowork_mire6j2d`，确认 reviewer enabled、`2 agents · 0 running`、Project settings、未发送草稿 enable/clear，并在最后补丁后确认 primary Trash disabled。退出后磁盘为 37 events / last `seq 36` / projection 36，初始七事件不变，无 user/task/permission-review-request，`session.json` 与 plist 均 `0600`。未发送 provider 请求；真实 App Sandbox symlink picker 与 shared-worker removal UI、Phase A/B/L 仍未覆盖。
- 2026-07-28 分发勘误：上一条 Phase S 历史记录中的“App Sandbox
  symlink picker 未覆盖”已随 Mac App Store 产品面退役，不再是当前验证缺口；
  shared-worker removal UI 和其他非 App-Store 项仍按各自状态处理。
- 2026-07-20 Phase A 最终验证：`IntatisArtifactsTests|ContextProjectionTests|SubmittedIntentHistoryTests|SubmittedIntentStoreTests|SubmissionProjectionTests|SubmissionProtocolTests|TaskContractTests|CoworkMentionRoutingTests|OrchestrationReliabilityTests|AutomaticPermissionReviewTests` combined focused run **122/122**；独立 scratch 目录完整 SwiftPM **824 tests executed / 14 skipped / 0 failures**；`swift build`、`xcodegen generate`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均成功。覆盖 stable `SubmissionID`、outbox-first + canonical two-event admission、one-based monotonic attempt、exact retry/no duplicate message、projection/context correlation、FIFO/restored-root pause、reviewer-unavailable ordinary request、owner-only ArtifactStore 与 unsafe mode/symlink/hardlink 拒绝。第一次 full run 在既有 Tools process 段长时间无输出后被有界中止，附近两个 process tests 单独均通过；随后全量复跑为上述 824/14/0。Computer Use 使用最新 Debug app 打开 reviewer failed 的历史验证 session，确认 composer 可编辑、Send 可用，点击后显示同一 submission 的 `route_unavailable` retry card，失败后仍可编辑；附件 picker 在 reviewer failed 时也可导入本地文件并启用 attachment-only Send。磁盘只新增 `user_message → queued(attempt 1) → failed(route_unavailable, retryable)`，outbox 已 reconciliation，无 task/permission/model-output 事件。未发送真实 provider 请求；当时 Phase B 与 Phase L 尚未完成，二者已由后续独立实施与验证记录取代；Artifact orphan GC/掉电矩阵仍 UNKNOWN。
- 2026-07-20 Phase B 最终验证：`ToolRegistryLeaseTests|PermissionReviewProtocolTests|PermissionReviewControlPlaneTests|AutomaticPermissionReviewTests|AgentLoopPolicyTests|AgentInvocationNonRecursiveTests|SpawnAgentPermissionTests|OrchestrationReliabilityTests` combined focused run **164/164**。覆盖 timeout/cancel 只影响当前 call、active `{reviewTaskID, nonce}` generation 只 retire 当前代、下一次 fresh provider allow、old late allow 不改变 settlements、replacement 不继承隔离、provider factory 单次失败恢复、真实 write tool 第一次 timeout 零执行/第二次 fresh allow 恰好一次执行、terminal claim 后 settlement append suspension + caller cancel 的单 settlement/deny delivery、pre-submit caller cancel 不误报 control-plane shutdown、caller-cancelled attach 不登记 Agent、post-review inference resolution 暂停期间取消不能越过最终 durable-admission fence，以及 quiesce 后 durable detach 失败 resume 时 fresh generation 与旧 allow 无效。所有 late-producer 断言都等待显式 finished ack，不使用固定 sleep。legacy `provider_still_stopping` decode 继续通过，但 permission reviewer runtime 不再产生该恢复状态。`swift build --disable-sandbox`、`xcodegen generate`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均成功。本轮 root full SwiftPM 在沙箱内先遇到既有 Tools nested Seatbelt/loopback 限制；脱离外层沙箱后相关 process tests 开始通过，但完整 run 在既有 `IntatisToolsTests` structured-process 段长时间无输出后有界中止，不能记作 full pass 或源码失败；卡点附近 `testStructuredProcessShellRunnerStillSupportsToolBackendCommands` 单独 1/1 通过。Computer Use 启动最新 Debug app，恢复 reviewer failed/disabled 历史 Cowork session，确认状态 banner 显示 input remains available / ask-class tools fail closed；空输入 Send disabled，本地未发送草稿使 Send enabled，清空后再次 disabled。未点击 Send、Retry、Reauthorize，未请求真实 provider；真实 endpoint cancellation/服务端停止时序仍为 UNKNOWN。

- 2026-07-20 Phase T 最终验证：`ToolExecutionProtocolTests|ToolExecutionProjectionTests|AgentLoopPolicyTests|WorkTaskRuntimeTests|GoalRuntimeControllerTests|OrchestrationReliabilityTests` combined focused run **128/128**（5+8+29+13+31+42）。覆盖 optional field 缺失解码、new success 显式 committed、legacy succeeded/nil 兼容完成、`succeeded + not_started` invalid/uncertain、duplicate prepare（含相同 payload）永久 ambiguous 且保留首张、相同 duplicate settlement 幂等保留首条、冲突 terminal 永久 ambiguous、production adapter 独占 stale no-effect 转换、pre-executor cancel 先结算后中断、executor-entered cancel 保持 unresolved，以及 zero-settlement/non-ambiguous legacy repair。restore/legacy repair、Goal startup、进程内 launch 与 whole-task retry 均要求 `replayForProjectionChecked().hasCompleteKnownHistory`，unknown future event 或 `seq` gap 无法支持 absence/order proof并 fail closed。最终源码后 `swift build --disable-sandbox` 成功。Phase T 未运行 full SwiftPM、Xcode/UI、真实 provider 或真实 legacy session restore 演练；这些仍是外部验证边界。
- 2026-07-20 Phase C 最终验证：`TurnOutcomeProtocolTests|PermissionSettlementTransactionTests|PermissionProjectionTests|AgentLoopOutcomeTests|SandboxDenialOutcomeTests|WorkspaceSandboxDenialTests|PermissionReviewControlPlaneTests|OrchestrationReliabilityTests` combined focused run **126/126**。覆盖 additive/legacy outcome、manual/automatic mode、approve/decline/cancel-turn、RequestID first-write/first-terminal CAS、exact duplicate/reconnect idempotence、conflicting request/terminal fail-closed、FIFO middle settlement、Decline 后模型继续、Cancel 无伪 tool result、provider self-cancellation 归 runtime failure、可信 sandbox startup denial/no retry、owner/duplicate waiter cancellation、以及 provider/tool cleanup 先于 task terminal/caller return。独立 scratch 的完整 `swift test --disable-sandbox --scratch-path /private/tmp/intatis-phase-c-full` 执行 **895 tests / 14 skipped / 0 failures**；`xcodegen generate`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 成功。Computer Use 用独立 bundle ID 的 DEBUG-only `-IntatisPhaseCPermissionFixture` 验证 Manual 的 `Approve Call`、`Decline Call`、`Cancel Turn` 分别显示正确 notice，Automatic 显示 `Automatic review in progress…` 且没有三个 manual action。fixture 明确不创建 provider、EventLog、credential resolver、responder 或 executor，只证明生产 permission card 的动作区分与 automatic non-actionability；未发送真实 provider 请求。首次以 LaunchServices app-path 重新定位时没有保留 fixture 参数，出现普通产品根界面；未进行任何点击/发送即关闭，正式验收改用 exact executable args + 独立 bundle ID。
- 2026-07-20 Phase L 最终验证：`GoalRuntimeControllerTests` **34/34**，覆盖冷启动 active→paused、达到预算→budget-limited、pause persistence failure fail closed 与显式 Resume；`BoundedSessionRuntimeShutdownTests` **5/5**，覆盖 simultaneous broadcast、monotonic deadline、uncooperative child timed-out、single-flight 与 exact identity first-wins。独立 scratch 命令 `env CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-phase-l-full-validation-clang SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-phase-l-full-validation-swiftpm swift test --disable-sandbox --scratch-path .build/phase-l-full-validation` 执行 **903 tests / 14 skipped / 0 failures**。IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug（`CODE_SIGNING_ALLOWED=NO`）构建成功；最后一次 app-only shutdown hardening 又由 macOS Debug build 编译通过。
- Phase L Computer Use 使用独立 bundle ID `com.vita.IntatisPhaseLDirectValidation` 和 DEBUG-only `-IntatisPhaseLLifecycleFixture`，fixture 只在 `/private/tmp` synthetic ledger 上运行 fake A/B runtime，不创建生产 provider、EventLog、credential、workspace 或工具 executor。实际操作通过：A 运行时切换 B/History 仍继续且 stop count 不变；A/B 同时运行；Command-W 后进程与 ticks 继续；Command-N 复用同一 manager runtime；Command-Q 后 A/B 各 stop/settle 一次；正常重开不自动增长且显式 Resume A 不影响 B；按 exact executable path/launch time 解析 PID 后 `SIGKILL`，重开把 A 的 running 显示为 interrupted 且不续跑；B 进入不合作 hang 时，700 ms deadline 下 Command-Q 在 3 秒内退出，ledger 保留 stopping 而不伪造 settlement，重开显示 interrupted。最终确认 validation 进程无残留。该矩阵证明 app ownership、窗口/退出/重开和 deadline 合同，不证明真实 provider 在服务端何时物理停止，也不替代真实生产 EventLog/tool mutation 边界的 process-kill 演练。

### 对话 Markdown / Microsoft 派生渲染专项

```sh
swift package --disable-sandbox dump-package
swift package --disable-sandbox show-dependencies --format json
swift build --target IntatisSharedUI --scratch-path /private/tmp/intatis-render-build
swift test --filter MessageRendererModeTests --scratch-path /private/tmp/intatis-render-tests
swift test --filter MarkdownSchedulerTests --scratch-path /private/tmp/intatis-render-tests
swift test --filter MessageRenderingTests --scratch-path /private/tmp/intatis-render-tests
xcodegen generate
xcodebuild -project Intatis.xcodeproj -scheme IntatisMac -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intatis-render-mac-dd COMPILER_INDEX_STORE_ENABLE=NO build
xcodebuild -project Intatis.xcodeproj -scheme IntatisiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/intatis-render-ios-dd COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Intatis.xcodeproj -scheme IntatisMac -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/intatis-render-mac-release-dd COMPILER_INDEX_STORE_ENABLE=NO build
xcodebuild -project Intatis.xcodeproj -scheme IntatisiOS -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/intatis-render-ios-release-dd COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
plutil -lint /private/tmp/intatis-render-ios-dd/Build/Products/Debug-iphonesimulator/IntatisiOS.app/Settings.bundle/Root.plist
```

`MessageRendererModeTests` 当前 11 项，覆盖无偏好默认 Microsoft、`microsoft`/`plainSafe` 持久值、旧 `rich` 迁移、新旧 launch override、冲突时 plain-safe 胜出、未知值 fail closed、Unicode 与 CR/LF/CRLF byte identity、空流式占位、role 强制 plain、Microsoft routing 和 stale-document 拒绝。`MarkdownSchedulerTests` 当前 6 项，覆盖全局并发/待处理容量、每 key 单 running + replaceable pending、latest-only publication、取消/finish 生命周期、公平与 output-free snapshot。`MessageRenderingTests` 当前 41 项，除既有 admission/raw/revision/math/viewport 合同外，新增 16-row history window、earlier/newer/latest、旧页 append 稳定、page-scope/selection 隔离，以及同一原生 `NSHostingView` / `NSScrollView` 对 16 个 rich row 执行 4 轮 top↔bottom 并冻结 `ParagraphNSView` identity。`ThreadScrollCoordinatorTests` 当前 30 项，另以源码结构测试冻结 macOS Chat/Code/Cowork transcript 使用 bounded `VStack` + `ForEach(historyWindow.items)` + pager，且该范围不含 `LazyVStack` / `IntatisAdaptiveThreadStack`。新增两项分别证明 raw restore 后更新一代的 native bottom geometry 可以释放 rich admission，以及 restore 前 stale bottom geometry 必须拒绝。2026-07-31 两套 focused 合计 71/71；此前 vendor full 77 XCTest + 11 Swift Testing = 88/88 与 strict Release `-warnings-as-errors` 仍是独立既有结果。这些单元测试本身仍不能推导真实 clipboard/VoiceOver、current-container 长 soak 或真机通过。

零覆盖防护：`MarkdownSchedulerTests` 无整文件 feature gate；`MessageRenderingTests` 只用显式 `#if os(macOS)` 标出 Apple UI 测试平台，并在该平台强制 `import SwiftStreamingMarkdown`。macOS production dependency 缺失会直接编译失败，不允许再用 `canImport` 把整个 suite 静默变成 0 tests。验证记录仍必须报告 discovery 数量和关键测试名。

生产 facade 不允许在 Intatis 内检查/改写 Markdown AST；测试应把 facade 边界放在 admission/backpressure/revision/config 和派生包公开 API。必须断言：raw >64 KiB 完全不申请 parser；未完成 parse 更新先 debounce 50 ms；每 view 只保留最新 request；scheduler 最多 1 running/32 pending 且不存 work/document/result；取消或 stale finish 不发布；只有 raw/mode/completion/appearance/config 全匹配的最新 document 可替换 raw Text。raw 投影还必须断言 append-only 使用固定 100 ms leading/trailing deadline、只读最新 revision、final/correction/truncation/reentry 同步精确、旧 timer generation 无效、rich/fallback 分支共享状态、parser document 已为 nil 时不重复触发 `@Published`。vendor 公式测试必须覆盖 `$...$` / `\(...\)` inline、`$$...$$` / `\[...\]` display、display 跨行、未闭合流式前缀、完成/替换、escaped delimiter、currency、相邻字符、inline/fenced code、link/image/autolink/raw HTML、多 candidate、无效 TeX fallback、原始 source attachment 与 inline/display iosMath mode；还要验证超过旧 32 个公式、旧 8 KiB 单式和旧 1024pt attachment width 时仍正常 admission/preflight。不得重新加入公式数量、单式字节或固定 attachment 尺寸上限，也不得恢复旧 regex `LaTexPreProcessor`、旧 cmark source-range、highlight cache 或 Intatis 私有 layout 测试。

2026-07-18 事故前 latest-source 验证：focused 37/37；完整 SwiftPM 755 tests、14 skipped、0 failures。该 full 数字是事故前且数学变更前的基线，不得冒充当前 pass。事故后新增 selection ownership 测试后，`MessageRenderingTests` 为 21/21，vendored derivative strict Debug/Release 各 44/44；vendor iOS Simulator test target `build-for-testing` 成功（compile-only，未启动 test host）；当时的 IntatisMac/IntatisiOS Debug/Release build、macOS/generic iOS unsigned Archive 与六-app bundle/notice/settings scan 成功。2026-07-23 iosMath 依赖准入只证明 exact commit 上的 macOS SwiftPM Debug/Release、compile-only `swift build --build-tests` 和 unsigned iOS Simulator Release build；上游 test executable 未运行，Intatis delimiter/UI/accessibility/performance 也尚不能由这组依赖证据证明。事故后 root full 尝试在既有 `IntatisToolsTests` nested `sandbox-exec` / loopback failures 后无输出挂起并人工中止。外层受限 sandbox 的 manifest/module-cache 或 Tools process/loopback 限制不能冒充源码失败；同样也不能把一个未完成的 full run 写成通过。swift-markdown 传递清单仍是 Swift 5 language mode，iosMath 是 Objective-C target，不能宣称整个依赖图 strict-clean。

当前安全启动前置为 `scripts/RendererValidationWatchdog.swift`。它只接受 bundle ID、编译进二进制的 fixture marker、调用方显式提供的 executable SHA-256 与固定 fixture SHA-256 全部匹配的 validation build，并且缺少 `--user-approved-gui` 时在启动前 fail closed。每个 `run` 还必须显式给出 `--math disabled|single-dollar`；不得以缺省值或 plain-safe 替代同一 Microsoft renderer 的数学 A/B。2026-07-18 无 GUI 自测 8/8 通过，clean exit、wall/RSS/rolling-CPU fuse、process-group cleanup、unexpected exit、telemetry failure 与 lock contention 均符合预期且每例二次确认清理；watchdog 以 `-warnings-as-errors` 编译成功。数学变更前 historical SHA `1fe134ee…` 不得复用；2026-07-24 当前数学 validation executable SHA-256 为 `ec56cec173c13e41edb4f53e3ff5fcb1ac3d35079d40f140c4503a4d99dde55f`。fixture SHA-256 继续固定为 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`。watchdog containment 已通过记录见本节顶部，但它仍不是长时 release 性能证明。

```sh
<watchdog> run --user-approved-gui \
  --app <IntatisMac.app> --expected-app-sha256 <CURRENT_EXECUTABLE_SHA256> \
  --fixture Tests/Fixtures/incident-1249-sanitized-v1.json \
  --output <NEW_DIRECTORY> --stage math-structure --renderer microsoft \
  --math single-dollar --appearance light --profile isolation
```

公式专用 stage 包括 `math-one`、`math-thirty-two`、`math-structure`、
`math-history` 与 `math-stream`；`math-structure` 覆盖标题/列表/引用/表格，
`math-history` 覆盖多消息历史与离开后重入。对应 A/B 必须只切换
`--math disabled` / `--math single-dollar`，其他参数保持一致。

以下是历史离线 fixture 参数，不创建 `AppEnvironment`、provider、session 或凭据 resolver。**不得直接手动执行这些命令，也不得并行启动实例。** 2026-07-24 的用户批准只覆盖本次已记录、由父 watchdog 启动的单子进程；未来重新验收仍需明确授权，并同时设置 wall time、RSS/footprint、CPU 和实例数 hard limit，越界立即终止并验证残留实例为零：

```sh
<DerivedData>/Build/Products/Debug/IntatisMac.app/Contents/MacOS/IntatisMac -IntatisRendererFixture -IntatisPlainSafeMessages
<DerivedData>/Build/Products/Debug/IntatisMac.app/Contents/MacOS/IntatisMac -IntatisRendererFixture -IntatisMicrosoftMarkdownMessages -IntatisAppearanceLight
<DerivedData>/Build/Products/Debug/IntatisMac.app/Contents/MacOS/IntatisMac -IntatisRendererFixture -IntatisMicrosoftMarkdownMessages -IntatisAppearanceDark
# 旧参数仅作迁移回归
<DerivedData>/Build/Products/Debug/IntatisMac.app/Contents/MacOS/IntatisMac -IntatisRendererFixture -IntatisRichTextMessages
```

2026-07-18 Computer Use **FAIL / ABORTED** 现在是历史事故记录：验收错误地并存三个 validation app，Force Quit 对主实例显示 129.63 GB application memory；CPU diagnostic incident `FA228932-2C40-4AC2-A0C2-62EF41342B4A` 记录 sampled footprint 109.16 MB→803.30 MB。该值不是精确 RSS，根因仍为 `UNKNOWN`。2026-07-24 已完成单实例 math-disabled/enabled structure A/B、1/32/history/stream isolation 与 Light/Dark structure Computer Use，全部受 watchdog 约束并清理无残留；结果见本节顶部。未来 selection/clipboard/VoiceOver、长 session 或 >160 秒 soak仍不得在 watchdog 外启动/保留 app，任何越界继续保持 NO-GO。

后续 Computer Use/手动验收继续按以下顺序：验证 plain-safe 救援闭环，记录目标 `events.jsonl` 的 hash/size/mtime；以 `-IntatisPlainSafeMessages` 启动并恢复问题 session；确认消息 AX ID 为 plain、公式原文、可滚动/选择/复制且没有持续等待光标；在启动 override 仍生效时把 Picker 保存为 Plain；退出后不带 renderer 参数重启并再次恢复；最后复核 EventLog 未被 renderer mode 重写。2026-07-24 同一 Microsoft renderer 的 math-disabled/legacy-single-dollar 结构 A/B、标题/列表/引用/表格可见性、literal code 和 AX source 是旧语法证据；当前四类 delimiter/no-local-cap 实现仍需新的真实 selection/clipboard、完整 Copy、长行水平滚动、安全链接和真实问题 session 持续滚动。code 中 dollar/parenthesis/bracket delimiter、currency、escape 与未闭合 form 必须继续保留字面；code 外合法 `$...$` / `\(...\)` / `$$...$$` / `\[...\]` 的 clipboard 必须是原始 TeX 而非空白或 U+FFFC。plain-safe 只能证明救援路径，不能冒充 no-math baseline。图片不得发起加载，table 不显示 copy/download actions；滚动/切换期间应持续响应，旧 revision 不得闪回覆盖新 raw 文本。不必向真实 provider 发送请求。

2026-07-21 小滚动条缺陷复验：真实 `cowork_9mdz9qkh` 在 execution trace 默认隐藏后只有 2 条顶层可见行，其中 assistant rich row 高约 2,879pt。旧 `LazyVStack` 下原生滚动值 0.25/0.50 可达，但设置 0.75 会跳为 1.0；改用 adaptive 容器后 0.25、0.50、0.75、1.0 均保持对应位置，连续滚动也观察到 0.683105，证明原来不可达的中后段已恢复。最终单实例在约 3 分 43 秒、多次滚动与 AX 操作后的 RSS 抽样为 216,992 KiB，未观察到短时线性 runaway；这不是长时 watchdog/malloc retaining-edge 证据，不得据此解除历史 release NO-GO。最终源码下 `MessageRenderingTests` 22/22，IntatisMac macOS Debug 与 IntatisiOS Simulator Debug 均 build succeeded；未运行完整 SwiftPM、长时 renderer watchdog 或真实 iOS 设备测试。

2026-07-30 session-entry/scroll 最终复验必须与旧小滚动条结果分开记录。同一 `cowork_tf2lkjbh` 下 rich+lazy 卡死、plain+lazy 正常、rich+eager 正常，且仅关闭代码块/表格 selection 不能消除卡死；sample 需能区分 AttributeGraph flush、SelectionOverlay、bottom probe 和 coordinator。当前产品回归必须至少覆盖：macOS Chat/Code/Cowork 源码结构无消息级 lazy；13-row/5-rich 问题 session 首次进入；原生 scrollbar 多个中间值与 top/bottom；A→B→A；超过 16 条时 Earlier/Newer/Latest；停留旧页时 append 不换页；current page 独立 scope；操作后 CPU 回落与无新 hang bundle。2026-07-30 实测 scrollbar 为 `1 → 0.807806 → 0.615613 → 0.423419 → 0.615613 → 0.807806 → 1`，55-message session 可在 `40–55`、`24–39` 与 Latest 间切换，操作后 CPU 抽样 0.0%。没有发 provider 请求或改 EventLog。共享 iOS Chat 必须单独验证。

性能 fixture 必须使用 `Tests/Fixtures/incident-1249-sanitized-v1.json`，先核对 SHA-256 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`，分别记录 Release plain-safe、Microsoft math-disabled、Microsoft math-enabled 的 5 次 cold open、20 次 replay、主线程 stall、interaction、parse 与 settle 分布，异常值不得只报平均数；公式成本判断必须比较后两者，不能拿 plain-safe 当 no-math baseline。watchdog 的 `--math single-dollar` 目前是兼容保留的 enabled token，patch group 12 后实际开启全部四类 delimiter。host 必须直接依赖 production `IntatisSharedUI` 并实例化真实 `IntatisMessageContentView`；当前 macOS 产品容器必须匹配最多 16-row 的 bounded eager history page，并另用至少 17 条验证显式 paging，不能再以 `LazyVStack` fixture 冒充 production。全局无界 eager 仍不是产品；旧 17-row eager A/B 也不等价于当前 16-row page。另以常见四类 delimiter、40 个公式和流式 replacement 分阶段测 iosMath native label 的同步主线程 parse/update；watchdog 现有 20–35 秒只是 abort containment，不能覆盖历史 160 秒事故窗口或替代长时 soak。复制 reducer 或单独写一个相似 `Text` benchmark 不算 facade 证据。plain 的 100 ms publication cadence、fixed deadline 和 latest-only 读取由纯 reducer 的虚拟时钟测试证明；真实 facade host 不得为了测量而加入会改变生产 `ObservableObject` publication 路径的 instrumentation，只记录 1,249 次 facade 输入以及最终 source rows UTF-8 bytes + SHA。host 无法从公开 API 读取 `rawState` publication、屏幕或剪贴板，不能把 ingress hash 写成最终可见/复制证据。冻结门为 interaction p95 ≤8 ms、max ≤50 ms，>250 ms potential-hang 行数必须为 0。75 ms Plain 的正式 replay 有 2/20 轮 p95 超门，是拒绝基线而不是可接受结果。macOS/Simulator 通过后仍须在低端真实 iPhone/iPad 复验长表格、快速滚动、Dynamic Type、VoiceOver、旋转、内存压力与附件组合；没有真机证据时必须标为 UNKNOWN。

2026-07-18 事故前窄协议正式结果：75 ms Plain 仍是 rejected historical baseline（replay 2/20 p95 超门）。100 ms Plain 完成 5 cold + 20 replay、25/25 exact、interaction gate failures 0；cold/replay worst p95 为 6.152250/4.370458 ms、max 30.395208/29.591167 ms。当时 production-shaped `LazyVStack` Microsoft 为 5 cold + 20 replay、25/25 exact、interaction gate failures 0；cold/replay worst p95 为 4.020458/4.876292 ms、max 37.840875/36.596500 ms，replay absolute peak/residual RSS 最高 102.953/101.375 MiB，absolute peak/residual footprint 最高 33.173/32.454 MiB。当时 17-row eager `VStack` 对照也 final exact，但 cold 5/5、replay 20/20 的 p95 >8 ms（9.670500/10.140583 ms）。这些数值必须作为历史证据保留，却已被后来的真实 session lazy/native feedback A/B 取代其“生产容器选择”权威；旧无界 17-row eager 也不能冒充当前 16-row bounded page。只有 interaction 8/50 ms 是当时预先冻结的 pass/fail 门；main/RSS/footprint/CPU 是 observational。post-fix xctrace 为 17/17 exact、>250 ms potential-hangs 0，旧 trace 的 17 条 `.task(id: ViewRevision)` 告警只作历史。完整旧 aggregate/hash 与事故勘误见 `codex-report/07_18_26-11_46-swift-streaming-markdown-cutover-implementation-validation.md`。

发布验证不能只停在编译/视觉：根 `Package.swift` 必须保持仓内相对 vendor 路径，派生包必须 exact resolve `swift-markdown` 0.8 / `swift-cmark` 0.8 / iosMath 2.5.0，且不得暴露 probe executable、嵌套 Git/cache、上游 agent instructions 或夹带 Examples/实验/品牌/未声明媒体资源；Microsoft `LICENSE` 与永久 patch ledger 必须随源码保留。需检查最终 Developer ID macOS 与 iOS artifact 中用户可访问 `NOTICE.md` 及三份 `ThirdPartyNotices` 全文并 hash 比对。每个 macOS/iOS 最终 app 必须盘点 `iosMath_iosMath.bundle`：`fonts/` exact payload 为 8 OTF、8 math-table plist、5 license、4 README、`math_table_to_plist.py`，共 26 文件/7,234,424 bytes；完整 Xcode bundle 加生成的根 `Info.plist` 后为 27 文件。还要核对 OTF hashes 与 `ThirdPartyNotices/MathRendering.md`。产物不得含旧 highlight JS/CSS、Copilot palette/media、Cambria Math 或其他未声明资源；八套 iosMath 字体是已声明且经批准的公式资源，不得继续按旧规则误判为残留。

## Lint / Format

仓内无显式 lint/format 配置。`UNKNOWN` — 是否有 SwiftFormat/SwiftLint 需后续确认。建议至少 `swift build` 通过。

## 手动验证矩阵

本矩阵按当前 macOS direct-distribution 产品解释。shell-backed 工具的当前
负面条件是 `read_only/shell-disabled`；不得增加 App Store 产品分支、构建
遗留 target 或恢复已取消的分发约束。

| 场景 | 步骤 | 预期 | 状态 |
|---|---|---|---|
| IntatisMac 默认 workbench entitlement | `xcodegen generate` → `xcodebuild -scheme IntatisMac` → `codesign -d --entitlements - .../IntatisMac.app` | `IntatisMac` 使用 `IntatisMac.DeveloperID.entitlements` 与 `.macDeveloperID`；生成 app 不含 `com.apple.security.app-sandbox`；shell/git/browser 仍需经过权限门 | 本轮通过：XcodeGen 生成 project；`xcodebuild -project Intatis.xcodeproj -scheme IntatisMac -configuration Debug -destination platform=macOS -derivedDataPath /private/tmp/intatis-devprofile-dd COMPILER_INDEX_STORE_ENABLE=NO build` 成功；`codesign -d --entitlements - /private/tmp/intatis-devprofile-dd/Build/Products/Debug/IntatisMac.app` 未包含 `com.apple.security.app-sandbox` |
| production Cowork rich resize/scroll | 真实 entry、A→B→A、连续 zoom/restore、上下滚动、超过 16 条时 Earlier/Latest | 无 hang、无单核持续占满；session 内容、旧页 upper bound 与用户滚动意图保持 | 第一阶段普通 Release 完成 A→B→A、5 次 zoom/restore、8 次 scroll 和旧 lazy-container soak；随后 rich+lazy 的 session-entry freeze 促使产品改为 16-row bounded eager pages。当前 IntatisMac Debug 使用同一 `cowork_tf2lkjbh` 完成首次进入、多个 scrollbar 中间值、A→B→A，以及 55-message `40–55 → 24–39 → Latest`；操作后 CPU 抽样 0.0%、无新 hang incident。current-container >160 秒 soak 仍 OPEN |
| IntatisMac chat | `make app` → Xcode 运行 IntatisMac → chat 发消息 | 流式回复 | UNKNOWN（需真机 + key） |
| IntatisMac 离线对话渲染 fixture | 仅在用户批准且 watchdog 就绪后，单实例 Debug app 加 `-IntatisRendererFixture -IntatisMicrosoftMarkdownMessages`；先 minimal 10–20 秒，再逐阶段操作 Copy、滚动、stream replacement | assistant/agent 内容正确且资源曲线/退出有界；代码可复制、table 无 action、图片不加载、stage 不闪回；任一 wall/RSS/footprint/CPU/实例数越界立即终止 | 2026-07-18 三实例事故仍是历史 adverse baseline：Force Quit 显示 129.63 GB application memory，diagnostic footprint 109.16→803.30 MB，最终 retaining edge `UNKNOWN`。2026-07-24 使用 hash-pinned validation binary 完成新的单实例短时 watchdog/Computer Use：Light/Dark `math-structure`、math-disabled/enabled A/B、`math-one`、`math-thirty-two`、`math-history`、`math-stream` 均 exit 0、资源/退出有界且无残留。该短时证据不能替代 >160 秒 soak、真实 clipboard/VoiceOver 与历史 retaining-edge 解释，因此仍不可标为 renderer release-ready |
| Plain-safe 问题 session 救援 | 资源 gate 通过后：记录 EventLog → `-IntatisPlainSafeMessages` 单实例启动 → 恢复/滚动 → override 下保存 Plain → 无参数重启 → 再恢复；iOS 另检查 Settings 与 bundle | 不进入 rich 路径、不持续等待；append-only 视觉更新有界到 100 ms，semantic/final exact；下次仍 Plain；renderer preference 不写 EventLog；Settings key/values/default 一致 | 事故前 CU 曾验证 legacy `rich`、Plain 下历史 Chat/Code/Cowork 与恢复 Microsoft，但不能冒充事故后修复证据。事故后 iOS Debug/Release/Archive 的 Settings static contract 通过；latest GUI selection/clipboard bytes 与 iOS content 仍 OPEN |
| Microsoft LaTeX 公式 | 同一 validation binary/fixture 先用 Microsoft math-disabled，再启用 math；依次运行 `math-one`、`math-thirty-two`（当前为 40 个兼容 stage）、`math-structure`、`math-history` 与 `math-stream`，覆盖四类 delimiter、display 跨行、code/currency/escape/invalid TeX、Light/Dark、selection/copy/AX；最后检查 macOS/iOS `iosMath_iosMath.bundle` 与 notice hash | 合法 `$...$` / `\(...\)` inline 与 `$$...$$` / `\[...\]` display 进入 native iosMath；code/protected literal、currency、escape、未闭合保持原文；超过旧 32 个/8 KiB/1024pt 阈值不触发本地 cap；fallback/AX/clipboard 保留 exact TeX；plain-safe 完全 bypass；同一 renderer A/B 的主线程 stall、interaction、RSS/footprint/CPU/退出清理有界；`fonts/` 26-file payload、完整 27-file bundle、OTF hash 和五份 font license 匹配声明 | 2026-07-31 focused 39/39 通过；完整 vendor/root/app build 与新四类 delimiter 的真实窗口验证待记录。2026-07-24 两份 lockfile/bundle/license 与旧单美元 A/B/Computer Use 结果仅作 dependency、资源和历史可见性证据；真实 selection/clipboard bytes、VoiceOver 操作、>160 秒 soak、最低支持 macOS 版本与 iOS 实机仍 OPEN，故不可标为 renderer release-ready |
| IntatisMac cowork | Xcode 运行 IntatisMac → cowork → @mention | agent 间路由 + 权限卡片 | UNKNOWN |
| Cowork 同一回答重复显示 | 回放 `task_started → message_completed → task_completed`，并覆盖 main/worker、长 seq 间隔、正文不同、跨任务同文、retry、迟到旧 attempt terminal 与 task-only legacy fallback；分别调用默认/调试展示策略 | 同一 TaskID/agent/attempt 且正文完全相同的 `task_completed` 只在默认 UI 隐藏，真实 `message_completed` 保留；task-only/attempt 不同/正文不同/跨任务同文不误删，旧 terminal 不清除新 attempt；debug 保持两个 `.agent` 行和原顺序；EventLog 与 durable `task_completed` 不变 | 最终 focused 21/21、完整 Conversation 127/127、Swift build 与 IntatisMac Debug build 通过；真实 `cowork_9mdz9qkh` 只读事件/hash 对应通过。未启动 App，GUI 像素与滚动复验仍为 UNKNOWN |
| Cowork durable Goal / WorkTask 四层模型 | 用 fake provider 创建 `/goal` 或明确中英文持续 Goal intent，跨至少两个 ContinuationRun；让 main `task_create` 建依赖 DAG、`delegate_task(work_task_id:)`，worker `task_update` 提交 result/evidence；并发 auto delegation、依赖重规划、两个 write-capable WorkTask 覆盖重叠/unknown `expectedArtifacts`；覆盖 pause/full edit/resume/clear、carry-forward、scoped barrier/cancel、late mailbox send/discard、重启 replay、created/running→checkpoint recovery、unaudited checkpoint reconcile、verifier complete/continue/blocked_candidate、malformed/tool-call/timeout/cancel/provider failure、typed provider hard usage limit、ordinary 429 与 output-limit | Goal / WorkTask / ContinuationRun / AgentInvocation ID 与终态彼此独立；invocation result 仅为 candidate；WorkTask result/evidence 是 agent-reported，Goal proof 只引用 host 从 durable 成功 allowlisted tool settlement 派生的 `validationEvidence`；DAG/revision/readiness 与 `in_progress` execution contract fail closed；worker 只能更新自己绑定任务；并发 auto delegation 原子预留不同 worker；重叠/unknown write set 拒绝第二个 writer；legacy child/mailbox wake 继承 Goal/run scope；host 续跑不嵌套 AgentLoop；carry-forward 原子取消/克隆/重映射；barrier/cancel 只 drain scoped queued/claimed/running，并以 exact Goal/run tombstone + admission barrier 阻止取消竞态中的新 root/provider/message admission；迟到旧 run message 写 `agent_message_discarded`，不写 consumed、重启不复活；Pause/Edit/Clear 只在取消和 durable checkpoint 全部成功后提交；Goal Edit 清除旧 audit/blocker/progress streak；startup scheduler gate、Goal mutation/stop gate、pending-stop retry 与 shutdown fence 先完成 recovery，再显式 resume data plane；start 取消返回前 durable stop 已创建 continuation；每个 checkpointed run 只结算一次 audit，audit+run completed+可选 Goal terminal 是一个有序 batch；complete proof 精确覆盖 objective/criteria/constraints 且逐项有 host-bound evidence；同 blocker 达阈值才 blocked；process restore 与进程内 resume/edit 均在新 run 前保守结算 checkpoint；只有 durable `failureCode=provider_usage_limit` 进入 usage-limited，且 paused current Goal 也能保留该 signal；普通 429/output-limit 不误判 | 本轮最终 focused/full/build 与 Computer Use 结果见本节顶部验证记录；真实 provider 多轮费用、App 进程被杀后的长期恢复与完整 GUI 操作仍属外部矩阵 |
| IntatisMac Cowork Goal/Tasks UI | 新建 Cowork session → 输入 `/goal <目标>` → 观察宽/窄窗口并在无 pending 时手动隐藏 inspector → 展开 Tasks → Pause → Edit，分别修改 objective、success criteria、constraints、token budget → Save → Resume；另以已有 pending permission 检查宽屏固定 rail 与窄屏兜底；Clear 只在明确确认的手动测试中执行 | 宽屏 rail 使用原生 Liquid Glass，顺序为权限审查（存在时）/ `Agents` / `Goal` / `Tasks`，完全不显示 Git；pending 时 rail 固定可见。窄到无法容纳 rail 时只显示一个同请求权限 Material 兜底卡，不复制 Goal/Tasks 或保留空白高度；无 pending 时用户仍可隐藏 rail。Goal 状态/objective/elapsed/token/audit/run/revision 和按钮来自 durable projection；Edit sheet 从 projection 完整预填四类字段，非法输入阻止保存，运行续跑先 checkpoint，保存后 revision/fields durable 更新；Tasks 显示 criteria/result/evidence/dependencies/invocations；不再从 TaskContract objective 伪造 Goals | SharedUI 结构与 `cowork.permission.review`、`cowork.goal.*` / `cowork.goal.editor.*` accessibility identifiers 已加入；最新视觉与构建结果见本轮 2026-08-02 验证记录及根目录 `design-qa.md`。未创建真实 durable Goal 时，Pause/Edit/Resume/Clear 与长期恢复 flow 仍须标记 `UNKNOWN` |
| IntatisMac Cowork project mode / Phase S | Xcode 运行最新 IntatisMac → Cowork New session → 选择主 workspace → 打开 Project Settings → 退出并重启 App → 从侧栏恢复；临时移走测试 session plist → 尝试错误目录 → relaunch → 选择 exact original directory；另用 fixture/静态复核覆盖丢失 main/reviewer、legacy name/settings/bookmark、symlink mapping 与 shared workspace cleanup | fresh session 严格 `seq 0...6`；EventLog/session projection canonical 一致；legacy name append-before-rebuild；historical main strict fold；bookmark 只在 schema1 binary plist `0600`。缺 plist/错误目录 fail closed；exact identity 才恢复。symlink alias 只在 scope 后 canonicalize，并先写 settings 再 marker；shared capability 只有零引用时可清理，primary 默认不可删除 | focused 137/137；独立 scratch full 785/14 skipped/0 failures；Swift/macOS/iOS builds 通过。Computer Use 新建/恢复/reauthorize、unsent draft、primary Trash disabled 与最终 37-event/seq36 disk audit 符合预期；未发送 provider 请求。真实 symlink picker/shared-worker removal UI、direct multi-root、Phase A/B/L 与真实 provider E2E 未覆盖 |
| Cowork 权限与编排硬化 | fake providers + EventLog 故障注入覆盖 reviewer 控制面 FIFO/queue deadline/capacity/timeout/budget/durable verdict、权限审计 fail-closed、tool execution prepare/settle、非幂等 crash reconciliation、non-cooperative provider watchdog、cross-process EventLog append/writer lease、detach/revoke durable-first、并发 soft-budget reservation、workspace root device/inode replacement（含权限等待期间替换）；确认 production registry 不含 `run_shell`；保留 runner 覆盖 workspace 外直接/符号链接读写、loopback 网络、cancel/timeout、双流大输出 | allow 必须先落 settled；关键 audit 失败不执行工具；未决非幂等副作用不自动重放；第二个 session runtime 启动失败；detach/revoke 失败不先改内存；timeout/stop 有界；root identity 改变后 attach/权限等待/prepare/执行/retry/process fail closed；模型无 raw shell surface，底层 runner 仍只能访问 workspace 且默认断网；预算 dispatch 前预留且明确是 soft | 当前 Task/Goal 合并过滤中的 `OrchestrationReliabilityTests` 32/32 通过，九个相关 suite 合计 121/121；IntatisMac、IntatisiOS Simulator 与 CLI build 成功。完整 605-test run 的 34 条失败全部集中于既有 Tools process/loopback 场景，宿主拒绝嵌套 `sandbox-exec`/loopback；前序独立真实 macOS shell smoke 仍为已通过基线。真实 provider/device、Linux bwrap、双实例与长期恢复矩阵 UNKNOWN |
| Cowork no-effect tool settlement / task-local isolation | fake `task_update` 覆盖 stale、worker 完整快照中的重复合同字段、manager 真实 frozen-owner 变化、post-append lost acknowledgement；任意 manager 尝试伪造 no-effect；legacy fixture 覆盖 exact raw digest/authorization/TaskContract/capability lease/run/WorkTask snapshot 与 tampered digest；另构造 duplicate prepare（含相同 payload）、identical/conflicting duplicate terminal、mismatched/earlier settlement、success/not_started、new committed success、复用 execution ID、JSON safe integer 边界与 executor-entered cancellation；分别在 restore/Goal startup/进程内 launch/whole-task retry 注入 unknown future event、`seq` gap、contract/attempt/terminal 时序正反例和 current Goal | `task_update` 是 PATCH；完全相同的重复合同字段是 no-op，真实 frozen 合同变化仍拒绝。只有 production adapter 在首个 WorkTask EventLog append 前的 rejection 可产生 no-effect；post-append/lost-ack 保持 unknown。legacy repair 仅无 current Goal、complete-known、exact current record、non-ambiguous、zero-settlement、typed intent、唯一非空 task resource、JSON-safe expected，并由 pre-prepare actual>expected 或 exact durable raw-argument/authorization/lease/snapshot proof 支撑时发生；redacted/missing/mismatch 不修复。每个 executionID 仍只保留首张 prepare；相同 duplicate settlement 幂等，冲突永久 ambiguous；success/not_started 无效且 uncertain；pre-executor cancel 写 cancelled/not_started 后仍中断。四条安全路径继续要求 complete-known history，无 Goal isolation 继续要求 contract-before-prepare、positive exact attempt、terminal-after-prepare | 历史 Phase T 基线为六 suite **128/128** 与 successful build；本轮新增用例尚未运行成功：SwiftPM module cache 与 nested `sandbox-exec` 受托管宿主限制，沙箱外申请又因审批服务用量限制被拒。须在可运行 SwiftPM 的宿主补跑 `WorkTaskRuntimeTests`、`OrchestrationReliabilityTests` 与 `swift build`；真实 process-kill/current-Goal reconciliation 仍属外部或后续矩阵 |
| Phase C permission / turn outcome UI | 以独立验证 bundle 启动 `-IntatisPhaseCPermissionFixture -IntatisAppearanceLight` / `-IntatisAppearanceDark`；Manual 检查默认折叠、展开 `Details`、`Approve Call`/Reset/`Decline Call`/Reset/`Cancel Turn`，再切到 Automatic；另在 Cowork 宽/窄布局只读检查同一 pending request 的唯一展示位置 | 生产 `PermissionCard` 默认仍使用紧凑低对比 Material；Cowork 宽屏 rail 由宿主关闭内层 Material 并提供原生 Liquid Glass，窄屏兜底恢复默认 Material。默认只显示 risk/tool/reason/status/actions，structured action/resource 与 `apply_patch` diff 仅在 Details 展开后出现，通用详情不渲染 raw args。Manual 三个 action 与 remembered MCP approval 保持原语义；Automatic 只显示 `Automatic review in progress…`，不存在人工按钮。离线 fixture 不创建 provider、EventLog、credential resolver、responder 或 executor | 2026-07-31 fixture 的 Light/Dark、collapsed/expanded、automatic、approved notice 仍是基础视觉证据；2026-08-02 Cowork rail 复验与最新 focused/build 结果另记于本轮记录。历史 Phase C focused **126/126** 与完整 SwiftPM **895 / 14 skipped / 0 failures** 仍是权限语义基线；本 UI 复验不证明真实 provider verdict、remote transport、process-kill pending replay 或服务端 cancellation |
| Cowork 委派结果反馈 | fake main provider 调用 `delegate_task` / `ask_agent`；fake worker provider 返回文本或先调用 `list_files` 再返回总结；fake task group 覆盖兄弟 task 状态与 sibling 私有内容 | `delegate_task` / `ask_agent` 工具路径通过 scheduler 执行目标 agent；worker 可按 worker lease 调用只读工具；`delegate_task` 回填 mediated Task Report，`ask_agent` 保持直接答案；worker prompt 只看到 metadata-only task group state，不泄漏 sibling objective/result/private path；`list_agents` 给 coordinator 输出 lease role 与 compact task state；`spawn_agent` team member 在承接 task 前不会被 scheduler drain 自动回收，承接过 task 且 idle 后才自动 detach；仍无直接嵌套 `AgentLoop` | 本轮通过 `swift test --filter ContextProjectionTests`（4 tests, 0 failures）、`swift test --filter SchedulerMailboxTests`（7 tests, 0 failures）、`swift test --filter MessageDelegationSplitTests.testDelegateTaskCreatesTaskContractAndTaskDelegatedEvent`（1 test, 0 failures）和 full `swift test`（336 tests, 13 skipped, 0 failures）；sandbox 内 SwiftPM manifest 编译因用户级 clang/Swift module cache 不可写失败，测试使用外部权限重跑；真实 GUI/provider E2E UNKNOWN |
| Cowork Runtime/自动审批/原子协调升级 | request snapshot 构造 Code main、Cowork main/coordinator、worker、reviewer 首请求；fake provider 调用省略 `to` 的 `delegate_task` 与 `spawn_agent`；reviewer 覆盖 allow/deny/ask_user/timeout/cancel/malformed/provider failure/soft budget；agent 连续发出相同 denied write | Code/Cowork 共用 headless `AgentRuntime`；首个 system message 声明 Intatis mode、API tools 权威、strict JSON Schema 与 ToolResult；worker/reviewer 工具面收窄；`delegate_task` 原子复用/创建 `worker-N` 并返回 task/agent identity + TaskReport，task admission 失败时回滚本次新建 worker；`spawn_agent` 只有一个外部权限决定且内部 admission batch 不重审 attach；自动模式无 GUI fallback；soft reviewer budget 不关停；第三次相同 denied ToolCall 终止本轮 | `ContextProjectionTests` 13、`AgentLoopPolicyTests` 15、`AgentInvocationNonRecursiveTests` 7、`AutomaticPermissionReviewTests` 15、`PermissionReviewControlPlaneTests` 17、`SpawnAgentPermissionTests` 9、`CoworkEndToEndTests` 3 均通过；全量 494 tests / 14 skipped / 0 failures |
| IntatisMac multimodal | Xcode 运行 → 图像/转写 | artifact 写入 + 事件 | UNKNOWN |
| IntatisMac 多 provider/model 设置 | 设置页新增 provider → 填 Base URL 或 Chat endpoint/API key → 新增/选择 model → 保存 → Chat/Code/Cowork 新请求 | Base URL 与 Chat endpoint 互相同步；metadata 不写入 UserDefaults 明文 key；用户本次输入的 API key 写入当前可编辑 provider JSON 的 `provider.<id>.options.apiKey` 而非 Keychain；已有 key 显示圆点占位；新请求使用选中 provider/model/chat endpoint | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisMac 高级 JSON provider 配置 | 设置页点击 Open Intatis Config → 编辑生成/打开的 `~/.config/intatis/intatis.json`（或 `INTATIS_CONFIG` 显式指定文件），按 OpenCode-compatible `enabled_providers` + `model` + `provider` map 配置 provider/model，并用 `options.apiKey` 的 OpenCode-style 明文、`{env:NAME}` 或 `{file:path}` 指向 secret → 重启或保存后发 chat | JSON/JSONC catalog 覆盖 UserDefaults；旧 Intatis `config.json` 与 direct `providers` 数组仍可读取，但默认发现与生成只使用 Intatis-owned `intatis.json/jsonc`，不读取任何 `opencode.json` 或 OpenCode app 配置；模板含 `$schema` / `enabled_providers` / `npm` / `options.baseURL` / `models` 和 `{env:...}` key 引用；设置页 Save 会把本次输入的 key 写入同一文件 `provider.<id>.options.apiKey`；真实请求按 env/file/auth JSON/Intatis-owned OpenCode-compatible config 取 secret；不读写 OS Keychain，未把 key 写入 UserDefaults | 构建通过；真实文件/key UNKNOWN |
| IntatisiOS 导入 Intatis JSON/JSONC | 在独立模拟器或真机从主 Chat 齿轮进入 Settings → Configuration → Import Intatis Config → 从系统 Files 选择 modern `provider` map 或 legacy direct `providers` 文件；分别覆盖 literal key、`{env:...}` / `{file:...}`、variant、unsupported adapter、非法/超限文件，重启后复查选择 | history/model/new/settings 原生 toolbar 在已有 key 时仍显示且窄屏不重叠；原生 file importer 可选择 `.json` / `.jsonc`；成功后 provider/model/endpoint/selection 与 base model raw options 持久，原文件可移动且不会被改写/监视；app-owned `Intatis/imported-chat-configuration.json` 为 protected owner-only snapshot且不含 literal key，literal key 先进入 protected `Intatis/auth.json`，UserDefaults 不含 raw options/key；env/file 引用、ignored variants、unsupported adapter 显示具体警告；非法/超限输入拒绝且不替换现有配置；iOS 仍只链接 Chat 子集 | `swift test --disable-sandbox --filter ChatConfigurationImportTests`：5/5；IntatisiOS generic Simulator Debug build：通过；独立 iPhone 17e Simulator 从主界面 Settings accessibility entry 完成 1/1 XCUITest，验证原生 Files picker、实际 JSONC 选择、导入后 provider/model UI 与两个 `0600` regular files 的 secret 隔离；真实 iOS 设备和真实 endpoint/key UNKNOWN |
| Chat/Code 兼容 model request options | 配置 provider npm、model-level provider npm、selected variant 与未知嵌套 `models.<id>.options`；同时尝试伪造 `model/messages/tools/stream/stream_options/n/best_of/candidate_count`；分别构造 Chat、Code Agent 与 exact Cowork profile 请求；编码/解码新旧 endpoint/catalog；覆盖完整 slash model ID | model override → provider npm → compatible default；只有 nil 才使用下一层，显式空/空白仍是 exact unsupported identity。CLI Chat/Code endpoint deep-merge selected variant；raw options 在配置/profile 中保真，最终由 exact adapter 解释。Intatis structural fields 覆盖配置伪造，usage/multi-candidate controls 被清除；新式 compatible/OpenRouter adapter 省略 `n` 和 runtime 自动 `parallel_tool_calls`，legacy wire 保留 `n = 1`。旧 durable 值缺 adapter 保持 legacy decode/fingerprint，schema-v1 原必填空 options 仍编码。该断言不代表 Cowork durable catalog 接受 unknown options | 2026-07-28：新增 strict-routing exact body 回归，focused 与总体验证见本轮记录；真实 OpenRouter dashboard 观察仍为 **UNKNOWN** |
| OpenCode npm adapter / OpenRouter strict routing | compatible model options 使用 `reasoningEffort: xhigh` 并保留 `provider.only`、`allow_fallbacks: false`、`require_parameters: true`；加入声明 parallel-safe 的 Skill-like tool，并让 runtime 请求 parallel；另配置 model `provider.npm = @openrouter/ai-sdk-provider`、unknown/empty npm、camel/snake/nested 冲突、null cacheControl 与 runtime typed effort | compatible exact body 只含 `model/messages/stream/tools/reasoning_effort/provider`，不合成 pinned package 不发送的 `n` 或 metadata-derived `parallel_tool_calls`；其 reasoning 冲突行为匹配 pinned `@ai-sdk/openai-compatible@2.0.41`。OpenRouter override 使用 nested runtime reasoning、不执行 compatible camel-to-snake，null cacheControl 不生成 wire key；unknown/empty npm 零 request、fail closed；adapter 变化产生新 immutable revision | 2026-07-28：23:56 重发已证明最新 binding 生效，但旧 binary 仍因 `parallel_tool_calls: true` 被 OpenRouter strict routing 过滤；修复后 Provider **147/147**、完整 SwiftPM **1485 / 16 skipped / 0 failures**、Developer ID IntatisMac Debug build成功。未读取用户 config/key；修复后二进制的真实 endpoint 重发仍为 **UNKNOWN** |
| 配置来源的模型推理标签与 variants | model options 分别放入 `reasoning_effort`、`reasoningEffort`、`reasoning.effort`、`output_config.effort`、`thinking.budgetTokens`、`reasoning.max_tokens`；给一个模型配置 `low` / `medium` / `high` variants，并另加 `disabled: true` variant；打开 Chat/Code/Cowork 模型菜单，依次选择基础项和 variants | parser 返回原始 effort 字符串或 `<n> tokens` 展示值且不改变 options；菜单保留基础 model 并追加未禁用 variants；选择只保存 identity；请求 model ID 不变，所选 variant 按 plain-object recursive、array/scalar/null replacement 的 deep merge 覆盖基础 options，`disabled` 不进入请求 | 本轮 deep-merge provider regression 通过；原生 Menu 像素/色彩与真实 provider body人工 QA **UNKNOWN** |
| IntatisMac Chat 模型切换 | Chat 页打开模型菜单 → 选择另一个 provider/model 或同一 model 的 variant → 发送下一条消息 | 菜单按 provider 分组并显示配置来源的灰色 variant/推理标签；选择 identity 写入 `intatis.providerSelection.v1`；`ProviderRegistry` 立即重建；下一条 chat 使用新 provider/model 及所选 variant 的原始参数；高级 JSON 文件不被自动改写 | macOS Debug build 通过；共享菜单的 iOS Simulator Debug build 通过；真实 endpoint/key 与 dashboard body 观察 UNKNOWN |
| IntatisMac Cowork 底部下一次 `@main` 模型 | 让模型 A 的 current work/worker 保持运行，忙时从 composer 菜单选择 B，确认 current work 不变并 Send 一条 main message；再选 C 并 Send 第二条；另发 direct worker message和 `/goal`；对 B/C 提交做 outbox/restart/Retry，并撤销一个已选 profile | 菜单消费配置 reconcile 生成的 secret-free exact options，忙时仍可用；选择只 stage，不产生日志/rebind。两次 Send 分别把 B/C 冻结进自己的 immutable payload；FIFO 到各自执行边界时，可选 main rebind 与对应 root created/assigned/queued 必须是同一 EventLog batch，Retry rebind/queue 同样原子；direct worker payload 无 main binding；Goal durable 保存并在每轮 continuation/restart 复用原 binding；restart/Retry 不读取后来选择；profile 不可用或新 main Send 无 exact binding 时 fail closed、零 fallback。current/已冻结 task、worker、permission reviewer、Goal verifier、Chat/Code selection 与 Project Settings future-agent default 均不变；UI 不显示 raw endpoint、credential/options/raw variant key/revision digest | 2026-07-22：next-main focused suites **211/211**；Protocol/Conversation/AgentKernel/Cowork 广覆盖 **592/592**；`swift build --disable-sandbox`、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug 均通过。renderer release 仍 NO-GO，因此不启动 App。按仓库规则未新增测试源码，原子 batch、Goal restart 与 A/B 真实路由仍需后续专门自动化/受控人工/真实 endpoint 验证 |
| IntatisMac UI 信息架构 | 运行 IntatisMac → 在 sidebar 切换 Chat/Code/Cowork 与具名 session → 调整窗口到 compact/宽屏 → 检查 composer、普通回复、权限状态和异常卡片 | sidebar 内是 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航且仅选中项使用 interactive Liquid Glass、当前 mode 的 `Recent` sessions/30×30 圆形 New `+` 与底部 Settings；Rename/Delete context menu 与 busy delete gate 保留；主 header 显示 session display name；Code/Cowork 顶部紧凑且 Cowork 不常驻 reviewer 横幅；消息无 agent 头像和通用 Agent badge；正常 assistant/agent 回复无外层卡片；composer 第一排共用 40pt model/profile interactive-glass 菜单左、usage 右，第二排已有附件/图像 action 左、原生多行输入居中、可选 Cowork stop 与 Send 右；默认单行时 attachment/image action、stop、Send 与输入容器外高均为 40pt，spacing 为 8；输入增长到多行时左右按钮保持底边对齐；Send prominent；Chat 默认无右 inspector，Code 宽屏显示既有 status inspector；Cowork 宽屏显示 permission-first 原生 Liquid Glass rail，完全没有 Git；不得给 Chat/Code 凭空新增附件能力 | 2026-07-23 的 shared composer/sidebar 构建结果仍是历史基线；2026-08-02 Cowork rail 的最新源码、Light/Dark、窄宽与 build 结果见本轮验证记录及 `design-qa.md` |
| 2026-07-31 conversation chrome | 用本轮独立 bundle 打开真实历史 Chat，定位一条 user→assistant 相邻消息；另运行 Phase C offline fixture 的 Light/Dark、manual/automatic/resolved 状态；不点击 Send | sidebar 品牌块只有 `Intatis`；用户 trailing 气泡正文直接开始，不显示 `You`，assistant identity/time 保留；权限卡默认折叠、低对比且 actions 可达，automatic 无人工 actions，resolved notice 紧凑 | Computer Use 与 reference+implementation 同输入视觉比较通过；截图见 `design-qa.md`。未发送 provider 请求；真实 Cowork pending request 与 Reduce Transparency/Increase Contrast/窄窗口矩阵仍 `UNKNOWN` |
| 2026-08-01 session title metadata | 用 unique-bundle IntatisMac 打开真实 Chat history，并切换 Code/Cowork；检查 main session header 与 Chat/Cowork Recent rows；不点击 Send、不创建 session | active Chat/Code/Cowork header 只显示 durable session name，无 model/provider/host、workspace/state 或 agent/running subtitle；Recent row 只显示 session name，无 event/date/path/runtime detail，且无空白 subtitle row；selection/New/Rename/Delete/busy gate 与空态说明不变 | Swift parse 通过；`ThreadLayoutTests` 6/6；Developer ID macOS Debug build 通过；Computer Use 1100×760 前后同输入比较通过，截图见 `design-qa.md`。未发送 provider 请求；active Code/Cowork thread 的真实运行态像素仍 `UNKNOWN` |
| IntatisMac Chat/Code/Cowork session/history | 侧栏切换 mode → 点当前 history 区域 New → 发送消息 → 从对应 mode history 恢复旧 session → 右键 Rename/Delete → 再发送消息；删除/篡改派生 `session.json` 后 refresh | 每个 session 对应独立 `<session>/events.jsonl` 与 artifacts；New 不继续追加旧会话；History 恢复 EventLog 投影；legacy name 先 transaction append settings+marker 再 rebuild，Rename EventLog-first，ID/目录不变；同水位/落后 cache corruption 由 EventLog 修复；Delete 二次确认、只删目标 session 目录及 session-owned projection/bookmark，不删绑定工作区，运行中禁止删除 | Phase S focused 137/137、独立 scratch full 785/14 skipped/0 failures、macOS/iOS builds 通过；Computer Use 验证 Cowork 新建/重启/重授权/最新恢复；真实右键 Rename/Delete GUI 仍 UNKNOWN |
| IntatisMac GUI token/turn stats | Chat/Code/Cowork 发送或回放一轮有 usage 的模型请求；fake provider 覆盖拆分 usage chunk、OpenAI cached prompt tokens 与 Agent 多请求 usage | 最近一轮 `turn_stats` 位于 composer 第一排右侧，model/profile 位于同排左侧；有 cached usage 时显示 Context、non-cached Input、Cached、Output 与 Time，窄宽时允许横向滚动且默认锚定 trailing；缺 cached/context 字段时只显示可证明字段，不虚构数值 | 2026-07-21 曾在历史布局看到真实数值，但不能证明当前排布；当前排布已编译，实际右对齐、窄宽滚动与真实 endpoint context-window 显示仍待运行态复核 |
| API/provider 错误反馈 | fake HTTP/SSE 返回 401、provider error payload、HTTP 502 HTML、malformed SSE、缺 completion marker 的流式 EOF、非 2xx image/transcription、HTTP 2xx 但 image/transcription payload 不匹配、非 HTTP Chat endpoint/Base URL；ChatLoop/AgentLoop 与 Chat/Code projection 回放 provider 401/429、malformed SSE error、partial delta 后 error；tool-call stream 覆盖缺失/string index、JSON object arguments、截断/非法 JSON arguments、空 arguments 兼容、非首个 choice 的 content/tool_calls/finish_reason、多 choice 中 `tool_calls` finish reason 优先、`tool_calls` 结束但缺 tool name、tool-call delta 后错误 `stop` 结束态、旧式 `function_call` 结束态；工具调用覆盖坏 JSON / 非对象 / 缺 required 字段 / 基础类型错误 / 数值越界 / 字符串长度违规 / 未知字段参数 | `ProviderErrorFormatting` 输出包含状态码、可行动提示与裁剪后的结构化 provider message；HTTP 非 2xx 的 HTML/纯文本代理错误页只显示裁剪 `Preview`，不误标为 `Provider said`；非法 provider endpoint 在网络前变成 `config` 错误并提示检查 Base URL/Chat endpoint；image/transcription 2xx 异常 payload 变成带结构化 provider message 或 preview 的 decoding 错误，普通 HTML/缺字段 JSON/坏 base64 不误标为 `Provider said`；ChatLoop/AgentLoop 通过 `ErrorPayload` 记录明确 code/message；Chat / Code / Cowork 错误卡片显示 retry/config/endpoint 等恢复建议；partial assistant/agent 输出失败时保留已输出文本并标记 stopped；缺完成标记不得合成 completed；不完整 tool-call finish 或非空 arguments 非完整 JSON 不得合成成功；tool-call delta 归一为既有 `ToolCall`；坏工具参数在权限前变成 `invalid tool input:`；不写完整响应体或 secret | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（62 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），macOS/iOS Xcode Debug build 通过；真实 provider/key UNKNOWN |
| Provider health check / 设置页 Test Provider | macOS 设置页点击 Test Provider，iOS Settings 点击 Test Provider；fake stream 覆盖 completed stream、missing `[DONE]`、`finish_reason` without `[DONE]`、缺完成标记 preview 保留、timeout、unknown endpoint、非法 provider URL、agent role 与 agent request body | 设置页先保存当前配置再测试；报告显示 ok/failed、endpoint/model/wire、耗时、首 token、usage/code/message、裁剪 preview；chat/agent health check 均请求 usage；非法 URL 报告 `config`，不尝试发起底层 transport；不显示 secret 或完整响应体；macOS/iOS 复用 provider 层逻辑；缺 `[DONE]` 但有 `finish_reason` 不误判为 partial stream，真正缺完成标记时报告 partial stream | Provider focused tests 通过（62 tests, 0 failures），full SwiftPM tests 通过（275 tests, 0 failures），macOS/iOS Xcode build 通过；真实 provider/key UNKNOWN |
| Provider retry/timeout/rate-limit/redirect policy | fake stream/data client 覆盖首字节前 503、mid-stream 503、tool-calling 503、tool-calling error-only SSE 502→成功、accepted partial→SSE 502、finish 后 usage、重复完成信号、缺 completion marker、非 HTTP endpoint 预校验、所有 HTTP 30x、image 503→200、image 429 Retry-After→200、image/transcription 2xx 异常 payload、transcription timeout、Retry-After delay cap、duration-style reset header | tool-calling 在未接受非错误 payload 时会 retry error-only retryable SSE；接受 text/tool/usage/completion 后不会 retry；`finish_reason` 与 `[DONE]` 都可完成流，finish 后 usage 不丢失且 done 不重复；无完成信号的 EOF 会变成 endpoint 兼容错误；非法 provider URL 在 network/retry 前变成 config 错误；HTTP 30x 不跟随到未经 catalog/binding 审查的 Location，直接 fail closed；HTTP 非 2xx 未结构化响应体只显示裁剪 preview；image/transcription 走共享 retry/timeout，2xx 异常 payload 不 retry 而是明确 decoding 错误；`Retry-After` / rate-limit reset headers（数字秒、HTTP 日期、duration 字符串）影响 retry delay 并进入错误文案；完整 HTTP(S) diagnostic URL 在 EventLog/UI 前变成 `[REDACTED_URL]` | `IntatisProvidersToolCallingTests` 29/29；完整 `swift test` exit 0；macOS/iOS touched builds 成功。真实 provider/key UNKNOWN |
| 工具执行失败反馈 | Code/Cowork fake provider 触发 unknown tool、permission denied、tool error、坏 JSON 参数、非对象参数、缺 required 字段、基础类型错误、数值越界、字符串长度违规、未知字段参数、带 endpoint/header/api_key 的 unknown/invalid 调用、作为 inference-control surface 的 `spawn_agent`、超长但有效参数、空 command/path/query/diff 参数、无参工具空参数、tool-calling partial stream EOF、不完整 tool-call finish、截断/非法 tool-call arguments、多 choice 工具 finish reason、非首个 choice tool-call、Agent 工具循环多请求 usage 累计 | `.tool_call` 在 append 前完成参数分类；unknown/invalid/全部 spawn inference-control calls 只落 bounded redacted placeholder + count/redacted，不写 raw-value digest；有效非控制参数也 secret-scrub/限长，只有未脱敏/未截断 canonical args 可带 digest；恶意 endpoint/header/api_key、完整 raw args 及其普通 hash 均不出现在 JSONL；`tool_result` observation 保留失败原因；坏 JSON / 非对象 / 缺 required 字段 / 基础类型错误 / 数字范围违规 / 字符串长度违规 / 被 `additionalProperties:false` 禁止的未知字段在权限请求和工具执行前返回 `invalid tool input:`；`read_file.maxBytes` 必须 `>= 1`；标准工具 path/query/command/diff 必须非空；required 为空的无参工具空参数归一为 `{}`；Code projection 标记失败、回填工具名并派生恢复建议；AgentLoop 对缺完成标记的 partial agent 输出写入 error 并标记 stopped；tool-call finish 缺完整工具调用或非空 arguments 非完整 JSON 时 provider 抛明确兼容错误；CLI 失败输出使用错误色；GUI 不解析 assistant transcript | 既有基线见本节顶部；新增 tool-call audit hardening 的最终专项/full/build结果以本轮总体验证记录为准，不能沿用旧 22-test focused 数字冒充已验证；GUI 手动 UNKNOWN |
| Agent Git control | Code/Cowork/CLI agent 调用 `git_status`、`git_diff`、`git_diff_staged`、`git_info`、`git_recent_commits`、`git_diff_base`、`git_branch`、`git_create_branch`、`git_stage`、`git_unstage`、`git_commit`、`git_apply_patch_check`、`git_apply_patch`、`git_stage_patch`、`git_unstage_patch`、`git_revert_patch`、`git_worktree_list`、`git_worktree_create`、`git_worktree_remove`、`git_remotes`、`git_fetch`、`git_pull_ff`、`git_push`、`git_switch`；准备普通 Git repo、非 repo 目录、workspace 子目录、受管 `.intatis/git-worktrees` linked worktree、已配置 remote、本地 branch、submodule、已 staged sensitive path、空 staged index、普通 staged file、可正向/反向 apply 的 patch、冲突 patch | read-only Git 工具不需要写权限；stage/unstage/create-branch/commit/apply-patch/worktree-create/fetch/pull-ff 走写/网络权限流；revert-patch/worktree-remove/push/switch 是 destructive 或 destructive+network 并要求确认；动态 paths/patch changed paths 经 `PathConfinement` 且只传 workspace 相对路径给 git；repository root 必须等于 workspace root，普通 git metadata 不逃出 workspace，受管 worktree metadata 只能指向 owning workspace repo；commit 禁用 hooks/GPG 交互并拒绝 staged sensitive path；remote Git 只接受已配置 remote name、不接受 URL remote/refspec，并遮蔽 URL 凭据/token；pull 只允许 clean 当前分支 `--ff-only`；push 不支持 force/force-with-lease；switch 只允许 clean working tree 上切换既有本地分支；Cowork worker 默认看不到 Git 工具，coordinator 可见本地 Git control 与 remote Git control；旧 runShell lease 只暴露 read-only Git 工具；不支持 merge/rebase/reset/clean/remote auth 管理/PR/CI | 本轮 Git fake service / registry / lease / permission / patch path escape / destructive confirmation / remote confirmation / force-argument schema tests 已更新并通过。验证通过：`swift build --scratch-path /private/tmp/intatis-git-remote-build`；`swift test --scratch-path /private/tmp/intatis-git-remote-tests --filter 'IntatisToolsTests|IntatisAgentKernelTests|IntatisPermissionTests|CapabilityLeaseTests|ToolRegistryLeaseTests'`（136 tests / 14 skipped / 0 failures）；`git diff --check`。本轮未对当前仓库执行真实 remote fetch/pull/push；`INTATIS_REAL_GIT_SMOKE=1` opt-in XCTest 仍为上一轮覆盖真实临时 Git repo stage/commit/recent/info、patch check/apply/revert clean、受管 worktree create/info/remove；临时 SwiftPM harness `/private/tmp/intatis-git-harness` 也为上一轮结果。真实复杂 Git 仓库、submodule、merge conflict、commit hook、detached HEAD、非 repo、patch conflict、真实远端 fetch/pull/push/auth、GUI/provider E2E 矩阵 UNKNOWN |
| Agent 文档/媒体工具 | Code/Cowork/CLI agent 调用 `read_pdf`、`read_document`、`edit_pdf_pages`、`reconstruct_document_image`、`compile_latex`、`generate_image`；准备可抽取文本 PDF、扫描/纯图像 PDF、扫描/照片样本、`.tex` 样本、provider 生图配置；缺少外部 CLI 时确认返回可行动配置错误 | 可抽取文本层 PDF 用 `read_pdf`；扫描/纯图像 PDF 的阅读与总结用 `read_document` 且 backend 省略/`auto`；`read_document` 输入不超过 512 MiB，parser 启动前的 path/file/size/extension/backend 拒绝必须结算为 no-effect；只有用户明确要新的可编辑输出产物时才用 `reconstruct_document_image`，不把 PDF 作为 `imagePath`；PDF 页面抽取/拆分只写 workspace 内文件；LaTeX 经 Tectonic/latexmk/xelatex/pdflatex 产出 PDF；生图经 provider image capability 写入图片文件；所有工具调用都有 schema 校验、权限请求/决策、`tool_result`、changedFiles；Cowork read-only worker 默认只看到 `read_pdf`，read-write coordinator/worker 才可见 process-backed `read_document` | 上一轮完整基线保留于本节历史记录。2026-08-02 选择合同验证：`ContextProjectionTests` 21/21，文档 descriptor/no-text hint/standard registry 3/3。同日局部大文件/no-effect 热修验证：314 MiB sparse PDF 放行、>512 MiB preflight 拒绝且 backend 零调用等 3/3；AgentLoop typed no-effect settlement 1/1；`swift build --disable-sandbox` 和 IntatisMac Developer ID Debug unsigned build 通过。未运行真实 314 MiB PDF 的完整 OCR，也没有改动通用宿主路由、分页或原子输出链路；真实 provider 触发的 App E2E、MarkItDown、PPTX/XLSX/legacy Office 质量矩阵仍为 UNKNOWN |
| Agent 网络/浏览器工具 | Code/Cowork/CLI agent 调用 `web_fetch`、`browser_diagnostics`、`browser_profiles`、`browser_profile_delete`、`browser_history`、`browser_navigate`、`browser_snapshot`、`browser_handoff`、`browser_reload`、`browser_back`、`browser_forward`、`browser_click`、`browser_type`、`browser_submit`、`browser_select_option`、`browser_press_key`、`browser_scroll`、`browser_wait`、`browser_screenshot`、`browser_upload_file`、`browser_download`、`browser_downloads`、`browser_search`；准备 Node.js + Playwright + Chromium/Chrome/Edge，或 Node.js 内置 `WebSocket` + Chrome DevTools Protocol fallback + 已安装 Edge/Chrome/Chromium；用独立 profile 登录测试站点，执行搜索、浏览、headed 用户接管/登录、刷新、前进/后退、点击、输入、提交表单、新页面/弹窗跟随、下拉选择、按键/快捷键、滚动、动态等待、截图、workspace 文件上传、显式下载、profile metadata/下载 metadata/历史检查和显式 profile 删除；缺少 Playwright 或浏览器 channel 时确认返回可行动配置错误/诊断 | `web_fetch` 只做 HTTP(S) fetch；`browser_*` 使用持久 Chromium/Chrome/Edge profile，优先走 Playwright，Playwright 缺失时走 CDP fallback；登录态、cookies、localStorage、history metadata、navigation stack 和 downloads 存在 workspace `.intatis/browser/`，不写 Keychain；同一进程内同一 workspace profile 的 Playwright/CDP-backed 命令串行执行，不同 profile 可并行；`browser_handoff` 打开有界 headed 窗口供用户手动登录/接管并在超时后返回页面快照；页面快照和动作结果返回可定位交互控件摘要（role/name/selector/options），打开新 tab/window 的交互应跟随到最终页面并写入 state/history，但不得打印 cookies/localStorage/profile DB、密码/token 或当前文本输入框 value；Playwright wrapper 有命令级 watchdog，CDP fallback 的 send/close/process 退出有界且 click/download 使用真实鼠标事件；`browser_profiles` 只列 profile 名称、当前 URL/title、state/history/download 计数、目录统计和 active/lock runtime marker 存在性，不读取 profile 数据库、marker 内容或下载内容；`browser_profile_delete` 是 `.destructive` 工具，必须要求 `confirmProfile` 精确匹配，只删除 workspace 内目标 profile/state/downloads/history metadata，删除前可概括提示 runtime marker 状态，但不读取或输出内部文件内容/marker 文件名；`browser_history` 只暴露受控 metadata，不读取 profile 数据库；`browser_back` / `browser_forward` 使用 `state/<profile>.json` 的 navigation stack/index 选择目标 URL，并在同一 profile 临界区内用真实 profile 打开目标页；`browser_screenshot` 只写工作区 PNG；`browser_upload_file` 只能引用 workspace 内文件；`browser_download` 只写 `.intatis/browser/downloads/<profile>` 并通过 changedFiles 暴露路径；`browser_downloads` 只列 metadata，不读取内容；`browser_type` observation 遮蔽本次输入值，并拒绝疑似密码/2FA/token/API key 输入目标（Swift 工具入口 + Playwright/CDP DOM guard）；`browser_submit` 支持提交当前表单或按 locator 定位 form/control/submitter 后提交；`browser_select_option` 至少要求目标 locator 和 value/label/index，`browser_press_key` 支持目标 locator 或当前焦点；`browser_scroll` 支持方向/距离或显式 delta 并可先定位元素；`browser_wait` 支持 passive wait 或 selector/text/role 状态等待；所有浏览器工具都有 schema 校验、权限请求/决策、`tool_result`；read_only/shell-disabled 下 shell-backed browser 工具 hard deny，read_only 下 profile 删除 hard deny；Cowork worker 默认看不到 `web_fetch` / `browser_*`，coordinator 可见网络/浏览器工具 | 上一轮 Tools focused tests 通过基线（55 tests, 12 skipped, 0 failures，覆盖 fake-shell concurrent profile state/history metadata、同一 workspace profile 命令串行化 fake-shell overlap、metadata-only profile inventory 与 runtime marker 存在性脱敏、确认保护的 profile 删除与 history pruning/marker warning 脱敏、headed handoff payload/state/history、workspace 上传、显式下载 changedFiles、下载 metadata 只读列表、搜索结果文本/链接/history、交互控件摘要输出、打开新页面 observation/state/history、browser_type 凭据目标拒绝、web_fetch local HTTP/truncation/non-HTTP URL 覆盖、表单提交 payload/history、下拉选择历史、按键历史、滚动历史、等待历史、reload 历史、back/forward navigation stack 与历史、zero-delta 拒绝和 key 控制字符拒绝）；真实浏览器 smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-test --filter IntatisToolsTests/testRealBrowserBackendSmokeWhenEnabled` 通过（1 test, 0 failures），验证 Playwright 缺失时 `BrowserNavigateTool` 走 Edge/CDP 访问 `https://example.com`；真实 search smoke `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-clang-module-cache INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-browser-search-real --filter IntatisToolsTests/testRealBrowserSearchWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可用持久 profile 打开 DuckDuckGo 搜索页并写入 search history metadata；真实 profile smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-test --filter IntatisToolsTests/testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled` 通过（1 test, 0 failures），验证同一 Edge/CDP profile 的持久 cookie、localStorage 状态与 history metadata 跨两次工具调用保留；真实 upload/download smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-tools-real-test --filter IntatisToolsTests/testRealBrowserUploadDownloadWhenEnabled` 通过（1 test, 0 failures），验证真实 file input 上传、Blob 下载、下载路径 changedFiles 和 metadata-only listing；真实 submit smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-submit-real-smoke --filter IntatisToolsTests/testRealBrowserSubmitWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可在本地 HTTP 表单页提交并到达结果页、写入 submit history metadata；真实 popup/new-page smoke `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-clang-module-cache INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-popup-real-smoke2 --filter IntatisToolsTests/testRealBrowserPopupNewPageWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可用真实鼠标事件点击 target=_blank 链接、跟随新页面并写入 state/history；真实 select/press smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-test-codex --filter IntatisToolsTests/testRealBrowserSelectAndPressKeyWhenEnabled` 此前通过（1 test, 0 failures，需允许启动浏览器/脱离 sandbox），验证 Edge/CDP 可执行下拉选择和 Enter key dispatch；本轮把该 smoke 扩展为真实交互摘要断言后，尝试重跑被 sandbox escalation 自动审批拒绝，因此真实 CDP 交互摘要断言仍是 UNKNOWN；真实 scroll/wait smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-scroll-test2 --filter IntatisToolsTests/testRealBrowserScrollAndWaitWhenEnabled` 通过（1 test, 0 failures，需允许启动浏览器和本地 HTTP 服务/脱离 sandbox），验证 Edge/CDP 可滚动页面并等待动态文本出现；真实 profile isolation smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-isolation-test2 --filter IntatisToolsTests/testRealBrowserProfilesRemainIsolatedWhenEnabled` 通过（1 test, 0 failures），验证两个 Edge/CDP profile 的 cookie、localStorage marker 与 history metadata 互相隔离；真实 back/forward smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-history-test --filter IntatisToolsTests/testRealBrowserBackForwardWhenEnabled` 通过（1 test, 0 failures），验证 loopback HTTP 页面上的 navigation stack 前进/后退；真实 dynamic feed/task smoke `INTATIS_REAL_BROWSER_SMOKE=1 swift test --scratch-path /private/tmp/intatis-real-feed-task-smoke --filter IntatisToolsTests/testRealBrowserDynamicFeedAndOnlineTaskWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可在本地动态信息流中 scroll/wait、进入任务表单、输入非敏感文本并提交到完成页、写入 navigate/scroll/wait/click/type/submit history metadata；真实 handoff smoke `INTATIS_REAL_BROWSER_HANDOFF_SMOKE=1 swift test --scratch-path .build/intatis-tools-real-handoff-test --filter IntatisToolsTests/testRealBrowserHandoffWhenEnabled` 通过（1 test, 0 failures），验证 Edge/CDP 可打开有界 headed persistent profile 并回写 state/history；新增真实不同 profile 并发启动 opt-in smoke `INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled` 目前仅验证默认 skip path 通过，实际 Edge/CDP 并发启动因本轮 outside-sandbox escalation 被使用量限制拒绝未运行；ToolRegistryLease focused tests 通过（6 tests, 0 failures）；MessageDelegationSplit focused tests 通过（8 tests, 0 failures）；CoworkEndToEnd focused tests 通过（3 tests, 0 failures）；Permission focused tests 通过（37 tests, 0 failures）；AgentKernel focused tests 通过（22 tests, 0 failures，含 browser_search、browser_profile_delete、浏览器表单任务与动态信息流浏览 AgentLoop 权限流）；CapabilityLease focused tests 通过（3 tests, 0 failures）；Cowork focused tests 通过（81 tests, 0 failures）；full SwiftPM tests 通过（331 tests, 12 skipped, 0 failures）；`swift build` 通过；IntatisMac / IntatisiOS simulator Xcode Debug build 通过；generic iOS 设备 build 因未配置 development team 签名失败，未作为源码失败处理；本机 Node v26.3.0 可用、Microsoft Edge app 存在，但 Playwright module 当前不可解析且 Google Chrome/Chromium app 未发现；真实 Playwright、第三方站点登录、社交媒体、代办网站、真实第三方网站下载/上传/表单提交、长期 profile 清理/污染和真实同时启动多 profile 管理 UNKNOWN；sequential profile isolation 已通过，同进程同 profile 串行化真实浏览器并发矩阵仍待验证 |
| `/goal` Chat 标签 | Chat 输入 `/goal ship v0.12` → 发送 | 用户消息显示 Goal 标签；消息正文为 `ship v0.12`；provider 收到清洗后的目标文本；事件 `user_message.payload.tags == ["Goal"]` 且 `goal == "ship v0.12"` | SwiftPM focused tests 通过；GUI 手动 UNKNOWN |
| `/goal` Code 标签 | Code 输入 `/goal inspect workspace` → 发送 | Code 用户气泡显示 Goal 标签；AgentLoop 收到清洗后的目标文本；事件保留 Goal 元数据 | SwiftPM focused tests 通过；GUI 手动 UNKNOWN |
| `/goal` Cowork durable mention | Cowork 输入 `/goal @Alpha inspect` 或 `@Alpha /goal inspect` | 两种写法都创建 durable Goal + ContinuationRun；@Alpha 只作为请求上下文/提示，实际 continuation 仍由 `@main` 主持；不得只写 `user_message` Goal 标签；Goal/WorkTask/run 事件可 replay | deterministic protocol/projection tests 已加入；GUI/CLI 语法与真实 provider 手动以本轮最终验证为准 |
| Cowork Main-led agent 生命周期 | fake provider 中 `@main` 调用 `spawn_agent` → `delegate_task`；另测手动 attach worker 后 delegate | `spawn_agent` 记录 requester；`delegate_task` 等待 scheduler 执行子 agent 并把 mediated Task Report 作为 tool observation 回填给 `@main`；tool-spawned worker 完成且 idle 后自动 detach；手动 attach worker 不自动回收；`ask_agent` 仍返回直接答案 | `xcrun xctest -XCTest AgentInvocationNonRecursiveTests .build/debug/IntatisPackageTests.xctest` 通过（5 tests）；`xcrun xctest -XCTest SpawnAgentPermissionTests .build/debug/IntatisPackageTests.xctest` 通过（6 tests）；真实 GUI/provider E2E UNKNOWN |
| Cowork 自动权限审查与授权身份绑定 | 打开 GUI Cowork session 或运行 `intatis cowork`；让 `write_file` / `apply_patch`、unknown/unleased/invalid tool、`delegate_task(to:auto)`、`ask_agent`、attach persistence fault 和跨重启副作用窗口进入权限流；制造 empty reason、risk downgrade、secret-bearing preview、queue/timeout/malformed/provider failure → CLI `/default` / `/auto` | session 默认启用独立 `@permission-reviewer`；同一 registry registration 解析 immutable `ResolvedToolAuthorization`，`write_file` / `apply_patch` canonical permission 均为 `filesystem.edit`；automatic review 只见 args digest/count + bounded secret-redacted preview，reason 必填且 risk 不得下降；同一 snapshot 贯穿 requested/settled/resolved/prepared/settled 并在 executor 前复核；auto delegate 在 review 前解析 exact target，deny 不创建 worker且 allow 后不 re-resolve；跨重启 unresolved side-effect evidence 阻止假完成；`ask_agent` 请求或返回路径的 Mediator failure 均无 succeeded settlement且 scheduler terminal 等待 reply delivery settlement；attach related events 通过 WAL 原子 batch，legacy/strict reader 均先恢复未决 WAL，安全关键路径使用 checked replay 并校验 session/sequence/known payload | 8 个专项 suite 合计 146/146，Conversation selected 67/67，独立终审相关组合 164/164；完整 SwiftPM 678 tests / 14 skipped / 36 failures，其中 34 条为 outer sandbox 下既有 Tools nested-sandbox/loopback，2 条为用户现有 highlight.js engine XCTest，权限与新 EventLog 回归无失败；`swift build` 通过；此前本轮 macOS/iOS Xcode Debug build 通过，最终 Xcode 重跑受托管 manifest nested-sandbox 限制；Computer Use 复验 reviewer enabled、2 agents/0 running、composer Send 门控通过，未发送 provider 请求；真实 provider verdict 质量、process-kill/syscall fault injection UNKNOWN |
| IntatisMac 配置文件密钥 | 已有 auth JSON 或 OpenCode-compatible `options.apiKey` 时启动 app → 打开设置页 → 连续发送两条 chat | 启动、设置页和真实请求均不访问 OS Keychain；secret 从配置文件/env/file 读取并在进程内缓存；无 macOS Keychain 认证弹窗 | 构建通过；真机手动 UNKNOWN |
| IntatisiOS 界面 serif | 用 Device Hub 打开空 Chat 首页、侧栏和 Settings；检查顶部模型、Intatis、Recents、空态、composer、sheet 标题/按钮/section/说明/表单；把同密度参考图与首页、侧栏实现放入同一比较输入；核对内容 renderer 未出现 iOS-only 字体分叉 | iOS app chrome 使用 Apple 系统 `.fontDesign(.serif)` + Dynamic Type；顶部模型为 headline semibold + primary，Intatis 为 title2 semibold，Recents 为 headline semibold，会话/空态和输入为 body；Markdown/plain fallback、代码块、公式和声明继续与 macOS 共用同一字体合同；参考图 sans 字体族只在 app chrome 上由用户明确的 serif 要求覆盖 | IntatisiOS generic Simulator Debug unsigned build与 `MessageRenderingTests` 41/41 通过；Dark 首页、侧栏和 Settings 的 @3x 截图/AX 检查无 P0/P1/P2；模拟器保持 Booted 且 Settings 留在前台，未发消息或 provider/网络请求；真实富文本长回复最终像素、所有 Dynamic Type 档位与辅助功能外观仍 UNKNOWN |
| IntatisiOS chat shell | Xcode/Device Hub 运行 IntatisiOS → 检查空首页、顶部 sidebar/model/new、左抽屉、Settings、paperclip 菜单与 Send/Stop | 空首页不含第三方 onboarding/建议卡；约 82% 抽屉显示 Intatis/Recents/Settings、非交互 session-search 占位和 Chat；底部为仅含生图项的 paperclip 菜单 + 输入 + 最右 Send/Stop；不得显示 Chat 网络搜索按钮、菜单项、开关或状态；不自动弹 API-key 配置；无工具/shell | IntatisiOS generic Simulator Debug unsigned build 通过；iOS 27.0 iPhone 17e 的首页、抽屉、model 菜单、Settings/配置导入入口和 paperclip 菜单已用 Device Hub 实际检查；最新截图/AX 确认没有 web-search UI；设备保持 Booted，未发 provider 请求；流式回复与通用附件 E2E UNKNOWN |
| IntatisiOS 多 provider/model 设置 | iOS Settings sheet 新增 provider/model → 填 Base URL 或 Chat endpoint/API key → 保存 → 发 chat | iOS 仍只链接 chat 子集；Base URL 与 Chat endpoint 互相同步；API key 写入 app container auth JSON 而非 Keychain；已有 key 显示圆点占位；新请求使用选中 provider/model/chat endpoint | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisiOS Chat 模型切换 | Chat 顶部中央 model 菜单 → 选择另一个 provider/model → 发送下一条消息 | iOS 仍只链接 chat 子集；选择写入 `intatis.providerSelection.v1`；下一条 chat 使用新 provider/model | 构建与顶部菜单展开 GUI 通过；真实 endpoint/key UNKNOWN |
| IntatisiOS Chat session/history | iOS 顶部新对话或抽屉底部 Chat 新建 → 发消息 → 抽屉 Recents 恢复旧 session | iOS 仍只链接 chat 子集；每个 Chat session 对应独立 app container `<session>/events.jsonl` 与 artifacts 目录；恢复历史不触发 workspace/tool 模块；抽屉搜索图标当前没有交互 | IntatisiOS Xcode build、顶部/抽屉新对话与抽屉开合 GUI 通过；含历史内容的真实 session 切换仍 UNKNOWN |
| IntatisiOS GUI token/turn stats | iOS Chat 发送一轮模型请求；fake provider 覆盖拆分 usage chunk 和 cached prompt tokens | iOS 仍只链接 chat 子集；最近一轮 `turn_stats` 通过 SharedUI 单行统计显示，不引入 workspace/tool 模块；同一响应内 split usage 字段级合并；cached/context 字段缺失时兼容旧显示 | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（62 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），IntatisiOS Xcode build 通过；真实 endpoint usage 手动 UNKNOWN |
| iOS 子集边界 | 检查 IntatisiOS 链接的 product | 不含 Tools/Permission/AgentKernel/Cowork | 已确认（project.yml） |
| Cowork 同 session per-agent inference profiles | 准备至少两个 host-approved route/model/variant 与各自不同的临时 credential ref；新建 session 验证 `@main`，spawn 两个 agent（一个省略 profile、一个显式 profile），并发各发一次请求；修改 future-agent default；在 suspended resolver、ordinary attach review-await 和 bootstrap admission-wait 期间更新 catalog/roster；对 running/queued agent 尝试 rebind，再在 idle 后 rebind；重启并制造一个普通 agent unresolved；CLI 运行 offline `intatis selftest`，用 unique unqualified model 与 missing reasoning variant，并建立 non-empty missing-main fixture 后执行 `/agent restore-main <path> <profile-id>`；用 Computer Use 检查 macOS Project sheet/roster/rebind 状态 | 省略 profile 精确继承调用者 exact binding；显式选择只能来自 host-approved 列表；两个 agent 各自使用固定 model/opaque variant/connection/credential ref，selected route key 与 raw macOS variant config key 不进入其他 binding/EventLog；default 变化不改现有 agent；catalog update/admission lock、resolver await 后 recheck、ordinary attach review-await 与 bootstrap admission-wait 后 exact profile/empty-session revalidation 关闭 TOCTOU；startup 只 gate exact-resolved `@main` 与 reviewer/control plane，ordinary unresolved worker 不阻止其他 agents，其 queued invocation 在 provider 前 durable failed、清除 busy fence后才能 rebind；non-empty CLI missing-main 不套 current default，只接受显式 restore；unique unqualified model 选择唯一 route，reasoning mismatch fail closed；busy rebind 拒绝，idle rebind durable 且只影响下一 invocation；missing/mismatch/unsupported wire fail closed，不回退 current；durable unsafe options fail closed；所有 request 固定单候选；UI/CLI/diagnostics 不出现 raw endpoint、credential/options/raw variant key/完整 digest/完整 URL | 终审前基线为 focused 62/62、CLI selftest、SwiftPM 734 / 14 skipped / 0 failures、macOS/iOS Simulator builds；新增终审项最终自动测试、构建与 Computer Use 以总体验证记录为准。真实多上游/key/endpoint/effort 网络 E2E、credential rotation、非 OpenAI-compatible wire、route lease/跨 trust-domain 专用审批与完整 capability validation 仍为 UNKNOWN/未实现 |
| 权限门硬 deny | worker 尝试 spawn_agent | 被拒 | 已有测试覆盖 |
| Cowork 循环 | A→B→A 委派 | 被拒 | UNKNOWN — 见 COWORK_PRINCIPLES §8 |

## 开源复用验证

引入、翻译、vendor、链接或升级上游源码/公开 prompt/runtime 时，除功能测试外必须完成：

- 记录上游 URL、固定 tag/commit、具体文件、原许可证和本地修改摘要。
- 核对目标文件头、根 LICENSE、NOTICE、传递依赖和资产许可证；结果写入 `NOTICE.md`，需要完整分发文本时写入 `ThirdPartyNotices/<project>.md`。
- 说明复用形式是 `derived`、`vendored`、`dependency` 还是 `external-runtime`；逐行翻译不能记成独立实现。
- 对 Apple 平台运行 `swift build` 及受影响 target 的测试；涉及 macOS helper/runtime 时还要验证 code signing、bounded timeout/cancel/process cleanup 和缺失 runtime 的失败降级。
- 验证外部实现仍经过 PermissionEngine、CapabilityLease、WorkspaceLease、PathConfinement、durable tool execution 与 EventLog；上游默认 allow/网络/文件能力不得直接继承。
- 确认 iOS target 没有因复用新增 shell/git/local-agent/Cowork 或非允许 runtime 链接。
- 升级 pinned upstream commit 时重新检查许可证/NOTICE/依赖变化和本地 patch，不得只验证编译通过。

## 验证边界声明

- 文档任务：至少运行 `git diff --check` 与 `git status --short`；**未运行构建/测试**，须声明。
- 只修改开源复用政策/NOTICE 且未引入任何源码或依赖时按文档任务验证；一旦实际加入或翻译上游实现，按受影响源码模块运行完整相称测试，不能只做文档检查。
- 代码任务：按改动风险运行相称的 `make test` / `make build` / `make app`；改 Cowork/AgentKernel 必须加测试（见 `docs/COWORK_PRINCIPLES.md` §8）。
- Per-agent inference profile 任务：至少运行 `InferenceProfileProtocolTests`、`InferenceCatalogTests`、`InferenceCatalogStoreResolverTests`、`PerAgentInferenceProfileTests`、`CoworkInferencePresentationTests`、`IntatisAgentKernelTests` 与 `swift build`；若触及 Orchestrator/permission/scheduler，追加完整 Cowork/authorization suites；若触及 CLI multi-route/config/resolver，构建 CLI 并运行 offline `swift run intatis selftest`，另验证 non-empty missing-main 的显式 restore；若触及 macOS/CLI，构建对应 target，并优先用 Computer Use/人工验证 future-default、per-agent safe label/trust classification、unresolved `@main` 时 GUI composer/本地 Send 仍可用且提交得到明确 route failure、CLI startup/data-plane resume 仍 fail closed、ordinary unresolved worker 不冻结其他 agents、该 worker invocation durable failed 后 busy fence 清除、Project Settings/CLI busy rebind 拒绝和 idle rebind 后下一轮生效。若触及 Cowork 底部 selector，还须验证 busy 可选但 current work 不变、每次 Send 独立冻结、A/B FIFO、direct worker nil、restart/Retry 保真、unavailable no fallback、只改 `@main` 且控制面/future default 不变。测试还必须分别证明 Chat/Code arbitrary options lossless 与 Cowork explicit durable schema fail-closed，不能混写成一条相反契约；涉及 transport/diagnostics 时必须补 30x no-follow 和 complete-URL redaction。真实 endpoint/key/上游请求未发送时必须明确写 UNKNOWN，不得用 fake provider、offline self-test 或 UI 标签冒充网络路由验证。
- 自动权限审查、tool authorization、delegate/ask 或副作用 completion evidence 任务：最少运行 `ToolRegistryLeaseTests`、`PermissionReviewProtocolTests`、`PermissionReviewControlPlaneTests`、`AutomaticPermissionReviewTests`、`AgentLoopPolicyTests`、`AgentInvocationNonRecursiveTests`、`SpawnAgentPermissionTests`、`OrchestrationReliabilityTests` 与 `swift build`；涉及 GUI/CLI 接入时再构建 IntatisMac/IntatisiOS touched target，并以 Computer Use 或人工验证 reviewer 状态可见、GUI composer/本地 durable Send 不被 reviewer failure 锁定、普通请求可 admission，且真正 ask-class tool 仍 fail closed。outer sandbox 阻止 nested Seatbelt/loopback 或 Xcode manifest sandbox 时，必须保留实际失败日志并与源码测试失败分开报告，不能改写为 pass。
- Phase C permission response / turn outcome / sandbox classification 任务：至少运行 `TurnOutcomeProtocolTests`、`PermissionSettlementTransactionTests`、`PermissionProjectionTests`、`AgentLoopOutcomeTests`、`SandboxDenialOutcomeTests`、`WorkspaceSandboxDenialTests`、`PermissionReviewControlPlaneTests`、`OrchestrationReliabilityTests` 与完整 SwiftPM；触及 app/CLI 时构建 macOS/iOS affected targets。Computer Use 只可用隔离 bundle/fixture 验证 Approve/Decline/Cancel 与 automatic non-actionable，并必须标明 fixture 无 provider/EventLog/responder/executor。还需保留 legacy decode、exact duplicate/reconnect、conflicting duplicate、FIFO middle settlement、Decline continuation、Cancel no-fake-result、cleanup-before-terminal 和普通 nonzero 不误判 sandbox 的正反例；未跑真实 endpoint、remote transport、process-kill 或 Linux bwrap 时必须写 `UNKNOWN`。
- Cowork submitted-intent / composer / attachment admission 任务：至少运行 `SubmissionProtocolTests`、`SubmittedIntentStoreTests`、`SubmissionProjectionTests`、`SubmittedIntentHistoryTests`、`ContextProjectionTests`、`CoworkMentionRoutingTests`、`OrchestrationReliabilityTests`、`AutomaticPermissionReviewTests`、`IntatisArtifactsTests` 与 `swift build`；触及 GUI 时构建 IntatisMac，并用 Computer Use 验证 reviewer/main/Goal/working 不锁 composer、本地 Send 先 durable accept、失败保留同一 submission/Retry、编辑中的新草稿不被旧提交回调清除。若 payload 增加 next-main binding，必须额外确认 legacy decode、new main/Goal nil fail-closed、outbox/replay/Retry 保真、A/B queued submission 各自冻结、direct worker nil、rebind + root/retry queue 同一 atomic batch、Goal continuation/restart 沿用 frozen binding 和 profile unavailable no fallback。磁盘检查必须确认唯一 `user_message + queued(attempt 1)`、状态单调、exact retry 不重复 user message、outbox reconciliation 与无意外 permission/model 事件；触及 ArtifactStore 还要覆盖 owner/mode/no-follow/single-link、并发 read-merge-write、unsafe extension 与 `commitUncertain`。
- Session settings/projection/workspace authorization/bootstrap/recovery 任务：至少运行 `SessionStateProtocolTests`、`SessionProjectionStoreTests`、`IntatisCoreTests`、`AutomaticPermissionReviewTests` 与 `swift build`；触及 macOS workspace lease、GUI/CLI 恢复时构建 IntatisMac/IntatisiOS touched target，并用 Computer Use/临时 session 验证 fresh 七事件/no-send、restart、Project Settings 与 reviewer readiness。磁盘检查必须确认 `events.jsonl` 权威、`session.json` schema2/水位、`workspace-access.plist` schema1 binary/`0600`；测试 legacy migration 时只能用临时 UserDefaults/bookmark fixture，必须覆盖 provenance、all-required verification、marker 幂等与 marker 后 no-fallback resurrection。
- 模型 `rename_session` 工具任务：在上一条基础上至少追加 `SessionNamingToolTests`、`SessionRenameAgentLoopTests`、`IntatisPermissionTests`、`ToolRegistryLeaseTests`、相关 `IntatisCoworkTests` 与 `swift build`；触及 macOS/CLI wiring 时构建 IntatisMac 与 CLI product。测试必须覆盖 schema 只含 `name`、1–120 Unicode/control 校验、current-session host binding、secret 在 authorization/prepared 前拒绝且 raw 名称不落 durable tool-call、exact execution-ID retry 幂等、operation conflict、A→X/B→Y/retry-A 不覆盖 Y、手工/model source、deterministic exact-intent allow/near-miss+locked 非 allow、Cowork 仅 `@main` 可见、legacy main lease 一次性 durable upgrade、worker/coordinator/reviewer 不继承，以及多窗口 exact-session revision/seq 更新。未用真实 provider 触发工具或未人工观察双窗口侧栏时必须明确写 `UNKNOWN`，不能用 scripted provider/unit test 冒充。
- Cowork `update_goal` main capability 任务：至少运行 `GoalManagerRuntimeTests`、`GoalVerifierControlPlaneTests`、`ToolRegistryLeaseTests`、`CapabilityLeaseTests`、相关 restore/bootstrap tests 与 `swift build`。必须覆盖 fresh exact `@main` 可见、legacy default durable replacement 幂等、task-scoped main 保留、worker/spawn coordinator/task-scoped non-main/reviewer 不继承，以及 complete 无独立 host-bound audit、blocked 无三轮相同 verified blocker 时仍 fail closed；不能把“main 能调用工具”写成“main 能自产 Goal completion proof”。
- Agent Git control 任务：至少运行 `swift test --filter IntatisToolsTests`、`swift test --filter IntatisAgentKernelTests`、`swift test --filter IntatisPermissionTests`、`swift test --filter CapabilityLeaseTests`、`swift test --filter ToolRegistryLeaseTests`、`swift build`；改协议/lease/registry 时建议跑 full `swift test`。涉及真实 `ProcessGitService` 的 stage/commit/patch/worktree smoke 应默认跳过，并通过 `INTATIS_REAL_GIT_SMOKE=1` 显式 opt-in。真实远端 fetch/pull/push/auth 不应默认对当前仓库执行；如需验证，应用临时 bare remote 或用户明确指定的测试 remote，且最终报告写明未覆盖的真实 Git 仓库矩阵（submodule/worktree、merge conflict、hooks、空 index、detached HEAD、非 repo、patch conflict、远端 auth/权限/网络错误）。
- Agent 文档/媒体工具任务：至少运行 `swift test --filter IntatisToolsTests`、`swift test --filter IntatisAgentKernelTests`、`swift test --filter CapabilityLeaseTests`、`swift test --filter IntatisCoworkTests`、`swift build`；改 macOS/CLI 接入时还应跑 IntatisMac Xcode build。涉及 `read_document` 时还要覆盖 schema/extension/input-output bound、workspace path、read-only/shell-disabled hard deny、Docling/MarkItDown explicit 与 auto fallback、两者缺失的 actionable failure、remote-service/plugin 禁用、默认断网、process timeout/cancel/cleanup、absolute-path diagnostic redaction、legacy Office 的 LibreOffice requirement，以及 read-only worker 与 read-write lease 工具面。已安装 backend 可在临时 workspace 做真实 DOCX/PPTX/XLSX smoke；未安装的 backend、legacy 格式或真实 App/provider-triggered E2E 必须明确写 UNKNOWN。
- Agent 网络/浏览器工具任务：至少运行 `swift test --filter IntatisToolsTests`、`swift test --filter IntatisPermissionTests`、`swift test --filter CapabilityLeaseTests`、`swift test --filter IntatisCoworkTests`、`swift test --filter IntatisAgentKernelTests`、`swift build`；改 macOS/CLI 接入时还应跑 IntatisMac Xcode build。表单/动态页面能力变更需覆盖 click/type（含敏感目标拒绝）/submit/select-option/press-key/scroll/wait/reload/back/forward/handoff/upload/download/downloads/history 和交互控件摘要输出的 fake-shell 测试；profile 并发语义变更需覆盖同 profile 命令不重叠、不同 profile 不全局串行的 fake-shell 测试。本机允许启动浏览器和访问外网时，可额外运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserBackendSmokeWhenEnabled` 验证真实 Playwright/CDP 后端，运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserSearchWhenEnabled` 验证真实搜索页访问和 search history metadata；允许启动本地 HTTP 服务和浏览器时，可运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled` 验证同一 profile 的持久 cookie/localStorage/history 持久化，运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserProfilesRemainIsolatedWhenEnabled` 验证两个 profile 的状态隔离，运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserBackForwardWhenEnabled` 验证真实前进/后退导航栈，并运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserScrollAndWaitWhenEnabled` 验证真实滚动和动态等待；允许启动浏览器时，可运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserUploadDownloadWhenEnabled` 验证真实 file input 上传和 browser download 保存/metadata 路径，运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserSelectAndPressKeyWhenEnabled` 验证真实下拉选择、按键分发和交互控件摘要，运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserSubmitWhenEnabled` 验证本地 HTTP 表单提交和 submit history metadata，运行 `INTATIS_REAL_BROWSER_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserDynamicFeedAndOnlineTaskWhenEnabled` 验证真实动态信息流浏览与本地在线任务提交，并运行 `INTATIS_REAL_BROWSER_HANDOFF_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserHandoffWhenEnabled` 验证真实 headed handoff profile。验证不同 profile 的真实并发启动时，运行 `INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE=1 swift test --filter IntatisToolsTests/testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled`。真实第三方网站表单提交、真实浏览器 smoke 在 Codex sandbox 内可能因浏览器进程无法暴露 DevTools port 或审批失败而无法运行，必要时需按权限提示允许脱离 sandbox 启动浏览器。真实 Playwright/Chromium/Chrome、第三方站点登录、社交媒体、代办网站、真实第三方网站下载/上传/表单提交、长期 profile 清理或真实同时启动多 profile 管理无法验证时，必须在最终报告中写明 UNKNOWN；若只新增工具表面/lease，应额外覆盖 ToolRegistryLease、MessageDelegationSplit、CoworkEndToEnd 的 worker/coordinator 工具面。

## External MCP Linux CLI gate

Linux MCP/CLI 改动必须先运行 portable crypto known-answer tests：

```sh
swift test --disable-sandbox --filter MCPPortableCryptoTests
```

双架构交叉构建使用仓内 `scripts/validate-linux-cli.sh`。调用方必须显式
传入已经过来源/校验和验证的 Swift executable、两个已安装 Static Linux
SDK ID 和输出目录；脚本不猜测 Swiftly、home 或临时目录：

```sh
INTATIS_SWIFT_BIN=/absolute/path/to/swift \
INTATIS_LINUX_SDKS_PATH=/absolute/path/to/swift-sdks \
INTATIS_LINUX_SDK_AARCH64=<installed-aarch64-sdk-id> \
INTATIS_LINUX_SDK_X86_64=<installed-x86_64-sdk-id> \
INTATIS_LINUX_VALIDATION_ROOT=/absolute/path/to/validation-output \
scripts/validate-linux-cli.sh
```

脚本分别执行 `swift build --product intatis`，并要求产物确实是目标架构的
静态 ELF；输出保留每个二进制的 SHA-256。macOS 上成功生成 aarch64 与
x86_64 静态 ELF 只证明交叉编译/链接，不代表二进制已经执行。真实 CLI
启动、OAuth/HTTP、stdio、bwrap、DNS/TLS 和进程清理仍须在匹配架构的
Linux host 上单独运行并报告。

2026-07-27 最终源码使用 Swift 6.3.3 RELEASE static SDK
`swift-6.3.3-RELEASE_static-linux-0.1.0` 执行：

```sh
INTATIS_SWIFT_BIN=/private/tmp/intatis-swiftly/toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift \
INTATIS_LINUX_SDKS_PATH=/private/tmp/intatis-swift-sdks \
INTATIS_LINUX_SDK_AARCH64=aarch64-swift-linux-musl \
INTATIS_LINUX_SDK_X86_64=x86_64-swift-linux-musl \
INTATIS_LINUX_VALIDATION_ROOT=/private/tmp/intatis-linux-mcp-validation \
scripts/validate-linux-cli.sh
```

最终结果：

- aarch64 static ELF：266,529,224 bytes；SHA-256
  `8f03fbccb3b8d3301e04ff7e6aca635286771c414ed124407e0fc532718856a9`。
- x86_64 static ELF：271,031,728 bytes；SHA-256
  `0a8071e5d01877c823d634f7a4613b267da64f159714939f10b61f8d65f06a20`。
- product 存在性、静态链接和架构匹配全部通过，脚本 exit 0。
- `RUNTIME_EXECUTION=NOT_RUN host=Darwin/arm64
  reason=cross_build_gate_only`。本机没有 bwrap、Docker、Podman、QEMU、
  Lima 或 Colima，因此 Linux 实机行为、bwrap、真实 stdio/HTTP/OAuth 仍为
  `I-ENV`。

## 2026-07-29 Permission reviewer completion allowance（历史，已由 2026-07-31 规则取代）

- 默认 reviewer policy 从 1024 completion tokens / 45 秒调整为
  4096 tokens / 120 秒；显式 completion allowance 上限为 16384。
  malformed、truncated、timeout 与 provider failure 仍 fail closed，不增加自动
  retry 或人工 fallback。
- 验证命令：
  `CLANG_MODULE_CACHE_PATH=/private/tmp/intatis-reviewer-clang-cache
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/intatis-reviewer-module-cache
  swift test --disable-sandbox --filter
  'PermissionReviewControlPlaneTests|AutomaticPermissionReviewTests'`。
- 结果：64 tests / 0 failures。首次直接运行因托管沙箱拒绝用户级 Clang
  module cache 写入而未进入源码编译；独立 scratch 路径随后因受限网络无法
  fetch `swift-system`，最终复用仓内已解析依赖并把 module cache 定向到
  `/private/tmp` 后通过。未运行完整 SwiftPM、Xcode build 或真实 provider
  reviewer E2E。

## 2026-07-31 Provider parameter compatibility and real-route smoke

- reviewer、legacy `ModelPermissionReviewer`、GoalVerifier 与 chat/agent health
  check 默认不再注入 `temperature`；reviewer/GoalVerifier 默认也不注入
  output-token/字符上限。显式 host policy 仍可原值传递；summary compactor 只在
  已知 usable window 或显式 token budget 下派生 correctness ceiling。
- 严格路由 wire 回归保留 `provider.require_parameters=true`，并确认请求体没有
  `temperature`、`max_tokens` 或 `max_completion_tokens`。reviewer provider
  failure 现在持久化经过 `RuntimeErrorPresentation` URL/secret 脱敏的诊断。
- 聚焦组合 `PermissionReviewControlPlaneTests|AutomaticPermissionReviewTests|
  GoalVerifierControlPlaneTests|AgentModelHistoryCompactorTests|
  ModelHistoryCompactionAgentLoopTests|IntatisPermissionReviewerTests|
  IntatisProvidersTests` 通过。相关完整 target 分片为 Providers 148/148、
  Permission 45/45、AgentKernel 165/165、Cowork 319/319、CLI 28 tests（3 个
  环境/opt-in skip），均为 0 failures；`swift build --disable-sandbox`、
  IntatisMac macOS Debug 与 IntatisiOS Simulator Debug unsigned build 均通过。
- 两个真实 opt-in smoke 使用现有 secret resolver 访问
  `openai/gpt-5.6-luna`：无工具短提示的 exact agent health 请求 1/1 通过（约
  1.25 秒）；完整 `PermissionReviewControlPlane` 请求 1/1 通过（约 3.60 秒），
  覆盖 provider factory、流式响应、verdict 解析及一对 durable
  `permission_review_requested` / `permission_review_settled`，不执行被审查工具。
  key、请求头和完整响应均未进入测试输出。这证明本机当前 strict route 可接受
  省略 synthetic 参数的真实审查请求，不等同于长期 permission verdict 质量或
  cancel/timeout 长尾 E2E 已验证。
- 一键 `swift test --disable-sandbox --quiet` 在约 10 分钟无最终摘要后按仓内已知
  XCTest runner hang 处理并中止（exit 130）；只读进程检查确认没有残留
  `swift-test` / `xctest`。因此不把该次运行记作 full pass，权威结论采用上述
  touched-target 分片。

## 常见问题

- **Linux 构建**：`IntatisSharedUI` 用 `#if canImport(SwiftUI)` 守卫；
  External MCP CLI 还要求 `CryptoKit`/`Crypto` 双后端和
  `Glibc`/`Musl` 双 libc 源码分支通过上述双架构静态构建。
- **Cowork 原则 vs 实现**：当前实现与 `docs/COWORK_PRINCIPLES.md` 原则有已知差距（见该文档 §6"当前已知 Cowork 问题"）。改动前先核对差距清单。
