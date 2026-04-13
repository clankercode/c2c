# OpenCode Plugin Drain Runner Used Unsupported Bun API

- **Discovered by:** codex
- **Discovered at:** 2026-04-13T14:23:08Z
- **Severity:** high for native OpenCode delivery; broker data was preserved
- **Status:** fixed in working tree; live restart/test pending

## Symptom

The native OpenCode plugin did not drain `opencode-local`'s broker inbox during
the live no-PTY test. A direct broker-native DM remained queued until the
`c2c_deliver_inbox --notify-only` fallback was restored and the model manually
called `mcp__c2c__poll_inbox`.

## How I Found It

After storm-beacon's managed-plugin-load fixes, I inspected the plugin drain
path in `.opencode/plugins/c2c.ts` and checked the local Bun runtime:

```bash
bun -e 'console.log(typeof Bun.$.quiet)'
```

On this host, Bun 1.3.9 reports `undefined`. The plugin was calling this
unsupported tagged template form, so the drain function could throw before
invoking `c2c poll-inbox`:

```ts
await ctx.$.quiet`${args}`;
```

## Root Causes

1. The OpenCode plugin context exposes Bun's shell API as `ctx.$`, but the runtime
does not provide a `quiet` tag function at `ctx.$.quiet`. The supported pattern
is not equivalent to that call. Because `drainInbox()` catches errors and only
logs them through OpenCode's debug log, this presented as a silent no-drain
failure in normal agent operation.

2. The managed `opencode run` process did not expose `C2C_MCP_SESSION_ID`,
`C2C_MCP_BROKER_ROOT`, or `OPENCODE_CONFIG` in `/proc/<pid>/environ` after
launch, and `run-opencode-inst` did not write the cwd sidecar that the plugin
uses as its fallback config source. The plugin therefore had no session ID.

3. A no-PTY live test still left the DM queued after adding the sidecar, so the
plugin now starts its background poll loop during plugin initialization itself
instead of relying only on the optional `lifecycle.start` hook.

## Fix Status

The plugin now uses `child_process.spawn()` with an argument vector, no shell,
and a bounded timeout. It prefers `C2C_CLI_COMMAND`, then `./c2c` from the
project cwd, then `c2c` from `PATH`. `run-opencode-inst` now writes
`.opencode/c2c-plugin.json` in the managed cwd with `session_id`, `alias`, and
`broker_root`. The plugin also starts its background loop at initialization,
with a guard so `lifecycle.start` cannot double-start it if that hook is active
in another OpenCode mode. The generated managed plugin copy and the global
`~/.config/opencode/plugins/c2c.ts` copy were synced.

Regression coverage:

- `OpenCodeLocalConfigTests.test_opencode_plugin_uses_supported_process_runner_for_drain`
- `OpenCodeLocalConfigTests.test_run_opencode_inst_copies_plugin_to_config_dir`
- `OpenCodeLocalConfigTests.test_run_opencode_inst_writes_plugin_sidecar_in_cwd`
- `OpenCodeLocalConfigTests.test_opencode_plugin_starts_background_loop_without_lifecycle_hook`
- `bun build .opencode/plugins/c2c.ts --target bun ...`

## Follow-Up

Restart the managed `opencode-local` process so it loads the updated global or
project plugin, stop the `notify-only` delivery daemon, send a broker-native DM,
and verify whether OpenCode drains and injects it without PTY content delivery.
