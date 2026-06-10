---
name: xcsteward-agent-driver
description: Use when Claude needs to run, monitor, or diagnose iOS Simulator tests through XCSteward in this repository. Use the CLI JSON contract directly; do not add an MCP or protocol wrapper.
---

# XCSteward Agent Driver

This project-local skill entrypoint delegates to the canonical vendor-neutral
skill in this repository:

`../../../Examples/agents/skills/xcsteward/SKILL.md`

Before running or diagnosing XCSteward jobs, read that canonical skill and
follow it. In particular, if a `submit --wait` command looks quiet or hung,
check the same state root with `status --json`, `jobs --json`, or
`status --watch` before killing or retrying the job.
