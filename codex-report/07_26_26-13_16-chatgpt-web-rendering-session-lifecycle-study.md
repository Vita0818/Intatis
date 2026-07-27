# ChatGPT Web 渲染与 Session 生命周期研究

## MODEL_CHECK_RESULT

当前执行环境显示为 GPT-5 系列 Codex Agent；会话内无法确认更细的服务端模型变体，故精确型号记为 `UNKNOWN`。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 结果：两者一致，符合项目预期根目录。
- 写入前已识别现有用户改动：`NOTICE.md`、两份既有 `codex-report`、`docs/CURRENT_STATE.md`、`docs/PROJECT_MAP.md` 与未跟踪的 `Experiments/`。本报告不覆盖、回退或整理这些改动。

## FILES_WRITTEN

- 新增：`codex-report/07_26_26-13_16-chatgpt-web-rendering-session-lifecycle-study.md`
- 新增：`Experiments/WebRendererParity/src/components/ConversationPane.tsx`
- 新增：`Experiments/WebRendererParity/src/components/DiagnosticsPanel.tsx`
- 新增：`Experiments/WebRendererParity/src/components/ViewportMessage.tsx`
- 新增：`Experiments/WebRendererParity/src/session/types.ts`
- 新增：`Experiments/WebRendererParity/src/session/sessionFixtures.ts`
- 新增：`Experiments/WebRendererParity/src/session/ThreadResidencyStore.ts`
- 新增：`Experiments/WebRendererParity/src/conversation.css`
- 新增：`Experiments/WebRendererParity/tests/app.lifecycle.test.tsx`
- 新增：`Experiments/WebRendererParity/tests/threadResidency.test.ts`
- 修改：`Experiments/WebRendererParity/src/App.tsx`、`main.tsx`、`sample.ts`
- 修改：`Experiments/WebRendererParity/src/renderer/CodeBlock.tsx`、`MathRenderer.tsx`
- 修改：`Experiments/WebRendererParity/index.html`、`README.md`、`INTEGRATION_ASSESSMENT.md`
- 修改：`Experiments/WebRendererParity/tests/renderer.contract.test.tsx`
- 修改：`docs/CURRENT_STATE.md`、`docs/PROJECT_MAP.md`、`docs/TESTING.md`
- 未修改或接线：`Apps/`、`Packages/`、`Vendor/`、`Package.swift`、`project.yml`、`Makefile`、`docs/NEXT_TARGET.md`

## 研究目的与结论

本轮研究的问题不是“网页 Markdown 能不能显示”，而是：

1. ChatGPT Web 在 Markdown、数学和代码渲染中，哪些对象真正长期存在；
2. session 切换时，页面、路由、查询缓存、React 树和 CodeMirror 如何释放或短时保温；
3. 这些行为对 Intatis 现有 native renderer 与进程级 session runtime 有什么可验证的启示；
4. 当前独立 `Experiments/WebRendererParity` 是否已经适合直接嵌入 Intatis App。

结论如下：

- **直接把当前 Web 实验接入 Intatis App：NO-GO。** 它会新增 WKWebView/WebContent、npm 供应链、Swift↔JavaScript bridge、辅助功能、焦点、选择、复制、滚动、进程回收和 EventLog 续订等尚未收口的生命周期面。现有页面与短时测量不是生产或发布证据。
- **把 renderer kernel 的行为合同作为参考：可行且有价值。** 值得借鉴的是“单一可见 renderer root、带 generation 的切换取消、旧树 unmount ACK、短时 warm residency、明确 hibernate/seq resume、视口分页、重型代码编辑器按需存在、按字节计的缓存预算和压力回收”，而不是复制 ChatGPT 的代码、样式或产品结构。
- **Intatis production 仍应保持 native。** 当前生产链仍是 `IntatisMessageContentView` → `IntatisMicrosoftMarkdownPipeline` → vendored `SwiftStreamingMarkdown` / iosMath，加永久保留的 `.plainSafe` 熔断。本报告不改变该架构。
- **`docs/NEXT_TARGET.md` 不变。** 当前 active follow-up 仍是 Cowork replacement-history compaction checkpoint + resume reconstruction；本研究不把 Web renderer 提升为新的业务源码目标。

## 证据分层与阅读规则

以下五层证据不能互相冒充：

1. **直接 live DOM / process 观察**：本轮对正在运行的公开 Web 产品页面做的 DOM、AX、heap 和 WebContent 进程抽样。
2. **当前公开 Web bundle 代码观察（build-specific）**：对当时公开下发的构建产物做行为级阅读。标识符、常量和控制流只对该 build 成立，不是公开 API，也不是长期产品合同。
3. **Intatis 本地源码审计**：直接读取当前工作树中的 Swift 与独立实验源码。
4. **推论**：由前述证据组合得出的设计解释或风险判断。
5. **UNKNOWN**：没有足够证据确认的实现、所有权或长期资源行为。

文中使用匿名样本 `A`、`C`，不记录真实会话 ID、账号标识、token、cookie、请求头或私密消息正文。对公开 bundle 只描述观察到的结构和行为，没有复制其源码、样式、品牌、Logo、图标、截图、prompt 或资产。

## ① 直接 live DOM / process 观察

### 1. Markdown、数学与代码的可见结构

在本轮抽样 build 中，完成态消息表现出三类不同成本的子树：

- 普通 Markdown 最终进入结构化 DOM，而不是把整段结果留成一个纯文本节点。
- 数学公式可见为 KaTeX 生成的 HTML 表现层，同时保留 MathML 语义层。页面上“看见一条公式”并不意味着只存在一个 DOM 节点；数学密集消息会显著放大 DOM 数。
- fenced code 的完成态可以生成 CodeMirror 编辑器视图。CodeMirror 不只是静态高亮 HTML，它拥有 editor view、语言支持、测量与选择等更重的生命周期。

流式代码尾部的可见行为与“每个 token 都重建完整 CodeMirror”不同：最新、尚未稳定的尾部可先保持轻量状态，等尾部稳定或消息完成后再进入完整编辑器表现。直接观察能证明状态会转换，但不能仅靠 DOM 外观证明内部一定采用了哪种增量语法树或缓存算法。

### 2. Session 切换：outer main 复用，旧消息 DOM disconnect

在 A→C→A 一类切换中，浏览器复用同一个 WebContent renderer
process，页面的 outer `main` 也保持同一个 DOM 元素；变化发生在会话内容子树。
保存的旧消息 DOM 引用在离开 session 后变为 `isConnected == false`，说明旧消息
节点从当前 document 断开，而不是把多个 session 的完整消息树同时藏在同一个
可见 root 下。

这项观察支持“路由壳复用、会话子树 unmount/remount”的解释，但不等于其所有 JavaScript 对象、查询数据、编辑器状态或闭包已经被垃圾回收。DOM disconnect 只是必要条件，不是内存释放证明。

### 3. 测量表

以下数字是一次受控抽样的现场值，计数口径保持一致，但不是发布门：

| 样本 | DOM 节点 | turns | `<pre>` | math | CodeMirror | JS heap | AX 节点 |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 5,071 | 2 | 2 | 101 | 1 | 约 100.97 MB | 749 |
| C | 1,654 | 2 | 24 | 0 | 12 | 约 103.38 MB | 362 |

观察：

- A 的数学节点远多于 C，DOM 总量也明显更高。
- C 虽然 DOM 总量较低，却有 12 个 CodeMirror；其 JS heap 反而略高于 A。这说明“DOM 少”不能直接等价为“内存低”，重型编辑器、语言包和 JS 对象图可能占主导。
- A/C 的 AX 计数在连续 3 轮切换/读取中分别稳定在约 749 / 362，未在短时切换中持续递增。它只能说明当时可访问性树没有明显按切换次数叠加，不能证明后台对象已全部释放。
- 从 A 切到明显更小的 C 时，DOM 会立刻缩小，但 JS heap / WebContent RSS
  没有义务同步下降。这与 disconnect 只表示“退出 document”、GC/allocator
  回收另有时机的模型一致。

### 4. WebContent RSS 观察

同一轮研究中记录到的 WebContent RSS 近似值如下：

| 阶段 | WebContent RSS 观察 |
|---|---:|
| 初始重内容阶段 | 约 432 MB |
| 切换并出现释放后的低点 | 约 258 MB |
| 后续重内容/重新活跃阶段 | 约 468 MB |
| 一段 idle 后 | 约 431 MB |
| reload 后 | 约 245 MB，但该次页面为空白 |

这些数值只说明资源可以下降、重新上涨，并且 reload 可能重建 WebContent 状态。它们**不是泄漏证明，也不是无泄漏证明**：

- 浏览器 GC、WebContent allocator、字体、JIT、共享资源和进程复用会造成高水位与延迟回收；
- 进程 RSS 不能精确归因到单个 session；
- reload 约 245 MB 的那次页面为空白，不能作为“正确恢复后的稳定基线”；
- 采样窗口远短于长期 session 使用，没有形成 plateau 统计。

## ② 当前公开 Web bundle 代码观察（build-specific）

### 1. Markdown：unified → HAST → React

当前公开 build 可观察到的总体方向是：

```text
Markdown source
  → unified / remark 风格的语法处理
  → HAST 风格的 HTML 抽象树
  → React 元素/组件
  → DOM
```

该链路解释了为何标题、列表、表格、链接、公式和代码可以在最终树中拥有不同组件生命周期。这里描述的是该 build 的结构性行为，不声明 ChatGPT 永久使用某个固定包版本，也不把其内部实现视为 Intatis 可复制源码。

流式 Markdown 另有一层 build-specific 保护：

- components 与 remark/plugin 配置被 memoize，避免在每个增量重新生成不必要的
  identity；
- streaming registry 在 turn/message unmount 时明确清理对应 map entry；
- 对未闭合 fence、directive、emphasis 和 link 等尾部做有限修补，而不是假设每个
  token 都已经是完整 Markdown；
- 当次 bundle 可见的启发式阈值包括 complex suffix `240`、full source
  `1,200`、full word segments `180` 与 suffix `480`。这些数字只描述抽样 build，
  不是稳定协议，也不应原样写进 Intatis production 常量。

### 2. 数学：KaTeX HTML + MathML

该 build 的公式输出同时包含：

- 用于视觉排版的 KaTeX HTML；
- 用于语义和辅助功能的 MathML。

因此数学密集会话的 DOM/AX 成本需要分别测量。只统计公式数量、只统计 `<span>`，或只看视觉截图，都不足以描述真实对象规模。

### 3. CodeMirror 生命周期与流式尾部

bundle 观察与 live DOM 一致地指向两阶段思路：

- 稳定的 fenced code 可以拥有完整 CodeMirror view；
- 流式尾部不必在每个增量都同步升级成完整编辑器，可保留较轻的 tail，稳定后再 settle；
- session 子树 unmount 后，旧 CodeMirror 所属 DOM 会断开；当次组件 cleanup
  会调用 `destroy()` 并清理 view 级资源；
- 已动态载入的 language module 仍可能留在同一个 JavaScript realm；销毁
  EditorView 不等于卸载 grammar 代码；
- 快速切回时 editor 可能重新创建，或由更上层 warm thread 数据重新投影。

本轮没有取得足够证据证明其 Lezer tree、语言扩展、EditorState 或 view plugin 的具体复用粒度，因此这部分更细的内部对象所有权仍是 `UNKNOWN`。

### 4. 查询缓存：`conversation/init` 的 `gcTime = 0`

在该 build 中，`conversation/init` 查询可观察到 `gcTime = 0` 与
`refetchOnMount = always`。这不等于“用户一离开路由，整个会话立即释放”：

- `gcTime = 0` 表示查询一旦真正变为 unused，就可以立即进入回收；
- route unmount 会 invalidate 该 query；它不是 30 秒 resident data 的主要
  所有者；
- 约 30 秒的 warm 行为来自另一层 retained thread tree，而不是把
  `conversation/init` query cache 的 `gcTime` 偷换成 30 秒。

### 5. Route retain/unmount、invalidate、`releaseThread`

该 build 的会话导航是 SPA / React Router 风格的 history
`push` / `replace`，不是每次切 session 都做 document reload。可见的关键机制可
概括为：

```text
进入 thread route
  → retainThread
  → 若有该 thread 的待删除 timer，则取消

离开 thread route
  → unmount 当前会话子树
  → invalidate conversation/init query
  → releaseThread
  → releaseThread 安排约 30 秒后的 thread-tree 删除

30 秒内快速切回
  → retainThread 取消对应删除 timer
  → 保留/恢复该 thread tree 的 warm 状态

timer 到期且仍未返回
  → 删除 retained thread tree
```

这个顺序同时解释了两个表面上矛盾的观察：

- 旧消息 DOM 可以在路由离开时立即 disconnect；
- retained thread tree 仍可保温约 30 秒，快速切回不必立刻做完整冷恢复；
- `conversation/init` unused query 则可按 `gcTime = 0` 立即 GC，两层不能混写。

30 秒是本轮 build-specific 观察，不应被当成跨版本承诺，更不能直接复制成 Intatis 的永久常量。它体现的是“短时 warm residency + 可取消延迟释放”策略。

### 6. 历史分页与可见性基础设施

当次 build 存在 older-history pagination sentinel 与基于
`IntersectionObserver` 的可见性感知基础设施。这证明页面具备按历史边界/可见性
驱动工作的能力，但没有足够证据确认所有消息类型都进入了完整的 DOM
virtualization，也没有确认其 overscan、placeholder、selection/scroll-anchor
策略。故“有分页/observer”是直接证据，“全列表已虚拟化”仍是 `UNKNOWN`。

## ③ Intatis 本地源码审计

### 1. `AppSessionRuntimeManager`：精确缓存，但无 LRU / TTL / hibernate

`Apps/IntatisMac/Sources/SessionRuntimeManager.swift` 当前按 session 类型分别保存：

- `chatRuntimes: [SessionID: AppChatSessionRuntime]`
- `codeRuntimes: [SessionID: CodeViewModel]`
- `coworkRuntimes: [SessionID: CoworkSlot]`
- 以及统一的 `entries`、观察订阅和展示状态字典。

已存在的 Chat/Code/Cowork runtime 会按 exact session key 复用；只有显式删除、应用 shutdown 或创建失败路径会移除。当前没有：

- 最大 runtime 数；
- LRU；
- idle TTL；
- hibernate 状态；
- 按 session 字节预算；
- memory pressure 驱逐策略。

这符合 Phase L “切 session/关窗口不停止后台 runtime”的产品合同，但也意味着用户依次打开越来越多 session 时，runtime、projection、订阅和其他内存状态可持续驻留。**生命周期正确不等于驻留规模有界。**

### 2. View 按 presentation scope 重建

Code/Cowork 使用 exact `IntatisThreadPresentationScope(kind, sessionID)`，根 thread 通过 `.id(presentationScope)` 建立身份。切 session 会销毁旧可见 ScrollView / row / renderer facade，再为目标 session 创建新树；业务 runtime 仍由 manager 保留。

Chat 也用 session identity 重建其页面内容，但当前滚动实现与 Code/Cowork 不同，见下文风险。

该结构的优点是旧 view scope 不会污染新 session。成本是：**回到缓存 runtime 可避免重新创建业务 runtime，不等于可见 rows 和 Markdown documents 被缓存。** rows 重建后，重新进入视口的消息会重新走 renderer admission/parse/publish。

### 3. Renderer `onDisappear` 明确释放 document

`Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift` 的生命周期 gate 在：

- `onAppear` 调用 `activate`；
- `onDisappear` 调用 `deactivate`；
- `deactivate` 同时关闭 rich state 与 raw state，并清除 last input。

当前没有 completed-document cache 或 paragraph native-view cache。这是防止不可见历史继续持有 native document/view graph 的重要边界；也意味着 session 重入时，消息 rows 可能重新解析。

现有限额包括：

- rich admission：单消息 UTF-8 ≤64 KiB；
- process-wide Markdown parse concurrency = 1；
- pending message key ≤32；
- 每 view latest-only request；
- incomplete parse debounce = 50 ms；
- raw projection throttle = 100 ms；
- 单消息公式 ≤32 个，单公式 UTF-8 ≤8 KiB；
- 顶层可见行 `<= 4` 用 eager，`>= 5` 用 lazy。

这些限额控制的是单次消息和 parser 背压，不是 session runtime 总量、EventLog 订阅队列、可见历史条数或多 session 缓存字节。

### 4. EventLog `AsyncStream` 默认 unbounded

`Packages/IntatisConversation/Sources/EventLog.swift` 的 `stream(from:)` 通过无参数 `AsyncStream.makeStream()` 创建 stream；未指定 buffering policy 时是默认 unbounded buffering。

活跃消费者正常追平时不一定形成问题，但以下组合值得警惕：

- runtime 被 manager 长期保留；
- session 不可见但仍订阅；
- projection consumer 因主线程、渲染、工具或 shutdown 竞争而变慢；
- 后台 provider/agent 继续快速追加事件。

如果未来引入 hibernate，不能只隐藏 view；必须明确取消订阅并记录 resume seq，恢复时走 checked catch-up。否则“不可见但仍活跃”的 unbounded stream 可能把 session retention 转成队列 retention。

### 5. Chat scroll 仍有无 owner 的 async/animation

`Apps/IntatisMac/Sources/IntatisChatScreen.swift` 当前 `scrollToBottom` 使用：

- `DispatchQueue.main.async`
- 可选 `withAnimation`
- 静态 bottom anchor。

该闭包没有 Code/Cowork `IntatisThreadScrollCoordinator` 那种 exact scope + generation + cancel 复核。页面 `.id(session)` 能销毁旧树，但无法从源码上证明已经排队的 main-queue closure 一定不会在切换边界参与旧 proxy/animation 工作。它也是未来做统一 switch-generation 协议时应优先收口的地方。

### 6. Cowork 首开并发

`AppSessionRuntimeManager.coworkRuntime` 对**同一个 session**有 `.creating(generation, task)` single-flight，能阻止相同 key 重复创建；但不同 session 的创建 task 没有全局并发上限。快速依次打开多个未缓存 Cowork session 时，严格 replay、settings/roster/lease 恢复、workspace scope、reviewer/Goal 对账等首开工作可以跨 session 重叠。

这不表示当前已复现泄漏；它表示“per-key single-flight”不能替代“cross-session warm/admission budget”。

### 7. 历史 retaining edge 仍是 `UNKNOWN`

2026-07-18 renderer GUI 事故曾抽样看到 footprint 约从 109 MB 增至
803 MB，但最终 retaining edge 仍未通过 malloc stack/heap graph 确认。后续修复
与短时单实例验证证明若干失控路径已被收紧，但不能据此把历史根因归到
parser、SwiftUI、TextKit、selection、session manager 或某一个依赖。

任何 WebView/React/CodeMirror 集成都将新增另一套对象图，不能用“WebContent 可独立回收”替代 native retaining-edge 诊断，也不能用本轮短时 Web 观察宣布 Intatis 已无生命周期风险。

## ④ 推论

### 1. ChatGPT 的关键收益来自分层释放，不只是 React

本轮最有价值的行为不是某个 Markdown 包，而是把不同层分开：

- outer app shell 可长期存在；
- 当前 session 的消息 DOM 可以立即 unmount；
- retained thread tree 可以短时 warm，而 unused `conversation/init` query 可立即
  GC；
- warm timer 可在快速切回时取消；
- route unmount 先 invalidate query 并调用 `releaseThread`，timer 到期后删除
  retained thread tree；
- 查询层在真正 unused 后可立即 GC。

Intatis 当前是“runtime 长驻 + view scope 重建 + document onDisappear 释放”，已经具备其中两层，但缺少介于“永久 runtime”与“完全 shutdown”之间的 hibernate/TTL 层。

### 2. DOM 节点数与 heap/RSS 必须联合解释

A 的 DOM/数学明显更多，C 的 CodeMirror 更多，而两者 heap 接近。这说明未来诊断至少要同时记录：

- visible/retained message 数；
- DOM 或 native view 数；
- math node / attachment 数；
- CodeMirror / native paragraph 数；
- parser/editor cache bytes；
- JS heap / native heap / WebContent RSS；
- EventLog subscriber 与 buffered event 数；
- session runtime 数及状态。

单看 RSS、DOM、消息数或 parser backlog都会误判。

### 3. “热 runtime”与“热 renderer”应分开预算

业务 runtime 的 warm 价值是避免重新恢复 provider、task、projection、permission、workspace scope；renderer 的 warm 价值是避免重建当前视口附近的重型 Markdown/math/code view。二者不应通过“保留整个 session 所有东西”捆绑实现。

更合理的策略是：

- runtime 可处于 active / warm / hibernated；
- renderer 只保留当前可见 root，最多保留少量最近 session 的轻量 viewport snapshot；
- completed document/editor cache 按字节、session、语言包统一预算，而不是按对象个数无限累积。

## ⑤ UNKNOWN

以下事项没有被本轮证据确认：

- ChatGPT Web 使用的 React、unified/remark、CodeMirror、Lezer 等全部精确版本及其长期 API；
- build 中 `retainThread` / `releaseThread` 和 30 秒 timer 在所有账号、实验
  cohort、页面类型和未来版本中是否一致；
- timer 到期后所有 JS 对象、CodeMirror state、语言包、字体、KaTeX cache 是否立即可回收；
- ChatGPT 是否对长会话使用完整虚拟化、分段 DOM、离屏缓存或服务端摘要，以及具体阈值；
- A/C heap 数字在强制 GC、长期 idle、更多切换后的稳定平台；
- WebContent RSS 中各 session、字体、JIT、共享资源和浏览器框架的精确归因；
- reload 后空白页面约 245 MB 是否能在正确内容恢复后保持；
- Intatis 历史 renderer 事故的最终 retaining edge；
- Intatis 在 3/10 个 session、50/1,000 条消息和真实后台 provider 工作下的长期 plateau；

## ChatGPT Web、现有 Web 实验与 Intatis native 对比

| 维度 | ChatGPT Web（本轮 build 观察） | `Experiments/WebRendererParity` | Intatis native production |
|---|---|---|---|
| 产品地位 | 公开 Web 产品现场 | source-tree-only 行为实验 | 当前正式产品路径 |
| Markdown | unified/remark 风格 → HAST → React | React/Vite +公开依赖的独立复现 | vendored `SwiftStreamingMarkdown` derivative |
| 数学 | KaTeX HTML + MathML | KaTeX HTML + MathML 行为实验 | iosMath + TextKit 2 live attachment |
| 代码 | CodeMirror，流式尾部延迟 settle | read-only CodeMirror，独立 tail 实现 | 当前原生代码块，无 production 语法高亮 |
| session DOM/view | outer main 复用，旧消息 DOM disconnect | outer shell 复用，exact-generation message subtree disconnect；单一可见 root | presentation scope 切换重建 view |
| 数据保温 | `releaseThread` 安排约 30 秒 thread-tree 删除；retain 可取消 | 30 秒可取消 warm metadata；最多 2 个 inactive sample resident | runtime 持续缓存，无 LRU/TTL |
| 不可见状态 | route unmount 先 invalidate query / `releaseThread`；timer 后删 thread tree | newest 12、older 10 pagination；900 px overscan 外卸载 rich child | renderer `onDisappear` 释放 document；runtime/subscription 仍在 |
| 查询/事件 | `conversation/init gcTime=0` 与 route retain 配合 | 无 Intatis EventLog bridge | EventLog canonical；live `AsyncStream` 默认 unbounded |
| 压力控制 | WebContent/浏览器自身策略，细节 UNKNOWN | 36 次 UI stress；harness 最多 1,000 次；DOM/editor/math cache/grammar diagnostics | parser 有限额；session/runtime 总量无 budget |
| 可直接接 App | 不适用 | **NO-GO** | 是 |

## 本轮独立实现页

本轮已经把 `Experiments/WebRendererParity` 增强为**独立实验原型**，没有接入
产品：

- 3 个完全合成、脱敏的 session fixture，每个 16 条消息，分别覆盖 Markdown、
  LaTeX 和代码；
- outer `[data-lab-main]` 保持，active message subtree 以
  `{sessionID, generation}` key 完整替换；单测保存旧引用并确认
  `isConnected === false`；
- `ThreadResidencyStore` 把旧 session 保温 30 秒；切回取消旧 timer，超时/
  `Release warm` 删除 metadata，true switch 才增加 generation/switch count；
- 首屏只 mount 最新 12 条，`Load older` 每次加 10 条；每条消息在 900 px
  root margin 之外卸载 Markdown/KaTeX/CodeMirror child，保留测量高度的
  placeholder；
- session switch 先取消当前 local streaming generation；代码流在同一个
  EditorView 中只插入 append suffix，同内容不发 change，非 append 才 full
  replace；
- CodeMirror unmount 会 `destroy()` view、timer 与异步 request generation；
  React root 被显式持有并在 `beforeunload` 时 `unmount()`；
- KaTeX cache 同时限制为 256 entries 与约 512 Ki characters；它仍是
  renderer-realm 共享 cache，不是 per-session cache；
- 动态 import 的 grammar 可能继续留在 JavaScript realm，因此诊断同时展示
  active EditorView、`.cm-editor` DOM 与 loaded grammar 名，避免把 editor
  teardown 冒充 module unload；
- `Stress switch` UI 默认 36 次、可中止，bounded harness 最多 1,000 次；
  snapshot 只返回
  脱敏 session ID、generation/residency 与数量，不返回消息正文、parser 或
  Intatis 数据。

实现继续保留以下边界：

- 这是 behavior lab，不是 ChatGPT 克隆；
- 不复制 ChatGPT 代码、样式、品牌、Logo、截图、prompt 或资产；
- 不记录真实会话 ID、token、cookie、请求或私密文本；
- 页面测量不是 Intatis production 或 release 证据；
- npm 依赖只属于实验目录，不进入 SwiftPM、XcodeGen 或 App bundle。

它还没有实现真正的 10-session / 1,000-message 数据集、跨 realm pressure
recycle、selection/focus/scroll-anchor 恢复、cache per-session byte budget 或
EventLog seq resume；这些仍属于下面的 production 建议和未来压力矩阵，不能把
当前 3×16 fixture 称为长期 memory plateau。

## 推荐的 Intatis 生命周期模型

### 1. 一个可见 WebView / renderer root

若未来继续评估 Web renderer，只允许每个窗口一个可见 WebView/renderer root。session 切换应替换该 root 的内容，而不是为每个 session 永久保留一棵 WebView/React/CodeMirror 树。

即使继续保持 native，也可采用同一所有权原则：一个窗口一个可见 thread root，session runtime 与 renderer tree 分离。

### 2. Switch generation 协议

建议把切换实现为显式状态机：

```text
switch requested
  → increment switchGeneration
  → cancel old parse / scroll / stream / bridge work
  → request old renderer unmount
  → await unmount ACK for the same generation
  → snapshot old viewport + lastAppliedSeq
  → mount target session viewport
  → reject every stale callback from older generations
```

关键点：

- `cancel` 不等于已经释放，必须有 unmount ACK；
- ACK 必须绑定 exact session + generation；
- mount 之前不能让旧 scroll/animation/CodeMirror callback 命中新 root；
- 超时应 fail closed 到回收/重建，而不是同时保留两棵未知状态的 renderer tree。

### 3. Active + 1–2 warm，TTL + LRU

建议默认：

- 1 个 active session；
- 最多 1–2 个 warm session；
- warm session 有短 TTL，可从 30 秒开始做实验，但必须以 Intatis 自己的压力数据决定；
- 超预算时按 LRU 先 hibernate 最旧 idle session；
- busy runtime、pending permission、active Goal/turn 的驱逐规则必须与 Phase L 合同分开设计，不能无条件 shutdown。

### 4. Hibernate：unsubscribe + seq resume

hibernate 不能只是隐藏 UI。至少要：

1. 取消 EventLog live subscription；
2. 记录 `lastAppliedSeq` 与可重建 projection checkpoint；
3. 释放 renderer document/editor/view；
4. 保留必要的 durable identity，但不保留 unbounded live buffer；
5. resume 时先登记目标 seq 后的 stream，再做 checked catch-up；
6. 对 seq gap、unknown future event、wrong session 或 WAL/read failure fail closed；
7. catch-up 后才允许新 live publication。

该方向应复用现有 Chat strict snapshot/catch-up 经验，不能另造第二事实源。

### 5. 分页 / 虚拟化

长 session 不应在进入时把 50–1,000 条消息全部变成同时活跃的 rich renderer：

- 首次只 mount 当前视口和少量 overscan；
- 向上滚动时分页读取历史；
- 离屏消息保留 raw/projection metadata，不保留 document/editor view；
- 滚动锚点使用 stable message identity + measured correction；
- pagination 与 live tail 必须按 seq 合并，不能重复或跳过；
- fast switch 时取消旧 session 的分页请求。

### 6. CodeMirror 只在近视口或流式活跃块存在

CodeMirror 应限制为：

- 近视口完成代码块；
- 当前流式活跃代码块；
- 用户明确聚焦/选择的块。

离屏完成块退化为可选择的轻量 code projection；重新进入近视口再创建 editor。流式尾部应保持 latest-only，不对每个 token重建语言扩展或完整 editor view。

### 7. Cache 按字节 / session / language 预算

需要同时限制：

- 总 cache bytes；
- 单 session bytes；
- 单文档/代码块 bytes；
- 活跃语言包/grammar 数；
- math render cache bytes；
- warm session 数；
- CodeMirror instance 数。

计数上限不能替代字节上限；“256 个小对象”和“256 个大文档”不是同一风险。超限时优先释放不可见 editor/document，再释放 warm session。

### 8. Memory pressure recycle

发生系统 memory pressure、WebContent 异常增长、unmount ACK 超时或诊断超门时：

- 先 hibernate warm sessions；
- 释放不可见 cache；
- 若仍不下降，回收并重建 renderer/WebContent；
- 以 EventLog `lastAppliedSeq` 恢复；
- 不把 reload 成功等同于内容恢复成功；
- 恢复失败显示可行动错误，并保留 `.plainSafe` native fallback。

## 压测设计与 plateau 判据

### 矩阵

至少覆盖：

| 维度 | 值 |
|---|---|
| 切换次数 | 500、1,000 |
| session 数 | 3、10 |
| 每 session 消息数 | 50、200、1,000 |
| 内容类型 | 纯文本、Markdown 表格、数学密集、代码密集、混合 |
| 状态 | completed、live streaming、后台 provider/agent 活跃、idle |
| 操作 | A→B→C 循环、随机切换、30 秒内快速切回、TTL 到期后冷回 |
| 压力 | 正常、memory pressure、renderer recycle、App 前后台 |

### 必记指标

- runtime 状态数：active / warm / hibernated；
- EventLog subscriber 数、每 subscriber buffered event 数、lastAppliedSeq；
- visible/retained message rows；
- native document / paragraph / math attachment 或 DOM/math node；
- CodeMirror/editor 数；
- parser pending/running；
- cache bytes（总量/每 session/每语言）；
- app RSS/footprint、WebContent RSS、JS/native heap；
- switch、unmount ACK、mount、catch-up latency；
- stale callback、seq gap、重复/漏消息、错误恢复次数。

### Plateau 判据

正式压测前应冻结门，不得看完结果再挑阈值。建议至少满足：

1. warm-up 后，在相同 active/warm 集合下，live DOM/native view、CodeMirror、subscriber 和 cache 数不随累计切换次数增长；
2. 每次 TTL 到期后，旧 session 的 renderer root/editor/document 均不可达或已销毁，subscriber 数回到 active + warm 策略允许值；
3. 500→1,000 次区间的 settled RSS/heap/cache 回归斜率不显著为正；可预先采用“每 100 次增长小于初始 settled baseline 的 1%，且置信区间包含零”作为候选门，但必须先用多轮噪声数据校准；
4. 3→10 session 时，steady-state 资源由 active + warm + budget 决定，而不是由历史访问 session 总数决定；
5. 50→1,000 消息时，同时活跃 renderer 数由 viewport/overscan 决定，历史消息增长主要体现在可分页的 durable/raw 数据，不体现在 editor/document 常驻数；
6. recycle 后能恢复正确内容与 exact seq，不接受“RSS 下降但页面空白”；
7. 所有 stale generation callback 为零，最终内容、顺序和复制 source exact；
8. 测试结束后无残留 WebContent、validation App、timer、EventLog subscriber 或后台 parser task。

本轮 A/C、AX 与 WebContent 数值没有满足上述矩阵，因此只能作为设计输入，不能标成 plateau pass。

## PROJECT_AUDIT_SUMMARY

- ChatGPT Web 的 observable renderer 分为 Markdown AST/HAST/React、KaTeX HTML+MathML 和 CodeMirror 三类不同对象图。
- session 切换复用 outer main，但旧消息 DOM 会 disconnect；当前 build 在
  unmount 时 invalidate query 并调用 `releaseThread`，后者用约 30 秒可取消
  timer 把“立即 unmount view”和“延迟删除 retained thread tree”分开。
- `conversation/init gcTime=0` 让 truly-unused query 可立即 GC；它不是 30 秒
  resident data，短时 warm 的所有者是 retained thread tree。
- Intatis 当前保留 exact session runtime，但没有 LRU/TTL/hibernate；view/document 会按 scope 与 `onDisappear` 释放，重入会重新创建 rows/解析。
- EventLog live stream 默认 unbounded；未来 hibernate 必须 unsubscribe + seq resume。
- Chat scroll 仍有未绑定 generation 的 main-queue async/animation；Cowork 对同 key首开 single-flight，但跨 session 可并发。
- 当前 Web 实验已实现 3×16 synthetic lifecycle lab、30 秒 warm metadata、
  viewport/pagination、suffix-only code update 与显式 diagnostics；它不适合
  直接接 App，native production 和 `NEXT_TARGET` 均保持不变。

## VALIDATION_RESULT

- `pwd` 与 `git rev-parse --show-toplevel`：均为
  `/Users/vita/Vitemis/Intatis`。
- `npm test`：4 test files，**46 tests / 0 failures**。
- `npm run licenses`：266 packages，`rejected = []`。
- `npm run build`：TypeScript project build 与 Vite production build 通过；
  main JS 约 941.04 kB minified / 290.19 kB gzip，另有 lazy grammar chunks 与
  KaTeX fonts；Vite 保留 >500 kB chunk warning。
- `npm run dev`：已在 `127.0.0.1:4173` 启动，监听范围没有扩大到局域网。
- `curl --fail http://127.0.0.1:4173/`：成功返回 lifecycle lab HTML。
- `git diff --check`：通过。
- `git status --short`：确认实验仍在 `Experiments/` 独立目录，报告为新文件，
  项目文档只更新 `CURRENT_STATE` / `PROJECT_MAP` / `TESTING`；未接入
  production target。
- 自动化明确证明 outer shell identity、old subtree disconnect、warm timer
  cancellation/eviction、pagination、stream generation cancellation、
  CodeMirror teardown 与 math-cache bound。未对新 lifecycle 页面做手工浏览器
  验收。
- **未运行 Swift build/test**：本轮没有修改 `Apps/`、`Packages/`、`Vendor/`、
  manifest 或生产 renderer；独立网页测试不能替代 native/release 验证。

## UNCERTAINTIES

- 公开 Web bundle 的观察只对本轮 build 成立，非稳定 API。
- 所有真实会话标识、token、cookie 和私密正文均未进入报告，因此无法在报告中提供可复现账号级 fixture；这是刻意的安全边界。
- WebContent RSS 与 JS heap 没有长期、强制 GC、分进程精确归因；不能据此证明或排除泄漏。
- reload 后低 RSS 对应空白页面，未证明正确恢复。
- ChatGPT 内部完整虚拟化、缓存字节预算、CodeMirror state/grammar 复用和服务端 thread retention 仍为 `UNKNOWN`。
- Intatis historical renderer retaining edge 仍为 `UNKNOWN`。
- Intatis 尚未实现或验证本文提出的 LRU/TTL/hibernate、subscriber resume、viewport pagination、pressure recycle 与 500–1,000 次 plateau。
- 并行 Web 实验增强的最终代码/测试结果由主 Agent 最终验证决定；本报告不把目标原型写成生产事实。

## NEXT_RECOMMENDED_ACTION

1. 保持已经完成的 Web lifecycle lab 独立，用它继续扩展确定性 fixture/soak，
   不接 App。
2. 在 native Intatis 单独设计 `active / warm / hibernated` runtime 状态、LRU/TTL、EventLog unsubscribe/seq-resume 和 cache byte budget；不要把 WebView 集成与 native runtime 收口合成一次大改。
3. 先收口 Chat scroll generation/cancel，再做 3/10 session、50–1,000 messages、500–1,000 switches 的单实例压力基线。
4. 只有在 plateau、辅助功能、复制/选择、bridge、安全、bundle/许可证、pressure recycle 与正确恢复全部有证据后，才重新评估 WKWebView renderer；在此之前结论保持 NO-GO。
5. 项目 active target 继续执行 `docs/NEXT_TARGET.md` 中的 replacement-history compaction，不因本研究自动改向。
