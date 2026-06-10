# Prompt: Update `XCSteward-website` For Current DevX

You are working in `/Users/acyment/dev/XCSteward-website`.

Update the website to reflect the current XCSteward developer experience from
`/Users/acyment/dev/XCSteward`. Treat the source repo docs as authoritative:

- `/Users/acyment/dev/XCSteward/README.md`
- `/Users/acyment/dev/XCSteward/CONTRACT.md`
- `/Users/acyment/dev/XCSteward/AGENTS.md`
- `/Users/acyment/dev/XCSteward/Examples/agents/skills/xcsteward/SKILL.md`

## New Product Points To Surface

- Plain human `submit --wait` is no longer a silent black box. It prints the
  queued job id, status/log/watch/follow commands, job directory, and compact
  wait updates.
- `status <job-id> --watch [--interval <seconds>]` polls until terminal.
  Human mode prints compact updates; `--watch --json` emits newline-delimited
  full `JobSummary` objects.
- `logs <job-id> --follow` streams the combined log until the job is terminal.
- Machine users should keep using `--json`; long-running JSON waits can add
  `--progress` for JSON-lines events on stderr.
- `--progress` events now include phase context when command-events are
  available: `phase` and `phase_elapsed_seconds`.
- `submit --env KEY=VALUE` is repeatable and overrides profile `[env]` for that
  job only. Website copy should describe this as per-run environment injection
  for `xcodebuild`, while noting that XCSteward records env override keys, not
  sensitive values.
- Agent DevX now includes:
  - reusable generic agent skill under `Examples/agents/skills/xcsteward/`
  - `projects --json`
  - `profile show <name> --json`
  - `profile init --detect --json`
  - `explain <job-id> --json`
  - `submit --metadata key=value` and `--label`
  - `submit --env KEY=VALUE`
  - `cleanup --caches`

## New Simulator Bootstrap Diagnosis To Surface

XCSteward now makes pre-XCTest simulator/bootstrap failures explicit instead of
letting users infer whether a run was stuck, flaky, or an app-code regression.

Surface this as a practical DevX improvement, not a cure-all:

- CoreSimulator / launch session failures before XCTest attaches are classified
  as `runner_bootstrap_failure`, not `test_failure`.
- The tool recognizes signatures such as `Unable to boot the Simulator`,
  `launchd failed to respond`, `Failed to start launchd_sim`,
  `NSPOSIXErrorDomain code=60`, `Failed to prepare device`, testmanagerd
  connection loss, and similar pre-test runner/bootstrap failures.
- `submit --wait` and `status` now say the run failed before XCTest attached,
  preserve the underlying CoreSimulator / `launchd_sim` detail, and include a
  bounded remediation hint such as shutting down or erasing the selected
  simulator before retrying once.
- If build succeeds but the test runner never really starts, XCSteward still
  treats the outcome as an environment/bootstrap failure rather than a real
  test execution failure.
- If `xcodebuild test-without-building` times out before XCSteward observes
  XCTest attach evidence, the job is classified as `runner_bootstrap_failure`
  with `diagnostic_excerpt.subtype = "pre_xctest_timeout"`, not plain
  `test_timeout`.
- The final summary says `XCTest did not attach before the test command timed
  out`, and terminal JSON can include the phase, timeout seconds, evidence
  paths, and a capped diagnostic excerpt.
- `explain <job-id> --json` repeats this classification and recommended action
  for agents.
- When a job is queued or in simulator/bootstrap setup and no
  `logs/combined.log` exists yet, `logs <job-id>` reports that the combined log
  is pending and points users back to `status <job-id> --watch` instead of
  failing with an opaque missing-file error.
- `doctor` still keeps project preflight bounded, but the `.xctestrun`
  integrity timeout warning now says when no compiler error was observed before
  timeout. Present this as clearer diagnosis for cold/long builds, not as an
  unlimited doctor run.

Suggested website phrasing:

> If CoreSimulator fails before XCTest attaches, XCSteward reports an
> environment failure with the simulator error and artifacts, rather than
> making you decide from a silent terminal or raw `xcodebuild` output whether
> the app regressed.

Suggested phrasing for the timeout-before-attach case:

> If the test command times out before XCTest ever attaches, XCSteward calls
> that out as a runner/bootstrap failure with a compact diagnostic excerpt,
> instead of labeling it as a timed-out test case.

## Website Files Likely To Change

Inspect first, then edit only what needs to change:

- `src/lib/site-content.ts`: shared positioning copy.
- `src/pages/index.astro`: homepage feature/CTA sections.
- `src/pages/try.astro`: alpha try-it workflow.
- `src/pages/llms.txt.ts` and `src/pages/llms-full.txt.ts`: machine-readable
  guidance for coding agents.
- `src/content/failures/coding-agents-ios-simulator-tests.md`
- `src/content/failures/multiple-xcodebuild-processes-same-mac.md`
- Any nearby failure page that mentions silent `xcodebuild`, agent loops, logs,
  or queue monitoring.

## Copy Requirements

- Keep the current cautious website voice. Do not claim XCSteward fixes,
  solves, eliminates, or guarantees anything.
- Keep the dual framing: single-run Xcode/Simulator fragility is real, and
  coding agents/scripts/local CI amplify it.
- Do not present XCSteward as a dashboard, SaaS, MCP layer, or hosted service.
  The product surface is the CLI and its JSON contract.
- Distinguish human UX from machine contract:
  - humans: `submit --wait`, `status --watch`, `logs --follow`
  - agents/automation: `--json`, `--progress`, `status --watch --json` as NDJSON
- Include one concise example that shows the no-longer-silent human path:

```bash
xcsteward submit --project app --wait --wait-timeout 900
xcsteward status <job-id> --watch
xcsteward logs <job-id> --follow
```

- Include one concise agent path:

```bash
xcsteward profile init --detect --json
xcsteward submit --project app --wait --wait-timeout 900 --json --progress --env API_BASE_URL=http://127.0.0.1:8080
xcsteward explain <job-id> --json
```

- Include one concise failure-inspection path:

```bash
xcsteward status <job-id> --watch
xcsteward explain <job-id> --json
xcsteward logs <job-id>
```

- If mentioning `runner_bootstrap_failure`, define it plainly as: runner or
  environment setup failed before XCTest attached. Do not imply it is always
  caused by a broken simulator; keep room for destination, launch session,
  artifact, or runner setup issues.
- If mentioning `pre_xctest_timeout`, define it plainly as: the test command
  hit its timeout before XCSteward observed XCTest attach/test execution
  evidence.
- Do not show env values from real user systems. Use placeholder values in
  examples and say metadata records keys only.

## Validation

Run the website gate before calling the task done:

```bash
pnpm verify
```

If verification cannot run, report the exact blocker and which files were
changed.
