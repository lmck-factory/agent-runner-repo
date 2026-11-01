# Operations

## Running the factory

**Full run** — Actions → `factory-pipeline` → *Run workflow*, leave `target`
empty (all targets in `TARGET_REPOS`) and `start_from` empty (whole chain).
Or:

```
gh workflow run factory-pipeline.yml
```

**Single target** — pass `target=owner/repo`.

**Resume an interrupted stage** — when a stage fails or times out, the job
uploads a `<target>-<stage>-resume-bundle` artifact and (first failure only)
auto-dispatches a resume run. To resume manually instead:

1. open the failed run, copy the `session_id` from the `<stage>.state.json`
   shown in the log (or from the artifact);
2. dispatch with `target=owner/repo`, `start_from=<stage>`,
   `resume_session=<stage-id>`, `attempt=2`.

The resumed run restores `.work/` + OpenCode session data from the newest
resume bundle and continues with `opencode run --session <id>`. Stages before
`start_from` are skipped; later stages continue the chain. Auto-resume stops
after attempt 2 to prevent loops — beyond that, fix the cause and dispatch
manually.

**Re-run only deployment** (code already delivered, Render needs
re-provisioning): `start_from=bootstrap-api` or `start_from=bootstrap-web`.

**Re-verify a live system**: use `start_from=bootstrap-web` — provisioning is
idempotent (existing services are found, not recreated) and the chain then
re-runs the smoke tests and reconciliation. Note the API URL output is only
produced by `bootstrap-api`, so on a `bootstrap-web`-only restart the CORS
assertion is skipped (the web smoke test still runs); for a full CORS
re-verification, restart from `backend` or run the whole chain.
`verify-api`/`verify-live` are
chain-internal: starting *at* one of them directly leaves its upstream job
outputs (service URLs) empty, so prefer starting at the matching `bootstrap-*`
stage.

## Scheduled drift check

`factory-pipeline` runs weekly (`17 3 * * 1`). For each target it hashes the
latest commits touching the concept paths (`docs/concept/**`,
`docs/concept.md`, `concept/**`, `concept.md`) against `state/drift.json`
(committed back by the job). Only targets whose concept changed get a full
pipeline run; unchanged targets are skipped. First schedule marks everything
as changed (bootstrap run).

## Stage timeouts

Agent stages run with an internal 330-minute `timeout` inside a 355-minute job
— the gap lets the job still archive the resume bundle after an internal
timeout. Bootstrap/verify jobs cap at 45–60 minutes.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `resolve` outputs `targets=[]` | `TARGET_REPOS` unset or invalid JSON; or the `target` filter matches nothing. |
| Stage fails instantly on `opencode: command not found` | `opencode-ai` install failed (npm outage) or `OPENCODE_VERSION` pin is wrong. |
| Agent asks a question and stops | The agent only ever asks for the repo URL — if the prompt reached it malformed, check the stage log; resume with the session id after fixing. |
| `No requirements found …` in the design/backend/web stage | The upstream stage did not push its deliverables (check its run + the target repo). Fix by re-running the upstream stage (`start_from=<upstream>`), the hard gates will not let downstream improvise. |
| `stage <X> delivered no commits` (assert step) | The agent exited 0 without pushing — most likely it ended on one of its own gates (no design / no requirements / missing concept material); the agent's stated reason is in the stage log. Fix the input and re-run with `start_from=<X>`. |
| `gate failed: …/factory-status.json missing` | The upstream stage pushed commits but not its status artifact (interrupted delivery or a workspace running an older contract — re-publish the workspaces). Re-run the upstream stage. |
| `… does not satisfy the factory contract` (assert/gate/bootstrap) | The stage's `render.yaml`/`openapi.yaml` violates [factory-contract.md](factory-contract.md) — the error names the exact rule (missing env key, missing `databases:`, wrong `rootDir`, no `operationId`, …). Fix the workspace contract or re-run the stage after correcting the blueprint. |
| Render create-service 4xx | The `render.yaml` shape may exceed what the bootstrap maps (see the error hint). Adjust `render-bootstrap.mjs` payload mapping; the Render API reference is `https://api.render.com/v1`. |
| `DATABASE_URL` not set | Postgres connection details could not be extracted from the create response; set it in the Render dashboard (or fix `findConnection`). |
| CORS check fails in `verify-live` | `CORS_ALLOWED_ORIGINS` missing/stale on the API service — `bootstrap-web` should have wired it; re-run `start_from=bootstrap-web`. The API must be redeployed after the env change (the bootstrap triggers it). |
| Double deploys | Render-side autoDeploy got enabled by hand — the bootstrap sets `autoDeploy: no`; deploy triggers belong to the pipeline and the target's deploy workflows only. |
| Push rejected on the target | The agent handles `pull --rebase` + retry itself; repeated failures usually mean branch protection — allow the `FACTORY_PUSH_TOKEN` identity or run the target on a writable branch policy. |
| Auto-resume didn't fire | It only fires once per stage (`attempt < 2`) and needs `actions: write` (already granted). Dispatch manually as described above. |
| Reconciliation `FAIL` rows | Each row names a missing deliverable/service/var; re-run the responsible stage or the matching `bootstrap-*` job. |

## Costs & capacity notes

- Agent stages are long (up to ~6 h on hosted runners). For heavy use,
  self-hosted runners with larger disks are a drop-in change (add
  `runs-on:` per job).
- Render services keep running between pipeline runs — pause/delete them in
  the dashboard for dormant targets.
- Artifact storage: resume bundles expire with the repo's artifact retention
  (default 90 days); nothing depends on expired bundles.
