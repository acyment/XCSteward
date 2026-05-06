import Foundation

enum FakeScenario: String {
    case success
    case manualShards = "manual_shards"
    case manualShardMergeFailure = "manual_shard_merge_failure"
    case manualShardBootstrapRetry = "manual_shard_bootstrap_retry"
    case manualShardBootstrapRetryWithPartialResult = "manual_shard_bootstrap_retry_with_partial_result"
    case manualShardFatalShortCircuit = "manual_shard_fatal_short_circuit"
    case manualShardsConcurrent = "manual_shards_concurrent"
    case buildFailure = "build_failure"
    case bootstrapRetry = "bootstrap_retry"
    case bootstrapRetryWithPartialResult = "bootstrap_retry_with_partial_result"
    case bootStatusFailure = "boot_status_failure"
    case bootedSimulatorNeedsRecovery = "booted_simulator_needs_recovery"
    case slowSuccess = "slow_success"
    case queuedCancellation = "queued_cancellation"
    case parallelMixedOutcomes = "parallel_mixed_outcomes"
    case parallelCancellation = "parallel_cancellation"
    case dynamicBackpressure = "dynamic_backpressure"
    case managedSimulatorStatusLine = "managed_simulator_status_line"
    case projectScopedListRequired = "project_scoped_list_required"
    case xctestrunRejectsTestPlan = "xctestrun_rejects_testplan"
    case generatedXCTESTRunPath = "generated_xctestrun_path"
    case runnerConfigurationFailureWithXCResult = "runner_configuration_failure_with_xcresult"
    case runningCancellation = "running_cancellation"
    case managedSimulatorCreateFailure = "managed_simulator_create_failure"
    case managedSimulatorCreateNoisySuccess = "managed_simulator_create_noisy_success"
    case managedSimulatorListHangs = "managed_simulator_list_hangs"
    case corruptXCResultSuccess = "corrupt_xcresult_success"
    case modernXCResultToolSummary = "modern_xcresulttool_summary"
    case testTimeout = "test_timeout"
    case listSchemes = "list_schemes"
    case xcodeVersionMismatch = "xcode_version_mismatch"
    case commandLineToolsSelection = "command_line_tools_selection"
    case missingFirstLaunchComponents = "missing_first_launch_components"
    case missingIPhoneSimulatorSDK = "missing_iphonesimulator_sdk"
    case showsdksWarningOnly = "showsdks_warning_only"
    case showsdksFailureWithSDKOnDisk = "showsdks_failure_with_sdk_on_disk"
    case noAvailableSimulatorRuntime = "no_available_simulator_runtime"
    case textualSimulatorRuntimeAvailability = "textual_simulator_runtime_availability"
    case negativeTextSimulatorRuntimeAvailability = "negative_text_simulator_runtime_availability"
    case flagSimulatorRuntimeAvailability = "flag_simulator_runtime_availability"
    case unavailableSimulatorRuntime = "unavailable_simulator_runtime"
    case runtimeDyldCacheUnavailable = "runtime_dyld_cache_unavailable"
    case unavailableSimulatorDevice = "unavailable_simulator_device"
    case textualUnavailableSimulatorDevice = "textual_unavailable_simulator_device"
    case flagUnavailableSimulatorDevice = "flag_unavailable_simulator_device"
    case hungCoreSimulatorList = "hung_coresimulator_list"
    case concurrentRunnerContention = "concurrent_runner_contention"
    case missingProcessLister = "missing_process_lister"
    case noRunnableDestinations = "no_runnable_destinations"
    case spacedIOSSimulatorDestination = "spaced_ios_simulator_destination"
    case missingTestPlan = "missing_test_plan"
    case packageResolutionFailure = "package_resolution_failure"
    case missingXCTestRun = "missing_xctestrun"
    case staleDoctorXCTestRun = "stale_doctor_xctestrun"
    case legacyXCResultTool = "legacy_xcresulttool"
    case xcodebuildMCPProcess = "xcodebuildmcp_process"
    case simulatorAppProcess = "simulator_app_process"
    case memoryPressureWarning = "memory_pressure_warning"
    case thermalStateSerious = "thermal_state_serious"
}

struct FakeToolEnvironment {
    let root: URL
    let bin: URL
    let log: URL
    let env: [String: String]
}

func makeFakeToolEnvironment(scenario: FakeScenario, extraEnv: [String: String] = [:]) throws -> FakeToolEnvironment {
    let root = try makeTempDirectory(function: "FakeToolEnvironment")
    let bin = root.appendingPathComponent("bin")
    let log = root.appendingPathComponent("tool.log")
    let xcodeContents = root.appendingPathComponent("FakeXcode.app/Contents")
    let xcodeDeveloper = xcodeContents.appendingPathComponent("Developer")
    let xcodebuildPath = xcodeDeveloper.appendingPathComponent("usr/bin/xcodebuild")
    let selectedDeveloperPath: String = scenario == .commandLineToolsSelection
        ? "/Library/Developer/CommandLineTools"
        : xcodeDeveloper.path
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xcodebuildPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    if scenario == .showsdksFailureWithSDKOnDisk {
        try FileManager.default.createDirectory(
            at: xcodeDeveloper.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.0.sdk"),
            withIntermediateDirectories: true
        )
    }
    try writeText(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>16.4</string>
            <key>ProductBuildVersion</key>
            <string>16F6</string>
        </dict>
        </plist>
        """,
        to: xcodeContents.appendingPathComponent("version.plist")
    )

    let commonEnv: [String: String] = [
        "FAKE_TOOL_ROOT": root.path,
        "FAKE_TOOL_LOG": log.path,
        "FAKE_TOOL_SCENARIO": scenario.rawValue,
        "FAKE_XCODE_SELECT_PATH": selectedDeveloperPath,
        "FAKE_XCODEBUILD_PATH": xcodebuildPath.path,
        "XCSTEWARD_DOCTOR_MIN_FREE_BYTES": "0",
        "XCSTEWARD_DOCTOR_WARN_FREE_BYTES": "0",
        "XCSTEWARD_DOCTOR_WARN_FREE_PERCENT": "0",
    ].merging(extraEnv, uniquingKeysWith: { _, new in new })

    try FakeToolScripts.installAll(into: bin)

    let env = [
        "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
    ].merging(commonEnv, uniquingKeysWith: { _, new in new })

    return FakeToolEnvironment(root: root, bin: bin, log: log, env: env)
}

private struct FakeToolScript {
    let name: String
    let contents: String
}

private enum FakeToolScripts {
    static func installAll(into bin: URL) throws {
        for script in all {
            try writeExecutable(script.contents, to: bin.appendingPathComponent(script.name))
        }
    }

    private static var all: [FakeToolScript] {
        [xcodebuild, xcrun, ps, memoryPressure, pmset, xcodeSelect]
    }

    private static var xcodebuild: FakeToolScript {
        FakeToolScript(
            name: "xcodebuild",
            contents: """
            #!/bin/bash
            set -euo pipefail
            LOG="${FAKE_TOOL_LOG:?missing log}"
            ROOT="${FAKE_TOOL_ROOT:?missing root}"
            SCENARIO="${FAKE_TOOL_SCENARIO:?missing scenario}"
            printf 'xcodebuild %s\\n' "$*" >> "$LOG"
            record_event() {
              local EVENT="$1"
              local PHASE="$2"
              local RESULT_PATH="${3:-}"
              printf 'event %s phase=%s job=%s project=%s pid=%s result=%s\\n' "$EVENT" "$PHASE" "${XCSTEWARD_JOB_ID:-}" "${XCSTEWARD_PROJECT:-}" "$$" "$RESULT_PATH" >> "$LOG"
            }
            for KEY in TMPDIR XCSTEWARD_JOB_ID XCSTEWARD_PROJECT XCSTEWARD_PHASE XCSTEWARD_PORT_RANGE_INDEX XCSTEWARD_PORT_RANGE_START XCSTEWARD_PORT_RANGE_END XCSTEWARD_PORT_RANGE_COUNT XCSTEWARD_PORT_RANGE XCSTEWARD_SHARD_ID XCSTEWARD_SHARD_INDEX XCSTEWARD_TOTAL_SHARDS TEST_RUNNER_XCSTEWARD_JOB_ID TEST_RUNNER_XCSTEWARD_PROJECT TEST_RUNNER_XCSTEWARD_MODE TEST_RUNNER_XCSTEWARD_PHASE TEST_RUNNER_XCSTEWARD_PORT_RANGE_INDEX TEST_RUNNER_XCSTEWARD_PORT_RANGE_START TEST_RUNNER_XCSTEWARD_PORT_RANGE_END TEST_RUNNER_XCSTEWARD_PORT_RANGE_COUNT TEST_RUNNER_XCSTEWARD_PORT_RANGE TEST_RUNNER_XCSTEWARD_SHARD_ID TEST_RUNNER_XCSTEWARD_SHARD_INDEX TEST_RUNNER_XCSTEWARD_TOTAL_SHARDS; do
              VALUE="${!KEY:-}"
              if [[ -n "$VALUE" ]]; then
                printf 'env %s=%s\\n' "$KEY" "$VALUE" >> "$LOG"
              fi
            done
            if [[ "$*" == "-version" ]]; then
              if [[ "$SCENARIO" == "xcode_version_mismatch" ]]; then
                cat <<'TXT'
            Xcode 16.3
            Build version 16E140
            TXT
              else
                cat <<'TXT'
            Xcode 16.4
            Build version 16F6
            TXT
              fi
              exit 0
            fi
            if [[ "$*" == "-help" ]]; then
              cat <<'TXT'
            Usage: xcodebuild [options] [action ...]
                -parallel-testing-enabled YES|NO
                -maximum-parallel-testing-workers NUMBER
                -parallel-testing-worker-count NUMBER
                -destination-timeout NUMBER
                -enableCodeCoverage YES|NO
                -resultStreamPath PATH
                -resultBundleVersion NUMBER
                -testProductsPath PATH
                -collect-test-diagnostics POLICY
            TXT
              exit 0
            fi
            if [[ "$*" == "-showsdks" ]]; then
              if [[ "$SCENARIO" == "showsdks_failure_with_sdk_on_disk" ]]; then
                echo "xcodebuild: error: unable to enumerate SDKs" >&2
                exit 74
              fi
              if [[ "$SCENARIO" == "missing_iphonesimulator_sdk" ]]; then
                cat <<'TXT'
            iOS SDKs:
                iOS 18.0                         -sdk iphoneos18.0
            TXT
              elif [[ "$SCENARIO" == "showsdks_warning_only" ]]; then
                cat <<'TXT'
            xcodebuild: warning: iphonesimulator platform support was not found
            iOS SDKs:
            	iOS 18.0                      	-sdk iphoneos18.0
            TXT
              else
                cat <<'TXT'
            iOS SDKs:
            	iOS 18.0                      	-sdk iphoneos18.0
            
            iOS Simulator SDKs:
            	Simulator - iOS 18.0         	-sdk iphonesimulator18.0
            TXT
              fi
              exit 0
            fi
            if [[ "$*" == *"-list"* ]]; then
              if [[ "$SCENARIO" == "project_scoped_list_required" && "$*" != *"-project"* && "$*" != *"-workspace"* ]]; then
                cat <<'JSON'
            {"project":{"schemes":["WrongScheme"]}}
            JSON
              else
                cat <<'JSON'
            {"project":{"schemes":["Demo","Publiqueitor-iOS","Lernit"]}}
            JSON
              fi
              exit 0
            fi
            if [[ "$*" == *"-showdestinations"* ]]; then
              if [[ "$SCENARIO" == "no_runnable_destinations" ]]; then
                cat <<'TXT'
            Available destinations for the "Demo" scheme:
            	{ platform:macOS, arch:arm64, name:My Mac }
            TXT
              elif [[ "$SCENARIO" == "spaced_ios_simulator_destination" ]]; then
                cat <<'TXT'
            Available destinations for the "Demo" scheme:
                { platform : iOS Simulator, id : SIM-123, OS : 18.0, name : iPhone 17 Pro }
            TXT
              else
                cat <<'TXT'
            Available destinations for the "Demo" scheme:
            	{ platform:iOS Simulator, id:SIM-123, OS:18.0, name:iPhone 17 Pro }
            TXT
              fi
              exit 0
            fi
            if [[ "$*" == *"-showTestPlans"* ]]; then
              if [[ "$SCENARIO" == "missing_test_plan" ]]; then
                cat <<'TXT'
            Smoke
            Regression
            TXT
              else
                cat <<'TXT'
            Stable
            Smoke
            TXT
              fi
              exit 0
            fi
            if [[ "$*" == *"-resolvePackageDependencies"* ]]; then
              if [[ "$SCENARIO" == "package_resolution_failure" ]]; then
                echo "Package resolution failed" >&2
                exit 74
              fi
              echo "Resolved package dependencies"
              exit 0
            fi
            if [[ "$*" == *"build-for-testing"* ]]; then
              if [[ "$SCENARIO" == "build_failure" ]]; then
                echo "Build failed" >&2
                exit 65
              fi
              if [[ "$SCENARIO" == "running_cancellation" ]]; then
                child=""
                trap 'echo "xcodebuild received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                touch "$ROOT/build-started"
                while true; do
                  sleep 1 &
                  child="$!"
                  wait "$child" || true
                done
              fi
              DERIVED=""
              TEST_PRODUCTS=""
              args=("$@")
              for ((i=0; i<${#args[@]}; i++)); do
                if [[ "${args[$i]}" == "-derivedDataPath" ]]; then
                  DERIVED="${args[$((i+1))]}"
                fi
                if [[ "${args[$i]}" == "-testProductsPath" ]]; then
                  TEST_PRODUCTS="${args[$((i+1))]}"
                fi
              done
              mkdir -p "$DERIVED/Build/Products"
              if [[ -n "$TEST_PRODUCTS" ]]; then
                mkdir -p "$TEST_PRODUCTS"
                touch "$TEST_PRODUCTS/manifest.json"
              fi
              if [[ "$SCENARIO" == "generated_xctestrun_path" ]]; then
                touch "$DERIVED/Build/Products/Demo_Stable_iphonesimulator18.0-arm64.xctestrun"
              elif [[ "$SCENARIO" == "missing_xctestrun" ]]; then
                echo "Skipping .xctestrun generation for scenario"
              elif [[ "$SCENARIO" == "stale_doctor_xctestrun" ]]; then
                touch -t 200001010000 "$DERIVED/Build/Products/stale.xctestrun"
              else
                touch "$DERIVED/Build/Products/fake.xctestrun"
              fi
              if [[ "$SCENARIO" == "slow_success" ]]; then
                record_event "start" "build"
                sleep 4
                record_event "end" "build"
              fi
              if [[ "$SCENARIO" == "queued_cancellation" ]] && mkdir "$ROOT/queued-cancellation-first.lock" 2>/dev/null; then
                record_event "start" "build"
                touch "$ROOT/queued-cancellation-first-started"
                for _ in {1..200}; do
                  if [[ -f "$ROOT/release-queued-cancellation" ]]; then
                    break
                  fi
                  sleep 0.1
                done
                record_event "end" "build"
              fi
              echo "Build succeeded"
              exit 0
            fi
            if [[ "$*" == *"test-without-building"* ]]; then
              RESULT=""
              XCTESTRUN=""
              HAS_TEST_PLAN=0
              ENUMERATION_OUTPUT=""
              ENUMERATE_TESTS=0
              ONLY_COUNT=0
              ONLY_VALUES=()
              args=("$@")
              for ((i=0; i<${#args[@]}; i++)); do
                if [[ "${args[$i]}" == "-resultBundlePath" ]]; then
                  RESULT="${args[$((i+1))]}"
                fi
                if [[ "${args[$i]}" == "-xctestrun" ]]; then
                  XCTESTRUN="${args[$((i+1))]}"
                fi
                if [[ "${args[$i]}" == "-testPlan" ]]; then
                  HAS_TEST_PLAN=1
                fi
                if [[ "${args[$i]}" == "-enumerate-tests" ]]; then
                  ENUMERATE_TESTS=1
                fi
                if [[ "${args[$i]}" == "-test-enumeration-output-path" ]]; then
                  ENUMERATION_OUTPUT="${args[$((i+1))]}"
                fi
                if [[ "${args[$i]}" == -only-testing:* ]]; then
                  ONLY_COUNT=$((ONLY_COUNT + 1))
                  ONLY_VALUES+=("${args[$i]#-only-testing:}")
                fi
              done
              if [[ ( "$SCENARIO" == "manual_shards" || "$SCENARIO" == "manual_shard_merge_failure" || "$SCENARIO" == "manual_shard_bootstrap_retry" || "$SCENARIO" == "manual_shard_bootstrap_retry_with_partial_result" || "$SCENARIO" == "manual_shard_fatal_short_circuit" || "$SCENARIO" == "manual_shards_concurrent" ) && "$ENUMERATE_TESTS" -eq 1 ]]; then
                mkdir -p "$(dirname "$ENUMERATION_OUTPUT")"
                cat <<'JSON' > "$ENUMERATION_OUTPUT"
            {"tests":[{"identifier":"DemoTests/FooTests/testA"},{"identifier":"DemoTests/FooTests/testB"},{"identifier":"DemoTests/BarTests/testC"},{"identifier":"DemoTests/BarTests/testD"}]}
            JSON
                echo "Enumerated tests"
                exit 0
              fi
              COUNT_FILE="$ROOT/test-count"
              COUNT=0
              if [[ -f "$COUNT_FILE" ]]; then
                COUNT="$(cat "$COUNT_FILE")"
              fi
              COUNT=$((COUNT + 1))
              echo "$COUNT" > "$COUNT_FILE"
              if [[ ( "$SCENARIO" == "bootstrap_retry" || "$SCENARIO" == "bootstrap_retry_with_partial_result" ) && "$COUNT" -eq 1 ]]; then
                if [[ "$SCENARIO" == "bootstrap_retry_with_partial_result" ]]; then
                  mkdir -p "$RESULT"
                  cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":0,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                fi
                echo "Failed to background test runner" >&2
                exit 74
              fi
              if [[ "$SCENARIO" == "manual_shard_bootstrap_retry" || "$SCENARIO" == "manual_shard_bootstrap_retry_with_partial_result" ]] && mkdir "$ROOT/manual-shard-bootstrap-failed.lock" 2>/dev/null; then
                if [[ "$SCENARIO" == "manual_shard_bootstrap_retry_with_partial_result" ]]; then
                  mkdir -p "$RESULT"
                  cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":0,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                fi
                echo "Failed to background test runner" >&2
                exit 74
              fi
              if [[ "$SCENARIO" == "xctestrun_rejects_testplan" && "$HAS_TEST_PLAN" -eq 1 ]]; then
                echo "Scheme 'Transient Testing' does not have an associated test plan named 'Stable'" >&2
                exit 64
              fi
              if [[ "$SCENARIO" == "generated_xctestrun_path" && ! -f "$XCTESTRUN" ]]; then
                echo "There are no test bundles available to test." >&2
                exit 70
              fi
              if [[ "$SCENARIO" == "runner_configuration_failure_with_xcresult" ]]; then
                mkdir -p "$RESULT"
                cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":0,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                echo "There are no test bundles available to test." >&2
                exit 64
              fi
              if [[ "$SCENARIO" == "test_timeout" ]]; then
                echo "Testing started"
                while true; do
                  :
                done
              fi
              if [[ "$SCENARIO" == "parallel_mixed_outcomes" ]]; then
                record_event "start" "test" "$RESULT"
                mkdir -p "$RESULT"
                if [[ "${XCSTEWARD_PROJECT:-}" == "demo-artifact" ]]; then
                  sleep 1
                  echo "not-json" > "$RESULT/summary.json"
                  record_event "end" "test" "$RESULT"
                  echo "Tests succeeded"
                  exit 0
                fi
                sleep 2
                cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":3,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                record_event "end" "test" "$RESULT"
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "parallel_cancellation" ]]; then
                if [[ "${XCSTEWARD_PROJECT:-}" == "demo-cancel" ]]; then
                  touch "$ROOT/demo-cancel-test-started"
                  record_event "start" "test" "$RESULT"
                  while [[ ! -f "$ROOT/release-demo-cancel" ]]; do
                    sleep 0.1
                  done
                  echo "xcodebuild observed cancellation project=${XCSTEWARD_PROJECT:-}" >> "$LOG"
                  record_event "terminated" "test" "$RESULT"
                  exit 143
                fi
                record_event "start" "test" "$RESULT"
                sleep 4
                mkdir -p "$RESULT"
                cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":3,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                record_event "end" "test" "$RESULT"
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "dynamic_backpressure" ]]; then
                record_event "start" "test" "$RESULT"
                if [[ "${XCSTEWARD_PROJECT:-}" == "demo-a" || "${XCSTEWARD_PROJECT:-}" == "demo-b" ]]; then
                  while [[ ! -f "$ROOT/release-running" ]]; do
                    sleep 0.1
                  done
                else
                  sleep 0.5
                fi
                mkdir -p "$RESULT"
                cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":3,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                record_event "end" "test" "$RESULT"
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "corrupt_xcresult_success" ]]; then
                mkdir -p "$RESULT"
                echo "not-json" > "$RESULT/summary.json"
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "modern_xcresulttool_summary" ]]; then
                mkdir -p "$RESULT"
                cat <<'JSON' > "$RESULT/summary.json"
            {"totalTestCount":2,"failedTests":0,"skippedTests":0,"passedTests":2,"result":"Passed"}
            JSON
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "slow_success" ]]; then
                record_event "start" "test" "$RESULT"
                sleep 4
              fi
              if [[ "$SCENARIO" == "manual_shard_fatal_short_circuit" ]]; then
                if [[ "$RESULT" == *"shard-000"* ]]; then
                  touch "$ROOT/fatal-shard-started"
                  for _ in {1..100}; do
                    if [[ -f "$ROOT/peer-shard-started" ]]; then
                      break
                    fi
                    sleep 0.05
                  done
                  echo "There are no test bundles available to test." >&2
                  exit 74
                fi
                trap 'echo "manual shard peer received SIGTERM" >> "$LOG"; exit 143' TERM
                touch "$ROOT/peer-shard-started"
                while true; do
                  sleep 1
                done
              fi
              mkdir -p "$RESULT"
              if [[ "$SCENARIO" == "manual_shards_concurrent" ]]; then
                record_event "start" "manual-shard" "$RESULT"
                sleep 2
              fi
              if [[ "$SCENARIO" == "manual_shards" || "$SCENARIO" == "manual_shard_merge_failure" || "$SCENARIO" == "manual_shard_bootstrap_retry" || "$SCENARIO" == "manual_shard_bootstrap_retry_with_partial_result" || "$SCENARIO" == "manual_shards_concurrent" ]]; then
                cat <<JSON > "$RESULT/summary.json"
            {"testsCount":$ONLY_COUNT,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                printf '{"tests":[' > "$RESULT/tests.json"
                FIRST_TEST=1
                for IDENTIFIER in "${ONLY_VALUES[@]}"; do
                  DURATION="1.0"
                  case "$IDENTIFIER" in
                    *"testA") DURATION="9.0" ;;
                    *"testB") DURATION="1.0" ;;
                    *"testC") DURATION="1.0" ;;
                    *"testD") DURATION="1.0" ;;
                  esac
                  if [[ "$FIRST_TEST" -eq 0 ]]; then
                    printf ',' >> "$RESULT/tests.json"
                  fi
                  FIRST_TEST=0
                  printf '{"identifier":"%s","duration":%s}' "$IDENTIFIER" "$DURATION" >> "$RESULT/tests.json"
                done
                printf ']}' >> "$RESULT/tests.json"
                if [[ "$SCENARIO" == "manual_shards_concurrent" ]]; then
                  record_event "end" "manual-shard" "$RESULT"
                fi
                echo "Tests succeeded"
                exit 0
              fi
              cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":3,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
              if [[ "$SCENARIO" == "slow_success" ]]; then
                record_event "end" "test" "$RESULT"
              fi
              echo "Tests succeeded"
              exit 0
            fi
            echo "Unexpected xcodebuild invocation: $*" >&2
            exit 99
            """
        )
    }

    private static var xcrun: FakeToolScript {
        FakeToolScript(
            name: "xcrun",
            contents: """
            #!/bin/bash
            set -euo pipefail
            LOG="${FAKE_TOOL_LOG:?missing log}"
            ROOT="${FAKE_TOOL_ROOT:?missing root}"
            SCENARIO="${FAKE_TOOL_SCENARIO:?missing scenario}"
            printf 'xcrun %s\\n' "$*" >> "$LOG"
            if [[ "$1" == "--find" && "$2" == "xcodebuild" ]]; then
              echo "${FAKE_XCODEBUILD_PATH:?missing xcodebuild path}"
              exit 0
            fi
            if [[ "$1" == "--find" && "$2" == "simctl" ]]; then
              if [[ "$SCENARIO" == "command_line_tools_selection" || "$SCENARIO" == "missing_first_launch_components" ]]; then
                echo 'xcrun: error: unable to find utility "simctl"' >&2
                exit 72
              fi
              echo "${FAKE_XCODE_SELECT_PATH:?missing xcode select path}/usr/bin/simctl"
              exit 0
            fi
            if [[ "$1" == "simctl" ]]; then
              shift
              if [[ "$1" == "help" ]]; then
                if [[ "$SCENARIO" == "missing_first_launch_components" ]]; then
                  echo 'simctl is unavailable until xcodebuild -runFirstLaunch completes' >&2
                  exit 72
                fi
                cat <<'TXT'
            usage: simctl <subcommand>
            TXT
                exit 0
              fi
              if [[ "$1" == "list" && "$2" == "runtimes" && "$3" == "--json" ]]; then
                if [[ "$SCENARIO" == "no_available_simulator_runtime" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-18-0","name":"tvOS 18.0","isAvailable":true}]}
            JSON
                elif [[ "$SCENARIO" == "textual_simulator_runtime_availability" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.ios-18-0","name":"ios 18.0","availability":"(available)"},{"identifier":"com.apple.CoreSimulator.SimRuntime.ios-17-4","name":"ios 17.4","availability":"(unavailable, dyld shared cache is missing)"}]}
            JSON
                elif [[ "$SCENARIO" == "negative_text_simulator_runtime_availability" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.ios-18-0","name":"ios 18.0","availability":"not available for this platform"}]}
            JSON
                elif [[ "$SCENARIO" == "flag_simulator_runtime_availability" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.ios-18-0","name":"ios 18.0","isAvailable":"YES"},{"identifier":"com.apple.CoreSimulator.SimRuntime.ios-17-4","name":"ios 17.4","isAvailable":0}]}
            JSON
                elif [[ "$SCENARIO" == "unavailable_simulator_runtime" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-4","name":"iOS 17.4","isAvailable":false}]}
            JSON
                elif [[ "$SCENARIO" == "runtime_dyld_cache_unavailable" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-4","name":"iOS 17.4","isAvailable":false,"availabilityError":"dyld shared cache is missing"}]}
            JSON
                else
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","isAvailable":true}]}
            JSON
                fi
                exit 0
              fi
              if [[ "$1" == "diagnose" && "$2" == "-l" ]]; then
                echo "$ROOT/CoreSimulatorDiagnostic-$(date +%s).log"
                exit 0
              fi
              if [[ "$1" == "privacy" ]]; then
                exit 0
              fi
              if [[ "$1" == "list" && "$2" == "--json" ]]; then
                if [[ "$SCENARIO" == "hung_coresimulator_list" ]]; then
                  sleep 3
                fi
                cat <<'JSON'
            {"devicetypes":[],"runtimes":[],"devices":{}}
            JSON
                exit 0
              fi
              if [[ "$1" == "list" && "$2" == "devices" && "${3:-}" == "--json" ]]; then
                if [[ "$SCENARIO" == "managed_simulator_list_hangs" ]]; then
                  child=""
                  trap 'echo "managed simctl list received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                  touch "$ROOT/managed-list-started"
                  while true; do
                    sleep 1 &
                    child="$!"
                    wait "$child" || true
                  done
                fi
                if [[ "$SCENARIO" == "unavailable_simulator_device" ]]; then
                  cat <<'JSON'
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true},{"name":"Old iPhone","udid":"SIM-OLD","state":"Shutdown","isAvailable":false,"availabilityError":"runtime is unavailable"}]}}
            JSON
                elif [[ "$SCENARIO" == "textual_unavailable_simulator_device" ]]; then
                  cat <<'JSON'
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":"YES"},{"name":"Text Old iPhone","udid":"SIM-TEXT","state":"Shutdown","availability":"not available (runtime profile not found)"},{"name":"Snake Old iPhone","udid":"SIM-SNAKE","state":"Shutdown","availability_error":"runtime is unavailable"}]}}
            JSON
                elif [[ "$SCENARIO" == "flag_unavailable_simulator_device" ]]; then
                  cat <<'JSON'
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":"YES"},{"name":"Int Old iPhone","udid":"SIM-INT","state":"Shutdown","isAvailable":0},{"name":"No Old iPhone","udid":"SIM-NO","state":"Shutdown","isAvailable":"NO"}]}}
            JSON
                elif [[ "$SCENARIO" == "managed_simulator_status_line" ]]; then
                  cat <<'JSON'
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"Publiqueitor Test iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true}]}}
            JSON
                else
                  cat <<'JSON'
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true}]}}
            JSON
                fi
                exit 0
              fi
              if [[ "$1" == "list" && "$2" == "devices" && "${3:-}" == "booted" && "${4:-}" == "--json" ]]; then
                cat <<'JSON'
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Booted"}]}}
            JSON
                exit 0
              fi
              if [[ "$1" == "list" && "$2" == "devices" ]]; then
                if [[ "$SCENARIO" == "managed_simulator_list_hangs" ]]; then
                  child=""
                  trap 'echo "managed simctl list received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                  touch "$ROOT/managed-list-started"
                  while true; do
                    sleep 1 &
                    child="$!"
                    wait "$child" || true
                  done
                fi
                if [[ "$SCENARIO" == "list_schemes" ]]; then
                  echo "== Devices =="
                  exit 0
                fi
                if [[ "$SCENARIO" == "managed_simulator_status_line" ]]; then
                  cat <<'TXT'
            == Devices ==
            Publiqueitor Test iPhone 17 Pro (SIM-123) (Shutdown)
            TXT
                  exit 0
                fi
                if [[ "$SCENARIO" == "booted_simulator_needs_recovery" ]]; then
                  cat <<'TXT'
            == Devices ==
            iPhone 17 Pro (SIM-123) (Booted)
            TXT
                  exit 0
                fi
                if [[ -f "$ROOT/sim-created" ]]; then
                  cat <<'TXT'
            == Devices ==
            iPhone 17 Pro (00000000-0000-0000-0000-000000000123) (Shutdown)
            TXT
                else
                  cat <<'TXT'
            == Devices ==
            iPhone 17 Pro (SIM-123) (Shutdown)
            TXT
                fi
                exit 0
              fi
              if [[ "$1" == "bootstatus" && "$SCENARIO" == "boot_status_failure" ]]; then
                cat <<'TXT' >&2
            Monitoring boot status for Demo Simulator (SIM-123).
            [2026-04-21 19:33:25 +0000] Status=2, isTerminal=NO, Elapsed=01:06.
            	Waiting on Data Migration
            TXT
                exit 75
              fi
              if [[ "$1" == "bootstatus" && "$SCENARIO" == "booted_simulator_needs_recovery" ]]; then
                if [[ ! -f "$ROOT/sim-recovered" ]]; then
                  cat <<'TXT' >&2
            Monitoring boot status for Demo Simulator (SIM-123).
            [2026-04-22 12:00:00 +0000] Status=2, isTerminal=NO, Elapsed=00:30.
            	Waiting on Data Migration
            TXT
                  exit 75
                fi
                exit 0
              fi
              if [[ "$1" == "boot" && "$SCENARIO" == "booted_simulator_needs_recovery" ]]; then
                if [[ ! -f "$ROOT/sim-recovered" ]]; then
                  echo 'Unable to boot device in current state: Booted' >&2
                  exit 149
                fi
                exit 0
              fi
              if [[ "$1" == "shutdown" && "$SCENARIO" == "booted_simulator_needs_recovery" ]]; then
                touch "$ROOT/sim-recovered"
                exit 0
              fi
              if [[ "$1" == "clone" ]]; then
                touch "$ROOT/sim-cloned"
                echo "00000000-0000-0000-0000-000000000456"
                exit 0
              fi
              if [[ "$1" == "delete" && "${2:-}" == "unavailable" ]]; then
                touch "$ROOT/deleted-unavailable"
                exit 0
              fi
              if [[ "$1" == "delete" ]]; then
                exit 0
              fi
              if [[ "$1" == "boot" || "$1" == "bootstatus" || "$1" == "shutdown" || "$1" == "erase" ]]; then
                exit 0
              fi
              if [[ "$1" == "create" ]]; then
                if [[ "$SCENARIO" == "managed_simulator_create_failure" ]]; then
                  echo 'CoreSimulator failed to create device: runtime unavailable' >&2
                  exit 70
                fi
                if [[ "$SCENARIO" == "managed_simulator_create_noisy_success" ]]; then
                  touch "$ROOT/sim-created"
                  echo 'CoreSimulator warning: runtime metadata was refreshed' >&2
                  echo "00000000-0000-0000-0000-000000000123"
                  exit 0
                fi
                touch "$ROOT/sim-created"
                echo "00000000-0000-0000-0000-000000000123"
                exit 0
              fi
            fi
            if [[ "$1" == "xcresulttool" ]]; then
              shift
              if [[ "$1" == "help" ]]; then
                cat <<'TXT'
            OVERVIEW: XCResult Tooling
            USAGE: xcresulttool <subcommand>
            SUBCOMMANDS:
              get
              export
              merge
            TXT
                exit 0
              fi
              if [[ "$1" == "merge" ]]; then
                OUTPUT_PATH=""
                args=("$@")
                for ((i=0; i<${#args[@]}; i++)); do
                  if [[ "${args[$i]}" == "--output-path" ]]; then
                    OUTPUT_PATH="${args[$((i+1))]}"
                  fi
                done
                if [[ "$SCENARIO" == "manual_shard_merge_failure" ]]; then
                  echo "merge failed" >&2
                  exit 64
                fi
                mkdir -p "$OUTPUT_PATH"
                cat <<'JSON' > "$OUTPUT_PATH/summary.json"
            {"testsCount":4,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                echo "Merged result bundles"
                exit 0
              fi
              if [[ "$1" == "get" && "$2" == "test-results" && "$3" == "summary" && "$4" == "--help" ]]; then
                if [[ "$SCENARIO" == "legacy_xcresulttool" ]]; then
                  echo "error: unknown subcommand 'test-results'" >&2
                  exit 64
                fi
                cat <<'TXT'
            OVERVIEW: Get test report summary.
            USAGE: xcresulttool get test-results summary --path <path>
            TXT
                exit 0
              fi
              if [[ "$1" == "get" && "$2" == "test-results" && "$3" == "summary" ]]; then
                PATH_ARG=""
                args=("$@")
                for ((i=0; i<${#args[@]}; i++)); do
                  if [[ "${args[$i]}" == "--path" ]]; then
                    PATH_ARG="${args[$((i+1))]}"
                  fi
                done
                cat "$PATH_ARG/summary.json"
                exit 0
              fi
              if [[ "$1" == "get" && "$2" == "test-results" && "$3" == "tests" ]]; then
                PATH_ARG=""
                args=("$@")
                for ((i=0; i<${#args[@]}; i++)); do
                  if [[ "${args[$i]}" == "--path" ]]; then
                    PATH_ARG="${args[$((i+1))]}"
                  fi
                done
                if [[ -f "$PATH_ARG/tests.json" ]]; then
                  cat "$PATH_ARG/tests.json"
                else
                  echo '{"tests":[]}'
                fi
                exit 0
              fi
            fi
            echo "Unexpected xcrun invocation: $*" >&2
            exit 98
            """
        )
    }

    private static var ps: FakeToolScript {
        FakeToolScript(
            name: "ps",
            contents: """
            #!/bin/bash
            set -euo pipefail
            LOG="${FAKE_TOOL_LOG:?missing log}"
            SCENARIO="${FAKE_TOOL_SCENARIO:?missing scenario}"
            printf 'ps %s\\n' "$*" >> "$LOG"
            if [[ "$SCENARIO" == "missing_process_lister" ]]; then
              echo "ps probe unavailable" >&2
              exit 126
            fi
            cat <<'TXT'
              PID COMMAND
            TXT
            if [[ "$SCENARIO" == "concurrent_runner_contention" ]]; then
              cat <<'TXT'
            42420 xcodebuild -scheme Demo test
            TXT
            elif [[ "$SCENARIO" == "xcodebuildmcp_process" ]]; then
              cat <<'TXT'
            42420 npm exec xcodebuildmcp@latest mcp
            TXT
            elif [[ "$SCENARIO" == "simulator_app_process" ]]; then
              cat <<'TXT'
            42421 /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator -SessionOnLaunch NO
            TXT
            fi
            exit 0
            """
        )
    }

    private static var memoryPressure: FakeToolScript {
        FakeToolScript(
            name: "memory_pressure",
            contents: """
            #!/bin/bash
            set -euo pipefail
            LOG="${FAKE_TOOL_LOG:?missing log}"
            ROOT="${FAKE_TOOL_ROOT:?missing root}"
            SCENARIO="${FAKE_TOOL_SCENARIO:?missing scenario}"
            printf 'memory_pressure %s\\n' "$*" >> "$LOG"
            if [[ "$SCENARIO" == "dynamic_backpressure" && -f "$ROOT/constrain-host" ]]; then
              cat <<'TXT'
            System-wide memory free percentage: 4%
            Memory pressure: Warning
            TXT
            elif [[ "$SCENARIO" == "memory_pressure_warning" ]]; then
              cat <<'TXT'
            System-wide memory free percentage: 4%
            Memory pressure: Warning
            TXT
            else
              cat <<'TXT'
            System-wide memory free percentage: 42%
            Memory pressure: Normal
            TXT
            fi
            exit 0
            """
        )
    }

    private static var pmset: FakeToolScript {
        FakeToolScript(
            name: "pmset",
            contents: """
            #!/bin/bash
            set -euo pipefail
            LOG="${FAKE_TOOL_LOG:?missing log}"
            SCENARIO="${FAKE_TOOL_SCENARIO:?missing scenario}"
            printf 'pmset %s\\n' "$*" >> "$LOG"
            if [[ "$*" != "-g therm" ]]; then
              echo "Unexpected pmset invocation: $*" >&2
              exit 97
            fi
            if [[ "$SCENARIO" == "thermal_state_serious" ]]; then
              cat <<'TXT'
            CPU_Scheduler_Limit = 70
            CPU_Available_CPUs = 6
            CPU_Speed_Limit = 70
            TXT
            else
              cat <<'TXT'
            CPU_Scheduler_Limit = 100
            CPU_Available_CPUs = 8
            CPU_Speed_Limit = 100
            TXT
            fi
            exit 0
            """
        )
    }

    private static var xcodeSelect: FakeToolScript {
        FakeToolScript(
            name: "xcode-select",
            contents: """
            #!/bin/bash
            set -euo pipefail
            LOG="${FAKE_TOOL_LOG:?missing log}"
            printf 'xcode-select %s\\n' "$*" >> "$LOG"
            if [[ "$1" == "-p" ]]; then
              echo "${FAKE_XCODE_SELECT_PATH:?missing xcode select path}"
              exit 0
            fi
            echo "Unexpected xcode-select invocation: $*" >&2
            exit 97
            """
        )
    }

}
