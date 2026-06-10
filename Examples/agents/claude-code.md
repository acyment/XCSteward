# Claude Code

Use `--json` for every command that supports it, keep the last JSON object in
the transcript, and summarize `state`, `result_class`, and useful artifact
paths for the user.

```bash
project="demo"

summary="$(xcsteward submit --project "$project" --json)"
printf '%s\n' "$summary"

job_id="$(printf '%s\n' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')"

while :; do
  status="$(xcsteward status "$job_id" --json || true)"
  printf '%s\n' "$status"
  state="$(printf '%s\n' "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
  case "$state" in
    queued|running) sleep 2 ;;
    *) break ;;
  esac
done

result_class="$(printf '%s\n' "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result_class"))')"
explanation="$(xcsteward explain "$job_id" --json || true)"
artifacts="$(xcsteward artifacts "$job_id" --json || true)"
printf '%s\n' "$explanation"
printf '%s\n' "$artifacts"
printf 'job_id=%s result_class=%s\n' "$job_id" "$result_class"
```

For a live terminal view, run `xcsteward status "$job_id" --watch`. For a
machine-readable stream, add `--json` and parse each newline-delimited
`JobSummary`. Use `xcsteward logs "$job_id" --follow` when a human wants the
combined log stream.

If a wait seems hung or quiet, query `xcsteward status "$job_id" --json` or
`xcsteward jobs --json` before killing it. If `logs` reports no `combined.log`
yet, the job may still be queued or in simulator/bootstrap setup before
xcodebuild has written logs.

Cancel a stale queued or running job:

```bash
xcsteward cancel "$job_id" --json
```

When `result_class` is `runner_bootstrap_failure` or `artifact_failure`,
inspect artifacts before retrying because those classes usually indicate host
or tooling trouble rather than app test assertions.
