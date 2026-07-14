# OpenCode 权限源码逐项对照与 Intatis 权限模型修正报告

日期：2026-07-12

报告性质：只读源码审计与迁移设计，不包含业务源码修改

Intatis 工作区：`/Users/vita/Vitemis/Intatis`

OpenCode 上游：[`anomalyco/opencode`](https://github.com/anomalyco/opencode)

固定版本：[`34e58090595d44e3e7cc37498f16753a98627456`](https://github.com/anomalyco/opencode/commit/34e58090595d44e3e7cc37498f16753a98627456)（`dev`，commit 时间 2026-07-11T20:31:57Z）

## 1. 结论先行

用户截图里的现象不是 UI 偶发错误，也不是审查模型单独判断失误。当前 Intatis 源码主动把 `spawn_agent` 定义成了 `.write`，并把目标 agent 的目录放进 `touchedPaths`。因此整个权限链会把“创建一个子 agent”解释成“写入工作区”，自动审查者看到的也是这个错误语义。

当前真实链路是：

```text
spawn_agent ToolCall
  -> SpawnAgentTool.descriptor.sideEffect == .write
  -> touchedPaths == [子 agent workspace]
  -> AgentLoop 生成 ToolCallContext
  -> DeterministicPolicyGate.evaluateWrite
  -> ask_user(reason: "write to workspace")
  -> Cowork 自动 Permission Reviewer
  -> allow / deny
  -> 允许后才执行 agent admission
```

所以截图里出现：

```text
deny: spawn_agent — permission denied: write to workspace
```

并不代表 `spawn_agent` 已经运行并准备修改文件。它只代表 Intatis 在真正创建子 agent 之前，用“workspace write”这个错误类别审批了 agent 生命周期操作。

我的核心判断是：

1. `spawn_agent` 的确不是只读操作，因为它会改变 roster、lease、session/task 状态；但它也不是“写文件”。它应属于 `agent.spawn` / `task` / `workspace.attach` 等控制面权限域。
2. 子 agent 获得 `WorkspaceLease.readWrite` 只表示它未来可申请执行写工具的最大边界，不表示当前 `spawn_agent` 已经获准写任何文件。
3. 子 agent 后续调用 `read_file`、`write_file`、Git、网络或命令工具时，仍应按每次真实 ToolCall 的参数、目标资源和实际风险重新审批。
4. Intatis 现在只有一个五值 `SideEffect` 枚举，却用它同时表达文件副作用、控制面副作用、权限风险、workspace lease 兼容性和崩溃重放策略。这是本次问题的根源。
5. OpenCode 值得借鉴的不是其默认安全策略，而是“每个工具自己产生 action + resource/pattern + metadata 的权限请求”这一数据模型。
6. OpenCode 也不能整套照搬。固定 commit 中同时存在 V1/V2 两套权限实现；新的 Bash V2 明确以宿主用户的文件、进程和网络权限运行，而且外部路径扫描仍只是 advisory，源码还留有迁移 parser 的 TODO。这比 Intatis 当前 production 不暴露 raw shell 的边界更宽。

因此，正确修复方向不是简单把 `spawn_agent.sideEffect` 从 `.write` 改成 `.readOnly`，而是拆开以下概念：

```text
Tool availability       CapabilityLease：这个 agent 能否看到/调用该工具
Authority ceiling       WorkspaceLease：最大可访问根目录、路径与 read/write 上限
Operation intent        PermissionIntent：本次具体要做什么、对什么资源做
Policy decision         allow / ask / deny：规则和自动审查的本次决定
Recovery semantics      ReplayPolicy：崩溃后是否可安全重放
```

## 2. 本次审计范围与方法

本报告没有把 OpenCode 的 `dev` 浮动分支当成稳定 API，而是固定到上面的 commit。逐项核对了：

- OpenCode V1 permission service、V2 permission service；
- OpenCode `read`、`edit`、`write`、`bash`、`task` 工具的实际审批调用点；
- OpenCode agent 默认权限、subagent session 权限派生；
- Intatis `ToolDescriptor`、`ToolCallContext`、`AgentLoop`、`DeterministicPolicyGate`、`PermissionEngine`；
- Intatis Cowork 自动权限审查控制面；
- Intatis `spawn_agent`、`delegate_task`、消息工具和默认 workspace/capability lease；
- 锁定当前行为的相关测试。

本报告只总结行为和可迁移设计，没有复制或逐行翻译 OpenCode 源码。OpenCode 在 Intatis 中仍是 research-only，本轮不需要更新 `NOTICE.md`。

## 3. OpenCode 源码逐项检查

### 3.1 V1：权限判断的核心不是 `read/write` 枚举，而是 `permission + pattern`

文件：[`packages/opencode/src/permission/index.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/permission/index.ts)

关键行为：

- `evaluate(permission, pattern, ...rulesets)` 对 action 名和资源 pattern 做 wildcard 匹配；
- 使用最后一条匹配规则，未匹配时默认 `ask`；
- 一个请求可带多个 `patterns`，任一 deny 都会拒绝；
- ask 事件保存 `permission`、`patterns`、`metadata`、`always` 和原始 tool；
- 用户选择 always 后，把工具建议的 pattern 作为 session 内批准规则；
- `edit`/`write`/`apply_patch` 可以统一映射到 `edit` 权限域，但资源仍是具体路径；
- 完全 deny 的工具可从模型可见工具表中隐藏。

这套模型的重点是：

```text
action = 要做的动作种类
pattern/resource = 本次动作实际作用的对象
metadata = 给审批 UI/审查者看的上下文
```

它没有要求所有工具先被塞进一个全局 `.write` 类别。

### 3.2 V2：仍然是 `action + resources`，并把“始终允许”按项目持久化

文件：

- [`packages/core/src/permission.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/core/src/permission.ts)
- [`packages/core/src/permission/saved.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/core/src/permission/saved.ts)

V2 把 V1 的名字调整为：

```text
permission -> action
patterns   -> resources
always     -> save
allow/ask/deny -> effect
```

核心语义没有变化：仍是对本次 `action` 与每一个 `resource` 求值，默认 ask，明确 deny 优先。保存的 allow 规则按 project 写入数据库，但配置中的 deny 会先执行，saved allow 不能覆盖配置 deny。

这对 Intatis 最有价值的一点是：规则和自动审查都接收结构化操作意图，而不是从 `.write` 猜测真实动作。

### 3.3 `read`：真正读哪个路径，就审批哪个路径

文件：[`packages/opencode/src/tool/read.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/read.ts)

实际顺序：

1. 解析 `filePath`；
2. 判断是否在项目外，必要时先申请 `external_directory`；
3. 再申请：

```text
permission: read
pattern: 相对 worktree 的真实路径
```

4. 获准后才读取。

这里没有因为 agent session 本身拥有目录访问权，就跳过本次 read 权限求值。

### 3.4 `edit` / `write`：审批具体文件，并把 diff 放进 metadata

文件：

- [`packages/opencode/src/tool/edit.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/edit.ts)
- [`packages/opencode/src/tool/write.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/write.ts)

两者都先计算目标文件和 diff，再申请：

```text
permission: edit
pattern: 真实目标文件相对路径
metadata:
  filepath
  diff
```

获准之后才真正写文件。也就是说，权限请求由工具根据已经解析的参数产生，审批者看到的是“要改哪个文件、准备改成什么”，不是一个脱离参数的静态 `.write` 标签。

### 3.5 `task`：创建子 agent 审批的是 agent 类型，不是假装成文件写入

文件：[`packages/opencode/src/tool/task.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/task.ts)

在查找和创建子 session 之前，TaskTool 申请：

```text
permission: task
patterns: [subagent_type]
metadata:
  description
  subagent_type
```

审批的是：当前 agent 能否调用这个类型的 subagent。它没有把创建子 agent 表述为 `edit` 或 workspace write。

获准后，OpenCode 才：

- 查找预先配置的 subagent 类型；
- 创建带 `parentID` 的 child session；
- 派生 child session permission；
- 调用 child prompt；
- 前台等待结果或转成 background job。

这一点直接支持 Intatis 当前已经做对的规则：一个外部 `spawn_agent` ToolCall 只有一次审批，内部 roster/lease/session/task admission 不应再递归发第二次 `agent.attach` 审批。

但 OpenCode 的同步 `ops.prompt()` 和 background job 结构不能直接替换 Intatis 的 scheduler/mailbox/task graph；Intatis 的 durable task 与无嵌套 `AgentLoop` 原则更严格。

### 3.6 subagent 权限派生：可借鉴 deny 传播，但不能照搬最大权限关系

文件：[`packages/opencode/src/agent/subagent-permissions.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/agent/subagent-permissions.ts)

当前实现会把父 session 的以下规则传播给 child：

- 所有 deny；
- `external_directory` 规则。

同时，如果 child 自身没有显式 `task` / `todowrite` 规则，则默认 deny，降低无界递归风险。

值得注意的是，源码注释明确表示：父 agent 的普通限制只约束父 agent，child 的自身配置决定 child 能力。这个模型可能允许 child 在非 deny 项上比 parent 更宽。

Intatis 不应照搬这一点。Intatis 更合适的规则是：

```text
child effective authority
  = child requested authority
  ∩ child configured profile
  ∩ issuer/current-task capability ceiling
  ∩ parent/session hard-deny ceiling
  ∩ workspace confinement
```

任何 child 都不能仅因为自身模板更宽，就超过创建它的 task/agent 当前可授予上限。

### 3.7 agent 默认权限：说明 action/resource 模型可表达模式，但默认值不适合 Intatis

文件：[`packages/opencode/src/agent/agent.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/agent/agent.ts)

固定 commit 中：

- 默认规则以 `* allow` 为基础；
- `doom_loop`、`external_directory` 等再覆盖为 ask；
- plan agent 用 `edit: * deny`，只对计划文件放行；
- explore agent 先 `* deny`，再显式允许 grep/glob/list/bash/webfetch/read 等；
- per-agent 配置继续追加，最后匹配规则生效。

这种规则表达能力值得借鉴；但 `* allow` 的安全默认不适合 Intatis 的本地多 agent、自动审批和 durable side-effect 模型。Intatis 应保留 hard deny、lease ceiling、workspace identity 和 fail-closed 默认。

### 3.8 Bash：OpenCode 当前源码反而证明“不能只看工具名，也不能整套复制”

文件：[`packages/core/src/tool/bash.ts`](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/core/src/tool/bash.ts)

当前 V2 Bash 的权限请求确实使用实际命令：

```text
action: bash
resources: [input.command]
save: [input.command]
```

因此用户可以对 `git status`、`rm *` 等真实命令 pattern 分别设置 allow/ask/deny。这符合“权限性质要根据真正调用的命令决定”的方向。

但是固定 commit 也明确存在以下风险：

- 描述写明 Bash 使用宿主用户的 filesystem/process/network authority；
- 对命令参数中的外部绝对路径只做 token-based advisory warning；
- 源码 TODO 明确尚未移植 tree-sitter Bash/PowerShell parser；
- TODO 明确尚未移植基于命令前缀的 reusable approval；
- 权限系统匹配字符串 pattern，不会自动理解 `rm` 一定是 destructive，除非规则或更上层分类明确表达。

因此 OpenCode 当前 Bash 不能作为 Intatis production raw shell 的直接安全基线。Intatis 继续不暴露 raw `run_shell`、使用 structured tools 和 OS workspace/network confinement 是正确的。

### 3.9 OpenCode 当前存在 V1/V2 双栈，迁移时必须按具体文件判断

固定 commit 中可以同时看到：

- `packages/opencode/src/permission/index.ts`：V1 permission/pattern；
- `packages/core/src/permission.ts`：V2 action/resource；
- `packages/opencode/src/tool/task.ts`：V1 `ctx.ask`；
- `packages/opencode/src/tool/read/edit/write.ts`：V1 `ctx.ask`；
- `packages/core/src/tool/bash.ts`：V2 `PermissionV2.assert`。

所以不能简单说“OpenCode 权限就是某一个文件里的最终设计”，也不能继续引用旧的浮动路径而不固定 commit。适合 Intatis 复用的是稳定的数据模型和测试思想，不是把整个正在迁移的权限 runtime 原样移植到 Swift。

## 4. Intatis 源码逐项检查

### 4.1 `SideEffect` 太窄，却承担了太多责任

文件：`Packages/IntatisCore/Sources/SideEffect.swift`

当前只有：

```text
read_only / write / exec / network / destructive
```

这个枚举目前同时被用于：

- deterministic permission gate；
- workspace read-only lease 检查；
- permission reviewer prompt；
- durable execution event；
- crash replay policy。

但“控制面创建 task”“向另一个 agent 发消息”“授予 child 一个最大 workspace lease”“真的改文件”并不是同一种维度。一个枚举无法准确承载这些含义。

### 4.2 `ToolDescriptor` 是静态分类，真实参数只补充 path/network

文件：`Packages/IntatisTools/Sources/ToolProtocol.swift`

`ToolDescriptor` 静态保存 `sideEffect`。每个工具动态提供的只有：

- `touchedPaths(args)`；
- `risksNetwork(args)`。

然后 `AgentLoop` 把静态 side effect、动态 path/network 和 raw args 拼成 `ToolCallContext`。

缺少的是一个由工具根据参数生成的结构化权限意图，例如：

```text
action: agent.spawn
resources: [agent:counter, workspace:/path]
metadata: requestedCapabilities/readOnly/canCoordinate/model/task
```

### 4.3 `AgentLoop` 的 lease 检查把 `.write` 直接等价为 workspace 可写性

文件：`Packages/IntatisAgentKernel/Sources/AgentLoop.swift`

当前 `workspaceLeaseFailure` 在 lease 为 read-only 时，只要 descriptor 不是 `.readOnly` 就拒绝：

```text
lease.access == readOnly && descriptor.sideEffect != readOnly
  -> workspace lease is read-only
```

这对 `write_file` 合理，对 `spawn_agent` 则不准确。`spawn_agent` 是否能创建控制面对象，应由 coordinator capability/delegation budget 决定；它是否能附加新 workspace，应由 workspace attach 权限决定；它不应因为当前 agent 的文件 lease 是 read-only 就被粗暴解释成“准备写文件”。

`AgentLoop` 后续的 durable prepare/settle、权限等待后 root identity 复核和执行前再次复核是正确设计，应保留。

### 4.4 `DeterministicPolicyGate` 只能看到粗粒度 side effect

文件：`Packages/IntatisPermission/Sources/DeterministicPolicyGate.swift`

当前 gate 对 `.write` 的逻辑是：

- read-only profile：hard deny；
- 保护配置路径：high-risk ask；
- manual/reviewed/autopilot：ask，原因固定为 `write to workspace`。

因此，只要 `spawn_agent` 被标为 `.write`，gate 就不可能生成准确的 `create subagent` 或 `attach workspace` 风险说明。

另一方面，Shell 路径已经比纯静态 side effect 更接近用户期望：`ShellInspector` 会从 raw args 取出 command，识别危险命令、网络/安装风险和有限的只读命令。这说明 Intatis 已经接受“真实参数决定权限”的原则，只是该原则尚未推广到所有工具。

### 4.5 文档里的“3 层门”和当前实际执行存在一处重要差异

文件：

- `Packages/IntatisPermission/Sources/PermissionEngine.swift`
- `Packages/IntatisPermission/Sources/ModelPermissionReviewer.swift`

`PermissionEngine` 只有在 gate 返回 `.pass` 时才调用 `ModelPermissionReviewer`。但当前 `DeterministicPolicyGate.evaluate` 对所有 `SideEffect` 分支都直接返回 allow/ask/deny，没有任何正常路径返回 `.pass`。

所以使用标准 gate 时，`ModelPermissionReviewer` 这一“Layer B”实际上不可达。Cowork 当前真正的自动模型审批不是这里，而是：

```text
DeterministicPolicyGate
  -> PermissionEngine.askUser
  -> AgentLoop PermissionResponder
  -> AgentPermissionResponder
  -> PermissionReviewControlPlane
```

这和项目文档中容易被理解为“gate -> ModelPermissionReviewer -> PermissionEngine -> responder”的描述不完全一致。后续修复应明确只保留一个模型审查位置，避免两套 reviewer 抽象继续并存。

### 4.6 Cowork 自动审查控制面的可靠性设计是对的，输入语义是错的

文件：

- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift`
- `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`
- `Packages/IntatisProtocol/Sources/PermissionReview.swift`

已经做对的部分：

- 独立 FIFO/single-flight；
- 不占普通 scheduler slot；
- reviewer 无工具，不运行嵌套 AgentLoop；
- queue/timeout/output 有界；
- request/settled durable-first；
- allow 只有 settled 写入成功后生效；
- timeout、cancel、malformed、tool call、provider failure 均 fail closed；
- token budget 是 soft warning，不关闭 reviewer；
- hard deny 和 self-review 不能放行。

问题在于 `PermissionReviewTask` 接收的仍是：

```text
tool + raw args + touchedPaths + risksNetwork + sideEffect + gate reason
```

当上游把 `spawn_agent` 错标成 `.write` 后，控制面只是在可靠地审批一份语义错误的请求。

源码中仍保留 `fallback` 字段和 `.fallback` completion 分支，但当前所有 `persistTerminal` 调用都传 `fallbackRequest: nil`，因此自动模式实际不会进入人工 fallback。这与当前产品方向一致，但残留代码会增加理解成本，后续可以在不改变行为的前提下清理。

### 4.7 `spawn_agent` 的当前错误是被源码和测试共同锁定的

文件：`Packages/IntatisCowork/Sources/CoordinatorTools.swift`

当前明确定义：

```text
SpawnAgentTool.sideEffect = write
touchedPaths = [args.path]
```

文件：`Packages/IntatisCowork/Tests/IntatisCoworkTests.swift`

测试 `testSpawnAgentDescriptorIsNotReadOnly` 明确断言它必须等于 `.write`。

文件：`Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift`

测试明确断言：

- reviewer 只审批一次 `spawn_agent`；
- 不再审批内部 `agent.attach`；
- reviewer context 的 touched path 等于 child workspace；
- 允许后原子提交 child capability/workspace lease。

“只审批一次、内部 admission 原子完成”是正确的；“这一次审批必须叫 workspace write”是错误的。修复应保留前者，替换后者。

### 4.8 child 默认 lease 进一步放大了误解

文件：`Packages/IntatisCowork/Sources/Orchestrator.swift`

`spawnFromTool` 创建 child 时：

- profile 固定 `.reviewed`；
- worker 通过 capability lease 去掉 coordinator 工具；
- 但 `prepareDefaultLeases` 无论 worker/coordinator，都创建 `.readWrite` 的默认 WorkspaceLease；
- 真正委派普通 worker task 时，task-scoped WorkspaceLease 才派生为 `.readOnly`；
- coordinator task 才派生 `.readWrite`。

因此“child admission 带 readWrite default workspace lease”确实存在，但它仍只是 future authority ceiling，不是当前文件写批准。

更干净的最小闭环是：

- 普通 `spawn_agent` 默认 child workspace lease 为 read-only；
- task contract 需要写入时，再显式申请 task-scoped readWrite lease；
- `canCoordinate` 与 workspace write 必须完全解耦；
- 如果产品需要预创建可写 teammate，也要通过 `requestedAccess: read_write` 明确表达，而不是静默默认。

### 4.9 同一个问题也出现在消息与委派工具上

文件：

- `Packages/IntatisCowork/Sources/CommunicationDelegationTools.swift`
- `Packages/IntatisCowork/Sources/AskAgentTool.swift`

当前分类：

| 工具 | 当前 `SideEffect` | 实际行为 |
|---|---:|---|
| `send_message` | read_only | 持久化消息并触发 mailbox 行为 |
| `request_information` | read_only | 发送持久化信息请求 |
| `reply_message` | read_only | 发送持久化回复 |
| `request_delegation` | read_only | 产生控制面请求 |
| `ask_agent` | write | 创建/运行 durable task 并回传答案 |
| `delegate_task` | write | 创建 task，可能创建 worker |
| `spawn_agent` | write | 创建 roster/lease/agent 状态 |
| `remove_agent` | write | 撤销 roster/lease 状态 |

这张表证明 `read_only/write` 已经不再表示真实文件访问：一部分控制面副作用被当作 read-only 自动允许，另一部分又被当作 workspace write 送审。

`ToolExecutionReplayPolicy` 已经用“工具名黑名单”补偿，要求这些通信/生命周期工具人工对账。这进一步证明权限分类与恢复分类本来就是两个维度，不应继续共用 `SideEffect`。

## 5. OpenCode 与 Intatis 精确对照

| 议题 | OpenCode 固定 commit | Intatis 当前 | 判断 |
|---|---|---|---|
| 权限请求主键 | action/permission + resource/pattern | static sideEffect + tool name | OpenCode 模型更适合规则和 UI |
| 文件读取 | `read` + 真实路径 | `.readOnly` + touched path | Intatis可保留 confinement，但应增加 action/resource |
| 文件写入 | `edit` + 真实路径 + diff metadata | `.write` + touched path + raw args | Intatis reviewer 缺少显式 diff/operation schema |
| shell | `bash` + 实际 command string | production 不暴露 raw shell；保留 ShellInspector | Intatis安全边界更好，不复制 OpenCode host-authority Bash |
| 创建 subagent | `task` + subagent type | `.write` + workspace path | Intatis把控制面错误表述成文件写入 |
| child 工具能力 | child agent permission rules | CapabilityLease 工具可见性 | Intatis lease 更结构化，应保留 |
| child workspace | external_directory rules | WorkspaceLease root/access/path identity | Intatis更强，应保留并与单次批准解耦 |
| parent deny 传播 | deny + external directory | hard deny + lease ceiling | Intatis应保证 child 不超过 issuer ceiling |
| 自动审批 | 官方权限服务等待 once/always/reject；auto 语义主要是 ask 处理策略 | 独立模型 reviewer，allow/deny-only，durable-first | Intatis差异化设计可保留 |
| crash recovery | session/job 机制 | durable prepare/settle + manual reconciliation | Intatis更严格，应保留 |
| 默认安全性 | 多数 action 默认 allow | workspace/profile/lease + hard deny | 不复制 OpenCode permissive defaults |

## 6. 应采用的目标权限模型

### 6.1 新增每次调用的 `PermissionIntent`

建议不要让权限层直接解释完整工具参数，而是由每个工具在执行前生成结构化、可审计的意图：

```swift
struct PermissionIntent {
    let action: String
    let resources: [PermissionResource]
    let metadata: [String: JSONValue]
    let risks: Set<PermissionRisk>
    let suggestedPersistentRules: [PermissionRulePattern]
    let recovery: ToolExecutionReplayPolicy
}
```

示例：

```text
list_files
  action: filesystem.read
  resources: [workspace:/Sources/**]
  risks: []

write_file
  action: filesystem.edit
  resources: [workspace:/Sources/App.swift]
  metadata: diff summary / bytes / create-or-replace
  risks: [workspace_mutation]

spawn_agent
  action: agent.spawn
  resources:
    agent:name=counter
    workspace:/Users/.../Intatis
  metadata:
    model=...
    requestedAccess=read_only
    canCoordinate=false
  risks: [control_plane_mutation, capability_grant]

delegate_task
  action: task.delegate
  resources: [agent:auto-or-name, workspace:current]
  metadata: role/deliverable/task budget
  risks: [control_plane_mutation, model_cost]
```

### 6.2 `SideEffect` 不再作为唯一权限语义

可以保留 `SideEffect` 兼容旧事件和 recovery，但至少拆出：

```text
DataEffect:
  none / read / mutate / execute / network / destructive

ControlEffect:
  none / message / create_task / create_agent / remove_agent / grant_capability

ReplayPolicy:
  safe / idempotent_with_key / requires_reconciliation
```

权限 gate 使用 `PermissionIntent`；EventLog 继续追加兼容字段，不能破坏旧 JSONL。

### 6.3 Lease 只做上限，不做批准

建议明确以下不变量：

```text
CapabilityLease says which tools may be offered.
WorkspaceLease says where and at what maximum access level they may operate.
PermissionIntent says what this invocation will actually do.
PermissionDecision authorizes only this invocation or an explicit matching rule.
```

因此：

- `WorkspaceLease.readWrite` 不会让任何写工具自动执行；
- `spawn_agent` 获准不会顺带批准 child 未来全部写入；
- child 每次 `write_file`/Git/network 仍产生自己的 intent；
- child intent 还必须落在 child lease、issuer ceiling 和 hard deny 的交集内。

### 6.4 自动 reviewer 的职责

全自动权限审批可以继续，但应按以下顺序：

```text
Tool schema validation
  -> capability visibility check
  -> workspace/path confinement ceiling
  -> deterministic intent rule evaluation
       deny: final
       allow: execute
       ask: automatic model reviewer
  -> reviewer allow/deny only
  -> durable settled commit
  -> revalidate root/lease
  -> durable execution prepare
  -> execute
```

自动 reviewer 只判断：这个已经在硬边界内的具体 intent 是否与当前 task 相符。它不能：

- 把 external workspace 变成合法 workspace；
- 把 read-only lease 提升成 readWrite；
- 给 worker 增加 coordinator capability；
- 覆盖 sensitive path、shell disabled 或 hard deny；
- 用自然语言批准一个结构化资源之外的额外动作。

### 6.5 `spawn_agent` 的目标流程

建议的最小行为：

```text
main calls spawn_agent
  -> validate name/model/path/canCoordinate/requestedAccess
  -> confirm main has agent.spawn capability + delegation budget
  -> canonicalize workspace
  -> if workspace is outside issuer's existing allowed roots:
       add separate workspace.attach resource/risk
  -> generate one PermissionIntent(action=agent.spawn)
  -> automatic reviewer allow/deny
  -> one durable atomic admission batch
  -> child starts with requested/default lease ceiling
  -> later child tools are approved independently
```

默认建议：

- same-workspace worker：`read_only`；
- `canCoordinate=false`；
- 空 coordinator tool lease；
- 需要写文件的 task 再申请 task-scoped readWrite；
- 显式 `requestedAccess=read_write` 才审批能力扩大；
- 创建到新目录时审批 `workspace.attach`，不是伪装成当前 workspace write。

## 7. 不建议的“快速修复”

以下修改看起来能消除截图报错，但会产生新的安全问题：

### 7.1 只把 `spawn_agent` 改成 `.readOnly`

错误原因：它仍会创建 agent、lease、roster 和持久事件，并可能扩展 workspace/capability。改成 read-only 会让 deterministic gate 自动放行。

### 7.2 给 reviewer prompt 加一句“spawn_agent 不是写文件”

错误原因：底层 request 仍是 `.write`，workspace lease 检查、gate reason、risk、EventLog 和 UI 仍然错误；只是要求模型抵消结构化数据。

### 7.3 spawn 时不给 child lease，等第一次工具调用再挂载

错误原因：agent session 没有明确最大边界，恢复和工具 registry 无法可靠构造。正确做法是创建受限 ceiling，而不是取消 ceiling。

### 7.4 直接复制 OpenCode permission runtime

错误原因：OpenCode 正处于 V1/V2 迁移，默认规则更宽，child 权限关系不同，Bash V2 使用宿主权限，且不包含 Intatis 的 durable review、root identity、scheduler 和 EventLog 不变量。

## 8. 建议的升级顺序

### Phase 0：先修正设计契约，不改行为

- 定义 `PermissionIntent`、`PermissionResource`、`PermissionRisk`；
- 明确 Lease/Intent/Decision/Replay 四者边界；
- 更新文档中“3 层门”的真实执行图，说明 Cowork reviewer 位于 responder 层；
- 标记 `ModelPermissionReviewer` 当前不可达，决定删除、合并还是重新接入，但不要保留两套模糊模型审查链。

### Phase 1：给现有文件工具增加 intent adapter

- `read/list/search` -> filesystem.read + 实际路径；
- `write/apply_patch` -> filesystem.edit + 实际路径 + diff metadata；
- Git/browser/document 工具生成各自 action/resource；
- 暂时从旧 SideEffect 派生兼容字段，保持事件可解码。

### Phase 2：修正 Cowork 控制面工具

- `spawn_agent` -> agent.spawn；
- `remove_agent` -> agent.remove；
- `delegate_task` / `ask_agent` -> task.delegate/task.ask；
- message tools -> agent.message/information.request/reply；
- 不再用 `.readOnly` 表示“不会写工作区”；
- ReplayPolicy 独立保留 manual reconciliation。

### Phase 3：修正 child 默认 authority

- 普通 worker 默认 workspace read-only；
- coordinator capability 和 workspace write 分离；
- 加入显式 `requestedAccess` 或 task lease upgrade；
- child effective authority 不得超过 issuer/task ceiling；
- 新 workspace 与同 workspace 采用不同 resource/risk。

### Phase 4：规则引擎与自动 reviewer 消费 intent

- deterministic rule 支持 action + resource wildcard；
- hard deny 先于 saved/session allow；
- reviewer prompt/JSON 直接携带 intent，不再让模型从 raw args 猜；
- UI 显示“创建只读 worker”“附加新目录”“写入文件”“运行网络操作”等真实文案；
- 自动模式保持 allow/deny-only、异常 fail closed、soft budget。

### Phase 5：清理与兼容

- 旧 `SideEffect` 仅保留事件兼容或迁移为派生字段；
- 清理当前不可达 `ModelPermissionReviewer` 或合并成唯一 reviewer；
- 清理自动 reviewer 中实际不可达的 human fallback 分支；
- 旧 JSONL 缺 intent 时按旧 tool/sideEffect 保守投影，不能改变历史决定；
- 不改变 Envelope、seq、durable prepare/settle 和 permission review 事件追加语义。

## 9. 必须补齐的验收测试

### 9.1 `spawn_agent`

- same-workspace read-only worker 的 intent 是 `agent.spawn`，不是 `filesystem.edit`；
- reviewer UI/prompt 不出现 `write to workspace`；
- 一个 spawn 仍只有一个权限决定；
- admission 内部不再触发 `agent.attach` 二次审批；
- deny 时不创建 roster/lease/agent events；
- allow 但 durable settled/admission 失败时不创建 child；
- child 后续 `write_file` 仍单独 ask/auto-review；
- child 后续 `list_files` 可按 read rule 允许；
- requested readWrite 和 `canCoordinate` 分别审批、互不隐含；
- external workspace 额外显示 workspace attach risk。

### 9.2 消息与委派

- `send_message` 不再因为 `.readOnly` 被误当成本地只读文件操作；
- message intent 经 capability + mediator + durable event；
- `delegate_task` 使用 task resource，不显示 workspace write；
- replay policy 仍要求非幂等控制面调用对账；
- worker 无 delegation capability 时 hard deny，不进入 reviewer。

### 9.3 Lease 与真实操作

- readWrite lease 不能跳过 write intent 审批；
- read-only lease 对真实 edit hard deny；
- read-only agent 仍可在显式 lifecycle capability 下创建只读 worker（如果产品决定允许）；
- root identity 在 review wait 和 durable prepare 后仍复核；
- denied path、sensitive path、external root 永远不能被 reviewer 放宽。

### 9.4 自动 reviewer

- reviewer 收到 action/resources/metadata/risks，而非只有 sideEffect；
- malformed/tool-call/timeout/provider failure 都只 deny 当前 intent；
- allow 必须在 settled 成功后返回；
- soft token threshold 不关闭 reviewer；
- 没有隐式人工 fallback；
- 同一 denied intent 的 circuit breaker 仍工作。

## 10. 对此前报告的修正

仓内已有 `codex-report/07_12_26-16_25-opencode-cowork-orchestration.md`，其总体产品方向仍成立：

- 一切外部能力都通过工具调用；
- Code 是 Cowork 中每个 agent 的单 agent runtime 基础；
- `spawn_agent` 只做一次外部审批，内部 admission 原子完成；
- Intatis 保留 scheduler/mailbox/EventLog/Lease，而不复制 OpenCode 的同步嵌套执行。

但其中权限章节需要以本报告为准修正：

1. 旧报告引用了 OpenCode 浮动 `dev` 路径，部分路径已经变化；本报告固定了具体 commit。
2. OpenCode 当前同时存在 V1/V2 权限栈，不能再描述为单一稳定 service。
3. 旧报告强调 `spawn_agent` “不是 read-only”是对的，但不应进一步推导为“所以它是 workspace write”。正确类别是 agent/task/control-plane mutation。
4. OpenCode 新 Bash V2 当前没有完成旧 parser/reusable-prefix 能力迁移，且宿主权限更宽；不能作为 Intatis raw shell 的直接复用候选。
5. Intatis 当前最大问题不是权限门数量不足，而是权限门收到的 operation intent 不准确。

## 11. 最终产品方向

Intatis 的权限系统不应回答一个模糊问题：

> “这个工具总体上像不像写操作？”

它应回答：

> “这个 agent 在这个 task 和 lease 上限内，现在要对这些明确资源执行这个明确动作；规则是否允许，若需要语义判断，自动 reviewer 是否批准这一次 intent？”

对于用户当前的例子，正确表达应当是：

```text
@main wants to create a read-only worker named counter
workspace: current Intatis project
coordination: disabled
requested capabilities: read/list/search
purpose: count Swift and text files
```

而不是：

```text
write to workspace
```

子 agent 真正执行 `list_files` 时，这是 read；真正执行 `write_file` 时，这是 edit；真正执行危险命令时，由具体命令和资源决定；真正扩展 workspace 或 capability 时，这是 attach/grant。权限系统只有把这些动作分开，自动审批才会既可用又可信。

## 12. 源码索引

### OpenCode（固定 commit）

- [V1 permission service](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/permission/index.ts)
- [V2 permission service](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/core/src/permission.ts)
- [V2 saved permission rules](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/core/src/permission/saved.ts)
- [Tool permission context](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/tool.ts)
- [Read tool](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/read.ts)
- [Edit tool](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/edit.ts)
- [Write tool](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/write.ts)
- [External directory permission](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/external-directory.ts)
- [Task/subagent tool](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/tool/task.ts)
- [Subagent permission derivation](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/agent/subagent-permissions.ts)
- [Agent default permission rules](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/opencode/src/agent/agent.ts)
- [V2 Bash tool](https://github.com/anomalyco/opencode/blob/34e58090595d44e3e7cc37498f16753a98627456/packages/core/src/tool/bash.ts)
- [OpenCode permission documentation](https://opencode.ai/docs/permissions/)
- [OpenCode agent documentation](https://opencode.ai/docs/agents/)

### Intatis（本地当前源码）

- `Packages/IntatisCore/Sources/SideEffect.swift`
- `Packages/IntatisTools/Sources/ToolProtocol.swift`
- `Packages/IntatisPermission/Sources/PermissionTypes.swift`
- `Packages/IntatisPermission/Sources/DeterministicPolicyGate.swift`
- `Packages/IntatisPermission/Sources/PermissionEngine.swift`
- `Packages/IntatisPermission/Sources/ModelPermissionReviewer.swift`
- `Packages/IntatisAgentKernel/Sources/AgentLoop.swift`
- `Packages/IntatisCowork/Sources/CoordinatorTools.swift`
- `Packages/IntatisCowork/Sources/CommunicationDelegationTools.swift`
- `Packages/IntatisCowork/Sources/AskAgentTool.swift`
- `Packages/IntatisCowork/Sources/AgentPermissionResponder.swift`
- `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`
- `Packages/IntatisCowork/Sources/Orchestrator.swift`
- `Packages/IntatisProtocol/Sources/PermissionReview.swift`
- `Packages/IntatisProtocol/Sources/ToolExecution.swift`
- `Packages/IntatisCowork/Tests/IntatisCoworkTests.swift`
- `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift`
- `Packages/IntatisCowork/Tests/SpawnAgentPermissionTests.swift`
- `Packages/IntatisAgentKernel/Tests/AgentLoopPolicyTests.swift`

## 13. 审计状态

### MODEL_CHECK_RESULT

当前执行模型：Codex（界面未向当前进程提供更精确的底层模型版本，无法进一步确认）。

### PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- Git root：`/Users/vita/Vitemis/Intatis`
- 两者匹配预期。

### FILES_WRITTEN

- `codex-report/07_12_26-20_37-opencode-permission-source-audit.md`

未修改任何 `Apps/`、`Packages/`、测试、工程配置或项目文档。

### PROJECT_AUDIT_SUMMARY

当前权限故障由静态 `SideEffect` 对控制面工具的错误建模引起；Cowork 自动 reviewer 的队列、durability、fail-closed 和无嵌套 AgentLoop 机制本身无需推倒重做。应替换 reviewer 之前的权限意图模型，并保留 Lease、PathConfinement、durable execution ticket 与 EventLog 边界。

### DOCS_CONTENT_SUMMARY

本报告记录了固定 OpenCode commit 的逐文件权限行为、Intatis 对应源码、截图的精确成因、不可直接复制的上游风险、目标权限模型、迁移顺序和验收测试。

### VALIDATION_RESULT

这是只读审计/Markdown 报告任务。完成后仅运行：

- `git diff --check -- codex-report/07_12_26-20_37-opencode-permission-source-audit.md`
- `git status --short`

未运行构建/测试；没有修改业务源码。

### UNCERTAINTIES

- OpenCode `dev` 正在持续迁移 V1/V2；本报告只对固定 commit 有效。
- OpenCode V2 agent/task 全量切换时序没有在本报告中穷尽，不能把当前双栈视为最终公共 API。
- Intatis 后续到底保留 `ModelPermissionReviewer` 作为规则层 reviewer，还是统一到 Cowork `PermissionResponder` 控制面，需要实现前做一次单一职责决定。
- child 默认是否永远 read-only，或允许 task contract 明确请求 readWrite，属于产品策略；本报告建议最小闭环默认 read-only。
- 本轮未发送真实 DeepSeek/OpenRouter 请求，因此没有验证修正后的 reviewer 文案和真实模型判定质量。

### NEXT_RECOMMENDED_ACTION

下一步先写一个不改行为的 `PermissionIntent` 协议草案和迁移测试表，确认 action/resource 命名、旧 EventLog 兼容和 reviewer 唯一入口；确认后再修改业务源码。不要先做 `spawn_agent -> .readOnly` 的单点补丁。
