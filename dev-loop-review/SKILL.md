---
name: dev-loop-review
description: >-
  Review the local review/* branches a dev-loop run produced, then act on the
  verdict. Enumerates the available review branches (git is ground truth),
  correlates each with the Taskwarrior task that produced it, walks the diffs,
  and then either creates fix tasks atomically through dev-loop-task for
  branches with findings, or merges clean branches into the current branch and
  deletes them. Use after running dev-loop, or when asked to "review what the
  loop did", "review the review branches", or "review and merge the dev-loop
  work".
---

# dev-loop-review

Close the loop on what dev-loop produced. dev-loop leaves one local
`review/<slug>` branch per merged-back task, and annotations on the producing
task (`base=`, `branch=`, `commits=`, `acceptance:`, `summary:`). This skill
follows the branches, not the task list: **enumerate the available review
branches → review each diff against its producing task's intent → act.**
Findings become new Taskwarrior fix tasks for the next dev-loop run; a clean
branch is merged into the current branch and deleted. No report file is saved —
the review lives in the created tasks and the inline summary.

## Load the task-creation component for findings

Before creating the first finding task, locate and read
`dev-loop-task/SKILL.md` completely. When the skills are siblings, resolve it as
`../dev-loop-task`; otherwise locate its installed directory. Use its
`dlt-create.sh` for every finding task so UUID capture and task metadata remain
atomic. Never recreate the old `task add` then `task +LATEST` sequence. A pass
with only clean verdicts need not load it. If the component is unavailable,
clean branches may still be reviewed, but stop with an environment blocker
before attempting to record any finding that requires a task.

## Operating rules (do not violate)

- **Branches are the work queue.** Collect from `refs/heads/review/*` (plus any
  `branch=` annotation that still resolves) via `dlr-collect.sh` — never by
  scanning tasks for what "should" exist. But **review against intent**: judge
  each branch's diff against its producing task's `description`, `acceptance:`,
  and `summary:` (in the collected object), not just generic taste.
- **Findings become tasks, not a report.** Create Taskwarrior tasks through
  dev-loop-task using the conventions dev-loop consumes (`project:`,
  `acceptance:`, and `input:` naming the review branch). Do not write a review
  file.
- **A branch with findings is never merged.** It stays in place — it is the
  `input:` base its fix task will build on.
- **A clean branch is merged and deleted.** Use `dlr-merge.sh` — it merges into
  the current branch and deletes with `git branch -d` (safe delete only). This
  skill is explicitly authorized to delete a review branch it has just merged
  (or one already merged); never force-delete (`-D`) an unmerged branch.
- **Never push to a remote.** Merging and branch deletion are local only.
- **Run checks in the box, never on the host.** If a verdict needs the test
  suite/build/lint actually executed (not just read), use `dlr-test.sh` — it
  runs the command inside a Crabbox/Incus box, the same sandbox dev-loop uses,
  never on the host checkout. It never touches the producing task (which is
  usually already `done`): the lease is keyed on the branch itself, not a
  Taskwarrior uuid.
- **No LLM/agent attribution** in merge commits or task text — no
  `Co-Authored-By:`, no "Generated with"/"🤖". Merge commits keep git's default
  message. This overrides any default commit-trailer behavior.
- **Don't mutate the producing task** beyond the audit annotation
  `dlr-merge.sh` writes. Never `task done`/`modify` completed tasks.
- **Diagnostics to stderr; stdout is parseable.** `dlr-collect.sh` emits JSON;
  `dlr-diff.sh` emits the log+diff; `dlr-merge.sh` prints the resulting HEAD.
- **Branch on exit codes, not prose:** `0` ok · `20` precondition/usage · `30`
  missing-artifact or merge-conflict.

The review scripts live in `scripts/` next to this file, source
`dlr-common.sh`, and are re-runnable. Task creation's `dlt-create.sh` lives in
the dev-loop-task skill. Run review scripts from inside the target repo
checkout. The exit-code table and troubleshooting are in **reference.md** —
read it when a step fails or you need exact flags.

## Phase 1 — Collect the available review branches

```sh
scripts/dlr-collect.sh                # every available review branch
scripts/dlr-collect.sh <goal-slug>    # only branches produced by that project
```

Emits a JSON array on stdout, one object per **existing local branch**:
`{branch, merged, ahead, superseded, superseded_by, base, task}` where `task`
is the producing task's
context (`{uuid, short, description, project, status, end, base, commits,
summary, acceptance}`) or `null` when no task records the branch (ORPHAN).
Capture it once and triage:

```sh
branches="$(scripts/dlr-collect.sh)"
printf '%s' "$branches" | jq -r '.[] | "\(.branch)  \(if .merged then "MERGED" elif .superseded then "SUPERSEDED by \(.superseded_by)" else "+\(.ahead)" end)  \(.task.description // "ORPHAN")"'
```

- Empty match (`[]`, exit `0`) → report "no review branches to review" and stop.
- `merged: true` → already landed in the current branch; skip review and just
  clean it up with `dlr-merge.sh` (it detects this and only deletes).
- `superseded: true` → another task (short uuid in `superseded_by`) records this
  branch as its `input:` — a fix is stacked (or being stacked) on top. Do not
  review or merge it on its own; it lands, and becomes `merged: true`, when its
  successor's branch merges.
- `task: null` (ORPHAN) → review it anyway against generic quality; if it needs
  fix tasks, ask the user which project to file them under.

## Phase 2 — Review each unmerged branch

For every object with `merged: false` and `superseded: false`, in order:

1. **State the intent.** Read `task.description`, `task.acceptance`, and
   `task.summary` from the collected object — this is the bar the diff is
   judged against.
2. **Walk the diff:**

   ```sh
   scripts/dlr-diff.sh "$branch"               # log + diffstat + full patch
   scripts/dlr-diff.sh "$branch" --stat-only   # big change: triage by stat first
   scripts/dlr-diff.sh "$branch" -- -w         # pass extra flags to git diff
   ```

   The diff base is the task's recorded `base=` when it still resolves,
   otherwise `git merge-base HEAD <branch>`. Review for correctness against the
   acceptance criteria, regressions, missing tests, security issues (dev-loop
   forbids secrets in the box and remote pushes — confirm nothing slipped), and
   leftover debug/attribution.
3. **Run checks, if the verdict needs it.** Reading the diff is often enough;
   when it isn't (the acceptance criteria name a test/build command, or a
   change is risky enough that "looks right" isn't sufficient), execute it
   inside a box — never on the host:

   ```sh
   scripts/dlr-test.sh "$branch" -- bash -lc 'pytest -q'
   scripts/dlr-test.sh "$branch" --keep-box -- bash -lc 'make build'  # iterate, same box
   ```

   Same sandbox model as dev-loop's `dl-run.sh`: a dedicated worktree checked
   out at the branch's tip, a Crabbox/Incus lease, the command's exit code
   forwarded verbatim. Unlike dev-loop, the lease is keyed on the branch (not a
   task uuid) and nothing is written to Taskwarrior — the producing task is
   usually already `done` and this skill must not touch it beyond
   `dlr-merge.sh`'s audit annotation. Pass `--keep-box` to run more than one
   command without re-warming; the box stops automatically otherwise.
4. **Record a verdict:** **clean** (nothing worth a task) or **needs-fixes**
   (with the concrete findings behind it). Nits too small to be worth a task
   round-trip do not block a clean verdict — mention them in the summary.

**Chain tips get an integration check.** If the branch under review is the tip
of a stacked chain (its task's `input:` points at a prior task's branch, which
in turn had its own `input:`), judge it against the *chain's* assembled
behavior, not only its own slice — the earlier increments already passed their
individual acceptance criteria, so re-checking each in isolation adds nothing.
Look for an `acceptance:` on this task that asserts end-to-end behavior across
the chain. If one exists, verify the assembled system actually satisfies it
(read the diff across the whole chain, or run it in a box). If the final task
in the chain carries no such criterion, treat that absence itself as a finding:
note it in the summary as a decomposition smell (each increment may have
passed alone while never being joined end-to-end) even if the diff otherwise
looks clean.

## Phase 3 — Act on each verdict

### needs-fixes → create fix tasks with dev-loop-task

Create one task per independent finding, small enough for one box and one review
branch. File it under the producing task's project and atomically wire it to
build on the reviewed branch:

```sh
project="$(printf '%s' "$obj" | jq -r .task.project)"
producer="$(printf '%s' "$obj" | jq -r .task.short)"
fix="$(/path/to/dev-loop-task-skill/scripts/dlt-create.sh \
  --project "$project" \
  --description "fix: <one concrete finding>" \
  --acceptance "<how we know the finding is fixed>" \
  --input "$branch" \
  --review-of "$producer $branch")"
```

- `input:` is the annotation dev-loop's `dl-box.sh` reads to root the fix
  task's worktree at the review branch — the fix lands as a new increment on
  top of the reviewed work.
- `review-of:` is imported in the same operation, so a completed helper call
  always leaves a fully traceable task and returns that exact task's UUID.
- Use `depends:` between fix tasks when one must land before another. In
  particular, if two findings touch the same file, don't file both with
  `input: $branch` (the same original review branch) — chain them: the later
  creation call should use `--depends <earlier-fix-uuid>` and `--input
  <earlier-fix-review-branch>`. Request `--json` when creating the earlier fix
  to capture both values without reconstructing its slug. Siblings rooted on
  the same branch that edit the same lines are guaranteed to conflict for every
  branch after the first one merges.
- **Leave the branch alone** — do not merge or delete it; the fix task owns it
  now (the next `dlr-collect.sh` run will show it as `superseded`).

### clean → merge and clean up

```sh
scripts/dlr-merge.sh "$branch"             # merge into current branch + git branch -d
scripts/dlr-merge.sh "$branch" --dry-run   # preview
```

Also run it for each `merged: true` branch from Phase 1 — it skips the merge
and just deletes. It refuses on a dirty worktree (exit `20`) and, on a merge
**conflict**, aborts the merge, leaves the branch untouched, and exits `30` —
treat that as a finding: create a fix task
("rebase $branch onto <current-branch> and resolve conflicts") with
`input: $branch`, and move on.

## Phase 4 — Summarize inline

End with a short inline summary — no file:

```markdown
## dev-loop review — <n> branches
| branch | task | verdict | action |
|--------|------|---------|--------|
| review/x | abc12345 implement X | clean | merged + deleted |
| review/y | def67890 test X | needs-fixes | 2 fix tasks: <shorts> |
| review/z | ORPHAN | conflict | fix task <short> created |
```

Plus 2–4 lines of cross-cutting observations (duplicated work, inconsistent
patterns, gaps) and, if fix tasks were created, note that another dev-loop run
(`dev-loop` skill, Phases 2–5) will pick them up. State that finding tasks were
left pending and unclaimed.

Defer to `task <uuid> info` for anything not in the collected object, and to
dev-loop's own reference for how the annotations got there.
