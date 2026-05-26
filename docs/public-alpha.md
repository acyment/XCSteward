# Public Alpha Runbook

This runbook defines the narrow supported path for the public alpha. It is
intended to be boring: install from source, verify the host, run one configured
project, inspect artifacts, and know which limitations are expected.

## Supported Alpha Scope

XCSteward alpha supports local serialized iOS Simulator test execution on one
Mac at a time. Serialized execution is the safe default. Xcode-managed
parallelism, manual sharding, and multi-job dispatch are available for dogfood,
but should be treated as experimental until the target host has passed the
hardening matrix and a live smoke run.

Native macOS app schemes and direct `-destination platform=macOS` execution are
outside public-alpha support. Use direct `xcodebuild -destination platform=macOS`
for native macOS app tests until XCSteward adds a simulator-free destination
path after the simulator-only alpha is validated.

Supported host assumptions:

- macOS 13 or newer.
- Swift 6 toolchain.
- A full Xcode.app selected with `xcode-select`.
- An installed iOS Simulator runtime compatible with the selected Xcode's
  `iphonesimulator` SDK.
- A writable XCSteward state root outside protected system paths.

Before using XCSteward on a real project, run:

```bash
xcsteward doctor --json
```

Fix failed checks before submitting jobs. Warnings are acceptable only when the
manual action is understood, for example known disk pressure or intentionally
experimental xcode-managed parallelism.

## Install From Source

```bash
swift build -c release
mkdir -p "$HOME/.local/bin"
cp .build/release/xcsteward "$HOME/.local/bin/xcsteward"
export PATH="$HOME/.local/bin:$PATH"
xcsteward --help
```

Use `XCSTEWARD_HOME` or `--state-root` to isolate alpha state:

```bash
export XCSTEWARD_HOME="$HOME/.xcsteward-alpha"
mkdir -p "$XCSTEWARD_HOME/projects"
```

## Quickstart With The Demo App

```bash
STATE_ROOT="${XCSTEWARD_HOME:-$HOME/.xcsteward-alpha}"
mkdir -p "$STATE_ROOT/projects"
sed "s#__XCSTEWARD_REPO_ROOT__#$(pwd)#g" \
  Examples/profiles/demo-app.toml.template \
  > "$STATE_ROOT/projects/demo-app.toml"

xcsteward --state-root "$STATE_ROOT" doctor --project demo-app
xcsteward --state-root "$STATE_ROOT" submit --project demo-app --wait --wait-timeout 300 --json
```

For long-running JSON commands, add `--progress` to receive compact JSON-lines
progress events on stderr while keeping stdout reserved for the final JSON
object:

```bash
xcsteward --state-root "$STATE_ROOT" doctor --project demo-app --json --progress
xcsteward --state-root "$STATE_ROOT" submit --project demo-app --wait --wait-timeout 300 --json --progress
```

The demo profile uses a managed simulator. If the configured runtime or device
type is not installed on the host, edit the profile to match an available
runtime from:

```bash
xcrun simctl list runtimes available
xcrun simctl list devicetypes
```

## Real Project Profile

Create `$XCSTEWARD_HOME/projects/app.toml`:

```toml
repo_root = "/absolute/path/to/repo"
workspace_path = "App.xcworkspace"
scheme = "App"
default_simulator_id = "SIMULATOR-UDID"

[parallel]
mode = "serial"
max_workers = 1

[timeouts]
boot = 120
build = 600
test = 600

[destination]
timeout = 120
```

Prefer `mode = "serial"` for first use. Increase worker counts only after
`doctor` passes and a live smoke job succeeds on the target host.

## Agent Workflow

Agents should submit, poll, and report artifact paths rather than rerunning
raw `xcodebuild` immediately. See:

- `Examples/agents/codex.md`
- `Examples/agents/claude-code.md`
- `Examples/agents/cursor.md`

Minimal loop:

```bash
summary="$(xcsteward submit --project app --json)"
job_id="$(printf '%s\n' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')"
xcsteward status "$job_id" --json
xcsteward artifacts "$job_id" --json
xcsteward logs "$job_id"
```

## Release Gate Before Tagging Alpha

Run the fake-tool release test tier and keep the suite-health report:

```bash
bash scripts/run-test-suite.sh --tier release --continue-on-failure \
  --report .build/test-suite/public-alpha-fake.json
```

Run the fake-tool hardening matrix:

```bash
bash scripts/run-hardening-matrix.sh --continue-on-failure \
  --report .build/hardening-matrix/public-alpha-fake.json
```

For one-off targeted verification outside the matrix, use the checked wrapper
instead of raw `swift test --filter`:

```bash
bash scripts/run-swift-test-filter.sh --filter DoctorProjectPreflightCommandTests/testDoctorFailsWhenNoRunnableIOSSimulatorDestinationExists
```

Run the live row on the intended support host:

```bash
XCSTEWARD_LIVE_SIMULATOR_ID=<simulator-udid> \
XCSTEWARD_LIVE_WAIT_TIMEOUT=300 \
bash scripts/run-hardening-matrix.sh --include-live \
  --report .build/hardening-matrix/public-alpha-live.json
```

Also record a live suite-health artifact for the same support host:

```bash
XCSTEWARD_LIVE_SIMULATOR_ID=<simulator-udid> \
XCSTEWARD_LIVE_WAIT_TIMEOUT=300 \
bash scripts/run-test-suite.sh --tier live \
  --report .build/test-suite/public-alpha-live.json
```

The live row is intentionally opt-in because it uses a real Xcode project,
real simulator runtime, and real `.xcresult` generation.
The fake reports and live reports are separate on purpose; a green fake suite
does not count as live Xcode coverage. Release notes should link or name both
fresh report paths and call out skipped live coverage if the live report is
missing.

The live suite log includes an `XCSTEWARD_LIVE_SMOKE_EVIDENCE` line with the
state root, job ID, summary, run metadata, `.xcresult`, test count, and
probe-warning count for the live XCSteward job.

## Known Limitations

- Public alpha is local-only and iOS Simulator-only. Multi-host scheduling is
  out of scope.
- Native macOS app destinations are post-alpha roadmap work; profiles currently
  target iOS Simulator execution rather than `-destination platform=macOS`.
  Run native macOS app tests with direct `xcodebuild -destination platform=macOS`
  until XCSteward adds a simulator-free destination path. Mac-only schemes are
  reported as `unsupported_destination` instead of being run against a simulator.
- Serialized simulator execution is the supported default.
- Xcode-managed parallelism can create clone simulators that doctor cannot
  fully preflight; use it only after a live smoke pass.
- Shared-Mac/team workflows are experimental.
- The supported Xcode/macOS range is intentionally narrow and should be
  expanded only with dogfood evidence.
- `doctor --fix` is narrow by default. Broad CoreSimulator cleanup requires
  both `--fix-global` and
  `--dangerously-confirm-global-coresimulator-cleanup`.
- Low disk space can still make real Xcode runs flaky; doctor warns before
  long simulator jobs and points operators to a dry-run XCSteward cleanup report
  before any preserved evidence is deleted.
- The CLI is the product surface. No dashboard or hosted service is included
  in the public alpha.

## Uninstall And Cleanup

Remove the binary:

```bash
rm "$HOME/.local/bin/xcsteward"
```

Remove only XCSteward-managed state:

```bash
rm -rf "${XCSTEWARD_HOME:-$HOME/Library/Application Support/XCSteward}"
```

Do not delete global CoreSimulator state as part of uninstalling XCSteward.
