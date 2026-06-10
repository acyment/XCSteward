---
name: xcsteward-agent-driver
description: Use when any AI or coding agent needs to run, monitor, or diagnose iOS Simulator tests through XCSteward. Applies to agents with shell access and JSON parsing, regardless of vendor or UI. Use the XCSteward CLI contract directly; do not add an MCP or protocol wrapper.
---

# XCSteward Agent Driver

XCSteward is the coordination layer for shared iOS Simulator test runs. When a
project is configured for XCSteward, drive tests through `xcsteward` instead of
calling `xcodebuild` directly.

## Core Rules

- Always pass `--json` for commands that support it.
- Preserve the last JSON document from each job in your transcript, logs, or
  temporary files.
- Branch on `state`, `result_class`, and the command exit code. Do not scrape
  human text or raw build logs to classify the outcome.
- Treat unknown JSON fields as additive, and default-branch unknown enum values.
- Machine output is on stdout. JSON progress events and error envelopes are on
  stderr.
- Do not add an MCP layer. The CLI plus JSON contract is the integration
  surface.

## Discover The Project

Use the local repository instructions first. Prefer `AGENTS.md`, then
`CONTRACT.md`, then short examples under `Examples/agents/` when they exist.

If the profile name is not obvious, use the machine-readable profile list:

```sh
xcsteward projects --json
```

Inspect a candidate before running it:

```sh
xcsteward profile show "$PROJECT" --json
```

If multiple profiles are plausible and there is no local instruction that
chooses one, ask the user for the profile name rather than guessing.

If no usable profile exists for the current repository, create one before
running tests:

```sh
xcsteward profile init --detect --json
```

Run this from the repository root. It detects a single shared `.xcworkspace` or
`.xcodeproj` and an unambiguous scheme, defaults the profile name to the repo
directory, and returns `next_commands`. Follow those commands when present.

If detection reports multiple schemes, rerun with `--scheme <name>` only when
local repo instructions make the choice clear; otherwise ask the user. If the
returned warnings say no simulator assignment was written, pass a concrete
`--simulator-id` on the first submit or rerun init with `--simulator-id`.

## Run A Job

Prefer one bounded synchronous command:

```sh
xcsteward submit --project "$PROJECT" --wait --wait-timeout "$SECONDS" --json --progress
```

When useful, attach ownership hints with repeatable metadata:

```sh
xcsteward submit --project "$PROJECT" --metadata agent="$AGENT_NAME" --metadata task="$TASK_ID" --label "$LABEL" --wait --wait-timeout "$SECONDS" --json --progress
```

Metadata is echoed in `JobSummary.metadata` and terminal
`artifacts/run-metadata.json` under `request.metadata`.

Use a timeout that matches the expected suite size. For targeted tests, pass the
same filters XCSteward exposes to Xcode:

```sh
xcsteward submit --project "$PROJECT" --only-testing AppTests/FooTests/testBar --wait --wait-timeout "$SECONDS" --json --progress
```

Because terminal product failures intentionally return nonzero exit codes, make
sure your shell runner still captures stdout and stderr. Do not let shell
`set -e` or an equivalent wrapper discard the final JSON.

## If A Wait Looks Hung

XCSteward state is inspectable while a job is queued or running. A quiet
`submit --wait --json` terminal does not mean the job is stuck, and it should
not be killed just because there has been no recent stdout.

Use the same state root and check the job from another command:

```sh
xcsteward status "$JOB_ID" --json
xcsteward jobs --json
xcsteward logs "$JOB_ID"
```

For a human terminal, use:

```sh
xcsteward status "$JOB_ID" --watch
xcsteward logs "$JOB_ID" --follow
```

For machine streaming, use `status "$JOB_ID" --watch --json` and branch on the
latest `JobSummary`. If `logs` says `combined.log` is not available yet, that
usually means the job is still queued or in simulator/bootstrap setup before
xcodebuild has written logs; keep polling `status` or run `explain` after the
job is terminal.

For long-running orchestration where a single wait command is not appropriate,
submit first, then poll. The example uses `jq` for brevity; use any reliable
JSON parser available to the agent:

```sh
summary="$(xcsteward submit --project "$PROJECT" --json)"
job_id="$(printf '%s\n' "$summary" | jq -r .job_id)"

while :; do
  status="$(xcsteward status "$job_id" --json || true)"
  state="$(printf '%s\n' "$status" | jq -r .state)"
  case "$state" in
    queued|running) sleep 2 ;;
    *) break ;;
  esac
done
```

For a human-facing terminal, `xcsteward status "$job_id" --watch` prints compact
updates until terminal and `xcsteward logs "$job_id" --follow` streams the
combined log. For machine use, keep using `--json`; `status --watch --json`
emits newline-delimited `JobSummary` objects.

## Interpret Results

Read `references/result-classes.md` for the result-class table.

After a terminal job, prefer the bounded triage document before opening raw
logs:

```sh
xcsteward explain "$JOB_ID" --json
```

General policy:

- `success`: report success and useful counts/artifacts.
- `test_failure` or `build_failure`: treat as product/test failure. Do not
  blind-retry. Inspect artifacts before editing code.
- `test_timeout` or `build_timeout`: retry at most once, then investigate
  timeout/flakiness with artifacts.
- `runner_bootstrap_failure` or `artifact_failure`: inspect artifacts and run
  `xcsteward doctor --json`; retry only after the environment issue is
  understood or fixed.
- `canceled`: report cancellation. Retry only if cancellation was incidental.
- `internal_error` or `unsupported_destination`: report with artifacts and
  check the profile, destination, or XCSteward configuration.

If a `--json` command fails before producing stdout, parse the stderr error
envelope:

```json
{ "error": { "code": "usage", "message": "..." }, "schema_version": 1 }
```

## Report Back

Include the fields that let a human or another agent continue the work:

- `job_id`
- `project`
- `state`
- `result_class`
- `exit_code`
- test counts, when present
- absolute artifact paths for `.xcresult`, combined log, build log, test log,
  diagnostics, JUnit, DerivedData, and command events when present

For failed jobs, summarize what you inspected and which artifact contains the
evidence. Prefer `explain --json` excerpts over pasting large logs.

## Maintenance

Run diagnostics when the result class or local context indicates host trouble:

```sh
xcsteward doctor --json
xcsteward doctor --project "$PROJECT" --json --progress
```

Use `doctor --fix` only for safe XCSteward-scoped remediation. Do not run
`doctor --fix-global --dangerously-confirm-global-coresimulator-cleanup` unless
the user or operator explicitly requested broad CoreSimulator cleanup.

To free XCSteward-owned cache/evidence files without deleting job artifacts,
use the cache-specific cleanup mode:

```sh
xcsteward cleanup --caches --json
xcsteward cleanup --caches --apply --json
```
