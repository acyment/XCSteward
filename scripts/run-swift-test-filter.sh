#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'TXT'
Usage: bash scripts/run-swift-test-filter.sh [swift-test-args...]

Runs `swift test` with at least one --filter argument and fails if SwiftPM
reports that no matching test cases were run.

Examples:
  bash scripts/run-swift-test-filter.sh --filter DoctorCommandTests/testExample
  bash scripts/run-swift-test-filter.sh test --filter DoctorCommandTests/testExample

Set SWIFT_EXECUTABLE to override the swift executable used by the wrapper.
TXT
}

args=("$@")
if [[ "${args[0]:-}" == "test" ]]; then
  args=("${args[@]:1}")
fi

has_filter=0
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    --filter)
      has_filter=1
      if [[ $((index + 1)) -ge ${#args[@]} || "${args[$((index + 1))]}" == -* ]]; then
        echo "error: --filter requires a test name or pattern" >&2
        exit 2
      fi
      ;;
    --filter=*)
      has_filter=1
      if [[ "${args[$index]}" == "--filter=" ]]; then
        echo "error: --filter requires a test name or pattern" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ "$has_filter" -eq 0 ]]; then
  echo "error: checked targeted test runs require at least one --filter argument" >&2
  usage >&2
  exit 2
fi

stdout_file="$(mktemp "${TMPDIR:-/tmp}/xcsteward-swift-test-filter.stdout.XXXXXX")"
stderr_file="$(mktemp "${TMPDIR:-/tmp}/xcsteward-swift-test-filter.stderr.XXXXXX")"
combined_file="$(mktemp "${TMPDIR:-/tmp}/xcsteward-swift-test-filter.combined.XXXXXX")"
cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$combined_file"
}
trap cleanup EXIT

set +e
"${SWIFT_EXECUTABLE:-swift}" test "${args[@]}" > "$stdout_file" 2> "$stderr_file"
swift_status=$?
set -e

cat "$stdout_file"
cat "$stderr_file" >&2
cat "$stdout_file" "$stderr_file" > "$combined_file"

if grep -Fq "No matching test cases were run" "$combined_file"; then
  echo "error: swift test filter matched zero test cases" >&2
  if [[ "$swift_status" -eq 0 ]]; then
    exit 64
  fi
fi

exit "$swift_status"
