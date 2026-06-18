---
name: dev-loop-review
description: >-
  Review the work a long-running dev-loop produced. Gathers the completed
  Taskwarrior tasks for a goal (or a recent time window), correlates each with
  the local review branch and commit range dev-loop recorded, walks the diffs,
  and presents a full code review — inline plus a saved markdown report. Strictly
  READ-ONLY: never mutates tasks, branches, or the repo, never pushes or merges.
  Use after running dev-loop, or when asked to "review what the loop did",
  "review the recent dev-loop work", or "go through the recently done tasks and
  commits and review them".
---

# dev-loop-review

Review what a dev-loop run produced. dev-loop leaves a trail of **completed
tasks**, each annotated with the **review branch** and **commit range** it
created and a human `summary:`. This skill follows that trail: collect the
completed tasks for a goal → for each, read its intent and walk its diff →
aggregate into one full review, shown inline and saved to a markdown file.

This skill **reviews**; it does not change anything. dev-loop already declined to
push or auto-merge — the merge decision stays with the human after this review.

## Operating rules (do not violate)

- **Read-only, always.** Inspect tasks, branches, and diffs only. Never run
  `task done`/`modify`/`annotate`, never create/checkout/merge/delete branches,
  never `git commit`/`push`/`reset`, never edit the repo. The only file you write
  is the review report under `$DLR_REPORT_DIR` (default `.dev-loop/`, gitignored).
- **Review against intent.** Judge each task's diff against *its own* acceptance
  criteria and summary (recorded by dev-loop), not just generic taste.
- **Don't merge or recommend pushing.** You may recommend follow-up tasks or
  flag blockers; the merge of any review branch is a separate human decision.
- **Diagnostics to stderr; stdout is parseable.** `dlr-collect.sh` emits JSON;
  `dlr-diff.sh` emits the log+diff. Drive the review from those.
- **Branch on exit codes, not prose:** `0` ok · `20` precondition/usage · `30`
  missing-artifact (a task's review branch or base is gone from this checkout).

All scripts live in `scripts/` next to this file, source `dlr-common.sh`, and are
read-only and re-runnable. Run them from inside the target repo checkout. The
exit-code table, env-var table, and troubleshooting are in **reference.md** —
read it when a step fails or you need exact flags.

## Phase 1 — Collect the completed work

Scope to a goal (the dev-loop project slug) by default; fall back to a time
window when no slug is known:

```sh
scripts/dlr-collect.sh <goal-slug>              # every completed task in the goal
scripts/dlr-collect.sh <goal-slug> --since 7d   # …completed in the last 7 days
scripts/dlr-collect.sh --since 24h              # all dev-loop tasks, last 24h
scripts/dlr-collect.sh                          # defaults to --since $DLR_SINCE
```

Emits a JSON array on stdout, one object per task, sorted by completion time:
`{uuid, short, description, project, end, base, branch, commits, summary,
acceptance, reviewable}`. `reviewable` is true when a review branch was recorded
(there is a diff to walk). Capture it once and iterate:

```sh
tasks="$(scripts/dlr-collect.sh <goal-slug>)"
printf '%s' "$tasks" | jq -r '.[] | "\(.short)  [\(if .reviewable then "diff" else "no-branch" end)]  \(.description)"'
```

An empty match is exit `0` with `[]` — report "no completed dev-loop work matched"
and stop.

## Phase 2 — Review each task

For every task in the array, in completion order:

1. **State the intent.** Read `description`, `acceptance`, and `summary` from the
   collected object — this is the bar the change is judged against.
2. **Walk the diff** (only when `reviewable`):

   ```sh
   scripts/dlr-diff.sh "$uuid"               # log + diffstat + full patch
   scripts/dlr-diff.sh "$uuid" --stat-only   # big change: triage by stat first
   scripts/dlr-diff.sh "$uuid" -- -w         # pass extra flags to git diff
   ```

   Review the patch for correctness against the acceptance criteria, regressions,
   missing tests, security issues (the dev-loop rules forbid secrets in the box
   and remote pushes — confirm nothing slipped), and leftover debug/attribution.
3. **Handle a missing artifact.** Exit `30` means the review branch or base is no
   longer in this checkout (deleted after a prior merge, or never fetched). Don't
   fail the whole review: fall back to the `commits=` annotation and review those
   SHAs if they resolve (`git show <sha>`), otherwise note the task as
   "not reviewable from this checkout" and move on.
4. **Record a verdict** per task: one of **ship / nits / changes-requested /
   blocked**, with the concrete findings behind it.

## Phase 3 — Aggregate & deliver

Present the full review **inline** and **save it** to a markdown report:

```sh
mkdir -p "${DLR_REPORT_DIR:-.dev-loop}"
# write the report you composed to:
#   ${DLR_REPORT_DIR:-.dev-loop}/review-<goal-slug>.md
```

Use this structure for both the inline answer and the saved file:

```markdown
# dev-loop review — <goal-slug>  (<n> tasks, <date>)

## Summary
<2–4 lines: what the loop set out to do, what landed, overall health,
the headline blockers if any.>

## Verdict by task
| task | description | branch | verdict | notes |
|------|-------------|--------|---------|-------|
| abc12345 | implement X | review/x | ship | — |
| def67890 | test X | review/x | changes-requested | missing edge-case test |

## Findings
### abc12345 — implement X   (ship)
- intent: <acceptance / summary>
- commits: <base..head (n=N)>
- <finding>, <finding> …

## Cross-cutting observations
<themes spanning tasks: duplicated work, inconsistent patterns, gaps between
tasks, ordering/dependency issues.>

## Recommended next steps
<ordered, concrete: which branches look ready to merge, what to fix first,
suggested follow-up tasks — but do not merge or push anything yourself.>
```

Then tell the user where the report was saved and give them the one-line
merge-review command for any branch you judged ready, e.g.
`git log --oneline <base>..<branch>` / `git diff --stat <base>..<branch>` — and
leave the actual merge to them.

Defer to `task <uuid> info` for anything not in the collected object, and to
dev-loop's own reference for how the annotations got there.
