#!/usr/bin/env bash
# Resolve pipeline inputs: which targets to run, and per target which stage to
# start from (with an optional resume session). Writes outputs for the caller.
#
# Env (workflow inputs, may be empty):
#   INPUT_TARGET         single target filter (owner/repo)
#   INPUT_START_FROM     stage to start from (skips earlier stages)
#   INPUT_RESUME_SESSION session id to resume inside the start_from stage
#   INPUT_ATTEMPT        resume attempt counter (default 1)
# Vars:
#   TARGET_REPOS         JSON array of owner/repo strings
#   PIPELINE_MODEL       model reference (default openrouter/auto)
#   PIPELINE_MODEL_ENVVAR  provider key env var (default OPENROUTER_API_KEY)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

TARGET_REPOS="${TARGET_REPOS:-[]}"

OUT=$(TARGET_REPOS="$TARGET_REPOS" \
      INPUT_START_FROM="${INPUT_START_FROM:-}" \
      INPUT_RESUME_SESSION="${INPUT_RESUME_SESSION:-}" \
      INPUT_ATTEMPT="${INPUT_ATTEMPT:-1}" \
      PIPELINE_MODEL="${PIPELINE_MODEL:-}" \
      PIPELINE_MODEL_ENVVAR="${PIPELINE_MODEL_ENVVAR:-}" \
      node <<'EOF'
const order = ["requirements", "design", "backend", "bootstrap-api", "verify-api", "web", "bootstrap-web", "verify-live"];
let repos = [];
try { repos = JSON.parse(process.env.TARGET_REPOS || "[]"); } catch (e) {
  console.error("[factory][error] TARGET_REPOS is not valid JSON: " + e.message);
  process.exit(1);
}
if (!Array.isArray(repos)) repos = [];

// verify-api / verify-live are chain-internal: their smoke tests read the
// service URLs from their bootstrap-* ancestors' outputs, which are empty when
// those jobs are skipped. Starting at a verify-* stage can only fail, so point
// at the matching bootstrap-* instead (provisioning is idempotent).
const resumable = order.filter((s) => !s.startsWith("verify-"));
const start = process.env.INPUT_START_FROM || "";
if (start && !resumable.includes(start)) {
  const hint = order.includes(start)
    ? "start at the matching bootstrap-* stage instead (verify-* stages are chain-internal: their service-URL outputs only exist in a full chain)"
    : "valid values: " + resumable.join(", ");
  console.error("[factory][error] INPUT_START_FROM '" + start + "' is not a valid start stage — " + hint);
  process.exit(1);
}

let chosen = repos;
const filter = process.env.INPUT_TARGET || "";
if (filter) chosen = repos.filter(r => r === filter || r.endsWith("/" + filter));
if (repos.length > 0 && chosen.length === 0) {
  console.error("[factory][error] target filter '" + filter + "' matches none of: " + repos.join(", "));
  process.exit(1);
}

// A resume session only means alongside a start stage (the restore step runs
// when start_from matches the stage); ignore stray values on full runs.
const session = start ? (process.env.INPUT_RESUME_SESSION || "") : "";
const attempt = start ? (process.env.INPUT_ATTEMPT || "1") : "1";
const matrix = chosen.map(repo => ({
  repo,
  start_from: start,
  resume_session: session,
  attempt,
}));
const runStages = start ? order.slice(order.indexOf(start)) : order;

console.log("targets=" + JSON.stringify(matrix));
console.log("run_stages=" + runStages.join(" "));
console.log("model=" + (process.env.PIPELINE_MODEL || "openrouter/auto"));
console.log("model_envvar=" + (process.env.PIPELINE_MODEL_ENVVAR || "OPENROUTER_API_KEY"));
EOF
)

echo "$OUT"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "$OUT" >> "$GITHUB_OUTPUT"
fi
