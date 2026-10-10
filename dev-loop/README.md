# dev-loop

`dev-loop` is the end-to-end controller for four sibling development skills:

```text
dev-create-tasks → dev-implement-task → dev-complete-task
                           ↘ dev-ask ↙
```

- `dev-create-tasks` creates durable, pending Taskwarrior work and stops.
- `dev-implement-task` claims one existing task, implements/tests it in an
  isolated host worktree, with optional Crabbox execution, and produces a local review branch.
- `dev-complete-task` reviews that branch, merges or queues fixes, marks the
  producer done, and cleans implementation resources.
- `dev-loop` composes those stages in bounded rounds.
- `dev-ask` remains the independent environment-blocker stop policy.

For end-to-end runs, the controller uses sibling scripts directly instead of
loading every component skill body. `dev-loop/scripts/dl-loop-state.sh` provides
read-only goal/round state as compact JSON, relative to the worker's own queue:
`--route` (defaulting to `DEV_LOOP_ROUTE`, then `standard`) decides what counts
as claimable, and pending work tagged for any other queue is reported as
`delegated` instead, since the claim helpers refuse it. `dlc-claim.sh` applies
the same predicate at review time, so one queue implements and reviews a task
end to end.

No stage pushes to a remote. Only completion merges into the current local
integration branch.

The repository-level `loop` executable polls Taskwarrior and launches the
selected agent (`codex`, `claude`, `agy`, `qwen`, `devin`, or `copilot`). One
worker drains one routing queue: `./loop --agent codex` processes the standard
(untagged) queue, and `--standard`, `--small`,
`--large`, or `--plan` selects a queue explicitly. Add `--implement-task` or
`--complete-task` to restrict the lifecycle stage. Each queue flag mirrors a
`dl-claim.sh` claim predicate and is exported to the agent as
`DEV_LOOP_ROUTE`, so a worker can never count work it cannot claim.

All agents accept `--model`. Codex, Claude, Agy, and Copilot also accept
`--effort`; Qwen and Devin reject it because their CLIs provide no matching
control. Devin and Copilot run in their documented non-interactive modes with
tool approvals enabled so an unattended worker cannot stop on a prompt.

Every invocation receives the current `.dev-knowledge.md` and its ETag in the
agent prompt, along with instructions for maintaining it and continuing to use
dev-board. The sibling `dev-knowledge` helper reads from the primary checkout's
root, so linked worktrees share one document. Missing is normal; read failures
stop the launcher before it starts an agent. The document is refreshed on every
retry, not only when the worker process starts.

The file may be gitignored with `/.dev-knowledge.md`; no ignore rules are changed
automatically. All writers must use the helper's conditional update operation
to prevent lost updates. See [dev-knowledge](../dev-knowledge/SKILL.md) for read,
creation, update, and stale-revision behavior. Python 3 and the sibling helper
are required by the launcher. Independent clones have independent documents.

OTEL export is opt-in per worker. Pass an OTLP/HTTP base URL (without
`/v1/logs`, `/v1/traces`, or `/v1/metrics`), for example:

```sh
./loop --agent codex --otel-endpoint http://localhost:4318
./loop --agent claude --otel-endpoint https://collector.example.com
```

Codex, Claude, Qwen, and Copilot support this option; Copilot exports traces
and metrics. Agy and Devin reject the option because no native exporter is
wired for them. No agent configuration files are edited. Without the flag,
the launcher disables OTEL via environment settings and, for Codex and Qwen,
explicit CLI overrides. This does not control unrelated vendor analytics or
administrator-enforced telemetry policies.

The project is derived automatically by the Taskwarrior claim harness's
GitHub-origin resolver, including lowercase normalization and `.git` removal.
Exported resource attributes are `service.namespace=<project>`,
`dev_loop.project=<project>`, and `dev_loop.repository=github.com/<owner>/<repo>`.
Filter or route on these attributes to partition projects sharing a collector.
The full repository attribute distinguishes repositories with the same basename.
Unrelated `OTEL_RESOURCE_ATTRIBUTES` are preserved; inherited project labels
are replaced. An invalid or missing GitHub origin prevents an OTEL-enabled
worker from starting. Exporter endpoints and protocols are overridden for each
signal so inherited destinations cannot divert exports. Existing OTLP auth
headers remain available. Qwen's legacy telemetry CLI flags must be supported
by the installed version.

Taskwarrior repository projects are autonomous: every task uses the lowercase
basename of the GitHub `origin` URL. Goal runs are isolated by `goal:` and a
generated `loop-id:` annotation rather than by project subnames.

## Prerequisites

The implementation and completion harnesses require Linux, Bash 4+, Git,
Taskwarrior 3, `jq`, and `flock`. Commands run locally in the task or review
worktree by default; Git worktrees isolate source files, not host processes.

Set `CRABBOX_PROVIDER=sprites` (or any compatible provider) to run checks through
Crabbox instead. That mode also requires Crabbox and the selected provider's
authentication, CLI, and project prerequisites. No provider is assumed, and
merely installing Crabbox or adding `crabbox.yaml` does not enable it. A selected
provider failure stops the operation rather than switching to the host.

Remote tasks record `box-provider=` so handoffs retain their original route.
Legacy tasks with a box but no recorded provider require an explicit
`CRABBOX_PROVIDER` for recovery. Set `DEV_LOOP_BOX_SCOPE` to distinguish accounts
or endpoints when reusing boxes with the same provider. Legacy parked-box files
are not adopted by the new namespace; inspect and stop those leases explicitly.
Automatic expiry is provider-dependent, so stop parked leases before finishing
a goal.

## Install

Install the workflow and knowledge directories as siblings in a skill discovery directory. Use
symlinks during development so repository edits remain live:

```sh
skill_root=/path/to/agent-skills

ln -s "$PWD/dev-create-tasks" "$skill_root/dev-create-tasks"
ln -s "$PWD/dev-implement-task" "$skill_root/dev-implement-task"
ln -s "$PWD/dev-complete-task" "$skill_root/dev-complete-task"
ln -s "$PWD/dev-loop" "$skill_root/dev-loop"
ln -s "$PWD/dev-ask" "$skill_root/dev-ask"
ln -s "$PWD/dev-board" "$skill_root/dev-board"
ln -s "$PWD/dev-knowledge" "$skill_root/dev-knowledge"
```

The skills intentionally resolve one another as siblings. If
`dev-complete-task` is installed elsewhere, set `DEV_IMPLEMENT_TASK_SKILL_DIR`
when invoking its finalization helper.

## Lifecycle

```text
pending
  → claimed/active
  → implemented with review branch (still active)
  → merged | stacked | superseded
  → completed and cleaned
```

Implementation never calls `task done`. Completion is the only stage that
finalizes an implemented producer. The wrapper repeats the lifecycle for
review-generated fixes and defaults to a five-round cap.

Lifecycle state continues to use `base=`, `box=`, `worktree=`, `branch=`,
`commits=`, `acceptance:`, `input:`, and `review-of:`. New tasks also carry
`repo-id:`, `goal:`, `loop-id:`, and `loop-round:` for repository and controller
scoping. Untagged tasks use the standard queue, `+SMALL` routes trivial work to
smaller-model workers, and `+LARGE` routes escalated work to larger-model
workers started with `loop --large`. `+LARGE` takes precedence when both tags
exist; removing it restores the prior small or standard queue without a resume
tag.

## Persistent worker exit

Launch a persistent agent with its process ID in `AGENT_PID`. Optionally set
`AGENT_NOTIFY` to an executable callback:

```sh
sh -c 'export AGENT_PID=$$; exec <agent command>'
```

After a standalone task worker reaches its final synchronized handoff, it calls
`AGENT_NOTIFY` with an event and task or loop ID, ignores notification failure,
and then runs `kill -TERM "$AGENT_PID"`. The shared
`dev-loop/scripts/dl-finish.sh` helper implements this sequence. Events are `tasks-created`,
`task-implemented`, `task-escalated`, `task-returned`, `task-completed`,
`goal-completed`, and `worker-idle`.

A composed `dev-loop` waits until the whole goal run finishes instead of
notifying or terminating between component stages. If either variable is not
set, that corresponding action is skipped.
