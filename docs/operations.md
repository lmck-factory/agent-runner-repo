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

Each stage is also guarded against an **early silent stop**: a run that exits 0
in under `MIN_STAGE_SEC` (default 900) was still mid-work when it ended — the
model returns a turn carrying nothing executable, the session goes idle and
`opencode run` exits 0 with no error event. `run-stage.sh` retries that once
(`STAGE_ATTEMPTS`, default 2) and then fails with exit 3 and the stage log's
last lines. Raise or lower `MIN_STAGE_SEC` in the job env for a stage that
genuinely delivers faster; `0` disables the floor.

## The stage log

Every stage writes its streamed OpenCode output to
`$RUNNER_TEMP/factory-<stage>.log` (attempt 1 of a retried stage is kept next
to it as `…log.attempt1`). The path is exported to the job as `STAGE_LOG`, so
the assert step prints its last 80 lines whenever a stage delivered no commit,
and the job uploads it as an artifact (`stage-log-<stage>`) on failure.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Stage fails instantly on `opencode: command not found` | `opencode-ai` install failed (npm outage) or `OPENCODE_VERSION` pin is wrong. |
| Agent asks a question and stops | The agent only ever asks for the repo URL — if the prompt reached it malformed, check the stage log. |
| `No requirements found …` in the design/backend/web stage | The upstream stage did not push its deliverables (check its run + the target repo). The agents' own hard gates will not let downstream improvise — fix the input and re-run the pipeline. |
| `stage <X> delivered no commits` (assert step) | The assert step prints the last 80 lines of the stage log and says which case it is: **the agent ended on one of its own gates** (no design / no requirements — its statement of fact is in the tail) or **the run ended with no delivery and no stated reason** (the stream simply stops — the model dropped out mid-work). Fix the input and re-run in the first case; the second case is what the early-stop floor below is for. |
| `stage <X> ended after <N>s` (exit 3 from `run-stage.sh`) | The model stopped early: the run exited 0 well under `MIN_STAGE_SEC` with nothing delivered, and the automatic retry did too. Re-dispatch; if it repeats, the stage model/provider is dropping turns — check `PIPELINE_MODEL` and the log artifact. |
| `stage <X> stalled — no output for 40m` (exit 137) | A subagent or provider stream hung. Drafts are checkpointed to the target repo before the critic loop, so a re-run picks the work up from there. Repeated stalls point at the OpenCode version pin — see *Stage timeouts*. |
| Push rejected on the target | The agent handles `pull --rebase` + retry itself; repeated failures usually mean branch protection — allow the `FACTORY_PUSH_TOKEN` identity or run the target on a writable branch policy. |

## Costs & capacity notes

- Agent stages are long (up to ~6 h on hosted runners). For heavy use,
  self-hosted runners with larger disks are a drop-in change (add
  `runs-on:` per job).
