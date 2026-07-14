# 架构缺陷剖析 2：自动权限审查单点阻塞与悲观闭锁 (Reviewer Single-Flight Fragility)

## 缺陷描述
自动权限审查机制为了追求“不可绕过”和“序列化证明”，被设计成了极端的单点串行检查口。更严重的是，当它遇到任何性能超时和异常时，它会悲观地“闭锁（Fail-closed）”。

## 涉及的核心文件与类型
- `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`
- **核心类型**：`public actor PermissionReviewControlPlane`

## 代码级致病机理分析
在该文件中，排队逻辑由 `private var queue: [PermissionReviewTaskID]` 负责。
在底部的 `runProvider` 函数以及 `drain()` / `process()` 处理流中，我们可以看到非常生硬的容错逻辑：
1. **排队瓶颈 (Single-Flight)**：在同一时刻 `runningExecution` 只有一个。即使有 10 个 Agent 同时并发申请读取不同文件的权限，审查也会被逼成串行（FIFO）。
2. **悲观闭锁阻断**：当 `runProvider` 遇到 `timedOut` (超时)，系统不是将其降级退回（比如把 `.askUser` 的红球抛回给真实的人类界面），而是强制构造一个原因为 `"permission reviewer timed out; automatic mode denied the request"` 的结果，然后调用 `persistTerminal(..., decision: .deny, ...)`。
3. **系统僵死连锁反应**：一旦返回 `.deny`，请求方 Agent 的工具调用就会失败。这在长达上百步的工作流中，会导致偶然的网络抖动（导致 Reviewer 超时），直接破坏一整个需要通宵运行的自动化代理链条，极其脆弱。
