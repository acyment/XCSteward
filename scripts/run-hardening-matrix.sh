#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XCSteward Contributors

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX_FILE="${XCSTEWARD_HARDENING_MATRIX_FILE:-$ROOT/docs/hardening-matrix.md}"

include_live=0
list_only=0
continue_on_failure=0
row_filter=""
report_path=""

usage() {
  cat <<'TXT'
Usage: bash scripts/run-hardening-matrix.sh [--list] [--row ROW_ID] [--include-live] [--continue-on-failure] [--report PATH]

Runs the fake-tool rows from docs/hardening-matrix.md sequentially.

Options:
  --list                 Print selected rows without running them.
  --row ROW_ID           Run only the row with this ID.
  --include-live         Include the live simulator smoke row. Requires XCSTEWARD_LIVE_SIMULATOR_ID.
  --continue-on-failure  Run remaining selected rows after a row fails, then exit nonzero.
  --report PATH          Write a JSON report. Defaults to .build/hardening-matrix/latest-report.json.
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-live)
      include_live=1
      shift
      ;;
    --list)
      list_only=1
      shift
      ;;
    --continue-on-failure)
      continue_on_failure=1
      shift
      ;;
    --row)
      if [[ $# -lt 2 ]]; then
        echo "error: --row requires a row ID" >&2
        exit 2
      fi
      row_filter="$2"
      shift 2
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

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_code_span() {
  local value
  value="$(trim "$1")"
  value="${value#\`}"
  value="${value%\`}"
  printf '%s' "$value"
}

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

row_ids=()
row_commands=()
live_skipped=0

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" == \|* ]] || continue

  IFS='|' read -r _ raw_id raw_command _ <<< "$line"
  id="$(strip_code_span "$raw_id")"
  command="$(strip_code_span "$raw_command")"

  [[ -n "$id" ]] || continue
  [[ "$id" != "Row ID" ]] || continue
  [[ "$id" != "---" ]] || continue

  if [[ -n "$row_filter" && "$id" != "$row_filter" ]]; then
    continue
  fi

  if [[ "$id" == "live-xcode-managed-smoke" ]]; then
    if [[ "$include_live" -eq 0 ]]; then
      live_skipped=1
      continue
    fi
    if [[ -z "${XCSTEWARD_LIVE_SIMULATOR_ID:-}" ]]; then
      echo "error: --include-live requires XCSTEWARD_LIVE_SIMULATOR_ID" >&2
      exit 2
    fi
    command='XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 swift test --filter LiveXcodeManagedParallelSmokeTests/testLiveXcodeManagedParallelSmoke'
  fi

  if [[ "$command" != *"swift test --filter"* ]]; then
    continue
  fi

  row_ids+=("$id")
  row_commands+=("$command")
done < "$MATRIX_FILE"

if [[ "${#row_ids[@]}" -eq 0 ]]; then
  if [[ -n "$row_filter" ]]; then
    echo "error: no hardening matrix row selected for '$row_filter'" >&2
  else
    echo "error: no hardening matrix rows found in $MATRIX_FILE" >&2
  fi
  exit 2
fi

if [[ "$list_only" -eq 1 ]]; then
  for i in "${!row_ids[@]}"; do
    printf '%s\t%s\n' "${row_ids[$i]}" "${row_commands[$i]}"
  done
  if [[ "$live_skipped" -eq 1 ]]; then
    echo "live-xcode-managed-smoke skipped; pass --include-live with XCSTEWARD_LIVE_SIMULATOR_ID to run it" >&2
  fi
  exit 0
fi

swiftpm_runner_args=(
  --disable-sandbox
  --cache-path "$ROOT/.build/hardening-swiftpm-cache"
  --config-path "$ROOT/.build/hardening-swiftpm-config"
  --security-path "$ROOT/.build/hardening-swiftpm-security"
)
prepared_live_env=0
prepared_swift_args=()
command_error=""

prepare_swift_command() {
  local command="$1"
  local remainder
  local token_count
  local index
  local filter
  local tokens=()

  prepared_live_env=0
  prepared_swift_args=(test "${swiftpm_runner_args[@]}")
  command_error=""

  remainder="$command"
  if [[ "$remainder" == "XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 "* ]]; then
    prepared_live_env=1
    remainder="${remainder#XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 }"
  fi

  if [[ "$remainder" != "swift test"* ]]; then
    command_error="command must start with 'swift test'"
    return 1
  fi

  remainder="${remainder#swift test}"
  remainder="$(trim "$remainder")"
  if [[ -z "$remainder" ]]; then
    command_error="command must include at least one --filter argument"
    return 1
  fi

  read -r -a tokens <<< "$remainder"
  token_count=${#tokens[@]}
  index=0
  while [[ "$index" -lt "$token_count" ]]; do
    if [[ "${tokens[$index]}" != "--filter" ]]; then
      command_error="only --filter arguments are supported"
      return 1
    fi
    index=$((index + 1))
    if [[ "$index" -ge "$token_count" ]]; then
      command_error="--filter requires a value"
      return 1
    fi
    filter="${tokens[$index]}"
    if [[ "$filter" == -* || ! "$filter" =~ ^[A-Za-z0-9_./-]+$ ]]; then
      command_error="unsupported --filter value '$filter'"
      return 1
    fi
    prepared_swift_args+=(--filter "$filter")
    index=$((index + 1))
  done
}

for i in "${!row_commands[@]}"; do
  if ! prepare_swift_command "${row_commands[$i]}"; then
    echo "error: unsafe or unsupported command for row '${row_ids[$i]}': $command_error" >&2
    exit 2
  fi
done

run_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_started_epoch="$(date +%s)"
run_rows=()
overall_status="passed"
exit_status=0
failed_count=0

cd "$ROOT"
mkdir -p \
  "$ROOT/.build/hardening-module-cache" \
  "$ROOT/.build/hardening-swiftpm-cache" \
  "$ROOT/.build/hardening-swiftpm-config" \
  "$ROOT/.build/hardening-swiftpm-security"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/hardening-module-cache}"

if [[ -z "$report_path" ]]; then
  report_path="$ROOT/.build/hardening-matrix/latest-report.json"
elif [[ "$report_path" != /* ]]; then
  report_path="$ROOT/$report_path"
fi
mkdir -p "$(dirname "$report_path")"

write_report() {
  local completed_at
  local completed_epoch
  local duration
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  completed_epoch="$(date +%s)"
  duration=$((completed_epoch - run_started_epoch))

  {
    printf '{\n'
    printf '  "status": %s,\n' "$(json_string "$overall_status")"
    printf '  "started_at": %s,\n' "$(json_string "$run_started_at")"
    printf '  "completed_at": %s,\n' "$(json_string "$completed_at")"
    printf '  "duration_seconds": %d,\n' "$duration"
    printf '  "matrix_file": %s,\n' "$(json_string "$MATRIX_FILE")"
    printf '  "live_included": %s,\n' "$([[ "$include_live" -eq 1 ]] && printf true || printf false)"
    printf '  "live_skipped": %s,\n' "$([[ "$live_skipped" -eq 1 ]] && printf true || printf false)"
    printf '  "continue_on_failure": %s,\n' "$([[ "$continue_on_failure" -eq 1 ]] && printf true || printf false)"
    printf '  "failed_count": %d,\n' "$failed_count"
    printf '  "rows": [\n'
    for i in "${!run_rows[@]}"; do
      if [[ "$i" -gt 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "${run_rows[$i]}"
    done
    printf '\n  ]\n'
    printf '}\n'
  } > "$report_path"
}

for i in "${!row_ids[@]}"; do
  number=$((i + 1))
  total=${#row_ids[@]}
  id="${row_ids[$i]}"
  command="${row_commands[$i]}"
  prepare_swift_command "$command"
  command="$(format_command swift "${prepared_swift_args[@]}")"
  if [[ "$prepared_live_env" -eq 1 ]]; then
    command="XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 $command"
  fi

  printf '[%d/%d] %s\n' "$number" "$total" "$id"
  row_started_epoch="$(date +%s)"
  if [[ "$prepared_live_env" -eq 1 ]]; then
    if XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 bash scripts/run-swift-test-filter.sh "${prepared_swift_args[@]}"; then
      row_status=0
    else
      row_status=$?
    fi
  else
    if bash scripts/run-swift-test-filter.sh "${prepared_swift_args[@]}"; then
      row_status=0
    else
      row_status=$?
    fi
  fi
  row_completed_epoch="$(date +%s)"
  row_duration=$((row_completed_epoch - row_started_epoch))
  row_result="$([[ "$row_status" -eq 0 ]] && printf passed || printf failed)"
  run_rows+=("{\"id\":$(json_string "$id"),\"command\":$(json_string "$command"),\"status\":$(json_string "$row_result"),\"exit_code\":$row_status,\"duration_seconds\":$row_duration}")
  if [[ "$row_status" -ne 0 ]]; then
    overall_status="failed"
    failed_count=$((failed_count + 1))
    if [[ "$exit_status" -eq 0 ]]; then
      exit_status="$row_status"
    fi
    if [[ "$continue_on_failure" -eq 0 ]]; then
      write_report
      echo "Hardening matrix report: $report_path"
      exit "$exit_status"
    fi
  fi
done

if [[ "$live_skipped" -eq 1 ]]; then
  echo "live-xcode-managed-smoke skipped; pass --include-live with XCSTEWARD_LIVE_SIMULATOR_ID to run it"
fi

write_report
echo "Hardening matrix report: $report_path"
if [[ "$overall_status" == "failed" ]]; then
  printf 'Hardening matrix failed: %d row(s) failed\n' "$failed_count"
  exit "$exit_status"
fi
printf 'Hardening matrix passed: %d row(s)\n' "${#row_ids[@]}"
