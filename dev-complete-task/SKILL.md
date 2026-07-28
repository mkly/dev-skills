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

Resolve the exact producer and branch:

```sh
branches="$("$COMPLETE_SKILL/scripts/dlc-collect.sh" --from-task "$uuid")"
"$COMPLETE_SKILL/scripts/dlc-diff.sh" "$branch"
```

Require matching repository/loop identity, acceptance, summary, commit range,
and—when active—the current owner. Review correctness, regression risk, tests,
security, secrets, and debug or attribution residue. When execution is needed,
run isolated verification with `dlc-test.sh "$branch" --compact -- <command>`
from `COMPLETE_SKILL`. Record one evidence-backed verdict.

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
failures. On a standalone final handoff, run
`"$LOOP_SKILL/scripts/dl-finish.sh" task-completed "$uuid"`; do not run it inside
`dev-loop`.
