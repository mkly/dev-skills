#!/usr/bin/env bash
# dct-create.sh — atomically create one pending implementation-ready task.
#
# The UUID is generated before creation and the complete task is sent through
# one `task import` operation. This avoids the racy `task add` + `+LATEST`
# pattern while keeping stdout to one exact machine-readable result.
set -euo pipefail
IFS=$'\n\t'

DCT_OK=0
DCT_PRECOND=20

PROJECT=""
REPO_ID=""
GOAL=""
LOOP_ID=""
FROM_TASK=""
DESCRIPTION=""
INPUT_REF=""
REVIEW_OF=""
LOOP_ROUND=""
DRY_RUN=0
JSON_OUTPUT=0
SMALL_TASK=0
declare -a ACCEPTANCE=()
declare -a DEPENDENCIES=()
declare -a EXTRA_ANNOTATIONS=()

dct_log() { printf 'dev-create-tasks: %s\n' "$*" >&2; }
dct_err() { printf 'dev-create-tasks: ERROR: %s\n' "$*" >&2; }
dct_die() { local code="$1"; shift; dct_err "$*"; exit "$code"; }

usage() {
  cat >&2 <<'EOF'
Usage: dct-create.sh (--goal <slug> --loop-id <uuid> | --from-task <task-ref>)
                     --description <text> --acceptance <criterion> [options]

Required:
  --goal <slug>            goal name for an initial task batch
  --loop-id <uuid>         shared controller identity for an initial task batch
  --from-task <task-ref>   instead inherit repository/goal/loop identity
  --description <text>     concise task outcome
  --acceptance <criterion> acceptance outcome; repeatable

Options:
  --depends <task-ref>      dependency UUID/short UUID/ID; repeatable
  --input <ref>             add "input: <ref>"
  --review-of <value>       add "review-of: <value>"
  --loop-round <n>          round number (initial default 1; follow-up default
                            is the producer's round plus one)
  --annotation <text>       add another annotation; repeatable
  --small                   tag this trivial task +SMALL
  --json                    emit task and derived repository/loop identity
  --dry-run                 validate and preview without importing
  -h, --help                show this help

Default stdout is the exact created UUID. Diagnostics and dry-run payloads go
to stderr. Actual creation runs `task sync` first; dry-run does not. Exit: 0
success, 20 usage/precondition/sync/import/verification failure.
EOF
}

require_value() {
  local flag="$1" remaining="$2"
  [ "$remaining" -gt 0 ] || { usage; dct_die "$DCT_PRECOND" "$flag needs a value"; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --goal)
      shift; require_value --goal "$#"; GOAL="$1" ;;
    --loop-id)
      shift; require_value --loop-id "$#"; LOOP_ID="$1" ;;
    --from-task)
      shift; require_value --from-task "$#"; FROM_TASK="$1" ;;
    --description)
      shift; require_value --description "$#"; DESCRIPTION="$1" ;;
    --acceptance)
      shift; require_value --acceptance "$#"; ACCEPTANCE+=("$1") ;;
    --depends)
      shift; require_value --depends "$#"; DEPENDENCIES+=("$1") ;;
    --input)
      shift; require_value --input "$#"
      [ -n "$1" ] || dct_die "$DCT_PRECOND" "--input may not be empty"
      [ -z "$INPUT_REF" ] || dct_die "$DCT_PRECOND" "--input may be supplied only once"
      INPUT_REF="$1" ;;
    --review-of)
      shift; require_value --review-of "$#"
      [ -n "$1" ] || dct_die "$DCT_PRECOND" "--review-of may not be empty"
      [ -z "$REVIEW_OF" ] || dct_die "$DCT_PRECOND" "--review-of may be supplied only once"
      REVIEW_OF="$1" ;;
    --loop-round)
      shift; require_value --loop-round "$#"
      [ -n "$1" ] || dct_die "$DCT_PRECOND" "--loop-round may not be empty"
      [ -z "$LOOP_ROUND" ] || dct_die "$DCT_PRECOND" "--loop-round may be supplied only once"
      LOOP_ROUND="$1" ;;
    --annotation)
      shift; require_value --annotation "$#"; EXTRA_ANNOTATIONS+=("$1") ;;
    --small) SMALL_TASK=1 ;;
    --json) JSON_OUTPUT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit "$DCT_OK" ;;
    -*) usage; dct_die "$DCT_PRECOND" "unknown flag: $1" ;;
    *) usage; dct_die "$DCT_PRECOND" "unexpected argument: $1" ;;
  esac
  shift
done

[ -n "$DESCRIPTION" ] || { usage; dct_die "$DCT_PRECOND" "--description is required"; }
[ "${#ACCEPTANCE[@]}" -gt 0 ] || { usage; dct_die "$DCT_PRECOND" "at least one --acceptance is required"; }
[[ "$DESCRIPTION" =~ [^[:space:]] ]] \
  || dct_die "$DCT_PRECOND" "--description may not be blank"

if [ -n "$FROM_TASK" ]; then
  [ -z "$GOAL" ] && [ -z "$LOOP_ID" ] \
    || dct_die "$DCT_PRECOND" "--from-task cannot be combined with --goal or --loop-id"
else
  [ -n "$GOAL" ] && [ -n "$LOOP_ID" ] \
    || { usage; dct_die "$DCT_PRECOND" "initial creation requires --goal and --loop-id"; }
fi
if [ -n "$GOAL" ] && ! [[ "$GOAL" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  dct_die "$DCT_PRECOND" "--goal must be a lowercase slug using letters, digits, '_' or '-'"
fi
if [ -n "$LOOP_ID" ] && ! [[ "$LOOP_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  dct_die "$DCT_PRECOND" "--loop-id must be a UUID"
fi
if [ -n "$LOOP_ROUND" ] && ! [[ "$LOOP_ROUND" =~ ^[1-9][0-9]*$ ]]; then
  dct_die "$DCT_PRECOND" "--loop-round must be a positive integer"
fi
if [ -n "$INPUT_REF" ] && [[ "$INPUT_REF" =~ [[:space:]] ]]; then
  dct_die "$DCT_PRECOND" "--input must be one branch/ref without whitespace"
fi

reject_multiline() {
  local label="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) dct_die "$DCT_PRECOND" "$label must be one line" ;;
  esac
}

reject_multiline "description" "$DESCRIPTION"
for value in "${ACCEPTANCE[@]}"; do
  [[ "$value" =~ [^[:space:]] ]] \
    || dct_die "$DCT_PRECOND" "acceptance criteria may not be blank"
  reject_multiline "acceptance criterion" "$value"
done
for value in "${EXTRA_ANNOTATIONS[@]}"; do
  [[ "$value" =~ [^[:space:]] ]] || dct_die "$DCT_PRECOND" "annotations may not be blank"
  reject_multiline "annotation" "$value"
  case "$value" in
    "repo-id:"*|"goal:"*|"loop-id:"*|"loop-round:"*|"plan:"*)
      dct_die "$DCT_PRECOND" "identity annotations are reserved; use the corresponding option"
      ;;
  esac
done
if [ -n "$REVIEW_OF" ]; then
  [[ "$REVIEW_OF" =~ [^[:space:]] ]] || dct_die "$DCT_PRECOND" "--review-of may not be blank"
  reject_multiline "review-of value" "$REVIEW_OF"
fi

missing=()
for command_name in task jq date tr sed git; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
[ "${#missing[@]}" -eq 0 ] \
  || dct_die "$DCT_PRECOND" "missing required command(s): ${missing[*]}"

dct_task() {
  task rc.confirmation=no rc.recurrence.confirmation=no rc.context=none rc.verbose=nothing "$@"
}

dct_task_export() {
  dct_task rc.json.array=on "$@" export
}

dct_sync() {
  local output rc
  if output="$(dct_task sync 2>&1)"; then
    dct_log "Taskwarrior sync complete"
    return
  else
    rc=$?
  fi

  case "$output" in
    *"No sync.* settings are configured."*)
      dct_log "Taskwarrior sync is not configured; continuing"
      return
      ;;
  esac

  [ -z "$output" ] || printf '%s\n' "$output" >&2
  dct_die "$DCT_PRECOND" "Taskwarrior sync failed (exit $rc)"
}

resolve_repo_identity() {
  local origin path owner repo
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || dct_die "$DCT_PRECOND" "task creation must run inside the target Git repository"
  origin="$(git remote get-url origin 2>/dev/null)" \
    || dct_die "$DCT_PRECOND" "target repository has no origin remote"

  case "$origin" in
    git@github.com:*) path="${origin#git@github.com:}" ;;
    ssh://git@github.com/*) path="${origin#ssh://git@github.com/}" ;;
    https://github.com/*) path="${origin#https://github.com/}" ;;
    http://github.com/*) path="${origin#http://github.com/}" ;;
    git://github.com/*) path="${origin#git://github.com/}" ;;
    *) dct_die "$DCT_PRECOND" "origin must be a GitHub repository URL: $origin" ;;
  esac

  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"
  owner="${path%%/*}"
  repo="${path#*/}"
  if [ -z "$owner" ] || [ -z "$repo" ] || [ "$repo" = "$path" ] || [[ "$repo" == */* ]]; then
    dct_die "$DCT_PRECOND" "could not derive GitHub owner/repository from origin: $origin"
  fi
  [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$repo" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || dct_die "$DCT_PRECOND" "GitHub origin has unsupported owner/repository characters: $origin"

  PROJECT="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
  owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
  REPO_ID="github.com/${owner}/${PROJECT}"
}

inherit_task_identity() {
  local exported count identity producer_round
  exported="$(dct_task_export "$FROM_TASK" 2>/dev/null)" \
    || dct_die "$DCT_PRECOND" "failed to export identity source task: $FROM_TASK"
  count="$(printf '%s' "$exported" | jq 'length' 2>/dev/null)" \
    || dct_die "$DCT_PRECOND" "Taskwarrior returned invalid JSON for identity source: $FROM_TASK"
  [ "$count" = "1" ] \
    || dct_die "$DCT_PRECOND" "identity source '$FROM_TASK' resolved to $count tasks; expected exactly one"
  identity="$(printf '%s' "$exported" | jq -c '
    def note($p):
      [(.[]?.annotations // [])[]?.description
       | select(startswith($p + ":"))
       | sub("^" + $p + ":\\s*"; "")] | last // "";
    {project: (.[0].project // ""), repo_id: note("repo-id"),
     goal: note("goal"), loop_id: note("loop-id"),
     loop_round: note("loop-round")}
  ')" || dct_die "$DCT_PRECOND" "failed to parse identity source task: $FROM_TASK"

  [ "$(printf '%s' "$identity" | jq -r .project)" = "$PROJECT" ] \
    || dct_die "$DCT_PRECOND" "identity source project does not match current origin project '$PROJECT'"
  [ "$(printf '%s' "$identity" | jq -r .repo_id)" = "$REPO_ID" ] \
    || dct_die "$DCT_PRECOND" "identity source repo-id does not match current origin '$REPO_ID'"
  GOAL="$(printf '%s' "$identity" | jq -r .goal)"
  LOOP_ID="$(printf '%s' "$identity" | jq -r .loop_id)"
  producer_round="$(printf '%s' "$identity" | jq -r .loop_round)"
  [[ "$GOAL" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || dct_die "$DCT_PRECOND" "identity source has no valid goal annotation"
  [[ "$LOOP_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || dct_die "$DCT_PRECOND" "identity source has no valid loop-id annotation"
  [[ "$producer_round" =~ ^[1-9][0-9]*$ ]] \
    || dct_die "$DCT_PRECOND" "identity source has no valid loop-round annotation"
  [ -n "$LOOP_ROUND" ] || LOOP_ROUND="$((10#$producer_round + 1))"
}

resolve_repo_identity
if [ "$DRY_RUN" -eq 0 ]; then
  dct_sync
fi
if [ -n "$FROM_TASK" ]; then
  inherit_task_identity
else
  [ -n "$LOOP_ROUND" ] || LOOP_ROUND=1
fi
LOOP_ID="${LOOP_ID,,}"

case "$PROJECT" in
  *[!A-Za-z0-9._-]*|'') dct_die "$DCT_PRECOND" "derived project has unsupported characters: $PROJECT" ;;
esac
[[ "$LOOP_ROUND" =~ ^[1-9][0-9]*$ ]] \
  || dct_die "$DCT_PRECOND" "--loop-round must be a positive integer"

existing="$(dct_task_export 2>/dev/null)" \
  || dct_die "$DCT_PRECOND" "failed to inspect existing tasks for repository collisions"
conflicts="$(printf '%s' "$existing" | jq --arg project "$PROJECT" --arg repo_id "$REPO_ID" '
  [ .[] | select((.project // "") == $project)
    | {uuid, repo_id: ([.annotations[]?.description
        | select(startswith("repo-id:"))
        | sub("^repo-id:\\s*"; "")] | last // "")}
    | select(.repo_id != "" and .repo_id != $repo_id) ]
')" || dct_die "$DCT_PRECOND" "failed to inspect repository identity annotations"
[ "$(printf '%s' "$conflicts" | jq 'length')" = 0 ] \
  || dct_die "$DCT_PRECOND" "project '$PROJECT' is already associated with another GitHub repository"

resolve_dependency() {
  local ref="$1" exported count resolved
  if ! exported="$(dct_task_export "$ref" 2>/dev/null)"; then
    dct_die "$DCT_PRECOND" "failed to resolve dependency: $ref"
  fi
  count="$(printf '%s' "$exported" | jq 'length' 2>/dev/null)" \
    || dct_die "$DCT_PRECOND" "Taskwarrior returned invalid JSON while resolving dependency: $ref"
  [ "$count" = "1" ] \
    || dct_die "$DCT_PRECOND" "dependency '$ref' resolved to $count tasks; expected exactly one"
  printf '%s' "$exported" | jq -e \
    --arg project "$PROJECT" --arg repo_id "$REPO_ID" \
    --arg goal "$GOAL" --arg loop_id "$LOOP_ID" '
      def note($p):
        [.[0].annotations[]?.description
         | select(startswith($p + ":"))
         | sub("^" + $p + ":\\s*"; "")] | last // "";
      .[0].project == $project
      and note("repo-id") == $repo_id
      and note("goal") == $goal
      and (note("loop-id") | ascii_downcase) == ($loop_id | ascii_downcase)
    ' >/dev/null \
    || dct_die "$DCT_PRECOND" "dependency '$ref' does not share the task's repository, goal, and loop identity"
  resolved="$(printf '%s' "$exported" | jq -r '.[0].uuid // empty')"
  [[ "$resolved" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || dct_die "$DCT_PRECOND" "dependency '$ref' has no valid UUID"
  printf '%s\n' "${resolved,,}"
}

declare -a RESOLVED_DEPENDENCIES=()
declare -A SEEN_DEPENDENCIES=()
for dependency in "${DEPENDENCIES[@]}"; do
  resolved_dependency="$(resolve_dependency "$dependency")"
  if [ -z "${SEEN_DEPENDENCIES[$resolved_dependency]:-}" ]; then
    RESOLVED_DEPENDENCIES+=("$resolved_dependency")
    SEEN_DEPENDENCIES[$resolved_dependency]=1
  fi
done

generate_uuid() {
  local generated=""
  if [ -r /proc/sys/kernel/random/uuid ]; then
    IFS= read -r generated </proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    generated="$(uuidgen)"
  else
    dct_die "$DCT_PRECOND" "cannot generate a UUID (/proc UUID source and uuidgen are unavailable)"
  fi
  generated="${generated,,}"
  [[ "$generated" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || dct_die "$DCT_PRECOND" "UUID generator returned an invalid value"
  printf '%s\n' "$generated"
}

json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
  else
    printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'
  fi
}

UUID="$(generate_uuid)"
ENTRY="$(date -u +%Y%m%dT%H%M%SZ)"
declare -a NOTES=()
NOTES+=("repo-id: $REPO_ID")
NOTES+=("goal: $GOAL")
NOTES+=("loop-id: $LOOP_ID")
NOTES+=("loop-round: $LOOP_ROUND")
for criterion in "${ACCEPTANCE[@]}"; do NOTES+=("acceptance: $criterion"); done
[ -z "$INPUT_REF" ] || NOTES+=("input: $INPUT_REF")
[ -z "$REVIEW_OF" ] || NOTES+=("review-of: $REVIEW_OF")
NOTES+=("${EXTRA_ANNOTATIONS[@]}")

DEPENDENCIES_JSON="$(json_array "${RESOLVED_DEPENDENCIES[@]}")"
NOTES_JSON="$(json_array "${NOTES[@]}")"
PAYLOAD="$(jq -cn \
  --arg uuid "$UUID" \
  --arg entry "$ENTRY" \
  --arg description "$DESCRIPTION" \
  --arg project "$PROJECT" \
  --argjson depends "$DEPENDENCIES_JSON" \
  --argjson notes "$NOTES_JSON" \
  --argjson small "$SMALL_TASK" '
    {
      uuid: $uuid,
      status: "pending",
      entry: $entry,
      description: $description,
      project: $project,
      annotations: ($notes | map({entry: $entry, description: .}))
    }
    + if ($depends | length) > 0 then {depends: $depends} else {} end
    + if $small == 1 then {tags: ["SMALL"]} else {} end
  ')" || dct_die "$DCT_PRECOND" "failed to construct task JSON"

task_slug() {
  local compact short words
  compact="${UUID//-/}"
  short="${compact:0:8}"
  words="$(printf '%s' "$DESCRIPTION" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed 's/^-//; s/-$//')"
  words="${words:0:24}"
  words="${words%-}"
  if [ -n "$words" ]; then
    printf 'dl-%s-%s\n' "$short" "$words"
  else
    printf 'dl-%s\n' "$short"
  fi
}

REVIEW_BRANCH="review/$(task_slug)"

emit_result() {
  local created="$1"
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    jq -cn \
      --arg uuid "$UUID" \
      --arg review_branch "$REVIEW_BRANCH" \
      --arg project "$PROJECT" \
      --arg repo_id "$REPO_ID" \
      --arg goal "$GOAL" \
      --arg loop_id "$LOOP_ID" \
      --arg loop_round "$LOOP_ROUND" \
      --arg description "$DESCRIPTION" \
      --argjson small "$SMALL_TASK" \
      --argjson created "$created" \
      '{uuid: $uuid, review_branch: $review_branch, project: $project,
        repo_id: $repo_id, goal: $goal, loop_id: $loop_id,
        loop_round: ($loop_round | tonumber), description: $description,
        tags: (if $small == 1 then ["SMALL"] else [] end),
        created: $created}'
  else
    printf '%s\n' "$UUID"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  dct_log "DRY-RUN: would import the following task"
  printf '%s\n' "$PAYLOAD" | jq . >&2
  emit_result false
  exit "$DCT_OK"
fi

# `task import` identifies a task by UUID. Supplying our own UUID and complete
# JSON makes this one Taskwarrior write; there is no mutable +LATEST selector
# for another creator to race. TaskChampion/SQLite serializes the write.
if ! printf '[%s]\n' "$PAYLOAD" | dct_task import - >&2; then
  dct_die "$DCT_PRECOND" "Taskwarrior import failed; proposed UUID was $UUID"
fi

if ! CREATED="$(dct_task_export "$UUID" 2>/dev/null)"; then
  dct_die "$DCT_PRECOND" "created task $UUID but could not export it for verification"
fi
if ! printf '%s' "$CREATED" | jq -e \
  --arg uuid "$UUID" \
  --arg project "$PROJECT" \
  --arg description "$DESCRIPTION" \
  --argjson depends "$DEPENDENCIES_JSON" \
  --argjson small "$SMALL_TASK" \
  --argjson notes "$NOTES_JSON" '
    length == 1
    and .[0].uuid == $uuid
    and .[0].status == "pending"
    and .[0].project == $project
    and .[0].description == $description
    and (.[0].start? == null)
    and ((.[0].assignee // "") == "")
    and (((.[0].depends // []) | sort) == ($depends | sort))
    and (((.[0].tags // []) | sort) ==
         (if $small == 1 then ["SMALL"] else [] end))
    and ([.[0].annotations[]?.description] as $actual
         | (($notes - $actual) | length) == 0)
  ' >/dev/null; then
  dct_die "$DCT_PRECOND" "task $UUID was imported but failed post-create verification"
fi

dct_log "created pending, unstarted task $UUID ($REVIEW_BRANCH)"
emit_result true
