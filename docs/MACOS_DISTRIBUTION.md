# macOS 分发与沙箱边界

文档状态：当前发行合同
生效日期：2026-07-28
最近核对：2026-08-22
产品基线：v0.55（build 55）

## 产品决策

Intatis 的 macOS 产品只通过 Developer ID 签名、公证和直接下载分发。项目不再
规划、发布或验收 Mac App Store 版本，也不再把 Mac App Store 的 App Sandbox
限制作为产品设计、功能裁剪、依赖选择或测试矩阵的约束。

用户已于 2026-08-21 明确要求删除旧 Mac App Store target。当前源码和 XcodeGen
工程定义已不再包含 `IntatisMacAppStore` target/scheme、`INTATIS_MAC_APP_STORE`
编译条件或 `IntatisMac.AppStore.entitlements`。`.macAppStore` profile 只在共享协议
解码和隔离测试中保留兼容语义，不对应可构建 App，也不得据此恢复第二个产品图。
历史测试记录继续按发生时事实保留，不改写为当前构建能力。
仓库根 `README.md` 和旧 `codex-report/` 中若仍有“双 macOS 构建”或 App Store
规划文字，均被本文件和 `docs/CURRENT_STATE.md` 的新决策取代，只能作为历史
背景读取。

## 当前 macOS 产品面

- 唯一发行 App target：`IntatisMac`。
- 分发方式：Developer ID 签名、公证、直接下载或用户自建。
- 产品能力：完整 Chat UI 与 Codex Runtime-backed Code/Cowork workspace shell。原 global Skills、
  managed terminal、Git、browser/document helper和stdio/HTTP MCP源码仍在仓内，但在新的
  Code/Cowork shipping turn 中只有完成Codex官方MCP/plugin接线后才能恢复产品可用性，不能走旧内核。
- 默认 macOS 验收：SwiftPM/CLI、`IntatisMac` Developer ID 产品图，以及与改动
  相关的签名、公证、Hardened Runtime、entitlements 和 bundle/link inventory。
- 生成的 Xcode 工程不得重新出现 `IntatisMacAppStore` target 或 scheme。

iOS 当前仍是独立的 chat 子集。本决策不自动删除或扩大 iOS 产品面，也不改变
iOS 自身的系统 sandbox 与 target-linkage 限制。

## Codex Runtime auxiliary executable gate

2026-08-22 的第一版源码把 OpenAI Codex App Server 作为 external runtime，固定
基于source commit `25af12f7e61572b0bc18ddb1008be543b91519b0`和仓内provider-body passthrough patch的
`codex-cli 0.145.0-intatis.2`。当前 `IntatisMac` Debug build仅从开发机local安装发现 exact binary；
`project.yml` 尚未把它复制进 App bundle，因此现有打包脚本
即使通过旧 gate，也不能被描述为“Codex-backed独立分发候选”。

正式恢复 `scripts/package-macos-release.sh` 输出前必须新增并验证：

1. fixed source/Cargo.lock + checked-in patch的arm64+x86_64可复现build与每架构hash；
2. exact Rust dependency closure的全部license/NOTICE，包含upstream Ratatui-derived attribution；
3. universal或architecture-correct nested `Contents/MacOS/codex`/auxiliary位置与final bundle inventory；
4. nested executable先以同一Developer ID team签名并启用适用Hardened Runtime，再签outer App；
5. outer App和DMG的notarization/staple/Gatekeeper后，在无用户预装Codex、无`~/.codex`登录的fresh
   account中验证Intatis isolated CODEX_HOME、custom Responses provider与`codex --version`；
6. update/rollback必须以整个已签名App版本为单位，不能从PATH悄悄切到另一Codex版本。

任一门槛缺失必须阻断release；不得把external开发依赖静默当成用户先决条件，也不得bundle未审计
单架构binary、关闭library validation、放宽entitlements或回退旧AgentLoop。

开发预览不是正式release，但只要交给用户运行，也必须显式使用`ENABLE_DEBUG_DYLIB=NO`，确认
`Contents/MacOS`只有主可执行文件且`otool -L`无`IntatisMac.debug.dylib`引用，再按现有Developer ID
entitlements做ad-hoc Hardened Runtime签名并从最终交付路径真实启动。Xcode 27默认Debug launcher即使
通过deep/strict codesign，仍可能因主程序与debug dylib的non-platform Team ID不一致被DYLD拒绝；不得
通过关闭library validation规避。

2026-08-19 用户已批准 JetBrains Mono 为 macOS/iOS 统一的第一方英文字体。两份 exact v2.304 TTF
随 `IntatisSharedUI` resources 进入 Debug、Release 与正式 bundle；没有 system-font opt-out 或实验打包
分支。正式 release build 必须核对 exact resource inventory/hash、OFL、bundle size、Dynamic Type、
VoiceOver 与中英混排，并在任一漂移时 fail closed。字体选型不再单独阻断发行；签名、公证、Gatekeeper
和 clean-machine 等其余发行门槛仍须全部满足，且不得覆盖既有 notarization recovery artifact。

## 直分发打包入口

仓库唯一正式打包入口是 `scripts/package-macos-release.sh`。它只构建
`IntatisMac`，并且在以下所有条件成立后才把产物写入 `dist/`：

1. 当前 Keychain 存在有效的 `Developer ID Application` identity；
2. `INTATIS_NOTARY_PROFILE` 指向用户已通过 `notarytool store-credentials`
   保存的 Keychain profile；
3. universal Release build 同时包含 `arm64` 与 `x86_64`；
4. 使用 Developer ID entitlements、secure timestamp 与 Hardened Runtime 完成签名；
5. App 公证状态为 `Accepted`，staple/validate、严格 codesign 与 Gatekeeper assessment
   全部通过；
6. DMG 包含 `/Applications` 拖放入口，以 Developer ID 单独签名，再次公证并完成
   staple/validate、codesign 与 Gatekeeper assessment。

使用方式：

```sh
INTATIS_NOTARY_PROFILE=<本机 profile 名称> \
  scripts/package-macos-release.sh
```

如果当前网络必须通过本机代理/VPN 才能访问 GitHub，但该代理/VPN 会阻断 Apple
notarization，使用交互式两阶段模式：

```sh
INTATIS_PAUSE_BEFORE_NOTARIZATION=1 \
INTATIS_NOTARY_PROFILE=<本机 profile 名称> \
  scripts/package-macos-release.sh
```

运行命令时保持代理/VPN 开启，让 Xcode/SwiftPM 完成依赖解析、Release 构建和 Developer
ID 签名。脚本提示 `GitHub is no longer used after this point` 后保持终端打开，关闭会阻断
Apple 的代理/VPN，再按 Return。脚本会用当前 Keychain profile 探测 Apple notarization；
若仍不可达，会保留已经签名的临时 App 并原地等待重试，不重新构建。不要为了这个流程删除
Git 的 GitHub 专用 proxy 配置；该配置在暂停点之后不再参与后续步骤。

上传使用 `notarytool submit --no-wait --progress`，终端持续显示上传进度并在上传结束后记录
submission ID。随后 `notarytool wait` 默认最多等待 30 分钟；可通过
`INTATIS_NOTARY_TIMEOUT=2h` 等正时长显式调整。超时不代表失败，Apple 会继续处理；若状态
仍是 `In Progress`，脚本以非零状态安全退出并把签名 App、上传日志、submission ID 和后续
DMG 状态保存在 owner-only 的 `.intatis/release-recovery/<run>/`。不得因此重复上传。按脚本
打印的精确命令恢复同一提交，例如：

```sh
INTATIS_NOTARY_PROFILE=<本机 profile 名称> \
INTATIS_RESUME_RELEASE_DIR=<脚本打印的绝对 recovery 路径> \
  scripts/package-macos-release.sh
```

恢复模式重新核对版本、universal 架构、Developer ID、Hardened Runtime 和 entitlements，
然后复用已记录的 App/DMG submission ID；不会重新构建或重新上传。签名完成后的 Control-C、
TERM、网络错误、Apple 长时间处理或 Invalid 也保留 recovery 目录，成功输出最终产物后才自动
清理。`INTATIS_RESUME_RELEASE_DIR` 只接受仓库 `.intatis/release-recovery/` 下当前用户拥有、
模式为 `0700` 且 state/App 均非 symlink 的绝对路径。

如果 Keychain 中存在多个 Developer ID Application identity，额外设置
`INTATIS_DEVELOPER_IDENTITY` 为目标证书的完整 common name。可用
`INTATIS_OUTPUT_DIR` 改变输出目录。证书、私钥、Apple 账号/App Store Connect
凭据和 profile 内容都不得进入仓库；脚本只接收 identity/profile 名称。

输出包括 stapled App 的 ZIP、已单独公证并 stapled 的 DMG，以及两者的 SHA-256
清单。任一门槛失败都不得把 ad-hoc/未公证包发布为正式产物。

## “不再考虑 App Store 沙箱”的精确定义

以后不得仅为兼容 Mac App Store App Sandbox 而：

- 移除或禁用 managed terminal、PTY、spawn-based Git、浏览器 helper、stdio
  MCP、global Skill roots 或其他直接分发版能力；
- 新增进程内 Git/MCP/脚本替代实现；
- 把 Code/Cowork 降级成 chat-only 或 HTTP-only；
- 重新引入 `IntatisMacAppStore`、App Store scheme、编译条件或专属 entitlements；
- 将 App Store entitlement/linkage/build 结果列为发布阻塞项。

这项决策只移除 **Mac App Store 分发所强加的 App Sandbox 产品约束**，不移除
Intatis 自己的安全边界。以下要求继续有效：

- `DeterministicPolicyGate` / `ModelPermissionReviewer` /
  `PermissionEngine` 三层权限门；
- `CapabilityLease`、`WorkspaceLease`、`PathConfinement`、
  `SecretScanner`、Mediator 和 EventLog/durable tool ticket；
- managed terminal 的 workspace-scoped Seatbelt、默认断网、凭据环境过滤、
  进程清理和输出边界；
- Developer ID Hardened Runtime、代码签名、公证、Keychain 与最小必要
  entitlements；输入栏语音使用系统 TCC 麦克风授权，并在 shipping Developer ID target 只增加
  Hardened Runtime 所需的 `com.apple.security.device.audio-input=true`，不启用 App Sandbox；
- iOS target 的 chat-only linkage 边界。

因此，后续文档和报告提到 `sandbox` 时必须说明具体含义。`App Sandbox` /
`Mac App Store sandbox` 仅可用于历史记录或遗留 target 说明；`Seatbelt
runtime sandbox`、测试宿主 sandbox、Linux bwrap 和权限/工作区围栏仍是当前
产品安全合同，不能因为本决策而弱化。

## 验证规则

默认产品验证矩阵为：

1. 与改动相称的 SwiftPM focused/full tests；
2. `swift build` 与受影响的 CLI product；
3. `xcodegen generate`；
4. `IntatisMac` macOS build；
5. 触及实际发行时的 Developer ID 签名、公证、Hardened Runtime、
   entitlements 和 bundle/link inventory；
6. 触及 iOS 子集时才追加 `IntatisiOS` build/test。

工程生成后必须检查 target/scheme 清单，确认只有 `IntatisMac` macOS App 与
`IntatisiOS` iOS App，不得静默恢复已删除的 `IntatisMacAppStore`。旧历史报告中的
同名构建结果不进入当前验证矩阵，也不能触发第二套产品修复。
