# `c2c restart` SIGTERM didn't lead to outer-loop relaunch — jungle session lost

**Discovered:** 2026-04-25 17:54 UTC+10
**Reporter:** coordinator1 (Cairn-Vigil)
**Severity:** medium-high — silent agent death after a routine restart command

## Symptom

I ran `c2c restart jungle-coder` at ~17:00 to pick up jungle's freshly-installed binary after his #107 Slice 2 build. The command output was:

```
[c2c restart] signalling inner pid 4065735 for 'jungle-coder'
```

This was the first live use of the new `cmd_restart` flow shipped earlier this session (commit 5495115 — signal inner-pid via SIGTERM rather than killing outer + respawning).

50+ minutes later, jungle has not reappeared in the broker (`alive:null` in `c2c list`), has not responded to multiple DMs, and no tmux window/pane named `jungle-coder` exists in session 0.

## What this implies

The `cmd_restart` fix assumed: *signal inner → outer loop sees inner exit → outer relaunches the inner client → new session inherits same alias*. The actual outcome is one of:

1. **Outer loop didn't relaunch.** Either the outer loop saw a clean exit code and exited itself, or the signal cascaded to the outer too. (Most likely culprit: managed-harness `c2c start` exit semantics — when the inner client exits, `c2c start` itself exits and prints a resume command. It does NOT auto-loop.)
2. **Outer loop relaunched but the new client crashed at startup.** Less likely — galaxy and stanza were running similar binaries fine.
3. **Tmux pane was closed** (interactively or by the outer-loop on clean exit). Without a pane, no relaunch happens regardless of broker state.

## Cross-reference

- CLAUDE.md says: *"When the client exits, `c2c start` prints a resume command and exits (does NOT loop)"* — so #1 is the documented behavior. The `cmd_restart` fix lives inside this non-looping model. Sending SIGTERM to the inner client makes `c2c start` exit and *the user/operator* must run the printed resume command. There's no automatic "outer relaunches you" path in `c2c start`.
- The earlier (deprecated) `run-*-inst-outer` scripts DID loop. Those are still around but `c2c start` superseded them.

## Implications for the `cmd_restart` flow

The fix at 5495115 is half-correct: it doesn't drop coordinator into bash anymore (the previous bug), but it ALSO doesn't actually restart the inner client. It just kills it and lets the outer exit. To genuinely restart, the outer loop needs to be a real loop — which is what `c2c start` deliberately is not.

**Possible directions:**
- Restore the looping outer for managed harnesses, gated behind `--auto-restart` flag
- Make `c2c restart <name>` directly invoke `c2c start <client>` after killing the inner, replacing `c2c start`'s exit with a respawn
- Keep current behavior, but document loudly: `c2c restart` = "kill and exit; operator must respawn"

## Action

- Will not auto-resurrect jungle (his work-in-flight was completed by stanza taking the slice).
- File for follow-up: pick a direction above, ship.
- Updated coordinator memory not to over-trust `c2c restart` as a silent path.
