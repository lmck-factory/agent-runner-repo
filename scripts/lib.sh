#!/usr/bin/env bash
# Shared helpers for the factory pipeline scripts.
set -euo pipefail

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

# Make every git clone inside the runner (agent workspaces, target repos the
# agents clone themselves from within OpenCode) authenticate with the PAT.
configure_git_auth() {
  require_env FACTORY_PUSH_TOKEN
  git config --global user.name "factory-bot"
  git config --global user.email "factory-bot@users.noreply.github.com"
  git config --global --add safe.directory '*'
  git config --global url."https://x-access-token:${FACTORY_PUSH_TOKEN}@github.com/".insteadOf "https://github.com/"
}
