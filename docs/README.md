# Agent Runner — factory orchestrator

This repository drives the four OpenCode agent workspaces as one autonomous
factory. Given a target repository holding a **concept**, it runs

1. **requirements** — `product-manager` writes `docs/requirements/`
2. **design** — `solution-architect` writes `docs/solution-design/`
3. **backend** — `backend-developer` writes `app/api/` + `ci-api.yml`/`deploy-api.yml`
4. **web** — `web-developer` writes `app/web/` + `ci-web.yml`/`deploy-web.yml`

against every repo in `vars.TARGET_REPOS`. One GitHub Actions run per target
repo, isolated from the others.

## Layout

```
.github/workflows/
├── factory-pipeline.yml   # entry point: matrix-dispatch one target-pipeline
│                          # per repo in vars.TARGET_REPOS
└── target-pipeline.yml    # reusable chain: requirements -> design -> backend
                           # -> web (one job per stage)
scripts/
├── lib.sh                 # shared helpers (stage<->agent mapping, git auth)
├── checkout-agents.sh     # clone/refresh one agent workspace repo
└── run-stage.sh           # opencode run under timeout
docs/
├── README.md              # this documentation
├── setup.md               # one-time manual setup
├── operations.md          # running and troubleshooting
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
   under an internal timeout (330 min; job limit 355 min);
4. the agent itself clones the target repo into its `.work/`, implements,
   critic-loops, commits and pushes to the target's default branch —
   authenticated via the `FACTORY_PUSH_TOKEN` git credential rewrite;
5. the job then **asserts the stage delivered**: the default branch must have
   advanced during the stage (a stage that ends on one of its own gates exits 0
   without pushing and is failed here with the agent's own stated reason in its
   log).

The model comes from the `PIPELINE_MODEL` variable (e.g.
`openrouter/anthropic/claude-sonnet-4.5`) and its provider key from the
`OPENCODE_MODEL_API_KEY` secret, exported under the env var named by
`PIPELINE_MODEL_ENVVAR` (default `OPENROUTER_API_KEY`). The agent workspaces
deliberately pin **no** model.

See [setup.md](setup.md) for the one-time manual setup and
[operations.md](operations.md) for running and troubleshooting.
