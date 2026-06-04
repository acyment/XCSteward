# Agent workflow examples

> Start with the canonical, vendor-neutral guide: [`AGENTS.md`](../../AGENTS.md)
> (the loop, outcome interpretation, and retry policy), backed by the interface
> spec in [`CONTRACT.md`](../../CONTRACT.md). The files here are short
> tool-specific snippets of that same loop.

These examples show the minimal machine-consumable loop for agents that submit
XCSteward jobs, poll status, inspect artifacts, and cancel stale work.

- [Claude Code](claude-code.md)
- [Codex](codex.md)
- [Cursor](cursor.md)

Replace `demo` with the configured profile name under
`$XCSTEWARD_HOME/projects` or
`~/Library/Application Support/XCSteward/projects`.
