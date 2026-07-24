# Intatis 单美元符号 LaTeX 数学渲染实施计划

> 日期：2026-07-23
>
> 状态：原始实施前计划已执行；2026-07-24 的实施结果与剩余发布门槛见文末第 14 节
>
> 第一阶段范围：macOS Chat / Code / Cowork 与 iOS Chat 的 assistant / agent 富文本消息，新增行内 `$...$` 数学模式
>
> 当前 Markdown basis：Microsoft SwiftStreamingMarkdown `v0.6.0` / `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd` 的仓内派生版
>
> 原计划数学引擎候选、最终已批准并采用：`kostub/iosMath` `2.5.0` / `838cddc01fdd67efd530f8bb67959ad2715f9b06`

## MODEL_CHECK_RESULT

当前执行环境为 Codex / GPT-5 系列 Agent；本地环境无法独立核实更精确的服务端 deployment 标识。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者一致，符合项目要求。
- 计划创建前工作树已有大量 UI、本地化、会话排序、停止动作、thinking 时间、projection、Goal / Cowork 和文档改动。本计划不覆盖、回退、整理、暂存或提交这些既有改动。

## FILES_WRITTEN

以下是 2026-07-23 “只写计划”那一轮的历史记录，不是后续实施的文件清单：

- 当时新增：`codex-report/07_23_26-21_28-single-dollar-latex-rendering-implementation-plan.md`
- 当时未修改 `Apps/`、`Packages/`、`Vendor/`、`Package.swift`、`Package.resolved`、`project.yml`、`NOTICE.md`、`ThirdPartyNotices/`、测试或 `docs/`。后续实施实际改动见第 14 节和最终交付报告。

## 0. 结论先行

第一阶段采用“三层分工”，不恢复旧 MarkdownUI 双栈，也不把公式交给 WebView：

| 内容 | 所有者 | 第一阶段行为 |
| --- | --- | --- |
| 普通 Markdown | 当前仓内 Microsoft SwiftStreamingMarkdown 派生版 + `swift-markdown 0.8.0` / `swift-cmark 0.8.0` | 保持当前标题、段落、列表、表格、引用、链接等路径 |
| 代码块 / 行内代码 | 当前 Microsoft AST + 原生 CodeBlockView / TextKit inline-code 路径 | byte-exact 显示和复制；永远不进入数学识别 |
| 行内数学 | vendored renderer 内新增 code-aware math preprocessor / attachment；TeX parser 与排版交给经批准的成熟数学引擎 | 第一阶段只解释单美元符号 `$...$` |
| 原始消息 | EventLog / projection raw `String` | 继续是唯一真值；任何失败均可回退原文 |

目标调用关系：

```text
EventLog / projection raw String
  -> IntatisMessageContentView
     -> plainSafe
        -> exact raw SwiftUI Text
     -> microsoft
        -> Intatis latest-only admission / scheduler
        -> vendored Microsoft parser
           -> ordinary Markdown nodes
           -> code nodes（不识别数学）
           -> accepted $...$ math nodes
              -> native TextKit attachment
              -> audited TeX math engine
        -> DocumentView
```

这项工作不建立第四套 renderer，不修改 provider 输入，不修改 EventLog schema，不持久化 AST / attachment / bitmap，也不改变用户选择的普通界面字体。数学引擎使用的 OpenType math font 只服务于公式排版。

## 1. 当前问题与真实基线

### 1.1 为什么实施前公式显示为原文

在本计划形成时，富文本路径本身正常工作：

- assistant / agent 消息进入 `IntatisMessageContentView(.richText)`；
- `MarkdownDocumentParser` 能解析并显示标题、列表、表格、引用和普通代码块；
- 当时 production configuration 明确关闭数学；
- 当时根依赖图没有 iosMath，app bundle 也不应含数学字体。

因此，当时 session 中 `$...$`、`\[...\]` 等显示为普通字符，不是 EventLog 丢失，也不是整条 Markdown 失效，而是实施前 renderer 按设计没有数学节点。

### 1.2 不能恢复的旧方案

不得恢复 2026-07-15 的旧 MarkdownUI / highlight.js / iosMath 整栈。当前唯一 rich Markdown 路径继续是 Microsoft 派生版。

同样不得原样恢复 Microsoft `v0.6.0` 的 `LaTexPreProcessor`：

- 上游实现会在 Markdown parse 前对完整字符串做正则替换；
- 它没有先保护 fenced code 与 inline code；
- 因而代码字面量中的 TeX delimiter 可能被改写；
- 它也不支持本阶段要求的正常单 `$...$`。

本计划只在 vendored Microsoft renderer 内恢复经重新设计的数学扩展点，并把修改永久记录到 `INTATIS_PATCH_LEDGER.md`。

### 1.3 当前性能事实不能被数学功能覆盖

当前 renderer 保留以下已实现保护：

- 单条 rich message UTF-8 不超过 64 KiB；
- 全进程最多 1 个 Markdown parse permit；
- 最多 32 个 pending message key；
- 每个 message view 最多 1 个 running 与 1 个可替换 pending acquire；
- incomplete message 50 ms debounce；
- raw fallback 使用 100 ms fixed-window latest-only projection；
- completed-document cache 为零；
- paragraph native-view cache 为零；
- stale generation 不得发布。

但作为本计划的实施前历史基线，2026-07-18 的 GUI 验收是 `FAIL / ABORTED`：

- Force Quit 曾显示 129.63 GB application-memory UI 读数；
- CPU diagnostic 的 sampled footprint 为约 109.16 MB → 803.30 MB；
- 最终 retaining edge 仍为 `UNKNOWN`。

所以数学实现即使所有 headless tests 通过，也不能被描述为 release-ready；必须保留并重新执行受控单实例 GUI gate。

## 2. 第一阶段语法合同

### 2.1 支持

第一阶段只启用行内单美元符号：

```markdown
能量为 $E = mc^2$。

概率为 $P(A \mid B)=\frac{P(B\mid A)P(A)}{P(B)}$。

向量为 $\vec{x}_i$。
```

有效 opener / closer 的初始规则：

1. delimiter 必须是未转义的单个 `$`；
2. `$$` 不作为两个单美元 delimiter；
3. opener 后一个字符不得是空白、换行或另一个 `$`；
4. closer 前一个字符不得是空白、换行或另一个 `$`；
5. closer 后若紧跟十进制数字，则不作为 closer；
6. 一个 inline candidate 不跨逻辑行；
7. candidate 内容不得为空；
8. escaped `\$` 保留普通美元符号；
9. scanner 必须按原始 UTF-8 / Swift `String.Index` 安全映射，不得按错误的 UTF-16 或 grapheme offset 截断正文。

这些规则的目标是支持正常 `$x$` 数学输入，同时降低货币文本的误判风险。

### 2.2 必须保持字面文本

以下内容第一阶段不得渲染为数学：

```markdown
$29.99
$5 and $10
\$29.99
`$x_i$`

```swift
let template = "$x_i$"
```

未闭合：$x_i
空内容：$$
带空格：$ x_i $
```

还必须保护：

- 所有 fenced code block；
- 缩进 code block；
- list / blockquote 内的 code block；
- 任意合法 backtick inline code span；
- code span 中的 escaped backtick 与多 backtick delimiter；
- link destination、autolink 与 renderer 不支持解释的 raw literal；
- 已被 swift-markdown 确认为 code 的任何节点。

### 2.3 第一阶段明确不支持

下列形式不在第一阶段内：

- display math `$$...$$`；
- inline `\(...\)`；
- display `\[...\]`；
- 跨行单 `$...$`；
- 完整 `.tex` 文档；
- `\documentclass`、`\usepackage`、外部文件、shell escape 或网络宏包；
- MathJax / KaTeX / WebView / JavaScript；
- 语法高亮恢复；
- 数学公式编辑器或所见即所得输入。

这些能力如需增加，必须在第一阶段稳定后另写增量计划，不能顺手扩大本轮范围。

## 3. Code-aware 解析设计

### 3.1 所有权边界

数学 delimiter 识别属于 Markdown grammar integration，必须实现于：

```text
Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/**
```

不得放入：

```text
IntatisMessageContentView
ChatViewModel / CodeViewModel / CoworkViewModel
ConversationProjection / CodeProjection
EventLog / provider / AgentLoop
```

Intatis SharedUI 只决定生产 configuration 是否启用 `.singleDollarInline`，不遍历 Markdown AST，不重写 code fence，也不拥有 TeX parser。

### 3.2 两阶段、按需解析

计划使用“只有出现可能的单 `$` 时才增加一次 code-aware pass”的策略：

```text
cheap byte-safe candidate check
  -> 没有可能的单 $：沿用当前一次 Markdown parse
  -> 存在可能的单 $：
       1. 用同一个 swift-markdown parser 解析 raw source
       2. 从 AST source ranges 收集 InlineCode / CodeBlock 保护区
       3. 只在保护区之外配对 $...$
       4. 若没有 accepted candidate，直接转换第一次 AST
       5. 若存在 accepted candidate，以不可伪造的 request-local token
          替换 accepted candidates，并进行第二次 Markdown parse
       6. token 在转换阶段变成数学 attachment
```

这样做的原因：

- 不自行实现 fenced-code / backtick grammar；
- code awareness 来自同一 pinned `swift-markdown` AST；
- 公式内部的 `_`、`*`、反斜线、花括号等不先被 CommonMark 拆成错误的 emphasis/link 节点；
- 没有 `$` 的普通消息保持当前单 parse 路径；
- 货币或未闭合 candidate 若最终未被接受，可以复用第一次 AST，不做第二次 parse。

### 3.3 request-local token 与注入防护

内部 placeholder 只能在一次 parse request 内存在：

- 每次 request 生成独立 nonce / token namespace；
- token 到公式的映射只由本次预处理产生；
- raw model text 中看起来像内部 token 的字符串没有 catalog entry 时只能按普通文字 / code 显示；
- catalog 只保存 bounded source、presentation 与原始 literal，不保存 view、image、font 或 parser object；
- catalog 不进入 EventLog、cache、actor mailbox 或 scheduler state；
- `RenderableDocument` 仍只由接收方 MainActor 拥有。

不得通过全局 mutable dictionary 在 parse request 之间共享公式。

### 3.4 数学 admission budget

初始预算采用比历史方案更保守的值：

| 项目 | 初始上限 | 超限行为 |
| --- | ---: | --- |
| rich message | 64 KiB UTF-8 | 沿用当前整条 raw fallback |
| 单个 `$...$` 内容 | 8 KiB UTF-8 | 本条 document 禁用数学，普通 Markdown 仍可渲染，公式保持 literal |
| 每条消息 accepted candidate | 32 | 本条 document 禁用数学，普通 Markdown 仍可渲染，所有公式保持 literal |
| 单公式 intrinsic width / height | 实施时根据基准冻结 | 超限显示原始 literal，不创建无界 attachment |
| 同时运行的 Markdown parse | 1 | 沿用当前 scheduler |

数学 admission 必须在创建 attachment / label 之前完成。不能先渲染前 32 个、再把其余公式改成另一种语义；同一消息要么通过本阶段数学 admission，要么所有 `$...$` 保持 literal。

8 KiB / 32 是第一阶段安全值，不是永久 API。任何上调必须有同 fixture 的 CPU、main-thread、memory 与 cancellation 数据。

## 4. TeX parser 与原生排版设计

### 4.1 候选引擎

第一候选为已使用过、但当前已退出依赖图的：

```text
https://github.com/kostub/iosMath.git
tag: 2.5.0
revision: 838cddc01fdd67efd530f8bb67959ad2715f9b06
engine license: MIT
```

iosMath 只负责：

- TeX math tokenization；
- command / atom tree；
- 数学字体度量；
- line / glyph layout；
- CoreText / AppKit / UIKit 绘制。

Intatis / Microsoft derivative 不实现 TeX parser、命令表、atom tree、字体度量或数学排版。

### 4.2 许可证批准门

iosMath 2.5.0 的 package resource bundle 不只有 MIT engine，还包含多套数学字体及相应许可证，历史审计包括：

- GUST Font License / LPPL 系列字体；
- SIL Open Font License 字体。

`docs/OPEN_SOURCE_REUSE.md` 要求自定义许可证在引入前获得用户明确批准。因此：

> 本计划不是对 GUST / LPPL 字体条款的自动批准。

进入 `Package.swift` / `Package.resolved` 前必须记录用户对“iosMath 2.5.0 及其实际随包字体许可证”的明确同意，并重新核对 tag、revision、package manifest、资源清单、license text 与最终 app bundle。

若用户不同意，不得偷偷换成另一个未经审计的 fork、复制系统字体、删除 package 内许可证或通过 build script 隐藏资源。届时应停止依赖变更，另写 OFL-only / 其他引擎方案。

### 4.3 Swift 6 / 线程安全预检

依赖获批后，在正式 UI 集成前必须完成一个小型 headless spike：

1. exact revision 能在当前 Swift 6.2 / Xcode 26 toolchain 下 Debug / Release 编译；
2. `MTMathListBuilder` 或等价 parser 是否能安全地以 request-local 实例离开 MainActor；
3. parser 是否依赖全局 mutable symbol / font state；
4. cancellation 后是否仍可能把旧结果交给新 generation；
5. malformed / deeply nested / large expression 的同步耗时；
6. `MTMathUILabel` 的创建、测量、更新和销毁必须留在 MainActor；
7. 不以 `@unchecked Sendable`、`nonisolated(unsafe)` 或全局锁包住未知对象来伪装并发安全。

若 TeX validation 只能同步运行于 MainActor，则在冻结可接受的单公式耗时前保持 production math disabled。timeout 不能中断同步 parser，因此不能用 timeout 文案伪称风险已解决。

### 4.4 TextKit attachment

accepted formula 转换为专用 `NSTextAttachment`：

- attachment 内容只携带 bounded formula source、原始 literal、字体尺寸和动态颜色语义；
- 使用 Intatis 专用 file type / UTI，不注册到宽泛的 `UTType.data`，避免与 citation 或未来 attachment provider 冲突；
- AppKit / UIKit 分别注册对应 `NSTextAttachmentViewProvider`；
- provider 创建 `MTMathUILabel`，使用 `.text` 数学模式；
- foreground color 取当前动态 paragraph color，不写死白色 / 黑色 / RGB；
- intrinsic size 必须经过 finite / positive / maximum-bound 检查；
- malformed source、引擎 error、nonfinite size 或超限时显示原始 `$...$` literal，不允许空白 attachment；
- attachment 和 label 不进入 completed-document cache 或 native-view cache；
- view 离开可见树后不得由全局 provider / catalog 持有。

普通 UI 字体仍由 Intatis 当前主题决定；math font 只用于数学 glyph 和 TeX metrics。

### 4.5 复制与无障碍

必须验证而不是假设：

- VoiceOver 至少读出本地化的“数学公式”以及原始 TeX source；
- inline attachment 不能只暴露 Unicode replacement character；
- 选择包含公式的段落时，复制结果必须有明确合同；
- 首选结果是复制原始 `$...$`；
- 如果 TextKit attachment 无法提供 byte-exact selection copy，则在进入 production 前必须给出独立、用户可达的 raw-message copy 路径，不能把 replacement character 当作完成；
- Dynamic Type / macOS 字号变化后公式 baseline 和 paragraph line height 必须重新测量；
- dark / light appearance 切换不得把公式留在旧颜色。

## 5. 配置与熔断

### 5.1 Renderer configuration

vendored package增加明确、默认关闭的数学配置，例如：

```text
MathRenderConfig.disabled
MathRenderConfig.singleDollarInline(...)
```

要求：

- package 默认保持 `.disabled`；
- Intatis production `firstReleaseParseConfiguration()` 只有在依赖、许可证和测试门关闭后才启用 `.singleDollarInline`；
- images、citations、animation、syntax highlighting 继续关闭；
- math attachment 不复用 Markdown image network path；
- `plainSafe` 继续完全绕过 Markdown 与 math；
- math 可单独在一处配置关闭，不需要回滚全部 Markdown。

### 5.2 Revision identity

启用数学会改变显示配置，因此必须：

- 提升 `IntatisMarkdownRendererLimits.configurationRevision`；
- math mode / appearance / font-size semantics 进入 request revision；
- old no-math document 不得在新配置下发布；
- streaming correction、truncation、completion 与 mode 切换继续触发当前 generation 校验；
- raw source 相同但 math configuration 不同时不得误复用旧 document。

## 6. 预计修改范围

以下是实施阶段的预期文件，不代表本轮已经修改：

### 6.1 Vendored Microsoft derivative

```text
Vendor/SwiftStreamingMarkdown/Package.swift
Vendor/SwiftStreamingMarkdown/Package.resolved
Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md
Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/Parser/**
Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/Inline/**
Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/Models/**
Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/Paragraph/AppKit/**
Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/Paragraph/UIKit/**
Vendor/SwiftStreamingMarkdown/Tests/MarkdownTextTests/**
```

建议新增的职责文件：

```text
Parser/InlineMathPreprocessor.swift
Models/MathRenderConfig.swift
Models/MathAttachmentData.swift
UI/Paragraph/MathAttachmentViewProvider.swift
```

实际命名可按现有 package 结构微调，但不能把全部逻辑堆回 Intatis facade。

### 6.2 Intatis thin integration

```text
Packages/IntatisSharedUI/Sources/MessageRendering/
  IntatisMicrosoftMarkdownPipeline.swift

Packages/IntatisSharedUI/Tests/
  MessageRenderingTests.swift
```

`IntatisMessageContentView.swift` 原则上不需要新增公式 scanner；如需变更，只允许 configuration / accessibility / lifecycle integration，不得解析 delimiter。

### 6.3 Dependency、NOTICE 与文档

```text
Package.resolved
NOTICE.md
ThirdPartyNotices/MathRendering.md
docs/CURRENT_STATE.md
docs/PROJECT_MAP.md
docs/ARCHITECTURE.md
docs/DO_NOT_BREAK.md
docs/TESTING.md
docs/NEXT_TARGET.md
```

根 `Package.swift` 预计继续只依赖仓内 `Vendor/SwiftStreamingMarkdown`；iosMath 应成为 vendored derivative 的 exact transitive dependency，而不是在 SharedUI 再建立第二条 direct edge。若 SwiftPM 实际解析要求不同，必须在最终报告解释，不能静默制造双重 package identity。

`project.yml` 预计无需语义修改；若 XcodeGen / Xcode package resolution 要求变更，必须单独说明并复核 iOS 子集。

## 7. 实施顺序与停止条件

以下 checkbox 保留为实施前计划快照，不用它们表达当前完成状态；实际执行结果与仍未关闭的发布门槛以第 14 节为准。

### Phase 0：冻结当前基线

- [ ] 记录当前 Git diff，避让用户既有改动；
- [ ] 跑 vendored renderer focused tests；
- [ ] 跑 SharedUI renderer tests；
- [ ] 保存当前 dependency graph 与 bundle resource inventory；
- [ ] 不启动 GUI，除非用户另行明确批准受控验证。

停止条件：当前 headless renderer baseline 自身失败，先解释既有失败，不把它归因于尚未实施的数学功能。

### Phase 1：许可证与依赖准入

- [ ] 获得 iosMath 2.5.0 及随包字体许可证的用户明确批准；
- [ ] 固定 URL、tag、revision；
- [ ] 读取根 license、文件头、manifest、字体 license 和资源目录；
- [ ] 检查 transitive dependencies；
- [ ] 更新拟采用项的 provenance 表。

停止条件：许可证范围不清、资源与声明不一致、用户不批准 custom font license。

### Phase 2：独立引擎 spike

- [ ] strict Debug / Release compile；
- [ ] malformed / nested / 8 KiB 边界 parse；
- [ ] parser threading / cancellation / generation audit；
- [ ] label intrinsic-size 与 invalid-size audit；
- [ ] macOS / iOS compile surface。

停止条件：只能靠 unsafe concurrency 绕过、同步 parse 无法满足冻结后的 main-thread gate、异常公式导致 crash / hang。

### Phase 3：vendored code-aware math node

- [ ] cheap candidate detection；
- [ ] AST code-range collection；
- [ ] `$...$` delimiter state machine；
- [ ] request-local placeholder catalog；
- [ ] math admission；
- [ ] normal Markdown fast path保持一次 parse；
- [ ] accepted math path最多两次 parse；
- [ ] invalid / stale / oversize raw fallback。

停止条件：需要在 SharedUI 自写 fenced-code grammar、需要修改 raw EventLog、或 code literal 不能 byte-exact 保留。

### Phase 4：TextKit attachment 与 UI

- [ ] dedicated attachment file type；
- [ ] AppKit provider；
- [ ] UIKit provider；
- [ ] dynamic color / size / baseline；
- [ ] invalid formula literal fallback；
- [ ] accessibility label；
- [ ] selection / copy contract；
- [ ] zero package-owned native-view cache。

停止条件：公式失败会造成整段空白、attachment 不能释放、copy / accessibility 没有可接受降级。

### Phase 5：SharedUI integration

- [ ] production config 启用单 `$...$`；
- [ ] configuration revision 提升；
- [ ] plainSafe 保持 parser-free；
- [ ] images / citations / animation / highlighting 继续 disabled；
- [ ] Chat / Code / Cowork / iOS 继续复用同一 facade；
- [ ] no-math kill switch 能独立关闭。

停止条件：需要为某个产品面复制 renderer、worker / provider / EventLog 语义发生变化。

### Phase 6：测试、构建与静态审计

- [ ] vendor unit tests；
- [ ] SharedUI focused tests；
- [ ] complete SwiftPM tests；
- [ ] macOS Debug / Release build；
- [ ] generic iOS build / test compile；
- [ ] unsigned archive（按现有 testing 文档要求）；
- [ ] macOS / iOS app bundle resource inventory；
- [ ] license / NOTICE hash 与 app 内可读性；
- [ ] banned-resource / remote-image / JavaScript scan；
- [ ] `git diff --check`。

停止条件：任一平台缺依赖、bundle 中出现未声明字体 / 品牌资源、NOTICE 与实际资源不一致。

### Phase 7：受控 GUI 性能验收

在实施前，此阶段需要用户另行明确批准启动 GUI；用户随后已批准按该方案构建并推荐使用 Computer Use 验证。

- [ ] 父进程保证只有一个 validation app 实例；
- [ ] 同时监控 wall time、RSS、footprint、CPU 与残留进程；
- [ ] 先运行无数学 baseline，再运行完全相同的数学 fixture；
- [ ] 分阶段：静态段落 → 1 个公式 → 32 个公式 → streaming closure → 历史滚动 / reentry → selection / copy；
- [ ] 越过 safety watchdog 立即终止，不继续叠加实例；
- [ ] 保存 signpost / sample；若仍增长，采集 malloc stack / heap graph 后再归因。

停止条件：

- 任意 >250 ms potential hang；
- interaction p95 超过既有 8 ms gate；
- single interaction 超过既有 50 ms gate；
- RSS / footprint 呈重复 reentry 的无界单调增长；
- old formula labels 在 message disappearance 后仍被 package-owned graph 持有；
- current 2026-07-18 adverse evidence 未被受控基线解释或关闭。

数值型 RSS / footprint release threshold 必须在运行前依据 baseline 冻结，不能观察结果后再改门槛。watchdog 的 abort threshold 与 release pass threshold必须分开记录。

### Phase 8：文档、回滚与交付

- [ ] 更新 vendor ledger；
- [ ] 更新 NOTICE / ThirdPartyNotices；
- [ ] 更新项目权威文档；
- [ ] 记录实际文件、依赖、测试、bundle hash、未决风险；
- [ ] 保留 `.plainSafe`；
- [ ] 证明关闭 math config 后恢复当前 renderer 行为；
- [ ] 不 add、不 commit、不 push，除非用户另外明确要求。

## 8. 测试矩阵

### 8.1 Delimiter

必须覆盖：

```text
$x$
$x_i$
$\frac{a}{b}$
中文前缀 $E=mc^2$ 中文后缀
\$x$
$29.99
$5 and $10
$$
$ x $
$x
x$
$x$1
$x\$y$
```

每例断言：

- accepted / literal 结果；
- 原始 source 不变；
- Unicode index 安全；
- parse catalog 不跨 request 泄漏。

### 8.2 Markdown interaction

必须覆盖公式位于：

- paragraph；
- heading；
- emphasis / strong 周边；
- unordered / ordered list；
- blockquote；
- table cell；
- link label 周边；
- 中英文和 emoji 周边。

还必须覆盖公式内容含：

- `_` / `^`；
- `{}`；
- `\frac` / `\vec` / `\text`；
- raw `*` 等可能被 CommonMark 解释的字符；
- escaped dollar。

### 8.3 Code protection

必须覆盖：

- 单 backtick；
- 多 backtick；
- fenced triple backtick；
- fenced tilde；
- 未闭合 fence；
- 缩进 code；
- list / blockquote 嵌套 code；
- code 内 `$x$`、`\(...\)`、`$$...$$`；
- code copy bytes 与输入完全一致。

### 8.4 Failure and budget

必须覆盖：

- malformed TeX；
- unknown command；
- 深层嵌套；
- 8 KiB - 1 / 8 KiB / 8 KiB + 1；
- 31 / 32 / 33 candidates；
- nonfinite / zero / huge intrinsic size；
- engine unavailable；
- attachment decode failure；
- appearance switch；
- deactivation / reentry。

任何失败都不得产生 blank message、crash、无限 spinner 或错误持久化。

### 8.5 Streaming and stale publication

依次提交：

```text
$
$x
$x$
$x$ 后
$y$ 后
```

并覆盖：

- append-only；
- correction；
- truncation；
- final exact flush；
- mode rich → plainSafe；
- light → dark；
- message identity change；
- old parse finishes after new generation；
- disappear / reappear。

旧 document / attachment 不得覆盖当前 raw source。

### 8.6 Accessibility and copy

- VoiceOver 读出公式 source；
- keyboard selection；
- paragraph copy；
- code copy；
- Dynamic Type；
- macOS 12/24 小时或 locale 与公式无耦合；
- English / zh-Hans UI label；
- user / system plain rows不进入 math。

## 9. 性能预算与测量方法

### 9.1 普通 Markdown

没有 `$` 的消息必须保持当前路径：

- 一次 Markdown parse；
- 不创建 math catalog；
- 不链接任何 runtime network；
- 不创建 math attachment；
- interaction gate 不退化。

需要用现有 17 messages / 1,249 deltas fixture 对比改动前后；fixture SHA-256 与既有报告保持一致。

### 9.2 含公式 Markdown

可能的额外成本：

- 第一次 raw AST 用于 code source ranges；
- accepted candidate 时第二次 transformed AST；
- 每个可见公式一个 native attachment / math label；
- MainActor intrinsic-size 与 baseline layout；
- dark / light 或 Dynamic Type 变化后的重新测量。

控制手段：

- 只在可能存在单 `$` 时进入 math preflight；
- 无 accepted candidate 复用第一次 AST；
- 最大 32 公式；
- 最大 8 KiB 单公式；
- 仍受全局 1 permit / latest-only scheduler 控制；
- stale document 不 mount；
- 未闭合 streaming candidate 不创建 label；
- 不增加 completed-document / math-view cache。

### 9.3 代码块

代码块继续：

- 不运行 syntax highlighter；
- 不运行 JavaScript；
- 不进入 math scanner；
- 原生 Text / horizontal scroll / Copy；
- 受整条 64 KiB admission 约束。

数学 patch 必须证明 code block 的 parse、布局和 copy 回归为零。

## 10. 回滚方案

### 10.1 运行时 / 配置回滚

优先回滚：

```text
production MathRenderConfig.singleDollarInline
  -> MathRenderConfig.disabled
```

结果：

- 普通 Microsoft Markdown 继续工作；
- 代码块继续工作；
- 所有 `$...$` 回到 literal；
- EventLog / session 无迁移；
- 不需要删除用户数据；
- `plainSafe` 仍是更强的整套 renderer 熔断。

### 10.2 源码 / 依赖回滚

数学变更应保持为一个可识别 patch group：

- vendor math source / tests；
- iosMath exact dependency；
- root / vendor resolved pins；
- math notices；
- project docs。

因为 raw source 从未改变，移除这一 patch group不会产生数据迁移。不得用 `git reset --hard`、`git checkout .` 或清理用户工作树来回滚。

## 11. 完成定义

第一阶段只有同时满足以下条件才算完成：

1. `$x$` 等正常单美元公式在 macOS / iOS assistant / agent rich message 中渲染；
2. 代码块、inline code、货币、escaped dollar 与未闭合公式保持 literal；
3. invalid / oversize math 保留原始 `$...$`，不留空白；
4. ordinary Markdown 和 code block 行为不退化；
5. raw EventLog / projection / provider wire 完全不变；
6. `plainSafe` 和独立 math disable 都有效；
7. exact dependency、字体资源、NOTICE 与 bundle inventory 一致；
8. vendor strict、SharedUI focused、完整测试、macOS / iOS build 通过；
9. 受控 GUI 未出现 hang、失控 CPU / memory 或残留实例；
10. selection / copy / accessibility 有实际验证；
11. vendor patch ledger 和项目权威文档已更新；
12. 最终报告明确区分：Microsoft-derived code、iosMath dependency、Intatis-owned thin admission / lifecycle integration。

在第 9 项关闭前，最多只能描述为“源码与 headless 验证完成”，不得标记为 release-ready。

## 12. 实施前唯一需要的外部决定

开始依赖和业务源码修改前，需要用户明确决定：

> 是否批准引入 `iosMath 2.5.0` exact revision，以及它实际随 package 分发的 GUST / LPPL / OFL 数学字体与许可证文本。

批准后按本计划 Phase 0 → Phase 8 执行。未批准则停止在计划阶段，另做 OFL-only 或其他成熟数学引擎的依赖方案；不自行替用户接受许可证，也不偷偷恢复历史资源。

## 13. 依据

- `codex-report/07_15_26-chat-markdown-code-latex-rendering-research.md`
- `codex-report/07_17_26-22_16-swift-streaming-markdown-adoption-migration-report.md`
- `codex-report/07_17_26-23_25-markdown-phase0-phase1-implementation-record.md`
- `codex-report/07_18_26-11_46-swift-streaming-markdown-cutover-implementation-validation.md`
- `docs/CURRENT_STATE.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/OPEN_SOURCE_REUSE.md`
- `docs/TESTING.md`
- `NOTICE.md`
- `ThirdPartyNotices/MathRendering.md`
- `Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md`

## 14. 2026-07-24 实施结果

### 14.1 已完成的实现

用户已明确批准 iosMath 2.5.0 exact revision 及随包分发的 GUST / LPPL / OFL 字体与许可证文本。实施保持了本计划的三层边界：

- 普通 Markdown 与代码仍由仓内 Microsoft SwiftStreamingMarkdown 派生版及原生 TextKit/CodeBlock 路径处理；
- Intatis-owned scanner 只接受受保护上下文之外的正常单美元 `$...$`，每条消息最多 32 个公式、每个公式最多 8 KiB，任一上限失败时整条消息的候选全部保持 literal；
- fenced/inline code、currency、escaped dollar、`$$`、`\(...\)`、`\[...\]`、未闭合和不合法候选保持原文；
- accepted math 通过 iosMath live `MTMathUILabel` + TextKit 2 attachment 显示，不生成或缓存 production raster；
- raw EventLog / projection / provider wire 没有改写，formula attachment 持有 exact 原始 `$...$` 供失败回退、copy projection 与 accessibility；
- `plainSafe` 与独立 math-disabled 配置仍可绕过数学路径。

AppKit 最终可见性问题的源码根因在 paragraph attachment lifecycle：`ParagraphNSView` 现在显式持有 `NSTextContentStorage → NSTextLayoutManager → NSTextContainer`，在 `setAttributedString` 后恢复 primary layout manager，并把 `layoutViewport()` 合并到下一次 main turn。AppKit attachment 不再设置 generic `attachmentCell`，只使用专用动态 UTI 的直接 `NSTextAttachmentViewProvider`；没有 broad UTI hijack。`CATransaction.flush()` 仅存在于测试。

### 14.2 验证结果

- Vendor：75 XCTest + 7 Swift Testing = **82/82**；strict Release `-warnings-as-errors` 通过。
- SharedUI：`MessageRenderingTests` **25/25**。
- 根工程：fresh `swift test --skip-build --disable-sandbox` 为 **938 tests / 14 skipped / 0 failures**。此前一次 full rerun 进入 XCTest 等待态后被有界中止并确认无残留，不能隐去；随后新进程 17.061 秒完整通过。
- Products：XcodeGen、IntatisMac Debug/Release、IntatisiOS generic Simulator Debug/Release 均成功。
- Supply chain：两份 lockfile 固定 iosMath 2.5.0 / `838cddc01fdd67efd530f8bb67959ad2715f9b06`；macOS/iOS Release bundle 各含 8 OTF 和完整 26-file `fonts/` payload；仓内和双端 app `NOTICE.md` SHA-256 均为 `02778763b3743e591b3ccb30537f853d2d5a791b1002e032ff65ed5821c7b5b8`。
- Hash-pinned validation executable `ec56cec173c13e41edb4f53e3ff5fcb1ac3d35079d40f140c4503a4d99dde55f` 完成同 renderer math-disabled/enabled A/B，以及 `math-one`、`math-thirty-two`、`math-history`、`math-stream` 短时隔离阶段；全部 exit 0、无 TERM/KILL、二次清理成功且无残留。
- Light/Dark Computer Use `math-structure` 各约 47.47 秒。稳定画面显示 heading、paragraph、unordered/ordered list、blockquote、table 内的 live math glyph；`$not_math$` 与 `$table_code$` 保持 literal；AX tree 描述原始 TeX。Light/Dark peak RSS 分别为 136,691,712 / 135,036,928 bytes，footprint 为 48,710,520 / 48,087,904 bytes，rolling CPU 为 11.5379% / 11.2088%。这些是单次 containment observation，不是性能阈值或提升结论。

### 14.3 完成定义的当前判定

源码、依赖、许可证、字体资源、测试、双端构建、短时同 renderer A/B、五个隔离阶段与 Light/Dark 可见性已经完成。以下仍是发布验证门槛：

1. 2026-07-18 历史事故的最终 malloc retaining edge 仍为 `UNKNOWN`；
2. 尚未进行 >160 秒单实例 long soak；
3. AX tree 已验证 source projection，但真实 selection / clipboard bytes 与真实 VoiceOver 操作尚未执行；
4. 尚未覆盖最低支持 macOS runtime 与低端 iPhone/iPad 实机。

因此本轮结论是“单美元数学实现和短时受控验证完成”，不是 “renderer release-ready”。第 11 节第 10 项及长时/实机发布门槛继续保持 open。
