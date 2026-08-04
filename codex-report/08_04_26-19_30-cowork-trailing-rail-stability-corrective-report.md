# Cowork trailing rail 稳定性第三版修正报告

日期：2026-08-04  
范围：macOS Cowork 宽屏右侧 Agents / Goal / Tasks / Permission 液态玻璃卡片  
状态：源码修正与自动化验证完成；真实视觉由用户新构建手动确认

## 1. 问题

在同一宽屏 Cowork 窗口中切换不同 agent 的对话时，右侧玻璃卡会发生一次可见的横向跳变，
并可能看起来偏移数像素到十余像素。前两版修正虽然固定了 348pt rail、318pt card，删除了
viewport preference feedback，并拆除了共享 `GlassEffectContainer`，但用户在确认使用新构建后仍能
稳定复现，因此这些历史结论不能继续视为通过证据。

本轮不使用 Computer Use，也不以截图/低帧率采样判断是否修复；这两种方式不足以可靠捕获一次性、
数像素级的光学跳变。

## 2. 当前源码中的直接原因

### 2.1 rail 仍以 transcript view 作为 overlay 宿主

旧结构把 `.overlay(alignment: .trailing)` 直接挂在 `threadColumn` 上。即使 rail 自身宽度是固定值，
它的 placement lifecycle 仍属于会随 empty/loading/page/rich/scroller 状态更新的 transcript subtree。
因此“宽度固定”并不等于“rail 的宿主和原生 glass 节点固定”。

### 2.2 selection 使整条 rail 的 Equatable 边界失效

`CoworkStatusRailRenderSnapshot` 仍包含 `selectedAgentID`。点击 agent 时 snapshot 必然不相等，原本用来
隔离 transcript 高频更新的 `.equatable()` 边界会主动重新计算整个 inspector，包括所有 card 的原生
`Glass.clear` backdrop。这个更新与用户观察到的“一点击就蹦一下”严格同频。

### 2.3 glass backdrop 只是 inline background，不是独立稳定节点

旧注释声称内容更新不会 remount optical surface，但实现仍是在 modifier 的 inline `background`
closure 中直接构造 `Color.clear.glassEffect(...)`，没有一个独立、可比较的 backdrop view 来兑现该合同。

## 3. 本轮怎么改

### 3.1 由 outer-detail canvas 唯一拥有几何

`GeometryReader` 提供的 exact outer size 先形成固定透明 canvas：

- conversation 作为 `.overlay(alignment: .leading)`；
- rail 作为同一 canvas 的 `.overlay(alignment: .trailing)`；
- conversation 仍获得扣除 348pt 后的内容布局宽度，但它的 intrinsic size、消息长度、滚动条和
  raw/rich 状态都不再是 rail 的 alignment guide；
- rail 继续固定 348pt，card 固定 318pt，右侧保留 10pt primary-scroller clearance。

### 3.2 selection 不再刷新 glass rail

`selectedAgentID` 从 `CoworkStatusRailRenderSnapshot` 删除。rail 内新增窗口局部轻量 selection state：

- 外部 selection 变化只同步这个小状态；
- 每个 agent row 只有蓝色背景和 accessibility value 观察它；
- Agents / Permission / Goal / Tasks 的 glass section 不因 conversation selection 变化而重新进入
  rail render boundary；
- selection transaction 显式关闭 animation 和 `disablesAnimations`。

### 3.3 glass backdrop 成为 content-independent Equatable view

`Glass.clear` 被放进独立 `IntatisClearLiquidGlassBackdrop`：

- equality 只由 corner radius、interactive 状态、display scale 和系统 color scheme 决定；
- label、计数、状态和蓝色 selection 在 backdrop 上方独立更新；
- 保留 native `Glass.clear`、identity transition 和系统动态 separator 单物理像素轮廓；
- 不增加固定 RGB、渐变、阴影、自绘高光或整栏背景。

## 4. 做完后的界面合同

在窗口大小不变时，切换 `@main`、任一 live agent 或 historical detached agent：

- rail 的 trailing edge、348pt 宽度及各 318pt card 的横向位置不变；
- 中间 header、conversation 和 composer 使用同一固定宽度，不随 agent 内容长短改变；
- 右栏唯一需要立即变化的是被点击行的 accent 蓝底和其 accessibility selected value；
- agent 的真实状态、权限、Goal、Tasks 若自身数据变化，仍可正常更新内容；
- 原生 glass 可以继续响应系统窗口/光照环境，但 conversation selection 本身不再重建 glass 节点。

## 5. 验证边界

自动化验证包括固定宽度 policy、snapshot 排除 selection、源码结构合同，以及 production-shaped
AppKit host 中交错的 agent selection / mode / inspector / window-size 压力循环。macOS/iOS 构建用于
确认共享 SwiftUI surface 没有平台编译回归。

实际结果：

- `ThreadLayoutTests`：13/13；
- `CoworkInferencePresentationTests`：8/8；
- `CoworkAgentThreadPresentationModelTests`：10/10；
- 合计：31 tests / 0 failures；
- production-shaped host：360 次交错 selection/mode/inspector/window-size 循环通过；
- IntatisMac macOS Debug unsigned build：通过；
- IntatisiOS generic Simulator Debug unsigned build：通过；
- 构建只出现仓库既有的 `onChange` deprecation 与 unused `try?` warnings；没有本轮新增编译错误。

最终“肉眼是否还会跳一下”不由 Computer Use、截图或单帧像素比较代替。用户需要在本轮新构建中，
保持窗口大小不变并连续点击多个 agent 作最终手动确认；在该确认完成前，本报告不写“视觉已通过”。

## 6. 修改文件

- `Packages/IntatisSharedUI/Sources/CoworkViews.swift`
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`
- `Packages/IntatisSharedUI/Tests/CoworkInferencePresentationTests.swift`
- `Packages/IntatisSharedUI/Tests/ThreadLayoutTests.swift`
- `docs/CURRENT_STATE.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/TESTING.md`
- 本报告
