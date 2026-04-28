# Todo Files Sweep — 2026-04-28T12:26:30Z

Author: coordinator1 (Cairn-Vigil) sweep agent
Files audited: `todo-ideas.txt`, `todo-ongoing.txt`, `todo.txt`

## Summary

| File | Open before | Open after | Moved/closed | Genuinely new |
|------|-------------|------------|--------------|---------------|
| `todo-ideas.txt` | 0 `new` (1 `brainstorming`) | 0 `new` | 0 | 0 |
| `todo-ongoing.txt` | 11 entries | 11 entries | 0 (currency check only) | n/a |
| `todo.txt` | 4 open `[ ]` | 0 open `[ ]` | 4 → `[x]` | 0 |

Net: **4 todo.txt entries closed (all already shipped, just unticked).** No entries promoted to TaskCreate — every open item was already implemented.

## todo-ideas.txt

No entries with `Status: new`. The file currently contains:

1. **Use c2c relay for remote GUI work** — `Status: ingested` (already in todo-ongoing as "Remote relay transport"). Stays.
2. **c2c git proxy extensions — signing + attribution** — `Status: ingested` (#119/#129, design doc landed). Stays.
3. **PoW-gated email proxy at c2c.im** — `Status: brainstorming and planning`. Immediate slice (`git.attribution` + `--author` injection) marked SHIPPED in fcae0442. Future slice (PoW proxy) still in design — design decisions locked 2026-04-28 by Max. Stays under brainstorming.
4. Empty template entry at end (no status). Harmless placeholder.

**Action: none.** No `new` entries to triage. No file edits needed for this section.

## todo-ongoing.txt — currency audit

All 11 project entries reviewed against `git log --since=2026-04-23`:

| Project | Status claim | Currency | Verdict |
|---------|--------------|----------|---------|
| Agent-file epic | done v1.1 | accurate (no recent commits affecting status) | OK |
| Codex-headless integration | done 2026-04-23 | accurate | OK |
| OCaml port | active, recent #310/#311/#312/#313/#314/#322 | accurate (last referenced SHAs match log) | OK |
| Sitrep discipline | active/mature | accurate (paired-compaction 2026-04-28 case logged) | OK |
| Security: alias-hijack | done v1 | accurate | OK |
| Deprecated script cleanup | done | accurate | OK |
| Terminal E2E framework | active | accurate | OK |
| Remote relay transport | v1 shipped | accurate | OK |
| Post-restart UX hardening | active, #335/#336/#337/#340/#341/#342/#344/#345 | **needs update** — many of these closed since the entry was written: #336 (18e1d695), #335 v2a (8ff19204/fb1605b0), #340a (bcd40c8a), #341 (53ac8494), #342 (7a56b68a), #344 (9189c7b2), #345 (ecc1d162), #337 (106747ab) — most or all of #335/#337/#340/#341/#342/#344/#345 now closed | **>24h drift** |
| Coord workflow + peer-PASS | active, #360 URGENT queued | **needs update** — #360 fix landed 99d7b6cf/c20e0bba, #352 doctor landed bb3808ef/742be21f | **>24h drift** |
| MCP surface reliability | active, #332/#346 in flight | **needs update** — #332 closed (260746e5), #346 closed (4f2913a1) | **>24h drift** |
| Public-docs accuracy | active, #350/#356-#359 queued | **needs update** — #350 + bundle #356-#359 landed (453672f0, 1f82555a) | **>24h drift** |

**4 ongoing-project entries are >24h stale.** All four are "active" projects that have had their pending issues closed. Recommend coord refresh those four "Status:" lines in the next sitrep window. Did not auto-edit because these are project-level summaries that benefit from human-judgment phrasing.

## todo.txt

### Closed in this sweep (verified shipped, ticked `[x]`)

1. **DESIGN ephemeral one-shot agents** — SPEC promoted (3805a697/b9aaa505); primitive #143 landed (10310a7b/42190629/b129fd0d/fe93c4a7).
2. **IDEA task-decomposition planning agent** — `planner1` role #112 landed (c5a4e65b).
3. **IDEA standby reviewer agents** — `review-bot` role #108 landed (9b7a4f7c/ca6e19cf).
4. **c2c xml sender role/perms attribute** — #107 shipped (design 810deeb7, Slice 1 91d0cdd2/0f00901c, Slice 2 c7256997).

After edits: `todo.txt` has zero open `[ ]` items.

### Genuinely new for TaskCreate

**None.** Every open item was already implemented; the backlog had simply not been reaped.

## Stale / superseded

None identified — todo-ideas.txt is clean, todo.txt items all reconciled to shipped commits.

## Recommendations for coord (file, don't auto-execute)

1. Refresh the four stale `todo-ongoing.txt` "Status:" lines at next sitrep:
   - Post-restart UX hardening (most of cluster closed)
   - Coord workflow + peer-PASS (#360 + #352 closed)
   - MCP surface reliability (#332 + #346 closed)
   - Public-docs accuracy (#350 + #356-#359 bundle landed)
2. Consider clearing the empty template stub at the end of `todo-ideas.txt` (line 100) — purely cosmetic.
3. todo.txt now has no open items — fine state, but worth a Max-prompted refresh to surface any new bugs/papercuts.

## Files edited

- `/home/xertrov/src/c2c/todo.txt` — 4 entries flipped `[ ]` → `[x]` with shipped SHA references.
- No edits to `/home/xertrov/src/c2c/todo-ideas.txt` or `/home/xertrov/src/c2c/todo-ongoing.txt` (no `new` entries; ongoing-status edits left for coord judgment).
