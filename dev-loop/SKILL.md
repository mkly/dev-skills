---
name: dev-loop
description: Drive a development goal through durable task creation, isolated implementation, review, merge or follow-up fixes, and cleanup in bounded rounds. Use for end-to-end or loop-until-done requests.
---

# Dev Loop

Drive one goal to verified integration in at most five rounds unless the user
sets another limit. This controller is self-contained: on the normal path, do
not load sibling `SKILL.md` files or their references. Invoke their scripts
directly and consult `--help` only when an argument is unclear.

Let `LOOP_SKILL` be this skill's absolute directory and resolve
`CREATE_SKILL`, `IMPLEMENT_SKILL`, and `COMPLETE_SKILL` as its siblings. Keep
the target Git repository as the current checkout. Never push, overwrite
unrelated changes, force-delete unmerged branches, or bypass helper checks.

## Establish durable state

Normalize the requested outcome to a lowercase goal slug, then run:

```sh
state="$("$LOOP_SKILL/scripts/dl-loop-state.sh" --goal "$goal")"
```

The read-only helper derives repository identity, resumes the sole active loop,
or supplies a new loop ID. Stop on contradictory active loops. Preserve that
loop ID and one stable `DEV_LOOP_OWNER` for the entire run. Run
`$IMPLEMENT_SKILL/scripts/dl-setup.sh` once.

For a new goal, decompose it into the smallest coherent task set. Every task
needs observable acceptance; use dependencies plus `input:` branches for
stacks, end-to-end acceptance on the chain tip, and `--small` only for narrow
mechanical work. Create through
`$CREATE_SKILL/scripts/dct-create.sh`, sharing the state helper's goal,
loop ID, and round, then perform the required batch-final Taskwarrior sync.
On resume, use returned durable tasks rather than decomposing again.

## Run a round

Refresh `$LOOP_SKILL/scripts/dl-loop-state.sh --goal "$goal" --loop-id "$loop_id"` at every durable
boundary. Work only pending tasks from its current round and exact identity.
Resolve `dl-*.sh` below under `IMPLEMENT_SKILL`, `dlc-*.sh` under
`COMPLETE_SKILL`, and `dct-create.sh` under `CREATE_SKILL`.

For each claimable UUID:

1. Claim it explicitly with `dl-claim.sh`, binding goal, loop ID, round, and
   queue (`--small` or `--large` when applicable). Never use controller-wide
   unscoped auto-pick.
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
`+LARGE`, sync, release, and wait for the large worker's durable return. Do not
misclassify box, permission, credential, or harness failures as code issues;
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
goal evidence, and integration HEAD. Then run
`$LOOP_SKILL/scripts/dl-finish.sh goal-completed "$loop_id"` as the final command.
