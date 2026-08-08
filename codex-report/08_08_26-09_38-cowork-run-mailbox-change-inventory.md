# Cowork current-run 终态控制与 Mailbox correlation 修复变更清单

## MODEL_CHECK_RESULT

当前执行身份为 Codex / GPT-5 系列；运行时未暴露更细模型版本，记为 `UNKNOWN`。

## PATH_CHECK_RESULT

- `pwd`：`/Users/vita/Vitemis/Intatis`
- `git rev-parse --show-toplevel`：`/Users/vita/Vitemis/Intatis`
- 两者一致，且与预期 Intatis Git root 匹配。
- 本清单依据 2026-08-08 09:38（Asia/Singapore）的未提交工作树生成。

## INVENTORY_SCOPE

- 修复依据：外部事故报告只作为只读输入；没有修改 Councils/Councis 仓库。
- 实现改动共涉及 43 个文件：38 个已跟踪文件修改、5 个新增文件。
- 已跟踪 diff 为 1,545 行新增、170 行删除；5 个新增文件合计 1,379 行，因此报告生成前的完整实现变更为 2,924 行新增、170 行删除。
- 本报告本身是第 44 个工作树文件，不计入上述实现数字。
- 未执行 `git add`、`git commit`、`git push` 或创建 PR。

## CONCRETE_INTERFACE_CHANGES

| 接口层 | 具体接口 | 新合同 |
| --- | --- | --- |
| 模型工具 | `finish_run({reason})` | 仅 exact `@main`、`issuer == nil`、带 current `ContinuationRunID` 的 root invocation 可见；`reason` 为 1–1000 字符，`additionalProperties=false`；模型不能提交任何 identity。 |
| 模型工具 | `stop_run({reason})` | 与 `finish_run` 同一可见性和 schema，只表达 stopped 意图；真实 Session/Run/Goal/Submission/root Task/source 均由宿主注入。 |
| 模型工具 | `request_information({to, question, based_on?})` | `based_on` 是 explicit mailbox follow-up 使用的上一条 reply MessageID；宿主要求它属于当前 frozen mailbox receipt、原 sender、同一 run scope。新请求使用 fresh RequestID，并沿用 conversation root。 |
| 模型工具 | `reply_message({to, content, inReplyTo})` | `inReplyTo` 从 optional 改为 required；只能回答当前 mailbox invocation 冻结的 exact information RequestID；同一 RequestID 只接受一个 terminal reply，exact duplicate 幂等，冲突拒绝。 |
| Swift protocol | `RunController.requestClose(outcome:reason:)` | 新增 host-bound run 控制 seam；工具无法传 SessionID/RunID/TaskID。 |
| Swift protocol | `AgentMessenger.requestInformation(to:question:basedOn:)` | 增加 optional `basedOn` correlation。 |
| Swift protocol | `AgentMessenger.replyMessage(to:content:inReplyTo:)` | `inReplyTo` 改为 non-optional `String`。 |
| Tool context | `ToolContext.runController`、`AgentLoop.init(...runController:)`、`AgentRuntime.makeLoop(...runController:)` | 把 invocation-bound run controller 从 Orchestrator 注入真实工具 executor。 |
| Wire event | `continuation_run_close_requested` | 新的 additive Event/Envelope type；payload 是 `ContinuationRunCloseRequestedPayload`，不替代 completed/cancelled/checkpointed 事件。 |
| Wire payload | `ContinuationRunCloseRequestedPayload` | 字段：`sessionID`、`runID`、optional `goalID/submissionID/rootTaskID`、`requestedOutcome`、`source`、`reason`、`requestedAt`。 |
| Wire enum | `ContinuationRunCloseOutcome` | `completed`、`stopped`、`cancelled`、`timed_out`、`failed`、`interrupted`。模型只能请求前两种，其余由 host/runtime 使用。 |
| Wire enum | `ContinuationRunCloseSource` | `main_agent`、`user`、`runtime`、`host_lifecycle`。 |
| Mailbox payload | `InformationRequestedPayload` | additive optional `conversationID` 与 `basedOn`；旧 JSON 缺字段仍解码为 nil。 |
| Mailbox payload | `InformationRepliedPayload` | additive optional `conversationID`；既有 optional `inReplyTo` 保留 wire compatibility，live tool path 强制非空。 |
| Mailbox runtime | `PendingAgentMessage` | 增加 optional `conversationID`、`basedOn`，供 durable replay、wake 和 authority classification 使用。 |
| Lease | `ToolCapability.controlRun` | main-only control capability；从 worker、child coordinator、mailbox task、reviewer 和 spawn 派生面移除。 |
| Permission | `PermissionControlEffect.closeRun` | run close intent 的 typed control effect；`DeterministicPolicyGate` 把 exact close intent归类为 low-risk pass，后续仍经过 registry、lease、PermissionEngine 和 durable tool ticket。 |
| Replay | `ToolExecutionReplayPolicy.nonReplayableTools` | 加入 `finish_run`、`stop_run`，防止恢复时重放控制面终止操作。 |
| EventLog CAS | `EventLog.claimContinuationRunClose` | 在 complete-known history 与跨进程独占锁内执行 per-RunID first-write；exact duplicate 返回 canonical winner，冲突 durable history fail closed。 |
| Projection | `CoworkProjection.continuationRunCloseClaims` | 保存每个 RunID 的首个 durable claim。 |
| Projection | `CoworkProjection.ambiguousContinuationRunCloseClaimIDs` | 标记同一 RunID 的非同值多 claim；runtime restore/admission 必须 fail closed。 |

## SOURCE_FILE_AND_FUNCTION_INVENTORY

下面逐一覆盖所有 23 个生产源码、prompt/Skill 文件。`状态` 中“新增”表示此前未被 Git 跟踪。

| ID | 状态 | 文件 | 改动的类型、函数或接口 | 具体改动 |
| --- | --- | --- | --- | --- |
| S01 | 修改 | `Packages/IntatisAgentKernel/Sources/AgentLoop.swift` | `AgentLoop.runController`；`AgentLoop.init(...)`；`AgentLoop.runTool(...)` | 保存并向 `ToolContext` 传递 `RunController`，使真实 tool executor 能调用宿主绑定的当前 run 控制面。 |
| S02 | 修改 | `Packages/IntatisAgentKernel/Sources/AgentRuntime.swift` | `AgentRuntime.makeLoop(...)` | 新增 `runController` 参数并透传给 `AgentLoop`；Code host 默认仍为 nil，Cowork exact root 才注入。 |
| S03 | 修改 | `Packages/IntatisAgentKernel/Sources/ContextBuilder.swift` | `ContextBuilder.coworkSystemPrompt(...)` | coordinator prompt 增加 `finish_run`/`stop_run` 自主调用条件、成功后不再调用工具且只返回一次 final；coordinator/worker prompt 均改为 correlation-scoped reply、reply receipt no-ACK、实质追问使用 fresh `request_information(based_on:)`。 |
| S04 | 修改 | `Packages/IntatisConversation/Sources/CodeProjection.swift` | `CodeProjection.apply(_:)` | 对 `continuationRunCloseRequested` 做展示 no-op，避免控制面 claim 变成用户气泡。 |
| S05 | 修改 | `Packages/IntatisConversation/Sources/CoworkProjection.swift` | stored properties `continuationRunCloseClaims`、`ambiguousContinuationRunCloseClaimIDs`；`CoworkProjection.apply(_:)` | 首 claim 写入 projection；后续相同值保持幂等，非同值把 RunID 标为 ambiguous。 |
| S06 | 修改 | `Packages/IntatisConversation/Sources/EventLog.swift` | `EventLogError.conflictingContinuationRunCloseClaim`；`errorDescription`；`recoverySuggestion`；新 `ContinuationRunCloseClaimResult.init(...)`；新 `EventLog.claimContinuationRunClose(_:ts:)` | 实现跨进程 first-write close CAS、完整历史/unknown event/seq 校验、exact duplicate/first winner 语义和冲突历史 fail-closed 错误。 |
| S07 | 修改 | `Packages/IntatisConversation/Sources/Projection.swift` | `ConversationProjection.apply(_:)` | 对 `continuationRunCloseRequested` 做普通 Chat projection no-op。 |
| S08 | 修改 | `Packages/IntatisCowork/Sources/AgentScheduler.swift` | `PendingAgentMessage.conversationID`、`basedOn`；`PendingAgentMessage.init(...)` | mailbox runtime 保存多轮 conversation correlation，并维持 optional Codable 兼容。 |
| S09 | 修改 | `Packages/IntatisCowork/Sources/CommunicationDelegationTools.swift` | `RequestInformationTool.descriptor/Args/permissionIntent/execute`；`ReplyMessageTool.descriptor/Args/permissionIntent/execute` | `request_information` 新增 `based_on` schema/metadata/dispatch；`reply_message.inReplyTo` 变为 required，descriptor 明确它只终结一个 request、不是 ACK 工具。 |
| S10 | 修改 | `Packages/IntatisCowork/Sources/GoalRuntimeController.swift` | `StopRequest`；两个 initializer；`start()`；`abortStartupAttempt()`；`shutdown()`；`sendUserTurn(...)`；`handle(_:)`；`stopAutomaticContinuation(...)`；`discoverPendingStop(...)`；`retryPendingStop(...)`；`settleStoppedRun(...)` | cancellation callbacks 新增 `ContinuationRunCloseSource`；startup recovery/runtime transition 用 `.runtime`，shutdown 用 `.hostLifecycle`，UI/default stop 用 `.user`；ordinary turn 等 scheduler idle 后检查 durable close claim，non-completed claim 使 run 进入 cancelled 而非伪 completed；pending stop 保留/升级 source。 |
| S11 | 修改 | `Packages/IntatisCowork/Sources/MessageBus.swift` | `requestInformation(from:to:question:taskID:requestID:conversationID:basedOn:)`；`replyMessage(from:to:content:inReplyTo:conversationID:taskID:replyID:)` | request 默认以自身 RequestID 建立 conversation root，并保存 `basedOn`；reply 强制 exact `inReplyTo` 并继承 `conversationID`。Mediator-first 与 durable-first 路径不变。 |
| S12 | 修改 | `Packages/IntatisCowork/Sources/Orchestrator.swift` | stored state、restore、run close/cancel、communication、mailbox lease、tool registry、terminal settlement 等函数；完整函数级清单见下一节 | 实现 exact-run durable fence、源保真、恢复 drain、模型工具可见性与授权复核；把 mailbox 拆为 ordinary/information-request/information-reply/delegation 四种 authority；执行精确 correlation 验证及 legacy lease 迁移。 |
| S13 | 新增 | `Packages/IntatisCowork/Sources/RunControlTools.swift` | `RunCloseArguments`；`runCloseIntent`；`executeRunClose`；`FinishRunTool`；`StopRunTool`；各自 `descriptor`、`permissionIntent`、`execute` | 定义两个 model-facing strict JSON-schema 工具；只接收 reason；构造 `.closeRun` intent；通过 `ToolContext.runController` 执行宿主终止。 |
| S14 | 修改 | `Packages/IntatisPermission/Sources/DeterministicPolicyGate.swift` | `DeterministicPolicyGate.evaluate(_:_:)` | 把含 `.closeRun` 的 exact intent 识别为 low-risk pass；hard deny 与其余权限层仍可收窄。 |
| S15 | 修改 | `Packages/IntatisProtocol/Sources/CoworkEvents.swift` | `InformationRequestedPayload` fields/init；`InformationRepliedPayload` fields/init | 添加 `conversationID`、`basedOn`，reply 添加 `conversationID`；全部为 additive optional 字段，保留旧日志解码。 |
| S16 | 修改 | `Packages/IntatisProtocol/Sources/Envelope.swift` | `Envelope.init(from:)`；`Envelope.encode(to:)` | 加入 `continuationRunCloseRequested` payload 的 encode/decode 分支。 |
| S17 | 修改 | `Packages/IntatisProtocol/Sources/Event.swift` | `Event.continuationRunCloseRequested`；`Event.EventType.continuationRunCloseRequested`；`Event.type` | 增加 Swift event case、稳定 wire tag `continuation_run_close_requested` 与 type 映射。 |
| S18 | 修改 | `Packages/IntatisProtocol/Sources/Leases.swift` | `ToolCapability.controlRun`；`CapabilityLease.worker(...)` | 增加 `control_run` capability；worker default 加入 `requestInformation` 作为可被宿主收窄到 reply-receipt follow-up 的 ceiling，但普通 worker的 communication grant 不因此扩大。 |
| S19 | 修改 | `Packages/IntatisProtocol/Sources/PermissionIntent.swift` | `PermissionControlEffect.closeRun` | 增加稳定 wire value `close_run`。 |
| S20 | 修改 | `Packages/IntatisProtocol/Sources/TaskGoalEvents.swift` | 新 `ContinuationRunCloseOutcome`；新 `ContinuationRunCloseSource`；新 `ContinuationRunCloseRequestedPayload` 及 initializer | 冻结 current-run close 的 typed wire vocabulary 与 host-bound identity/source 字段。 |
| S21 | 修改 | `Packages/IntatisProtocol/Sources/ToolExecution.swift` | `ToolExecutionReplayPolicy.nonReplayableTools` | 把 `finish_run`、`stop_run` 列为 non-replayable。 |
| S22 | 修改 | `Packages/IntatisTools/Sources/ToolProtocol.swift` | `AgentMessenger.requestInformation`；`AgentMessenger.replyMessage`；新 `RunController`；`ToolContext.runController` 与 initializer | 把 mailbox correlation 和 current-run host seam提升为共享 Tool protocol 层接口。 |
| S23 | 修改 | `Packages/IntatisSkills/Resources/BundledSkills/cowork-agent-orchestration/SKILL.md` | frontmatter description；`Drive the request proactively` 第 7 步；新 `Keep mailbox conversations live without acknowledgment loops` 章节 | 指导模型何时主动 finish/stop；明确一次 reply 只关闭 exact correlation，reply receipt 不 ACK，实质追问必须 fresh request + `based_on`，且不得为道谢制造新请求。 |

### `Orchestrator.swift` 函数级清单

| 分组 | 改动的函数/类型 | 具体行为 |
| --- | --- | --- |
| 状态与初始化 | stored properties `cancellationRunCloseSources`、`continuationRunCloseClaims`、`continuationRunCloseInstallations`；`Orchestrator.init(...)` | 分别保存取消来源、durable first claim 和 EventLog await 期间的 actor-local in-flight tombstone。 |
| 恢复 | 新 `validatedContinuationRunCloseClaims(from:)`；`restore(from:)` | restore 对 ambiguous history fail closed；每次 projection 重建后重载 claims；scheduler/mailbox 恢复前调用 exact-run drain；同时迁移 main control 和 mailbox follow-up legacy lease。 |
| 单任务取消 | `cancel(taskID:reason:)`；新 private `cancel(taskID:reason:runCloseSource:)`；`cancelBeforeExecution(...)` | 用户入口标记 `.user`；queued/claimed/running root 都先持久化 run close，再取消 provider/tool；持久化失败则 fail closed，不伪造 task terminal。 |
| 模型请求 close | 新 `requestContinuationRunClose(currentTaskID:outcome:reason:)` | 校验 exact `@main` root、current RunID、只允许 completed/stopped；由宿主构造 payload；安装 claim、drain 同 run 其余工作并返回 typed observation。 |
| claim 安装 | 新 `installContinuationRunCloseClaim(_:)` | EventLog await 前增加 in-flight tombstone；CAS 成功后缓存 canonical claim；durable claim 落盘后才等待旧 admission holder。 |
| root close | 新 `closeRootRunIfNeeded(for:outcome:source:reason:)`；新 `durableRunCloseReason(_:)` | host failure/cancel/timeout/shutdown 复用同一 first-write机制；reason 经 diagnostic sanitizer 限到 1,000 字符。 |
| exact-run drain | 新 `scheduledTaskIDs(continuationRunID:excludingTaskID:)`；新 `discardPendingMessages(continuationRunID:goalID:reason:)`；新 `drainClosedContinuationRun(_:excludingTaskID:resumeUnrelatedWork:)` | 只枚举同一 RunID；当前 root 可被排除以返回一次 final；取消 queued/claimed/running/graph-only task并 durable discard pending messages；不连带其他 run。 |
| session/scoped cancel | `cancelAll(reason:)`；`cancelActiveTasks(reason:runCloseSource:)`；`cancelActiveTasks(goalID:continuationRunID:reason:resumePendingTasksOnSuccess:runCloseSource:)`；private `cancelAll(...)` | session shutdown 使用 `.hostLifecycle`；数据面 stop默认 `.user`；Goal/run cancel 在旧 admission barrier 前尽早写 claim，root 尚不可见时等 admission 后补 claim。 |
| information request | `requestInformation(from:to:question:basedOn:taskID:)` | mailbox follow-up 必须把 `based_on` 指向当前 frozen reply；检查 exact sender/recipient、同 Goal/run/submission scope和 complete-known durable history；生成 fresh RequestID并返回 `request_id`。普通非-mailbox request 不接受 `based_on`。 |
| information reply | `replyMessage(from:to:content:inReplyTo:taskID:)` | `inReplyTo` 必填且必须是当前 frozen information request；验证 exact sender/recipient/scope；首 terminal 生效，exact duplicate返回 idempotent，冲突或 ambiguous durable reply拒绝；返回 `reply_id`。 |
| communication helpers | 新 `completeKnownCommunicationHistory()`；新 static `sameCommunicationScope(_:_:)`；新 `communicationScopeMatches(_:causalTaskID:)`；`communicationCancellationFailure(taskID:)` | correlation 只能在完整已知历史和相同 Goal/Run/Submission 范围内建立；legacy nil causal 仅在双方均 unscoped 时窄兼容；closed run返回确切 fence reason。 |
| mailbox classification | `mailboxDeliveryBatchKey(for:fallbackSender:)`；`MailboxDeliveryAuthorityClass` | authority 从旧二分改为 `.ordinaryMessage`、`.informationRequest`、`.informationReply`、`.delegationRequest`；不同 class 不混 batch。 |
| mailbox replay | `pendingMessageDetails(for:pendingIDs:events:)` | 从 request/reply event恢复 `conversationID`、`basedOn`、`inReplyTo`。 |
| mailbox task lease | `prepareMailboxDeliveryTask(issuer:assignee:messages:authorityClass:scopeContract:)` | ordinary=`communication .none`/无通信工具；request=`reply_message + .replyOnly`；reply receipt=`request_information + .selectedAgents([original sender])`；delegation=request-only depth 1；所有类别保持 read-only且无无关控制面能力。 |
| lease迁移与派生 | `deterministicDefaultCapabilityLeases(...)`；`upgradeMainControlCapabilitiesIfNeeded(...)`；新 `upgradeMailboxFollowupCapabilitiesIfNeeded(...)`；`prepareDelegatedTask(...)`；`prepareDefaultLeases(...)`；`prepareSpawnLeases(...)`；`mainScopedCapabilityLease(...)` | legacy main default补 `controlRun`；legacy worker default补 `requestInformation` ceiling并 durable replace；只有 main default保留 `controlRun`，worker/task/spawn/child 始终剥离。 |
| tool构建与执行 | `run(_:taskContract:...)`；`authorizationRevalidationFailure(...)`；`toolRegistry(for:agentID:includesTerminal:canControlRun:)` | 只有 exact root计算 `canControlRun=true`、注册两个工具并注入 `OrchestratorRunController`；已审批工具在 close claim或 in-flight installation期间仍被 executor 前 revalidation拦截。 |
| scheduler/terminal | `executeClaimedTask(_:)`；`finishFailedTask(...runCloseOutcome:)`；`finishCancelledTask(...)`；`cancelUnqueuedRootTask(...runCloseSource:)`；`isGoalRunCancellationRequested(...)`；`executionDidFinish(...)` | dispatch 前观察 tombstone/claim；timeout使用 `.timedOut`，普通失败 `.failed`，取消保留 caller source；run close落盘早于 provider/tool cleanup与 task terminal；结束后清理 source map。 |
| messenger adapter | `BusMessenger.requestInformation(...)`；`BusMessenger.replyMessage(...)` | 适配新的 `AgentMessenger` signature并透传 `basedOn`/required `inReplyTo`。 |
| run adapter | 新 `OrchestratorRunController`；`requestClose(outcome:reason:)` | invocation-bound `RunController` 实现，把当前 TaskID与模型 outcome/reason交给 Orchestrator；模型看不到绑定 identity。 |

## TEST_FILE_AND_FUNCTION_INVENTORY

下面覆盖全部 13 个测试文件；新增测试文件中的 helper/provider 也列出。

| ID | 状态 | 文件 | 改动/新增的测试函数或 helper | 覆盖内容 |
| --- | --- | --- | --- | --- |
| T01 | 修改 | `Packages/IntatisAgentKernel/Tests/ContextProjectionTests.swift` | `testCoordinatorPromptRequiresExactBundledOrchestrationSkill` | 断言 coordinator/worker prompt 含 finish/stop、host-bound run、correlation-scoped reply、no-ACK、fresh `based_on` follow-up。 |
| T02 | 新增 | `Packages/IntatisConversation/Tests/ContinuationRunCloseClaimTests.swift` | helpers `makeLogPair`、`claim`；`testConcurrentExactClaimAppendsOnce`；`testConflictingClaimObservesFirstWinnerWithoutAppending`；`testProjectionRetainsFirstClaimAndFlagsConflictingDurableHistory` | 两个 EventLog 实例并发 CAS只追加一次；冲突 caller观察首 winner；projection 标记人为冲突历史。 |
| T03 | 修改 | `Packages/IntatisCowork/Tests/GoalRuntimeControllerTests.swift` | `testPausedInterruptedRunIsCancelledAndRecoveredWithoutExecuting`；`testPausedInterruptedCancellationFailureKeepsStartupUnsafeAndDoesNotExecute`；`testGoalControlsFailClosedWhileStartupRecoveryIsInProgress`；`testShutdownDuringPauseCancellationDoesNotResumePendingInvocations`；`testStartCancelsInterruptedActiveRunWithoutWakingSchedulerBeforeRecovery`；`testCancelledStartAfterRecoveryPauseReturnsUnsafeWithoutLaunching`；`testPauseResumeReconcilesPriorCheckpointBeforeClearCheckpointsCurrentRun` | 更新 injected cancel closures的新 source参数，并保留原有恢复、barrier、shutdown、pause/resume fail-closed断言。 |
| T04 | 修改 | `Packages/IntatisCowork/Tests/IntatisCoworkTests.swift` | `testMainCanSpawnWorkerButSpawnedWorkerHasNoCoordinatorTools` | worker system prompt 断言改为 exact frozen request reply规则。 |
| T05 | 修改 | `Packages/IntatisCowork/Tests/MessageDelegationSplitTests.swift` | `testSendMessageCreatesDurableMailboxWakeTaskAndConsumesMessage`；`testRequestInformationCreatesDurableMailboxWakeTaskAndConsumesRequest`；重命名为 `testReplyMessageRejectsUnfrozenCorrelation`；新 `testReplyMessageSchemaRequiresExactCorrelationAndRejectsExtraFields`；`testDelegateTaskCreatesTaskContractAndTaskDelegatedEvent`；`testMessageBusEventsDistinguishMailboxCommunicationFromMediatedDelegation` | ordinary/delegation communication `.none`；request返回 RequestID；unfrozen/nil reply拒绝且不写 event；schema强制 required `inReplyTo`。 |
| T06 | 修改 | `Packages/IntatisCowork/Tests/OrchestrationReliabilityTests.swift` | `ReliabilityMailboxSideEffectThenFailProvider.frozenMessageID(in:)`、`stream(_:)`；`testMailboxAutomaticRetryStopsAfterSettledNonReplayableExecution`；`testScopedCancellationDurablyDiscardsMessageAdmittedByNonCooperativeSender` | non-replayable reply使用真实 frozen RequestID；并发取消证明 close claim seq早于 discarded message seq且每 RunID仅一个 claim。 |
| T07 | 修改 | `Packages/IntatisCowork/Tests/ToolRegistryLeaseTests.swift` | 新 `testRunControlRegistryRequiresExactMainRootInvocationAndCapability`；扩展 `testRestoreDurablyUpgradesLegacyMainDefaultRenameCapabilityOnce`；新 `testRestoreDurablyUpgradesLegacyWorkerForCorrelationSafeFollowupOnce` | exact main/root/capability工具可见性；reason-only schema；legacy main补 verdict/controlRun；legacy worker只补 follow-up ceiling且普通 registry仍不可发起信息请求。 |
| T08 | 新增 | `Packages/IntatisCowork/Tests/RunControlTests.swift` | helpers `RunControlScriptedProvider`、`RunControlDelayedStreamState`、`RunControlDelayedProvider`、`fixture`、`waitForRunningTask`；7 个 tests：`testFinishRunIsVisibleToExactMainRootAndClaimsBeforeTaskTerminal`、`testRootFinalResponseDoesNotForgeExplicitRunCloseClaim`、`testStopRunCreatesStoppedClaimForExactCurrentRun`、`testRootTimeoutInstallsRuntimeCloseFenceBeforeFailedTerminal`、`testRunningUserCancellationFencesRunBeforeCancelledTerminalAndPreservesSource`、`testSessionShutdownPreservesHostLifecycleCloseSource`、`testRestoreDrainsQueuedTaskBehindDurableCloseFenceWithoutProviderDispatch` | 工具可见性、claim顺序、ordinary final不伪 claim、completed/stopped、timeout/user/host source、恢复不dispatch closed run。 |
| T09 | 新增 | `Packages/IntatisCowork/Tests/MailboxCorrelationTests.swift` | providers `CorrelatedConversationProvider`、`DuplicateReplyScenarioProvider`、`AcknowledgementAttemptProvider`、`RunControlScriptedProviderForMailboxValidation` 及其 stream/response/toolCall helpers；4 个 tests：`testReplyReceiptHasNoReplyToolButCanOpenExplicitFollowUpCorrelation`、`testInformationRequestAcceptsOneTerminalReplyAndRejectsConflict`、`testReplyReceiptAcknowledgementAttemptCannotCreateAnotherMessageOrWake`、`testReplyValidationRejectsMissingForgedCrossAgentAndCrossRunCorrelation` | fresh RequestID + stable conversation root + `basedOn`；单 terminal/exact duplicate/conflict；receipt无 reply工具且 ACK尝试失败；missing/forged/cross-agent/cross-run correlation fail closed。 |
| T10 | 修改 | `Packages/IntatisPermission/Tests/IntatisPermissionTests.swift` | `testWorkTaskAndGoalControlEffectsAreNotWorkspaceWrites` | 增加 `run.close.completed`/`.closeRun` low-risk control intent覆盖。 |
| T11 | 修改 | `Packages/IntatisProtocol/Tests/TaskGoalProtocolTests.swift` | `testAllTaskGoalRunEventsRoundTripWithStableTypeTags` | 新 close payload以稳定 `continuation_run_close_requested` tag round-trip。 |
| T12 | 新增 | `Packages/IntatisProtocol/Tests/CommunicationCorrelationProtocolTests.swift` | `testLegacyInformationEventsDecodeWithoutCorrelationExtensions`；`testCorrelationFieldsRoundTrip` | 旧 request/reply JSON缺新字段仍解码；new conversationID/basedOn/inReplyTo完整 round-trip。 |
| T13 | 修改 | `Packages/IntatisSkills/Tests/IntatisSkillsTests.swift` | `testProductBundleDiscoversCoworkOrchestrationAsSystemSkill` | bundled Skill激活内容包含 finish_run、mailbox live conversation、fresh correlation和 no-ACK。 |

## DOCUMENTATION_FILE_INVENTORY

| ID | 文件 | 修改位置/接口 | 内容 |
| --- | --- | --- | --- |
| D01 | `AGENTS.md` | `项目理解要求` → `Cowork run/mailbox 终态` | 把 exact root run tools、first-write/pre-wait fence、source保真、普通 final不伪 claim，以及 correlation-scoped/no-ACK/fresh-follow-up写成常驻约束。 |
| D02 | `docs/ARCHITECTURE.md` | 当前工具协议、Mailbox设计、核心数据结构表 | 记录工具可见性/schema/permission/durable claim；四类 mailbox authority；`ContinuationRunCloseRequestedPayload`、information correlation与 `controlRun` 数据合同。 |
| D03 | `docs/COWORK_PRINCIPLES.md` | Goal/Run原则、消息原则、测试不变量 | 增加模型可表达/宿主强制的 run边界；明确 claim先于 admission wait/cleanup/drain；冻结 information request/reply与长期对话不冲突的原则。 |
| D04 | `docs/CURRENT_STATE.md` | macOS/Cowork当前产品面 | 把实现后的 exact `@main` run tools、tombstone/claim/restore、typed source和四类 mailbox authority记录为当前状态。 |
| D05 | `docs/DO_NOT_BREAK.md` | JSONL数据格式、ContinuationRun、Mailbox禁区 | 冻结 additive close event/first-write CAS；禁止模型提交 identity、禁止其他 run被连带取消；禁止把 `information_replied`变成全局禁言或 ACK ping-pong。 |
| D06 | `docs/PROJECT_MAP.md` | Cowork链路、协议/投影、Mailbox runtime、测试地图 | 加入 `RunControlTools.swift`、close claim/EventLog/Projection、correlation payload/lease和新增专项测试文件。 |
| D07 | `docs/TESTING.md` | 回归要求、2026-08-08真实结果 | 加入 run close/mailbox correlation验收点；记录 focused/full Swift测试、Skill/Xcode/version/build结果与 Computer Use服务启动阻塞。 |

## BEHAVIORAL_RESULT

### Current-run 终态控制

1. 模型拥有足够判断力时，可以自主调用 `finish_run` 或 `stop_run`。
2. 模型只表达 outcome + reason；控制面拥有全部 identity、权限、持久化和 drain authority。
3. close installation 先在 actor 内形成 admission/authorization tombstone，再由 EventLog跨进程 first-write。
4. durable claim早于旧 admission wait、provider/tool cleanup、task terminal与 exact-run drain。
5. current root在成功 ToolResult后可返回一次 final；其他同 run task/message/tool不能越过 fence。
6. ordinary final本身不会被 host猜成显式 close claim。
7. restore在 provider dispatch/mailbox wake前兑现已有 close fence。

### Mailbox长期协作

1. ordinary message是 one-way，不提供 ACK工具。
2. information request只可由一个 exact `reply_message(inReplyTo:)`终结。
3. information reply receipt不提供 `reply_message`，因此不会形成 reply/ACK活锁。
4. receipt若带来实质新问题，可以向原 sender创建 `request_information(based_on:)`。
5. follow-up得到 fresh RequestID，保留 stable conversation root；所以一次 `information_replied`只关闭一个 correlation，不关闭整个 conversation或 agent pair。

## VALIDATION_RESULT

实现完成时实际运行并通过：

- focused run-control/mailbox/protocol/EventLog/lease/prompt/Skill/permission测试：73 tests / 0 failures；
- `IntatisCoworkTests`：341 tests / 0 failures；
- 完整 `swift test`：exit 0；其中 `IntatisAgentKernelTests` 175 tests、`IntatisSharedUITests` 141 tests，所有已运行 target均为 0 failures；
- `xcodegen generate`：通过；
- `scripts/check-version-consistency.sh`：`Intatis version is consistent: 0.38 (build 38)`；
- `IntatisMac` macOS Debug unsigned build：通过；
- `IntatisiOS` generic Simulator Debug unsigned build：通过；
- 两个最终 bundle均读回 `0.38 (38)`；
- bundled Cowork Skill `quick_validate.py`：`Skill is valid`；
- `git diff --check`：通过。

本轮只编制报告，没有重新运行构建或测试；最终仅重新执行报告覆盖检查、`git diff --check`和`git status --short`。

## UNCERTAINTIES

- Computer Use已通过 built App绝对路径、bundle ID和 app listing入口尝试，但都在连接 Intatis前返回 `Sky Computer Use service startup request failed`。因此真实 UI、真实 provider自主调用 run工具及长时间多-agent session仍为 `UNKNOWN`。
- 未运行 Developer ID正式签名、公证、staple、Gatekeeper或 ZIP/DMG打包；本修复不构成正式 release证据。
- 本清单描述的是未提交工作树；后续若继续修改，函数行号和 diff统计会变化。文件路径、symbol与接口合同是本报告的稳定索引。

## NEXT_RECOMMENDED_ACTION

先人工复核本清单是否符合预期。若需要纳入版本控制，再由用户另行明确要求 `git add`/`commit`；不要把报告编制自动扩大为提交或发布操作。Sky服务恢复后，再用真实 Cowork session验证模型自主 `finish_run`/`stop_run`与两轮 information follow-up。
