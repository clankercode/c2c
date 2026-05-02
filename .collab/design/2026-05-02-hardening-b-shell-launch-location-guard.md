# Hardening B: Shell-Launch-Location Guard

## Context

Two incidents during the catastrophic-spike push had agents whose shells were
`pwd`-ed into the main tree (`/home/xertrov/src/c2c`) while their actual
worktree was `.worktrees/<slice>/`. Git operations from that shell mutated the
main tree's HEAD (shared `.git/` layout). This is a Pattern 6/13/14
contamination class.

This is a **design-only slice** (no implementation).

Filed from: `.collab/findings/2026-05-02T01-45-00Z-coordinator1-shim-regression-cluster-and-main-tree-branch-flips.md § Hardening B`

## Design

### Mechanism

1. **At `c2c start <client>`**: the outer wrapper resolves the `cwd` at
   launch time and writes it to `.c2c/instances/<alias>/expected-cwd` as a plain
   text file (single line, the absolute path).

2. **On `c2c send` / `c2c list` / `c2c poll-inbox`** (any broker-facing
   call from that session): the MCP handler reads `expected-cwd` and compares it
   to the actual `cwd` of the calling process. If they differ:
   - The broker logs a soft warning to `broker.log` with a `[WORKTREE-MISMATCH]` tag.
   - The warning includes: alias, expected path, actual path, session_id.
   - When the mismatch clears (agent `cd`s back to expected), log at INFO level.

3. **No hard blocking**: agents may legitimately shell into other trees for
   read-only operations. This is a soft warn, not a guard.

4. **`c2c restart` re-writes the file**: the shell re-launches from wherever
   `c2c restart` was run — that's the new canonical cwd. Without re-write,
   an agent finishing slice X and restarting from slice Y's worktree would still
   carry the old `expected-cwd`.

5. **`C2C_COORDINATOR=1` exempt**: the coordinator may intentionally run from
   the main tree. Skip the check when `is_coordinator ()` is true (same env var
   bypass as pre-reset shim).

6. **Cross-host skip**: if `sender_fp ≠ broker_fp` (registration metadata),
   skip the check — `cwd` is only meaningful on the same host.

### File Format

```
# .c2c/instances/<alias>/expected-cwd
# One line, absolute path, no trailing newline
/home/xertrov/src/c2c/.worktrees/my-slice
```

### Pre-requisite: cwd in Registration Metadata ⚠️

**CONFIRMED (fern-coder, 2026-05-02): `cwd` is NOT in registration metadata.**
Registration captures: alias, session_id, pid, client, model — no cwd.

**This is a hard prerequisite.** Adding the mismatch check requires:
1. Adding `cwd: string` to the registration schema in `c2c_mcp.ml`
2. Capturing `cwd` in the `register` handler (from `Unix.getcwd ()` at registration time)
3. Surfacing `cwd` in `c2c list --json` output
4. Adding the `expected-cwd` file + comparison logic (the Hardening B slice proper)

Hardening B slice proper (this doc) should be split into two slices:
- **Pre-requisite slice**: add `cwd` to registration schema
- **Hardening B proper**: `expected-cwd` file + broker mismatch check

Do NOT begin Hardening B proper until the `cwd`-in-registration prerequisite is landed.

### Scope Decisions

- **Only the outer wrapper writes this file** (not the inner agent process,
  not the broker). The outer wrapper's `cwd` at `c2c start` time is the
  canonical expected path.
- **The comparison is broker-side**: the broker reads `expected-cwd` and compares
  to the sender's actual `cwd` (from the registration metadata). This means
  it works regardless of the agent's internal shell state.
- **Only agents have this file** — human instances (`c2c start claude -n xertrov`)
  do not need this mechanism (humans know where they are).

### Open Questions (resolved via implementer review)

~~1. **When does the file get updated?**~~ Resolved: only at `c2c start`;
   rewritten on `c2c restart`. Passive `cd` does NOT update it.

~~2. **Warning suppression?**~~ Resolved: yes — log INFO when mismatch clears.

3. **Relationship to `c2c_instances_dir`** — the file lives alongside
   `outer.pid`, `inner.pid`, `deliver.pid` in the instance dir.
   No new directory needed.

4. **What about `c2c instances`?** Should `c2c instances` surface the
   `expected_cwd` alongside PID/time? Proposal: add a column.

5. ~~**Cross-host**~~ Resolved: skip check when `sender_fp ≠ broker_fp`.

6. ~~**Coordinator bypass**~~ Resolved: skip when `C2C_COORDINATOR=1`.

7. **cwd-at-registration**: is `cwd` already stored in registration metadata?
   If not, this is a prerequisite. See § Pre-requisite above.

### Related Hardening Proposals

- **Hardening A** (done): shim-modifying-slice peer-PASS rubric (bash -n + smoke check)
- **Hardening C** (deferred): extend pre-reset shim to refuse `git switch`/`rebase` in main tree

## Implementer Notes

**Split into two slices:**

### Slice 1: cwd-in-registration (prerequisite)
1. Add `cwd: string` field to registration record in `c2c_mcp.ml`
2. Capture `cwd` via `Unix.getcwd ()` in the `register` handler
3. Surface `cwd` in `c2c list --json` output
4. Tests for cwd capture and display

### Slice 2: Hardening B proper (after Slice 1 lands)
1. Add `expected_cwd_path` helper in `c2c_start.ml` alongside existing pid-file helpers
2. Write `expected-cwd` file in `run_outer_loop` before restart loop; re-write on `c2c restart`
3. Add `WORKTREE-MISMATCH` + `WORKTREE-MATCH` log tags in broker send/list/poll handlers
4. Add `expected_cwd` column to `c2c instances` JSON output
5. Add coordinator bypass (`C2C_COORDINATOR=1` env var check) in broker handler
6. Add a test in `test_c2c_start.ml` for the file-write path

## Status

Design draft — refinements incorporated from fern-coder review (broker-side approach confirmed; coordinator bypass added; restart-re-write clarified; cwd-at-registration flagged as prerequisite).
