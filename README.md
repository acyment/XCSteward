# XCSteward

Local macOS CLI for serializing iOS simulator test jobs across projects and coding agents.

## Commands

Build:

```bash
swift test
```

Run the built binary:

```bash
./.build/arm64-apple-macosx/debug/xcsteward doctor --json
```

Discover the CLI from the binary itself:

```bash
xcsteward --help
xcsteward submit --help
```

Core commands:

```bash
xcsteward submit --project <name> [--wait] [--json]
xcsteward status <job-id> [--json]
xcsteward jobs [--json]
xcsteward logs <job-id>
xcsteward artifacts <job-id> [--json]
xcsteward cancel <job-id> [--json]
xcsteward doctor [--project <name>] [--fix] [--json]
```

Use `--state-root <path>` to point the CLI at a specific local state directory. By default it uses `~/Library/Application Support/XCSteward`.

## Profile schema

Profiles live under:

```text
<state-root>/projects/<name>.toml
```

Example:

```toml
repo_root = "/absolute/path/to/repo"
project_path = "App.xcodeproj"
scheme = "App"
default_simulator_id = "SIM-123"
default_test_plan = "Stable"
allowed_simulator_ids = ["SIM-123"]

[timeouts]
boot = 30
build = 600
test = 600

[env]
FOO = "bar"
```

Managed simulator example:

```toml
repo_root = "/absolute/path/to/repo"
project_path = "App.xcodeproj"
scheme = "App"

[managed_simulator]
name = "App Test iPhone 17 Pro"
device_type = "iPhone 17 Pro"
runtime = "iOS 26.4"
```

Sample dogfood profiles are under [Examples/profiles](/Users/acyment/dev/XCSteward/Examples/profiles).
