# #429 — `c2c --version` init-cost investigation

**Date**: 2026-04-29  
**Author**: stanza-coder (subagent dispatch)  
**Baseline**: `c2c --version` ≈ **1.45–1.85s wall-clock**, ~1.65s CPU. Trivial OCaml `print_endline` runs in ~5ms, so this is c2c-specific init, not OCaml runtime overhead. (Disproves the earlier "1.6–1.9s structural floor" claim in `2026-04-29-stanza-coder-419-lean-init-audit.md`.)

## Methodology

Worktree: `.worktrees/429-init-cost-instrument/` (branch `429-init-instrument` off `origin/master`). Read-only audit; no commits to master.

Added a tiny `ocaml/init_timer.ml` (Unix-only) prepended to the `c2c_mcp` library module list:
```ocaml
let t0 = Unix.gettimeofday ()
let cpu0 = Sys.time ()
let mark name = Printf.eprintf "[init %.1fms +%.1fms cpu=%.1fms] %s\n%!" ...
```
Tracks **wall-clock since first user code** + **per-mark delta** + **cumulative CPU**.

Inserted `let () = Init_timer.mark "..."` at the top of every c2c-owned library module, then bisected within the offending module. Built with `dune build --root .` from the worktree, ran `_build/default/ocaml/cli/c2c.exe --version 2>&1`.

Pre-`Init_timer` cost (linker + Lwt/Cohttp/Mirage-crypto/Sqlite/Hacl/X509/Conduit/CA-certs library `let () =` blocks): **~8ms CPU**. Confirmed independently with a probe binary linking those same libs: ~5ms total. **External library init is not the problem.**

## Top-3 init sites

The entire 1.45s wall-clock cost lives in two top-level `let`-bindings near the top of `ocaml/c2c_mcp.ml`, both in the `c2c_mcp` library that is linked into both `c2c.exe` and the MCP server. Mark output (representative run):

```
[init     0.1ms cpu=0.1ms] lib:c2c_mcp                                  ← types only above this point
[init   796.0ms +795.9ms cpu=0.2ms] before server_runtime_identity      ← lines 1–209
[init  1485.7ms +689.7ms cpu=681.9ms] after server_runtime_identity     ← lines 209–222
[init  1485.8ms +  0.0ms cpu=682.0ms] after Broker module               ← rest of file is FREE
```

### #1 — `git rev-parse --short HEAD` shell-out
**File**: `ocaml/c2c_mcp.ml:133-143` (master line numbers).  
**Cost**: **~796ms wall, <1ms CPU** (pure fork+exec+git blocking).  
**What it does**: shells out to `git rev-parse --short HEAD` to populate `server_git_hash`, used only inside the `server_info` JSON returned by the MCP `initialize` handler.  
**Why this hurts**: runs at every binary load — `c2c list`, `c2c --version`, every CLI invocation, every `c2c doctor` self-test sub-call, etc. **Even though #420 already embeds a compile-time git SHA in `Version.git_sha`, this code path is a duplicate that ignores the embedded value.** Wall-clock varies (cold vs warm git, repo size, FS cache); CPU is essentially zero because the calling process is blocked on `wait()`.

### #2 — SHA-256 of the entire 23 MB c2c binary
**File**: `ocaml/c2c_mcp.ml:208-220` (`let server_runtime_identity = ...`).  
**Cost**: **~690ms wall, ~680ms CPU** — read the 23 MB executable into memory, run `Digestif.SHA256.digest_string`, hex-encode.  
**What it does**: builds a `runtime_identity` JSON record (pid, started_at, executable path, executable mtime, **executable_sha256**) used only by the MCP server's `initialize` response and the `mcp__c2c__server_info` tool — for stale-MCP diagnostics (#282).  
**Why this hurts**: pure CPU work hashing the binary on every process startup, regardless of whether anything will ever read the field. Runs even for `c2c --version`, where it is unconditionally wasted. Direct readlink+SHA256+stat calls happen at module-init time (top-level `let server_runtime_identity = let executable = ... in let executable_mtime = ... in `Assoc [ ... best_effort_file_sha256 executable ... ]`).

### #3 — everything else
< 5ms total combined. The rest of `c2c_mcp.ml`, `module Broker`, `c2c_start.ml`, `relay*.ml`, `peer_review.ml`, `c2c.ml`'s body — every other instrumented module printed within 1ms of the previous mark. **There is no third meaningful init site.** The `c2c_start.ml` `Hashtbl.add client_adapters` (Cairn's #418 candidate), `c2c_peer_pass.ml:373` and `c2c_mcp.ml:3351` registrations are all < 0.1ms each.

## Quick-win candidates (>100ms each)

Both #1 and #2 are pure quick wins — the values exist solely to populate `server_info` for the MCP `initialize` response. CLI subcommands never read them.

**Fix #1 (~796ms saved)**: replace the live `git rev-parse` shell-out with `Version.git_sha` (the value already embedded at compile time by the `version_git_sha.ml` dune rule, #420). Keep the `RAILWAY_GIT_COMMIT_SHA` env-var override for Railway-deployed builds. Net change: delete lines 137-143, replace with the env-var fallback to `Version.git_sha`.

**Fix #2 (~690ms saved)**: wrap `server_runtime_identity` (and `server_info`, which transitively forces it) in `lazy`, and force them only inside the `initialize` and `server_info` handlers. The MCP server pays the cost once per spawn (acceptable — MCP clients spawn the server rarely). The CLI never pays it. Concretely:

```ocaml
let server_runtime_identity = lazy (
  let executable = best_effort_server_executable () in
  ... `Assoc [ ... best_effort_file_sha256 executable ... ]
)
let server_info = lazy (`Assoc [ ... ; ("runtime_identity", Lazy.force server_runtime_identity) ])
```

Combined: **~1.45s → ~5–10ms** for `c2c --version` and any other CLI subcommand. Restores the binary to "feels instant" range.

## Risks

- **Fix #1**: the embedded `Version.git_sha` is the value at *build time* of the binary. If the binary is run from a checkout whose HEAD has moved past the build, the live rev-parse would have reported the newer SHA. In practice this is fine — `server_info` is meant to identify the running binary, not the working tree. The `c2c doctor` "stale MCP" check (#282) wants build identity, not workdir state. Caller assumptions to verify before landing.
- **Fix #2**: `server_info` callers (the `mcp__c2c__server_info` tool, `c2c doctor` checks 1–3 in `c2c.ml:6972`) need to call `Lazy.force server_info`. Trivial mechanical change. No correctness risk — the lazy is a one-shot memoizer.
- **Both**: don't accidentally expose `Version.git_sha = "unknown"` in production. The build rule already falls back to "unknown" when `git` is unavailable; the env-var override (`C2C_BUILD_GIT_SHA`, `RAILWAY_GIT_COMMIT_SHA`) is the prod escape hatch.

## Next-slice proposal — `#429a` and `#429b`

**`#429a` (small, < 30 LOC)**: replace `server_git_hash`'s `git rev-parse` shell-out with `Version.git_sha`. Keep `RAILWAY_GIT_COMMIT_SHA` precedence. Self-tests: `c2c --version` shows the correct SHA from the dune-generated `version_git_sha.ml`; `mcp__c2c__server_info` returns the same SHA; on a binary built without git, "unknown" is reported. AC: `time c2c --version` drops by ≈ 800ms.

**`#429b` (small)**: wrap `server_runtime_identity` and `server_info` in `lazy`, force at first read inside the MCP handler(s). Self-tests: `c2c --version` no longer reads `/proc/self/exe` or hashes the binary (verify with `strace -e openat,read` if available, otherwise via timing); MCP `server_info` tool still returns a populated `runtime_identity`. AC: `time c2c --version` drops a further ≈ 700ms.

After both: expected `c2c --version` ≈ **5–10ms** (matches the `print_endline` probe). Slate's #418 fast path becomes the dominant cost again, but the absolute number is small enough that further reduction needs a different approach (stripped binary, or `c2c-fast` for CLI-only).

## Files / artifacts

- Worktree: `/home/xertrov/src/c2c/.worktrees/429-init-cost-instrument/` (uncommitted instrumentation; `branch 429-init-instrument`).
- Instrumentation module: `ocaml/init_timer.ml` (Unix-only, ~15 LOC).
- Mark dump from a representative run included above.
- Master file references:
  - `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:133-143` — git rev-parse shell-out.
  - `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:208-220` — binary SHA-256.
  - `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:222-230` — `server_info` consumer.
  - `/home/xertrov/src/c2c/ocaml/dune:13-27` — existing #420 compile-time SHA rule (re-use this for fix #1).
  - `/home/xertrov/src/c2c/ocaml/cli/c2c.ml:9474-9534` — fast-path try block (already routes `--version`).
