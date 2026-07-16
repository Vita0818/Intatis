# Intatis 对话渲染调研与落地报告：Markdown / Code / LaTeX

> 日期：2026-07-15
> 状态：已从只读调研更新为本轮实际落地版
> 产品基线：iOS 26 / macOS 26，不考虑旧系统兼容
> 范围：对话消息中的 Markdown、完整代码块、LaTeX 三套独立渲染能力

## 0. 执行摘要

本轮已经按“三个东西、三条独立方向”完成实现，而不是把它们混成一个万能 renderer：

| 独立方向 | 最终采用 | Intatis 自己负责 | 明确不自研 |
| --- | --- | --- | --- |
| Markdown | MarkdownUI 2.4.1 | 消息入口、主题、链接/图片策略、流式调度、回退 | CommonMark/GFM parser、AST、block/inline 排版 |
| Code | 选择性 vendored highlight.js 11.11.1，通过 JavaScriptCore 薄适配 | 完整代码框、语言栏、复制、Menlo、选择、双向滚动、缓存、回退 | lexer、语言 grammar、关键字表、token 分类与语法着色 |
| LaTeX | iosMath 2.5.0 | 显式定界符路由、SwiftUI/AppKit/UIKit 包装、inline/display 容器、缓存、回退 | TeX parser、命令表、atom tree、字体度量、数学排版与绘制 |

最终调用关系为：

```text
EventLog / Projection 中的 raw message（唯一真值）
                         ↓
          IntatisMessageContentView
             ├─ MarkdownUI 2.4.1
             │    └─ fenced code → IntatisCodeBlockView
             │                       └─ highlight.js 11.11.1
             │                          （JavaScriptCore 薄适配）
             └─ 显式 math delimiter → iosMath 2.5.0
```

实际审计改变了调研阶段的代码方向：CodeEditor 与 HighlighterSwift 都没有进入依赖图，也没有复制其 wrapper。HighlighterSwift 的实证 SwiftPM 构建表明资源 bundle 会复制完整主题目录，其中含 `nnfx` / `kimbie` 的 CC BY-SA 资产；因此最终只选择性 vendor 三个逐文件审计的资源。`highlight.min.js` 直接锚定官方 `highlightjs/cdn-release` 11.11.1 tag 的生成文件；两个 a11y CSS 的实际字节源是 HighlighterSwift 3.1.0 的适配版，并同时保留 HighlighterSwift MIT modifications 与 highlight.js BSD-3-Clause 许可链。审计还剔除了一个虽仍显示 11.11.1 package version、却由 release 后开发 commit 生成的候选脚本，避免版本标签与实际执行字节不一致。最终官方 common build 注册 36 个常用 grammar，覆盖 Intatis 暴露的语言，同时把三项资源从约 994 KiB 降到 129,157 bytes。

## 1. 调研结论与证据边界

### 1.1 ChatGPT 网页端能借鉴什么

ChatGPT 网页端 renderer 源码没有公开，不能可靠断言其内部使用 KaTeX、MathJax、Shiki、highlight.js 或任何特定库。压缩 bundle、DOM class 和网络资源最多只能形成推测，不能成为 Intatis 的开源 provenance。

可确认并借鉴的是成熟对话产品的外部行为：

- Markdown 正文、代码块和公式在视觉与错误策略上彼此独立；
- 代码是完整的框体组件，不只是返回几段彩色文本；
- 已完成内容保持稳定，流式期间只更新正在增长的尾部；
- 解析、高亮或公式排版失败时保留原文；
- 代码块 Copy 使用 raw code source，而不是从富文本或 HTML 反向提取；无效公式保留可选择的 literal；
- 单 `$...$` 容易与货币文本冲突，首版不应默认启用。

OpenAI 公开的 `openai/chatkit-js` 不是 ChatGPT 网页端源码。公开 issue 只可证明 ChatKit 曾支持块级 `$$...$$`，并因货币歧义未默认支持单美元符号行内公式；本报告不把这解释成 ChatGPT 内部实现证据。

### 1.2 成熟开源项目带来的模式

| 项目 | 已核验的成熟做法 | 对本实现的影响 |
| --- | --- | --- |
| [Vercel Streamdown](https://github.com/vercel/streamdown) / [Chatbot](https://github.com/vercel/ai-chatbot) | 修补流式未闭合 Markdown、按稳定 block 渲染、完成块 memoize | 采用节流、完成态缓存、原文回退，不引入 React runtime |
| [Lobe UI](https://github.com/lobehub/lobe-ui) | append-only 高亮、stable/unstable token、processor/cache 复用 | 高亮结果有界缓存；流式结果不覆盖 raw source |
| [LibreChat](https://github.com/danny-avila/LibreChat) | 利用 AST position 切稳定 source slice，只让尾 block 增长 | 已完成消息立即缓存；历史消息不随新 token 重建 |
| [Open WebUI](https://github.com/open-webui/open-webui) | Markdown lexer 节流、代码/公式分组件、KaTeX 懒加载 | 证明“每帧一次”仍不足以替代稳定缓存 |
| [Chatbox](https://github.com/chatboxai/chatbox) | 语言栏、复制、横滚、Shiki singleton、LRU | 借鉴完整代码块 UX；GPL-3.0 源码不复制 |
| [Enchanted](https://github.com/AugustDev/enchanted) | SwiftUI + MarkdownUI、流式更新批处理 | 证明 Apple-native MarkdownUI 接入路径可行 |

这些项目只提供架构与交互参考。最终核心引擎来自已固定版本的 MarkdownUI、highlight.js 和 iosMath；Intatis 没有翻写网页项目的 parser、grammar 或排版实现。

## 2. 三条独立渲染方向

### 2.1 MarkdownRenderer：MarkdownUI 2.4.1

MarkdownUI 负责 Markdown tokenization、AST 和 SwiftUI block/inline 渲染。Intatis 不维护自己的 CommonMark/GFM 语法或 block visitor。

本地薄层只做：

- 根据消息角色决定 `.richText` 或 `.plainText`；
- 注入 Intatis 主题；
- 将 fenced code block 交给独立 `IntatisCodeBlockView`；
- 把派生的 `intatis-math://` 图片 URL 交给独立公式 provider；
- 限制链接 scheme；
- 拦截 Markdown 远程图片；
- 管理流式延迟、取消、完成态缓存和纯文本回退。

未启用 raw HTML 执行。链接只允许 `http`、`https`、`mailto`。MarkdownUI 的 `NetworkImage` 仍在固定依赖图中，但 Intatis 覆盖 block 与 inline image provider，不允许消息内容隐式下载远程图片。

#### MarkdownUI 2.4.1 上游复杂度风险

最终审计不能只以“单条消息不超过 512 KiB”作为 Markdown 安全门。MarkdownUI 当前公开记录表明，小得多、但结构恶意或病理化的输入也可能在递归 SwiftUI `Text + Text` 组合与列表布局阶段产生崩溃或长时间冻结：

- open issue [#312](https://github.com/gonzalezreal/swift-markdown-ui/issues/312)：约 250 个 soft breaks 即可触发 crash；
- open issue [#426](https://github.com/gonzalezreal/swift-markdown-ui/issues/426)：MarkdownUI 2.4.1 对中等长度/深层列表输入可能冻结；
- open PR [#438](https://github.com/gonzalezreal/swift-markdown-ui/pull/438)：上游分析将问题指向递归 `Text + Text` 构造，并记录真机约 500、模拟器约 3000 个相关节点的量级差异；
- open issue [#445](https://github.com/gonzalezreal/swift-markdown-ui/issues/445)：列表嵌套达到约 10 层时布局性能急剧下降。

这些数字是上游 issue/PR 中的复现与分析，不是 Intatis 可依赖的稳定平台上限。PR #438 尚未合并；Intatis 不复制其 renderer 核心修复，也不把未合并 patch 伪装成本项目原创。当前选择是在进入 `MarkdownContent` / SwiftUI renderer 前，用已固定的 cmark-gfm AST 做只读 complexity gate；parser、AST 语义和 Markdown 排版核心仍归上游，Intatis 只做是否允许 rich projection 的安全决策。

### 2.2 CodeRenderer：完整代码框 + highlight.js 11.11.1

用户看到的是完整的只读代码块：

```text
┌─ SWIFT ───────────────────────────── Copy ┐
│ let count: Int = 10                       │
│ for index in 0..<count {                  │
│     print(index)                          │
│ }                                         │
└───────────────────────────────────────────┘
```

实际能力包括：

- 语言标签和复制/已复制状态；
- Menlo 13 pt 等宽字体；
- 背景、圆角、边框、内边距和分隔线；
- 原生文本选择；
- 水平与垂直滚动，长行不强制折行；
- 内容高度上限，避免大块代码无限撑高消息；
- Swift、TypeScript 等受支持语言的关键词、类型、字符串、注释和数字着色；
- 语言别名规范化，例如 `js → javascript`、`ts → typescript`、`zsh → bash`；
- 未知语言、超限、加载失败，以及暂时禁用的受影响 C-family grammar 都立即显示完整 plaintext；
- 复制永远使用未经改写的 `source`。

语法识别由固定的 highlight.js 引擎及其上游 grammar 完成。Intatis 的 JavaScriptCore adapter 只执行以下接口转换：

```text
(source, normalizedLanguage, light/dark theme)
        → hljs.highlight(...)
        → upstream HTML fragment
        → NSAttributedString / AttributedString
```

adapter 在返回前校验最终 attributed string 与 raw source 完全一致；任何异常、未知语言或文本变化都回退 plaintext。代码永远不会被执行，也不会出现 HTML/SVG preview、远程 grammar 下载或隐式 workspace 写入。

### 2.3 LaTeXRenderer：iosMath 2.5.0

首版支持三种显式定界符：

- 行内：`\(...\)`
- 块级：`\[...\]`
- 块级：`$$...$$`

单 `$...$` 不启用，普通 `$25.00` 保持货币文本。适配器会跳过由同一 pinned cmark-gfm 识别出的所有 CommonMark code block（包括缩进、blockquote/list 嵌套、tab 与未闭合 fence）以及有效 inline code span，因此代码中的 TeX 字符串不会被误判为公式；Intatis 不自己维护另一套 fence grammar。块级公式仅在 column-one、独占逻辑行的顶层定界符中启用；list、blockquote、table 或 prose 内的 display delimiter 保留字面 source，避免为了插入根级空行而破坏 Markdown 容器结构。

iosMath 负责 TeX tokenization、命令解析、atom tree、字体度量、排版和绘制。Intatis 只：

- 识别上述明确边界；
- 用 iosMath parser 预验证表达式；
- 把合法表达式映射为进程内 `intatis-math://` 派生 URL；
- 用 `MTMathUILabel` 包装 inline/display 渲染；
- 为超宽 display 公式提供水平滚动；
- display 公式提供包含原 TeX 的 accessibility label；inline image 使用 labeled initializer，但 MarkdownUI 2.4.1 把它拼入 `Text` attachment 后，macOS Accessibility tree 仍只暴露 replacement character，因此 inline 数学语义化 VoiceOver 仍是明确待验证/上游限制；
- 对无效或未闭合公式保留可复制的字面定界符与原文。

inline 公式通过透明 template image 接入 MarkdownUI 的 inline image provider；display 公式使用原生 SwiftUI wrapper。MarkdownUI 会把“整段只有一个 image”的段落提升到 block image provider，因此 Intatis 的 block provider 也显式识别 `.inline` math 并改走 standalone inline math view，不会把纯公式段误判为被拦截的远程图片。两者都不走 WebView、远程脚本或 CDN。

## 3. 为什么没有采用 CodeEditor / HighlighterSwift

### 3.1 CodeEditor

调研阶段曾考虑 ZeeZide/CodeEditor 和 `mchakravarty/CodeEditorView` 一类完整编辑器组件。实证后未采用，原因是：

- 对话场景需要只读代码框，不需要编辑器状态、命令和大面积交互表面；
- 外框、语言栏、复制和滚动本来就是 Intatis 产品接口层；
- 采用完整编辑器会引入比需求更大的依赖和维护面；
- 语法核心仍可直接复用成熟 highlight.js，而无需自研 lexer/grammar。

最终没有链接、vendor 或复制 CodeEditor wrapper/source/assets。

### 3.2 HighlighterSwift

HighlighterSwift wrapper 及其 modifications 是 MIT，但其 SwiftPM resource bundle 的实证构建会复制完整主题目录，其中包含 CC BY-SA 的 `nnfx` / `kimbie` 主题。这个整包资源范围不符合 Intatis 当前依赖准入策略。

最终处理方式不是重写高亮器，而是：

1. `highlight.min.js` 的字节源直接锚定 `highlightjs/cdn-release` tag 11.11.1 commit `91724c0adaf7bea7e5c5c85e4ea1d672f6c0ed23` 的 `build/highlight.min.js`，generated header 对应 source revision `08cb242e7d`；
2. `a11y-light.css` / `a11y-dark.css` 的真实字节源是 HighlighterSwift 3.1.0 commit `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0` 中的适配版；
3. 两个 CSS 同时遵循 HighlighterSwift MIT modifications 与 highlight.js BSD-3-Clause 的许可链，不能只标成 BSD-3-Clause；
4. 不引入 HighlighterSwift Swift wrapper 和其他主题；
5. 用很薄的 JavaScriptCore adapter 调用上游引擎。

这满足“核心解析/grammar/高亮引擎直接复用成熟开源项目，Intatis 只写接口”的边界。

## 4. 实际集成架构

### 4.1 文件与职责

```text
Packages/IntatisSharedUI/Sources/MessageRendering/
├─ IntatisMessageContentView.swift  # 公共入口、MarkdownUI 主题与安全 provider
├─ IntatisRenderDocument.swift      # raw truth、cmark code range、显式公式路由、AST 缓存
├─ IntatisCodeBlockView.swift       # 完整代码框 + highlight.js 薄适配
├─ IntatisMathView.swift            # iosMath 的 SwiftUI/AppKit/UIKit 包装
└─ Resources/
   ├─ highlight.min.js
   ├─ a11y-light.css
   └─ a11y-dark.css
```

`IntatisMessageContentView` 的输入只有稳定消息 ID、raw text、完成状态、rich/plain policy 和现有 thread style。它位于 SharedUI 派生展示层，不改变 ChatLoop、AgentLoop、provider 请求、ConversationProjection、EventLog JSONL、Envelope 或 `seq` 语义。

### 4.2 Chat / Code / Cowork 接入

| 产品面 | 接入点 | 富文本策略 |
| --- | --- | --- |
| macOS Chat | `Apps/IntatisMac/Sources/IntatisChatScreen.swift` | assistant / agent 消息使用 rich renderer；user / system 保持原有纯文本 |
| iOS Chat / Shared Chat | `Packages/IntatisSharedUI/Sources/Views.swift` | assistant / agent 消息 rich；user / system plain |
| Code | `Packages/IntatisSharedUI/Sources/CodeViews.swift` | agent 正文 rich；用户输入和结构化专用卡片保持 plain/原视图 |
| Cowork | 复用 `CodeItemRow` | 继承 Code 的 agent 富文本路径，不创建第四套 renderer |

这样既覆盖三种产品面，又避免把 patch、permission、error、tool result 等结构化内容错误地当成任意 Markdown 执行。

### 4.3 原始文本与派生状态

raw message 永远是唯一真值。以下都是可丢弃、可重建的 UI 派生物：

- 公式私有 URL 和表达式 map；
- Markdown AST / SwiftUI view tree；
- syntax token / attributed runs；
- inline 公式 bitmap；
- 主题、字体和内容缓存。

代码块 Copy 直接使用 raw code source；无效公式与整条 fail-closed 路径保留字面 source。富文本视图本身没有虚构“整条 raw copy”能力；消息 raw text 的保证是它始终留在 EventLog/projection 作为事实源。派生内容不会写回 EventLog，也不会改变 provider 收到或模型返回的文本。

## 5. 流式、缓存与性能边界

### 5.1 流式更新

- rich message 使用 `.task(id: revision)`；新 revision 自动取消旧任务；
- 未完成 Markdown 消息延迟 50 ms 合并更新；完成消息立即构建；
- 未完成代码块延迟 60 ms 后再高亮；任务取消即丢弃结果；
- 未闭合公式不反复排版，直接显示字面 source；
- 已完成文档进入缓存，不因同一 source 再次构建；
- 高亮未就绪时先显示 plaintext，不阻塞对话流式输出；
- 每条 rich input 先经过一次 pinned cmark-gfm 只读 complexity/source-range audit，通过后再由 MarkdownUI 构造显示 AST；这是安全审计 parse 加上游显示 parse，不再宣称 ordinary Markdown “exactly one parse”；
- cmark/MarkdownContent 构建和 JavaScriptCore 语法分类分别由串行 actor worker 移出 SwiftUI main actor；
- 公式私有 URL 包含 presentation 与 source digest，流式原位改写公式不会复用陈旧 inline image identity；
- 同一 delimiter 无闭合符时只扫描到 EOF 一次，后续 opener 不重复二次扫描；
- code render revision 与高亮缓存使用分字段、UTF-8 byte-exact key，命中后再次复核显示字符，避免语言/source 拼接碰撞或 Unicode canonical-equivalence 把旧代码错显到新代码框。

当前实现没有声称拥有真正的增量 Markdown parser。它通过 revision 取消、UI 节流、完成态缓存和 plaintext-first 控制成本；后续只有在 OS 26 真机数据证明需要时，再考虑稳定 block 级缓存。

### 5.2 有界缓存与输入上限

| 边界 | 当前值 | 超限行为 |
| --- | ---: | --- |
| 单条 rich message | 512 KiB UTF-8 | 整条回退纯文本 |
| 单个公式 | 32 KiB UTF-8 | 保留原公式文本，不交给 iosMath 绘制 |
| 每条消息公式候选 | 64 对显式 delimiter | 整条 rich projection fail closed 为纯文本 |
| 派生 Markdown | 768 KiB UTF-8 | 整条回退纯文本，不交给 MarkdownUI parser |
| inline 公式 bitmap | 1024 × 256 px，且不超过 262,144 pixels | 显示有界失败标记；raw EventLog 文本不变 |
| 单个代码块高亮 | 64 KiB UTF-8 | 完整代码框内显示 plaintext |
| 完成文档缓存 | 96 项 / 总成本 4 MiB | `NSCache` 自动淘汰 |
| 高亮缓存 | 64 项 | FIFO 式有界淘汰 |
| 代码块可视高度 | 最高 360 pt | 框内纵向滚动 |

缓存只存派生展示结果，不承诺持久化，也不能成为消息事实来源。

### 5.3 Markdown AST complexity gate（已落地）

complexity gate 位于 `MarkdownContent` 构造之前。它用与 MarkdownUI 2.4.1 同构的 pinned cmark-gfm parser 配置：`CMARK_OPT_SOURCEPOS`，并显式挂载 `autolink`、`strikethrough`、`tagfilter`、`tasklist`、`table` 五个 GFM extension。检查器只遍历只读 AST 并累计复杂度，不修改 AST、不重新解释 Markdown 语法，也没有复制 PR #438 的核心 renderer 改动。

| 指标 | 最终上限 | 超限行为 |
| --- | ---: | --- |
| 单个 paragraph 的 soft break + line break | 128 | 整条 raw message 回退 plain |
| paragraph / heading / table cell 的非 break inline node | 256 | 整条 raw message 回退 plain |
| list nesting | 8 | 整条 raw message 回退 plain |
| 总 AST node 数 | 4,096 | 整条 raw message 回退 plain |
| AST 最大深度 | 32 | 整条 raw message 回退 plain |

如果 raw source 出现任一受支持 math opener，检查器会为最多 64 个公式 placeholder 预留最坏增长：总 node 预算减 256、depth 减 1、每个 inline container 的非 break node 预算减 192；即该路径按 3,840 nodes、31 depth、64 non-break inline nodes 审核原始 AST。这样公式替换后的 MarkdownUI 显示 AST 仍被完整预算覆盖。

gate 对 parser/extension 初始化失败、计数超限、未知节点类型或 source range 不可证明的情况全部 fail closed；不会先构建部分 rich view 再局部截断。测试覆盖第 128/129 个 paragraph break、第 8/9 层 list、大 GFM table AST、宽 inline tree 和正常 GFM 内容。

同一次只读 AST audit 同时处理 `CMARK_NODE_CODE_BLOCK` 与 `CMARK_NODE_CODE`，统一向 math adapter 提供代码保护范围，但不会含混地把所有多行 inline code 都描述成“直接采用 exact SOURCEPOS”：

- `CODE_BLOCK` 继续按 cmark 的 start/end line 保护完整 raw block；
- 单行 `CODE` 直接把 cmark `SOURCEPOS` 的 byte-oriented line/column 映射为 Swift `String.Index`；
- 多行 `CODE` 不能盲信 `endColumn`：cmark 在 blockquote/list continuation line 上会先扣除容器前缀，再报告末列；
- 对多行 `CODE`，Intatis 使用 cmark 已解析节点的 `endLine` 与 `cmark_node_get_backtick_count`，只在对应 raw 末行、从上游 end column 之后定位该已知长度的 closing run，并以此校正保护范围；
- 上述处理是对已解析节点的 source-position repair，不查找 opener、不自行决定哪一组反引号配对，也不实现第二套 CommonMark code-span parser；
- closing run、UTF-8 边界或 range 无法被证明时，检查器 fail closed，整条消息回退 raw plain；
- cmark 行号映射覆盖 LF、CR、CRLF，且 CRLF 视为一个逻辑换行；fenced、indented、blockquote/list 内 code 保留原始 Unicode source；
- 通用手写 backtick 配对器已经删除；连续长反引号、未闭合 inline code 和递增长 backtick run 的 DoS 回归仍保持线性有界扫描。

## 6. 安全与平台边界

### 6.1 渲染安全

- Markdown 不执行 raw HTML；
- 链接只允许 `http` / `https` / `mailto`；
- block/inline Markdown 图片 provider 都拦截任意外部图片；
- `intatis-math://` 只解析当前文档已登记的表达式；
- math adapter 不进入 cmark 识别的 block code 或有效 inline code span；
- highlight.js 只接收字符串并返回样式结果，不运行消息代码；
- 不支持 CDN、远程 script、远程 grammar、WebView 或隐式网络资源；
- parser、高亮、无效 TeX 与输入超限均 fail closed 到 raw text；极少数已经通过预校验、但在 inline bitmap 阶段失败的公式显示有界警告标记，provider 不抛错，因此不会导致同段其他 inline 公式一起消失或应用崩溃。原始消息始终保留在 EventLog/projection，运行期位图失败不被误称为“可选择 raw 公式回退”。

在 Markdown 路径中，字节数门不能替代结构复杂度门。只有通过第 5.3 节 pinned cmark AST 只读检查的文本才允许构造 `MarkdownContent`；soft/line break、list nesting、总节点或总深度任一超限时，整条消息必须直接使用 raw plain projection。

highlight.js 官方 issue [#4362](https://github.com/highlightjs/highlight.js/issues/4362) 仍记录 11.11.1 C/C++ `FUNCTION_DECLARATION` grammar 的二次复杂度 ReDoS；本轮本地 PoC 也观察到输入翻倍时耗时约四倍。Intatis 不修改上游 grammar：`c`、`cpp` 在采用已修复且重新审计的 release 前固定走 plaintext，完整代码框、Menlo、选择、滚动和复制仍保留。官方 common build 不含同样受影响的 Arduino grammar；其余已登记 grammar 继续使用官方引擎与 64 KiB 总输入门。

### 6.2 产品与权限边界

渲染依赖只通过 `IntatisSharedUI` 进入 Apple 平台，不进入 CLI/headless 执行图。iOS 仍是 Chat 子集；本功能没有把 shell、Git、patch、本地 agent workspace 或 Cowork 执行能力引入 iOS。

renderer 不拥有也不修改 PermissionEngine、CapabilityLease、WorkspaceLease、PathConfinement、SecretScanner、Mediator、durable tool execution 或 EventLog。未来若为代码块增加“运行”按钮，那是一个新的权限化工具任务，不能复用纯展示组件绕过现有安全链路。

## 7. 依赖锁、provenance 与 NOTICE

### 7.1 SwiftPM 精确版本与解析 commit

| 依赖 | 精确版本 | `Package.resolved` commit | 作用 |
| --- | --- | --- | --- |
| MarkdownUI | 2.4.1 | `5f613358148239d0292c0cef674a3c2314737f9e` | Markdown parser 与 SwiftUI renderer |
| NetworkImage | 6.0.0 | `7aff8d1b31148d32c5933d75557d42f6323ee3d1` | MarkdownUI 依赖图固定；远程 provider 被 Intatis 覆盖 |
| swift-cmark | 0.5.0 | `3ccff77b2dc5b96b77db3da0d68d28068593fa53` | MarkdownUI 的 CommonMark parser；Intatis 只读审计复杂度并读取 CODE/CODE_BLOCK source metadata |
| swift-snapshot-testing | 1.12.0 | `26ed3a2b4a2df47917ca9b790a57f91285b923fb` | MarkdownUI 测试侧依赖固定；不链接 Intatis app 产品 |
| iosMath | 2.5.0 | `838cddc01fdd67efd530f8bb67959ad2715f9b06` | TeX parser、layout 与字体资源 |

`Package.swift` 对五项使用 exact constraint，避免 MarkdownUI 的开放依赖范围在后续 resolve 时漂移。

### 7.2 vendored highlight.js 文件

| 文件 | SHA-256 | 真实字节源 | 许可链 |
| --- | --- | --- | --- |
| `highlight.min.js` | `c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381` | `highlightjs/cdn-release` 11.11.1 tag commit `91724c0adaf7bea7e5c5c85e4ea1d672f6c0ed23`，`build/highlight.min.js` | highlight.js BSD-3-Clause |
| `a11y-light.css` | `8dc8508231539c9f0942e2bf9244e1dab8d4aa1334c486649ab831695b3792d5` | HighlighterSwift 3.1.0 commit `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0` 的适配版 | HighlighterSwift MIT modifications + highlight.js BSD-3-Clause |
| `a11y-dark.css` | `1819a72f11c6edb3ea07d32f19f0ac410da8e387673791f6b6e3a9387b314d48` | HighlighterSwift 3.1.0 commit `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0` 的适配版 | HighlighterSwift MIT modifications + highlight.js BSD-3-Clause |

升级任一文件必须重新核对引擎版本、三项 hash、主题作者/许可、语言覆盖与 JavaScriptCore 行为，不能只覆盖文件。

### 7.3 已写入的合规材料

- `NOTICE.md`
- `ThirdPartyNotices/MarkdownRendering.md`
- `ThirdPartyNotices/SyntaxHighlighting.md`
- `ThirdPartyNotices/MathRendering.md`

这些文件记录依赖、commit、具体复用方式、版权、许可、字体映射、资产 hash 和分发边界。它们存在于源码树只是 provenance 记录；正式 App Store / Developer ID 产物仍必须让用户能够访问相应 NOTICE 与详细许可。

## 8. OS 26 基线

本轮已经把两套工程声明统一为最低 iOS 26 / macOS 26：

- `Package.swift`：`.macOS("26.0")`、`.iOS("26.0")`
- `project.yml`：macOS / iOS deployment target 26

因此实现不包含 iOS 16、macOS 13 等旧系统的兼容分支；验收只针对 OS 26 SDK 与目标平台。

## 9. 测试与 Computer Use 验证

### 9.1 最终自动化与构建状态

complexity gate、source range 和反引号回归落地后，最终验证结果如下。这里把 renderer 结果、外层 sandbox 无法启动的系统 importer，以及仓库既有 IntatisTools 环境失败分开记录，不用一个笼统的“全量通过”掩盖执行边界。

| 检查 | 结果 |
| --- | --- |
| `swift package dump-package` | 通过；iOS/macOS 26 与 target 图解析正常 |
| `swift package resolve` | 通过；五项 SwiftPM 依赖保持精确 pins |
| `swift build --target IntatisSharedUI --scratch-path /private/tmp/intatis-render-build` | 通过 |
| `MessageRenderingTests` | 共 29 项；外层 sandbox 可运行的 28 项为 28/28 通过 |
| `testBundledHighlightJSEngineReturnsTheExactSource` | 唯一无法在外层 sandbox 自动执行的 focused test；AppKit HTML importer helper 不能在该环境启动，不是 assertion failure |
| 排除 IntatisTools 与上述 importer test 的仓库回归 | 546 tests、0 failures |
| 全量测试（跳过上述 importer test） | 633 tests、14 skipped、34 failures（9 unexpected）；全部来自既有 IntatisTools 外层 sandbox 中 `sandbox-exec` / loopback 受限，与本渲染任务无关 |
| `xcodegen generate` | 通过 |
| macOS IntatisMac Xcode build | 通过 |
| generic iOS Simulator Xcode build | 通过 |

29 项 focused test matrix 覆盖：

- 普通 Markdown 原样交给上游；
- inline/display 公式独立路由；
- `$$...$$` 与货币文本不冲突；
- inline、缩进、blockquote/list 嵌套、伪 closing fence 等 CommonMark code 中不识别公式；
- escaped math opener/closer 保持字面语义；
- 容器内 display math 保留 literal，顶层 display math 独立路由；
- 无效与未闭合 TeX 保留可复制原文；
- rendered document 始终保留 raw truth；
- 512 KiB 超限 fail closed；
- 64 公式候选超限 fail closed，重复未闭合 opener 保持有界扫描；
- inline bitmap 像素/尺寸策略拒绝非法或超大分配；
- 流式公式内容变化会产生新的内部 image identity；
- 纯 inline 公式独占段落时仍路由为 math，而非 remote-image blocked；
- 语言别名与未知语言行为；
- highlight.js 输出字符与原始代码完全一致；
- language/source 边界不能碰撞高亮缓存；
- 受上游 issue #4362 影响的 C/C++ grammar 固定 plaintext；
- 单 paragraph 128/129 个 soft/line break 的准入边界；
- 8/9 层 list nesting 的准入边界；
- 4,096 总 AST node、32 depth、256 non-break inline node 与公式预留预算的 fail closed；
- CR-only、LF、CRLF、混合换行的 cmark code range；
- 单行 `CODE` 直接 SOURCEPOS 映射，以及多行 `CODE` 的 `endLine + backtickCount` source-position repair；
- blockquote + list continuation prefix 下，末行公式仍处于 inline-code 保护范围，末端外部公式仍可正常路由；
- fenced、indented、blockquote/list 内 code 的 Unicode source 保真；
- 超长 backtick run、重复未闭合 opener 的线性时间/DoS 回归。

增强后的 `testUnicodeAndMultilineInlineCodeUseCmarkSourceRanges` 同时覆盖根级多行 code span，以及 blockquote + list 容器中被剥离 continuation prefix 的多行 code span；后者对 LF、CR、CRLF 全部执行“末端内部公式保持 literal、外部公式正常识别”的断言。focused test 总数仍为 29，受限环境可运行项仍为 28/28 通过。

`testBundledHighlightJSEngineReturnsTheExactSource` 触发的是 `NSAttributedString` AppKit HTML importer 的系统 helper 路径；Codex 外层 sandbox 阻止 helper 启动，因而不能把它计作自动通过。最新 Computer Use 在真实构建的 app 进程中验证了 Swift / TypeScript 语法颜色与可见 source 字节保真，为该系统 importer 路径提供了产品级证据。

### 9.2 专用离线 fixture

macOS DEBUG app 新增 `-IntatisRendererFixture` 启动参数。fixture 不创建生产 `AppEnvironment`，离线覆盖：

- heading、emphasis、链接、引用、列表、task list、table；
- Swift、TypeScript、未知语言、超长单行和完整代码框；
- inline / display 公式、无效公式；
- 三阶段流式内容；
- remote image blocked；
- light / dark 外观；
- 可确定性 copy override。

### 9.3 最终源码的 Computer Use 结果

已通过 macOS Accessibility tree、可见截图和真实交互验证：

独立审计修复多行 inline-code source-position 后，又用重新构建的最终
`IntatisMac.app` 启动浅色离线 fixture；最新 Accessibility tree 与截图再次确认
Markdown 层级、GFM table、Swift 完整代码框及 sole-inline/display 公式均可见。
下面的深色、Copy、横滚、stream 与 production-root 结果来自同一轮实现的完整
交互矩阵；末次修复只改 cmark 代码范围推导，并已另由 28/28 focused、546/0
隔离回归和双平台重建覆盖。

- 浅色和深色 fixture 都通过视觉与 Accessibility tree 检查；
- Markdown 层级、列表、任务项和 GFM table 可见；
- inline、独占段落的 sole-inline 和 display 公式都由 iosMath 正确绘制，浅色/深色下均无异常底色；
- 无效 TeX 与未闭合公式保留原始反斜杠和定界符，可读、可复制；
- Swift、TypeScript 和 unknown language 都进入独立完整代码框；未知语言回退 plaintext 后仍保持完整框体并左对齐；
- 代码框具有语言栏、Copy 按钮、Menlo 等宽字体、语法颜色和完整原文；
- Copy 真实交互回传哨兵 `END_OF_LONG_LINE`，证明复制源是 raw code；
- 超长代码行不换行，真实横向滚动可以到达行尾哨兵；
- 三阶段 streaming 全部通过：初始文本、未闭合中间态和最终闭合后的代码/公式渲染均可达且无崩溃；
- Markdown 远程图片被 provider 阻断并显示 blocked 状态；
- 不带 `-IntatisRendererFixture` 启动参数的正常主界面 smoke test 通过，期间没有发送 provider 请求。

首轮视觉检查曾发现三个集成问题：inline 公式出现黑底、短代码在双向 ScrollView 中居中、无效 TeX 的反斜杠被 Markdown 吃掉。实现分别改为透明 template image、`.defaultScrollAnchor(.topLeading)` 和展示缓冲区定界符转义；修复后的浅色/深色、公式、未知语言左对齐和定界符保真均已由 Computer Use 复验通过。这也是使用真实 UI/Computer Use 而不只依赖单元测试的直接收益。

当前仍有一个明确的无障碍限制：普通段落中的 inline formula 在 macOS Accessibility tree 中仍显示为 replacement character。独占段落 inline 与 display math 可被识别，但 MarkdownUI 2.4.1 把普通 inline image attachment 拼入 `Text` 后，没有向 AX tree 暴露公式语义；这不是视觉渲染失败，也不能被误写成 inline VoiceOver 已完成。

## 10. 明确的发布门：iosMath 字体许可

iosMath 2.5.0 会把八套 OpenType 数学字体复制进资源 bundle。字体不是 iosMath MIT 源码许可的当然附属物，必须按各自许可证处理：

- 部分字体使用 SIL Open Font License 1.1；
- 部分字体使用 GUST Font License / LPPL 1.3c-or-later；
- 精确字体到许可证的映射已记录在 `ThirdPartyNotices/MathRendering.md`。

当前项目自动准入规则没有把 GUST/LPPL 视为无需确认的普通宽松许可。因此：

> **当前实现选择不构成 `OPEN_SOURCE_REUSE.md` 所要求的明确许可证批准。即使 renderer 验证与 macOS/iOS 构建已经完成，在继续保留 iosMath 用于分发或正式发版前，仍必须由项目负责人明确接受这组字体许可证，或取得法律/合规确认；同时必须在二进制中提供 NOTICE 与字体许可文本。这个门没有因为 iosMath 源码是 MIT 而自动消失。**

如果不能接受 GUST/LPPL，下一步不是重写公式排版引擎，而是评估是否能在不破坏 iosMath 功能与许可证的前提下只分发 OFL 字体，或改用另一套已审计的成熟上游 math engine/font bundle。

## 11. 当前完成度与剩余工作

### 已完成

- 三套 renderer 的核心引擎选型、固定与接入；
- Chat / Code / Cowork 的角色化路由；
- 完整只读代码块，不只是语法高亮函数；
- explicit LaTeX inline/display；
- 流式节流、任务取消、完成态与高亮缓存；
- raw truth、纯文本回退和输入上限；
- 远程图片与危险链接边界；
- exact dependency lock、vendored asset hashes、NOTICE/provenance；
- pinned cmark complexity gate、五项 GFM extension、单行 `CODE` SOURCEPOS 与 `CODE_BLOCK` range；
- 多行 `CODE` 的容器前缀 end-column 修复、LF/CR/CRLF、通用手写 backtick 配对移除和线性 DoS 回归；
- 29 项 focused test 的 28/28 可运行项、546 项隔离回归、双平台构建与最终 Computer Use 验证。

### 发布前仍需完成

1. 明确接受或法律确认 iosMath 字体的 GUST/LPPL 条款。
2. 确认 App Store / Developer ID 最终产物中可访问全部 NOTICE/字体许可。
3. 在 OS 26 真机补做 Dynamic Type、普通 inline math VoiceOver、低内存和 512 KiB 边界压力回归。
4. 若需要完全自动化 AppKit HTML importer test，提供不受 Codex 外层 sandbox 限制的宿主测试环境；当前真实 app 证据已覆盖产品路径。
5. 将 IntatisTools 的既有 `sandbox-exec` / loopback 外层 sandbox 失败作为独立任务处理，不与 renderer 回归混为一谈。
6. 若未来需要单 `$...$`、远程图片或代码执行，分别建立新的产品/安全设计，不在当前 adapter 中隐式打开。

## 12. 最终实现原则

这次落地遵守了用户要求的核心边界：

1. Markdown、代码、LaTeX 是三套独立能力。
2. 三套真正的 parser / grammar / 排版核心都来自成熟开源项目。
3. Intatis 只写消息路由、平台包装、产品 UI、安全策略、流式与缓存接口。
4. 代码交付物是完整代码框；高亮只是其中一部分。
5. 原始消息永远保留为事实源并可整条降级，不被富文本派生状态替换；代码块 Copy 明确复制 raw code source。
6. 依赖引入以实证构建和逐资产许可证审计为准，不因 wrapper 的顶层许可而忽略 bundle 内容。
7. ChatGPT 网页端只作公开行为参考，不声称获得或复制其私有 renderer 源码。

## 13. 本轮项目检查摘要

### MODEL_CHECK_RESULT

Codex，基于 GPT-5；无法确认更细的公开内部变体。

### PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 路径匹配预期：是

### FILES_WRITTEN

本报告记录的是本轮整体实现；实际代码、配置、测试和合规文件清单见第 4、7、9 节。报告文件为：

- `codex-report/07_15_26-chat-markdown-code-latex-rendering-research.md`

### PROJECT_AUDIT_SUMMARY

- renderer 位于 `IntatisSharedUI` 的 UI projection 边界；
- raw EventLog / projection / provider wire payload 未改变；
- iOS 平台仍只链接 Chat 子集；
- Cowork 复用 Code 消息视图，没有新建平行第四套实现；
- 代码 renderer 始终是纯展示，不直接触发工具执行。

### UNCERTAINTIES

- ChatGPT 网页端内部 renderer 技术栈仍未公开，保持 `UNKNOWN`；
- display iosMath 已有 TeX accessibility label；inline attachment 在当前 macOS AX tree 中仍不暴露数学语义，OS 26 VoiceOver/上游可行性需要专项验证；
- GUST/LPPL 字体许可是否获项目明确接受，当前仍是发布 blocker；
- AppKit HTML importer test 受 Codex 外层 sandbox 限制，不能在该环境自动执行；
- 仓库全量测试仍有既有 IntatisTools `sandbox-exec` / loopback 环境失败，但隔离后的非 Tools、非 importer 546 项为 0 failures；
- 最终商店/Developer ID 包如何展示第三方 notices，需要在发行流程中确认。

### NEXT_RECOMMENDED_ACTION

renderer 源码、相关自动化、双平台构建与最终 Computer Use 已收敛。下一步优先关闭 iosMath 字体许可证与二进制 NOTICE 展示两个发布门，并专项验证普通 inline math 的 VoiceOver 限制；IntatisTools 的外层 sandbox 失败应另开任务，不阻塞本渲染实现的事实记录。
