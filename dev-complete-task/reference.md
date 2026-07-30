# dev-complete-task — reference

Use this reference for helper flags, state interchange, and failure recovery.
Keep the target repository's integration checkout as the current directory.

## Contents

- [Lifecycle interchange](#lifecycle-interchange)
- [Exit codes](#exit-codes)
- [Scripts](#scripts)
- [Environment](#environment)
- [Recipes](#recipes)
- [Troubleshooting](#troubleshooting)

## Lifecycle interchange

`dev-implement-task` records the state completion consumes:

| Annotation | Meaning |
|---|---|
| `base=<sha>` | implementation diff base |
| `worktree=<path>` | owned task worktree to clean after verdict |
| `box=<handle>` | implementation lease to park or stop |
| `branch=<name>` | local review branch |
| `commits=<range> (n=N)` | implementation commit range |
| `acceptance: ...` | observable completion criteria |
| `summary: ...` | implementation summary and checks |
| `input: <ref>` | predecessor branch for stacked work |
| `repo-id: ...` | canonical GitHub owner/repository |
| `goal: ...` | human-readable goal slug |
| `loop-id: ...` | exact controller-run UUID |
| `loop-round: <n>` | wrapper round |
| `plan: <producer-uuid>` | hop to a producer's `plan` UDA when this task carries none of its own |

Completion writes:

| State | Meaning |
|---|---|
| `dev-complete-task: merged ...` | audit note from `dlc-merge.sh` |
| `dev-loop: completed outcome=<value> ...` | terminal lifecycle event from `dlc-done.sh` |
| `review-of: <short> <branch>` | follow-up task points to its reviewed producer |

`dlc-done.sh` clears the `plan` UDA on `--outcome merged` only; `stacked` and
`superseded` keep it so a preserved review branch's successor can still read it.

Keep machine annotations stable for compatibility with tasks created by the
former skill layout.

## Exit codes

| Code | Meaning | Response |
|---:|---|---|
| `0` | success, including an empty collection | continue |
| `10` | completion finalizer found another owner | stop or obtain explicit takeover authorization |
| `20` | usage, missing tool, dirty checkout, or failed precondition | correct the precondition; apply `dev-ask` when environmental |
| `30` | missing branch/base or merge conflict | preserve the branch and treat it as a finding |

Once `dlc-test.sh` starts the requested command, it forwards that command's exit
code verbatim, including values that happen to equal `20` or `30`.

## Scripts

| Script | Arguments | stdout | Mutation |
|---|---|---|---|
| `dlc-collect.sh` | `[--from-task <task-ref>]` | JSON branch array | none |
| `dlc-diff.sh` | `<branch> [--stat-only] [-- <git flags>]` | log/diff | none |
| `dlc-test.sh` | `<branch> [--compact] [--keep-box] [--no-sync] [--dry-run] -- <cmd...>` | command output | temporary worktree/lease only |
| `dlc-merge.sh` | `<branch> [--dry-run]` | resulting HEAD | local merge, safe branch delete, audit annotation |
| `dlc-done.sh` | `<uuid> --outcome <merged\|stacked\|superseded> [--stop-box] [--keep-worktree] [--force] [--dry-run]` | none | task completion and implementation-resource cleanup |

All diagnostics go to stderr. `dlc-collect.sh` and `dlc-diff.sh` are read-only.
No helper pushes or force-deletes an unmerged review branch.

## Environment

Review testing uses a branch-keyed namespace so it cannot collide with the
producer task's implementation lease:

| Variable | Default | Purpose |
|---|---|---|
| `CRABBOX_PROVIDER` | `incus` | provider passed to every Crabbox call |
| `DLC_TEST_TTL` | `30m` | verification lease TTL |
| `DLC_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/dev-complete-task` | completion test state |
| `DLC_WORKTREE_DIR` | `${DLC_STATE_DIR}/worktrees` | branch verification worktrees |
| `INCUS_IMAGE` | unset | optional warmup image |
| `INCUS_TYPE` | unset | optional `container` or `vm` |
| `INCUS_REMOTE` | unset | optional Incus remote |
| `DEV_IMPLEMENT_TASK_SKILL_DIR` | sibling `../dev-implement-task` | installed implementation skill used by `dlc-done.sh` |

`dlc-done.sh` also honors the implementation harness's `DEV_LOOP_OWNER`,
`DEV_LOOP_STATE_DIR`, `DEV_LOOP_WORKTREE_DIR`, and provider settings. The
completing worker does **not** need to be the one that implemented the task —
review-ready work is claimable by any worker, and a different implementer is
recorded as a `completion handoff from <owner>` annotation.

## Recipes

### Collect one controller loop's branches

```sh
all="$(scripts/dlc-collect.sh --from-task "$uuid")"
obj="$(printf '%s' "$all" | jq --arg uuid "$uuid" \
  '[.[] | select(.task.uuid == $uuid)] | if length == 1 then .[0] else empty end')"
```

Each object contains:

```text
{branch, merged, ahead, superseded, superseded_by, base, task}
```

Git is ground truth for branch existence. With `--from-task`, the helper derives
the repository identity from the current GitHub origin and the goal/loop
identity from that producer; callers never supply a project name. Taskwarrior
annotations provide producer intent. `superseded` means another non-deleted task
with the same repository, goal, and loop identity names the branch as its
`input:`; do not merge that branch independently.

An orphan branch has `task: null`. Review it only with explicit project/intent
from the user; it cannot be completed as a Taskwarrior producer automatically.

### Inspect a branch

```sh
scripts/dlc-diff.sh "$branch"
scripts/dlc-diff.sh "$branch" --stat-only
scripts/dlc-diff.sh "$branch" -- -w
```

The helper uses recorded `base=` when it resolves, otherwise the merge base of
the current integration HEAD and branch.

### Run isolated verification

```sh
scripts/dlc-test.sh "$branch" --compact -- bash -lc 'pytest -q'
scripts/dlc-test.sh "$branch" --keep-box -- bash -lc 'make build'
```

The helper checks out the branch in a dedicated external worktree, warms a
short-lived lease, syncs tracked files, and forwards the command exit code. It
does not reuse or mutate the producer's task box. `--compact` uses in-box RTK
when available and otherwise runs the raw command with a warning.

### Merge a clean branch

```sh
scripts/dlc-merge.sh "$branch" --dry-run
scripts/dlc-merge.sh "$branch"
scripts/dlc-done.sh "$uuid" --outcome merged
task rc.confirmation=no sync
```

The merge helper requires a clean, attached integration checkout. If the branch
is already an ancestor of HEAD, it skips the merge and safely deletes the
branch. On conflict it aborts, keeps the branch, and exits `30`.

### Finalize a planned stack predecessor

Verify a pending consumer depends on the producer and has
`input: <producer-branch>`, then:

```sh
scripts/dlc-done.sh "$uuid" --outcome stacked
task rc.confirmation=no sync
```

The branch stays available for the consumer. After the chain tip merges, earlier
branches become ancestors of HEAD; run `dlc-merge.sh` on each to delete them
safely.

### Queue findings and supersede the producer

Create the first follow-up through `dev-create-tasks`:

```sh
fix="$(/path/to/dev-create-tasks-skill/scripts/dct-create.sh \
  --from-task "$uuid" \
  --description 'fix: <finding>' \
  --acceptance '<proof>' \
  --depends "$uuid" \
  --input "$branch" \
  --review-of "${uuid:0:8} $branch" \
  --loop-round "$next_round")"
task rc.confirmation=no sync
scripts/dlc-done.sh "$uuid" --outcome superseded
task rc.confirmation=no sync
```

Keep the review branch. The dependency prevents another agent from claiming the
fix before the producer is finalized. Chain overlapping fixes by depending on
the previous fix and using its predicted review branch as the next input.

### Recover an interrupted completion

Inspect, in order:

```sh
task "$uuid" export | jq '.[0]'
git branch --list 'review/*'
/path/to/dev-implement-task-skill/scripts/dl-status.sh
```

Re-run the idempotent helper that owns the first incomplete boundary. Never
recreate a deleted review branch by guessing its contents.

## Troubleshooting

| Symptom | Cause and response |
|---|---|
| `dlc-collect.sh` returns `[]` | No resolving branch matches the producer's exact repository, goal, and loop identity. Inspect task identity, `branch=`, and local refs. |
| Producer is active but owned by someone else | Do not finalize it. Ask that owner to complete/release it or obtain explicit takeover authorization. |
| Dirty integration checkout | Preserve the user's changes. Commit/stash only with authorization, then retry completion. |
| `dlc-diff.sh` cannot resolve the base | Restore/fetch the recorded base or review against a deliberately selected merge base; do not guess silently. |
| Verification worktree already holds the branch | Reuse/remove it through `dlc-test.sh`; do not delete an unrelated worktree. |
| Verification box fails to warm twice | Apply `dev-ask`; do not run the acceptance command on the host. |
| `dlc-merge.sh` exits `30` on conflict | Merge was aborted and the branch preserved. Create a conflict-resolution task rooted on that branch. |
| `dlc-done.sh` cannot locate `dl-common.sh` | Install skills as siblings or set `DEV_IMPLEMENT_TASK_SKILL_DIR`. |
| `dlc-done.sh` reports an invalid outcome | Use exactly `merged`, `stacked`, or `superseded`. |
| `outcome=merged` says the review branch still exists | Run `dlc-merge.sh` first; finalization also verifies the recorded implementation head is integrated. |
| `outcome=stacked` or `superseded` says the branch is missing | Restore the recorded review branch before completing; it is required as the successor's input. |
| Final sync fails | Preserve local task/branch state and apply `dev-ask`; do not report durable handoff or success. |
| Branch remains after a merged chain tip | It is an already-merged ancestor. Run `dlc-merge.sh <branch>` for safe cleanup. |
