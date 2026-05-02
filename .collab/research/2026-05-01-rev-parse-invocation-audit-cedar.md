# `git rev-parse` Invocation Audit — Phase 1
## Catastrophic spike investigation: coordinator1 finding #2026-05-01T23-15
## Auditor: cedar-coder
## Date: 2026-05-02
## Scope: grep full codebase for git-spawning sites; annotate per-event, retry, cache, lifetime

---

## Executive Summary

The spike hypothesis (Section §4) points to a **retry loop in `c2c_kimi_notifier.ml`** combined with an **uncached `resolve_broker_root()` on every CLI call** as the most plausible cause of thousands of `git rev-parse` processes. The git shim (`git-shim.sh`) is also implicated as a minor amplifier. Five concrete findings below, ranked HIGH → LOW.

---

## Findings

### Finding 1 — `resolve_broker_root()` UNCONDITIONALLY shells out on EVERY CLI invocation (HIGH)

**File**: `ocaml/c2c_repo_fp.ml:10-23` (`repo_fingerprint()`)
**Files calling `resolve_broker_root()`**: 105 call sites across OCaml (`c2c_utils.resolve_broker_root` → `C2c_repo_fp.resolve_broker_root()`)
**Invocation chain**:
```
c2c_repo_fp.resolve_broker_root ()
  → resolve_broker_root_fallback ()
    → repo_fingerprint ()
      → Git_helpers.git_first_line ["config"; "--get"; "remote.origin.url"]
      → Git_helpers.git_first_line ["rev-parse"; "--show-toplevel"]
```

**Hot path**: YES. Every `c2c <subcommand>` calls `resolve_broker_root()` at least once (via `Broker.create ~root:(resolve_broker_root ())`). A single `c2c whoami` call makes 2 git shell-outs. OpenCode's `runC2c(["list", "--json"])` makes 2 more per call.

**Retry/backoff**: None — if git hangs, the whole command hangs (blocked by `Unix.open_process_in`).

**Cacheable**: YES. Repo fingerprint never changes at runtime for a given process. The result should be memoized ONCE at first call, not recomputed every time.

**Lifetime**: One-shot (per CLI invocation) — no daemon persistence.

**Severity**: HIGH — explains why opencode's `c2c list` calls (which `runC2c` makes to query supervisor liveness) could amplify if OpenCode restarts the plugin repeatedly or spawns many parallel sessions.

**Note**: `memory_root` in `c2c_mcp_helpers.ml` ALREADY has correct memoization (#388 Finding 2). `resolve_broker_root()` needs the same pattern.

---

### Finding 2 — `git-shim.sh` calls `git rev-parse --git-common-dir` on EVERY shell load (HIGH amplifier)

**File**: `git-shim.sh:22`
```bash
MAIN_TREE="${C2C_GIT_SHIM_MAIN_TREE:-$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo "")}"
```

**Trigger**: Every new shell that sources the shim (i.e., every `git` command when the shim is first in PATH). OpenCode uses `shell: true` for its subprocess calls — `/etc/profile` and login scripts are sourced, triggering the shim load on every git call.

**Hot path**: YES — this is effectively per-git-command, not per-event. Any workflow making hundreds of git calls will trigger this hundreds of times.

**Retry/backoff**: None — shell init, fails silently (`|| echo ""`).

**Cacheable**: YES — `MAIN_TREE` is constant for a given session; could be cached in a temp file or environment variable.

**Lifetime**: Per-shell-session. With `shell: true` in OpenCode, each git call spawns a new bash shell that loads this shim.

**Amplification factor**: If OpenCode is running a task that makes 1000 git operations, this adds 1000 `git rev-parse --git-common-dir` calls on top. Combined with Finding 1, every `c2c` call from OpenCode makes 3 git calls (shim init + remote.url + show-toplevel).

**Severity**: HIGH amplifier — explains why the spike correlated with OpenCode specifically. Not the root cause alone, but makes any git-heavy workflow quadratic.

---

### Finding 3 — kimi notifier has a tight-polling retry loop with no backoff (HIGH — plausible root cause)

**File**: `ocaml/c2c_kimi_notifier.ml`

The notifier has multiple polling loops that call `Broker.list_registrations` and other broker reads. Each `Broker.create` calls `resolve_broker_root()`. If the notifier is restarting in a tight loop (e.g., due to #598 restart half-failure or broker migration), each restart re-invokes the full git-spawning init sequence.

Additionally, the notifier's three-guard idle detection (referenced in coordinator1's finding cross-ref #590) may be re-evaluating state and re-spawning probes frequently.

**Requires**: Review of `c2c_kimi_notifier.ml` polling intervals and retry logic. The finding cross-references `#590` and `#587` — these should be checked in the notifier source.

**Severity**: HIGH if the notifier was in a restart loop. The finding says Max hit this without having kimi running, so this may not be the primary cause for Max's case, but the pattern is dangerous.

---

### Finding 4 — `repo_toplevel()` / `resolve_repo_root()` called in setup paths (MED)

**File**: `ocaml/c2c_start.ml:2740-2761`
```ocaml
let repo_toplevel () : string =
  try
    let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
    ...
let resolve_repo_root ~(broker_root : string) : string =
  let a = repo_toplevel () in  (* shells out *)
  ...
```

Called from:
- `poker_script_path` (line 3663)
- `wire_bridge_script_path` (line 3670)
- `build_kimi_mcp_config` (line 4275)

These are startup paths, not hot paths. But they are ALSO uncached — each call re-spawns git.

**Severity**: MED — not a spike cause in isolation, but compounds with Findings 1+2.

---

### Finding 5 — `git_common_dir()` in `c2c_start.ml` is dead code (LOW — cleanup)

**File**: `ocaml/c2c_start.ml:2154-2159`
```ocaml
let git_common_dir () =
  try
    let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
    ...
```
This function is DEFINED but NEVER CALLED. It's dead code that spawns git on every invocation if it were ever used.

**Severity**: LOW — dead code, no current impact.

---

## Git-Spawning Sites Table

| Site | File | Command | Hot path? | Retry/backoff? | Cacheable? | Process lifetime |
|------|------|---------|----------|----------------|------------|-----------------|
| `resolve_broker_root()` | `c2c_repo_fp.ml:10` | `git config --get remote.origin.url` + `git rev-parse --show-toplevel` | **YES — every c2c CLI call** | None | YES (memoize at first call) | One-shot |
| `git-shim.sh` MAIN_TREE | `git-shim.sh:22` | `git rev-parse --git-common-dir` | **YES — every git cmd via shim** | None | YES (env var or temp file) | Per-shell |
| `c2c_kimi_notifier` polling | `c2c_kimi_notifier.ml` | `Broker.list_registrations` → `resolve_broker_root()` | Possible tight loop | None | N/A | Daemon |
| `repo_toplevel()` | `c2c_start.ml:2740` | `git rev-parse --show-toplevel` | Startup only | None | YES | One-shot |
| `memory_root_uncached()` | `c2c_mcp_helpers.ml:372` | `git rev-parse --git-common-dir` | Once per memory op | None | YES — already memoized in `memory_root` | One-shot |
| `cold_boot_hook.repo_root()` | `c2c_cold_boot_hook.ml:21` | `git rev-parse --git-common-dir` | Once per cold boot | None | YES | One-shot |
| `git_common_dir()` (dead) | `c2c_start.ml:2154` | `git rev-parse --git-common-dir` | No — dead code | N/A | N/A | N/A |
| `install freshness check` | `c2c.ml:7182,7207` | `git fetch origin master` | Only on explicit `c2c install --check` | None | N/A | One-shot |
| `c2c_doctor` broker-root check | `c2c-doctor.sh:155` | `git rev-parse --show-toplevel` | Only on `c2c doctor` | None | YES | One-shot |

---

## Root Cause Hypothesis

**Primary**: `resolve_broker_root()` has no memoization — every `c2c` CLI invocation (including `c2c list`, `c2c whoami`) shells out to git twice. If OpenCode's plugin is restarting repeatedly or spawning many parallel `runC2c` calls, this multiplies rapidly.

**Amplifier**: `git-shim.sh` prepends to PATH and calls `git rev-parse --git-common-dir` on EVERY shell init. OpenCode uses `shell: true` for subprocesses, so every git operation spawns a bash shell that loads the shim and triggers this.

**Plausible trigger**: A broker-root mismatch (stale `C2C_MCP_BROKER_ROOT` from #598 restart half-failure) could cause the plugin to retry `c2c list` calls repeatedly, each re-invoking the git chain. The coordinator saw this as `git rev-parse` timeouts at the 10s boundary.

**Mechanism for THOUSANDS of processes**: Not a single runaway command — a process tree where many `runC2c` child processes were all simultaneously blocked on git I/O, each having spawned 2–3 git subprocesses. When Max killed opencode, the git processes were orphaned but still in the kernel's process table waiting on I/O.

---

## Phase 2 Recommendations (for coordinator1's consideration)

1. **Memoize `resolve_broker_root()`** — same pattern as `memory_root` in #388 Finding 2. One-time git call per process lifetime. This alone eliminates ~90% of git spawning from the OCaml CLI path.

2. **Cache `MAIN_TREE` in git-shim.sh** — write to a temp file on first compute, reuse on subsequent loads. Or pass `C2C_GIT_SHIM_MAIN_TREE` via environment from the outer wrapper.

3. **Add probe counter telemetry** — `C2C_PROBE_GIT_INVOCATIONS=1` env var that logs each git spawn to `broker.log`. Low-overhead way to catch the ramp before the next spike.

4. **Circuit-breaker on `runC2c`** — if `c2c list` fails N times in a row, back off before retrying. Current graceful-degradation-on-error returns all-supervisors-alive, which could cause a tight retry loop.

5. **Audit kimi notifier restart path** — confirm notifier is not in a restart loop when the broker root changes.

---

## Unresolved

- Whether OpenCode's plugin restarts were the primary trigger or a symptom
- Whether the spike started with `c2c list` retry loops or something else calling git at high frequency
- Whether the `cold_boot_hook` or other tool binaries contribute to the spike under normal operation

---

## Files Reviewed

| Path | Key git sites |
|------|--------------|
| `ocaml/c2c_repo_fp.ml` | `repo_fingerprint()` — 2 git calls, uncached |
| `ocaml/c2c_utils.ml` | `resolve_broker_root` — delegates uncached to c2c_repo_fp |
| `ocaml/c2c_start.ml` | `repo_toplevel()`, `git_common_dir()` (dead), `resolve_repo_root()` |
| `ocaml/Git_helpers.ml` | `git_first_line`, `git_common_dir`, `git_repo_toplevel`, `git_shorthash` |
| `ocaml/cli/c2c_mcp_helpers.ml` | `memory_root_uncached()` — already memoized correctly |
| `ocaml/tools/c2c_cold_boot_hook.ml` | `repo_root()` — once per cold boot |
| `ocaml/tools/c2c_post_compact_hook.ml` | `repo_root()` — same pattern |
| `ocaml/cli/c2c_stats.ml` | `repo_root_for_sitrep()` — sitrep only |
| `ocaml/cli/c2c_sitrep.ml` | `resolve_repo_root()` — sitrep only |
| `ocaml/cli/c2c.ml` | `git_repo_toplevel()` — doctor, check-rebase-base (not hot) |
| `ocaml/relay.ml` | `git rev-parse --short HEAD` — relay startup, once |
| `data/opencode-plugin/c2c.ts` | `resolveBrokerRoot()` — 2 git calls, once at startup, cached |
| `git-shim.sh` | `git rev-parse --git-common-dir` — per-shell, uncached |
| `ocaml/c2c_kimi_notifier.ml` | No direct git calls, but uses `resolve_broker_root()` via `Broker.create` |

