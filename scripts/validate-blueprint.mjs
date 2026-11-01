#!/usr/bin/env node
// Validate a target repo's render.yaml blueprint / openapi.yaml contract
// against the factory contract (docs/factory-contract.md).
//
// Used by:
//   - gate-check.sh (web gate: validates the backend stage's render.yaml +
//     openapi.yaml before the web stage and the Render bootstrap run)
//   - the backend/web agent jobs (validate their own deliverable right after
//     the stage, so a contract violation fails the responsible stage)
//   - render-bootstrap.mjs (fail fast with a readable error before calling the
//     Render API)
//
// CLI:
//   node validate-blueprint.mjs --kind api|web|openapi --file <path|-> 
// Exit 0 when valid (warnings allowed), 1 when invalid.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import YAML from "yaml";

const SERVICE_TYPES = new Set(["web_service", "static_site", "background_worker", "cron_job"]);
const API_DIR = "app/api";
const WEB_DIR = "app/web";

function envKeys(svc) {
  return (svc?.envVars || []).map((e) => e?.key).filter(Boolean);
}

// The factory bootstrap passes rootDir to Render; a blueprint that leaves the
// repo root as the build root breaks the Docker build (the Dockerfile lives
// inside the code folder). Accept an explicit dockerfilePath under the code
// folder as an equivalent declaration.
function checkRoot(svc, dir, errors) {
  const docker = svc?.dockerfilePath || "";
  if (!svc?.rootDir && !docker) {
    errors.push(`'${svc?.name}' must set 'rootDir: ${dir}' (or an explicit dockerfilePath under ${dir}/) — the factory bootstrap passes rootDir to Render`);
  } else if (svc.rootDir && svc.rootDir !== dir) {
    errors.push(`'${svc.name}' declares rootDir '${svc.rootDir}' — expected '${dir}'`);
  } else if (!svc.rootDir && docker && !docker.startsWith(`${dir}/`)) {
    errors.push(`'${svc.name}' dockerfilePath '${docker}' is outside ${dir}/ — expected it under ${dir}/`);
  }
}

// Validate a render.yaml document for one factory stage.
// kind: "api" (backend blueprint) | "web" (web blueprint)
export function validateBlueprint(doc, kind) {
  const errors = [];
  const warnings = [];
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    errors.push("not a YAML mapping");
    return { errors, warnings };
  }
  const services = Array.isArray(doc.services) ? doc.services.filter((s) => s && s.name) : [];
  const databases = Array.isArray(doc.databases) ? doc.databases.filter((d) => d && d.name) : [];
  if (services.length === 0) errors.push("no services declared (a factory blueprint declares at least one)");

  for (const s of services) {
    if (!SERVICE_TYPES.has(s.type)) {
      errors.push(`service '${s.name}' has unsupported type '${s.type}' (expected one of: ${[...SERVICE_TYPES].join(", ")})`);
    }
  }

  if (kind === "api") {
    const svc = services.find((s) => s.type === "web_service");
    if (!svc) {
      errors.push("api blueprint must declare a web_service");
    } else {
      checkRoot(svc, API_DIR, errors);
      const keys = envKeys(svc);
      for (const k of ["DATABASE_URL", "CORS_ALLOWED_ORIGINS"]) {
        if (!keys.includes(k)) {
          errors.push(`web_service '${svc.name}' must declare env key '${k}' (sync: false) — the factory bootstrap wires it`);
        }
      }
      if (!svc.healthCheckPath) {
        warnings.push(`web_service '${svc.name}' declares no healthCheckPath (smoke tests then default to /actuator/health)`);
      }
    }
    if (databases.length === 0) {
      errors.push("api blueprint must declare a managed database under 'databases:' so the bootstrap provisions Postgres and wires DATABASE_URL");
    }
  } else if (kind === "web") {
    for (const s of services) {
      const keys = envKeys(s);
      if (s.type === "static_site") {
        if (s.rootDir && s.rootDir !== WEB_DIR) {
          errors.push(`static_site '${s.name}' declares rootDir '${s.rootDir}' — expected '${WEB_DIR}'`);
        }
        if (!keys.includes("VITE_API_BASE_URL")) {
          errors.push(`static_site '${s.name}' must declare env key 'VITE_API_BASE_URL' (sync: false) — the factory bootstrap wires the API base URL into it`);
        }
        if (!s.buildCommand) {
          warnings.push(`static_site '${s.name}' declares no buildCommand (Render's default may not match the app)`);
        }
      } else if (s.type === "web_service") {
        // Container-deployed web app (Next.js).
        checkRoot(s, WEB_DIR, errors);
        if (!keys.includes("NEXT_PUBLIC_API_BASE_URL")) {
          errors.push(`web_service '${s.name}' must declare env key 'NEXT_PUBLIC_API_BASE_URL' (sync: false) — the factory bootstrap wires the API base URL into it`);
        }
      }
    }
  }
  return { errors, warnings };
}

// Validate the canonical API contract the web stage builds its client from.
export function validateOpenApi(doc) {
  const errors = [];
  const warnings = [];
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    errors.push("not a YAML mapping");
    return { errors, warnings };
  }
  if (!doc.openapi) errors.push("missing 'openapi' version field");
  if (!doc.info?.title) errors.push("missing info.title");
  if (!doc.info?.version) errors.push("missing info.version");
  const paths = doc.paths && typeof doc.paths === "object" ? doc.paths : null;
  if (!paths || Object.keys(paths).length === 0) {
    errors.push("no paths declared — the contract is empty");
    return { errors, warnings };
  }
  const METHODS = ["get", "put", "post", "delete", "patch", "head", "options", "trace"];
  let ops = 0;
  for (const [p, item] of Object.entries(paths)) {
    for (const m of METHODS) {
      if (!item?.[m]) continue;
      ops++;
      if (!item[m].operationId) {
        warnings.push(`${m.toUpperCase()} ${p} has no operationId (the web stage's typed client is generated from these)`);
      }
    }
  }
  if (ops === 0) errors.push("no operations declared under paths");
  return { errors, warnings };
}

function cli() {
  const args = process.argv.slice(2);
  let kind = "";
  let file = "";
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--kind") kind = args[++i] || "";
    else if (args[i] === "--file") file = args[++i] || "";
  }
  if (!kind || !["api", "web", "openapi"].includes(kind)) {
    console.error("[validate][error] usage: validate-blueprint.mjs --kind api|web|openapi --file <path|->");
    process.exit(2);
  }
  if (!file) {
    console.error("[validate][error] --file is required (use '-' for stdin)");
    process.exit(2);
  }
  const raw = file === "-" ? readFileSync(0, "utf8") : readFileSync(file, "utf8");
  let doc;
  try {
    doc = YAML.parse(raw);
  } catch (e) {
    console.error(`[validate][error] ${kind === "openapi" ? "openapi.yaml" : "render.yaml"} is not valid YAML: ${e.message}`);
    process.exit(1);
  }
  const { errors, warnings } = kind === "openapi" ? validateOpenApi(doc) : validateBlueprint(doc, kind);
  for (const w of warnings) console.warn(`[validate][warn] ${w}`);
  if (errors.length) {
    for (const e of errors) console.error(`[validate][error] ${e}`);
    console.error(`[validate] ${kind} document INVALID (${errors.length} error(s), ${warnings.length} warning(s))`);
    process.exit(1);
  }
  console.log(`[validate] ${kind} document OK (${warnings.length} warning(s))`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  cli();
}
