#!/usr/bin/env bash
# Run one factory stage with OpenCode: timeout-guarded.
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
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_env STAGE AGENT_DIR TARGET MODEL MODEL_KEY
CONCEPT_FOLDER="${CONCEPT_FOLDER:-docs/concept}"
REQ_FOLDER="${REQ_FOLDER:-docs/requirements}"
DESIGN_FOLDER="${DESIGN_FOLDER:-docs/solution-design}"
MODEL_ENVVAR="${MODEL_ENVVAR:-OPENROUTER_API_KEY}"
TIMEOUT_MIN="${TIMEOUT_MIN:-330}"

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

set +e
timeout --foreground "${TIMEOUT_MIN}m" \
  opencode run --agent "$(agent_name_for_stage "$STAGE")" -m "$MODEL" --format json "$PROMPT"
rc=$?
set -e

log "stage=$STAGE exit=$rc"
if [ "$rc" = "124" ]; then
  echo "::error::stage $STAGE timed out after ${TIMEOUT_MIN}m" >&2
  exit 124
fi
exit "$rc"
