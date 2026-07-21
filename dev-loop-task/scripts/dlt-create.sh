#!/usr/bin/env bash
# dlt-create.sh — atomically create one pending, dev-loop-compatible task.
#
# The UUID is generated before creation and the complete task is sent through
# one `task import` operation. This avoids the racy `task add` + `+LATEST`
# pattern while keeping stdout to one exact machine-readable result.
set -euo pipefail
IFS=$'\n\t'

DLT_OK=0
DLT_PRECOND=20

PROJECT=""
DESCRIPTION=""
INPUT_REF=""
REVIEW_OF=""
LOOP_ROUND=""
DRY_RUN=0
JSON_OUTPUT=0
declare -a ACCEPTANCE=()
declare -a DEPENDENCIES=()
declare -a EXTRA_ANNOTATIONS=()

dlt_log() { printf 'dev-loop-task: %s\n' "$*" >&2; }
dlt_err() { printf 'dev-loop-task: ERROR: %s\n' "$*" >&2; }
dlt_die() { local code="$1"; shift; dlt_err "$*"; exit "$code"; }

usage() {
  cat >&2 <<'EOF'
Usage: dlt-create.sh --project <slug> --description <text>
                     --acceptance <criterion> [options]

Required:
  --project <slug>          Taskwarrior project slug
  --description <text>     concise task outcome
  --acceptance <criterion> acceptance outcome; repeatable

Options:
  --depends <task-ref>      dependency UUID/short UUID/ID; repeatable
  --input <ref>             add "input: <ref>"
  --review-of <value>       add "review-of: <value>"
  --loop-round <n>          add "loop-round: <n>" (positive integer)
  --annotation <text>       add another annotation; repeatable
  --json                    emit {uuid,review_branch,project,description,created}
  --dry-run                 validate and preview without importing
  -h, --help                show this help

Default stdout is the exact created UUID. Diagnostics and dry-run payloads go
to stderr. Exit: 0 success, 20 usage/precondition/import/verification failure.
EOF
}

require_value() {
  local flag="$1" remaining="$2"
  [ "$remaining" -gt 0 ] || { usage; dlt_die "$DLT_PRECOND" "$flag needs a value"; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      shift; require_value --project "$#"; PROJECT="$1" ;;
    --description)
      shift; require_value --description "$#"; DESCRIPTION="$1" ;;
    --acceptance)
      shift; require_value --acceptance "$#"; ACCEPTANCE+=("$1") ;;
    --depends)
      shift; require_value --depends "$#"; DEPENDENCIES+=("$1") ;;
    --input)
      shift; require_value --input "$#"
      [ -n "$1" ] || dlt_die "$DLT_PRECOND" "--input may not be empty"
      [ -z "$INPUT_REF" ] || dlt_die "$DLT_PRECOND" "--input may be supplied only once"
      INPUT_REF="$1" ;;
    --review-of)
      shift; require_value --review-of "$#"
      [ -n "$1" ] || dlt_die "$DLT_PRECOND" "--review-of may not be empty"
      [ -z "$REVIEW_OF" ] || dlt_die "$DLT_PRECOND" "--review-of may be supplied only once"
      REVIEW_OF="$1" ;;
    --loop-round)
      shift; require_value --loop-round "$#"
      [ -n "$1" ] || dlt_die "$DLT_PRECOND" "--loop-round may not be empty"
      [ -z "$LOOP_ROUND" ] || dlt_die "$DLT_PRECOND" "--loop-round may be supplied only once"
      LOOP_ROUND="$1" ;;
    --annotation)
      shift; require_value --annotation "$#"; EXTRA_ANNOTATIONS+=("$1") ;;
    --json) JSON_OUTPUT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit "$DLT_OK" ;;
    -*) usage; dlt_die "$DLT_PRECOND" "unknown flag: $1" ;;
    *) usage; dlt_die "$DLT_PRECOND" "unexpected argument: $1" ;;
  esac
  shift
done

[ -n "$PROJECT" ] || { usage; dlt_die "$DLT_PRECOND" "--project is required"; }
[ -n "$DESCRIPTION" ] || { usage; dlt_die "$DLT_PRECOND" "--description is required"; }
[ "${#ACCEPTANCE[@]}" -gt 0 ] || { usage; dlt_die "$DLT_PRECOND" "at least one --acceptance is required"; }
[[ "$DESCRIPTION" =~ [^[:space:]] ]] \
  || dlt_die "$DLT_PRECOND" "--description may not be blank"

case "$PROJECT" in
  *[!A-Za-z0-9._-]*|'') dlt_die "$DLT_PRECOND" "project must be a slug using letters, digits, '.', '_' or '-'" ;;
esac
if [ -n "$LOOP_ROUND" ] && ! [[ "$LOOP_ROUND" =~ ^[1-9][0-9]*$ ]]; then
  dlt_die "$DLT_PRECOND" "--loop-round must be a positive integer"
fi
if [ -n "$INPUT_REF" ] && [[ "$INPUT_REF" =~ [[:space:]] ]]; then
  dlt_die "$DLT_PRECOND" "--input must be one branch/ref without whitespace"
fi

reject_multiline() {
  local label="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) dlt_die "$DLT_PRECOND" "$label must be one line" ;;
  esac
}

reject_multiline "description" "$DESCRIPTION"
for value in "${ACCEPTANCE[@]}"; do
  [[ "$value" =~ [^[:space:]] ]] \
    || dlt_die "$DLT_PRECOND" "acceptance criteria may not be blank"
  reject_multiline "acceptance criterion" "$value"
done
for value in "${EXTRA_ANNOTATIONS[@]}"; do
  [[ "$value" =~ [^[:space:]] ]] || dlt_die "$DLT_PRECOND" "annotations may not be blank"
  reject_multiline "annotation" "$value"
done
if [ -n "$REVIEW_OF" ]; then
  [[ "$REVIEW_OF" =~ [^[:space:]] ]] || dlt_die "$DLT_PRECOND" "--review-of may not be blank"
  reject_multiline "review-of value" "$REVIEW_OF"
fi

missing=()
for command_name in task jq date tr sed; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
[ "${#missing[@]}" -eq 0 ] \
  || dlt_die "$DLT_PRECOND" "missing required command(s): ${missing[*]}"

dlt_task() {
  task rc.confirmation=no rc.recurrence.confirmation=no rc.context=none rc.verbose=nothing "$@"
}

dlt_task_export() {
  dlt_task rc.json.array=on "$@" export
}

if ! TASK_LOCKING="$(dlt_task _get rc.locking 2>/dev/null)"; then
  dlt_die "$DLT_PRECOND" "could not read Taskwarrior's locking setting"
fi
case "${TASK_LOCKING,,}" in
  0|false|no|off)
    dlt_die "$DLT_PRECOND" "Taskwarrior locking is disabled (rc.locking=$TASK_LOCKING); refusing concurrent-safe creation"
    ;;
esac

resolve_dependency() {
  local ref="$1" exported count resolved
  if ! exported="$(dlt_task_export "$ref" 2>/dev/null)"; then
    dlt_die "$DLT_PRECOND" "failed to resolve dependency: $ref"
  fi
  count="$(printf '%s' "$exported" | jq 'length' 2>/dev/null)" \
    || dlt_die "$DLT_PRECOND" "Taskwarrior returned invalid JSON while resolving dependency: $ref"
  [ "$count" = "1" ] \
    || dlt_die "$DLT_PRECOND" "dependency '$ref' resolved to $count tasks; expected exactly one"
  resolved="$(printf '%s' "$exported" | jq -r '.[0].uuid // empty')"
  [[ "$resolved" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || dlt_die "$DLT_PRECOND" "dependency '$ref' has no valid UUID"
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
    dlt_die "$DLT_PRECOND" "cannot generate a UUID (/proc UUID source and uuidgen are unavailable)"
  fi
  generated="${generated,,}"
  [[ "$generated" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || dlt_die "$DLT_PRECOND" "UUID generator returned an invalid value"
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
for criterion in "${ACCEPTANCE[@]}"; do NOTES+=("acceptance: $criterion"); done
[ -z "$INPUT_REF" ] || NOTES+=("input: $INPUT_REF")
[ -z "$REVIEW_OF" ] || NOTES+=("review-of: $REVIEW_OF")
[ -z "$LOOP_ROUND" ] || NOTES+=("loop-round: $LOOP_ROUND")
NOTES+=("${EXTRA_ANNOTATIONS[@]}")

DEPENDENCIES_JSON="$(json_array "${RESOLVED_DEPENDENCIES[@]}")"
NOTES_JSON="$(json_array "${NOTES[@]}")"
PAYLOAD="$(jq -cn \
  --arg uuid "$UUID" \
  --arg entry "$ENTRY" \
  --arg description "$DESCRIPTION" \
  --arg project "$PROJECT" \
  --argjson depends "$DEPENDENCIES_JSON" \
  --argjson notes "$NOTES_JSON" '
    {
      uuid: $uuid,
      status: "pending",
      entry: $entry,
      description: $description,
      project: $project,
      annotations: ($notes | map({entry: $entry, description: .}))
    }
    + if ($depends | length) > 0 then {depends: $depends} else {} end
  ')" || dlt_die "$DLT_PRECOND" "failed to construct task JSON"

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
      --arg description "$DESCRIPTION" \
      --argjson created "$created" \
      '{uuid: $uuid, review_branch: $review_branch, project: $project, description: $description, created: $created}'
  else
    printf '%s\n' "$UUID"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  dlt_log "DRY-RUN: would import the following task"
  printf '%s\n' "$PAYLOAD" | jq . >&2
  emit_result false
  exit "$DLT_OK"
fi

# `task import` identifies a task by UUID. Supplying our own UUID and complete
# JSON makes this one Taskwarrior-locked write; there is no mutable +LATEST
# selector for another creator to race. The precondition above rejects a task
# store whose internal locking has been explicitly disabled.
if ! printf '[%s]\n' "$PAYLOAD" | dlt_task import - >&2; then
  dlt_die "$DLT_PRECOND" "Taskwarrior import failed; proposed UUID was $UUID"
fi

if ! CREATED="$(dlt_task_export "$UUID" 2>/dev/null)"; then
  dlt_die "$DLT_PRECOND" "created task $UUID but could not export it for verification"
fi
if ! printf '%s' "$CREATED" | jq -e \
  --arg uuid "$UUID" \
  --arg project "$PROJECT" \
  --arg description "$DESCRIPTION" \
  --argjson depends "$DEPENDENCIES_JSON" \
  --argjson notes "$NOTES_JSON" '
    length == 1
    and .[0].uuid == $uuid
    and .[0].status == "pending"
    and .[0].project == $project
    and .[0].description == $description
    and (.[0].start? == null)
    and ((.[0].assignee // "") == "")
    and (((.[0].depends // []) | sort) == ($depends | sort))
    and ([.[0].annotations[]?.description] as $actual
         | (($notes - $actual) | length) == 0)
  ' >/dev/null; then
  dlt_die "$DLT_PRECOND" "task $UUID was imported but failed post-create verification"
fi

dlt_log "created pending, unstarted task $UUID ($REVIEW_BRANCH)"
emit_result true
