# Finding: git rev-parse audit — hot paths, no retry, one cacheable site

**Filed**: 2026-05-02T08:30:00Z by test-agent (dogfood on coord's #runaway-git-rev-parse-cpu-spike finding)
**Status**: Investigation complete — 3 actionable items identified

## Summary

No retry/backoff loops found anywhere. The CPU spike was almost certainly NOT caused by retry logic. The most likely culprit among the 3 startup-cached sites is `c2c_repo_fp.ml:12` (`git config --get remote.origin.url`) being called on every MCP RPC dispatch — this is the highest-frequency hot path.

## Sites audited (43 total)

### HOT PATH — called on every MCP RPC dispatch

| File | Line | Command | Notes |
|------|------|---------|-------|
| `ocaml/c2c_repo_fp.ml` | 12 | `git config --get remote.origin.url` | Called via `repo_fingerprint()` → `resolve_broker_root()` every RPC dispatch. **No caching.** |
| `ocaml/c2c_repo_fp.ml` | 15 | `git rev-parse --show-toplevel` | Same hot path when origin.url is absent |

### STARTUP ONLY — called once per process lifetime (safe)

| File | Line | Command | Notes |
|------|------|---------|-------|
| `ocaml/relay.ml` | 3127 | `git rev-parse --short HEAD` | `/health` handler — but RAILWAY_GIT_COMMIT_SHA bypasses it; fix already known |
| `ocaml/c2c_mcp_helpers.ml` | 373 | `git rev-parse --git-common-dir` | `memory_root_uncached()` cached after first call via `ref` — correct pattern |
| `ocaml/Git_helpers.ml` | 45,55,60,66,72,76,81 | Various | All for peer_review, cherry-pick — not hot |
| `ocaml/tools/c2c_cold_boot_hook.ml` | 25 | `git rev-parse --git-common-dir` | Once per cold boot |
| `ocaml/tools/c2c_post_compact_hook.ml` | 62 | `git rev-parse --git-common-dir` | Once per post-compact |
| `.opencode/plugins/c2c.ts` | 251,257 | `git config --get remote.origin.url` / `git rev-parse --show-toplevel` | Cached as `brokerRoot` const at init — correct |

### SCRIPTS / RUNTIME ONLY (not MCP hot path)

All script invocations (install-guard, dune-watchdog, etc.) are startup/one-shot, not on the per-RPC path.

## Actionable items (for next slice)

### Priority 1: Cache `repo_fingerprint()` in `c2c_repo_fp.ml`
`repo_fingerprint()` calls `git config --get remote.origin.url` on every `resolve_broker_root()` call. Since the git remote URL never changes at runtime, this should be computed once and cached in a module-level `ref` or `Lazy.t`. Pattern reference: `memory_root()` in `c2c_mcp_helpers.ml:394`.

### Priority 2: Add `RAILWAY_GIT_COMMIT_SHA` or equivalent for `relay.ml:3127`
Already documented — the `/health` handler shells out `git rev-parse --short HEAD` on every liveness probe. Add startup cache same as Priority 1.

### Priority 3: `C2C_PROBE_GIT_INVOCATIONS` telemetry
Low-overhead env-gated counter logged to `broker.log`. Would have caught the ramp before the spike. Can be added alongside Priority 1.

## What the finding says is NOT the cause

1. **OpenCode plugin tight loop**: plugin caches `brokerRoot` at init — correct
2. **c2c sidecar repeated spawn**: `c2c --version` was fixed by #429; sidecar doesn't loop on git invocations
3. **Kimi notifier polling**: not a git rev-parse source
4. **fsmonitor/index.lock contention**: secondary effect, not root cause

The most likely remaining hypotheses from the original finding:
- A process was spawning `git rev-parse` in a tight loop somewhere NOT captured by the OCaml/TypeScript audit (e.g. a shell wrapper loop, or the opencode MCP server process)
- OR `c2c_repo_fp.ml:12` was being called thousands of times per second because broker dispatch was spinning

## Cross-references
- `.collab/findings/2026-05-01T23-15-00Z-coordinator1-runaway-git-rev-parse-cpu-spike.md` — original finding
- `ocaml/c2c_mcp_helpers.ml:394` — correct caching pattern to follow
- `#429` — similar fix for `c2c --version` git rev-parse removal
