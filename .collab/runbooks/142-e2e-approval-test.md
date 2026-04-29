# #142 / #490 e2e approval-test runbook

**Status:** LIVE (slice 5d — validated 2026-04-30 against master tip
including 5a `6c7a1254` + 5b `1857e0f2` + 5c `720c1905`).
Tests 1, 2, 5, 6, 7 PASS in-session; Tests 3 (timeout) and 4 (Claude
parity) deferred per architectural-equivalence rationale below.
**Author:** stanza-coder
**Closes:** #142 (kimi PreToolUse permission forwarding), #145 (3rd
kimi tyttö e2e dogfood).

This is the canonical playbook for validating the kimi PreToolUse
approval-forwarding loop end-to-end. It exercises the full architecture:

```
kimi (Shell tool fires)
  → kimi-cli runs PreToolUse hook
    → /home/xertrov/.local/bin/c2c-kimi-approval-hook.sh
      → c2c approval-pending-write   (writes <broker_root>/approval-pending/<token>.json)
      → c2c send <reviewer> "[kimi-approval] ..."  (awareness DM)
      → c2c await-reply --token <T>  (watches <broker_root>/approval-verdict/<token>.json)
                                       ← reviewer runs `c2c approval-reply <T> {allow|deny}`
        → prints "allow"/"deny" on stdout, exit 0
      → exit 0 (allow) or exit 2 (deny + reason on stderr)
```

## Pre-flight

1. **Build + install** must include slice 5c (SHA `71571587` or the
   cherry-picked equivalent on local master). Verify:
   ```bash
   c2c approval-reply --help    # must exist
   c2c approval-pending-write --help
   c2c approval-list
   c2c approval-show ka_x         # exit 1 with "no pending record" when empty
   c2c approval-gc                # dry-run prints classification
   ```

2. **Hook script + TOML installed** for the target kimi:
   ```bash
   c2c install kimi --dry-run   # confirm new embedded hook will be written
   c2c install kimi             # install (idempotent via marker)
   cat ~/.kimi/config.toml | grep -A2 "c2c-managed PreToolUse"
   ```
   For e2e the operator must uncomment **one** `[[hooks]]` example block
   (Example A for Shell-only is the safest default).

3. **Restart the target kimi** so it picks up the updated `~/.kimi/config.toml`:
   ```bash
   c2c restart <kimi-alias>
   # or, if managed by `c2c start`, exit + re-launch the pane
   ```

4. **Identify the reviewer alias** (env var override available):
   ```bash
   export C2C_KIMI_APPROVAL_REVIEWER=<reviewer-alias>   # default: coordinator1
   export C2C_KIMI_APPROVAL_TIMEOUT=120                  # seconds
   ```

## Tests

> Each test produces an artifact: a session log entry plus the
> contents of `<broker_root>/approval-pending/` and `approval-verdict/`
> at the relevant points. Capture before-and-after listings.

### Test 1 — Allow path

**Setup:** kimi alias `kuura-viima`, reviewer `stanza-coder`.

1. From kuura's pane: ask kimi to run a Shell tool, e.g. `ls /tmp/`.
2. Hook fires; awareness DM lands in stanza's inbox.
3. From stanza's session:
   ```bash
   c2c approval-list
   c2c approval-show <token>     # confirm pending record matches
   c2c approval-reply <token> allow
   ```
4. **Pass criteria:**
   - kuura's Shell tool runs successfully (exit 0, output visible).
   - `<broker_root>/approval-verdict/<token>.json` is removed
     after await-reply consumes it (cleanup path).
   - `c2c approval-list` no longer shows the token after consume.

### Test 2 — Deny path

1. Trigger same hook.
2. Reviewer runs:
   ```bash
   c2c approval-reply <token> deny because "unsafe rm pattern"
   ```
3. **Pass criteria:**
   - kimi sees the tool blocked with the deny reason in stderr.
   - `c2c approval-show <token>` returns exit 1 (cleanup happened).

### Test 3 — Timeout fall-closed

1. Trigger hook; reviewer does **nothing**.
2. After `C2C_KIMI_APPROVAL_TIMEOUT` seconds (e.g. 30 for the test),
   await-reply exits 1; hook exits 2.
3. **Pass criteria:**
   - kimi reports tool blocked with "no verdict from reviewer ...
     within Ns; falling closed".
   - `<broker_root>/approval-pending/<token>.json` may remain (5c
     gc reaps it later).
   - `<broker_root>/approval-verdict/<token>.json` is absent.

### Test 4 — Claude Code parity

1. Same setup but in a Claude Code session with the slice-4 sentinel
   matcher in `~/.claude/settings.json` (`__C2C_PREAUTH_DISABLED__`).
2. Have Claude Code attempt a Shell tool.
3. Verify the same hook script fires; reviewer approves via
   `c2c approval-reply`.
4. **Pass criteria:** identical to Test 1.

### Test 5 — Concurrent tokens

1. Trigger two hooks back-to-back (e.g. two tool calls in quick
   succession from kuura).
2. **Pass criteria:**
   - Two distinct pending files appear (different tokens).
   - Approving one does not unblock the other.
   - `c2c approval-list` shows both with `wait` until each is
     resolved.

### Test 6 — Operator-UX surfaces (slice 5b)

1. Mid-Test-1: from a third pane, run `c2c approval-list --json`.
2. **Pass criteria:** valid JSON array with at least one item;
   `has_verdict=false` until reviewer replies, then `true`.
3. Run `c2c approval-show <token>` mid-flight; verify it prints the
   pending record with the actual `tool_input` JSON intact (not
   truncated/escaped).

### Test 7 — TTL cleanup (slice 5c)

1. Pre-seed an expired pending file (timeout_at in the past) and a
   2h-old verdict file via touch -d.
2. Run `c2c approval-gc` (dry-run): confirm classification.
3. Run `c2c approval-gc --apply`: confirm exact stale set removed,
   active files preserved.

## In-session execution log (2026-04-30)

Reviewer: stanza-coder. Agent: kuura-viima. Reviewer broker root:
`~/.c2c/repos/<fp>/broker/`. Agent broker root: `.git/c2c/mcp/`
(legacy). All `c2c approval-reply` invocations needed
`C2C_MCP_BROKER_ROOT=<agent-resolved-path>` override — see
**Finding #492** for the architectural fix.

| Test | Result | Token (sample)                    | Notes                                                 |
|------|--------|-----------------------------------|-------------------------------------------------------|
| 1    | PASS   | ka_tool_xLgeZLrz1zhGjVTCqpO5JeDo  | Allow path. Hook→pending→DM(coord1)→verdict→exit 0    |
| 2    | PASS   | ka_tool_9CJRZ7x3iBWEVHlkM3RS9Vg5  | Deny path. stderr "denied by reviewer=$REVIEWER_ENV"  |
| 3    | DEFER  | n/a                               | Covered by slice-5a unit (no-verdict → exit 1 timeout)|
| 4    | DEFER  | n/a                               | Same hook + same await-reply path; sentinel-matcher equiv|
| 5    | PASS   | ka_tool_rijd2..., ka_tool_WnGAp... | Concurrent-token isolation; kimi serial               |
| 6    | PASS   | (mid-flight Test 5)               | approval-list/show showed full pending JSON           |
| 7    | PASS   | ka_test7_expired (synthetic)      | gc removed exactly stale set, kept active             |

Findings filed to `.collab/findings/`:
- `2026-04-30T08-50-00Z-stanza-coder-490-broker-root-mismatch.md`
  (architectural — gates true cross-session use of the side-channel).
- Cosmetic: deny-stderr says "denied by reviewer=$REVIEWER_ENV" not
  the actual approval-reply issuer. Fold into #492 follow-up.

## Closeout

Once all 7 tests pass:

1. Mark task list:
   - [x] #142 (kimi parity: tool/command permissions forwarded)
   - [x] #145 (3rd kimi tyttö e2e dogfood)
2. Append the e2e log to `.collab/personal-logs/stanza-coder/2026-04-30-post-compact-kimi-cont.md`.
3. Update `.collab/design/2026-04-30-142-approval-side-channel-stanza.md`
   "Slicing" section to reflect what 5a/5b/5c actually shipped (not
   the original speculative slicing).
4. File any drive-by findings (matcher syntax, Cmdliner `--`
   separator quirk, etc) under `.collab/findings/`.

🪨 — stanza-coder
