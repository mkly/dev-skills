# shellcheck shell=bash
# dlr-common.sh — shared helpers for the dev-loop-review skill scripts.
# Sourced, never executed directly. Keep POSIX-ish bash; assume bash 4+.
#
# This skill reviews the local review/* branches dev-loop produced and ACTS on
# the verdict: fix tasks for findings, merge + branch delete for clean branches.
# Collection and diffing are read-only; only dlr-merge.sh mutates the repo
# (local merge + safe branch delete + one audit annotation — never a push).
# Mirrors dev-loop's conventions so output stays machine-parseable.

# ---------------------------------------------------------------------------
# Exit codes (stable contract the agent branches on; see reference.md).
#   0  ok        (a query that legitimately matches nothing is also 0 + empty)
#   20 precondition / usage failure (missing tool, not in a repo, dirty
#      worktree, bad args)
#   30 missing-artifact (branch/base not present locally) or merge-conflict
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
# Taskwarrior wrappers — deterministic, non-interactive.
# ---------------------------------------------------------------------------
# dlr_task_export <filter...> — JSON array of matching tasks on stdout.
# shellcheck disable=SC2120  # callers may pass no filter (= export everything)
dlr_task_export() {
  task rc.confirmation=no rc.json.array=on rc.verbose=nothing "$@" export 2>/dev/null
}

# ---------------------------------------------------------------------------
# Annotation readers. dev-loop records two annotation styles:
#   * machine state as  key=value   (box=, base=, branch=, commits=)  — last wins
#   * human notes as     prefix: …  (summary:, acceptance:)           — collect all
# DLR_JQ_DEFS provides both as jq functions operating on one task object.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2089  # a jq program, not a shell expansion
DLR_JQ_DEFS='
  def kv($k):
    (.annotations // []) | map(.description)
    | map(select(startswith($k + "=")))
    | last // ""
    | if . == "" then "" else .[($k|length)+1:] end;
  def notes($p):
    [ (.annotations // []) | map(.description)
      | map(select(startswith($p + ":"))) | .[]
      | sub("^" + $p + ":\\s*"; "") ] | join("\n");
'
# shellcheck disable=SC2090
export DLR_JQ_DEFS

# dlr_task_for_branch <branch> — normalized JSON of the task recording
# branch=<branch> (last match wins across ALL statuses, since the producer is
# usually completed), or the literal `null` when no task records it. Shape
# matches dlr-collect.sh's .task objects:
#   {uuid, short, description, project, status, end, base, commits,
#    summary, acceptance}
dlr_task_for_branch() {
  local branch="$1" raw result rc

  # Do not leave this as a pipeline. Under `set -euo pipefail`, an unexpected
  # Taskwarrior exit propagates through a caller's command substitution before
  # the review script can explain the failure or normalize it to our contract.
  # shellcheck disable=SC2119
  raw="$(dlr_task_export)" || {
    rc=$?
    dlr_err "failed to export Taskwarrior metadata while resolving producing task for branch '${branch}' (task exit ${rc})"
    return "$DLR_PRECOND"
  }

  result="$(printf '%s' "$raw" | jq --arg b "$branch" "$DLR_JQ_DEFS"'
    [ .[] | select(kv("branch") == $b) ] | last
    | if . == null then null else
        { uuid, short: .uuid[0:8], description,
          project: (.project // ""), status, end: (.end // ""),
          base: kv("base"), commits: kv("commits"),
          summary: notes("summary"), acceptance: notes("acceptance") }
      end')" || {
    rc=$?
    dlr_err "failed to parse Taskwarrior metadata while resolving producing task for branch '${branch}' (jq exit ${rc})"
    return "$DLR_PRECOND"
  }
  printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# Crabbox/Incus knobs for dlr-test.sh — a review branch's producing task is
# usually already `done` (its own dev-loop box long stopped), and this skill
# must never mutate that task beyond dlr-merge.sh's audit annotation. So
# dlr-test.sh's box lease is keyed on the BRANCH (deterministic slug), never on
# a Taskwarrior uuid/annotation — no claim, no task write, fully stateless.
# Names match dev-loop's own env vars so one config works for both skills.
# ---------------------------------------------------------------------------
: "${CRABBOX_PROVIDER:=incus}"
: "${DLR_TEST_TTL:=30m}"        # short-lived: one review check, not a work session
: "${INCUS_IMAGE:=}"            # optional -incus-image override
: "${INCUS_TYPE:=}"             # optional -incus-instance-type (container|vm)
: "${INCUS_REMOTE:=}"           # optional -incus-remote
: "${DLR_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dev-loop-review}"
: "${DLR_WORKTREE_DIR:=${DLR_STATE_DIR}/worktrees}"  # per-branch checkouts (outside the repo tree)
export CRABBOX_PROVIDER DLR_TEST_TTL INCUS_IMAGE INCUS_TYPE INCUS_REMOTE DLR_STATE_DIR DLR_WORKTREE_DIR

# dlr_crabbox_incus_flags — Incus overrides as extra `crabbox` args, only when set.
dlr_crabbox_incus_flags() {
  local -a f=()
  [ -n "$INCUS_IMAGE" ]  && f+=(-incus-image "$INCUS_IMAGE")
  [ -n "$INCUS_TYPE" ]   && f+=(-incus-instance-type "$INCUS_TYPE")
  [ -n "$INCUS_REMOTE" ] && f+=(-incus-remote "$INCUS_REMOTE")
  if [ "${#f[@]}" -gt 0 ]; then printf '%s\n' "${f[@]}"; fi
}

# dlr_repo_key — stable short id for THIS repo (namespaces DLR_WORKTREE_DIR so
# two checkouts on one machine never collide). Same derivation as dev-loop's.
dlr_repo_key() {
  local cdir base
  cdir="$(git rev-parse --git-common-dir 2>/dev/null || echo .)"
  cdir="$(cd "$cdir" 2>/dev/null && pwd -P || printf '%s' "$cdir")"
  base="$(basename "$(dirname "$cdir")")"
  printf '%s-%s' "$base" "$(printf '%s' "$cdir" | cksum | cut -d' ' -f1)"
}

# dlr_worktree_dir_for <slug> — absolute path of the per-branch test worktree.
dlr_worktree_dir_for() {
  printf '%s/%s/%s' "$DLR_WORKTREE_DIR" "$(dlr_repo_key)" "$1"
}

# dlr_slug_for_branch <branch> — deterministic, crabbox/filesystem-safe id.
# Same branch always yields the same slug, so a box can be found by `crabbox
# status -id <slug>` directly — no stored handle, no annotation needed.
dlr_slug_for_branch() {
  local words
  words="$(printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed 's/^-//; s/-$//')"
  words="${words:0:36}"; words="${words%-}"
  printf 'dlrt-%s\n' "${words:-branch}"
}
