import Foundation

enum FakeScenario: String {
    case success
    case buildFailure = "build_failure"
    case bootstrapRetry = "bootstrap_retry"
    case bootStatusFailure = "boot_status_failure"
    case bootedSimulatorNeedsRecovery = "booted_simulator_needs_recovery"
    case slowSuccess = "slow_success"
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
    case showsdksFailureWithSDKOnDisk = "showsdks_failure_with_sdk_on_disk"
    case noAvailableSimulatorRuntime = "no_available_simulator_runtime"
    case unavailableSimulatorRuntime = "unavailable_simulator_runtime"
    case hungCoreSimulatorList = "hung_coresimulator_list"
    case concurrentRunnerContention = "concurrent_runner_contention"
    case missingProcessLister = "missing_process_lister"
    case noRunnableDestinations = "no_runnable_destinations"
    case missingTestPlan = "missing_test_plan"
    case packageResolutionFailure = "package_resolution_failure"
    case legacyXCResultTool = "legacy_xcresulttool"
    case xcodebuildMCPProcess = "xcodebuildmcp_process"
    case simulatorAppProcess = "simulator_app_process"
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
    ].merging(extraEnv, uniquingKeysWith: { _, new in new })

    try writeExecutable(
        """
        #!/bin/bash
        set -euo pipefail
        LOG="${FAKE_TOOL_LOG:?missing log}"
        ROOT="${FAKE_TOOL_ROOT:?missing root}"
        SCENARIO="${FAKE_TOOL_SCENARIO:?missing scenario}"
        printf 'xcodebuild %s\\n' "$*" >> "$LOG"
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
        if [[ "$*" == "-showsdks" ]]; then
          if [[ "$SCENARIO" == "showsdks_failure_with_sdk_on_disk" ]]; then
            echo "xcodebuild: error: unable to enumerate SDKs" >&2
            exit 74
          fi
          if [[ "$SCENARIO" == "missing_iphonesimulator_sdk" ]]; then
            cat <<'TXT'
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
          args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-derivedDataPath" ]]; then
              DERIVED="${args[$((i+1))]}"
            fi
          done
          mkdir -p "$DERIVED/Build/Products"
          if [[ "$SCENARIO" == "generated_xctestrun_path" ]]; then
            touch "$DERIVED/Build/Products/Demo_Stable_iphonesimulator18.0-arm64.xctestrun"
          else
            touch "$DERIVED/Build/Products/fake.xctestrun"
          fi
          if [[ "$SCENARIO" == "slow_success" ]]; then
            sleep 4
          fi
          echo "Build succeeded"
          exit 0
        fi
        if [[ "$*" == *"test-without-building"* ]]; then
          RESULT=""
          XCTESTRUN=""
          HAS_TEST_PLAN=0
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
          done
          COUNT_FILE="$ROOT/test-count"
          COUNT=0
          if [[ -f "$COUNT_FILE" ]]; then
            COUNT="$(cat "$COUNT_FILE")"
          fi
          COUNT=$((COUNT + 1))
          echo "$COUNT" > "$COUNT_FILE"
          if [[ "$SCENARIO" == "bootstrap_retry" && "$COUNT" -eq 1 ]]; then
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
            sleep 4
          fi
          mkdir -p "$RESULT"
          cat <<'JSON' > "$RESULT/summary.json"
        {"testsCount":3,"testsFailedCount":0,"testsSkippedCount":0}
        JSON
          echo "Tests succeeded"
          exit 0
        fi
        echo "Unexpected xcodebuild invocation: $*" >&2
        exit 99
        """,
        to: bin.appendingPathComponent("xcodebuild")
    )

    try writeExecutable(
        """
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
            elif [[ "$SCENARIO" == "unavailable_simulator_runtime" ]]; then
              cat <<'JSON'
        {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-4","name":"iOS 17.4","isAvailable":false}]}
        JSON
            else
              cat <<'JSON'
        {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","isAvailable":true}]}
        JSON
            fi
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
        TXT
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
        fi
        echo "Unexpected xcrun invocation: $*" >&2
        exit 98
        """,
        to: bin.appendingPathComponent("xcrun")
    )

    try writeExecutable(
        """
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
        """,
        to: bin.appendingPathComponent("ps")
    )

    try writeExecutable(
        """
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
        """,
        to: bin.appendingPathComponent("xcode-select")
    )

    let env = [
        "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
    ].merging(commonEnv, uniquingKeysWith: { _, new in new })

    return FakeToolEnvironment(root: root, bin: bin, log: log, env: env)
}
