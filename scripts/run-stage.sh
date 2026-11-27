#!/usr/bin/env bash
# Run one factory stage with OpenCode: timeout-guarded, stall-guarded, and
# guarded against a run that stops early with exit 0.
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
#   MIN_STAGE_SEC    minimum plausible runtime for a delivered stage, in seconds
#                    (default 900). A run that ends sooner exited 0 while the
#                    agent was still mid-work: a provider turn carrying no
#                    executable tool call leaves the session idle and `opencode
#                    run` exits 0 with no error event at all. Such a run is
#                    retried once and then failed with exit 3. 0 disables it.
#   STAGE_ATTEMPTS   attempts allowed for that early exit (default 2 = one retry)
#
# The stage log always lives at a stable path — exported to later steps of the
# same job as STAGE_LOG through $GITHUB_ENV — so the pipeline's assert step can
# tail it when no commit landed, and the job can upload it as an artifact.
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
MIN_STAGE_SEC="${MIN_STAGE_SEC:-900}"
STAGE_ATTEMPTS="${STAGE_ATTEMPTS:-2}"
for numeric_var in STALL_MIN MIN_STAGE_SEC STAGE_ATTEMPTS TIMEOUT_MIN; do
  case "${!numeric_var}" in
    ''|*[!0-9]*)
      echo "::error::$numeric_var must be a whole number (got '${!numeric_var}')" >&2
      exit 2 ;;
  esac
done

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

# A stable log path (not a mktemp) so the assert step can read it after this
# script exits. Tee the stage output into it: the streamed opencode events are
# the only activity signal available — a hung subagent or provider stream
# produces nothing at all, which is exactly what the watchdog looks for.
STAGE_LOG="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/factory-${STAGE}.log"
STALL_FLAG="${STAGE_LOG}.stall"
# Create it before the first watchdog sample, so a missing file can never read
# as "no output since the epoch".
: > "$STAGE_LOG"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "STAGE_LOG=$STAGE_LOG" >> "$GITHUB_ENV"
fi

# One attempt: timeout-guarded and stall-guarded. Leaves rc + elapsed set.
run_attempt() {
  local attempt="$1" start_ts rc_attempt watchdog_pid
  rm -f "$STALL_FLAG"
  start_ts=$(date +%s)

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
      last_write=$(stat -c %Y "$STAGE_LOG" 2>/dev/null || date +%s)
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
  rc_attempt=$?
  if [ -f "$STALL_FLAG" ]; then
    # A stall kill is in progress or done — let the watchdog finish its
    # escalation instead of reaping it mid-flight.
    wait "$watchdog_pid" 2>/dev/null || true
  else
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  set -e

  rc=$rc_attempt
  elapsed=$(( $(date +%s) - start_ts ))
  log "stage=$STAGE attempt=$attempt/$STAGE_ATTEMPTS exit=$rc elapsed=${elapsed}s"
}

attempt=1
while :; do
  run_attempt "$attempt"
  if [ "$rc" = "0" ] && [ "$elapsed" -lt "$MIN_STAGE_SEC" ] && [ "$attempt" -lt "$STAGE_ATTEMPTS" ]; then
    # Exit 0 this early is not a delivery: the model stopped mid-work without
    # an error event (see MIN_STAGE_SEC). Retry once from a clean session —
    # the clone survives, so the agent picks its own residue up.
    echo "::warning::stage $STAGE ended after ${elapsed}s — under the ${MIN_STAGE_SEC}s floor, so the model stopped early; retrying (attempt $((attempt + 1))/$STAGE_ATTEMPTS)" >&2
    mv -f "$STAGE_LOG" "${STAGE_LOG}.attempt${attempt}"
    : > "$STAGE_LOG"
    attempt=$((attempt + 1))
    continue
  fi
  break
done

log "stage=$STAGE exit=$rc elapsed=${elapsed}s attempts=$attempt/$STAGE_ATTEMPTS log=$STAGE_LOG"

# Diagnosis precedence: a stall kill outranks everything (even a normal exit
# it raced), then the internal timeout, then the early-exit floor, then the
# model's own exit code.
if [ -f "$STALL_FLAG" ]; then
  echo "::error::stage $STAGE stalled — no output for ${STALL_MIN}m; last output:" >&2
  tail -n 50 "$STAGE_LOG" >&2 || true
  exit 137
fi
if [ "$rc" = "124" ]; then
  echo "::error::stage $STAGE timed out after ${TIMEOUT_MIN}m" >&2
  exit 124
fi
if [ "$rc" = "0" ] && [ "$elapsed" -lt "$MIN_STAGE_SEC" ]; then
  echo "::error::stage $STAGE ended after ${elapsed}s — the model stopped early without delivering (floor ${MIN_STAGE_SEC}s, attempts $attempt/$STAGE_ATTEMPTS); last output:" >&2
  tail -n 80 "$STAGE_LOG" >&2 || true
  exit 3
fi
exit "$rc"
