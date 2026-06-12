# Implementation Plan — Feature A: Connect Metadata (opt-out)

**Worktree:** `.worktrees/wt-feat-connect-metadata` · **Branch:** `feat/connect-metadata`
**Base:** `origin/master` @ 8c2f5f51 · **Verdict from investigation:** PRACTICAL (mostly built)
**Source research:** `.collab/research/2026-06-12-three-feature-investigations.md` §A

## Goal
On register, capture lightweight node metadata (repo/folder) by default, with an explicit
opt-out on both surfaces. Decisions locked by Max:
- **Reuse existing fields** — no new redundant `repo` blob. `cwd` (folder) and the repo
  slug in `canonical_alias` already exist; the metadata we "send" is `cwd`.
- **At-rest only** by default — do NOT add `cwd` to `list`/`whoami` peer-facing output in
  this slice (display is a separate opt-in decision; keep it out).
- **Opt-out covers only the metadata capture, NOT the worktree-guard's use of `cwd`.**
  The Hardening-B worktree-mismatch guard (`c2c_broker.ml:1103-1191`) relies on `cwd`;
  the opt-out must not blind that guard. ⇒ Implement the opt-out as "don't *persist/expose*
  metadata," while the guard's transient comparison still works — OR gate a NEW lightweight
  field and keep `cwd` always-captured for the guard. **Chosen approach below.**

## Chosen approach
Because `cwd` is load-bearing for the worktree guard, do NOT make `cwd` itself opt-out-able.
Instead:
1. Keep `cwd` capture exactly as today (always on — guard depends on it).
2. The opt-out (`--no-metadata` / `include_metadata:false`) controls a single boolean
   `metadata_opt_out` stored on the registration that suppresses any *future* metadata
   surfacing/federation (display, relay) — i.e. it's a consent flag, honored at every
   read/exposure site. v1 has no display/federation, so the flag is recorded and honored
   by the (currently empty) exposure set, future-proofing the opt-out without weakening the
   guard.
3. **Fix the real bug:** CLI `c2c register` currently passes `cwd=None`; MCP passes the real
   cwd. Make CLI pass `~cwd:(Sys.getcwd ())` too, so "default-on metadata" is consistent
   across entry points. This is the concrete user-visible win of the slice.

> Rationale: this satisfies "default-on metadata with opt-out" honestly while respecting
> that `cwd` can't simply be dropped. If Max later wants the opt-out to also drop `cwd`
> capture, that's a follow-up that must also adjust the worktree guard — out of scope here.

## Slices
### Slice A1 — CLI cwd parity (the bug fix) + opt-out flag
- `ocaml/cli/c2c.ml:2855` (`register_cmd` term): add a `--no-metadata` boolean Cmdliner flag
  (default false ⇒ metadata on).
- `ocaml/cli/c2c.ml:2901` (the `Broker.register` call): pass `~cwd:(Sys.getcwd ())` unless
  `--no-metadata`; pass `~metadata_opt_out:no_metadata`.
- Confirm the human/JSON register epilog (`c2c.ml:2910-2914`) is unaffected.

### Slice A2 — registration record + persistence
- `ocaml/c2c_broker.ml`: add `metadata_opt_out : bool` to the registration record (default
  false). Thread through `register` (`:1871`), state carry-over (`:1904-1927`).
- `registration_to_json` (`c2c_broker.ml:122`) + `registration_of_json` (`:248`): serialize
  the new bool (omit when false to keep JSON lean; default false on read). VERIFY round-trip
  + forward-compat (old records without the field read as `false`).

### Slice A3 — MCP register surface
- `ocaml/c2c_mcp.ml:30-38` (`register` tool schema): add `bool_prop "include_metadata"`
  (default true semantics enforced in handler).
- `ocaml/c2c_identity_handlers.ml:170-177,285-287` (register handler): read
  `include_metadata` (default true); when false, set `metadata_opt_out=true` and skip cwd
  capture path's *exposure* (but keep cwd for guard — see approach). Return value unchanged.

### Slice A4 — tests + docs
- Extend a registration test (`ocaml/cli/test_c2c_onboarding.ml` or
  `ocaml/test/test_c2c_mcp.ml`): assert (a) CLI register now stores cwd; (b) `--no-metadata`
  sets `metadata_opt_out` and is honored; (c) JSON round-trip of the new field; (d)
  forward-compat (record without field). Gate any external effect behind existing fixture
  env vars.
- Docs: `.collab/runbooks/c2c-env-vars.md` (note the flag), MCP `register` tool description,
  one line in CLAUDE.md "Key Architecture Notes" about the consent flag.

## Acceptance criteria
- `dune build` clean IN THIS WORKTREE (`opam exec -- dune build --root <wt> -j2`, rc=0).
- New tests pass; full test suite green (`-j2`).
- CLI `c2c register --help` shows `--no-metadata`; MCP `register` schema shows
  `include_metadata`.
- CLI register stores cwd (verified by test); `--no-metadata` honored.
- No change to `list`/`whoami` peer output (display deferred).
- Docs updated for any changed surface (docs-up-to-date gate).

## Final step — REVIEW-AND-FIX LOOP (required)
After implementation + green build/tests, run the `review-and-fix` skill on the slice SHA,
looping until PASS (fix real defects in NEW commits, never `--amend`). Then a peer
cross-review by a DIFFERENT ccc model (the implementing model must not self-pass), with the
"build clean" verdict produced INSIDE this worktree (capture
`build-clean-IN-slice-worktree-rc=0`). Do NOT push — features land after connect-docs;
coordinator/Max gate the push.
