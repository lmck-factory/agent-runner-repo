#!/usr/bin/env bash
# Run one factory stage with OpenCode: timeout-guarded and stall-guarded.
#
# Env:
#   STAGE            stage id (requirements|design|backend|web)
#   AGENT_DIR        cloned agent workspace dir (contains .opencode/)
#   TARGET           target repo (owner/repo) — used to build the prompt
#   CONCEPT_FOLDER   concept folder (default docs/concept; requirements stage)
#   REQ_FOLDER       requirements folder (default docs/requirements)
#   DESIGN_FOLDER    design folder (default docs/solution-design)
#   MODEL            model reference for `opencode run -m` (e.g. openrouter/...)
#   MODEL_KEY        API key for the model's provider
#   MODEL_ENVVAR     provider key env var name (default OPENROUTER_API_KEY)
#   TIMEOUT_MIN      internal timeout in minutes (default 330; the job's own
#                    timeout-minutes must be larger so the timeout error prints)
#   STALL_MIN        abort with exit 137 when the stage produces no output for
#                    this many minutes (default 40) — a hung subagent or provider
#                    stream would otherwise burn the whole TIMEOUT_MIN silently
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_env STAGE AGENT_DIR TARGET MODEL MODEL_KEY
CONCEPT_FOLDER="${CONCEPT_FOLDER:-docs/concept}"
REQ_FOLDER="${REQ_FOLDER:-docs/requirements}"
DESIGN_FOLDER="${DESIGN_FOLDER:-docs/solution-design}"
MODEL_ENVVAR="${MODEL_ENVVAR:-OPENROUTER_API_KEY}"
TIMEOUT_MIN="${TIMEOUT_MIN:-330}"
STALL_MIN="${STALL_MIN:-40}"
case "$STALL_MIN" in
  ''|*[!0-9]*)
    echo "::error::STALL_MIN must be a whole number of minutes (got '$STALL_MIN')" >&2
    exit 2 ;;
esac

# Build the stage prompt with explicit named flags — the workspace commands
# parse these, so folders can never land in the wrong positional slot (the
# requirements command's $2 is the *concept* folder, not the requirements one).
prompt_for_stage() {
  local cmd repo
  cmd="$(command_for_stage "$1")"
  repo="https://github.com/${TARGET}"
  case "$1" in
    requirements) echo "${cmd} --repo ${repo} --concept ${CONCEPT_FOLDER} --requirements ${REQ_FOLDER} --design ${DESIGN_FOLDER}" ;;
    *)            echo "${cmd} --repo ${repo} --requirements ${REQ_FOLDER} --design ${DESIGN_FOLDER}" ;;
  esac
}

# Export the provider key under the env var the selected provider expects.
export "${MODEL_ENVVAR}=${MODEL_KEY}"

cd "$AGENT_DIR"
PROMPT="$(prompt_for_stage "$STAGE")"
log "running stage=$STAGE agent_dir=$AGENT_DIR model=$MODEL"
log "prompt=$PROMPT"

# Tee the stage output to a temp log: the streamed opencode events are the
# only activity signal available — a hung subagent or provider stream
# produces nothing at all, which is exactly what the watchdog looks for.
STAGE_LOG="$(mktemp "${TMPDIR:-/tmp}/factory-${STAGE}.XXXXXX")"
STALL_FLAG="${STAGE_LOG}.stall"

set +e
timeout --foreground "${TIMEOUT_MIN}m" \
  opencode run --agent "$(agent_name_for_stage "$STAGE")" -m "$MODEL" --format json "$PROMPT" \
  > >(tee "$STAGE_LOG") 2>&1 &
stage_pid=$!

# Stall watchdog: kill the stage when its output has been silent for
# STALL_MIN minutes. TERM first — timeout forwards it to opencode — then
# escalate after a grace period.
(
  while kill -0 "$stage_pid" 2>/dev/null; do
    last_write=$(stat -c %Y "$STAGE_LOG" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - last_write )) -ge $(( STALL_MIN * 60 )) ]; then
      : > "$STALL_FLAG"
      kill -TERM "$stage_pid" 2>/dev/null || true
      sleep 30
      pkill -KILL -P "$stage_pid" 2>/dev/null || true
      kill -KILL "$stage_pid" 2>/dev/null || true
      exit 0
    fi
    sleep 30
  done
) &
watchdog_pid=$!

wait "$stage_pid"
rc=$?
if [ -f "$STALL_FLAG" ]; then
  # A stall kill is in progress or done — let the watchdog finish its
  # escalation instead of reaping it mid-flight.
  wait "$watchdog_pid" 2>/dev/null || true
else
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
fi
set -e

log "stage=$STAGE exit=$rc"

# The flag file is authoritative: a stall kill outranks every other
# diagnosis, even when it raced a normal exit or landed as a 124.
if [ "$rc" != "0" ] && [ -f "$STALL_FLAG" ]; then
  echo "::error::stage $STAGE stalled — no output for ${STALL_MIN}m; last output:" >&2
  tail -n 50 "$STAGE_LOG" >&2 || true
  exit 137
fi
if [ "$rc" = "124" ]; then
  echo "::error::stage $STAGE timed out after ${TIMEOUT_MIN}m" >&2
  exit 124
fi
exit "$rc"
