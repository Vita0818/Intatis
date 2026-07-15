MODEL_CHECK_RESULT: Gemini 3.1 Pro (High)
PATH_CHECK_RESULT: 
- pwd: /Users/vita/Vitemis/Intatis
- git root: /Users/vita/Vitemis/Intatis
- Match: Yes

FINDINGS:
在针对 Task & Goal 模式进行缺陷和设计弱点（Flaws/Weaknesses）的深入审查中，发现以下架构与实现上的隐患：

1. **审计系统的强文本匹配极其脆弱（Fragile LLM Evidence Matching）**：
   在 `GoalVerifierControlPlane.swift` 中，审计面验证 LLM 提供的证据是否合法时，使用了严格的 `reference` 字符串完全相等匹配 (`compact(kind).lowercased() + "\u{0}" + compact(reference)`)。由于大语言模型（LLM）并不擅长做到 100% 完美的字面量复制，如果模型在输出 `reference` 时哪怕带入了一个不可见的空格差异或轻微的大小写变动，就会触发 `No cited evidence matched an authoritative record`，导致本该完成的 Goal 无法完成。这种硬编码式的严格相等判断极易导致验收失败。

2. **缺少控制面验证的内部重试机制（No Internal Retry for Verifier）**：
   如果 `GoalVerifierControlPlane` 收到格式错误的 JSON（`malformedOutput`）或者模型意外返回了工具调用意图（`sawToolCall`），验证器会立刻直接返回 `.continue` 判决并附带 failure kind，而**没有进行内部退避或重试机制**（Backoff/Retry）。这意味着只要模型稍微输出失误，就会白白浪费一整轮的推理等待和 Token，强迫宿主和用户在外部重新发起，交互体验脆弱。

3. **并发更新冲突与僵化的状态转移（Concurrency Collision & Rigid DAG）**：
   `WorkTaskGraph.update` 方法通过 `expectedRevision` 做乐观并发控制，但对状态转移（如 `pending` -> `ready` -> `inProgress`）的限制极其严苛。如果多个子 Agent 并发执行并试图更新同一个 `WorkTask` 的不同字段，会高频触发 `staleRevision` 错误。如果上游调度器没有妥善的抖动重试机制，极易导致活锁（Livelock）。此外，对 `progressNote` 的覆盖逻辑过于僵硬，如果依赖项发生变更，原有的前序备注可能被覆盖丢失。

4. **强制证据约束可能引发任务死锁（Forced Evidence on All Criteria）**：
   `WorkTask.swift` 的验证逻辑规定，只要存在 `acceptanceCriteria`，就**必须**提交 `evidence` 才能 `completed`（即 `!next.evidence.isEmpty` 为 true）。对于某些具有主观性或纯配置变更、无需实质文件产出的任务（例如：“理解背景”或“改变内存变量状态”），如果 Agent 无法生搬硬套出一个 `TaskEvidence`，这个 WorkTask 就永远无法流转到 `.completed`。

5. **Token 预算为"软限制"，存在超支隐患（Soft Token Budget Overrun）**：
   虽然 Goal 支持了 `tokenBudget`，但正如文档所述，其属于“软限制”。由于 `AgentRuntime` 的流式调用是在原子层之外并发进行的，`budgetLimited` 信号往往要等到下一次 Checkpoint/结算时才生效。对于高吞吐率的 Provider，这会导致在被拦截前实际消耗的 Token 大幅超出用户设定的预算上限。

6. **Requirement ID 映射要求严苛**：
   审计面要求模型准确回传系统分配的 `objective` / `success_criterion_1` / `constraint_1` 等标识符。在上下文窗口中指令较多时，如果模型漏传某一个 ID，代码会无情地判定 `Goal verifier omitted this required requirement`，并拒绝整个任务的闭环。

FILES_WRITTEN:
- gemini-report/07_14_26-22_15-task_goal_flaws.md

VALIDATION_RESULT:
- 执行了 `view_file` 查阅 `GoalVerifierControlPlane.swift`, `Goal.swift`, `WorkTask.swift` 等关键源码，深度分析了验证链条、异常处理与并发控制缺陷。

UNCERTAINTIES:
- Orchestrator（宿主）在捕获 `staleRevision` 后的重试/退避策略目前在内核协议层不可见，这可能在运行时能部分缓解并发写入问题，但仅就 DAG 图操作层面来看，写入冲突依然是一个高频风险源。

NEXT_RECOMMENDED_ACTION:
- **优化匹配逻辑**：建议将 `GoalVerifierControlPlane` 的 Evidence 匹配逻辑由严格字符串匹配改为“模糊匹配”或仅校验存在性，允许大小写或前缀变异。
- **强制 JSON 约束或引入内部重试**：对兼容的模型强制启用 Structured Output (JSON Schema)，或者在遇到 `malformedOutput` 时在 ControlPlane 内部执行 1~2 次的短路重试，提高容错率。
- **允许特例任务闭环**：建议在 `WorkTask` 定义中引入一种机制，允许明确声明为“无实体证据”也算满足标准的特例验收模式。
