# Parallel-dune softlock — runbook entry

**Author:** stanza-coder
**Date:** 2026-04-28 15:20 AEST (UTC 05:20)
**Severity:** OPERATIONAL — recovery procedure known
**Discovered during:** quota-burn parallel-subagent dispatch (Max
directive to hit 95% by 5h reset)

## Symptom

When 3+ parallel subagents (or Bash invocations) each run
`opam exec -- dune build --root <worktree>` simultaneously across
different worktrees of the same repo, dune can softlock. Builds
hang past their normal duration; the `dune_watchdog.py` 300s
timer eventually kills them, but quota is wasted in the interim.

Observed today: 3 stalled builds — one at 3:39 elapsed,
two at 2:54 — all blocked, none progressing.

## Recovery

```
killall dune
```

Verify cleared:
```
ps -eo pid,etime,cmd | grep dune | grep -v grep
```

Subagents typically retry the build automatically. If they don't,
re-dispatch.

## Likely root cause

Dune's per-build internal locks (e.g. `_build/.lock`) and/or
opam-env race when many `opam exec` invocations resolve switch
state simultaneously. Each worktree has its own `_build/` so
inter-worktree contention should be low — but the shared opam
state and CPU contention can still produce mutual deadlock.

## Mitigations (potential, untested)

1. **Stagger dispatches** — schedule parallel subagents to start
   ~30s apart so dune gets to module-resolution before peers
   contend on the same opam env.
2. **Shared serialized lock**: `flock ~/.cache/c2c-dune.lock dune build`
   wrapped in a justfile recipe. Trades parallelism for stability
   on dune's hot path. Acceptable since builds are dominated by
   `_build/` cache hits anyway.
3. **Accept the occasional `killall dune`** — operational cost
   when you choose to burn quota with high parallelism.
4. **Check existing `dune_watchdog.py` config** — might already
   have stagger logic; if not, this is the surface to extend.

## When to apply

- High-parallel-subagent burn windows (quota-targeting work).
- Multi-worktree cherry-pick chains.
- Whenever > 2 subagents are simultaneously invoked with build
  steps.

## Cross-references

- Related: `c2c-install-guard.sh` flock pattern (#302) for
  install paths — analogous shared-resource serialization.
- The `dune_watchdog.py` script lives at `scripts/dune_watchdog.py`;
  worth a peek if extending the mitigation.

## Operational discipline

- Before kicking off a high-parallel burn, note the current
  dune process count (`pgrep dune | wc -l`); if > 0, wait for
  them to drain or `killall` first.
- Quota-burn windows are fine, but bake in a periodic
  `ps | grep dune` check every 2-3 min so stalls don't eat
  the whole window.

## Notes

- Max flagged the recovery procedure mid-burn at 2026-04-28
  15:19 AEST. Filing this for next-stanza / next-Cairn so the
  reflex is documented.

— stanza-coder
