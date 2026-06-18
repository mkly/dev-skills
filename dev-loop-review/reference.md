# dev-loop-review — reference

Deep reference for the `dev-loop-review` skill: exit codes, environment knobs,
each script's contract, recipes, and troubleshooting. The day-to-day workflow is
in **SKILL.md**; read this when a step fails or you need exact flags.

This skill is **read-only**. It inspects completed dev-loop tasks and their local
review branches and writes exactly one thing: the markdown review report under
`$DLR_REPORT_DIR`. It never touches Taskwarrior state, branches, or your repo.

## How it relates to dev-loop

dev-loop, when it finishes a task, leaves a durable trail on the **completed**
Taskwarrior task via annotations:

| annotation        | style       | written by        | meaning                                   |
|-------------------|-------------|-------------------|-------------------------------------------|
| `base=<sha>`      | `key=value` | `dl-box.sh`       | HEAD when the box was warmed = diff base  |
| `branch=<name>`   | `key=value` | `dl-merge-back.sh`| the local review branch created           |
| `commits=<r> (n=N)` | `key=value` | `dl-merge-back.sh`| `<base12>..<head12>` range + commit count |
| `summary: …`      | `prefix:`   | agent (Phase 5)   | human note: what changed and why          |
| `acceptance: …`   | `prefix:`   | agent (Phase 1)   | how the task is judged done               |

`key=value` annotations are read **last-wins** (the latest value of a key);
`prefix:` notes are **all collected**. This skill only *reads* these — it relies
on dev-loop having written them. Tasks without `branch=`/`commits=` are treated as
non–dev-loop (filtered out when scanning by time window with no slug).

## Exit codes

The stable contract the agent branches on:

| code | name        | meaning                                                            |
|------|-------------|--------------------------------------------------------------------|
| `0`  | ok          | success; a query that legitimately matches nothing is also `0`     |
| `20` | precondition| missing tool, not in a git repo, bad usage/args, or no such task   |
| `30` | missing-artifact | a task's review branch or base is not present in this checkout|

`30` is expected and recoverable: review branches are local and may have been
merged-and-deleted, or the base may have been pruned/rebased away. Fall back to
the `commits=` SHAs (`git show <sha>`) or note the task as not reviewable here.

## Environment knobs

| var              | default     | effect                                                       |
|------------------|-------------|--------------------------------------------------------------|
| `DLR_SINCE`      | `7d`        | default time window for `--since` and for a bare collect call|
| `DLR_REPORT_DIR` | `.dev-loop` | directory the saved markdown report is written to (gitignored)|

Durations are passed straight to Taskwarrior as `end.after:now-<dur>`, so any
Taskwarrior duration works: `90m`, `2h`, `24h`, `7d`, `1w`, `1mo`.

## Scripts at a glance

All in `scripts/`, sourced from `dlr-common.sh`, read-only, re-runnable. Each
prints diagnostics to **stderr** and its machine-parseable payload to **stdout**.

### `dlr-collect.sh [<project-slug>] [--since <dur>]`
Enumerate completed dev-loop tasks and their review artifacts. Emits a JSON array
on stdout, one object per task, sorted by completion time:
`{uuid, short, description, project, end, base, branch, commits, summary,
acceptance, reviewable}`.
- With a slug → every completed task in `project:<slug>`.
- `--since <dur>` adds an `end.after:now-<dur>` window (combinable with a slug).
- No slug → defaults to `--since $DLR_SINCE` **and** filters to tasks that carry
  dev-loop annotations (`branch=`/`commits=`), so unrelated tasks are excluded.
- `reviewable` = a `branch=` was recorded (there is a diff to walk).
- Empty match → exit `0`, body `[]`. Match counts go to stderr.

### `dlr-diff.sh <uuid> [--stat-only] [-- <git diff flags>]`
Resolve one task's `base=`/`branch=` and print, to stdout: the commit log
(`git log --oneline base..branch`), the diffstat, and the full patch. Read-only
(`git log`/`git diff` only; never checks out).
- `--stat-only` skips the full patch (triage a large change first).
- `-- <flags>` forwards extra flags to `git diff` (e.g. `-w`, `-M`).
- Exit `30` if the task has no `branch=`, the branch is absent locally, no
  `base=`, or the base commit is missing locally — message says which.

### `dlr-common.sh` (sourced, not run)
Shared library: exit-code constants, `dlr_log`/`dlr_warn`/`dlr_err`/`dlr_die`,
`dlr_require`, `dlr_in_git_repo`, `dlr_task_export`, and the annotation readers
`dlr_anno_kv <key>` / `dlr_anno_notes <prefix>` (both read a task's exported JSON
on stdin).

## Recipes

**Review a whole goal, save the report:**
```sh
slug=my-goal
tasks="$(scripts/dlr-collect.sh "$slug")"
printf '%s' "$tasks" | jq -r '.[] | "\(.short)  \(.description)"'
for u in $(printf '%s' "$tasks" | jq -r '.[] | select(.reviewable) | .uuid'); do
  scripts/dlr-diff.sh "$u"        # review each
done
mkdir -p "${DLR_REPORT_DIR:-.dev-loop}"
# …compose and write ${DLR_REPORT_DIR:-.dev-loop}/review-$slug.md
```

**Just the recent work, no slug:**
```sh
scripts/dlr-collect.sh --since 24h | jq -r '.[] | "\(.end)  \(.short)  \(.description)"'
```

**Triage a large task, then read the full patch:**
```sh
scripts/dlr-diff.sh "$uuid" --stat-only
scripts/dlr-diff.sh "$uuid"
```

**Fall back to commit SHAs when the branch is gone (exit 30):**
```sh
range="$(scripts/dlr-collect.sh "$slug" | jq -r --arg u "$uuid" '.[] | select(.uuid==$u) | .commits')"
# range looks like "abc123abc123..def456def456 (n=3)"; review the SHAs directly:
git show "${range%% *}"     # or: git log -p ${range%% *}
```

**Inspect a completed task directly (anything not in the collected object):**
```sh
task <uuid> info
task status:completed project:<slug> export | jq .
```

## Troubleshooting

- **`dlr-collect.sh` prints `[]`.** Nothing matched. Check the slug
  (`task projects`), widen `--since`, or confirm the tasks are actually completed
  (`task status:completed count`). Note plain `task status:completed` shows
  nothing because the default report implies `status:pending`; use
  `task all status:completed`, `task completed`, or `… export`.
- **Task shows but `reviewable:false`.** No `branch=` annotation — dev-loop's
  merge-back never produced a review branch for it (e.g. a test-only task, or
  merge-back exited `30`/`20`). Review via `commits=` if present, else note it.
- **`dlr-diff.sh` exits `30` "branch not present locally".** The review branch
  was deleted after a merge, or this checkout never fetched it. Use the `commits=`
  SHAs (recipe above) or review on the checkout that still has the branch.
- **`dlr-diff.sh` exits `30` "base commit not present".** The base was pruned or
  rebased away. The `commits=` annotation still records the original range;
  resolve the SHAs if they exist, otherwise the diff can't be reconstructed here.
- **`exit 20` "not inside a git repository".** Run from inside the target repo
  checkout (the same place dev-loop ran).
- **`exit 20` "missing required command(s)".** Install the named tool; this skill
  needs `task`, `jq`, and `git`.
