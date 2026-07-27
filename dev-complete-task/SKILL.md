---
name: dev-complete-task
description: >-
  Review and complete one implemented Taskwarrior development task by checking
  its local review branch against acceptance, running isolated verification,
  merging clean work or queuing durable follow-up tasks, and finalizing task
  resources. Use when asked to review, accept, finish, merge, or complete an
  implemented task, or as the completion stage invoked by dev-loop.
---

# Dev Complete Task

Turn one review-ready task into one terminal verdict:
**reconstruct intent -> review and verify -> merge or queue fixes -> complete
the producer -> clean resources.**

## Operating boundary

- Consume one task with a recorded local review branch. Do not implement code
  in the producer's worktree.
- Judge the branch against the task description, every `acceptance:` annotation,
  its `summary:`, and the assembled behavior of any stacked chain.
- Merge only a clean branch into the current local integration branch. Never
  push, force-delete an unmerged branch, or add agent attribution.
- For findings, create follow-up work only through `dev-create-tasks`; never
  duplicate its Taskwarrior import logic.
- Finalize the producer only after the clean merge succeeds, every finding task
  is durably created, or a pre-existing dependent task durably names its branch
  as the next stacked input. Completion owns `task done`, worktree cleanup, and
  box parking/stopping.
- Keep a branch with findings because it is the fix tasks' `input:` base.

Load `dev-ask` and apply its stop rules to environment, harness, box,
permission, credential, and tooling failures. Do not route around failed helper
scripts.

## Load component skills

Before creating the first finding task, read `dev-create-tasks/SKILL.md`
completely and use its `scripts/dct-create.sh`. Resolve it as the sibling
`../dev-create-tasks` when possible. A clean completion does not need to load
the creation component.

`scripts/dlc-done.sh` reuses the implementation harness's state helpers. Resolve
`dev-implement-task` as sibling `../dev-implement-task`, or export
`DEV_IMPLEMENT_TASK_SKILL_DIR` to its installed directory before invoking the
completion helper.

Run this skill's scripts from inside the target repository. Read `reference.md`
for exact flags, environment variables, exit codes, and troubleshooting.

## 1. Resolve one review-ready task

Export the named UUID and require:

- a project equal to the lowercase current GitHub origin basename;
- matching `repo-id:`, `goal:`, `loop-id:`, and `loop-round:` annotations;
- at least one `acceptance:` annotation;
- a resolving `branch=` annotation; and
- an implementation `summary:` and `commits=` range.

Allow both active tasks produced by `dev-implement-task` and completed legacy
tasks produced by the former workflow. For an active task, require the current
`DEV_LOOP_OWNER` to own the claim unless the user explicitly authorizes a
takeover. Never select a task from another repository or loop.

Collect branch context and select the exact producer:

```sh
branches="$(scripts/dlc-collect.sh --from-task '<uuid>')"
obj="$(printf '%s' "$branches" | jq --arg uuid '<uuid>' \
  '[.[] | select(.task.uuid == $uuid)] | if length == 1 then .[0] else empty end')"
```

Stop if the task maps ambiguously, its branch is missing, or the integration
checkout is detached or dirty. Preserve unrelated user changes.

The collector derives project/repo identity from the current GitHub origin and
goal/loop identity from the producer. It rejects a mismatched producer and
ignores branches and `input:` consumers from other goals or loops.

## 2. Review intent and diff

Read the description, acceptance criteria, summary, input ancestry, and round
metadata from the task. Inspect the complete branch increment:

```sh
scripts/dlc-diff.sh "$branch"
scripts/dlc-diff.sh "$branch" --stat-only
```

Review for correctness, acceptance coverage, regressions, missing tests,
security problems, debug residue, secrets, and attribution. For a stacked chain
tip, verify the assembled end-to-end behavior rather than only the final slice.

When the verdict requires execution, run checks in an isolated box:

```sh
scripts/dlc-test.sh "$branch" --compact -- bash -lc '<acceptance command>'
```

Use `--keep-box` only for multiple checks in the same review. Use raw mode when
exact diagnostics matter. Record one verdict: `clean` or `needs-fixes`, with
concrete evidence.

## 3A. Complete a clean task

Merge and safely delete the review branch:

```sh
scripts/dlc-merge.sh "$branch"
scripts/dlc-done.sh "$uuid" --outcome merged
task rc.confirmation=no sync
```

`dlc-merge.sh` aborts conflicts and preserves the branch. Treat a conflict as a
finding; never force the merge. `dlc-done.sh` removes the implementation
worktree and scratch branch, parks or stops the box, records the outcome, and
marks the task done. The final sync publishes completion and dependency
readiness; accept an explicitly unconfigured sync, but stop on any other sync
failure.

Re-export the task and verify it is completed, the review branch is gone, and
the integration HEAD contains the branch tip. Run implementation status to
confirm no claim, worktree, or lease leak remains for the task.

## 3B. Complete a planned stacked increment

When a pending consumer already depends on this producer and names the
producer's review branch as `input:`, review the producer as an individual
increment but do not merge or delete its branch. Verify the consumer's durable
dependency, input branch, acceptance, project, repo ID, goal, and loop ID, then
run:

```sh
scripts/dlc-done.sh "$uuid" --outcome stacked
task rc.confirmation=no sync
```

This releases the dependent consumer while preserving code ancestry. Report
the successor UUID and branch. The eventual chain tip must carry and pass an
end-to-end acceptance criterion; merging that tip lands the earlier increments.
Clean their then-merged branches with `dlc-merge.sh` afterward.

## 3C. Complete a task with findings

Create one fix task per independent finding by inheriting repository and loop
identity from the producer. Root each first fix on the preserved branch and
block it on the producer until the producer is finalized:

```sh
fix="$(/path/to/dev-create-tasks-skill/scripts/dct-create.sh \
  --from-task "$uuid" \
  --description 'fix: <one concrete finding>' \
  --acceptance '<observable proof the finding is fixed>' \
  --depends "$uuid" \
  --input "$branch" \
  --review-of "${uuid:0:8} $branch")"
```

`--from-task` defaults to the producer's round plus one. Pass an explicit
`--loop-round <n>` when several chained fixes must share the same next round.
Later tasks depend on the earlier fix and use its predicted review branch as
`input:`, while inheriting identity from the original reviewed producer.

After creating the complete finding batch:

1. Run `dev-create-tasks`' required batch-final `task sync`.
2. Verify every fix is pending and unstarted, has the producer's exact project,
   `repo-id:`, `goal:`, and `loop-id:`, and has `acceptance:`, `input:`,
   `review-of:`, the next round, and the intended dependency.
3. Run `scripts/dlc-done.sh "$uuid" --outcome superseded`.
4. Run `task rc.confirmation=no sync` again so the completed producer releases
   its dependent fixes durably.

Do not merge or delete the producer's review branch. Verify it still resolves
and every first fix names it as `input:`. Report the producer as completed and
superseded, and list the pending follow-up UUIDs.

## 4. Report the terminal state

Report the task UUID, repository project, goal, loop ID, round, verdict,
acceptance evidence, checks run, integration HEAD or preserved input branch,
follow-up UUIDs, and cleanup status. State whether the task was merged or
superseded.

If a helper fails after a partial mutation, reconstruct state from Taskwarrior,
git, and `dev-implement-task/scripts/dl-status.sh` before retrying. All helpers
are intended to be safely repeatable at completed boundaries.

When running as a standalone worker, set `notify_event=task-completed` and
`notify_ref="$uuid"` after the final sync, re-export, and cleanup verification.
When no review-ready task is available, set `notify_event=worker-idle` and
`notify_ref=""`. Then make this the last command:

```sh
if [ -n "${AGENT_NOTIFY:-}" ]; then
  "$AGENT_NOTIFY" "$notify_event" "$notify_ref" || true
fi
if [ -n "${AGENT_PID:-}" ]; then
  kill -TERM "$AGENT_PID"
fi
```

Notification is best-effort and must not strand the worker. If `AGENT_PID` is
absent, report normally. Do not notify or terminate when this skill runs inside
`dev-loop`; the wrapper continues the composed goal.
