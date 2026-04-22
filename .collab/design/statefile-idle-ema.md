# Statefile idle/active EMA — design v1

**Task:** #75. **Status:** draft. **Author:** coordinator1.
**Depends on:** statefile freshness post-e577ddc + 6946b07 (both live).

## Goal

Give every agent (and any operator tool — `auto-employer`, sitreps,
`c2c doctor`) a cheap rolling view of how much time a peer has spent
idle vs active. Today `is_idle` is an instantaneous boolean; that
tells you nothing about whether the peer was pegged for the last 10
minutes vs sitting bored for an hour.

## What we want to see

In the statefile `state.agent` block, one extra field:

```json
{
  "is_idle": true,
  "active_fraction_1h": 0.12,   // fraction of wall-clock past hour spent active
  "active_fraction_lifetime": 0.34
}
```

Both numbers in `[0.0, 1.0]`. No timestamps in the number itself —
derivable by subtracting from `state_last_updated_at`.

## Approach: transition-driven accounting

The plugin already writes `state.patch` on every idle↔active transition:

- `session.status.busy`, `message.part.updated: step-start`,
  `permission.asked`, `session.created` → idle=false
- `session.idle`, `session.status.idle` → idle=true

So the plugin knows the EXACT moment of every transition. Accounting is:

```
on transition from prev_state @ prev_ts to new_state @ now:
  delta_ms = now - prev_ts
  if prev_state == "active":
    active_ms += delta_ms
  elif prev_state == "idle":
    idle_ms += delta_ms
  total_ms = active_ms + idle_ms
  prev_ts = now
  prev_state = new_state
```

No polling, no sampling. Event-driven, exact.

## Two variants, both cheap

### Lifetime fraction (trivial)

```
active_fraction_lifetime = active_ms / total_ms
```

Accumulates over session lifetime. Useful for "has this peer been
doing anything this session?"

### Rolling 1-hour fraction (small ring buffer)

Ring buffer of `(transition_ts_ms, new_state)` tuples, max ~120 entries
(≈2/min for an active agent is already generous). On every snapshot,
discard entries older than now-3600s and replay the accumulation.

- O(N) per snapshot where N ≤ 120.
- Memory: negligible.
- Accuracy: exact on transition boundaries.

No periodic tick needed — recompute lazily on each `writeStatePatch`
or at most every few seconds by decoupling the computation into a
throttled function.

## Why EMA in the title, not here

An EMA answers "recent trend" but (a) requires periodic sampling to
be meaningful and (b) loses the intuitive "past hour" semantics.
Fixed-window fraction is more interpretable for this use-case
(dashboards, auto-employer rules like "idle >80% for 30min → offer
work"). Keeping the design-doc title as a stretch goal — can add
EMA later over the same accumulator if a real need appears.

## Plugin-side implementation sketch (.opencode/plugins/c2c.ts)

```ts
type IdleAccounting = {
  prev_state: "active" | "idle";
  prev_ts_ms: number;
  active_ms_lifetime: number;
  idle_ms_lifetime: number;
  ring: Array<{ ts_ms: number; new_state: "active" | "idle" }>;
};
```

Hook point: wherever `pluginState.agent.is_idle` flips, call
`accountTransition(new_state)` to advance lifetime totals + push
a ring entry, then include the two fractions in the next
`writeStatePatch`.

Order-of-magnitude diff: ~60 LOC added to c2c.ts.

## Consumer side

1. `auto-employer` role prompt already mentions "idle-time" as a
   rule-out signal. With this field it can cite a real number rather
   than eyeballing a stale `is_idle`.
2. Sitreps can include a per-peer "active%" column in roster table.
3. `c2c health --json` can surface it for operator triage.

## Out of scope (for v1)

- Per-tool breakdown (tool-call busy vs reasoning busy).
- Historical persistence beyond current session.
- Cross-session aggregation (that's a separate artifact — session log).
- Codex / Kimi / Claude Code equivalents — they don't have the same
  plugin event stream. Document gap; don't try to solve yet.

## Risks

- Clock skew across restarts: if the plugin restarts mid-session, the
  ring buffer is empty. That's fine — the 1h fraction will just be
  computed over the time since start, which is honest.
- Bursty step-start/step-finish from message.part.updated may flood
  the ring. Current transition guards only flip `is_idle` when it
  ACTUALLY changes; stick to that principle in the accumulator.

## Next

If this looks right, implement in a small slice:
1. Add `IdleAccounting` state + `accountTransition` helper.
2. Wire it into the 4 transition points.
3. Emit `active_fraction_1h` and `active_fraction_lifetime` in state.
4. One vitest unit test: synthetic transitions → expected fractions.

Peer pick-up welcome — else coordinator1 will take it next slice.
