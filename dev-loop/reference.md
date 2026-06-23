# dev-loop — reference

Verbatim recipes, the environment-variable table, the exit-code contract, and
troubleshooting. SKILL.md is the lean workflow; read this when a step fails or
you need exact behavior. All scripts are in `scripts/`, source `dl-common.sh`,
use `set -euo pipefail`, send diagnostics to stderr, and accept `--dry-run` on
mutating operations.

## Exit-code contract

Every script uses this set so callers branch on the code, not on prose:

| Code | Name        | Meaning                                                            | Typical reaction                                        |
|-----:|-------------|--------------------------------------------------------------------|---------------------------------------------------------|
| `0`  | ok          | success (auto-pick claim with nothing available is also `0`/empty) | proceed                                                 |
| `10` | lost-race   | task is owned by another owner                                     | pick a different task; never work it                    |
| `20` | precondition| missing tool, bad/absent task, no box, doctor fail, usage error    | read the message, fix the precondition, retry           |
| `30` | merge       | nothing to merge, bundle-verify fail, or branch already exists     | report; pass an explicit branch / re-warm if base moved |

Constants live in `dl-common.sh` as `DL_OK` / `DL_LOST` / `DL_PRECOND` /
`DL_MERGE` (exported).

## Environment variables

| Variable              | Default                                  | Purpose |
|-----------------------|------------------------------------------|---------|
| `DEV_LOOP_OWNER`      | `$USER@$(hostname -s)`                    | Claim owner / lock identity. **Export a distinct value per agent** when several agents share one Unix user (e.g. `$USER@$host/agent-$$`); the default is not distinct per process. |
| `CRABBOX_PROVIDER`    | `incus`                                   | Crabbox provider. Passed to **every** crabbox call (bare `crabbox list` defaults elsewhere and fails). |
| `DEV_LOOP_TTL`        | `2h`                                      | Lease TTL passed to `crabbox warmup -ttl`. |
| `DEV_LOOP_STALE`      | `4h`                                      | Age past which `dl-status.sh` flags an active claim `[STALE]`. (Stealing still requires an explicit `--steal-after`.) |
| `INCUS_IMAGE`         | (unset → crabbox default)                 | Optional `-incus-image` override; applied only at warmup. |
| `INCUS_TYPE`          | (unset → `container`)                     | Optional `-incus-instance-type` (`container`\|`vm`); warmup only. |
| `INCUS_REMOTE`        | (unset → local)                           | Optional `-incus-remote`; warmup only. |
| `DEV_LOOP_STATE_DIR`  | `${XDG_STATE_HOME:-$HOME/.local/state}/dev-loop` | Holds the `flock` lockfiles (`locks/`). |
| `DEV_LOOP_WORKTREE_DIR` | `${DEV_LOOP_STATE_DIR}/worktrees`        | Parent dir for per-task git worktrees. Each task gets `<dir>/<repo-key>/<slug>` (a worktree on scratch branch `dl/<slug>`). Kept OUTSIDE the repo so worktrees never appear as untracked files. The `<repo-key>` is derived from `git rev-parse --git-common-dir`, so it is stable across a repo's own worktrees. |
| `DEV_LOOP_BUNDLE_DIR` | `.dev-loop`                               | Repo-local, self-gitignored dir for downloaded bundles. Never the working tree. |
| `DL_DRY_RUN`          | (unset)                                   | Non-empty → mutating ops are logged, not run (same as `--dry-run`). Reads still run. |

Durations accept `90s`, `30m`, `2h`, `1d`, `2h30m`, or a bare integer (seconds).

Note: Incus flags (`-incus-image`/`-incus-instance-type`/`-incus-remote`) are
**warmup-only**. A warmed lease already encodes its config, so `run`/`status`/
`stop` pass only `-provider`/`-id`. Setting `INCUS_*` after a box is warmed has
no effect until the next warmup.

## Scripts at a glance

| Script              | Args                                              | stdout            | Notes |
|---------------------|---------------------------------------------------|-------------------|-------|
| `dl-setup.sh`       | `[--dry-run]`                                      | —                 | UDA + tooling + `crabbox doctor` gate. Idempotent. |
| `dl-claim.sh`       | `[<uuid>] [--steal-after <dur>] [--dry-run]`       | claimed uuid      | flock + CAS lock. Auto-pick when no uuid. |
| `dl-box.sh`         | `<uuid> [--dry-run]`                                | box handle        | Create-or-reuse the per-task worktree (`dl/<slug>`) AND warm-or-reuse one lease; records `worktree=`,`base=`,`box=`. |
| `dl-run.sh`         | `<uuid> [--no-sync\|--resync] [crabbox flags] -- <cmd>` | (command output) | cd's into the task worktree and syncs it up every run; `--no-sync` skips. Forwards cmd exit code. |
| `dl-merge-back.sh`  | `<uuid> [<branch>] [--dry-run]`                    | branch name       | Operates on the task worktree: in-box orphan snapshot→bundle→download→re-parent onto base→new branch. |
| `dl-release.sh`     | `<uuid> [--stop-box] [--force] [--dry-run]`        | —                 | Abandon claim; clears `assignee`; task stays pending (worktree left intact). |
| `dl-done.sh`        | `<uuid> [--keep-box] [--keep-worktree] [--force] [--dry-run]` | —          | `task done` + stop box + remove worktree & scratch branch `dl/<slug>`. `review/<slug>` is kept. Idempotent if already done. |
| `dl-status.sh`      | `[-h]`                                              | (report)          | Read-only claim/lease/worktree reconciliation. Mutates nothing. |

## Recipes

### Claim — the lock (flock + compare-and-swap)

`dl-claim.sh` is the hard guarantee that two owners never work one task:

1. Small randomized jitter de-synchronizes concurrent starts.
2. `flock -w 10` on `$DEV_LOOP_STATE_DIR/locks/<name>.lock` (fd 9) — a true mutex
   for this file-based Taskwarrior. By-uuid claims lock `task-<uuid>`; auto-pick
   locks `select` so selection+claim is atomic across the host.
3. Inside the lock, compare-and-swap: `task <uuid> modify assignee:<owner>`,
   then read it back via `task export | jq`; if it isn't ours, exit `10`. This
   is the cross-host degradation path (if a taskd sync server is ever added,
   where flock cannot span hosts).
4. `task <uuid> start` (sets `+ACTIVE` and the `start` timestamp used for
   staleness), annotate `claimed`, print the uuid.

Outcomes: claimed → `0` + uuid; owned by another → `10`; bad/non-pending task →
`20`; auto-pick with nothing available → `0` with empty stdout.

### Stale-claim reclaim (never silent)

```sh
scripts/dl-claim.sh <uuid> --steal-after 4h      # specific stale task
scripts/dl-claim.sh --steal-after 4h             # auto-pick incl. stale actives
```

Only an active claim whose `start` is at least `<dur>` old is reclaimable; the
takeover is recorded as an annotation (`stolen from <owner> after <n>s idle`).
Without `--steal-after`, an owned task always returns `10`.

### Work in the box & the sync model

**The task's own git worktree is the single source of truth.** `dl-box.sh`
creates one worktree per task — a separate working tree on scratch branch
`dl/<slug>`, rooted at `base`, under `$DEV_LOOP_WORKTREE_DIR/<repo-key>/<slug>`
and recorded as `worktree=<path>`. Edit files **in that worktree path** with your
normal tools. This is what isolates concurrent tasks: a git branch can be checked
out in only one worktree at a time, so two agents on the same repo never share a
working tree or fight over the index. (Objects and refs are shared across
worktrees, so the `review/<slug>` branch a task produces is still visible from the
main checkout.) `dl-run.sh` and `dl-merge-back.sh` cd into the worktree
automatically; you do not pass the path.

The box is a build/test sandbox only. Do NOT edit inside the box — Crabbox does
not forward stdin into `run` commands (so heredoc/pipe-driven in-box editors
silently get no input) and it never syncs `.git`, so in-box state is unreliable
and is overwritten on the next sync. (This is why ad-hoc in-box "apply these
string replacements" scripts are an anti-pattern: edit in the worktree instead.)

Crabbox rsyncs the worktree **up** on every `run`, copying only git-**tracked**
files (it derives the file list from `git ls-files`, run from the worktree). So
`dl-run.sh` syncs on every run by default — each run reflects your latest edits —
while box-generated build artifacts (untracked) survive a sync untouched. The
catch: **a NEW file you create is untracked, so `git add` it (in the worktree) or
it will not sync up** (and merge-back will not see it).

```sh
scripts/dl-run.sh "$uuid" -- bash -lc 'apt-get update && make'   # syncs worktree up
scripts/dl-run.sh "$uuid" -- bash -lc 'make test'                # syncs again (latest edits)
scripts/dl-run.sh "$uuid" --no-sync -- bash -lc 'make test'      # fast re-run, skip upload
scripts/dl-run.sh "$uuid" -sync-only --                          # just sync, run nothing
```

Extra flags before `--` are passed through to `crabbox run` (e.g. `-allow-env`,
`-env-from-profile`, `-artifact-glob`). The default `run` adds `-keep`,
`-keep-on-failure` (a failed run leaves the box for debugging) and a
`-label <project>/<uuid>`.

### Merge back via git bundle (exact sequence)

Crabbox never syncs `.git`, so the box has no history to bundle incrementally.
Merge-back therefore works by **snapshot**: the box builds a throwaway repo and
captures its working tree as a single **orphan** commit (no `base` prerequisite),
bundles that, and the bundle is **re-parented onto `base` locally**. The download
only fires on command success, so the snapshot, no-op guard, and bundle creation
happen in **one** `crabbox run`. The box script emits a `DL_*` sentinel on stdout
(captured and `grep`ed locally) and a matching non-zero exit so a no-op /
init-fail never triggers a download:

In the box (single run; the task worktree synced up first):
```sh
git config --global --add safe.directory '*'
rm -rf .git; git init -q       || { echo DL_NOGIT;       exit 41; }   # throwaway repo
git add -A
git diff --cached --quiet      && { echo DL_NOOP;        exit 43; }   # empty working tree
git commit -q --no-verify -m "<task desc>" \
                               || { echo DL_COMMIT_FAIL; exit 45; }   # local author identity via env
git branch -f dl/<slug> HEAD
git bundle create /tmp/<slug>.bundle dl/<slug> \
                               || { echo DL_BUNDLE_FAIL; exit 44; }   # whole branch, no prereq
echo DL_BUNDLE_OK
```
`crabbox run ... -download /tmp/<slug>.bundle=.dev-loop/<slug>.bundle -- bash -c '<above>'`

Locally, after a successful download:
```sh
git bundle verify .dev-loop/<slug>.bundle                     # pure integrity check (orphan, no prereqs)
git fetch .dev-loop/<slug>.bundle refs/heads/dl/<slug>:refs/dev-loop/import/<slug>
tree="$(git rev-parse refs/dev-loop/import/<slug>^{tree})"
# no-op if the snapshot tree is identical to base, else re-parent onto base:
git diff --quiet "<base>^{tree}" "$tree" && { echo "no changes"; }   # -> exit 30
new="$(git commit-tree "$tree" -p <base> -m "<task desc>")"           # clean one-commit increment
git branch <branch> "$new"
git --no-pager log --oneline <base>..<branch>
git --no-pager diff --stat <base>..<branch>
```

Sentinel → exit mapping: `DL_NOGIT`→`20`, `DL_NOOP`→`30`, `DL_COMMIT_FAIL`→`20`,
`DL_BUNDLE_FAIL`→`20`, no `DL_BUNDLE_OK`→`20`. Re-parenting via `commit-tree`
means the review branch shares history with `base`, so `base..branch` is exactly
the task's diff (not a detached full-repo snapshot). `git bundle` (not
`format-patch`) carries all objects including binaries. The argv stays small (no
base64 bootstrap), so it never approaches `ARG_MAX`. The branch is created but
**never merged** — review and merge it deliberately. `.dev-loop/` self-ignores
via a `.gitignore` containing `*`, so the user's tracked `.gitignore` is never
touched. (If the recorded `base` has been pruned locally, the snapshot is
imported as an orphan branch with a warning instead.)

### Status & reconciliation

```sh
scripts/dl-status.sh
```
Read-only. Reports active claims (owner, age, `*` = yours, `[STALE]` at
`DEV_LOOP_STALE`), live leases from `crabbox list -json`, **orphan** leases (a
running lease no pending task references → likely a leak), dangling box refs
(a task's `box=` no longer resolves), and per-task **worktrees** for this repo:
each is matched against `git worktree list` filtered to this repo's
`$DEV_LOOP_WORKTREE_DIR/<repo-key>/` prefix and flagged ORPHAN (registered but no
pending task references it — left by a completed/released task; prune with
`git worktree prune`) or MISSING (a pending task records a `worktree=` path whose
dir is gone — re-run `dl-box.sh` to recreate it). Act on findings with
`dl-release.sh`, `dl-done.sh`, the printed `crabbox stop` hint, or
`git worktree prune`.

### Recoverable state (annotations, not extra UDAs)

To keep config to the single `assignee` UDA, machine state lives in append-only
annotations (reads take the last match): `box=<handle>`, `base=<sha>`,
`worktree=<path>` (the per-task git worktree, recorded by `dl-box.sh`; phases
cd into it to edit/sync/merge-back), `branch=<name>`,
`commits=<base>..<head> (n=N)` (the commit range the task produced, recorded by
`dl-merge-back.sh` so commits stay linked even if the branch is
merged/renamed/deleted), plus free-form `dev-loop: <event> (by <owner>)`
lifecycle notes. A crashed/resumed loop reconstructs context from these — and
because the `worktree=` path is durable, a resumed loop re-enters the same
isolated tree (or `dl-box.sh` recreates it if it was pruned).

Annotations are also the place for **human-readable task notes**: a `summary:`
annotation (added before `dl-done.sh`) captures what was done and why. Because
`task done` keeps the task and its annotations in the completed list, this makes
each finished task self-describing — inspect it later with `task <uuid> info` or
`task <uuid> export | jq -r '.annotations[]?.description'`.

Because state is durable here and not in the agent's head, the orchestrator
should **compact its context between tasks** (see SKILL.md "Loop"): a freshly
compacted iteration rehydrates per-task state from `task <uuid> export` and
`dl-status.sh` exactly as a resumed loop would, so nothing is lost while stale
build/test churn that causes context rot is dropped.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `dl-setup.sh` exits `20` on doctor | Run `crabbox doctor -provider incus` and fix what it reports (Incus not initialized, no remote, etc.). |
| `crabbox list` fails / wrong provider | Always pass `-provider`. The skill scripts do; bare crabbox calls default to another provider. |
| Claim returns `10` immediately | Task is owned by another owner. Pick another, or `--steal-after <dur>` if it is genuinely stale. |
| Merge-back exit `20` (in-box snapshot failed) | Read the box output above the error. The box builds a throwaway repo (`git init`) and bundles an orphan snapshot — `.git` is intentionally NOT needed in the box. |
| Merge-back exit `30` "no changes" | The box working tree is empty or identical to `base`. Confirm your edits are in the task **worktree** and tracked (`git add` new files), then re-run `dl-run.sh` so they sync up before merge-back. |
| Merge-back exit `30` "branch already exists" | Pass an explicit `<branch>` name, or delete the stale local branch. |
| `bundle verify` fails locally | The bundle is corrupt/truncated (re-run merge-back). The orphan bundle has no base prerequisite, so a moved/pruned local `base` does NOT cause a verify failure — it only falls back to importing an orphan branch. |
| My edits didn't reach the box / merge-back | The task **worktree** (`worktree=` annotation) is the source of truth and syncs up every run, but only **tracked** files sync. Make sure you edited in the worktree path (not the shared checkout), `git add` new files, and don't edit inside the box. |
| `dl-box.sh` exits `20` "could not create worktree" | The scratch branch `dl/<slug>` is already checked out in another worktree, or the path is occupied. Run `dl-status.sh` / `git worktree list`; clear a stale one with `git worktree remove --force <path>` then `git worktree prune`. |
| `dl-run.sh`/`dl-merge-back.sh` exit `20` "recorded worktree is missing" | The worktree dir was deleted/pruned out from under the task. Re-run `dl-box.sh <uuid>` to recreate it on the same scratch branch, then retry. |
| Worktree flagged ORPHAN in `dl-status.sh` | A worktree left by a completed/released task. Remove it: `git worktree remove --force <path>` then `git worktree prune` (the registration alone clears with just `git worktree prune`). |
| Orphan lease in `dl-status.sh` | A leaked box. Stop it: `crabbox stop -provider <p> -id <id>`. |
| Secrets uploaded to the box | Add them to `.crabboxignore`; review with `crabbox sync-plan`. Inject env only via crabbox `-allow-env`/`-env-from-profile`. |
| Two agents, same Unix user, claims collide on identity | Export distinct `DEV_LOOP_OWNER` per agent before Phase 0. |
