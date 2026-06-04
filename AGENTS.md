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
xcsteward artifacts "$job_id" --json     # paths to .xcresult, logs, junit, …
```

Prefer `submit --wait --json` (optionally `--wait-timeout <seconds>`) when you
want a single synchronous call instead of polling; it exits with the job's
outcome code (see below).

## Interpreting the outcome

Decide what to do from `result_class` (and the matching exit code):

| `result_class` | Exit | What it means | Agent action |
|---|---|---|---|
| `success` | 0 | Tests passed | Done. |
| `test_failure` / `build_failure` | 10 | Real product/test failure | **Do not blind-retry.** Surface the failure + artifacts to the user. |
| `test_timeout` / `build_timeout` | 11 | Phase exceeded its timeout | Retry at most once; investigate flakiness/timeouts. |
| `runner_bootstrap_failure` / `artifact_failure` | 12 | Host/tooling problem, not your code | Inspect artifacts, run `xcsteward doctor --json`, fix the environment, then retry. |
| `canceled` | 13 | Job was canceled | Report; retry only if the cancellation was incidental. |
| `internal_error` / `unsupported_destination` | 14 | XCSteward/config problem | Report with artifacts; check the destination/profile. |

Usage/config errors (no job produced) exit `2`–`7` with an error document on
stderr (`code` + `message`). See [`CONTRACT.md`](CONTRACT.md) for the full table.

## Retry policy

- Retry **infrastructure** failures (12) and **timeouts** (11), with a small cap.
- **Never** auto-retry `test_failure`/`build_failure` (10) — those are real.
- After repeated infra failures, run `doctor` and stop; the host needs attention.

## Maintenance commands

- `xcsteward doctor --json` — environment readiness (`overall_status`
  pass/warn/fail; exit `20` on fail). `--fix` applies safe, XCSteward-scoped
  remediations.
- `xcsteward cleanup --json` — dry-run prune of old terminal jobs; add `--apply`
  to delete.
- `xcsteward jobs --json` — array of full job summaries.

## Stability

Read `schema_version` (currently `1`). The contract evolves additively; a
breaking change bumps `schema_version` and is recorded in
[`CONTRACT.md`](CONTRACT.md). Tool-specific snippets live in
[`Examples/agents/`](Examples/agents/).
