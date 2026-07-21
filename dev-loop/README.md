# dev-loop

A repo-agnostic Claude Code / Agent skill that composes `dev-loop-task` with an
isolated implementation pass:

> **atomically create durable Taskwarrior tasks → claim a task (so only one owner
> ever works it) → work in a per-task git worktree, building/testing inside an
> isolated Incus box leased via Crabbox → snapshot the worktree onto a new
> *local* review branch.**

It never pushes to a remote and never auto-merges. The review branch is left for
a human/agent to inspect and merge deliberately.

`dev-loop-task/SKILL.md` owns task creation; this skill consumes those pending
tasks. `SKILL.md` is the agent-facing implementation workflow; `reference.md`
has exact recipes, environment variables, exit codes, and troubleshooting. The
work is done by small, idempotent, shellcheck-clean scripts in `scripts/`.

## Prerequisites

Linux only. The scripts use GNU `date -d`, `flock` from util-linux, and bash 4+
features such as `mapfile` and associative arrays.

| Tool | Why | Verified with |
|------|-----|---------------|
| [Taskwarrior](https://taskwarrior.org/) (`task`) | task store **and** the claim lock | `2.6.2` (file-based, no taskd needed) |
| [Crabbox](https://github.com/openclaw/crabbox) (`crabbox`) | leases the isolated execution box | `0.32.0` |
| [Incus](https://linuxcontainers.org/incus/) (`incus`) | the box provider | `6.0.4` |
| `git`, `jq`, `flock`, `bash` | worktrees + local review branches, JSON parsing, the OS mutex | — |

`flock` and `bash` ship with most Linux distros (`flock` is in `util-linux`).
Incus must be initialized (`incus admin init`) and reachable — `dl-setup.sh`
gates on `crabbox doctor -provider incus` and tells you what is missing.

## Install

Install both sibling skill directories. Symlink them (recommended — edits stay
live) or copy them into your Claude skills dir:

```sh
# Symlink (preferred):
ln -s "$PWD/dev-loop" ~/.claude/skills/dev-loop
ln -s "$PWD/dev-loop-task" ~/.claude/skills/dev-loop-task

# …or copy:
cp -r dev-loop ~/.claude/skills/dev-loop
cp -r dev-loop-task ~/.claude/skills/dev-loop-task
```

Claude Code discovers skills under `~/.claude/skills/` by their `SKILL.md`
frontmatter; no further registration is needed. To make it available in one
repo only, symlink into that repo's `.claude/skills/` instead.

The scripts resolve their own locations, so they work via symlinks and can also
be run directly from any repo checkout:

```sh
~/.claude/skills/dev-loop/scripts/dl-setup.sh
```

## Quick start

Run from inside the target repo (the checkout you want changes against):

```sh
S=~/.claude/skills/dev-loop/scripts
T=~/.claude/skills/dev-loop-task/scripts

$S/dl-setup.sh                                   # Phase 0: one-time, idempotent
uuid="$($T/dlt-create.sh --project demo --description 'make the thing' \
  --acceptance 'the thing works as requested')"  # Phase 1: create only
uuid="$($S/dl-claim.sh "$uuid")"                 # Phase 2: claim (the lock)
$S/dl-box.sh "$uuid"                              # Phase 3: warm an Incus box
$S/dl-run.sh "$uuid" -- bash -lc 'make && make test'
branch="$($S/dl-merge-back.sh "$uuid")"           # Phase 4: → new local branch
base="$(task "$uuid" export | jq -r '.[0].annotations | map(.description) | map(select(startswith("base="))) | last | .[5:]')"
git log --oneline "$base..$branch"               # review (script also prints log/stat)
$S/dl-done.sh "$uuid"                             # Phase 5: complete + park the box for reuse
```

`dl-status.sh` (read-only) reconciles claims against live leases at any time.
Multiple agents sharing one Unix user should each `export DEV_LOOP_OWNER` to a
distinct value first — see `reference.md`.

## Guarantees & boundaries

- **One owner per task.** `dl-claim.sh` takes an OS `flock` (true mutex on this
  single host) plus a compare-and-swap on the `assignee` UDA. A lost race exits
  `10`; the agent picks another task.
- **No remote push, no auto-merge.** Merge-back snapshots the task's own git
  worktree and re-parents it onto the recorded base as one commit on a fresh
  *local* review branch — a purely local operation, no box round-trip.
- **No secrets into the box** except via Crabbox's own `-allow-env` /
  `-env-from-profile`. Review `.crabboxignore` / `crabbox sync-plan`.
- **Leak control.** Every lease gets a `-ttl`; runs are labeled, and
  `dl-status.sh` flags orphan leases and stale claims.

The only Taskwarrior config it adds is a single `assignee` UDA (with a
timestamped backup of the active taskrc when one exists). All other machine state
lives in task annotations, so nothing else is bolted onto your Taskwarrior setup.

## License

See the repository root.
