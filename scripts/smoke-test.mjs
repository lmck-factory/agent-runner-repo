#!/usr/bin/env node
// Poll the deployed services until live, then verify HTTP + CORS behaviour.
//
// Env:
//   WEB_URL        web app URL (optional)
//   API_URL        API base URL (optional)
//   API_HEALTH_PATH  explicit health path (default: read healthCheckPath from
//                    the target's app/api/render.yaml when TARGET is set,
//                    else probe /actuator/health, /health, /)
//   TARGET         target repo (owner/repo) — enables the blueprint lookup
//   GH_TOKEN       token for gh CLI (blueprint lookup)
//   CORS_ORIGIN    when set with API_URL, assert the API answers this Origin
//   ATTEMPTS       default 40
//   INTERVAL_SEC   default 15
//   REQUIRE_CORS   1 = CORS mismatch fails the check (default: warn only)
const WEB_URL = (process.env.WEB_URL || "").replace(/\/$/, "");
const API_URL = (process.env.API_URL || "").replace(/\/$/, "");
const TARGET = process.env.TARGET || "";
let API_HEALTH_PATH = process.env.API_HEALTH_PATH || "";
const CORS_ORIGIN = (process.env.CORS_ORIGIN || "").replace(/\/$/, "");
const ATTEMPTS = Number(process.env.ATTEMPTS || 40);
const INTERVAL_SEC = Number(process.env.INTERVAL_SEC || 15);
const REQUIRE_CORS = process.env.REQUIRE_CORS === "1";

if (!WEB_URL && !API_URL) {
  console.error("[smoke][error] at least one of WEB_URL / API_URL is required");
  process.exit(1);
}

// Resolve the API's health path from the target's blueprint when it is not
// given explicitly, so the smoke test and the CORS probe hit the endpoint the
// API actually declares (contract: docs/factory-contract.md).
if (!API_HEALTH_PATH && API_URL && TARGET) {
  try {
    const { execSync } = await import("node:child_process");
    const YAML = (await import("yaml")).default;
    const branch = execSync(`gh api repos/${TARGET} --jq .default_branch`, { shell: "/bin/bash" }).toString().trim();
    const raw = execSync(
      `gh api -H "Accept: application/vnd.github.raw" "repos/${TARGET}/contents/app/api/render.yaml?ref=${branch}"`,
      { shell: "/bin/bash" }
    ).toString();
    const declared = (YAML.parse(raw)?.services || []).map((s) => s?.healthCheckPath).filter(Boolean);
    if (declared.length) {
      API_HEALTH_PATH = declared[0];
      console.log(`[smoke] health path from blueprint: ${API_HEALTH_PATH}`);
    }
  } catch (e) {
    console.warn(`[smoke][warn] could not read healthCheckPath from the target blueprint (${e.message.split("\n")[0]}) — probing defaults`);
  }
}
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
let hardFail = false;

async function probe(url, opts = {}) {
  try {
    const res = await fetch(url, { redirect: "follow", ...opts });
    return { ok: res.ok, status: res.status, headers: res.headers, body: await res.text().catch(() => "") };
  } catch (e) {
    return { ok: false, status: 0, error: e.message };
  }
}

async function waitWeb() {
  for (let i = 1; i <= ATTEMPTS; i++) {
    const r = await probe(WEB_URL);
    if (r.ok && /html/i.test(r.headers.get("content-type") || r.body.slice(0, 200))) {
      console.log(`[smoke] web live: ${WEB_URL} (${r.status})`);
      return true;
    }
    console.log(`[smoke] web not ready (attempt ${i}/${ATTEMPTS}, status ${r.status})`);
    await sleep(INTERVAL_SEC);
  }
  return false;
}

async function waitApi() {
  const paths = API_HEALTH_PATH ? [API_HEALTH_PATH] : ["/actuator/health", "/health", "/"];
  for (let i = 1; i <= ATTEMPTS; i++) {
    for (const p of paths) {
      const r = await probe(`${API_URL}${p}`);
      if (r.ok) {
        console.log(`[smoke] api live: ${API_URL}${p} (${r.status})`);
        return true;
      }
    }
    console.log(`[smoke] api not ready (attempt ${i}/${ATTEMPTS})`);
    await sleep(INTERVAL_SEC);
  }
  return false;
}

async function checkCors() {
  const r = await probe(`${API_URL}${API_HEALTH_PATH || "/actuator/health"}`, { headers: { Origin: CORS_ORIGIN } });
  const allow = r.headers?.get?.("access-control-allow-origin");
  if (allow === CORS_ORIGIN || allow === "*") {
    console.log(`[smoke] CORS ok: Access-Control-Allow-Origin=${allow} for origin ${CORS_ORIGIN}`);
    return true;
  }
  const msg = `[smoke] CORS MISSING: API did not return Access-Control-Allow-Origin for ${CORS_ORIGIN} (got: ${allow ?? "none"}) — the web app will be blocked in the browser; check CORS_ALLOWED_ORIGINS on the API service`;
  if (REQUIRE_CORS) { console.error(`[smoke][error] ${msg}`); hardFail = true; return false; }
  console.warn(`[smoke][warn] ${msg}`);
  return false;
}

if (WEB_URL) {
  if (!(await waitWeb())) {
    console.error(`[smoke][error] web never became live: ${WEB_URL}`);
    hardFail = true;
  }
}
if (API_URL) {
  if (!(await waitApi())) {
    console.error(`[smoke][error] api never became healthy: ${API_URL}`);
    hardFail = true;
  } else if (CORS_ORIGIN && WEB_URL) {
    await checkCors();
  }
}
process.exit(hardFail ? 1 : 0);
