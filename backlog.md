# XCSteward Backlog

## Doctor Follow-Up

### Slice 1: Toolchain and CLI selection

- [x] `global.developer_dir_env_override`
  
  - Detect when `DEVELOPER_DIR` overrides `xcode-select -p`.
  - Warn when the override differs from the selected developer directory.
  - Fail when the override points at a missing path or a clearly invalid developer dir.
  - Auto-fix boundary: only normalize or ignore the override inside XCSteward child processes; never mutate the user shell.

- [x] `global.clt_vs_xcode_selection`
  
  - Detect when the active developer directory points at Command Line Tools instead of a full Xcode.app.
  - Verify `simctl` and `iphonesimulator` SDK resolution.
  - Manual-only remediation.

- [x] `global.first_launch_components`
  
  - Detect missing first-launch components with `xcrun --find simctl` and related signals.
  - Manual-only remediation by default; at most show the exact `xcodebuild -runFirstLaunch` command.

- [x] `global.iphonesimulator_sdk_present`
  
  - Verify `xcodebuild -showsdks` exposes an `iphonesimulator` SDK.
  - Fail when simulator SDKs are unavailable.

### Slice 2: Simulator host health

- [x] `global.simulator_runtime_installed`
  
  - Verify at least one available iOS Simulator runtime exists.

- [x] `global.simulator_runtime_unavailable`
  
  - Detect installed but unavailable runtimes and surface version-specific guidance.

- [x] `global.coresim_list_json_health`
  
  - Run `simctl list --json` behind a timeout and fail when CoreSimulator enumeration hangs.

- [x] `global.concurrent_runner_contention`
  
  - Detect active competing `xcodebuild`, `xctest`, `simctl`, or `Simulator` processes outside XCSteward ownership.
  - Warn or fail depending on the process class.

### Slice 3: Project-aware preflight

- [x] `project.showdestinations_runnable`
  
  - Use `xcodebuild ... -showdestinations` to confirm at least one runnable iOS Simulator destination exists.

- [x] `project.testplan_exists`
  
  - Validate explicit test plans with `xcodebuild -showTestPlans`.

- [x] `project.derived_data_isolation`
  
  - Warn when the configured or inferred DerivedData path is shared, global, or inside the repo.

- [x] `project.package_resolution_preflight`
  
  - Run `xcodebuild -resolvePackageDependencies` as an explicit preflight and surface SwiftPM resolution failures.

- [x] `project.xcresulttool_compat`
  
  - Verify `xcresulttool` is available and that XCSteward is using a parser path compatible with the detected Xcode version.

## Later

- [x] `refactor.executor_job_paths`
  
  - Introduce a single job path/artifact bundle for executor paths.
  - Avoid rebuilding logs/artifact/DerivedData paths in multiple terminal branches.

- [x] `refactor.executor_terminal_summary_helpers`
  
  - Centralize terminal summary creation and persistence in `JobExecutor`.
  - Remove repeated canceled/failure summary boilerplate from simulator execution flow.

- [x] `refactor.executor_command_result_helpers`
  
  - Centralize command failure detail formatting and result-class/state mapping.
  - Keep simulator command handling readable as cancellation and artifact checks evolve.

- [x] `refactor.executor_tool_context`
  
  - Replace repeated `profile`, `jobID`, `store`, `combinedLog` parameter chains with an execution tool context.
  - Make tracked process ownership explicit at call sites.

- [x] `refactor.doctor_tool_probe_builders`
  
  - Extract common doctor probe-to-check patterns for timeout, nonzero exit, invalid JSON, and missing tools.
  - Reduce repetitive manual remediation strings in health checks.

- [x] `refactor.shared_process_detection`
  
  - Share process-line parsing and runner-contention detection between doctor and executor.
  - Keep doctor warnings and executor fail-fast behavior aligned.

- [x] `refactor.state_store_update_patch`
  
  - Replace the wide optional-argument `updateJobState` method with explicit update intents or a patch object.
  - Reduce accidental stale-field preservation in terminal state transitions.

- [x] `refactor.process_runner_spawn_allocation`
  
  - Wrap `posix_spawn` argv/envp/file-action setup behind small helpers.
  - Keep unsafe pointer lifetime management away from timeout and process-group logic.

- [x] `runner.process_group_cleanup`
  
  - Start simulator execution tools in their own process group.
  - Terminate the process group on timeout/cancel so `xcodebuild` descendants do not survive the job.

- [x] `project.managed_simulator_resolution_cancellable`
  
  - Mark jobs running before managed simulator resolution starts.
  - Run managed `simctl list` and `simctl create` through the tracked tool path so cancellation can interrupt them.

- [x] `project.managed_simulator_create_output_validation`
  
  - Validate successful `simctl create` output as a single UDID-shaped token.
  - Reject warnings or merged stderr/stdout instead of using them as a destination ID.

- [x] `project.xcresult_summary_required_for_success`
  
  - Treat corrupt, empty, or unparsable `.xcresult` bundles as artifact failures.
  - Do not report success with nil counts when the result bundle cannot be parsed.

- [x] `runner.cancel_failure_race`
  
  - Avoid converting already-observed build, bootstrap, or artifact failures into cancellation solely because `cancel_requested` races in afterward.

- [x] `runner.timeout_force_kill`
  
  - Avoid blocking forever after a subprocess timeout when `xcodebuild` or `simctl` ignores SIGTERM.
  - Escalate to SIGKILL after a short grace period and bound output-drain waits.

- [x] `runner.cancel_active_child`
  
  - Persist active `xcodebuild`/`simctl` child PIDs while a job is running.
  - Make `cancel` terminate the active child process instead of killing the worker process.
  - Record canceled summaries for running jobs that are interrupted by cancellation.

- [x] `project.build_for_testing_testplan`
  
  - Pass the requested or default test plan to `xcodebuild build-for-testing`.
  - Keep `test-without-building -xctestrun` free of `-testPlan`.

- [x] `project.managed_simulator_create_failure`
  
  - Do not treat failed `simctl create` stderr/stdout as a simulator UDID.
  - Fail with the underlying CoreSimulator error when create exits nonzero or times out.

- [x] `runner.test_timeout_classification`
  
  - Distinguish test/app execution timeouts from simulator runner bootstrap failures.
  - Preserve actionable result classes for hangs that occur after tests have started.

- [ ] `global.unavailable_devices_cleanup`

- [ ] `project.xctestrun_integrity`

- [ ] `global.disk_pressure_warning`

- [ ] `global.protected_path_warning`

- [ ] `global.runtime_dyld_cache_state`
