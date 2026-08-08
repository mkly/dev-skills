---
name: dev-complete-task
description: Review and finish one implemented Taskwarrior task by verifying its local review branch, then merging clean work or creating durable follow-up tasks and cleaning resources.
---

# Dev Complete Task

Give one review-ready task a terminal verdict: `merged`, `stacked`, or
`superseded`. Let `COMPLETE_SKILL` be this skill's absolute directory and
resolve `CREATE_SKILL`, `IMPLEMENT_SKILL`, and `LOOP_SKILL` as its siblings;
keep the target repository as the current directory. Use bundled scripts'
`--help` for exact flags and exits.

## Boundary

- Judge the recorded branch against the description, every `acceptance:`, its
  implementation summary, and any stacked end-to-end behavior.
- Do not implement fixes in the producer worktree.
- Merge only a clean branch into a clean, attached local integration checkout.
  Never push or force-delete an unmerged branch.
- Finalize only after a merge, durable successor, or durable finding batch.

## Review

Inspect matching pending producers, select exactly one, then acquire its
separate reviewer lock before reading the diff:

```sh
branches="$("$COMPLETE_SKILL/scripts/dlc-collect.sh" --from-task "$uuid")"
"$COMPLETE_SKILL/scripts/dlc-claim.sh" "$uuid"
"$COMPLETE_SKILL/scripts/dlc-diff.sh" "$branch"
```

Exit `10` means another agent is reviewing it; do not inspect, test, merge, or
finalize that producer. Exit `20` with a queue message means the task belongs to
another routing queue: the claim defaults to `DEV_LOOP_ROUTE`, so leave that work
to its own `loop` worker instead of passing a contradicting queue flag. The reviewer lock is independent of the implementation
assignee and remains held through the terminal verdict. Release it with
`dlc-release.sh "$uuid"` only when abandoning review without a verdict.

Require matching repository/loop identity, acceptance, summary, commit range,
and—when active—the current owner. Review correctness, regression risk,
security, secrets, and debug or attribution residue from the diff first; the
suite takes 10+ minutes and is nearly always green, so treat it as a final
gate, not a discovery tool. Run `dlc-test.sh "$branch" --compact -- <command>`
from `COMPLETE_SKILL` only once the diff review clears — skip it if a finding
already routes the branch to Findings. Record one evidence-backed verdict.

## Apply the verdict

- **Clean:** run `$COMPLETE_SKILL/scripts/dlc-merge.sh "$branch"`, then
  `$COMPLETE_SKILL/scripts/dlc-done.sh "$uuid" --outcome merged`, sync, and verify integration and
  resource cleanup.
- **Planned stack predecessor:** verify its pending consumer depends on it and
  names its branch as `input:`, then finalize with `--outcome stacked`. Preserve
  the branch until the chain tip lands.
- **Findings:** create one independently acceptable fix per finding through
  `$CREATE_SKILL/scripts/dct-create.sh --from-task "$uuid"`. Root the
  first fix on the preserved producer branch and chain overlapping fixes. Sync
  and verify the complete batch before finalizing the producer with
  `--outcome superseded`. Never merge or delete its branch.

After the final sync, verify terminal task state, required branch preservation
or deletion, and cleanup with `$IMPLEMENT_SKILL/scripts/dl-status.sh`.
Report identity, verdict, acceptance evidence, checks, branch/HEAD, follow-up
UUIDs, and cleanup.

After a partial mutation or unexplained helper failure, read
[recovery.md](recovery.md). Invoke `dev-ask` only for environmental or harness
failures.

On any exceptional path, and when review context a later round needs would
otherwise die with this worker, load the sibling `dev-board` skill and post it.
`loop` exports `DEV_BOARD_ROOT`. Search the board before diagnosing a blocker of
your own. Finding tasks and outcomes stay authoritative in Taskwarrior. On a standalone final handoff, run
`"$LOOP_SKILL/scripts/dl-finish.sh" task-completed "$uuid"`; do not run it inside
`dev-loop`.
