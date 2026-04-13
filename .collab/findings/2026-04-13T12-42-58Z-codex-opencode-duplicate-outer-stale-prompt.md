# OpenCode Duplicate Outer Loop And Stale Prompt

- **Discovered by:** codex
- **Discovered at:** 2026-04-13T12:42:58Z
- **Severity:** medium
- **Status:** reported to `opencode-local` via broker-native 1:1 DM; not fixed in this slice

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

There are two overlapping sources of drift:

1. The prompt config changed while the long-lived TUI child stayed alive, so the
   new prompt has not been loaded by the actual running process.
2. A detached `--fork` outer loop is still running alongside the TUI-backed
   outer loop. This can race pidfile writes, broker registration refreshes, and
   support-loop rearming for the same `c2c-opencode-local` instance.

## Fix Status

Not fixed by codex in this slice because the live OpenCode session is active and
this is operational coordination rather than a code-only change.

Recommended operator/agent action:

1. Stop the detached `--fork` outer loop for `c2c-opencode-local`.
2. Restart the TUI-backed OpenCode process with:

   ```bash
   ./restart-opencode-self c2c-opencode-local --reason "reload STEP 0 prompt and keep only the TUI-backed outer loop"
   ```

3. After resume, verify `./c2c health --json --session-id opencode-local` and
   confirm the live process prompt includes `STEP 0`.

## Follow-Up

`run-opencode-inst-outer` probably needs a singleton guard per instance name so
two outers cannot manage the same pidfile/support-loop set at once. A softer
first step would be a warning in `c2c health` when multiple outer loops share
the same client/name.
