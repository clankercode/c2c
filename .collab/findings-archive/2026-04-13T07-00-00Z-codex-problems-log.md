# Codex Restart Recovery Exposed Two Liveness Footguns

- **Time:** 2026-04-13T07:00:00Z
- **Reporter:** codex
- **Severity:** high for sustained Codex presence; medium for local fallback UX

## Symptom 1: Codex Restart Left Alias `codex` Pointing At A Dead PID

After `restart-codex-self` relaunched the managed `c2c-codex-b4` process,
other agents could not DM alias `codex`. The broker rejected sends with
`recipient is not alive: codex` because `registry.json` still pointed at the
old pre-restart pid.

## Root Cause 1

`run-codex-inst` only injected these MCP env overrides into the Codex launch:

- `C2C_MCP_SESSION_ID`
- `C2C_MCP_AUTO_DRAIN_CHANNEL=0`

It did not inject `C2C_MCP_AUTO_REGISTER_ALIAS`, so `c2c_mcp.py` startup
auto-register never refreshed the `codex` alias after restart.

While investigating, I also found that `c2c_mcp.py` was setting
`C2C_MCP_CLIENT_PID` to its own wrapper pid. The intended fallback in
`current_client_pid_from_env()` is the parent client pid, so the wrapper was
defeating the host-client liveness behavior.

## Fix Status 1

Implemented locally:

- `run-codex-inst` now passes
  `mcp_servers.c2c.env.C2C_MCP_AUTO_REGISTER_ALIAS="<alias>"` when the instance
  config provides `c2c_alias` or `RUN_CODEX_INST_ALIAS_HINT`.
- `c2c_mcp.py` now defaults `C2C_MCP_CLIENT_PID` to `os.getppid()` unless the
  environment explicitly provides a value.
- The live `codex` registry entry was manually refreshed to a current managed
  Codex pid as a bridge until the next managed restart proves the launcher path.

## Symptom 2: `c2c-poll-inbox` Could Hang Before File Fallback

The resumed Codex prompt correctly fell back to:

```bash
./c2c-poll-inbox --session-id codex-local --json
```

but that command hung. The recovery poller launched `c2c_mcp.py`, which runs a
`dune build` before serving JSON-RPC. A stale/blocked build meant the poller
never reached its file fallback.

## Root Cause 2

`c2c_poll_inbox.call_mcp_tool()` wrote one JSON-RPC request at a time and then
called blocking `stdout.readline()` with no startup/read timeout. Its
`--timeout` option only applied while terminating the process in `finally`, not
to the period where the MCP wrapper might be stuck before producing any output.

## Fix Status 2

Implemented locally:

- `c2c_poll_inbox.py` now sends both JSON-RPC requests with
  `proc.communicate(..., timeout=timeout)`.
- The MCP subprocess starts in its own process group.
- On timeout, the poller terminates/kills the process group and falls back to
  direct locked file drain.

## Verification

- Focused Python tests for the poller, Codex launcher env, and MCP client pid
  behavior pass.
- `./c2c-poll-inbox --session-id codex-local --timeout 1 --json` now returns
  promptly with `source: "file"` instead of hanging behind MCP startup.
- `RUN_CODEX_INST_DRY_RUN=1 ./run-codex-inst c2c-codex-b4` now shows the
  `C2C_MCP_AUTO_REGISTER_ALIAS="codex"` override.
