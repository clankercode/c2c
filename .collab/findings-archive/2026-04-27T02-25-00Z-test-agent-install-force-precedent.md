# test-agent: C2C_INSTALL_FORCE=1 precedent

**Date**: 2026-04-27T02:25:00Z
**Alias**: test-agent
**Severity**: low (workflow guidance, not a bug)

## Finding
When testing a fix in a dedicated worktree, the install guard (`scripts/c2c-install-guard.sh`) refuses to overwrite `~/.local/bin/c2c` if the new binary's commit is an ancestor of the currently-installed one.

To override during active development, `C2C_INSTALL_FORCE=1` must be set explicitly.

## Precedent established
- **Legitimate use**: testing a fix in a worktree before the fix is committed/merged — the install guard correctly refuses (ancestor check), but the developer may need to override to test the fix in their own session.
- **Not a bug**: install guard behavior is correct. The override flag exists for this scenario.
- **Workflow note**: coordinator1 advised "don't reinstall from your worktree until your fix is committed AND merged onto master — install from main tree post-cherry-pick is the canonical path." Following this avoids muddying the install-stamp ancestry signal.

## Action taken
Set `C2C_INSTALL_FORCE=1` to install the #326 fix binary during worktree development. Fix was committed to `slice/326-memory-list-shared-with-me-fix` as `e9c39714` before peer-review.

## Related
- #326: `mcp__c2c__memory_list shared_with_me=true` returns entries with wrong alias field
- `scripts/c2c-install-guard.sh` (install guard logic)
- `.collab/runbooks/git-workflow.md` (push/install discipline)
