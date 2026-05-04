# 🚨 Catastrophic CPU spike — git shim self-exec recursion (root cause for 2026-05-01 + 2026-05-02 events)

- **Filed**: 2026-05-02T01:12:00Z by coordinator1 (Cairn-Vigil)
- **Reported by**: Max (in-conversation, 2026-05-02T00:21Z + 00:39Z + 00:48Z)
- **Severity**: CRITICAL — node-level outage; same class as 2026-05-01T23:15Z spike
- **Status**: mitigated (shim replaced 2026-05-02T01:12Z; opencode peers killed via Ctrl+D); fix-forward needed in install code

## Symptom

Max: "load avg at 22… 32… opencode agents have hung… stopped all opencode via ctrl+d."

`ps -eo pid,pcpu,etime,comm --sort=-pcpu` showed 14+ `git` processes
each at **89% CPU**, elapsed times 30–35min, all with `PPID == PID − 1`
or PPID=1 (orphaned). Load average climbed to 32.35 / 5m. Same
fingerprint as the 2026-05-01T23:15Z incident.

## Root cause (CONFIRMED)

The c2c attribution shim at
`/home/xertrov/.local/state/c2c/bin/git` was generated with this body:

```bash
#!/bin/bash
if [ "${C2C_GIT_SHIM_ACTIVE:-}" = "1" ]; then
  exec '/home/xertrov/.local/state/c2c/bin/git' "$@"   # ← points to ITSELF
fi
export C2C_GIT_SHIM_ACTIVE=1
exec git-pre-reset "$@"
```

The "real git" exec target was the shim's own path. Trace:

1. opencode (per-pane) calls `git cat-file --batch` on its snapshot
   tree (legitimate operation).
2. PATH puts `/home/xertrov/.local/state/c2c/bin/` first → resolves
   to attribution shim.
3. `C2C_GIT_SHIM_ACTIVE` not set on first call → exports `=1`,
   `exec git-pre-reset cat-file --batch`.
4. `git-pre-reset` line 22:
   ```bash
   MAIN_TREE="${C2C_GIT_SHIM_MAIN_TREE:-$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo "")}"
   ```
   Shells out to `git rev-parse --git-common-dir`. PATH-resolved
   `git` → attribution shim again.
5. Attribution shim sees `C2C_GIT_SHIM_ACTIVE=1` → takes the
   "delegate to real git" branch → `exec '/home/xertrov/.local/state/c2c/bin/git' "$@"`.
6. **That path is the attribution shim itself.** `exec` replaces
   the process with the same script and same env → re-enters step 5
   → infinite tight `exec` loop, single process at ~89% CPU.

Each `git` invocation by opencode spawns one `git-pre-reset` parent
(hung waiting for the line-22 substitution) plus one infinite-exec-loop
attribution-shim child (CPU-bound). At 7 active opencode peers, each
generating snapshot ops on every prompt edit, the count climbed to
14+ runaway processes.

The `git` shim's `exec '/usr/bin/git' "$@"` branch is intended to
be the "real git" delegate. The code that *generates* the shim
(`Git_helpers.find_real_git`, `ocaml/c2c_start.ml:1525`) walks PATH
and skips the dir named by `C2C_GIT_SHIM_DIR`. When that env var is
unset at install time, `find_real_git` returns the FIRST `git` in
PATH — which can be the c2c shim itself when it was installed in a
prior run. `find_real_git` does not content-check the candidate, so
it can't tell a c2c shim from real git. → **self-pointing shim
written to disk**.

The per-instance variant
(`/home/xertrov/.local/share/c2c/instances/coordinator1/bin/git`)
correctly points to `/usr/bin/git`. Divergence between per-instance
and per-user-state shim install paths is the surface defect.

## Mitigation applied (2026-05-02T01:12Z)

1. Renamed `/home/xertrov/.local/state/c2c/bin/git{,-pre-reset}` to
   `*.DISABLED.shim-recursion` to immediately stop new fork-bombs.
2. Killed remaining hung procs (`pkill -9 -f state/c2c/bin/git`).
3. Wrote a corrected attribution shim (exec target =
   `/usr/bin/git`) at the state location.
4. Restored `git-pre-reset` (the per-reset guard is still
   correct on its own; line 22 only loops because the attribution
   shim was self-pointing).
5. Verified `PATH=/home/xertrov/.local/state/c2c/bin:$PATH git
   rev-parse --short HEAD` returns `b081974a` in <1s, exit 0.
6. Load 1m dropped from 32 → 13 within 1 minute of mitigation.

## Code fix needed (queued for swarm)

**Two-part hardening on `Git_helpers.find_real_git` (`ocaml/Git_helpers.ml:1`):**

1. **Content-check candidate.** Before returning a `git` candidate,
   read its first line — if it's `#!/bin/bash` AND the file contains
   the marker `# Delegation shim: git attribution for managed sessions`,
   skip it regardless of `C2C_GIT_SHIM_DIR`. This is the reliable
   guard.
2. **Hard fallback.** If no non-shim candidate exists in PATH, fall
   back to known-good `/usr/bin/git` if it exists, then `/usr/local/bin/git`,
   then fail loudly. Never write a self-pointing shim — refuse to
   install rather than write a known-broken delegation chain.

**Optional further hardening (`git-pre-reset` line 22):** invoke the
real-git probe via an absolute path captured at shim-install time,
e.g. cache the resolved real-git path in
`/home/xertrov/.local/state/c2c/bin/.real-git-path` and have
`git-pre-reset` `read_path=$(cat ...real-git-path) && exec
$read_path rev-parse --git-common-dir` instead of relying on PATH
resolution at runtime. Removes one layer of "what's git" ambiguity.

## Cross-references

- `.collab/findings/2026-05-01T23-15-00Z-coordinator1-runaway-git-rev-parse-cpu-spike.md`
  — first event same fingerprint; was the warning shot. This finding
  supersedes its hypothesis tree (#1 OpenCode plugin tight loop, #2
  c2c sidecar repeated spawn — both wrong; the loop is the shim
  recursing on itself).
- `.collab/research/2026-05-01-rev-parse-invocation-audit-cedar.md` —
  cedar's audit identified `git-shim.sh:22` as an amplifier; correct
  observation, but the AMPLIFIER becomes a fork-bomb only when
  combined with the self-pointing exec target (this finding).
- `.collab/findings/2026-05-02T08-30-00Z-test-agent-git-rev-parse-audit.md`
  — test-agent's parallel audit; flagged `c2c_repo_fp.ml:12` as
  primary suspect — that's a separate hot-path issue that should
  still be cached (Phase 2B, #610), but is NOT the cause of the
  catastrophic spike.
- #609 (Phase 2A circuit-breaker, birch) — defensive net stays
  valuable even after the code fix above; spawn-rate caps catch
  the next class of bug.
- #611 (Phase 2C shim MAIN_TREE cache + telemetry, cedar) — should
  ALSO incorporate the content-check + hard-fallback fix.

## Severity rationale

- **Two consecutive node-level outages** (2026-05-01 ~23:00Z and
  2026-05-02 ~01:00Z), same root cause, with #604/#609/#610/#611
  in flight to address downstream symptoms but never the proximal
  bug.
- **Self-amplifying**: each opencode prompt edit spawns a snapshot
  `git cat-file --batch` → one runaway. Active swarm = nonstop
  ramp.
- **Hard to diagnose from outside**: process listing shows "git"
  consuming CPU; you have to follow `cmdline` to see the bash-script
  shim, then read the shim to see the self-exec.
- **Recurrence guaranteed without code fix**: any `c2c install`
  re-run from a managed shell will re-write the broken shim.

## Action items

1. (queued) `find_real_git` content-check hardening — author
   needed; severity blocks all swarm operation. Suggest cedar
   (already on Phase 2C) bundles this into #611 OR a new slice
   `#613 git-shim self-exec hardening`.
2. (queued) `git-pre-reset` cache-real-git-path optimization
   (rolls into Phase 2C / #611).
3. **DO NOT run `c2c install self` on this host** until the fix
   lands — would re-write the broken shim. The mitigation is
   manual file content; not durable.
4. todo-ongoing project entry / todo.txt entry for the code fix
   (separate task ID).

— Cairn-Vigil
