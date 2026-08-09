---
name: dev-complete-task
description: Review and finish one implemented Taskwarrior task by verifying its local review branch, fixing the findings on it, then merging, or creating durable follow-up tasks when a major blocker stops the merge, and cleaning resources.
---

# Dev Complete Task

Give one review-ready task a terminal verdict: `merged`, `stacked`, or
`superseded`. Let `COMPLETE_SKILL` be this skill's absolute directory and
resolve `CREATE_SKILL`, `IMPLEMENT_SKILL`, `LOOP_SKILL`, and `BOARD_SKILL` as
its siblings;
keep the target repository as the current directory. Use bundled scripts'
`--help` for exact flags and exits.

## Boundary

- Judge the recorded branch against the description, every `acceptance:`, its
  implementation summary, and any stacked end-to-end behavior.
- Do not implement fixes in the producer worktree.
- Merge only a clean branch into a clean, attached local integration checkout.
  Resolving that merge's conflicts there is part of merging, not implementing a
  fix; anything beyond reconciling the two sides belongs in a follow-up task.
  Never push or force-delete an unmerged branch.
- Fixing a finding yourself on the review branch is the default outcome; see
  [Fix findings directly](#fix-findings-directly). Filing a follow-up task is
  the exception, reserved for a major blocker.
- Finalize only after a merge, durable successor, or durable finding batch.
- Treat `AGENT_PID` and `AGENT_NOTIFY` as controller-owned lifecycle values:
  inherit them verbatim; never assign, overwrite, or unset them.
- End every run by calling `dl-finish.sh`; see [Finish](#finish).

## Review

Inspect matching pending producers, select exactly one, then acquire its
separate reviewer lock before reading the diff:

```sh
branches="$("$COMPLETE_SKILL/scripts/dlc-collect.sh" --from-task "$uuid")"
"$COMPLETE_SKILL/scripts/dlc-claim.sh" "$uuid"
"$COMPLETE_SKILL/scripts/dlc-diff.sh" "$branch"
```

Exit `10` means another agent already holds the reviewer lock: do not inspect,
test, merge, or finalize that producer, do not wait for the lock, and do not
select a second producer instead. You have no work — stop here and go straight
to [Finish](#finish) with `worker-idle`. A `DL_LOST` failure later in the run,
from `dlc-done.sh` reporting a concurrent agent under your owner, ends the same
way: stop and finish as `worker-idle`. Exit `20` with a queue message means the task belongs to
another routing queue: the claim defaults to `DEV_LOOP_ROUTE`, so leave that work
to its own `loop` worker instead of passing a contradicting queue flag. The reviewer lock is independent of the implementation
assignee and remains held through the terminal verdict. Release it with
`dlc-release.sh "$uuid"` only when abandoning review without a verdict.

Require matching repository/loop identity, acceptance, summary, commit range,
and—when active—the current owner. Review correctness, regression risk,
security, secrets, and debug or attribution residue from the diff first; the
suite takes 10+ minutes and is nearly always green, so treat it as a final
gate, not a discovery tool. Run `dlc-test.sh "$branch" --compact -- <command>`
from `COMPLETE_SKILL` only once the diff review clears — skip it if a major
blocker already routes the branch to Findings. Findings alone do not send a
branch to Findings: fix them on the branch first, then run the suite once over
the result. Record one evidence-backed verdict.

## Apply the verdict

- **Clean:** run `$COMPLETE_SKILL/scripts/dlc-merge.sh "$branch"`, then
  `$COMPLETE_SKILL/scripts/dlc-done.sh "$uuid" --outcome merged`, sync, and verify integration and
  resource cleanup. A merge conflict is not a finding and does not fail the
  review: exit `40` leaves the merge in progress with the conflicted paths
  listed, so resolve each one in the integration checkout, keeping both sides'
  intent, `git add` them, then
  `$COMPLETE_SKILL/scripts/dlc-merge.sh "$branch" --continue` and carry on to
  `dlc-done.sh --outcome merged`. Re-run the acceptance checks when the
  resolution changed behavior rather than adjacent lines. Only when the two
  sides genuinely cannot be reconciled here — the branch needs real
  reimplementation against the new base — run `dlc-merge.sh "$branch" --abort`
  and route it to Findings.
- **Planned stack predecessor:** verify its pending consumer depends on it and
  names its branch as `input:`, then finalize with `--outcome stacked`. Preserve
  the branch until the chain tip lands.

Both `stacked` and `superseded` close the producer while keeping its review
branch alive, so each one transfers the obligation to merge that branch onto a
successor. `dlc-done.sh` enforces the transfer: it refuses either outcome
unless the producer carries a `successor=<uuid>` annotation naming a task that
is still pending. `dct-create.sh --from-task` writes that annotation, so the
normal Findings path satisfies it automatically. A closed task can never be
reclaimed for review — `dlc-claim.sh` requires `status:pending` — so a
preserved branch whose successors have all closed is stranded permanently
outside the integration branch. Never reach for `--force` to get past this;
create or reopen a successor instead.
- **Findings:** this path opens only once a major blocker is established. Then
  every finding you did not fix directly gets one independently
  acceptable fix task through
  `$CREATE_SKILL/scripts/dct-create.sh --from-task "$uuid"`. Root the
  first fix on the preserved producer branch and chain overlapping fixes. Sync
  and verify the complete batch before finalizing the producer with
  `--outcome superseded`. Never merge or delete its branch.

## Fix findings directly

Fix what you find. A follow-up task costs another worker round, another box, and
another review, so a finding you can correct and prove here is finished here —
including ones that run to several files or a few commits, and ones that need a
new test or a new acceptance criterion you add to the producer. Read enough
surrounding code to be sure of the fix; leaving the diff is expected, not
disqualifying.

Route a finding to Findings only when it is a **major blocker** — one of:

- The fix means reimplementing the task's approach, or rewriting most of the
  diff, rather than correcting it.
- It needs a decision that is not yours to make: ambiguous product intent, a
  behavior contract or public API whose consumers must agree, a schema or data
  migration whose rollout has to be planned.
- It reaches well outside the task's scope — a separate subsystem, a dependency
  upgrade, a repo-wide refactor — and would turn one task into two anyway.
- You tried the fix and it did not converge: verification still fails, or the
  change keeps growing as you pull on it.
- The branch genuinely cannot be reconciled with the current base and needs
  reimplementation against it.

Security, auth, and concurrency findings are not automatically blockers — fix
them if the correct fix is clear and the acceptance checks prove it; escalate
them when the right behavior is a judgment call. Uncertainty about *what* the
code should do is a blocker; uncertainty about *how* to write the fix is not,
so work it out.

One major blocker settles the whole round: the branch is not merging, so file
the remaining findings alongside it rather than committing on a branch a
successor is about to build on. Fix directly whenever no finding is a blocker.

Fix on the review branch, before the merge, in the verification worktree
`dlc-test.sh` keeps for that branch — never in the producer's own worktree and
never in the integration checkout. `dlc-test.sh` logs the path it uses and
reuses it as long as it sits at the branch tip, so a commit made there is the
branch tip and stays verifiable in a box:

```sh
wt=<path dlc-test.sh logged for this branch>
# edit under "$wt", then:
git -C "$wt" commit -am "fix: <finding> (review of ${uuid:0:8})"
"$COMPLETE_SKILL/scripts/dlc-test.sh" "$branch" --compact -- <command>
task rc.confirmation=no annotate "$uuid" "review-fix: <finding>"
```

Then merge and finalize `--outcome merged` as usual; the extra commits land with
the branch, and the recorded implementation head stays an ancestor of HEAD.
Report each direct fix alongside the verdict — a fixed finding is still a
finding, and the user sees it or it did not happen. If a fix turns into a major
blocker while you work it, stop editing, reset the branch back to the recorded
implementation head, and file it as a follow-up task instead.

After the final sync, verify terminal task state, required branch preservation
or deletion, and cleanup with `$IMPLEMENT_SKILL/scripts/dl-status.sh`.
Report identity, verdict, acceptance evidence, checks, branch/HEAD, follow-up
UUIDs, and cleanup.

After a partial mutation or unexplained helper failure, read
[recovery.md](recovery.md). Invoke `dev-ask` only for environmental or harness
failures.

On any exceptional path, and when review context a later round needs would
otherwise die with this worker, post it to the shared board:

```sh
"$BOARD_SKILL/scripts/db-search.sh" --task "$uuid" --text '<question in a few words>'
"$BOARD_SKILL/scripts/db-post.sh" --task "$uuid" --loop "$loop_id" \
  --subject '<one-line finding>' --body-text "$context"
```

Search before diagnosing a blocker of your own — another worker may have posted
the cause. Reply to an existing discussion with `db-post.sh --parent
<message-id>` rather than starting a second thread on the same subject. Finding
tasks and outcomes stay authoritative in Taskwarrior.

## Finish

Every run ends with this command, whatever the verdict was, and including the
short ones: a lost reviewer lock (exit `10`), no review-ready task, a producer
left to another queue. A run that ends after two commands still ends here:

```sh
"$LOOP_SKILL/scripts/dl-finish.sh" task-completed "$uuid"
```

Use `worker-idle` in place of `task-completed` when no review-ready task
existed. The single exception is a composed run: skip this only when `dev-loop`
loaded this skill as a stage in the current session and will finish on your
behalf. If you are not certain you are that case, you are not that case — run
it.

Report first, then run it. Nothing follows it: no summary, no verification, no
closing message. Reaching the end of your turn without it is an incomplete run,
not a finished one, and nothing waits for you to come back: your process exits,
the poll loop sees an eligible queue, and it launches a replacement worker that
starts its own review and leases its own box while yours is still running.

That failure mode has one common cause, so treat it as a rule: **never end your
turn while a command is still running.** `dlc-test.sh` takes 10+ minutes in a
box, and there is no re-invocation when it reports back — announcing that you
will pick the result up later ends the run then and there, abandoning the
reviewer lock, the worktree, and the box. Wait for the command's real exit
status and act on it in the same turn. If you genuinely cannot, release the lock
with `dlc-release.sh` and finish as `worker-idle` so the queue is left clean.

Preserve inherited `AGENT_PID` and `AGENT_NOTIFY` verbatim so the command can
notify the controller and terminate the worker; never alter either value to make
the helper return successfully.
