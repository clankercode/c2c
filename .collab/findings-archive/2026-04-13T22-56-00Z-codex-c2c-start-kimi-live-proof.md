# c2c start Kimi per-instance identity proof

## Symptom

`c2c start kimi -n <instance>` successfully launched a Kimi child with c2c MCP
tools, but the child registered and spoke as `kimi-nova-2` instead of the
requested instance name.

## Discovery

Codex launched:

```bash
./c2c start kimi -n kimi-start-proof-codex -- --print --final-message-only -p ...
```

The live Kimi run completed its room send, but `mcp__c2c__whoami` returned
`kimi-nova-2`. Inspecting `~/.kimi/mcp.json` showed a global c2c server config
with hard-coded `C2C_MCP_SESSION_ID=kimi-nova` and
`C2C_MCP_AUTO_REGISTER_ALIAS=kimi-nova`, so the Kimi CLI's MCP config overrode
the managed instance environment.

## Root Cause

`c2c start` was setting per-instance environment variables for the managed
process, but Kimi reads MCP server environment from its MCP config file. When no
explicit `--mcp-config-file` was provided, Kimi loaded the global config and
spawned the c2c MCP server with stale global identity.

## Fix Status

Fixed in the current tree:

- `c2c_start.prepare_launch_args()` now writes
  `~/.local/share/c2c/instances/<name>/kimi-mcp.json` for managed Kimi
  launches.
- The generated config pins `C2C_MCP_SESSION_ID`,
  `C2C_MCP_AUTO_REGISTER_ALIAS`, broker root, auto-join rooms, and safe
  auto-drain defaults for the named instance.
- If the operator supplies `--mcp-config-file` or `--mcp-config`, c2c respects
  that explicit config and does not inject another one.

## Verification

RED:

```bash
python3 -m pytest tests/test_c2c_cli.py::C2CStartUnitTests -q
```

Failed with missing `prepare_launch_args`.

GREEN:

```bash
python3 -m pytest tests/test_c2c_cli.py::C2CStartUnitTests -q
```

Passed: `19 passed`.

Syntax:

```bash
python3 -m py_compile c2c_start.py tests/test_c2c_cli.py
```

Passed.

Live proof:

```bash
./c2c start kimi -n kimi-start-proof-codex2 -- --print --final-message-only -p ...
```

Kimi reported `mcp__c2c__whoami` as `kimi-start-proof-codex2` and sent room
marker:

```text
C2C_START_KIMI_INSTANCE_ID_PROOF_1776121240 alias=kimi-start-proof-codex2 session_id=kimi-start-proof-codex2
```

The proof instance was stopped, its generated instance state was removed, and
`mcp__c2c__prune_rooms` evicted the dead proof room membership.

## Severity

High for managed Kimi: the start command appeared to work while silently
registering under the wrong identity, which breaks per-instance routing and
confuses room membership.
