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

- A `--json` command writes **exactly one JSON document to stdout**, except
  documented streaming modes such as `status --watch --json`, which write
  newline-delimited JSON documents. Human (non-`--json`) output also goes to
  stdout.
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
| `projects` | List configured project profiles | ProjectListDocument | 0 |
| `profile show <name>` | Show a materialized project profile | ProfileShowDocument | 0; 3/4 on missing or invalid profile |
| `profile init [--repo-root <p>] --detect` | Create a detected project profile | ProfileInitDocument | 0; 4/7 on detection failures |
| `status <job-id> [--watch]` | Show a job summary; with `--watch`, poll until terminal | JobSummary; `--watch --json` emits NDJSON JobSummary objects | 0 non-terminal/success; 10–14 by outcome |
| `jobs` | List all jobs | Array of JobSummary | 0 |
| `explain <job-id>` | Explain a job outcome and useful evidence | ExplainDocument | 0; 3 on missing job |
| `artifacts <job-id>` | Artifact paths for a job | JobArtifacts | 0 |
| `logs <job-id> [--follow]` | Print combined log (raw); with `--follow`, stream until terminal | — | 0 |
| `cancel <job-id>` | Cancel a job | JobSummary | **0 on success** (state in JSON) |
| `cleanup [--apply]` | Prune old terminal jobs or, with `--caches`, XCSteward-owned cache items | CleanupReport | 0 |
| `doctor [--project <p>] [--fix]` | Environment diagnostics | DoctorReport | 0; **20** when overall status is `fail` |

`jobs --json` returns a **bare array of full `JobSummary` objects** (same shape
as `status --json`); each element carries its own `schema_version`.

`status --watch --json` returns newline-delimited full `JobSummary` objects on
stdout. One-shot `status --json` remains a single JSON object.

`submit` accepts repeatable `--metadata <key=value>` and `--label <value>`,
which is equivalent to `--metadata label=<value>`. Metadata is preserved in
`JobSummary.metadata` and terminal `artifacts/run-metadata.json` under
`request.metadata`.

`submit` also accepts repeatable `--env <KEY=VALUE>`. These values override
profile `[env]` for that job's tool invocations only. Terminal
`artifacts/run-metadata.json` records `request.env_override_keys` only; it does
not copy env override values.

`submit --wait --json --progress` emits experimental JSON-line progress events
on stderr. When command events are available, progress events include additive
`phase` and `phase_elapsed_seconds` fields.

## JSON shapes (stable fields)

**ProjectListDocument** — `state_root`, `projects_root`, `projects[]`
(`name`, `path`, `load_status`, optional `error_code`/`error_message`,
optional `repo_root`/`project_path`/`workspace_path`/`scheme`),
`schema_version`.

**ProfileShowDocument** — `path`, `profile` (materialized profile settings),
`schema_version`.

**ProfileInitDocument** — `profile_path`, `created`, `warnings[]`,
`next_commands[]`, `profile` (materialized profile settings), `schema_version`.

**ExplainDocument** — `job_id`, `project`, `state`, `result_class`,
`exit_code`, `summary_line`, `retry_policy` (`auto_retry`,
`max_auto_retries`, `reason`), `recommended_action`, `artifacts`, `failed_tests[]`
(`class_name`, `name`, `failure_kind`, `message`), `build_issues[]`
(`source`, `path`, `line_number`, `text`), `log_excerpts[]` (`source`, `path`,
`line_count`, `excerpt`), `warnings[]`, `summary`, `schema_version`.

**JobSummary** — `job_id`, `project`, `state`, `result_class`, `exit_code`,
`submitted_at`, `started_at`, `finished_at`, `duration_seconds`, `test_plan`,
`only_testing`, `simulator_id`, `counts` (`tests_run`/`tests_failed`/`tests_skipped`),
`artifacts` (JobArtifacts), `summary_line`, `metadata`, `diagnostic_excerpt`,
`schema_version`.
Timestamps are Unix epoch seconds; nullable fields are present even when unknown.

**JobDiagnosticExcerpt** — omitted or null when absent. When present, `subtype`,
`phase`, `phase_elapsed_seconds`, `timeout_seconds`, `evidence_paths[]`,
`excerpt`.
For a test command timeout before XCTest attaches, `subtype` is
`pre_xctest_timeout` and `result_class` remains `runner_bootstrap_failure`.

**JobArtifacts** — `xcresult`, `combinedLog`, `buildLog`, `testLog`,
`derivedData`, `diagnostics`, `junit`, `commandEvents`, `schema_version`
(absolute paths or null).

**DoctorReport** — `overall_status` (`pass`|`warn`|`fail`), `checks[]`
(`id`, `status`, `message`, `auto_fixable`, `fixed`, `manual_action`,
`evidence_path`, `failure_excerpt`), `profiles_checked`, `schema_version`.

**CleanupReport** — `dry_run`, `older_than_seconds`, `keep_last`,
`max_total_bytes`, `cutoff`, `total_managed_bytes`, `selected_bytes`,
`candidate_count`, `deleted_count`, `candidates[]`, `cache_selected_bytes`,
`cache_candidate_count`, `cache_deleted_count`, `cache_candidates[]`,
(`path`, `kind`, `deleted`, `bytes`, `reason`), `schema_version`.

**Error envelope** — `{ "error": { "code", "message" }, "schema_version" }`.

### Enum values

- `state`: `queued`, `running`, `succeeded`, `failed`, `canceled`, `interrupted`.
- `result_class`: `success`, `build_failure`, `build_timeout`, `test_failure`,
  `test_timeout`, `unsupported_destination`, `runner_bootstrap_failure`,
  `artifact_failure`, `canceled`, `internal_error`.
- `runner_bootstrap_failure` includes environment/runner failures before XCTest
  attaches, including simulator boot/launch failures and test command timeouts
  before attach evidence is observed.
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
- **schema_version 1 additive** — added `projects --json`, `profile show
  --json`, and `profile init --detect --json` for agent-friendly profile
  discovery and bootstrapping; `profile init` now defaults `--repo-root` to the
  current directory and emits `next_commands`.
- **schema_version 1 additive** — added `explain <job-id> --json` for bounded
  triage of summaries, artifacts, failed tests, build issues, log excerpts, and
  retry guidance.
- **schema_version 1 additive** — added repeatable `submit --metadata
  <key=value>` and `--label <value>` for preserving agent/job ownership hints in
  `JobSummary.metadata` and run metadata.
- **schema_version 1 additive** — added `cleanup --caches` plus cache fields in
  `CleanupReport` for dry-run/apply cleanup of XCSteward-owned state-root cache
  and retained doctor evidence items without selecting job artifacts.
- **schema_version 1 additive** — added human wait context/progress for plain
  `submit --wait`, `status --watch` with NDJSON output under `--json`, and
  `logs --follow` for streaming combined logs until a job is terminal.
- **schema_version 1 additive** — added repeatable `submit --env <KEY=VALUE>`,
  `JobSummary.diagnostic_excerpt`, progress `phase` /
  `phase_elapsed_seconds`, and `pre_xctest_timeout` diagnostics under
  `runner_bootstrap_failure` for test command timeouts before XCTest attaches.
