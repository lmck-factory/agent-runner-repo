#!/usr/bin/env bash
# Shared helpers for the factory pipeline scripts.
set -euo pipefail

# Stale VS Code js-debug env: NODE_OPTIONS may point at a deleted bootloader.js,
# which crashes any node invocation (MODULE_NOT_FOUND) before the script body
# even runs. Harmless outside VS Code.
unset NODE_OPTIONS VSCODE_INSPECTOR_OPTIONS

log()  { echo "[factory] $*" >&2; }
die()  { echo "[factory][error] $*" >&2; exit 1; }

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || die "required environment variable $name is not set"
  done
}

# Stage -> agent workspace mapping (repo names live in the lmck-factory org).
agent_repo_for_stage() {
  case "$1" in
    requirements) echo "product-manager" ;;
    design)       echo "solution-architect" ;;
    backend)      echo "backend-developer" ;;
    web)          echo "web-developer" ;;
    *) die "unknown stage '$1'" ;;
  esac
}

agent_name_for_stage() {
  case "$1" in
    requirements) echo "product-manager" ;;
    design)       echo "solution-architect" ;;
    backend)      echo "backend-developer" ;;
    web)          echo "web-developer" ;;
    *) die "unknown stage '$1'" ;;
  esac
}

command_for_stage() {
  case "$1" in
    requirements) echo "/requirements" ;;
    design)       echo "/design" ;;
    backend)      echo "/implement-api" ;;
    web)          echo "/implement-web" ;;
    *) die "unknown stage '$1'" ;;
  esac
}

# Called by an assert step when the default branch did not move: print the
# tail of the stage log (exported by run-stage.sh as STAGE_LOG) and say what
# the stage actually ended on — its own gate statement, or nothing at all.
# $1 = stage id, $2 = GitHub annotation prefix ("::error::" / "::warning::").
report_no_delivery() {
  local stage="${1:?stage id}" ann="${2:-::error::}" tail_text
  if [ -z "${STAGE_LOG:-}" ] || [ ! -f "$STAGE_LOG" ]; then
    echo "${ann}stage $stage delivered no commits (stage log not found: STAGE_LOG='${STAGE_LOG:-unset}')"
    return 0
  fi
  echo "--- tail of $STAGE_LOG ---"
  tail -n 80 "$STAGE_LOG" || true
  echo "--- end of tail ---"
  # Classify from the last 200 lines. Bash pattern matching rather than a
  # `tail | grep -q` pipeline: under pipefail, grep exiting early closes the
  # pipe, tail dies of SIGPIPE and the pipeline reports failure even on a match.
  tail_text=$(tail -n 200 "$STAGE_LOG" || true)
  case "$tail_text" in
    *"No solution design found"*|*"No requirements found"*)
      echo "${ann}stage $stage delivered no commits — the agent ended on one of its own gates; its statement of fact is in the tail above" ;;
    *)
      echo "${ann}stage $stage delivered no commits — the run ended with no delivery and no stated reason; the tail above is the last thing it produced" ;;
  esac
}

# Make every git clone inside the runner (agent workspaces, target repos the
# agents clone themselves from within OpenCode) authenticate with the PAT.
configure_git_auth() {
  require_env FACTORY_PUSH_TOKEN
  git config --global user.name "factory-bot"
  git config --global user.email "factory-bot@users.noreply.github.com"
  git config --global --add safe.directory '*'
  git config --global url."https://x-access-token:${FACTORY_PUSH_TOKEN}@github.com/".insteadOf "https://github.com/"
}
