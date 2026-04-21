# OpenCode Duplicate Outer Loop And Stale Prompt

- **Discovered by:** codex
- **Discovered at:** 2026-04-13T12:42:58Z
- **Severity:** medium
- **Status:** fixed and live-verified

## Symptom

`run-opencode-inst.d/c2c-opencode-local.json` contains the newer `STEP 0`
`mcp__c2c__whoami` prompt, but the live OpenCode process still has the older
prompt in its command line. The live process is:

```text
pid 2734575: opencode --session ses_283b6f0daffe4Z0L0avo1Jo6ox --prompt ...
```

The command-line prompt starts at `STEP 1` and therefore has not picked up the
config repair committed in `0a6a441`.

At the same time, two outer loops exist for the same managed instance:

```text
pid 2663807: python3 ./run-opencode-inst-outer c2c-opencode-local --fork
pid 2734574: python3 ./run-opencode-inst-outer c2c-opencode-local
```

The `--fork` outer loop is detached on `/dev/null`; the non-`--fork` loop is the
TUI-backed loop on `pts/22` and owns the useful child `pid 2734575`.

## How It Was Found

While reviewing OpenCode restart state, `python3 -m json.tool
run-opencode-inst.d/c2c-opencode-local.json` showed the expected `STEP 0`
prompt, but:

```bash
ps -o pid,ppid,pgid,sid,stat,etimes,comm,args -p 2734575
```

showed the running prompt without `STEP 0`. `c2c health --json --session-id
opencode-local` also reported two running OpenCode outer loops.

## Root Cause

There were three overlapping sources of drift:

1. The prompt config changed while the long-lived TUI child stayed alive, so the
   new prompt has not been loaded by the actual running process.
2. A detached `--fork` outer loop is still running alongside the TUI-backed
   outer loop. This can race pidfile writes, broker registration refreshes, and
   support-loop rearming for the same `c2c-opencode-local` instance.
3. `run-opencode-inst` did not export `C2C_MCP_CLIENT_PID`. OpenCode MCP server
   subprocesses therefore fell back to `os.getppid()` inside `c2c_mcp.py`, which
   can identify a short-lived OpenCode worker instead of the durable TUI process.
   After the TUI restart, this briefly registered `opencode-local` to dead pid
   `2963521` while the actual TUI process `2960315` stayed alive.

## Fix Status

Fixed in code by exporting `C2C_MCP_CLIENT_PID=str(os.getpid())` from
`run-opencode-inst` before it execs OpenCode. Since the wrapper process becomes
the long-lived OpenCode process after `exec`, MCP children now inherit the
durable client pid instead of guessing from their own parent process.

Verification:

```text
python3 -m unittest tests.test_c2c_cli.OpenCodeLocalConfigTests.test_run_opencode_inst_dry_run_reports_local_config_and_session -v
python3 -m unittest tests.test_c2c_cli.OpenCodeLocalConfigTests -v
python3 -m unittest tests.test_c2c_mcp_auto_register -v
python3 -m py_compile run-opencode-inst
```

Live mitigation already applied:

- Stopped detached outer loop pid `2663807`.
- Restarted TUI-backed OpenCode child, replacing old prompt-only pid `2734575`
  with pid `2960315`.
- Re-armed support loops against pid `2960315` and refreshed the broker row back
  to that live pid after a transient auto-register overwrite.
- After committing the code fix, restarted OpenCode again. New live pid
  `2977561` inherited `C2C_MCP_CLIENT_PID=2977561`; the broker row still pointed
  at `2977561` after a delay and support loops rearmed against that pid.

Recommended operator/agent action:

No immediate operator action remains for the live `opencode-local` instance.
Future restarts should inherit `C2C_MCP_CLIENT_PID` from `run-opencode-inst`.

## Follow-Up

`run-opencode-inst-outer` probably needs a singleton guard per instance name so
two outers cannot manage the same pidfile/support-loop set at once. A softer
first step would be a warning in `c2c health` when multiple outer loops share
the same client/name.
