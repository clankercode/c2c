# Handoff — opencode model bake-off + dogfood + feature work (Max present, intermittent)

**Written 2026-06-12 ~04:00 local, before compaction.** Continue autonomously.

## Max's standing directives (CRITICAL — carry forward)
1. **Use ccc opencode subagents (mm3, mm27, glm51, mimo25p) as much as possible.** Use
   **codex** (`ccc @cx-reviewer`/`@cx-coder`) ONLY for final reviews / when a model is stuck.
2. **Every agent runs `review-and-fix` after its work.** Use `ccc --yolo @model` (without
   --yolo, opencode agents DIE on permission walls — that killed mm3's first relay run).
3. **Bake-off**: develop an evidence-based opinion on which of mm3/glm51/mimo25p (and mm27)
   is best/fastest. Cycle tasks between them. Get them to review+fix each other's work; tally
   bugs found + severity. **Don't forget mimo25p.**
4. **Dogfood comprehensively** — incl. relay (DONE: GREEN) + a LOCAL relay running
   (DONE: tmux window `c2c-relay`, http://127.0.0.1:7331).
5. **STOP CONDITION**: do NOT stop the heartbeat Monitor (`bdrcosvel`) until ABSOLUTELY
   EVERYTHING is done (all changes review-and-fix'd to PASS, all tests green, slices merged).
   ONLY THEN print full agent rankings (mm3/mm27/glm51/mimo25p) + save to memory, THEN
   TaskStop bdrcosvel.
6. NO push (local-only work); coordinator gates pushes. Merges to master need
   `C2C_COORDINATOR=1` (pre-reset shim). Use worktrees per slice.

## Tracking doc (authoritative bake-off data)
`.collab/research/2026-06-12-opencode-model-bakeoff.md` — task log, cross-review tally,
fix-candidates, running opinion, STOP CONDITION. KEEP UPDATING IT.

## Running bake-off opinion (as of 04:00)
- **glm51** — strongest: clean P3a impl + 2 thorough dogfoods (13 + 9 issues). Reliable.
- **mm27** — strong dogfooder (found 2 Sev1 silent-loss bugs). Now doing the fix slice.
- **mm3** — strong WITH --yolo (relay GREEN, sha256 exact matches). Only blemish: died w/o yolo.
- **mimo25p** — WEAK on review (T2: no verdict/fixes, fizzled). Getting a FAIR impl sample now
  (my-rooms CLI, T9). Judge after that.

## Live agents (background bash tasks, auto-notify on completion)
- `bap7gpgnd` — **cx-reviewer** peer-review of **P0** (wt-sessid-p0 @ cd558329). Reported
  session-id suite green 8/8; may add fix commits. AWAIT verdict + final SHA.
- `bt85wynx9` — **mm27** fixing **silent-send bug class** in `wt-silent-send-fix` (@776d17e4,
  no commits yet). Prompt: /tmp/prompt-mm27-fix-silent.txt
- `bm41mqgn1` — **mimo25p** implementing **my-rooms CLI** in `wt-myrooms-cli` (@776d17e4, no
  commits yet). Prompt: /tmp/prompt-mimo-myrooms.txt
- `b89tcdvqd` — **mm3** PROPER peer-review of **P3a** (wt-sessions-discovery @ 31a30344;
  mimo's earlier review T2 was incomplete). AWAIT verdict.
- **glm51 — FREE/RESERVED** for the `--from` sender-spoofing fix (security, glm51 found it),
  to dispatch AFTER wt-silent-send-fix merges (same send handlers — avoid parallel edits).

## Worktrees / branches (none merged yet)
- wt-sessid-p0 @ cd558329 [P0] — cx review in progress → then merge.
- wt-sessions-discovery @ 31a30344 [P3a] — needs mm3 peer-PASS → then merge.
- wt-silent-send-fix @ 776d17e4 [fix] — mm27 working.
- wt-myrooms-cli @ 776d17e4 [my-rooms] — mimo working.

## Merge plan (once each PASSes peer review, as C2C_COORDINATOR=1)
P0 → P3a → silent-send-fix → my-rooms. After P0 merges, UNBLOCKS: P1 (Stop hook #10),
#7 (hook test harness), P4 (#11). Dispatch those to opencode models next (cycle; give mimo
another impl if its my-rooms is weak; give the hero P0 end-to-end tmux dogfood to MYSELF).

## Fix candidates surfaced by dogfooding (in tracking doc)
- Sev1 ×2: rooms send after-leave / to-ghost-room silently lost (mm27) — being fixed.
- Sev2: send/ephemeral to unregistered alias silently queues (glm51) — being fixed.
- Sev2 SECURITY: `c2c send --from` unvalidated → sender spoofing (glm51) — glm51 to fix post-merge.
- PoW zero CLI observability (glm51) — enhancement candidate.
- 5 Sev3 relay hygiene items (mm3).

## Findings on disk (4)
glm51-memory-schedule-ephemeral, mm27-rooms, mm3-relay, glm51-sessions-send-pow
(all .collab/findings/2026-06-12-*.md). UNTRACKED in main tree — commit them in a batch
(C2C_COORDINATOR=1) at a checkpoint to keep git status clean.

## Infra
- Local relay: tmux window `c2c-relay`, http://127.0.0.1:7331 (auth dev, pow off, in-memory).
- ccc config FIXED: mm/mm3 provider minimax→minimax-coding-plan (all 4 models now work).
- Heartbeat Monitor `bdrcosvel` (DO NOT STOP until everything done — see directive 5).
