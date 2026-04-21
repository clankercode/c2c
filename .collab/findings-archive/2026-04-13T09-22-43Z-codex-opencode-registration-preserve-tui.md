# OpenCode auto-registration now preserves the durable TUI over one-shot runs

## Symptom

`opencode-local` direct sends could fail with:

`recipient is not alive: opencode-local`

even while the interactive OpenCode TUI was alive. The broker row could point to
a short-lived `opencode run` worker instead of the durable TUI pid.

## Discovery

After the Codex↔OpenCode proof, the live broker registry showed:

`alias=opencode-local`, `pid=<opencode run ...>`

while the interactive TUI was still alive at pid `2193537`. The one-shot worker
had auto-registered the same `session_id`/`alias` and displaced the durable TUI
registration.

## Root Cause

`c2c_mcp.py` auto-registration removed any existing row with the same
`session_id` or `alias` and inserted the current client pid. That is correct for
normal restarts, but OpenCode has two process roles sharing the same alias:

- durable TUI: `opencode -s <session>`
- one-shot worker: `opencode run --session <session> <prompt>`

The one-shot should not clobber the durable TUI's live broker presence.

## Fix Status

Fixed in `c2c_mcp.py`:

- detects live existing broker rows using `pid` + `pid_start_time`
- detects OpenCode one-shot workers by command line (`opencode run`)
- preserves a live durable TUI registration when a one-shot worker starts
- still allows a durable TUI registration to replace a live one-shot worker

Focused tests cover both preservation and replacement.

Live smoke:

1. Refreshed `opencode-local` via `maybe_auto_register_startup` with TUI pid
   `2193537`.
2. Sent Codex → OpenCode direct DM with `mcp__c2c__send`; it queued instead of
   rejecting as dead.
3. Woke OpenCode with delayed PTY nudge.
4. Codex received:

`from_alias=opencode-local`, `content=opencode registration liveness smoke received`

## Severity

High for OpenCode reliability. Without this fix, liveness could oscillate with
every one-shot run, causing direct sends to randomly fail or route to a dead
registration.
