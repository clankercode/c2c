# Spec Drift Audit — 2026-04-28T12:32 UTC

**Auditor:** coordinator1
**Scope:** `.collab/specs/` (1 file) + `.collab/design/SPEC-*.md` (9 files)
**Goal:** Classify each SPEC vs current master (HEAD `a44db752`), recommend top updates.

## Inventory

| # | Path | Stated Status | Reality | Class |
|---|------|---------------|---------|-------|
| 1 | `specs/2026-04-21-alias-naming-standardization.md` | draft — awaiting coordinator1 review | Phase 1 + #378 + prime disambiguator shipped | YELLOW |
| 2 | `design/SPEC-signed-peer-pass.md` | implemented | Up to date through S1/H1/H2/H2b/M1 + #56 + #57 | GREEN |
| 3 | `design/SPEC-agent-stats-command.md` | implemented (5 SHAs) | `c2c stats` shipped; spec describes intent | HISTORICAL |
| 4 | `design/SPEC-delivery-latency.md` | implemented (8171bc6) | Watcher 2.0s + poker 180s in code | GREEN (minor) |
| 5 | `design/SPEC-dup-scanner.md` | implemented | `scripts/c2c-dup-scanner.py` exists | HISTORICAL |
| 6 | `design/SPEC-ephemeral-agents.md` | APPROVED 2026-04-24 | `c2c agent run` shipped; same as #7 | HISTORICAL (dup) |
| 7 | `design/SPEC-ephemeral-one-shot-agents.md` | SHIPPED | `c2c agent run/refine` + `stop_self` live | HISTORICAL |
| 8 | `design/SPEC-generic-pty-tmux-clients.md` | implemented (4 SHAs) | `c2c start pty/tmux` shipped | HISTORICAL |
| 9 | `design/SPEC-sender-role-attribute.md` | implemented; "Blocked on c2c_mcp.ml" | `role` field landed; #107 commits in tree | YELLOW (contradicts itself) |
| 10 | `design/SPEC-send-memory-handoff.md` | MCP-only shipped, CLI deferred | `send_memory_handoff` event in c2c_mcp.ml; CLI `memory send` not present | GREEN |

## Detailed Findings

### #1 alias-naming-standardization.md — YELLOW
Spec is dated 2026-04-21 marked "draft — awaiting coordinator1 review". Reality:
- `compute_canonical_alias`, `canonical_alias` field on registration: **shipped** (`c2c_mcp.ml:1253`, `mli:125`).
- Prime disambiguator `suggest_alias_prime` with `small_primes = [|2;3;5;7;...;47|]`: **shipped** (`c2c_mcp.ml:1259, 1389`) — matches spec section 3 sketch verbatim.
- `#378` (commit `c4983bd5`, today): case-insensitive alias-pool collision + same-word-doubled rejection. Spec does NOT mention case-folding invariants — should append a §1.x note.
- `whoami` / `list` carry `canonical_alias` (`c2c_mcp.ml:425, 4754`): matches spec §5 Phase 1 plan.

**Recommended update**: flip status to "Phase 1 implemented (SHA …)", append a "Case-insensitivity (#378)" subsection.

### #2 SPEC-signed-peer-pass.md — GREEN
Already enumerates today's SHAs in the Status block: `2a6ad11a` (H1), `d2c8ec38` (H2), `0c57b839` (H2b), `2af9def4` (M1), `ef09077c` (S1), plus #56 size-cap and #57 path-traversal sections. Verbatim reject-string at line 32 cross-references `c2c_mcp.ml:4471-4473`. No drift detected.

### #3 SPEC-agent-stats-command.md — HISTORICAL
Status says "implemented" with SHAs `0012aff, 79eb696, 9ae19d1, 22790c0, c614860, ec479e6`. Body still phrases everything as "Proposed CLI surface" / "Open questions". Should move to `specs-archive/` or get a "shipped-as" preamble noting which fields actually surfaced (no token cost was completable per-client, etc.).

### #4 SPEC-delivery-latency.md — GREEN
Defaults match: `inbox_watcher_delay_seconds` consumed from env (`c2c_mcp_server_inner.ml:95`), poker `interval = 180.0` (`c2c_poker.ml:14`). CLAUDE.md notes default went 5s→2s. Spec cites SHA 8171bc6 in header. Minor: §3 (room fan-out async) is still "deferred" — accurate.

### #5 SPEC-dup-scanner.md — HISTORICAL
File exists, both SHAs listed. Move to specs-archive.

### #6/#7 SPEC-ephemeral-agents.md / SPEC-ephemeral-one-shot-agents.md — HISTORICAL + duplicate
These are two specs for the same feature. #7 (one-shot) is the older "resolved design" doc; #6 is the implementation companion. Both are SHIPPED. **Recommend: archive #7, keep #6 with a "consolidated from one-shot SPEC" note OR merge into one canonical historical file**.

### #8 SPEC-generic-pty-tmux-clients.md — HISTORICAL
All slices shipped (`c2c start pty`, `c2c start tmux`, `c2c get-tmux-location`, `--` passthrough). Move to archive.

### #9 SPEC-sender-role-attribute.md — YELLOW (self-contradictory)
Header says "Status: implemented" + "Shipped: wishlist item 150" but body §6 still says "BLOCKED on c2c_mcp.ml — Max is actively editing". Reality: `role : string option` is on the `registration` record (`c2c_mcp.mli:61`), `register` accepts `?role`, `channel_notification` propagates it, hook honors it (`c2c_inbox_hook.ml:250`), commits `8882792a` + `cbcbf469` landed. Body needs a rewrite (delete §6 "Status: Blocked" and the "Files to change" tense).

### #10 SPEC-send-memory-handoff.md — GREEN
Already annotated 2026-04-28 with the "MCP-only shipped, CLI deferred" preamble. `send_memory_handoff` event logged at `c2c_mcp.ml:3180`. Accurate.

## Specs mentioning "future work" / "TBD" — verified

- SPEC-signed-peer-pass `ts` 30-day expiry: still `NOT YET IMPLEMENTED` — accurate.
- SPEC-delivery-latency room-fan-out async: still deferred — accurate.
- SPEC-send-memory-handoff CLI subcommand: still deferred — accurate.
- alias-naming Phase 2 federation: still pending — accurate.

## Top 5 Recommended Updates (highest yield first)

1. **SPEC-sender-role-attribute.md** — body contradicts header. Strip the "BLOCKED on c2c_mcp.ml" / future-tense section; cite shipped SHAs (`8882792a`, `cbcbf469`, `201a2076`) inline. ~5min, removes confusion for newcomers reading "blocked" on an actually-shipped feature.
2. **alias-naming-standardization.md** — flip from "draft" to "Phase 1 implemented", append #378 case-insensitivity invariant. Ties spec to the ~2 weeks of churn (`c4983bd5` and prior). Matters because it's the only file in `.collab/specs/` and gets visibility.
3. **Consolidate SPEC-ephemeral-agents.md + SPEC-ephemeral-one-shot-agents.md** — same feature, two files. Archive the older "one-shot" version, leave a pointer.
4. **Bulk move HISTORICAL specs to `.collab/specs-archive/`** — agent-stats, dup-scanner, generic-pty-tmux, ephemeral-*. Reduces noise in `.collab/design/` for active-design discoverability. Five files.
5. **SPEC-signed-peer-pass.md (small)** — already excellent; only nit is adding a bullet at line 5 for `e6781f51` / `c4983bd5` if any peer-pass-adjacent changes (none today, so probably skip). Top-of-file "Shipped" list could optionally add a "see also: #56, #57" TOC link.

## Counts

- 10 specs audited
- 1 GREEN (peer-pass), 1 GREEN-minor (latency), 1 GREEN (send-memory) = 3 GREEN
- 2 YELLOW (alias-naming, sender-role)
- 5 HISTORICAL (agent-stats, dup-scanner, ephemeral×2, pty-tmux)
- 0 RED
