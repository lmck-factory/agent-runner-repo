#!/usr/bin/env bash
# Clone (or refresh) one agent workspace repo into .factory/agents/<name>/.
#
# Env:
#   STAGE                stage id (requirements|design|backend|web)
#   AGENT_REPO           agent workspace repo (owner/name); defaults to the
#                        stage's mapped repo name under $FACTORY_ORG
#   FACTORY_ORG          GitHub org owning the agent repos (default lmck-factory)
#   AGENTS_ROOT          checkout root (default .factory/agents)
#   FACTORY_PUSH_TOKEN   PAT used for cloning private agent repos
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_env STAGE
FACTORY_ORG="${FACTORY_ORG:-lmck-factory}"
AGENTS_ROOT="${AGENTS_ROOT:-.factory/agents}"
AGENT_REPO="${AGENT_REPO:-${FACTORY_ORG}/$(agent_repo_for_stage "$STAGE")}"
NAME="${AGENT_REPO##*/}"

configure_git_auth

mkdir -p "$AGENTS_ROOT"
DEST="$AGENTS_ROOT/$NAME"

if [ -d "$DEST/.git" ]; then
  log "refreshing existing clone of $AGENT_REPO"
  git -C "$DEST" fetch --all --prune
  git -C "$DEST" reset --hard origin/HEAD
else
  log "cloning $AGENT_REPO -> $DEST"
  git clone "https://github.com/${AGENT_REPO}.git" "$DEST"
fi

git -C "$DEST" rev-parse HEAD >&2
log "agent workspace $NAME ready at $DEST"
echo "$DEST"
