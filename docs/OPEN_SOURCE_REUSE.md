# OPEN_SOURCE_REUSE

生效日期：2026-07-12

## 项目立场

Intatis 是 Apple-first、Swift-native 优先的本地 AI workbench。项目不再采用“禁止直接复用外部源码”的严格 clean-room 政策；允许在许可证兼容、来源清晰、归属完整、安全边界不降级的前提下，选择性复制、翻译、修改、链接或以独立进程复用成熟开源实现。

允许复用不等于无条件搬运。Intatis 的产品身份、Apple 平台体验、权限模型、持久化协议和安全边界仍由本项目控制。

## 允许的复用形式

```text
reference       只研究公开行为、架构与测试，不复制表达
derived         复制、翻译或改写具体源码/公开 prompt；视为派生复用
vendored        把上游源码或资源放入仓库
dependency      通过 SwiftPM、系统库、包管理器或动态/静态链接使用
external-runtime 以独立 helper/process/service 运行上游实现
```

逐行把 TypeScript、Rust、Go 等源码翻译成 Swift 仍属于 `derived`，必须保留来源与许可证记录，不能标成独立 clean-room 实现。

## 许可证准入

- MIT、BSD-2-Clause、BSD-3-Clause、ISC、Apache-2.0 等宽松许可证可在完成文件级和依赖级核对后采用。
- GPL、AGPL、LGPL、MPL、SSPL、BSL、Commons Clause、source-available、双重许可或自定义许可证必须在引入前单独评估传播义务、链接边界、网络服务条款和商业限制，并取得用户明确批准。
- 缺少许可证、许可证范围不清、文件头与根许可证冲突、来源不明或仅来自代码片段转载的内容不得复制。
- 根仓库许可证不自动覆盖 vendored 依赖、生成物、字体、图标、截图、模型权重、数据集或第三方资产；必须逐项确认。
- MIT 等宽松许可证通常允许闭源商业使用，但仍须保留其要求的版权和许可声明；许可证合规不等于获得商标或品牌授权。

## 永久禁止项

- 不使用泄露、反编译、绕过访问控制获得的源码或私有 prompt。
- 不复制第三方产品名称、Logo、图标、截图、UI 资产、商标性外观或品牌文案作为 Intatis 产品身份。
- 不把上游许可证、版权声明或来源记录删除、模糊化或错误标成 Intatis 原创。
- 不因复用外部实现而绕过 `DeterministicPolicyGate`、`PermissionEngine`、`CapabilityLease`、`WorkspaceLease`、`PathConfinement`、`SecretScanner`、`Mediator`、durable tool ticket 或 EventLog 审计。
- 不让外部 runtime 扩大 iOS 平台边界；iOS 仍不得获得本地 workspace Agent、shell、Git 或 Cowork 执行能力。

## Prompt、文案与资产

- 公开仓库中由兼容许可证覆盖的 model-facing prompt 可以按 `derived` 复用，但必须固定上游 commit、记录来源、移除上游品牌/支持链接，并重新核对 Intatis 的工具名、权限语义和安全边界。
- 私有、泄露或许可证不明确的 prompt 永久禁止使用。
- 用户可见文案默认由 Intatis 自己编写；若确需复用开源文案，按源码同等记录来源，但不得造成官方关联或商标混淆。
- UI 图标、Logo、截图、产品名称和品牌视觉不因源码采用 MIT 等许可证就自动进入允许范围；没有单独确认时不得复用。

## Apple-first 实现规则

- App shell、SwiftUI/AppKit 界面、EventLog、权限控制、lease、scheduler、workspace bookmark 与 iOS/macOS 平台边界优先保持 Swift 原生。
- 从非 Swift 项目复用时，先判断是“选择性翻译核心逻辑”还是“隔离为外部 runtime”更合适，不做无边界的整仓移植。
- Node/Bun/Rust/Go 等 helper 默认只可作为 macOS DeveloperID 路径的隔离组件评估；引入前必须设计签名、Hardened Runtime、sandbox、更新、进程清理、资源占用和失败降级。不得把它们隐式带入 iOS target。
- 外部 runtime 必须通过受控协议接入 Intatis，由 Intatis 继续拥有权限决定、工作区授权、事件审计和用户可见状态；不得让上游 runtime 成为不可审计的第二事实源。

## 每次复用前的检查清单

1. 固定上游仓库 URL、tag/commit 和具体文件路径；不得直接跟随浮动 `main`/`dev` 作为可重复构建依据。
2. 读取根许可证、目标文件头、NOTICE、依赖清单和相关资产许可证。
3. 选择 `derived` / `vendored` / `dependency` / `external-runtime` 之一，并说明为何适合 Apple 平台。
4. 评估 SwiftPM/Xcode target、macOS 签名、App Store、iOS 子集、binary size、更新和供应链影响。
5. 说明外部实现如何接入现有 Permission/EventLog/Lease/PathConfinement 边界。
6. 在 `NOTICE.md` 增加当前实际采用项；需要分发完整第三方声明时新增 `ThirdPartyNotices/<project>.md`。
7. 对直接复制或翻译的文件，在文件头或相邻来源清单中记录上游 URL、commit、原许可证、本地修改摘要；不得把许可证全文散落复制到每个源码文件。
8. 添加与复用风险相称的测试，并对照上游测试覆盖输入校验、错误路径、取消、并发和安全边界。
9. 最终报告明确区分“直接复制”“翻译/改写”“仅参考行为”和“独立实现”。

## OpenCode 当前准入结论

- 官方活跃仓库：`https://github.com/anomalyco/opencode`
- 调研时根许可证：MIT
- 当前状态：`research-only`，截至本政策生效时尚未把 OpenCode 源码、公开 prompt 或 UI 资产加入 Intatis。
- 后续允许选择性复用其具体实现，但每批必须固定 commit、核对目标文件与传递依赖，并按本政策记录 provenance。
- Intatis 不使用 OpenCode 名称、Logo、图标或 UI 品牌；若复用 TypeScript 实现，优先选择可验证的逻辑/测试进行 Swift 派生实现，或作为 macOS-only 隔离 runtime 评估。

## Codex CLI managed terminal 参考记录

- 上游：`https://github.com/openai/codex`
- 固定 commit：`1a817bb95d942d4ca93f6ed09c97968713ff6d2a`（调研日期 2026-07-24）
- 核对结果：根许可证为 Apache-2.0，仓库包含 NOTICE；本轮阅读了 `codex-rs/core/src/unified_exec/process_manager.rs`、`async_watcher.rs`、`head_tail_buffer.rs`、`codex-rs/utils/pty/src/pty.rs`、`process.rs`、`codex-rs/core/src/tools/handlers/unified_exec/write_stdin.rs`、`codex-rs/protocol/src/shell_environment.rs` 与 `codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`。
- 本轮复用形式是 `reference`：参考了“长进程返回 session、后续继续写 stdin/轮询”“真实 PTY/controlling terminal”“持续 drain 且有界保留 head+tail”“process/session manager 负责取消与清理”“sandbox 与环境由 host 冻结”等行为和测试方向。
- Intatis 的 `ProcessTerminalSessionManager`、Swift tool/lease/permission/EventLog 接线和 `IntatisPTYLauncher` C helper 均为独立实现；没有复制、逐行翻译、vendor 或链接 Codex Rust/C 源码、prompt、测试、文案、名称、Logo 或 UI 资产。因此本轮没有新增第三方分发物，也没有修改 `NOTICE.md`。如果后续直接采用任何 Codex 文件或表达，必须把对应批次改记为 `derived` / `vendored` / `dependency`，重新核对该 commit 的目标文件、依赖、Apache-2.0 NOTICE 与本地修改摘要后再更新 NOTICE。

## Codex CLI 模型历史参考记录

- 上游：`https://github.com/openai/codex`
- 固定 commit：`4c43465133428898aa84f0bfc02c306ed65fb66a`（调研日期 2026-07-25）
- 核对结果：根许可证为 Apache-2.0，仓库包含 NOTICE；本轮重点阅读 `codex-rs/core/src/state/session.rs`、`context_manager/history.rs`、`context_manager/normalize.rs`、`codex-rs/core/src/session/turn.rs`、`session/rollout_reconstruction.rs`、`codex-rs/protocol/src/models.rs`、`protocol.rs`、`codex-rs/rollout/src/policy.rs` 以及对应 context/history/compaction tests。
- 本轮复用形式是 `reference`：参考同一 thread 持有有序 model items、completed item 单次入历史、function call/output 按 call ID 配对、请求前对 missing/orphan pair 做 prompt-only 归一化、resume 从 rollout 重建，以及 compaction 保存完整 `replacement_history` 的行为。
- Intatis 的 `ModelHistoryItemPayload`、EventLog wire event、Swift projector、legacy bridge、AgentLoop 接线和测试均为独立实现；没有复制、逐行翻译、vendor 或链接 Codex Rust 源码、prompt、测试、文案、名称、Logo 或 UI 资产。因此本轮没有新增第三方分发物，也没有修改 `NOTICE.md`。后续若直接采用上游任何文件或表达，必须重新按目标 commit 核对来源与 Apache-2.0 NOTICE，并把复用类型改为 `derived` / `vendored` / `dependency`。

## 上游升级规则

- 每个已采用上游维护一个 pinned commit 和本地 patch/translation 摘要。
- 升级时先比较许可证、NOTICE、依赖和安全边界，再比较源码；不能只做版本号替换。
- 上游的新权限默认、工具能力或网络/文件访问不能自动继承到 Intatis；必须重新映射到 CapabilityLease、WorkspaceLease 和 PermissionEngine。
- 无法确认行为或许可证变化时标记 `UNKNOWN` 并停止合入，不得猜测。
