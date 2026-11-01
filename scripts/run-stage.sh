#!/usr/bin/env bash
# Run one factory stage with OpenCode: timeout-guarded, session-resumable.
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
#                    timeout-minutes must be larger so artifacts can upload)
#   SESSION_ID       optional: resume this session instead of starting one
#   STATE_DIR        where logs/state land (default .factory/state)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_env STAGE AGENT_DIR TARGET MODEL MODEL_KEY
CONCEPT_FOLDER="${CONCEPT_FOLDER:-docs/concept}"
REQ_FOLDER="${REQ_FOLDER:-docs/requirements}"
DESIGN_FOLDER="${DESIGN_FOLDER:-docs/solution-design}"
MODEL_ENVVAR="${MODEL_ENVVAR:-OPENROUTER_API_KEY}"
TIMEOUT_MIN="${TIMEOUT_MIN:-330}"
STATE_DIR="${STATE_DIR:-.factory/state}"
RESUME_PROMPT="${RESUME_PROMPT:-Continue the run to completion: finish the current phase, run the critic loop, deliver, commit, and push as the workspace conventions require.}"

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

mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/${STAGE}.log"
STATE="$STATE_DIR/${STAGE}.state.json"

# Export the provider key under the env var the selected provider expects.
export "${MODEL_ENVVAR}=${MODEL_KEY}"
# Keep OpenCode's data (sessions, storage) inside the workspace so it can be
# archived for resume.
export XDG_DATA_HOME="${XDG_DATA_HOME:-$PWD/.factory/opencode-data}"

cd "$AGENT_DIR"
log "running stage=$STAGE agent_dir=$AGENT_DIR model=$MODEL resume_session=${SESSION_ID:-<none>}"
[ -n "${SESSION_ID:-}" ] || log "prompt=$(prompt_for_stage "$STAGE")"

set +e
if [ -n "${SESSION_ID:-}" ]; then
  # Resumed sessions keep their agent, but the model must stay the pipeline's
  # — otherwise a resume silently runs on OpenCode's default model.
  timeout --foreground "${TIMEOUT_MIN}m" \
    opencode run --session "$SESSION_ID" -m "$MODEL" --format json "$RESUME_PROMPT" 2>&1 | tee "$LOG"
else
  PROMPT="$(prompt_for_stage "$STAGE")"
  timeout --foreground "${TIMEOUT_MIN}m" \
    opencode run --agent "$(agent_name_for_stage "$STAGE")" -m "$MODEL" --format json "$PROMPT" 2>&1 | tee "$LOG"
fi
rc=${PIPESTATUS[0]}
set -e

# Tolerant session-id extraction: JSON("sessionID":"ses_...") or free text.
sid="${SESSION_ID:-}"
if [ -z "$sid" ]; then
  sid=$(grep -o '"sessionID"[[:space:]]*:[[:space:]]*"[^"]*"' "$LOG" 2>/dev/null \
        | tail -1 | sed 's/.*"sessionID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
fi
if [ -z "$sid" ]; then
  sid=$(grep -oE 'ses_[A-Za-z0-9]+' "$LOG" 2>/dev/null | tail -1 || true)
fi

printf '{"stage":"%s","session_id":"%s","exit_code":%s}\n' "$STAGE" "$sid" "$rc" > "$STATE"
log "stage=$STAGE exit=$rc session_id=${sid:-<not found>}"

if [ "$rc" = "124" ]; then
  echo "::error::stage $STAGE timed out after ${TIMEOUT_MIN}m; resumable with session ${sid:-<unknown>}" >&2
  exit 124
fi
exit "$rc"
