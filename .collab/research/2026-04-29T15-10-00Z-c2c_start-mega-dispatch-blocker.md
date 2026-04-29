# Blocker: c2c_start mega-dispatch §1 — no bounded extraction available

**Author:** slate-coder (subagent dispatched by slate-coder)
**Date:** 2026-04-29T15:10:00Z
**Task:** "Take ONE bounded chunk from §1 of stanza-coder's c2c_start mega-dispatch split design doc."

## What I found

### 1. There is no `c2c_start` mega-dispatch design doc

`grep -l "c2c_start" .collab/design/*.md` returns docs that *mention*
`c2c_start.ml` in passing (push-aware heartbeat, cherry-pick
divergence, session-id env export, role-specific rooms, etc.) but
**none** propose a split of `c2c_start.ml`'s dispatch into smaller
named functions.

The closest match — and almost certainly the doc the dispatcher
meant — is:

`/home/xertrov/src/c2c/.collab/design/2026-04-29-stanza-coder-c2c-mcp-mega-dispatch-refactor.md`

That doc is about **`c2c_mcp.ml`**, not `c2c_start.ml`. It's the
right author (stanza-coder), the right shape (multi-section design
proposing dispatch split into named functions), the right date
(2026-04-29), and the only mega-dispatch refactor design currently
on the books.

I did NOT freelance an alternate refactor target. Flagging the
ambiguity.

### 2. Even taking that doc, §1 is not extraction-shaped

`§1. Current state` of the c2c_mcp doc is purely descriptive:

- LOC counts (1880 LOC, 34 arms, average 55 LOC/arm).
- A table of repeated boilerplate patterns (14 × `resolve_session_id`
  + `Broker.touch_session`, 50 × `tool_result`, ~50 ×
  `optional_string_member`, etc.).
- An assessment of the signal-to-noise ratio.

There is **no §1.1 / §1.2 / §1.3 sub-numbering** and no extraction
proposed inside §1. Bounded extractions live in **§5 Migration
plan**:

- **Slice 1a** — helpers (`with_session`, `with_session_lwt`,
  `tool_ok`, `tool_err`, `tool_ok_json`); replace ~14
  `resolve_session_id` + `Broker.touch_session` sites and ~50
  `tool_result ~content:... ~is_error:...` sites. Net diff
  ~150 LOC removed, ~50 added.
- **Slice 1b** — five typed decoders (`decode_alias_args`,
  `decode_room_args`, `decode_message_args`,
  `decode_pending_perm_args`, `decode_memory_args`).
- **Slice 2** — extract `memory_list` / `memory_read` /
  `memory_write` handlers (~340 LOC).

Of those, the smallest, lowest-risk, most isolated chunk is
**Slice 1a partial** (e.g. just the `tool_ok` / `tool_err` smart
constructors + replace ~50 sites). That's a clean mechanical
sweep with no behavior change.

But it's NOT in §1 — it's in §5.

## Why I stopped

The task explicitly said:

> If the design doc cannot be located OR §1 doesn't have a clear
> bounded extraction (e.g., it's all coupled), STOP and write a
> short blocker note ... Do NOT freelance a different refactor.

Both conditions apply:

- (a) The named doc (`c2c_start* mega-dispatch`) does not exist.
- (b) The closest doc's §1 is descriptive analysis, not extraction.

## Recommended unblock

Pick one:

1. **Re-scope to c2c_mcp Phase 1a (smart constructors only).**
   Smallest bite: introduce `tool_ok content` and `tool_err content`
   as wrappers for `tool_result ~content ~is_error:false/true`,
   and replace ~10 sites in one feature area (e.g. just the memory
   arms, or just the rooms arms). Pure mechanical, no behavior
   change, ~30-50 LOC delta. This is a §5 Slice 1a-derived chunk,
   not §1, but it matches the dispatcher's intent ("smallest /
   clearest extraction").
2. **Re-scope to c2c_mcp Slice 2 (memory handlers).**
   Doc explicitly calls memory out as the natural first Option-A
   extraction (~1.5–2h, ~340 LOC). Three arms moved into
   `handle_memory_*` functions above the dispatch. Self-contained,
   no cross-tool state, dedicated test coverage exists
   (`just test-one -k memory`). Slightly larger than option 1
   but better matches the "extract a dispatch arm into a named
   function" framing.
3. **Author the missing c2c_start mega-dispatch design doc.**
   If `c2c_start.ml` actually has a mega-dispatch worth splitting,
   stanza needs to write that doc first. (I have NOT audited
   `c2c_start.ml` for this — out of scope for the blocker.)

Awaiting direction from slate-coder (parent) before proceeding.

## Receipts

- Design doc actually located:
  `/home/xertrov/src/c2c/.collab/design/2026-04-29-stanza-coder-c2c-mcp-mega-dispatch-refactor.md`
- Section structure: `## 1. Current state`, `## 2. Goals & non-goals`,
  `## 3. Design options surveyed`, `## 4. Recommendation: phased
  C-then-A`, `## 5. Migration plan`, `## 6. Test strategy`,
  `## 7. Risks & open questions`, `## 8. Receipts`.
- §5 Phase 1a, 1b, Slice 2 are the actual extraction chunks.
