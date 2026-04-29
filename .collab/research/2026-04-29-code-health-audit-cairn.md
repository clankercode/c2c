---
agent: cairn-coder (subagent of coordinator1)
ts: 2026-04-29
task: "#388 recurring code-health audit"
scope: ocaml/ tree (excluding _build/, .worktrees/, deprecated/)
---

# c2c OCaml code-health audit — 2026-04-29

Survey only — no fixes applied. Items ordered roughly by ROI (impact/slice-size).

Top finding (one-liner): **128-word `alias_words` array is duplicated verbatim in `ocaml/c2c_start.ml:1791` and `ocaml/cli/c2c_setup.ml:168`** — CLAUDE.md flags it explicitly and a 1455-word file under `data/` already exists but is unused. Trivial dedup, surprise pothole if anyone edits one and not the other.

---

## 1. `alias_words` array duplicated verbatim — HIGH / XS

- **Refs**: `ocaml/c2c_start.ml:1791`, `ocaml/cli/c2c_setup.ml:168`
- **Problem**: The 128-element pool is copy-pasted into both files. CLAUDE.md
  even documents this drift hazard ("hardcoded in `c2c_start.ml` and
  `c2c_setup.ml`; the 1,455-word `data/c2c_alias_words.txt` is unused").
  Any edit to one and not the other silently changes alias-collision
  behavior between paths.
- **Fix**: Move to a tiny shared module (e.g. `ocaml/c2c_alias_pool.ml`)
  exposing `words : string array` and `random_pair : unit -> string`.
  Both call sites import. Optionally migrate to `data/c2c_alias_words.txt`
  + `dune` `embed_file`, but minimum slice is just dedup the literal.
- **Severity**: HIGH (correctness drift, called out in CLAUDE.md).
- **Slice**: XS.

## 2. `mkdir_p` defined ~10 times across the tree — MED / S

- **Refs**: `ocaml/c2c_io.ml:23` (canonical), `ocaml/c2c_mcp.ml:89`
  (separate impl despite #396 dedup note above it!), `ocaml/c2c_mcp.ml:298`
  (alias to canonical), `ocaml/cli/c2c_migrate.ml:121`,
  `ocaml/cli/c2c_setup.ml:215`, plus three inline `let rec mkdir_p` in
  `c2c_setup.ml` at lines 808, 823, 994, plus `ocaml/peer_review.ml:519`,
  `ocaml/cli/c2c_relay_managed.ml:32`. Tools and tests pile on more.
- **Problem**: `c2c_mcp.ml` line 89 defines `let rec mkdir_p d = ...` then
  line 298 defines another `mkdir_p` aliasing `C2c_io.mkdir_p` — both
  are referenced inside the same file. Issue #396 ("dedup mkdir_p") ostensibly
  closed this but only fixed one call site. `c2c_setup.ml` has THREE separate
  inline copies inside `setup_claude` for dry-run-aware variants.
- **Fix**: Make `C2c_io.mkdir_p` (and a `C2c_io.mkdir_p_dryrun ~dry_run`
  variant) the single canonical helpers. Delete the line-89 copy in
  `c2c_mcp.ml` and inline `let rec mkdir_p` triplet in `c2c_setup.ml`.
  Search and replace remaining shadowing copies.
- **Severity**: MED (pothole — #396 already paid this debt once and it
  reaccrued).
- **Slice**: S.

## 3. `c2c_mcp.ml` `Broker` module is 2823 lines — MED / M

- **Ref**: `ocaml/c2c_mcp.ml:409` (`module Broker = struct`) through
  `:3232` (`end`). Total file is 6245 lines.
- **Problem**: The `Broker` module bundles registration, inbox, room
  membership, room messages, peer-pass logging, sweep, x25519/identity
  side, MCP-tool dispatch glue, and persistence. Mixed concerns make it
  hard to test in isolation; cold-boot context after compaction has to
  page in the whole giant.
- **Fix**: Split into sibling modules with thin re-exports for backwards
  compat: `Broker_registry` (alias rows + sweep + liveness),
  `Broker_inbox` (per-alias queue + push/drain),
  `Broker_rooms` (membership + room state),
  `Broker_audit` (peer-pass / handoff log helpers around lines 3254–3350).
  Keep `Broker` as a façade module with `include` + small glue.
- **Severity**: MED (organisational, not correctness).
- **Slice**: M (worth doing in 2-3 small slices, not one big-bang).

## 4. `cli/c2c.ml` is 9197 lines with multiple long handler bodies — MED / M

- **Refs**: `ocaml/cli/c2c.ml` — `monitor_cmd` (~561 lines starting near
  line 2659), `start_cmd` (~440 lines from 6435), `init_cmd` (266 lines
  from 4886), `relay_rooms_cmd` (234 lines from 3790), `status_cmd`
  (221 lines from 1829).
- **Problem**: One file holds Cmdliner term construction, business
  logic, JSON shapes, and side effects. Touch a flag, recompile the
  world. The Cmdliner term builders for the long subcommands inline
  the implementation rather than calling out to a sibling module.
- **Fix**: Per heavy subcommand, move the action body to a sibling
  module (`c2c_monitor.ml`, `c2c_status.ml`, etc. — pattern already
  used by `c2c_stats.ml`, `c2c_rooms.ml`, `c2c_history.ml`). Keep the
  Cmdliner `Term.t` in `c2c.ml`, action in the sibling. Start with one
  command (e.g. `monitor_cmd`) as a proof slice.
- **Severity**: MED (compile time + cold-boot context).
- **Slice**: M (one command per slice, S each).

## 5. `c2c_start.ml run_outer_loop` is 850 lines — MED / S

- **Ref**: `ocaml/c2c_start.ml:3272` `let run_outer_loop ~name ~client ...`.
- **Problem**: One function handles env setup, capability probing,
  argv assembly, fork/exec, stderr tee start, signal handling, exit
  classification, and cleanup. This is the function findings repeatedly
  cite (TTY/pgroup bugs, alias-drift, child-pid clobber). Hard to unit
  test; harder to reason about when something breaks.
- **Fix**: Extract pure helpers — `classify_exit`, `compose_argv`,
  `arm_signal_handlers`, `fork_and_exec` — into `c2c_start.ml` private
  defs above the loop, leaving `run_outer_loop` as orchestration.
  Sequence: pull each helper out, prove a unit test, then thin the loop.
- **Severity**: MED (recurring incident hot-spot per `.collab/findings/`).
- **Slice**: S (per helper extraction).

## 6. `cli/c2c_setup.ml` per-client setup_* funcs share copy-pasted scaffolding — MED / S

- **Refs**: `ocaml/cli/c2c_setup.ml` — `setup_claude` (199 lines, 763),
  `setup_opencode` (166, 468), `setup_codex` (78, 268), `setup_kimi`
  (57, 347), `setup_gemini` (62, 405), `setup_crush` (57, 963).
- **Problem**: Each function does the same shape: resolve client dir,
  read existing config (if any) → merge `c2c` MCP entry → write back
  with dry-run gate, optionally write hook. The merge + dry-run write
  pattern (`json_write_file_or_dryrun`) is consistent but the
  surrounding code-walks are duplicated, including three inline
  `let rec mkdir_p` (see #2). Slate's findings under
  `2026-04-28T10-23-15Z-slate-coder-c2c-install-consistency-audit.md`
  flagged inconsistent install behavior across clients.
- **Fix**: Introduce a `Client_setup` record (paths + merge fn +
  optional hook fn) and a single driver. Per-client entries become
  data, not control flow. Knock-on: kills the inline `mkdir_p`
  triplets and tightens consistency for #406 (gemini), #405 (crush).
- **Severity**: MED.
- **Slice**: S–M depending on appetite (start by extracting one
  shared scaffolding helper).

## 7. Ad-hoc `Unix.gmtime` ISO-8601 formatting scattered ~20 sites — LOW / XS

- **Refs**: `ocaml/Banner.ml:34`, `ocaml/relay_signed_ops.ml:13`,
  `ocaml/c2c_mcp.ml:371`, `ocaml/c2c_mcp.ml:814`,
  `ocaml/cli/c2c_sitrep.ml:29`, `ocaml/cli/c2c_stats.ml:253,273,279,525,537`,
  `ocaml/relay_enc.ml:39`, `ocaml/cli/c2c_rooms.ml:150,336,504,512`,
  `ocaml/cli/c2c_stickers.ml:84`, `ocaml/cli/c2c_coord.ml:30`,
  `ocaml/cli/c2c.ml:67,616`. There IS a `c2c_post_compact_hook.iso8601_now`
  but only one site uses it.
- **Problem**: Each site rolls its own `Printf.sprintf` against
  `tm_year + 1900`, `tm_mon + 1`, etc. Easy to drift on
  trailing-`Z` vs `+00:00`, or on the `_` vs `T` separator. Recent
  PRs (e.g. `ts=HH:MM` work in #417) needed cross-site touchups.
- **Fix**: Promote `iso8601_of_time` / `iso8601_now` (and a
  `format_short ~ts ~kind` companion) into `C2c_io` or a new
  `C2c_time` module. Mechanical rewrite of the ~20 sites. Add a
  trivial `tests/test_c2c_time.ml`.
- **Severity**: LOW (cosmetic/correctness on edge cases).
- **Slice**: XS.

## 8. `read_file` / `write_file` defined ad-hoc in ≥5 modules — LOW / XS

- **Refs**: `ocaml/cli/c2c_memory.ml:70`,`:79`;
  `ocaml/cli/c2c.ml:3535`, `:7594`; `ocaml/c2c_mcp.ml:5802`;
  `ocaml/cli/c2c_stats.ml:285`,`:290`. Plus `atomic_write_json` in
  `c2c_utils.ml:36` (canonical) but `c2c_setup.ml` rolls its own
  `json_write_file` (line 195) and `c2c_stickers.ml:162` rolls
  `atomic_write_file` (raw bytes variant).
- **Problem**: Five separate `read_file` definitions, each marginally
  different (some trim, some don't, some swallow exceptions). Subtle
  behaviour drift. Lock semantics (`fcntl.flock`) only present in some.
- **Fix**: Add to `C2c_io` or `C2c_utils`: `read_file`, `read_file_trimmed`,
  `write_file_atomic`, `write_file_atomic_locked`. Migrate call
  sites; drop the per-module copies.
- **Severity**: LOW.
- **Slice**: XS.

## 9. `c2c_agent.ml` ships TODO placeholders into generated agent role files — LOW / XS

- **Refs**: `ocaml/cli/c2c_agent.ml:252` ("TODO: describe this agent's
  purpose"), `:292`–`:293` ("TODO: list primary responsibilities" /
  "TODO: add more as needed").
- **Problem**: These strings are emitted into the on-disk role markdown
  for new agents and stick around forever (greppable forever in
  `.c2c/`). The TODO is for the operator, not the code, but mixing
  user-facing prompt copy with literal "TODO:" is noisy and
  occasionally trips skill prompts that scan for unfinished work.
- **Fix**: Replace with empty bullets or italicised
  `_(describe this agent…)_` placeholder text. Keep the slot but
  drop the literal `TODO:` token so transcript scanners don't false-
  positive.
- **Severity**: LOW.
- **Slice**: XS.

## 10. `c2c_mcp.ml` has both `string_member` (3666) and `string_member_any` (3693), `c2c_start.ml` has its own `string_member` (2858) — LOW / XS

- **Refs**: `ocaml/c2c_mcp.ml:3666`, `:3693`; `ocaml/c2c_start.ml:2858`.
- **Problem**: Tiny JSON helpers re-defined per file; `Yojson.Safe.Util`
  is invoked directly ~160+ times across the codebase with assorted
  defensive `try ... with _ -> None` wrappers. Inconsistent behaviour
  on `null` vs missing.
- **Fix**: Extract into `ocaml/json_util.ml` (or fold into
  `c2c_utils.ml`): `string_member`, `string_member_any`,
  `int_member`, `bool_member`, all returning `string option` /
  `int option`. Migrate the two existing dups. New code can land on
  the shared helper without churn.
- **Severity**: LOW.
- **Slice**: XS.

## 11. (bonus) `relay.ml` is 4837 lines, single file mixes server, client, in-memory + sqlite backends — MED / M

- **Refs**: `ocaml/relay.ml` — `module InMemoryRelay` at `:487`,
  `module SqliteRelay` at `:1266`, `module Relay_server(R : RELAY)` at
  `:2376`, `module Relay_client` at `:4447`. `SqliteRelay.create` alone
  is ~973 lines (`:1275`).
- **Problem**: Same problem shape as #3 but for the relay tier.
  Compilation of any tweak to the WS layer requires recompiling sqlite
  DDL/migration code. Recovery findings (the master-reset disaster
  2026-04-29T01-13) involved relay.ml conflict resolution that lost a
  bunch of recent work — smaller files would have made the rebuild path
  faster.
- **Fix**: Split into `relay_inmemory.ml`, `relay_sqlite.ml`,
  `relay_server.ml`, `relay_client.ml` with `relay.ml` becoming a
  thin re-export module. Sequence sqlite first (most isolated).
- **Severity**: MED.
- **Slice**: M.

---

## Patterns recurring in `.collab/findings/`

- **Stale build / cached `_build/`** (#28 today —
  `2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`,
  `2026-04-29T02-30-00Z-test-agent-review-build-cache-stale.md`): suggests
  the "review-and-fix" skill should `dune build --force` or do a
  `_build/` clean before claiming PASS. Out of scope of OCaml-tree
  refactor, but worth flagging the skill update as a tooling slice.
- **Cross-file env-var/string drift** (e.g. `C2C_MCP_AUTO_DRAIN_CHANNEL`,
  `C2C_MCP_BROKER_ROOT`): no central registry. A `c2c_env.ml` listing
  every supported env var with type + default would be a future S slice
  (skipped from this round to keep the list tight; surfacing here for
  a follow-up audit).

## Suggested pickup order for the swarm

1. #1 (alias_words) — XS, HIGH, kills CLAUDE.md drift hazard.
2. #2 (mkdir_p dedup round 2) — S, MED, finishes #396.
3. #7 (iso8601 helper) — XS, mechanical, sets up cleaner diffs.
4. #8 (read_file/write_file) — XS, similar shape.
5. #10 (json_util) — XS, prerequisite for #4 and #6 cleanups.
6. #6 (per-client setup scaffolding) — S, then #4 and #5 in parallel.
7. #3 and #11 (Broker / Relay splits) — M each, last because they
   conflict-magnet during cherry-pick season.
