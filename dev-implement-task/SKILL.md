---
name: dev-implement-task
description: >-
  Claim and implement one existing Taskwarrior development task in an isolated
  Crabbox/Incus environment, test its acceptance criteria, and snapshot the
  result to a local review branch without completing the task or merging it
  into the integration branch. Route code problems through the durable +LARGE
  queue when a larger-model worker should fix them. Use when asked to implement,
  work, execute, or pick up a queued task, or as the implementation stage
  invoked by dev-loop.
---

# Dev Implement Task

Turn one pending task into one review-ready branch and stop:
**claim -> prepare worktree and box -> edit -> test -> merge back locally ->
record summary -> return the task and branch.**

## Operating boundary

- Consume one existing Taskwarrior UUID. Never create or decompose tasks.
- Claim before reading or changing the task's worktree. Never work a task owned
  by another agent.
- Edit only in the task's recorded git worktree. Use the box only to build and
  test; in-box edits are discarded on the next sync.
- Produce a new local review branch. Never push or merge it into the integration
  branch.
- Record `summary:`, `branch=`, `base=`, and `commits=` state, then stop while
  the task remains pending and active. Never run `task done` or
  `dev-complete-task/scripts/dlc-done.sh` from this skill.
- On abandonment, use `dl-release.sh`; do not pretend the task was implemented.
- Standard workers claim only untagged tasks. Smaller-model workers use
  `dl-claim.sh --small` for `+SMALL` tasks. Larger-model workers use
  `dl-claim.sh --large` for `+LARGE` tasks.
- Do not add LLM or agent attribution to commits, task text, or annotations.

If the user supplies a goal rather than an existing task, load
`dev-create-tasks` first and let it create and sync the task set. Return to this
skill only when the user or the `dev-loop` controller authorizes implementation
of a specific returned UUID. A direct `dev-create-tasks` invocation stops at its
own boundary.

Load `dev-ask` and apply its stop rules to environment, harness, box,
permission, credential, and tooling failures. Do not route around failed helper
scripts.

## Helper contract

Run the bundled scripts from this skill directory while keeping the target
repository as the current checkout. In examples,
`/path/to/dev-implement-task-skill` is the directory containing this file.
Read `reference.md` for exact flags, environment variables, exit codes, and
troubleshooting.

Stable exit codes are: `0` success, `10` lost claim race, `20` usage or
precondition failure, and `30` empty/conflicting merge-back or branch collision.
Keep stdout parseable; helpers write diagnostics to stderr.

## 1. Set up the implementation harness

Run setup once per machine or when the harness configuration changes:

```sh
/path/to/dev-implement-task-skill/scripts/dl-setup.sh
```

Use one stable `DEV_LOOP_OWNER` for the entire task. In concurrent environments
sharing a Unix user, set a distinct literal owner before claiming:

```sh
export DEV_LOOP_OWNER="$USER@$(hostname -s)/agent-unique-name"
```

Do not change it between commands. Preserve the existing `DEV_LOOP_*` state and
annotation conventions so tasks created by older versions remain resumable.

## 2. Inspect and claim exactly one task

Export the named task and confirm it is pending and ready, its project equals
the lowercase current GitHub origin basename, its `repo-id:` matches that
origin, and it has valid `goal:`, `loop-id:`, `loop-round:`, and at least one
`acceptance:` annotation. Do not select work from another repository or loop.

```sh
uuid="$(/path/to/dev-implement-task-skill/scripts/dl-claim.sh <uuid>)"
```

When invoked by `dev-loop`, bind the claim to the controller identity too:

```sh
uuid="$(/path/to/dev-implement-task-skill/scripts/dl-claim.sh <uuid> \
  --goal "$goal" --loop-id "$loop_id" --loop-round "$round")"
```

The helper mechanically derives the repository identity from `origin`, rejects
foreign or malformed tasks, and refuses a pending task that is not ready.
Auto-pick is repository-scoped and considers only tasks with the complete
identity/acceptance contract; controller filters narrow it further. Default
claims require neither routing tag; `--small` requires `+SMALL` without
`+LARGE`; `--large` requires `+LARGE`. The same rules apply to explicit UUIDs.

- Exit `10` means another owner won. Do not work the task.
- Reclaiming your own task is idempotent.
- Use `--steal-after <duration>` only with explicit authorization and retain
  the takeover annotation.
- Use auto-pick without goal/loop filters only when the request explicitly
  covers this repository's selected worker queue. Goal-scoped controllers must
  always pass a UUID plus the exact goal, loop ID, round, and worker flag.

## 3. Prepare the worktree and box

```sh
/path/to/dev-implement-task-skill/scripts/dl-box.sh "$uuid"
```

Keep a yielded warmup command alive until it returns a real exit code. Poll the
same execution session through quiet intervals; do not start another warmup.
If the session is lost, run `dl-status.sh` before retrying.

`dl-box.sh` creates or resumes:

- a dedicated worktree rooted at the task's latest `input:` ref or current
  integration HEAD, recorded as `worktree=` and `base=`; and
- one Crabbox/Incus lease recorded as `box=`.

Edit in the recorded worktree with normal file tools. Add new files to git
before box runs so Crabbox sync includes them.

## 4. Implement and verify acceptance

Read the task description, acceptance annotations, dependencies, input branch,
and existing lifecycle annotations. Make only the changes needed for this task.

Run focused checks in the box:

```sh
/path/to/dev-implement-task-skill/scripts/dl-run.sh "$uuid" --compact -- \
  bash -lc '<focused build/test command>'
```

Use `--compact` for verbose routine output and raw mode for exact diagnostics.
Run a broader suite at most once, immediately before merge-back, and only when
the change can plausibly affect broader behavior. Never weaken or skip the
task's acceptance checks to get a pass.

If a larger-model agent can quickly resolve a code problem, delegate the fix
through the task instead of asking only for advice:

```sh
task "$uuid" annotate "escalation: <detailed issue>"
task "$uuid" annotate "attempt: <what was tried and the relevant failure>"
task "$uuid" modify +LARGE
task rc.confirmation=no sync
/path/to/dev-implement-task-skill/scripts/dl-release.sh "$uuid"
task rc.confirmation=no sync
```

Keep an existing `+SMALL` tag when adding `+LARGE`; the large queue takes
precedence. The task already carries its contract and its latest `branch=` and `worktree=`
values when those artifacts exist. Stop editing after release. A larger-model
worker claims routed work with the same repository/loop filters plus `--large`,
reads those task fields, fixes and tests the recorded worktree, then returns it
to its prior queue:

```sh
task "$uuid" annotate "escalation-result: <change and checks>"
task "$uuid" modify -LARGE
/path/to/dev-implement-task-skill/scripts/dl-release.sh "$uuid"
task rc.confirmation=no sync
```

Removing `+LARGE` is the complete return signal; no resume tag is needed. An
untagged task returns to the standard queue, while a task that retained
`+SMALL` returns to the small queue. The next matching worker reclaims it,
reconstructs the worktree from its annotations, verifies the fix, and continues
here. The larger worker must not merge back, complete the task, remove
`+SMALL`, or remove `+LARGE` before recording its result.
If box setup failed before recording a worktree, apply `dev-ask` to that
environment failure rather than escalating it as a code problem.

For a standalone worker, set `notify_event=task-escalated` after routing to
`+LARGE`, or `notify_event=task-returned` after a large worker returns it. Then
apply the final notification and termination block below after release and final
sync. Do not notify or terminate when this skill is running as a stage inside
`dev-loop`.

## 5. Produce the review branch

Snapshot the complete worktree onto a new local branch:

```sh
branch="$(/path/to/dev-implement-task-skill/scripts/dl-merge-back.sh "$uuid")"
```

The helper records `branch=` and `commits=` and prints the review branch. It
never merges or pushes. On an empty result or collision (exit `30`), resolve the
cause without marking the task implemented.

Record the durable implementation summary while the task is still active:

```sh
task "$uuid" annotate "summary: <what changed, why, and checks run>"
task rc.confirmation=no sync
```

Accept an explicitly unconfigured sync, but apply `dev-ask` to any other sync
failure before reporting a durable handoff.

Re-export the task and verify all of the following:

- status is still `pending` and `start` remains set;
- the claim still belongs to the current owner;
- `branch=`, `base=`, `commits=`, and `summary:` are present; and
- the review branch resolves locally.

Report the UUID, project, branch, commit range, checks, and acceptance evidence.
State explicitly that the task remains active and awaits `dev-complete-task`.
Do not clean the worktree or box yet; completion owns final resource cleanup.

When running as a standalone worker, set `notify_event=task-implemented` after
the durable verification above, or `notify_event=worker-idle` after an unscoped
auto-pick returns no UUID. Then make this the last command:

```sh
if [ -n "${AGENT_NOTIFY:-}" ]; then
  "$AGENT_NOTIFY" "$notify_event" "${uuid:-}" || true
fi
if [ -n "${AGENT_PID:-}" ]; then
  kill -TERM "$AGENT_PID"
fi
```

Notification is best-effort and must not strand the worker. If `AGENT_PID` is
absent, report normally. The composed `dev-loop` does not notify or terminate
between component stages.

## Recovery

Use `dl-status.sh` after interrupted commands to reconstruct claims, boxes,
worktrees, and review branches. Use `dl-release.sh` to abandon an incomplete
implementation and make it claimable again. Never release a successfully
implemented task merely to simulate the completion boundary.
