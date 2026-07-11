# B125 — Cross-worktree parallel dune softlock; global gate + shared cache

**Author:** codex-glade-velu-rci7 (subagent implementing B125)
**Date:** 2026-07-11
**Severity:** OPERATIONAL / build reliability — blocks multi-agent throughput
**Status:** MITIGATED (code on `bl-b125`; parent merges)

## Symptom

Multiple `dune build --root .worktrees/<slice>` processes hang for 1–5+
hours at ~0.1% CPU across different worktrees. Observed live on this
machine during B125 claim:

| worktree | elapsed (approx) | notes |
|----------|------------------|-------|
| bl-b110  | 5h32m            | `-j1`, many targets |
| bl-b117  | 1h40m            | `-j 2` |
| bl-b119  | 3h45m            | full just-build target list |
| bl-b120  | 1h17m            | `-j 2` |

Per-worktree `flock _build/.c2c-build.lock` (post-2026-04-28) does **not**
prevent this — each hung build is in a different worktree with its own
`_build/`.

## Prior art

- Finding: `.collab/findings/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`
  (same-worktree softlock; recovery `killall dune`)
- Mitigation v1: per-worktree flock in `justfile` + `scripts/dune-build-locked.sh`
- Runbook: `.collab/runbooks/worktree-per-feature.md` § parallel-dune softlock
- Watchdog: `scripts/dune-watchdog.sh` (default 900s) — kills hung builds
  but does not prevent the stampede; agents still waste wall clock

## Root-cause summary (research)

Not a single proven deadlock line, but a consistent operational pattern:

1. **Same-worktree** contention on dune's `_build/.lock` / sandbox state
   (original 2026-04-28 case) — fixed by per-worktree flock.
2. **Cross-worktree** hangs remain because:
   - Shared **opam switch** (`opam exec` / ocamlfind / compiler libs) is
     machine-global; concurrent heavy dune invocations thrash it.
   - Dune's **shared cache** (`~/.cache/dune`) can see concurrent writers
     from many worktrees; default was only `enabled-except-user-rules`
     and was never wired into just recipes.
   - CPU/RAM/disk stampede: N full rebuilds of a large OCaml tree on one
     host → each process starves and appears "stuck" at ~0% CPU.
3. **Bypass path**: many agents still run raw
   `opam exec -- dune build --root …` (or just recipes that only held
   the *local* flock). Those never entered a machine-wide queue.

Conclusion: treat concurrent cross-worktree dune as unsafe by default.
Serialize (or tightly bound) at the machine level; use the shared cache
so serialized rebuilds stay fast.

## Options considered

| Option | Pros | Cons |
|--------|------|------|
| Document `killall dune` only | Free | Keeps happening; wastes hours |
| Stagger subagent starts ~30s | Simple | Fragile; doesn't stop parallel just/build |
| Dune shared cache only | Faster hits | Does not stop concurrency hangs |
| Global exclusive lock (N=1) | Reliable | Serial builds |
| Global slots N=1..k + cache | Tunable; default safe | Agents must use wrapper |
| Remote/distributed cache | Scale | Out of scope |

**Recommendation implemented:** machine-wide slot gate (default N=1) +
enable Dune shared cache + keep per-worktree flock + keep watchdog.
Integrate into every agent-facing just dune path.

## What was implemented

### `scripts/dune-build-locked.sh` (canonical entry)

1. Export `DUNE_CACHE=enabled` (unless already set / `C2C_DUNE_CACHE=disabled`)
2. Export `DUNE_CACHE_STORAGE_MODE=hardlink` by default (same FS as
   `~/.cache` + worktrees on this host)
3. Optional `C2C_DUNE_CACHE_ROOT` → `DUNE_CACHE_ROOT`
4. Acquire **global slot** under
   `${XDG_CACHE_HOME:-$HOME/.cache}/c2c/dune-global/slot-*.lock`
   (count = `C2C_DUNE_GLOBAL_SLOTS`, default **1**)
5. Acquire per-worktree `_build/.c2c-build.lock`
6. Run via `scripts/dune-watchdog.sh` (default 900s) →
   `opam exec -- dune <subcmd> --root <worktree> …`

### `justfile`

`build`, `build-cli`, `build-server`, `test-ocaml`, `watch-e2e`,
`codex-deliver-e2e`, `check`, `check-connect-commands`, `install-cli`,
`install-mcp`, `install-hook`, `install-all`, `clean` all call the
wrapper (no more bare `flock _build … dune` / bare `opam exec -- dune`).

### Tests

`test/test_dune_flock.sh` — fast smoke for local lock, global gate
timeout, cache env wiring, multi-slot N=2, skip-global bypass, invalid
slots. Uses `C2C_DUNE_WRAPPER_TEST_CMD` (no real dune).

### Docs

- This finding
- `.collab/runbooks/worktree-per-feature.md` § parallel-dune softlock updated

## How to tune

```bash
# Default: one dune at a time machine-wide (safest)
just build

# Allow two concurrent cross-worktree builds (if host is beefy)
C2C_DUNE_GLOBAL_SLOTS=2 just build

# Fail fast instead of queueing
C2C_DUNE_LOCK_WAIT_SECONDS=30 just build

# Opt out of shared cache
C2C_DUNE_CACHE=disabled just build

# Custom cache root
C2C_DUNE_CACHE_ROOT=/mnt/fast/dune-cache just build

# Emergency bypass of global gate only (still local flock + watchdog)
C2C_DUNE_SKIP_GLOBAL_LOCK=1 just build

# Watchdog
DUNE_WATCHDOG_TIMEOUT=1200 just build
DUNE_WATCHDOG=0 just build   # disable
```

Ad-hoc (no just):

```bash
scripts/dune-build-locked.sh build ./ocaml/cli/c2c.exe
scripts/dune-build-locked.sh runtest ocaml/
```

## Recovery (still applies for pre-gate / raw dune)

```bash
# Prefer scoped kill for your worktree
pkill -f "dune build --root $(pwd)"

# Nuclear (coordinates with peers first — kills everyone's dune)
killall dune
```

Raw `opam exec -- dune build` still bypasses the gate — do not use it
in agent prompts.

## Residual risks / follow-ups

1. **Bypass culture**: any prompt/script still calling raw dune will hang
   the fleet. Consider a PATH shim later (out of scope for B125).
2. **Default N=1 queues agents**: wall-clock for N sequential builds;
   shared cache should make most rebuilds cache-hit heavy. Raise slots
   only if hangs stay gone.
3. **opam itself** is not locked beyond serializing dune; pure
   `opam install` races are separate.
4. **Hung zombies already running** are not auto-killed by this change;
   operators may still need a one-time cleanup after deploy.
5. Exact dune-internal deadlock under cache+opam not bisected — if N=1
   still hangs, escalate with `strace -p <pid>` / dune `--debug-cache`.

## Cross-references

- Backlog: B125
- Prior: `.collab/findings/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`
- Runbook: `.collab/runbooks/worktree-per-feature.md`
- Wrapper: `scripts/dune-build-locked.sh`
- Smoke: `test/test_dune_flock.sh`
