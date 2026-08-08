---
name: dev-create-tasks
description: Create or refine durable, implementation-ready Taskwarrior development tasks without claiming or executing them. Use for filing, queuing, or decomposing development work, including follow-up findings.
---

# Dev Create Tasks

Create pending, unclaimed work through `scripts/dct-create.sh`, then stop. Let
`CREATE_SKILL` be this skill's absolute directory and `LOOP_SKILL` its sibling
`dev-loop`; keep the target Git repository as the current directory. The helper
derives and validates repository identity. Use `--help` for its argument contract.

## Boundary

- Mutate only Taskwarrior. Do not claim, implement, test, or create branches.
- Keep tasks reconstructable without conversation history or agent attribution.
- Run `task rc.confirmation=no sync` before inspection and after the complete
  batch. Accept only the helper's explicit unconfigured-sync result.
- Treat `AGENT_PID` and `AGENT_NOTIFY` as controller-owned lifecycle values:
  inherit them verbatim; never assign, overwrite, or unset them.
- End every run by calling `dl-finish.sh`; see [Finish](#finish).

## Design the task set

Default to one task per coherent outcome. Split when work needs independent
bases or acceptance decisions, or cannot fit in one isolated worktree. Give
every task an outcome-oriented description and observable `acceptance:`.

Use both `--depends <producer>` and `--input <producer-branch>` when code
ancestry matters. Put end-to-end acceptance on the final task in a stack. Use
`--small` only for narrow, mechanical, fully specified work; never assign
`+LARGE` during initial creation. Use `--plan` for a decomposition task whose
deliverable is finer-grained tasks rather than code: attach its plan artifact
via the implement skill's `dl_plan_put`, and leave it for the sibling
`dev-decompose-task` skill — work queues never claim `+PLAN` tasks.

For an existing goal, run the sibling controller's read-only state helper:

```sh
"$LOOP_SKILL/scripts/dl-loop-state.sh" --goal '<goal-slug>'
```

Reuse its loop ID and existing equivalent tasks. A new state supplies a fresh
loop ID. Never combine contradictory loops.

## Create and verify

Create initial work with a shared goal and loop ID:

```sh
uuid="$("$CREATE_SKILL/scripts/dct-create.sh" --goal "$goal" --loop-id "$loop_id" \
  --description 'implement X' --acceptance 'X passes focused checks')"
```

Create findings with `--from-task <producer>`; add dependency, input branch,
review ancestry, and an explicit round only when the default next round is not
correct. Use `--json` when wiring a predicted review branch.

After final sync, export returned UUIDs and verify pending status, no start or
assignee, identity, acceptance, routing, dependencies, and ancestry. Report the
goal/loop identity and created UUIDs, stating that none were claimed.

Invoke `dev-ask` only when an environmental or harness failure occurs.

## Finish

Every run ends with this command, including runs that created no task:

```sh
"$LOOP_SKILL/scripts/dl-finish.sh" tasks-created "$loop_id"
```

The single exception is a composed run: skip this only when `dev-loop` loaded
this skill as a stage in the current session and will finish on your behalf. If
you are not certain you are that case, you are not that case — run it.

Report first, then run it. Nothing follows it: no summary, no verification, no
closing message. Reaching the end of your turn without it is an incomplete run,
not a finished one — the worker process stays alive holding its queue, and the
poll loop launches nothing until someone kills it by hand.

Preserve inherited `AGENT_PID` and `AGENT_NOTIFY` verbatim so the command can
notify the controller and terminate the worker; never alter either value to make
the helper return successfully.
