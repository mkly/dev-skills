# Completion recovery

Read this only after a partial mutation or unexplained helper failure.

- Re-export the producer, list its recorded branch, and run
  `$IMPLEMENT_SKILL/scripts/dl-status.sh`.
- Inspect the latest `reviewer=` and `review-start=` annotations before
  resuming. Only the exact reviewer agent may continue a partial review.
- Resume from the first incomplete durable boundary; helpers are idempotent at
  completed boundaries.
- Preserve a dirty integration checkout and ask before committing or stashing
  unrelated changes.
- Exit `10` means the review is unclaimed or another reviewer controls it. Do
  not inspect, merge, or finalize it. Release your own abandoned claim, or use
  explicit stale takeover only after verifying the recorded reviewer is gone.
- Exit `20` is a usage or precondition failure. Invoke `dev-ask` after two
  environmental failures.
- Exit `30` means a missing branch/base or merge conflict. Preserve the branch
  and treat a conflict as a finding.
- Never recreate a missing review branch by guessing its contents.

If the diagnostic is still unexplained, consult `reference.md` for the exact
helper and symptom only.
