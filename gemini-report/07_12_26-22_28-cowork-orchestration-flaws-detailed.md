# Intatis 多 Agent 编排架构缺点详情与源码映射

## MODEL_CHECK_RESULT
Gemini 3.1 Pro (High)

## PATH_CHECK_RESULT
- `pwd`: `/Users/vita/Vitemis/Intatis`
工作目录匹配预期。

## FINDINGS
结合源码文件与架构文档，以下是多 Agent 编排（Cowork）核心缺陷的具体文件与函数/类映射：

### 1. 进程内架构与隔离缺失 (In-Process Bottleneck)
所有的核心调度器和消息总线被设计为普通的 Swift `actor`，完全运行在同一个 App 进程生命周期内。
- **涉及文件**：
  - `Packages/IntatisCowork/Sources/Orchestrator.swift` (包含 `Orchestrator` actor，控制整体生命周期)
  - `Packages/IntatisCowork/Sources/MessageBus.swift` (跨 Agent 消息投递 actor)
  - `Packages/IntatisAgentKernel/Sources/AgentRuntime.swift`
- **缺陷表现**：如果在执行某个工具或者沙盒操作（如 `Packages/IntatisTools/Sources/ShellGit.swift` 里的底层 Process 调用）时发生宿主进程崩溃，所有并行的 Agent 将全部挂掉。系统设计了 `JSONRPC.swift` 的词汇但目前没有实装真正的 Daemon 隔离。

### 2. 协作颗粒度僵化：统一模型与单工作区
- **统一模型缺陷**：
  - **涉及文件**：`Apps/IntatisMac/Sources/CoworkProjectSettings.swift`
  - **缺陷表现**：该文件管理的是 per-session 的全局项目设置，它仅包含一个统一的默认 `provider/model`，系统无法给不同的 Agent（如主节点和子节点）配置不同的 Provider 和模型。
- **单工作区限制**：
  - **涉及文件**：`Packages/IntatisTools/Sources/PathConfinement.swift` 和 `WorkspaceLease`。
  - **缺陷表现**：严格校验 `canonical root` 的 inode/device，所有 Agent 只能在这个唯一的 Root 下活动，不支持跨目录重度工程协作。

### 3. 自动权限审查单点阻塞与脆性 (Reviewer Single-Flight Fragility)
控制面的自动化审批者是彻底的单线程漏斗，并在遇到异常时粗暴拦截。
- **涉及文件**：`Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`
- **缺陷表现**：
  - **单点堵塞**：`PermissionReviewControlPlane` 是一个 actor，内部持有一个上限为 64 的 `queue`。在 `submit()` 函数中所有请求被串行塞入。如果同时有多个 Worker 发起数百次批量工具调用，队列将迅速打满。
  - **Fail-closed（悲观闭锁）**：查看文件内的 `runProvider` 返回处理（第396行之后）。如果 `timeoutSeconds` 耗尽（返回 `.timedOut`）或者 Provider 网络错误（返回 `.failed`），它会直接调用 `persistTerminal(..., decision: .deny, ...)`。此时它不会把审批权抛还给用户界面让用户手动救场，而是直接以硬拒绝阻断这一整条 Agent 任务链。

### 4. 资源控制并非硬保障 (Soft Token Bounds & Watchdog)
- **Soft Budget 限额风险**：
  - **涉及文件**：`Packages/IntatisAgentKernel/Sources/AgentExecutionBudget.swift` 以及 `PermissionReviewControlPlane.swift` (第 367-373 行)。
  - **缺陷表现**：即使发现 Token 超量，代码逻辑仅是将状态置为警告（`healthState = .degraded`），然后任由任务继续运行（"review remains active and usage continues to be recorded"）。对于幻觉造成的 API 无限计费缺乏强制熔断（断路器）干预机制。
- **协作式的 Cancellation**：
  - **涉及文件**：`Packages/IntatisAgentKernel/Sources/AgentLoop.swift`。
  - **缺陷表现**：取消任务依赖 Provider 客户端和执行工具抛出 `CancellationError`。如果外部进程挂起不响应，调度槽将持续被占用。

### 5. 长会话的性能炸弹 (O(N) Event Projection)
状态重建严重依赖全量的事件遍历，没有索引缓存。
- **涉及文件**：
  - `Packages/IntatisConversation/Sources/EventLog.swift` (JSONL 追加日志)
  - `Packages/IntatisConversation/Sources/CoworkProjection.swift`
  - `Packages/IntatisAgentKernel/Sources/ContextProjector.swift`
- **缺陷表现**：例如在 `PermissionReviewControlPlane.swift` 的第 666 行 `CoworkProjection.build(from: events)`，每次权限审批或 Agent 上下文投影时，都会全量遍历内存中的 `events` 数组。在动辄数千行操作的长对话和深层衍生任务中，这种没有任何索引重构（recovery index）的折叠计算（Folding）会造成 CPU 和内存剧烈波动。

## FILES_WRITTEN
- `gemini-report/07_12_26-22_28-cowork-orchestration-flaws-detailed.md`

## VALIDATION_RESULT
（基于代码搜索、架构文档对照与静态代码审查）

## NEXT_RECOMMENDED_ACTION
无需自动修复，请开发者参阅具体的模块依赖关系进行针对性重构（例如为 `EventLog` 实现增量缓存索引，或为 `PermissionReviewControlPlane` 提供降级到人工的交互机制）。
