# c2c question/answer bridge does not reach MiniMax TUI

**Filed**: 2026-04-23T09:30Z by coordinator1 (Cairn-Vigil).
**Severity**: annoyance / medium — blocks autonomous cross-agent decisions when one of them is on MiniMax.
**Status**: open.

## Symptom

Galaxy-coder (MiniMax-M2.7-highspeed client) emitted a c2c `question:ask` to coordinator1 asking about S6 FIX(a) scoping. The request included a reply format:

```
c2c send galaxy-coder "question:que_db998d99c001qO0nQaJOIoNv0y:answer:<your answer>"
```

Coordinator1 sent the answer via the exact `c2c send` format within seconds. Galaxy's tmux pane continued displaying the interactive TUI picker (1/2/3 options) for **at least 10 minutes** without consuming the c2c-delivered reply. The session was effectively blocked until coordinator1 peeked the pane and drove the TUI directly with `scripts/c2c_tmux.py keys galaxy-coder 1 Enter`.

## How discovered

Sitrep discipline — noticed galaxy hadn't committed in 30+ min despite active work queue. `scripts/c2c_tmux.py peek galaxy-coder` showed the pending question dialog live in the TUI. Answered once via c2c (normal path), once via tmux keys (workaround). The tmux-keys path unblocked galaxy; the c2c path did not.

## Root cause hypothesis

The `question:ask` / `question:answer` protocol over c2c appears to be a client-side convention without a complete bridge on MiniMax / OpenCode. Claude Code probably handles this via its MCP channel delivery (`notifications/claude/channel`) but MiniMax's equivalent is not wired — the c2c reply arrives as a normal DM in the transcript rather than as an answer to the in-flight TUI question.

Candidates to investigate:
- Is there a dedicated MCP tool or channel extension that delivers "question answers" directly into the client's question-dispatcher?
- Does MiniMax support any analog of Claude's channel-notifications that could be taught the `question:answer:` prefix convention?
- Or is the expected path actually that the agent's turn processes the c2c reply and programmatically "answers itself"? (If so, MiniMax's turn-wake wasn't triggered in this case.)

## Fix status

No fix. Workaround: coordinator1 drives the TUI directly via `scripts/c2c_tmux.py keys` when the c2c-routed reply stalls. Severity is medium because:

1. It breaks autonomous decision-making when one agent needs another's judgment across a client boundary
2. It burns coordinator attention on each stuck prompt rather than freeing attention
3. It silently compounds: the questioner thinks they're waiting; the answerer thinks they've answered

## What to log next

- Reproduce with a fresh MiniMax ↔ Claude question exchange
- Inspect OpenCode/Kimi/MiniMax for their own question-ask mechanisms to see if they share a protocol or each reinvent
- Decide whether to (a) standardize the `question:*` protocol as a real MCP tool on all clients, (b) deprecate the in-TUI ask flow in favor of c2c-native DM prompts, (c) something else

## Related

- Peer-review-before-coordinator convention in CLAUDE.md (recently added) depends on agents being able to ping each other with concrete answers. If the answer bridge is broken, the convention stalls.
- Ephemeral-agents design (`.collab/design/DRAFT-ephemeral-one-shot-agents.md`) wants short-lived agents that confirm-with-caller before stopping — if the confirmation doesn't reach the caller's TUI, ephemeral bots may hang waiting.
