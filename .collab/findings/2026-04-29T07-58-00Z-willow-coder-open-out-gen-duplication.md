# Finding: `open_out_gen` scattered — deduplication opportunity

**Agent**: willow-coder
**Date**: 2026-04-29
**Severity**: MED (code health)
**Status**: peer-PASS cedar, awaiting coord cherry-pick

## Implementation result

Committed in worktree `.worktrees/388-open-out-gen/`:
- SHA `2c90434e`: `refactor(#388): add C2c_io.append_jsonl and migrate 14 call sites`
- Preceded by SHA `36651800`: `wip: add append_jsonl to c2c_io` (helper definition)

Changes:
- `ocaml/c2c_io.ml`: added `append_jsonl` helper
- `ocaml/c2c_mcp.ml`: migrated 12 sites, net -67 LOC
- `ocaml/relay_nudge.ml`: migrated 2 sites, net -12 LOC
- Total net: ~79 LOC reduction

Build: clean (`just check` passes)
Tests: 291 pass (`test_c2c_mcp.exe`)

Sites NOT migrated (out of scope for this slice):
- Open_trunc tmp files (atomic rename pattern) — c2c_mcp×1, c2c_start×1
- Open_text files (TLS, world-readable) — c2c_relay_connector×2
- No-wronly files — relay_identity×2, signers_path×1
- World-readable 0o644 files — c2c_mcp×1, cli/c2c×2, server×1, hook×1 (future follow-up)

## Refined scope

NOT all 24 are migratable. Distinct flag combos with precise counts:

| Pattern | Perm | Count | Files | Migratable? |
|---------|------|-------|-------|-------------|
| `[Open_append; Open_creat; Open_wronly]` | 0o600 | 14 | c2c_mcp×12, relay_nudge×2 | YES — `append_jsonl ~perm:0o600` |
| `[Open_wronly; Open_append; Open_creat]` | 0o600 | 3 | c2c_mcp×3 (archive, dead_letter, room_hist) | SAME set, textually diff order — fold into above |
| `[Open_wronly; Open_creat; Open_trunc; Open_text]` | 0o600 | 2 | c2c_mcp×1, c2c_start×1 | NO — atomic write tmp, different semantics |
| `[Open_wronly; Open_creat; Open_append]` | 0o644 | 5 | c2c_mcp×1, cli/c2c×2, server×1, hook×1 | MAYBE — `append_jsonl ~perm:0o644` |
| `[Open_text; Open_append; Open_creat]` | 0o644 | 2 | c2c_relay_connector×2 | NO — text mode, different semantics |
| `[Open_creat; Open_append]` | 0o600 | 2 | relay_identity×2 | NO — no wronly, different semantics |
| `[Open_append; Open_creat]` | 0o644 | 1 | c2c_mcp×1 (signers) | NO — no wronly |

**Primary migration target**: 14 sites with `[Open_append; Open_creat; Open_wronly] 0o600`
→ add `append_jsonl` helper to `C2c_io`, migrate call sites.
Net LOC reduction: ~6 lines × 14 = ~84 LOC from these 14 alone.

**Secondary**: 5 sites with `[Open_wronly; Open_creat; Open_append] 0o644` — same
helper with `~perm:0o644`.

**Out of scope for this slice**: tmp files (Open_trunc), text-mode files (Open_text),
no-wronly files (relay_identity, signers_path).

## Implementation plan

1. Add `append_jsonl : ?perm:int -> path:string -> line:string -> unit` to `C2c_io`
2. Migrate the 14 `[Open_append; Open_creat; Open_wronly] 0o600` sites
3. (Optional follow-up) `append_jsonl ~perm:0o644` for 5 world-readable sites
