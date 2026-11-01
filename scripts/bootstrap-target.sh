#!/usr/bin/env bash
# Validate a target repository is ready for a factory run: repo reachable,
# default branch resolvable, concept material present. Run manually or as a
# pre-flight before dispatching the pipeline.
#
# Usage: scripts/bootstrap-target.sh <owner/repo>
# Env:   GH_TOKEN (or gh already authenticated), REQ_FOLDER, DESIGN_FOLDER
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

TARGET="${1:?usage: bootstrap-target.sh <owner/repo>}"
REQ_FOLDER="${REQ_FOLDER:-docs/requirements}"
DESIGN_FOLDER="${DESIGN_FOLDER:-docs/solution-design}"
command -v gh >/dev/null || die "gh CLI is required"

branch=$(gh api "repos/${TARGET}" --jq .default_branch)
log "target=$TARGET default_branch=$branch"

has() { gh api "repos/${TARGET}/contents/$1?ref=${branch}" --jq .path >/dev/null 2>&1; }

CONCEPT=""
for c in docs/concept/README.md docs/concept.md concept/README.md concept.md; do
  if has "$c"; then CONCEPT="$c"; break; fi
done
[ -n "$CONCEPT" ] || die "no concept material found (looked for docs/concept/README.md, docs/concept.md, concept/README.md, concept.md) — add the concept before running the pipeline"

if has "${REQ_FOLDER}/README.md"; then log "note: ${REQ_FOLDER}/ already has requirements (run will extend, not create)"; fi
if has "${DESIGN_FOLDER}/README.md"; then log "note: ${DESIGN_FOLDER}/ already has a design (run will extend, not create)"; fi

log "target is ready: concept=$CONCEPT branch=$branch"
