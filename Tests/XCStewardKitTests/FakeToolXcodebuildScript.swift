extension FakeToolScripts {
    static var xcodebuild: FakeToolScript {
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
              if [[ "$SCENARIO" == "xcodebuild_list_failure" ]]; then
                echo "xcodebuild: error: unable to inspect project in current sandbox" >&2
                exit 74
              fi
              if [[ "$SCENARIO" == "project_scoped_list_required" && "$*" != *"-project"* && "$*" != *"-workspace"* ]]; then
                cat <<'JSON'
            {"project":{"schemes":["WrongScheme"]}}
            JSON
              elif [[ "$SCENARIO" == "xcodebuild_list_json_with_warning_prefix" ]]; then
                cat <<'JSON'
            2026-05-25 16:37:56.193 xcodebuild[75675:10522323] [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
            {"project":{"schemes":["Demo","Feliche"]}}
            JSON
              else
                cat <<'JSON'
            {"project":{"schemes":["Demo","Publiqueitor-iOS","Lernit"]}}
            JSON
              fi
              exit 0
            fi
            if [[ "$*" == *"-showdestinations"* ]]; then
              if [[ "$SCENARIO" == "no_runnable_destinations" || "$SCENARIO" == "macos_only_destination" ]]; then
                cat <<'TXT'
            Available destinations for the "Demo" scheme:
            	{ platform:macOS, arch:arm64, name:My Mac }
            TXT
              elif [[ "$SCENARIO" == "placeholder_ios_simulator_destination" ]]; then
                cat <<'TXT'
            Available destinations for the "Demo" scheme:
                { platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
            TXT
              elif [[ "$SCENARIO" == "transient_placeholder_ios_simulator_destination" ]]; then
                COUNT_FILE="$ROOT/showdestinations-count"
                COUNT=0
                if [[ -f "$COUNT_FILE" ]]; then
                  COUNT="$(cat "$COUNT_FILE")"
                fi
                COUNT="$((COUNT + 1))"
                printf '%s' "$COUNT" > "$COUNT_FILE"
                if [[ "$COUNT" == "1" ]]; then
                  cat <<'TXT'
            Available destinations for the "Demo" scheme:
                { platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
            TXT
                else
                  cat <<'TXT'
            Available destinations for the "Demo" scheme:
                { platform:iOS Simulator, id:SIM-123, OS:18.0, name:iPhone 17 Pro }
            TXT
                fi
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
              if [[ "$SCENARIO" == "build_timeout" ]]; then
                echo "Build started"
                while true; do
                  sleep 1
                done
              fi
              if [[ "$SCENARIO" == "running_cancellation" ]]; then
                child=""
                trap 'echo "xcodebuild received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                echo "Build started"
                touch "$ROOT/build-started"
                while true; do
                  sleep 1 &
                  child="$!"
                  wait "$child" || true
                done
              fi
              if [[ "$SCENARIO" == "worker_crash_during_build" && "${XCSTEWARD_PROJECT:-}" == "demo-crash" ]]; then
                child=""
                trap 'echo "orphaned build received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                echo "Build started"
                touch "$ROOT/worker-crash-build-started"
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
              if [[ "$SCENARIO" == "test_cancellation" ]]; then
                child=""
                trap 'echo "xcodebuild test received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                touch "$ROOT/test-started"
                echo "Testing started"
                while true; do
                  sleep 1 &
                  child="$!"
                  wait "$child" || true
                done
              fi
              if [[ "$SCENARIO" == "worker_crash_during_test" && "${XCSTEWARD_PROJECT:-}" == "demo-crash" ]]; then
                child=""
                trap 'echo "orphaned test received SIGTERM" >> "$LOG"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; exit 143' TERM
                touch "$ROOT/worker-crash-test-started"
                echo "Testing started"
                while true; do
                  sleep 1 &
                  child="$!"
                  wait "$child" || true
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
              if [[ "$SCENARIO" == "missing_xcresult_success" ]]; then
                echo "Tests succeeded without result bundle"
                exit 0
              fi
              if [[ "$SCENARIO" == "corrupt_xcresult_success" ]]; then
                mkdir -p "$RESULT"
                echo "not-json" > "$RESULT/summary.json"
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "xcresult_summary_timeout_success" ]]; then
                mkdir -p "$RESULT"
                cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":1,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                echo "Tests succeeded"
                exit 0
              fi
              if [[ "$SCENARIO" == "junit_generation_failure" ]]; then
                mkdir -p "$RESULT"
                cat <<'JSON' > "$RESULT/summary.json"
            {"testsCount":3,"testsFailedCount":0,"testsSkippedCount":0}
            JSON
                mkdir -p "$(dirname "$RESULT")/junit.xml"
                echo "Tests succeeded but JUnit path is blocked"
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
}
