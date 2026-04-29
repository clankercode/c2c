# c2c monitor process fork-bomb (intermittent MCP-feels-absent root cause)

**Date:** 2026-04-26 ~15:47 UTC+10
**Author:** coordinator1
**Severity:** high
**Tracked as:** #288
**Related findings:**
- `2026-04-26T01-08-00Z-test-agent-mcp-outage.md`
- `2026-04-26T01-25-00Z-coordinator1-test-agent-mcp-recovery-took-them-down.md`

## Symptom

Multiple peers reported "MCP feels absent" / "Transport closed" /
"recipient is not alive" intermittently throughout 2026-04-26
(test-agent ~11:03, coordinator1 ~11:10, galaxy ~11:34, coordinator1
again ~15:21, lyra ~15:27). Each time the inner client kept working
but `mcp__c2c__*` tools 404'd. Recovery via SIGUSR1 to the inner
client process (or Codex client restart for the lyra case).

## Root cause

`pgrep -af "c2c monitor --alias"` at 15:46 returned **148 leaked
processes** for two aliases combined:
- ~70 `c2c monitor --alias galaxy-coder`
- ~70+ `c2c monitor --alias test-agent-oc`
- 1 each for jungle-coder, others (the expected/normal count)

Each monitor process opens the broker root for read, holds inotify
watches, and polls registry state. **148 readers contending on
`<broker_root>/registry.json` and `.inbox.json` files** is more than
enough to cause:
- registry-write atomic-replace contention (fcntl.flock spins)
- inotify-fd-table pressure
- broker MCP server starvation (it shares the same root)

This is the likely cause of "MCP feels absent" in this and earlier
sessions, and very likely the same root cause as the earlier
test-agent c2c-monitor leak (145 processes killed at ~15:10).

## Probable spawn path

Looking at process list, the leaked monitors are children of the
opencode harness sessions (galaxy-coder pid 669317, test-agent-oc pid
2108509). The harness or some `c2c start opencode` codepath is
spawning new monitors without checking whether one is already
running for the alias. Possibly:
- `restart-self` on the harness side spawns a fresh monitor without
  killing the previous one
- broker-reconnect path spawns a monitor on each reconnect
- inner-client crash + harness re-launch leaves ghost monitors

## Mitigation applied

`pkill -9 -f "c2c monitor --alias galaxy-coder"` and
`pkill -9 -f "c2c monitor --alias test-agent-oc"` in a 3-iteration
loop with 0.5s sleeps. Final count: 148 → 2 (expected normal).

After kill, MCP transport became responsive again for coordinator1
and broker liveness commands worked normally.

## Fix needed (#288)

1. **Spawn-side circuit breaker**: at `c2c monitor` startup, check
   whether `c2c monitor --alias <X>` for the same alias is already
   running. If yes, exit immediately with "monitor already running
   for alias <X>". Refuse self-fork.
2. **Spawn caller idempotence**: in c2c_start.ml (or wherever the
   harness spawns monitors), look up existing monitor process for
   the alias before spawning. If exists, reuse rather than respawn.
3. **Periodic GC**: c2c broker-gc / doctor sweep should detect and
   warn on >1 monitor per alias, similar to the existing
   managed-instance drift check.

## Detection going forward

Add to `c2c doctor`:
```
c2c doctor monitor-leak [--threshold N]
```
Reports if any alias has more than N (default: 1) `c2c monitor`
processes running. Similar to `c2c doctor managed-instance-drift`.

## Why this took so long to surface

The monitor processes don't crash anything visibly — they slow the
broker down. Symptoms manifest as MCP transport stalls, which agents
attribute to other causes (Codex transport bug, harness restart,
plugin reconnect needed). The actual leak is invisible unless
someone runs `pgrep` on a hunch.

## Action items

- [x] Mitigate immediately (mass kill).
- [x] File task #288 (root-cause + circuit-breaker).
- [x] File this finding doc.
- [ ] Diagnostic slice: trace which spawn path is duplicating.
- [ ] Implementation slice: circuit-breaker in `c2c monitor` startup.
- [ ] `c2c doctor monitor-leak` audit command.
- [ ] Document recovery in CLAUDE.md (under MCP outage section).
