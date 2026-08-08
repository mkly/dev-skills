---
name: dev-implement-task
description: Claim and implement one queued Taskwarrior development task in its isolated worktree and Crabbox, then produce a local review branch without completing or merging the task.
---

# Dev Implement Task

Turn one pending UUID into a review-ready local branch. Let `IMPLEMENT_SKILL`
be this skill's absolute directory and `LOOP_SKILL` and `BOARD_SKILL` its
siblings `dev-loop` and `dev-board`;
keep the target repository as the current checkout. Use each bundled script's
`--help` for flags and exit codes.

## Boundary

- Claim before reading or changing the task worktree; never work another
  owner's task.
- Edit only the recorded host worktree. Use the box only for builds and tests.
- Never create tasks, push, merge into integration, or mark the task done.
  `+PLAN` decomposition tasks belong to the sibling `dev-decompose-task`
  skill; `dl-claim.sh` excludes them from every work queue.
- Leave a successful task pending and active for `dev-complete-task`.
- Preserve one stable `DEV_LOOP_OWNER` throughout the task.
- End every run by calling `dl-finish.sh`; see [Finish](#finish).
- Treat `AGENT_PID` and `AGENT_NOTIFY` as controller-owned lifecycle values:
  never assign, overwrite, or unset them. When present, `AGENT_PID` is the
  inherited numeric Linux PID that `dl-finish.sh` terminates, not an arbitrary
  agent ID or claim nonce. When absent, leave it absent; `dl-claim.sh` safely
  generates its own claim nonce.

## Implement

1. Run `$IMPLEMENT_SKILL/scripts/dl-setup.sh` once per machine or harness change.
2. Inspect the task contract, then claim the explicit UUID with
   `$IMPLEMENT_SKILL/scripts/dl-claim.sh`. A controller must also pass its goal, loop ID, round,
   and queue flag; a worker launched by `loop` inherits its queue from
   `DEV_LOOP_ROUTE` and must not pass a flag that contradicts it. Exit `10`
   means another worker holds the claim: do not work the task, do not wait for
   it to be released, and do not pick a different task. You have no work — stop
   here and go straight to [Finish](#finish) with `worker-idle`. Empty stdout
   from an auto-pick is the same situation and takes the same path.
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

On any exceptional path, post to the shared board what the annotation cannot
carry: a blocker another worker will hit too, an approach abandoned and why, or
the reasoning behind an escalation.

```sh
"$BOARD_SKILL/scripts/db-search.sh" --task "$uuid" --text '<blocker in a few words>'
"$BOARD_SKILL/scripts/db-post.sh" --task "$uuid" --loop "$loop_id" \
  --subject '<one-line blocker>' --body-text "$report"
```

Search before diagnosing, not after: another worker may have posted this
blocker's answer already, and `dl-claim.sh` prints any existing discussion of the
task to stderr when you claim it. Both scripts derive their own identity and
repair their own index, so neither needs setup. Annotations stay authoritative
for task state; the article carries the knowledge across workers.

## Finish

Every run ends with this command, including the short ones: a lost claim race
(exit `10`), an auto-pick that found nothing, an escalation, an abandoned task.
A run that ends after two commands still ends here:

```sh
"$LOOP_SKILL/scripts/dl-finish.sh" task-implemented "$uuid"
```

Substitute `task-escalated`, `task-returned`, or `worker-idle` for
`task-implemented` when that is the outcome. The single exception is a composed
run: skip this only when `dev-loop` loaded this skill as a stage in the current
session and will finish on your behalf. If you are not certain you are that
case, you are not that case — run it.

Report first, then run it. Nothing follows it: no summary, no verification, no
closing message. Reaching the end of your turn without it is an incomplete run,
not a finished one — the worker process stays alive holding its queue, and the
poll loop launches nothing until someone kills it by hand.

Preserve inherited `AGENT_PID` and `AGENT_NOTIFY` verbatim so the command can
notify the controller and terminate the worker; never alter either value to make
the helper return successfully.
