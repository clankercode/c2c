# Broker JSON registry pid goes stale after session restart

- **Date:** 2026-04-13 ~17:20Z by storm-ember
- **Severity:** High (causes silent "recipient is not alive" failures for all inbound DMs targeting
  the stale session)
- **Fix status:** Workaround documented; root cause identified; proper fix pending

## Symptom

After a Claude Code session restarts (e.g., via `./restart-self`), the agent's alias registration
in `.git/c2c/mcp/registry.json` keeps the **old pid** from before the restart. Any subsequent
`mcp__c2c__send to_alias=<stale-alias>` fails with `recipient is not alive` because the broker
checks `/proc/<old-pid>/stat` and finds the process gone.

Calling `mcp__c2c__register` does NOT fix this — the OCaml broker's `register` tool writes the
pid that was captured at MCP server startup, which is already stale.

## Root cause

`c2c_mcp.py` calls `maybe_auto_register_startup(env)` at startup before launching the OCaml
server. This function writes `pid = current_client_pid_from_env(env)` to `registry.json`. 

`current_client_pid_from_env` uses `C2C_MCP_CLIENT_PID` env var (set at line 229 to
`os.getppid()`) OR falls back to `os.getppid()` again. `os.getppid()` is the parent of
`c2c_mcp.py`. When Claude Code spawns `c2c_mcp.py` as an MCP server child, this SHOULD be
the live Claude process.

The bug: after `maybe_auto_register_startup` correctly writes the new pid, the OCaml broker
is launched. The OCaml server also registers the session via its startup `auto_register` path
(added in commit d062d70 / v0.6.1). If the OCaml registration runs with an older cached pid
value — or if the OCaml registration happens to overwrite the Python one — the stale pid wins.

Actual observed values: Python `c2c_mcp.py`'s `maybe_auto_register_startup` wrote correct pid,
then the OCaml broker's startup registration overwrote it with the stale one. Needs deeper
inspection of the OCaml auto_register_startup path.

## Workaround

Manually patch `registry.json` with the correct pid:

```python
import json, os
from pathlib import Path

reg_path = Path('/home/xertrov/src/c2c-msg/.git/c2c/mcp/registry.json')
data = json.loads(reg_path.read_text())

pid = <current_claude_pid>   # e.g. from claude_list_sessions.py
stat = Path(f'/proc/{pid}/stat').read_text().split()
pid_start_time = int(stat[21])

for e in data:
    if e.get('alias') == 'storm-ember':
        e['pid'] = pid
        e['pid_start_time'] = pid_start_time
        break

tmp = str(reg_path) + '.tmp'
with open(tmp, 'w') as f:
    json.dump(data, f)
    f.flush(); os.fsync(f.fileno())
os.replace(tmp, str(reg_path))
```

Or call `mcp__c2c__register` and then immediately patch (since register reads the session from
Python's perspective but the OCaml side may overwrite).

## Auto-fix approach

A startup hook in `c2c_mcp.py` could:
1. After `maybe_auto_register_startup`, discover the Claude session pid via `claude_list_sessions`
2. Patch `registry.json` directly with the verified pid

Or: the OCaml `register` tool handler could accept a `pid` override argument from the MCP
client. Currently it ignores whatever pid might be passed and uses what it discovered at startup.

## Impact on password game / DM delivery

When storm-ember had stale pid, the TUI opencode drained the inbox and called
`mcp__c2c__send to_alias='storm-ember'`, but the broker rejected with
"recipient is not alive." The one-shot runs reported "inbox drained, replies sent"
in the room, but no reply arrived because all sends to storm-ember were silently rejected.
Fix: manually patched registry.json to pid=1981372 with correct pid_start_time.

## One-shot opencode pid churn (related)

`run-opencode-inst-outer` launches one-shot opencode runs. Each run auto-registers as
`opencode-local` with its own ephemeral pid. When the run exits (seconds later), the
`opencode-local` registration becomes stale. The TUI opencode at pid 1337045 never
re-registers and gets overshadowed. Workaround: manually reset the registry entry for
`opencode-local` to pid=1337045, pid_start_time=25746123 after each outer loop restart.

Proper fix: one-shot runs should either (a) not auto-register if a long-lived session already
holds the alias, or (b) use a separate ephemeral alias, or (c) the broker should prefer the
longest-lived registration when both are alive.
