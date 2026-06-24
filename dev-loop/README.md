# dev-loop

A repo-agnostic Claude Code / Agent skill that runs a full development loop:

> **decompose a goal into Taskwarrior tasks → claim a task (so only one owner
> ever works it) → work in a per-task git worktree, building/testing inside an
> isolated Incus box leased via Crabbox → snapshot the worktree onto a new
> *local* review branch.**

It never pushes to a remote and never auto-merges. The review branch is left for
a human/agent to inspect and merge deliberately.

`SKILL.md` is the agent-facing entry point (the workflow); `reference.md` has the
exact recipes, environment-variable table, exit-code contract, and
troubleshooting. The work is done by small, idempotent, shellcheck-clean scripts
in `scripts/`.

## Prerequisites

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

The skill is just this directory. Symlink (recommended — edits stay live) or copy
it into your Claude skills dir:

```sh
# Symlink (preferred):
ln -s "$PWD/dev-loop" ~/.claude/skills/dev-loop

# …or copy:
cp -r dev-loop ~/.claude/skills/dev-loop
```

Claude Code discovers skills under `~/.claude/skills/` by their `SKILL.md`
frontmatter; no further registration is needed. To make it available in one
repo only, symlink into that repo's `.claude/skills/` instead.

The scripts resolve their own location, so they work via a symlink and can also
be run directly from any repo checkout:

```sh
~/.claude/skills/dev-loop/scripts/dl-setup.sh
```

## Quick start

Run from inside the target repo (the checkout you want changes against):

```sh
S=~/.claude/skills/dev-loop/scripts

$S/dl-setup.sh                                   # Phase 0: one-time, idempotent
task add project:demo "make the thing"           # Phase 1: decompose the goal
uuid="$($S/dl-claim.sh)"                          # Phase 2: claim (the lock)
$S/dl-box.sh "$uuid"                              # Phase 3: warm an Incus box
$S/dl-run.sh "$uuid" -- bash -lc 'make && make test'
branch="$($S/dl-merge-back.sh "$uuid")"           # Phase 4: → new local branch
git log --oneline "main..$branch"                # review (never auto-merged)
$S/dl-done.sh "$uuid"                             # Phase 5: complete + free the box
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
- **Leak control.** Every lease gets a `-ttl` and a `-label`; `dl-status.sh`
  flags orphan leases and stale claims.

The only Taskwarrior config it adds is a single `assignee` UDA (with a
timestamped `~/.taskrc` backup). All other machine state lives in task
annotations, so nothing else is bolted onto your Taskwarrior setup.

## License

See the repository root.
