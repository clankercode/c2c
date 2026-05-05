# Code-health Audit-5: c2c_start.ml + c2c_setup.ml

**Auditor**: birch-coder
**Date**: 2026-05-04
**Files audited**: `ocaml/c2c_start.ml` (5729 lines), `ocaml/cli/c2c_setup.ml` (~1600 lines)
**Task**: Survey only, no fixes. Rate each finding HIGH/MED/LOW, estimate slice size XS/S/M.

---

## Prior Audit Items (from task description)

### 1. `alias_words` 128-element array — previously flagged HIGH

**Status**: RESOLVED.

Both files now reference the converged `C2c_alias_words` module:
- `c2c_start.ml:2311`: `let words = C2c_alias_words.words`
- `c2c_setup.ml:187`: `let words = C2c_alias_words.words`

The comment at `c2c_start.ml:2305-2307` explicitly notes this was converged in #388. The 128-entry literal is no longer duplicated.

**Verdict**: Not a finding. Was previously HIGH, now fixed.

---

### 2. 3× inline `mkdir_p` copies in c2c_setup.ml — previously flagged MED

**Status**: RESOLVED (or was a false alarm).

`c2c_setup.ml` has exactly one `mkdir_p` definition at line 245:
```ocaml
let mkdir_p dry_run dir =
  if dry_run then ...
  else C2c_mcp.mkdir_p dir
```
It delegates to `C2c_mcp.mkdir_p`. The file also has `mkdir_or_dryrun` (line 239) which wraps `Unix.mkdir` directly — a distinct function.

The "3× inline copies" description does not match current state. Either the copies were removed in a prior refactoring, or the prior audit miscounted (the file has many call sites that invoke `mkdir_p` but only one definition).

**Verdict**: Not a finding. No action needed.

---

## New Findings

### Finding 1 — `resolve_effective_extra_args` defined twice

**File**: `c2c_start.ml`
**Severity**: MEDIUM
**Slice size**: XS (single duplicate definition; trivial fix is one-line deletion)

**Description**: `resolve_effective_extra_args` is defined at line 2473 AND again at line 2491. Both definitions are identical:

```ocaml
let resolve_effective_extra_args
    ~(cli_extra_args : string list)
    ~(persisted_extra_args : string list) : string list =
  ignore persisted_extra_args;
  cli_extra_args
```

The second definition (line 2491) completely shadows the first. The second one has the same comment block above it (lines 2479-2490) which is also identical to the comment above the first. This is a textbook copy-paste duplicate — someone likely copy-pasted the function block and forgot to delete the original.

The function is called at line 5298 from `cmd_start`'s resume path.

**Fix**: Delete the second definition (lines 2491-2496).

---

### Finding 2 — `run_outer_loop` is extremely large (~1035 lines)

**File**: `c2c_start.ml` lines 4043-5067
**Severity**: LOW (architectural, not a bug)
**Slice size**: M (significant refactor; not urgent)

**Description**: `run_outer_loop` spans ~1035 lines and handles:
- Binary resolution + pre-flight checks
- Directory setup (mkdir_p, tmux location, expected-cwd)
- Git shim installation
- Registry precheck + instance lock
- Environment construction (build_env)
- Kimi session pre-seeding
- Managed client fork + inner child setup
- PTY/deliver/poker daemon spawning
- Signal handling (SIGTERM handler)
- Stderr tee thread
- OpenCode plugin refresh
- Session resume logic
- Exit handling + orphan capture
- Restart detection (exit 42 → stale broker_root)

This function is doing too many things. A clean split would be into sub-functions:
- `prepare_instance` (dirs, shims, locks)
- `build_launch_env` (currently inline in `run_outer_loop`)
- `spawn_child` (fork + exec + inner child setup)
- `start_sidecars` (deliver, poker, notifier, tee)

**Risk of current state**: The nested `if/else` chains inside the child fork block (lines 4566-4753) are particularly hard to follow. Any change to one client type risks breaking another.

**Not urgent** — the function is well-commented and has been stable. Worth a future cleanup pass.

---

### Finding 3 — `start_stderr_tee` is ~91 lines with complex state machine

**File**: `c2c_start.ml` lines 2164-2254
**Severity**: LOW
**Slice size**: S

**Description**: `start_stderr_tee` manages a tee thread with:
- A log ring buffer (2 MB rotation)
- Line-buffered flushing with partial-line handling
- Stop-pipe for clean shutdown
- Two-mode output (outer stderr + log file simultaneously)

The function is 91 lines with a deeply nested `Thread.create` callback containing a recursive `loop` inside another `try/with`. The comment block explaining the shutdown sequence (lines 4940-4950 in `run_outer_loop`) is actually describing the shutdown **caller's** responsibility, not the tee thread itself — this is confusing since the tee thread's own shutdown logic (using the stop pipe) is in `start_stderr_tee`.

One real concern: the stop-pipe shutdown pattern (close outer_stderr_fd → close tee_write_fd → signal stop pipe → Thread.join) in the caller is fragile. If the tee thread is blocked writing to outer_stderr_fd when the caller closes it, the tee thread's `flush_line` will get EBADF and raise, but the `with _ -> ()` will silently swallow it. This is by design per the comment but worth documenting inline.

---

### Finding 4 — `start_stderr_tee` return type conflates thread with fd lifetime

**File**: `c2c_start.ml` lines 2164-2254
**Severity**: LOW
**Slice size**: S

**Description**: `start_stderr_tee` returns `(pipe_write_fd, stop_write_fd, tee_thread)`. The caller must keep both file descriptors open for the thread's lifetime — closing either prematurely will cause the tee thread to misbehave (tee_write_fd closure → EPIPE on next write; stop_write_fd closure → stop signal never fires). There is no encapsulation enforcing this; the fd lifetimes are implicit in the caller's structured-exit path (lines 4940-4962).

A cleaner design would wrap the tee thread + its resources in a single imperative handle with a `stop` method, so the fd lifetime and thread lifetime are tied together and cannot be misused independently. This is a design smell rather than a bug.

---

### Finding 5 — `deliver_command` returns `None` silently on missing binary

**File**: `c2c_start.ml` line 3198-3201
**Severity**: LOW
**Slice size**: XS

```ocaml
let deliver_command ~(broker_root : string) : (string * string list) option =
  Option.map (fun path -> (path, [])) (find_binary "c2c-deliver-inbox")
```

When `c2c-deliver-inbox` is not on PATH, this returns `None` silently. Callers (the deliver-daemon spawn path in `start_deliver_daemon`) handle this by not spawning the daemon. However, the decision to skip the daemon is invisible to operators — they get no warning that delivery will be degraded.

A `Printf.eprintf` warning when the binary is absent (but `needs_deliver = true` for the client) would make the degraded state self-evident.

---

### Finding 6 — `setup_claude` is ~240 lines with deeply nested JSON manipulation

**File**: `c2c_setup.ml` lines ~955-1196+
**Severity**: LOW
**Slice size**: M

**Description**: `setup_claude` handles:
- MCP config file (project-global or user-global) read/write
- PostToolUse hook script write + registration
- PreToolUse permission-forwarding hook registration
- Settings.json mutation (hooks list manipulation)

The settings.json mutation is ~90 lines of hand-rolled JSON traversal with no helper abstraction. The pattern of "find existing hooks list → append or update our entry → write back" is repeated for PostToolUse and PreToolUse with slightly different logic.

A `hook_entry_exists`, `upsert_hook_entry`, and `remove_hook_entry` helper trio would reduce this significantly and make the logic more testable.

Note: This function works correctly — the concern is maintainability as the hook registration logic continues to grow (e.g. future hook types).

---

### Finding 7 — `write_git_shim_atomic` uses temp file in same dir (correct pattern, worth noting)

**File**: `c2c_start.ml` lines 1623-1667
**Severity**: Informational

The atomic-install pattern (`write to *.tmp.<pid>`, `fsync`, `rename`) is correctly implemented here and in `write_json_file_atomic`. This is the right approach for atomic updates. No action needed.

---

## Summary Table

| # | Finding | File | Severity | Slice |
|---|---------|------|----------|-------|
| 1 | `resolve_effective_extra_args` defined twice (2473, 2491) | c2c_start.ml | MEDIUM | XS |
| 2 | `run_outer_loop` ~1035 lines — too many responsibilities | c2c_start.ml | LOW | M |
| 3 | `start_stderr_tee` 91 lines — complex state machine | c2c_start.ml | LOW | S |
| 4 | `start_stderr_tee` fd lifetime not encapsulated | c2c_start.ml | LOW | S |
| 5 | `deliver_command` silent None — no operator warning | c2c_start.ml | LOW | XS |
| 6 | `setup_claude` ~240 lines with hand-rolled JSON | c2c_setup.ml | LOW | M |
| 7 | Informational: atomic-write pattern correct | c2c_start.ml | — | — |

**Prior HIGH (alias_words duplication)**: RESOLVED.
**Prior MED (mkdir_p 3× copies)**: RESOLVED (or was a miscount).

**Total actionable findings**: 7 (0 HIGH, 6 LOW, 1 informational).
**Immediate fix recommendation**: Fix #1 (duplicate function) — XS slice, trivial fix, eliminates dead code.