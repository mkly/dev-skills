---
name: dev-loop-task
description: >-
  Create or refine one or more durable Taskwarrior tasks that dev-loop can
  consume later, without claiming, starting, implementing, testing, or reviewing
  them. Use when asked to create, add, file, queue, or capture a development task
  for later; to decompose a goal into tasks without beginning work; or as the
  shared task-creation component loaded by dev-loop, dev-loop-review, or
  dev-loop-complete.
---

# Dev Loop Task

Turn development intent into pending, unclaimed Taskwarrior work and stop. Make
the task durable enough that a later agent can reconstruct scope, ordering, and
acceptance without relying on conversation history.

## Operating boundary

- **Only mutate Taskwarrior.** Read the target repository when needed to make
  scope and acceptance concrete, but do not edit files, create branches, or run
  implementation commands.
- **Never start execution.** Do not run `task start`, `dl-claim.sh`,
  `dl-setup.sh`, Crabbox/Incus commands, tests, merge-back, or review actions.
  Every created task must remain pending, unstarted, and unassigned.
- **Return control at the boundary.** When invoked directly, report the created
  task UUIDs and stop. When loaded by another dev-loop skill, return the UUIDs
  to that controller; the caller decides whether its broader authorization
  permits claiming or continuing.
- **Do not add LLM/agent attribution** to descriptions or annotations.
- **Keep stdout parseable.** The bundled helper prints only the exact created
  UUID by default. Diagnostics go to stderr.

The helper is bundled with this skill. In examples,
`/path/to/dev-loop-task-skill` means the directory containing this `SKILL.md`.
It requires `task` and `jq`, but it does not require a git repository,
dev-loop setup, Crabbox, or Incus.

## 1. Establish the task set

Run `task rc.confirmation=no sync` before inspecting or creating tasks. Continue
when it succeeds or reports `No sync.* settings are configured`; the latter
means there is simply nothing to sync. Stop on any other sync failure.
`dlt-create.sh` repeats this check immediately before each real import and skips
it for `--dry-run`.

State the requested outcome in observable terms. Choose one existing project
slug when the work belongs to an active goal; otherwise choose a concise unused
slug. Inspect pending tasks before creating anything and reuse an existing task
when it already captures the same intent and acceptance:

```sh
task rc.context=none rc.json.array=on rc.verbose=nothing status:pending export \
  | jq --arg project '<goal-slug>' \
       '[.[] | select(.project == $project) | {uuid, status, start, assignee, description, depends, annotations}]'
```

Do not create a duplicate merely because wording differs. If an existing task
is clearly the same work but lacks an acceptance note, refine that task in
Taskwarrior and report it instead of adding another. If the matching task is
already started or assigned, do not mutate or duplicate it; report its owner and
state.

Default to one task for one coherent outcome. Split only when pieces need
different bases, different reviewers, genuinely independent accept/reject
decisions, or cannot reasonably fit in one box and one review branch. Batch
trivial related edits because every task pays claim, warmup, merge-back, and
review overhead.

## 2. Encode the durable contract

Give every task:

- one project slug;
- a concise outcome-oriented description;
- at least one `acceptance: <observable proof>` annotation; and
- dependencies and branch inputs when ordering matters.

Use these annotation conventions:

| Annotation | Purpose |
|---|---|
| `acceptance: ...` | One or more checks/outcomes that prove the task is done |
| `input: <ref>` | Branch/ref on which the task's worktree must be based |
| `review-of: <short> <branch>` | Trace a review finding back to its producer |
| `loop-round: <n>` | Round metadata supplied by dev-loop-complete |

Ordering and code ancestry are separate. `depends:<producer>` keeps a consumer
out of `+READY`; `input: review/<producer-slug>` tells `dl-box.sh` which code to
build on. When a consumer needs a producer's output, record both.

If tasks touch the same files or one consumes another, chain them rather than
creating sibling branches from one base. Give the final task in every stacked
chain an additional end-to-end acceptance criterion for the assembled behavior.

## 3. Create each task atomically

Use `dlt-create.sh`, not `task add` followed by `task +LATEST`. The helper
generates the UUID first and imports the complete task—including acceptance,
dependencies, and annotations—in one Taskwarrior operation. This makes its
returned UUID exact even when other agents create tasks concurrently.
TaskChampion/SQLite serializes the import.

Create a simple task:

```sh
uuid="$(/path/to/dev-loop-task-skill/scripts/dlt-create.sh \
  --project '<goal-slug>' \
  --description 'implement X' \
  --acceptance 'the named behavior is observable and its focused checks pass')"
```

Repeat `--acceptance`, `--depends`, and `--annotation` as needed. Use
`--input`, `--review-of`, and `--loop-round` for their corresponding durable
annotations.

For a chain, request JSON so the helper also returns the producer's predicted
default review branch:

```sh
producer_json="$(/path/to/dev-loop-task-skill/scripts/dlt-create.sh --json \
  --project '<goal-slug>' --description 'implement X' \
  --acceptance 'X passes its focused checks')"
producer="$(printf '%s' "$producer_json" | jq -r .uuid)"
producer_branch="$(printf '%s' "$producer_json" | jq -r .review_branch)"

consumer="$(/path/to/dev-loop-task-skill/scripts/dlt-create.sh \
  --project '<goal-slug>' --description 'integrate X with Y' \
  --depends "$producer" --input "$producer_branch" \
  --acceptance 'Y consumes X successfully' \
  --acceptance 'end-to-end: the assembled X-to-Y flow produces the expected result')"
```

The predicted branch matches dev-loop's default `review/<task-slug>`. Do not
change a producer's description after wiring a consumer to that prediction, and
do not use a custom merge-back branch for such a producer unless you also fix
the consumer's `input:` annotation.

Pass `--dry-run` to validate inputs and preview the imported JSON without
writing Taskwarrior. A dry run still emits a proposed UUID; it does not identify
an existing task. Add `--json` to distinguish it via `"created": false`.

## 4. Verify and report

After creation, inspect each returned UUID:

```sh
task rc.context=none rc.json.array=on rc.verbose=nothing "$uuid" export \
  | jq '.[0] | {uuid, status, start, assignee, project, description, depends, annotations}'
```

Confirm that it is pending, has no `start` or assignee, contains every planned
acceptance criterion, and has the intended dependencies and input branch.
Report the project, short UUID, description, dependencies/readiness, and
acceptance criteria. End with an explicit statement that no task was claimed or
started.

The helper exits `20` for usage, missing tools, sync failures,
ambiguous/missing dependencies, import failures, or failed verification. Treat
a missing/broken `task` or `jq` installation as an environment problem and
apply dev-ask; do not recreate the helper's import workflow by hand.
