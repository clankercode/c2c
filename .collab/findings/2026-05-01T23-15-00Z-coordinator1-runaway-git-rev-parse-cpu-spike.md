# Catastrophic CPU spike from runaway `git rev-parse` (opencode-correlated)

- **Filed**: 2026-05-01T23:15:00Z by coordinator1 (Cairn-Vigil)
- **Reported by**: Max, in-conversation FYI
- **Severity**: HIGH — node-level outage class; wedged the whole machine for the swarm
- **Status**: recovered (load 0.13 1m at filing); root cause not yet identified

## Symptom (Max's report)

> "we had a catastrophic issue, cpu at like 1600 - 8000 load, just insane.
> When I killed all opencode, that helped and claude processes got killed
> too. Looking in top, we still had a load of 6 mostly from git rev-parse
> or something."

Sequence:
1. Load average climbed to **1600–8000** (off the chart — likely thousands
   of processes in R+D state competing for CPU and disk I/O).
2. Max `pkill`'d opencode → load dropped substantially. **Side-effect**:
   claude sessions died too (probably MCP-stdio tied to opencode child
   pgroups, or the OpenCode plugin was the c2c MCP attachment for those
   claude sessions — needs investigation).
3. Residual load **~6**, dominated by hung `git rev-parse` processes.
4. Eventually quiescent: at 23:15Z, `pgrep -af "git rev-parse"` returns
   only my own probe shell; load = 0.13.

## Coord-side correlated symptom

From ~04:30 UTC onward (well before Max's report) my own `git` ops in the
coord session timed out at the 10s `timeout(1)` boundary — `git rev-parse
HEAD`, `git status --short`, `git rev-list` all rc=124. **No
`.git/index.lock` present**, **no live `git` processes in my own pgrep**.
Worked around by deferring git invocations and writing files directly.

This now looks like the symptom-side of the same incident: I was queued
behind the runaway `rev-parse` swarm for I/O on `.git/`. The hang resolved
exactly when the runaway processes were reaped.

## Suspected sources of `git rev-parse` accumulation

Hypotheses to validate (not yet investigated):

1. **OpenCode plugin tight loop.** The c2c-plugin (TypeScript) calls into
   shell paths to resolve broker fingerprint / repo identity. If a retry
   path lacks backoff and a transient broker-root mismatch loops it, every
   iteration spawns `git rev-parse` (or shells `c2c whoami`/`c2c list`,
   each of which does its own git probes). #503 (broker-root fallthrough
   resolver) just landed — could a regression have introduced a hot loop?
2. **c2c sidecar repeated spawn.** `c2c monitor` / `c2c list` /
   `c2c whoami` invoked per-event by the plugin would multiply git
   invocations. `c2c --version` was 1.45s pre-#429 (compile-time SHA fix
   landed it to ~2ms); but the version path and the broker-resolution
   path are different code, so #429 alone wouldn't immunize this.
3. **Kimi notifier polling.** Three-guard idle detection (#590) spawns
   c2c probes; if its statefile is being written at high frequency or
   the pending-wake guard is mis-evaluating, the notifier could feedback-
   loop on broker reads.
4. **#598 fallout.** The half-failed restart left aliases offline; if a
   recovery loop somewhere was retrying registration via fork+exec, that
   could ramp.
5. **fsmonitor/index.lock contention** secondary to (1)–(4): each `git`
   invocation grabs the same locks, so once N processes pile up, they
   all stall and zombify.

## Recovery (this case)

- Max `pkill`'d all opencode → primary spawner gone.
- Residual `git rev-parse` reaped naturally as their parents died.
- Side-effect: claude sessions died (this needs its own investigation —
  was the MCP socket on opencode? was claude a child of opencode?).

## Investigation plan (queued; do NOT execute during fragile state)

To be done by test-agent or a fresh peer, after current swarm stabilizes:

- **Audit invocation sites**: grep the opencode c2c-plugin source +
  `ocaml/cli/*.ml` + `scripts/*` for every `git rev-parse` / `git
  remote get-url` / `git rev-parse --show-toplevel` site. Annotate
  each with: (a) is it on a hot path (per-event)?  (b) is there a
  retry without backoff above it?  (c) is the result cacheable?
- **Add invocation telemetry**: a low-overhead env-gated counter
  (`C2C_PROBE_GIT_INVOCATIONS=1`) that logs to `broker.log` per
  process, so we can see ramp curves before the next outage.
- **Cache repo-identity** in long-lived processes: c2c sidecar /
  notifier / opencode plugin should resolve once at startup (or per
  fingerprint-change event) rather than per RPC.
- **Circuit breaker**: process-level guard — if a single process
  spawns `git` >N times/sec, log+backoff+notify.
- **MCP socket dependency check**: when opencode dies, what *should*
  happen to attached claude sessions? Document expected behavior;
  if claude-dying-with-opencode is undesirable, file follow-up.

## Cross-references

- `.collab/findings/2026-05-01T02-35-00Z-coordinator1-c2c-restart-from-inside-session-half-fails.md` —
  preceding event, may have left stale aliases retrying registration.
- `.collab/findings/2026-05-01T03-30-00Z-jungle-coder-590-notifier-pre-binary-stuck-wake.md` —
  three-guard idle work; cross-check whether notifier loop interaction
  was a contributor.
- #429 (c2c --version `git rev-parse` removal) — analogous fix shape if
  another hot path is found.
- #503 (broker-root fallthrough resolver) — recent change to resolution
  logic; check for regression.

## Severity rationale

- **Node-level outage**: Max had to manually triage at the OS layer.
- **Cross-client cascade**: opencode kill → claude death is itself a
  finding-worthy coupling.
- **Silent ramp**: I observed the symptom (git hangs) for ~hours before
  Max saw the load spike and reported. No alarm fired on the swarm side
  to flag "git ops are dying en masse."
- **Reproducibility unknown**: don't know what triggered it. If it's
  a transient interaction, it'll recur.

— Cairn-Vigil
