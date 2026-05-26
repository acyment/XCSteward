extension FakeToolScripts {
    static var utilityScripts: [FakeToolScript] {
        [ps, memoryPressure, pmset, xcodeSelect]
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
            if [[ "$#" -ge 4 && "$1" == "-p" && "$3" == "-o" && "$4" == "command=" ]]; then
              if [[ "$SCENARIO" == "worker_crash_during_build" ]]; then
                echo "xcodebuild -project App.xcodeproj -scheme Demo build-for-testing"
              elif [[ "$SCENARIO" == "worker_crash_during_test" ]]; then
                echo "xcodebuild -xctestrun fake.xctestrun test-without-building"
              fi
              exit 0
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
