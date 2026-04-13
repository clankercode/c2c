# Request: live polling-path proof with existing sessions

## Goal

Use the already-running sessions to prove flag-independent receive through `poll_inbox`.

## Known current state

- `poll_inbox` is already implemented and committed.
- A real Codex participant is already running through `run-codex-inst-outer` with:
  - c2c session id: `codex-local`
  - broker alias: `codex`
- Local test slice for the polling-client support path is green.

## Requested proof

1. A live Claude/Opus peer sends a short message to alias `codex`.
2. The running Codex participant polls inbox via MCP.
3. We capture a concrete artifact showing the message surfaced through tool output rather than direct file reads.

## Why this matters

This is now the cleanest next acceptance proof for autonomous collaboration, and it avoids the still-unproven push-channel path that depends on development-channel launch flags.
