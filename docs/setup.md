# One-time setup

Everything below is manual (needs credentials a fresh machine won't have);
everything after is automated by the pipeline.

## 1. Publish the four agent workspaces

The pipeline clones each stage's workspace from GitHub at runtime. Until they
are pushed, no stage can run. From `lmck-factory/` (needs `gh` authenticated
against the `lmck-factory` org):

```
cd agent-runner-repo
scripts/publish-agent-repos.sh lmck-factory private
```

This creates and pushes `product-manager`, `solution-architect`,
`backend-developer`, `web-developer` (excluding `.work/`, `node_modules/`,
local git metadata). Re-run it whenever the local workspaces change — the
pipeline always uses the pushed state.

## 2. This repo's secrets

| Secret | Meaning |
| --- | --- |
| `FACTORY_PUSH_TOKEN` | Fine-grained PAT (or classic `repo` PAT) with, on the agent repos **and all target repos**: **Contents: read/write**, **Secrets: write**, **Variables: write** (the bootstrap syncs `RENDER_API_KEY` + `RENDER_*_SERVICE_ID` into each target), and **Actions: read**. Used to clone private agent repos, authenticate the agents' own target clones/pushes, and sync secrets/vars into target repos. |
| `RENDER_API_KEY` | Render account API key (Dashboard → Account Settings → API keys). Used for service/Postgres provisioning, env wiring and deploy triggers. |
| `OPENCODE_MODEL_API_KEY` | API key for the model provider named by `PIPELINE_MODEL` (e.g. an OpenRouter key). Exported to the agent run as the provider expects. |

## 3. This repo's variables

| Variable | Example | Meaning |
| --- | --- | --- |
| `TARGET_REPOS` | `["lmck-factory/demo-shop"]` | JSON array of target repos the pipeline runs against. |
| `PIPELINE_MODEL` | `openrouter/anthropic/claude-sonnet-4.5` | Model passed to `opencode run -m`. |
| `PIPELINE_MODEL_ENVVAR` | `OPENROUTER_API_KEY` | (optional) Provider key env var name; defaults to `OPENROUTER_API_KEY`. |
| `OPENCODE_VERSION` | `1.x` | (optional) Pin the `opencode-ai` npm version; defaults to `latest`. |

No model is pinned inside the agent workspaces on purpose — the pipeline owns
model selection so one variable upgrades the whole factory.

## 4. Render account

- Create an API key (step 2) in the Render dashboard.
- The bootstrap picks the first owner returned by `GET /v1/owners`; with
  multiple workspaces/teams, set `OWNER_ID` in the target-pipeline env to the
  right owner (`GET /v1/owners` lists them).
- Postgres plan defaults to `starter-512mb` (override with `RENDER_PG_PLAN`
  in the target-pipeline env). Note the plan Render offers your account.

## 5. Prepare a target repo

A target repo needs the **concept material** the product manager reads:
`docs/concept/` (a folder of documents) or `docs/concept.md`. Validate with:

```
scripts/bootstrap-target.sh lmck-factory/demo-shop
```

Then add it to `TARGET_REPOS` and dispatch **factory-pipeline**.

What the agents deliver into the target (and what the pipeline gates on) is
specified in [factory-contract.md](factory-contract.md): the folder layout, the
per-stage `factory-status.json` artifacts, the `render.yaml`/`openapi.yaml`
shapes the Render bootstrap consumes, and the env vars the deploy wiring
provisions.

## 6. Verify

- `gh workflow list` shows `factory-pipeline` and (in runs) the per-target
  `target-pipeline`.
- Dispatch `factory-pipeline` with an empty `target` → it plans a matrix over
  every repo in `TARGET_REPOS`.
