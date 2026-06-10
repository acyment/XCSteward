# XCSteward Result Classes

Use `result_class` and the matching exit code for control flow.

| result_class | Exit | Meaning | Agent action |
|---|---:|---|---|
| `success` | 0 | Tests passed. | Report success and useful artifacts. |
| `test_failure` | 10 | Tests failed. | Do not blind-retry. Inspect `.xcresult`, JUnit, and test logs. |
| `build_failure` | 10 | Build failed. | Do not blind-retry. Inspect build log and command events. |
| `test_timeout` | 11 | Test phase exceeded timeout. | Retry at most once, then investigate timeout or flakiness. |
| `build_timeout` | 11 | Build phase exceeded timeout. | Retry at most once, then inspect build evidence. |
| `runner_bootstrap_failure` | 12 | Host/tooling/profile issue before normal test execution. | Inspect artifacts, run `doctor --json`, fix environment before retrying. |
| `artifact_failure` | 12 | Required result artifacts were missing or invalid. | Inspect artifacts and diagnostics; retry only after understanding the issue. |
| `canceled` | 13 | Job was canceled. | Report cancellation; retry only if incidental. |
| `internal_error` | 14 | XCSteward internal/configuration problem. | Report with artifacts and diagnostics. |
| `unsupported_destination` | 14 | The configured destination is outside current XCSteward support. | Check profile and destination; do not retry blindly. |

Unknown result classes should be treated as non-success, reported with the full
JSON summary and artifact paths, and not retried automatically.
