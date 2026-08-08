---
name: dev-loop
description: Drive a development goal through durable task creation, isolated implementation, review, merge or follow-up fixes, and cleanup in bounded rounds. Use for end-to-end or loop-until-done requests.
---

# Dev Loop

Drive one goal to verified integration in at most five rounds unless the user
sets another limit. This controller is self-contained: on the normal path, do
not load sibling `SKILL.md` files or their references, except `dev-board` on the
exceptional paths below. Invoke their scripts
directly and consult `--help` only when an argument is unclear.

Let `LOOP_SKILL` be this skill's absolute directory and resolve
`CREATE_SKILL`, `IMPLEMENT_SKILL`, and `COMPLETE_SKILL` as its siblings. Keep
the target Git repository as the current checkout. Never push, overwrite
unrelated changes, force-delete unmerged branches, or bypass helper checks.

Treat `AGENT_PID` and `AGENT_NOTIFY` as controller-owned lifecycle values.
Workers must inherit them verbatim and must never assign, overwrite, or unset
them. When present, `AGENT_PID` is a numeric Linux PID used by `dl-finish.sh`
as the `kill -TERM` target; it is not an arbitrary agent identifier. Absence is
valid and must remain absence. Every run, on every path, ends by calling
`dl-finish.sh`; see [Finish](#finish).

## Establish durable state

Normalize the requested outcome to a lowercase goal slug, then run:

```sh
state="$("$LOOP_SKILL/scripts/dl-loop-state.sh" --goal "$goal")"
```

The read-only helper derives repository identity, resumes the sole active loop,
or supplies a new loop ID. Stop on contradictory active loops. Preserve that
loop ID and one stable `DEV_LOOP_OWNER` for the entire run. Run
`$IMPLEMENT_SKILL/scripts/dl-setup.sh` once.

For a request to drain existing work, if no pending task is available, do not
create tasks and do not stop at a prose response — "there is nothing to do" is
still a run that has to end through [Finish](#finish), with the `worker-idle`
event. Answering in prose and stopping leaves the worker alive holding its
queue.

For a new goal, decompose it into the smallest coherent task set. Every task
needs observable acceptance; use dependencies plus `input:` branches for
stacks, end-to-end acceptance on the chain tip, and `--small` only for narrow
mechanical work. Create through
`$CREATE_SKILL/scripts/dct-create.sh`, sharing the state helper's goal,
loop ID, and round, then perform the required batch-final Taskwarrior sync.
On resume, use returned durable tasks rather than decomposing again.

A goal too large to decompose in one sitting may instead be captured as
`+PLAN` decomposition tasks: create each with `dct-create.sh --plan` and
attach its plan artifact through the implement skill's `dl_plan_put`. A
`+PLAN` task is never implemented directly, and the default, `--small`, and
`--large` queues never claim one. Route it to the sibling `dev-decompose-task`
skill, which claims via `dl-claim.sh --plan`, creates the plan's follow-up
tasks with `dct-create.sh --from-task`, records them as `decomposed-into=`
annotations, and finalizes the producer with `dlc-done.sh --outcome
decomposed`. Drain the plan queue before the work queues it feeds.

## Run a round

Refresh `$LOOP_SKILL/scripts/dl-loop-state.sh --goal "$goal" --loop-id "$loop_id"` at every durable
boundary. Work only pending tasks from its current round and exact identity.
Resolve `dl-*.sh` below under `IMPLEMENT_SKILL`, `dlc-*.sh` under
`COMPLETE_SKILL`, and `dct-create.sh` under `CREATE_SKILL`.

`BOARD_SKILL` is the sibling `dev-board` directory, and `loop` exports
`DEV_BOARD_ROOT`. Load and use it when knowledge would otherwise die with this
worker: a blocker another queue will hit too, an approach abandoned and why, the
reasoning behind an escalation, or review context a later round needs. Search it
before diagnosing a blocker of your own, since another worker may have already
posted the answer. Its articles are context only; keep every task transition and
authoritative work contract in Taskwarrior. Do not load it merely to poll for
messages.

For each claimable UUID:

1. Claim it explicitly with `dl-claim.sh`, binding goal, loop ID, round, and
   queue (`--small`, `--large`, or `--plan` when applicable). Never use
   controller-wide unscoped auto-pick. A `+PLAN` task follows the
   `dev-decompose-task` path, not steps 2–6.

   Exit `10` means another worker claimed it first. As the controller you have
   other work: drop that UUID without touching it, never wait for the claim to
   be released, and continue to the next claimable UUID. Only when the race
   leaves nothing claimable does the run end — as `worker-idle` through
   [Finish](#finish), never as a prose report that the tasks were all taken.
2. Prepare with `dl-box.sh`; wait for a yielded warmup's real exit status.
3. Edit only the recorded host worktree. Add new files before box runs. Test
   acceptance through `dl-run.sh --compact`; use raw output when diagnosing.
4. Snapshot with `dl-merge-back.sh`, record `summary:`, sync, and verify the
   active producer and resolving review branch.
5. Review the complete increment with `dlc-diff.sh`; run isolated
   `dlc-test.sh` when execution is needed.
6. Apply exactly one disposition:
   - clean: `dlc-merge.sh`, then `dlc-done.sh --outcome merged`;
   - verified stack predecessor: preserve its branch and finalize `stacked`;
   - findings: create accepted next-round tasks with `dct-create.sh
     --from-task`, rooted on the preserved branch, then finalize `superseded`.
7. Sync and verify terminal producer state and resource cleanup before choosing
   another task.

For a code issue needing a larger worker, record the issue and attempt, add
`+LARGE`, sync, release, and await the separate `loop --large` worker's durable
return. The state helper is queue-aware
through `DEV_LOOP_ROUTE`: pending work on any other queue is reported as
`delegated`, never claimable — awaited elsewhere, neither yours to claim nor
grounds to declare the goal complete, so finish as `worker-idle` when nothing
else is claimable. Do not misclassify box, permission, credential, or harness failures as code issues;
invoke `dev-ask` only when such a failure occurs.

Drain the round, clean merged ancestor branches, and verify every finding task
belongs to the next round with correct acceptance and ancestry. Continue while
the state helper reports pending work and the round limit permits it. At the
limit, preserve pending tasks and branches and request authorization to extend.

## Finish

Declare success only when the exact loop has no pending/active task, unmerged
review branch, unresolved verdict, claim, worktree, or lease, and the integrated
checkout demonstrates the original goal acceptance. Use `dl-status.sh` for the
final resource check.

Report repository/goal identity, rounds, task outcomes, merged branches, checks,
goal evidence, and integration HEAD. Then end the run:

```sh
"$LOOP_SKILL/scripts/dl-finish.sh" goal-completed "$loop_id"
```

Every run ends here, with no exception — a completed goal, an exhausted round
limit, an escalation awaited elsewhere, a queue raced empty by other workers,
and an idle worker that found nothing all terminate through this command; only
the event differs (`goal-completed`, `worker-idle`). Report first, then run it. Nothing follows it: no summary, no
verification, no closing message. Reaching the end of your turn without it is an
incomplete run, not a finished one — the worker process stays alive holding its
queue, and the poll loop launches nothing until someone kills it by hand.

The command handles optional `AGENT_NOTIFY` and `AGENT_PID`. Never alter either
inherited value to bypass notification, PID validation, or worker termination.
