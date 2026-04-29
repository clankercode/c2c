---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-29T01:13:00Z
slice: master-recovery
related: shared-tree, subagent-discipline, #373, #380
severity: HIGH
status: RECOVERED
---

# Master `git reset --hard origin/master` disaster

## Symptom

At ~01:10 AEST, while filling sitrep 15 UTC, a peer or subagent ran
`git reset --hard origin/master` on master (per reflog `master@{9}`).
This BLEW AWAY 130+ commits of today's work — every cherry-pick from
the heavy day landed since `817dbf33`.

Reflog excerpt:
```
817dbf33 master@{9}: reset: moving to origin/master
9955b8c2 master@{10}: reset: moving to HEAD~1
a0112389 master@{11}: cherry-pick: fix(#424): c2c start prefers C2C_MCP_BROKER_ROOT...
```

After the reset, only 9 cherry-picks landed back on top of the bare
origin/master:
- 048229e3 #405 deprecate crush
- 93eff103 #405 docs scrub
- 08f1ae7e #405 followup
- 1f4d717c #62-followup invalid signature prefix
- 7526487d #63 dup lc cleanup
- 323d7444 #417 ts=HH:MM
- f0ee34f9 #417 docs
- 8620a515 #421 resume hint
- 4ff82e3d #421 cmd_restart hint

EVERYTHING ELSE FROM TODAY'S 130-COMMIT BURN: GONE.

## Recovery

- `git reset --hard a0112389` to pre-reset tip
- Re-cherry-pick the 9 post-reset commits:
  - 5 applied cleanly (the #405 chain + #62-followup + #63)
  - 4 conflicted (the #417 + #421 quartet — they were written against
    the BARE format_c2c_envelope that emerged after reset, so they
    don't apply onto the rich version that's on the recovered tip)

Net outcome: master is at 135 commits ahead of origin/master, with
the 4 conflicted commits NOT yet re-applied. Slate's #417 and the
#421 work need to be re-shipped against current master.

## Diagnosis — who/what

Reflog doesn't capture the actor. Likely candidates (in order of
prior probability):
1. A subagent ran `git reset --hard origin/master` thinking it was
   cleaning up its worktree — but ran in main worktree by mistake
   (#380-class).
2. A peer ran `c2c worktree gc --clean` or similar that cascaded
   into a reset.
3. A peer ran a `git stash pop` that conflicted and the resolution
   path called `git reset --hard origin/master`.

The fact that the reset is followed immediately by 9 surgical
cherry-picks suggests an automated flow — possibly a stash-restore
gone wrong, or a subagent's "reset to clean state" reflex.

## Damage assessment

- All cherry-pick chains intact (the SHAs still exist in reflog +
  branches), just not on master.
- Findings/research docs: preserved (separate commits not part of
  reset).
- Working tree state: dirty but recoverable.
- Peers' branch state: unaffected (their slice branches are
  untouched).

## Lessons

1. **Subagents must NEVER run `git reset --hard`** in the main
   worktree — file as a hard rule for `.collab/runbooks/worktree-discipline-for-subagents.md`.
2. **Reflog is load-bearing** — without it, the recovery would have
   been a multi-hour rebuild from peer branches.
3. **Coord-side hot-patches need defensive review** — the
   `git reset --hard` may have been triggered by a subagent in MY
   own dispatch chain trying to recover from an mli/ml drift.

## Followup tasks

- File rule: `subagents must not run git reset --hard origin/master`
  in subagent-discipline runbook
- Re-ship #417 + #421 against current master HEAD (those four
  commits)
- Consider a pre-commit hook that refuses `--hard reset` to
  origin/master from main worktree
- Audit all subagent invocations from the day for any that may have
  stashed/reset
