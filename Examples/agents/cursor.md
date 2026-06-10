# Cursor

Run the loop in Cursor's integrated terminal from any repository. Keep the
profile name explicit so generated commands are easy to audit.

```bash
project="demo"

submit_json="$(xcsteward submit --project "$project" --json)"
job_id="$(printf '%s\n' "$submit_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')"
printf 'submitted %s\n' "$job_id"

while :; do
  status_json="$(xcsteward status "$job_id" --json || true)"
  state="$(printf '%s\n' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
  result_class="$(printf '%s\n' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result_class"))')"
  printf '%s %s %s\n' "$job_id" "$state" "$result_class"
  case "$state" in
    queued|running) sleep 2 ;;
    *) break ;;
  esac
done

explanation_json="$(xcsteward explain "$job_id" --json || true)"
artifact_json="$(xcsteward artifacts "$job_id" --json || true)"
printf '%s\n' "$explanation_json"
printf '%s\n' "$artifact_json"
```

For interactive monitoring in Cursor's terminal, use `xcsteward status
"$job_id" --watch` and `xcsteward logs "$job_id" --follow`. For automation,
prefer `status "$job_id" --watch --json` only if the caller can process
newline-delimited `JobSummary` objects.

If a wait seems hung or quiet, query `xcsteward status "$job_id" --json` or
`xcsteward jobs --json` before killing it. If `logs` reports no `combined.log`
yet, the job may still be queued or in simulator/bootstrap setup before
xcodebuild has written logs.

Cancel stale work before starting a conflicting run:

```bash
xcsteward cancel "$job_id" --json
```

For terminal `failed` jobs, start with the `explain` document, then open the
returned `buildLog`, `testLog`, `diagnostics`, or `xcresult` path when needed.
For terminal `canceled` jobs, submit a fresh job instead of reusing stale
artifacts.
