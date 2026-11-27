# Operations

## Running the factory

Actions → `factory-pipeline` → *Run workflow*, or:

```
gh workflow run factory-pipeline.yml
```

The run plans one `target-pipeline` chain per repo in `vars.TARGET_REPOS`
(isolated — one failing target does not affect the others):

```
requirements (product-manager) -> design (solution-architect)
-> backend (backend-developer) -> web (web-developer)
```

There are no inputs: every run covers every configured target, from the top.
To change the target set, edit the `TARGET_REPOS` repository variable.

## Stage timeouts

Agent stages run with an internal 330-minute `timeout` inside a 355-minute job
— the gap lets the job still print the timeout error after an internal timeout.

Each stage is also **stall-guarded**: its streamed output is tee'd to a log a
watchdog watches, and `STALL_MIN` minutes without any output (default 40 — a
hung subagent or provider stream produces nothing at all) aborts the stage
with exit 137 and a `stage <X> stalled` error instead of silently burning the
rest of the budget. A healthy critic iteration has been observed silent for
~30 minutes; raise `STALL_MIN` in the job env if a legitimate phase stays
quiet longer.

OpenCode itself is pinned by the workflow's `OPENCODE_VERSION` default
(currently `1.19.5`). `latest` resolved to 1.19.6 on 2026-11-17 and every
330-minute timeout since has coincided with it (suspected subagent-hang
regression). Bump the pin only after a full pipeline run on the new version
succeeds.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Stage fails instantly on `opencode: command not found` | `opencode-ai` install failed (npm outage) or `OPENCODE_VERSION` pin is wrong. |
| Agent asks a question and stops | The agent only ever asks for the repo URL — if the prompt reached it malformed, check the stage log. |
| `No requirements found …` in the design/backend/web stage | The upstream stage did not push its deliverables (check its run + the target repo). The agents' own hard gates will not let downstream improvise — fix the input and re-run the pipeline. |
| `stage <X> delivered no commits` (assert step) | The agent exited 0 without pushing — most likely it ended on one of its own gates (no design / no requirements / missing concept material); the agent's stated reason is in the stage log. Fix the input and re-run. |
| `stage <X> stalled — no output for 40m` (exit 137) | A subagent or provider stream hung. Drafts are checkpointed to the target repo before the critic loop, so a re-run picks the work up from there. Repeated stalls point at the OpenCode version pin — see *Stage timeouts*. |
| Push rejected on the target | The agent handles `pull --rebase` + retry itself; repeated failures usually mean branch protection — allow the `FACTORY_PUSH_TOKEN` identity or run the target on a writable branch policy. |

## Costs & capacity notes

- Agent stages are long (up to ~6 h on hosted runners). For heavy use,
  self-hosted runners with larger disks are a drop-in change (add
  `runs-on:` per job).
