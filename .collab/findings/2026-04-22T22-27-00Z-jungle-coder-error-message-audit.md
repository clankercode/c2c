# findings: error-message-audit

**Date**: 2026-04-22T22-27-00Z
**Alias**: jungle-coder
**Severity**: low (cosmetic/confusing wording)

## Areas Audited

- Stale stashes (git stash context — not c2c error messages)
- Orphan test registrations (sweep output)
- Dry-run output (install, refresh-peer)
- Doctor stale deploy warning

## Findings

### 1. Doctor stale deploy wording: "deployed" vs "local"

The doctor output shows:
```
⚠ stale deploy (deployed: 3a7a983, local: 6a2bc7) (17 commits)
```

"local" here means "local git HEAD is newer than deployed." But "stale deploy" with "deployed: X, local: Y" where local > deployed is self-contradictory — the deployed version is the stale one, not the local. The phrase "stale deploy" means "the relay server is running an older version than what you have locally." The wording is slightly confusing on first read.

**Suggestion**: Change to:
```
⚠ relay behind local (deployed: 3a7a983, local: 6a2bc7, 17 commits behind)
```
or
```
⚠ stale relay (running 3a7a983, local is 6a2bc7 — 17 commits ahead)
```

### 2. c2c start: "orphan instances" vs c2c sweep: "orphan inboxes"

Two different uses of "orphan" in c2c:

- `c2c start`: "stop orphan instances first" → means "instances running outside c2c management (e.g. killed OpenCode processes)"
- `c2c sweep`: "orphan inbox files" → means "inbox JSON files belonging to no registered session"

Both use "orphan" but mean different things. The c2c start usage is less precise — it means "not managed by c2c" rather than the c2c_mcp meaning of "has no registration."

**Suggestion**: Rename `c2c start`'s "orphan instances" to "unmanaged instances" or "orphaned instances" (the latter technically applies since they've lost their c2c parent). Or clarify the message: "stop other instances sharing the same db" would be clearer.

### 3. Refresh-peer error when PID not alive: "refusing to update"

```
error: PID 12345 is not alive. Refusing to update.
```

This is clear. No issue.

### 4. Sweep dryrun output

The sweep dryrun output is clear and actionable:
```
NON-EMPTY content that sweep would delete:
  session-id (alias)  (N msgs)
  -> consider draining these before running sweep.
```

No issues found.

### 5. Install dry-run output

The `[DRY-RUN]` prefix is clear. Format is:
```
[DRY-RUN] would write N bytes to /path/to/file
[DRY-RUN] would create directory /path/to/dir
```

No issues found.

### 6. Refresh-peer dry-run output

```
[dry-run] Would update 'alias': pid None -> 12345
```

Clear. No issues found.

## Status

- Low severity — all error paths are recoverable and mostly clear
- Most actionable fix: doctor stale deploy wording (finding 1) — takes 5 min
- Second actionable: c2c start "orphan" wording (finding 2) — takes 10 min
- Not fixing without coordinator1 approval
