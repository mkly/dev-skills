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
`dlr-collect.sh` and `dlr-diff.sh` are read-only; `dlr-merge.sh` mutates the
repo/tasks; `dlr-test.sh` mutates nothing in the repo/Taskwarrior but does
create/reuse a Crabbox/Incus lease and a worktree (see below).

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

### `dlr-test.sh <branch> [--keep-box] [--no-sync] [--dry-run] -- <cmd...>`
Run `<cmd...>` against a review branch inside a Crabbox/Incus box — the same
sandbox dev-loop uses for build/test, never the host. Use it when a verdict
needs the test suite/build/lint actually **executed**, not just read via
`dlr-diff.sh`.
- Checks the branch out into a dedicated worktree under `DLR_WORKTREE_DIR`
  (outside the repo tree, reused across calls for the same branch — recreated
  if it drifts from the branch's tip).
- The Crabbox lease is keyed on a **deterministic slug derived from the branch
  name** (`dlrt-<branch>`), not a Taskwarrior uuid: no claim, no annotation, no
  write to the producing task, which is usually already `done` and whose own
  dev-loop box is long stopped. A live lease for that slug is found and reused
  by `crabbox status -id <slug>` alone.
- Forwards `<cmd>`'s exit code **verbatim** — 0/20/30 from `<cmd>` itself do
  not mean ok/precondition/missing; those meanings only apply to failures
  *before* the command runs (bad branch, missing tools).
- Stops the box after the run unless `--keep-box` (pass it to run several
  commands against the same branch without re-warming each time).
- `--no-sync` skips re-uploading the worktree (fast re-run when nothing local
  changed since the last call for this branch).
- Never edits, merges, or pushes anything; never touches the current
  checkout's HEAD or working tree.

### `dlr-common.sh` (sourced, not run)
Shared library: exit-code constants, `dlr_log`/`dlr_warn`/`dlr_err`/`dlr_die`,
`dlr_require`, `dlr_in_git_repo`, `dlr_task_export`, the jq annotation helpers
in `$DLR_JQ_DEFS` (`kv($k)` last-wins / `notes($p)` collect-all),
`dlr_task_for_branch <branch>` (JSON of the producing task, or `null`), and the
Crabbox/Incus env knobs + `dlr_crabbox_incus_flags`, `dlr_repo_key`,
`dlr_worktree_dir_for`, `dlr_slug_for_branch` helpers `dlr-test.sh` uses.

## Environment (`dlr-test.sh` only)

| var                | default                              | meaning                                   |
|--------------------|---------------------------------------|--------------------------------------------|
| `CRABBOX_PROVIDER` | `incus`                                | passed as `crabbox -provider`               |
| `DLR_TEST_TTL`     | `30m`                                  | lease ttl — short-lived, one review check   |
| `INCUS_IMAGE`      | *(unset)*                              | optional `-incus-image` override            |
| `INCUS_TYPE`       | *(unset)*                              | optional `-incus-instance-type` override     |
| `INCUS_REMOTE`     | *(unset)*                              | optional `-incus-remote` override            |
| `DLR_STATE_DIR`    | `$XDG_STATE_HOME/dev-loop-review` (or `~/.local/state/dev-loop-review`) | root for below |
| `DLR_WORKTREE_DIR` | `$DLR_STATE_DIR/worktrees`              | per-branch test checkouts                   |

Names deliberately match dev-loop's own `CRABBOX_PROVIDER`/`INCUS_*` so one
Crabbox config works for both skills; `DLR_STATE_DIR`/`DLR_WORKTREE_DIR` are
kept in a separate namespace from dev-loop's `DEV_LOOP_*` state dir so the two
skills' worktrees never collide.

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

**Actually run the tests for a branch (in the box, not the host):**
```sh
scripts/dlr-test.sh "$branch" -- bash -lc 'pytest -q'
echo "exit: $?"          # 0 → verdict leans clean; nonzero → needs-fixes
```
A fresh box has no Python virtualenv or installed dependencies — a bare
`pytest`/`uv pip install` fails with "No virtual environment found". For a
Python repo, bootstrap one in the same command (`--keep-box` while iterating
so the venv survives across calls instead of being rebuilt every time):
```sh
scripts/dlr-test.sh "$branch" --keep-box \
  -- bash -lc 'uv venv && uv pip install -e .[dev] && pytest -q'
```

**Iterate several checks against one branch without re-warming:**
```sh
scripts/dlr-test.sh "$branch" --keep-box -- bash -lc 'make build'
scripts/dlr-test.sh "$branch"             -- bash -lc 'pytest -q'   # last call: no --keep-box, box stops
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
  skill needs `task`, `jq`, and `git` (`dlr-test.sh` also needs `crabbox`).
- **`dlr-test.sh` exits `30` "review branch … is not present locally".** Same
  meaning as elsewhere: the branch was deleted or never fetched. Re-run
  `dlr-collect.sh` to see what's actually available.
- **`dlr-test.sh` exits `20` "could not create worktree … (checked out
  elsewhere?)".** Two working trees can't hold the same branch at once. Find
  the other checkout with `git worktree list` and remove/finish it, or wait
  for whatever else is using it.
- **Command fails with "No virtual environment found" / bare `uv pip install`
  errors.** The box starts with no Python venv or dependencies installed —
  there's no bootstrap hook, so prefix the wrapped command with
  `uv venv && uv pip install -e .[dev] &&` (see the recipe above). Use
  `--keep-box` while iterating so the venv isn't rebuilt on every call.
- **`dlr-test.sh` exits `20` "crabbox warmup failed".** The stderr above the
  error is crabbox's own output — treat it like any other `crabbox warmup`
  failure (provider/image/remote misconfigured, Incus not reachable, quota).
  Check the same env vars dev-loop's `dl-box.sh` troubleshooting covers
  (`CRABBOX_PROVIDER`, `INCUS_IMAGE`, `INCUS_TYPE`, `INCUS_REMOTE`).
- **`dlr-test.sh` exits `20` "could not resolve a live box handle after
  warmup".** `crabbox warmup` reported success but its output didn't contain a
  recognizable `cbx_…` handle and `crabbox status -id <slug>` still can't see
  it. Run `crabbox status -provider "$CRABBOX_PROVIDER" -id dlrt-<branch-slug>`
  by hand to inspect it.
- **`dlr-test.sh`'s command exits `20` or `30` itself.** That's the wrapped
  command's own exit code forwarded verbatim, not a `dlr-test.sh` failure —
  don't confuse it with the precondition/missing-artifact codes above.
- **A box from `dlr-test.sh` is still running.** Leases use `-label
  dev-loop-review/<branch>` and `-keep -keep-on-failure`, so a failed or
  `--keep-box` run leaves it up on purpose. List/stop by hand:
  `crabbox status -provider "$CRABBOX_PROVIDER" -id dlrt-<branch-slug>` /
  `crabbox stop -provider "$CRABBOX_PROVIDER" -id dlrt-<branch-slug>`.
