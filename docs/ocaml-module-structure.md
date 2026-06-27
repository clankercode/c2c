# OCaml Module Structure: Current Extractions

**File:** `ocaml/cli/c2c.ml` (12,713 LOC as of this audit)
**Status:** Phase 1, Phase 2, and the rooms extraction are complete. This page is a coarse map; prefer module names over line-number references because `c2c.ml` changes frequently.

---

## Extracted Files

| File | LOC | Status |
|------|-----|--------|
| `ocaml/cli/c2c_setup.ml` | 2,099 | **DONE** — client install/setup logic |
| `ocaml/cli/c2c_types.ml` | 12 | **DONE** — small shared CLI types |
| `ocaml/cli/c2c_commands.ml` | 184 | **DONE** — safety-tier command metadata |
| `ocaml/cli/c2c_rooms.ml` | 805 | **DONE** — local room CLI commands and helpers |

Many newer slices also live in dedicated modules, including stats/sitreps, relay-managed helpers, docs drift, worktrees, stickers, memory, migrate, MCP config rewriting, peer-PASS, agents/roles, coordinator helpers, git shim, history formatting, Kimi hooks, approval paths, authorizers, deliver/watch helpers, schedule, uninstall, TUI watch state/data/render, and relay subscribe-daemon support. See `ocaml/cli/dune` for the authoritative module list.

---

## Current `c2c.ml` Responsibilities

`ocaml/cli/c2c.ml` remains the entrypoint module for the `c2c` executable. It still owns:

- top-level command assembly and `Cmdliner` wiring;
- common command helpers that have not yet been moved;
- command groups that delegate into extracted modules;
- compatibility aliases and operator/internal command registration.

Avoid relying on exact line ranges in docs or reviews. Use symbol names plus file paths, then verify with `grep`/editor search in the current checkout.

---

## Extraction Direction

Completed extractions have moved high-churn clusters out of the monolith without changing the command surface. Future extraction candidates are still the remaining large command groups and shared helper clusters, but each slice should preserve the invariant that `c2c.ml` is the executable entrypoint module named by `(name c2c)` in `ocaml/cli/dune`.

## Decision Record

- **2026-04-24:** Phase 1 extracted — `c2c_setup.ml` + `c2c_types.ml`.
- **2026-04-24:** Phase 2 extracted — `c2c_commands.ml`.
- **2026-04-24 and later:** Rooms extraction completed as `c2c_rooms.ml`; subsequent slices continued extracting focused modules listed in `ocaml/cli/dune`.
