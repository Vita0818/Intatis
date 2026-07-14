# Intatis 多 Agent 编排架构缺点与风险审查

## MODEL_CHECK_RESULT
Gemini 3.1 Pro (High)

## PATH_CHECK_RESULT
- `pwd`: `/Users/vita/Vitemis/Intatis`
- `git rev-parse`: `/Users/vita/Vitemis/Intatis`
工作目录匹配预期。

## FINDINGS
基于对 `ARCHITECTURE.md`、`COWORK_PRINCIPLES.md` 及 `CURRENT_STATE.md` 的深入只读审查，Intatis 的多 Agent 编排虽然在理论抽象上严谨，但在当前的落地形态与设计边界上，存在以下明显缺陷与待验证的架构瓶颈：

### 1. 进程内架构与隔离缺失 (In-Process Bottleneck)
- **非分布式运行**：虽然系统设计了 `MessageBus` 和持久化投递，但当前的 v0.1 内核完全是**单进程（In-Process）内运行**（JSON-RPC 传输层未实装，外部 daemon 仍在规划中）。所有 Agent 在同一内存空间执行，一旦某个任务（如操作大量原生指针的底层逻辑或沙盒崩溃）导致宿主 App 崩溃，整个编排环境会集体宕机，缺乏进程级别的容错与隔离能力。

### 2. 协作颗粒度僵化：统一模型与单工作区
- **无法独立选型模型**：`CURRENT_STATE.md` 明确指出“当前仍未实现每个 agent 独立 provider/model picker”。这在 Cowork 中是个硬伤，意味着无法实施高低搭配策略（即无法让主控 `@main` 使用昂贵的旗舰大模型，而下属负责文件计数等繁杂活儿的 worker 使用廉价的高速小模型）。
- **多工作区限制**：目前工具执行严格受限于单一的 `workspaceRoot`，“多目录 direct multi-root tool context 仍是后续工作”。Agent 目前难以在一个上下文中针对不同的 Git Repo 进行交叉操作，限制了重度项目间协作的能力。

### 3. 自动权限审查单点阻塞与脆性 (Reviewer Single-Flight)
- **排队瓶颈**：保留的控制面 `@permission-reviewer` 设计为 `FIFO/single-flight`（队列上限64）。当多个 worker 并发产生大量工具操作请求时，单线排队的审查器势必成为卡死整个 Task Graph 的单点瓶颈。
- **Fail-closed 导致的脆弱**：审查超时或出错不会平滑退回给人类接管（除非提前显式切换为手动模式），而是直接 `durable deny` 当前调用。这使得自动化链条非常脆弱，一次由于并发高引发的超时或偶尔的网络抖动，就可能直接中断下游 Agent 的委派链。

### 4. 资源控制并非硬保障 (Soft Bounds)
- **Token 预算限额是 Soft 限制**：系统的 `AgentExecutionBudget`（共享会话 Token 预算）受制于不同模型 Provider Tokenizer 的实现差异，只能做到"Soft"预估，超额（overrun）情况仍可能发生。若有 Worker 发生幻觉疯狂调用，存在瞬间耗尽大量 API 费用的风险，缺乏强力的绝对熔断机制。
- **协同式取消**：任务 Cancellation 是协作式的。如果底层执行工具卡死（如某个 shell 脚本忽略 TERM 或网络 Fetch 无限挂起），由于没有脱离当前进程池的硬清理，仍然可能导致调度槽被耗尽。

### 5. 长会话的性能炸弹 (Performance Indexing Missing)
- 系统过度依赖全量的 `EventLog`（JSONL）来追踪一切生命周期和消息。当前“EventLog-derived context/recovery index remains a future long-session performance optimization”，缺乏索引。如果对话轮次极长、衍生任务极多，由于每次都需要重建调度器和投影 `ContextProjector`，计算量和内存压力会随着事件数量呈指数上升，产生严重的性能问题。

### 6. 核心机制缺乏真实 E2E 验证
- 尽管存在庞大的内部断言和 Mock 测试，但文档多处标红了 `UNKNOWN`。最核心的隐患在于：“真实外部 provider 的完整多工具 E2E 仍 UNKNOWN” 以及 “真实长任务恢复仍待真机验证”。基于 Fake Provider 的单测无法模拟真实大模型的幻觉、残缺的 `finish_reason`、以及复杂的调用时序。这种严密的架构设计在遇到真实非确定性输出时的表现依然是个问号。

## FILES_WRITTEN
- `gemini-report/07_12_26-22_27-cowork-orchestration-flaws.md`

## VALIDATION_RESULT
（无新的终端验证执行，基于静态文档审计）

## UNCERTAINTIES
暂无。缺点与瓶颈已经基于项目资料列出。

## NEXT_RECOMMENDED_ACTION
无需自动修改。建议开发者可以以此报告作为下一阶段性能与架构优化的反推清单。
