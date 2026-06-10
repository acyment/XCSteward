# Codex

Use the same workspace state root throughout a task. Report absolute artifact
paths back to the user so they can open result bundles, logs, and JUnit output
from the shared machine.

```bash
project="demo"
state_root="${XCSTEWARD_HOME:-$HOME/Library/Application Support/XCSteward}"

summary="$(xcsteward --state-root "$state_root" submit --project "$project" --json)"
job_id="$(printf '%s\n' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')"

while :; do
  status="$(xcsteward --state-root "$state_root" status "$job_id" --json || true)"
  state="$(printf '%s\n' "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
  printf 'job %s: %s\n' "$job_id" "$state"
  case "$state" in
    queued|running) sleep 2 ;;
    *) break ;;
  esac
done

printf '%s\n' "$status"
xcsteward --state-root "$state_root" explain "$job_id" --json
xcsteward --state-root "$state_root" artifacts "$job_id" --json
```

If Codex needs streaming status instead of a polling loop, use
`xcsteward --state-root "$state_root" status "$job_id" --watch --json` and
consume the newline-delimited `JobSummary` objects. Use
`logs "$job_id" --follow` only for human-facing terminal inspection.

If a wait seems hung or quiet, check the same state root with `status --json`,
`jobs --json`, or `status --watch` before killing the job. A missing
`combined.log` usually means the job is still queued or in simulator/bootstrap
setup before xcodebuild has written logs.

Classification guide:

```bash
result_class="$(printf '%s\n' "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result_class"))')"
case "$result_class" in
  success) printf 'tests passed\n' ;;
  build_failure|test_failure|test_timeout) printf 'project failure: inspect logs and xcresult\n' ;;
  runner_bootstrap_failure|artifact_failure|internal_error) printf 'infrastructure failure: inspect diagnostics before retrying\n' ;;
  canceled) printf 'job was canceled\n' ;;
esac
```

Prefer `doctor --fix` for stale XCSteward-owned leases. Use
`doctor --fix-global` only when broad CoreSimulator cleanup is explicitly
wanted.
