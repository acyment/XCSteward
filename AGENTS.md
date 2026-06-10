# Driving XCSteward from an AI agent

This guide is for **AI agents and automation that run XCSteward as a tool**
(Claude Code, Cursor, Codex, CI scripts, …). To contribute to XCSteward itself,
see [`README.md`](README.md); for the exact interface, see [`CONTRACT.md`](CONTRACT.md).

It is vendor-neutral: the same loop works from any agent that can run a shell
command and parse JSON.

## Why go through XCSteward instead of `xcodebuild`

On a shared Mac, multiple agents/scripts calling `xcodebuild` directly collide
over the simulator subsystem. XCSteward serializes jobs through a lease-backed
queue, isolates each job's DerivedData / logs / `.xcresult`, and gives you a
**stable JSON contract** so you never scrape build output.

## Rules

1. **Always pass `--json`.** Parse stdout; never parse human text.
2. **Persist the last JSON document** you received for each job.
3. **Branch on `result_class` and the exit code**, not on log scraping.
4. **Ignore unknown JSON fields** and **default-branch unknown enum values**
   (the contract evolves additively; read `schema_version`).
5. Machine output is on **stdout**; errors and `--progress` events are on
   **stderr**.

## Canonical loop

```sh
# 1) Submit (returns immediately with a queued job)
summary="$(xcsteward submit --project "$PROJECT" --json)"
job_id="$(printf '%s' "$summary" | jq -r .job_id)"

# 2) Poll until terminal, backing off
while :; do
  status="$(xcsteward status "$job_id" --json)"
  case "$(printf '%s' "$status" | jq -r .state)" in
    queued|running) sleep 2 ;;
    *) break ;;
  esac
done

# 3) Read outcome + artifacts
result_class="$(printf '%s' "$status" | jq -r .result_class)"
xcsteward explain "$job_id" --json       # bounded triage + retry guidance
xcsteward artifacts "$job_id" --json     # paths to .xcresult, logs, junit, …
```

Prefer `submit --wait --json` (optionally `--wait-timeout <seconds>`) when you
want a single synchronous call instead of polling; it exits with the job's
outcome code (see below).

For an interactive human view of an existing job, `status <job-id> --watch`
prints compact updates until terminal and `logs <job-id> --follow` streams the
combined log. With `--json`, `status --watch` prints newline-delimited
`JobSummary` objects.

Agents that can process streaming stdout may use `status <job-id> --watch
--json` instead of a manual polling loop. Continue to branch on the most recent
`JobSummary`, not on human watch text.

If a `submit --wait` terminal is quiet long enough to seem hung, check
XCSteward state instead of guessing: run `status <job-id> --json`,
`jobs --json`, or human `status <job-id> --watch` against the same state root.
No `combined.log` yet usually means the job is still queued or in
simulator/bootstrap setup before xcodebuild has written logs.

When useful, attach ownership hints without changing the contract shape:
`--metadata agent=<agent> --metadata task=<id> --label <short-label>`. These
keys are echoed in the job summary and terminal run metadata.

When a job needs per-run environment, use repeatable `--env KEY=VALUE`. CLI env
overrides profile `[env]` for that job only; terminal run metadata records only
`env_override_keys`, not values.

## Interpreting the outcome

Decide what to do from `result_class` (and the matching exit code):

| `result_class` | Exit | What it means | Agent action |
|---|---|---|---|
| `success` | 0 | Tests passed | Done. |
| `test_failure` / `build_failure` | 10 | Real product/test failure | **Do not blind-retry.** Surface the failure + artifacts to the user. |
| `test_timeout` / `build_timeout` | 11 | Phase exceeded its timeout after the phase started normally | Retry at most once; investigate flakiness/timeouts. |
| `runner_bootstrap_failure` / `artifact_failure` | 12 | Host/tooling problem, not your code | Inspect artifacts, run `xcsteward doctor --json`, fix the environment, then retry. |
| `canceled` | 13 | Job was canceled | Report; retry only if the cancellation was incidental. |
| `internal_error` / `unsupported_destination` | 14 | XCSteward/config problem | Report with artifacts; check the destination/profile. |

Usage/config errors (no job produced) exit `2`–`7` with an error document on
stderr (`code` + `message`). See [`CONTRACT.md`](CONTRACT.md) for the full table.

## Retry policy

- Retry **infrastructure** failures (12) and **timeouts** (11), with a small cap.
- **Never** auto-retry `test_failure`/`build_failure` (10) — those are real.
- After repeated infra failures, run `doctor` and stop; the host needs attention.
- If `result_class` is `runner_bootstrap_failure` and
  `diagnostic_excerpt.subtype` is `pre_xctest_timeout`, XCTest never attached;
  treat it as simulator/bootstrap trouble, not a timed-out test case.

## Maintenance commands

- `xcsteward projects --json` — discover configured project profiles and their
  load status.
- `xcsteward profile show <name> --json` — inspect the materialized profile an
  agent is about to run.
- `xcsteward profile init --repo-root <path> --detect --json` — create an
  initial profile when the repo has a detectable project/workspace and scheme.
  From the repo root, `xcsteward profile init --detect --json` is enough; follow
  the returned `next_commands` when present.
- `xcsteward explain <job-id> --json` — bounded triage document with summary,
  artifacts, failed tests or build issues, useful log excerpts, and retry
  guidance.
- `xcsteward doctor --json` — environment readiness (`overall_status`
  pass/warn/fail; exit `20` on fail). `--fix` applies safe, XCSteward-scoped
  remediations.
- `xcsteward cleanup --json` — dry-run prune of old terminal jobs; add `--apply`
  to delete.
- `xcsteward cleanup --caches --json` — dry-run cleanup of XCSteward-owned
  cache/evidence files; add `--apply` to delete without selecting job artifacts.
- `xcsteward jobs --json` — array of full job summaries.

## Stability

Read `schema_version` (currently `1`). The contract evolves additively; a
breaking change bumps `schema_version` and is recorded in
[`CONTRACT.md`](CONTRACT.md). Tool-specific snippets live in
[`Examples/agents/`](Examples/agents/).
