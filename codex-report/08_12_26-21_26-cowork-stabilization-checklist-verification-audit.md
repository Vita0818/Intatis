# 对「Cowork 系统稳定化审计清单」的只读复核审计

> 复核日期：2026-08-12
>
> 仓库：`/Users/vita/Vitemis/Intatis`
>
> 被复核对象：根目录 `08_12_26-21_02-cowork-system-stabilization-audit-checklist.md`（1188 行，下称「原报告」）
>
> 复核性质：只读。本审计不修改任何源码、配置、构建脚本或测试；仅新增本报告文件。所有结论以当前工作树源码为准。
>
> 复核方法：逐点对照原报告的「已证实」事实断言与「当前工作树已有修补」声明，到对应源码中核实。每完成一点立即写入，再开始下一点。
>
> 复核分级（沿用原报告第 2 节，并补充）：
> - **吻合**：源码与原报告断言一致。
> - **部分吻合**：大体一致，但存在可指出的偏差或需补充说明。
> - **不吻合**：源码与原报告断言冲突。
> - **无法证实**：当前证据不足以判定（如原报告自己也标 UNKNOWN，或依赖未落盘的运行时数据）。
> - **未触及**：原报告声明的修补在源码中找不到对应实现。

---

## 复核点 0：仓库状态与源码触点（原报告第 19、20、24 节）

### 0.1 路径与 Git 状态

- `pwd` 与 `git rev-parse --show-toplevel` 均为 `/Users/vita/Vitemis/Intatis`，与原报告 `PATH_CHECK_RESULT` 一致。
- 复核时刻（`date`）：2026-08-12 21:26:51 +08。
- `git status --short`：工作树**干净**，无未提交改动。
- 最新提交：`85f535e v0.49`，作者 Vita，时间 **2026-08-12 21:23:08 +0800**。

### 0.2 与原报告「未提交工作树」声明的差异

原报告第 20 节明确写「工作树中已经存在多组业务源码、测试和文档修改」，并声明「本文没有修改、回退、暂存或提交这些既存改动」。

复核发现：该报告文件本身（1188 行）与其描述的「未提交工作树改动」（`AppConfig.swift`、`CoworkViewModel.swift`、`AuthorizationSidecar.swift`、`AgentLoop.swift`、`Orchestrator.swift`、`WorkTaskTools.swift` 等多文件）**已在 21:23 被一并提交为 `v0.49`**。即：

- 原报告写于 21:07，提交发生于 21:23，本复核发生于 21:26。
- 原报告自述「未提交」，但复核时这些改动已**成为已提交状态**（v0.49）。

这对复核的含义：当前工作树 = v0.49 = 原报告 + 原报告描述的全部修补。因此原报告中所有「当前工作树已有修补」的断言，理应在当前源码中可被验证为**已存在**。这是一个重要的状态前提，原报告自身的「未提交」措辞在提交后已不再准确，但不影响事实核对。

### 0.3 源码触点存在性（原报告第 19 节）

原报告第 19 节列出 19 个「关键源码触点」。逐个核对：

| # | 触点路径 | 复核结果 |
|---|---|---|
| 1 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift` | OK |
| 2 | `Packages/IntatisAgentKernel/Sources/AuthorizationSidecar.swift` | OK |
| 3 | `Packages/IntatisAgentKernel/Sources/ContextBuilder.swift` | OK |
| 4 | `Packages/IntatisProviders/Sources/OpenAIToolCalling.swift` | OK |
| 5 | `Packages/IntatisCowork/Sources/Orchestrator.swift` | OK |
| 6 | `Packages/IntatisCowork/Sources/WorkTaskTools.swift` | OK |
| 7 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift` | OK |
| 8 | `Packages/IntatisPermission/Sources/PermissionReviewTextVerdict.swift` | OK |
| 9 | `Packages/IntatisConversation/Sources/CodeProjection.swift` | OK |
| 10 | `Packages/IntatisSharedUI/Sources/CodeViews.swift` | OK |
| 11 | `Packages/IntatisConversation/Sources/RuntimeErrorPresentation.swift` | OK |
| 12 | `Apps/IntatisMac/Sources/AppConfig.swift` | OK |
| 13 | `Apps/IntatisMac/Sources/CoworkViewModel.swift` | OK |
| 14 | `Apps/IntatisMac/Sources/IntatisMacApp.swift` | OK |
| 15 | `Apps/intatis-cli/Sources/CLIConfig.swift` | OK |
| 16 | `Apps/intatis-cli/Sources/CLIProviderCatalog.swift` | OK |
| 17 | `Apps/intatis-cli/Sources/CLIInferenceProfiles.swift` | OK |
| 18 | `Apps/intatis-cli/Sources/Interactive.swift` | OK |
| 19 | `Packages/IntatisSkills/Resources/BundledSkills/cowork-agent-orchestration/SKILL.md` | OK |

**结论：全部 19 个触点均存在**。原报告第 19 节清单准确，且原报告自述这些「不是修改授权，也不是穷举列表」，复核认同其非穷举性质。

### 0.4 本点小结

- 路径/Git root：吻合。
- 触点清单：全部吻合（19/19 存在）。
- 「未提交工作树」声明：与当前事实**不吻合**——改动已于 21:23 提交为 v0.49；这是原报告写就后发生的状态变化，非原报告事实错误，但复核时该状态已改变，后续复核均以 v0.49 已提交源码为准。

---

## 复核点 1：INC-01 —— strict authorization sidecar 导致全上游 HTTP 400（原报告第 4 节）

### 1.1 原报告核心断言

- 旧实现把 `__intatis_authorization_context` 加入 `properties` 但不加入 `required`，同时保留 `strict:true`，形成 `strict==true && properties.keys != required` 的非法组合。
- 涉及 `activate_skill`、`read_skill_resource`、`search_knowledge` 的可选 `limit`。
- 「当前工作树已有修补」：strict sidecar、递归 strict schema 校验、`tool_search_output` 延迟工具装饰。
- 正确边界：sidecar 在 provider copy 中是 required string；`strict:true` 对象递归 closed；发网前 typed validation。

### 1.2 源码核对

`Packages/IntatisAgentKernel/Sources/AuthorizationSidecar.swift`：

- `reservedFieldName = "__intatis_authorization_context"`（L173-174）——字段名吻合。
- `decorateParameters`（L429-493）：把 sidecar 同时写入 `properties`（L480）**和** `required`（L481），即修复后的合法组合，**与原报告「正确边界」一致**。
- `validateStrictSchema`（L573-706）递归校验：`additionalProperties == false`（L621）、`required` 为字符串数组（L628-638）、`Set(requiredNames) == Set(properties.keys)`（L644），并递归进入 `properties`/`items`/`contains`/`anyOf`/`oneOf`/`allOf`/`$defs`/`definitions`/`dependentSchemas` 等。**与原报告「递归 closed-object invariant」一致**。
- `tool_search` 本身不装饰（`.toolSearch` 分支 L411-412 直接返回），但 `decorate(_ output: ModelToolSearchOutput)`（L214-224）与 `decorateDeferredToolDefinition`（L495-566）递归装饰其延迟发现的 function/namespace 子工具。**与原报告「`tool_search` 本身保持原样，但其延迟工具必须装饰」一致**。
- 非 automatic 模式存在保留字段时由 `containsReservedField`（L335-346）做 mode-confused 拒绝。

`Packages/IntatisAgentKernel/Sources/AgentLoop.swift`：

- `providerToolSpecs`（L1242-1252）与 `providerMessages`（L1258-1267）仅在 `mode == .cowork && approvalMode == .automaticReviewer` 时调用 `AuthorizationSidecarCodec.decorate` / `decorateProviderMessages`。**与原报告「automatic 模式下 provider-facing sidecar 才注入」一致**；decorate 在构造 provider specs/messages 阶段完成，先于发网，且 `decorate` 对 strict 违规直接 `throw`（typed fail-closed），**与原报告「发网前 typed validation」一致**。

`Packages/IntatisKnowledge/Sources/SearchKnowledgeTool.swift`：

- descriptor（L16-52）：`strict: true`、`additionalProperties: false`、`required` 含 `knowledge_base`/`query`/`limit`（L23-26），`limit` 用 `anyOf: [integer, null]`（L37-48）表示「必须出现但可为 null」。这正是原报告 4.4 节所述 strict 下的 nullable 语义（"语义可选"），**与原报告对该工具的描述一致**。

### 1.3 原报告无法由当前源码独立验证的部分

- 「旧实现把 sidecar 加入 properties 但不加入 required」这一**原始 bug 形态**已无法从当前源码直接观察（代码已被修复）。原报告将其标为「已证实」依据来自 EventLog 与历史工作树，当前仓库无法复现该旧形态。此点记为**无法由源码独立证实（但修复形态吻合）**。
- 「涉及 `activate_skill`、`read_skill_resource`」：本次复核未单独打开这两个工具的 descriptor 文件逐一比对 strict 字段，但 codec 是通用递归实现，对所有 `.function` 工具统一处理；该细节属未展开核查，记为**未深入验证**。

### 1.4 前向门禁（原报告 4.6 节）

4.6 节列出的回归门禁均为未勾选的 `[ ]` 待办项（递归检查、静态/Skill/Knowledge/MCP/deferred 同一检查器、HTTP body capture 层验证、OpenRouter 与 OpenAI-compatible 各跑 smoke、禁止断言非法合同）。这些是**未来工作**，非事实断言，复核只确认其为待办状态：当前 `AuthorizationSidecarTests.swift` 与 `AgentLoopPolicyTests.swift`、`CLIProviderAdapterTests.swift`、`RealProviderSmokeTests.swift` 已扩展（见 v0.49 stat），但「真实 provider 矩阵 smoke 是否已跑」属运行时事实，源码无法证明其已执行。

### 1.5 本点小结

- sidecar 修复（required + 递归 strict 校验 + tool_search_output 装饰 + 发网前 typed throw）：**吻合**。
- 「automatic 模式才注入」：**吻合**。
- `search_knowledge.limit` 的 nullable strict 表示：**吻合**。
- 原始 bug 形态与 `activate_skill`/`read_skill_resource` 细节：**无法由当前源码独立证实**（代码已修复；原始 EventLog 证据不在源码中）。
- 4.6 回归门禁：**待办状态**（非事实断言）。

---

## 复核点 2：INC-02 —— 未来 owner、错误调用顺序与副作用误判（原报告第 5 节）

### 2.1 原报告核心断言

- `task_create` 的 owner 必须是当前已 attach 的 data-plane agent；preflight 在任何 WorkTask 事件 append 前拒绝。
- 旧设计：descriptor 未说明 future/planned agent 不能作 owner；runtime prompt 未说明同批非事务。
- 通用 `requiresManualReconciliation` 可能把纯 preflight error 误报为 unknown。
- 「当前工作树已补」：task_create owner/调用顺序合同；为 `task_create`/`task_update` 首个 WorkTask append 前拒绝建立更精确的 `not_started` 通道。
- 「仓库里约有六十个静态 mutating tools」是旧盘点估计，必须重新生成。

### 2.2 源码核对

`Packages/IntatisCowork/Sources/WorkTaskTools.swift`：

- `task_create` descriptor（L65-93）：`owner` 为可选（`required` 仅 `title`/`description`，L91），description 明确写「owner is optional; when present it must name a currently attached data-plane agent confirmed by a successful list_agents or spawn_agent ToolResult received in an earlier tool-call round. Never name a planned or future agent. When creating before spawn or delegation, omit owner…」（L67）；`owner` 字段描述（L84）与 `depends_on` 描述（L79）均强调「earlier successful ToolResult」「Never reference a WorkTask that is only planned or created by another call in the same assistant response」。**与原报告「补充 owner/调用顺序合同」一致**。
- 注意：`task_create` 的 `permissionIntent` 仍为 `replayPolicy: .requiresManualReconciliation`（L125）。该静态 replayPolicy 未变；修复体现在**运行期 effectDisposition**而非静态 replayPolicy。二者属不同轴（replayPolicy 描述可否重放，effectDisposition 描述实际副作用），不必然矛盾，但 descriptor 层仍标 manual reconciliation、运行层标 notStarted 的张力值得后续注意。

`Packages/IntatisCowork/Sources/Orchestrator.swift`：

- `createWorkTask`（L5968-5998）：owner 校验 `guard owner != Self.automaticPermissionReviewerID, registry.agent(owner) != nil else { throw IntatisError.notFound("WorkTask owner is not an attached data-plane agent") }`（L5994-5998）发生在任何 WorkTask 事件 append 之前（preparedGraph/preparedEvents/created 在其后 L6000+）。**与原报告「owner 校验在任何 WorkTask 事件 append 之前正确拒绝」一致**。
- `provenWorkTaskCreatePreflightRejection`（L5924-5966）：把 preflight 拒绝映射为 `ToolExecutionRejectedWithoutSideEffect`，对 `.notFound`（owner 未 attach）给出 typed code `"owner_not_attached"`（L5941）并附纠正指引。**与原报告「更精确的 not_started 通道」一致**。
- 恢复路径中对 stale-revision / preflight-no-effect 的 `toolExecutionSettled` 使用 `effectDisposition: .notStarted`（L3083-3087）。**与原报告 not_started 语义一致**。

`Packages/IntatisCowork/Tests/WorkTaskRuntimeTests.swift`：

- `testMutatingWorkTaskToolsRejectMissingHostManagerAsNotStarted`（L200）、future-owner 用例（L405-420）：对 `owner:"dpv-ch2"`（未 attach）断言抛出 `ToolExecutionRejectedWithoutSideEffect` 且 `code == "owner_not_attached"`（L412），且 `XCTAssertEqual(afterEvents, beforeEvents)`（L419-420）证明**零 WorkTask 事件**。`testManagerFrozenContractRejectionIsProvenNotStarted`（L512）覆盖 manager 冻结合同拒绝。**测试与原报告事故描述（零副作用、可纠正、非 manual reconciliation）一致**。

### 2.3 「约六十个 mutating tools」复核

原报告 5.4 与第 22 节均把此数标为 UNKNOWN/需重新生成。复核观察：仓库中 `sideEffect` 类别至少包含 `.readOnly`/`.write`/`.exec`/`.destructive`/`.network`（`ShellGit.swift`、`BrowserTools.swift`、`DocumentTools.swift`、`FileTools.swift`、`PatchTool.swift`、`TerminalTools.swift`、`SessionNamingTool.swift`、`DocumentMediaTools.swift`、`MCPEventLogHostAdapters.swift` 等多处）。Grep 工具对 `sideEffect: \.\w+` 命中超过 100 处且截断，其中混杂 Sources 与 Tests、单工具多 git/browser 子命令。**精确去重计数需要原报告第 13.4 节 Side-Effect Boundary Matrix 那样的逐工具盘点**，本次只读复核不穷举。结论：原报告把该数标为「需重新生成」是恰当的；本复核不给出替代数字，仅确认其数量级非平凡（远超个位数）。

### 2.4 本点小结

- task_create descriptor 禁止 future owner + 调用顺序合同：**吻合**。
- owner 校验在首个 WorkTask append 前 + typed `owner_not_attached` + `effectDisposition: .notStarted`：**吻合**。
- 测试证明零副作用：**吻合**。
- 静态 `replayPolicy: .requiresManualReconciliation` 未变（运行期 notStarted）：**部分吻合**（修复在运行期，descriptor 层 replayPolicy 仍是 manual reconciliation，存在可指出的张力）。
- 「约六十个 mutating tools」：**无法证实具体数字**（原报告自标 UNKNOWN；需 Phase 1 盘点，本复核未穷举）。

---

## 复核点 3：INC-03 —— permission reviewer verdict 协议不稳定（原报告第 6 节）

### 3.1 原报告核心断言

- `PermissionReviewTextVerdictParser` 合同：恰有一条 final-line ASCII `ALLOW`/`DENY`、前面非空 reason、reason ≤ 240 字符、不接受 JSON、不接受 code fence、不接受多 marker/变体 marker。
- prompt 只要求「short nonempty reason」，未告诉模型 240 字符硬上限（prompt/parser 漂移）。
- 所有 parser 分支折叠为同一个 `malformed_verdict`。
- raw reviewer text 按隐私设计不写入 EventLog，因此具体失败分支 UNKNOWN。
- 6.4 节为「必须改进」建议（parser 返回 typed failure category、持久化无敏感分类、prompt/parser/test 同源、reason 过长不应阻断授权）。

### 3.2 源码核对

`Packages/IntatisPermission/Sources/PermissionReviewTextVerdict.swift`：

- `maximumReasonCharacterCount = 240`（L20）——**吻合**。
- `parse`（L22-54）：取末行作 marker（L31-32，`decision(forExactASCIIMarker:)` L56-65 为大小写不敏感精确 ASCII、无变体）；`markerCount == 1`（L41，拒多 marker）；reason 非空、`<= 240`、`!containsCodeFence`（``` 或 ~~~，L48/L81-83）、`!containsJSONPayload`（`{}`/`[]`，L49/L85-98）——**全部吻合**。
- **所有失败路径均 `return nil`**（L33、L41、L50）——parser 本身不返回 typed 失败类别，**吻合原报告「只有 nil」描述**。

`Packages/IntatisProtocol/Sources/ToolAuthorization.swift:769`：`case malformedVerdict = "malformed_verdict"`。

`Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`：

- parser nil 与「无 completion marker / 非 success finish reason」两条路径**都**以 `failureKind: .malformedVerdict` 持久化（L1038、L1053）。即 `missing marker`、`bad finish reason`、`multiple markers`、`empty reason`、`reason too long`、`code fence`、`JSON` 等全部折叠为同一 `.malformedVerdict`。**吻合原报告「所有 parser 分支折叠为同一个 malformed_verdict」**，且复核发现折叠面**比原报告所述更广**（连 transport 层的 completion/finish reason 失败也归入 malformedVerdict）。
- `invalidVerdictReason(output)`（L1027/1042 调用，定义 L1900-1911）返回**固定宿主文案**（如「permission reviewer returned a malformed plain-text verdict; automatic mode denied the request」L1910），而非 raw reviewer text。`persistTerminal` 持久化的 `reason` 是这些固定文案。**吻合原报告「raw reviewer text 不写入 EventLog」**；且持久化字段中**没有** `missing_marker`/`multiple_markers`/`reason_too_long`/`json_not_allowed` 这类 typed 诊断分类——**原报告 6.4 节的「持久化无敏感分类」建议尚未实现**。

### 3.3 prompt/parser 漂移复核

- reviewer prompt（`PermissionReviewControlPlane.swift` L1730「Return a short nonempty audit reason, then put exactly one ASCII verdict marker on the final nonempty line: ALLOW or DENY.」、L1825-1826「Return a short reason followed by ALLOW or DENY on the final nonempty line.」）**仍未提及 240 字符硬上限**。
- 文件中出现的 `240`（L1816、L2254、L2255、L2320）均为 `safeReviewText(..., maxCharacters: 240)`，用于截断**展示给 reviewer 的数据**（model 名、path、pattern），与「告诉模型 reason 上限」无关。
- 结论：**prompt 仍只要求 short reason，parser 仍硬拒 >240**——原报告 6.1 所述漂移**在当前代码中持续存在**。这与原报告把 prompt/parser 同源列为「必须改进」（6.4）而非「已修补」（第 20 节未列）一致。

### 3.4 「reason 过长不应阻断授权」建议

- 当前 parser 仍对 `reason.count > 240` 返回 nil → malformedVerdict → deny（PermissionReviewTextVerdict.swift L47）。原报告 6.4「reason 如果本来不持久化，不应因为非安全相关的冗长问题阻断整个授权」**尚未实现**；与原报告将其列为建议（非已修补）一致。

### 3.5 本点小结

- parser 规则（240/final-line/单 marker/拒 JSON/拒 fence）：**吻合**。
- parser 全返回 nil、折叠为单一 `malformed_verdict`：**吻合**（且折叠面更广）。
- raw text 不入 EventLog：**吻合**。
- prompt 未告知 240 上限（漂移）：**吻合且持续存在**（原报告亦未声称已修）。
- 6.4 建议（typed 失败类别持久化、prompt/parser 同源、reason 过长不阻断）：**未触及/未实现**——与原报告将其列为「必须改进」而非工作树已修补一致。
- 当日 DeepSeek 具体失败分支：**无法证实**（原报告自标 UNKNOWN；当前持久化也不足以反查，复核认同）。

---

## 复核点 4：INC-04 —— reviewer 模型错误跟随 `@main`（原报告第 7 节）

### 4.1 原报告核心断言

- 旧设计从 `@main` 派生/freeze reviewer binding；配置中 `judge_model` 实际未被读取、无生产链路。
- 新合同：顶层 `permission_reviewer_model`（`<provider>/<model-id>` base profile），不增加 UI 选项；host/config 层独立解析并冻结；不跟随 UI/session/default/live/historical `@main`/后续 rebind；字段缺失时仅在同一 JSON 解析阶段一次性继承顶层 `model`；显式空/类型错/route 不存在/provider 不可用/配置损坏时 fail closed，不得悄悄回退 main。

### 4.2 源码核对

**`judge_model` 无读取链路**：对 `judge_model|judgeModel` 全仓 Grep（Sources+Tests）**零命中**。**吻合原报告「judge_model 不是实际受支持字段、无生产读取链路」**。

`Apps/IntatisMac/Sources/AppConfig.swift`：

- 字段 `permissionReviewerModel: ModelRef?`（L282）+ `permissionReviewerModelWasExplicitlyConfigured: Bool?`（L286）。配置键 `permission_reviewer_model`（L280 注释、L1054 `root.keys.contains`）。
- 「字段缺失一次性继承顶层 model」：`normalizedRoleModelRef(catalog.permissionReviewerModel ?? (catalog.permissionReviewerModelWasExplicitlyConfigured == nil ? permissionReviewerFallback : nil), …)`（L698-708）。`permissionReviewerFallback` 由 `selectedProviderID`/`selectedModelID` 构造（L695-697）。注释（L700-704）说明 nil marker 表示 legacy 内部 catalog。
- 「显式非法/损坏 fail closed」：`catalogWithPermissionReviewerFailedClosed()`（L1082-1097）：配置无法产出 catalog 时，`failClosed.permissionReviewerModel = nil` 且 `WasExplicitlyConfigured = true`；注释（L1073-1078）明确「leave this authorization role explicitly unavailable instead of retargeting it to stale UI or @main state」。**吻合原报告「配置损坏 fail closed、不回退 main」**。
- write-back 保留 presence（L1218-1226）：有值写字符串、无值写 `NSNull`，避免把 explicit-null 写成 absent。

`Apps/intatis-cli/Sources/CLIProviderCatalog.swift`：

- `permissionReviewerFieldPresent`（L180）区分 present/absent；`selectPermissionReviewerModel`（L300）。
- fail-closed 错误：「absent and the JSON top-level model is unavailable」（L313）、「cannot inherit an unknown JSON top-level model」（L325）、「invalid CLI permission_reviewer_model」（L460）、「does not resolve to a configured inference model」（L469）、「must use the canonical provider/model shape」（L476）。**吻合原报告 CLI 侧 present-aware + fail-closed 合同**。

`Packages/IntatisCowork/Sources/Orchestrator.swift`：

- `bootstrapFreshSession(... permissionReviewerModel: ModelID, permissionReviewerInferenceBinding: AgentInferenceBinding? …)`（L1586-1592）：reviewer 模型与 binding 作为**显式冻结参数**传入，不来自 `@main`。
- 校验 `permissionReviewerInferenceBinding.modelID != permissionReviewerModel` → fail（L1602-1607）；reviewer Agent 用 `model: permissionReviewerModel`（L1646）、`profile: .readOnly`（L1648）、`coordinationDepth: 0`（L1649）。**吻合原报告「reviewer binding 独立解析并冻结、read_only、depth 0、不跟随 main rebind」**。

「不增加 UI 选项」：Grep 命中 `CoworkViewModel.swift`/`IntatisMacApp.swift` 中的 `permission_reviewer_model` 均为**校验/错误文案**（如 L298「Configure a resolvable permission_reviewer_model before creating Cowork.」、L449「The configured permission_reviewer_model is missing, invalid, or unavailable…」、CoworkViewModel L1704/L1925），**未发现 UI 选择器控件**。**吻合原报告「不增加 UI 选项」**。

### 4.3 可指出的细节/张力

- macOS legacy-catalog 桥接：`permissionReviewerModelWasExplicitlyConfigured == nil`（早于该字段的 legacy 内部 catalog）时，reviewer 回退到 `permissionReviewerFallback`，而后者由**当前 UI 选择的** `selectedProviderID`/`selectedModelID` 构造（L695-697、L705-707）。即原报告「reviewer 不跟随 UI 当前选择」对**现代配置**严格成立，但对**legacy 内部 catalog**存在一条窄迁移例外（注释 L700-704 自述为 legacy 兼容）。这是一条可指出的边界，但不违背现代配置的不变量。
- 原报告 7.3 列出的 focused tests（`AutomaticPermissionReviewTests`/`PerAgentInferenceProfileTests`/`CLIProviderAdapterTests`/`IntatisCLITests`/`swift build`）属运行时事实；v0.49 stat 显示 `CLIProviderAdapterTests.swift`(+277)、`AutomaticPermissionReviewTests.swift`(+291) 等已扩展，但「是否已跑全量 suite / 真实 reviewer provider 矩阵 / config migration 全场景」源码无法证明，复核不替代运行验证。

### 4.4 本点小结

- `judge_model` 无读取链路：**吻合**（零命中）。
- `permission_reviewer_model` 独立配置、无 UI 选项、缺省一次性继承顶层 model、显式非法/损坏 fail closed、bootstrap 冻结且不跟随 main rebind、reviewer read_only/depth 0：**吻合**。
- legacy 内部 catalog 回退当前 UI 选择：**部分吻合**（窄迁移例外，现代配置不变量不受影响）。
- focused tests 已通过/全量/真实 provider 矩阵：**无法由源码证实**（运行时事实，原报告 7.3 亦未声称已跑全量）。

---

## 复核点 5：INC-05 —— worker `task_update`、有效 DENY 与完成失败（原报告第 8 节）

### 5.1 原报告核心断言

- manager 与 worker 共享同一宽 `task_update` 模型面 schema；worker 实际不能改图结构/owner/priority/retry/冻结合同，系统主要依赖 description/prompt/reviewer/executor 后置 preflight/completion fuse。
- 8.4 推荐：按角色投影（如 `update_owned_work_task`，schema 根本不暴露冻结合同字段）。
- 首次调用 executor 在首个 WorkTask append 前拒绝、`effectDisposition=not_started`、无副作用；第二次 reviewer 给出协议合法的语义 DENY、无 `tool_execution_prepared`、无 executor 副作用。
- SideEffectEvidenceLedger 持有 unresolved denied/failed `task_update` → completion fuse 阻止假完成 → child 以 `unresolved_denied_side_effects` 失败、WorkTask 保持 `in_progress`。
- literal backslash 最初来源 UNKNOWN。

### 5.2 源码核对

`Packages/IntatisCowork/Sources/WorkTaskTools.swift`：

- `task_update` descriptor（L163-222）：`required` 仅 `task_id`/`expected_revision`（L220），`properties` 暴露 `title`/`description`/`acceptance_criteria`/`expected_artifacts`/`owner`/`depends_on`/`priority`/`progress_note`/`status`/`result`/`evidence`/`retry` **全部 optional 字段**（L172-219）。**吻合原报告「manager 与 worker 共享同一宽 schema、模型可发送全部 optional 字段」**。
- descriptor 描述（L168）以文字约束 worker 行为（"Workers may update progress/status/result/evidence on their assigned task but cannot change its contract. …"），即依赖文字而非 schema 机械排除。**吻合原报告 8.3「主要依赖 description…」的批评**。

`Packages/IntatisCowork/Sources/Orchestrator.swift`：

- `provenWorkTaskUpdatePreflightRejection`（L6108-6150）：把 task_update 的 preflight 拒绝映射为 `ToolExecutionRejectedWithoutSideEffect`，含 typed code（staleRevision / permission_denied / not_found / invalid_update / …）与「rejected without applying changes … Call task_get … then retry …」纠正指引。`updateWorkTask` 在 L6331 `throw Self.provenWorkTaskUpdatePreflightRejection(...)`。**吻合原报告「task_update 首个 WorkTask append 前拒绝 = not_started、无副作用」**，且为 5.4 所述「更精确 not_started 通道」的一部分。
- capability 区分 manager/worker：`Leases.swift:42` `case updateOwnedWorkTask = "update_owned_work_task"`（L152 列入 worker 能力）。但 `Orchestrator.swift:11188-11189` `if lease.tools.contains(.updateOwnedWorkTask) { register([TaskUpdateTool()], granting: [.updateOwnedWorkTask]) }`——worker 拿到的仍是**同一个 `TaskUpdateTool()`**（同一个宽 schema），仅以 capability 闸门访问，**未按角色投影成更窄的 schema**。L2972-2974、L7616 也仅以 `capabilityLease.tools.contains(.updateOwnedWorkTask)` 区分 canUpdateOwned。

**结论**：原报告 8.4 推荐的「独立、最小、不暴露冻结合同字段的 worker 工具」**尚未实现**；当前仅以 capability lease 区分 manager/worker，模型面 schema 未收窄。这与原报告把 8.4 列为推荐、第 20 节未列入「工作树已修补」一致，亦与第 21 节 DEC-02「是新增 `update_owned_work_task`，还是按 capability 投影同名 `task_update` 的不同 schema？」的待决状态一致。当前实现选择了后者（capability 投影同名工具），但**未实际投影出不同 schema**。

`Packages/IntatisAgentKernel/Sources/AgentLoop.swift`：

- `SideEffectEvidenceLedger` actor（L191），`AgentLoopError.unresolvedDeniedSideEffects([String])`（L68）；`throw AgentLoopError.unresolvedDeniedSideEffects(unresolved)`（L1078）——completion fuse 在存在 unresolved denied/failed 副作用时阻止假完成；`case .unresolvedDeniedSideEffects: code = "unresolved_denied_side_effects"`（L1850-1851）给出 typed code。**吻合原报告「SideEffectEvidenceLedger 持有 unresolved denied/failed → completion fuse 阻止假完成 → unresolved_denied_side_effects」**。
- 该行为由 `AgentLoopPolicyTests.swift`（L2029/L2245/L2275/L2360/L2489/L2557）、`OrchestrationReliabilityTests.swift`（L2938）、`IntatisConversationCodeTests.swift`（L70 `code: "unresolved_denied_side_effects"`）测试覆盖。

### 5.3 第二次 reviewer 语义 DENY / 无 executor 副作用

- reviewer 可返回协议合法的 `DENY`（`PermissionReviewTextVerdictParser` 的 `decision(forExactASCIIMarker:)` 支持 `DENY`，PermissionReviewTextVerdict.swift L60-63）。DENY 在权限层结算，不进入 executor；原报告「无 `tool_execution_prepared`、无 executor 副作用」与「durable tool execution ticket → executor」的分层一致。该具体运行时事件链（8.1 第二次调用的逐字段值）属运行时事实，源码层面只能确认机制存在，**无法证实当日具体 DENY 的逐字理由**（raw reason 不落盘，原报告自标 UNKNOWN，复核认同）。

### 5.4 literal backslash 来源

- 原报告 8.5 标 UNKNOWN。复核未追溯 `学分\/学时` 类转义的引入层；当前源码无法独立判定该 backslash 由模型输出、转义层、历史再编码或 canonicalization 中哪一层引入。**维持 UNKNOWN**，与原报告一致。

### 5.5 本点小结

- 共享宽 `task_update` schema、依赖文字约束（非 schema 机械排除）：**吻合**。
- `update_owned_work_task` 仅为 capability、仍注册同一宽 `TaskUpdateTool`：**吻合**（8.4 推荐的独立最小工具**未实现**，与原报告将其列为推荐/DEC-02 待决一致）。
- task_update preflight `not_started` 通道（`ToolExecutionRejectedWithoutSideEffect`）：**吻合**。
- completion fuse / `SideEffectEvidenceLedger` / `unresolved_denied_side_effects`：**吻合**（且有测试覆盖）。
- 第二次语义 DENY 逐字理由 / literal backslash 来源：**无法证实**（原报告自标 UNKNOWN，复核认同）。

---

## 复核点 6：INC-06 —— 600 秒 deadline 最后 832 秒才结算（原报告第 9 节）

### 6.1 原报告核心断言

- root `executionTimeoutSeconds=600`；root 同步等待 `delegate_task -> awaitSchedulerResult(child)`。
- 600 秒 timer 到期后 parent operation 被 cancel，但 `awaitSchedulerResult` 使用 `withCheckedContinuation` 无 cancellation handler；child scheduler execution 也不因 parent timeout 自动停止。
- timeout wrapper 为不在 loser 清理前落 terminal，继续 drain/join；直到 child 自然终态（约 20:08）continuation 才恢复，root 才落盘 `Task timed out after 600 seconds`；UI 统计约 832 秒。
- 9.3 节为待决产品决策（方案 A 总 wall-clock / 方案 B delegated child 不计入），DEC-01 未决；原报告标「未修」。

### 6.2 源码核对

`Packages/IntatisCowork/Sources/Orchestrator.swift`：

- `awaitSchedulerResult(_ taskID:)`（L10901-10913）：
  ```swift
  return await withCheckedContinuation { continuation in
      resultWaiters[taskID, default: []].append(continuation)
      schedulerResultWaiterHookForTesting?(taskID)
  }
  ```
  仅把 continuation 追加到 `resultWaiters[taskID]`，**无 `withTaskCancellationHandler`、无 `continuation.resume` on cancel**。`withCheckedContinuation` 不会因 `Task.cancel` 自动恢复；continuation 只在 child 对该 taskID 产出结果时被 resume。**精确吻合原报告「child wait 使用 withCheckedContinuation，没有 cancellation handler」**，且该结构在当前代码中**仍存在（未修）**。

- 调用点为 root/parent 的同步委派等待：L3250、L3510、L4424、L5431、L5489（`_ = await awaitSchedulerResult(...)` / `let report = await awaitSchedulerResult(...)`）。

- `withTaskTimeout`（L220-280）：用 `withThrowingTaskGroup` 让 `operation` 与 `Task.sleep(timeout)` 赛跑。任一方先到即 `group.cancelAll()`，随后**显式 drain loser**：
  ```swift
  while true {
      do { guard try await group.next() != nil else { break } }
      catch is CancellationError { … }
      catch { … }   // first terminal owns the race; loser late failure cannot replace it
  }
  ```
  注释（L246-248）：「Explicitly drain the losing child as well so the terminal task event cannot be committed while provider/tool cleanup is still executing.」catch 分支（L266-278）对 caller cancellation/provider failure 同样 drain。**精确吻合原报告「timeout wrapper 为不在 loser 清理前落 terminal，继续 drain/join」**。

- 二者合流：timeout 触发 → `group.cancelAll()` 取消 `operation`（即 `run`）→ 但 `run` 阻塞在 `awaitSchedulerResult` 的无 handler continuation → cancel 无法释放 waiter → `while true { group.next() }` 必须等 `operation`（即 child 终态）才结束 → `withTaskTimeout` 在 child 终态后才抛 `.timedOut`。**精确复现原报告「root 到 832 秒才完成结算」的因果链**。child 的 scheduler execution 是独立调度任务，parent cancel 不取消它，**吻合「child scheduler execution 也没有因 parent timeout 自动停止」**。

- 超时数值：`timeout = task.contract.executionTimeoutSeconds ?? executionPolicy.taskTimeoutSeconds`（L9681），`withTaskTimeout(seconds: timeout)`（L9683）。`OrchestrationReliabilityTests.swift:1538` 断言 `XCTAssertEqual(root.executionTimeoutSeconds, 600)`。**吻合原报告 600 秒**。

### 6.3 当前代码对该行为的定位

`OrchestrationReliabilityTests.swift` L2290-2293 注释将该 drain 表述为**有意设计**："The watchdog has fired, but structured timeout cleanup keeps the scheduler task non-terminal until this finite blocking provider unwinds. A permanently synchronous provider is outside the runtime contract and would intentionally keep the task non-terminal." 即：drain 是为清理顺序而设，并非单纯缺陷；但与「无 cancellation propagation 到 delegated-child wait」叠加后，600 秒 deadline 并非真正 wall-clock 预算。这恰好对应原报告 9.3 / DEC-01 所述「deadline 语义含糊、需产品二选一」——当前代码**未做该选择**，故 INC-06 **维持未修状态**，与原报告一致。

### 6.4 本点小结

- `awaitSchedulerResult` 使用无 handler 的 `withCheckedContinuation`：**吻合**（且当前仍存在）。
- `withTaskTimeout` 显式 drain loser、terminal 晚于清理：**吻合**（L246-258、L270-276）。
- root timeout 不能释放 delegated-child wait → 832 秒才结算的因果链：**吻合**（机制在源码中可还原）。
- `executionTimeoutSeconds=600`：**吻合**（测试 L1538）。
- 9.3 / DEC-01 deadline 语义二选一：**未决/未修**（与原报告「未修」一致）。
- 具体运行时时间戳（19:54/20:03/20:08、832.242 秒）：**无法由源码证实**（属运行时 EventLog 事实，原报告 9.1 给出，复核不重放 EventLog）。

---

## 复核点 7：INC-07 —— 错误来源在 UI 被压扁（原报告第 10 节）

### 7.1 原报告核心断言

- 10.1：reviewer 语义 DENY 真实路径为 `DeterministicPolicyGate pass/medium → automatic reviewer DENY → source=automatic_reviewer`，但 UI 据「折叠后的 `failureSource=policy_denied`」显示「task_update call denied by policy」，使用户无法区分 deterministic hard deny、automatic reviewer semantic deny、reviewer malformed/failure、authorization revalidation failure、MCP policy deny。durable `permission_resolved` 仍保留 `source=automatic_reviewer`；折叠发生在 control-plane/tool-result 映射。
- 10.2：root 失败是 Cowork task deadline + cancellation-unaware child wait，但 UI 据 `message.contains("timed out")` 字符串分类，给出「Retry or switch provider / This looks transient or provider-side」——对本事故错误。
- 10.3：正确链 typed runtime error → durable event code/source/effectDisposition/retryDisposition → projection typed state → UI copy + recovery；禁止 `message.contains("timeout")`、generic `policy_denied`、字符串推断。原报告标「未修」。

### 7.2 源码核对

`Packages/IntatisSharedUI/Sources/CodeViews.swift` 权限通知标题（L854-871）：**UI 标题是按 typed `failureSource` switch 的**，并非只消费单一粗字段：

```
.policyDenied       → "%@ call denied by policy"
.reviewerTimedOut   → "Automatic review timed out"
.reviewerFailed     → "Automatic review failed"
.sandboxDenied      → "Sandbox denied %@"
.userDenied         → "%@ call declined"
.userCancelled/.turnCancelled → "Turn cancelled"
.runtimeFailed      → "%@ runtime failed"
nil                 → "%@ denied"
```

即 UI **确实区分** reviewer 失败（`.reviewerFailed`）、reviewer 超时（`.reviewerTimedOut`）、sandbox、user decline、runtime failure。故原报告 10.1「UI 无法区分 reviewer malformed/failure」**不精确**——这些在标题层是可区分的。

但核心折叠点成立：`Packages/IntatisAgentKernel/Sources/AgentLoop.swift:3921` `failureSource: outcome.decision == .deny ? .policyDenied : nil`——**任何 deny 决策**（无论来自 deterministic gate 还是 automatic reviewer 语义 DENY）都映射为 `.policyDenied`；`ExecutionFailureSource` 枚举中**无 `.reviewerDenied` 分支**（全仓 Grep 未见）。因此 reviewer **语义 DENY** 与 deterministic **hard deny** 都落到 `.policyDenied` → 标题「call denied by policy」。**这一具体折叠与原报告 10.1 吻合**（reviewer-FAILURE 与 reviewer-DENY 是两回事：前者有独立 `.reviewerFailed`，后者折叠进 `.policyDenied`）。

### 7.3 10.2 字符串分类复核

`Packages/IntatisConversation/Sources/RuntimeErrorPresentation.swift`：

- `recoveryAdvice(code:message:)`（L112-191）混用 code 与 **message 子串匹配**。L157-177：
  ```
  if normalizedCode == "provider.network"
      || lower.contains("network")
      || lower.contains("timed out")
      || lower.contains("timeout")
      || lower.contains("could not connect") ... {
      → title "Retry or switch provider"
      → detail "This looks transient or provider-side. Retry after the suggested delay, reduce context size, or switch provider."
  }
  ```
  「Retry or switch provider」「This looks transient or provider-side」**逐字命中原报告 10.2 引述**。`message(for:)`（L56-67）取 `error.localizedDescription` 经 sanitizer——`CoworkTaskExecutionError.timedOut(seconds:)` 的描述含「timed out」，会触发 L159 `lower.contains("timed out")` → 上述 transient/provider-side 建议。**吻合原报告「UI 据 message.contains("timed out") 做字符串分类」**，且该字符串分类在当前代码中**持续存在（未修）**。

- `code(for:)`（L25-54）将 `IntatisError.permissionDenied` 映射为单一 `"permission_denied"`（L44-45），不携带 `automatic_reviewer` 等来源；`recoveryAdvice` 对 `permission_denied` 给出「Review permission and rerun / blocked by policy or user decision」（L143-148）。**吻合原报告「来源在 code/message 层丢失」**。

### 7.4 两层 UI 差异（可指出的事实）

复核发现 UI 实际有**两条**错误展示路径，原报告未细分：

1. **标题层**（`CodeViews.swift` 权限通知）：typed `failureSource` switch——reviewer 失败/超时、sandbox、user 在标题层**可区分**；唯独 reviewer 语义 DENY 与 deterministic deny 同落 `.policyDenied`。
2. **恢复建议层**（`RuntimeErrorPresentation.recoveryAdvice`）：code + message **字符串匹配**——timeout 走 `contains("timed out")` → provider/transient 建议，policy 走 `permission_denied` → 「blocked by policy」。

原报告 10.1 主要对应标题层折叠（reviewer DENY→policyDenied），10.2 主要对应恢复建议层字符串分类。二者均为真，但原报告把「UI 无法区分 reviewer malformed/failure」写入 10.1 清单与标题层事实有出入（标题层可区分 `.reviewerFailed`）。

### 7.5 本点小结

- 10.1 reviewer 语义 DENY 折叠进 `.policyDenied` →「denied by policy」、与 deterministic hard deny 不可区分：**吻合**。
- 10.1「UI 无法区分 reviewer malformed/failure」：**部分吻合/不精确**（标题层有独立 `.reviewerFailed`/`.reviewerTimedOut`，可区分；原报告清单过宽）。
- 10.2 scheduler timeout 经 `message.contains("timed out")` →「Retry or switch provider / transient or provider-side」：**吻合**（逐字命中 RuntimeErrorPresentation.swift L174-175，且当前仍存在）。
- 10.3 typed error 全链 / 禁止字符串推断：**未实现**（恢复建议层仍用 `contains` 字符串分类），与原报告「未修」一致。
- 原报告「durable `permission_resolved` 仍保留 `source=automatic_reviewer`，折叠发生在 control-plane/tool-result 映射」：**吻合**（EventLog 层 reviewer 路径独立 typed，折叠发生在 `failureSource`/`code` 映射层）。

---

## 复核点 8：结构性章节复核（原报告第 13 矩阵 / 14 不变量 / 21 DEC / 22 UNKNOWN）

### 8.1 第 13 节「全仓只读审计清单」（13.1–13.10）

该节为 10 张矩阵的**待办清单**，所有条目均为未勾选的 `[ ]`（Tool Surface / Role-Capability / Schema-Wire / Side-Effect Boundary / Wait-Timeout-Cancellation / Permission Routing / EventLog→Projection→UI Error / Config-Binding / Prompt-Skill-Descriptor / Recovery-Replay）。原报告自身在第 23 节把「完成 Phase 1 只读全仓矩阵」列为下一步、未声称已完成。复核结论：**矩阵确为待办状态**，原报告未将其误标为已完成；本只读复核亦不替代该 Phase 1 盘点。复核点 2 已对「约六十个 mutating tools」作出说明（需重新生成）。

### 8.2 第 14 节「自动不变量」抽样核对

抽样几条有源码支撑的不变量：

- **14.1「reviewer 工具列表必须为空」**：`PermissionReviewControlPlane.swift:1714` reviewer prompt 明写「You are a control-plane reviewer, not a task worker. You have no tools and must never request or simulate tool use.」；L1017 对 reviewer 试图 tool call 以 `reviewerContractViolation` 拒绝。reviewer 在 bootstrap 以 `profile: .readOnly`、`coordinationDepth: 0` 注册（`Orchestrator.swift:1648-1649`），且全仓多处 `guard to != Self.automaticPermissionReviewerID` 阻止其成为 delegate/message/owner 目标。**吻合**。
- **14.2「request-owned decoration 不改变 business executor contract」「PATCH 工具没出现的字段不修改」**：`AuthorizationSidecarCodec.extract` 用 `object.removeValue(forKey: reservedFieldName)` 剥离 sidecar（`AuthorizationSidecar.swift:256`），`executableCall.arguments` 用剥离后的 canonical business args（L376-383）；`task_update` decodeRequest 对 optional 字段 `owner = .unchanged`（`WorkTaskTools.swift:308`）。**吻合**。
- **14.5「deterministic hard deny 终局」「reviewer 只能收窄，不能扩大 gate 权限」**：`DeterministicPolicyGate.swift:5`「its `deny` is final」；`ModelPermissionReviewer.swift:7-8`「only `pass` results … can narrow to deny/ask but never reaches a hard-denied action」；`PermissionTypes.swift:105-106`；`PermissionEngine.swift:44`「a reviewer can never turn a hard deny into allow」。**吻合**。
- **14.5「mechanically provable internal settlement 不应被概率 reviewer 随机阻断」**：**未实现**——worker `task_update` 仍走概率 reviewer（见复核点 5；`updateOwnedWorkTask` 仅 capability、同宽 schema）。原报告将此列为 DEC-03 待决，**一致**。
- **14.6「explicit invalid 永远不等于 missing」「reviewer route 只来自 frozen config binding」**：见复核点 4（AppConfig fail-closed + bootstrap 冻结）。**吻合**。

抽样未覆盖全部 14.1–14.7 条目；未抽到的条目本复核不宣称已验证。

### 8.3 第 21 节 DEC-01–DEC-06 框架核对

逐条对照当前源码状态：

- **DEC-01 root deadline 语义**：未决（INC-06 未修，`awaitSchedulerResult` 仍 cancellation-unaware，`withTaskTimeout` 仍 drain loser）。**吻合「待决」**。
- **DEC-02 worker settlement API**：未决（`update_owned_work_task` 仅为 capability、仍注册同一宽 `TaskUpdateTool`，无独立最小工具）。**吻合「待决」**。
- **DEC-03 mechanical settlement 绕过 reviewer**：未决（worker settlement 仍经概率 reviewer）。**吻合「待决」**。
- **DEC-04 reviewer diagnostic 隐私边界**：未决（持久化仅固定宿主文案 + `.malformedVerdict`，无 `missing_marker`/`reason_too_long` 等 typed 分类）。**吻合「待决」**。
- **DEC-05 durable typed error schema**：未决（恢复建议层仍用 `contains` 字符串分类）。**吻合「待决」**。
- **DEC-06 unknown side effect 下的 UI 行为**：原报告推荐只显示 Reconcile/Inspect、不显示普通 Retry。复核未单独验证 unknown-effect 路径的 UI 按钮；`RuntimeErrorPresentation.recoveryAdvice` 对未命中任何分支的情况返回 `nil`（L190），是否在 UI 上等价于「不显示 Retry」需结合调用方判定，本复核记为**未深入验证**。

### 8.4 第 22 节 UNKNOWN 清单核对

原报告列 7 项 UNKNOWN。复核对照：

1. 「mutating shipping tools 精确数量」：复核点 2 已说明需重新生成。**维持 UNKNOWN**。
2. 「当日 DeepSeek malformed reviewer text 具体 parser 失败分支」：复核点 3 证实 raw text 不落盘、持久化仅 `.malformedVerdict`，无法反查。**维持 UNKNOWN**。
3. 「literal backslash 最初由哪一层引入」：复核点 5 未追溯。**维持 UNKNOWN**。
4. 「仓库中所有 cancellation-unaware continuation/waiter 的完整数量」：复核点 6 确认 `awaitSchedulerResult` 为其一；全仓 `withCheckedContinuation` 命中极多（权限/scheduler/mailbox/goal-verifier/idle 等多处），逐一判定「是否有 cancellation handler」需逐点审计，本复核未穷举。**维持 UNKNOWN**。
5. 「所有 shipping provider 对 strict tool schema 与 reviewer plain-text contract 的真实兼容状态」：运行时事实，源码无法证明。**维持 UNKNOWN**。
6. 「当前未提交修补在完整测试矩阵和长时 soak 下是否稳定」：**措辞已过时**——复核点 0 证实该修补已于 21:23 提交为 v0.49，不再是「未提交」；但「是否在完整测试矩阵/长时 soak 下稳定」本身仍属运行时 UNKNOWN。**维持 UNKNOWN（但「未提交」措辞需更正为「已提交未充分验证」）**。
7. 「是否还有未被当前事故触发的 effect-boundary/config fallback/projection/replay 缺陷」：系统性未知。**维持 UNKNOWN**。

### 8.5 本点小结

- 第 13 节矩阵：**待办状态**（原报告未误标完成）。
- 第 14 节抽样不变量（reviewer 空工具、sidecar 剥离、gate hard-deny 终局/reviewer 只收窄、config fail-closed）：**吻合**；mechanical settlement 绕过 reviewer：**未实现**（与 DEC-03 待决一致）。
- 第 21 节 DEC-01–DEC-05：**吻合「待决」**；DEC-06 未深入验证。
- 第 22 节 UNKNOWN：**7 项维持 UNKNOWN**，其中第 6 项「未提交修补」措辞**已过时**（实为已提交 v0.49 未充分验证）。

---

## 9. 总体复核结论

### 9.1 逐点结论汇总

| 复核点 | 对应原报告 | 结论 | 要点 |
|---|---|---|---|
| 0 | §19/20/24 | 部分吻合 | 19 触点全存在；但「未提交工作树」已过时——改动已于 21:23 提交为 v0.49 |
| 1 | §4 INC-01 | 吻合 | sidecar required + 递归 strict 校验 + tool_search_output 装饰 + 发网前 typed throw 均在；原始 bug 形态无法由当前源码复现（已修） |
| 2 | §5 INC-02 | 吻合（含张力） | owner 校验在首个 append 前、typed `owner_not_attached`、`notStarted`、测试证零副作用；静态 `replayPolicy: requiresManualReconciliation` 未变（与运行期 notStarted 存在张力）；~60 mutating tools 维持需重新生成 |
| 3 | §6 INC-03 | 吻合 | parser 规则、240、全返回 nil、折叠为单一 `malformed_verdict`、raw text 不落盘 均吻合；prompt 未告知 240（漂移持续）；6.4 typed 诊断建议未实现 |
| 4 | §7 INC-04 | 吻合（含窄例外） | `judge_model` 零读取；`permission_reviewer_model` 独立配置/无 UI/缺省一次性继承/显式非法 fail closed/bootstrap 冻结 均在；legacy 内部 catalog 回退当前 UI 选择为窄迁移例外 |
| 5 | §8 INC-05 | 吻合 | 共享宽 schema、依赖文字约束；`update_owned_work_task` 仅 capability 仍注册同一宽工具（8.4 推荐未实现）；preflight `notStarted` 通道、completion fuse/`unresolved_denied_side_effects` 在 |
| 6 | §9 INC-06 | 吻合（未修） | `awaitSchedulerResult` 无 handler 的 `withCheckedContinuation` 仍在；`withTaskTimeout` 显式 drain loser；600s 默认；DEC-01 未决 |
| 7 | §10 INC-07 | 部分吻合 | reviewer 语义 DENY 折叠进 `.policyDenied`→「denied by policy」吻合；timeout 经 `contains("timed out")`→「Retry or switch provider」吻合；但 UI 标题层实有 typed `failureSource`（`.reviewerFailed`/`.reviewerTimedOut`/`.sandboxDenied` 等可区分），原报告 10.1「无法区分 reviewer malformed/failure」清单过宽 |
| 8 | §13/14/21/22 | 吻合 | 矩阵确为待办；抽样不变量（reviewer 空工具/sidecar 剥离/gate hard-deny 终局/config fail-closed）吻合；mechanical settlement 绕过 reviewer 未实现（DEC-03）；DEC-01~05 待决吻合；UNKNOWN 7 项维持，其中第 6 项「未提交」措辞过时 |

### 9.2 总体判断

原报告作为「事故汇总 + 只读审计计划 + 重构门禁」**事实层基本准确**：7 个事故中，已修补项（INC-01/02/04 的修补面、INC-03/05 的 not_started 通道、INC-05 的 completion fuse）在当前 v0.49 源码中可被验证存在；未修项（INC-06 cancellation、INC-07 typed error 全链、INC-03/05 的 schema 收窄与 typed 诊断、prompt/parser 同源）在源码中确为未修，与原报告标注一致。

**复核发现的可指出偏差/过时点（共 4 处）**：
1. 第 20 节「未提交工作树」措辞已过时——修补已于 21:23 提交为 v0.49（复核点 0）。
2. 第 22 节第 6 项 UNKNOWN「当前未提交修补…是否稳定」同上，应更正为「已提交未充分验证」（复核点 8）。
3. 第 10.1 节「UI 无法区分 reviewer malformed/failure」与源码不符——UI 标题层有 typed `.reviewerFailed`/`.reviewerTimedOut`；真正不可区分的只是 reviewer 语义 DENY vs deterministic hard deny（均落 `.policyDenied`）（复核点 7）。
4. 第 5.4/8 节隐含的「task_create/task_update not_started 通道」与静态 `replayPolicy: .requiresManualReconciliation` 并存——修复在运行期 effectDisposition，descriptor 层 replayPolicy 未动，存在可指出的张力（复核点 2）。

**复核未发现原报告的事实性硬错误**（即源码与断言直接冲突）；上述 4 点均为措辞过时或清单过宽，不改变原报告的事故归因与门禁结论。

### 9.3 本复核未做的事（边界声明）

- 未重放 EventLog，故所有「已证实」运行时事件链（具体时间戳、832.242 秒、DeepSeek/Luna 具体输出、literal backslash、具体 DENY 理由）均**未独立证实**，仅核对宿主侧机制是否与原报告描述一致。
- 未穷举全仓 mutating tools、未穷举所有 cancellation-unaware continuation、未逐一验证 14.1–14.7 全部不变量、未验证 DEC-06 的 unknown-effect UI 按钮——这些原报告自身标 UNKNOWN/待 Phase 1 盘点。
- 未运行 build/test（本任务为只读审计；AGENTS.md 允许文档任务仅运行 `git diff --check` 与 `git status --short`）。

---

## 10. 本报告自身的检查记录

- `MODEL_CHECK_RESULT`：当前会话模型为 `OpenRouter/z-ai/glm-5.2`（环境标注）；无法独立确认服务端精确模型版本。
- `PATH_CHECK_RESULT`：`pwd` = `/Users/vita/Vitemis/Intatis`；`git rev-parse --show-toplevel` = `/Users/vita/Vitemis/Intatis`；一致，匹配预期。
- `FILES_WRITTEN`：仅新增本报告 `08_12_26-21_26-cowork-stabilization-checklist-verification-audit.md`。**未修改任何源码、配置、构建脚本或测试**。
- `PROJECT_AUDIT_SUMMARY`：对照原报告 7 事故 + 结构章节，核查 AgentKernel(sidecar/AgentLoop)、Cowork(Orchestrator/WorkTaskTools/PermissionReviewControlPlane)、Permission(Verdict/Gate/Reviewer/Engine)、Conversation(RuntimeErrorPresentation/CodeProjection)、SharedUI(CodeViews)、Apps(AppConfig/CLIConfig) 等模块。
- `DOCS_CONTENT_SUMMARY`：本报告含 10 节——头注/分级、复核点 0(仓库与触点)、1–7(七个事故)、8(结构章节)、9(总体结论)、10(自检)。
- `VALIDATION_RESULT`：见下节「实际运行命令与结果」。
- `UNCERTAINTIES`：运行时事件链均未独立重放（见 9.3）；mutating tools 精确数、全部 cancellation-unaware continuation、全部 shipping provider 兼容、DEC-06 UI 按钮未验证。
- `NEXT_RECOMMENDED_ACTION`：不建议据本复核自动改源码。若要推进，按原报告 Phase 1 完成全仓只读矩阵，并优先闭合 INC-06（deadline 语义/cancellation 传播）与 INC-05/DEC-02（worker-owned settlement schema 收窄）两个 P0 边界——这两项在当前源码中确为未修。
