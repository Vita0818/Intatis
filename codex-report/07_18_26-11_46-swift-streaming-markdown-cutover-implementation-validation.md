# Intatis SwiftStreamingMarkdown 生产切换、仓内 Vendoring 与验收报告

> 日期：2026-07-18
>
> 依据：`codex-report/07_17_26-22_16-swift-streaming-markdown-adoption-migration-report.md`
>
> 范围：macOS Chat / Code / Cowork 与 iOS Chat 的 assistant/agent 消息显示
>
> 上游 basis：Microsoft SwiftStreamingMarkdown `v0.6.0` / `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`
>
> 当前判定：**RELEASE NO-GO。renderer 实现切换、旧源码/旧 direct dependency 退出、仓内 vendoring、当前源码的 macOS/iOS Debug/Release build、两个 unsigned Archive 与六份 app bundle audit 已完成；事故后 vendored 包 strict Debug/Release 各 44/44、SharedUI `MessageRenderingTests` 21/21。可是 latest-build GUI/Computer Use 验收发生失控增长：Force Quit 显示主 `Intatis Renderer Validation` 实例为 129.63 GB application memory，系统诊断另记录采样 footprint 109.16 MB→803.30 MB。该轮验收为 `FAIL / ABORTED`，根因仍为 `UNKNOWN`。已落地 diff/layout/selection amplification-path 修复并通过无界面验证，但在受控单实例 GUI 复验通过前，当前工作树不可发布。**

## MODEL_CHECK_RESULT

当前模型：GPT-5 系列 Codex；运行环境没有提供可核实的更细服务端型号。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者一致，符合项目要求。
- 工作树在 Markdown 工作开始前已有 per-agent inference profile、Goal/Cowork 等用户改动；本任务没有清理、回退、暂存或提交这些改动。

## 1. 最终结论

这次迁移没有在 Intatis 内重写 Markdown renderer。当前产品边界是：

```text
EventLog / projection raw String（唯一真值）
  -> IntatisMessageContentView（唯一产品 facade）
     -> 仓内 Microsoft 派生包 DocumentView（可丢弃 rich projection）
     -> facade-lifetime raw Text projection（永久 plain-safe / pending / oversize 熔断）
```

已经完成的核心结果：

1. Microsoft SwiftStreamingMarkdown 的 parser integration 与原生 SwiftUI/TextKit 布局成为唯一 rich 路径。
2. 完整可构建的派生包已存入 `Vendor/SwiftStreamingMarkdown`，根 `Package.swift` 使用相对仓内路径，不再依赖 `/private/tmp`，也不需要单独发布一个 Intatis 远端 fork。
3. Microsoft MIT `LICENSE`、README、生产源码、测试、`Package.resolved` 与永久 patch/provenance ledger 一起进入仓内，由包含它们的 Intatis 根 Git revision 统一版本化。
4. 旧 MarkdownUI、自有 cmark/math/code adapter、iosMath、highlight.js/HighlightSwift、NetworkImage、Shimmer、snapshot/macro 依赖与旧资源已经退出当前生产源码/依赖图。
5. Chat、Code、Cowork 与 iOS Chat 仍只认识 `IntatisMessageContentView`，没有复制 renderer；CLI/headless 不链接 Apple UI renderer。
6. Intatis 只保留 renderer-neutral 的 admission、revision、latest-only 调度、安全配置、主题映射和 raw fallback；没有新增 Markdown lexer、parser、AST rewriter、table layout、code grammar 或 TeX renderer。
7. Rich 默认开启；`plainSafe` 仍可通过设置或启动参数立即熔断，不迁移 session、不改写 EventLog。
8. 事故后恢复了上游 `DocumentView` / 两平台 `ParagraphView` 的等值 diff 护栏，稳定宽度只触发一次 intrinsic-size 刷新，并把 rich selection ownership 从整棵 `DocumentView` 下沉到实际可选择的 paragraph/table/code leaf；这些是对高置信放大路径的最小修复，不是对最终根因的形式化证明。

当前状态要分成三件事：

| 问题 | 结论 |
|---|---|
| 旧 renderer 是否已退出生产源码与 direct dependency 图 | **是** |
| SwiftStreamingMarkdown 派生源码是否已进入 Intatis 仓库 | **是** |
| 当前工作树是否已经完成全部 release 验收 | **否；latest-build GUI/Computer Use 为 `FAIL / ABORTED`，整体 `NO-GO`** |

供应链的原阻碍已经改变：**“必须先发布远端 immutable fork”不再是 blocker**。但未提交的工作树本身仍不是发行 identity；最终分发仍应指向一个包含 `Vendor/SwiftStreamingMarkdown`、许可证和 ledger 的确定 Intatis 根 commit/tag。

此外，vendored 包的两个 parser dependency 仍是远端 exact pin：`swift-markdown 0.8.0` 与传递的 `swift-cmark 0.8.0`。首次无缓存解析仍需要从 GitHub 取得它们，所以当前方案是“renderer 派生源码仓内固定”，不是“整个依赖图完全离线”。

## 2. 许可证、归属与 Vendoring 边界

### 2.1 归属

MIT 允许复制、修改、合并、发布和分发。Intatis 可以维护这份仓内派生源码，但不能把 Microsoft 原始代码表述成 Intatis 独立原创。当前做法是：

- 保留上游 Microsoft MIT `LICENSE`；
- 在根 `NOTICE.md` 和 `ThirdPartyNotices/MarkdownRendering.md` 标明上游与修改关系；
- 在 vendored 目录内永久保留 `INTATIS_PATCH_LEDGER.md`；
- 将 Intatis 新增/修改部分描述为对 Microsoft v0.6.0 的派生维护，而不是重写或原创 renderer。

### 2.2 精确上游 basis

```text
Upstream: https://github.com/microsoft/SwiftStreamingMarkdown
Tag:      v0.6.0
Commit:   c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd
License:  MIT
```

仓内位置：

```text
Vendor/SwiftStreamingMarkdown
```

根 manifest：

```swift
.package(path: "Vendor/SwiftStreamingMarkdown")
```

这消除了旧的绝对路径：

```text
/private/tmp/SwiftStreamingMarkdown
```

### 2.3 导入规模和保留内容

当前 vendored snapshot：

- 108 个 regular files；
- `du -sh` 约 628 KiB 的仓内文件系统占用；文件 payload 合计 375,629 bytes；
- 包含 `Package.swift`、`Package.resolved`、`README.md`、Microsoft `LICENSE`；
- 包含完整 `Sources/MarkdownText`；
- 包含完整 `Tests/MarkdownTextTests`，包括 Intatis candidate matrix、first-release contracts、AppKit/UIKit layout 与 equality/selection 回归测试；
- 包含永久 `INTATIS_PATCH_LEDGER.md`。

### 2.4 明确排除内容

导入没有把整个上游 checkout 不加区分地塞入主仓。以下内容明确排除：

- 上游 `.git`，避免 nested Git repo；
- `.build`、`.swiftpm` 与候选的约 434 MB 构建缓存；
- `SendingProbe.swift`、`StructAliasProbe.swift`、`IntegrationProbe.swift`、`IntegrationNegativeProbe.swift`；
- `ProbeExecutable/**`、空 probe 目录，以及 `SendingIntegrationProbe` executable product/target；
- 非生产 `Examples` tree，包括 Microsoft bundle identity、Roboto 字体、示例品牌配置和未进入产品的 sample media；
- 上游 agent/automation/CI metadata；
- 与已经删除的 HighlightSwift、iosMath、Shimmer、snapshot/macro surface 对应的资源和测试快照。

因此“放进我们的项目”在工程上表示：**由 Intatis 根仓库维护、版本化和分发经过审计的派生快照**；不表示删除上游归属，也不表示保留与产品无关的品牌/示例资产。

## 3. Vendored 包的实现边界

`swift package dump-package` 确认 manifest 只包含：

| 类型 | 名称 | 路径/依赖 |
|---|---|---|
| library product | `SwiftStreamingMarkdown` | target `SwiftStreamingMarkdown` |
| regular target | `SwiftStreamingMarkdown` | `Sources/MarkdownText`；依赖 `Markdown` |
| test target | `SwiftStreamingMarkdownTests` | `Tests/MarkdownTextTests` |

不存在 executable product/target，也不存在 probe source。

直接与传递依赖：

| 依赖 | 版本/修订 | 许可证边界 |
|---|---|---|
| `swift-markdown` | exact `0.8.0` / `3c6f9523da3a1ec2fd829673e472d95b8097a3b8` | Apache-2.0 + Swift Runtime Library Exception |
| `swift-cmark` | exact `0.8.0` / `924936d0427cb25a61169739a7660230bffa6ea6` | 上游 `COPYING` 记录的 BSD/MIT 派生条款 |

派生包保留：

- Microsoft 的 Markdown 模型与 parser integration；
- heading、paragraph、emphasis、link、list、task list、blockquote、table、thematic break；
- SwiftUI `DocumentView` 与 AppKit/UIKit TextKit paragraph presentation；
- selectable plain code block 与原生 copy control。

派生包删除或强制关闭：

- HighlightSwift、高亮主题与 syntax highlighting；
- iosMath、LaTeX preprocessor、math view 与字体；
- Shimmer、Equatable macro、SnapshotTesting；
- Microsoft/Copilot palette、图标、media assets；
- citation 交互、table copy/download actions、image loading、text animation；
- package-owned paragraph native-view reuse cache。

公开的异步 ownership-transfer 边界是：

```swift
@concurrent
public static func parse(
    text: String,
    config: sending MarkdownRenderConfig
) async -> sending RenderableDocument
```

非 `Sendable` 的 `RenderableDocument` 通过 `sending` 一次性交给 `@MainActor` UI owner。派生包没有为此加入 `@unchecked Sendable`、`nonisolated(unsafe)` 或 `@preconcurrency` escape hatch。

这份派生包相对上游仍是非平凡 diff：生产 renderer/package source 的主要修改面是 39 个文件，约 269 insertions / 1,142 deletions；大量删除来自可选依赖、资源和 snapshot 清理。它是“尽量不接管 grammar/layout 的薄派生”，不是“无需维护的零 diff”。具体 patch groups 与删除条件以 vendored ledger 为准。

## 4. Intatis 集成架构

### 4.1 Renderer mode 与救援熔断

稳定模式：

```text
IntatisMessageRendererMode.microsoft
IntatisMessageRendererMode.plainSafe
```

稳定入口：

```text
UserDefaults: intatis.messageRendering.mode.v1
macOS force plain:     -IntatisPlainSafeMessages
macOS force Microsoft: -IntatisMicrosoftMarkdownMessages
legacy rich override:  -IntatisRichTextMessages
```

缺少偏好时默认 Microsoft；旧持久值 `rich` 映射到 Microsoft；未知值 fail closed 到 plain-safe；冲突启动参数由 plain-safe 胜出。macOS/iOS 设置使用同一持久键，iOS 另保留 `Settings.bundle` 预启动入口。

角色策略仍高于 renderer mode：user、system 或特殊卡片的 `.plainText` 不会因为全局 Microsoft 模式而进入 rich parser。

### 4.2 Raw-first facade

`IntatisMessageContentView` 的公开输入保持：

```text
messageID / rawText / isComplete / policy / style
```

只有 document 的 message ID、raw source、completion、appearance/config revision 与当前 view revision 全部一致时，rich projection 才能替换 raw Text。parse pending、超限、取消、模式切换或 stale result 均显示 raw projection；旧 document 不得覆盖新 source。

### 4.3 Raw 与 rich 背压

plain-safe/raw fallback 采用 facade-lifetime latest-only state：

- append-only snapshot 使用 100 ms fixed-window leading/trailing throttle；
- timer deadline 不被每个 token 重置，只保留 latest revision；
- init/activation/reentry/correction/truncation/final 同步发布当前精确 source；
- generation guard 阻止旧 timer 覆盖 final/newer state；
- rich document 已经是 `nil` 时不逐 token 重复发布 `nil`。

rich 固定预算：

| 项目 | 值 |
|---|---:|
| whole-message admission | UTF-8 ≤ 64 KiB |
| process-wide concurrent parse permits | 1 |
| process-wide pending message keys | 32 |
| per-view request buffer | `.bufferingNewest(1)` |
| incomplete snapshot debounce | 50 ms |
| completed-document cache | 0 |
| paragraph native-view reuse cache | 0 |

`IntatisLatestOnlyPermitScheduler` 只保存 Sendable key/generation/continuation/permit lifecycle/metrics，不保存 parser、document、result 或 arbitrary closure。

### 4.4 首版安全配置

- images：disabled，remote/file/data 都不加载；
- citations：disabled；
- animation：disabled；
- syntax highlight：disabled；
- math/LaTeX：disabled；
- table copy/download actions：disabled；
- text selection：enabled；
- code：完整 plain code、横向滚动、原生 copy；
- links：只保留 `http`、`https`、`mailto`，其他 scheme 丢弃。

## 5. 旧栈退出审计

已退出当前生产工作树的旧源码：

- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisRenderDocument.swift`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMathView.swift`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisCodeBlockView.swift`

已退出的旧 vendored 资源：

- `MessageRendering/Resources/highlight.min.js`
- `MessageRendering/Resources/a11y-light.css`
- `MessageRendering/Resources/a11y-dark.css`

根 direct dependency 图不再包含 MarkdownUI、NetworkImage、旧 `swift-cmark 0.5.0` pin、iosMath、HighlightSwift/highlight.js、Shimmer、SnapshotTesting 或 Equatable macro。

旧实现只应保留在 Git history、旧 release 与历史报告中。运行时 rollback 使用 `plainSafe` 与版本回退，不把旧 renderer 永久重新编进 binary。

## 6. 测试与构建证据

### 6.1 Focused renderer suites

| Suite | 结果 | 合同重点 |
|---|---:|---|
| `MessageRendererModeTests` | 11/11 | 默认值、override、legacy migration、fail-closed、routing |
| `MarkdownSchedulerTests` | 6/6 | global bound、per-key latest-only、fairness、cancel/finish |
| `MessageRenderingTests` | 21/21（事故后重跑） | admission、scheme、fixture、raw lifecycle、final/stale、pipeline/facade、rich selection ownership |
| 合计 | **38/38** | **0 failures；前两组是未受本修复影响的既有通过证据，第三组在事故后重跑** |

### 6.2 全量 SwiftPM

事故前最新完整基线：

```text
Executed: 755 tests
Skipped:   14 tests
Failures:   0
Unexpected: 0
Exit:       0
```

该结果替代旧报告中的 752/14/0 统计。事故后另一次全量尝试在既有 `IntatisToolsTests` 的 nested `sandbox-exec` / loopback 失败后进入无输出挂起并被人工中止，因此没有新的当前全量总数；不得把 755/14/0 冒充事故后完整 pass。事故后的 renderer 直接覆盖由 21/21 SharedUI focused、两组 44/44 vendor strict 与 current product build/archive 提供。

### 6.3 Vendored 包 strict macOS Debug / Release

vendored package 使用独立 `/private/tmp` scratch/module/config/security path 验证；没有在 `Vendor/SwiftStreamingMarkdown` 内生成 `.build`、`.swiftpm` 或 `.git`。

初始 post-hygiene matrix 启用了 dependency-import 与 automatic-resolution gate；事故后当前源码复跑保留三项 Swift compiler strict gate：

```text
-Xswiftc -warnings-as-errors
-Xswiftc -strict-concurrency=complete
-Xswiftc -warn-concurrency
```

初始 matrix 另有 `--explicit-target-dependency-import-check error` 与 `--disable-automatic-resolution`；事故后复跑从既有 exact-resolved scratch graph 取依赖，没有重新声称一次 fresh network resolution。

结果：

| Configuration | XCTest | Swift Testing | 合计 | Failures |
|---|---:|---:|---:|---:|
| macOS Debug | 38 | 6 | **44/44** | 0 |
| macOS Release | 38 | 6 | **44/44** | 0 |

事故后当前源码使用 `-strict-concurrency=complete`、`-warn-concurrency` 与 `-warnings-as-errors` 重新执行两种 configuration，均为 44 项、0 failures。旧的 build/test duration 只属于事故前快照，不再作为当前性能数据复用。

测试过程出现 headless AppKit `com.apple.hiservices-xpcservice Connection Invalid` 环境日志，但相应 lifecycle/measurement tests 通过；这不是 compiler warning 或 test failure。`--skip-update` 仅产生 SwiftPM deprecation 提示，依赖实际从既有 cache 取得并按 `Package.resolved` 固定。

### 6.4 Intatis Xcode build 状态

以下是**仓内 vendoring 后**当前已确认结果：

| 项目 | 状态 |
|---|---|
| IntatisMac macOS Debug build | **PASS** |
| IntatisMac macOS Release build | **PASS** |
| IntatisiOS iOS Simulator Debug build | **PASS** |
| IntatisiOS iOS Simulator Release build | **PASS** |
| IntatisMac macOS Release unsigned Archive | **PASS** |
| IntatisiOS generic iOS Device Release unsigned Archive | **PASS** |
| SwiftStreamingMarkdown iOS Simulator test target `build-for-testing` | **PASS（compile-only，未启动 Simulator/test host）** |

上述产物都在事故后修复的当前 `Vendor/SwiftStreamingMarkdown` 源码上重建。构建只有仓库既有的弃用/未使用结果警告，没有新的 renderer 编译错误；构建通过不能覆盖第 8 节的 GUI 资源事故。

## 7. 固定 fixture 与性能协议

固定 fixture：

```text
Packages/IntatisSharedUI/Tests/Fixtures/incident-1249-sanitized-v1.json
17 messages
1,249 cumulative deltas
SHA-256 fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1
```

正式 host 通过 local package dependency 引入当前 `IntatisSharedUI`，在真实 SwiftUI `NSWindow` 中实例化生产 `IntatisMessageContentView`，用 Release 构建按全局原顺序 1 ms 投递 1,249 deltas，每轮完成后观察 60 秒。协议为每种模式 5 次 cold + 20 次 replay，并保存 machine-readable event/process evidence。

冻结 interaction 门：

```text
interaction p95 <= 8 ms
interaction max <= 50 ms
```

### 7.1 Plain-safe 正式结果

Plain formal 5 cold + 20 replay 全部 exit 0、1,249 次 facade ingress、17/17 final raw inputs byte/SHA exact、interaction failures 0。

| Plain | cold 5 | replay 20 |
|---|---:|---:|
| interaction p95 across runs worst | 6.1523 ms | 4.3705 ms |
| interaction single max | 30.3952 ms | 29.5912 ms |
| main-delay p95 across runs worst | 2.0781 ms | 2.0793 ms |
| CPU settle max；missing | 0.2816 s；0 | 0.3824 s；0 |
| peak / residual RSS delta max | 7.0469 / 6.8750 MiB | 6.9844 / 3.6094 MiB |
| peak / residual footprint delta max | 5.5000 / 5.2813 MiB | 5.4219 / 5.1407 MiB |

证据：`/private/tmp/intatis-facade-perf-results-lifecycle-final-foreground-plain-v2`；`summary.json` SHA-256 `086897059393b43c43632fb5f4b6b3c145370db8f2a8129d54e4e5e91ab9a1ee`。

### 7.2 Eager `VStack` 反例：保留为 NO-GO

第一轮 foreground Microsoft formal host 使用 eager `VStack` 一次性物化全部行。它不是 Chat/Code/Cowork 当前生产列表的 container shape，因此不能作为产品 GO 数据；但它是重要反例，不能删除或混入 Lazy 数据：

- 5/5 cold 与 20/20 replay 均超过 p95 ≤ 8 ms 门；
- cold worst p95 9.6705 ms，single max 39.2674 ms；
- replay worst p95 10.1406 ms，single max 33.3622 ms；
- 25/25 final raw inputs 仍 exact，所有 process exit 0；
- 失败来自 eager foreground materialization/update shape，而不是 raw identity 错误或 >50 ms 单次门。

证据：`/private/tmp/intatis-facade-perf-results-lifecycle-final-foreground-microsoft-v1`；`summary.json` SHA-256 `0f7e1c8413f51af2df1a72795be306f2803da4c8936e96c403f96534779ea8c8`。

结论：**eager `VStack` = NO-GO**。未来不得用它替换生产列表，也不得把其数据伪装成当前 production-shaped 结果。

### 7.3 Production-shaped `LazyVStack` Microsoft 正式结果

scratch host 唯一相关 A/B 是把 eager `VStack` 换成与 Chat、Code、Cowork 和 renderer fixture 相同的 lazy list shape；production renderer/facade source 未为测试专门降级。`container-shape.txt` 明确记录：

```text
production-shaped LazyVStack; eager VStack evidence retained separately as NO-GO
```

完整 5 cold + 20 replay：全部 exit 0、1,249 ingress、17/17 final raw inputs byte/SHA exact、interaction failures 0。

| Microsoft production-shaped LazyVStack | cold 5 | replay 20 |
|---|---:|---:|
| interaction p95 across runs worst | 4.0205 ms | 4.8763 ms |
| interaction single max | 37.8409 ms | 36.5965 ms |
| main-delay p95 across runs worst | 2.0615 ms | 2.0638 ms |
| CPU settle max；missing | 0.3072 s；0 | 0.3007 s；0 |
| peak / residual RSS delta max | 22.7500 / 22.7344 MiB | 22.8125 / 22.4375 MiB |
| absolute peak / residual RSS max | 99.1250 / 99.1250 MiB | 102.9531 / 101.3750 MiB |
| peak / residual footprint delta max | 11.5782 / 11.3907 MiB | 11.4063 / 9.2813 MiB |
| absolute peak / residual footprint max | 29.8758 / 29.7508 MiB | 33.1728 / 32.4540 MiB |

证据：`/private/tmp/intatis-facade-perf-results-lifecycle-final-foreground-lazy-microsoft-v1`；`summary.json` SHA-256 `9aac0e154b415a9d0497e5d2c5cfc397aff3433b38959a35f21dae8d6d6458f8`。

这组 Lazy 数据是当前产品形态的正式本机 interaction 证据。RSS/footprint 仍属于 observational：尚未为低端目标设备书面冻结统一内存门，不能把 interaction pass 夸大为全资源预算 pass。

### 7.4 Post-fix xctrace

独立 Microsoft foreground xctrace 结果：

- target exit 0；
- 1,249 ingress、17/17 final raw inputs exact；
- interaction p95 9.0966 ms、max 35.4072 ms；该录制使用 eager foreground container，只用于 hang/lifecycle 调查，不取代 7.3 的产品 interaction 数据；
- `potential-hangs`（>250 ms）为 0 data rows；
- `Invalid Configuration` pattern：0；
- `multiple times per frame` pattern：0；
- `AttributeGraph` pattern：0；
- `cycle` pattern：0。

此前旧 trace 中 17 条 `.task(id: ViewRevision)` / multiple-updates-per-frame 告警已经由 lifecycle gate 修正；post-fix `target.stdout` 不再出现这些 pattern。trace 仍采样到真实 `DocumentView`、font 与 TextKit/layout 工作，因此不是悄悄回退 plain path 后得到的“零告警”。

证据：`/private/tmp/intatis-facade-perf-results-lifecycle-final-foreground-xctrace-microsoft-v1`；`metrics.jsonl` SHA-256 `382cfefa457f164756f21609c40925a1402871eb6a67c4cd436ae47583df3b6b`；`target.stdout` SHA-256 `2295ada9e44046aaf94f63b185d3c61c821a39212db39c439e7530f397b82a49`。

xctrace 未发现 >250 ms hang 不是不存在任何 UI 风险的形式化证明；它只关闭本次固定 workload 下的已知高频 lifecycle warning 与 observable hang pattern。

## 8. Computer Use 验收

**状态：FAIL / ABORTED；RELEASE NO-GO。**

latest-build 验收期间错误地同时保留了三个 `Intatis Renderer Validation` 实例。用户提供的 Force Quit 截图中，主实例显示 **129.63 GB application memory**，其余两个实例约为 49.4 MB 与 32.6 MB。这是 macOS Force Quit 的应用内存读数，不能换算或宣称为精确 RSS、footprint 或 byte count；三实例并存本身也是验收操作错误。

系统 CPU diagnostic：

```text
Path: /Library/Logs/DiagnosticReports/IntatisRendererValidation_2026-07-18-182732_MacBook-Pro.cpu_resource.diag
Incident: FA228932-2C40-4AC2-A0C2-62EF41342B4A
Window: 160 s
CPU used: 90 s (about 56%)
Sampled footprint: 109.16 MB -> 803.30 MB
```

主栈涉及 SwiftUICore、AttributeGraph、lazy layout、`ParagraphView` copy/destruction 与 `SelectionOverlay`。证据可以确认 validation process 在 renderer/UI lifecycle 中发生失控增长，但缺少 malloc allocation stack 或 heap graph，最终 retaining edge 仍为 **UNKNOWN**。因此不得把事故写成已经证明由 Markdown parser、Microsoft 上游、Computer Use、AX tree 或某个 Apple framework leak 单独造成。18:11 的两份 LaunchServices SIGABRT `.ips` 是另一事件，也不纳入本事故因果链。

事故后已做的最小修复：

- 手写恢复 `DocumentView` 和 AppKit/UIKit `ParagraphView` 的 upstream-equivalent `Equatable` 语义，不恢复 macro 依赖；
- AppKit/UIKit paragraph 使用独立的有效宽度 tracker，稳定正宽/零宽不反复 invalidation，`valid -> zero -> same valid` 会重新测量一次；
- rich facade 去掉整棵 `DocumentView` 的第二层 `.textSelection(.enabled)`，plain fallback、native paragraph、table text leaf 与 code leaf 各自保留 selection ownership；
- 加入对应的 equality、stable-width、selection source-contract 回归测试。

这些修复与严格测试证明上述局部合同，但尚未证明真实 window 下总 view graph 已有界。为避免再次耗尽系统资源，本轮主动停止所有 GUI/Computer Use/Simulator app 启动，只进行源码、测试、build 与 bundle audit。iOS latest app-content、macOS selection/copy/keyboard/accessibility 仍缺运行态证据。再次验收必须先获得用户明确同意，并使用单实例、子进程 hard watchdog、低内存/CPU kill threshold、逐阶段采样和每轮强制清理；在此之前不能把早期 Computer Use 结果冒充当前修复的通过证据。

### 8.1 事故后 containment 前置

无界面防护设施现已完成，但没有据此启动应用：

- `RendererFixtureView` 改为一次只 materialize 一个 minimal/table/code/stream/incident/full-static stage；1,249-delta incident replay 需固定 fixture SHA、17 messages / 1,249 deltas 与唯一 message IDs 全部匹配，并且只在用户点击后开始；
- Release validation build 仅在 `INTATIS_RENDERER_VALIDATION` compilation condition 下编入该 fixture，正常 Release 不因启动参数意外进入验证 UI；
- `scripts/RendererValidationWatchdog.swift` 只允许固定 Intatis bundle ID、固定 fixture SHA、二进制 fixture marker 和调用方显式提供的 executable SHA 全部匹配的 build；没有 `--user-approved-gui` 时在 spawn 前 fail closed；
- watchdog 使用单独 process group、100 ms RSS/phys-footprint/CPU 采样、rolling/absolute CPU、wall time、实例数硬阈值，以及 TERM→KILL 和两次空进程组确认；evidence 目录与文件为 owner-only；
- 8 个无 GUI self-test 全部通过：clean exit、wall fuse、RSS fuse、rolling CPU fuse、process-group kill、unexpected exit、telemetry fail-closed 与 lock contention，每例 `cleanupVerifiedTwice=true`；watchdog 以 `-warnings-as-errors` 编译成功；
- 当前 Release validation app 构建成功，executable SHA-256 为 `1fe134ee434c06aa9c570eddaa929377f6d8f7d9e90fb33fbdb141cbc2e4533f`；fixture SHA-256 为 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`。缺少授权的完整 run command 返回 64，未进入 app launch。

以上是 containment 与制品身份的通过证据，不是 renderer runtime、视觉或性能通过；release 状态保持 `NO-GO`。

## 9. Bundle 与许可证验收

源码层已完成：

- vendored Microsoft MIT `LICENSE` 存在；
- 根 `NOTICE.md` 已把派生位置写成 `Vendor/SwiftStreamingMarkdown`，不再写 `UNPUBLISHED` candidate；
- `ThirdPartyNotices` 已记录 SwiftStreamingMarkdown、swift-markdown 与 swift-cmark；
- source tree 不包含导入时明确排除的 Examples/brand/font/media/probe/build-cache surface。

**当前 vendoring 后 app/Archive bundle scan：PASS。**

事故后当前源码重建的六份 app（macOS Debug/Release、iOS Simulator Debug/Release、macOS unsigned Archive、generic iOS unsigned Archive）均完成同一静态 audit：

- 根 `NOTICE.md` 与三份 `ThirdPartyNotices` 在六份 app 中均存在且 SHA-256 与仓库一致；source hash 分别为 `2bbe5c4aa7d91f655fc1db45a1b3d2c74016256f33526430e7cc89174b80bb2a`、`50ae1858f8b5c8af5526c91d744fe9b68942cf6a0284e502f22252ba5f22071d`、`95685740cb553ff3df7791ec96235ad5969f9abf2654130639a57e19bf4124bc`、`846183f2e712ef1c2f0df113a0693b7b407ba08f720afeedb0f17eba4567fca7`；
- 每份 SwiftStreamingMarkdown resource bundle 恰有 38 个文件：1 个 `Info.plist` 与 37 个 `Localizable.strings`；
- 旧 `highlight.min.js`、a11y CSS、TTF/OTF/Roboto、Copilot 文件名扫描为 0；app executable 的 MarkdownUI、NetworkImage、iosMath、HighlightSwift、旧 JS/CSS、Roboto/Copilot、Shimmer、SnapshotTesting 禁止字符串扫描为 0；
- iOS Debug、Release 与 Archive 的 `Settings.bundle/Root.plist` 均使用 key `intatis.messageRendering.mode.v1`，values `plainSafe` / `microsoft`，default `microsoft`。

该静态 audit 只证明制品/声明边界，不证明第 8 节的运行态资源问题已经关闭。

## 10. Phase 0–6 状态

| Phase | 当前状态 | 说明 |
|---|---|---|
| Phase 0 消息永远可用 | 源码合同完成；latest CU failed/aborted | plain-safe、raw-first、无 schema migration 已实现；current-build 可见/selection/copy 尚未通过运行态复验 |
| Phase 1 隔离 harness | **NO-GO** | 早期 Lazy protocol 过 interaction 门，但后续 on-window validation 出现失控增长；旧窄协议不能覆盖 adverse evidence |
| Phase 2 关闭生产阻断 | 实现完成 | parser 0.8、关闭可选功能/资源、ownership boundary、zero cache 已实现 |
| Phase 3 原子生产切换 | 本地源码与 vendoring 完成 | facade、根相对依赖、vendor source/tests/license/ledger 已形成同一工作树；最终根 commit/tag 尚未形成 |
| Phase 4 生产集成验证 | **NO-GO** | strict/focused/build/archive/bundle scan 已完成；current GUI/CU 为 FAIL/ABORTED，资源有界与 selection/copy/accessibility 未证明 |
| Phase 5 旧栈退出 | 源码/依赖图/制品扫描完成 | 旧源码、旧资源、旧 direct dependencies 已退出；六份当前 app 静态扫描通过 |
| Phase 6 发布与回到上游 | 未完成 | 不再需要单独远端 fork；仍需根 revision、最终发行矩阵及可上游化 patch 的 issue/PR |

## 11. FILES_WRITTEN

Markdown 迁移当前主要涉及：

- `Vendor/SwiftStreamingMarkdown/**`（108 files，含 source/tests/LICENSE/README/ledger）；
- `Package.swift`；
- `Package.resolved`；
- `project.yml`；
- `NOTICE.md`；
- `ThirdPartyNotices/MarkdownRendering.md`；
- `ThirdPartyNotices/MathRendering.md`；
- `ThirdPartyNotices/SyntaxHighlighting.md`；
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift`；
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageRendererMode.swift`；
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisLatestOnlyPermitScheduler.swift`；
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMicrosoftMarkdownPipeline.swift`；
- renderer tests、fixture、settings 与 notice surface；
- `scripts/RendererValidationWatchdog.swift`；
- `docs/CURRENT_STATE.md`、`PROJECT_MAP.md`、`ARCHITECTURE.md`、`DO_NOT_BREAK.md`、`TESTING.md`、`NEXT_TARGET.md`；
- 本报告。

没有执行 git add、commit、branch、push 或 PR。

## 12. PROJECT_AUDIT_SUMMARY

- 消息真值和 provider/agent 链路没有改变；renderer 仍是 EventLog projection 后的 UI 末端。
- macOS Chat、Code、Cowork 和 iOS Chat 共用一个 facade；CLI/headless 不链接 Apple renderer。
- iOS 仍是 chat 子集；vendored renderer 没有引入 shell、Git 或 local-agent workspace 能力。
- SwiftStreamingMarkdown 不能访问 PermissionEngine、CapabilityLease、WorkspaceLease、PathConfinement、SecretScanner、Mediator、durable tool execution 或 EventLog 写入。
- 本轮没有更改 EventLog schema、Envelope、`seq`、ArtifactStore 或 provider request wire。
- Microsoft 原始代码继续按 MIT 与 NOTICE 归属；Intatis 维护的是派生快照，不宣称独立原创。

## 13. VALIDATION_RESULT

### 13.1 已通过

- 路径/Git root：均为 `/Users/vita/Vitemis/Intatis`。
- vendor inventory：108 files，约 628 KiB；无 nested `.git`、`.build`、`.swiftpm`、Examples 或 probe executable。
- manifest：1 library product、1 regular target、1 test target、0 executable target。
- 事故后 SharedUI focused：`MessageRenderingTests` 21/21，0 failures。
- 事故前完整 SwiftPM 基线：755 tests，14 skipped，0 failures，0 unexpected，exit 0；事故后全量尝试进入既有 Tools nested-Seatbelt/loopback failures 后无输出挂起并人工中止，不能冒充当前 full pass。
- vendor macOS strict Debug：44/44，0 failures，exit 0。
- vendor macOS strict Release：44/44，0 failures，exit 0。
- IntatisMac macOS Debug build：PASS。
- IntatisMac macOS Release build：PASS。
- IntatisiOS Simulator Debug build：PASS。
- IntatisiOS Simulator Release build：PASS。
- IntatisMac macOS Release unsigned Archive：PASS。
- IntatisiOS generic Device Release unsigned Archive：PASS。
- vendor iOS Simulator test target `build-for-testing`：PASS；compile-only，未启动 Simulator/test host。
- 六份 current app bundle/notice/settings audit：PASS。
- renderer watchdog 无 GUI self-test：8/8 PASS，所有 case 均二次确认 cleanup；`-warnings-as-errors` 编译 PASS。
- `INTATIS_RENDERER_VALIDATION` Release validation app：PASS；fixture marker 与 executable/fixture SHA 静态核对 PASS；未启动 app。
- Plain formal：5 cold + 20 replay，25/25 exact，interaction failures 0。
- production-shaped Lazy Microsoft formal：5 cold + 20 replay，25/25 exact，interaction failures 0。
- post-fix xctrace：17/17 exact，>250 ms potential-hang rows 0，旧 SwiftUI warning pattern 0。

上述 performance/xctrace 是事故前的窄协议历史证据；它们不能覆盖随后发生的 GUI 内存增长。

### 13.2 FAIL / OPEN

- latest vendored-build Computer Use：**FAIL / ABORTED**；
- on-window memory/CPU boundedness：**未证明，release blocker**；
- latest iOS app-content smoke；
- macOS selection/copy/keyboard/VoiceOver 与 clipboard byte evidence；
- 事故后完整根 SwiftPM run：尝试执行，但既有 Tools tests 因 outer sandbox 的 nested `sandbox-exec` / loopback 限制失败并进入无输出 hang，人工中止；
- 用户已明确暂缓的真实 iPhone/iPad 设备矩阵。

### 13.3 最终仓库检查

- 本报告更新后执行 `git diff --check -- codex-report/07_18_26-11_46-swift-streaming-markdown-cutover-implementation-validation.md`。
- 没有清理或回退工作树中的其他用户改动。
- 未执行 git add、commit、branch、push 或 PR。

## 14. UNCERTAINTIES / RELEASE BLOCKERS

### 14.1 已解除：独立远端 fork

旧 blocker：根 manifest 指向 `/private/tmp/SwiftStreamingMarkdown`，必须先发布单独 remote fork。

当前：完整派生包已在 `Vendor/SwiftStreamingMarkdown`，根 manifest 使用相对路径。Microsoft license、patch ledger 和测试都随根仓版本化；**不再需要创建单独远端 fork**。

仍需做的是把当前工作树形成一个经过审计的 Intatis 根 commit/tag；这是 release identity 工作，不是新建 fork 的前置条件。

### 14.2 仍存在的远端依赖

`swift-markdown`/`swift-cmark` 仍是 exact remote pin。无缓存构建需要网络；如果未来要求完全离线供应链，需要另做两者的 vendoring、许可证与升级治理，不能从当前请求自动扩大范围。

### 14.3 尚未关闭的本机 release gates

- current vendor build 的 Computer Use 已失败/中止，必须在有资源 watchdog 的单实例环境中重新验收；
- 129.63 GB Force Quit application-memory 读数及 CPU diagnostic footprint 增长尚未由受控 GUI rerun 关闭，根因仍为 `UNKNOWN`；
- selection、clipboard bytes、keyboard/VoiceOver、remote-image zero-request 与实际 link action 缺最新运行态证据；
- 本机 Microsoft Lazy RSS/footprint 已记录，但低端设备的正式资源预算与接受阈值尚未冻结。

### 14.4 真实 iOS 设备

按用户指示暂缓，以下保持 `UNKNOWN`：

- 低端支持档位 5 cold + 20 replay + 60 s 稳态；
- VoiceOver 顺序、label、焦点和 code-copy 可达性；
- Dynamic Type；
- 旋转/窗口尺寸变化；
- 内存压力与重复进入；
- attachment/image-disabled 组合；
- 真机 raw selection/copy bytes。

## 15. NEXT_RECOMMENDED_ACTION

接下来不需要再写 Markdown renderer，也不需要创建单独远端 fork。当前 build/archive/bundle gate 已关闭，唯一安全的下一步是：

1. 在用户明确同意重新启动 GUI 后，只启动一个最新 `Intatis Renderer Validation` 子进程；父 watchdog 必须同时限制 wall time、RSS/footprint、CPU 与实例数，越界立即终止并保存采样，不允许出现第二个残留实例；
2. 先做 10–20 秒 minimal paragraph/table/code fixture，再逐阶段增加 selection、滚动、stream replacement；每阶段确认进程退出和残留实例为零，不能直接重放长 session；
3. 只有资源曲线稳定后，才用 Computer Use 补 latest-build Rich/Plain、历史 Chat/Code/Cowork、code copy、selection/keyboard/accessibility 与 iOS app-content；任何阶段增长失控都保持 `NO-GO`；
4. 如果受控 rerun 仍增长，采集 malloc stack logging/heap graph 与 signpost 后再定位最终 retaining edge；在证据出现前不要继续猜 parser 或 framework leak；
5. GUI gate 通过后，再将当前工作树形成可追溯的 Intatis 根 revision，并复核相对 vendor 解析；真实 iOS 设备仍按用户方向另行恢复；
6. 对可通用的 equality/layout/feature-profile patch 向 Microsoft 上游建 issue/PR；官方 release 覆盖 ledger 删除条件后再切回 immutable tag。

这些 `FAIL / OPEN` gate 关闭前，当前工作树可以继续开发和无界面验证，但不能标记为最终可分发 release。发生 rich renderer 事故时直接切 `plainSafe`；不要恢复旧 MarkdownUI/iosMath/highlight.js 栈，也不要在 Intatis 内补写另一套 Markdown parser/layout。
