# Claude Code Agent Four Modes Study Report

## MODEL_CHECK_RESULT

Codex / GPT-5-based agent. Exact runtime model identifier is not exposed in this session.

## PATH_CHECK_RESULT

- `pwd`: `/Users/vita/Vitemis/Intatis`
- Git root: `/Users/vita/Vitemis/Intatis`
- Result: path and Git root match the expected Intatis repository root.
- Initial `git status --short`: clean before this report was written.

## FILES_WRITTEN

- `codex-report/07_08_26-11_56-claude-agent-modes.md`

## SUMMARY

截至 2026-07-08，我对 Claude Code 官方文档中 "Agents and parallel work" 的四种并行/编排方式做了复核和学习。结论是：这不是一个单一底层 `Agent` 工具的四个 permission mode，而是一套按协调主体和规模分层的 Agent 工作模式：

1. `Subagents`: 一个主会话里的委派 worker，独立上下文执行支线任务，向主会话返回摘要。
2. `Agent view`: 用户管理多个独立后台 Claude Code 会话的控制台。
3. `Agent teams`: 一个 lead session 协调多个 teammate session，带共享任务列表和 agent 间消息。
4. `Dynamic workflows`: 由 JavaScript workflow 脚本在后台编排大量 subagents，并汇总/交叉验证结果。

这四种模式的核心区别不是 "是否能并行"，而是：

- 谁持有计划：主 agent、人、lead agent、脚本。
- 中间状态在哪里：worker 上下文、独立 session、共享任务列表、脚本变量。
- worker 是否互相通信：subagent 不直接通信；agent teams 支持；workflow 通常由脚本聚合。
- 可重复性在哪里：subagent 定义、后台 session、team 配置、workflow 脚本。
- 安全边界在哪里：工具 allowlist、permission prompt、worktree/session 隔离、workflow 启动审批、工具运行时权限。

## SOURCES

Primary official sources used:

- Claude Code Docs, "Run agents in parallel": https://code.claude.com/docs/en/agents
- Claude Code Docs, "Create custom subagents": https://code.claude.com/docs/en/sub-agents
- Claude Code Docs, "Manage multiple agents with agent view": https://code.claude.com/docs/en/agent-view
- Claude Code Docs, "Orchestrate teams of Claude Code sessions": https://code.claude.com/docs/en/agent-teams
- Claude Code Docs, "Orchestrate subagents at scale with dynamic workflows": https://code.claude.com/docs/en/workflows
- Claude Code Docs, "Tools reference": https://code.claude.com/docs/en/tools-reference
- Claude Code Docs, "What's new": https://code.claude.com/docs/en/whats-new

Project-local context read before writing:

- `/Users/vita/Vitemis/AGENTS.md`
- `docs/CURRENT_STATE.md`
- `docs/PROJECT_MAP.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/TESTING.md`
- `docs/NEXT_TARGET.md`
- `docs/COWORK_PRINCIPLES.md`

## FOUR MODES AT A GLANCE

| Mode | Coordinator | Unit of work | Intermediate state | Best fit | Primary risk |
|---|---|---|---|---|---|
| Subagents | Current Claude session | Side task in separate context | Subagent context; parent gets final summary | Focused exploration, noisy logs, repeatable specialist work | Parent may miss details; over-delegation; tool leakage if capabilities are broad |
| Agent view | Human user | Full background Claude Code session | Each session transcript/state | Multiple independent tasks the user wants to dispatch and monitor | Quota/cost multiplication; worktree cleanup; human must reconcile outputs |
| Agent teams | Lead Claude session | Teammate sessions | Shared task list plus direct teammate messages | Parallel exploration requiring discussion or challenge | Coordination overhead, higher tokens, file conflict risk |
| Dynamic workflows | Workflow script/runtime | Many subagents per scripted phase | Script variables and workflow run state | Large audits, migrations, cross-checked research, repeatable multi-agent patterns | Runaway scale/cost; script approval and permissions; harder mental model |

## MODE 1: SUBAGENTS

### What It Is

Subagents are specialized workers spawned from a single Claude Code conversation. Each subagent has its own context window, custom prompt, model choice, tool restrictions, permission mode, optional hooks, and optional skills. The parent session delegates a focused task and receives a final text result or summary; it does not continuously ingest the subagent's full intermediate transcript.

Official docs describe built-in examples such as `Explore`, `Plan`, and `general-purpose`, plus user/project-defined Markdown subagents stored under `.claude/agents/` or `~/.claude/agents/`.

### Mechanics

- The low-level tool surface is the `Agent` tool.
- A subagent can be invoked automatically when its description matches the task, or explicitly by asking Claude to use a named subagent.
- Tool access is narrowed by frontmatter fields like `tools` and `disallowedTools`.
- If neither field is set, the subagent can inherit parent tools; this is powerful but risky.
- Permission checks still happen on the subagent's own tool calls.
- As of current docs, subagents can run foreground or background; background permission prompts surface in the main session.

### Why It Exists

Subagents solve context pollution. A task like "search the whole codebase for every place this type is used" can produce many file reads and intermediate notes. Keeping that inside a separate context preserves the main conversation for decisions and final synthesis.

### Good Use Cases

- Codebase exploration before a focused edit.
- Running a test suite or log scan and returning only failures.
- Creating reusable specialist workers such as code reviewer, debugger, database query validator, or documentation researcher.
- Parallel research where each worker investigates one hypothesis or one subsystem and returns compact findings.

### Failure Modes

- If a subagent inherits too many tools, it can perform actions outside its intended role.
- If the parent only sees the final summary, important uncertainty or nuance may be lost.
- Automatic delegation can become noisy if descriptions are too broad.
- Nested/background subagent chains need depth guards and clear permission behavior.

### Intatis Interpretation

Intatis should treat this pattern as "task-scoped worker execution", not as a permanent agent hierarchy. The project already has the right primitives: `TaskContract`, `CapabilityLease`, `MessageBus`, `Mediator`, and `AgentLoop`. The clean-room equivalent should be:

- Main agent issues a structured task contract.
- Worker receives scoped context, not full raw transcript.
- Worker gets a limited capability lease.
- Worker returns a structured report through the message bus/mediator.
- Parent receives enough evidence and uncertainty, not just a vague success statement.

This maps well to existing Cowork constraints: worker should not inherit coordinator tools, browser/network tools, or write/exec tools by default.

## MODE 2: AGENT VIEW

### What It Is

Agent view is a user-facing control surface opened with `claude agents`. It shows independent background Claude Code sessions, grouped by status such as working, needs input, completed, failed, or stopped. The user can dispatch new sessions, peek at a row, reply, attach to a full conversation, detach, and come back later.

The important distinction: these are not subagents inside the current conversation. They are full Claude Code sessions running in the background.

### Mechanics

- A prompt typed into agent view starts a new background session.
- Each background session is a full Claude Code conversation.
- Sessions keep running without a terminal attached through a supervisor process.
- The user can peek for a compact status/result, reply without attaching, or attach into the full session.
- Agent view is marked as research preview in the official docs.

### Why It Exists

Agent view optimizes for human dispatch and oversight. It is the right mode when tasks are independent and the user wants to parallelize without keeping each transcript open.

### Good Use Cases

- Send one session to investigate a failing test.
- Send another session to review a pull request.
- Send a third session to prototype a small change.
- Check later which sessions need input or produced a result.

### Failure Modes

- Each session consumes its own model quota and can multiply cost quickly.
- Independent sessions can produce conflicting changes unless isolated.
- If sessions create worktrees, cleanup and review become a real product concern.
- The human becomes the merge/coherence layer.

### Intatis Interpretation

This should not be conflated with Cowork's agent roster. Agent view is closer to a future "background session supervisor" for Intatis Code/Cowork:

- It should manage whole sessions, not task-local workers.
- It should surface session state from append-only event logs.
- It should allow attach/detach without mutating hidden state.
- It should isolate file writes by workspace/worktree or an equivalent Intatis workspace lease.
- It should make cost, tool activity, permission waits, and changed files visible.

This is a good fit for Intatis' local-first workbench direction, but it should be built as a session management layer, not as a replacement for Cowork's task graph.

## MODE 3: AGENT TEAMS

### What It Is

Agent teams are coordinated groups of Claude Code sessions. One session acts as lead and manages teammates. Teammates work independently in their own context windows, share a task list, and can message one another directly. The official docs mark this as experimental and disabled by default behind `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.

### Mechanics

- A lead session coordinates work, assigns tasks, and synthesizes results.
- Teammates are independent Claude Code instances with their own context windows.
- Teammates can communicate directly instead of only reporting to the lead.
- The team has shared task state.
- The feature has known limitations around resumption, coordination, and shutdown behavior.

### How It Differs From Subagents

Subagents report back to the caller. They are good when only the result matters.

Agent teams coordinate through shared task state and direct agent-to-agent messages. They are useful when workers need to challenge, refine, or combine each other's findings.

The cost and coordination overhead are higher because each teammate is a separate Claude instance.

### Good Use Cases

- Parallel review where reviewers compare findings.
- Debugging with competing hypotheses.
- Cross-layer feature work where frontend, backend, and tests can be owned separately.
- Research tasks where independent agents should critique each other's conclusions.

### Failure Modes

- Coordination overhead can exceed the benefit for sequential or tightly coupled tasks.
- Direct inter-agent messaging needs secret filtering and length limits.
- File conflicts are likely if ownership boundaries are vague.
- Lead termination, teammate shutdown, and session resumption become product-level reliability issues.

### Intatis Interpretation

This mode is closest to Intatis Cowork, but Intatis' existing principles are stricter and should remain stricter:

- Avoid permanent `main/coordinator/worker/leaf` role trees.
- Role belongs to the task; identity is persistent.
- Capabilities are leases, not inherited powers.
- Agent communication must go through `MessageBus` and `Mediator`.
- No `AgentLoop` directly recurses into another `AgentLoop`.
- Agent-to-agent payloads should be structured enough for replay and audit.

The useful lesson is not "copy team semantics"; it is that multi-agent productization requires visible shared task state, direct but mediated communication, and explicit ownership of work partitions.

## MODE 4: DYNAMIC WORKFLOWS

### What It Is

Dynamic workflows move orchestration out of Claude's turn-by-turn conversation and into a generated JavaScript script. The script runs in a workflow runtime, spawns many subagents, stores intermediate results in script variables, and returns a consolidated result.

Official docs position this for codebase audits, large migrations, cross-checked research, and tasks too large for one conversation to coordinate manually.

### Mechanics

- Claude writes a workflow script for the described task.
- The workflow runtime executes it in the background.
- The script coordinates agents; agents perform file reads, edits, shell commands, web fetches, and other tool work according to permissions.
- The workflow itself does not directly access filesystem or shell.
- Runs can be inspected through `/workflows`.
- Saved workflows can become reusable commands under `.claude/workflows/` or `~/.claude/workflows/`.
- The docs describe concurrency and total-agent caps to bound resource use.

### Why It Exists

The orchestration plan becomes inspectable and repeatable. Instead of asking the model to remember "spawn reviewers, merge findings, verify claims, repeat until stable" across many conversational turns, the script holds the loop, branching, fan-out, aggregation, and verification pattern.

### Good Use Cases

- Audit every file in a category for the same issue.
- Migrate many files in parallel.
- Run a checker, fix, and repeat until the check passes or progress stops.
- Review every changed file, then deduplicate and rank findings.
- Deep research where claims must be cross-checked.

### Failure Modes

- More agents means higher token usage and more permission prompts.
- Generated orchestration can be wrong even if each worker is competent.
- Saved workflows can become stale as repository structure changes.
- If the workflow approval model is too permissive, the script becomes a high-amplification execution path.

### Intatis Interpretation

This is the most relevant pattern for future large-scale Intatis Code/Cowork work, but it should be introduced cautiously.

The clean-room Intatis version should be a "workflow runner" where:

- Workflow code coordinates tasks but cannot directly access files, shell, network, or secrets.
- Every concrete operation still flows through AgentLoop, schema validation, `PermissionEngine`, `PathConfinement`, and append-only `EventLog`.
- Workflow scripts are visible, reviewable, bounded, resumable, and tied to a workspace lease.
- Intermediate results are structured, not raw transcript dumps.
- Token budget, max agents, max depth, and stop conditions are explicit.

This aligns with Intatis' NEXT_TARGET priorities around recovery, observability, task status, permission UX, and artifact traceability.

## CROSS-CUTTING DESIGN MODEL

The four modes form a ladder:

1. Worker isolation: use subagents when the main issue is context hygiene.
2. Human dispatch: use agent view when independent tasks need parallel execution under human supervision.
3. Agent collaboration: use teams when agents need to communicate and coordinate.
4. Scripted orchestration: use workflows when scale and repeatability matter more than conversational flexibility.

The critical design axis is "where does the plan live?"

| Plan holder | Official mode | Consequence |
|---|---|---|
| Main conversation | Subagents | Simple, flexible, lower overhead, but summaries can hide details |
| Human user | Agent view | Strong oversight, many independent sessions, manual synthesis |
| Lead agent | Agent teams | Collaborative and adaptive, but more coordination overhead |
| Script/runtime | Dynamic workflows | Repeatable and scalable, but needs strict guardrails |

## SECURITY AND PERMISSION LESSONS

The official Claude Code docs reinforce several safety points that match Intatis' local rules:

- Tool access must be explicit and narrow. A worker with inherited tools is convenient but risky.
- Background work still needs visible permission prompts and status.
- More parallelism multiplies cost and blast radius.
- Work isolation matters when multiple sessions can edit files.
- Direct agent communication needs mediation, summary limits, and secret scanning.
- Workflow-level approval is not enough; individual tool calls still need policy checks.

For Intatis, the non-negotiable constraints remain:

- `DeterministicPolicyGate` hard deny stays final.
- `ModelPermissionReviewer` can only narrow.
- `PermissionEngine` remains the only path from model tool call to execution.
- `PathConfinement` remains mandatory for file outputs.
- `MessageBus` plus `Mediator` remains the only agent-to-agent delivery path.
- Browser/profile artifacts under `.intatis/browser` must not be treated as ordinary shareable artifacts.
- iOS must remain the restricted Chat subset.

## FIT WITH INTATIS CURRENT ARCHITECTURE

Current Intatis already has many primitives needed for a clean-room version of these patterns:

- `AgentLoop`: single agent tool loop.
- `Orchestrator`: Cowork actor coordinating agents.
- `TaskContract` and task events: structured task assignment and completion.
- `CapabilityLease`: tool exposure boundary.
- `MessageBus` and `Mediator`: mediated communication and secret filtering.
- `EventLog`: append-only replay/audit foundation.
- `TurnStatsProjection`: token/timing observability.
- Browser/document/media tools: agent-visible capabilities with strict permission and path boundaries.

The main gap is not "can Intatis spawn workers"; it is productization:

- durable background session supervision,
- reliable task recovery,
- explicit workflow scripts,
- per-agent status and cost visibility,
- conflict management for parallel file edits,
- real provider/browser/manual validation matrices.

## RECOMMENDED CLEAN-ROOM PRODUCT MAPPING

Use generic product names internally to avoid copying Claude Code names or branding:

| Claude Code term | Intatis-safe concept | Suggested Intatis surface |
|---|---|---|
| Subagents | Task-scoped workers | Cowork delegated tasks with scoped context and capability leases |
| Agent view | Background session monitor | A Code/Cowork session board driven by EventLog state |
| Agent teams | Collaborative task group | Cowork task graph with mediated direct messages and shared task status |
| Dynamic workflows | Scripted task orchestration | Bounded workflow runner that spawns task contracts, not raw recursive loops |

## IMPLEMENTATION GUIDANCE FOR INTATIS

### 1. Keep Delegation and Messaging Separate

Do not let one vague `ask_agent` operation cover every case. Preserve the distinction already stated in `docs/COWORK_PRINCIPLES.md`:

- `send_message` / `reply_message`: communication.
- `request_information`: targeted question.
- `delegate_task`: task with expected deliverable and report.
- workflow step: scripted fan-out/fan-in.

### 2. Make Context Projection a First-Class Object

For subagent/team/workflow modes, each worker should know:

- global objective summary,
- issuer,
- task contract,
- role hint,
- expected deliverable,
- allowed capabilities,
- workspace lease,
- related tasks/agents,
- relevant artifacts,
- explicit constraints and stop condition.

Avoid giving workers full raw transcript by default.

### 3. Add a Session Supervisor Separately From Cowork

An Intatis analogue of agent view should supervise whole sessions, not task-local workers. It should track:

- session id,
- mode,
- workspace/worktree,
- last activity,
- current blocked reason,
- permission waits,
- changed files,
- open artifacts,
- token/cost summary,
- safe attach/detach.

This can reuse `SessionHistoryStore` and append-only event logs.

### 4. Treat Agent Teams as Cowork, Not a New Parallel Feature

Intatis Cowork should remain the team surface. The next product quality step is not adding another "team" abstraction; it is improving:

- task graph visibility,
- task ownership,
- mediated agent messages,
- conflict handling,
- worker lifecycle,
- task report quality,
- recovery after failure.

### 5. Defer Dynamic Workflows Until Safety and Replay Are Strong

Workflow orchestration is high leverage and high blast radius. Before adding it, Intatis should define:

- workflow file format,
- script sandbox,
- max concurrent agents,
- max total agents,
- token budget,
- stop condition,
- resumption semantics,
- permission approval model,
- event schema for workflow phase/agent/result.

The workflow should coordinate AgentLoop tasks, not directly run shell or read/write files.

## OPEN QUESTIONS

- How much of Claude Code's current behavior is product policy versus implementation detail is not fully knowable from public docs.
- Agent teams are experimental and documented as having limitations; any Intatis design should treat that pattern as a signal, not a stable API contract.
- Dynamic workflow details may change across Claude Code versions; Intatis should adopt the concept, not mirror the exact command surface.
- Official docs mention worktrees as a supporting isolation primitive. Intatis currently has workspace leases and browser/profile confinement; a future parallel-edit design still needs an explicit file conflict/isolation strategy.

## VALIDATION_RESULT

- `git diff --check`: passed with no output.
- `git status --short`: `?? codex-report/`
- Build/test: not run. This was a report-only task under `codex-report/`; no source, test, build, or project configuration files were modified.

## UNCERTAINTIES

- Exact current model runtime id is unavailable.
- I did not inspect Claude Code source code or private implementation, only public official documentation.
- I did not verify Claude Code behavior in a live Claude Code install; this is documentation-based understanding.
- No Intatis business source was modified.

## NEXT_RECOMMENDED_ACTION

For Intatis, the next useful design action is to compare the current Cowork `TaskContract` / `CapabilityLease` / `MessageBus` implementation against the four-mode matrix above and decide whether the next local slice should be:

1. a background session supervisor,
2. richer Cowork task/team status,
3. or a bounded workflow-runner design document.

Do not start workflow implementation before defining replay, permission, budget, and file-conflict semantics.
