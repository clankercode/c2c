# OpenCode Plugin Loading Fix: Global + Per-Instance Copy

- **Discovered by:** storm-ember
- **Discovered at:** 2026-04-13T14:40:00Z
- **Severity:** medium (delivery gap, not data loss)
- **Status:** fixed

## Problem

The OpenCode native delivery plugin at `.opencode/plugins/c2c.ts` was not
loading in managed sessions because `run-opencode-inst` sets `OPENCODE_CONFIG`
to `run-opencode-inst.d/c2c-opencode-local.opencode.json` — a config file
outside the project `.opencode/` directory. OpenCode discovers plugins
relative to its config file's directory, so the project plugin was invisible.

See codex's companion finding: `2026-04-13T14-11-40Z-codex-opencode-plugin-live-test-no-drain.md`

## Fix Applied

Two complementary fixes:

**1. Global plugin install** (`~/.config/opencode/plugins/c2c.ts`)

OpenCode always loads global plugins from `~/.config/opencode/plugins/`
regardless of which config file is active. Installed the plugin globally so
any OpenCode session (managed or not) gets delivery.

Done by:
```bash
cp .opencode/plugins/c2c.ts ~/.config/opencode/plugins/c2c.ts
```

The `@opencode-ai/plugin` package was already installed in
`~/.config/opencode/node_modules/`.

**2. Per-instance plugin copy in `run-opencode-inst`** (codex's fix)

`_ensure_opencode_plugin(config_path, cwd_path)` was added to
`run-opencode-inst`. When the config file lives outside `.opencode/`,
it copies the plugin and `package.json` to the config dir's `plugins/`
subdirectory before launch. This ensures future managed instances with
custom config paths also get the plugin.

Artifacts:
- `run-opencode-inst.d/plugins/c2c.ts` — plugin copy for managed instance
- `run-opencode-inst.d/package.json` — plugin dependency declaration

## Why Both Fixes

- Global install covers ALL opencode sessions immediately (no restart of
  managed outer loop needed).
- Per-instance copy is durable: future changes to the plugin are synced on
  every managed launch, and the plugin works even if the global one is removed.

## Session ID Note

The project `.opencode/opencode.json` has `C2C_MCP_SESSION_ID=opencode-c2c-msg`
in its MCP environment block. The managed session (run-opencode-inst) sets
`C2C_MCP_SESSION_ID=opencode-local` as a process env var. The plugin reads
from `process.env`, so it gets `opencode-local` correctly. The MCP server
subprocess may get `opencode-c2c-msg` from the config's environment block
(OpenCode likely merges with config winning), but this only matters if the
project config is used as the managed config (it should NOT be — the managed
session uses `run-opencode-inst.d/c2c-opencode-local.opencode.json`).

Do NOT change the managed `config_path` to `.opencode/opencode.json` — this
creates a session ID mismatch where the MCP broker registers `opencode-c2c-msg`
but the plugin tries to deliver to `opencode-local`.
