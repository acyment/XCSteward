extension FakeToolScripts {
    static var xcrun: FakeToolScript {
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
              if [[ "$SCENARIO" == "xcodebuild_unavailable" ]]; then
                echo 'xcrun: error: unable to find utility "xcodebuild"' >&2
                exit 72
              fi
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
                elif [[ "$SCENARIO" == "iphonesimulator_sdk_runtime_mismatch" ]]; then
                  cat <<'JSON'
            {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-4","name":"iOS 17.4","isAvailable":true}]}
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
              if [[ "$1" == "list" && "$2" == "devicetypes" && "${3:-}" == "--json" ]]; then
                cat <<'JSON'
            {"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","name":"iPhone 17 Pro"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16","name":"iPhone 16"}]}
            JSON
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
                if [[ "$SCENARIO" == "coresimulator_device_list_failure" ]]; then
                  echo 'simctl list devices failed: CoreSimulatorService unavailable' >&2
                  exit 70
                elif [[ "$SCENARIO" == "unavailable_simulator_device" ]]; then
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
            {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true},{"name":"iPhone 17 Pro Shard","udid":"SIM-456","state":"Shutdown","isAvailable":true},{"name":"Override iPhone","udid":"SIM-OVERRIDE","state":"Shutdown","isAvailable":true},{"name":"Concurrent A","udid":"SIM-A","state":"Shutdown","isAvailable":true},{"name":"Concurrent B","udid":"SIM-B","state":"Shutdown","isAvailable":true},{"name":"Concurrent C","udid":"SIM-C","state":"Shutdown","isAvailable":true},{"name":"Shared iPhone","udid":"SIM-SHARED","state":"Shutdown","isAvailable":true},{"name":"Success iPhone","udid":"SIM-SUCCESS","state":"Shutdown","isAvailable":true},{"name":"Artifact iPhone","udid":"SIM-ARTIFACT","state":"Shutdown","isAvailable":true},{"name":"Keep iPhone","udid":"SIM-KEEP","state":"Shutdown","isAvailable":true},{"name":"Cancel iPhone","udid":"SIM-CANCEL","state":"Shutdown","isAvailable":true},{"name":"Manual A0","udid":"SIM-A0","state":"Shutdown","isAvailable":true},{"name":"Manual A1","udid":"SIM-A1","state":"Shutdown","isAvailable":true},{"name":"Manual B0","udid":"SIM-B0","state":"Shutdown","isAvailable":true},{"name":"Manual B1","udid":"SIM-B1","state":"Shutdown","isAvailable":true}]}}
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
              if [[ "$1" == "boot" && "$SCENARIO" == "simulator_disappears_during_boot" ]]; then
                echo 'Invalid device: SIM-123' >&2
                exit 70
              fi
              if [[ "$1" == "boot" && "$SCENARIO" == "simulator_boot_cancellation" ]]; then
                child=""
                trap 'echo "simctl boot received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                touch "$ROOT/simulator-boot-started"
                while true; do
                  sleep 1 &
                  child="$!"
                  wait "$child" || true
                done
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
                if [[ "$SCENARIO" == "managed_simulator_create_requires_identifiers" ]]; then
                  if [[ "${3:-}" != com.apple.CoreSimulator.SimDeviceType.* || "${4:-}" != com.apple.CoreSimulator.SimRuntime.* ]]; then
                    echo 'Invalid runtime: display names are not accepted on this host' >&2
                    exit 145
                  fi
                fi
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
                if [[ "$SCENARIO" == "post_test_artifact_cancellation" ]]; then
                  trap 'echo "xcresulttool summary received SIGTERM" >> "$LOG"; exit 143' TERM
                  touch "$ROOT/xcresult-summary-started"
                  while [[ ! -f "$ROOT/release-xcresult-summary" ]]; do
                    sleep 0.1
                  done
                fi
                if [[ "$SCENARIO" == "xcresult_summary_timeout_success" ]]; then
                  trap 'echo "xcresulttool summary timeout probe received SIGTERM" >> "$LOG"; exit 143' TERM
                  sleep 5
                fi
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
}
