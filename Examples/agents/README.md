# Agent workflow examples

> Start with the canonical, vendor-neutral guide: [`AGENTS.md`](../../AGENTS.md)
> (the loop, outcome interpretation, and retry policy), backed by the interface
> spec in [`CONTRACT.md`](../../CONTRACT.md). The files here are short
> tool-specific snippets of that same loop.

These examples show the minimal machine-consumable loop for agents that submit
XCSteward jobs, poll status, inspect artifacts, and cancel stale work.
For an interactive human terminal, `xcsteward status <job-id> --watch` prints
compact updates and `xcsteward logs <job-id> --follow` tails the combined log.
For machine streaming, `status --watch --json` emits newline-delimited
`JobSummary` objects; keep branching on JSON, not human text.

If a `submit --wait` command appears quiet for a long time, do not infer that
XCSteward is hung. Check the same state root with `xcsteward status <job-id>
--json`, `xcsteward jobs --json`, or a human `status <job-id> --watch`. When
`combined.log` is not available yet, the job may still be queued or in
simulator/bootstrap setup before xcodebuild has written logs.

- [Claude Code](claude-code.md)
- [Codex](codex.md)
- [Cursor](cursor.md)
- [Reusable generic agent skill](skills/xcsteward/SKILL.md)

Replace `demo` with the configured profile name under
`$XCSTEWARD_HOME/projects` or
`~/Library/Application Support/XCSteward/projects`.

If no profile exists yet and the repository has a single shared project or
workspace, run `xcsteward profile init --detect --json` from the repo root and
follow the returned `next_commands`.
