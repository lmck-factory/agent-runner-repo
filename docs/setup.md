# One-time setup

Everything below is manual (needs credentials a fresh machine won't have);
everything after is automated by the pipeline.

## 1. Publish the four agent workspaces

The pipeline clones each stage's workspace from GitHub at runtime. Until they
are pushed, no stage can run. From `lmck-factory/` (needs `gh` authenticated
against the `lmck-factory` org), for each of `product-manager`,
`solution-architect`, `backend-developer`, `web-developer`:

```
ws=product-manager   # repeat for the other three
gh repo create "lmck-factory/$ws" --private --description "Factory stage workspace: $ws"
tmp=$(mktemp -d)
tar -C "$ws" --exclude='.work' --exclude='node_modules' --exclude='.git' -cf - . | tar -C "$tmp" -xf -
cd "$tmp" && git init -q -b main && git add -A
git -c user.name=factory-setup -c user.email=factory-setup@users.noreply.github.com \
  commit -q -m "chore: publish $ws workspace"
git push -q "https://github.com/lmck-factory/$ws.git" main --force
cd - && rm -rf "$tmp"
```

Re-run whenever the local workspaces change — the pipeline always uses the
pushed state.

## 2. This repo's secrets

| Secret | Meaning |
| --- | --- |
| `FACTORY_PUSH_TOKEN` | Fine-grained PAT (or classic `repo` PAT) with **Contents: read/write** on the agent repos **and all target repos**. Used to clone private agent repos and authenticate the agents' own target clones/pushes. |
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

## 4. Prepare a target repo

A target repo needs the **concept material** the product manager reads:
`docs/concept/` (a folder of documents) or `docs/concept.md`. Check with:

```
gh api "repos/<owner>/repo/contents/docs/concept?ref=<default-branch>" --jq .path
```

Then add it to `TARGET_REPOS` and dispatch **factory-pipeline**.

What the agents deliver into the target is specified in
[factory-contract.md](factory-contract.md): the folder layout, the per-stage
`factory-status.json` artifacts, and the `render.yaml`/`openapi.yaml` shapes.

## 5. Verify

- `gh workflow list` shows `factory-pipeline` and (in runs) the per-target
  `target-pipeline`.
- Dispatch `factory-pipeline` → it plans a matrix over every repo in
  `TARGET_REPOS`, one `target-pipeline` chain per repo.
