# dev-loop-review — reference

Deep reference for the `dev-loop-review` skill: exit codes, each script's
contract, recipes, and troubleshooting. The day-to-day workflow is in
**SKILL.md**; read this when a step fails or you need exact flags.

This skill turns dev-loop's output branches into **actions**: it enumerates the
available local `review/*` branches, reviews each diff against its producing
task's intent, and then either files fix tasks (findings) or merges the branch
into the current branch and deletes it (clean). It never pushes to a remote and
never writes a report file.

## How it relates to dev-loop

dev-loop, when it finishes a task, leaves one local review branch and a durable
trail on the producing Taskwarrior task via annotations:

| annotation          | style       | written by         | meaning                                    |
|---------------------|-------------|--------------------|--------------------------------------------|
| `base=<sha>`        | `key=value` | `dl-box.sh`        | worktree root = the review diff base       |
| `branch=<name>`     | `key=value` | `dl-merge-back.sh` | the local review branch created            |
| `commits=<r> (n=N)` | `key=value` | `dl-merge-back.sh` | `<base12>..<head12>` range + commit count  |
| `summary: …`        | `prefix:`   | agent (Phase 5)    | human note: what changed and why           |
| `acceptance: …`     | `prefix:`   | agent (Phase 1)    | how the task is judged done                |

`key=value` annotations are read **last-wins**; `prefix:` notes are **all
collected**. This skill reads that trail to find each branch's producing task —
but the work queue itself is **git**: only branches that actually exist locally
are reviewed. A `branch=` annotation whose branch is gone (already merged and
deleted) is simply not in the queue.

This skill in turn writes annotations dev-loop consumes:

| annotation                    | written by            | consumed by                                  |
|-------------------------------|-----------------------|----------------------------------------------|
| `acceptance: …` (on fix task) | agent (Phase 3)       | the next dev-loop run / this skill next time |
| `input: <branch>` (on fix task) | agent (Phase 3)     | `dl-box.sh` — roots the fix worktree at the reviewed branch |
| `review-of: <short> <branch>` (on fix task) | agent (Phase 3) | humans tracing a fix back to its review |
| `dev-loop-review: merged …` (on producer) | `dlr-merge.sh` | audit trail of what landed where          |

## Exit codes

The stable contract the agent branches on:

| code | name         | meaning                                                              |
|------|--------------|----------------------------------------------------------------------|
| `0`  | ok           | success; a query that legitimately matches nothing is also `0`       |
| `20` | precondition | missing tool, not in a git repo, dirty worktree, detached HEAD, bad usage |
| `30` | missing/conflict | branch or diff base not present locally, or the merge conflicted |

`30` from `dlr-merge.sh` on a conflict is recoverable and expected: the merge
is aborted, the branch is kept, and the right response is a fix task
(`input: <branch>`) asking for a rebase/conflict resolution.

## Scripts at a glance

All in `scripts/`, sourced from `dlr-common.sh`, re-runnable. Each prints
diagnostics to **stderr** and its machine-parseable payload to **stdout**.
`dlr-collect.sh` and `dlr-diff.sh` are read-only; only `dlr-merge.sh` mutates.

### `dlr-collect.sh [<project-slug>]`
Enumerate the available local review branches. Candidate set =
`refs/heads/review/*` ∪ every `branch=` annotation value that still resolves to
a local branch; each is reverse-mapped to its producing task (any status).
Emits a JSON array on stdout, sorted by branch name:
`{branch, merged, ahead, superseded, superseded_by, base, task}` where `task`
is `{uuid, short, description, project, status, end, base, commits, summary,
acceptance}` or `null` (ORPHAN — no task records the branch).
- `merged` = branch tip is an ancestor of HEAD (landed; just clean up).
- `ahead` = `git rev-list --count HEAD..branch`.
- `superseded` = another (non-deleted) task records this branch as its latest
  `input:` — a fix builds on top of it. Don't merge or re-review it on its own;
  `superseded_by` is that task's short uuid (`""` otherwise).
- `base` = the task's `base=` if it still resolves, else
  `git merge-base HEAD branch`, else `""`.
- With a slug → only branches whose producing task is in `project:<slug>`
  (orphans are excluded, since their project is unknown).
- No branches → exit `0`, body `[]`. Counts go to stderr.

### `dlr-diff.sh <branch> [--stat-only] [-- <git diff flags>]`
Print one branch's review diff: a producing-task header, the commit log
(`git log --oneline base..branch`), the diffstat, and the full patch. The base
resolves like `dlr-collect.sh`'s. Read-only (never checks out).
- `--stat-only` skips the full patch (triage a large change first).
- `-- <flags>` forwards extra flags to `git diff` (e.g. `-w`, `-M`).
- Exit `30` if the branch is absent locally or no diff base can be determined.

### `dlr-merge.sh <branch> [--dry-run]`
Merge a **clean** review branch into the current branch, delete it
(`git branch -d` — safe delete only), and annotate the producing task
(`dev-loop-review: merged … ; branch deleted`, best-effort). Local only; the
merge commit keeps git's default message (no attribution trailers). Prints the
resulting HEAD sha on stdout.
- Already-merged branch → skips the merge, just deletes (use it for cleanup).
- Dirty worktree, detached HEAD, or `<branch>` checked out → exit `20`,
  nothing changed.
- Merge conflict → `git merge --abort`, branch kept, exit `30`.
- `--dry-run` reports the plan and changes nothing.

### `dlr-common.sh` (sourced, not run)
Shared library: exit-code constants, `dlr_log`/`dlr_warn`/`dlr_err`/`dlr_die`,
`dlr_require`, `dlr_in_git_repo`, `dlr_task_export`, the jq annotation helpers
in `$DLR_JQ_DEFS` (`kv($k)` last-wins / `notes($p)` collect-all), and
`dlr_task_for_branch <branch>` (JSON of the producing task, or `null`).

## Recipes

**Review a whole goal end-to-end:**
```sh
slug=my-goal
branches="$(scripts/dlr-collect.sh "$slug")"
printf '%s' "$branches" | jq -r '.[] | "\(.branch)  \(if .merged then "MERGED" elif .superseded then "SUPERSEDED by \(.superseded_by)" else "+\(.ahead)" end)  \(.task.description // "ORPHAN")"'
for b in $(printf '%s' "$branches" | jq -r '.[] | select((.merged or .superseded) | not) | .branch'); do
  scripts/dlr-diff.sh "$b"        # review each; verdict: clean | needs-fixes
done
# clean → scripts/dlr-merge.sh "$b"
# needs-fixes → task add … (see SKILL.md Phase 3)
```

**File a fix task for a finding (dev-loop conventions):**
```sh
task add project:"$slug" "fix: <one concrete finding>"
fix="$(task +LATEST uuids)"
task "$fix" annotate "acceptance: <how we know it's fixed>"
task "$fix" annotate "input: $branch"
task "$fix" annotate "review-of: <producer-short> $branch"
```

**Clean up branches that already landed:**
```sh
scripts/dlr-collect.sh | jq -r '.[] | select(.merged) | .branch' \
  | while read -r b; do scripts/dlr-merge.sh "$b"; done
```

**Triage a large branch, then read the full patch:**
```sh
scripts/dlr-diff.sh "$branch" --stat-only
scripts/dlr-diff.sh "$branch"
```

**Inspect the producing task directly (anything not in the collected object):**
```sh
task <uuid> info
```

## Troubleshooting

- **`dlr-collect.sh` prints `[]`.** No local `review/*` branches exist and no
  `branch=` annotation resolves to one — the loop's output has all been merged
  and deleted, or dev-loop never ran merge-back here. Confirm with
  `git branch --list 'review/*'` and dev-loop's `dl-status.sh` (its Review
  branches section shows `GONE` entries for merged-and-deleted branches).
- **A branch shows `task: null` (ORPHAN).** No task records it — the annotation
  was lost or the branch was made by hand. Review it against generic quality;
  ask the user for a project before filing fix tasks.
- **`dlr-diff.sh` exits `30` "cannot determine a diff base".** The recorded
  base is gone and the branch shares no history with HEAD (e.g. rebased away).
  Review the branch's own commits directly (`git log -p <branch>`), or use the
  producing task's `commits=` range if those SHAs still resolve.
- **`dlr-merge.sh` exits `20` "worktree is dirty".** Commit or stash local
  changes first — the script refuses to merge over uncommitted work.
- **`dlr-merge.sh` exits `30` "merge … conflicts".** The merge was aborted and
  the branch kept. File a fix task ("rebase `<branch>` onto `<current>` and
  resolve conflicts") with `input: <branch>`, and move on.
- **`git branch -d` refused (branch not fully merged).** Should not happen
  right after a successful merge; if it does, something moved HEAD between the
  merge and the delete — re-run `dlr-merge.sh` (already-merged branches are
  delete-only).
- **`exit 20` "not inside a git repository".** Run from inside the target repo
  checkout (the same place dev-loop ran).
- **`exit 20` "missing required command(s)".** Install the named tool; this
  skill needs `task`, `jq`, and `git`.
