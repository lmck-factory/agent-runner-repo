# Factory contract (v1)

The machine-verifiable contract between the four agent workspaces and the
orchestrator. Everything here is **enforced** by the pipeline — by
`gate-check.sh` before each stage, by the per-stage "assert delivered" steps,
by `validate-blueprint.mjs`, and by `render-bootstrap.mjs` / `smoke-test.mjs` /
`reconcile-check.mjs` at deploy time. A stage that violates it fails **at the
responsible stage**, not downstream with a confusing error.

The copies in `backend-developer/factory-contract.md` and
`web-developer/factory-contract.md` are published into the agent workspace
repos; this file in `agent-runner-repo/docs/` is canonical — keep them in sync
(re-publish the workspaces after editing them).

## 1. Deliverable layout and ownership

| Path | Owner stage | Rule |
| --- | --- | --- |
| `docs/requirements/**` | requirements (product-manager) | only writer |
| `docs/solution-design/**` | design (solution-architect) | only writer |
| `app/api/**` | backend (backend-developer) | only writer |
| `app/web/**` | web (web-developer) | only writer |
| `.github/workflows/ci-api.yml`, `deploy-api.yml` | backend | only these two under `.github/workflows/` |
| `.github/workflows/ci-web.yml`, `deploy-web.yml` | web | only these two under `.github/workflows/` |
| `docs/concept/**`, `docs/concept.md` | (human) | read-only for every stage |

Every stage commits **only** inside its owned paths, and every delivered stage
ends with the default branch **advanced** (the pipeline asserts this).

## 2. Stage status artifact — `factory-status.json`

Every agent stage commits a status file **inside its own deliverable folder**
as part of the delivered commit:

| Stage | Status file |
| --- | --- |
| requirements | `docs/requirements/factory-status.json` |
| design | `docs/solution-design/factory-status.json` |
| backend | `app/api/factory-status.json` |
| web | `app/web/factory-status.json` |

Schema (v1):

```json
{
  "contract_version": 1,
  "stage": "backend",
  "status": "delivered",
  "commit": "<full sha of the delivered commit when known, else empty>",
  "generated_at": "<ISO 8601 UTC>",
  "deliverables": ["app/api", "app/api/openapi.yaml", "app/api/render.yaml",
                   ".github/workflows/ci-api.yml", ".github/workflows/deploy-api.yml"],
  "change_set": null,
  "critic": { "verdict": "SATISFIED", "iterations": 3, "unresolved_findings": 0 },
  "assumptions_logged": 12,
  "notes": "optional free text (e.g. draft-requirement reliance, deviations)"
}
```

Rules:

- `stage` is the factory stage id: `requirements` | `design` | `backend` | `web`.
- `status` is `delivered` **only when the stage actually pushed its
  deliverables**. A stage that ends on one of its own gates (no design, no
  requirements, …) commits **nothing** — no status file, no deliverables — and
  the pipeline marks the run failed at that stage with the agent's own stated
  reason in its log.
- `critic.unresolved_findings` must be `0` for `status: "delivered"`; findings
  the critic cap leaves open are logged in the stage README's "Unresolved
  critic findings" and reduce the run's quality score, but do not block.
- `deliverables` lists the paths the stage pushed; the reconcile check warns
  when a listed path is missing on the branch.

## 3. `render.yaml` (the deploy blueprint the bootstrap consumes)

The bootstrap (`render-bootstrap.mjs`) provisions Render resources **only**
from `app/api/render.yaml` and `app/web/render.yaml`, validated by
`validate-blueprint.mjs --kind api|web`.

### API blueprint (`app/api/render.yaml`)

- Declares exactly one `web_service` with:
  - `rootDir: app/api` (or an explicit `dockerfilePath` under `app/api/`);
  - `healthCheckPath` (convention: `/actuator/health`, publicly reachable,
    unauthenticated);
  - `envVars` declaring, with `sync: false`:
    - `DATABASE_URL` — wired by the bootstrap from the managed database;
    - `CORS_ALLOWED_ORIGINS` — wired by the bootstrap to the deployed web
      origin after the web service exists (the API must read it at runtime and
      redeploy to take effect; the bootstrap triggers that redeploy).
- Declares at least one managed database under `databases:` (the bootstrap
  provisions it and wires `DATABASE_URL`; the instance is named
  `<target-slug>-<declared name>` so targets never collide).
- The service is matched back to this target by **repo + name**: keep the name
  stable across runs.

### Web blueprint (`app/web/render.yaml`)

- `static_site` (Vite SPA — the default):
  - `rootDir: app/web` when set;
  - a `buildCommand` matching the app;
  - `envVars` declaring `VITE_API_BASE_URL` with `sync: false` — wired by the
    bootstrap to the API service URL before the first deploy (build-time env).
- `web_service` (Next.js, container-deployed): same as the API service rules
  (`rootDir: app/web`, Dockerfile under `app/web/`), and declares
  `NEXT_PUBLIC_API_BASE_URL` with `sync: false`.

Never hard-code secrets in `render.yaml` — env references only.

## 4. `app/api/openapi.yaml` — the canonical API contract

- Valid OpenAPI 3.x: `openapi`, `info.title`, `info.version`, non-empty `paths`.
- Every operation carries an `operationId` (the web stage's typed client is
  generated from them).
- It **matches the controllers** — verified by `api-critic` during the backend
  stage and structurally re-validated by the web stage's gate. The web stage
  builds its typed client from this file; it is a hard gate, not a fallback.

## 5. Deploy workflows (stage-owned)

- `ci-api.yml` carries a `workflow_call` trigger; `deploy-api.yml` is
  push-scoped to `app/api/**` and `needs:`-gated on the CI logic reused in the
  same run; same pattern for `ci-web.yml` / `deploy-web.yml` with `app/web/**`.
- **Graceful first run:** on the very first factory run the Render services,
  `RENDER_API_KEY` secret and `RENDER_*_SERVICE_ID` variables do not exist yet
  when the stage pushes its workflows (the bootstrap syncs them afterwards).
  Both deploy workflows must therefore **no-op instead of failing** when the
  wiring is absent, e.g.:

  ```yaml
  jobs:
    deploy:
      if: ${{ vars.RENDER_API_SERVICE_ID != '' }}   # RENDER_WEB_SERVICE_ID for web
      ...
  ```

- Deploys fire two ways on purpose (accepted race, idempotent on Render): the
  pipeline's bootstrap `POST /v1/services/{id}/deploys`, and the push-triggered
  deploy workflow. Render-side autoDeploy stays `no`.

## 6. Runtime expectations the verify steps rely on

- The API answers `GET <healthCheckPath>` with 2xx when up, without auth.
- The API honours `CORS_ALLOWED_ORIGINS` and returns
  `Access-Control-Allow-Origin: <web origin>` (asserted live by `verify-live`).
- The web app reads its API base URL from `VITE_API_BASE_URL` /
  `NEXT_PUBLIC_API_BASE_URL` (never hard-coded).
- Folder names are exactly `docs/requirements`, `docs/solution-design`,
  `app/api`, `app/web` (the orchestrator's `REQ_FOLDER`/`DESIGN_FOLDER`
  inputs may override the first two; agents receive them in the prompt).
