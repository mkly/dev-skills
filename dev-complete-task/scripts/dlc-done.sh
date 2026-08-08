#!/usr/bin/env bash
# dlc-done.sh — finalize a reviewed task and park its box for reuse.
#
#   dlc-done.sh <uuid> --outcome <merged|stacked|superseded|decomposed>
#               [--stop-box] [--keep-worktree] [--force] [--dry-run]
#
# Parks the task's live crabbox lease for the next task (or explicitly stops it),
# removes the task's per-task git worktree and its scratch branch dl/<slug> (the
# review/<slug> branch is KEPT), marks the task done (which drops it from pending
# and releases both claims), and records a lifecycle annotation. Any worker may
# first acquire the separate reviewer claim; a task implemented by another owner
# is annotated as a handoff rather than refused.
#
# Exit: 0 ok, 20 precondition.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL_SKILL_DIR="${DEV_IMPLEMENT_TASK_SKILL_DIR:-$(cd "$SCRIPT_DIR/../../dev-implement-task" 2>/dev/null && pwd || true)}"
[ -n "$IMPL_SKILL_DIR" ] && [ -f "$IMPL_SKILL_DIR/scripts/dl-common.sh" ] || {
  printf 'dev-complete-task: ERROR: cannot locate dev-implement-task/scripts/dl-common.sh; install the skills as siblings or set DEV_IMPLEMENT_TASK_SKILL_DIR\n' >&2
  exit 20
}
# shellcheck source=../../dev-implement-task/scripts/dl-common.sh
. "$IMPL_SKILL_DIR/scripts/dl-common.sh"
# shellcheck source=dlc-common.sh
. "$SCRIPT_DIR/dlc-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlc-done.sh <uuid> --outcome <merged|stacked|superseded|decomposed>
                   [--stop-box] [--keep-worktree] [--force] [--dry-run] [-h|--help]

  --outcome        terminal review disposition (required); `decomposed`
                   finalizes a +PLAN task whose follow-up tasks are recorded
                   in decomposed-into= annotations — it has no review branch,
                   so the implementation claim (not a reviewer claim) is the
                   finalization lock
  --stop-box       stop the crabbox lease instead of parking it for reuse
  --keep-worktree  leave the per-task worktree + scratch branch in place
  --force          bypass the unmerged-worktree guard
  --dry-run        log mutations instead of performing them

Exit: 0 ok, 20 precondition.
EOF
}

UUID=""; OUTCOME=""; STOP_BOX=0; KEEP_WT=0; FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outcome)
      shift
      [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--outcome needs a value"; }
      OUTCOME="$1" ;;
    --stop-box)      STOP_BOX=1 ;;
    --keep-box)      dl_warn "--keep-box is deprecated; parking is now the default" ;;
    --keep-worktree) KEEP_WT=1 ;;
    --force)    FORCE=1 ;;
    --dry-run)  DL_DRY_RUN=1 ;;
    -h|--help)  usage; exit 0 ;;
    -*) usage; dl_die "$DL_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$UUID" ] || { usage; dl_die "$DL_PRECOND" "unexpected extra argument: $1"; }
        UUID="$1" ;;
  esac
  shift
done
[ -n "$UUID" ] || { usage; dl_die "$DL_PRECOND" "task uuid required"; }
case "$OUTCOME" in
  merged|stacked|superseded|decomposed) ;;
  "") usage; dl_die "$DL_PRECOND" "--outcome is required" ;;
  *) usage; dl_die "$DL_PRECOND" "invalid --outcome '$OUTCOME' (expected merged, stacked, superseded, or decomposed)" ;;
esac

dl_require task jq crabbox git
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"

status="$(dl_task_field "$UUID" '.status // ""')"
if [ "$status" = "completed" ]; then
  if [ -n "$(dlc_anno_get "$UUID" reviewer)" ]; then
    dlc_require_reviewer "$UUID"
    dl_do dl_task "$UUID" annotate "review-start="
    dl_do dl_task "$UUID" annotate "reviewer="
  fi
  dl_log "task $UUID already completed"
  exit "$DL_OK"
fi

assignee="$(dl_task_field "$UUID" '.assignee // ""')"
implementer="$(owner_base "$assignee")"

if [ "$OUTCOME" = "decomposed" ]; then
  # Decomposition tasks never enter review (dlc-claim requires a branch and
  # summary they do not have). The implementation claim taken by
  # dl-claim.sh --plan is the finalization lock instead: only the exact agent
  # holding it may finalize.
  [ -n "$implementer" ] && [ "$implementer" = "$DEV_LOOP_OWNER" ] \
    || dl_die "$DL_LOST" "task $UUID outcome=decomposed requires the implementation claim; held by '${implementer:-nobody}', you are '$DEV_LOOP_OWNER'"
  held_nonce="${assignee#*#}"
  [ "$held_nonce" != "$assignee" ] || held_nonce=""
  if [ -n "${AGENT_PID:-}" ] && [ -n "$held_nonce" ] && [ "$held_nonce" != "$AGENT_PID" ]; then
    dl_die "$DL_LOST" "task $UUID is held by a concurrent agent sharing owner '$implementer' (holder nonce $held_nonce, ours $AGENT_PID)"
  fi
else
  # The implementation assignee and reviewer are independent. Only the exact
  # reviewer agent that claimed this task may give it a terminal disposition.
  # The implementation owner is recorded as a handoff below, not treated as a
  # competing claim.
  dlc_require_reviewer "$UUID"
fi

branch="$(dl_anno_get "$UUID" branch)"
base="$(dl_anno_get "$UUID" base)"
commits="$(dl_anno_get "$UUID" commits)"

dl_in_git_repo
case "$OUTCOME" in
  merged)
    [ -n "$branch" ] || dl_die "$DL_PRECOND" "task $UUID has no recorded review branch"
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
      dl_die "$DL_PRECOND" "review branch '$branch' still exists; run dlc-merge.sh before finalizing outcome=merged"
    fi
    range="${commits%% *}"
    head="${range#*..}"
    [ -n "$commits" ] && [ "$head" != "$range" ] \
      || dl_die "$DL_PRECOND" "task $UUID has no parseable commits= range"
    git cat-file -e "${head}^{commit}" 2>/dev/null \
      || dl_die "$DL_PRECOND" "recorded implementation head '$head' does not resolve"
    git merge-base --is-ancestor "$head" HEAD >/dev/null 2>&1 \
      || dl_die "$DL_PRECOND" "recorded implementation head '$head' is not integrated into current HEAD"
    dl_plan_clear "$UUID"
    ;;
  stacked|superseded)
    [ -n "$branch" ] || dl_die "$DL_PRECOND" "task $UUID has no recorded review branch to preserve"
    git show-ref --verify --quiet "refs/heads/${branch}" \
      || dl_die "$DL_PRECOND" "review branch '$branch' is missing; refusing outcome=$OUTCOME"
    ;;
  decomposed)
    [ -n "$(dlc_anno_get "$UUID" decomposed-into)" ] \
      || dl_die "$DL_PRECOND" "task $UUID has no decomposed-into= annotation; create the follow-up tasks and record their UUIDs first"
    dl_plan_clear "$UUID"
    ;;
esac

# Remove the per-task worktree and its scratch branch (best-effort). The
# review/<slug> branch is shared in the repo and is KEPT — only the throwaway
# worktree + dl/<slug> pointer go away, freeing the tree for reuse and keeping
# `git worktree list` clean. Must run from inside the repo (not the worktree).
if [ "$KEEP_WT" -ne 1 ]; then
  wt="$(dl_anno_get "$UUID" worktree)"
  if [ -n "$wt" ] && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -d "$wt" ] && [ "$FORCE" -ne 1 ] && [ -z "$branch" ] && dl_worktree_dirty_vs_base "$wt" "$base"; then
      dl_die "$DL_PRECOND" "worktree has unmerged changes and no review branch; run dl-merge-back.sh <uuid> first, or pass --force / --keep-worktree"
    fi
    prefix="${DEV_LOOP_WORKTREE_DIR}/$(dl_repo_key)/"
    case "$wt" in
      "$prefix"*) ;;
      *)
        dl_warn "recorded worktree $wt is outside this repo's dev-loop worktree dir ($prefix); leaving it in place"
        wt=""
        ;;
    esac
  fi
  if [ -n "$wt" ] && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -d "$wt" ]; then
      wt_phys="$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
      cwd_phys="$(pwd -P)"
      if [ "$cwd_phys" = "$wt_phys" ] || [[ "$cwd_phys" == "$wt_phys/"* ]]; then
        main_checkout="$(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1 || true)"
        retry_cmd="$0 $UUID"
        [ "$STOP_BOX" -eq 1 ] && retry_cmd="$retry_cmd --stop-box"
        [ "$FORCE" -eq 1 ] && retry_cmd="$retry_cmd --force"
        dl_warn "current directory is inside the worktree being removed; leaving it in place"
        if [ -n "$main_checkout" ] && [ "$main_checkout" != "$wt_phys" ]; then
          dl_warn "run from the main checkout: cd '$main_checkout' && $retry_cmd"
        else
          dl_warn "run from the main checkout and retry: $retry_cmd"
        fi
        wt=""
      fi
    fi
  fi
  if [ -n "$wt" ] && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    desc="$(dl_task_field "$UUID" '.description // ""')"
    wbranch="dl/$(dl_slug "$UUID" "$desc")"
    dl_log "removing worktree $wt (scratch branch $wbranch)"
    dl_do git worktree remove --force "$wt" 2>/dev/null \
      || dl_warn "could not remove worktree $wt (may already be gone)"
    dl_do git worktree prune 2>/dev/null || true
    dl_do git branch -D "$wbranch" 2>/dev/null \
      || dl_warn "could not delete scratch branch $wbranch (may already be gone)"
  elif [ -n "$wt" ]; then
    dl_warn "not inside a git repo; leaving worktree $wt in place (remove with: git worktree remove --force '$wt')"
  fi
fi

# Only expose the lease for reuse after the unmerged-worktree guard and cleanup
# have succeeded. Crabbox's idle timeout reaps it if the loop ends here.
handle="$(dl_anno_get "$UUID" box)"
holder=""
[ -z "$handle" ] || holder="$(dl_box_holder "$handle" "$UUID")"
if [ -n "$handle" ] && [ -n "$holder" ]; then
  # Another pending task adopted this lease while we held it recorded. It is
  # not ours to park or stop; both would disrupt a live task.
  dl_warn "box $handle is held by task ${holder:0:8}; leaving it alone"
elif [ -n "$handle" ]; then
  if [ "$STOP_BOX" -eq 1 ]; then
    dl_log "stopping box $handle"
    dl_do crabbox stop -provider "$CRABBOX_PROVIDER" -id "$handle" || dl_warn "could not stop box $handle (may already be gone)"
  elif [ -n "$DL_DRY_RUN" ]; then
    dl_log "DRY-RUN: park box $handle for the next task"
  elif dl_box_alive "$handle"; then
    parked="$(head -n1 "$(dl_idle_box_file)" 2>/dev/null || true)"
    if [ -n "$parked" ] && [ "$parked" != "$handle" ] && dl_box_alive "$parked"; then
      dl_log "a box is already parked ($parked); stopping box $handle"
      dl_do crabbox stop -provider "$CRABBOX_PROVIDER" -id "$handle" || dl_warn "could not stop box $handle (may already be gone)"
    else
      dl_idle_box_park "$handle"
      dl_log "parked box $handle for the next task (idle timeout will reap it)"
    fi
  else
    dl_warn "could not park box $handle (it is no longer live)"
  fi
fi

if [ -n "$implementer" ] && [ "$implementer" != "$DEV_LOOP_OWNER" ]; then
  dl_anno_event "$UUID" "completion handoff from $implementer"
fi
dl_anno_event "$UUID" "completed outcome=$OUTCOME${branch:+ (review branch: $branch)}"
# shellcheck disable=SC1010  # 'done' is the Taskwarrior subcommand, not a loop keyword
dl_do dl_task "$UUID" done
if [ "$OUTCOME" != "decomposed" ]; then
  dl_do dl_task "$UUID" annotate "review-start="
  dl_do dl_task "$UUID" annotate "reviewer="
fi
case "$OUTCOME" in
  merged) dl_log "done: $UUID — merged review accepted" ;;
  stacked) dl_log "done: $UUID — review branch \"$branch\" preserved for its planned successor" ;;
  superseded) dl_log "done: $UUID — review branch \"$branch\" preserved for follow-up fixes" ;;
  decomposed) dl_log "done: $UUID — decomposed into the tasks recorded in decomposed-into= annotations" ;;
esac
