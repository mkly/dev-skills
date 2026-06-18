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
while IFS=$'\t' read -r lid lslug llabel; do
  [ -n "$lid$lslug" ] || continue
  had_lease=1
  ref="${REF_UUID[$lid]:-}"; [ -n "$ref" ] || ref="${REF_UUID[$lslug]:-}"
  if [ -n "$ref" ]; then
    printf '  %-28s  task %s  %s\n' "${lid:-$lslug}" "${ref:0:8}" "${llabel}"
  else
    printf '  %-28s  ORPHAN (no pending task references it)  %s\n' "${lid:-$lslug}" "${llabel}"
    ORPHANS+=("${lid:-$lslug}")
  fi
done < <(printf '%s' "$leases_json" \
  | jq -r '.[]? | [ (.id//.ID//.name//.slug//.Slug//""), (.slug//.Slug//""), (.label//.Label//"") ] | @tsv' 2>/dev/null || true)
[ "$had_lease" -eq 1 ] || printf '  (none)\n'

# Dangling box refs: a pending task points at a lease that is not live.
mapfile -t live_ids < <(printf '%s' "$leases_json" \
  | jq -r '.[]? | (.id//.ID//.name//.slug//.Slug//""), (.slug//.Slug//"")' 2>/dev/null | sort -u || true)
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

if [ "${#ORPHANS[@]}" -gt 0 ]; then
  printf '\nHint: stop orphan leases with:  crabbox stop -provider %s -id <id>\n' "$CRABBOX_PROVIDER"
fi
