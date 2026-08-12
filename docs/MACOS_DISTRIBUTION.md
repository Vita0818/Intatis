# macOS 分发与沙箱边界

文档状态：当前发行合同
生效日期：2026-07-28
最近核对：2026-08-11
产品基线：v0.48（build 48）

## 产品决策

Intatis 的 macOS 产品只通过 Developer ID 签名、公证和直接下载分发。项目不再
规划、发布或验收 Mac App Store 版本，也不再把 Mac App Store 的 App Sandbox
限制作为产品设计、功能裁剪、依赖选择或测试矩阵的约束。

当前源码中的 `IntatisMacAppStore` target、`.macAppStore` profile 和
`IntatisMac.AppStore.entitlements` 是此前方案留下的兼容/历史实现，不是当前
发行产品面、未来版本承诺或默认验收门。没有用户对业务源码清理的明确授权时，
只如实标注其遗留状态，不自动删除 target、profile、entitlements 或历史测试
记录；任何专门恢复、扩展或验证该 target 的工作也必须由用户另行明确要求。
仓库根 `README.md` 和旧 `codex-report/` 中若仍有“双 macOS 构建”或 App Store
规划文字，均被本文件和 `docs/CURRENT_STATE.md` 的新决策取代，只能作为历史
背景读取。

## 当前 macOS 产品面

- 唯一发行 App target：`IntatisMac`。
- 分发方式：Developer ID 签名、公证、直接下载或用户自建。
- 产品能力：完整 Chat / Code / Cowork、workspace 与 global Skills、managed
  terminal、本地 Git、浏览器/文档 helper，以及 stdio + HTTP MCP。
- 默认 macOS 验收：SwiftPM/CLI、`IntatisMac` Developer ID 产品图，以及与改动
  相关的签名、公证、Hardened Runtime、entitlements 和 bundle/link inventory。
- `IntatisMacAppStore` 不进入日常构建、回归、release gate 或架构权衡。

iOS 当前仍是独立的 chat 子集。本决策不自动删除或扩大 iOS 产品面，也不改变
iOS 自身的系统 sandbox 与 target-linkage 限制。

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
- 要求业务实现、开源依赖或测试同时满足 `IntatisMacAppStore`；
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

除非用户明确点名遗留 target，否则不要构建、修复、测试或报告
`IntatisMacAppStore`，也不要因它失败而修改当前发行产品。
