---
name: dev-implement-task
description: Claim and implement one queued Taskwarrior development task in its isolated worktree and Crabbox, then produce a local review branch without completing or merging the task.
---

# Dev Implement Task

Turn one pending UUID into a review-ready local branch. Let `IMPLEMENT_SKILL`
be this skill's absolute directory and `LOOP_SKILL` its sibling `dev-loop`;
keep the target repository as the current checkout. Use each bundled script's
`--help` for flags and exit codes.

## Boundary

- Claim before reading or changing the task worktree; never work another
  owner's task.
- Edit only the recorded host worktree. Use the box only for builds and tests.
- Never create tasks, push, merge into integration, or mark the task done.
- Leave a successful task pending and active for `dev-complete-task`.
- Preserve one stable `DEV_LOOP_OWNER` throughout the task.
- Treat `AGENT_PID` and `AGENT_NOTIFY` as controller-owned lifecycle values:
  never assign, overwrite, or unset them. When present, `AGENT_PID` is the
  inherited numeric Linux PID that `dl-finish.sh` terminates, not an arbitrary
  agent ID or claim nonce. When absent, leave it absent; `dl-claim.sh` safely
  generates its own claim nonce.

## Implement

1. Run `$IMPLEMENT_SKILL/scripts/dl-setup.sh` once per machine or harness change.
2. Inspect the task contract, then claim the explicit UUID with
   `$IMPLEMENT_SKILL/scripts/dl-claim.sh`. A controller must also pass its goal, loop ID, round,
   and queue flag. Exit `10` means the claim was lost; do not work the task.
3. Run `$IMPLEMENT_SKILL/scripts/dl-box.sh "$uuid"` and wait for its real exit status. Poll the
   same yielded session through quiet warmup periods.
4. Edit the recorded worktree. Add new files to Git before box runs because
   only tracked files sync into Crabbox.
5. Run focused acceptance checks with:

   ```sh
   "$IMPLEMENT_SKILL/scripts/dl-run.sh" "$uuid" --compact -- bash -lc '<command>'
   ```

   Use raw mode for exact diagnostics. Run a broader suite once only when the
   change can affect wider behavior.
6. Snapshot with `$IMPLEMENT_SKILL/scripts/dl-merge-back.sh "$uuid"`, annotate a durable
   `summary:` of changes and checks, and sync Taskwarrior.
7. Re-export and require the original claim, pending/active status, resolving
   `branch=`, `base=`, `commits=`, and `summary:`.

Report the UUID, branch, commit range, checks, and acceptance evidence. Do not
clean the worktree or box; completion owns cleanup.

## Exceptional paths

For a code problem suited to a larger worker, record `escalation:` and
`attempt:`, add `+LARGE`, sync, release with
`$IMPLEMENT_SKILL/scripts/dl-release.sh`, and stop editing.
A large worker records `escalation-result:`, removes `+LARGE`, releases, and
syncs; it does not complete or merge the task.

On abandonment, use `$IMPLEMENT_SKILL/scripts/dl-release.sh`. After an interrupted helper or an
unexplained exit `20`/`30`, read [recovery.md](recovery.md). Invoke `dev-ask`
only for an environmental or harness failure.

For a standalone final handoff, run
`"$LOOP_SKILL/scripts/dl-finish.sh" task-implemented "$uuid"`; use
`task-escalated`, `task-returned`, or `worker-idle` when applicable. Do not run
it as a composed `dev-loop` stage. Preserve inherited `AGENT_PID` and
`AGENT_NOTIFY` verbatim so this final command can notify the controller and
terminate the worker as configured; never alter either value to make the
helper return successfully.
