#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XCSteward Contributors

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tier="fast"
group_filter=""
list_only=0
continue_on_failure=0
include_live=0
check_coverage=0
report_path=""

usage() {
  cat <<'TXT'
Usage: bash scripts/run-test-suite.sh [--tier fast|release|live] [--group GROUP_ID] [--list] [--check-coverage] [--include-live] [--continue-on-failure] [--report PATH]

Runs named XCSteward test-suite tiers and writes suite-health JSON evidence.

Tiers:
  fast     Normal refactor loop. Pure units, parsers, command helpers, and script checks.
  release  Public-alpha fake-tool release gate. Includes fast plus slow E2E/hardening groups.
  live     Opt-in live simulator smoke group only.

Options:
  --group GROUP_ID       Run a single named group regardless of tier.
  --list                 Print selected groups without running them.
  --check-coverage       Validate release-tier XCTest class coverage, then exit.
  --include-live         Include the live smoke group in the release tier. Requires XCSTEWARD_LIVE_SIMULATOR_ID.
  --continue-on-failure  Run remaining selected groups after a failure, then exit nonzero.
  --report PATH          Write JSON report. Defaults to .build/test-suite/<tier>-latest.json.
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      if [[ $# -lt 2 ]]; then
        echo "error: --tier requires fast, release, or live" >&2
        exit 2
      fi
      tier="$2"
      shift 2
      ;;
    --group)
      if [[ $# -lt 2 ]]; then
        echo "error: --group requires a group ID" >&2
        exit 2
      fi
      group_filter="$2"
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    --check-coverage)
      check_coverage=1
      shift
      ;;
    --include-live)
      include_live=1
      shift
      ;;
    --continue-on-failure)
      continue_on_failure=1
      shift
      ;;
    --report)
      if [[ $# -lt 2 ]]; then
        echo "error: --report requires a path" >&2
        exit 2
      fi
      report_path="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$tier" in
  fast|release|live) ;;
  *)
    echo "error: unsupported tier '$tier'" >&2
    exit 2
    ;;
esac

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

quote_arg() {
  local value="$1"
  local escaped
  if [[ "$value" =~ ^[A-Za-z0-9_./:=+-]+$ ]]; then
    printf '%s' "$value"
  else
    escaped="${value//\'/\'\\\'\'}"
    printf "'%s'" "$escaped"
  fi
}

format_command() {
  local output=""
  local arg
  for arg in "$@"; do
    if [[ -n "$output" ]]; then
      output+=" "
    fi
    output+="$(quote_arg "$arg")"
  done
  printf '%s' "$output"
}

groups=(
  "unit-core|fast|CoreSimulatorAvailabilityTests CoreSimulatorDeviceTypeTests CoreSimulatorProbeModelsTests CoreSimulatorRuntimeTests DoctorCheckRegistryTests DoctorOutputParsersTests HostCapacityParserTests JobSummaryFactoryTests JUnitReportWriterTests ManualShardPlanningTests ProcessDetectionTests ProcessToolRunnerTests ResultClassPolicyTests SubmitCommandOptionsTests TestOutcomeClassifierTests XcodebuildCommandBuilderTests XCResultReaderTests|Pure units, parsers, builders, and small service boundaries."
  "profile-config|fast|ProfileLoaderTests ProfileSectionDecodersTests|Profile loading and typed section decoding."
  "state-and-reporting|fast|CleanupCommandTests CommandJSONErrorTests ResultReporterTests StateStoreGatewayTests|State-root, cleanup, JSON error, and reporting checks."
  "script-hardening|fast|CheckedSwiftTestFilterScriptTests FakeToolScriptSelfTests HardeningMatrixTests TestSuiteTierScriptTests|Release-script and generated fake-tool self-tests."
  "doctor-preflight|release|DoctorCommandTests DoctorDiskHealthCommandTests DoctorPathSafetyCommandTests DoctorStateHealthCommandTests DoctorXcodeEnvironmentCommandTests DoctorCoreSimulatorCommandTests DoctorProjectPreflightCommandTests DoctorManagedSimulatorCommandTests|Doctor command output, disk/path/state health, Xcode environment checks, CoreSimulator checks, project preflights, managed simulator fix policy."
  "e2e-command-surface|release|SubmitCommandE2ETests CLIProgressTests XcodeManagedConfigurationE2ETests ExecutionOutcomeE2ETests WorkerLaunchE2ETests|Submit/status/artifacts, progress output, xcode-managed configuration, worker launch, retry, cleanup, and execution-outcome E2E coverage."
  "artifacts-cancel-timeout|release|CancellationE2ETests ExecutorCancellationRaceTests ProcessMonitoringRecoveryTests ResultArtifactE2ETests TimeoutHardeningE2ETests|Artifact, cancellation, timeout, and process-monitoring hardening."
  "manual-shards|release|ManualShardE2ETests ManualShardConfigurationE2ETests ManualShardRunnerServiceBoundaryTests|Manual shard execution, profile argument propagation, and service-boundary checks."
  "simulator-hardening|release|ManagedSimulatorE2ETests SimulatorBootstrapE2ETests SimulatorHardeningE2ETests SimulatorLeaseTests SimulatorLifecycleTests|Managed simulator, lease, lifecycle, and simulator failure behavior."
  "worker-and-capacity|release|HostCapacityTests WorkerCrashRecoveryE2ETests WorkerParallelE2ETests WorkerSchedulingE2ETests|Worker scheduling, crash recovery, and host-capacity behavior."
  "profile-recovery|release|ProfileFailureRecoveryTests ProfileValidationE2ETests|Profile validation and pre-mutation failure recovery."
  "live-xcode-managed-smoke|live|LiveXcodeManagedParallelSmokeTests|Opt-in live Xcode-managed simulator smoke."
)

if [[ -n "${XCSTEWARD_TEST_SUITE_GROUPS_FILE:-}" ]]; then
  if [[ ! -f "$XCSTEWARD_TEST_SUITE_GROUPS_FILE" ]]; then
    echo "error: XCSTEWARD_TEST_SUITE_GROUPS_FILE does not exist: $XCSTEWARD_TEST_SUITE_GROUPS_FILE" >&2
    exit 2
  fi
  groups=()
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -n "$row" && "$row" != \#* ]] || continue
    groups+=("$row")
  done < "$XCSTEWARD_TEST_SUITE_GROUPS_FILE"
fi

validate_group_manifest() {
  local temp_dir group_ids_file duplicate_ids_file row id row_tier filters description extra filter
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcsteward-test-suite-manifest.XXXXXX")"
  group_ids_file="$temp_dir/group-ids.txt"
  duplicate_ids_file="$temp_dir/duplicate-ids.txt"
  : > "$group_ids_file"

  for row in "${groups[@]}"; do
    IFS='|' read -r id row_tier filters description extra <<< "$row"
    if [[ -z "${id:-}" || -z "${row_tier:-}" || -z "${filters:-}" || -z "${description:-}" || -n "${extra:-}" ]]; then
      echo "error: malformed test-suite group row: $row" >&2
      rm -rf "$temp_dir"
      exit 2
    fi
    if [[ ! "$id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      echo "error: test-suite group ID contains unsupported characters: $id" >&2
      rm -rf "$temp_dir"
      exit 2
    fi
    case "$row_tier" in
      fast|release|live) ;;
      *)
        echo "error: test-suite group '$id' has unsupported tier '$row_tier'" >&2
        rm -rf "$temp_dir"
        exit 2
        ;;
    esac
    for filter in $filters; do
      if [[ ! "$filter" =~ ^[A-Za-z0-9_./-]+$ ]]; then
        echo "error: test-suite group '$id' has unsupported filter '$filter'" >&2
        rm -rf "$temp_dir"
        exit 2
      fi
    done
    printf '%s\n' "$id" >> "$group_ids_file"
  done

  sort "$group_ids_file" | uniq -d > "$duplicate_ids_file"
  if [[ -s "$duplicate_ids_file" ]]; then
    echo "error: duplicate test-suite group IDs:" >&2
    sed 's/^/  - /' "$duplicate_ids_file" >&2
    rm -rf "$temp_dir"
    exit 2
  fi
  rm -rf "$temp_dir"
}

validate_group_manifest

selected_ids=()
selected_tiers=()
selected_filters=()
selected_descriptions=()
live_skipped=0
report_tier=""
default_report_name=""

select_group() {
  local row="$1"
  local id row_tier filters description
  IFS='|' read -r id row_tier filters description <<< "$row"

  if [[ -n "$group_filter" ]]; then
    [[ "$id" == "$group_filter" ]] || return 0
  else
    case "$tier" in
      fast)
        [[ "$row_tier" == "fast" ]] || return 0
        ;;
      release)
        if [[ "$row_tier" == "live" ]]; then
          if [[ "$include_live" -eq 1 ]]; then
            :
          else
            live_skipped=1
            return 0
          fi
        elif [[ "$row_tier" != "fast" && "$row_tier" != "release" ]]; then
          return 0
        fi
        ;;
      live)
        [[ "$row_tier" == "live" ]] || return 0
        ;;
    esac
  fi

  selected_ids+=("$id")
  selected_tiers+=("$row_tier")
  selected_filters+=("$filters")
  selected_descriptions+=("$description")
}

for row in "${groups[@]}"; do
  select_group "$row"
done

if [[ "${#selected_ids[@]}" -eq 0 ]]; then
  if [[ -n "$group_filter" ]]; then
    echo "error: no test-suite group selected for '$group_filter'" >&2
  else
    echo "error: no test-suite groups selected for tier '$tier'" >&2
  fi
  exit 2
fi

all_xctest_classes() {
  grep -hE '^(final )?class [A-Za-z0-9_]+: XCTestCase' "$ROOT"/Tests/XCStewardKitTests/*Tests.swift \
    | sed -E 's/^(final )?class ([A-Za-z0-9_]+):.*/\2/' \
    | sort -u
}

validate_selected_filters_exist() {
  local temp_dir known_file missing_file selected_classes_file duplicate_file filters filter filter_class
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcsteward-test-suite-filters.XXXXXX")"
  known_file="$temp_dir/known.txt"
  missing_file="$temp_dir/missing.txt"
  selected_classes_file="$temp_dir/selected-classes.txt"
  duplicate_file="$temp_dir/duplicate.txt"
  all_xctest_classes > "$known_file"
  : > "$missing_file"
  : > "$selected_classes_file"

  for filters in "${selected_filters[@]}"; do
    for filter in $filters; do
      filter_class="${filter%%/*}"
      printf '%s\n' "$filter_class" >> "$selected_classes_file"
      if ! grep -Fxq "$filter_class" "$known_file"; then
        printf '%s\n' "$filter" >> "$missing_file"
      fi
    done
  done

  if [[ -s "$missing_file" ]]; then
    echo "error: selected test-suite filters do not match XCTestCase classes:" >&2
    sort -u "$missing_file" | sed 's/^/  - /' >&2
    rm -rf "$temp_dir"
    exit 2
  fi

  sort "$selected_classes_file" | uniq -d > "$duplicate_file"
  if [[ -s "$duplicate_file" ]]; then
    echo "error: selected test-suite filters include duplicate XCTestCase classes:" >&2
    sed 's/^/  - /' "$duplicate_file" >&2
    rm -rf "$temp_dir"
    exit 2
  fi
  rm -rf "$temp_dir"
}

validate_selected_filters_exist

requires_live=0
for selected_tier in "${selected_tiers[@]}"; do
  if [[ "$selected_tier" == "live" ]]; then
    requires_live=1
  fi
done
if [[ "$requires_live" -eq 1 && "$list_only" -eq 0 && "$check_coverage" -eq 0 && -z "${XCSTEWARD_LIVE_SIMULATOR_ID:-}" ]]; then
  echo "error: live test-suite groups require XCSTEWARD_LIVE_SIMULATOR_ID" >&2
  exit 2
fi

release_filter_classes() {
  local row id row_tier filters description filter
  for row in "${groups[@]}"; do
    IFS='|' read -r id row_tier filters description <<< "$row"
    [[ "$row_tier" == "fast" || "$row_tier" == "release" ]] || continue
    for filter in $filters; do
      printf '%s\n' "$filter"
    done
  done
}

validate_release_coverage() {
  local temp_dir expected_file covered_file missing_file class
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcsteward-test-suite-coverage.XXXXXX")"
  expected_file="$temp_dir/expected.txt"
  covered_file="$temp_dir/covered.txt"
  missing_file="$temp_dir/missing.txt"

  all_xctest_classes | grep -v '^LiveXcodeManagedParallelSmokeTests$' > "$expected_file"
  release_filter_classes | sort -u > "$covered_file"

  : > "$missing_file"
  while IFS= read -r class || [[ -n "$class" ]]; do
    if ! grep -Fxq "$class" "$covered_file"; then
      printf '%s\n' "$class" >> "$missing_file"
    fi
  done < "$expected_file"

  if [[ -s "$missing_file" ]]; then
    echo "error: release tier is missing XCTest classes:" >&2
    sed 's/^/  - /' "$missing_file" >&2
    rm -rf "$temp_dir"
    exit 2
  fi
  rm -rf "$temp_dir"
}

if [[ "$check_coverage" -eq 1 ]]; then
  validate_release_coverage
  echo "Release tier covers all non-live XCTestCase classes exactly once."
  exit 0
fi

if [[ "$list_only" -eq 1 ]]; then
  for i in "${!selected_ids[@]}"; do
    printf '%s\t%s\t%s\n' "${selected_ids[$i]}" "${selected_tiers[$i]}" "${selected_filters[$i]}"
  done
  if [[ "$live_skipped" -eq 1 ]]; then
    echo "live-xcode-managed-smoke skipped; pass --include-live with XCSTEWARD_LIVE_SIMULATOR_ID to include it" >&2
  fi
  exit 0
fi

if [[ "$tier" == "release" && -z "$group_filter" ]]; then
  validate_release_coverage
fi

if [[ -n "$group_filter" ]]; then
  report_tier="${selected_tiers[0]}"
  default_report_name="${group_filter}-latest.json"
else
  report_tier="$tier"
  default_report_name="${tier}-latest.json"
fi

cd "$ROOT"

swiftpm_runner_args=(
  --disable-sandbox
  --cache-path "$ROOT/.build/test-suite-swiftpm-cache"
  --config-path "$ROOT/.build/test-suite-swiftpm-config"
  --security-path "$ROOT/.build/test-suite-swiftpm-security"
)

mkdir -p \
  "$ROOT/.build/test-suite-module-cache" \
  "$ROOT/.build/test-suite-swiftpm-cache" \
  "$ROOT/.build/test-suite-swiftpm-config" \
  "$ROOT/.build/test-suite-swiftpm-security"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/test-suite-module-cache}"

if [[ -z "$report_path" ]]; then
  report_path="$ROOT/.build/test-suite/$default_report_name"
elif [[ "$report_path" != /* ]]; then
  report_path="$ROOT/$report_path"
fi
mkdir -p "$(dirname "$report_path")"
log_dir="${report_path}.logs"
rm -rf "$log_dir"
mkdir -p "$log_dir"

run_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_started_epoch="$(date +%s)"
run_groups=()
duration_rows=()
overall_status="passed"
exit_status=0
failed_count=0
total_tests=0
total_failures=0
total_skipped=0
live_smoke_status="not_requested"
if [[ "$live_skipped" -eq 1 ]]; then
  live_smoke_status="skipped"
fi

parse_tests() {
  local file="$1"
  local value
  value="$(grep -E 'Executed [0-9]+ tests?' "$file" | tail -1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/' || true)"
  printf '%s' "${value:-0}"
}

parse_failures() {
  local file="$1"
  local value
  value="$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures' "$file" | tail -1 | sed -E 's/.*with ([0-9]+) failures.*/\1/' || true)"
  printf '%s' "${value:-0}"
}

parse_skipped() {
  local file="$1"
  local value
  value="$(grep -Eo '[0-9]+ skipped' "$file" | tail -1 | sed -E 's/ .*//' || true)"
  printf '%s' "${value:-0}"
}

write_report() {
  local completed_at completed_epoch duration slowest_file index row_duration row_id
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  completed_epoch="$(date +%s)"
  duration=$((completed_epoch - run_started_epoch))
  slowest_file="$(mktemp "${TMPDIR:-/tmp}/xcsteward-test-suite-slowest.XXXXXX")"
  if [[ "${#duration_rows[@]}" -gt 0 ]]; then
    printf '%s\n' "${duration_rows[@]}" | sort -t'|' -k1,1nr | head -5 > "$slowest_file"
  else
    : > "$slowest_file"
  fi

  {
    printf '{\n'
    printf '  "status": %s,\n' "$(json_string "$overall_status")"
    printf '  "tier": %s,\n' "$(json_string "$report_tier")"
    printf '  "started_at": %s,\n' "$(json_string "$run_started_at")"
    printf '  "completed_at": %s,\n' "$(json_string "$completed_at")"
    printf '  "duration_seconds": %d,\n' "$duration"
    printf '  "selected_group_count": %d,\n' "${#selected_ids[@]}"
    printf '  "group_count": %d,\n' "${#run_groups[@]}"
    printf '  "failed_count": %d,\n' "$failed_count"
    printf '  "test_count": %d,\n' "$total_tests"
    printf '  "failure_count": %d,\n' "$total_failures"
    printf '  "skipped_count": %d,\n' "$total_skipped"
    printf '  "continue_on_failure": %s,\n' "$([[ "$continue_on_failure" -eq 1 ]] && printf true || printf false)"
    printf '  "live_included": %s,\n' "$([[ "$include_live" -eq 1 || "$report_tier" == "live" ]] && printf true || printf false)"
    printf '  "live_skipped": %s,\n' "$([[ "$live_skipped" -eq 1 ]] && printf true || printf false)"
    printf '  "live_smoke_status": %s,\n' "$(json_string "$live_smoke_status")"
    printf '  "logs_dir": %s,\n' "$(json_string "$log_dir")"
    printf '  "slowest_groups": [\n'
    index=0
    while IFS='|' read -r row_duration row_id || [[ -n "$row_duration" ]]; do
      [[ -n "$row_duration" ]] || continue
      if [[ "$index" -gt 0 ]]; then
        printf ',\n'
      fi
      printf '    {"id":%s,"duration_seconds":%d}' "$(json_string "$row_id")" "$row_duration"
      index=$((index + 1))
    done < "$slowest_file"
    printf '\n  ],\n'
    printf '  "groups": [\n'
    for i in "${!run_groups[@]}"; do
      if [[ "$i" -gt 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "${run_groups[$i]}"
    done
    printf '\n  ]\n'
    printf '}\n'
  } > "$report_path"

  rm -f "$slowest_file"
}

for i in "${!selected_ids[@]}"; do
  id="${selected_ids[$i]}"
  group_tier="${selected_tiers[$i]}"
  filters="${selected_filters[$i]}"
  description="${selected_descriptions[$i]}"
  group_log="$log_dir/$id.log"
  filter_args=()
  for filter in $filters; do
    filter_args+=(--filter "$filter")
  done
  command=(bash scripts/run-swift-test-filter.sh "${swiftpm_runner_args[@]}" "${filter_args[@]}")
  command_text="$(format_command "${command[@]}")"

  printf '[%d/%d] %s\n' "$((i + 1))" "${#selected_ids[@]}" "$id"
  group_started_epoch="$(date +%s)"
  if [[ "$group_tier" == "live" ]]; then
    if XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 "${command[@]}" > "$group_log" 2>&1; then
      group_status=0
    else
      group_status=$?
    fi
  else
    if "${command[@]}" > "$group_log" 2>&1; then
      group_status=0
    else
      group_status=$?
    fi
  fi
  cat "$group_log"

  group_completed_epoch="$(date +%s)"
  group_duration=$((group_completed_epoch - group_started_epoch))
  group_tests="$(parse_tests "$group_log")"
  group_failures="$(parse_failures "$group_log")"
  group_skipped="$(parse_skipped "$group_log")"
  if [[ "$group_status" -eq 0 && "$group_tests" -eq 0 ]]; then
    group_status=65
    echo "error: test-suite group executed zero tests" | tee -a "$group_log" >&2
  fi
  group_result="$([[ "$group_status" -eq 0 ]] && printf passed || printf failed)"

  total_tests=$((total_tests + group_tests))
  total_failures=$((total_failures + group_failures))
  total_skipped=$((total_skipped + group_skipped))
  duration_rows+=("$group_duration|$id")

  if [[ "$group_tier" == "live" ]]; then
    live_smoke_status="$group_result"
    command_text="XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 $command_text"
  fi

  run_groups+=("{\"id\":$(json_string "$id"),\"tier\":$(json_string "$group_tier"),\"description\":$(json_string "$description"),\"filters\":$(json_string "$filters"),\"command\":$(json_string "$command_text"),\"status\":$(json_string "$group_result"),\"exit_code\":$group_status,\"duration_seconds\":$group_duration,\"test_count\":$group_tests,\"failure_count\":$group_failures,\"skipped_count\":$group_skipped,\"log\":$(json_string "$group_log")}")

  if [[ "$group_status" -ne 0 ]]; then
    overall_status="failed"
    failed_count=$((failed_count + 1))
    if [[ "$exit_status" -eq 0 ]]; then
      exit_status="$group_status"
    fi
    if [[ "$continue_on_failure" -eq 0 ]]; then
      write_report
      echo "Test suite report: $report_path"
      exit "$exit_status"
    fi
  fi
done

if [[ "$live_skipped" -eq 1 ]]; then
  echo "live-xcode-managed-smoke skipped; pass --include-live with XCSTEWARD_LIVE_SIMULATOR_ID to include it"
fi

write_report
echo "Test suite report: $report_path"
if [[ "$overall_status" == "failed" ]]; then
  printf 'Test suite failed: %d group(s) failed\n' "$failed_count"
  exit "$exit_status"
fi
printf 'Test suite passed: %d group(s), %d test(s), %d skipped\n' "${#selected_ids[@]}" "$total_tests" "$total_skipped"
