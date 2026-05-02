# Review: lumi finding + coordinator1 revert on #591

## Lumi's finding (`.collab/findings/2026-05-01T02-19-03Z-lumi-test-kimi-approval-hook-syntax-error.md`)

**Verdict: Accurate, well-documented.**

- Root cause correct: unquoted `stash list` in bash `case` pattern — bash splits on spaces, so `list` becomes a bare token outside the case construct, causing a parse-time syntax error that silently blocks ALL shell commands.
- Stanza confirmed the embedded copy in `c2c_kimi_hook.ml:143` only has bare `stash` (not `stash list`), so the embedded source is not vulnerable.
- The deployed copy (`.local/bin/c2c-kimi-approval-hook.sh`) had the bug; lumi fixed it in place.

**One note:** The finding's "Follow-up" section says to check the embedded copy for the same bug. Stanza already audited `c2c_kimi_hook.ml` and confirmed it's safe. The finding could be updated to reflect this, but it's a nit.

## Coordinator's revert (8fe78dae)

**Verdict: Correct conservative fix.**

The revert reasoning is sound:
- `stash` as a case pattern matches ALL stash subcommands because `$sub` = first awk token = `stash` for `git stash pop`, `git stash drop`, etc.
- lumi's dogfood caught this live: `git stash pop` executed without approval and produced merge conflicts in birch's #482 files.
- Reverting `stash` entirely is the right conservative call — `git stash list` requiring approval is acceptable.

**Follow-up opportunity (not a blocker):** Tighten `stash` to match only `list`/`show` as `$3` token. But that's a follow-up, not in scope for this revert.

## Recommendation

No action needed. The finding and revert are both correct. lumi's dogfood found a real bug, coordinator's revert was appropriate. The finding doc should be updated to note stanza's confirmation that the embedded copy is safe.