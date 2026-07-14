# 架构缺陷剖析 4：长会话的性能炸弹 (Performance Indexing Missing)

## 缺陷描述
Intatis 选择了一种极端追求持久化还原度（Durability）的 append-only 事件溯源日志（Event Source）设计。但因为缺失了内存快照和持久化索引，这个设计在长距离多轮交互后，会变成可怕的性能黑洞。

## 涉及的核心文件与类型
- **底层日志存储**：`Packages/IntatisConversation/Sources/EventLog.swift`
- **状态构建投影**：`Packages/IntatisConversation/Sources/CoworkProjection.swift` (例如 `CoworkProjection.build(from: events)`)
- **上下文裁剪**：`Packages/IntatisAgentKernel/Sources/ContextProjector.swift`

## 代码级致病机理分析
1. **每次操作都需全量重放 (O(N) Replay)**：
   我们可以在 `PermissionReviewControlPlane.swift` 中看到大量类似 `let events = await log.replay()` 然后 `CoworkProjection.build(from: events)` 的调用。这意味着仅仅是为了做一次权限校验判断，程序就要把该对话生命周期里从 0 开始产生过的成千上万个事件 `Envelope` 全量折叠遍历一遍。
2. **性能与内存崩溃风险**：
   `CURRENT_STATE.md` 明确声明 EventLog 仍缺乏索引结构（recovery index）。在几十个 Agent 频繁产生 `MessageBus` 信件流、心跳、任务分发流转事件后，这会导致：
   - 每一次新的 Agent 发言，为了拼接 Context，CPU 都必须对巨大数组做一次折叠（Reduce）。
   - 用户在界面上明显感知到越来越严重的卡顿（每一步都需要指数级增加的处理耗时），不仅拖慢推理响应，还会很快触发系统内存不足（OOM）的阈值。
