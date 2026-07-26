# dev-loop

A repo-agnostic agent skill that composes `dev-loop-task` with an isolated
implementation pass:

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
| [Taskwarrior](https://taskwarrior.org/) (`task`) | durable task and owner store | `3.4.2` (TaskChampion/SQLite) |
| [Crabbox](https://github.com/openclaw/crabbox) (`crabbox`) | leases the isolated execution box | `0.32.0` |
| [Incus](https://linuxcontainers.org/incus/) (`incus`) | the box provider | `6.0.4` |
| `git`, `jq`, `flock`, `bash` | worktrees + local review branches, JSON parsing, the OS mutex | — |

`flock` and `bash` ship with most Linux distros (`flock` is in `util-linux`).
Incus must be initialized (`incus admin init`) and reachable — `dl-setup.sh`
gates on `crabbox doctor -provider incus` and tells you what is missing.

## Install

Install both sibling skill directories in a location your agent runtime scans.
Keep them as siblings so their cross-skill references resolve. Symlink them
(recommended — edits stay live) or copy them into that directory:

```sh
agent_skill_root=/path/to/agent-skills

# Symlink (preferred):
ln -s "$PWD/dev-loop" "$agent_skill_root/dev-loop"
ln -s "$PWD/dev-loop-task" "$agent_skill_root/dev-loop-task"

# …or copy:
cp -r dev-loop "$agent_skill_root/dev-loop"
cp -r dev-loop-task "$agent_skill_root/dev-loop-task"
```

Configure the runtime to discover each directory's `SKILL.md` frontmatter. The
discovery path and registration mechanism are runtime-specific; the skills and
their scripts do not depend on either one.

The scripts resolve their own locations, so they work via symlinks and can also
be run directly from any repo checkout:

```sh
/path/to/agent-skills/dev-loop/scripts/dl-setup.sh
```

## Quick start

Run from inside the target repo (the checkout you want changes against):

```sh
dev_loop_scripts=/path/to/agent-skills/dev-loop/scripts
dev_task_scripts=/path/to/agent-skills/dev-loop-task/scripts

"$dev_loop_scripts/dl-setup.sh"                                   # Phase 0: one-time, idempotent
uuid="$("$dev_task_scripts/dlt-create.sh" \
  --project demo.make-the-thing --description 'make the thing' \
  --acceptance 'the thing works as requested')"                    # Phase 1: create only
task rc.confirmation=no sync                                       # Phase 1: publish completed batch
uuid="$("$dev_loop_scripts/dl-claim.sh" "$uuid")"                 # Phase 2: claim (the lock)
"$dev_loop_scripts/dl-box.sh" "$uuid"                             # Phase 3: warm an Incus box
"$dev_loop_scripts/dl-run.sh" "$uuid" --compact -- bash -lc 'make && make test'
branch="$("$dev_loop_scripts/dl-merge-back.sh" "$uuid")"          # Phase 4: → new local branch
base="$(task "$uuid" export | jq -r '.[0].annotations | map(.description) | map(select(startswith("base="))) | last | .[5:]')"
git log --oneline "$base..$branch"                                # review (script also prints log/stat)
"$dev_loop_scripts/dl-done.sh" "$uuid"                            # Phase 5: complete + park the box for reuse
```

`dl-status.sh` (read-only) reconciles claims against live leases at any time.
Multiple agents sharing one Unix user should each `export DEV_LOOP_OWNER` to a
distinct value first — see `reference.md`.

## Guarantees & boundaries

- **One owner per task on one host.** `dl-claim.sh` takes an OS `flock` around
  the claim sequence and verifies its nonce-bearing `assignee` UDA write. A
  lost race exits `10`; the agent picks another task. Separate TaskChampion
  sync replicas require external coordination because sync is not a
  distributed mutex.
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
