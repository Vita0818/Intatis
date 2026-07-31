# Intatis 浏览器执行回归修复报告

日期：2026-07-31  
范围：Code / Cowork / CLI 的真实 `browser_*` 执行 lane  
结论：已修复并通过真实 Microsoft Edge/CDP、Tools、AgentKernel、Permission 与
Xcode 27 macOS build 验证。

## 1. 事故现象

问题 session 中 `browser_search` 已经通过 permission reviewer，但 executor
返回：

```text
browser backend failed: browser did not expose a DevTools port
```

与此同时 macOS 显示 Microsoft Edge `EXC_CRASH (SIGABRT)`；crash report 表明
Edge 由 Intatis 的 Node child 拉起。该组合证明：

1. 浏览器工具确实已注册，模型也确实调用到了它；
2. 权限审查已经 allow，不是 reviewer timeout；
3. 浏览器进程开始启动后 abort，失败点位于执行 backend，而非联网能力发现。

## 2. 根因链

v0.19 把真实浏览器 action 与普通 structured network command 合并到
`networkStructuredShell`。macOS 该 runner 为普通命令提供 deny-default
Seatbelt；这个策略会被 Node 启动的整个 Edge 进程树继承。

真实 Edge 试验确认了两层冲突：

- 动态链接/LaunchServices 启动阶段需要的系统访问不适合通用 structured
  command policy；
- 即使逐项放开启动读取，Chromium helper 仍报告
  `forbidden-sandbox-reinit`，因为 helper 需要建立自己的 renderer/service
  sandbox，而它已经继承 Intatis 外层 Seatbelt。

Edge 因此在 DevToolsActivePort 出现前 abort。旧 CDP wrapper 又只在端口出现后
才完整安装 cleanup，于是用户看到的是二次症状“没有 DevTools port”，并可能残留
child 或诊断输出。

WorkspaceLease 的默认敏感路径 deny pattern 还会匹配 Chromium profile 内部的
若干数据库/证书文件名。把浏览器的内部 profile 文件逐一当作模型可写文件审批，
既不可维护，也不是正确的 authority grain；authority 应是 host 固定 driver
对已批准 profile root 的受控使用。

## 3. 被否决的方案

### 3.1 继续扩大通用 deny-default Seatbelt

否决。它不能解决 Chromium helper 的 nested sandbox re-init；继续追加系统路径
allow 只会扩大策略且仍不可靠。

### 3.2 给浏览器单独建立 allow-default 外层 Seatbelt

否决。真实 Edge helper 仍触发 `forbidden-sandbox-reinit`。问题不是 deny 条目
多少，而是浏览器进程树已经处于外层 Seatbelt。

### 3.3 添加 `--no-sandbox`

否决。它可能让浏览器启动，但会关闭 Chromium renderer/service 隔离，把执行
回归变成安全回归。Intatis shipping code 不允许该参数。

### 3.4 回到任意 shell string

否决。模型可控 command、`/bin/sh -c` 或 generic `ShellRunner` 会重新引入命令
注入与 runner 路由混淆。

## 4. 最终实现

### 4.1 专用 typed broker

`ToolProtocol.swift` 定义 internal `BrowserBackendInvocation` 和
`BrowserBackendRunner`；`ToolContext.browserBackend` 是真实浏览器 action 的
唯一执行入口。invocation 只携带 host 生成的固定 JavaScript、base64-encoded
typed arguments、workspace root 和声明的 read/write paths。

shipping `ProcessShellRunner` 对应
`ShellGit.swift::BrowserBackendProcessRunner`：

- 只查找受信任的固定 Node 安装位置；
- 创建 owner-only 临时 runtime/script；
- 使用参数数组直接执行 Node，不经过 shell；
- 清理环境变量，只保留运行所需的最小集合；
- macOS 不添加外层 Seatbelt，保留 Edge/Chrome/Chromium native sandbox；
- Linux 保留 Bubblewrap，缺失时 fail closed。

测试/自定义 host 仍可注入 `browserBackendShell`，但 shipping
`ProcessShellRunner` 即使同时注入 custom structured/network runner，也不会被
后者劫持。

### 4.2 权限和路径边界

该分流不绕过原有 schema、CapabilityLease、PermissionEngine、durable tool
ticket 或 AgentLoop。

每次真实 action 在创建目录前声明并验证：

```text
.intatis/browser/profiles/<profile>
.intatis/browser/downloads/<profile>
.intatis/browser/state/<profile>.json
.intatis/browser/history.jsonl
```

截图再加入 output path，上传再加入 input path。runner 随后重新验证 canonical
root identity、WorkspaceLease read/write access、allowed rules、mandatory
denied patterns 和 PathConfinement。read-only lease、窄 lease、denied path 或
workspace replacement 都在 Node spawn 前 fail closed。

浏览器内部 profile 数据只由固定 driver 处理；工具 observation 不读取或输出
cookies、localStorage、profile databases、下载内容或 secret。

取消冲突的外层 Seatbelt 后，独立复核发现旧 state/history URL 若被篡改成
`file://`，会成为新的 workspace escape 输入。最终实现因此增加三道门：

1. Swift 在 backend spawn 前验证显式 URL、state URL 与 back/forward target；
2. Playwright/CDP fixed driver 在真正导航前再次只接受带 host 的 HTTP(S)；
3. backend result URL 在正文返回或写入 state/history 前再次验证。

伪造 stack 项还会从 metadata/navigation snapshot 中剔除；HTTP/HTTPS 正常状态
保持兼容。

### 4.3 生命周期与输出

共享 process runner 不再把 stdout/stderr 写入运行期间物理无界的临时文件，而是
持续 drain 到 bounded head/tail buffer。CDP cleanup 在 Edge spawn 后立即安装，
不等待 DevToolsActivePort：

- startup abort 会读取有限 stderr 并回收 child；
- timeout/cancel 会 close client、TERM/KILL process tree；
- active browser 状态在所有 terminal path 清除；
- consumer 不轮询也不会让输出 pipe 堵塞。

`DevToolsActivePort` 不再吞掉任意 unlink 错误：只有 `ENOENT` 可继续。新 marker
必须满足本次 launch timestamp、current UID、regular/single-link、bounded size
与 browser endpoint shape；Node 随后读取 `/json/version`，要求 browser
WebSocket path 与 marker 完全一致且绑定同一 loopback port。所有 page target
WebSocket 也必须绑定该 port；`/json/list` 与无现有 page 时的 `/json/new`
PUT/GET fallback 在构造 `CDPClient` 前走同一校验，避免采用旧代或伪造的非本地
endpoint。

Edge/Chrome 启动参数还使用 Chromium 源码公开的
`--disable-crashpad-for-testing`，避免测试/自动化进程创建额外 crashpad broker；
没有关闭 renderer sandbox。

## 5. 修改文件

- `Packages/IntatisTools/Sources/BrowserTools.swift`
- `Packages/IntatisTools/Sources/ToolProtocol.swift`
- `Packages/IntatisTools/Sources/ShellGit.swift`
- `Packages/IntatisTools/Sources/TerminalTools.swift`
- `Packages/IntatisTools/Tests/IntatisToolsTests.swift`
- `docs/CURRENT_STATE.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/PROJECT_MAP.md`
- `docs/TESTING.md`
- `docs/NEXT_TARGET.md`
- 本报告

没有引入第三方依赖、复制 Chromium/Playwright 源码、修改 EventLog schema 或
弱化 PermissionEngine。

## 6. 实际验证

### 6.1 真实 Edge/CDP

```text
testRealBrowserBackendSmokeWhenEnabled
  navigate: 1/1 passed

testRealBrowserSearchWhenEnabled
testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled
  search + persistence: 2/2 passed

testRealBrowserUploadDownloadWhenEnabled
  upload/download: 1/1 passed
```

这些测试使用 shipping `BrowserBackendProcessRunner`，不是 fake runner。

### 6.2 自动化回归

```text
IntatisToolsTests.IntatisToolsTests
  pre-final full run: 97 executed / 15 opt-in skipped / 0 failures

testCDPNewPageFallbackValidatesReturnedWebSocketEndpointBeforeConnect
  final-source targeted behavior: 1/1 passed

AgentKernel browser search/form/dynamic-feed/profile-delete
  4/4 passed

Permission browser gate
  3/3 passed
```

新增覆盖包括 runner selection、完整 managed touched paths、read-only/narrow/
denied lease 的 pre-spawn fail-closed、workspace replacement、sanitized
environment、高输出 bounded drain、伪造 `file://` state/history backend
0-call 拒绝、正常 HTTP/HTTPS 兼容，以及 `/json/new` 外部 WebSocket 在连接前
拒绝。最后一项提取并实际执行 production fixed driver 的 `pageTarget` 函数，
不是单纯源码字符串断言。

```text
testRealCDPBrowserIgnoresStaleDevToolsActivePortWhenEnabled
  pre-seeded forged marker -> current launch endpoint: 1/1 passed
```

### 6.3 App build

```text
Xcode 27 IntatisMac macOS Debug
CODE_SIGNING_ALLOWED=NO
derived data: /private/tmp/intatis-browser-regression-dd
result: succeeded
```

final-source 完整 98-test Tools suite 未再次执行：外层执行审批在最后一次真实浏览器
重跑请求时达到当前额度限制。这里不把旧 full run 与新增测试拼成一次不存在的
“98/98”；可确认的最终源码证据是新增行为测试 1/1、SwiftPM build 成功与上述
Xcode 27 build 成功。此前同一 shipping runner 的正常 Edge、search/profile、
upload/download 和 stale-port real smoke 均已通过。

## 7. 已知边界

本轮已验证本机 Microsoft Edge + CDP fallback。以下仍为 `UNKNOWN`，不能写成已
支持矩阵：

- 可解析 Playwright module 时的真实 Playwright path；
- Google Chrome / Chromium；
- headed `browser_handoff`；
- 不同 profile 的真实同时启动；
- 第三方登录、验证码/2FA、长期 profile 污染与清理；
- latest-built App 中从 Cowork UI 发起的人工端到端搜索。

这些是后续矩阵，不是本次 Edge/CDP startup 回归的未修复条件。

## 8. 参考

- Chromium macOS sandbox 设计：
  <https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/mac/README.md>
- Chromium `disable-crashpad-for-testing` switch：
  <https://chromium.googlesource.com/chromium/src.git/+/master/chrome/common/chrome_switches.cc>
