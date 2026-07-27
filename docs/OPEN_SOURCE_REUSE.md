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

## 官方 Swift MCP SDK 当前准入结论

- 上游：`https://github.com/modelcontextprotocol/swift-sdk`
- 固定版本与 commit：`0.12.1` /
  `a0ae212ebf6eab5f754c3129608bc5557637e605`
- 复用形式：`vendored` + `derived`；本地 client-only package 位于
  `Vendor/MCPClientSDK`。
- 许可证：上游处于许可迁移期；完整组合文本同时保留 Apache-2.0、未完成
  relicensing 的既有 MIT contribution，以及非 specification 文档的
  CC-BY-4.0 声明。不得把整批源码简写成单一许可证。
- 最终 SwiftPM 依赖闭包固定为 `swift-system 1.4.0`、
  `swift-log 1.6.2` 与 Apple 平台 `EventSource 1.1.0`；精确 revision
  由本地 manifest 和根 `Package.resolved` 双重固定。`swift-nio`、
  docc plugin、swift-atomics 与 swift-collections 不进入 MCP 产品依赖图。
- Linux CLI/MCP 图额外使用官方 `apple/swift-crypto 4.5.1`
  （commit `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6`）的 `Crypto`
  product，替代 Linux 不存在的 CryptoKit；所有 root target dependency
  都有 `.linux` 平台条件，macOS/iOS 继续只链接系统 CryptoKit。
  其传递闭包包括 `swift-asn1 1.7.1`，且 swift-crypto 内 vendored
  BoringSSL `0226f30467f540a3f62ef48d453f93927da199b6` 和 XKCP
  `11297f566178023faba59ff14b6b399241488283` 的完整许可证/NOTICE、
  精确来源和完整性散列均登记在 `ThirdPartyNotices/SwiftCrypto.md`
  与 `ThirdPartyNotices/Licenses/`；不得换成自制散列/加密 fallback。
- 上游 `MCP` product 同时含 client/server API，不满足 Intatis
  client-only 边界。因此本地衍生包排除 `Server` actor、HTTP Server
  transports、conformance executables、paired in-memory/custom network
  transports 与 server-side OAuth publishing/validation types；只保留
  Client、Base client closure 以及客户端必须使用的 tools/resources/
  prompts/completion/logging wire schema。
- `Vendor/MCPClientSDK/UPSTREAM.md` 固定源码 inventory，
  `Vendor/MCPClientSDK/PATCHES.md` 记录逐项修改与升级重放要求，
  `ThirdPartyNotices/MCPClient.md` 和 `ThirdPartyNotices/Licenses/`
  提供分发声明与完整许可证。根 `NOTICE.md` 已登记本次实际采用项。
- 任何升级都必须重新验证 client-only 编译闭包、per-server version
  patch、HTTP/OAuth/stdio/tasks conformance、Swift/macOS/Linux compatibility
  和无 Server API/target/binary/seam；Linux 还必须重跑 portable crypto
  KAT 与 glibc/musl 双架构静态构建。不能直接切回上游单一 `MCP`
  product。

## Codex MCP tool_search 派生复用记录

- 上游：`https://github.com/openai/codex`，固定 commit
  `61a44880a85d2fd0d8770908dea5733495e571c8`；许可证 Apache-2.0。
- 复用形式：公开 `tool_search` wire/history 合同、MCP 搜索文本字段和
  stdio schema cache 行为按 `derived` 登记；未采用 Codex MCP Server、
  UI、品牌资产、私有 prompt 或 Rust runtime。
- Codex 固定使用 `bm25 2.3.2` 的 English default tokenizer。Intatis
  对 scoring/embedder/tokenizer/Snowball/fxhash 做 Swift 派生实现，
  base64 封装 deunicode 1.6.2 未修改数据，并复制 stop-words 0.9.0 的
  179 项英文表。对应 MIT/BSD-3-Clause/Apache-2.0 来源、crate
  checksum、文件级修改和完整声明见
  `ThirdPartyNotices/MCPToolSearch.md`。
- `Tests/MCPBM25ParityOracle` 是不进入产品 target 的 source-only Rust
  差分工具；语料由代码生成，不分发 `rust-stemmers/test_data`。Swift
  测试固定 tokenizer、stemmer、逐位 BM25 分数和 10,000 文档压力结果。
- 任何 Codex 或 tokenizer 依赖升级都必须重新固定源码/包 checksum，
  运行 Rust oracle 与 Swift digest/bit-pattern 对照，并重新核对
  `tool_search_output` history、deferred tools 不进入后续顶层 `tools`、
  stale catalog fail-closed 及 32-entry/30-minute stdio LRU 边界。

## MCP 原生 HTTP transport 准入结论

- `Packages/IntatisCurlTransport` 是 Intatis 自有的 C/Swift 边界实现；
  没有复制 curl、BoringSSL 或 zlib 源码。复用形式是 `dependency`：
  macOS 链接 Apple SDK/系统提供的 libcurl，Linux CLI 链接官方 Swift
  Static Linux SDK 提供的静态 archive。iOS 不链接该 target。
- Apple 路径不 vendor 或随 App bundle 复制 Darwin libcurl；release
  必须用最终 App linkage/bundle inventory 复核这一点。Linux 路径会把
  实际使用的 object code 合入单文件静态 CLI，因此必须随 CLI 提供完整
  第三方声明，不能把 SDK 中的库误当成终端用户系统库。
- Linux 构建制品固定为官方
  `swift-6.3.3-RELEASE_static-linux-0.1.0` artifact，Swift.org 公布的
  archive SHA-256 为
  `87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b`；
  提取后的 SPDX SBOM SHA-256 为
  `bef245e3aa47c9623dfc7e5d4df01510f283722b6e8d9a80a38cc3c1cb4040a0`。
  `libcurl.pc` 的静态闭包是
  `-lcurl -lssl -lcrypto -lz`，两套 architecture archive 的逐文件
  hash 见 `ThirdPartyNotices/MCPHTTPTransport.md`。
- curl 的 SBOM 条目为 `8.15.0`/`MIT`，但 SDK 自带
  `curlver.h`/`libcurl.pc` 标成 `8.15.0-DEV`，后者文件头使用精确
  SPDX `curl`。准入采用更保守的 curl 原始 `COPYING` 条款，不能只按
  泛化 MIT 处理。zlib 由 SBOM 与 header 共同确认是 1.3.1 / `Zlib`。
- SDK 的 `libssl.a` / `libcrypto.a` headers 明确是 BoringSSL，SBOM
  许可证表达式为 `OpenSSL AND ISC AND MIT`，但 `versionInfo` 为空。
  该 SBOM 缺项已通过 Swift 官方 Static Linux SDK 构建 recipe
  `swiftlang/swift-docker@cdfdf30bef6f1529ad34662274db00781d87ab61`
  与双架构 header 字节身份交叉校验收口：curl 固定
  `curl-8_15_0` / `cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a`，
  BoringSSL 固定
  `817ab07ebb53da35afea409ab9328f578492832d`，zlib 固定 `v1.3.1` /
  `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`。SDK 中 `aarch64` 与
  `x86_64` 的 `curlver.h`、`openssl/base.h`、`zlib.h` Git blob
  分别与上述固定源码完全一致；详细 blob ID 见
  `ThirdPartyNotices/MCPHTTPTransport.md`。
- Swift Crypto 4.5.1 的 BoringSSL commit
  `0226f30467f540a3f62ef48d453f93927da199b6` 是另一套依赖，不能与
  Static Linux SDK 的
  `817ab07ebb53da35afea409ab9328f578492832d` 相互冒充。官方 artifact
  checksum、SBOM hash、Swift recipe/source pins、headers/pkg-config
  与逐 architecture archive hash 共同构成可复验 provenance；SDK 未
  提供单 archive 的 signed source attestation 或 reproducible-build
  声明，文档不能把 header identity 夸大为 `.a` 的逐位复现证明。
  Linux 分发仍须附带 OpenSSL、Original SSLeay、ISC 与 fiat-crypto
  MIT 的完整组合文本及必要 acknowledgement。
- 完整来源、二进制 hash、许可证文本和分发义务位于
  `ThirdPartyNotices/MCPHTTPTransport.md` 与
  `ThirdPartyNotices/Licenses/curl-8.15.0-COPYING.txt`、
  `ThirdPartyNotices/Licenses/zlib-1.3.1-LICENSE.txt` 与
  `ThirdPartyNotices/Licenses/BoringSSL-817ab07ebb53da35afea409ab9328f578492832d-LICENSE.txt`；
  根 `NOTICE.md` 已区分 Apple system library、Linux static archive
  与 Swift Crypto 的另一套 BoringSSL closure。
- 升级 Swift toolchain/Static Linux SDK、替换 archive、改变 link
  flags 或新增 TLS/compression backend 时，必须重新下载核验官方
  checksum、读取完整 SBOM/pkg-config/headers、重算双架构 archive
  hash、比较许可证/NOTICE、更新上述记录，并重跑双架构静态 build。
  仅复用旧 notice 或仅看到库名相同不构成升级准入。

## 上游升级规则

- 每个已采用上游维护一个 pinned commit 和本地 patch/translation 摘要。
- 升级时先比较许可证、NOTICE、依赖和安全边界，再比较源码；不能只做版本号替换。
- 上游的新权限默认、工具能力或网络/文件访问不能自动继承到 Intatis；必须重新映射到 CapabilityLease、WorkspaceLease 和 PermissionEngine。
- 无法确认行为或许可证变化时标记 `UNKNOWN` 并停止合入，不得猜测。
