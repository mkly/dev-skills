#!/usr/bin/env bash

set -u

usage() {
  cat <<'EOF'
Usage: check.sh --agent <codex|claude|agy> [--small]

Poll Taskwarrior for pending work and launch the selected coding agent.
Use --small to consider only pending tasks tagged +SMALL.
EOF
}

agent=""
small_only=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      if [ "$#" -lt 2 ]; then
        printf 'check.sh: --agent requires a value\n' >&2
        usage >&2
        exit 2
      fi
      agent="$2"
      shift 2
      ;;
    --small)
      small_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'check.sh: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$agent" in
  codex|claude|agy) ;;
  "")
    printf 'check.sh: --agent is required\n' >&2
    usage >&2
    exit 2
    ;;
  *)
    printf 'check.sh: unsupported agent: %s\n' "$agent" >&2
    usage >&2
    exit 2
    ;;
esac

task_filter=(status:pending)
task_scope="all pending tasks"
agent_scope="Process pending tasks regardless of whether they have the +SMALL tag."

if "$small_only"; then
  task_filter+=(+SMALL)
  task_scope="pending +SMALL tasks"
  agent_scope="Only claim and process pending tasks tagged +SMALL; leave every other task untouched."
fi

prompt="/skills dev-loop Drain the existing ${task_scope} for this repository. Inspect matching pending Taskwarrior tasks first and use each task's existing goal and loop-id annotations; do not derive a new goal from this prompt. Process each existing goal and loop separately until no matching task remains. ${agent_scope} Exit if no matching pending task exists."

run_agent() {
  case "$agent" in
    codex)
      bash -c 'export AGENT_PID=$$; exec "$@"' check-agent \
        codex --yolo "$prompt"
      ;;
    claude)
      bash -c 'export AGENT_PID=$$; exec "$@"' check-agent \
        claude --dangerously-skip-permissions "$prompt"
      ;;
    agy)
      bash -c 'export AGENT_PID=$$; exec "$@"' check-agent \
        agy --dangerously-skip-permissions --prompt-interactive "$prompt"
      ;;
  esac
}

while true; do
  pending_count="$(task rc.verbose=nothing "${task_filter[@]}" count)"

  if [ "$pending_count" -eq 0 ]; then
    printf 'No %s. Checking again in 5 seconds...\n' "$task_scope"
    sleep 5
    continue
  fi

  run_agent
  printf 'Restarting in 5 seconds...\n'
  if [ -t 1 ]; then
    reset
  fi
  sleep 5
done
