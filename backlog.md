# XCSteward Backlog

## Pending

### High-ROI refactor opportunities

- [ ] Split `DoctorEngine` into focused check groups and shared probe helpers.
  - `Sources/XCStewardKit/Doctor.swift`
  - Evidence: the file is 2,010 lines with the highest source branch density found in the Swift sources; it mixes check registration, Xcode/CoreSimulator probes, JSON parsing, path safety, disk checks, and report construction.
  - Target slice: move global Xcode environment checks, CoreSimulator checks, project preflight checks, and shared `DoctorCheck` construction/probe result handling into focused types while keeping check IDs and output stable.
  - ROI: every new doctor check currently increases risk in one large file; this should reduce merge conflicts and make targeted tests such as `DoctorCommandTests` and `DoctorCheckRegistryTests` cheaper to reason about.

- [ ] Factor shared xcodebuild attempt, retry, and artifact-preservation flow.
  - `Sources/XCStewardKit/Executor.swift`
  - `Sources/XCStewardKit/ManualShardRunner.swift`
  - `Sources/XCStewardKit/ExecutionSupport.swift`
  - Evidence: xcode-managed tests and manual shards both remove result bundles, run xcodebuild, classify outcomes, preserve first-attempt artifacts, record diagnostics, recover simulators, and retry bootstrap/artifact failures.
  - Target slice: introduce a small attempt runner/result object used by both single-run and shard-run paths; keep manual shard scheduling separate.
  - ROI: retry, cancellation, diagnostics, and artifact semantics are high-risk behavior, and duplicated flow makes fixes easy to apply to only one execution mode.

- [ ] Move CLI command parsers/handlers behind a command table.
  - `Sources/XCStewardKit/App.swift`
  - Evidence: `XCStewardApp` still owns top-level dispatch, help text, option parsing, stdout formatting, worker spawning, cancellation, status, and artifacts.
  - Target slice: move command parsers/handlers behind a command table now that cleanup selection/deletion lives in `CleanupService`.
  - ROI: command parsing can be tested without exercising the full CLI surface, and new commands will stop increasing the size of the app entry point.

- [ ] Break the embedded fake tool scripts into scenario-oriented fixtures.
  - `Tests/XCStewardKitTests/FakeToolFixtures.swift`
  - Evidence: the file is 973 lines, with a single embedded fake-tool script block accounting for most branch-heavy test fixture logic.
  - Target slice: split `xcodebuild`, `xcrun`, `ps`, and host-capacity fake tools into separate fixture builders or script assets, and centralize scenario names/capabilities.
  - ROI: most E2E changes depend on these fixtures; smaller fixtures should make failures easier to localize and reduce accidental scenario coupling.

- [ ] Split `EndToEndCommandTests` by workflow using the existing `E2EScenario` helper.
  - `Tests/XCStewardKitTests/EndToEndCommandTests.swift`
  - `Tests/XCStewardKitTests/E2ECommandTestSupport.swift`
  - Evidence: the file is 4,145 lines and covers submit/status/artifacts, managed simulators, manual shards, retry behavior, worker parallelism, cancellation, cleanup, and host backpressure in one suite.
  - Target slice: move tests into focused files such as submit/artifacts, simulator management, manual shards, worker scheduling, cancellation, and cleanup while preserving helper APIs.
  - ROI: low behavior risk with immediate payoff in reviewability, targeted test runs, and conflict reduction.

## Completed

All initial hardening items are complete.

### High-ROI refactors

- [x] Extract typed Doctor CoreSimulator probe parsing.
  - `Sources/XCStewardKit/Doctor.swift`
  - `Sources/XCStewardKit/CoreSimulatorProbeModels.swift`
  - `Tests/XCStewardKitTests/CoreSimulatorProbeModelsTests.swift`
  - Introduced `Decodable` probe response models for `simctl list runtimes --json` and `simctl list devices --json`, then moved runtime/device availability decisions out of raw `[String: Any]` indexing.

- [x] Extract cleanup selection/deletion policy from `XCStewardApp`.
  - `Sources/XCStewardKit/App.swift`
  - `Sources/XCStewardKit/CleanupService.swift`
  - `Tests/XCStewardKitTests/CleanupCommandTests.swift`
  - Moved terminal-job selection, protected-job filtering, size accounting, and deletion into `CleanupService` with direct policy coverage.
