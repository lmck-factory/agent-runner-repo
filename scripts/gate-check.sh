#!/usr/bin/env bash
# Verify that a stage's upstream inputs exist on the target repo's default
# branch before the stage runs (defense in depth beside the agents' own gates).
#
# Env:
#   GATE             gate to enforce:
#                      design   -> requirements delivered (README + factory
#                                  status file declaring 'delivered')
#                      backend  -> design delivered (README + factory status)
#                      web      -> design delivered; the backend's canonical
#                                  contract present AND valid: app/api/
#                                  openapi.yaml + app/api/render.yaml must
#                                  satisfy the factory contract
#   TARGET           target repo (owner/repo)
#   REQ_FOLDER       default docs/requirements
#   DESIGN_FOLDER    default docs/solution-design
#   GATE_PUSHED      optional: 'true'|'false' — whether the upstream stage
#                    pushed commits this run (job output of the upstream
#                    agent job). Empty on resumed runs, where the status file
#                    is the only assertion available.
#   GH_TOKEN         token for gh api
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_env GATE TARGET
REQ_FOLDER="${REQ_FOLDER:-docs/requirements}"
DESIGN_FOLDER="${DESIGN_FOLDER:-docs/solution-design}"

command -v gh >/dev/null || die "gh CLI is required"
command -v node >/dev/null || die "node is required"

branch=$(gh api "repos/${TARGET}" --jq .default_branch)
log "gate=$GATE target=$TARGET branch=$branch"

exists() {
  gh api "repos/${TARGET}/contents/$1?ref=${branch}" --jq .path >/dev/null 2>&1
}

# Fetch a file from the target's default branch as raw text.
fetch() {
  gh api -H "Accept: application/vnd.github.raw" "repos/${TARGET}/contents/$1?ref=${branch}"
}

# The upstream stage's own run must have declared itself delivered in its
# factory-status.json (contract: docs/factory-contract.md).
check_stage_status() {
  local path="$1" expect="$2" body stage status
  body=$(fetch "$path" 2>/dev/null) \
    || die "gate failed: ${path} missing on ${TARGET}@${branch} — the '${expect}' stage has not delivered (no factory status). Re-run it with start_from=<${expect}>."
  stage=$(echo "$body" | jq -r '.stage // empty' 2>/dev/null || true)
  status=$(echo "$body" | jq -r '.status // empty' 2>/dev/null || true)
  [ "$stage" = "$expect" ] \
    || die "gate failed: ${path} declares stage '${stage}', expected '${expect}' — stale or foreign status file"
  [ "$status" = "delivered" ] \
    || die "gate failed: the '${expect}' stage status is '${status:-unknown}' — it did not deliver; re-run it with start_from=<${expect}> and check its log for the stated reason"
  log "gate: '${expect}' delivered (status file ok)"
}

# The upstream agent job asserts it pushed commits (HEAD moved during the
# stage). A stage that ends on one of its own gates exits 0 without pushing —
# that must fail here rather than silently continue the chain.
check_upstream_pushed() {
  if [ -z "${GATE_PUSHED:-}" ]; then
    log "gate: upstream push assertion unavailable (resumed run) — relying on the status file"
  elif [ "$GATE_PUSHED" != "true" ]; then
    die "gate failed: the upstream stage pushed no commits this run — it most likely ended on one of its own gates (see its stage log for the stated reason)"
  else
    log "gate: upstream stage pushed commits this run"
  fi
}

validate_target_file() {
  local kind="$1" path="$2" tmp
  tmp=$(mktemp)
  fetch "$path" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; die "gate failed: ${path} missing on ${TARGET}@${branch}"; }
  if ! node "$(dirname "$0")/validate-blueprint.mjs" --kind "$kind" --file "$tmp"; then
    rm -f "$tmp"
    die "gate failed: ${path} does not satisfy the factory contract (see docs/factory-contract.md) — fix the upstream stage with start_from=<stage>"
  fi
  rm -f "$tmp"
  log "gate: ${path} satisfies the factory contract"
}

case "$GATE" in
  requirements)
    # No upstream gate; sanity-check the concept folder instead when present.
    if exists "docs/concept/README.md" || exists "docs/concept.md"; then
      log "concept material present"
    else
      log "warning: no docs/concept found — the agent will use the prompt's concept"
    fi
    ;;
  design)
    exists "${REQ_FOLDER}/README.md" \
      || die "gate failed: ${REQ_FOLDER}/README.md missing on ${TARGET}@${branch} — the requirements stage has not delivered"
    check_stage_status "${REQ_FOLDER}/factory-status.json" "requirements"
    check_upstream_pushed
    log "gate passed: requirements present and delivered"
    ;;
  backend)
    exists "${DESIGN_FOLDER}/README.md" \
      || die "gate failed: ${DESIGN_FOLDER}/README.md missing on ${TARGET}@${branch} — the design stage has not delivered"
    check_stage_status "${DESIGN_FOLDER}/factory-status.json" "design"
    check_upstream_pushed
    log "gate passed: design present and delivered"
    ;;
  web)
    exists "${DESIGN_FOLDER}/README.md" \
      || die "gate failed: ${DESIGN_FOLDER}/README.md missing on ${TARGET}@${branch} — the design stage has not delivered"
    check_stage_status "${DESIGN_FOLDER}/factory-status.json" "design"
    # The web stage builds its typed client from the backend's canonical
    # contract — it must exist and satisfy the factory contract (hard gate).
    exists "app/api/openapi.yaml" \
      || die "gate failed: app/api/openapi.yaml missing on ${TARGET}@${branch} — the backend stage has not delivered the canonical API contract"
    check_stage_status "app/api/factory-status.json" "backend"
    validate_target_file openapi "app/api/openapi.yaml"
    validate_target_file api "app/api/render.yaml"
    log "gate passed: design delivered, backend contract present and valid"
    ;;
  *)
    die "unknown gate '$GATE'"
    ;;
esac
