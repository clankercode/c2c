# SPEC: c2c doctor --summary (Actionable Operator Output)

## Background

`c2c doctor` currently outputs verbose multi-section diagnostic text: health checks,
managed instances, commit queue, and verdict. This is thorough but noisy — an
operator scanning for "what do I need to do right now" must read the full output.

This spec adds `--summary` mode: a compact, categorized operator action block that
separates FIX NOW / COORDINATOR / ALL CLEAR so the operator can assess situation
in seconds.

## Changes

### File: `scripts/c2c-doctor.sh`

Add `--summary` flag. When passed, output is replaced by a compact 3-part block:

#### Output format

```
=== ACTION REQUIRED ===
[FIX_CHAR] FIX NOW:        <comma-separated items with inline hints>
[COORD_CHAR] COORDINATOR:  <items needing coord decision or remote deploy>
[OK_CHAR] ALL CLEAR:        <brief list of healthy systems>

=== HEALTH: N/N checks passing ===
<failure lines only, one per line, indented 2 spaces>
(empty line if all passing)

=== PUSH: N relay-critical commits queued ===
<relay-critical commit SHAs + subjects, one per line, indented 2 spaces>
(empty line if none queued)
```

Icons: `✗` (red), `⚠` (yellow), `✓` (green), `–` (dim/nothing)

#### Classification rules

**FIX NOW** — items requiring immediate local action:
- Dead registrations present (run `c2c sweep` to list, `c2c sweep --dry-run` to preview)
- Health checks returning non-OK
- `just test` failures
- /tmp < 500MB (risk of disk exhaustion)

**COORDINATOR** — items requiring human coordination:
- Relay stale AND relay-critical commits queued → "push needed"
- Unread swarm-lounge messages (count)
- Stale deploy marker present

**ALL CLEAR** — healthy systems (only shown if non-empty, or "nothing" placeholder):
- Relay current
- All health checks passing
- No dead registrations
- Tests green
- No pending relay-critical commits

#### Hints

FIX NOW items include inline hints in parentheses:
```
✗ FIX NOW: 2 dead registrations (→ run: c2c sweep); /tmp low 423MB (→ free space)
```

#### Health check passthrough

Run `c2c health` once (captured), extract individual check lines. In `--summary`
mode, only non-OK checks are shown. In full mode, show everything.

#### Commit classification

Same logic as existing (RELAY_CRITICAL, RELAY_CONNECTOR, LOCAL_ONLY) but in
`--summary` mode only relay-critical are shown.

### No OCaml changes required

`c2c doctor` is a thin wrapper that `execvp`s `bash scripts/c2c-doctor.sh`.
The `--summary` flag is entirely within the shell script.

## Acceptance criteria

1. `c2c doctor --summary` produces compact 3-section output
2. FIX NOW items have inline remediation hints
3. ALL CLEAR section only shown if non-empty (or "nothing" placeholder)
4. `c2c doctor` (without --summary) continues to produce full verbose output unchanged
5. `--json` flag (existing) continues to work independently of `--summary`
6. Exit code: 0 always (diagnostic only; don't fail on health issues)
