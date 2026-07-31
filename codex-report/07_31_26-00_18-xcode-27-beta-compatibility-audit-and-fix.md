# Xcode 27 / macOS 27 Beta 兼容性审计与修复记录

日期：2026-07-31（Asia/Singapore）

## 结论

本轮已经完成可复现问题的兼容处理，并通过 SwiftPM、IntatisMac 和
IntatisiOS 的 Xcode 27 构建验证。

关于“是不是新系统导致”的结论必须拆开：

1. `Gestures.InvalidTransition` 的 teardown assertion 可以高置信归类为
   Apple Beta 系统框架侧兼容回归。失败栈完全位于
   `Gestures`、`SwiftUICore`、`AppKit`、`NSTextInteraction` 和
   `NSHostingView.deinit`，没有 Intatis frame；它发生在未稳定的
   SwiftUI/AppKit interaction graph 被 XCTest 拆除时。
2. 16-row 宿主测试最初收不到首批 geometry/preference callback，不应写成
   “纯系统 API 全局坏了”。它只在 Xcode 27 的 async XCTest hosting 生命周期
   与 Intatis 复杂 rich renderer 组合中按顺序复现；两个只含 Apple API 的
   最小程序均通过。准确分类是 **Xcode 27 测试宿主生命周期与 Intatis
   renderer 测试夹具的交互兼容问题**。
3. 当前机器只安装了 Xcode 27，没有旧 Xcode/SDK 可做同机 A/B。因此能够确认
   “升级后暴露了系统框架和测试宿主兼容回归”，但不能诚实宣称所有原始 timeout
   都由 macOS 27 或 Xcode 27 单方、排他性造成。
4. 本轮另复现了 Xcode 27 `xctest` 的 target-wide filter 问题：把
   `IntatisSharedUITests` 的 108 个 selector 一次性传入 `-XCTest` 后，runner
   可长期停在 `XCTWaiter`，主线程等待、工作线程空闲。无过滤整仓执行和按单个
   test class 过滤均通过。这是测试工具链问题，不是 Intatis App 卡死。

没有通过延长 timeout、伪造 callback、自动放行 rich admission 或切换
plain renderer 来掩盖问题。

## 验证环境

| 项目 | 实际值 |
| --- | --- |
| macOS | 27.0 Beta，build `26A5388g` |
| Xcode | 27.0 Beta，build `27A5228h` |
| Swift | Apple Swift 6.4，`swiftlang-6.4.0.27.1` |
| Target | `arm64-apple-macosx27.0.0` |
| Developer directory | `/Applications/Xcode.app/Contents/Developer` |
| 本机 Xcode 数量 | 1；没有旧版 Xcode 可做同机 A/B |

## 原始复现与证据

### 1. 生产形态的 16-row hosting 测试

原始失败有如下确定性状态：

- `ParagraphNSView` 数量为 0；
- rich admission 停在 `suspended(generation: 1)`；
- coordinator 的 geometry observation count 为 0；
- scroller position 为 0；
- 单独运行 16-row case 可以通过，但在前置 async Markdown case 后可稳定
  timeout。

这说明失败点不是“rich document 已经渲染但滚动错误”，而是测试宿主没有让
首批 SwiftUI/AppKit geometry transaction 在断言前稳定下来。

### 2. teardown assertion

timeout unwind 后，Apple framework 触发：

- `InvalidTransition phase idle target failed(deinit)`；
- 部分复现为 `failed(removedFromContainer)`。

采样和 debugger 栈经过：

`Gestures` → `NSGestureRecognizer` →
`NSTextSelectionManager` / `NSTextInteraction` →
`SwiftUICore.CoreInteractionEffect.destroy` →
`GraphHost.invalidate` → `NSHostingView.deinit`。

该 assertion 是系统 framework 的内部状态机失败。Intatis 只能确保宿主在释放
原生 selectable text/gesture graph 前完成一次正常 run-loop settle，不能在
产品代码中修改 Apple 私有状态机。

### 3. Apple-only 对照实验

在 `/private/tmp` 构建了两个不依赖 Intatis 的诊断程序：

- 纯 AppKit/SwiftUI executable：`NSHostingView` + `ScrollViewReader` +
  `GeometryReader`/`PreferenceKey`，`orderFront` 和
  `makeKeyAndOrderFront` 两种路径均收到 geometry/preference callback，并正常
  teardown。
- 纯 Apple XCTest package：async precursor + selectable `Text` +
  `onScrollGeometryChange` + native scroll + teardown，隔离与顺序运行都通过。

因此没有证据支持“macOS 27 的 `PreferenceKey` 或
`onScrollGeometryChange` 在所有程序里失效”。这些程序只用于归因，不代替
Intatis production-shaped tests。

### 4. Xcode 27 target-wide test filter

`swift test --filter IntatisSharedUITests` 会生成一个包含 108 个 selector 的
`xctest -XCTest ...` 调用。本轮该进程超过两分钟无测试输出：

- `swift-test` 与 `xctest` 均仍存活；
- CPU 为 0%；
- 3 秒 `sample` 显示主线程位于
  `XCTFailableInvocation.invokeWithAsynchronousWait` →
  `XCTWaiter._performWait` → `CFRunLoop`；
- 其余 workqueue thread 空闲。

终止该无效过滤后，两个相关 class filter 立即分别在约 0.8 秒和 2.3 秒内
通过。后续在 Xcode 27 下不把“大量 selector 的整 target filter”作为
SharedUI 权威命令；使用无过滤全量运行或按 class 分片。

## 实施的兼容修改

### Production SharedUI

`PendingEntryRichAdmission` 现在记录实际 raw-bottom restore 时的 geometry
observation generation。lazy entry 只有在以下任一**精确、可验证**条件成立后
才释放 rich admission：

1. 原有的 exact bottom-anchor visibility 信号成立；或
2. restore 之后出现了更新一代的 native scroll-geometry observation，且该
   observation 同时证明 `latestIsAtBottom` 和有限正 content height。

restore 之前的 stale geometry 明确不能放行。该修改没有引入 wall-clock
兜底、timeout 成功、自动切 plain 或 fake visibility。

### Xcode 27 XCTest hosting 生命周期

真实 `NSHostingView` 测试夹具现在：

- 使用 key borderless window 并显式 display/layout；
- 安装 production-shaped `onScrollGeometryChange`；
- host attach 后在主线程泵一次 AppKit run loop，使首批 SwiftUI transaction
  可被 XCTest 观察；
- teardown 时先把 root 替换为 `EmptyView`，再次泵 run loop，再清空
  `contentView`，避免直接释放仍带 selectable text/gesture interaction 的
  graph；
- timeout 诊断保留 paragraph 数、admission、geometry observation 和 scroller
  position。

这部分只修改测试宿主生命周期，不修改 App 的正常事件循环。

### Swift 6.4 / Xcode 27 编译兼容

- MainActor fixture 的 `.shared` 默认参数改为在 initializer 内解析；
- async fake video provider 使用 `NSLock.withLock`；
- Code/Cowork 的 MCP snapshot provider 使用显式 `@Sendable` 类型，而不是
  `Optional.map` 隐式闭包转换；
- Code dispatch 在并发闭包捕获前冻结 capability lease。

这些改动清除了 Xcode 27 新暴露的 actor isolation、async lock、Sendability
和 captured mutable variable 诊断，不改变 provider、permission 或 lease
语义。

## 新增回归覆盖

- `testLazyEntryAcceptsPostRestoreBottomScrollGeometry`
- `testLazyEntryRejectsStalePreRestoreBottomScrollGeometry`

第二项是防止“任何历史 bottom observation 都算成功”的反兜底测试。

## 最终验证

| 验证 | 结果 |
| --- | --- |
| `ThreadScrollCoordinatorTests` | 30/30，0 failures |
| `MessageRenderingTests` | 41/41，0 failures；含 3 个真实 `NSHostingView` cases |
| 完整 `swift test --disable-sandbox` | 所有 test bundle 退出 0；0 failures；既有 opt-in environment skips 保留 |
| `swift build --disable-sandbox` | succeeded |
| IntatisMac Debug，macOS 27 SDK，unsigned | succeeded |
| IntatisiOS Debug，generic iOS Simulator，unsigned | succeeded |

完整 SwiftPM 的最终输出由多个 test bundle 分别汇总，本轮没有把未出现的全局
总数自行相加或猜测成一个数字。

全新 scratch 的一次额外复核在编译前失败，因为本机 Git HTTPS 代理仍指向不可用
的 `127.0.0.1:1082`，依赖 clone 无法开始；随后使用已解析且 exact-pinned 的
本地 checkout/cache 完成上述验证。这不是源码、SDK 或测试失败。

Xcode 27 仍报告少量既有低优先级 warning，例如 unused `try?`、
单参数 `onChange` deprecated 和一个 unused binding；它们没有升级为 build
error。本轮针对 Swift 6.4 新出现的并发/隔离 warning 已处理。

## 尚未证明的事项

- 未使用旧 Xcode/旧 SDK 对同一源码做 A/B，所以“所有 timeout 排他性由新系统
  造成”仍为 `UNKNOWN`。
- 本轮没有启动真实 IntatisMac 并对用户的实际 Cowork session 做手工
  entry/scroll/resize 操作；自动化 production-shaped host 和两个产品 build
  均通过，但运行态 GUI 复验仍应单独执行。
- 没有找到 Apple 发布说明中与
  `Gestures.InvalidTransition failed(deinit)` 完全匹配的公开 known issue。

## 后续建议

1. 在下一版 macOS 27/Xcode 27 Beta 更新后重跑两个 focused class、无过滤完整
   SwiftPM 和双端 build。
2. 若需要“排他性系统归因”，安装一份可并存的旧 Xcode，用同一 commit、
   同一 DerivedData 清理策略和同一测试序列做 A/B。
3. 对真实问题 session 做一次 latest-build 的进入、上下滚动、连续 resize 和
   session A→B→A；若仍卡死，使用已有 hang diagnostics/sample 取当前栈，不把
   旧 `Gestures` teardown assertion 自动套到新的产品现场。

## 公开参考

- [Apple Xcode 27 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)：
  用于核对 Xcode 27 / Swift 6.4 工具链基线；当前公开条目没有与本轮
  `Gestures.InvalidTransition` assertion 完全匹配的 known issue。
