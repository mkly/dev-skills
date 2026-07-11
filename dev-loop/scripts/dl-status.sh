#!/usr/bin/env bash
# dl-status.sh — read-only overview + box/claim reconciliation.
#
#   dl-status.sh [-h]
#
# Reports: your active claims, ALL active claims (owner + age + staleness),
# live crabbox leases, and reconciliation — orphan leases (running but not
# referenced by any pending task) and dangling box refs (task points at a lease
# that is gone). Mutates nothing; use dl-release.sh/dl-done.sh to act on it.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

case "${1:-}" in -h|--help)
  printf 'Usage: dl-status.sh [-h]\n\nRead-only claim + box reconciliation report.\n' >&2; exit 0 ;;
esac

dl_require task jq crabbox

stale_secs="$(dl_dur_to_secs "$DEV_LOOP_STALE")"
now="$(date -u +%s)"
fmt_age() { local s="$1"; printf '%dh%02dm' "$(( s/3600 ))" "$(( (s%3600)/60 ))"; }

printf 'dev-loop status   owner=%s   provider=%s   stale>=%s\n' \
  "$DEV_LOOP_OWNER" "$CRABBOX_PROVIDER" "$DEV_LOOP_STALE"
printf -- '----------------------------------------------------------------\n'

# Referenced boxes: handle -> uuid for every pending task that has one.
declare -A REF_UUID
mapfile -t pending < <(dl_task_export status:pending | jq -r '.[].uuid' 2>/dev/null || true)

printf 'Active claims:\n'
any_active=0
for u in ${pending[@]+"${pending[@]}"}; do
  [ -n "$u" ] || continue
  handle="$(dl_anno_get "$u" box)"
  if [ -n "$handle" ]; then REF_UUID["$handle"]="$u"; fi

  start="$(dl_task_field "$u" '.start // ""')"
  [ -n "$start" ] || continue            # not +ACTIVE
  any_active=1
  assignee="$(dl_task_field "$u" '.assignee // ""')"
  desc="$(dl_task_field "$u" '.description // ""')"
  epoch="$(dl_ts_to_epoch "$start")"
  if [ -n "$epoch" ]; then age=$(( now - epoch )); else age=0; fi
  mark="    "
  [ "${assignee%%#*}" = "$DEV_LOOP_OWNER" ] && mark=" *  "
  flag=""
  [ "$age" -ge "$stale_secs" ] && flag="  [STALE]"
  printf '%s%s  %-22s  age %-7s  %s%s\n' \
    "$mark" "${u:0:8}" "${assignee:-<none>}" "$(fmt_age "$age")" "${desc:0:40}" "$flag"
done
[ "$any_active" -eq 1 ] || printf '  (none)\n'
printf '  (* = owned by you)\n'

# Live leases from crabbox.
printf '\nLive leases:\n'
leases_json="$(crabbox list -provider "$CRABBOX_PROVIDER" -json 2>/dev/null || echo '[]')"
if ! printf '%s' "$leases_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
  printf '  (could not list leases for provider %s)\n' "$CRABBOX_PROVIDER"
  leases_json='[]'
fi

declare -a ORPHANS=()
had_lease=0
parked_box="$(head -n1 "$(dl_idle_box_file)" 2>/dev/null || true)"
while IFS=$'\t' read -r lid lslug llabel; do
  [ -n "$lid$lslug" ] || continue
  had_lease=1
  # Guard the array subscript: a lease can report an empty id (only a slug), and
  # `${REF_UUID[]}` is a fatal "bad array subscript" under `set -u`. Only index
  # with a non-empty key, falling back from id to slug.
  ref=""
  [ -n "$lid" ] && ref="${REF_UUID[$lid]:-}"
  if [ -z "$ref" ] && [ -n "$lslug" ]; then ref="${REF_UUID[$lslug]:-}"; fi
  if [ -n "$ref" ]; then
    printf '  %-28s  task %s  %s\n' "${lid:-$lslug}" "${ref:0:8}" "${llabel}"
  elif [ -n "$parked_box" ] && { [ "$lid" = "$parked_box" ] || [ "$lslug" = "$parked_box" ]; }; then
    printf '  %-28s  PARKED (idle box awaiting next task)  %s\n' "${lid:-$lslug}" "${llabel}"
  else
    printf '  %-28s  ORPHAN (no pending task references it)  %s\n' "${lid:-$lslug}" "${llabel}"
    ORPHANS+=("${lid:-$lslug}")
  fi
done < <(printf '%s' "$leases_json" \
  | jq -r '.[]?
      | [ (.labels.lease // .lease // (.id|strings) // .ID // .name // ""),
          (.labels.slug  // .slug  // .Slug // ""),
          (.name // .label // .Label // "") ]
      | @tsv' 2>/dev/null || true)
[ "$had_lease" -eq 1 ] || printf '  (none)\n'

# Dangling box refs: a pending task points at a lease that is not live.
mapfile -t live_ids < <(printf '%s' "$leases_json" \
  | jq -r '.[]? | (.labels.lease // .lease // (.id|strings) // .ID // .name // ""), (.labels.slug // .slug // .Slug // "")' 2>/dev/null | sort -u || true)
is_live() { local h="$1" x; for x in ${live_ids[@]+"${live_ids[@]}"}; do [ "$x" = "$h" ] && return 0; done; return 1; }

printf '\nDangling box refs:\n'
any_dangle=0
for h in "${!REF_UUID[@]}"; do
  if ! is_live "$h"; then
    any_dangle=1
    printf '  task %s references box %s which is not live (annotation is stale)\n' "${REF_UUID[$h]:0:8}" "$h"
  fi
done
[ "$any_dangle" -eq 1 ] || printf '  (none)\n'

# Per-task git worktrees for THIS repo (under DEV_LOOP_WORKTREE_DIR). Flags
# ORPHAN (registered but no pending task references it — left by a completed or
# released task) and MISSING (a pending task records a worktree= path whose dir
# is gone — re-run dl-box.sh to recreate it).
printf '\nWorktrees:\n'
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  declare -A WT_UUID
  for u in ${pending[@]+"${pending[@]}"}; do
    [ -n "$u" ] || continue
    wt="$(dl_anno_get "$u" worktree)"
    [ -n "$wt" ] && WT_UUID["$wt"]="$u"
  done
  prefix="${DEV_LOOP_WORKTREE_DIR}/$(dl_repo_key)/"
  had_wt=0
  while IFS= read -r line; do
    case "$line" in "worktree "*) path="${line#worktree }" ;; *) continue ;; esac
    case "$path" in "$prefix"*) ;; *) continue ;; esac
    had_wt=1
    ref="${WT_UUID[$path]:-}"
    if [ -n "$ref" ]; then
      printf '  %-48s  task %s\n' "$path" "${ref:0:8}"
      unset 'WT_UUID[$path]'
    else
      printf '  %-48s  ORPHAN (no pending task references it)\n' "$path"
    fi
  done < <(git worktree list --porcelain 2>/dev/null || true)
  for wt in "${!WT_UUID[@]}"; do
    [ -d "$wt" ] && continue
    had_wt=1
    printf '  %-48s  MISSING (task %s recorded it; re-run dl-box.sh)\n' "$wt" "${WT_UUID[$wt]:0:8}"
  done
  [ "$had_wt" -eq 1 ] || printf '  (none)\n'
  printf '  prune stale registrations with:  git worktree prune\n'
else
  printf '  (not inside a git repository)\n'
fi

# Review branches: the OUTPUT of the pipeline — one local branch per task that
# merged back. Git is ground truth that a branch exists; the producing task is
# found by reverse-mapping its branch= annotation across ALL tasks (incl.
# completed — the producer is usually completed by the time you look). For each
# branch we report merge state against the current checkout: MERGED (tip is an
# ancestor of HEAD → reviewed/landed, safe to `git branch -d`) vs unmerged
# (still awaiting review, with its ahead count). Flags ORPHAN branches no task
# records, and GONE branches a task recorded but that no longer exist (already
# merged + deleted) — so "what's waiting to merge" is answerable at a glance.
printf '\nReview branches:\n'
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  declare -A BR_UUID BR_STATUS
  while IFS=$'\t' read -r b u s; do
    [ -n "$b" ] || continue
    BR_UUID["$b"]="$u"; BR_STATUS["$b"]="$s"
  done < <(dl_task_export | jq -r '
      .[]
      | { b: ((.annotations // []) | map(.description)
              | map(select(startswith("branch="))) | last // ""),
          u: .uuid, s: .status }
      | select(.b != "")
      | "\(.b[7:])\t\(.u)\t\(.s)"' 2>/dev/null || true)

  cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD)"
  # Candidate set = every branch= annotation value ∪ every refs/heads/review/*
  # branch. (Annotations may name a custom branch outside review/*; the glob
  # catches review branches whose producing task's annotation was lost.)
  declare -A SEEN
  cands=()
  for b in "${!BR_UUID[@]}"; do cands+=("$b"); done
  while IFS= read -r b; do [ -n "$b" ] && cands+=("$b"); done \
    < <(git for-each-ref --format='%(refname:short)' refs/heads/review 2>/dev/null || true)

  had_br=0
  for b in ${cands[@]+"${cands[@]}"}; do
    [ -n "${SEEN[$b]:-}" ] && continue
    SEEN["$b"]=1
    had_br=1
    ref="${BR_UUID[$b]:-}"
    if git show-ref --verify --quiet "refs/heads/${b}"; then
      ahead="$(git rev-list --count "HEAD..${b}" 2>/dev/null || echo '?')"
      if git merge-base --is-ancestor "$b" HEAD >/dev/null 2>&1; then
        state="MERGED into ${cur} — safe: git branch -d ${b}"
      else
        state="unmerged (+${ahead} vs ${cur}) — awaiting review"
      fi
    else
      state="GONE (recorded but branch no longer exists — merged + deleted?)"
    fi
    if [ -n "$ref" ]; then
      printf '  %-44s  task %s [%s]  %s\n' "$b" "${ref:0:8}" "${BR_STATUS[$b]:-?}" "$state"
    else
      printf '  %-44s  ORPHAN (no task records it)  %s\n' "$b" "$state"
    fi
  done
  [ "$had_br" -eq 1 ] || printf '  (none)\n'
else
  printf '  (not inside a git repository)\n'
fi

if [ "${#ORPHANS[@]}" -gt 0 ]; then
  printf '\nHint: stop orphan leases with:  crabbox stop -provider %s -id <id>\n' "$CRABBOX_PROVIDER"
fi
