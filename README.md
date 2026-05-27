# XCSteward

Local macOS CLI for coordinating iOS simulator test jobs across projects and coding agents.

## Public alpha scope

XCSteward is public-alpha software. Use it first on disposable or low-risk
local state, keep raw `xcodebuild` as the fallback, and inspect the job
artifacts when a run fails. The alpha safety promise is narrow: XCSteward
should not report false success, mutate simulators without a job-owned lease,
delete state outside its configured state root, or run broad CoreSimulator
cleanup unless an operator explicitly opts in with a global fix flag.

The supported alpha target is a local Apple Silicon or Intel Mac running
macOS 13 or newer with a Swift 6 toolchain and Xcode 16 or newer selected by
`xcode-select`. The fake-tool test suite is the default verification path.
Before tagging a public alpha, also run the opt-in live smoke test on the
exact Xcode and simulator runtime you intend to support.
The release-gate runbook is [docs/hardening-matrix.md](docs/hardening-matrix.md).
The public-alpha operator runbook is [docs/public-alpha.md](docs/public-alpha.md), and live-use progress is tracked in [docs/dogfood-ledger.md](docs/dogfood-ledger.md).

Keep alpha concurrency conservative. Serialized local simulator jobs are the
default. Multi-job dispatch, manual sharding, hybrid sharding, and shared-Mac
operation should be treated as experimental until they pass the hardening
matrix and a live dogfood run on the target host.

## Install

### Homebrew

```bash
brew tap acyment/tap
brew install xcsteward
```

Verify the binary and local host setup:

```bash
xcsteward --help
xcsteward doctor --json
```

### From Source

Requires a Swift 6 toolchain and Xcode 16 or newer.

```bash
git clone https://github.com/acyment/XCSteward.git
cd XCSteward
swift build -c release
mkdir -p "$HOME/.local/bin"
cp .build/release/xcsteward "$HOME/.local/bin/xcsteward"
```

Add the install directory to your shell path if needed:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The default state root is `~/Library/Application Support/XCSteward`. Override
it per command with `--state-root <path>` or for the process environment with
`XCSTEWARD_HOME=<path>`.

## Quickstart

Build and install the binary, then create one project profile under the state
root:

```bash
STATE_ROOT="${XCSTEWARD_HOME:-$HOME/Library/Application Support/XCSteward}"
mkdir -p "$STATE_ROOT/projects"
cp Examples/profiles/demo-app.toml.template "$STATE_ROOT/projects/demo-app.toml"
perl -pi -e "s#__XCSTEWARD_REPO_ROOT__#$PWD#g" "$STATE_ROOT/projects/demo-app.toml"
xcsteward doctor --project demo-app
xcsteward submit --project demo-app --wait --json
```

For long-running JSON commands, add `--progress` to stream compact progress
events on stderr while stdout stays reserved for the final JSON object:

```bash
xcsteward doctor --project demo-app --json --progress
xcsteward submit --project demo-app --wait --json --progress
```

For a real app, replace the template with a profile that points at your repo,
scheme, and simulator UDID:

```toml
repo_root = "/absolute/path/to/repo"
workspace_path = "App.xcworkspace"
scheme = "App"
default_simulator_id = "SIM-UDID"
```

After a terminal job, inspect the evidence trail:

```bash
xcsteward artifacts <job-id> --json
xcsteward logs <job-id>
```

Agent workflow examples are available in [Examples/agents](Examples/agents).

## Commands

Build:

```bash
swift test
```

For the normal refactor loop, run the named fast tier. It writes suite-health
JSON under `.build/test-suite/`:

```bash
bash scripts/run-test-suite.sh --tier fast
```

Before a release, run the fake-tool release tier and keep the report with the
hardening-matrix and dogfood artifacts:

```bash
bash scripts/run-test-suite.sh --tier release --continue-on-failure \
  --report .build/test-suite/public-alpha-fake.json
```

For targeted verification, use the checked filter wrapper so a stale
`--filter` cannot pass as a zero-test run:

```bash
bash scripts/run-swift-test-filter.sh --filter SubmitCommandE2ETests/testSubmitWaitSuccessCreatesArtifactsAndStructuredSummary
```

The default suite uses fake tools. To run the opt-in live Xcode-managed
parallel smoke test against a real simulator, pass an explicit simulator UDID:

```bash
XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 \
XCSTEWARD_LIVE_SIMULATOR_ID=<simulator-udid> \
swift test --filter LiveXcodeManagedParallelSmokeTests
```

By default, that test generates a tiny Swift package and runs it through
XCSteward with `parallel.mode = "xcode-managed"` and exact worker count `2`.
To point the smoke test at an existing project instead, also set
`XCSTEWARD_LIVE_REPO_ROOT`, `XCSTEWARD_LIVE_SCHEME`, and optionally
`XCSTEWARD_LIVE_PROJECT_PATH` or `XCSTEWARD_LIVE_WORKSPACE_PATH`.

Run the built binary:

```bash
./.build/arm64-apple-macosx/debug/xcsteward doctor --json
```

Discover the CLI from the binary itself:

```bash
xcsteward --help
xcsteward submit --help
```

Core commands:

```bash
xcsteward submit --project <name> [--wait] [--wait-timeout 300] [--json]
xcsteward submit --project <name> --only-testing AppTests/FooTests --skip-testing AppTests/FooTests/testFlaky --wait
xcsteward submit --project <name> --only-test-configuration Smoke --skip-test-configuration Flaky --wait
xcsteward status <job-id> [--json]
xcsteward jobs [--json]
xcsteward logs <job-id>
xcsteward artifacts <job-id> [--json]
xcsteward cancel <job-id> [--json]
xcsteward cleanup [--dry-run] [--apply] [--older-than 7d] [--keep-last 20] [--max-total-size 50gb] [--json]
xcsteward doctor [--project <name>] [--fix] [--fix-global --dangerously-confirm-global-coresimulator-cleanup] [--json]
```

`cleanup` is dry-run by default. It only selects terminal jobs under the
configured `jobs/` state-root directory, keeps the newest terminal jobs, skips
active worker or simulator leases, and refuses live process IDs. `--max-total-size`
also selects the oldest eligible terminal jobs until managed terminal-job bytes
fit under the budget. Use `--apply` to delete the selected job directories and
terminal job records.

`doctor` reports stale worker and simulator lease records. With `--fix`, it
removes simulator leases owned by dead XCSteward processes without touching
active leases. Broad CoreSimulator cleanup, such as deleting unavailable
devices, requires both `--fix-global` and the danger confirmation flag
`--dangerously-confirm-global-coresimulator-cleanup`.

## Uninstall and cleanup

Remove the installed binary:

```bash
rm "$HOME/.local/bin/xcsteward"
```

Clean old terminal jobs without deleting active or non-XCSteward state:

```bash
xcsteward cleanup --dry-run --older-than 7d --keep-last 20 --max-total-size 50gb --json
xcsteward cleanup --apply --older-than 7d --keep-last 20 --max-total-size 50gb --json
```

To remove all XCSteward-local state after stopping any active XCSteward worker,
delete only the configured state root:

```bash
rm -rf "$HOME/Library/Application Support/XCSteward"
```

If you used `XCSTEWARD_HOME` or `--state-root`, remove that explicit directory
instead. Do not delete global CoreSimulator state as part of uninstalling
XCSteward.

## JSON output contract

Commands with `--json` write one JSON document to stdout when the requested
object can be loaded. Some of those commands intentionally return a nonzero
exit code after printing JSON, for example `status --json` for a failed job,
`submit --wait --json` for a failed job, or `doctor --json` when a required
check fails. When `--json` is present but the command fails before loading its
requested object, XCSteward writes one JSON error document to stderr and leaves
stdout empty:

```json
{
  "error": {
    "code": "usage",
    "message": "submit requires --project"
  }
}
```

Stable command error codes are `usage`, `not_found`,
`invalid_configuration`, `command_failed`, `canceled`, and
`unexpected_error`.

`submit --json`, `submit --wait --json`, `status --json`, and
`cancel --json` return a job summary object:

```json
{
  "job_id": "UUID",
  "project": "demo",
  "state": "queued",
  "result_class": null,
  "exit_code": null,
  "submitted_at": 1760000000.0,
  "started_at": null,
  "finished_at": null,
  "duration_seconds": null,
  "test_plan": null,
  "only_testing": [],
  "simulator_id": null,
  "counts": null,
  "artifacts": {
    "xcresult": null,
    "combinedLog": null,
    "buildLog": null,
    "testLog": null,
    "derivedData": null,
    "diagnostics": null,
    "junit": null
  },
  "summary_line": "UUID queued",
  "metadata": {}
}
```

Stable job states are `queued`, `running`, `succeeded`, `failed`, `canceled`,
and `interrupted`. Stable result classes are `success`, `build_failure`,
`test_failure`, `test_timeout`, `runner_bootstrap_failure`,
`artifact_failure`, `canceled`, and `internal_error`. Timestamp fields are Unix
epoch seconds as numbers. Nullable fields are present even when the value is
not known yet.

`jobs --json` returns an array of compact job objects:

```json
[
  {
    "job_id": "UUID",
    "project": "demo",
    "state": "succeeded",
    "result_class": "success"
  }
]
```

`artifacts --json` returns the `artifacts` object from the terminal job
summary. Paths are absolute local filesystem paths and can be `null` when that
artifact was not produced.

`cleanup --json` returns a cleanup report. By default `dry_run` is `true`; use
`--apply` when the selected terminal job directories and records should be
deleted:

```json
{
  "dry_run": true,
  "older_than_seconds": 604800,
  "keep_last": 20,
  "max_total_bytes": 53687091200,
  "cutoff": 1760000000.0,
  "total_managed_bytes": 120000000000,
  "selected_bytes": 70000000000,
  "candidate_count": 2,
  "deleted_count": 0,
  "candidates": [
    {
      "job_id": "UUID",
      "state": "succeeded",
      "result_class": "success",
      "finished_at": 1760000000.0,
      "job_directory": "/absolute/path/to/state/jobs/UUID",
      "deleted": false,
      "bytes": 35000000000,
      "reason": "size_budget"
    }
  ]
}
```

Cleanup candidate `reason` values are `age` and `size_budget`. `bytes` is the
best-effort allocated disk usage of regular files under the job directory, with
logical file size as a fallback when allocation metadata is unavailable.
`max_total_bytes` is `null` when `--max-total-size` was not supplied.

`doctor --json` returns:

```json
{
  "overall_status": "pass",
  "checks": [
    {
      "id": "global.xcode_available",
      "status": "pass",
      "message": "xcodebuild is available",
      "auto_fixable": false,
      "fixed": false,
      "manual_action": null
    }
  ],
  "profiles_checked": []
}
```

Doctor statuses are `pass`, `warn`, and `fail`. Agents should treat unknown
future fields as additive, preserve the full JSON object in logs, and make
control-flow decisions from `state`, `result_class`, `overall_status`,
`dry_run`, `candidate_count`, and `deleted_count`.

Use `--state-root <path>` to point the CLI at a specific local state directory. By default it uses `~/Library/Application Support/XCSteward`.

Set `XCSTEWARD_MAX_CONCURRENT_JOBS=<n>` on the worker environment to allow the
singleton worker process to run up to `n` queued jobs at once. The default is
`1`. Concurrent jobs still require distinct simulator UDIDs because XCSteward
leases each resolved simulator exclusively for the owning job.

When concurrent jobs are enabled, XCSteward writes a best-effort
`host-health.json` snapshot under the state root and reduces dispatch
concurrency to one job when configured health signals indicate constrained host
capacity. Supported inputs are `XCSTEWARD_MEMORY_PRESSURE`,
`XCSTEWARD_SAMPLE_MEMORY_PRESSURE`, `XCSTEWARD_THERMAL_STATE`,
`XCSTEWARD_SAMPLE_THERMAL_STATE`, `XCSTEWARD_MAX_LOAD_AVERAGE`,
`XCSTEWARD_LOAD_AVERAGE`, `XCSTEWARD_RECENT_INFRA_FAILURE_LIMIT`,
`XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS`,
`XCSTEWARD_MAX_BOOTED_SIMULATORS`, `XCSTEWARD_BOOTED_SIMULATOR_COUNT`,
`XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES`, `XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT`,
and `XCSTEWARD_FOREIGN_ACTIVITY_POLICY`.
Recovered runner/bootstrap incidents, including shard retries that ultimately
succeed, are counted as recent infrastructure failures for this capacity gate.
When `XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT` is set and reached within the same
failure window, the worker writes `draining=true` to `host-health.json` and
stops dispatching new queued jobs until the window clears.
Set `XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES` to cap simulator lease pressure
independently from job count; active jobs are treated as reserved simulator
slots while they are still starting.
Set `XCSTEWARD_SAMPLE_MEMORY_PRESSURE=true` to sample macOS
`memory_pressure` and reduce dispatch to one job when it reports warning,
serious, or critical pressure. `XCSTEWARD_MEMORY_PRESSURE` can still inject an
explicit value and takes precedence over sampling. Memory-pressure sampling is
off by default; `host-health.json` reports the policy as
`memory_pressure_sampling_enabled`.
Set `XCSTEWARD_SAMPLE_THERMAL_STATE=true` to sample `pmset -g therm` and reduce
dispatch to one job when CPU thermal throttling maps to serious or critical
state. `XCSTEWARD_THERMAL_STATE` can still inject an explicit value and takes
precedence over sampling. Thermal sampling is off by default;
`host-health.json` reports the policy as `thermal_state_sampling_enabled`.
Set `XCSTEWARD_MAX_LOAD_AVERAGE` to reduce dispatch to one job when the host's
1-minute load average reaches that threshold. `XCSTEWARD_LOAD_AVERAGE` can
override the sampled load average in controlled environments.
`XCSTEWARD_FOREIGN_ACTIVITY_POLICY` controls how non-XCSteward
`xcodebuild test`/`xctest` activity affects dispatch: `capacity` (default)
reduces concurrent dispatch to one job, `strict` stops new dispatch while the
foreign runner is active, and `ignore` disables this capacity signal.

## Profile schema

Profiles live under:

```text
<state-root>/projects/<name>.toml
```

Minimal profile:

```toml
repo_root = "/absolute/path/to/repo"
project_path = "App.xcodeproj"
scheme = "App"
default_simulator_id = "SIM-UDID"
```

Set exactly one of `project_path` or `workspace_path`; use
`workspace_path = "App.xcworkspace"` for workspace-based apps. `repo_root` and
`scheme` are required. A simulator must come from `default_simulator_id`, an
allowed `--simulator-id` override, or a `[managed_simulator]` block.

Create and verify a profile:

```bash
STATE_ROOT="${XCSTEWARD_HOME:-$HOME/Library/Application Support/XCSteward}"
mkdir -p "$STATE_ROOT/projects"
$EDITOR "$STATE_ROOT/projects/demo.toml"
xcsteward doctor --project demo
xcsteward submit --project demo --wait --wait-timeout 300 --json
```

Example:

```toml
repo_root = "/absolute/path/to/repo"
project_path = "App.xcodeproj"
scheme = "App"
default_simulator_id = "SIM-123"
default_test_plan = "Stable"
allowed_simulator_ids = ["SIM-123"]
reset_policy = "none" # none | shutdown | erase

[timeouts]
# Positive seconds.
boot = 30
build = 600
test = 600

[destination]
# Optional xcodebuild destination wait cap in seconds.
timeout = 30

[coverage]
# Optional xcodebuild code coverage override. Omit the block to let the scheme decide.
# `enabled` must be a boolean.
enabled = true

[result_stream]
# Optional xcodebuild result stream artifact for test runs.
# `enabled` must be a boolean.
enabled = false

[result_bundle]
# Optional xcodebuild result bundle format version for test result bundles.
# `version` must be a positive integer.
version = 3

[parallel]
mode = "xcode-managed"
max_workers = 1
exact_workers = false
# shard_count is only used by mode = "manual-shards" or "hybrid"
shard_count = 1

[ports]
# Optional per-run/per-shard port range exposed to test runners.
base = 51000
count = 16
stride = 100

[test_timeouts]
# Defaults shown here. Set enabled = false to let the scheme decide.
enabled = true
default_execution_time_allowance = 120
maximum_execution_time_allowance = 600

[test_retries]
# Opt-in Xcode-managed flaky-test retry controls.
enabled = false
iterations = 1
retry_tests_on_failure = true
run_tests_until_failure = false
relaunch_between_iterations = false

[test_diagnostics]
# Optional Xcode result-bundle diagnostics collection policy.
collect = "on-failure" # on-failure | never

[test_products]
# Opt in to materializing job-scoped .xctestproducts during build-for-testing.
# `enabled` and `use_for_testing` must be booleans.
enabled = false
# Also pass -testProductsPath to test-without-building instead of -xctestrun.
use_for_testing = false

[privacy]
# Optional simctl privacy setup for each leased simulator before tests run.
# `grant`, `revoke`, and `reset` must be arrays of service or service:bundle entries.
reset = ["all"]
grant = ["photos:com.example.App", "location:com.example.App"]
revoke = ["microphone:com.example.App"]

[env]
# Environment values must be strings and are passed through verbatim.
FOO = "bar"
```

Parallel defaults are `mode = "xcode-managed"`, `max_workers = 1`, and
`exact_workers = false`. In this mode XCSteward lets Xcode manage simulator
test workers during `test-without-building`. While a job is running, XCSteward
records an exclusive lease for the resolved simulator UDID and releases it when
the job reaches a terminal state; stale leases owned by dead XCSteward
processes are recovered before the next job runs. Active jobs refresh their
worker and simulator lease heartbeats while long-running build/test commands
are in flight, so lease state remains useful for monitoring during slow jobs.
Use higher `max_workers` values only after a live smoke job proves that Xcode's
clone simulator launches are stable on the host. Targeted single-method
submissions are serialized automatically unless `exact_workers = true`.

Set `reset_policy = "shutdown"` or `reset_policy = "erase"` to clean only the
simulator UDIDs leased by XCSteward after a job. The default `none` leaves the
leased simulator state untouched after successful jobs; retry recovery still
uses targeted shutdown/erase when an infrastructure failure requires it.

The optional `[destination]` block passes `-destination-timeout <seconds>` to
destination-bearing `xcodebuild` invocations: `build-for-testing`,
`test-without-building`, manual shard runs, and test enumeration. Omit the
block to leave Xcode's default destination timeout unchanged.

The optional `[coverage]` block passes `-enableCodeCoverage YES|NO` to
`build-for-testing` and every `test-without-building` invocation, including
manual and hybrid shards. Omit the block to leave the scheme's code coverage
setting unchanged. Because coverage instrumentation is decided during build,
XCSteward applies the same override to both phases.

The optional `[result_stream]` block enables xcodebuild result-stream artifacts
for `test-without-building`. When `enabled = true`, XCSteward pre-creates the
stream file required by xcodebuild and passes `-resultStreamPath`. Non-sharded
runs write `artifacts/result-stream.json` and link it from
`run-metadata.json`; manual and hybrid shards write one `result-stream.json`
inside each shard artifact directory and link it from `shards.json`.

The optional `[result_bundle]` block passes `-resultBundleVersion <version>` to
every `test-without-building` invocation that writes an `.xcresult`, including
manual and hybrid shards. Omit the block to leave Xcode's default result bundle
format unchanged.

Every `xcodebuild` invocation gets a run-scoped `TMPDIR` under the job
directory plus `XCSTEWARD_JOB_ID`, `XCSTEWARD_PROJECT`, and
`XCSTEWARD_PHASE`. Test and enumeration invocations also receive
`TEST_RUNNER_XCSTEWARD_JOB_ID`, `TEST_RUNNER_XCSTEWARD_PROJECT`,
`TEST_RUNNER_XCSTEWARD_PHASE`, and `TEST_RUNNER_XCSTEWARD_MODE`, which
`xcodebuild` forwards to the test runner through the supported
`TEST_RUNNER_` environment mechanism. Manual and hybrid shards additionally get
`XCSTEWARD_SHARD_ID`, `XCSTEWARD_SHARD_INDEX`, `XCSTEWARD_TOTAL_SHARDS`, and
matching `TEST_RUNNER_` variables, with a separate shard `TMPDIR` for each
`test-without-building` process.

Use repeatable `--only-testing <identifier>` and `--skip-testing <identifier>`
submit options to pass Xcode test selection filters. Xcode-managed runs receive
both `-only-testing:` and `-skip-testing:` flags directly. Manual and hybrid
shards use `--only-testing` as the explicit shard input; when no
`--only-testing` filters are provided, XCSteward filters enumerated tests with
`--skip-testing` before splitting shards, then still passes the skip filters to
each shard invocation.

Use repeatable `--only-test-configuration <name>` and
`--skip-test-configuration <name>` submit options to pass test-plan
configuration filters through to Xcode. XCSteward applies those filters to
test enumeration and to every `test-without-building` invocation, including
manual and hybrid shard runs.

The optional `[ports]` block reserves deterministic port ranges for tests that
launch local mock servers. XCSteward does not bind those ports itself; it
injects `XCSTEWARD_PORT_RANGE_*` and matching `TEST_RUNNER_` variables so the
test runner can choose ports from the assigned range. Non-sharded test runs use
range index `0`. Manual and hybrid shards use `base + shard_index * stride`,
and the loader validates that all configured shard ranges fit within TCP port
65535. Use different base ranges for profiles that may run concurrently.

The optional `[privacy]` block applies `xcrun simctl privacy` operations to
each simulator UDID leased by XCSteward before test execution. Use
`grant = ["service:bundle.identifier"]` and
`revoke = ["service:bundle.identifier"]`; use `reset = ["service"]` or
`reset = ["service:bundle.identifier"]`. Supported services match `simctl
privacy`: `all`, `calendar`, `contacts-limited`, `contacts`, `location`,
`location-always`, `photos-add`, `photos`, `media-library`, `microphone`,
`motion`, `reminders`, and `siri`. Manual and hybrid shards apply the same
privacy policy independently to every shard simulator, including temporary
managed clones.

XCSteward enables Xcode's per-test execution allowance flags by default for
`test-without-building`: `-test-timeouts-enabled YES`,
`-default-test-execution-time-allowance 120`, and
`-maximum-test-execution-time-allowance 600`. Configure `[test_timeouts]` to
change those values, or set `enabled = false` to pass
`-test-timeouts-enabled NO` without allowance values.

The optional `[test_retries]` block exposes Xcode's native test repetition
flags for suites that intentionally opt in to flaky-test handling. When enabled,
XCSteward passes `-test-iterations <iterations>` plus either
`-retry-tests-on-failure` or `-run-tests-until-failure`. These retries are
separate from XCSteward's infrastructure retry path; runner/bootstrap failures
are still classified and retried by XCSteward before test retry policy matters.
`retry_tests_on_failure` and `run_tests_until_failure` are mutually exclusive.
Set `relaunch_between_iterations = true` to pass
`-test-repetition-relaunch-enabled YES`; set it to `false` to pass
`-test-repetition-relaunch-enabled NO`. If omitted, XCSteward leaves Xcode's
default repetition process behavior unchanged.

The optional `[test_diagnostics]` block controls Xcode's result-bundle
diagnostic collection policy. Set `collect = "on-failure"` to pass
`-collect-test-diagnostics on-failure`, or `collect = "never"` to pass
`-collect-test-diagnostics never`. If the block is omitted, XCSteward leaves
the scheme/toolchain default unchanged. Manual and hybrid shards receive the
same diagnostic collection flag as non-sharded test runs.

Every terminal job writes `artifacts/run-metadata.json` as an audit manifest.
It includes the job state, result classification, simulator UDID, selected
Xcode version, macOS version, request filters, profile policy, and artifact
paths. This file is intentionally separate from `JobSummary` so existing
summary consumers do not need to migrate.
When XCSteward retries an xcode-managed runner/bootstrap failure, it preserves
the retryable first-attempt `.xcresult` under
`artifacts/attempts/test-attempt-001/` and records it in `run-metadata.json`.
XCSteward also snapshots `xcodebuild -help` into
`artifacts/xcodebuild-help.txt` on a best-effort basis and links it from
`run-metadata.json`. That artifact makes it easier to audit which Xcode flags
the selected toolchain advertised for a run. Best-effort reporting probes that
fail, time out, or produce unparseable output are recorded in
`run-metadata.json` under `probe_warnings` with the probe source, command,
exit code, timeout status, and a bounded output excerpt.

Set `[test_products] enabled = true` to pass `-testProductsPath
<job>/artifacts/test-products.xctestproducts` during `build-for-testing`.
By default, XCSteward still executes with the generated `.xctestrun`, so the
portable test-products bundle is available as an artifact without changing the
runtime contract. Set `use_for_testing = true` to also pass
`-testProductsPath <job>/artifacts/test-products.xctestproducts` to
`test-without-building` instead of `-xctestrun`. `use_for_testing` requires
`enabled = true`. The path is recorded in `artifacts/run-metadata.json` when
Xcode materializes it.

Use serial mode to keep the previous single-worker behavior:

```toml
[parallel]
mode = "serial"
```

Manual sharding is opt-in. XCSteward still builds once, then enumerates tests
from the generated `.xctestrun` or configured `.xctestproducts` path and runs
`shard_count` concurrent `test-without-building` invocations with Xcode inner
parallelism disabled. Each
non-empty shard needs its own simulator UDID from `default_simulator_id`,
`allowed_simulator_ids`, or `--simulator-id`, unless `[managed_simulator]`
enables `clone_for_shards`. With clone provisioning enabled, XCSteward shuts
down the managed template after enumeration, creates temporary `simctl clone`
simulators for missing shard slots, leases them, and deletes only those
temporary clones after the job. Each shard writes its own `.xcresult` under the
job artifacts directory. The job summary keeps the existing schema and points
`artifacts.diagnostics` at
`artifacts/combined-summary.json`. XCSteward also writes the raw per-shard list
to `artifacts/shards.json` for compatibility. Every completed test run also
writes `artifacts/junit.xml` and exposes it as `artifacts.junit` for CI systems
that expect JUnit XML; `.xcresult` bundles remain the source of truth.
When all shards succeed, XCSteward also attempts a best-effort
`xcresulttool merge` into `artifacts/merged.xcresult` and exposes it through
`artifacts.xcresult`; per-shard bundles remain the source of truth if merge is
unavailable or fails.
After a successful shard run, XCSteward records per-test duration samples from
`xcresulttool get test-results tests` when available; later manual and hybrid
runs use those timings to balance shards. If no timing history exists yet,
XCSteward falls back to deterministic round-robin splitting.
If a shard fails before XCTest really gets going, XCSteward retries that shard
once after `simctl shutdown`, `simctl erase`, and a fresh boot of the leased
simulator. The per-shard diagnostics include `attempts`, `retry_reason`, and
`simulator_diagnostics` paths captured with `simctl diagnose -l`. Retryable
first-attempt shard `.xcresult` bundles are preserved under
`artifacts/shards/<shard-id>/attempts/attempt-001/` and linked from each
retried shard's `attempt_artifacts`.

```toml
default_simulator_id = "SIM-123"
allowed_simulator_ids = ["SIM-123", "SIM-456"]

[parallel]
mode = "manual-shards"
shard_count = 2
```

Hybrid mode uses the same outer sharding model, but each shard keeps
Xcode-managed inner parallelism enabled using `max_workers` and
`exact_workers`:

```toml
[parallel]
mode = "hybrid"
shard_count = 2
max_workers = 2
exact_workers = false
```

Managed simulator example:

```toml
repo_root = "/absolute/path/to/repo"
project_path = "App.xcodeproj"
scheme = "App"

[managed_simulator]
name = "App Test iPhone 17 Pro"
device_type = "iPhone 17 Pro"
runtime = "iOS 26.4"
clone_for_shards = true
```

Sample dogfood profiles are under [Examples/profiles](Examples/profiles).
Agent workflow examples are under [Examples/agents](Examples/agents).
A minimal runnable iOS fixture is under [Examples/DemoApp](Examples/DemoApp);
copy [demo-app.toml.template](Examples/profiles/demo-app.toml.template)
into your state root with `__XCSTEWARD_REPO_ROOT__` replaced by this repository
path to exercise the documented `doctor` and `submit --wait --json` flow.

## Known limitations

XCSteward is host-local. The queue, worker lease, simulator lease, and artifact
state live under one state root on one Mac; distributed worker coordination is
out of scope today.

The public alpha is intended for recent local Xcode installs and local iOS
Simulator execution only. Older Xcode versions, unusual toolchain selections,
beta simulator runtimes, and CI-hosted macOS images may work, but they are not
yet part of the supported range until they have live dogfood coverage.

Native macOS app destinations are post-alpha roadmap work. Profiles currently
target iOS Simulator execution rather than `-destination platform=macOS`; run
native macOS app tests with direct `xcodebuild -destination platform=macOS`
until XCSteward adds a simulator-free destination path. Mac-only schemes are
reported as `unsupported_destination` instead of being run against a simulator.

XCSteward depends on local Xcode and CoreSimulator behavior. It can recover
from stale XCSteward-owned leases and targeted simulator failures, but broad
host repair still requires an operator decision. `doctor --fix` is
XCSteward-scoped by default, and global CoreSimulator cleanup requires
`doctor --fix-global --dangerously-confirm-global-coresimulator-cleanup`.

Artifacts are preserved for completed jobs, and retry attempts preserve their
own attempt-specific bundles. The `cleanup` command provides conservative
age-based terminal-job cleanup and optional total-size budgeting for terminal
jobs under the XCSteward state root. Hosts still need disk monitoring for
non-XCSteward storage and protected active jobs.

`--json` result output is structured and stable enough for agents. Agents
should parse stdout for loaded command results and stderr for command error
documents, while still using the process exit code for the top-level outcome.

Manual and hybrid sharding still rely on test enumeration and Xcode result
tooling. If those tools change shape or fail, XCSteward records best-effort
diagnostics but may need follow-up fixes for new Xcode releases.

Concurrent dispatch and shared-Mac use are still alpha surfaces. Leave
`XCSTEWARD_MAX_CONCURRENT_JOBS` unset unless you have run the hardening matrix
and a live smoke test on that host.
