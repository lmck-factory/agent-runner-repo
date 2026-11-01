#!/usr/bin/env bash
# Restore the most recent resume bundle for a target: the agent workspace's
# .work/ clone plus OpenCode's data dir (session state), so `opencode run
# --session <id>` continues an interrupted stage.
#
# Env:
#   TARGET          target repo (owner/repo)
#   STAGE           stage id (requirements|design|backend|web) — resume bundles
#                   are stage-scoped so a later stage's bundle is never
#                   restored into an earlier one
#   GITHUB_REPOSITORY  the agent-runner repo (set automatically on runners)
#   GH_TOKEN        token with actions:read on this repo
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_env TARGET STAGE GITHUB_REPOSITORY
ART_NAME="${TARGET//\//-}-${STAGE}-resume-bundle"

artifact_id=$(gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts?name=${ART_NAME}" \
  --jq '.artifacts | sort_by(.id) | reverse | .[0].id // empty' || true)
[ -n "$artifact_id" ] || die "no resume bundle artifact '${ART_NAME}' found for ${TARGET}"

log "downloading resume bundle artifact id=${artifact_id}"
TMP=$(mktemp -d)
gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" > "$TMP/bundle.zip"
unzip -q "$TMP/bundle.zip" -d "$TMP/bundle"

# The bundle keeps the original workspace layout: .factory/state,
# .factory/opencode-data (XDG_DATA_HOME with the session), and the agent
# workspace's .work clone. Restore all of it; the fresh agent clone made by
# checkout-agents.sh gets its interrupted .work back.
[ -d "$TMP/bundle/.factory" ] || die "unexpected resume bundle layout (no .factory/)"
mkdir -p .factory
cp -a "$TMP/bundle/.factory/." .factory/
rm -rf "$TMP"
log "restored .factory (state + OpenCode session data + agent .work clones)"
log "resume bundle restored"
