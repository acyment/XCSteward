# XCSteward

Local macOS CLI for coordinating iOS simulator test jobs across projects and coding agents.

## Commands

Build:

```bash
swift test
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
xcsteward submit --project <name> [--wait] [--json]
xcsteward submit --project <name> --only-testing AppTests/FooTests --skip-testing AppTests/FooTests/testFlaky --wait
xcsteward submit --project <name> --only-test-configuration Smoke --skip-test-configuration Flaky --wait
xcsteward status <job-id> [--json]
xcsteward jobs [--json]
xcsteward logs <job-id>
xcsteward artifacts <job-id> [--json]
xcsteward cancel <job-id> [--json]
xcsteward doctor [--project <name>] [--fix] [--json]
```

`doctor` reports stale worker and simulator lease records. With `--fix`, it
removes simulator leases owned by dead XCSteward processes without touching
active leases.

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
explicit value and takes precedence over sampling.
Set `XCSTEWARD_SAMPLE_THERMAL_STATE=true` to sample `pmset -g therm` and reduce
dispatch to one job when CPU thermal throttling maps to serious or critical
state. `XCSTEWARD_THERMAL_STATE` can still inject an explicit value and takes
precedence over sampling.
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
boot = 30
build = 600
test = 600

[destination]
# Optional xcodebuild destination wait cap in seconds.
timeout = 30

[coverage]
# Optional xcodebuild code coverage override. Omit the block to let the scheme decide.
enabled = true

[result_stream]
# Optional xcodebuild result stream artifact for test runs.
enabled = false

[result_bundle]
# Optional xcodebuild result bundle format version for test result bundles.
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
enabled = false
# Also pass -testProductsPath to test-without-building instead of -xctestrun.
use_for_testing = false

[privacy]
# Optional simctl privacy setup for each leased simulator before tests run.
reset = ["all"]
grant = ["photos:com.example.App", "location:com.example.App"]
revoke = ["microphone:com.example.App"]

[env]
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
XCSteward also snapshots `xcodebuild -help` into
`artifacts/xcodebuild-help.txt` on a best-effort basis and links it from
`run-metadata.json`. That artifact makes it easier to audit which Xcode flags
the selected toolchain advertised for a run.

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
`simulator_diagnostics` paths captured with `simctl diagnose -l`.

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

Sample dogfood profiles are under [Examples/profiles](/Users/acyment/dev/XCSteward/Examples/profiles).
