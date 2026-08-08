---
name: dev-decompose-task
description: Claim one +PLAN decomposition task, read its attached plan artifact, create the finer-grained follow-up tasks it describes, and finalize it as decomposed. Use for draining the plan queue; never implements code.
---

# Dev Decompose Task

Turn one `+PLAN` task into its pending, unclaimed follow-up tasks. Let
`IMPLEMENT_SKILL`, `CREATE_SKILL`, and `COMPLETE_SKILL` be the sibling
`dev-implement-task`, `dev-create-tasks`, and `dev-complete-task` skill
directories; keep the target Git repository as the current checkout.

## Boundary

- Mutate only Taskwarrior. Never create branches, worktrees, or boxes, edit
  repository files, or implement any of the work the plan describes.
- Never claim, start, or reorder the follow-up tasks you create; leave them
  pending and unclaimed for the ordinary work queues.
- Preserve one stable `DEV_LOOP_OWNER` throughout the task. Treat `AGENT_PID`
  and `AGENT_NOTIFY` as controller-owned lifecycle values: inherit them
  verbatim; never assign, overwrite, or unset them.
- Run `task rc.confirmation=no sync` before claiming and after the complete
  batch. Accept only the helper's explicit unconfigured-sync result.

## Decompose

1. Claim from the plan queue (bind goal, loop ID, and round when a controller
   supplies them):

   ```sh
   uuid="$("$IMPLEMENT_SKILL/scripts/dl-claim.sh" --plan [--goal "$goal" --loop-id "$loop_id"])"
   ```

   Empty stdout means no claimable plan task; exit `10` means the claim was
   lost — do not touch the task in either case.
2. Read the full contract: the task's description and `acceptance:`
   annotations, and the attached plan artifact:

   ```sh
   . "$IMPLEMENT_SKILL/scripts/dl-common.sh"
   dl_plan_get "$uuid"
   ```

   Follow at most one `plan: <uuid>` annotation hop if the artifact lives on
   another task. A plan task with no readable plan artifact and no
   self-contained annotations is not decomposable; release it with
   `$IMPLEMENT_SKILL/scripts/dl-release.sh` and report the defect.
3. Design the follow-up set from the plan: one task per coherent outcome, each
   with an outcome-oriented description and observable `acceptance:`. Wire
   `--depends` (and `--input` where code ancestry matters) between siblings and
   to still-pending external dependencies. Put end-to-end acceptance on the
   final task of a stack. Use `--small` only for narrow mechanical work. A
   child that still needs its own decomposition is created with `--plan` and a
   plan artifact of its own (`dl_plan_put`).
4. Create every child with inherited identity:

   ```sh
   child="$("$CREATE_SKILL/scripts/dct-create.sh" --from-task "$uuid" \
     --description '<outcome>' --acceptance '<observable criterion>' ...)"
   ```

5. Record each created child on the producer:

   ```sh
   dl_task "$uuid" annotate "decomposed-into=$child"
   ```

6. Finalize. Decomposition has no review stage; the implementation claim from
   step 1 is the finalization lock:

   ```sh
   "$COMPLETE_SKILL/scripts/dlc-done.sh" "$uuid" --outcome decomposed
   ```

7. Sync, then verify every child is pending, unstarted, and unassigned with
   correct identity, acceptance, and dependencies, and the producer is
   completed with its `decomposed-into=` annotations intact.

Report the producer UUID, the created child UUIDs with one-line descriptions,
and the dependency shape, stating that no child was claimed. For a standalone
final handoff, run `"$LOOP_SKILL/scripts/dl-finish.sh" tasks-created "$loop_id"`
with `LOOP_SKILL` the sibling `dev-loop`. Invoke `dev-ask` only for an
environmental or harness failure.

On an exceptional path — an unworkable plan, an assumption the plan got wrong,
or a blocker another queue will hit too — load the sibling `dev-board` skill and
post it; `loop` exports `DEV_BOARD_ROOT`. Task state stays in Taskwarrior.
