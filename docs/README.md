# Agent Runner — factory orchestrator

This repository drives the four OpenCode agent workspaces as one autonomous
factory. Given a target repository holding a **concept**, it runs

1. **requirements** — `product-manager` writes `docs/requirements/`
2. **design** — `solution-architect` writes `docs/solution-design/`
3. **backend** — `backend-developer` writes `app/api/` + `ci-api.yml`/`deploy-api.yml`
4. **web** — `web-developer` writes `app/web/` + `ci-web.yml`/`deploy-web.yml`

and in between provisions and deploys the result on **Render** via the Render
API, ending with a live smoke test (web + API + CORS) and a repo/Render
reconciliation check. One GitHub Actions run per target repo, isolated from
the others.

## Layout

```
.github/workflows/
├── factory-pipeline.yml   # entry point: resolve targets, drift check (schedule),
│                          # matrix-dispatch one target-pipeline per repo
└── target-pipeline.yml    # reusable chain: requirements -> design -> backend
                           # -> bootstrap-api -> verify-api -> web
                           # -> bootstrap-web -> verify-live
scripts/
├── lib.sh                 # shared helpers (stage<->agent mapping, git auth)
├── resolve-inputs.sh      # targets/stages/model resolution for the matrix
├── checkout-agents.sh     # clone/refresh one agent workspace repo
├── run-stage.sh           # opencode run under timeout, session extraction
├── gate-check.sh          # upstream artifact + factory-status + contract gates
├── validate-blueprint.mjs # render.yaml / openapi.yaml vs the factory contract
├── restore-resume.sh      # restore .work + OpenCode session data from artifacts
├── render-bootstrap.mjs   # Render services + Postgres + env wiring + deploys
├── smoke-test.mjs         # wait-for-live + HTTP + CORS assertions
├── reconcile-check.mjs    # repo deliverables vs Render reality
├── drift-check.mjs        # concept drift detection (scheduled)
├── publish-agent-repos.sh # one-time: push the 4 workspaces to GitHub
└── bootstrap-target.sh    # pre-flight validation of a target repo
state/drift.json           # committed drift state (updated by the schedule)
docs/
├── README.md              # this documentation
├── setup.md               # one-time manual setup
├── operations.md          # running, resuming, troubleshooting
└── factory-contract.md    # CANONICAL machine-verified contract between the
                           # agent workspaces and the orchestrator (copies ship
                           # in the backend-developer/web-developer workspaces)
```

## How a stage runs

Each agent stage job:

1. checks out **this** repo and installs OpenCode (`opencode-ai`);
2. clones the stage's agent workspace repo (e.g. `lmck-factory/backend-developer`)
   into `.factory/agents/<name>/` — the agent runs inside its workspace, so its
   `AGENTS.md`, `.opencode/` config, permissions and bundled skills apply;
3. runs `opencode run --agent <agent> -m "$PIPELINE_MODEL" "/<command> <target-url> …"`
   under an internal timeout (330 min; job limit 355 min) with
   `XDG_DATA_HOME` inside the workspace so session state is archivable;
4. the agent itself clones the target repo into its `.work/`, implements,
   critic-loops, commits and pushes to the target's default branch —
   authenticated via the `FACTORY_PUSH_TOKEN` git credential rewrite — and
   commits its `factory-status.json` status artifact (factory contract §2);
5. the job then **asserts the stage delivered**: the default branch must have
   advanced during the stage (a stage that ends on one of its own gates exits 0
   without pushing and is failed here with the agent's own stated reason in its
   log), and — for the implementer stages — the delivered `render.yaml` /
   `openapi.yaml` must satisfy the factory contract
   (`validate-blueprint.mjs`), so a contract violation fails the responsible
   stage instead of the Render bootstrap 40 minutes later;
6. on failure/timeout the job archives `.factory/state`, the OpenCode data dir
   and the agent's `.work/` as a stage-scoped `<target>-<stage>-resume-bundle`
   artifact and
   re-dispatches the pipeline once with `start_from=<stage>` +
   `resume_session=<id>`, which restores the bundle and continues via
   `opencode run --session <id> -m "$PIPELINE_MODEL"` instead of starting over.

The model comes from the `PIPELINE_MODEL` variable (e.g.
`openrouter/anthropic/claude-sonnet-4.5`) and its provider key from the
`OPENCODE_MODEL_API_KEY` secret, exported under the env var named by
`PIPELINE_MODEL_ENVVAR` (default `OPENROUTER_API_KEY`). The agent workspaces
deliberately pin **no** model.

## Deployment model

- Each target's `app/api/render.yaml` and `app/web/render.yaml` are the Render
  **resource declarations** the bootstrap consumes — services are created via
  `POST /v1/services`, managed Postgres via `POST /v1/postgres`.
- Deploys are triggered **only** two ways: by this pipeline
  (`POST /v1/services/{id}/deploys`) and by the target's own
  `deploy-api.yml`/`deploy-web.yml` on push. Render-side autoDeploy is set to
  `no` so nothing double-fires.
- The bootstrap also syncs `RENDER_API_KEY` (secret) and
  `RENDER_API_SERVICE_ID`/`RENDER_WEB_SERVICE_ID` (variables) into the target
  repo, which is what its deploy workflows use — the agents' docs describe
  exactly this setup.
- After the web service exists, the bootstrap sets the API's
  `CORS_ALLOWED_ORIGINS` to the web origin and redeploys the API;
  `verify-live` fails if the API does not actually answer the web origin.

See [setup.md](setup.md) for the one-time manual setup and
[operations.md](operations.md) for running, resuming and troubleshooting.
