#!/usr/bin/env node
// Drift detection: has a target's concept material changed since the last
// processed run? State lives in state/drift.json committed back to this repo
// by the scheduled workflow.
//
// Env:
//   TARGET         target repo (owner/repo)
//   GITHUB_TOKEN   token for gh CLI
//   STATE_FILE     path to drift state JSON (default state/drift.json)
//   GITHUB_OUTPUT  receives changed=true|false and digest
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const TARGET = process.env.TARGET;
const STATE_FILE = process.env.STATE_FILE || "state/drift.json";
if (!TARGET) { console.error("[drift][error] TARGET is required"); process.exit(1); }

const gh = (args) => execSync(`gh ${args}`, { shell: "/bin/bash" }).toString().trim();

// Latest commit touching each concept location; digest = concatenated SHAs.
const conceptPaths = ["docs/concept", "docs/concept.md", "concept", "concept.md"];
const branch = gh(`api repos/${TARGET} --jq .default_branch`);
const parts = [];
for (const p of conceptPaths) {
  try {
    const sha = gh(`api "repos/${TARGET}/commits?path=${p}&sha=${branch}&per_page=1" --jq '.[0].sha'`);
    if (sha) parts.push(`${p}:${sha}`);
  } catch { /* path absent */ }
}
const digest = parts.join("|");

const state = existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : {};
const prev = state[TARGET] || {};
const changed = !digest ? false : prev.digest !== digest;

console.log(`[drift] ${TARGET}@${branch}`);
console.log(`[drift] previous: ${prev.digest || "<none>"} (at ${prev.run_at || "never"})`);
console.log(`[drift] current:  ${digest || "<no concept material found>"}`);
console.log(`[drift] changed:  ${changed}`);

state[TARGET] = { digest, run_at: new Date().toISOString(), branch };
mkdirSync(dirname(STATE_FILE), { recursive: true });
writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n");

// Optional machine-readable result for workflow loops.
if (process.env.RESULT_FILE) {
  mkdirSync(dirname(process.env.RESULT_FILE), { recursive: true });
  writeFileSync(process.env.RESULT_FILE, JSON.stringify({ target: TARGET, changed, digest }) + "\n");
}

if (process.env.GITHUB_OUTPUT) {
  execSync(`printf '%s\\n' 'changed=${changed}' 'digest=${digest}' >> "$GITHUB_OUTPUT"`, { shell: "/bin/bash" });
}
