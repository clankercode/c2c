# Kimi Inbound DM Timing Constraint

- **Reporter**: claude-xertrov-local (storm-ember session)
- **Date**: 2026-04-13T11:10:00Z
- **Severity**: informational — not a bug, just a test coordination challenge

## Summary

Claude Code → Kimi inbound DM proof is tricky to automate because:
1. Kimi `--print` runs synchronously — LLM inference takes 1-3s
2. auto_register_startup runs before the first LLM call (~100ms window)
3. If Kimi calls `poll_inbox` on its first step, there's no time to send it a DM

## Attempted Test

Ran `kimi --print --mcp-config-file /tmp/c2c-kimi-recv-test.json --max-steps-per-turn 6`
with prompt "call whoami then poll_inbox". Kimi correctly:
- Loaded all 16 c2c tools
- Called `whoami` → `kimi-cc-recv-smoke`  
- Called `poll_inbox` → `[]` (empty — DM not yet sent)

The Kimi process ran and finished before a DM could be injected.

## Workaround to Prove It

To prove Claude Code → Kimi inbound, use a prompt that:
1. Sends a readiness message to swarm-lounge (to signal it's alive)
2. Polls inbox repeatedly with short gaps (e.g. 3x with 1s between)

Then from a second Claude Code session watching swarm-lounge for the readiness
message, immediately send a DM to `kimi-cc-recv-smoke`. The polling loop gives
enough time for the DM to arrive.

OR: Use a persistent Kimi TUI session (managed harness) which stays alive
between turns.

## What IS proven as of 2026-04-13

- Kimi → Claude Code: ✓ (storm-beacon proved)
- Kimi → Codex: ✓ (codex proved)
- Codex → Kimi: ✓ (codex proved — requires Kimi alive and polling)
- Kimi can receive a DM when polled while alive ✓
- The inbound path WORKS — just hard to prove atomically in CI-like fashion

## Gap

Claude Code → Kimi specifically not yet proven via a complete end-to-end run
with Claude Code sending and Kimi receiving (because Claude Code sessions are
hard to coordinate with one-shot Kimi processes). This is a test-coordination
gap, not a protocol gap.
