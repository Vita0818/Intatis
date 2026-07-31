# macOS 分发与沙箱边界

生效日期：2026-07-28

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
  entitlements；
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
