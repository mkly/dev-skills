# shellcheck shell=bash
# dlc-common.sh — shared helpers for the dev-complete-task skill scripts.
# Sourced, never executed directly. Keep POSIX-ish bash; assume bash 4+.
#
# This skill reviews local implementation branches and acts on the verdict:
# preserve branches for findings, or merge + safely delete clean branches.
# Collection and diffing are read-only; only dlc-merge.sh mutates the repo
# (local merge + safe branch delete + one audit annotation — never a push).
# Mirrors dev-implement-task's conventions so output stays machine-parseable.

# ---------------------------------------------------------------------------
# Exit codes (stable contract the agent branches on; see reference.md).
#   0  ok        (a query that legitimately matches nothing is also 0 + empty)
#   20 precondition / usage failure (missing tool, not in a repo, dirty
#      worktree, bad args)
#   30 missing-artifact (branch/base not present locally) or merge-conflict
# ---------------------------------------------------------------------------
DLC_OK=0
DLC_PRECOND=20
DLC_MISSING=30
export DLC_OK DLC_PRECOND DLC_MISSING

# ---------------------------------------------------------------------------
# Logging — everything diagnostic goes to stderr so stdout stays parseable.
# ---------------------------------------------------------------------------
dlc_log()  { printf 'dev-complete-task: %s\n' "$*" >&2; }
dlc_warn() { printf 'dev-complete-task: WARN: %s\n' "$*" >&2; }
dlc_err()  { printf 'dev-complete-task: ERROR: %s\n' "$*" >&2; }
# dlc_die <exit-code> <message...>
dlc_die()  { local code="$1"; shift; dlc_err "$*"; exit "$code"; }

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
# dlc_require <cmd...> — fail (20) if any command is missing.
dlc_require() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    dlc_die "$DLC_PRECOND" "missing required command(s): ${missing[*]}"
  fi
}

# dlc_in_git_repo — fail (20) unless cwd is inside a git work tree.
dlc_in_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || dlc_die "$DLC_PRECOND" "not inside a git repository (run from your repo checkout)"
}

# dlc_resolve_repo_identity — set DLC_REPO_PROJECT and DLC_REPO_ID from the
# current checkout's GitHub origin. Repository identity is never caller-named.
dlc_resolve_repo_identity() {
  local origin path owner repo
  dlc_in_git_repo
  origin="$(git remote get-url origin 2>/dev/null)" \
    || dlc_die "$DLC_PRECOND" "target repository has no origin remote"
  case "$origin" in
    git@github.com:*) path="${origin#git@github.com:}" ;;
    ssh://git@github.com/*) path="${origin#ssh://git@github.com/}" ;;
    https://github.com/*) path="${origin#https://github.com/}" ;;
    http://github.com/*) path="${origin#http://github.com/}" ;;
    git://github.com/*) path="${origin#git://github.com/}" ;;
    *) dlc_die "$DLC_PRECOND" "origin must be a GitHub repository URL: $origin" ;;
  esac
  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"
  owner="${path%%/*}"
  repo="${path#*/}"
  if [ -z "$owner" ] || [ -z "$repo" ] || [ "$repo" = "$path" ] || [[ "$repo" == */* ]]; then
    dlc_die "$DLC_PRECOND" "could not derive GitHub owner/repository from origin: $origin"
  fi
  [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$repo" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || dlc_die "$DLC_PRECOND" "GitHub origin has unsupported owner/repository characters: $origin"
  DLC_REPO_PROJECT="${repo,,}"
  DLC_REPO_ID="github.com/${owner,,}/${DLC_REPO_PROJECT}"
  export DLC_REPO_PROJECT DLC_REPO_ID
}

# ---------------------------------------------------------------------------
# Taskwarrior wrappers — deterministic, non-interactive.
# ---------------------------------------------------------------------------
# dlc_task_export <filter...> — JSON array of matching tasks on stdout.
# shellcheck disable=SC2120  # callers may pass no filter (= export everything)
dlc_task_export() {
  task rc.confirmation=no rc.json.array=on rc.verbose=nothing "$@" export 2>/dev/null
}

# ---------------------------------------------------------------------------
# Annotation readers. dev-implement-task records two annotation styles:
#   * machine state as  key=value   (box=, base=, branch=, commits=)  — last wins
#   * human notes as     prefix: …  (summary:, acceptance:)           — collect all
# DLC_JQ_DEFS provides both as jq functions operating on one task object.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2089  # a jq program, not a shell expansion
DLC_JQ_DEFS='
  def kv($k):
    (.annotations // []) | map(.description)
    | map(select(startswith($k + "=")))
    | last // ""
    | if . == "" then "" else .[($k|length)+1:] end;
  def note($p):
    (.annotations // []) | map(.description)
    | map(select(startswith($p + ":")))
    | last // ""
    | sub("^" + $p + ":\\s*"; "");
  def notes($p):
    [ (.annotations // []) | map(.description)
      | map(select(startswith($p + ":"))) | .[]
      | sub("^" + $p + ":\\s*"; "") ] | join("\n");
'
# shellcheck disable=SC2090
export DLC_JQ_DEFS

# dlc_task_for_branch <branch> — normalized JSON of the task recording
# branch=<branch> (last match wins across ALL statuses for legacy
# compatibility), or the literal `null` when no task records it. Shape
# matches dlc-collect.sh's .task objects:
#   {uuid, short, description, project, repo_id, goal, loop_id, loop_round,
#    input, status, end, base, commits, summary, acceptance}
dlc_task_for_branch() {
  local branch="$1" raw result rc

  # Do not leave this as a pipeline. Under `set -euo pipefail`, an unexpected
  # Taskwarrior exit propagates through a caller's command substitution before
  # the review script can explain the failure or normalize it to our contract.
  # shellcheck disable=SC2119
  raw="$(dlc_task_export)" || {
    rc=$?
    dlc_err "failed to export Taskwarrior metadata while resolving producing task for branch '${branch}' (task exit ${rc})"
    return "$DLC_PRECOND"
  }

  result="$(printf '%s' "$raw" | jq --arg b "$branch" "$DLC_JQ_DEFS"'
    [ .[] | select(kv("branch") == $b) ] | last
    | if . == null then null else
        { uuid, short: .uuid[0:8], description,
          project: (.project // ""), status, end: (.end // ""),
          base: kv("base"), commits: kv("commits"),
          repo_id: note("repo-id"), goal: note("goal"),
          loop_id: note("loop-id"), loop_round: note("loop-round"),
          input: note("input"),
          summary: notes("summary"), acceptance: notes("acceptance") }
      end')" || {
    rc=$?
    dlc_err "failed to parse Taskwarrior metadata while resolving producing task for branch '${branch}' (jq exit ${rc})"
    return "$DLC_PRECOND"
  }
  printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# Crabbox/Incus knobs for dlc-test.sh. Verification uses a branch-keyed lease so
# it cannot disturb the implementation task's owned box or worktree. It never
# writes Taskwarrior state. Names match dev-implement-task's provider vars so
# one config works for both skills.
# ---------------------------------------------------------------------------
: "${CRABBOX_PROVIDER:=incus}"
: "${DLC_TEST_TTL:=30m}"        # short-lived: one review check, not a work session
: "${INCUS_IMAGE:=}"            # optional -incus-image override
: "${INCUS_TYPE:=}"             # optional -incus-instance-type (container|vm)
: "${INCUS_REMOTE:=}"           # optional -incus-remote
: "${DLC_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dev-complete-task}"
: "${DLC_WORKTREE_DIR:=${DLC_STATE_DIR}/worktrees}"  # per-branch checkouts (outside the repo tree)
export CRABBOX_PROVIDER DLC_TEST_TTL INCUS_IMAGE INCUS_TYPE INCUS_REMOTE DLC_STATE_DIR DLC_WORKTREE_DIR

# dlc_crabbox_incus_flags — Incus overrides as extra `crabbox` args, only when set.
dlc_crabbox_incus_flags() {
  local -a f=()
  [ -n "$INCUS_IMAGE" ]  && f+=(-incus-image "$INCUS_IMAGE")
  [ -n "$INCUS_TYPE" ]   && f+=(-incus-instance-type "$INCUS_TYPE")
  [ -n "$INCUS_REMOTE" ] && f+=(-incus-remote "$INCUS_REMOTE")
  if [ "${#f[@]}" -gt 0 ]; then printf '%s\n' "${f[@]}"; fi
}

# dlc_repo_key — stable short id for THIS repo (namespaces DLC_WORKTREE_DIR so
# two checkouts on one machine never collide). Same derivation as implementation.
dlc_repo_key() {
  local cdir base
  cdir="$(git rev-parse --git-common-dir 2>/dev/null || echo .)"
  cdir="$(cd "$cdir" 2>/dev/null && pwd -P || printf '%s' "$cdir")"
  base="$(basename "$(dirname "$cdir")")"
  printf '%s-%s' "$base" "$(printf '%s' "$cdir" | cksum | cut -d' ' -f1)"
}

# dlc_worktree_dir_for <slug> — absolute path of the per-branch test worktree.
dlc_worktree_dir_for() {
  printf '%s/%s/%s' "$DLC_WORKTREE_DIR" "$(dlc_repo_key)" "$1"
}

# dlc_slug_for_branch <branch> — deterministic, crabbox/filesystem-safe id.
# Same branch always yields the same slug, so a box can be found by `crabbox
# status -id <slug>` directly — no stored handle, no annotation needed.
dlc_slug_for_branch() {
  local words
  words="$(printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed 's/^-//; s/-$//')"
  words="${words:0:36}"; words="${words%-}"
  printf 'dlrt-%s\n' "${words:-branch}"
}
