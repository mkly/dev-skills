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
| `reviewer=<owner>#<nonce>` | independent reviewer lock; latest value wins |
| `review-start=<timestamp>` | reviewer claim time used for explicit stale takeover |

Completion writes:

| State | Meaning |
|---|---|
| `dev-complete-task: merged ...` | audit note from `dlc-merge.sh` |
| `dev-complete-task: review claimed ...` | reviewer lock lifecycle audit |
| `dev-loop: completed outcome=<value> ...` | terminal lifecycle event from `dlc-done.sh` |
| `review-fix: <finding>` | finding the reviewer repaired on the review branch instead of filing |
| `review-of: <short> <branch>` | follow-up task points to its reviewed producer |

`dlc-done.sh` clears the `plan` UDA on `--outcome merged` only; `stacked` and
`superseded` keep it so a preserved review branch's successor can still read it.

Keep machine annotations stable for compatibility with tasks created by the
former skill layout.

## Exit codes

| Code | Meaning | Response |
|---:|---|---|
| `0` | success, including an empty collection | continue |
| `10` | review is unclaimed or held by another reviewer agent | stop; release or explicitly steal only a stale review claim |
| `20` | usage, missing tool, dirty checkout, or failed precondition | correct the precondition; apply `dev-ask` when environmental |
| `30` | missing branch/base | restore or fetch the artifact; do not guess |
| `40` | merge conflict awaiting resolution | resolve the listed paths, stage them, re-run `dlc-merge.sh --continue` |

Once `dlc-test.sh` starts the requested command, it forwards that command's exit
code verbatim, including values that happen to equal `20`, `30`, or `40`.

## Scripts

| Script | Arguments | stdout | Mutation |
|---|---|---|---|
| `dlc-collect.sh` | `[--from-task <task-ref>]` | JSON branch array | none |
| `dlc-claim.sh` | `<task-ref> [--steal-after <dur>] [--standard\|--small\|--large\|--plan]` | exact task UUID | reviewer annotations only |
| `dlc-release.sh` | `<task-ref>` | none | clears current reviewer annotations |
| `dlc-diff.sh` | `<branch> [--stat-only] [-- <git flags>]` | log/diff | none |
| `dlc-test.sh` | `<branch> [--compact] [--keep-box] [--no-sync] [--dry-run] -- <cmd...>` | command output | temporary worktree/lease only |
| `dlc-merge.sh` | `<branch> [--dry-run\|--continue\|--abort]` | resulting HEAD | local merge (conflicts left in progress for resolution), safe branch delete, audit annotation |
| `dlc-done.sh` | `<uuid> --outcome <merged\|stacked\|superseded> [--stop-box] [--keep-worktree] [--force] [--dry-run]` | none | task completion and implementation-resource cleanup |

All diagnostics go to stderr. `dlc-collect.sh` and `dlc-diff.sh` are read-only.
Diff, test, merge, and finalization require the caller's exact reviewer claim.
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
| `DEV_LOOP_ROUTE` | unset (→ the untagged standard queue) | routing queue (`standard`, `small`, `large`, `plan`) exported by `loop`. `dlc-claim.sh` applies the same predicate as `dl-claim.sh`, so the queue that implemented a task is the queue that reviews it; an explicit `--standard`/`--small`/`--large`/`--plan` overrides it, and any other value is a precondition error (`20`). |

`DLC_STATE_DIR/locks/review-select.lock` serializes reviewer claims on one host.
The durable `reviewer=` annotation and exact readback detect lost Taskwarrior
writes; as with implementation claims, TaskChampion sync is not a distributed
mutex across replicas.

`dlc-done.sh` also honors the implementation harness's `DEV_LOOP_OWNER`,
`DEV_LOOP_STATE_DIR`, `DEV_LOOP_WORKTREE_DIR`, and provider settings. The
reviewer does **not** need to be the implementer: any worker may acquire the
separate reviewer lock, while a different implementer is recorded as a
`completion handoff from <owner>` annotation.

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

The nested task includes `reviewer` and `review_started`. Inspect these before
selection, then arbitrate the final choice with `dlc-claim.sh`; collection alone
does not reserve a task.

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
scripts/dlc-claim.sh "$uuid"
scripts/dlc-diff.sh "$branch"
scripts/dlc-diff.sh "$branch" --stat-only
scripts/dlc-diff.sh "$branch" -- -w
```

The helper uses recorded `base=` when it resolves, otherwise the merge base of
the current integration HEAD and branch. Exit `10` if this agent no longer owns
the reviewer claim.

### Release an abandoned review

```sh
scripts/dlc-release.sh "$uuid"
```

Do this only before a terminal verdict. A crash leaves the durable claim in
place; another reviewer may use `dlc-claim.sh "$uuid" --steal-after 4h` after
verifying the recorded age and current agent state.

### Run isolated verification

```sh
scripts/dlc-test.sh "$branch" --compact -- bash -lc 'pytest -q'
scripts/dlc-test.sh "$branch" --keep-box -- bash -lc 'make build'
```

Run last, after the diff review clears — the suite takes 10+ minutes and is
almost always green, so it's a final gate, not a way to find problems. Skip it
if a major blocker already routes the branch to Findings.

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
branch.

### Resolve a conflicting merge

A conflict does not fail the review. The helper leaves the merge in progress,
prints the conflicted paths, and exits `40`:

```sh
scripts/dlc-merge.sh "$branch"            # exit 40, merge in progress
git diff --name-only --diff-filter=U      # the same conflicted paths
# resolve each path, preserving both sides' intent
git add <paths>
scripts/dlc-merge.sh "$branch" --continue # commits the merge, deletes the branch
scripts/dlc-done.sh "$uuid" --outcome merged
```

`--continue` refuses (exit `40`) while any path is still unmerged or a staged
file still carries `<<<<<<<`/`>>>>>>>` markers. Re-run the acceptance checks with
`dlc-test.sh` when the resolution changed behavior rather than adjacent lines;
the branch is gone after `--continue`, so test the integration branch itself.

Reserve `scripts/dlc-merge.sh "$branch" --abort` for conflicts that genuinely
cannot be reconciled in the integration checkout — the branch needs
reimplementation against the new base. It backs the merge out, keeps the branch,
and the producer then goes to Findings with a rebase/reimplement fix task.

### Fix a finding instead of filing it

This is the default path for every finding that is not a major blocker;
SKILL.md decides that, and this is the mechanics. The fix goes on the
review branch before the merge, in the branch's verification worktree
(`$DLC_WORKTREE_DIR/<branch slug>`, logged by `dlc-test.sh` on every run):

```sh
scripts/dlc-test.sh "$branch" --compact -- bash -lc '<acceptance command>'
wt=<path from the "test worktree for <branch>" log line>
# edit under "$wt"
git -C "$wt" commit -am "fix: <finding> (review of ${uuid:0:8})"
scripts/dlc-test.sh "$branch" --compact -- bash -lc '<acceptance command>'
task rc.confirmation=no annotate "$uuid" "review-fix: <finding>"
scripts/dlc-merge.sh "$branch"
scripts/dlc-done.sh "$uuid" --outcome merged
task rc.confirmation=no sync
```

The worktree is checked out on the branch, so committing there moves the branch
tip and `dlc-test.sh` still treats the worktree as fresh, syncs it, and re-runs
the checks in a box. Repeat the edit/commit/verify cycle for as many commits as
the fixes need. The extra commits sit outside the recorded `commits=` range and
do not disturb finalization: `outcome=merged` checks that the recorded
implementation head is an ancestor of HEAD, not that it equals HEAD.

Do not fix in the integration checkout after the merge — `dlc-test.sh` requires
a review branch with a producing task, so a post-merge commit has no supported
way to be verified in a box, and acceptance checks never run on the host. If a
fix turns into a major blocker, `git -C "$wt" reset --hard <recorded head>` and
file a follow-up task instead.

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
| `dlc-claim.sh` exits `10` | Another reviewer owns the task. Do not inspect or dispose it; wait for release or use explicit stale takeover when justified. |
| Producer is active under another assignee | Expected after implementation handoff. The separate reviewer claim, not `assignee`, controls review disposition. |
| Dirty integration checkout | Preserve the user's changes. Commit/stash only with authorization, then retry completion. |
| `dlc-diff.sh` cannot resolve the base | Restore/fetch the recorded base or review against a deliberately selected merge base; do not guess silently. |
| Verification worktree already holds the branch | Reuse/remove it through `dlc-test.sh`; do not delete an unrelated worktree. |
| Verification box fails to warm twice | Apply `dev-ask`; do not run the acceptance command on the host. |
| `dlc-merge.sh` exits `40` on conflict | The merge is still in progress and the paths are listed. Resolve them, `git add`, and re-run with `--continue`; this is not a review finding. |
| `dlc-merge.sh` says a merge is already in progress | An earlier conflicted merge was never finished. Resolve and `--continue`, or `--abort` to back it out. |
| `--continue` reports leftover conflict markers | A staged file still contains `<<<<<<<`/`>>>>>>>`. Finish the resolution in the listed files and stage them again. |
| `dlc-done.sh` cannot locate `dl-common.sh` | Install skills as siblings or set `DEV_IMPLEMENT_TASK_SKILL_DIR`. |
| `dlc-done.sh` reports an invalid outcome | Use exactly `merged`, `stacked`, or `superseded`. |
| `outcome=merged` says the review branch still exists | Run `dlc-merge.sh` first; finalization also verifies the recorded implementation head is integrated. |
| `outcome=stacked` or `superseded` says the branch is missing | Restore the recorded review branch before completing; it is required as the successor's input. |
| Final sync fails | Preserve local task/branch state and apply `dev-ask`; do not report durable handoff or success. |
| Branch remains after a merged chain tip | It is an already-merged ancestor. Run `dlc-merge.sh <branch>` for safe cleanup. |
