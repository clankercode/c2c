# Code Health Audit — 2026-05-01

- **Author:** willow-coder (subagent)
- **Scope:** #388 periodic code-health audit
- **Worktree:** .worktrees/388-code-health-audit

## Refactor Opportunities

### [MED] `mkdir_p` local redefinitions scattered across test/tool files

**Canonical chain (per `c2c_io.ml` header #400b):**
```
C2c_io.mkdir_p  (ocaml/c2c_io.ml:23 — the single canonical)
  → C2c_mcp.mkdir_p  (re-exports / wraps it)
  → C2c_utils.mkdir_p (ocaml/cli/c2c_utils.ml:12 — thin alias, intentional)
```

**Deviation found:** ~7 test files and 2 tool files redefine `mkdir_p` locally instead of importing the canonical:

| File | Redefinition style |
|------|-------------------|
| `ocaml/tools/c2c_inbox_hook.ml:27` | `let mkdir_p dir = C2c_io.mkdir_p ~mode:0o700 dir` |
| `ocaml/tools/c2c_cold_boot_hook.ml:13` | `let mkdir_p dir = C2c_io.mkdir_p ~mode:0o700 dir` |
| `ocaml/test/test_post_compact_hook.ml:33` | Full recursive impl (not calling canonical) |
| `ocaml/cli/test_c2c_stats.ml:12` | Full recursive impl |
| `ocaml/cli/test_c2c_onboarding.ml:26` | Full recursive impl |
| `ocaml/cli/test_c2c_migrate.ml:19` | Full recursive impl |
| `ocaml/cli/test_c2c_mcp_config_rewriter.ml:7` | Full recursive impl |
| `ocaml/cli/c2c_relay_managed.ml:32` | `let mkdir_p = C2c_utils.mkdir_p` (acceptable alias) |
| `ocaml/cli/c2c_setup.ml:245` | `let mkdir_p dry_run dir = ...` (dry-run wrapper, legitimate) |

**Assessment:** Test-file redefinitions are intentional sandboxing (each test needs its own temp dir tree). The tool-file redefinitions (`c2c_inbox_hook`, `c2c_cold_boot_hook`) are redundant — they just wrap the canonical with a hardcoded `~mode:0o700` that could be called directly. Recommend: delete the local wrappers in `tools/` files, call `C2c_io.mkdir_p ~mode:0o700` inline or use `C2c_utils.mkdir_p`.

### [LOW] `relay_identity.ml` and `relay_enc.ml` both define `mkdir_p_mode`

Both `ocaml/relay_identity.ml:187` and `ocaml/relay_enc.ml:109` define:
```ocaml
let mkdir_p_mode path mode = C2c_io.mkdir_p ~mode path
```
This is a trivial 1-liner wrapper — not a bug, but duplication that could be converged into `C2c_io` directly (add an optional `?mode` parameter to the canonical, already exists at `c2c_io.ml:23`).

---

## Module-Size Outliers

> Threshold: >800 LOC. `post-#450 c2c_mcp.ml` is 434 LOC (clean baseline).

### Files over 800 LOC (verified via `wc -l`):

| File | LOC | Notes |
|------|-----|-------|
| `ocaml/cli/c2c.ml` | 11,246 | CLI root; all command groups. #450 extracted 7 handlers (now separate .ml files). |
| `ocaml/test/test_c2c_mcp.ml` | 11,722 | Largest test file — integration tests for MCP surface. |
| `ocaml/c2c_start.ml` | 5,443 | Agent launch logic — over threshold; natural extraction candidate? |
| `ocaml/relay.ml` | 5,152 | Relay core — already has sibling modules (relay_forwarder, relay_nudge, relay_identity, etc.); large but may be structurally sound. |
| `ocaml/test/test_c2c_start.ml` | 3,752 | Large integration test suite. |
| `ocaml/c2c_broker.ml` | 3,741 | Broker core — over threshold; check for extraction candidates. |
| `ocaml/cli/c2c_setup.ml` | 1,596 | Installation/setup logic. |
| `ocaml/c2c_mcp_helpers_post_broker.ml` | 1,208 | Created in #450 slice 0.5. Hoists helpers used after Broker.boot. Over threshold. |
| `ocaml/test/test_peer_review.ml` | 1,042 | Peer review test suite. |
| `ocaml/cli/c2c_agent.ml` | 984 | Agent management logic. |
| `ocaml/cli/c2c_worktree.ml` | 911 | Worktree management. |

> **Note:** `c2c_mcp.ml` is **434 LOC** post-#450 — not on this list. The earlier figure of 30,041 was a hallucination.

### Handler modules extracted in #450 (all clean, under 600 LOC):

| Module | LOC | Natural extraction? |
|--------|-----|---------------------|
| `c2c_memory_handlers.ml` | 204 | ✓ Small, single responsibility |
| `c2c_room_handlers.ml` | 396 | ✓ Small |
| `c2c_agent_state_handlers.ml` | 172 | ✓ Small |
| `c2c_pending_reply_handlers.ml` | 203 | ✓ Small |
| `c2c_inbox_handlers.ml` | 219 | ✓ Small |
| `c2c_send_handlers.ml` | 343 | ✓ Small |
| `c2c_identity_handlers.ml` | 531 | ✓ Under 600, reasonable |

**Assessment:** #450 slice work was effective — handler modules are all under 600 LOC and `c2c_mcp.ml` is a lean 434 LOC. The remaining large files are in `cli/`, `relay.ml`, `broker.ml`, and `c2c_start.ml` — these are the architectural decomposition targets. `relay.ml` (5,152 LOC) already has sibling modules suggesting it was partially decomposed; `c2c_start.ml` (5,443 LOC) and `c2c_broker.ml` (3,741 LOC) may have similar potential.

---

## Test Coverage Gaps

### #450 extracted handler modules — no dedicated unit tests

The 7 handler modules extracted in #450 S1-S7 have **no dedicated test files**:

| Handler module | LOC | Dedicated test file? |
|----------------|-----|---------------------|
| `c2c_memory_handlers.ml` | 204 | ❌ None |
| `c2c_room_handlers.ml` | 396 | ❌ None |
| `c2c_agent_state_handlers.ml` | 172 | ❌ None |
| `c2c_pending_reply_handlers.ml` | 203 | ❌ None |
| `c2c_inbox_handlers.ml` | 219 | ❌ None |
| `c2c_send_handlers.ml` | 343 | ❌ None |
| `c2c_identity_handlers.ml` | 531 | ❌ None |

**Mitigating factor:** These are tested indirectly through `test_c2c_mcp.ml` (11,722 LOC) and `test_c2c_start.ml` (3,752 LOC) integration tests.

**Risk:** If a handler has a subtle bug (e.g., edge case in room leave/join, memory read/write path), it won't be caught by a targeted regression test. Recommend adding dedicated test files for each handler module, following the pattern of existing test files (e.g., `test_c2c_kimi_notifier.ml`).

---

## Stale TODO/FIXME

### No TODO/FIXME comments found in OCaml code

Extensive grep across all `ocaml/**/*.ml` files for `(* TODO`, `(* FIXME`, `(* XXX`, `(* HACK` returned **zero matches**. The OCaml codebase is clean of age-dated developer notes.

---

## Summary

| Category | Count | Severity |
|----------|-------|----------|
| Parallel canonical (mkdir_p redefinitions in tools/) | 2 | [MED] |
| Trivial duplication (mkdir_p_mode in relay_identity + relay_enc) | 1 | [LOW] |
| Module-size outliers >800 LOC | 11 | [MED] all — c2c_mcp.ml is 434 LOC post-#450 (clean); no [HIGH] outliers remain after fix |
| Handler modules with no dedicated tests | 7 | [MED] |
| Stale TODO/FIXME | 0 | N/A (clean) |
| Dead-code branches (`if false`, unreachable match) | 0 | N/A (clean) |
