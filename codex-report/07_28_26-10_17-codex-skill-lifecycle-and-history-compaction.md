# Codex Skill 生命周期与替换式历史压缩源码审计及 Intatis 对齐报告

## 报告元数据

- 审计日期：2026-07-28
- Intatis 仓库：`/Users/vita/Vitemis/Intatis`
- 上游仓库：OpenAI Codex
- 固定上游 commit：`bd2de422aa287b97b06ca6425a10935bcf1b3731`
- 上游 commit 时间：2026-07-27T14:31:50Z
- 上游 commit 标题：`Parse Claude and Cursor session records separately (#35623)`
- 审计性质：公开源码行为审计、Intatis 差异分析、实施合同
- 本报告不复制 Codex 的 compact prompt、Skill prompt、测试快照或大段源码；只记录公开行为、类型边界、控制流和验证要求。

## 执行结论

六项批评中，真正应优先处理的不是“为 Skill 另造一套激活状态机”，而是审计
开始时 Intatis 尚未完成的、Codex 式通用模型历史压缩与可恢复替换检查点。本轮
已按后文边界完成稳定 Code conversation 与 Cowork `@main` 的本地 lifecycle
主链，也完成了 catalog 自适应预算/计量和严格 MCP dependency preflight 的
P1 受限范围；
未完成的上游差异仍逐项列在第十五节，不能把这些主链完成扩大为全部 Codex
runtime 等价。

Codex 没有为 Skill 建立 Session 级 activated ledger、TTL、卸载表或跨 Turn
激活状态。它明确把 Skill 语义限定在当前 Turn，但完整 Skill 正文仍作为普通
模型历史项进入本次 rollout；在发生通用历史压缩前，该正文仍会占用后续请求
上下文。Codex 的实际解决办法是：

1. 当前 Turn 按需读取完整 `SKILL.md`，不把 Skill 语义自动带到下一 Turn；
2. 使用通用 90% 自动压缩阈值与 95% 有效上下文硬边界；
3. 在 pre-turn 或需要继续采样的 mid-turn 执行压缩；
4. 用“最多 20,000 token 的真实用户消息 + 一份新摘要”替换旧历史；
5. 将完整 replacement history 和 window chain 持久化为压缩检查点；
6. 恢复时从最新有效检查点开始，只正向重放其后的存活尾部。

因此，本轮建议排序为：

- **P0（本轮已完成主链）**：实现 Intatis 的通用、durable、可恢复
  replacement-history compaction，覆盖稳定 Code conversation 与 Cowork
  `@main`，并让长工具循环具备 mid-turn 压缩能力。
- **P1（本轮已完成受限范围）**：补齐 Codex Core 的 Skill catalog 自适应
  预算、omission/truncation warning/metrics，以及 MCP-only Skill dependency
  metadata 与 request-owned 缺失检测。Intatis 没有实现 Codex 的
  Install/Continue-anyway、OAuth、外部配置写入和 runtime refresh。
- **P2**：基于实测再决定是否引入动态 Skill 召回；同名冲突 UX、文件变化通知、
  任意二进制/语言包 preflight 和脚本路径便利化也属于 P2。
- **不应实施**：绕过现有 Managed Terminal、CapabilityLease、WorkspaceLease、
  PermissionEngine 或 durable tool execution 的“Skill 专用免审执行环境”。

## 一、审计依据与方法

### 1.1 上游固定方式

本报告只以固定 commit
[`bd2de422aa287b97b06ca6425a10935bcf1b3731`](https://github.com/openai/codex/tree/bd2de422aa287b97b06ca6425a10935bcf1b3731)
为事实依据，不用 floating `main` 推断行为。

重点检查的上游路径包括：

- `codex-rs/core-skills/src/render.rs`
- `codex-rs/core-skills/src/injection.rs`
- `codex-rs/core-skills/src/skill_instructions.rs`
- `codex-rs/core-skills/src/service.rs`
- `codex-rs/skills/src/model.rs`
- `codex-rs/app-server/src/skills_watcher.rs`
- `codex-rs/core/src/session/turn.rs`
- `codex-rs/core/src/session/context_window.rs`
- `codex-rs/core/src/compact.rs`
- `codex-rs/core/src/session/mod.rs`
- `codex-rs/core/src/session/rollout_reconstruction.rs`
- `codex-rs/core/src/state/auto_compact_window.rs`
- `codex-rs/protocol/src/openai_models.rs`
- `codex-rs/protocol/src/protocol.rs`
- `codex-rs/protocol/src/compacted_item.rs`
- `codex-rs/core/src/mcp_skill_dependencies.rs`
- `codex-rs/ext/skills/src/dynamic_skill_selector.rs`
- `codex-rs/ext/skills/src/shadow_selection_experiment.rs`
- `codex-rs/core/tests/suite/compact.rs`
- `codex-rs/core/tests/suite/compact_remote.rs`

### 1.2 Intatis 对照范围

本报告同时核对了当前工作树中的：

- `Packages/IntatisSkills/Sources/SkillCatalogService.swift`
- `Packages/IntatisSkills/Sources/SkillTypes.swift`
- `Packages/IntatisSkills/Sources/SkillMCPDependencies.swift`
- `Packages/IntatisSkills/Sources/SkillTools.swift`
- `Packages/IntatisTools/Sources/MCPToolAvailabilitySnapshot.swift`
- `Packages/IntatisAgentKernel/Sources/AgentRequestToolSnapshot.swift`
- `Packages/IntatisMCP/Sources/MCPConnection.swift`
- `Packages/IntatisMCP/Sources/MCPProductionRuntime.swift`
- `Packages/IntatisSkills/Tests/IntatisSkillsTests.swift`
- `Packages/IntatisAgentKernel/Sources/ContextBuilder.swift`
- `Packages/IntatisAgentKernel/Sources/AgentModelHistoryProjector.swift`
- `Packages/IntatisAgentKernel/Tests/SkillDurableActivationTests.swift`
- `Packages/IntatisCowork/Sources/Orchestrator.swift`
- `Apps/IntatisMac/Sources/CodeViewModel.swift`
- `Apps/IntatisMac/Sources/CoworkViewModel.swift`
- `Apps/intatis-cli/Sources/Interactive.swift`
- `docs/ARCHITECTURE.md`
- `docs/CURRENT_STATE.md`
- `docs/NEXT_TARGET.md`
- `docs/OPEN_SOURCE_REUSE.md`

源码、测试和文档冲突时，本报告以当前源码和测试合同为准。

## 二、六项批评逐项判定

### 2.1 Skill 数量扩展性

**判定：核心风险属实，但“只是直接拼接并粗暴截字符串”的描述不准确。优先级：
P1；向量检索本身为 P2。**

审计开始时 Intatis 默认使用固定 8,000 字符；本轮已经按 pinned Codex Core
预算语义改为使用 exact profile 的 canonical primary `contextWindowTokens`：
Codex `context_window` 优先，缺失时可由显式 OpenCode `limit.context` 补位。
primary 存在时 metadata budget 为
`max(1, floor(primary × 2%))` approximate tokens；两者缺失或非法时才回退
8,000 字符。不会按 model slug、`max_context_window` 或 compaction 窗口猜
预算，也没有把 ext/skills 路径的额外 4k cap 混进 Core 合同。`limit.context`
补位是 Intatis compatibility adapter，不应误写成 Codex Core 原始字段行为。

Intatis renderer 继续按 `system → admin → workspace → user → additional`
排序，计算最小条目成本，再公平分配 description；若最小条目也放不下，会省略
后排 Skill 并输出 omitted marker。预算只计算 metadata 行，不包含 trusted
developer envelope。冻结 snapshot 还保存 count-only
total/kept/omitted/truncated/rendered-cost metrics 与 warning，不包含名称、路径、
描述、正文或秘密。目前这些 metrics/warning 尚无 App、CLI 或 EventLog
consumer，所以不能写成已经上线的 operational telemetry；renderer 也不是
Codex 的逐字节复制。

所以：

- 这不是任意位置截断，也不是完全没有优先级；
- 但被省略的 Skill 对模型确实不可见，无法被模型主动激活；
- 30～50 个 Skill 是否必然越界取决于名称、source locator 和描述长度，不能只
  用数量断言；规模继续增长后风险真实存在。

Codex 当前也没有彻底消除这个问题。其 Core 路径在原始主 context window
存在时使用约 2% token budget，缺失时回退 8,000 字符；先缩短描述、尝试短
路径 alias，最后仍可能省略完整条目，并发出 warning 与 metrics。固定 commit
另有 ext/skills resolved/max-window + 4k cap 路径；本报告采用 CLI Core 行为，
不把两条实现混写。

Codex 固定 commit 中已有 BM25、character n-gram、RRF 等便宜 selector，但
`SkillSearch` 当前是 shadow-selection experiment：只评估候选召回和命中，
不改变真正 model-visible catalog。因此不能把它描述成已经上线的语义召回，
也不能据此宣称官方已经解决大规模 Skill 可见性。

Intatis 本轮已完成第一阶段预算、marker、warning 与 count-only metrics。下一
合理顺序是先增加受控 host consumer，收集真实 catalog 条目数、omitted 数、
实际激活命中和误召回数据；有实证后再做 bounded lexical/hybrid Top-K。没有
规模与质量数据时不应直接引入 embedding/vector 基础设施。

### 2.2 多轮上下文浪费与 Skill 生命周期

**判定：属实；审计开始时是 P0。本轮已完成下述 bounded main path，不再列为
未实施的当前最高优先级。**

Intatis 的显式唯一 `$name` 正文是当前请求的 contextual fragment；模型主动调用
`activate_skill` 时，完整冻结正文通过普通 tool result 返回。对 Cowork 稳定
`@main` 而言，有界 tool output 会进入 durable `model_history_item`，后续
provider dispatch 可从 EventLog 重建它。在通用压缩落地前，大 Skill 正文会与
普通工具输出一样继续占用上下文。

Codex 也没有 Skill 专用 TTL。官方合同明确要求“除非后续 Turn 再次提及，否则
不要跨 Turn 携带 Skill”，但物理正文仍进入普通 rollout history。Codex 依靠
通用 compaction 将这类 contextual Skill 内容从 replacement history 的“真实
用户消息保留区”排除，只允许摘要模型以自然语言保留仍然重要的任务影响。

因此不建议增加以下状态：

- `activatedSkillsForSession`
- 固定 N Turn TTL
- 自动跨 Turn 复用旧 Skill 正文
- 脱离当前用户意图的 Skill sticky state

这些机制会与 Codex 的 Turn 语义相反，也会制造正文版本、权限版本和 workspace
版本失配。正确方向是本轮已经落地的 replacement-history compaction，而不是
另建 sticky lifecycle。

### 2.3 Skill 与工具链撕裂、内部脚本不可执行

**判定：作为“必须增加 Skill 专用执行器”的结论不成立；脚本路径便利性可列
P2，但不得扩大权限。**

Codex 把 Skill 定义为说明和资源，不把 Skill 目录变成新的执行权限根。文件系统
Skill 若包含 `scripts/`，模型仍通过普通 shell/exec 工具运行或修改脚本，继续
接受 sandbox、approval 和现有工具合同约束。官方 Skill 使用说明明确倾向复用
脚本，但没有为它们提供免审批 runtime。

Intatis 当前的 `activate_skill` / `read_skill_resource` 是受 snapshot 约束的读取
工具；脚本执行仍应走现有 `exec_command` / `write_stdin` Managed Terminal，
并经过：

- ToolRegistry schema；
- CapabilityLease；
- WorkspaceLease 与 PathConfinement；
- PermissionEngine；
- durable prepare/result/settlement；
- sandbox 与 SecretScanner。

这不是“工具链撕裂”，而是必要的能力分层。当前真实边界是：位于未授权全局
Skill 根中的脚本不能仅因 Skill 被发现就获得执行权限。若未来要改善体验，应让
用户显式选择 capability root，或把必要脚本 materialize 到已授权 workspace，
不能让 Skill 读取权限暗中升级成任意本地代码执行权。

### 2.4 同名 Skill、目录覆盖与冲突

**判定：原批评对当前实现的描述大部分不属实；可观测性与配置 UX 为 P2。**

Intatis 的 `seenSkillFiles` 只按 canonical file path 去重，不按 Skill name 或
opaque ID 把不同来源互相覆盖。来自 workspace 与 user 的同名 Skill 会同时保留、
获得不同 ID；显式 `$name` 遇到多义时拒绝整个显式激活，并要求用户消歧。它不是
“全局同名项 first-seen 后静默压掉项目项”。

Codex 固定 commit 的合同相同：

- skill root 按明确 config-layer/input 顺序合并；
- 同一物理 path 由 first root 获胜；
- repo 与 user 中的同名 Skill 同时保留；
- 不做 ESLint 风格继承合并。

现有缺口是 UI/诊断层没有把同名来源关系解释得足够直观，也没有显式的
“禁用此来源”或“按 path 选择”配置体验。可以在 P2 增加冲突诊断和 enable/disable
规则，但不应先实现隐式 merge，因为 Skill 指令合并会产生不可预测语义和权限
误解。

### 2.5 环境依赖预检

**判定：审计开始时 Intatis 缺口属实；本轮已完成更窄的 MCP-only P1。
原批评要求的通用 `uv`/`gdb`/Python 包 preflight 仍超出 Codex 当前能力，属于
P2。**

Codex 则从 `agents/openai.yaml` 读取 `dependencies.tools`，但当前正式支持的
类型只有 MCP。对被提及的 Skill，feature 开启时会：

1. 计算缺失 MCP server；
2. 避免重复提示；
3. 在需要时请求用户确认；
4. 写入 MCP 配置；
5. 必要时进行 OAuth；
6. 刷新当前 runtime MCP servers。

这不等于通用 OS/package preflight。Codex 没有用一套通用 schema 保证 `uv`、
`gdb`、Python module、Xcode SDK 或任意二进制都已存在。

Intatis 本轮增加了有界、严格的 `agents/openai.yaml`
`dependencies.tools` 子集，只接受 `type: mcp`、exact server ID，以及受限
`stdio` 绝对 canonical executable 或无 credential/query/fragment 的 HTTPS
locator。snapshot 只保存不可逆 locator fingerprint，machine metadata 按
ASCII 大小写不敏感从 generic resources 排除；无效 metadata 只使实际选择的
Skill fail closed，不污染无关 Skill。

缺失检测不读取 process-global config 或 live registry。显式 `$name` 在正文
注入前冻结首个 ordinary provider request 的 dynamic tool snapshot；tool-driven
`activate_skill` / `read_skill_resource` 使用 request-owned snapshot；该
request 的 response 选择了对应 Skill tool。只有 exact server ID 与
transport-locator fingerprint 作为一对出现在
该 host-attested frozen availability 中才通过。production host 只从同一
request 经过 capability/policy 过滤的 agent-visible tool entries 派生该
assertion，因此 server 至少需要贡献一个可见 tool；低层 `.frozen` factory
只验证 shape/pairing，不自证网络连接。无 MCP host、同名 server 改 endpoint、
旧 generation 或无法形成 assertion 均 typed fail closed。raw endpoint、
command、header、credential 和 query 不进入 model-visible availability。

这不是 Codex dependency 全流程等价：Intatis 当前没有 Install/Continue
anyway、OAuth、外部配置写入或 runtime refresh，也没有通用 binary/package
schema。若未来补这些外部变更，必须另行设计版本约束、可信来源、权限、durable
admission、平台差异、离线行为和供应链审计，不能把 preflight 顺手扩成静默
自动安装器。

### 2.6 热加载与实时更新

**判定：“必须重启对话或 Session 才能看到更新”不属实；P2 可补通知，不是
运行阻塞项。**

Intatis 当前没有 watcher，但 `SkillCatalogService.snapshot()` 本身不缓存。
Code 每次 send、Cowork 每次 AgentInvocation、CLI 每次对应 invocation 都重新
扫描并生成一个 immutable snapshot。正在运行的 invocation 继续使用原 snapshot，
下一次 send/invocation 会看到磁盘变化。

冻结当前 invocation 是正确行为，因为它保证：

- 同一 tool loop 内 catalog、正文、resource 和 registry digest 一致；
- 旧 provider response 不能绑定到更新后的 Skill 正文；
- 执行中修改文件不会制造半旧半新的 authority。

Codex app-server/TUI 另外有递归文件 watcher：本地变化经过约 10 秒节流后清除
service cache，发送 `skills/changed`，后续 Turn 强制 reload；当前正在运行的
Turn 仍不会被中途替换。Intatis 可在 P2 增加同类 UI 通知，但不得把 watcher
事件直接注入正在采样的 invocation。

## 三、Codex 的真实 Skill 生命周期

### 3.1 发现与当前 Turn 快照

Codex 在 Turn 开始阶段使用本轮 metadata snapshot 解析显式 Skill 提及。完整
`SKILL.md` 只在确定使用后读取，体现 progressive disclosure。显式注入被包装为
user-role contextual fragment，而不是 system policy，也不是权限授予。

从语义上看，Skill 只作用于当前 Turn；从物理历史看，该 contextual fragment
仍会进入普通 response history 与 rollout。Codex 没有单独的 activation
repository 或 lifecycle table。

### 3.2 contextual Skill 与真实用户消息的区别

Codex 对 `<skill>` 等 contextual user message 有独立分类。它们可以进入模型
prompt，但不会映射为真实用户 Turn item。压缩时，`collect_user_messages` 只保留
能解析为真实 `UserMessage` 的项目，并排除旧 summary。

由此得到关键合同：

- 压缩前：Skill 正文仍占物理 context；
- 压缩后：Skill 正文不会被当成 20,000 token 的真实用户原文保留；
- 摘要可保留任务所需的结论，但不是正文的无损缓存；
- 后续 Turn 若再次需要 Skill，必须基于新 Turn 的 snapshot 重新读取。

### 3.3 reload 生命周期

Codex 的 service cache 与 watcher 只决定下一个 snapshot 是否重新发现；它们
不改变当前 Turn。Intatis 当前“每次 invocation 新 snapshot”的语义已经满足
正确性，只缺 Codex 的缓存失效通知与 UI 反馈。

## 四、90% / 95% 与压缩触发

### 4.1 两个百分比不能混为一谈

Codex 的两个默认值含义不同：

- **90%**：默认 `total` scope 下 `auto_compact_token_limit` 的软阈值。若模型
  给出自定义阈值且能取得 raw context window，该 model limit 会被 clamp 到 raw
  window 的 90% 以内。实验性的 `body_after_prefix` scope 则把显式 config limit
  当作“当前 window prefix 之后的增长预算”直接使用，不应误套 total-scope
  clamp。
- **95%**：`effective_context_window_percent` 默认值，用于把 raw context window
  换算成模型可用于输入的有效硬边界，为 system/tool/output headroom 留余量。

`context_window_token_status` 在自动预算达到时触发，也会在 95% 有效硬边界达到时
强制触发。默认 total scope 下，90% 通常先发生，所以 95% 不是第二个日常软阈值，
而是独立的 usable-window hard cap。

上游 mid-turn 测试把样本 usage 设为 raw window 的 `95% + 1`，只是保证同时越过
阈值；不能据此把官方默认 auto compact 写成 95%。

### 4.2 pre-turn

Codex 在记录本轮新 user input 与 context update 之前检查旧历史。若旧历史已到
阈值，先压缩旧历史，再捕获本轮 step context、注入 Skill/插件并记录新输入。

上游源码明确留有 TODO：当前 pre-turn 不预估即将加入的新用户消息和 context
diff。因此一个大输入把线程推过阈值时，不一定在同一次首采样前提前压缩。

应保持的精确行为：

- 新用户消息不进入这次 pre-turn compact request；
- compaction 成功后，新输入再进入正常请求；
- 如果上一轮最终答案越过阈值且没有继续采样，压缩通常等到下一次用户 Turn。

### 4.3 mid-turn

Codex 只在模型仍需要 follow-up、已有 pending input，或显式请求新 context
window 时检查 mid-turn rollover。普通最终回答已完成且无后续采样时，不为追求
即时整洁而额外压缩。

mid-turn compaction 必须保留本轮工具调用/输出及当前 world state，使压缩后的
下一次采样仍处于同一个逻辑 Turn。压缩后继续 tool loop，而不是结束后新造 Turn。

## 五、本地 compaction 的 replacement history

### 5.1 compact request

Codex 在 clone 的 history 上追加一个专用 summarization request，再调用模型。
如果 compact request 自身收到 context-window-exceeded，会从 clone 最旧端逐项
删除并重试；这里的 `remove_first_item` 维持 function call/output 配对语义，
不能把 tool output 留成 orphan。原 live history 在成功前不被破坏。

Intatis 不应复制上游 prompt 原文。应独立编写 summary 合同，要求保留目标、已
完成工作、重要决策、未解决项、约束、必要路径/标识、验证证据和下一步，同时
禁止秘密、无关大段工具输出及虚构状态。

### 5.2 成功后的精确布局

Codex 成功后构造的新历史为：

1. 可选 canonical initial context；
2. 从最新向前选择的真实用户消息，合计最多约 20,000 token；
3. 若边界消息超预算，只截取该边界消息的可容纳部分；
4. 恢复为原时间顺序；
5. 最后一项是一条 user-role summary。

旧 summary 不会作为真实用户消息再次保留；Skill contextual fragment、developer
context、tool call/output 和 assistant 原文也不会直接进入 20,000 token 原文区。
它们只有被 summary 模型提炼后才可能留下。

### 5.3 initial context 注入位置

- pre-turn/manual：`DoNotInject`。replacement history 不带初始上下文，并清除
  reference context；下一次普通 Turn 完整重注入。
- mid-turn：`BeforeLastUserMessage`。使用同一 frozen step context 和 world
  state，把 canonical context 插在最后一条真实用户消息之前；若没有真实用户
  消息，则插在 summary/compaction item 之前，保证 summary 仍位于最后。

### 5.4 精度边界

Codex 会在完成压缩后告警：长线程与多次压缩会降低准确性。摘要是有损变换，
不能作为 Skill 正文、工具输出、审计记录或 EventLog 的替代。

## 六、checkpoint、window chain 与恢复

### 6.1 新 checkpoint 内容

Codex 的 `CompactedItem` 包含：

- `message`
- `replacement_history`
- `window_number`
- `first_window_id`
- `previous_window_id`
- `window_id`

新 checkpoint 总是写入 `replacement_history: Some(...)`。所有缺失 response item
ID 在构造 checkpoint 前分配，确保 live replacement 与 persisted replacement
完全一致。

window ID 使用 UUIDv7。首次 window 建立 `first_window_id`；每次 advance 增加
`window_number`，旧 `window_id` 成为 `previous_window_id`，再生成新 ID。

### 6.2 resume 算法

Codex 恢复时从新到旧扫描 rollout：

1. 找到最新仍然存活、带 replacement history 的检查点；
2. 取得恢复所需的 Turn settings、reference context、world-state baseline 和
   window metadata；
3. 以 checkpoint replacement history 作为精确 base；
4. 只把 checkpoint 之后的 surviving suffix 按原顺序重放；
5. 同时处理 rollback、aborted turn、world-state full/patch 和 metadata；
6. fork 时先过滤出 fork point 之前的有效 rollout，再应用同一恢复规则。

旧 rollout 的 `replacement_history == nil` 走兼容桥：从当时历史提取真实用户
消息，再与 checkpoint message 重建；旧 numeric window id 兼容迁移为
`window_number`。这只是 legacy 路径，不应成为新写入格式。

### 6.3 Intatis 必须保留的更强持久化合同

Codex 固定 commit 中存在一个不应照抄的缺陷：

- `replace_compacted_history` 先替换 live history；
- 随后调用 `persist_rollout_items`；
- 持久化失败只记录 error，不把失败返回给 caller。

这可能造成进程内 live history 已前进、rollout 却没有 checkpoint。

Intatis 的 EventLog 是 canonical truth，因此必须采用更强顺序：

1. 先构造并分配完整 canonical replacement item IDs；
2. 将 compaction checkpoint、full world-state baseline 和 reference
   TurnContext 作为一个原子 EventLog batch 持久化；
3. 读回/使用实际落盘 canonical bytes；
4. 只有 batch 成功后才替换 live model history 并发布 subscriber 状态；
5. append 失败时保留旧 live history，当前 compaction fail closed；
6. 禁止下一次 provider request 使用未持久化的新历史。

这不是偏离 Codex 的功能语义，而是为符合 Intatis 既有 EventLog 权威合同所必需
的安全加强。

## 七、已知上游弱点与测试证据边界

### 7.1 ignored remote-compaction 测试

`codex-rs/core/tests/suite/compact_remote.rs` 中
`remote_compact_persists_replacement_history_in_rollout` 被 `#[ignore]`，注释明确
说明当前 main 的 replacement-history persistence 行为已知不正确，等待后续 PR。

因此：

- 不能把 Codex remote compaction 宣称为已被完整回归测试证明；
- Intatis 不应在本地 checkpoint 合同未通过前默认启用 remote compact；
- remote provider 返回必须严格校验 shape、item IDs 和 replacement persistence。

### 7.2 network skip

多项 Codex integration test 使用 `skip_if_no_network!`。这类测试在无网络环境
可能显示整个测试命令成功，但相关 case 实际没有执行。报告验证结果时必须同时
给出 discovered、executed、skipped、ignored 和 failures，不能把“命令 exit 0”
等同于所有关键行为被证明。

### 7.3 fake provider 的正确定位

确定性 fake provider 测试不是“假测试”：它适合证明事件顺序、阈值、历史布局、
checkpoint 原子性、恢复和竞态。但它不能证明真实 provider 的 usage 精度、摘要
质量、远程 compact wire 兼容性和长期网络行为。

Intatis 的报告必须分开写：

- 本地 deterministic contract：可以由 fake provider 证明；
- 真实 provider/network matrix：未执行时必须写 `UNKNOWN`，不得由 fake test
  外推为通过。

## 八、Intatis 当前差异

| 维度 | Intatis 当前状态 | Codex 固定 commit | 结论 |
| --- | --- | --- | --- |
| Skill catalog budget | canonical primary（`context_window`，缺失时显式 `limit.context`）的 2% UTF-8 approximate tokens；两者缺失时 8,000 characters；公平截断、marker、snapshot count metrics/warning | Core 为 raw primary `context_window` 约 2% token，缺失时 8,000 characters；ext/skills 另有 max+4k cap | 只对齐 2% 算术/8k fallback seam；输入归一、UTF-8 estimator、renderer/path alias 与 telemetry 不等价 |
| Skill snapshot | 每次 send/AgentInvocation 全量冻结正文与 UTF-8 resources | Turn metadata snapshot；显式正文按需读取；app-server 有 cache/watcher | Intatis 更强冻结，不需改成中途 live mutation |
| Skill activation | 显式 `$name` contextual；模型可调用 `activate_skill` | Turn-scoped contextual injection/`skills.read` 路径 | 角色/工具形式不同，生命周期原则相同 |
| Skill body history | `activate_skill` tool output 可进入稳定 Code conversation / Cowork `@main` durable model history | contextual Skill 进入普通 rollout | 两者都需要通用 compaction |
| 历史压缩 | 审计开始时尚无；本轮已为稳定 Code conversation 与 Cowork `@main` 增加本地完整 v1 replacement item array checkpoint | pre/mid-turn、20k 用户消息、summary、checkpoint、resume | 生命周期主缺口已落地；arbitrary provider items/world state 仍不等价 |
| canonical persistence | EventLog append-only、strict replay、可 fail closed | rollout append 失败可能只记录日志 | Intatis 必须保留更强原子持久化 |
| dependency | 严格 `agents/openai.yaml` MCP-only metadata；request-owned agent-visible tool view 的 server+locator assertion，且 server 至少一项可见 tool | MCP dependency + prompt/install/config/OAuth/runtime refresh | 更窄、更严格的 Intatis preflight；外部变更流程故意未冒充等价 |
| reload | 下一 invocation 重新扫描；当前 invocation frozen | watcher 清 cache，下一 Turn reload；当前 Turn frozen | 不是重启 Session 问题 |
| 同名冲突 | 不同 path 同名并存，`$name` 多义拒绝 | repo/user 同名并存；同 path first root | 无静默 name override；P2 做 UX |
| script execution | 走 Managed Terminal 和现有权限链 | 走普通 exec/shell 与 sandbox/approval | 不建免审 Skill runtime |

## 九、对照目标合同（实施前）

### 9.1 协议与模型历史

新增 additive、可旧版本安全解码的 model-history compaction checkpoint。payload
至少承载 Codex 对应字段：

- schema version；
- checkpoint/item identity；
- exact session、agent、task、attempt、turn 关联；
- summary message；
- 完整 replacement history；
- `window_number`；
- UUIDv7 `first_window_id` / `previous_window_id` / `window_id`；
- 与 full world-state/reference context 同一原子 batch 的关联。

replacement history 必须是 provider-facing canonical items，而不是 UI 气泡、
bounded audit preview 或 transcript 反解析结果。

### 9.2 阈值

按 Codex 固定 commit 对齐：

- 默认 auto compact：raw context window 的 90%；
- 默认 `total` scope 使用 `min(configured limit, raw window 的 90%)`；
- 若同时实现 `body_after_prefix` parity，显式 limit 是 prefix 之后的增长预算，
  不套 total-scope 90% clamp，但仍受 95% usable-window hard cap；
- effective usable window：raw window 的 95%；
- 默认计费 scope：total active context；
- 95% usable-window hard cap 独立生效；
- full context、usage 和 fallback buffer 的计算须 saturating、overflow-safe；
- context window 不可知时不得编造百分比值，应使用显式配置或停用自动阈值并给出
  typed diagnostic。

### 9.3 pre-turn 与 mid-turn

- pre-turn 在加入新 user/context input 前运行；
- 第一阶段保持 Codex 当前“不预估 pending input”的精确行为，并在文档中注明；
- mid-turn 只在仍需继续采样、存在 pending input 或显式 rollover 时运行；
- mid-turn 需携带当前 tool artifacts、canonical world state 和 exact step context；
- compact 失败不得伪装成普通完成，也不得丢失原历史。

### 9.4 replacement 算法

- compact request 在 history clone 上运行；
- context overflow 只裁 clone 的最老项目；
- 成功后只保留真实用户消息，排除旧 summary 与 Skill contextual fragments；
- 从新到旧选择最多 20,000 approximate tokens，边界项截断后恢复时间顺序；
- summary 作为最后一条 user-role item；
- pre-turn 不重注入 initial context；
- mid-turn 在最后真实用户消息之前注入 canonical initial context；
- 成功后重新计算 token usage；
- 多次 compaction 必须生成新 window，而不是覆盖旧 checkpoint。

### 9.5 EventLog-first commit

必须使用 Intatis 的原子 EventLog batch：

- item IDs 先分配；
- checkpoint、world-state baseline、reference context 一次提交；
- live swap 发生在 durable commit 之后；
- commit 失败不改变 live history；
- returned/subscriber 数据必须来自实际落盘 bytes；
- unknown future event、seq gap、冲突 checkpoint 或损坏 replacement fail closed；
- 不修改旧 JSONL 事件的解码含义。

### 9.6 resume、fork 与 legacy

- reverse scan 最新有效 checkpoint；
- 以 exact replacement 作为 base；
- 只重放 surviving suffix；
- 处理 rollback、aborted/cancelled turn、full/patch world state；
- fork 先限定 fork point；
- legacy 无 replacement checkpoint 可按“真实用户消息 + summary”兼容重建；
- 新 checkpoint 禁止写 `replacement_history == nil`；
- 同一 persisted checkpoint 重放必须幂等。

### 9.7 首批产品接线

建议 P0 接线顺序：

1. `IntatisAgentKernel` 共用 compaction state/algorithm；
2. Cowork 稳定 `@main` durable model history；
3. Code 跨 send 历史；
4. 所有长 AgentLoop 的 mid-turn compaction；
5. exact task/attempt 可恢复的 Cowork invocation；
6. remote compact 仅在 capability、shape 与 persistence 测试全部成立后启用。

Chat 是否接入应另行评估，不能让本轮 Code/Cowork 修复扩大 iOS 工具和 AgentKernel
边界。

## 十、P1 与 P2

### 10.1 P1（本轮已完成的受限范围）

- catalog 从 exact canonical primary `contextWindowTokens` 取得
  `max(1, floor(window × 2%))` approximate-token budget；Codex
  `context_window` 优先，缺失时只允许显式 OpenCode `limit.context` 补位；
  两者缺失/非法时使用 8,000-character fallback，不按
  slug/max/compaction window 猜值，也不加入 ext/skills 的 4k cap；
- 保留 Intatis 的 source 排序、公平 description 缩短与 omitted marker，并在
  immutable snapshot 中增加 count-only catalog total/kept/omitted/truncated/
  rendered-cost metrics 和 warning；trusted envelope 不计入 metadata budget；
- 增加可选、严格、有界的 `agents/openai.yaml` 子集，只支持 MCP dependency；
- 只对实际显式选择、`activate_skill` 或 `read_skill_resource` 的 Skill 做
  request-owned missing/stale-endpoint 检测，exact server ID 与 locator
  fingerprint 必须在 production host 从 agent-visible tool entries 派生的
  assertion 中成对匹配，server 至少贡献一个可见 tool；machine metadata 不可
  被 generic resource tool 披露；
- 没有 MCP host 或 assertion 时 fail closed，不读取 config/global registry
  兜底。

本节没有完成的 Codex 部分是：catalog warning/metrics 尚无产品级 consumer，
renderer 不是逐字节同构；MCP 没有 Install/Continue-anyway、OAuth、外部配置
持久化或 runtime refresh。这些外部变更若后续实施，仍必须走 Intatis 现有权限
与 durable admission，不能静默扩大连接。

### 10.2 P2

- 用真实数据评估 lexical/BM25/character n-gram/hybrid selector，再决定是否改变
  model-visible catalog；
- 不以 embedding/vector database 作为默认前提；
- 同名来源冲突 UI、按 path enable/disable、明确 omission diagnostics；
- `skills/changed` 通知和低频 watcher；只影响下一 invocation；
- 任意 binary/package prerequisite schema 与跨平台检查；
- Skill script 路径/工作目录便利化，但仍通过 Managed Terminal 和全部权限门；
- 多次压缩的长期摘要质量评估与用户主动“开启新会话”建议。

## 十一、验收与防止“假通过”

完整上游等价最终至少需要以下无网络 deterministic tests。本轮实际覆盖与尚未
实现的项目以第十四、十五节为准；本清单不能反向当成“全部已经通过”的声明：

1. 90% auto soft limit 与 95% usable hard cap 分别命中；
2. total scope 的 configured limit 被 clamp；body-after-prefix 与 total 的计费
   语义明确分开，total scope 为默认；
3. pre-turn compact request 不含刚到达的新用户消息；
4. mid-turn 在 tool output 后触发，compact 后继续同一 Turn；
5. 20,000 token 逆向选择、边界截断、时间顺序恢复；
6. 旧 summary、Skill contextual、developer、assistant、tool 原文不进入真实用户保留区；
7. summary 始终是 replacement history 最后一项；
8. pre-turn 与 mid-turn initial-context 位置分别正确；
9. live replacement 与 persisted replacement item IDs 完全一致；
10. EventLog batch 故障注入时 live history 不改变、provider 不继续；
11. 多 checkpoint UUIDv7 chain 与 window number 单调；
12. restart 从最新 checkpoint + suffix 精确重建；
13. rollback/fork/aborted turn 恢复；
14. legacy nil replacement 兼容，新写入禁止 nil；
15. unknown future event、seq gap、冲突 ID、坏 payload fail closed；
16. Skill 正文在压缩前可见、压缩后不以 contextual 原文保留、再次提及时重新加载；
17. 同一 invocation 修改 `SKILL.md` 不改变 snapshot，下一 invocation 可见；
18. remote compact persistence 测试不得 ignored。

结构测试通过后，再单独运行：

- Code 长会话多次压缩 + process restart；
- Cowork `@main` 多 submission、多工具轮、多次压缩 + process restart；
- task-scoped worker 超长单 Turn；
- 真实 OpenAI-compatible provider 的 usage/summary/stream matrix；
- 可选 remote compact provider matrix。

最终报告必须列出每组 discovered、executed、skipped、ignored、failed 数量。任何
real-provider、GUI、process-kill 或长期 soak 未执行时，应明确标为 `UNKNOWN`。

## 十二、开源来源与 NOTICE 判定

Codex 根许可证为 Apache-2.0，仓库包含 NOTICE。本报告将本次使用方式分类为
`reference`：

- 只研究公开类型、算法边界、控制流、测试意图和已知缺陷；
- 不复制或逐行翻译 Rust 源码；
- 不复制 compact prompt、Skill prompt、快照、产品文案、名称、Logo 或 UI 资产；
- 不 vendor、链接或分发 Codex crate；
- Intatis 的 Swift 类型、EventLog event、compactor、projector、恢复器和测试应
  独立实现；
- Intatis 还会有意保留更强的 EventLog-first 原子持久化，不复制上游
  live-before-persist 缺陷。

因此，本报告本身以及按上述边界进行的独立实现都不新增第三方分发物，
`NOTICE.md` 无需修改。本固定 commit、Core/ext catalog 差异、Skill/MCP/
compaction 具体参考文件及 `reference` 分类已经补记到
`docs/OPEN_SOURCE_REUSE.md`。如果后续直接采用上游 prompt、源码表达、测试
fixture 或文件，则必须重新分类为 `derived` / `vendored` / `dependency`，核对
目标文件许可证与 NOTICE，并更新本地 provenance 和 `NOTICE.md`。

## 十三、本轮实施结果

### 13.1 已完成的生命周期主链

本轮不是给 Skill 增加 sticky activation/TTL，而是按 Codex 的实际做法完成通用
模型历史替换：

1. 新增 additive `model_history_compacted` EventLog 事件和
   `ModelHistoryCompactedPayload`。新写入始终包含完整 replacement history、
   summary、单调 window number 以及 canonical UUIDv7
   `first/previous/current window ID`。
2. `model_history_item` 的 user-role 项新增 `real_user` / `contextual` /
   `compaction_summary` 分类。显式 Skill 正文以 contextual 项保存，绝不进入
   20,000-token 真实用户保留区；旧事件缺字段时按 legacy real user 解码。
3. `AgentModelHistoryCompactor` 在历史副本上调用同一 exact provider/model，
   不暴露工具；只对机器分类的 `ProviderContextWindowExceededError` 从最旧端
   删除一个逻辑 item group 后重试。连续 leading system/developer 前缀永久
   受保护；assistant tool-call batch 只连带删除紧邻 matching outputs，不按
   跨 Turn 复用 call ID 全局查找，也不制造 orphan output；任意本地化字符串
   或普通 400 不触发该路径。
4. replacement 从最新向前选择真实用户消息；20,000 approximate tokens 是
   retention 上限，实际预算还会按 usable window 与 summary 大小动态缩小。
   边界消息保留 UTF-8-safe 最新后缀并写明确截断标记，然后恢复时间顺序，最后
   追加 user-role continuation summary。summary request 的 output ceiling
   最多为 4,096 tokens，并可因 replacement space / shared token budget 进一步
   降低；host 还在 append 每个 stream delta 前执行同一
   provider-neutral 实际输出 bound，并在 replacement 前用 `SecretScanner`
   拒绝已知 secret-like material。provider 忽略 ceiling 或 replacement 仍
   超窗时在落盘前 typed fail closed。
5. pre-turn 在当前 user/context 进入模型历史前检查旧历史；mid-turn 只在工具
   结果后仍需下一次采样时检查。最终回答即使越阈值也不即时制造额外 compact
   request，等下一 Turn 处理。pre-turn 先冻结首个普通请求的 dynamic tool
   snapshot；工具执行后仍需采样时先冻结下一普通请求的 snapshot，然后用同一
   exact provider specs 完成阈值判断、95% replacement postcondition 与对应
   dispatch。snapshot 失败 fail closed，不回退 base registry。
6. mid-turn replacement 在最新真实用户之前保存本轮 canonical task/external/
   Skill contextual messages；summary 仍为最后一项。压缩本身不消耗
   `maxIterations`，但 usage 进入当前 Turn 的统计/预算。
7. 稳定 Code conversation 与 Cowork `@main` 都接入相同协议。Code 的新 Turn
   自动获得
   `SubmissionID`，direct model-history 项明确 `taskID == nil`；Cowork 继续要求
   exact root task/submission/assignee/attempt 绑定。task-scoped worker 与控制面
   agent 不读取、记录或压缩主线程历史。
8. 恢复器从最新“对当前 submission 仍有效”的 checkpoint 作为 base，只重放
   后缀；支持 queued U2 先于 U1 checkpoint 落盘、mid-turn 无第二个 user 的
   continuation、同 submission retry 使较新 checkpoint 失效、两窗口 lineage、
   legacy completed U/A bridge，以及 checkpoint 边界前旧 raw history 被遮蔽。

### 13.2 EventLog-first 安全加强

Intatis 没有照抄 Codex 的 live-before-persist 顺序：

- `appendModelHistoryCompaction` 在跨进程锁内重新扫描 complete-known history，
  拒绝 unknown future event、seq gap 与损坏记录；
- 使用“同一 agent 最新 model-history seq”做 compare-and-swap。其他 agent 或
  普通 UI/audit event 可并发追加，同一 agent 的历史变化会令旧 compact 结果
  stale 并失败；
- Protocol 的 `validate()` 在编码/解码边界拒绝未知 schema、空 summary/历史、
  非 v1 replacement shape/classification、坏 final summary 与非 canonical
  UUIDv7；EventLog 在 CAS 后、任何 WAL/JSONL bytes 生成前复核完整同-agent
  window lineage 与 ID 唯一性，且 generic append 不能绕过专用入口；
- durable shape/lineage 校验不冒充来源证明：projector 仍独立校验 retained user
  对应 accepted submission、contextual placement 与 checkpoint coverage；
- 大于 64 KiB 的单 checkpoint 走现有可恢复 WAL 边界；
- checkpoint 成功落盘后 `AgentLoop` 才把 live request history 换成
  replacement；append/CAS 失败时普通 provider dispatch 不会使用未持久化历史。

当前 Intatis 没有与 Codex 同构的独立 `TurnContextItem` /
`WorldStateItem(full|patch)` 事件。所需的本轮 canonical context 直接作为
replacement 内的 typed contextual items 与 checkpoint 一起提交，因此这里是
“一个 canonical checkpoint 事件”的原子提交，不是假称已经实现了不存在的三事件
batch。

### 13.3 90% / 95% 与 exact route

- `AgentModelContextPolicy` 只读取显式 `context_window`、
  `max_context_window`、`auto_compact_token_limit`、
  `effective_context_window_percent`、`comp_hash` 或 OpenCode
  `limit.context` 元数据；不按 model slug 猜窗口。
- 默认 total-scope auto limit 为 raw/max window 的 90%；显式 limit 在窗口已知
  时被 clamp；95% usable window 作为独立 hard trigger，实际触发取两者较早值；
  同一 95% 还是 checkpoint 落盘前对 canonical system/developer prefix、
  replacement/context 与对应下一普通请求冻结 exact 工具 schema 的
  postcondition。
- raw/max window 未知但 exact metadata 明确给出 `auto_compact_token_limit`
  时，只使用该显式 trigger；此时不会伪造 95% hard window 或相应 postcondition。
  两者都未知才关闭自动触发。
- profile revision/fingerprint 包含该元数据。Code 的 provider、model 和 context
  policy 从同一次 immutable catalog resolution 原子取得；只有一个同
  endpoint/model 的 current base profile 时启用自动压缩，歧义或 legacy route
  保持 `.unspecified`。Cowork 稳定 `@main` 继续使用冻结 exact inference
  binding；普通 worker 不接收该 policy。

### 13.4 与长任务设置的关联结果

本工作树同时保留了此前已授权的长任务上调，委派深度仍保持 1：

- Cowork 新 task contract 默认 timeout：300 秒 → 600 秒；
- Code 默认 `maxIterations` 保持 50，Cowork 默认 64；
- Chat streaming timeout 保持 120 秒，Code/Cowork agent streaming 为 180 秒；
- CLI 无显式 override 时按 Code 50 / Cowork 64 分流；显式用户值继续优先；
- 历史已经持久化的 300 秒 task contract 不迁移、不静默改写。

这些上调只减少非预期终止，不替代本报告的 context-window 生命周期修复。

### 13.5 主要写入位置

- Protocol/EventLog：
  `Packages/IntatisProtocol/Sources/ModelHistory.swift`、
  `Envelope.swift`、`Event.swift`、
  `Packages/IntatisConversation/Sources/EventLog.swift`
- Kernel：
  `AgentModelHistoryCompactor.swift`、`AgentModelHistoryProjector.swift`、
  `AgentModelHistoryWindowID.swift`、`AgentTokenEstimator.swift`、
  `AgentLoop.swift`、`ContextBuilder.swift`、`AgentRuntime.swift`
- Provider/profile：
  `AgentModelContextPolicy.swift`、`InferenceCatalog.swift`、
  `ProviderRegistry.swift`、`ProviderErrorFormatting.swift`、
  `OpenAIToolCalling.swift`
- 产品接线：
  `Apps/IntatisMac/Sources/CodeViewModel.swift`、
  `Apps/intatis-cli/Sources/Interactive.swift`、
  `MCPCLILiveCommands.swift`，以及 Cowork `Orchestrator.swift` /
  `CoordinatorTools.swift`
- Skill catalog/MCP preflight：
  `Packages/IntatisSkills/Sources/SkillTypes.swift`、
  `SkillCatalogService.swift`、`SkillMCPDependencies.swift`、`SkillTools.swift`、
  `Packages/IntatisTools/Sources/MCPToolAvailabilitySnapshot.swift`、
  `Packages/IntatisAgentKernel/Sources/AgentRequestToolSnapshot.swift`、
  `Packages/IntatisMCP/Sources/MCPConnection.swift` 与
  `MCPProductionRuntime.swift`
- 合同测试：
  Protocol、EventLog、projector、compactor、AgentLoop、Code fresh-loop replay、Skill
  catalog/MCP dependency/durable activation、request-owned tool snapshot、
  profile route 与 provider typed overflow 测试。

### 13.6 Skill catalog 与 MCP dependency P1

- `SkillCatalogMetadataBudget` 精确区分 characters 与 approximate tokens。
  canonical primary context 可知时按 Codex Core 2% 公式计算；Codex
  `context_window` 优先，缺失时可由显式 OpenCode `limit.context` 补位；两者
  未知时保留 8,000 characters。approximate-token 模式使用稳定的 UTF-8
  bytes/4 ceiling，仅作为 provider-neutral budget，不冒充真实 tokenizer。
- metadata budget 不包含 trusted developer envelope。`SkillCatalogMetrics`
  只记录计数与 cost；omitted 时总是产生 warning，只有 description 平均截断
  超过阈值时才产生纯 truncation warning。snapshot digest 包含 budget/result，
  同一 invocation 不会被 live 文件或 route 变化偷换。
- `SkillMCPDependencies` 只解析严格 MCP 子集，并把 raw transport locator 转成
  `mcplocator_` fingerprint。`MCPToolAvailabilitySnapshot` 只有
  `.unavailable` 或经 bounded shape validation 构造的 `.frozen` 两种状态；
  `.frozen` 是 trusted host assertion，不会自行验证连接。positive assertion
  必须把 dependency server 留在同一 server set 中，并按 server+locator 成对
  保存。
- production MCP connection 从 exact transport configuration 派生 locator；
  不属于 Skill allowlist 的普通有效 MCP 配置仍可正常连接，但不会获得 Skill
  dependency assertion。Agent request builder 只从同一个 filtered/granted
  agent-visible MCP tool view 冻结 tools、servers 和 assertion；server 至少
  贡献一个可见 tool entry，避免 config-only、resource-only、旧 generation
  或 TOCTOU 通过预检。当前 tests 主要使用手工构造的 trusted availability
  fixture，不能冒充 production builder 或真实 server E2E。
- 无歧义显式 Skill 会在首个正文注入前先取得并复用首个 request snapshot；
  task-scoped worker 也遵循自己的 exact snapshot。模型调用 Skill tools 时，
  preflight 使用 request-owned snapshot，其 response 选择了该 Skill tool。
  不存在无 MCP host 的 base-registry 或 global-state fallback。

### 13.7 子 Agent 的不同模型选择

- coordinator 的 `list_inference_profiles` 只列 host-approved、secret-free 的
  profile ID、安全 label、model 和 variant；不披露 endpoint、credential、
  header 或 raw options。
- `spawn_agent` 可传 `inference_profile_id` 选择不同 exact profile；省略时继承
  caller 的完整 revision/connection/model/variant/digest。旧 `model` 字段只是
  deprecated compatibility input，不能绕过 profile allowlist。
- model-facing tool descriptor 现在明确推荐默认省略并继承；只有某个已列出的
  label/model/variant 明确适配被委派工作时才选择不同 profile。当前没有
  host-owned workload→model 推荐标签，因此更细的“代码审查固定用 X、搜索固定
  用 Y”仍只是模型判断，不能称为平台保证。
- capability/delegation 深度与 inference profile 独立：选择不同模型不会自动
  获得 coordinator、写入、通信或更深 delegation 能力。

## 十四、验证结果

### 14.1 deterministic 合同证据

已完成的定向矩阵：

| 测试组 | discovered | executed | skipped | ignored | failed |
| --- | ---: | ---: | ---: | ---: | ---: |
| `AgentModelContextPolicyTests` | 10 | 10 | 0 | 0 | 0 |
| `AgentModelHistoryCompactorTests` | 13 | 13 | 0 | 0 | 0 |
| `CodeModelHistoryCompactionTests` | 1 | 1 | 0 | 0 | 0 |
| `ContextProjectionTests` | 20 | 20 | 0 | 0 | 0 |
| `IntatisSkillsTests` | 19 | 19 | 0 | 0 | 0 |
| `SkillMCPDependencyTests` | 9 | 9 | 0 | 0 | 0 |
| `ModelHistoryCompactionAgentLoopTests` | 12 | 12 | 0 | 0 | 0 |
| `ModelHistoryCompactionEventLogTests` | 9 | 9 | 0 | 0 | 0 |
| `ModelHistoryProjectionTests` | 14 | 14 | 0 | 0 | 0 |
| `ModelHistoryProtocolTests` | 11 | 11 | 0 | 0 | 0 |
| `SkillDurableActivationTests` | 2 | 2 | 0 | 0 | 0 |
| `AgentRequestToolSnapshotTests` | 6 | 6 | 0 | 0 | 0 |
| `CLIConfigRuntimeBudgetTests` | 2 | 2 | 0 | 0 | 0 |
| `CLIModelContextMetadataTests` | 1 | 1 | 0 | 0 | 0 |
| **合计** | **129** | **129** | **0** | **0** | **0** |

该矩阵实际证明了：90/95 元数据计算、20k 上限/动态收缩/UTF-8 边界、4,096
summary ceiling、压缩后 postcondition、provider 忽略 ceiling 零 checkpoint、
typed overflow 的逻辑 pair 裁剪、pre/mid/final 时机、Protocol v1 shape、
checkpoint durable CAS/generic-append gate/WAL、window lineage、Code/Cowork
fresh-loop replay、Skill snapshot/contextual 排除、worker 不压缩、Codex
Core-style catalog budget/metrics、严格 MCP machine metadata、caller-frozen
request-owned availability pairing、同名 endpoint 变化 fail-closed 与
Code/Cowork 首请求 snapshot。availability fixture 并非真实 production MCP
builder/server E2E。

这里的 fresh-loop replay 是新建 `AgentLoop` 后复用同一个 `EventLog` 对象；
没有 reopen 新 `EventLog` 实例，更没有真正杀进程。因此它只证明 projector/
loop 的 durable-history replay contract，不是 process restart 证据。

### 14.2 全量与产品构建

最终源码验证如下；没有用定向测试替代全量或产品构建：

- full `swift test --disable-sandbox -q`：1470 tests、16 个 opt-in environment
  skipped、0 failures；
- `swift build --disable-sandbox`：通过；
- `xcodegen generate`：通过；
- IntatisMac unsigned macOS Debug：通过；
- IntatisMacAppStore unsigned macOS Debug：通过；
- IntatisiOS generic Simulator Debug：通过；
- `git diff --check`：通过。

首次在 managed 外层 sandbox 内运行聚焦测试时，Swift compiler 因不能写
`~/.cache/clang/ModuleCache` 而在 manifest 阶段失败；本轮较早源码状态的全量
诊断还因宿主拦截嵌套 Seatbelt、process、Git 与 loopback 形成
1436 tests / 35 skipped / 45 failures。上述最终源码的 1470 / 16 / 0 是经显式
允许脱离该外层 sandbox 后的权威结果；没有为迎合宿主弱化产品 sandbox。

### 14.3 真实环境证据

以下均未由 deterministic fake provider 外推，当前状态为 `UNKNOWN`：

- 真实 OpenAI/OpenAI-compatible provider 的 usage、摘要质量、partial stream 与
  context-overflow error shape；
- retained `attachmentIDs` 对应历史图片的真实 artifact reload 与 provider
  rehydration；
- 真正杀死 App/CLI 进程后从 EventLog 恢复；
- GUI 长会话与多次 compact 的交互/可理解性；
- production MCP connection-set→agent-visible availability builder，以及真实
  server 的 dependency match/mismatch、reconnect 与 endpoint rotation；
- 多小时 soak、真实 600 秒 Cowork invocation；
- Codex remote compact 等价 wire；Intatis 本轮没有启用 remote compact。

### 14.4 兜底、严格限制与“假测试”审计

没有发现会把缺失能力伪装成成功的 hidden fallback：

- Skill MCP host assertion 缺失、metadata 无效、endpoint/command 改变、host 不存在或
  request snapshot 不可冻结时均 fail closed；不会退回 process-global config、
  base registry、旧 generation 或人工 Continue。production assertion 还要求
  server 在该请求 agent-visible view 中至少贡献一个 tool。
- exact model 的 canonical primary context 缺失时，catalog 使用 Codex Core
  明定的 8,000-character fallback；显式 OpenCode `limit.context` 可作为 primary
  compatibility input，但这不是按 model 名猜窗口。compaction policy 在窗口
  和显式 limit 都未知时保持 `.unspecified`，不会编造 90%/95%。
- summarizer 只有收到机器分类的 typed context-overflow 才会在 history clone
  上有界删除最旧 logical group 后重试；连续 system/developer 前缀、原 durable
  history 与 call/output pairing 受保护。其他 provider error 不走该路径，所有
  clone 都失败时不写 checkpoint、不替换 live history。
- legacy EventLog/route 字段只做明确兼容解码；不能 exact resolve 的 binding、
  provenance、future event 或 checkpoint lineage 均停止 provider dispatch，
  不套用 today default。

当前保留的严格限制是设计边界，不应被描述为隐藏降级：单 Skill body/resource
48 KiB、invocation-local Skill tool 披露总计 192 KiB、catalog 2%/8k、
retained real-user 最多 20k approximate tokens、summary 最多 4,096、Code/Cowork
循环 50/64、Cowork 新 task 600 秒、delegation depth 1。它们达到上限时要么
明确省略 metadata 并给 marker，要么 typed fail/terminal，不能返回伪成功。

测试方面，129 项定向矩阵和 1470 项全量测试中的 scripted/capturing provider
属于 deterministic contract doubles：它们有效证明事件顺序、请求内容、
fail-closed、竞态和恢复 shape，不是“预写通过结论”的假测试；但它们不能证明
真实 provider/MCP/network/GUI/process-kill/long-soak，后者已在 14.3 保持
`UNKNOWN`。本轮没有以 ignored/network-skipped case 作为真实环境通过证据。

## 十五、未完成边界与不等价项

本轮已完成 Skill 生命周期的主修复，但不能诚实地宣称 Intatis 已复制 Codex 的
全部线程运行时。明确剩余项如下：

1. `body_after_prefix` 实验 scope 未实现；Intatis 当前只实现 Codex 默认的
   total scope。
2. `comp_hash` 已进入 exact profile metadata/fingerprint，但“前后两轮两个非空
   hash 不同即强制用 previous model 先压缩、current model fallback”的切模流程
   尚未实现；切换为更小 context-window model 的 previous-model compact 亦未实现。
3. Intatis 没有 Codex 同构的 `TurnContextItem`、reference-context lifecycle、
   full/patch world-state 与 rollback/fork rollout，因此也没有假造对应恢复测试。
   当前 mid-turn 所需 context 由 checkpoint 内 contextual replacement 保存。
4. replacement schema 为未来结构化 provider item 留有字段，但 v1 projector
   只接受本地 compactor 实际写入的 user message/context/summary 形状；远程返回
   的 arbitrary call/reasoning replacement 尚未准入。
5. remote compact 未启用；上游对应 persistence test 本身仍 ignored。
6. 阈值使用确定性、provider-neutral UTF-8 byte estimator，不是各 provider 的
   exact tokenizer；95% postcondition 对当前冻结的 canonical prefix、
   replacement/context 与同一 request-owned exact 工具 snapshot 生效，动态
   catalog 不再在“判定后、对应 dispatch 前”偷换，但真实 endpoint tokenizer
   drift 仍需测量。
7. Code legacy `submissionID == nil` 的旧消息仅作为 summarizer 输入迁移，不会
   被伪造为带 provenance 的 20k retained real user。
8. replacement payload 会保留 retained user 的 `attachmentIDs`，但当前
   provider history 仍是 text-only，尚未把历史图片从 ArtifactStore 重新装载；
   不能把 ID provenance 写成多模态恢复已完成。
9. catalog Core 预算、marker 与 snapshot warning/metrics 已实现，但 renderer
   不是 Codex byte-identical，metrics/warning 还没有 App/CLI/EventLog consumer；
   因此只能称 contract seam 完成，不能称 operational telemetry 已上线。
10. MCP dependency 只完成严格 metadata 与 request-owned fail-closed
    preflight。Codex 的 Install/Continue-anyway、OAuth、外部配置持久化和 runtime
    refresh 未实现；production connection-set availability builder 和真实 server
    E2E 尚未验证；通用 `uv`/`gdb`/Python/package prerequisite 也未实现。
11. watcher/changed 通知、冲突 UI、durable enable/disable 与真实
    lexical/hybrid selector 评测仍是 P2；Codex 固定 commit 的 selector 仍是
    shadow experiment，Intatis 没有用 embedding 伪装成已上线召回。

安全确认：

- 没有新增 Skill 专用执行器或权限绕过；
- Skill 脚本仍走 Managed Terminal、CapabilityLease、WorkspaceLease、
  PermissionEngine、durable tool execution 与 sandbox；
- 没有复制 Codex compact prompt、Skill prompt、大段源码、测试 fixture、品牌
  文案或资产；
- 没有把 fake provider 测试称为真实生产 provider 通过；
- 未修改 `NOTICE.md`，因为本轮仍是固定 commit 的公开源码 reference、独立 Swift
  实现，没有新增分发物。
