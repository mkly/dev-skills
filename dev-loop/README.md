# dev-loop

`dev-loop` is the end-to-end controller for four sibling development skills:

```text
dev-create-tasks → dev-implement-task → dev-complete-task
                           ↘ dev-ask ↙
```

- `dev-create-tasks` creates durable, pending Taskwarrior work and stops.
- `dev-implement-task` claims one existing task, implements/tests it in an
  isolated Crabbox/Incus environment, and produces a local review branch.
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
selected agent. One worker drains one routing queue: `./loop --agent codex`
processes the standard (untagged) queue, and `--standard`, `--small`,
`--large`, or `--plan` selects a queue explicitly. Add `--implement-task` or
`--complete-task` to restrict the lifecycle stage. Each queue flag mirrors a
`dl-claim.sh` claim predicate and is exported to the agent as
`DEV_LOOP_ROUTE`, so a worker can never count work it cannot claim.

Taskwarrior repository projects are autonomous: every task uses the lowercase
basename of the GitHub `origin` URL. Goal runs are isolated by `goal:` and a
generated `loop-id:` annotation rather than by project subnames.

## Prerequisites

The implementation and completion harnesses require Linux, Bash 4+, Git,
Taskwarrior 3, `jq`, `flock`, Crabbox, and an initialized Incus provider.

## Install

Install all five directories as siblings in a skill discovery directory. Use
symlinks during development so repository edits remain live:

```sh
skill_root=/path/to/agent-skills

ln -s "$PWD/dev-create-tasks" "$skill_root/dev-create-tasks"
ln -s "$PWD/dev-implement-task" "$skill_root/dev-implement-task"
ln -s "$PWD/dev-complete-task" "$skill_root/dev-complete-task"
ln -s "$PWD/dev-loop" "$skill_root/dev-loop"
ln -s "$PWD/dev-ask" "$skill_root/dev-ask"
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
