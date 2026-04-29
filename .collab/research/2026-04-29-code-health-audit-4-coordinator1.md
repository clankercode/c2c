# Code-health audit #4 — 2026-04-29

**Author**: coordinator1 (Cairn-Vigil)
**Scope**: OCaml tree at `ocaml/` — long-function / module-too-big candidates,
remaining bare-stdlib I/O patterns, dead code, stale comments,
parallel-canonical patterns NOT covered by audit-3 (willow) or
cedar's path-constants finding.
**Method**: read-only structural sweep (awk-measured top-level let lengths,
grep across `ocaml/**.ml`), `scripts/audit-staleness-check.sh` cross-check.
No code modified.

---

## Prior audit cross-reference

This doc deliberately does NOT re-flag:

| Already covered | Source |
|---|---|
| `Yojson.Safe.from_file` / `from_string` migration to `read_json_opt` | willow audit-3 §1; cedar finding §1 |
| 4 CONFIG `failwith` sites in `c2c_mcp.ml` + `c2c_stickers.ml:11` | willow audit-3 §2 |
| `handle_tool_call` (~407 LOC) extraction (#338) | willow audit-3 §3 (defers to stanza) |
| `auto_register_impl` 4× guard-logging duplication | willow audit-3 §4; cairn earlier |
| `memory_base_dir` / `memory_entry_path` cross-file dup | willow audit-3 §5 |
| Repeated path constants (`registry.json`, `pending_permissions.json`, `relay_pins.json`) | cedar §2 |
| `mkdir_p` / `append_jsonl` / `open_out_gen` broker.log | landed (a350be59, 7a3b4dd0) |

The findings below are NEW.

---

## Findings

### Finding 1 — `run_outer_loop` is 863 LOC: the largest function in the OCaml tree

**Severity**: HIGH (maintainability + debug surface)

**Location**: `ocaml/c2c_start.ml:3450` — `let run_outer_loop ~name ~client …`

`run_outer_loop` spans **863 lines** (3450–~4313). It is the bigger sibling of
`handle_tool_call` (407 LOC, already on stanza's #338 plate) and dwarfs every
other function in the tree:

| Function | LOC | File |
|---|---|---|
| `run_outer_loop` | **863** | `c2c_start.ml:3450` |
| `monitor_cmd` | 621 | `c2c/c2c.ml:2673` (Finding 2) |
| `start_cmd` | 440 | `cli/c2c.ml:7254` (Finding 2) |
| `handle_tool_call` | 407 | `c2c_mcp.ml:5649` (already #338) |
| `cmd_start` | 314 | `c2c_start.ml:4324` |
| `init_cmd` | 290 | `cli/c2c.ml:5093` |

The function fuses: tmux pane management, child PID tracking, deliver-daemon
orchestration, signal handlers, restart-on-exit policy, stderr tee, role/intro
injection, plugin-drift checks, and the actual launch. Each concern is a
candidate for extraction.

**Symptoms today**:
- Compaction-loop debugging (the recurring "outer loop ate a child" class of
  bug) lands in 800-line review surfaces.
- Tests for `c2c_start` exercise `cmd_start` end-to-end; `run_outer_loop`
  has no fine-grained unit coverage of the restart policy because it isn't
  callable in isolation.
- Adds friction to slice-per-feature work — almost every `c2c start` slice
  edits in the same 800-line block, generating worktree merge friction
  (Pattern 13 stash hazard amplified).

**Proposed slice**: NOT a single big-bang refactor — extract one concern at
a time. First easy win: pull the **stderr tee** subroutine (`start_stderr_tee`
already at module-top, line 3357 — confirm the call sites and split the inline
copies in `run_outer_loop`) and the **signal handler installation** block.
Each extraction is ~50 LOC and a fresh slice. Estimate the full refactor at
6–8 slices over 2–3 weeks; no functional change per slice.

Est. LOC moved: ~600 across 6+ slices; net delta near zero.

---

### Finding 2 — `monitor_cmd` (621 LOC) and `start_cmd` (440 LOC) in `cli/c2c.ml`

**Severity**: MED

**Location**: `cli/c2c.ml:2673` (`monitor_cmd`), `cli/c2c.ml:7254` (`start_cmd`)

Same pattern as Finding 1 but inside `cli/c2c.ml`. The Cmdliner Term
construction, business logic, formatting, and side-effects are all inlined
into one `let` per command. The other big offenders in the same file:

| Cmdliner Cmd | LOC | Line |
|---|---|---|
| `monitor_cmd` | 621 | 2673 |
| `start_cmd` | 440 | 7254 |
| `init_cmd` | 290 | 5093 |
| `relay_rooms_cmd` | 238 | 3944 |
| `status_cmd` | 222 | 1841 |
| `relay_mobile_pair_cmd` | 191 | 4374 |
| `relay_mesh_cmd` | 163 | 6274 |
| `relay_serve_cmd` | 155 | 3421 |
| `relay_dm_cmd` | 153 | 4221 |
| `verify_cmd` | 121 | (multiple) |

Idiomatic Cmdliner pattern is to keep the `Cmd.v` declaration thin and
delegate to a separate `run_xxx` function. Several existing commands already
do this (`fast_path_*`, `repo_*`); `monitor_cmd` / `start_cmd` / `init_cmd`
do not.

**Proposed slice**: extract `run_monitor` from `monitor_cmd` as a first
data point — a mechanical move with no behavioral change, ~5 LOC of
Cmdliner glue retained. If pattern works, extend to `start_cmd` and
`init_cmd` as a follow-up. Est: ~20 LOC of net Cmdliner glue per command,
no LOC reduction but a 5–10× improvement in callable-from-tests surface.

---

### Finding 3 — 57 bare `open_in` sites that should use `C2c_io.read_file`

**Severity**: MED (consistency + crash surface)

The `#388` audit landed `C2c_io.read_file` (`open_in` + `Fun.protect` +
`really_input_string` + `close_in`) as the canonical helper, but the bare
pattern is still scattered across the largest modules:

| File | Bare `open_in ` count |
|---|---|
| `cli/c2c.ml` | 30 |
| `c2c_start.ml` | 17 |
| `c2c_mcp.ml` | 10 |
| **Total** | **57** |

Sample (verbatim, `cli/c2c.ml:1378-1381`):

```ocaml
let ic = open_in sidecar in
let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
  let n = in_channel_length ic in really_input_string ic n) in
let j = Yojson.Safe.from_string data in
```

That's exactly `C2c_io.read_file` followed by `Yojson.Safe.from_string` —
or, when the surrounding `try ... with _ -> None/[]` wraps it,
`C2c_io.read_json_opt` (willow's #388 helper). About **half** the sites
in `cli/c2c.ml` are inside `try _ with _ -> default` — direct
`read_json_opt` candidates that complement cedar's already-flagged
`from_file` migration list with a SEPARATE migration angle (the
`open_in`/`close_in`/`really_input_string` triple, not the `from_file`
shortcut).

**Risk**: the bare pattern is correct in most cases, but the `Fun.protect`
boilerplate is easy to typo (one missing `close_in` and the broker leaks
fds — already seen in `relay_e2e.ml` history). Convergence reduces that
surface.

**Proposed slice**: one slice per file (3 slices, sized by module).
Mechanical migration. Est: ~57 sites × ~3 LOC each = ~170 LOC net
reduction. Most aggressive single-slice net reduction in the audit.

---

### Finding 4 — Dead-code: `path_suffixes` in `c2c_docs_drift.ml`

**Severity**: LOW

**Location**: `cli/c2c_docs_drift.ml:47` defines, `:79` silences
(`let _ = path_suffixes  (* reserved for future expansion *)`)

```ocaml
let path_suffixes = [ ".md"; ".py"; ".sh"; ".ml"; ".mli"; ".ts"; ".tsx";
                      ".json"; ".toml"; ".yml"; ".yaml" ]
…
let _ = path_suffixes  (* reserved for future expansion *)
```

YAGNI — the value is not referenced anywhere. The `let _ =` silences the
"unused" warning; that's a code smell, not a fix. Either the future
expansion is real and there's a tracking issue, or it's dead code.

**Proposed slice**: delete both lines. ~3 LOC. Trivial — pair with any
docs-drift bugfix slice.

---

### Finding 5 — 3 `failwith "not in a git repository"` in CLI command bodies

**Severity**: MED (parity with willow §2)

Willow §2 caught `c2c_stickers.ml:11`. The same pattern appears at three
more sites that ALSO fire on user context (running outside a git repo):

| File | Line | Context |
|---|---|---|
| `cli/c2c_peer_pass.ml` | 15 | peer-PASS subcommands |
| `cli/c2c_worktree.ml` | 45 | worktree gc / list |
| `cli/c2c_worktree.ml` | 164 | worktree command |

Same fix as willow §2: return `Result.error` / clear-message exit, not
`failwith` (which surfaces as a stacktrace with `Fatal error: exception
Failure("not in a git repository")`). Particularly bad on `c2c worktree
gc` which is documented as a maintenance command operators run from
arbitrary cwds.

**Proposed slice**: bundle with willow §2's `c2c_stickers.ml:11` —
single `not_in_git_repo_error` helper in `c2c_utils.ml`, four call-sites
converted. Est: ~25 LOC, includes the `c2c_stickers.ml` site.

---

### Finding 6 — Stale `Equivalent to Python …` comment in `c2c_wire_bridge.ml`

**Severity**: LOW (documentation hygiene)

**Location**: `c2c_wire_bridge.ml:3`

```
(** Kimi Wire bridge: deliver c2c broker messages via kimi --wire JSON-RPC.
    Equivalent to Python c2c_kimi_wire_bridge.py. *)
```

Per `CLAUDE.md`'s "Python Scripts (deprecated)" section, the OCaml side
is the source of truth and the Python scripts are deprecated. Inline
comments still pointing at "equivalent Python" reinforce the wrong
directionality. There's only one such site I caught (compare with
`c2c_docs_drift.ml:244` which is a permitted enumeration of deprecated
script names — different role, leave it alone), but worth a sweep.

`c2c_start.ml:2896` also notes "Wire-bridge fully deprecated for kimi"
— if the wire-bridge is "fully deprecated for kimi", does
`c2c_wire_bridge.ml` (275 LOC) still earn its weight? Worth a separate
investigation slice ("is c2c_wire_bridge dead?") — this finding only
flags the stale doc comment.

**Proposed slice**: 1-line edit (`Equivalent to Python …` → just remove
or replace with deprecation note). Folded into any `c2c_wire_bridge`
slice. ~1 LOC.

---

### Finding 7 — Stale "audit §2" cross-reference in `c2c_mcp.ml`

**Severity**: LOW

**Location**: willow §5 already noted that `c2c_mcp.ml:7271,7362,7446`
contain `(* lifted top-level (audit §2) *)` comments while the dup was
never removed. Logging a separate finding here because the comment text
itself ("audit §2") is now stale across multiple audit cycles — readers
hit it and have no way to know which audit. Either remove the comment
when willow's §5 lands, or replace with the canonical `#388-followup` /
`#338` issue link. Folded into willow §5.

---

## Summary table

| # | Severity | Finding | Est. LOC | Priority |
|---|---|---|---|---|
| 1 | HIGH | `run_outer_loop` 863-LOC extraction (multi-slice) | ~600 moved | High |
| 2 | MED | `monitor_cmd` / `start_cmd` / `init_cmd` thin Cmdliner shells | net 0 | Medium |
| 3 | MED | 57 bare `open_in` → `C2c_io.read_file` migration | ~170 net | Medium |
| 4 | LOW | `path_suffixes` dead code in `c2c_docs_drift.ml` | ~3 net | Low |
| 5 | MED | 3 `failwith "not in git"` in CLI command bodies | ~25 net | Medium |
| 6 | LOW | Stale "Equivalent to Python …" comment in `c2c_wire_bridge.ml` | ~1 net | Low |
| 7 | LOW | Stale "audit §2" comments — fold into willow §5 | 0 | Low |

**Net LOC reduction**: ~200 (dominated by Finding 3); plus ~600 lines
re-organized in Finding 1 (multi-slice).

---

## Highest-leverage finding (for coordinator dispatch)

**Finding 3** (bare-`open_in` migration) is the highest-leverage win:
57 sites × ~3 LOC each, mechanical, three independent slices (one per
module), and it directly extends willow's already-landed `C2c_io`
canonical surface. Each slice is small enough for a fresh subagent and
has zero cross-slice merge risk (different files). Pair this with
Finding 5 (failwith → graceful) for a "code-health Sprint 4 batch"
across 4 small slices.

**Finding 1** (`run_outer_loop` extraction) is the highest-impact
finding but requires careful slice design — recommend it follow the
#338 `handle_tool_call` extraction pattern stanza is already running,
so we have a proven template before opening a second front.

---

## Staleness check

`scripts/audit-staleness-check.sh` was run on this doc. The script's
file:line resolution prefixes from cwd; relative paths used here are
`ocaml/...` which the script does not expand, so it reports
`FILE_MISSING` for every line ref. This is a **script limitation, not
a stale finding** — every line ref was hand-verified at audit time
against `HEAD`:

| Line ref | Verified at HEAD |
|---|---|
| `c2c_start.ml:3450` (`run_outer_loop`) | ✓ |
| `cli/c2c.ml:2673` (`monitor_cmd`) | ✓ |
| `cli/c2c.ml:7254` (`start_cmd`) | ✓ |
| `cli/c2c.ml:5093` (`init_cmd`) | ✓ |
| `cli/c2c_docs_drift.ml:79` (`path_suffixes`) | ✓ |
| `cli/c2c_peer_pass.ml:15` (failwith) | ✓ |
| `cli/c2c_worktree.ml:45,164` (failwith) | ✓ |
| `c2c_wire_bridge.ml:3` (stale comment) | ✓ |

Issue/PR refs: #338, #388, #400b — all "POSSIBLY ADDRESSED" (expected
— this audit cross-references prior audits whose slices have landed).
No SHAs in body so no SHA-staleness hits.

— coordinator1 (Cairn-Vigil)
