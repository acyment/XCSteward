<div align="center">
<img alt="XCSteward" src="assets/logo.svg" width="140">
<h1>XCSteward</h1>
<p><strong>Queue, run, and inspect iOS simulator tests — without simulator collisions, lost artifacts, or mystery failures.</strong></p>
<p>
<a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License"></a>
<a href=""><img src="https://img.shields.io/badge/platform-macOS%2013+-silver.svg" alt="macOS"></a>
<a href=""><img src="https://img.shields.io/badge/version-v0.1.0--alpha-orange.svg" alt="Version"></a>
</p>
</div>

XCSteward is a local-first macOS CLI for iOS development environments where humans, scripts, and coding agents can collide over the same simulator state.

It serializes `xcodebuild` jobs through a lease-backed queue, isolates every job's DerivedData, logs, `.xcresult`, and structured JSON summaries, and gives both humans and agents a stable contract for running simulator tests without scraping walls of text.

> Requires: Swift 6 · Xcode 16+ · macOS 13+

## What it does

- Queues simulator test jobs instead of letting agents call `xcodebuild` directly
- Runs one controlled simulator job at a time
- Isolates DerivedData, logs, `.xcresult`, and JSON summaries per job
- Gives humans and agents a stable CLI contract for test execution

## The problem

iOS simulator test execution was designed for one human at a time:

```bash
xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 16' ...
```

Point, run, done. But modern workflows run multiple coding agents in parallel
— one on the login flow, one fixing a flaky snapshot test, one upgrading a
dependency. When two agents hit the same simulator:

| Symptom | Why |
| --- | --- |
| Simulator boots and shuts down under competing requests | Neither agent owns the device |
| `xcodebuild -showdestinations` returns placeholder-only output | Xcode can't enumerate a busy simulator |
| "Simulator is already in use" error | Race condition, not a simulator bug |
| Tests pass locally but fail on CI with no evidence | No artifacts preserved, no timeline |

> This is not a simulator bug. It's a scheduling problem that raw `xcodebuild`
> doesn't solve.

XCSteward turns that single-user model into a multi-agent queue:

1. Each agent submits a job
2. The queue serializes access to the shared simulator pool
3. Every job runs to completion with isolated DerivedData, preserved artifacts,
   and a deterministic result

Agents no longer trip over each other's simulator state.

## Install

### Homebrew

```bash
brew tap acyment/tap
brew install xcsteward
```

Verify:

```bash
xcsteward --help
xcsteward doctor --json
```

### From source

Requires Swift 6 and Xcode 16 or newer.

```bash
git clone https://github.com/acyment/XCSteward.git
cd XCSteward
swift build -c release
mkdir -p "$HOME/.local/bin"
cp .build/release/xcsteward "$HOME/.local/bin/xcsteward"
```

Add to PATH if needed:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The default state root is `~/Library/Application Support/XCSteward`. Override
per command with `--state-root <path>` or set `XCSTEWARD_HOME=<path>`.

## Quickstart

Create a project profile under the state root:

```bash
STATE_ROOT="${XCSTEWARD_HOME:-$HOME/Library/Application Support/XCSteward}"
mkdir -p "$STATE_ROOT/projects"
cp Examples/profiles/demo-app.toml.template "$STATE_ROOT/projects/demo-app.toml"
perl -pi -e "s#__XCSTEWARD_REPO_ROOT__#$PWD#g" "$STATE_ROOT/projects/demo-app.toml"
xcsteward doctor --project demo-app
xcsteward submit --project demo-app --wait --json
```

For long-running JSON commands, add `--progress` to stream compact events on
stderr while stdout stays reserved for the final JSON object:

```bash
xcsteward doctor --project demo-app --json --progress
xcsteward submit --project demo-app --wait --json --progress
```

For a real app, replace the template with a profile pointing at your repo,
scheme, and simulator UDID:

```toml
repo_root = "/absolute/path/to/repo"
workspace_path = "App.xcworkspace"
scheme = "App"
default_simulator_id = "SIM-UDID"
```

After a terminal job, inspect the evidence:

```bash
xcsteward artifacts <job-id> --json
xcsteward logs <job-id>
```

Agent workflow examples are in [Examples/agents](Examples/agents).

## Commands

```bash
# Submit
xcsteward submit --project <name> [--wait] [--wait-timeout 300] [--json]
xcsteward submit --project <name> --only-testing AppTests/FooTests --skip-testing AppTests/FooTests/testFlaky --wait
xcsteward submit --project <name> --only-test-configuration Smoke --skip-test-configuration Flaky --wait

# Inspect
xcsteward status <job-id> [--json]
xcsteward jobs [--json]
xcsteward logs <job-id>
xcsteward artifacts <job-id> [--json]
xcsteward cancel <job-id> [--json]

# Maintenance
xcsteward doctor [--project <name>] [--fix] [--fix-global --dangerously-confirm-global-coresimulator-cleanup] [--json]
xcsteward cleanup [--dry-run] [--apply] [--older-than 7d] [--keep-last 20] [--max-total-size 50gb] [--json]
```

`cleanup` is dry-run by default. It selects terminal jobs under `jobs/`, keeps
the newest, skips active leases and live PIDs, and respects `--max-total-size`.
Use `--apply` to delete.

`doctor` reports stale worker and simulator leases. `--fix` removes leases
owned by dead XCSteward processes without touching active ones. Broad
CoreSimulator cleanup requires `--fix-global` plus the danger confirmation flag.

## API

Commands with `--json` write one JSON document to stdout. Some return nonzero
exit codes after printing JSON — for example `status --json` on a failed job
or `doctor --json` when a required check fails. When `--json` is present but
the command fails before loading its object, XCSteward writes one JSON error to
stderr and leaves stdout empty:

```json
{
  "error": {
    "code": "usage",
    "message": "submit requires --project"
  }
}
```

Stable error codes: `usage`, `not_found`, `invalid_configuration`,
`command_failed`, `canceled`, `unexpected_error`.

### Job summary

`submit --json`, `submit --wait --json`, `status --json`, and `cancel --json`:

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

Stable states: `queued`, `running`, `succeeded`, `failed`, `canceled`,
`interrupted`. Stable result classes: `success`, `build_failure`,
`test_failure`, `test_timeout`, `runner_bootstrap_failure`,
`artifact_failure`, `canceled`, `internal_error`. Timestamps are Unix epoch
seconds. Nullable fields are present even when unknown.

### Jobs list

`jobs --json` returns an array of compact objects:

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

### Artifacts

`artifacts --json` returns the `artifacts` object from the terminal job
summary. Paths are absolute local filesystem paths and can be `null` when not
produced.

### Cleanup report

`cleanup --json` returns:

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

Candidate reasons: `age`, `size_budget`. `bytes` is best-effort allocated disk
usage with logical file size as fallback. `max_total_bytes` is `null` when not
supplied.

### Doctor report

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

Doctor statuses: `pass`, `warn`, `fail`. Agents should treat unknown future
fields as additive, preserve the full JSON in logs, and make control-flow
decisions from `state`, `result_class`, `overall_status`, `dry_run`,
`candidate_count`, and `deleted_count`.

### Environment overrides

Use `--state-root <path>` for a specific state directory. Default:
`~/Library/Application Support/XCSteward`.

Set `XCSTEWARD_MAX_CONCURRENT_JOBS=<n>` to allow up to `n` queued jobs at once.
Default is `1`. Concurrent jobs still require distinct simulator UDIDs — each
is leased exclusively.

When concurrency is enabled, XCSteward writes a `host-health.json` snapshot and
reduces dispatch to one job when health signals indicate constrained capacity.
Supported environment inputs:

| Variable | Behavior |
| --- | --- |
| `XCSTEWARD_MEMORY_PRESSURE` | Injected memory pressure level |
| `XCSTEWARD_SAMPLE_MEMORY_PRESSURE` | Sample macOS `memory_pressure`; reduces dispatch on warning/serious/critical |
| `XCSTEWARD_THERMAL_STATE` | Injected thermal state |
| `XCSTEWARD_SAMPLE_THERMAL_STATE` | Sample `pmset -g therm`; reduces dispatch on serious/critical CPU throttling |
| `XCSTEWARD_MAX_LOAD_AVERAGE` | Reduce dispatch when 1-minute load reaches threshold |
| `XCSTEWARD_LOAD_AVERAGE` | Override sampled load average |
| `XCSTEWARD_MAX_BOOTED_SIMULATORS` | Cap booted simulators |
| `XCSTEWARD_BOOTED_SIMULATOR_COUNT` | Override booted count |
| `XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES` | Cap simulator lease pressure independently from job count |
| `XCSTEWARD_FOREIGN_ACTIVITY_POLICY` | `capacity` (default), `strict`, or `ignore` for non-XCSteward xcodebuild activity |
| `XCSTEWARD_RECENT_INFRA_FAILURE_LIMIT` + `XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS` | Drain gate |
| `XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT` | Write `draining=true` and stop dispatch when reached |

Recovered runner/bootstrap incidents (including shard retries that ultimately
succeed) count as recent infrastructure failures for the capacity gate.

## Profile configuration

Profiles live under `<state-root>/projects/<name>.toml`.

### Minimal

```toml
repo_root = "/absolute/path/to/repo"
project_path = "App.xcodeproj"
scheme = "App"
default_simulator_id = "SIM-UDID"
```

Set exactly one of `project_path` or `workspace_path`. `repo_root` and `scheme`
are required. A simulator comes from `default_simulator_id`, an allowed
`--simulator-id` override, or a `[managed_simulator]` block.

Create and verify:

```bash
STATE_ROOT="${XCSTEWARD_HOME:-$HOME/Library/Application Support/XCSteward}"
mkdir -p "$STATE_ROOT/projects"
$EDITOR "$STATE_ROOT/projects/demo.toml"
xcsteward doctor --project demo
xcsteward submit --project demo --wait --wait-timeout 300 --json
```

### Full example

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
timeout = 30

[coverage]
enabled = true

[result_stream]
enabled = false

[result_bundle]
version = 3

[parallel]
mode = "xcode-managed"
max_workers = 1
exact_workers = false
shard_count = 1

[ports]
base = 51000
count = 16
stride = 100

[test_timeouts]
enabled = true
default_execution_time_allowance = 120
maximum_execution_time_allowance = 600

[test_retries]
enabled = false
iterations = 1
retry_tests_on_failure = true
run_tests_until_failure = false
relaunch_between_iterations = false

[test_diagnostics]
collect = "on-failure"

[test_products]
enabled = false
use_for_testing = false

[privacy]
reset = ["all"]
grant = ["photos:com.example.App", "location:com.example.App"]
revoke = ["microphone:com.example.App"]

[env]
FOO = "bar"
```

### Parallel modes

Defaults: `mode = "xcode-managed"`, `max_workers = 1`, `exact_workers = false`.
XCSteward lets Xcode manage test workers during `test-without-building`.
Each job records an exclusive simulator lease; stale leases from dead processes
are recovered before the next job. Active jobs refresh lease heartbeats during
long build/test phases.

Use higher `max_workers` only after a live smoke job proves Xcode clone
simulator launches are stable on the host. Targeted single-method submissions
serialize automatically unless `exact_workers = true`.

Serial mode for single-worker behavior:

```toml
[parallel]
mode = "serial"
```

### Manual sharding

Opt-in. XCSteward builds once, enumerates tests, then runs `shard_count`
concurrent `test-without-building` invocations with Xcode inner parallelism
disabled. Each non-empty shard needs its own simulator UDID unless
`[managed_simulator]` enables `clone_for_shards`.

With clone provisioning, XCSteward shuts down the managed template after
enumeration, creates temporary `simctl clone` simulators for missing shard
slots, leases them, and deletes only those temporary clones after the job.
Each shard writes its own `.xcresult`.

When all shards succeed, XCSteward attempts best-effort `xcresulttool merge`
into `artifacts/merged.xcresult`. Per-shard bundles remain the source of truth
if merge fails.

After a successful shard run, XCSteward records per-test duration samples;
later manual and hybrid runs use those timings to balance shards. If no timing
history exists, it falls back to round-robin splitting.

If a shard fails before XCTest starts, XCSteward retries once after
`simctl shutdown`, `simctl erase`, and fresh boot. Per-shard diagnostics
include `attempts`, `retry_reason`, and `simulator_diagnostics` paths.

```toml
default_simulator_id = "SIM-123"
allowed_simulator_ids = ["SIM-123", "SIM-456"]

[parallel]
mode = "manual-shards"
shard_count = 2
```

### Hybrid mode

Outer sharding with Xcode-managed inner parallelism:

```toml
[parallel]
mode = "hybrid"
shard_count = 2
max_workers = 2
exact_workers = false
```

### Managed simulator

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

### Reference

- `reset_policy`: `none` (default), `shutdown`, or `erase`. Cleans only
  XCSteward-leased simulators after a job. Retry recovery still uses targeted
  shutdown/erase on infrastructure failures.
- `[destination]`: passes `-destination-timeout <seconds>` to destination-bearing
  `xcodebuild` invocations. Omit to leave Xcode's default.
- `[coverage]`: passes `-enableCodeCoverage YES|NO` to `build-for-testing` and
  every `test-without-building`. Applied to both phases because coverage is
  decided during build.
- `[result_stream]`: when `enabled = true`, pre-creates the stream file and
  passes `-resultStreamPath`.
- `[result_bundle]`: passes `-resultBundleVersion <version>` to every
  `test-without-building` that writes `.xcresult`.
- Environment variables: every `xcodebuild` gets `XCSTEWARD_JOB_ID`,
  `XCSTEWARD_PROJECT`, `XCSTEWARD_PHASE`, and run-scoped `TMPDIR`. Test
  invocations also get `TEST_RUNNER_*` variants. Manual/hybrid shards get
  `XCSTEWARD_SHARD_ID`, `XCSTEWARD_SHARD_INDEX`, `XCSTEWARD_TOTAL_SHARDS`,
  and matching `TEST_RUNNER_*` variables with separate shard `TMPDIR`.
- `--only-testing` / `--skip-testing`: passed directly to Xcode-managed runs.
  Manual/hybrid shards use `--only-testing` as explicit shard input; when none
  provided, enumerated tests are filtered with `--skip-testing` before
  splitting, then skip filters pass to each shard.
- `--only-test-configuration` / `--skip-test-configuration`: passed through to
  Xcode on enumeration and every `test-without-building` invocation.
- `[ports]`: reserves deterministic port ranges. Injects `XCSTEWARD_PORT_RANGE_*`
  and matching `TEST_RUNNER_*` variables. Non-sharded runs use index `0`.
  Manual/hybrid shards use `base + shard_index * stride`. Validated to fit
  within TCP port 65535.
- `[privacy]`: applies `xcrun simctl privacy` to each leased simulator before
  tests. Supported services: `all`, `calendar`, `contacts-limited`, `contacts`,
  `location`, `location-always`, `photos-add`, `photos`, `media-library`,
  `microphone`, `motion`, `reminders`, `siri`. Applied independently to every
  shard simulator including temporary managed clones.
- `[test_timeouts]`: defaults shown above. Set `enabled = false` to pass
  `-test-timeouts-enabled NO`. Defaults: `-test-timeouts-enabled YES`,
  `-default-test-execution-time-allowance 120`,
  `-maximum-test-execution-time-allowance 600`.
- `[test_retries]`: opt-in Xcode native repetition. Passes
  `-test-iterations <iterations>` plus `-retry-tests-on-failure` or
  `-run-tests-until-failure`. Separate from XCSteward's infrastructure retry
  path. `retry_tests_on_failure` and `run_tests_until_failure` are mutually
  exclusive. `relaunch_between_iterations` passes
  `-test-repetition-relaunch-enabled YES/NO`.
- `[test_diagnostics]`: `collect = "on-failure"` or `"never"`. Omit to leave
  scheme default.
- `run-metadata.json`: audit manifest written by every terminal job. Includes
  job state, result classification, simulator UDID, selected Xcode/macOS
  versions, request filters, profile policy, and artifact paths.
- Retry preservation: when XCSteward retries a runner/bootstrap failure, the
  first-attempt `.xcresult` is preserved under
  `artifacts/attempts/test-attempt-001/` and recorded in `run-metadata.json`.
- `xcodebuild-help.txt`: best-effort snapshot of `xcodebuild -help`, linked from
  `run-metadata.json`. Failed/timed-out probes are recorded under
  `probe_warnings` with source, command, exit code, timeout status, and bounded
  output excerpt.
- `[test_products]`: `enabled = true` passes `-testProductsPath` during
  `build-for-testing`. Default execution still uses `.xcctestrun`. Set
  `use_for_testing = true` to also pass it to `test-without-building` instead
  of `-xctestrun`. Requires `enabled = true`.

## Development

Run tests:

```bash
swift test
```

Fast tier for the refactor loop (writes suite-health JSON to
`.build/test-suite/`):

```bash
bash scripts/run-test-suite.sh --tier fast
```

Release tier before shipping (keep the report with hardening-matrix and
dogfood artifacts):

```bash
bash scripts/run-test-suite.sh --tier release --continue-on-failure \
  --report .build/test-suite/public-alpha-fake.json
```

Targeted verification with checked filter wrapper (prevents stale `--filter`
from passing as a zero-test run):

```bash
bash scripts/run-swift-test-filter.sh --filter SubmitCommandE2ETests/testSubmitWaitSuccessCreatesArtifactsAndStructuredSummary
```

Opt-in live Xcode-managed parallel smoke test against a real simulator:

```bash
XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 \
XCSTEWARD_LIVE_SIMULATOR_ID=<simulator-udid> \
swift test --filter LiveXcodeManagedParallelSmokeTests
```

By default this generates a tiny Swift package and runs it through XCSteward
with `parallel.mode = "xcode-managed"` and `exact_workers = true` (worker
count 2). To point at an existing project, also set `XCSTEWARD_LIVE_REPO_ROOT`,
`XCSTEWARD_LIVE_SCHEME`, and optionally `XCSTEWARD_LIVE_PROJECT_PATH` or
`XCSTEWARD_LIVE_WORKSPACE_PATH`.

Run the built binary:

```bash
./.build/arm64-apple-macosx/debug/xcsteward doctor --json
```

## Scope

> [!NOTE]
> XCSteward is public-alpha software. Use it first on disposable or low-risk
> local state and keep raw `xcodebuild` as the fallback.

| Category | Detail |
| --- | --- |
| **Supported** | Local Apple Silicon or Intel Mac, macOS 13+, Swift 6, Xcode 16+ selected by `xcode-select`, iOS Simulator execution, serialized local jobs |
| **Experimental** | Xcode-managed parallelism, manual sharding, multi-job dispatch, shared-Mac operation. Require explicit opt-in and passed live dogfood run on target host |
| **Out of scope** | Native macOS app destinations (`-destination platform=macOS`), multi-host scheduling, hosted dashboards. Native macOS support is post-alpha roadmap work |

XCSteward is host-local. Queue, worker lease, simulator lease, and artifact
state live under one state root on one Mac. Distributed coordination is out of
scope today.

The public alpha targets recent local Xcode installs and local iOS Simulator
execution. Older Xcode versions, unusual toolchain selections, beta simulator
runtimes, and CI-hosted macOS images may work but are not in the supported
range until they have live dogfood coverage.

Native macOS app destinations are post-alpha. Profiles target iOS Simulator
execution; run native macOS app tests with direct
`xcodebuild -destination platform=macOS` until XCSteward adds a simulator-free
path. Mac-only schemes return `unsupported_destination` instead of being run
against a simulator.

XCSteward recovers from stale XCSteward-owned leases and targeted simulator
failures, but broad host repair requires an operator decision. `doctor --fix`
is XCSteward-scoped by default. Global CoreSimulator cleanup requires
`doctor --fix-global --dangerously-confirm-global-coresimulator-cleanup`.

Artifacts are preserved for completed jobs; retry attempts preserve their own
attempt-specific bundles. The `cleanup` command provides conservative age-based
terminal-job cleanup and optional total-size budgeting. Hosts still need disk
monitoring for non-XCSteward storage and protected active jobs.

`--json` output is structured and stable enough for agents. Parse stdout for
loaded command results and stderr for command error documents; use the process
exit code for the top-level outcome.

Manual and hybrid sharding rely on test enumeration and Xcode result tooling.
If those tools change or fail, XCSteward records best-effort diagnostics but
may need follow-up fixes for new Xcode releases.

Concurrent dispatch and shared-Mac use are still alpha surfaces. Leave
`XCSTEWARD_MAX_CONCURRENT_JOBS` unset unless you have run the hardening matrix
and a live smoke test on that host.

## Links

| Resource | Path |
| --- | --- |
| Operator runbook | [docs/public-alpha.md](docs/public-alpha.md) |
| Hardening matrix | [docs/hardening-matrix.md](docs/hardening-matrix.md) |
| Live dogfood evidence | [docs/dogfood-ledger.md](docs/dogfood-ledger.md) |
| Agent workflow examples | [Examples/agents](Examples/agents) |
| Sample profiles | [Examples/profiles](Examples/profiles) |
| Demo iOS fixture | [Examples/DemoApp](Examples/DemoApp) |

## Uninstall

### Homebrew

```bash
brew uninstall xcsteward
brew untap acyment/tap
```

### Manual install

Remove the binary:

```bash
rm "$HOME/.local/bin/xcsteward"
```

Clean old terminal jobs without touching active or non-XCSteward state:

```bash
xcsteward cleanup --dry-run --older-than 7d --keep-last 20 --max-total-size 50gb --json
xcsteward cleanup --apply --older-than 7d --keep-last 20 --max-total-size 50gb --json
```

Remove all XCSteward-local state after stopping active workers:

```bash
rm -rf "$HOME/Library/Application Support/XCSteward"
```

If you used `XCSTEWARD_HOME` or `--state-root`, remove that directory instead.
Do not delete global CoreSimulator state as part of uninstalling XCSteward.
