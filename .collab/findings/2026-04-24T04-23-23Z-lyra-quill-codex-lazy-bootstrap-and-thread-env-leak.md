## Summary

Two Codex identity problems were still present after the earlier request-metadata fix:

1. Managed Codex MCP sessions started without `C2C_MCP_SESSION_ID`, so startup auto-register never ran. The session only became usable after a manual `c2c register`.
2. `c2c start codex` still seeded `CODEX_THREAD_ID=<instance-name>` in the managed child env, and also inherited the parent shell's real `CODEX_THREAD_ID`. That mixed managed-session identity with native Codex thread identity.

## Symptoms

- `mcp__c2c__whoami` stopped erroring, but returned an empty result until a manual CLI `c2c register`.
- `c2c list --json` showed no live registration for `Lyra-Quill-X` even though the Codex session was up.
- The live shell had both:
  - `C2C_MCP_SESSION_ID=Lyra-Quill-X`
  - `CODEX_THREAD_ID=<real codex thread>`
- `~/.local/share/c2c/mcp-debug/no-session.log` showed Codex MCP server startups under `no-session`, proving the server still launched without session env.
- A focused Python repro showed the broker row being created as `session_id=lyra-quill` on first `whoami`, meaning fallback alias-derivation had won instead of managed-session recovery.

## Root Cause

### Lazy bootstrap gap

Request-time Codex metadata recovery was only being used to resolve individual tool calls. That fixed `whoami`/`poll_inbox` session lookup, but not startup registration. Since Codex does not reliably pass `C2C_MCP_SESSION_ID` into the MCP subprocess, startup auto-register never had enough identity to bind the managed alias.

### Native thread env leak

`build_env` still did two wrong things for Codex:

- explicitly added `CODEX_THREAD_ID=<instance-name>`
- failed to strip inherited `CODEX_THREAD_ID` from the parent shell

That made the managed child start with a misleading native-thread env before Codex had established its real thread id.

## Fix

- Added request-time self-heal:
  - `ensure_request_session_bootstrap`
  - `auto_register_impl`
  - `auto_join_rooms_impl`
- On `tools/call`, when request metadata yields a managed Codex session id, c2c now:
  - auto-registers the alias
  - auto-joins configured rooms
  - then serves the tool call
- Removed explicit Codex `CODEX_THREAD_ID` seeding from `build_env`
- Added `CODEX_THREAD_ID` to the inherited native session keys stripped from managed child env

## Verification

- `opam exec -- dune exec ./ocaml/test/test_c2c_start.exe --no-buffer --force`
- `_build/default/ocaml/test/test_c2c_mcp.exe`
- `python3 -m pytest -q tests/test_c2c_mcp_channel_integration.py -k 'codex_turn_metadata_maps_to_managed_session_id or codex_whoami_lazy_bootstraps_managed_registration' --force-test-env`

## Severity

High. This was a real dogfood failure for managed Codex sessions: MCP looked half-alive but did not fully join the broker until an operator manually repaired identity. The leaked `CODEX_THREAD_ID` also risked subtle confusion between managed session ids and native Codex thread ids.
