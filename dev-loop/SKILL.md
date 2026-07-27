---
name: dev-loop
description: >-
  Drive a development goal to completion by composing dev-create-tasks,
  dev-implement-task, dev-complete-task, and dev-ask in bounded rounds. Use when
  asked to work through a goal end to end, split and execute a goal, loop until
  done, or repeatedly implement and complete review-generated fixes until the
  exact repository project and loop ID are clean. Stop after five rounds by
  default.
---

# Dev Loop

Compose the task lifecycle without absorbing its responsibilities:
**create durable tasks -> implement one task -> complete that task -> repeat
for queued fixes -> prove the goal complete.**

## Load the component skills

Before acting, locate and read these files completely:

1. `dev-create-tasks/SKILL.md` — create and sync pending work.
2. `dev-implement-task/SKILL.md` — claim one UUID and produce a review branch.
3. `dev-complete-task/SKILL.md` — review, integrate or supersede, and finalize
   that UUID.
4. `dev-ask/SKILL.md` — stop on environment or harness blockers.

Resolve them as sibling directories when installed together. Run helpers from
the owning skill while keeping the target repository as the working checkout.
Never copy one component's procedure into this controller or invoke a helper
past the owning skill's boundary.

Tell the user which repository project, goal, loop ID, and round are starting. Explain
that each task will pass through creation, implementation, and completion, with
`dev-ask` guarding environment failures.

## Controller invariants

- Derive the project from the lowercase GitHub `origin` basename. Never ask the
  user or agent to invent it.
- Scope controller queries and branch collection by exact project plus exact
  `loop-id:`. Project alone includes other goals in the repository.
- Use one stable `DEV_LOOP_OWNER` for the entire run.
- Never create duplicate tasks when durable state already exists.
- Never claim a task outside the current project, loop ID, and round.
- Never treat an implementation branch or a Taskwarrior `done` status alone as
  goal completion.
- Never push, overwrite unrelated changes, force-delete unmerged branches, or
  merge without `dev-complete-task`'s verdict.
- Preserve component exit-code, synchronization, ownership, box, and cleanup
  contracts.

## Configure process exit

Persistent-agent launchers may export the agent process ID as `AGENT_PID` and
an optional notification executable as `AGENT_NOTIFY`:

```sh
sh -c 'export AGENT_PID=$$; exec <agent command>'
```

The `exec` preserves the wrapper PID as the agent PID. Do not infer it from
`$PPID`. `AGENT_NOTIFY` receives an event name and task or loop ID. Component
stages must not notify or terminate a composed `dev-loop`; only this wrapper
does so after the complete goal run reaches its final durable state.

## Define rounds and durable state

Use at most five rounds unless the user selects another limit. Round 1 contains
the initial task set. Findings produced while completing round N become tasks
for round N+1.

```text
project: <lowercase GitHub origin basename>
repo-id: github.com/<owner>/<repo>
goal: <goal-slug>
loop-id: <uuid>
loop-round: <n>
```

Use `dev-create-tasks`' autonomous origin resolver. Normalize the requested goal
to a lowercase slug. Inspect tasks whose project equals the derived repository
project and whose `repo-id:` and `goal:` match. Resume the one active loop ID
represented by pending tasks or surviving review branches. If none exists,
generate a new UUID. Multiple active loop IDs for the same repository/goal are
contradictory durable state; stop rather than combine them.

Resume the highest `loop-round:` within that exact loop. Never adopt legacy or
out-of-band tasks that lack matching repository and loop identity, and never
reset a loop ID after interruption.

Keep one observable goal-level acceptance statement across every round. Task
acceptance proves an increment; the controller completes only when the assembled
integration branch proves the original outcome.

## Start or resume the goal

1. Confirm the current checkout is the intended local integration branch.
   Preserve unrelated changes; completion requires a clean checkout for merges.
2. Derive project/repo ID from `origin`, resolve or generate the goal's loop ID,
   then inspect only matching tasks, branches, claims, worktrees, and leases.
3. Run `dev-implement-task/scripts/dl-setup.sh` once and establish the stable
   owner ID.
4. On a fresh goal, invoke `dev-create-tasks` with the shared `--goal` and
   `--loop-id` on every initial import. Round defaults to 1. Preserve
   dependencies and `input:` ancestry, add `--small` only to clearly trivial
   tasks under that skill's rule, then run the batch-final sync.
5. On a resumed goal, reconstruct state instead of decomposing the goal again.

## Run one round

### 1. Select ready work

Enumerate pending tasks whose project, `repo-id:`, `goal:`, and `loop-id:` match
the controller and whose latest `loop-round:` equals the current round. Honor
dependencies and owners. Pass each selected UUID explicitly to
`dev-implement-task`, binding the claim with `--goal`, `--loop-id`, and
`--loop-round`; never use unscoped auto-pick. Standard workers accept only
untagged tasks, smaller-model workers add `--small`, and larger-model workers
add `--large`. While both tags exist, `+LARGE` takes precedence.

If tasks remain but none is ready, inspect dependencies, owners, and preserved
branches. Stop with the exact invariant when no safe progress is possible.

### 2. Implement one task

Invoke `dev-implement-task` for the selected UUID. Require it to return:

- an active, still-pending producer owned by this controller;
- a resolving local `branch=` and recorded commit range;
- a durable implementation summary; and
- acceptance checks that passed in the box.

Do not select another task until this task reaches a completion disposition or
has been durably tagged `+LARGE`, synchronized, and released for a larger-model
worker. When that worker records `escalation-result:`, removes `+LARGE`, and
releases it, an untagged task returns to the standard queue and a retained
`+SMALL` task returns to the small queue without another marker.

### 3. Complete the task

Invoke `dev-complete-task` immediately for the returned UUID, with one exception
for deliberate stacked chains: when an already-created consumer depends on the
producer and names its review branch as `input:`, complete the producer as a
verified stacked increment, keep its branch, and let the consumer become ready.
The eventual chain tip must be reviewed against end-to-end acceptance; merging
the tip lands the ancestor increments, after which completion cleans their
already-merged branches.

For an ordinary task, let `dev-complete-task` produce one of two outcomes:

- `merged`: acceptance is demonstrated, the branch is integrated and deleted,
  the producer is completed, and resources are cleaned.
- `superseded`: findings are captured as durable round N+1 tasks rooted on the
  preserved review branch, then the producer is completed and cleaned.

After either outcome, verify Taskwarrior sync and reconcile status. Never leave
an active producer behind before moving to another task.

### 4. Drain and reconcile

Repeat selection, implementation, and completion until no task in the current
round is ready. Clean any surviving ancestor review branches that became merged
when a chain tip landed. Confirm no current-round task remains active.

Snapshot pending UUIDs before and after the round. Validate every new finding
task:

- exact project, `repo-id:`, `goal:`, and `loop-id:` match;
- `loop-round: <current + 1>`;
- `acceptance:`, `input:`, and `review-of:` annotations; and
- correct dependency and branch ancestry.

Treat inability to prove the goal-level outcome as a finding and create a
verification or integration task through `dev-create-tasks`.

## Decide whether to continue

Declare success only when all of these are true:

- no pending, waiting, or active task remains in the exact project/loop ID;
- no matching loop review branch remains after merged-ancestor cleanup;
- every completion verdict has been acted on and synchronized;
- no matching task claim, worktree, or lease leak remains; and
- the assembled integration branch demonstrates the original goal acceptance.

If next-round tasks exist and the round limit is not reached, increment the
round and continue without re-decomposing the goal.

If the final allowed round creates more work, leave the tasks pending and
unclaimed, preserve their input branches, and report the recurring findings.
Ask whether to authorize another round or change approach.

## Stop and report

Apply `dev-ask`'s two-strike rule immediately to environment, harness, box,
permission, credential, or tooling failures. An environment stop preserves the
current round and does not consume another one.

On success, report the repository project, repo ID, goal, loop ID, rounds used,
tasks created/implemented/completed, branches merged, checks run, goal evidence,
and integration HEAD. State that no matching tasks, review branches, claims,
worktrees, or leases remain.

On any stop, report the same durable state plus the exact blocker, current
round, preserved artifacts, and smallest decision needed to continue.

After the final durable check, notify first and then terminate. Make these the
last commands attempted:

```sh
if [ -n "${AGENT_NOTIFY:-}" ]; then
  "$AGENT_NOTIFY" goal-completed "$loop_id" || true
fi
if [ -n "${AGENT_PID:-}" ]; then
  kill -TERM "$AGENT_PID"
fi
```

Notification is best-effort and must not strand the worker. If `AGENT_PID` is
absent, provide the report above and end the turn normally.
