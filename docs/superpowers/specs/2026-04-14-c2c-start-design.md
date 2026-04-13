# `c2c start` — Unified Instance Launcher

## Problem

The current harness system (`run-*-inst`, `run-*-inst-outer`, `c2c_restart_me.py`) has grown organically across 5 client types. Each client has 2 scripts (inner + outer loop), a configure script, and scattered state in `run-*-inst.d/` directories. Per-agent aliases leak into global config files (`~/.codex/config.toml`, `~/.kimi/mcp.json`), causing alias drift bugs when non-harness sessions inherit stale values.

## Goal

Replace all 10 harness scripts with a single `c2c start <client> [-n NAME]` command that:
- Sets up env vars (session_id, alias, broker root, client PID) correctly
- Manages the outer restart loop, deliver daemon, and poker
- Stores instance state in a standard location
- Provides lifecycle commands (stop, restart, instances)

## CLI Interface

```
c2c start <client> [-n NAME] [--] [EXTRA_ARGS...]
c2c stop <NAME>
c2c instances [--json]
c2c restart <NAME>
```

### Arguments

| Arg | Required | Description |
|-----|----------|-------------|
| `client` | yes | One of: `claude`, `codex`, `opencode`, `kimi`, `crush` |
| `-n NAME` | no | Instance name. Sets both `session_id` and `alias` to NAME. Default: `<client>-<hostname>` |
| `EXTRA_ARGS` | no | Passed through to the client binary after `--` |

### Examples

```bash
c2c start claude -n story-tree              # Claude Code with alias "story-tree"
c2c start codex -n aalto                    # Codex with alias "aalto"
c2c start opencode                          # OpenCode with default name "opencode-<hostname>"
c2c start kimi -n nova -- --model k2        # Kimi with extra args
c2c stop story-tree                         # Stop the instance
c2c restart aalto                           # Restart with same config
c2c instances                               # List all running instances
c2c instances --json                        # Machine-readable output
```

## Foreground vs Background

By default, `c2c start` runs in the foreground — it prints instance status and blocks until `Ctrl+C` or `c2c stop`. The outer loop, deliver daemon, and poker run as background subprocesses.

With `--detach` flag, `c2c start` forks into the background immediately and prints the instance name + PID. This is equivalent to `nohup c2c start ... &` but cleaner.

```bash
c2c start claude -n story-tree            # foreground (default)
c2c start claude -n story-tree --detach   # background
```

## Error Handling

- **Binary not found**: `c2c start` checks that the client binary exists in PATH before launching. If missing, prints install instructions and exits 1.
- **Duplicate name**: if an instance with the same name is already running (pidfile exists and PID is alive), refuses to start and suggests `c2c restart` or `c2c stop` first.
- **Stale pidfile**: if pidfile exists but PID is dead, cleans up stale state and starts fresh.

## Launch Sequence

When `c2c start` runs:

1. **Validate**: check client type exists, check name not already running (by pidfile)
2. **Auto-configure**: if no MCP config exists for this client type, run `c2c setup <client>` automatically (without `C2C_MCP_AUTO_REGISTER_ALIAS` in global config)
3. **Env setup**: set environment for the client subprocess:
   - `C2C_MCP_SESSION_ID=<name>`
   - `C2C_MCP_AUTO_REGISTER_ALIAS=<name>`
   - `C2C_MCP_BROKER_ROOT=<broker_root>`
   - `C2C_MCP_CLIENT_PID=<outer_loop_pid>`
   - `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`
   - `C2C_MCP_AUTO_DRAIN_CHANNEL=0`
4. **Write instance state** to `~/.local/share/c2c/instances/<name>/config.json`
5. **Fork outer loop**: daemonize (double-fork + setsid), write `outer.pid`
6. **Outer loop** (per iteration):
   - Launch client subprocess with env
   - Start deliver daemon (`c2c_deliver_inbox.py --notify-only --loop`)
   - Start poker if client needs it (`c2c_poker.py --interval 600`)
   - Call `c2c_refresh_peer.py <name> --pid <child_pid> --session-id <name>`
   - Wait for child exit
   - On crash: exponential backoff (2s → 60s max), restart
   - On clean exit (0): stop loop
7. **Cleanup** on `c2c stop`: SIGTERM outer loop → outer loop SIGTERMs child + deliver daemon + poker

## State Directory

```
~/.local/share/c2c/instances/<name>/
├── config.json        # instance config (see below)
├── outer.pid          # outer loop PID
├── deliver.pid        # deliver daemon PID (if running)
├── poker.pid          # poker PID (if running)
├── outer.log          # outer loop stderr/stdout
├── deliver.log        # deliver daemon log
└── poker.log          # poker log
```

### config.json schema

```json
{
  "name": "story-tree",
  "client": "claude",
  "session_id": "story-tree",
  "alias": "story-tree",
  "extra_args": [],
  "created_at": 1776117000,
  "broker_root": "/home/xertrov/src/c2c-msg/.git/c2c/mcp",
  "auto_join_rooms": "swarm-lounge"
}
```

## Per-Client Config

Internal dict in `c2c_start.py`:

```python
CLIENT_CONFIGS = {
    "claude": {
        "binary": "claude",
        "deliver_client": "claude",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "claude-poker",
    },
    "codex": {
        "binary": "codex",
        "deliver_client": "codex",
        "needs_poker": False,
    },
    "opencode": {
        "binary": "opencode",
        "deliver_client": "opencode",
        "needs_poker": False,
    },
    "kimi": {
        "binary": "kimi",
        "deliver_client": "kimi",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "kimi-poker",
    },
    "crush": {
        "binary": "crush",
        "deliver_client": "crush",
        "needs_poker": False,
    },
}
```

## MCP Config Fix (Side Effect)

### Before (broken)
`c2c configure-codex` writes to `~/.codex/config.toml`:
```toml
C2C_MCP_AUTO_REGISTER_ALIAS = "codex-xertrov-x-game"
```
This leaks into ALL Codex sessions, causing alias drift.

### After (fixed)
`c2c configure-codex` writes to `~/.codex/config.toml`:
```toml
# No C2C_MCP_AUTO_REGISTER_ALIAS — set by c2c start via env
```
`c2c start codex -n aalto` sets `C2C_MCP_AUTO_REGISTER_ALIAS=aalto` in env.

Same fix applies to all 5 configure scripts.

### Non-harness sessions
Running the client directly (without `c2c start`) will:
- Use `default_session_id()` for session_id (auto-detected from process context)
- Use session_id as alias (since `C2C_MCP_AUTO_REGISTER_ALIAS` is not set)
- Can call `register` explicitly to set a custom alias

## Deprecated Scripts

The following become dead code after this lands:

| Old script | Replaced by |
|------------|-------------|
| `run-claude-inst` | `c2c start claude` |
| `run-claude-inst-outer` | outer loop in `c2c_start.py` |
| `run-codex-inst` | `c2c start codex` |
| `run-codex-inst-outer` | outer loop in `c2c_start.py` |
| `run-opencode-inst` | `c2c start opencode` |
| `run-opencode-inst-outer` | outer loop in `c2c_start.py` |
| `run-kimi-inst` | `c2c start kimi` |
| `run-kimi-inst-outer` | outer loop in `c2c_start.py` |
| `run-crush-inst` | `c2c start crush` |
| `run-crush-inst-outer` | outer loop in `c2c_start.py` |
| `c2c_restart_me.py` | `c2c restart <name>` |
| `c2c_poker_sweep.py` | integrated into instance cleanup |

Note: the rearm scripts (`run-kimi-inst-rearm`, `run-opencode-inst-rearm`) may still be needed for refresh-peer logic. Keep them unless the refresh-peer logic moves into `c2c_start.py`.

## Wiring

### c2c_cli.py
Add dispatch for `start`, `stop`, `instances`, `restart`.

### c2c_install.py
Add wrapper scripts: `c2c-start`, `c2c-stop`, `c2c-instances`, `c2c-restart`.

### USAGE string
Add to the command list.

### CLAUDE.md
Update "Recommended Monitor setup" and harness references to use `c2c start`.

### c2c_setup.py
Update post-setup instructions to suggest `c2c start <client> -n <name>` instead of manual outer loop launch.

### c2c_health.py
Add instance status to health output (which instances are running, deliver daemon status, poker status).

## Testing

### Unit tests (in `tests/test_c2c_cli.py`)

- `C2CStartUnitTests`:
  - `test_default_name_uses_hostname`: verify default name is `<client>-<hostname>`
  - `test_explicit_name_sets_session_and_alias`: verify `-n foo` sets both
  - `test_duplicate_name_rejected`: verify can't start two instances with same name
  - `test_invalid_client_rejected`: verify unknown client type errors
  - `test_env_setup_includes_all_vars`: verify env dict has all required vars
  - `test_config_json_written`: verify instance config is written
  - `test_extra_args_passed_through`: verify `--` separator works
- `C2CStopUnitTests`:
  - `test_stop_sends_sigterm`: verify SIGTERM sent to outer loop
  - `test_stop_cleans_pidfiles`: verify pidfiles removed
  - `test_stop_nonexistent_errors`: verify error for unknown name
- `C2CInstancesUnitTests`:
  - `test_instances_lists_running`: verify running instances listed
  - `test_instances_json_output`: verify --json format
  - `test_instances_empty`: verify empty list when no instances
- `C2CConfigureAliasFixTests`:
  - `test_configure_codex_no_alias`: verify configure-codex doesn't write AUTO_REGISTER_ALIAS
  - `test_configure_kimi_no_alias`: verify configure-kimi doesn't write AUTO_REGISTER_ALIAS

### Integration tests
- `test_start_creates_instance_dir`: verify state directory created
- `test_start_stop_lifecycle`: verify start → stop cleans up

## Acceptance Criteria

1. `c2c start claude -n story-tree` launches Claude Code with correct env, starts deliver daemon + poker, and outer restart loop
2. `c2c instances` shows running instances with name, client type, PID, uptime
3. `c2c stop story-tree` cleanly shuts down all processes
4. `c2c restart story-tree` stop + start with same config
5. No per-agent aliases in global config files (fixes alias drift)
6. All 5 client types supported
7. Existing tests pass (no regressions)
8. New unit tests cover start/stop/instances logic
