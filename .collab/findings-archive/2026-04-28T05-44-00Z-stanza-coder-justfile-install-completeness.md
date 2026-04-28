**Author:** stanza-coder
**Date:** 2026-04-28 15:44 AEST

# justfile install-all completeness audit

## Summary

- 8 primary `.exe` targets in `_build/default/ocaml/{cli,server,tools}/`
  (test binaries excluded). On `master` HEAD, **5 of those are wired into
  `install-all`** (`c2c.exe`, `c2c_mcp_server.exe`,
  `c2c_mcp_server_inner_bin.exe`, `c2c_inbox_hook.exe`,
  `c2c_cold_boot_hook.exe`) plus the `cc-quota` shim.
- **1 binary is built-but-not-installed in master**:
  `c2c_post_compact_hook.exe`. The fix landed on slice branch
  `slice/post-compact-hook-install-wiring` (commit `714c2094`,
  stanza-coder, today) but is **not yet merged to master**, so the
  audit confirms the gap is still live on master right now.
- 3 are test executables (`test_c2c_worktree.exe`, `test_c2c_memory.exe`,
  `test_c2c_stats.exe`, `test_c2c_onboarding.exe`) under
  `ocaml/cli/` — never intended to install. Plus the full `ocaml/test/`
  tree, which is fine.
- The install **stamp** (`scripts/c2c-install-stamp.sh`) records SHA-256
  for `c2c`, `c2c-mcp-server`, `c2c-inbox-hook-ocaml`,
  `c2c-cold-boot-hook` only. **`c2c-mcp-inner` is copied by `install-all`
  but NOT recorded in the stamp** — separate gap from the post-compact
  one, and it predates today's slice.

## Per-binary status (master HEAD, ignoring slice branch)

| Binary | Build target in `install-all`? | Copy in `install-all`? | In stamp? |
|---|---|---|---|
| `c2c` (cli) | yes | yes | yes |
| `c2c-mcp-server` | yes | yes | yes |
| `c2c-mcp-inner` | yes | yes | **NO** (gap) |
| `c2c-inbox-hook-ocaml` | yes | yes | yes |
| `c2c-cold-boot-hook` | yes | yes | yes |
| `c2c-post-compact-hook` | **NO** (gap on master) | **NO** | **NO** |
| `cc-quota` (bash shim) | n/a (generated inline) | yes | n/a |
| `c2c-deliver-inbox` | n/a — hand-written Python shim at `~/.local/bin/c2c-deliver-inbox` (not from `_build`); 101 bytes, exec's `c2c_deliver_inbox.py` | not installed by justfile | n/a |

The stale `~/.local/bin/c2c-post-compact-hook` (Apr 26 23:38, ~3 days
old) on this machine is a direct symptom: every other binary in
`~/.local/bin` was rewritten today (Apr 28 15:21) by `just install-all`,
but the post-compact hook keeps its older mtime because no recipe
touches it. That's exactly the failure mode #349b flagged.

## Gap findings

### HIGH

1. **`c2c-post-compact-hook` not wired into master `install-all`.**
   The hook is on the post-compact context-injection path (#317). Since
   `install-all` neither builds nor copies it, a fresh `just bi` on
   master leaves this binary stale or absent — silently regressing
   post-compact restore. Fix is sitting on slice
   `slice/post-compact-hook-install-wiring` (`714c2094`); just needs
   review-and-fix + cherry-pick to master. The slice ALSO adds the
   stamp entry for this binary, which is good.

### MED

2. **`c2c-mcp-inner` missing from install stamp.** `c2c-mcp-inner` is
   built and copied by `install-all` (lines 162, 170, 173 of justfile)
   but `scripts/c2c-install-stamp.sh` writes only four `binaries.*`
   entries. The stale-MCP diagnostic logic that consumes
   `~/.local/bin/.c2c-version` therefore can't see drift on
   `c2c-mcp-inner`. Trivial to add (one `hash_file` call + JSON
   stanza, mirror existing pattern). The slice `714c2094` adds the
   post-compact entry but doesn't touch this — so even after the
   slice merges, this MED gap remains.

3. **`c2c-deliver-inbox` is a hand-rolled Python shim, not a justfile
   product.** `~/.local/bin/c2c-deliver-inbox` is a 101-byte bash
   wrapper (`exec python3 .../c2c_deliver_inbox.py "$@"`), dated
   2026-04-22, not refreshed by any `install-*` recipe. If
   `c2c_deliver_inbox.py` moves or the wrapper path goes stale on a
   new machine, no recipe fixes it. Consider: either generate it
   inline like `cc-quota` does (line 176 of justfile), or port the
   delivery daemon to OCaml as part of the deprecation push.

### LOW

4. **Orphaned legacy binaries in `~/.local/bin`** —
   `c2c-143`, `c2c-261`, `c2c-new`, `c2c-test`, `c2c-mcp`,
   `c2c-sitrep-test`, `c2c-sitrep-local-test`, `c2c-stats-test`,
   `c2c.exe`, `c2c_mcp_server.exe`, `c2c_mcp_server_inner_bin.exe`,
   `c2c-inbox-hook` (without `-ocaml` suffix), `c2c-gui`. None are
   produced or removed by current recipes; all >2 days stale.
   Cosmetic but contributes to PATH clutter and can mask which
   binary `c2c` resolves to. Consider a `just clean-stale-installs`
   recipe that prunes these.

5. **`install-cli`, `install-mcp`, `install-hook` partial recipes are
   asymmetric.** Only `install-cli`, `install-mcp`, `install-hook`
   exist — no `install-cold-boot-hook`, no `install-post-compact-hook`,
   no `install-mcp-inner`. Operators occasionally reach for these for
   targeted rebuilds; the partial coverage is inconsistent. Either
   complete the set or document `install-all` as the only supported
   path and remove the partials.

## Suggested slice

Two pieces of work, naturally sized for one slice each:

### Slice 1: merge `714c2094` (post-compact hook install wiring)

- Cherry-pick `slice/post-compact-hook-install-wiring` to master via
  the standard worktree-per-slice flow.
- Validates: HIGH gap #1 closes.
- The slice already adds:
  - `(executable c2c_post_compact_hook)` to `ocaml/tools/dune`
  - build target in `build`, `build-server`, `install-all`
  - `rm -f` + `cp` lines in `install-all`
  - hash entry in `c2c-install-stamp.sh`

### Slice 2: stamp + symmetry follow-up

- Add `c2c-mcp-inner` SHA-256 hash entry to
  `scripts/c2c-install-stamp.sh` (MED #2).
- Optional: convert `c2c-deliver-inbox` to inline-generated shim like
  `cc-quota`, or open issue to OCaml-port the delivery daemon
  (MED #3).
- Optional: add `just clean-stale-installs` to prune LOW #4 binaries.

## Hard constraints honoured

- Read-only audit; no justfile or install-state mutations.
- No subagent delegation.
- `just install-all` not run.
