# Design — sub-50ms `c2c --version` (#429)

**Author:** Cairn-Vigil (coordinator1)
**Date:** 2026-04-29
**Status:** Design — not yet implemented
**Related:** #418 (fast-path dispatch), #420 (compile-time SHA), #429 (this)

## Problem

`c2c --version` measured at 1.45s on Max's machine, ~1.8s on coordinator1's
host. A trivial `print_endline "hi"` ocamlopt binary on the same host runs
in ~2ms. The fast-path at the top of `c2c.ml`'s `let () =` already short-
circuits `--version` (lines 9530-9533) — yet the binary still pays ~1.4s of
**module initialization** that runs *before* `let () = try_fast_path ()` is
even reached.

Where the cost goes (audit of top-level `let () = …` initializers and
load-time work):

- `cli/c2c.ml` itself: 49 Cmdliner term/Cmd constructors built at top
  level (the `all_cmds` list and every `let foo_cmd = …` it pulls in).
  Each builds `Cmdliner.Term.t` / `Cmd.t` thunks eagerly.
- `c2c_mcp.ml:3351` — Peer_review pin-rotate logger registration.
- `c2c_start.ml:1112,1283,2841-2844` — adapter Hashtbl populated at load.
- `Banner.ml:12` — theme table populated at load (cheap, but loaded).
- `cli/c2c_peer_pass.ml:373` — top-level effect.
- Indirect: any `Mirage_crypto_rng_unix.use_default ()` reachable from
  module init (relay_signed_ops, relay_e2e, relay_enc, relay_identity,
  c2c_stickers — most are guarded inside functions, but the load brings
  in compiled code, GC, and the linked `mirage-crypto` C stubs).
- 23MB binary, 6 shared libs only — dynamic linking is NOT the cost.
  OCaml runtime startup + module init dominates.

`#420` already removed the ~1s `git rev-parse` shellout. The remaining
1.4s is structural: the binary is too big to start fast, and the
fast-path runs after `Stdlib`/all transitive modules have been
initialised.

## Goal

`c2c --version` (and ideally `c2c help`, `c2c commands`) returns in
**< 50ms** wall-clock on a warm cache, **< 100ms** cold.

This matters because:

1. Shell prompts, `c2c doctor`, install validators, peer-PASS scripts,
   smoke tests, and `restart-self` all call `--version` repeatedly to
   validate "did the new binary land". 1.4s × N calls per slice handoff
   adds real friction.
2. It's a canary for cold-start cost — anything that fixes `--version`
   also speeds up `c2c whoami`, `c2c list`, etc. (the dogfood-critical
   Tier 1 commands).

## Approaches

### A. Shell wrapper + tiny `c2c-impl-version` binary

`/home/.../bin/c2c` becomes a 5-line POSIX shell script:

```sh
#!/bin/sh
case "$1" in
  --version|-v) exec c2c-impl-version ;;
esac
exec c2c-impl "$@"
```

Two installed binaries: `c2c-impl-version` (one-screen OCaml file, prints
embedded `Version.version` + `Version.git_sha`) and `c2c-impl` (current
binary, renamed).

**Effort:** ~1 day. Add a second `executable` stanza in
`ocaml/cli/dune` referencing only `Version` (not `c2c_mcp` library).
Adjust `just install-all` to install both.

**Wall-clock:** trivial OCaml binary linking only `Version` is ~5-10ms
cold, ~2-3ms warm. Add ~3-5ms shell fork-exec → **8-15ms** total. **Easily
hits sub-50ms.**

**Dogfood blast radius:** HIGH.
- `which c2c` no longer reports an ELF binary; tools that `file $(which c2c)`
  break (e.g. `c2c doctor` install integrity, `.c2c-version` stamp logic
  in `c2c install`, `#322` install-stamp SHA-256).
- The install guard (`#302`) is keyed off the `c2c` binary; needs to know
  about both files.
- `c2c restart-self` and PATH-tracking heuristics may follow the wrapper
  vs. the impl differently.
- `realpath $(which c2c)` results change for any script that reads it.

**Distribution:** Two binaries to ship (Railway Docker image, GitHub
release artifacts). Shell wrapper must be POSIX-portable (no bashisms);
on macOS/Linux fine, on weird BSD installs maybe surprising. The wrapper
adds one PATH lookup per invocation.

### B. ELF custom section + `readelf` in shell wrapper

Same wrapper shape, but `--version` becomes
`readelf -p .c2c_version $(realpath $(which c2c)) | tail -1`.

**Effort:** ~1 day, but more fiddly. Need a dune rule that runs `objcopy
--add-section .c2c_version=version.txt` after link. Need to handle
`readelf` not being on $PATH on minimal images.

**Wall-clock:** `readelf` startup ≈ 10ms; shell ~5ms; **15-25ms total**.
Hits sub-50ms.

**Dogfood blast radius:** MEDIUM-HIGH. Same wrapper-identity issues as
A. Plus a hard dependency on binutils at runtime, which the c2c project
hasn't required before. Plus `readelf -p` output format is parseable but
not stable across binutils versions.

**Distribution:** Single OCaml binary (good), but adds binutils as a
runtime dep (bad for slim Docker images and `c2c install` on hosts
without binutils). Cross-platform: Linux fine, macOS uses Mach-O
(`otool -s`), Windows is its own world. We currently target Linux + macOS.

### C. Lazy-init the existing main binary

Convert top-level `let () = …` initializers to `let init_X () = …` thunks,
called only on the slow path. Specifically:

- Hoist the 49 Cmdliner `Cmd.t` builders behind a `let cmds = lazy …`
  thunk. The fast-path never forces `cmds`.
- Move `Peer_review.set_pin_rotate_logger` call out of module init into
  a `Cli_init.ensure ()` call gated on slow-path entry.
- Move adapter `Hashtbl.add` calls in `c2c_start.ml` into a similarly
  lazy registry.
- Audit transitive deps: any module reachable only from slow-path
  commands should not have its `let () = …` fire on `--version`.

**Effort:** 3-5 days, plus a continuous burden. Fixing the
"initializer" pattern in OCaml is doable but each fix risks subtle
regressions (e.g. forgetting a side-effect a downstream module relied
on at load time). Requires whole-module audit. Tests must cover
"thunk forced once, fast-path doesn't force, slow-path does" ordering.

**Wall-clock:** Best case ~5-15ms (we approach the trivial-binary
floor). Realistic case: 100-300ms — there are still ~6MB of compiled
code to fault into the page cache cold, and we cannot lazy-init *all*
of OCaml's stdlib + cohttp + sqlite3 + mirage-crypto stubs. The big
wins come from skipping Cmdliner's eager term construction, which is
likely the single biggest contributor.

**Dogfood blast radius:** LOW for the right invocations (single
binary, no install/PATH changes), HIGH for the wrong ones (any module
that quietly relied on load-order side effects breaks subtly across
all commands, not just `--version`).

**Distribution:** Zero change. Single binary, single install path, no
new runtime deps.

## Comparison table

| Aspect            | A (wrapper+mini)   | B (ELF section)    | C (lazy-init)      |
|-------------------|--------------------|--------------------|--------------------|
| Wall-clock target | ✅ 8-15ms          | ✅ 15-25ms         | ⚠️ 100-300ms (best ~15) |
| Effort (days)     | 1                  | 1                  | 3-5 + audit burden |
| Single binary?    | ❌                 | ✅                 | ✅                 |
| New runtime deps  | None (POSIX sh)    | binutils           | None               |
| Install changes   | Two binaries       | objcopy step       | None               |
| Dogfood breakage  | HIGH (file/which)  | HIGH (file/which)  | LOW–HIGH           |
| Reversibility     | Easy (rm script)   | Easy (rm rule)     | Hard (audit trail) |
| Future extensibility | Add `c2c-impl-help` etc. | Limited       | Speeds up everything |

## Recommendation: **C (lazy-init)** with **A as a fallback if C stalls**

### Rationale

The dogfood cost of A/B is the deciding factor. We have ~10 places
across `c2c install`, `c2c doctor`, `#302` install-guard, `#322`
install-stamp, peer-PASS validators, and `c2c restart-self` that
`stat`/`realpath`/`file` the `c2c` binary directly. Splitting `c2c`
into a script + impl is a multi-week ripple of "oh, this also
broke" — exactly the kind of friction Max told us NOT to spend
energy on (`feedback_solve_easy_stuff_yourself.md` cuts the other
way: don't *introduce* new yak-shaves).

C is harder per-engineer-day but its wins compound: every Tier 1
CLI command (whoami, list, send, peek_inbox) gets a slice of the
same speedup, not just `--version`. The "audit burden" risk is real
but bounded — we already enumerated the top-level initializers
above (≤ 10 sites total in our codebase).

The 100-300ms realistic floor for C is **still 5-10× better than
today** and well within the dogfood-comfort zone, even if we miss
the 50ms target. `--version` is invoked from scripts; 200ms is
indistinguishable from 50ms for human perception, and shell loops
calling it 50× per smoke run drop from 70s to 10s — that's the
real win.

If after slice 1 (Cmdliner laziness) we measure < 200ms and want
the extra 150ms, we can layer A on top later with clearer eyes —
a future "shell wrapper" commit lives well behind a working C
implementation. We do NOT want a wrapper as the only line of
defense against slow startup.

### Slice sketch (recommended path: C)

Worktree: `.worktrees/429-version-fast/`. Branch from `origin/master`.

**Commit 1 — measure + baseline (research, no code change).**
Add a `bench/version_startup.sh` that runs `c2c --version` 20×, reports
median+p99. Add an `alcotest` slow-flag perf test. File a
`.collab/findings/` note with the baseline numbers per host. ~1h work.

**Commit 2 — lazy Cmdliner term construction.**
Wrap `all_cmds` (cli/c2c.ml:9544-9548) and the 49 individual
`let foo_cmd = …` Cmdliner term builders in `lazy`. Force only inside
the slow-path branch of `let () =`. Confirm `try_fast_path ()` does not
reference any `Lazy.force`-required value. Re-run baseline. Expected:
~70-80% of the win, single-file diff. ~3h work + test.

**Commit 3 — lazy-init the `let () = …` side-effect registrations.**
Convert `c2c_mcp.ml:3351` (Peer_review logger), `c2c_start.ml:1112,
1283, 2841-2844` (adapter table), and `cli/c2c_peer_pass.ml:373` into
explicit `init ()` calls invoked from a single `Cli_init.ensure ()`
that the slow path hits before dispatch. Audit transitive deps for
any module-load side effects we're now skipping (grep for `Lwt_main`,
`Mirage_crypto_rng_unix.use_default`, `Random.self_init` reachable
from module init — most are already inside functions). ~4h work +
test + peer-PASS.

**Commit 4 — peer-PASS, doc updates, finding note.**
Update `.collab/findings/<ts>-cairn-429-version-startup.md` with
final numbers. If we hit < 100ms, mark closed. If we land at
200-300ms, file a follow-up issue for "approach A as add-on". Run
`review-and-fix` skill in-tree, peer-PASS DM to coordinator with
SHA, await coord-PASS before push.

### What NOT to do in this slice

- Do **NOT** strip the binary or add LTO as part of this slice — those
  are #429-adjacent but separately scoped and high-risk.
- Do **NOT** change `Version.git_sha` regeneration (#420 already
  resolved — leaving alone).
- Do **NOT** touch `try_fast_path ()` itself unless we find a bug;
  it already does the right thing.
- Do **NOT** introduce a shell wrapper as part of this slice. If C
  underdelivers, A is a *future* slice.

## Open questions for review

1. Are there any Cmdliner subcommand groups that *must* be constructed
   eagerly because their `~doc` strings depend on side-effectful
   module init (e.g. probing the env)? Spot-check during commit 2.
2. Does Bechamel or a similar OCaml microbench library justify its
   weight here, or is `time` + 20-iteration shell loop sufficient?
   Lean toward shell loop — fewer deps, more reproducible across
   peer machines.
3. Is `--version` invocation surface count actually as high as I'm
   asserting? Quick `git grep "c2c --version"` should validate before
   commit 1.
