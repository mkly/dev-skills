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

## Design the task set

Default to one task per coherent outcome. Split when work needs independent
bases or acceptance decisions, or cannot fit in one isolated worktree. Give
every task an outcome-oriented description and observable `acceptance:`.

Use both `--depends <producer>` and `--input <producer-branch>` when code
ancestry matters. Put end-to-end acceptance on the final task in a stack. Use
`--small` only for narrow, mechanical, fully specified work; never assign
`+LARGE` during initial creation.

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

On a standalone final handoff, run
`"$LOOP_SKILL/scripts/dl-finish.sh" tasks-created "$loop_id"`. Do not run it as a
stage inside `dev-loop`. Invoke `dev-ask` only when an environmental or harness
failure occurs.
