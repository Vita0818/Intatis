# Cowork Agent 对话切换实施与性能验收报告

- 日期：2026-08-03
- 历史 roster 语义修正：2026-08-04
- 状态：已实施并完成专项验收
- 依据方案：`codex-report/08_03_26-22_14-cowork-agent-conversation-switch-implementation-plan.md`
- 原性能审计：`codex-report/08_03_26-22_08-cowork-agent-thread-switch-performance-report.md`
- 核心判定：功能完成；点击、连续切换和选中 agent 持续增量的展示成本保持有界，最终 180 秒门禁未出现主线程告警、事故或原生文本视图线性累积。

## 1. MODEL_CHECK_RESULT

当前为 GPT-5 系列 Codex agent；无法从运行环境确认更精确的模型构建号。

## 2. PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者匹配项目预期。
- 开始实施时仅有用户要求保留的两份未跟踪报告；没有覆盖、回退或清理用户改动。

## 3. 最终用户体验

完成后的 Cowork 行为如下：

1. 打开 session 后，每个窗口显式默认查看 durable `@main`。
2. 右侧 Agents 区的 ordinary agent 状态行是可访问的 Button；点击后立即更新选中态和 `Viewing @agent` 标识。
3. 中间线程只显示该 agent 的有序工作对话，默认读取 Latest，单页最多 16 条。
4. 每个 agent 保存独立的 Earlier/Newer/Latest 数字边界；切走再切回会恢复该 agent 的页。
5. A→B→C 快速切换时，A/B 的迟到 page、update 或 rich admission 不能覆盖 C。
6. 右侧同一列表保留 session 历史上所有 agent；ordinary agent detach 后以既有状态图标显示
   `detached`，仍可点击查看。若当时正在查看它，选择和当前有界页面都保持不变，不回退 `@main`。
7. `@permission-reviewer` 仍显示状态，但没有 conversation Button，不能作为普通查看目标。
8. 查看对象只属于窗口 presentation state；不停止任何 runtime/agent，不改变 scheduler、mailbox、Goal、permission、lease 或 agent status。
9. composer 路由没有随查看对象改变：无显式 target 时仍发给 `@main`。
10. 同一 session 的两个窗口可以查看不同 agent，互不覆盖。

## 4. 实际实现

### 4.1 Typed agent attribution 与增量索引

`CodeProjection` 在 actor fold 路径维护：

- `messageID -> item index`；
- `submissionID -> user item / target agent`；
- `toolCallID -> tool name / agent`；
- `agentID -> all ordered item indices`；
- `agentID -> default-visible ordered item indices`。

归因只来自 typed payload/correlation：

| Row | 归因来源 |
| --- | --- |
| user message | `payload.to`；缺失时只回退 durable main |
| model delta/completion | `payload.agent`；晚到 typed agent 可修复早期无归属 delta |
| tool call / patch | typed agent |
| tool result | exact toolCallID |
| submission error | exact submissionID |
| A2A / information | from 与 to 两侧索引 |
| delegation / task | issuer/requester 与 assignee/recipient typed identity |

A2A canonical row 只保存一次，双方索引只保存轻量 Int 引用。没有修改 EventLog wire schema，
也没有从 title/body 或 `@name` 文本猜测归属。

整套 per-agent attribution/index（包括等待 durable main 后再补 legacy 归属的 pending index）
只由 Cowork reducer 显式开启；普通 Code projection 仍复用 message/tool O(1) lookup，但不保留
Cowork 专用的 per-item agent arrays/Set，避免本功能给长 Code 对话增加无意义的常驻内存。

### 4.2 Actor-owned bounded page

新增 `CoworkAgentThreadPage`，返回：

- exact AgentID；
- `items`，硬上限 16；
- lower/upper/total/capacity；
- projectedThroughSeq / projection generation；
- selected-agent working 状态。

查询先从 agent index 取位置，再只复制当前 slice；点击不读取或 replay EventLog，也不对完整
历史做 filter/sort/equality。8,000+ canonical rows、单 agent 1,000 rows 的 1,000 次 page query
专项用例保持有界。

### 4.3 切断 MainActor 的无界发布

Cowork snapshot 不再携带完整 `[CodeItem]`。Projection pump 只发布本批受影响的：

- all-thread AgentID；
- default-visible AgentID。

`CoworkViewModel` 通过 latest-only、bufferingNewest(1) 的 agent-scoped update hub 通知窗口。
只有当前窗口选中 agent 的 update 会触发 page reload；其他 agent 的 canonical events 仍完整 fold，
但不会使当前 transcript subtree 失效。

owner-only submitted-intent outbox 也按 target agent 预索引；canonical user message 落盘后 exact
overlay 被移除，不在每次 page request 扫描全量 outbox/canonical items。

### 4.4 Window-local presentation lifecycle

新增 `CoworkAgentThreadPresentationModel`，每个窗口独立持有：

- selectedAgentID，初始 main；
- 每-agent requestedUpperBound；
- 当前最多 16-row page；
- page/update task；
- 单调 request generation；
- rich rendering quiet gate。

selection、page、session replacement、disappear 和新一代请求都会 cancel 或 fence 旧任务。
页面结果必须同时匹配 generation、selected agent 与 page agent 才可提交。ordinary agent
detach 只改变 lifecycle/operation availability；其 historical identity 仍在 selectable set，因此
不会触发选择回退或清空当前页面。只有历史 identity 本身无法从 EventLog 恢复时才安全回退 main。

### 4.5 UI 与 accessibility

右侧 ordinary agent 行保留原状态/模型提示，并增加 selected background、checkmark、Button、
accessibility label/value 和稳定 identifier：

- selectable：`cowork.agent.<id>.conversation`；
- status-only：`cowork.agent.<id>.status-only`。

中间标题显示 `Viewing @<agent>`；loading、history pager、thinking/live follow 都绑定当前 agent。

### 4.6 Historical identity 与 live operation 分离

`CoworkProjection` 现在同时折叠两份不同语义的成员集合：

- `agentRoster`：当前在线、可发送/委派/配置/移除的 operational roster；
- `historicalAgentRoster`：同一 EventLog 中所有曾 durable attach/spawn 的 identity，detach 不删除。

UI `agents` 来自 historical roster；状态根据 live membership 决定，非 live ordinary agent 固定显示
`detached`、`isAttached=false`、`canRemove=false`，但保持 conversation selectable。发送 drain、main
inference readiness、agent-name collision、Project Settings rebind 和其他运行时入口仍先检查 live
roster，因而不会把“可查看历史”误当成“可继续工作”。被移除名称允许以后重新 attach；同一
AgentID 会沿用一条历史对话，而不是产生第二个同名身份。

历史列表本身使用 stable-ID `LazyVStack` / `LazyHStack`。agent presentation 先一次性按 AgentID
聚合 running/failed task、workspace lease 与 capability lease，再线性映射历史 roster；没有
agent×task 或 agent×lease 的重复全表扫描。

## 5. 最关键的不卡死设计

最终实现不是“点击后优化一次 filter”，而是切断所有与总历史长度相关的 UI 工作：

```text
EventLog exact events
  -> projection actor typed attribution/index
  -> affected AgentID only
  -> selected window latest-only update
  -> actor page query (<=16)
  -> generation fence
  -> one fixed ScrollView + 16 stable row slots
```

### 5.1 固定原生视图树

专项 Computer Use 验收发现，首个实现虽然没有心跳事故，但 `.id(pageScope)` 会在每次 agent/page
变化时替换整个 ScrollViewReader 根。180 秒后 live window 中出现约 3,696 组 AppKit TextKit
对象，RSS 从约 173 MiB 增至 278 MiB；关闭窗口后对象立即释放，证明 retaining edge 位于窗口
中的被替换原生 document/selection 子树。

最终修正为：

- ScrollView/ScrollViewReader 根保持固定；
- pageScope 变化显式 deactivate old / activate new coordinator；
- 不再使用 `.id(pageScope)` 替换根；
- 16 个可见 row 按 viewport offset 使用稳定 slot identity，不按每个 agent 的 message ID 重新
  创建一整页 native selection views。

### 5.2 Selection/content quiet gate

agent/page 切换立即暂停 rich admission，先显示 exact raw text。同一 selection/page 静止 300 ms
后才允许 rich Markdown。选中 agent 的每次 live update 也重置该 dwell：

- 快速连续点击不会为每个 click 挂载 AppKit Markdown tree；
- 20 Hz page publication/持续 streaming 保持 raw projection；
- 内容停止后自动恢复 rich renderer；
- canonical body、分页数量和 EventLog 均不改变。

这是最终内存稳定的关键。它延续既有 64 KiB whole-message admission、process-wide Markdown
permit、per-row viewport dwell 和 stale publication guard，没有增加 document/native-view cache。

## 6. 性能与 Computer Use 验收

Debug-only fixture 使用真实公开 `CoworkShell` 和生产 presentation model，但不打开 provider、
EventLog、workspace、permission runtime 或 credential：

- 8 个 selectable agents；
- 每 agent 1,000 rows；
- 4-agent 合计 500 canonical delta/s；
- 50 ms projection coalescing；
- 页面最多 16 rows；
- process-level heartbeat warning/incident counter。

最终候选结果：

| 验收 | 结果 |
| --- | --- |
| 默认页面 | `Viewing @main`，985–1,000 / 1,000 |
| 1,000 rapid switches | PASS，0 warning，0 incident |
| 180 秒 nominal 10 Hz soak | PASS，实际 1,486 timed switches |
| soak 累计 switch requests | 2,487（含此前 rapid/manual） |
| 后台流量 | 4-agent 500 canonical delta/s 全程持续 |
| 最终可见行 | 16 |
| 最终 heartbeat | warning 0 / incident 0 |
| `ps` RSS | 约 156.6 MiB |
| `vmmap` physical footprint | 62.1 MiB |
| `vmmap` peak physical footprint | 74.8 MiB |
| `NSTextViewSharedData` | 14 |
| `Gestures.GestureNode<()>` | 173 |

`ps` RSS 与 `vmmap` physical footprint 是不同口径，不能互换；两条曲线均未出现旧实现的线性
增长。中段 RSS 约 142.8 MiB，结束后静态 rich page 恢复时约 156.6 MiB，符合一个 bounded
visible page 的量级。

功能抽查：

- 点击 research 后只出现 research 的 985–1,000；
- docs 翻到 969–984，切到 research 再切回 docs，仍恢复 969–984；
- reviewer 只有 status-only accessibility node；
- soak 后 UI 仍可点击、分页和切换。

2026-08-04 修正后的 offline fixture 已实际验收：从 `@main` 切到 `@research` 后点击
`Detach selected`，`@research` 在原列表中切换为 detached，页面继续显示
`Viewing @research` 与 985–1,000 / 1,000；切到 `@main` 再返回，仍可打开同一历史页。随后在
4-agent 合计 500 canonical delta/s 持续更新时再次完成 1,000 rapid switches，结果为
0 warning / 0 incident，最终仍只挂载 16 rows。reviewer 继续只有 status-only node。该操作不创建
runtime、provider、workspace 或凭据访问。

## 7. 自动化验证

已执行：

- `swift test --filter CoworkAgentThreadPresentationModelTests`；
- `swift test --filter CoworkProjectionRegressionTests`；
- `swift test --filter CoworkInferencePresentationTests`；
- `swift test --filter CoworkAgentThreadProjectionTests`；
- `swift test --filter ThreadScrollCoordinatorTests/testMacRichTranscriptSurfacesUseBoundedEagerWindows`；
- 完整 `swift test`；
- `xcodebuild -project Intatis.xcodeproj -scheme IntatisMac -configuration Debug build CODE_SIGNING_ALLOWED=NO`；
- `git diff --check`；
- `git status --short`。

定向覆盖包括 typed attribution、tool-result correlation、A2A 双索引单正文、legacy main fallback、
0/1/16/17 page boundary、8k rows + 1,000 queries、非选中 agent 不发布、A→B→C stale discard、
detached selection 保留、真正缺失 identity 才 fallback、512 historical / 12 live roster、lazy
unfiltered rail、read-only operation fence、每-agent paging、双窗口隔离、selection/content rich dwell
与 content-free diagnostics。

完整 `swift test` 的第一次运行暴露一个源码合同测试仍要求 Cowork 使用
`ForEach(historyWindow.items)`；生产实现按内存验收改为固定 slot 后，该测试同步改为明确要求
`enumerated()` + `id: \.offset` 且禁止 `.id(item.id)`。修正后定向与最终全量测试通过。

最终收尾期间，两个中间全量 invocation 分别曾只报告 `IntatisCoworkTests` 与
`IntatisSharedUITests` target 失败，但总输出截断，未保留到具体断言；随后独立重跑分别为
320/320、123/123 通过。最终 `swift test --quiet --xunit-output ...` 全量运行 exit 0。两次 target
级波动均未复现，因此没有将其归因成当前功能缺陷，但仍作为测试运行器/时序不确定性保留记录。

2026-08-04 historical-roster 修正的增量验证结果：

- `CoworkProjectionRegressionTests`：8/8；
- `CoworkAgentThreadPresentationModelTests`：10/10；
- `CoworkInferencePresentationTests`：6/6；
- `IntatisConversationTests`：172/172；
- `IntatisMac` Debug unsigned build：exit 0；
- Computer Use：detach 当前 agent 后保持选择、离开再返回可读，以及追加 1,000 rapid switches，
  均为 0 warning / 0 incident；
- 当前 Codex managed sandbox 内再次运行完整 `swift test --disable-sandbox --quiet` 时，只有
  `IntatisToolsTests` 的 process/Seatbelt/loopback 用例因宿主限制失败；Cowork、AgentKernel 等后续
  target 通过。单独启动完整 `IntatisSharedUITests` target 的一次运行在 build 完成后无测试输出，
  手动中止；上述与本修正直接相关的 SharedUI 定向用例均独立通过。这里不把环境失败或悬挂写成
  产品通过，也不推翻前述允许 process/loopback 的宿主环境全量 exit 0 记录。

## 8. FILES_WRITTEN

主要业务与测试文件：

- `Apps/IntatisMac/Sources/CoworkViewModel.swift`
- `Apps/IntatisMac/Sources/CoworkProjectSettings.swift`
- `Apps/IntatisMac/Sources/IntatisMacApp.swift`
- `Apps/IntatisMac/Sources/CoworkAgentConversationFixtureView.swift`
- `Packages/IntatisConversation/Sources/CodeProjection.swift`
- `Packages/IntatisConversation/Sources/CoworkProjection.swift`
- `Packages/IntatisConversation/Sources/SessionProjectionPump.swift`
- `Packages/IntatisConversation/Tests/CoworkAgentThreadProjectionTests.swift`
- `Packages/IntatisConversation/Tests/CoworkProjectionRegressionTests.swift`
- `Packages/IntatisConversation/Tests/SessionProjectionPumpTests.swift`
- `Packages/IntatisCore/Sources/IntatisHangDiagnostics.swift`
- `Packages/IntatisCore/Tests/IntatisHangDiagnosticsTests.swift`
- `Packages/IntatisSharedUI/Sources/CoworkAgentThreadPresentationModel.swift`
- `Packages/IntatisSharedUI/Sources/CoworkViews.swift`
- `Packages/IntatisSharedUI/Sources/ExecutionTracePresentation.swift`
- `Packages/IntatisSharedUI/Tests/CoworkAgentThreadPresentationModelTests.swift`
- `Packages/IntatisSharedUI/Tests/CoworkInferencePresentationTests.swift`
- `Packages/IntatisSharedUI/Tests/ThreadLayoutTests.swift`
- `Packages/IntatisSharedUI/Tests/ThreadScrollCoordinatorTests.swift`

持久文档：

- `docs/CURRENT_STATE.md`
- `docs/ARCHITECTURE.md`
- `docs/COWORK_PRINCIPLES.md`
- `docs/DO_NOT_BREAK.md`
- `docs/TESTING.md`
- `docs/PROJECT_MAP.md`
- 本报告。

原性能审计与实施计划未删改。没有新增依赖、修改 Package.swift/project.yml、修改 EventLog schema、
执行 Git add/commit/push 或创建 PR。

## 9. UNCERTAINTIES

- 本轮 fixture 是真实 Cowork UI/presentation pipeline 的 offline 压测，不覆盖真实 provider 延迟、
  超大 events.jsonl I/O、磁盘压力、VoiceOver、最低支持硬件或多小时运行。
- `heap` / `vmmap` 是本机 macOS 27 beta 环境证据；正式最低系统/设备仍需独立矩阵。
- 当前产品合同是“查看 agent 不改变发送目标”。如果未来要求查看 worker 时直接发送给 worker，
  必须另做明确的路由、权限、composer 文案与恢复设计，不能隐式复用本选择状态。

## 10. NEXT_RECOMMENDED_ACTION

下一步建议在真实长历史 Cowork session 上做一次人工/VoiceOver 回归，并在最低支持 macOS 设备上
重复 180 秒门禁。不要继续扩大页面容量、恢复 root `.id`、增加隐藏 per-agent view cache，或把
window-local selection 提升成 runtime routing state。
