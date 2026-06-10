# Claude Project Instructions

Use the project-wide agent guide in [`AGENTS.md`](AGENTS.md) as the source of
truth for running, monitoring, and diagnosing XCSteward jobs.

When running iOS Simulator tests from Claude or Claude Code:

- Use XCSteward instead of calling `xcodebuild` directly.
- Use `--json` for command output and branch on `state`, `result_class`, and
  exit code.
- If a wait looks quiet or hung, inspect the same state root with
  `xcsteward status <job-id> --json`, `xcsteward jobs --json`, or
  `xcsteward status <job-id> --watch` before killing or retrying.
- If `logs` reports no `combined.log` yet, the job may still be queued or in
  simulator/bootstrap setup before xcodebuild has written logs.

Claude skill entrypoint: [`.claude/skills/xcsteward/SKILL.md`](.claude/skills/xcsteward/SKILL.md).
