# Intatis Markdown Phase 0 / Phase 1 实施与验收记录

日期：2026-07-17  
依据：`codex-report/07_17_26-22_16-swift-streaming-markdown-adoption-migration-report.md`

## 结论

本轮完成了报告建议的生产安全部分，并保持了报告的 cutover 门槛：

- **Phase 0 已落地。** 无 renderer 偏好时默认 `plainSafe`；macOS/iOS 应用内设置、macOS 启动 override 与 iOS 系统 Settings 预启动入口共用同一稳定 key。plain-safe 不进入现役 Markdown/cache/parser/highlight/math/image 路径。
- **Phase 1 已建立 exact-version 隔离 harness 并完成真实事故形态功能 smoke。** Microsoft `SwiftStreamingMarkdown` 没有加入 Intatis 主依赖图。
- **Microsoft v0.6.0 生产接入仍为 NO-GO。** 本轮没有修改根 `Package.swift` / `Package.resolved`，没有删除旧 renderer，也没有把候选写入 NOTICE。
- **旧栈完全替换尚未开始。** 这是有意遵守报告 Phase 2–5 的门，而不是遗漏实施。

## Phase 0：产品级 Plain Safe 熔断

### 稳定契约

新增 renderer-neutral 类型：

```text
IntatisMessageRendererMode.rich
IntatisMessageRendererMode.plainSafe
```

固定配置面：

```text
UserDefaults key: intatis.messageRendering.mode.v1
macOS force plain: -IntatisPlainSafeMessages
macOS force rich:  -IntatisRichTextMessages
```

解析规则：

1. 启动 override 优先于持久值；两个参数冲突时 plain-safe 胜出。
2. key 缺失或值损坏时默认 plain-safe。
3. 只有用户持久选择 rich 或显式 rich override 才进入现役 MarkdownUI 栈。
4. user/system/特殊卡片的原有 plain/dedicated policy 不扩大。

### 冷启动与流式安全

`IntatisMessageContentView` 在构造初始 document state 前读取 mode。plain-safe：

- 不查询完成文档 rich cache；
- 不构造 `Markdown` view；
- task 直接发布 `.plain(displayText)`，不调用 `IntatisRenderDocumentWorker`；
- 保留原始 Unicode、空格与 CR/LF/CRLF bytes；
- 只有空且未完成的消息显示 `…`。

rich 流式路径也新增 stale projection 门：已解析 document 的 `rawText` 必须与当前 `displayText` 完全相等才允许显示；debounce 或 actor 排队期间显示当前 raw Text，不再让上一 snapshot 的 Markdown 覆盖新 source。

切换到 plain-safe 会改变 task revision 并阻止旧结果发布。已经进入同步 cmark build 的单次工作不能被 Swift task 强制中断，但不会再显示或发布；冷启动默认/override 路径不会进入该 build。

### 用户入口

- macOS Settings：Rich Markdown / Plain text safe mode；立即持久化。
- iOS 应用内 Settings：同一 key；文案明确 renderer 选择立即保存，Cancel 只丢弃 provider 临时编辑。
- macOS override 生效时 Picker 仍可保存下次无 override 启动的模式，避免去掉救援参数后再次冻结。
- iOS `Settings.bundle`：系统 Settings 中可在启动 Intatis 之前选择 `plainSafe` / `rich`，默认 `plainSafe`；rich 标记为 experimental。
- DEBUG `RendererFixtureView`：显示当前 mode 与 launch override。

## Phase 1：Microsoft exact v0.6 隔离证据

固定候选：

```text
Repository: microsoft/SwiftStreamingMarkdown
Tag:        v0.6.0
Commit:     c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd
```

当前 official main `a4187829013c4588556d82dbf1ab65ed768a0262` 只比 tag 多 README 图片提交，production source 与 manifest 没有关闭本报告阻断项。

隔离 app 位于 `/private/tmp`，未进入仓库依赖图。harness 只读 EventLog，将 `message_delta` 按 message ID 合成为 cumulative snapshots；Computer Use 验收期间默认启用 privacy cover，AX tree 和截图不输出消息正文。

事故形态：

```text
17 messages
1,249 cumulative delta snapshots
three table-heavy messages: 517 / 207 / 235 deltas
```

已验证：

- latest-only streaming rich 回放与 Replay；
- static `MarkdownView`；
- Microsoft rich 与 raw plain 基线切换；
- 滚动至全部三条表格密集消息；
- 无持续 loading indicator，控件与滚动保持可响应。

这些时长包含 Computer Use attach/capture 开销，不能作为 Instruments 性能预算。首次 app attach 曾约 103 秒，随后 Replay、mode 切换和滚动大多约 1.2–2.1 秒；没有独立采样足以把首次耗时归因于 renderer。

尚未完成报告规定的 Phase 1 性能协议：优化 Release 候选的 5 次 cold open、20 次 replay、每次 60 秒稳态、main-thread stall、parse p95/max、RSS、CPU settle、`1 running + 1 pending` backlog、基准 Mac 与低端真实 iPhone/iPad。因此隔离功能 smoke 不是 production performance GO。

## 真实 Intatis Computer Use 验收

目标为当前问题 Cowork session。为避免在报告中泄露对话内容，只记录事件数量、hash、事件类型与 UI 状态。

### 救援与重启

- `-IntatisPlainSafeMessages` 启动后，问题 session 约 1.8 秒进入可交互 Cowork shell；未见 loading indicator。
- 向下滚动响应约 1.3 秒，向上滚动约 1.4 秒。
- override 生效时，Settings 明确显示当前强制 Plain Safe；Picker 可先写 rich、再持久恢复 plain，而当前运行始终保持强制 plain。
- 退出后确认 `com.Vita0818.IntatisMac` preference 为 `plainSafe`。
- 不带任何 renderer 参数重启，问题 session 约 1.7 秒重新进入可交互状态；滚动约 1.2 秒。
- 重启后的 Settings 显示 Plain selected、Rich unselected，且没有 launch override 文案。

以上时长同样包含 Computer Use action/capture 开销，仅用于“没有持续卡死”的功能判断。

### EventLog 不变性

初始日志：

```text
events: 1,648
size:   1,086,066 bytes
sha256: 612b86cd7f1fcf0f319ab5619e895019b2e758571c3d45dcaf21717b6f97b1ac
```

首次恢复 Cowork runtime 后，日志正常追加 workspace/capability lease 与 agent attach 事件。以 runtime 稳定后的 seq 1653 为边界，切换并持久化 renderer preference 前后：

```text
size:   1,089,328 bytes -> 1,089,328 bytes
sha256: 27e1fd836c982b937d52ca72cbf326e3eff1f0dad2d830df007f3b70f51269a1
mtime:  unchanged
last event: seq 1653 agent_attached
```

renderer 切换本身没有写 EventLog。第二次 app 启动又追加了正常的 lease revoke/grant 与 agent detach/attach，最终到 seq 1659；因此不能把“跨 runtime 重启的整个文件 hash 变化”误判为 renderer 改写。

### 选择与复制边界

离线 plain-safe fixture 的 AX tree显示完整 raw Markdown symbols、table pipes、fence 与 TeX delimiters，证明屏幕投影未吞掉这些 source。产品 view 仍应用 `.textSelection(.enabled)`，纯路由测试也按 UTF-8 Data 验证 byte identity。

本轮 Computer Use 的 AX `select_text` 不支持 SwiftUI static Text 的 selected-range，坐标 drag 又由 Computer Use 服务返回 `noWindowsAvailable`，所以没有取得自动化 clipboard byte-for-byte 证据。该项仍应保留为手动/后续 CU 能力验证，不写成已完全通过。

## 构建与测试

最终源码验证：

```text
MessageRendererModeTests: 10/10 passed
MessageRenderingTests:     29/29 passed
IntatisSharedUI target:    build passed
IntatisMac Debug:          build passed
IntatisiOS Simulator:      build passed (arm64 + x86_64)
Settings.bundle plist:     lint OK and present in IntatisiOS.app
git diff --check:          see final workspace validation
```

`MessageRenderingTests` 的 29/29 是经授权允许 AppKit HTML importer 的 SwiftPM 定向执行；旧文档中的 outer-sandbox-only 28/28 是历史环境记录。

## 为什么现在不能切 production

官方 v0.6.0 仍有以下阻断：

1. exact `swift-markdown 0.7.3`，畸形表格风险门未关闭；
2. LaTeX 在 Markdown parse 前全局重写，不识别 fenced/inline code ranges；
3. code highlighting 没有 disabled、explicit language 或 maxBytes API；
4. table copy/download actions 与图标不可由 config 完整控制；
5. package 无条件分发 Copilot palette/图标；
6. HighlightSwift exact revision 编译包含 CC BY-SA `nnfx` theme；
7. iosMath fork/Latin Modern Math 的 GUST/LPPL 与 provenance 仍需批准和补全；
8. Swift 6 language mode / complete strict-concurrency 构建失败；
9. runtime feature flag 不能从 target graph 移除 HighlightSwift、iosMath/font 或品牌资源。

因此本轮不更新 `NOTICE.md` / `ThirdPartyNotices`：没有新的 production dependency 或资源进入 Intatis。若后续采用 official tag 或极薄 fork，必须在同一个原子 cutover 中更新依赖、资源、NOTICE、测试和 docs。

## 下一步

1. 保留默认 plain-safe 与 iOS/macOS 救援入口。
2. 完成 Phase 1 的 Release/Instruments/真实设备性能协议和 selection/copy 手动证据。
3. 等待 Microsoft official tag；若节奏不满足，再建立只改 target 边界、资源、配置和并发问题的极薄 fork，并为每个 patch 建 upstream issue/PR 与删除条件。
4. 只有 Phase 2 全部门关闭后，才在专用分支执行 Phase 3–5 原子切换与旧栈删除。

