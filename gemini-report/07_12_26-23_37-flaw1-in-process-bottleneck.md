# 架构缺陷剖析 1：进程内瓶颈与强耦合 (In-Process Bottleneck)

## 缺陷描述
当前的 Cowork 核心是一个完全依托于 Swift 语言原生的单进程（In-Process）内存空间的框架。即所有的调度、总线、工具执行乃至模型 Provider 的轮询，都强行绑定在同一个应用程序（如 `IntatisMacApp`）的内存里。

## 涉及的核心文件与类型
- `Packages/IntatisCowork/Sources/Orchestrator.swift` (核心 `public actor Orchestrator`)
- `Packages/IntatisCowork/Sources/MessageBus.swift` (总线 `public actor MessageBus`)
- `Packages/IntatisAgentKernel/Sources/AgentRuntime.swift` (运行时容器)

## 严重性与后果
在 `Orchestrator.swift` 中我们可以看到，整个协作状态（如 `taskGraph`, `scheduler`, `runningExecutions`）都被存放在 `actor Orchestrator` 的实例属性中。
一旦多 Agent 并行运行时：
1. **沙盒指针崩溃引发团灭**：由于并没有实现类似 XPC Daemon 或者 gRPC 等外部进程挂载服务（`ARCHITECTURE.md` 提到 Daemon 在规划中未实现），如果底层通过 `Process()` 执行的 Git/Shell 脚本或者工具（`IntatisTools`）引发宿主 Crash，会导致内存里的这棵任务树直接丢失。
2. **重度任务抢占 UI 资源**：尽管 Actor 利用了协程和调度器剥离主线程，但极高频率的事件打印（如 `EventLog.append`）、海量的并发日志和 JSON 解析，依然在同一个进程内积压。当并发 Agent 达到两位数时，对单一进程的内存和锁争用压力极大。
