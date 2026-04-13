# OpenCode dry-run sidecar drift

- **Symptom:** The live `.opencode/c2c-plugin.json` sidecar pointed at
  `session_id=ses-internal-abc123` and `alias=opencode-special` while the
  managed `opencode-local` config and broker registration pointed at
  `opencode-local`.
- **How discovered:** While reviewing OpenCode restart state, `run-opencode-inst`
  config, pidfiles, and the live sidecar disagreed. The stale values matched a
  launcher dry-run test fixture.
- **Root cause:** `run-opencode-inst` dry-run still executed setup side effects:
  it copied plugin files and rewrote `.opencode/c2c-plugin.json` before printing
  the dry-run JSON. One test used the real repo as `cwd` with fake alias/session
  values, so a focused test run could silently corrupt the ignored live sidecar.
- **Fix status:** Fixed in Codex work after this finding. Dry-run no longer
  applies plugin-copy or sidecar-write side effects. Tests that need to verify
  those side effects now run a harmless short-lived fake command instead of
  relying on dry-run mutation. `run-opencode-inst-rearm` now refreshes the
  plugin sidecar from the managed config, so rearming support loops repairs this
  drift in live sessions.
- **Severity:** High for agent UX. The broker and PTY wake loops can look
  healthy while the native OpenCode plugin polls or attributes the wrong
  session, making plugin delivery failures misleading.
