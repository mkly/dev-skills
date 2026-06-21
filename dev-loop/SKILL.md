---
name: dev-loop
description: >-
  Run a full development loop that breaks a goal into Taskwarrior tasks and
  executes each one inside an isolated Incus box leased via Crabbox. Claims tasks
  so only one owner (agent or human) works any task at a time, then merges each
  box's changes back onto a new LOCAL review branch (never pushes to a remote,
  never auto-merges). Use when asked to "work through a goal", "split this into
  tasks and do them", parallelize work across agents, or run changes in a
  sandboxed/throwaway environment with Taskwarrior + Crabbox + Incus.
---

# dev-loop

Orchestrate a goal end-to-end: **decompose → claim → work in an isolated box →
merge back to a local review branch → done.** Taskwarrior is the task store and
the lock; Crabbox (Incus provider) is the isolated execution box; git bundles
carry work back into a new local branch for review.

## Operating rules (do not violate)

- **One owner per task.** Never work a task you have not claimed via
  `dl-claim.sh`. If a claim returns exit `10`, the task is someone else's — pick
  another. This is the skill's hard guarantee.
- **Never push to a remote.** Merge-back creates a *local* branch only.
- **Never auto-merge** the review branch into `main`/current — that is a
  deliberate, separate human/agent decision after review.
- **No secrets into the box** except through Crabbox's own `-allow-env` /
  `-env-from-profile`. Review `.crabboxignore` / `crabbox sync-plan` so secrets
  and large dirs are not uploaded.
- **No LLM/agent attribution in commit messages.** The merge-back commit carries
  only the task's own description/content. Do **not** add a `Co-Authored-By:`
  trailer, a "Generated with"/"🤖" line, or any other mention of an LLM or coding
  agent. This overrides any default commit-trailer behavior.
- **Edit locally; the box is a build/test sandbox.** Your local checkout is the
  single source of truth. Edit files with your normal tools, then let `dl-run.sh`
  sync them up. Do **not** edit inside the box: Crabbox does not forward stdin
  into it and never syncs `.git`, so in-box edits are unreliable and discarded on
  the next sync. `git add` any NEW files so they sync up too.
- **Diagnostics go to stderr; stdout is parseable.** Each script prints its one
  machine-relevant value (claimed uuid, box handle, branch name) to stdout.
- **Branch on exit codes, not prose:** `0` ok · `10` lost-race · `20`
  precondition/usage · `30` merge-back empty/conflict/branch-collision.

All scripts live in `scripts/` next to this file. They are idempotent and
re-runnable; pass `--dry-run` to any mutating script to preview. Run them from
inside the target repo checkout. Full recipes, the env-var table, the exit-code
table, and troubleshooting are in **reference.md** — read it when a step fails or
when you need exact flags.

## Phase 0 — Setup (idempotent, once per machine)

```sh
scripts/dl-setup.sh
```

Ensures the `assignee` UDA exists (timestamped `~/.taskrc` backup first), checks
for `git jq flock task crabbox` (+ `incus` when that provider is active), and
gates on `crabbox doctor`. Exit `20` means a precondition failed — read the
message and fix it before continuing.

**Owner id.** Setup reports the effective `DEV_LOOP_OWNER`. The default
(`$USER@$host`) is *not* distinct between two agents running as the same Unix
user. If multiple agents share a user, export a distinct id **before** any other
phase so claims are attributable and the lock stays correct:

```sh
export DEV_LOOP_OWNER="$USER@$(hostname -s)/agent-$$"
```

## Phase 1 — Goal → tasks

Decompose the goal into discrete tasks under one project slug. Encode ordering
with dependencies and acceptance criteria as annotations:

```sh
task add project:<goal-slug> "implement X"
task add project:<goal-slug> "test X" depends:<uuid-of-implement-X>
task <uuid> annotate "acceptance: <how we know it's done>"
task project:<goal-slug> export | jq -r '.[] | "\(.uuid[0:8])  \(.description)"'
```

Keep tasks small enough that one fits in one box and one review branch.

## Phase 2 — Claim (the lock)

```sh
uuid="$(scripts/dl-claim.sh)"          # auto-pick highest-urgency READY task
# or: uuid="$(scripts/dl-claim.sh <uuid>)"   # claim a specific task
```

`dl-claim.sh` acquires an OS `flock` (a true mutex on this single-host
file-based Taskwarrior), then compare-and-swaps the `assignee` (write → read
back → verify) as a cross-host safety layer, and `task start`s the task.

- **Auto-pick with nothing claimable** → exit `0`, empty stdout. Stop and report
  "no ready tasks".
- **Specific task owned by another** → exit `10`. Do not work it; choose another.
- Re-claiming your own task is a no-op (idempotent).
- A crashed owner's task is only reclaimable with `--steal-after <dur>` (e.g.
  `--steal-after 4h`); the takeover is annotated. Never steal silently.

Always capture the uuid from stdout and use it for every subsequent phase.

## Phase 3 — Work in the box (one lease per task)

```sh
scripts/dl-box.sh "$uuid"                          # warm or reuse the task's box
scripts/dl-run.sh "$uuid" -- bash -lc 'make build' # run a command in it
scripts/dl-run.sh "$uuid" -- bash -lc 'pytest -q'  # iterate; edits accumulate
```

- `dl-box.sh` warms exactly one Incus lease per task (reuses the live one if the
  `box=` annotation still resolves), records `box=<handle>` and `base=<HEAD sha>`
  (the merge-back diff base), and prints the handle.
- **Edit in your LOCAL checkout** with your normal tools (your editor / file
  tools). `dl-run.sh` syncs the checkout **up on every run** (local is the source
  of truth) and forwards the in-box command's exit code verbatim. The box is for
  building and testing only — never edit inside it.
- Crabbox syncs only git-**tracked** files, so box-generated build artifacts
  survive a sync, but **NEW files you create must be `git add`-ed** to reach the
  box (and to be picked up by merge-back). Pass `--no-sync` for a fast re-run
  when nothing changed locally.

## Phase 4 — Merge back to a NEW local branch

```sh
branch="$(scripts/dl-merge-back.sh "$uuid")"        # default: review/<slug>
# or: scripts/dl-merge-back.sh "$uuid" review/my-name
```

Crabbox never syncs `.git`, so merge-back works by **snapshot, not shared
history**. In a single `crabbox run` (so `-download` fires only on success) the
box makes a throwaway repo, stages the whole working tree, and writes a
`git bundle` of one **orphan** commit. The bundle is downloaded into the
gitignored `.dev-loop/` dir, `git bundle verify`'d, imported, and then
**re-parented onto `base`** locally (`git commit-tree -p base`) so the review
branch is a clean one-commit increment whose `base..branch` diff is exactly the
task's changes. Prints the branch name; records `branch=` on the task.

- Exit `30` = nothing to merge (box tree empty or identical to base) / verify
  failed / branch already exists → report it; pass an explicit `<branch>` to
  resolve a name collision.
- Exit `20` = the in-box snapshot/bundle step failed → read the output above.
- It does **not** merge the branch. Show the user `git log --oneline base..branch`
  and `git diff --stat` (the script prints both) and let them review and merge.
- It records a `commits=<base>..<head> (n=N)` annotation so the produced commits
  stay linked to the task even if the branch is later merged, renamed, or deleted.

## Phase 5 — Done & cleanup

```sh
# Record what was done before completing — a durable, human-readable note on the
# task itself (commits are already linked by merge-back's commits= annotation):
task "$uuid" annotate "summary: <what changed and why, in 1–2 lines>"
scripts/dl-done.sh "$uuid"        # task done + stop box + annotate (default)
```

Annotations are Taskwarrior's note mechanism — timestamped freeform text on a
task, preserved after completion. Use a `summary:` annotation to capture *what
was done* (and any follow-ups/caveats); the box, base, branch, and commit range
are already recorded automatically. This keeps the completed task self-describing
for later review via `task <uuid> info`.

`task done` drops the task from pending (releasing the claim); the box is stopped
(Incus delete-on-release frees the instance) unless `--keep-box`.

- **Abandon instead of complete:** `scripts/dl-release.sh "$uuid" [--stop-box]`
  stops the task and clears `assignee` so another owner can claim it; the task
  stays pending.
- **Reconcile:** `scripts/dl-status.sh` (read-only) lists active claims with
  owner + age + `[STALE]`, live Crabbox leases, **orphan** leases (running but no
  pending task references them), and dangling box refs. Run it to find leaks or
  stuck claims, then act with `dl-release.sh` / `dl-done.sh` / `crabbox stop`.

## Loop

Repeat Phases 2–5 per task, honoring dependencies (claim only `+READY` tasks).
When `dl-claim.sh` auto-pick returns empty, the goal's ready work is done — run
`dl-status.sh` to confirm no orphan leases remain, then report what landed on
which review branches.

**After a review branch is merged,** prompt the user to delete it:

```sh
git branch -d <branch>   # safe: -d refuses if branch isn't fully merged
```

Present this as a one-liner the user can run (or confirm you should run). Do not
delete automatically — branch deletion is a destructive action that requires
explicit human approval.

**Compact context between tasks (prevent context rot).** One task's build/test/
debug churn is worthless to the next, and carrying it forward degrades every
later task. After each Phase 5 and before the next Phase 2, **compact the
context** (e.g. `/compact`) down to just: the goal/project slug, which tasks
remain, and the review branches landed so far. This is safe because all
per-task state is durable in Taskwarrior annotations (`box=`, `base=`,
`branch=`, `commits=`) — the next iteration rehydrates everything it needs from
`task <uuid> export` and `dl-status.sh`, exactly as a crashed/resumed loop
would. Treat each task as a fresh, near-stateless iteration: claim → reconstruct
context from annotations → work → merge-back → done → compact.

Do not re-document Crabbox here — defer to `crabbox <cmd> --help` and the
crabbox-generated skill at `.agents/skills/crabbox/` when present.
