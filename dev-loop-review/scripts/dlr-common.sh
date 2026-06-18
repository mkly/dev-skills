# shellcheck shell=bash
# dlr-common.sh — shared helpers for the dev-loop-review skill scripts.
# Sourced, never executed directly. Keep POSIX-ish bash; assume bash 4+.
#
# This skill is READ-ONLY with respect to your repo and task store: it inspects
# completed dev-loop tasks and their local review branches and never mutates
# them. Mirrors dev-loop's conventions so output stays machine-parseable.

# ---------------------------------------------------------------------------
# Exit codes (stable contract the agent branches on; see reference.md).
#   0  ok        (a query that legitimately matches nothing is also 0 + empty)
#   20 precondition / usage failure (missing tool, not in a repo, bad args)
#   30 missing-artifact (a task's review branch or base is not present locally)
# ---------------------------------------------------------------------------
DLR_OK=0
DLR_PRECOND=20
DLR_MISSING=30
export DLR_OK DLR_PRECOND DLR_MISSING

# ---------------------------------------------------------------------------
# Logging — everything diagnostic goes to stderr so stdout stays parseable.
# ---------------------------------------------------------------------------
dlr_log()  { printf 'dev-loop-review: %s\n' "$*" >&2; }
dlr_warn() { printf 'dev-loop-review: WARN: %s\n' "$*" >&2; }
dlr_err()  { printf 'dev-loop-review: ERROR: %s\n' "$*" >&2; }
# dlr_die <exit-code> <message...>
dlr_die()  { local code="$1"; shift; dlr_err "$*"; exit "$code"; }

# ---------------------------------------------------------------------------
# Environment knobs (overridable; documented in reference.md).
# ---------------------------------------------------------------------------
: "${DLR_SINCE:=7d}"                       # default time window for --since / fallback
: "${DLR_REPORT_DIR:=.dev-loop}"           # where saved review reports land (gitignored)
export DLR_SINCE DLR_REPORT_DIR

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
# dlr_require <cmd...> — fail (20) if any command is missing.
dlr_require() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    dlr_die "$DLR_PRECOND" "missing required command(s): ${missing[*]}"
  fi
}

# dlr_in_git_repo — fail (20) unless cwd is inside a git work tree.
dlr_in_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || dlr_die "$DLR_PRECOND" "not inside a git repository (run from your repo checkout)"
}

# ---------------------------------------------------------------------------
# Taskwarrior wrappers — deterministic, non-interactive, read-only.
# ---------------------------------------------------------------------------
# dlr_task_export <filter...> — JSON array of matching tasks on stdout.
dlr_task_export() {
  task rc.confirmation=no rc.json.array=on rc.verbose=nothing "$@" export 2>/dev/null
}

# ---------------------------------------------------------------------------
# Annotation readers. dev-loop records two annotation styles:
#   * machine state as  key=value   (box=, base=, branch=, commits=)  — last wins
#   * human notes as     prefix: …  (summary:, acceptance:)           — collect all
# These operate on a single task's exported JSON passed on stdin.
# ---------------------------------------------------------------------------
# dlr_anno_kv <key>   — latest value of a key=value annotation (reads stdin JSON).
dlr_anno_kv() {
  jq -r --arg k "$1" '
    (.[0].annotations // []) | map(.description)
    | map(select(startswith($k + "=")))
    | last // ""
    | if . == "" then "" else (.[($k|length)+1:]) end'
}
# dlr_anno_notes <prefix> — all "prefix: …" notes, newline-joined (reads stdin JSON).
dlr_anno_notes() {
  jq -r --arg p "$1" '
    (.[0].annotations // []) | map(.description)
    | map(select(startswith($p + ":")))
    | .[] | sub("^" + $p + ":\\s*"; "")'
}
