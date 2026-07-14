# 架构缺陷剖析 3：模型与工作区颗粒度受限 (Resource Granularity)

## 缺陷描述
目前的系统没能解耦 Agent 的物理执行身份与模型身份，且在操作范围上只能限制于单一仓库路径，这直接扼杀了 Cowork “组建异构分工团队” 的潜力。

## 涉及的核心文件与类型
- **全局共享设定**：`Apps/IntatisMac/Sources/CoworkProjectSettings.swift`
- **单根限制设计**：`Packages/IntatisTools/Sources/PathConfinement.swift`
- **准入控制**：`Packages/IntatisCowork/Sources/Orchestrator.swift` 中的 `attach(_:)`

## 代码级致病机理分析
1. **无独立的 Model Picker**：目前对于 Provider 的依赖注入是在整个 Session 创建时完成的（`RuntimeEnvironmentManifest` 共享）。这意味着，无论是复杂决策的主脑 `@main`，还是仅仅用于正则提取和字符串截断的下级 `@worker`，都在烧最高端模型的 Token，完全无法做阶梯成本控制。
2. **唯一的主干（Canonical Root）**：系统在授予 `WorkspaceLease` 时，通过 `PathConfinement` 锁死了 Agent 的视野范围。如果一个需求涉及到跨库改动（比如同步更新某个依赖库、与当前 Repo 平级的服务器仓库），Worker 就如同瞎子摸象，不仅会被强行拒绝，甚至也无法向其它被授权跨目录的 Agent 正确委托文件路径。
