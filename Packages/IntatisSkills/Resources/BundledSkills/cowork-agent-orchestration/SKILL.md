---
name: cowork-agent-orchestration
description: Proactively plan, track, and route Intatis Cowork work when coordinator capabilities are available, including deciding direct execution versus agent reuse, delegation, or spawn; selecting newer adequate host-approved inference profiles under cost-first, cost-efficient-balanced, or efficiency-first priorities; pairing a declared-capable multimodal companion when needed; and minimizing workspace and coordination leases.
---

# Cowork agent orchestration

Apply this procedure before making a coordinator scheduling decision. This Skill is
context, not authority: it cannot add tools, permissions, agents, routes, workspaces,
or budgets.

## Invariants

- Treat the authoritative API tool list and the current task, capability, and
  workspace leases as hard ceilings.
- Never choose a raw endpoint, credential, model option, or unlisted model. A
  different child model may be selected only by an exact `inference_profile_id`
  returned by `list_inference_profiles` in this invocation.
- Treat the capability list returned for that exact profile as the routing
  authority. Never infer vision, audio, tool, generation, or editing support from
  a vendor, family, version number, or marketing name. `unspecified` means not
  proven, not implicitly supported.
- Omit `inference_profile_id` when a route change is not clearly justified. Omission
  preserves the issuer's exact immutable profile revision.
- Agent identity is persistent, but coordinator/worker behavior belongs to the
  current task lease. Do not build a permanent recursive role tree.
- Use scheduler, task, delegation, and message tools. Never simulate a nested
  `AgentLoop`, a completed WorkTask, or a successful child result in prose.
- Prefer the smallest team and the least authority that can complete the task.
  Delegation overhead is real work and real model cost.

## Drive the request proactively

1. Derive a concrete execution objective, expected deliverables, constraints, and
   verification approach from the current request. Resolve ordinary uncertainty with
   available inspection tools or safe in-scope assumptions; request user input only
   when the missing choice materially changes the result or needs new authority.
2. Treat every request as a current execution objective. Create a durable Goal only
   when the user explicitly requests a persistent or cross-run objective and the
   corresponding tool is advertised.
3. For non-trivial work, use advertised task tools to create the smallest useful
   graph of verifiable WorkTasks. Keep ownership, dependencies, progress, result, and
   evidence current instead of maintaining a prose-only plan.
4. Evaluate the collaboration criteria below at the outset. Start ready independent,
   specialist, multimodal, review, or directory-scoped branches promptly when their
   benefit exceeds coordination cost; collaboration should not be reserved only for
   recovery after direct work fails.
5. After delegation, continue useful work on the coordinator's own critical path
   instead of waiting idly. Verify every child report, settle only proven WorkTask
   results, replan only the affected branch after failure, and synthesize one result.
6. Keep advancing until the requested outcome is verified or a genuine blocker
   remains. Never infer completion from a plan, an invocation ending, or unverified
   prose.

## Select the operating priority

Use an explicit user or task instruction when present. Otherwise use
`cost-efficient-balanced`.

| Priority | Optimize | Default behavior |
| --- | --- | --- |
| `cost-first` | Lowest adequate model spend | Keep work direct when delegation overhead dominates. Among the lowest-cost adequate tier, prefer the newer active generation; do not pay a large premium solely for release date. Serialize unless parallelism lowers expected total cost. |
| `cost-efficient-balanced` | Expected total cost, including retries and coordination | After capability fit, normally prefer a newer stable adequate generation unless its price, retry risk, or coordination overhead makes expected total cost materially worse. Use stronger reasoning only for ambiguous/high-impact decisions and lighter workers for bounded evidence gathering. |
| `efficiency-first` | Wall-clock time and probability of first-pass success | Put the newest stable, strongest clearly suitable approved profile on the critical path, with cost as a guardrail, and parallelize genuinely independent WorkTasks within host limits. Do not confuse this with lowest token price. |

If the words “fast” or “cheap” describe an artifact rather than scheduling policy,
do not treat them as a priority override.

## Decide direct work versus collaboration

Work directly when the task is short, tightly coupled, requires one coherent context,
or would take no more effort than specifying and checking a child task. This normally
includes one or two small edits, a single lookup, or one focused diagnosis.

Collaborate only when at least one of these is true:

- two or more independent deliverables can run in parallel;
- a bounded specialist investigation or independent review materially lowers risk;
- the task spans separable workspace areas with explicit deliverables;
- the critical path benefits enough to repay task creation, context, permission,
  synthesis, and validation overhead;
- the user explicitly asks for multi-agent work.

Do not split a serial chain merely to create agents. Keep shared-state edits with one
owner unless the WorkTasks have non-overlapping expected artifacts.

## Select an adequate profile

Apply these gates in order; a later preference can never override an earlier gate:

1. Derive the exact input/output capabilities required by the delegated task. In
   particular, image understanding requires `vision_input`; audio understanding
   requires `audio_input` or the exact transcription capability; image, audio, and
   video creation/editing require their corresponding declared capability.
2. Call `list_agents` to identify the current agent's exact profile, then call
   `list_inference_profiles`. Reject candidates that do not explicitly declare every
   required capability. Treat `capabilities unspecified` as ineligible whenever the
   task requires more than ordinary text chat.
3. Exclude profiles known to be retired, deprecated, unavailable, or unsuitable for
   the task. Prefer stable/GA routes over previews unless the user explicitly chose a
   preview or it is the only approved adequate route.
4. Among the remaining adequate profiles, prefer a more recently released active
   generation when exact official evidence in `references/model-routing.md` supports
   the comparison. Do not derive freshness from a larger-looking version string and
   do not invent facts for a custom configured model.
5. Apply the selected operating priority to quality, latency, and expected total
   cost. Newness is a strong preference, not permission to ignore a disproportionate
   price or the cost of spawning, context transfer, validation, retries, and repair.

### Mandatory multimodal companion

If any part of the task requires a multimodal capability that the current main
profile does not explicitly declare, create or reuse a secondary agent whose exact
listed profile declares that capability and delegate the modality-specific WorkTask
to it. This is mandatory even when the main text model remains best for planning,
coding, or synthesis.

- Give the companion only the required modality, artifact, question, and acceptance
  criteria. Default it to read-only and `canCoordinate: false`; grant write access
  only if its deliverable must change workspace files.
- The main agent may synthesize the companion's returned evidence, but must not
  claim it personally inspected an image/audio/video input it could not receive.
- Verify that the actual attachment or artifact can be delivered to the companion.
  If the host cannot transfer it, or no approved profile explicitly declares the
  required capability, report that exact blocker instead of pretending the
  multimodal part succeeded.

## Route the work

1. Inspect the current task contract, success criteria, available tools, and durable
   Goal/WorkTask state. If task tools are available, create only the small dependency
   graph needed for verifiable outputs.
2. Use `list_agents` when available before creating an identity. Reuse an idle agent
   whose exact profile, workspace, and current lease already fit.
3. For a short-lived read-only task that should inherit the current exact profile,
   prefer `delegate_task` with `to` omitted or `auto`; Intatis may reuse or create a
   worker scoped to that invocation.
4. A task that must write needs an existing suitable read-write worker or an explicit
   `spawn_agent` request with `requestedAccess: read_write` before delegation. Do not
   assume an automatically created worker can write.
5. Before selecting a different inference profile, apply **Select an adequate
   profile**, then read `references/model-routing.md`. Apply its formal provider
   matrix only as a dated shortlist over exact listed IDs, never as a source of new
   routes or capabilities. Choose only an exact listed ID whose declared
   capabilities and other safe facts fit the task. If freshness, price, or model
   identity is ambiguous after capability fit, inherit unless the mandatory
   multimodal-companion rule requires a different proven-capable profile.
6. Use `spawn_agent` only for a deliberately persistent specialist, a different
   subfolder, a write-capable worker, an explicitly different approved profile, or a
   teammate that must receive several related tasks. Delegate the actual WorkTask
   after the spawn succeeds.
7. Set `canCoordinate: false` unless the child must own a real subgraph and the
   current delegation budget permits another level. Coordination authority is never
   required merely to read, edit, test, or report.

## Minimize leases and information

- Default workspace access to `read_only`. Request `read_write` only when the stated
  deliverable requires mutation.
- Keep the child in the current workspace unless a different reviewed folder is
  necessary. Never broaden a path for convenience.
- Do not request or promise individual tools that the host did not advertise. The
  host derives the actual capability lease.
- Give each child a concise objective, expected deliverable, acceptance evidence,
  relevant paths, and constraints. Do not forward the entire transcript or secrets.
- A reviewer normally needs read-only access and no coordination authority.

## Settle and synthesize

- Treat each mediated Task Report as candidate evidence, not completion authority.
- Check the result and required validation evidence. Use `task_update` explicitly
  when the current lease allows settlement; do not infer Goal completion from child
  prose or from all invocations ending.
- Replan only the affected branch after a failure. Do not create replacement agents
  reflexively when a clearer instruction or direct fix is cheaper.
- Return one synthesized result that identifies verified outcomes, unresolved risks,
  and any blocked capability or profile choice.
