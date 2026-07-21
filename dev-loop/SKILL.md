---
name: dev-loop
description: >-
  Run a development pass that uses dev-loop-task to break a goal into durable
  Taskwarrior tasks when needed, then claims and executes each one inside an
  isolated Incus box leased via Crabbox. Ensures one owner per task and merges
  each box's changes onto a new LOCAL review branch without pushing or
  auto-merging. Use when asked to "work through a goal", "split this into tasks
  and do them", parallelize work across agents, or run changes in a
  sandboxed/throwaway environment with Taskwarrior + Crabbox + Incus.
---

# dev-loop

Orchestrate a goal end-to-end: **decompose → claim → work in an isolated box →
merge back to a local review branch → done.** Taskwarrior is the task store and
the lock; Crabbox (Incus provider) is the isolated execution box; the per-task
git worktree is snapshotted into a new local branch for review.

## Load the task-creation component when needed

Before creating any task for a fresh goal, locate and read
`dev-loop-task/SKILL.md` completely. When the skills are stored as siblings,
resolve it as `../dev-loop-task`; otherwise locate its installed directory. Use
its bundled `dlt-create.sh` for every new task. Do not reconstruct task creation
with `task add` / `+LATEST`. A pass that only consumes an already-decomposed
project does not need to load this component.

`dev-loop-task` owns task sizing, acceptance, dependency/input wiring, duplicate
detection, and atomic UUID capture. Its stop-before-execution boundary applies
while creating tasks. Because this skill is invoked for implementation, resume
here with the returned UUIDs and continue to claiming only after task creation
has finished. If creation is needed and the component is unavailable, stop with
an environment blocker instead of copying its workflow by hand.

## Operating rules (do not violate)

- **One owner per task.** Never work a task you have not claimed via
  `dl-claim.sh`. If a claim returns exit `10`, the task is someone else's — pick
  another. This is the skill's hard guarantee, and `dl-box.sh`, `dl-run.sh`, and
  `dl-merge-back.sh` enforce it unless you pass `--force`.
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
- **Edit in the task's worktree; the box is a build/test sandbox.** `dl-box.sh`
  creates a dedicated git worktree per task (its own working tree + branch,
  recorded as `worktree=`) so many agents can work one repo on one machine
  without colliding. Edit **in that worktree path** with your normal tools — not
  in the shared checkout, and never inside the box (Crabbox does not forward
  stdin into it and never syncs `.git`, so in-box edits are unreliable and
  discarded on the next sync). `dl-run.sh`/`dl-merge-back.sh` operate on the
  worktree automatically. `git add` any NEW files so they sync up too.
- **Diagnostics go to stderr; stdout is parseable.** Each script prints its one
  machine-relevant value (claimed uuid, box handle, branch name) to stdout.
- **Wait for a box to finish warming.** `dl-box.sh` is a blocking operation: a
  fresh lease may take minutes. Run it in a persistent command session. If the
  execution tool yields a session/process ID while the command is still running,
  that means **warmup is still in progress**, not that the box is unavailable.
  Poll/wait on that same session (in Codex, call `write_stdin` with empty input)
  repeatedly until the command actually exits. Its initial `warming box`
  diagnostic and quiet periods are progress, not completion or failure. Do not
  invoke `dl-run.sh`, retry `dl-box.sh`, or return control to the user while that
  session is running. Proceed only after exit `0`, a printed box handle, and the
  task's matching `box=<handle>` annotation. If the session actually disappears
  before an exit result, run `dl-status.sh` before doing anything else so a
  partially-created lease is not mistaken for a failed warmup or leaked by a
  blind retry.
- **Branch on exit codes, not prose:** `0` ok · `10` lost-race · `20`
  precondition/usage · `30` merge-back empty/conflict/branch-collision.

The implementation helper scripts are bundled with the installed dev-loop
skill, not with the target repo; task creation's `dlt-create.sh` belongs to the
installed dev-loop-task skill. In command examples, `/path/to/dev-loop-skill`
means the installed directory containing this `SKILL.md`; invoke scripts from
there while keeping the target repo checkout as the current working directory.
Do not assume the target repo contains `scripts/dl-*.sh`. The scripts are
idempotent and re-runnable where that is safe; merge-back exact re-runs of the
same branch are no-ops, while branch-name collisions still return exit `30`.
Pass `--dry-run` to any mutating script to preview. Full recipes,
the env-var table, the exit-code table, and troubleshooting are in
**reference.md** — read it when a step fails or when you need exact flags.

## Phase 0 — Setup (idempotent, once per machine)

```sh
/path/to/dev-loop-skill/scripts/dl-setup.sh
```

Ensures the `assignee` UDA exists (timestamped backup of the active taskrc when
one exists), checks for `git jq flock task crabbox` (+ `incus` when that provider
is active), and gates on `crabbox doctor`. Exit `20` means a precondition failed
— read the message and fix it before continuing.

**Owner id.** Setup reports the effective `DEV_LOOP_OWNER`. The default fallback is read from a state file if present (generated by `dl-setup.sh` at `~/.config/dev-loop/owner`), falling back to the default `$USER@$host` identity.

The precedence for resolving the owner ID is:
1. Explicit `DEV_LOOP_OWNER` environment variable.
2. Persisted state file (`~/.config/dev-loop/owner`).
3. Dynamic default (`$USER@$host`).

For concurrent multi-agent environments sharing a Unix user, you must export a distinct owner ID. The ID must stay a fixed literal for the entire session (never use a dynamically re-expanded value like `$$` which changes per command and breaks locks):

```sh
export DEV_LOOP_OWNER="$USER@$(hostname -s)/agent-unique-name"
```

## Phase 1 — Goal → tasks

First inspect Taskwarrior for an existing project/task set that already captures
the goal. Resume it when present; never decompose the same goal twice.

For a fresh goal, follow dev-loop-task completely and create every task through
its atomic helper. Capture each returned UUID. For example:

```sh
/path/to/dev-loop-task-skill/scripts/dlt-create.sh \
  --project <goal-slug> \
  --description "implement X" \
  --acceptance "<observable proof that X is done>"
```

Use `--depends` plus `--input` for consumers, chain overlapping work, and put an
end-to-end acceptance criterion on every chain tip as dev-loop-task requires.
When a controller such as dev-loop-complete supplies extra metadata, pass it to
the same creation call so the task is complete at import time.

List the resulting project and verify all tasks are pending and unassigned.
Then continue to Phase 2; the direct dev-loop-task stopping rule does not end
this broader, explicitly authorized implementation pass.

## Phase 2 — Claim (the lock)

```sh
uuid="$(/path/to/dev-loop-skill/scripts/dl-claim.sh)"          # auto-pick highest-urgency READY task
# or: uuid="$(/path/to/dev-loop-skill/scripts/dl-claim.sh <uuid>)"   # claim a specific task
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
/path/to/dev-loop-skill/scripts/dl-box.sh "$uuid"                          # warm or reuse the task's box
/path/to/dev-loop-skill/scripts/dl-run.sh "$uuid" -- bash -lc 'make build' # run a command in it
/path/to/dev-loop-skill/scripts/dl-run.sh "$uuid" -- bash -lc 'pytest -q'  # iterate; edits accumulate
```

For a fresh lease, keep the `dl-box.sh` command alive until it exits. The
`warming box` line only means provisioning has begun; success is the printed
handle plus the task's `box=` annotation. Use this mandatory wait protocol:

1. Start `dl-box.sh` once in a persistent execution session.
2. If the tool reports `process running`, `session ID`, or an equivalent early
   yield, wait/poll that exact session again. In Codex, use empty-input
   `write_stdin`; do not start another command.
3. Repeat step 2 through quiet/no-output intervals until the session reports a
   real exit code. A yielded call has no exit code and is never a failure.
4. On exit `0`, capture the handle and continue. On a nonzero exit, follow the
   exit-code contract. Only if the session itself is lost, reconcile with
   `dl-status.sh` before deciding whether to retry.

Never conclude “the container is not up yet” and stop: “not up yet” means the
current action is to keep waiting on the existing warmup session.

- `dl-box.sh` sets up two things per task: (1) a dedicated **git worktree** on a
  scratch branch `dl/<slug>` rooted at `--base <ref>`, else the task's latest
  `input:` branch, else current HEAD, placed outside the repo under
  `$DEV_LOOP_WORKTREE_DIR/<repo>/<slug>` and recorded as `worktree=<path>`;
  and (2) exactly one Incus lease (reuses the live one if the `box=` annotation
  still resolves). It records `box=<handle>`, `base=<resolved sha>` (the
  merge-back diff base), and `worktree=<path>`, and prints the handle. The
  worktree gives
  each task its own isolated working tree + branch, so many agents can work the
  same repo on one machine without stepping on each other.
- **Edit in the task's worktree** (`worktree=<path>`) with your normal tools (your
  editor / file tools) — not in the shared checkout. `dl-run.sh` cd's into that
  worktree, syncs it **up on every run** (the worktree is the source of truth),
  and forwards the in-box command's exit code verbatim. The box is for building
  and testing only — never edit inside it.
- **Scope test runs to the change.** While iterating, run the tests named by the
  task's acceptance criteria (or covering the touched files), not the full
  suite. Run the broader suite at most once, right before merge-back, and only
  when the change could plausibly affect code outside its own slice — a
  prompt-text or doc change does not need 400 unrelated tests re-proven.
- Crabbox syncs only git-**tracked** files, so box-generated build artifacts
  survive a sync, but **NEW files you create must be `git add`-ed to reach the
  box** (merge-back snapshots the whole worktree, so it picks up untracked
  non-ignored files regardless — but the box won't see them until tracked). Pass
  `--no-sync` for a fast re-run when nothing changed locally.

## Phase 4 — Merge back to a NEW local branch

```sh
branch="$(/path/to/dev-loop-skill/scripts/dl-merge-back.sh "$uuid")"        # default: review/<slug>
# or: /path/to/dev-loop-skill/scripts/dl-merge-back.sh "$uuid" review/my-name
```

Merge-back is a purely **local** git operation on the task's worktree — no box
round-trip. The worktree (rooted at `base`) is the source of truth: the agent
edits there and the box is build/test only. Merge-back stages the worktree's
whole working tree into a throwaway index, writes that tree, and **re-parents it
onto `base`** (`git commit-tree -p base`) as one commit, so the review branch is
a clean increment whose `base..branch` diff is exactly the task's changes.
Gitignored build artifacts are excluded; newly created files are included
automatically (no `git add` needed for merge-back). Prints the branch name;
records `branch=` on the task.

- Exit `30` = nothing to merge (worktree identical to base) / branch already
  exists → report it; pass an explicit `<branch>` to resolve a name collision.
- Exit `20` = no recorded base/worktree, or the worktree dir is missing → run
  `/path/to/dev-loop-skill/scripts/dl-box.sh "$uuid"` first (or to recreate
  a pruned worktree).
- It does **not** merge the branch. Show the user `git log --oneline base..branch`
  and `git diff --stat` (the script prints both) and let them review and merge.
- It records a `commits=<base>..<head> (n=N)` annotation so the produced commits
  stay linked to the task even if the branch is later merged, renamed, or deleted.

## Phase 5 — Done & cleanup

```sh
# Record what was done before completing — a durable, human-readable note on the
# task itself (commits are already linked by merge-back's commits= annotation):
task "$uuid" annotate "summary: <what changed and why, in 1–2 lines>"
/path/to/dev-loop-skill/scripts/dl-done.sh "$uuid"        # task done + park box for reuse + annotate
```

Annotations are Taskwarrior's note mechanism — timestamped freeform text on a
task, preserved after completion. Use a `summary:` annotation to capture *what
was done* (and any follow-ups/caveats); the box, base, branch, and commit range
are already recorded automatically. This keeps the completed task self-describing
for later review via `task <uuid> info`.

`task done` drops the task from pending (releasing the claim); the live box is
parked for the next task unless `--stop-box`, and the task's worktree + scratch
branch `dl/<slug>` are removed unless `--keep-worktree`. The
`review/<slug>` branch is shared in the repo and is always KEPT for review.
If the worktree differs from `base=` and no `branch=` was recorded, `dl-done.sh`
exits `20` and leaves the worktree in place; run `dl-merge-back.sh "$uuid"` first
or pass `--force` / `--keep-worktree` intentionally.

- **Abandon instead of complete:** `/path/to/dev-loop-skill/scripts/dl-release.sh "$uuid" [--stop-box]`
  stops the task and clears `assignee` so another owner can claim it; the task
  stays pending. Its live box is parked for reuse unless `--stop-box`.
- **Reconcile:** `/path/to/dev-loop-skill/scripts/dl-status.sh` (read-only) lists active claims with
  owner + age + `[STALE]`, live Crabbox leases, **orphan** leases (running but no
  pending task references them), dangling box refs, per-task worktrees (flagging
  ORPHAN worktrees left by completed/released tasks and MISSING ones a pending
  task still records), and a **Review branches** section — the pipeline's
  *output*. The latter reverse-maps every `branch=` annotation (across ALL tasks,
  including completed) and every `refs/heads/review/*` branch to its producing
  task, and reports merge state vs the current checkout: `MERGED` (tip is an
  ancestor of HEAD → reviewed/landed, safe to `git branch -d`), `unmerged
  (+N)` (awaiting review), `ORPHAN` (a review branch no task records), and `GONE`
  (a task recorded a branch that no longer exists — merged + deleted). Run it to
  find leaks or stuck claims **and to answer "what's still waiting to merge"**,
  then act with `dl-release.sh` / `dl-done.sh` / `crabbox stop` /
  `git worktree prune`.

## Loop

Repeat Phases 2–5 per task, honoring dependencies (claim only `+READY` tasks).

**Keep per-task ceremony proportional.** The safety rules (claim before work,
edit in the worktree, merge back locally, record `summary:`) are fixed; the
deliberation is not. For a small task, read its annotations, make the change,
run its acceptance tests, and merge back — do not re-run `dl-setup.sh`, re-read
reference.md, or re-survey `dl-status.sh` on every iteration when nothing has
gone wrong. `dl-status.sh` is for reconciling after a failure or at the end of
the loop, not a per-task ritual.

When `dl-claim.sh` auto-pick returns empty, the goal's ready work is done — run
`/path/to/dev-loop-skill/scripts/dl-status.sh` to confirm no orphan leases
remain, then report what landed on which review branches.

**After a review branch is merged,** prompt the user to delete it:

```sh
git branch -d <branch>   # safe: -d refuses if branch isn't fully merged
```

Present this as a one-liner the user can run (or confirm you should run). Do not
delete automatically — branch deletion is a destructive action that requires
explicit human approval.

**Use automatic context compaction (prevent context rot).** Run long loops with
the host agent/runtime configured to compact after roughly 64k tokens of context
growth. If supported, count only growth after the persistent system/skill
instruction prefix so that prefix does not immediately consume the threshold.
Use 32–48k only when stale context remains a problem. Configuration names and
when changes take effect vary by agent; keep vendor-specific settings out of
this skill. Automatic compaction is token-driven and may occur during a task or
after several tasks, not specifically after Phase 5. If the host cannot
configure or trigger compaction, continue using the durable-state discipline
below and do not claim that boundary compaction occurred.

At every task boundary, keep the logical workflow near-stateless anyway: record
the Phase 5 `summary:`, then reconstruct the next task from `task <uuid> export`
and `dl-status.sh` rather than relying on remembered build/test/debug churn.
Per-task state is durable in Taskwarrior annotations (`box=`, `base=`,
`worktree=`, `branch=`, `commits=`), so periodic automatic compaction can safely
discard transient details. Treat each task as: claim → reconstruct from
annotations → work → merge-back → done → record durable state.

Do not re-document Crabbox here — defer to `crabbox <cmd> --help` and the
crabbox-generated skill at `.agents/skills/crabbox/` when present.
