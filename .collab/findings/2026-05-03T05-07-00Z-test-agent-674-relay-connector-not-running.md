# Finding: #674 cross-host E2E test — relay connector not running in containers

**Severity**: High — all cross-host delivery tests fail; all 3 DM/room/echo tests have the same root cause
**File**: `docker-tests/test_kimi_opencode_cross_host.py`
**Commit**: 817f0889 (base) + 93dc2367 (CLI flags)
**Date**: 2026-05-03
**Reviewed by**: test-agent

## Symptom

After fixing CLI flags, 4 tests pass (registration + one room test), but all DM and remaining room tests fail with "never received" assertions.

## Root cause: `c2c relay connect` not running

Containers in `docker-compose.e2e-multi-agent.yml` run `command: ["sleep", "3600"]` — no relay connector process.

When `c2c send alias@host "msg"` is called:
1. CLI appends to `remote-outbox.jsonl` (verified: entries present)
2. Returns `ok` immediately
3. **No relay connector running to read outbox and forward to relay**
4. Recipient never receives anything

Evidence:
```bash
# /var/lib/c2c/remote-outbox.jsonl in agent-a1 contains queued messages:
{"from_alias":"agent-a1","to_alias":"agent-b1@c2c-e2e-relay:7331","content":"hello-from-kimi-..."}

# Container PID 1: /usr/bin/tini -- sleep 3600
# No c2c relay connect process running
```

## Required fix

Each agent container needs to run `c2c relay connect` as a background process alongside (or instead of) `sleep 3600`. Options:

1. **Sidecar approach**: start `c2c relay connect` as background pid in each agent container before the test runs
2. **Entrypoint approach**: use a custom entrypoint script that starts `c2c relay connect` and then tails /dev/null or sleeps
3. **Connect in fixture**: the `registered_agents` fixture runs `c2c relay connect` in background for each container before returning

Option 3 (connect in fixture) is cleanest for a test — adds `&` background start of `c2c relay connect` per container in the fixture, with a brief sleep for connection establishment.

## Test design note

The `c2c send alias@host` path is async — it appends to outbox and returns. Tests that depend on synchronous delivery need the relay connector running. This is correct OCaml behavior (not a bug in the binary), but the test topology doesn't exercise it correctly.
