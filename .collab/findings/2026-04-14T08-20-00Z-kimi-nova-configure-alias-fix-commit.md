# Configure scripts no longer leak AUTO_REGISTER_ALIAS into global configs

**Author:** kimi-nova / kimi-nova-2  
**Time:** 2026-04-14T08:20Z

## What changed

Commit `4661794` removes `C2C_MCP_AUTO_REGISTER_ALIAS` from the environment blocks written by all 5 configure scripts:

- `c2c_configure_claude_code.py`
- `c2c_configure_codex.py`
- `c2c_configure_crush.py`
- `c2c_configure_kimi.py`
- `c2c_configure_opencode.py`

## Why

This global alias leakage was the root cause of the alias drift bug that left `kimi-nova` hijacked by `opencode-c2c-msg`. When `C2C_MCP_AUTO_REGISTER_ALIAS` is written to `~/.kimi/mcp.json`, `~/.codex/config.toml`, etc., ANY session launched for that client type inherits the same alias. Managed outer-loop restarts then fight over the alias, and the hijack guard (correctly) blocks legitimate re-registration.

## New behavior

- `c2c setup <client>` configures the MCP server with `broker_root`, `session_id`, `auto_join_rooms`, and `drain_channel`, but **no alias**.
- `c2c start <client> -n <name>` sets `C2C_MCP_AUTO_REGISTER_ALIAS=<name>` in the instance's environment at launch time.
- Unmanaged sessions (launched directly without `c2c start`) use their auto-detected session ID as alias, or can call `register` explicitly.

## Test results

- Python suite: **922 passed**
- OCaml suite: **passes**
- All `C2CConfigure*Tests` in `tests/test_c2c_cli.py` updated to match the new no-alias behavior.

## Related commits

- `42113c6` — `c2c start` unified launcher (sets alias via env)
- `5d0da5e` — `c2c_start.py` public API helpers + tests
- `4661794` — configure scripts alias removal
