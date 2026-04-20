---
author: planner1
ts: 2026-04-20T21:30:00Z
severity: medium
status: spec — ready for coder2-expert implementation
---

# Supervisor Liveness Detection — Plugin Design Spec

## Problem

The `first-alive` supervisor selection strategy currently selects `supervisors[0]`
blindly. If that alias is dead, stale, or offline:
- The DM is written to their broker inbox but never read
- The permission request hangs for 120s then falls back to TUI dialog
- Silent failure: no one knows the supervisor was unreachable

## Liveness Detection Options

### Option A: `c2c list --json` broker query (recommended)

The broker registry tracks per-session liveness:
- `alive: true/false` — PID liveness check
- `last_seen: <float>` — last time the session polled inbox
- `registered_at: <float>`

Plugin calls `c2c list --json` and filters for supervisors where `alive: true`.

**Pros**: authoritative, uses existing broker data, no new infrastructure  
**Cons**: one extra spawn per permission request (~5ms OCaml CLI)  
**Cost**: negligible for permission approval path (blocking anyway)

### Option B: Last-poll timestamp heuristic

Use `last_seen` from `c2c list --json` — if the supervisor polled inbox within
the last N seconds (e.g. `stale_threshold_s = 300`), treat as live.

Useful when PID liveness is wrong (process recycled, bypassed, etc.). Combine
with Option A: `alive AND last_seen_age < stale_threshold_s`.

### Option C: Relay-mediated heartbeat (future)

Each supervisor periodically registers on relay with a TTL. Plugin checks relay
for supervisor presence via `c2c relay list`. More robust for cross-machine
supervisors, but adds relay dependency. Out of scope for this slice.

### Option D: No liveness check — just try all alive supervisors (broadcast on failure)

If `first-alive` finds no live supervisor, fall back to broadcasting to all
configured supervisors. At least one might get it.

## Recommended Design: Options A + B + D

```typescript
type SupervisorLiveness = { alias: string; alive: boolean; lastSeenAge: number };

async function querySupervisorLiveness(): Promise<SupervisorLiveness[]> {
  try {
    const raw = await runC2c(["list", "--json"]);
    const parsed = JSON.parse(raw);
    const sessions: any[] = Array.isArray(parsed) ? parsed :
      (parsed.sessions ?? parsed.registrations ?? []);
    return supervisors.map(alias => {
      const entry = sessions.find((s: any) =>
        s.alias === alias || s.session_id === alias
      );
      if (!entry) return { alias, alive: false, lastSeenAge: Infinity };
      const lastSeenAge = entry.last_seen
        ? Date.now() / 1000 - entry.last_seen
        : Infinity;
      return { alias, alive: entry.alive === true, lastSeenAge };
    });
  } catch {
    // c2c list failed — assume all unknown, proceed with first supervisor
    return supervisors.map(alias => ({ alias, alive: true, lastSeenAge: 0 }));
  }
}

async function selectSupervisor(): Promise<string[]> {
  if (supervisorStrategy === "broadcast") return supervisors;
  if (supervisorStrategy === "round-robin") {
    return [supervisors[roundRobinIndex++ % supervisors.length]];
  }
  // first-alive
  const staleThresholdS = parseInt(process.env.C2C_SUPERVISOR_STALE_THRESHOLD_S || "300", 10);
  const liveness = await querySupervisorLiveness();
  const live = liveness.filter(s => s.alive && s.lastSeenAge < staleThresholdS);
  if (live.length > 0) return [live[0].alias];
  // Fallback: all configured (broadcast to maximise reach)
  await log(`supervisor liveness: no live supervisor found — broadcasting to all ${supervisors.length}`);
  return supervisors;
}
```

The permission hook becomes:
```typescript
const targets = await selectSupervisor();
for (const target of targets) {
  await runC2c(["send", target, msg]);
}
```

## Config / Env Vars

| Var | Default | Meaning |
|-----|---------|---------|
| `C2C_SUPERVISOR_STALE_THRESHOLD_S` | `300` | Age in seconds past which a supervisor is considered stale even if `alive: true` |
| `C2C_SUPERVISOR_STRATEGY` | `"first-alive"` | `first-alive` \| `round-robin` \| `broadcast` |

(Sidecar equivalents: `supervisor_stale_threshold_s`, `supervisor_strategy`)

## Edge Cases

1. **Supervisor not in broker registry** (never registered): treated as dead → broadcast fallback
2. **c2c list fails** (broker unreachable): assume all alive → use first supervisor
3. **All supervisors dead**: broadcast to all → at least inbox-queues them for when they revive
4. **Single supervisor, dead**: still sends (inbox queues) — better than silent drop

## Acceptance Criteria

1. `first-alive` strategy queries broker liveness before selecting supervisor
2. If supervisor[0] is dead/stale, falls back to next live supervisor
3. If no live supervisors: broadcasts to all (logged)
4. `c2c list` failure: graceful degradation to first supervisor (no exception)
5. Configurable stale threshold (`C2C_SUPERVISOR_STALE_THRESHOLD_S`)

## Implementation Notes

- `querySupervisorLiveness()` adds ~5-10ms per call (OCaml CLI spawn); acceptable for permission path
- Cache liveness results for 30s to avoid hammering `c2c list` on rapid permission events
- Liveness cache keyed by supervisor alias; invalidate on permission reply (supervisor must be alive if they replied)

## Related

- `.collab/findings/2026-04-20T21-05-00Z-planner1-c2c-init-supervisor-spec.md` (supervisor config)
- `.opencode/plugins/c2c.ts` — `selectSupervisor()` to be added
