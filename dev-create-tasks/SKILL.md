---
name: dev-create-tasks
description: >-
  Create or refine durable, implementation-ready Taskwarrior tasks without
  claiming or executing them. Derive the Taskwarrior project autonomously from
  the current GitHub origin basename and scope each goal with durable goal,
  loop-id, and round annotations. Mark clearly trivial work +SMALL at creation
  for smaller-model workers. Use when asked to create, add, file, queue, or
  decompose development work, or when dev-complete-task or dev-loop needs the
  shared task-creation component for initial or follow-up work.
---

# Dev Create Tasks

Turn development intent into pending, unclaimed Taskwarrior work and stop. Make
each task reconstructable without conversation history.

## Operating boundary

- Read the target Git repository and Taskwarrior state, but only mutate
  Taskwarrior.
- Never claim, start, implement, test, create branches, or run Crabbox/Incus.
- Create every task through `scripts/dct-create.sh`; never use `task add`
  followed by `+LATEST`.
- Complete the batch-final sync before returning UUIDs to a controller.
- Keep tasks pending, unstarted, and unassigned.
- Do not add LLM or agent attribution to task text.

The helper requires `git`, `task`, and `jq`. Run it from inside the target Git
repository. In examples, `/path/to/dev-create-tasks-skill` is this skill's
installed directory.

## Repository and loop identity

Map one Taskwarrior project to one Git repository. Derive it without agent or
human naming judgment:

1. Read `git remote get-url origin`.
2. Require a standard GitHub SSH, HTTPS, HTTP, or Git URL.
3. Remove the path and trailing `.git` from the repository basename.
4. Lowercase the basename and use it as `project`.
5. Lowercase the owner/basename pair and record it as
   `repo-id: github.com/<owner>/<repo>`.

For `git@github.com:mkly/dev-loop.git`, create tasks with:

```text
project: dev-loop
repo-id: github.com/mkly/dev-loop
```

Ignore the checkout directory name. Never accept, invent, or infer an arbitrary
`--project`. A missing or non-GitHub origin is a precondition failure. If an
existing task uses the same project with a different nonempty `repo-id:`, stop
instead of mixing repositories. Legacy tasks without `repo-id:` do not by
themselves trigger the collision guard.

Keep goal/controller identity separate from the project:

| Field | Purpose |
|---|---|
| `project` | Lowercase GitHub origin basename; groups every task for the repository |
| `repo-id: ...` | Canonical GitHub owner/repository identity |
| `goal: ...` | Human-readable lowercase goal slug |
| `loop-id: ...` | UUID shared by every initial and follow-up task in one controller run |
| `loop-round: ...` | Positive implementation/completion round |
| `+SMALL` | Optional worker routing for a clearly trivial task |

Generate one loop UUID before creating the first task and reuse it across the
entire goal. Project-wide human queries use `task project:<repo> list`.
Controller queries must match both exact project equality and exact `loop-id:`;
project alone deliberately includes simultaneous or historical goals.

## 1. Establish the task set

Run `task rc.confirmation=no sync` before inspecting or creating tasks. Continue
on success or the explicit unconfigured-sync result; stop on any other failure.
`dct-create.sh` repeats this check before each real import and skips it for
`--dry-run`.

State the goal as an observable outcome and normalize it to a lowercase slug.
Before generating a loop ID, inspect pending tasks for the derived project and
filter their `repo-id:` and `goal:` annotations with `jq`. If exactly one valid
loop ID already has pending work for that repository/goal, reuse that loop ID
and its highest round. If none exists, generate one UUID and start at round 1.
Multiple active loop IDs for the same repository/goal are contradictory durable
state; stop rather than combine them. Then inspect the exact selected loop for
tasks that already capture the same intent and acceptance. Reuse those tasks;
never create duplicates merely because wording differs.

Default to one task for one coherent outcome. Split only when pieces need
different bases, independent accept/reject decisions, or cannot fit in one box
and review branch. Chain overlapping or consuming work.

Use `--small` only for a task that is mechanical, narrowly scoped, and fully
specified by its acceptance criteria. Leave ambiguous, architectural, or
multi-component work untagged for the standard queue. `+LARGE` is reserved for
later escalation and is never assigned during initial decomposition.

## 2. Encode the durable contract

Give every task:

- the automatically derived repository project and `repo-id:`;
- the shared `goal:` and `loop-id:`;
- a `loop-round:` (initial default is `1`);
- an outcome-oriented description;
- at least one `acceptance:` criterion; and
- dependencies and `input:` ancestry when ordering matters.

Add `+SMALL` through `--small` when the task meets the trivial-work rule above.

Additional annotations are:

| Annotation | Purpose |
|---|---|
| `acceptance: ...` | Observable proof the task is complete |
| `input: <ref>` | Branch/ref on which implementation must be based |
| `review-of: <short> <branch>` | Trace a finding to its producer |

Ordering and ancestry are separate. Use both `depends:<producer>` and
`input: review/<producer-slug>` when a consumer needs a producer's code. Put an
end-to-end acceptance criterion on the final task of every stacked chain. The
helper rejects a dependency whose repository, goal, or loop identity differs;
cross-loop ordering must be coordinated outside this lifecycle.

## 3. Create tasks atomically

Create initial tasks with the same goal and selected loop ID. For a new loop,
the round defaults to 1; when adding to a resumed loop, pass its current highest
round explicitly:

```sh
uuid="$(/path/to/dev-create-tasks-skill/scripts/dct-create.sh \
  --goal '<goal-slug>' \
  --loop-id "$loop_id" \
  --description 'implement X' \
  --acceptance 'X passes its focused checks')"
```

For a trivial task, add `--small`. This choice is explicit for each created
task and is not inherited automatically by `--from-task`.

Initial tasks default to `loop-round: 1`; pass `--loop-round` when resuming an
existing loop whose current round is later.

Create review-generated follow-up work by inheriting identity from the producer:

```sh
fix="$(/path/to/dev-create-tasks-skill/scripts/dct-create.sh \
  --from-task "$producer" \
  --description 'fix: <finding>' \
  --acceptance '<proof the finding is fixed>' \
  --depends "$producer" \
  --input "$producer_branch" \
  --review-of "${producer:0:8} $producer_branch")"
```

Without an explicit `--loop-round`, `--from-task` uses the producer's round plus
one. It requires the producer's project, `repo-id:`, `goal:`, `loop-id:`, and
`loop-round:` to match the current GitHub origin. Use an explicit round when
multiple chained fixes belong to the same next round.

Use `--json` to receive `uuid`, predicted `review_branch`, `project`, `repo_id`,
`goal`, `loop_id`, `loop_round`, `tags`, and `created`. Use that predicted branch when
wiring a dependent task. Do not change a producer description after using its
prediction.

Use `--dry-run` to validate and preview without importing. A dry run still
emits a proposed task UUID with `created: false`.

## 4. Verify and return

After the complete batch, run one final:

```sh
task rc.confirmation=no sync
```

Then export every returned UUID and verify:

- status is pending with no start or assignee;
- project equals the lowercase current GitHub origin basename;
- `repo-id:`, `goal:`, `loop-id:`, and `loop-round:` are exact;
- acceptance, dependencies, input, and review ancestry match the plan.
- `+SMALL` is present exactly when the task was assigned to the small queue.

Report the repository project, repo ID, goal, loop ID, round, worker queue, task UUIDs,
dependencies, and acceptance criteria. State explicitly that nothing was
claimed or started.

When running as a standalone worker, make this the last command after the final
sync and verification:

```sh
if [ -n "${AGENT_NOTIFY:-}" ]; then
  "$AGENT_NOTIFY" tasks-created "$loop_id" || true
fi
if [ -n "${AGENT_PID:-}" ]; then
  kill -TERM "$AGENT_PID"
fi
```

Notification is best-effort and must not strand the worker. Do not notify or
terminate when this skill is a stage inside `dev-loop`; the wrapper continues
with implementation and completion. If `AGENT_PID` is absent, report normally.

Treat helper exit `20`, missing tools, origin failures, collision detection,
sync failures, and malformed producer identity as environment/harness problems
under `dev-ask`. Never reconstruct the import workflow or guess a project name.
