# Kimi Streaming Queue → Steer Patch

**Agent:** kimi-nova
**Date:** 2026-04-14T01:35Z
**Severity:** MEDIUM — reduces c2c DM latency from end-of-turn to end-of-step

## Problem

By default, when Kimi Code is actively processing a turn (streaming), any
user input submitted via Enter is **queued** for delivery after the current
turn completes. This means c2c PTY-injected wake prompts also wait until the
entire turn finishes before Kimi calls `mcp__c2c__poll_inbox`.

The user (kimi-nova) asked whether we can change this so messages are handled
at **end-of-step** rather than end-of-turn.

## Root Cause

In Kimi CLI's input router (`kimi_cli/ui/shell/visualize/_input_router.py`):

```python
def classify_input(text: str, *, is_streaming: bool) -> InputAction:
    ...
    if is_streaming:
        return InputAction(InputAction.QUEUE)
    return InputAction(InputAction.SEND)
```

During streaming, Enter always maps to `QUEUE`. The queued messages are stored
in `_interactive._queued_messages` and only drained after the turn ends.

Kimi also supports **steer** (Ctrl+S) which injects input immediately into the
running turn's context. The soul consumes pending steers **between steps**:

```python
# Consume any pending steers between steps
await self._consume_pending_steers()
```

If a steer is consumed, it forces another LLM step. This is exactly the
end-of-step delivery behavior we want.

## Fix Applied

### 1. Patch Kimi CLI source (local uv tool install)

Patched:
`/home/xertrov/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/ui/shell/visualize/_interactive.py`

Added an environment-variable gate in `handle_local_input()` so that when
`KIMI_CLI_C2C_STEER_STREAMING=1`, `QUEUE` actions are immediately steered
instead of being appended to the queue:

```python
# c2c override: steer streaming inputs immediately instead of
# queueing them for end-of-turn delivery.
if __import__("os").environ.get("KIMI_CLI_C2C_STEER_STREAMING", "").strip().lower() in {"1", "true", "yes"}:
    self.handle_immediate_steer(user_input)
    return
self._queued_messages.append(user_input)
```

### 2. Update managed launcher

Patched `run-kimi-inst` in the c2c repo to export:

```python
env["KIMI_CLI_C2C_STEER_STREAMING"] = "1"
```

This ensures all `run-kimi-inst-outer` managed sessions use the new behavior.

## Impact

- c2c wake prompts injected into an active Kimi session will now interrupt the
  current turn at the **end of the current step** instead of waiting for the
  full turn to complete.
- This significantly reduces DM latency for busy Kimi agents.
- The change is gated by an env var, so standalone `kimi` usage is unaffected.

## Risks / Notes

- The patch is applied to the **local uv tool installation**. If the user
  reinstalls or upgrades `kimi-cli` via uv, the patch will be lost and must be
  re-applied. A longer-term fix would be a Kimi CLI config option or a native
  c2c Kimi plugin that calls `soul.steer()` directly without PTY injection.
- With this patch, **any** Enter-key input during streaming (not just c2c
  nudges) will be steered. For an autonomous c2c-managed Kimi instance, this
  is the desired behavior.

## Verification

- `python3 -m py_compile run-kimi-inst` OK
- `python3 -m unittest tests.test_c2c_cli.RunKimiInstTests` 10/10 OK
- Kimi process must be restarted for the patched code + new env var to take
  effect.

## Next Step

Restart the live `kimi-nova` managed session:

```bash
# From a shell that can signal the outer loop
kill -INT $(cat run-kimi-inst.d/kimi-nova.pid)
```

The outer loop will relaunch with `KIMI_CLI_C2C_STEER_STREAMING=1`, and the
next c2c DM should be steered at end-of-step.
