MODEL_CHECK_RESULT: Gemini 3.1 Pro (High)
PATH_CHECK_RESULT: 
- pwd: /Users/vita/Vitemis/Intatis
- git root: /Users/vita/Vitemis/Intatis
- Match: Yes

FINDINGS:
在审查当前的 "task" 和 "goal" 模式时，主要发现了如下进展与设计实现（基于 `docs/NEXT_TARGET.md`，`docs/CURRENT_STATE.md` 以及 `Goal.swift`, `WorkTask.swift` 的源码）：

1. **四层结构设计**：
   Cowork durable work model（持久化工作模型）已经从原本模糊的单一 task 层，拆分为了明确的四层：
   - **`Goal`**：用户的持久化长期目标（可跨越多个 `ContinuationRun`）。
   - **`WorkTask`**：用户可见的结构化计划 DAG（有向无环图）。
   - **`ContinuationRun`**：宿主的一次推进/检查点/恢复（Checkpoint/Recovery）周期。
   - **`TaskContract` / `TaskGraph` / scheduler**：底层保留的 AgentInvocation 调度与执行层。

2. **Goal（目标系统）**：
   - 生命周期的强控制：采用 `active`, `paused`, `blocked`, `budgetLimited`, `usageLimited`, `completed` 等稳定状态。
   - 强审计与验证要求：Goal 的完成不再隐式地由底层子任务的状态来推断。完成 Goal 需要独立的、无工具调用权限的审查控制面（`GoalVerifierControlPlane`）提供 `GoalAuditSummary`。只有满足 objective、全部 success criteria 和 constraints，且无 remaining work/blocker 时，才能结算为完成。
   - Token / 预算保障：支持基于用户配置的 `tokenBudget`，并能响应 `budgetLimited` 以及 `ProviderUsageLimitError` 产生的信号。

3. **WorkTask（任务系统）**：
   - 用户可见视图：带有明确的状态流转（`pending`, `ready`, `inProgress`, `blocked`, `completed`, `failed`, `cancelled`）、优先级、完成验收标准（acceptanceCriteria）、预期交付物（expectedArtifacts）、依赖（dependsOn）以及责任人（owner）。
   - `WorkTaskGraph` 提供了严密的 DAG readiness 校验。底层执行（Invocation）结果（Agent 的日常对话和工具调用）不再被直接视为 WorkTask 的完结，Agent 必须通过 `task_update` 工具提交具体的 result 和 evidence 来满足完成条件。

4. **架构交互升级**：
   - 指令解析：Cowork 模式中的 `/goal` 指令已经从简单的用户消息标签（User message tags）升级为真正的 Durable Goal 发起入口。
   - GUI 表现：在右侧的 inspector 中，原来通过 Assistant 解析转录文本伪造的 TaskContract objective 已被剔除，全面替换为使用真实 projection 数据渲染的 `Goal` 与 `Tasks` 卡片组件。

FILES_WRITTEN:
- gemini-report/07_14_26-22_05-task_goal_audit.md

VALIDATION_RESULT:
- 执行了 `pwd` 与 `git rev-parse --show-toplevel`
- 执行了 `git status --short` 并核对了工作区变动
- 读取了核心的文档文件（NEXT_TARGET.md / CURRENT_STATE.md）与核心协议文件（Goal.swift / WorkTask.swift）

UNCERTAINTIES:
- Task 和 Goal 在本地环境和 XCTest 中已覆盖，但针对真实 Provider 和真实网络环境进行长周期的 E2E 恢复、取消和 budget 验证效果尚未完成，按文档所述该矩阵状态目前仍为 UNKNOWN。

NEXT_RECOMMENDED_ACTION:
- 建议接下来投入真实外部 provider 的 E2E 验证流程（Real Provider multi-run）、GUI 的 Goal/Tasks 交互流验证、App 真实重启的恢复场景以及长期 Token Budget 行为观察，以结束这些状态验证上的 UNKNOWN 盲区。
