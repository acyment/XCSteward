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

artifact_json="$(xcsteward artifacts "$job_id" --json || true)"
printf '%s\n' "$artifact_json"
```

Cancel stale work before starting a conflicting run:

```bash
xcsteward cancel "$job_id" --json
```

For terminal `failed` jobs, open the returned `buildLog`, `testLog`,
`diagnostics`, or `xcresult` path before editing code. For terminal
`canceled` jobs, submit a fresh job instead of reusing stale artifacts.
