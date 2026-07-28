# Implementation recovery

Read this only after an interrupted command or an unexplained helper failure.

- Exit `10` means the task is unclaimed or owned elsewhere. Do not edit it.
- Exit `20` means usage or a failed precondition. Read stderr, correct the
  stated prerequisite, and invoke `dev-ask` after two environmental failures.
- Exit `30` from merge-back means an empty snapshot or branch collision; keep
  the task active and resolve the stated cause.
- After a lost warmup session, run `$IMPLEMENT_SKILL/scripts/dl-status.sh` before retrying. Never
  start a second warmup while the first session may still be live.
- If edits do not reach the box, confirm they are in the recorded worktree and
  add new files to Git. Never edit inside Crabbox.
- If a worktree is missing, recreate it with `dl-box.sh`; do not guess its base.
- On abandonment, use `dl-release.sh`. Do not release a successful
  review-ready task to simulate completion.

If the diagnostic is still unexplained, consult `reference.md` for the exact
helper and symptom only.
