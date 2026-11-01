#!/usr/bin/env node
// Provision (or reconcile) a target repo's Render resources from its
// render.yaml files, wire environment variables, sync the target repo's
// GitHub Actions secrets/variables, and optionally trigger deploys.
//
// Env:
//   RENDER_API_KEY     Render API key (Bearer)
//   TARGET             target repo (owner/repo)
//   TARGET_CLONE       path to a clone of the target repo (default .)
//   STAGE              api | web | both   (which render.yaml files to process)
//   GITHUB_TOKEN       token for gh CLI (repo vars/secrets on the target)
//   OWNER_ID           optional Render owner id (default: first owner)
//   CORS_ORIGIN        optional web origin to allow on the API service
//   API_URL            optional API base URL — wires the web service's API
//                      base URL env var even when the api blueprint is not
//                      processed in this run (bootstrap-web)
//   TRIGGER_DEPLOY     1 to POST a deploy for each affected service (default 0)
//   RENDER_PG_PLAN     postgres plan (default starter-512mb)
//   GITHUB_OUTPUT      appended with api_url/web_url/service ids
//
// Multi-target safety: services are matched by name *and* repo (two targets
// never share a service); managed Postgres instances are named with a
// target-derived prefix so their names never collide either.
import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import YAML from "yaml";
import { validateBlueprint } from "./validate-blueprint.mjs";

const API = "https://api.render.com/v1";
const key = process.env.RENDER_API_KEY;
const TARGET = process.env.TARGET;
const CLONE = process.env.TARGET_CLONE || ".";
const STAGE = process.env.STAGE || "both";
const OWNER_ID = process.env.OWNER_ID || "";
const CORS_ORIGIN = process.env.CORS_ORIGIN || "";
const API_URL = (process.env.API_URL || "").replace(/\/$/, "");
const TRIGGER = process.env.TRIGGER_DEPLOY === "1";
const PG_PLAN = process.env.RENDER_PG_PLAN || "starter-512mb";

if (!key) fail("RENDER_API_KEY is required");
if (!TARGET) fail("TARGET (owner/repo) is required");

function fail(msg) {
  console.error(`[render-bootstrap][error] ${msg}`);
  process.exit(1);
}
function log(msg) {
  console.error(`[render-bootstrap] ${msg}`);
}
function out(keyName, value) {
  const line = `${keyName}=${value}`;
  console.log(line);
  if (process.env.GITHUB_OUTPUT) {
    execSync(`printf '%s\\n' "${line.replace(/"/g, '\\"')}" >> "$GITHUB_OUTPUT"`, { shell: "/bin/bash" });
  }
}

async function rq(method, path, body, { fatal = true } = {}) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    if (!fatal) return null;
    fail(`${method} ${path} -> ${res.status}: ${text.slice(0, 600)}`);
  }
  return text ? JSON.parse(text) : null;
}

function readBlueprint(rel) {
  const p = `${CLONE}/${rel}`;
  if (!existsSync(p)) return null;
  const doc = YAML.parse(readFileSync(p, "utf8"));
  return { path: rel, doc };
}

function serviceUrl(svc) {
  return (
    svc?.serviceDetails?.url ||
    svc?.staticSiteDetails?.url ||
    svc?.url ||
    (svc?.slug ? `https://${svc.slug}.onrender.com` : "")
  );
}

function declaredEnvKeys(decl) {
  return (decl.envVars || []).map((e) => e?.key).filter(Boolean);
}

const normRepo = (s) => (s || "").replace(/\.git$/, "").replace(/\/$/, "").toLowerCase();
const TARGET_HTTP = `https://github.com/${TARGET}`;
// Services belong to a repo: only ever match services of THIS target.
const sameRepo = (svc) => normRepo(svc?.repo) === normRepo(TARGET_HTTP);

// Target-scoped name prefix for managed databases (Postgres names must be
// unique per owner, and two targets may declare the same database name).
const PG_SLUG = `${TARGET}`.replace(/\//g, "-").replace(/[^a-zA-Z0-9-]/g, "-").toLowerCase().slice(0, 40);

// Build the Render create payload from a render.yaml service declaration.
function createPayload(decl, ownerId, branch) {
  const typeMap = { web_service: "web_service", static_site: "static_site", background_worker: "background_worker", cron_job: "cron_job" };
  const type = typeMap[decl.type] || (decl.runtime === "docker" ? "web_service" : decl.type);
  const base = {
    type,
    name: decl.name,
    ownerId,
    repo: TARGET_HTTP,
    branch,
    autoDeploy: "no", // deploys are triggered by this bootstrap and by the target's CI
  };
  if (decl.rootDir) base.rootDir = decl.rootDir;
  if (type === "static_site") {
    base.serviceDetails = {
      buildCommand: decl.buildCommand,
      publishPath: decl.staticPublishPath || decl.publishPath || "dist",
      pullRequestPreviewsEnabled: false,
    };
  } else {
    const details = { healthCheckPath: decl.healthCheckPath || undefined };
    if (decl.runtime) details.runtime = decl.runtime;
    if (decl.dockerfilePath) details.dockerfilePath = decl.dockerfilePath;
    if (decl.dockerContext) details.dockerContext = decl.dockerContext;
    base.serviceDetails = details;
  }
  // Non-secret env vars declared in the blueprint can go straight in.
  const envVars = (decl.envVars || [])
    .filter((e) => e && e.key && e.sync === false && !e.fromService && e.value !== undefined)
    .map((e) => ({ key: e.key, value: String(e.value) }));
  if (envVars.length) base.envVars = envVars;
  return base;
}

// Managed Postgres: find connection details on a postgres object however the
// API nests them (schema has moved between shapes).
function findConnection(pg) {
  const seen = new Set();
  let host, port, database, username, password;
  (function walk(node, depth) {
    if (!node || typeof node !== "object" || depth > 6 || seen.has(node)) return;
    seen.add(node);
    if (node.host && node.password && !host) {
      host = node.host; port = node.port || 5432;
      database = node.database || node.dbName || database;
      username = node.username || node.user || username;
      password = node.password;
    }
    for (const v of Object.values(node)) {
      if (v && typeof v === "object") walk(v, depth + 1);
    }
  })(pg, 0);
  if (!host || !password) return null;
  return `postgres://${encodeURIComponent(username || "postgres")}:${encodeURIComponent(password)}@${host}:${port}/${database || "postgres"}`;
}

// ---- main ----

const owners = await rq("GET", "/owners");
const ownerId = OWNER_ID || owners?.[0]?.id;
if (!ownerId) fail("no Render owner found for this API key (set OWNER_ID?)");

const branch = execSync(`gh api repos/${TARGET} --jq .default_branch`, { shell: "/bin/bash" }).toString().trim();
log(`target=${TARGET} branch=${branch} owner=${ownerId}`);

// The managed-database endpoint moved between API generations; probe both.
let PG_BASE = "/postgres";
for (const p of ["/postgres", "/postgres-details"]) {
  if (await rq("GET", `${p}?ownerId=${ownerId}&limit=1`, undefined, { fatal: false })) {
    PG_BASE = p;
    break;
  }
}
log(`managed postgres endpoint: ${PG_BASE}`);

let allServices = [];
for (let page = 1; ; page++) {
  const batch = await rq("GET", `/services?ownerId=${ownerId}&limit=100&page=${page}`);
  const arr = Array.isArray(batch) ? batch : batch?.items || [];
  allServices = allServices.concat(arr);
  if (arr.length < 100) break;
}
const allPgRaw = (await rq("GET", `${PG_BASE}?ownerId=${ownerId}&limit=100`)) || [];
const pgList = Array.isArray(allPgRaw) ? allPgRaw : allPgRaw.items || [];

const blueprints = [];
if (STAGE === "api" || STAGE === "both") {
  const bp = readBlueprint("app/api/render.yaml");
  if (bp) blueprints.push({ kind: "api", ...bp });
}
if (STAGE === "web" || STAGE === "both") {
  const bp = readBlueprint("app/web/render.yaml");
  if (bp) blueprints.push({ kind: "web", ...bp });
}
if (blueprints.length === 0) fail(`no render.yaml found for STAGE=${STAGE} (looked in app/api/, app/web/ of ${CLONE})`);

// Fail fast (with readable errors) before touching the Render API.
for (const bp of blueprints) {
  const { errors, warnings } = validateBlueprint(bp.doc, bp.kind);
  for (const w of warnings) log(`warning: ${bp.path}: ${w}`);
  if (errors.length) {
    fail(`${bp.path} does not satisfy the factory contract:\n  - ${errors.join("\n  - ")}\nsee docs/factory-contract.md`);
  }
}

const results = { api: null, web: null };
let apiDatabaseUrl = null;

// Pass 1: provision services + databases (api first so web can wire its URL).
blueprints.sort((a, b) => (a.kind === "api" ? -1 : 1)).forEach((bp) => {
  // remember for pass 2
  bp._services = (bp.doc.services || []).filter((s) => s && s.name);
  bp._databases = (bp.doc.databases || []).filter((d) => d && d.name);
});

for (const bp of blueprints) {
  // Managed databases declared by this blueprint (target-scoped names).
  for (const decl of bp._databases) {
    const pgName = `${PG_SLUG}-${decl.name}`.slice(0, 60);
    let pg = pgList.find((p) => p.name === pgName);
    if (!pg) {
      log(`creating postgres '${pgName}' (plan ${decl.plan || PG_PLAN})`);
      pg = await rq("POST", PG_BASE, {
        ownerId,
        name: pgName,
        databaseName: decl.databaseName || decl.name.replace(/-/g, "_"),
        user: decl.user || "app",
        plan: decl.plan || PG_PLAN,
        ...(decl.version ? { version: decl.version } : {}),
      });
      pgList.push(pg);
    } else {
      log(`postgres '${pgName}' already exists (${pg.id})`);
    }
    const url = findConnection(pg);
    if (url) {
      apiDatabaseUrl = url;
      log(`postgres '${pgName}' connection resolved`);
    } else {
      log(`warning: could not extract connection details for '${pgName}' — set DATABASE_URL manually`);
    }
  }

  for (const decl of bp._services) {
    let svc = allServices.find((s) => sameRepo(s) && s.name === decl.name);
    if (!svc) {
      log(`creating ${decl.type || "web_service"} '${decl.name}'`);
      try {
        svc = await rq("POST", "/services", createPayload(decl, ownerId, branch));
      } catch (e) {
        fail(`failed to create service '${decl.name}': ${e.message}\n` +
             `hint: inspect the payload against the Render API servicePOST schema; ` +
             `docker web services may need runtime-specific serviceDetails fields`);
      }
      allServices.push(svc);
    } else {
      log(`service '${decl.name}' already exists (${svc.id})`);
    }

    // Env var upsert (PUT replaces the whole set -> read, merge, write).
    const current = (await rq("GET", `/services/${svc.id}/env-vars`)) || [];
    const currentPairs = current.map((e) => ({ key: e.key, value: String(e.value ?? "") }));
    const map = new Map(currentPairs.map((e) => [e.key, e.value]));
    const declared = declaredEnvKeys(decl);

    if (bp.kind === "api" && apiDatabaseUrl && declared.includes("DATABASE_URL")) {
      map.set("DATABASE_URL", apiDatabaseUrl);
    }
    if (bp.kind === "api" && CORS_ORIGIN && declared.includes("CORS_ALLOWED_ORIGINS")) {
      map.set("CORS_ALLOWED_ORIGINS", CORS_ORIGIN);
    }
    if (bp.kind === "web") {
      const apiUrl = results.api ? serviceUrl(results.api) : API_URL;
      if (apiUrl) {
        for (const k of ["VITE_API_BASE_URL", "NEXT_PUBLIC_API_BASE_URL"]) {
          if (declared.length === 0 || declared.includes(k)) map.set(k, apiUrl);
        }
      } else {
        // Last resort: the API service may already exist in Render even though
        // its blueprint is not processed in this run (start_from=bootstrap-web).
        const apiBp = readBlueprint("app/api/render.yaml");
        for (const s of apiBp?.doc?.services || []) {
          const apiSvc = allServices.find((x) => sameRepo(x) && x.name === s.name);
          if (apiSvc && serviceUrl(apiSvc)) {
            for (const k of ["VITE_API_BASE_URL", "NEXT_PUBLIC_API_BASE_URL"]) {
              if (declared.length === 0 || declared.includes(k)) map.set(k, serviceUrl(apiSvc));
            }
            break;
          }
        }
      }
    }
    // Blueprint-declared sync:false values without provider wiring carry through.
    for (const e of decl.envVars || []) {
      if (e && e.key && e.sync === false && e.value !== undefined && !map.has(e.key)) {
        map.set(e.key, String(e.value));
      }
    }
    const nextPairs = [...map.entries()].map(([keyName, value]) => ({ key: keyName, value: String(value) }));
    if (JSON.stringify(nextPairs) !== JSON.stringify(currentPairs)) {
      await rq("PUT", `/services/${svc.id}/env-vars`, { replace: false, vars: nextPairs });
      log(`env vars upserted for '${decl.name}': ${nextPairs.map((e) => e.key).join(", ")}`);
    }

    if (TRIGGER) {
      log(`triggering deploy for '${decl.name}'`);
      await rq("POST", `/services/${svc.id}/deploys`, {});
    }

    results[bp.kind] = svc;
  }
}

// ---- sync target repo Actions secrets + variables via gh ----
if (process.env.GITHUB_TOKEN) {
  const gh = (args) => execSync(`gh ${args}`, { shell: "/bin/bash", stdio: ["ignore", "inherit", "inherit"] });
  if (results.api) {
    gh(`variable set RENDER_API_SERVICE_ID --body "${results.api.id}" -R ${TARGET}`);
  }
  if (results.web) {
    gh(`variable set RENDER_WEB_SERVICE_ID --body "${results.web.id}" -R ${TARGET}`);
  }
  // The shared Render API key lets the target's deploy workflows call the API.
  execSync(
    `printf '%s' "$RENDER_API_KEY" | gh secret set RENDER_API_KEY --body "$(cat)" -R ${TARGET}`,
    { shell: "/bin/bash", stdio: ["ignore", "inherit", "inherit"], env: process.env }
  );
  log("target repo Actions secrets/variables synced");
} else {
  log("warning: GITHUB_TOKEN not set — skipped syncing target repo secrets/variables");
}

if (results.api) {
  out("api_service_id", results.api.id);
  out("api_url", serviceUrl(results.api));
}
if (results.web) {
  out("web_service_id", results.web.id);
  out("web_url", serviceUrl(results.web));
}
log("done");
