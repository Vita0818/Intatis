# AGENTS.md

## Project

This repository is Intatis.

Intatis is a clean-room local AI workspace with three product surfaces:

```text
Chat    ordinary multimodal conversation
Code    single-agent local workspace work
Cowork  multi-agent local workspace collaboration
```

Do not describe Intatis as a clone in user-facing text. It may be inspired by existing local agent tools and agent desktop layouts, but implementation and naming must remain Intatis-native.

## Mandatory Reading Before Cowork Work

Before modifying Cowork, AgentKernel, MessageBus, permissions, or agent orchestration, read these docs:

```text
docs/COWORK_AGENT_ARCHITECTURE.md
docs/COWORK_TASK_CONTEXT_MODEL.md
docs/COWORK_CURRENT_FINDINGS.md
docs/COWORK_MIGRATION_PLAN.md
```

These documents define the intended architecture. Follow them unless the user explicitly overrides them.

## Core Cowork Principles

Do not implement Cowork as a hardcoded recursive agent tree.

Use these principles:

```text
Agent identity is persistent.
Role belongs to a task.
Permissions are temporary leases.
Context is scoped and projected.
Collaboration happens through a task graph and message bus.
AgentLoop must never directly recurse into another AgentLoop.
```

## Required Design Direction

Prefer:

```text
TaskContract
Scoped Context
CapabilityLease
WorkspaceLease
TaskGraph
Scheduler
MessageBus
ContextProjector
DelegationService
```

Avoid relying on:

```text
hardcoded coordinator/worker/leaf roles
coordinationDepth as role semantics
global conversation history for every agent
synchronous nested AgentLoop calls
one overloaded ask_agent operation for all interaction types
```

A numeric depth guard may exist as a safety fuse, but it must not be the core role model.

## Agent Context Rule

Every agent should know why it is running.

When an agent receives a task, its context should include:

```text
global objective summary
issuer / assigning agent
its task contract
its role hint for this task
its expected deliverable
its workspace lease
its allowed capabilities
related agents/tasks
lineage showing why it was created
```

Do not give an agent the entire raw global transcript by default.

Use scoped projection:

```text
global brief
task group context
task-local context
agent-local history
explicitly shared artifacts
workspace-relevant observations
```

## Tool and Capability Rule

Tools should be exposed according to a capability lease.

A normal worker task should not receive coordinator tools such as:

```text
spawn_agent
remove_agent
delegate_task
```

If a task needs delegation, grant it explicitly through `CapabilityLease.delegation`.

Child agents should not gain coordinator powers just because they were spawned.

## Communication Rule

Distinguish communication from delegation.

Communication:

```text
send_message
request_information
reply_message
```

Delegation:

```text
request_delegation
delegate_task
```

Do not use one ambiguous `ask_agent` operation for every purpose long-term.

## Recursion and Cycle Rule

AgentLoop must not directly call another AgentLoop in a nested synchronous way.

Use mailbox / scheduler / event flow.

Reject or guard:

```text
caller == target self-call
A → B → A cycles
unbounded delegation chains
duplicate task creation
unbounded agent spawning
```

## Workspace and Security Rule

Workspace expansion is never read-only.

Creating or attaching an agent to a new directory is a capability/workspace expansion and must be permissioned.

Do not let a model silently attach:

```text
/
~
/Users
~/.ssh
~/Library/Keychains
secret/token/key directories
```

All file access must go through workspace confinement and permission policy.

## Current Known Cowork Issues

Known issues from read-only audit:

```text
first-level child agents may still get coordinator tools
ask_agent allows self-call
ask_agent creates nested AgentLoop execution
priorHistory uses global conversation projection
spawn_agent has been treated too much like read-only
MessageBus payload is too thin
there is no task contract / capability lease yet
```

When working on Cowork, prioritize eliminating these problems.

## Implementation Order

Use this order unless instructed otherwise:

```text
1. Immediate safety patch:
   - worker cannot spawn by default
   - ask self-call rejected
   - spawn_agent not read-only
   - worker prompt does not advertise coordinator powers

2. Introduce TaskContract.

3. Introduce ContextProjector.

4. Introduce CapabilityLease / WorkspaceLease.

5. Split message and delegation APIs.

6. Replace nested AgentLoop calls with scheduler/mailbox.

7. Add task graph cycle detection.

8. Expand semantic event schema and tests.
```

## Testing Expectations

When changing Cowork or AgentKernel, add or update tests for:

```text
child cannot spawn without capability
child cannot ask itself
worker prompt does not advertise coordinator powers
task contract appears in context
context projection hides unrelated raw global transcript
capability lease controls tool registry
delegation cycle is rejected
workspace expansion requires permission
agent-to-agent event records caller, target, task, and causal chain
```

## Platform Boundary

macOS is the full Intatis product.

iOS is a true subset of macOS:

```text
iOS supports Chat, multimodal, providers, artifacts, session history.
iOS must not include local workspace Agent execution.
iOS must not link shell/git/patch/local-agent workspace modules.
```

Do not weaken this boundary.

## Clean-room Rule

Do not copy source code, private prompts, UI assets, icons, product names, or user-facing wording from Codex, Claude Code, DeepCode, OpenCode, ChatGPT, Claude, or similar products.

Use generic terms:

```text
local agent workspace
clean-room agent kernel
multi-agent cowork thread
task graph
capability lease
scoped context
```

## Change Discipline

For large changes:

```text
read docs first
state the intended module boundary
avoid broad rewrites
make the smallest coherent patch
add tests
report remaining risks
```

Do not add unrelated features while fixing Cowork orchestration.
