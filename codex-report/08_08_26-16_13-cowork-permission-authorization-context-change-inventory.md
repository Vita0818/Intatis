# Cowork 权限审查授权上下文修复：接口、文件与函数变更清单

日期：2026-08-08

仓库：`/Users/vita/Vitemis/Intatis`

范围：本次 Cowork automatic ask-class permission authorization context 修复

状态：实现与验证已完成，尚未 Git add/commit/push

## 结论

本次没有增加新的 Orchestrator 对外命令，也没有修改 UI、App target、PermissionEngine 三层门的
公开调用方式。对外协议面只有两个 additive `Codable` 类型、一个 optional 字段和一个 typed failure
枚举值；其余改动位于 AgentKernel 请求内报告器、Permission Review 控制面验证、测试和项目文档。

## 2026-08-11 兼容性修正（覆盖本文旧 `tools: []` / `no-tools` 报告器描述）

真实 OpenRouter exact Agent route 验证发现：原报告器虽然接口与 host binding 已完成，但依靠
`tools: []` 自由文本返回 JSON，不能可靠保证模型交付结构化报告；而在本次验证的
`deepseek/deepseek-v4-flash-0731` 路由上，forced `tool_choice` 与 `response_format` 又会在模型调用前被
上游兼容性检查拒绝。最终最小修正不改公开协议、PermissionEngine、reviewer 接口或业务工具 schema：

- 报告请求仍复用 acting agent 的 exact provider/model 与冻结 conversation snapshot，但只暴露一个
  output-only `submit_permission_authorization` function；该 function 不注册进 `ToolRegistry`，不获得执行
  ticket，也永远不会执行；
- 不强制 `tool_choice` / `response_format`。宿主只接受无 prose、恰好一个同名 function call，随后对
  arguments 做原有 exact JSON、secret、handle、EventLog closure 与 authorization binding 验证；错名、
  缺失、多个 call、混入文本或 malformed arguments 均保持 typed fail closed；
- 同一 assistant batch 内每个 ask-class call 仍单独生成、绑定、计量，报告不能跨 call 缓存或复用；
- 新增真实 provider smoke，并新增“双写同一 assistant batch 分别报告、分别审查、分别执行”的集成测试。

因此，下表中关于报告器 `tools: []`、`no-tools`、文本 JSON response 或“任何 tool call 都拒绝”的描述只
记录 2026-08-08 当时实现，均由本节覆盖；reviewer 本身仍保持无工具 JSON 判决请求。

下表逐项列出本次新增或修改的接口、类型、属性、函数、测试函数和文档位置。行号均指当前工作树。

## 逐项总表

| # | 层级 | 文件 | 接口、类型或函数 | 操作 | 具体修改 |
|---:|---|---|---|---|---|
| 1 | 公开协议 | `Packages/IntatisProtocol/Sources/PermissionReview.swift:47` | `PermissionAuthorizationReport` | 新增 | 新增 `public Codable/Equatable/Sendable` 语义报告；字段为 `authorizationGoal`、`currentProgress`、`latestInstructionInterpretation`、`currentActionJustification`、`scopeAssessment`，并新增对应 public initializer。五项均来自 requesting agent 的同模型报告，只是未信任解释。 |
| 2 | 公开协议 | `Packages/IntatisProtocol/Sources/PermissionReview.swift:70` | `PermissionAuthorizationContext` | 新增 | 新增 `public Codable/Equatable/Sendable` wrapper；只包含 `report` 与宿主验证后的 `supportingUserEventSequences`，并新增对应 public initializer。没有新增 model-supplied author、latest-user 原文或 binding digest。 |
| 3 | 公开协议 | `Packages/IntatisProtocol/Sources/PermissionReview.swift:84` | `PermissionReviewCausalContext.authorizationContext` 与 initializer | 修改 | 增加 optional `PermissionAuthorizationContext?` 字段和默认值为 `nil` 的 initializer 参数；旧 JSONL/旧 payload 缺字段时继续解码。 |
| 4 | 公开协议 | `Packages/IntatisProtocol/Sources/ToolAuthorization.swift:779` | `PermissionApprovalFailureKind.authorizationContextUnavailable` | 新增 | 增加 wire value `authorization_context_unavailable`，用于报告生成、绑定或验证不能证明安全时的 typed durable deny。 |
| 5 | AgentKernel 内部模型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:7` | `PermissionAuthorizationVisibleUserMessage` 与 initializer | 新增 | 冻结 requesting agent 实际可见用户消息的 `SubmissionID`、可选预期原文和截断标志，供 EventLog 反向核验。 |
| 6 | AgentKernel 内部模型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:21` | `PermissionAuthorizationReportingTurn` | 新增 | 冻结原 provider messages、当前 assistant text/tool-call batch、可见用户消息和 current submission，作为一次 exact tool call 的报告输入。 |
| 7 | AgentKernel 内部模型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:29` | `PermissionAuthorizationReporterResult` | 新增 | 返回 optional host-bound context 与本次报告请求的 usage；失败时 context 为 `nil`，不伪造上下文。 |
| 8 | AgentKernel 计量 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:37` | `PermissionAuthorizationUsageLedger.record(_:)` | 新增 | 并发安全累加每个独立 tool-call 报告请求的 token usage。 |
| 9 | AgentKernel 计量 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:41` | `PermissionAuthorizationUsageLedger.drain()` | 新增 | 在 turn 成功、失败、取消或 iteration exhaustion 时一次性取出并清空累计报告 usage。 |
| 10 | 报告器内部类型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:51` | `EvidenceCandidate` | 新增 | 保存临时 handle、canonical EventLog envelope、canonical `UserMessagePayload` 和秘密清洗后的 excerpt。 |
| 11 | 报告器内部类型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:58` | `ParsedOutput` | 新增 | 保存严格 JSON 解码后的五字段报告和模型选择的临时 handles。 |
| 12 | 报告器内部类型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:63` | `ProviderSnapshot` | 新增 | 有界累积文本、tool-call 标志、usage、completion marker、finish reason 和字符超限状态。 |
| 13 | 报告器内部类型 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:72` | `ProviderOutcome` | 新增 | 显式区分 `output`、`failed`、`timedOut`、`cancelled`，四种状态都携带当前 snapshot。 |
| 14 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:79` | `ProviderAccumulator` | 新增 | 使用 `NSLock` 管理单次 request-owned provider stream 的有界状态。 |
| 15 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:83` | `ProviderAccumulator.appendText(_:limit:)` | 新增 | 在 12,000 字符默认上限内累积 delta，超限立即标记失败。 |
| 16 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:94` | `ProviderAccumulator.noteToolCall()` | 新增 | 记录模型试图发 tool call；报告请求必须 `tools: []` 且任何 tool-call output 均 fail closed。 |
| 17 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:100` | `ProviderAccumulator.noteUsage(_:)` | 新增 | 合并 provider usage chunk。 |
| 18 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:106` | `ProviderAccumulator.noteCompletion(_:)` | 新增 | 记录显式 completion marker 和 finish reason。 |
| 19 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:113` | `ProviderAccumulator.value()` | 新增 | 锁内读取不可变 snapshot。 |
| 20 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:120` | `ProviderRace` | 新增 | 管理 provider、timeout、caller cancellation 三方 first-terminal race。 |
| 21 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:127` | `ProviderRace.setTasks(provider:timeout:)` | 新增 | 注册 request-owned provider/timeout task；若终态已产生则立即取消迟到 task。 |
| 22 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:140` | `ProviderRace.wait()` | 新增 | 等待首个终态，支持先终态后 waiter 和先 waiter 后终态。 |
| 23 | 报告器并发 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:153` | `ProviderRace.resolve(_:)` | 新增 | first-terminal-wins，取消另一侧 task 并仅恢复一次 continuation。 |
| 24 | 报告器入口 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:187` | `PermissionAuthorizationContextReporter.init(...)` | 新增 | 注入 exact EventLog/provider/model/reasoning/token meter，并设置有界 timeout、输出、可见消息、证据闭包与 catalog 上限。 |
| 25 | 报告器入口 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:209` | `report(turn:authorization:)` | 新增 | 完整报告流程：canonical evidence 建目、原 provider snapshot 后追加 developer prompt、同 model 且 `tools: []` 请求、预算 reserve/settle、严格终态检查、JSON 解析和 host binding。任何失败只返回 `context=nil`。 |
| 26 | 报告器 provider | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:296` | `runProvider(_:)` | 新增 | 执行 request-owned stream、45 秒默认 timeout、caller cancellation propagation、completion/tool-call/字符边界和 late-result fencing。 |
| 27 | 报告器证据 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:349` | `evidenceCandidates(for:)` | 新增 | 用 `replayForProjectionChecked()` + `hasCompleteKnownHistory` 将可见 `SubmissionID` 精确映射到唯一 canonical `user_message`；拒绝截断、重复、歧义、原文不符、跨 current boundary 或超预算。 |
| 28 | 报告器 prompt | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:412` | `reportingPrompt(turn:authorization:evidence:)` | 新增 | 生成 no-tools 严格 JSON prompt；明确区分 untrusted conversation/action batch、trusted host-resolved action 和 temporary user handles，禁止模型生成 author、seq、authorization ID 或 permission decision。 |
| 29 | 报告器解析 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:472` | `parse(_:)` | 新增 | 只接受 exact 顶层 keys、exact 五个 report keys、非空去重 handle 数组与全部合法字段。 |
| 30 | 报告器解析 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:514` | `normalizedReportField(_:)` | 新增 | 要求 string、trim 后非空、最多 1,200 字符且不含 `PermissionReviewTextSanitizer` 识别的敏感材料。 |
| 31 | 报告器绑定 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:524` | `bind(parsed:evidence:currentSubmissionID:maxClosureCount:)` | 新增 | 把 handles 映射为 canonical seq；无条件加入 current，并从最早引用到 current 闭包包含全部可见用户轮次，最多 36 项。 |
| 32 | 报告器终态 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:553` | `successfulFinishReason(_:)` | 新增 | 只接受 nil/`stop`/`end_turn`/`completed`/`complete`；仍要求已看到 completion marker。 |
| 33 | 报告器清洗 | `Packages/IntatisAgentKernel/Sources/PermissionAuthorizationContextReporter.swift:563` | `quote(_:limit:)` | 新增 | 使用现有 permission sanitizer 限长并转义换行、反斜杠和 prompt block delimiter。 |
| 34 | AgentLoop 主循环 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:520` | `AgentLoop.send(...)` | 修改 | 新建 turn-local usage ledger；冻结原 provider request 与当前 assistant batch；把 reporting turn 传入工具链；在所有成功/失败/取消出口把报告 usage 并入 `turn_stats`，但不把报告请求或原始输出写入 model history/UI。 |
| 35 | AgentLoop 工具批次 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:1568` | `runToolCalls(...)` | 修改 | 签名新增 `authorizationReportingTurn` 与 `permissionAuthorizationUsage`，顺序或并行 collaboration path 均逐 call 透传。 |
| 36 | AgentLoop 单工具 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:1686` | `runTool(...)` | 修改 | 签名新增上述两个参数，并在 exact authorization 已解析后传给 permission settlement；不改变 schema、gate、lease、prepare 或 executor 顺序。 |
| 37 | AgentLoop 权限结算 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:3047` | `settle(...)` | 修改 | 仅当 outcome 为 `.askUser`、runtime 为 Cowork、responder mode 为 `.automaticReviewer` 时调用同 acting provider/model reporter；随后检查 caller cancellation，再把 optional context 附加到原 permission request。manual、deterministic allow/deny 和 hard deny 不调用 reporter。 |
| 38 | AgentLoop 可见用户投影 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift:3304` | `permissionAuthorizationVisibleUserMessages(...)` | 新增 | `coworkMainThread` 使用 stable projection 的 real-user submissions；`taskScoped` worker 只获得当前 root submission；普通 conversation 只获得当前 submission，防止 worker 读取 main 私有历史。 |
| 39 | Review 控制面内部模型 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:147` | `ValidatedAuthorizationEvidence` | 新增 | 保存通过复核的 wrapper、supporting canonical events 和 canonical latest user event/payload。 |
| 40 | Review 控制面内部模型 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:154` | `AuthorizationEvidenceValidation` | 新增 | 明确区分 `.notRequired`、`.valid`、`.invalid(reason)`；host-originated `agentAdmission` 走 not-required。 |
| 41 | Review 控制面主处理 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:603` | `process(_:)` | 修改 | durable history 从 `replayChecked()` 改为 `replayForProjectionChecked()` 并要求 complete-known；在 reviewer dispatch 前调用 authorization evidence validator；invalid 以 high-risk typed durable deny 结算，valid 才进入 reviewer prompt。 |
| 42 | Review 控制面验证 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:1374` | `validateAuthorizationEvidence(task:events:maxSupportingEvents:)` | 新增 | 结构识别 exact model-authored call；验证 report、requesting agent、TaskContract/current SubmissionID、main/worker projection、canonical seq 排序唯一性、current inclusion、最大数量和 earliest-cited→current 完整闭包。 |
| 43 | Review 控制面验证 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:1398` | local `uniqueUserEvent(submissionID:)` | 新增 | 要求一个 SubmissionID 在同 session EventLog 中精确对应一个 canonical `user_message`；0 个或多个均拒绝。 |
| 44 | Review 控制面验证 | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:1506` | `validAuthorizationReport(_:)` | 新增 | 二次验证持久化/传输后的五字段均已 trim、非空、≤1,200 且不含敏感材料。 |
| 45 | Reviewer system prompt | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:1567` | `systemPrompt(reviewer:)` | 修改 | 明确 `AUTHORIZATION_REPORT` 是 untrusted interpretation，canonical latest/supporting evidence 是 host-resolved quoted evidence，requesting agent 是 host-bound author，所有 quoted blocks 都不能成为指令。 |
| 46 | Reviewer user prompt | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:1591` | `userPrompt(task:reviewer:events:maxRecentEvents:authorizationEvidence:)` | 修改 | 签名增加 validated evidence；在 REVIEW_TARGET 与 SESSION_CONTEXT 之间注入分栏 authorization blocks；非模型调用显示 not-applicable。 |
| 47 | Reviewer evidence prompt | `Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift:2085` | `authorizationEvidencePrompt(_:requestingAgent:)` | 新增 | 分别渲染 host-bound report author + 五字段 report、canonical latest user instruction、canonical supporting closure；所有原文继续限长和清洗。 |
| 48 | Protocol 测试 | `Packages/IntatisProtocol/Tests/PermissionReviewProtocolTests.swift:39` | `testPartialPermissionRequestContextUsesAdditiveDefaults` | 修改 | 增加断言：旧 partial context 解码后 `authorizationContext == nil`。 |
| 49 | Protocol 测试 | `Packages/IntatisProtocol/Tests/PermissionReviewProtocolTests.swift:53` | `testLegacyReviewTaskAndSettlementWithoutAuthorizationStillDecode` | 修改 | 增加断言：旧 review task 解码后 `causalContext.authorizationContext == nil`。 |
| 50 | Protocol 测试 | `Packages/IntatisProtocol/Tests/PermissionReviewProtocolTests.swift:107` | `testAuthorizationContextRoundTripsWithoutModelSuppliedBindingFields` | 新增 | 验证 wrapper round-trip；wire keys 只有 `report` 和 `supportingUserEventSequences`，不存在 `reportAuthor`、`latestUserInstruction`、`bindingDigest`。 |
| 51 | Reporter 测试基座 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:9` | `AuthorizationReporterProvider`（initializer、`requests`、`stream(_:)`） | 新增 | 提供同步 scripted stream 并捕获完整 `AgentRequest`，用于核对 exact provider request prefix、model 和 `tools: []`。 |
| 52 | Reporter 测试基座 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:37` | `AuthorizationReporterHangingProvider`（`requestCount`、`terminatedRequests`、`stream(_:)`） | 新增 | 提供不会自行结束的 stream，记录 termination，用于 timeout/caller cancel 清理验证。 |
| 53 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:63` | `testContinueReportMapsHandlesToCanonicalClosedEvidenceWithoutHistoryPollution` | 新增 | 复现省略指令 `Continue.`；验证引用前文后 canonical closure 包含原始指令和 current，request 使用同 model、原消息 prefix、`tools: []`，且 EventLog 不新增报告历史。 |
| 54 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:140` | `testUnknownEvidenceHandleFailsClosed` | 新增 | 模型返回 `U999` 时 context 为 nil。 |
| 55 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:179` | `testSecretBearingReportFailsClosed` | 新增 | 五字段中出现 secret-like credential 时 context 为 nil。 |
| 56 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:220` | `testTaskScopedWorkerEvidenceDoesNotExposeMainPrivateTurn` | 新增 | worker prompt/seq 只含其 current submission，不出现 main private marker。 |
| 57 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:270` | `testTimeoutFailsClosedAndTerminatesTheRequestOwnedStream` | 新增 | timeout 后 context 为 nil、及时返回，并触发当前 provider stream termination。 |
| 58 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:314` | `testResponseWithoutCompletionMarkerFailsClosed` | 新增 | 仅有文本、没有 `.done` 时不接受报告。 |
| 59 | Reporter 测试 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:353` | `testCallerCancellationFailsClosedAndTerminatesCurrentStream` | 新增 | caller cancel 后 context 为 nil，且只终止当前 request-owned stream。 |
| 60 | Reporter 测试辅助 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:403` | `makeFixture(_:)` | 新增 | 创建独立临时 session/EventLog fixture。 |
| 61 | Reporter 测试辅助 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:421` | `authorization(sessionID:toolCallID:)` | 新增 | 构造包含 exact invocation、digest、intent、side effect 和 ask gate 的 `ResolvedToolAuthorization`。 |
| 62 | Reporter 测试辅助 | `Packages/IntatisAgentKernel/Tests/PermissionAuthorizationContextReporterTests.swift:468` | `reportJSON(handles:justification:)` | 新增 | 生成 strict 五字段 report fixture。 |
| 63 | Automatic Review 测试辅助 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:262` | `autoReviewUserMessage(_:id:)` | 新增 | 所有 model-authored automatic-review 测试使用 production-like stable `SubmissionID`。 |
| 64 | Automatic Review 测试辅助 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:271` | `autoReviewAuthorizationReport(handles:justification:)` | 新增 | 为 acting main provider 插入独立 no-tools report response。 |
| 65 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:1607` | `testSpawnToolUsesOneAutomaticReviewAndCommitsCoordinatorAdmissionAtomically` | 修改 | 增加 stable submission 和 spawn call 的独立报告；仍验证一个外层 permission decision 和原子 admission。 |
| 66 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:1708` | `testReviewerApprovesWorkspaceWriteWithoutTerminalApproval` | 修改 | 增加 stable submission/report response；继续验证 reviewer allow 后 workspace write、无人工终端 approval。 |
| 67 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:1816` | `testMalformedAuthorizationReportDurablyDeniesBeforeReviewerProvider` | 新增 | malformed report 导致 requested context 为 nil、reviewer provider 0 调用、typed durable deny、文件不存在。 |
| 68 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:1896` | `testTimedOutReviewDeniesOnlyItsToolAndFreshGenerationCanExecuteNextTool` | 修改 | 两个 submission/tool call 各自生成报告；第一 reviewer generation timeout 不影响第二个 fresh report/reviewer generation。 |
| 69 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:2026` | `testCancellingActiveTasksKeepsAutomaticReviewerAvailableForNextRequest` | 修改 | 下一次请求增加 production-like submission/report，验证 task cancel 不关闭常驻 reviewer。 |
| 70 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:2085` | `testReviewerAskUserIsNormalizedToAutomaticDenyWithoutFallback` | 修改 | 增加 submission/report，继续证明 automatic reviewer 的 `ask_user` 不进入 GUI fallback。 |
| 71 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:2138` | `testReviewerDenyReasonIsPreservedAndDeniedWriteCannotCompleteInvocation` | 修改 | 增加 submission/report；调整最终 observation 检查到报告调用之后的真实 final request。 |
| 72 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:2231` | `testSuccessfulEquivalentEditClearsEarlierDeniedWriteEvidence` | 修改 | 两个等价 edit call 分别生成不同 justification；断言两次 no-tools 报告分别绑定不同 toolCallID，不能跨 call 复用。 |
| 73 | Automatic Review 测试 | `Packages/IntatisCowork/Tests/AutomaticPermissionReviewTests.swift:2334` | `testHardDenyNeverReachesAutomaticReviewer` | 修改 | 只增加 stable submission；没有报告响应，证明 deterministic hard deny 在 reporter/reviewer 前终局。 |
| 74 | Control Plane 测试基座 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:87` | `ReviewScriptedProvider.requests` 与 `stream(_:)` | 修改 | 捕获 main provider 的每次 request，以验证第二次请求是同 model、原 request prefix、`tools: []` 的报告调用。 |
| 75 | Control Plane 测试 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:521` | `testExactModelCallWithoutAuthorizationContextDurablyDeniesBeforeReviewerDispatch` | 新增 | exact turn/toolCall + root submission 缺 wrapper 时，在 reviewer provider 前 typed durable deny。 |
| 76 | Control Plane 测试 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:574` | `testValidatedAuthorizationReportIsSeparatedFromCanonicalUserEvidenceInPrompt` | 新增 | 合法 context 可 allow；prompt 中 report、canonical latest instruction、supporting evidence 三块分离，author 显示 host-bound `@main`。 |
| 77 | Control Plane 测试 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:631` | `testAuthorizationEvidenceClosureRejectsOmittedInterveningRevocation` | 新增 | 证据若引用早期授权和 current、却跳过中间“Stop”撤销，provider 0 调用并 typed deny。 |
| 78 | Control Plane 测试 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:707` | `testUnknownFutureEventDisablesAutomaticReviewBeforeProviderDispatch` | 新增 | EventLog 含 unknown future type 时 complete-known proof 失败，automatic review 在 provider 前 reconciliation deny。 |
| 79 | Control Plane 集成测试 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:970` | `testReviewerControlPlaneDoesNotConsumeOnlyDataPlaneSchedulerSlot` | 修改 | 测试脚本增加 report request 和 stable submission；断言 main 共三次请求、第二次为 same-model/no-tools/exact-prefix，同时 reviewer 仍不占唯一数据面 scheduler slot。 |
| 80 | Control Plane 测试辅助 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:2119` | `authorizationContext(sequences:)` | 新增 | 构造 host-bound context fixture。 |
| 81 | Control Plane 测试辅助 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:2132` | `authorizationReportJSON(handles:)` | 新增 | 构造 acting-provider strict JSON report fixture。 |
| 82 | Control Plane 测试辅助 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:2149` | `rootContract(id:submissionID:objective:)` | 新增 | 构造带 canonical current submission 的 root `TaskContract`。 |
| 83 | Control Plane 测试辅助 | `Packages/IntatisCowork/Tests/PermissionReviewControlPlaneTests.swift:2165` | `appendPriorRootTurn(log:taskID:submissionID:text:)` | 新增 | 写入 canonical user/task/model-history prior turn，用于真实 main projection 与撤销闭包测试。 |
| 84 | 取消生命周期测试基座 | `Packages/IntatisCowork/Tests/OrchestrationReliabilityTests.swift:202` | `ReliabilityWriteThenFinalProvider.stream(_:)` | 修改 | 第二次 main-provider 请求改为合法 authorization report；第三次才是原 final response，从而能观察 cancel 是否错误释放后续推理。 |
| 85 | 取消生命周期测试 | `Packages/IntatisCowork/Tests/OrchestrationReliabilityTests.swift:2594` | `testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer` | 修改 | 增加 stable submission；等待 reviewer 已启动后 cancel；预期 main 只有原 inference + report 两次请求，不得出现第三次 final inference 或文件写入。 |
| 86 | 架构文档 | `docs/ARCHITECTURE.md:24`、`:1043` | `2026-08-08 Cowork 自动权限审查授权上下文` 与 reviewer 架构条目 | 修改 | 写明完整数据流、三类 provenance、临时 handle/canonical closure、无 history/cache、typed deny、manual/hard-deny/admission 不变和旧日志兼容。 |
| 87 | 当前状态 | `docs/CURRENT_STATE.md:70` | Cowork automatic ask-class 当前实现条目 | 修改 | 把本次实现登记为当前真实状态，包括 same-provider report、EventLog mapping、control-plane revalidation 和 failure semantics。 |
| 88 | Cowork 原则 | `docs/COWORK_PRINCIPLES.md:295`、`:407` | Permission reviewer 原则与测试期望 | 修改 | 新增 same-model `tools: []`、report untrusted、canonical evidence 分栏、完整闭包、多 call 独立报告和 fail-closed 原则。 |
| 89 | 禁区文档 | `docs/DO_NOT_BREAK.md:588`、`:597-600` | EventLog/reporter/authorization context 禁区 | 修改 | 要求 complete-known replay；禁止模型生成 author/seq/binding/decision；禁止 fallback、跨 call cache、worker 越界和对 manual/hard deny/admission 改语义。 |
| 90 | 项目地图 | `docs/PROJECT_MAP.md:199`、`:211`、`:217` | Cowork 链路、权限门、Phase B reviewer isolation | 修改 | 登记新协议类型、报告器文件、控制面验证职责、typed failure 和对应测试位置。 |
| 91 | 测试文档 | `docs/TESTING.md:60`、`:347` | focused suite 命令、覆盖矩阵和 2026-08-08 实测结果 | 修改 | 增加四组 mandatory focused tests、正反例要求，以及实际 11/11、7/7、40/40、31/31、Cowork 346/346、全仓 1727/0 的验证记录。 |

## 文件级汇总

| 文件类别 | 文件数 | 文件 |
|---|---:|---|
| 生产源码 | 5 | `AgentLoop.swift`、`PermissionAuthorizationContextReporter.swift`、`PermissionReviewControlPlane.swift`、`PermissionReview.swift`、`ToolAuthorization.swift` |
| 测试源码 | 5 | `PermissionAuthorizationContextReporterTests.swift`、`AutomaticPermissionReviewTests.swift`、`PermissionReviewControlPlaneTests.swift`、`OrchestrationReliabilityTests.swift`、`PermissionReviewProtocolTests.swift` |
| 项目文档 | 6 | `ARCHITECTURE.md`、`CURRENT_STATE.md`、`COWORK_PRINCIPLES.md`、`DO_NOT_BREAK.md`、`PROJECT_MAP.md`、`TESTING.md` |
| 本清单 | 1 | `codex-report/08_08_26-16_13-cowork-permission-authorization-context-change-inventory.md` |

## 明确没有修改的接口与边界

- 没有修改 `Orchestrator.send` 的签名；测试只开始传入生产路径本就支持的 `UserMessagePayload.submissionID`。
- 没有修改 `PermissionEngine`、`DeterministicPolicyGate` 或 `ModelPermissionReviewer` 的公开接口。
- 没有新增 reviewer tool、普通 AgentLoop、scheduler slot、MessageBus target 或 UI surface。
- 没有让模型提交 author、EventLog seq、latest-user 原文副本、authorization ID、binding digest、gate、lease 或 permission decision。
- 没有改变 manual permission、deterministic allow、hard deny、host `agentAdmission` 或 executor durable ticket 的既有语义。
- 没有修改 `Apps/`、`Package.swift`、`project.yml`、构建脚本、依赖或 NOTICE。

## 已执行验证

| 验证 | 结果 |
|---|---|
| `PermissionReviewProtocolTests` | 11 tests / 0 failures |
| `PermissionAuthorizationContextReporterTests` | 7 tests / 0 failures |
| `AutomaticPermissionReviewTests` | 31 tests / 0 failures |
| `PermissionReviewControlPlaneTests` | 40 tests / 0 failures |
| `testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer` | 1 test / 0 failures |
| 完整 `IntatisCoworkTests` | 346 tests / 0 failures |
| 宿主环境完整 `swift test --disable-sandbox` | 14 targets；1727 tests；19 conditional skips；0 failures |
| `swift build --disable-sandbox` | 通过 |
| `git diff --check` | 通过 |

受管 sandbox 内第一次完整 suite 因外层 Seatbelt 拒绝既有 browser/LaTeX/Git/process 子进程启动而失败；
同一 working tree 在允许真实子进程边界的宿主环境重跑后全部通过。本次未执行真实
provider/credential/network smoke，也未修改 App/UI，因而未另跑 Xcode App build。

### 2026-08-11 修正验证补记

| 验证 | 结果 |
|---|---|
| `PermissionAuthorizationContextReporterTests` | 7 tests / 0 failures |
| `PermissionReviewProtocolTests` | 11 tests / 0 failures |
| `PermissionReviewControlPlaneTests` | 40 tests / 0 failures |
| `AutomaticPermissionReviewTests` | 32 tests / 0 failures（含同一 batch 两个 ask-class call 独立报告） |
| `testRealAgentOutputFunctionShapeWhenEnabled` | 真实 OpenRouter exact Agent route；1 test / 0 failures |
| `IntatisMac` Debug build（`CODE_SIGNING_ALLOWED=NO`） | 通过；仅既有 warnings |

本次真实 smoke 已获用户明确网络与计费授权；只发送合成诊断内容，不把知识库资料作为报告器测试输入。
上文“未执行真实 provider smoke”仅描述 2026-08-08 当轮，不再代表 2026-08-11 的修正验证状态。
