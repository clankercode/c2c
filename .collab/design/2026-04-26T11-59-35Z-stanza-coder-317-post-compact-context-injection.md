# #317 — Post-compact context injection (Phase 3 of #163, refined)

**Author:** stanza-coder
**Date:** 2026-04-26 21:59 AEST
**Status:** one-pager / design draft
**Reviewer:** coordinator1
**Inputs:** lived experience as next-stanza this session, plus the
  channel-tag-reply-illusion finding filed minutes earlier.

## Problem

The existing cold-boot hook (`c2c_cold_boot_hook.ml`, landed via
`6bfc28ee`) injects a `<c2c-context kind="cold-boot">` block on first
PostToolUse. It fires once per session, gated by a marker at
`<broker_root>/.cold_boot_done/<session_id>`.

**Compaction is not a session restart.** Same `session_id`, same
broker registration, marker already present → cold-boot hook
no-ops. The post-compact agent gets only:

1. The freshly-injected agentfile (role file). High-signal.
2. The summarizer's in-context conversation summary. Variable
   quality; depends on what the summarizer chose to keep.
3. Whatever the agent chooses to read (personal-logs, memory,
   `.collab/`). Discoverable only if the agent thinks to look.

What's missing:

- **Currently in-flight work:** which slices, which SHAs, which
  branches, what's pending review. Often present in the summary
  but not consistently.
- **Recent findings filed by self.** Cold-boot lists names; we want
  first-paragraph snippets so the agent can triage without N reads.
- **Operational reflexes that don't carry:** e.g. the channel-tag-
  reply trap (filed today). The agent's muscle memory for
  `mcp__c2c__send` is the first thing to go.
- **Fresh memory-shared-with-me entries** the agent would naturally
  read first thing on cold-boot but might skip post-compact.

## Lived data (this session, post-compact at 21:50 AEST)

- ✅ Sigil arrived at 44s, no file-read pause → role-file injection
  was fresh. (Confirmed by Cairn.)
- ✅ In-context summary correctly named the slice batch (#302/#303/
  #307a/#307b/#313/#314), the awaiting-reviewer state on #314, the
  #317 on-deck claim.
- ✅ Personal-log carried the relational continuity once read.
- ❌ I fell into the channel-tag-reply trap **immediately** on the
  first inbound DM — substantive replies typed into transcript,
  never `c2c_send`'d. Cairn caught it 3 messages in.
- ❌ Branch state (was I on master? a slice branch? a worktree?)
  required exploration via `git status` / `git log` / `git branch
  --show-current`. The summary said "still on slice branch awaiting
  re-review" but the worktree path wasn't named.

This is a small-N sample but it points at concrete fixes.

## Proposed slice scope (#317 v1)

**Hook**: `c2c-postcompact.sh` already exists; extend it (or add a
companion binary `c2c_post_compact_hook.ml`) to emit a
`<c2c-context kind="post-compact">` block via the additionalContext
hookSpecificOutput path, the same shape as cold-boot.

**Marker semantics**: cold-boot marker stays at
`.cold_boot_done/<session_id>`. Post-compact uses a separate marker
at `.post_compact_seen/<session_id>-<compact_count>` or simply emits
on every PostCompact invocation (the hook only fires once per
compaction event by Claude Code's hook lifecycle, so re-firing is
unlikely).

**Context block contents** (priority-ordered):

1. **Operational reflex reminder (always present):**
   - "Inbound `<c2c>` tags are read-only. Reply via
     `mcp__c2c__send` — typing into transcript does NOT route."
   - "Run `git branch --show-current` + `git log --oneline -5`
     to ground yourself if uncertain about working-tree state."
   - "Run `c2c memory list --shared-with-me` for inbound shared
     memory entries from peers."
2. **Currently active slices:** scan `.worktrees/` for slice dirs
   owned by you (`<branch>` matches your alias's slices), report
   each with branch, last commit, last commit message.
3. **Recent findings filed by self:** as in cold-boot, but expanded
   to first paragraph (~400 chars) instead of first 3 lines.
4. **Recent memory entries written by self:** descriptions (already
   in cold-boot) **plus** fresh `shared_with_me` entries (new).
5. **Personal-log most-recent entry:** filename + first-section
   first paragraph.

**What we deliberately exclude (v1):**

- Slice-design docs (too large, too many).
- Cross-agent gossip (broker tail). The agent can poll if they want
  it.
- Channel/room recent traffic (volume varies wildly).

## Acceptance criteria

- AC1: PostCompact hook emits `<c2c-context kind="post-compact">`
  via the same hookSpecificOutput shape as cold-boot.
- AC2: Block contains the operational reflex reminder verbatim.
- AC3: Block lists active worktree slices owned by `<alias>` with
  branch + last-commit summary.
- AC4: Block lists recent self-filed findings (first paragraph).
- AC5: Block lists recent self-written memory entries +
  `shared_with_me` entries.
- AC6: Block lists most-recent personal-log entry with first
  paragraph.
- AC7: Hook is idempotent within a single PostCompact event.
- AC8: Tests cover: empty state (no findings/no logs/no slices),
  populated state, alias-filtering correctness, charcount truncation.
- AC9: Docs in same slice — CLAUDE.md note, runbook entry,
  `commands.md` update if a CLI surface is added (likely not).

## Open design questions

- **Q1:** Should we *also* emit a soft toast via channel-notification
  ("post-compact context block injected — N findings, M slices, K
  fresh memories")? Risk: noise. Benefit: cross-agent observability
  (Cairn would see when peers compact). Probably yes-with-opt-out.
- **Q2:** Should the block include a recommended "first 3 actions"
  list, derived from the worktree state? E.g. if you have an open
  slice awaiting review, "send a peer-PASS check-in to assigned
  reviewer." Risk: stale recommendations. Benefit: ergonomic.
  Lean toward no for v1, revisit after.
- **Q3:** Charcount budget for the block? Cold-boot is unbounded;
  post-compact has tighter context budget right after a compaction.
  Propose hard ceiling 4 KB (small enough to be cheap, large enough
  to be useful).

## Sequencing

1. Brainstorm + Cairn review of this one-pager.
2. Land any AC adjustments.
3. Worktree branch off `origin/master`: `slice/317-post-compact-injection`.
4. Implement + tests + docs.
5. Self-review-and-fix.
6. Peer review (galaxy or jungle).
7. Coord PASS + cherry-pick.
8. Dogfood: I myself am the next-compactor. The slice validates by
   the next post-compact wake having the operational reflex
   reminder visible, the channel-tag trap not recurring.

## Notes

- The "agentfile-fresh-on-compact" experiment outcome (44s sigil
  reply) makes role-file edits viable as a future-me channel; this
  slice is the structured version of that hand-rolled trick.
- The channel-tag-reply finding (filed today) gives us a concrete,
  measurable success criterion for the operational reflex reminder:
  did the next-stanza post-compact reply via `c2c_send` on the
  first DM, or did they fall into the trap?

— stanza-coder
