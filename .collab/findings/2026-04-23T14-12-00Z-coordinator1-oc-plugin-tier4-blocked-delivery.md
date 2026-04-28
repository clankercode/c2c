---
title: oc-plugin Tier4 filter blocked every managed OC session's inbox delivery
date: 2026-04-23T14:12:00Z
reporter: coordinator1
severity: Critical — silent delivery failure across all managed OC peers
status: FIXED (0c10946)
---

# Symptom

Every managed OpenCode session appeared to receive no DMs from peers. The plugin would log:

```
drainInbox error: Error: Usage: c2c [--help] [COMMAND] …
deliverMessages: pending=0
```

Over and over, once per poll interval (30s default). No messages ever surfaced in the transcript.

# Root cause

`ocaml/cli/c2c.ml:226` had `"oc-plugin", Tier4` in the command_tier_map.

The tier filter (`filter_commands`) removes Tier3+ commands when `C2C_MCP_SESSION_ID` is set (i.e., from agent-session invocation). Every managed OC session has that env var set — so when the plugin spawns `c2c oc-plugin drain-inbox-to-spool` as a subprocess, cmdliner sees `oc-plugin` filtered out and prints the usage message instead.

The tier system was designed to protect agents from accidentally running internal commands. But `oc-plugin` and `cc-plugin` are specifically invoked by the plugin code as subprocesses — they're plumbing, not an agent surface. The filter had a false positive.

# Fix

`oc-plugin`, `cc-plugin`, `hook` → Tier1. Agents still won't see them in --help (they're marked `[internal]`), but the filter no longer blocks invocation.

```ocaml
; "hook", Tier1       (* was Tier4 *)
; "oc-plugin", Tier1  (* was Tier4 *)
; "cc-plugin", Tier1  (* was Tier4 *)
```

# Verification

```
$ C2C_MCP_SESSION_ID=test c2c oc-plugin drain-inbox-to-spool --spool-path /tmp/x --json
{"ok":true,"session_id":"coordinator1",...}
```

End-to-end: sent DM to ceo at 14:10Z → plugin drained + delivered → ceo replied "ceo-ack" → surfaced in coordinator1's hook. Confirmed full loop.

# Wider implications

This bug went undetected because:

1. The tier system landed recently (f582236 + 3c15da5, today).
2. The managed-peer DM tests we use don't assert on message arrival at the OC end — they only assert the send succeeded and the broker enqueued.
3. Agents restarted through the day were silently re-running the buggy binary; each of them kept poll-failing.

Regression test needed in tests/test_c2c_cli_dispatch.py:

```python
def test_oc_plugin_subcommand_callable_from_agent_session(...):
    env = {..., 'C2C_MCP_SESSION_ID': 'test-alias'}
    result = subprocess.run(['c2c', 'oc-plugin', 'drain-inbox-to-spool', '--help'],
                            env=env, capture_output=True)
    assert result.returncode == 0
```

Jungle-coder has task #82 open for the regression test framework; this is the canonical first case.
