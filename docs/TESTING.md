# TESTING

文档状态：当前验证矩阵
最近核对：2026-08-03
产品基线：v0.32（build 32）

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

- `project.yml`：`MARKETING_VERSION=0.32`，`CURRENT_PROJECT_VERSION=32`；
- macOS/iOS 参考 Info.plist：`0.32 (32)`；
- 生成的 `Intatis.xcodeproj`：相同版本；
- README、文档索引、CURRENT_STATE 和 PROJECT_MAP：相同当前基线；
- 最终 App bundle：`CFBundleShortVersionString=0.32`、`CFBundleVersion=32`。

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

1. v0.32/build 32 一致性检查；
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
- path escape、symlink/hardlink、secret、credential path、workspace lease fail closed；
- runtime stop 先 drain provider/tool/process，再释放 waiter/subscription/scope；
- Cowork worker 默认无 coordinator tools，reviewer/verifier 不进入普通 scheduler；
- iOS target closure 不出现 Tools/Permission/AgentKernel/Cowork/MCP。

精确不变量见 `docs/DO_NOT_BREAK.md`。

## UI 与可访问性回归

当前至少检查：

- macOS/iOS Light 与 Dark；
- Chat/Code/Cowork session 切换、16-row paging、Earlier/Newer/Latest；
- long rich response、Markdown/table/code/math 和 plain-safe fallback；
- composer 单行/多行、model menu、usage、Send/Stop；
- Cowork wide rail、narrow permission fallback、Goal/Tasks/Agents；
- Settings disclosure、provider test、本地诊断 ZIP；
- Dynamic Type、Reduce Transparency、Increase Contrast、VoiceOver 和 clipboard/selection。

截图或 Computer Use 只能证明对应 viewport/appearance 的视觉行为，不能替代 EventLog、
权限、bundle、签名或长时性能验证。

## 最近一次真实结果

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
- 用户普通终端的 `security find-identity -v -p codesigning` 已报告两个有效 identity，发行
  脚本也已进入真实 Developer ID 签名和 App 上传；Codex 托管沙箱无法读取登录 Keychain，
  因而在沙箱内仍返回 `0 valid identities found`，不能覆盖宿主证据。两次 App submission
  已被 Apple 接收但查询时均为 `In Progress`；尚无 Accepted、staple 或 Gatekeeper 证据。

## Release GO 条件

只有以下条件同时满足才能写 release GO：

- 当前 working tree 相关 tests/builds 通过，已知失败有明确处置；
- 最终 App/ZIP/DMG 元数据为 `0.32 (32)`；
- Developer ID、notarization、staple、codesign、Gatekeeper 全部通过；
- NOTICE/ThirdPartyNotices 和最终 bundle resource/link inventory 一致；
- 关键真实环境矩阵完成，未完成项以明确的风险接受记录处理。
