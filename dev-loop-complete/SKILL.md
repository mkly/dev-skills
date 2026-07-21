---
name: dev-loop-complete
description: >-
  Drive a development goal to completion by composing dev-loop,
  dev-loop-review, and dev-ask in bounded implementation/review rounds. Use
  when asked to "loop until done," to run dev-loop then dev-loop-review
  repeatedly, or to take a goal all the way through Taskwarrior decomposition
  and claims, isolated implementation, local review and merge, and any
  review-generated fix tasks until the project is clean. Stop after five rounds
  by default.
---

# Dev Loop Complete

Run the implementation and review skills as one bounded controller:
**plan work -> claim and implement -> review and merge -> turn findings into
work -> repeat until clean.**

## Load the component skills

Before acting, locate and read these three `SKILL.md` files completely:

1. `dev-loop` — create, claim, implement, test, merge back, and complete tasks.
2. `dev-loop-review` — inspect review branches, merge clean work, and create fix
   tasks for findings.
3. `dev-ask` — stop cleanly on environment, harness, or tooling failures.

When this skill is stored beside its dependencies, resolve them as
`../dev-loop`, `../dev-loop-review`, and `../dev-ask`. Otherwise locate their
installed skill directories. Run each component's bundled scripts from that
component's directory while keeping the target repository as the working
directory. Never substitute similarly named scripts from the target repository.

Tell the user that `dev-loop` will run before `dev-loop-review`, with `dev-ask`
guarding environment failures throughout. All of their operating and safety
rules remain in force. This skill only adds project scoping, repetition,
durable round tracking, and a completion rule.

At the phase boundary, let `dev-loop-review` govern review-branch disposition.
Dev-loop's ban on auto-merging applies during implementation and merge-back;
the later review verdict is the deliberate decision that authorizes
`dlr-merge.sh` to merge a clean branch and safely delete it with `git branch
-d`.

If a component skill is unavailable, treat that as an environment blocker and
follow `dev-ask`; do not reconstruct its harness by hand.

## Define the controller state

Treat one **round** as:

1. One dev-loop work pass that drains the goal's currently claimable tasks.
2. One dev-loop-review pass over the review branches produced for that goal.

Allow at most five rounds unless the user explicitly chooses another limit.
The initial implementation and its review are round 1. Fix tasks created by a
review belong to the next round. A clean result in the final allowed round
completes normally; new fixes found there would require another round, so
preserve them and stop at the cap.

Choose one unused Taskwarrior project slug for the goal and use it throughout.
Never claim or review unrelated work. Add this durable annotation to every
initial task:

```text
loop-round: 1
```

After each review, annotate every newly created fix task with
`loop-round: <next-round>`. Keep these annotations when stopping at the cap so
a resumed run cannot accidentally reset the counter. To resume, reconstruct
the round from the project's pending and completed task annotations plus its
existing review branches; do not decompose the original goal again. Treat a
pending task with `review-of:` but no `loop-round:` as an interrupted
post-review handoff: annotate it for the next round instead of creating a
duplicate.

## Start or resume the goal

1. State the original goal as an observable, goal-level acceptance outcome.
   Keep it as the completion bar across every round.
2. Confirm the current checkout is the intended local integration branch and
   is clean enough for `dev-loop-review` to merge into it. Never stash,
   overwrite, or discard unrelated user changes merely to make it clean.
3. Inspect existing tasks for the project, existing project review branches,
   and dev-loop status before creating anything. Resume durable state when it
   exists; create no duplicate tasks or branches.
4. Run dev-loop setup once and establish one stable, unique `DEV_LOOP_OWNER`
   for the entire run.
5. On a fresh goal only, decompose it with dev-loop Phase 1. Add acceptance
   annotations, dependencies, and `input:` branch links. Batch trivial related
   work and add an end-to-end acceptance criterion to the final task of every
   stacked chain. Annotate every created task with `loop-round: 1`.

Do not treat a Taskwarrior task being `done` as goal completion. In dev-loop,
that only means its local review branch is ready; the work has not necessarily
been reviewed or merged into the integration branch.

## Run a round

### 1. Drain the project's claimable work with dev-loop

Enumerate pending tasks only from the chosen project. Claim each selected UUID
explicitly with `dl-claim.sh <uuid>` rather than using an unscoped automatic
pick. For every successful claim, follow dev-loop Phases 3-5 exactly:

- warm or reuse the task's box and wait for warmup to really exit;
- edit only in the recorded task worktree;
- run acceptance checks in the box;
- merge back to a new local review branch;
- record the summary and complete the task.

Repeat until no project task is ready. Honor dependencies and claim ownership.
On claim exit `10`, skip work owned by someone else; never steal it silently.
If project tasks remain but none can be claimed, inspect their dependencies,
wait state, and owners. Review any branches already produced, but do not declare
the goal complete; stop with the exact contention or dependency state if it
cannot advance safely.

### 2. Review and act with dev-loop-review

Snapshot the project's pending task UUIDs, then run dev-loop-review scoped to
the project slug:

- collect branches with `dlr-collect.sh <goal-slug>`;
- review each actionable branch against its task acceptance criteria and the
  original goal-level outcome;
- run checks through `dlr-test.sh` when the verdict needs execution;
- merge and safely delete clean branches with `dlr-merge.sh`;
- leave branches with findings unmerged and create properly based, dependent
  fix tasks as dev-loop-review requires.

Treat inability to demonstrate the original goal-level outcome as a finding.
Create an integration or verification task instead of declaring success.

Compare pending task UUIDs after review with the snapshot. Ensure every new fix
task stays in the same project, has `acceptance:`, `input:`, and `review-of:`
annotations, and add `loop-round: <current-round + 1>`. Do not add the round
annotation to completed producer tasks; dev-loop-review's restriction on
mutating them still applies.

Collect the project branches again after review actions. A clean successor can
make its previously superseded ancestor branches become merged during the same
pass. Clean up those now-merged branches with `dlr-merge.sh`, then collect once
more so stale merged ancestors do not force a fake extra round.

### 3. Decide whether to continue

Declare the goal complete only when all of these are true after reconciliation:

- no pending, waiting, or claimed task remains for the project;
- no existing project review branch remains after merged-branch cleanup;
- every review verdict has been acted on successfully;
- the original goal-level acceptance outcome was demonstrated on the assembled
  work; and
- dev-loop status shows no active claim, worktree, or lease leak for the goal.

If review created fix tasks and the current round is below the limit, increment
the round and run another dev-loop pass followed by another review pass. Do not
re-decompose the original goal.

If unresolved work remains without a corresponding task, or a task remains
without a safe path to claim it, stop and report the invariant rather than
spinning or falsely declaring completion.

## Stop conditions

Apply `dev-ask`'s two-strike rule immediately to environment, harness, box,
permission, credential, or tooling failures. Preserve all tasks, claims,
worktrees, and review branches according to the component skills. An
environment stop does not consume another round; resume the same round after
the blocker is fixed.

When the final allowed round creates work for another round (round 5 creating
round 6 under the default limit):

1. Do not claim the new tasks.
2. Leave their input review branches intact.
3. Report each pending UUID, finding, dependency, and branch.
4. Summarize the recurring pattern that exhausted the limit.
5. Ask the user whether to authorize another round or change the approach.

## Report the result

On success, report the project slug, rounds used, tasks completed, review
branches merged, checks run, and resulting integration-branch HEAD. State
explicitly that there are no remaining project tasks or review branches.

On any stop, report the same state plus the exact reason, the current round,
preserved artifacts, and the smallest decision needed to continue. Never push
or merge to a remote as part of this skill.
