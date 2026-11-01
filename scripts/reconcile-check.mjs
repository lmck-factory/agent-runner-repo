#!/usr/bin/env node
// Reconcile a target repo against the factory's expectations: delivered
// artifacts on the default branch, Render services present and live, Actions
// wiring in place. Prints a PASS/FAIL/WARN table.
//
// Env:
//   TARGET          target repo (owner/repo)
//   RENDER_API_KEY  Render API key (service/deploy checks)
//   GITHUB_TOKEN    token for gh CLI
//   REQ_FOLDER      default docs/requirements
//   DESIGN_FOLDER   default docs/solution-design
//   REQUIRE         1 = exit non-zero on any FAIL (default 1)
import { execSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import YAML from "yaml";

const TARGET = process.env.TARGET;
const REQ = process.env.REQ_FOLDER || "docs/requirements";
const DESIGN = process.env.DESIGN_FOLDER || "docs/solution-design";
const REQUIRE = process.env.REQUIRE !== "0";
const API = "https://api.render.com/v1";

if (!TARGET) { console.error("[reconcile][error] TARGET is required"); process.exit(1); }

const gh = (args) => execSync(`gh ${args}`, { shell: "/bin/bash" }).toString().trim();
const rows = [];
const record = (name, ok, detail, warn = false) => rows.push({ name, status: ok ? "PASS" : warn ? "WARN" : "FAIL", detail });

async function rq(path) {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${process.env.RENDER_API_KEY}` } });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  return res.json();
}

// ---- target repo deliverables ----
let branch = "";
try {
  branch = gh(`api repos/${TARGET} --jq .default_branch`);
  record("repo reachable", true, `${TARGET}@${branch}`);
} catch (e) {
  record("repo reachable", false, e.message.slice(0, 120));
}

async function hasPath(p) {
  try { gh(`api "repos/${TARGET}/contents/${p}?ref=${branch}" --jq .path`); return true; }
  catch { return false; }
}

if (branch) {
  for (const [label, p, warnOnly] of [
    ["requirements delivered", `${REQ}/README.md`, false],
    ["design delivered", `${DESIGN}/README.md`, false],
    ["backend code", "app/api", false],
    ["api contract", "app/api/openapi.yaml", false],
    ["web code", "app/web", false],
    ["ci-api.yml", ".github/workflows/ci-api.yml", false],
    ["deploy-api.yml", ".github/workflows/deploy-api.yml", false],
    ["ci-web.yml", ".github/workflows/ci-web.yml", true],
    ["deploy-web.yml", ".github/workflows/deploy-web.yml", true],
    // Factory stage-status artifacts (docs/factory-contract.md): the last run
    // of each stage must have declared itself delivered.
    ["requirements status", `${REQ}/factory-status.json`, true],
    ["design status", `${DESIGN}/factory-status.json`, true],
    ["backend status", "app/api/factory-status.json", true],
    ["web status", "app/web/factory-status.json", true],
  ]) {
    record(label, await hasPath(p), p, warnOnly);
  }
}

// Read the blueprints from the TARGET's deliverables, not from this runner
// checkout: fetch a tarball of the default branch.
let ROOT = "";
if (branch) {
  try {
    const tmp = mkdtempSync(join(tmpdir(), "factory-target-"));
    execSync(
      `gh api "repos/${TARGET}/tarball/${branch}" > "${tmp}/target.tgz" && tar -xzf "${tmp}/target.tgz" -C "${tmp}" --strip-components=1`,
      { shell: "/bin/bash" }
    );
    ROOT = tmp;
    record("target checkout fetched", true, "tarball of default branch");
  } catch (e) {
    record("target checkout fetched", false, e.message.slice(0, 120));
  }
}

// ---- target repo Actions variables ----
try {
  const vars = JSON.parse(gh(`api "repos/${TARGET}/actions/variables"`));
  const names = (vars.variables || []).map((v) => v.name);
  record("RENDER_API_SERVICE_ID var", names.includes("RENDER_API_SERVICE_ID"), names.join(", ") || "(none)");
  record("RENDER_WEB_SERVICE_ID var", names.includes("RENDER_WEB_SERVICE_ID"), names.join(", ") || "(none)", true);
} catch (e) {
  record("Actions variables readable", false, e.message.slice(0, 120), true);
}

// ---- Render services live ----
if (process.env.RENDER_API_KEY) {
  try {
    const owners = await rq("/owners");
    const ownerId = owners[0]?.id;
    const svcs = await rq(`/services?ownerId=${ownerId}&limit=100`);
    const list = Array.isArray(svcs) ? svcs : svcs.items || [];

    const decls = [];
    for (const [kind, rel] of [["api", "app/api/render.yaml"], ["web", "app/web/render.yaml"]]) {
      const file = ROOT ? join(ROOT, rel) : "";
      if (file && existsSync(file)) {
        const doc = YAML.parse(readFileSync(file, "utf8"));
        for (const s of doc?.services || []) if (s?.name) decls.push({ kind, name: s.name });
      }
    }
    if (decls.length === 0) record("render.yaml decls", false, "no render.yaml found in the fetched target checkout", true);

    const normRepo = (s) => (s || "").replace(/\.git$/, "").replace(/\/$/, "").toLowerCase();
    for (const d of decls) {
      // Match by name AND repo so another target's same-named service is never
      // mistaken for this target's.
      const svc = list.find((s) => s.name === d.name && normRepo(s.repo) === normRepo(`https://github.com/${TARGET}`));
      if (!svc) { record(`render service '${d.name}'`, false, "not found in Render"); continue; }
      let live = false, detail = "no deploys";
      try {
        const dep = await rq(`/services/${svc.id}/deploys?limit=1`);
        const d0 = Array.isArray(dep) ? dep[0] : dep?.[0];
        live = d0?.status === "live";
        detail = `status=${d0?.status || "unknown"}`;
      } catch { /* keep detail */ }
      record(`render service '${d.name}' live`, live, detail);
      if (d.kind === "api") {
        try {
          const env = await rq(`/services/${svc.id}/env-vars`);
          const keys = (Array.isArray(env) ? env : []).map((e) => e.key);
          record("CORS_ALLOWED_ORIGINS set", keys.includes("CORS_ALLOWED_ORIGINS"), keys.join(", ") || "(none)", true);
          record("DATABASE_URL set", keys.includes("DATABASE_URL"), keys.join(", ") || "(none)");
        } catch (e) {
          record("api env vars readable", false, e.message.slice(0, 120), true);
        }
      }
    }
  } catch (e) {
    record("Render API reachable", false, e.message.slice(0, 120));
  }
} else {
  record("Render checks", false, "RENDER_API_KEY not set — skipped", true);
}

// ---- report ----
const width = Math.max(...rows.map((r) => r.name.length));
let failed = 0;
for (const r of rows) {
  console.log(`${r.status.padEnd(4)}  ${r.name.padEnd(width)}  ${r.detail}`);
  if (r.status === "FAIL") failed++;
}
console.log(`\n[reconcile] ${rows.length} checks, ${failed} failed`);
process.exit(failed > 0 && REQUIRE ? 1 : 0);
