# XCSteward CLI contract

Authoritative, versioned specification of XCSteward's machine-readable interface
so tools and coding agents can drive it without scraping human text.

- **Schema version:** `1` (the integer in every JSON document's `schema_version`).
- **Status:** alpha. Breaking changes are possible before `1.0`, but they will
  bump `schema_version` and be noted in the changelog below.

## Stability tiers

- **Stable** — relied upon; changes are additive or bump `schema_version`:
  the job-summary fields, the `JobState` / `ResultClass` / `DoctorStatus` enum
  value sets, the error-code strings, and the exit-code table.
- **Experimental** — may change without a `schema_version` bump: `--progress`
  events, the host-health/capacity signals, and the `_internal` command.

## Global invariants

- A `--json` command writes **exactly one JSON document to stdout**. Human
  (non-`--json`) output also goes to stdout.
- Diagnostics, the `--json` error envelope, and `--progress` events go to
  **stderr**.
- If a `--json` command fails before producing its object, stdout is empty and a
  single error document is written to stderr.
- Every emitted JSON document carries a top-level integer **`schema_version`**.
- Consumers must **ignore unknown fields** and **default-branch unknown enum
  values** (new states / result classes / checks may be added additively).

## Global flags & environment

- `--state-root <path>` — state directory (default
  `~/Library/Application Support/XCSteward`; or `XCSTEWARD_HOME`).
- `--json` — machine-readable output. `--progress` — JSON-lines events on stderr.
- `--help`, `-h`.

## Commands

| Command | Purpose | `--json` output | Notable exit codes |
|---|---|---|---|
| `submit --project <p> [--wait]` | Queue (optionally wait for) a test job | JobSummary | 0; 10/11/12/13/14 with `--wait`; 7 on wait timeout |
| `status <job-id>` | Show a job summary | JobSummary | 0 non-terminal/success; 10–14 by outcome |
| `jobs` | List all jobs | Array of JobSummary | 0 |
| `artifacts <job-id>` | Artifact paths for a job | JobArtifacts | 0 |
| `logs <job-id>` | Print combined log (raw) | — | 0 |
| `cancel <job-id>` | Cancel a job | JobSummary | **0 on success** (state in JSON) |
| `cleanup [--apply]` | Prune old terminal jobs | CleanupReport | 0 |
| `doctor [--project <p>] [--fix]` | Environment diagnostics | DoctorReport | 0; **20** when overall status is `fail` |

`jobs --json` returns a **bare array of full `JobSummary` objects** (same shape
as `status --json`); each element carries its own `schema_version`.

## JSON shapes (stable fields)

**JobSummary** — `job_id`, `project`, `state`, `result_class`, `exit_code`,
`submitted_at`, `started_at`, `finished_at`, `duration_seconds`, `test_plan`,
`only_testing`, `simulator_id`, `counts` (`tests_run`/`tests_failed`/`tests_skipped`),
`artifacts` (JobArtifacts), `summary_line`, `metadata`, `schema_version`.
Timestamps are Unix epoch seconds; nullable fields are present even when unknown.

**JobArtifacts** — `xcresult`, `combinedLog`, `buildLog`, `testLog`,
`derivedData`, `diagnostics`, `junit`, `commandEvents`, `schema_version`
(absolute paths or null).

**DoctorReport** — `overall_status` (`pass`|`warn`|`fail`), `checks[]`
(`id`, `status`, `message`, `auto_fixable`, `fixed`, `manual_action`,
`evidence_path`, `failure_excerpt`), `profiles_checked`, `schema_version`.

**CleanupReport** — `dry_run`, `older_than_seconds`, `keep_last`,
`max_total_bytes`, `cutoff`, `total_managed_bytes`, `selected_bytes`,
`candidate_count`, `deleted_count`, `candidates[]`, `schema_version`.

**Error envelope** — `{ "error": { "code", "message" }, "schema_version" }`.

### Enum values

- `state`: `queued`, `running`, `succeeded`, `failed`, `canceled`, `interrupted`.
- `result_class`: `success`, `build_failure`, `build_timeout`, `test_failure`,
  `test_timeout`, `unsupported_destination`, `runner_bootstrap_failure`,
  `artifact_failure`, `canceled`, `internal_error`.
- `doctor` `status`: `pass`, `warn`, `fail`.

## Exit codes

`0` is success; everything else is a failure. Ranges: `1` generic, `2–9`
CLI/usage errors, `10–19` job outcomes, `20–29` command diagnostics, `30+`
reserved (avoid `>125`).

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | generic / unexpected error |
| 2 | usage error |
| 3 | not found |
| 4 | invalid configuration |
| 5 | state root unavailable |
| 6 | operation canceled (e.g. an aborted command) |
| 7 | command failed (includes `--wait` timeout) |
| 10 | job `test_failure` / `build_failure` |
| 11 | job `test_timeout` / `build_timeout` |
| 12 | job infra failure (`runner_bootstrap_failure` / `artifact_failure`) |
| 13 | job canceled (terminal state) |
| 14 | job `internal_error` / `unsupported_destination` |
| 20 | `doctor` overall status `fail` |

`cancel` returns `0` when the cancellation request succeeds, regardless of the
resulting job state (read `state` from its JSON).

### Error codes ↔ exit codes

`usage`→2, `not_found`→3, `invalid_configuration`→4, `state_root_unavailable`→5,
`canceled`→6, `command_failed`→7, `unexpected_error`→1.

## Evolution policy

- **Additive** (no `schema_version` bump): new fields, new enum values, new
  commands/flags. Consumers must tolerate these.
- **Breaking** (bumps `schema_version`): removing/renaming/retyping a field,
  changing the meaning of an existing enum value, or changing an exit code's
  meaning. Breaking changes are listed in the changelog and, where practical,
  preceded by a deprecation period.

## Changelog

- **schema_version 1** — initial published contract. Added `schema_version` to
  all JSON documents; introduced the richer exit-code table (previously `0`/`1`);
  `jobs --json` widened from a reduced object to full `JobSummary` objects.
