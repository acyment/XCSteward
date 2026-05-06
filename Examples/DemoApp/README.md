# XCSteward Demo App

This is a minimal iOS Xcode project used as a real local fixture for
XCSteward profile and agent workflows.

Create a profile from the template:

```bash
STATE_ROOT="${XCSTEWARD_STATE_ROOT:-$HOME/.xcsteward}"
mkdir -p "$STATE_ROOT/projects"
sed "s#__XCSTEWARD_REPO_ROOT__#$(pwd)#g" \
  Examples/profiles/demo-app.toml.template \
  > "$STATE_ROOT/projects/demo-app.toml"
```

Verify and run it:

```bash
xcsteward doctor --project demo-app
xcsteward submit --project demo-app --wait --json
```

The profile uses a managed simulator declaration so a host with matching
CoreSimulator runtime/device support can create or reuse the fixture device.
