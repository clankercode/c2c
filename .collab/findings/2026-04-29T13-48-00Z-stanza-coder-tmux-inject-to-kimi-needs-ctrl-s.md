# Tmux-injecting to a busy kimi pane: messages QUEUE, need Ctrl-S to force-submit

- **Date:** 2026-04-29 13:48 UTC
- **Filed by:** stanza-coder (Max-flagged)
- **Severity:** Operational gotcha (not a bug per se; documented behavior)
- **Cross-references:** #150 (notifier session-id race forcing tmux-inject as workaround)

## Symptom

Operator (or another agent via `scripts/c2c_tmux.py send <pane> "<text>"`)
sends text to a kimi tmux pane while kimi is mid-turn (using a tool,
thinking, etc.). The text appears typed into the input box but does NOT
fire as a user-turn — kimi-cli's TUI shows it queued behind the
in-flight turn:

```
↑ to edit · ctrl-s to send immediately

── input · 1 queued ────────────────────────────────────────...
```

The message will eventually fire when the current turn boundary is
crossed, BUT if subsequent text is sent before that boundary, OR if the
operator wants the message processed RIGHT NOW (e.g. RESCIND messages
to halt mid-impl work), the queue-wait is wrong.

## Mechanism

kimi-cli's TUI input box has a "send when current turn completes"
default. Pressing Ctrl-S forces immediate submit of the typed text.
Pressing Enter alone (which `scripts/c2c_tmux.py send` already does)
appears to NOT force-submit — Enter goes into the "queue" rather than
"send immediately" path.

## Workaround

For force-submit, send Ctrl-S AFTER the text:

```bash
# Type the message
scripts/c2c_tmux.py send <pane> "<text>"

# Wait briefly so kimi's TUI registers the queued state
sleep 0.3

# Force-submit immediately
scripts/c2c_tmux.py keys <pane> C-s
```

Or extend `scripts/c2c_tmux.py send` to accept a `--force-submit` flag
that does the Ctrl-S after the text in the same invocation. Filed as
the runbook update below.

## Why this matters

In RESCIND scenarios — operator realizes a brief was sent in error and
wants to halt mid-impl work — the queue-wait is destructive. The kimi
agent finishes the in-flight tool/turn (potentially executing
unintended work), THEN reads the rescind. Without Ctrl-S, the rescind
fires AFTER damage is done.

In our 2026-04-29 22:43 incident: I sent #149/#151 impl briefs to
kuura/lumi via tmux, then 30s later sent rescind messages because Max
raised an architectural pivot (pre-mint UUID). The rescind messages
queued behind the impl briefs. Without Ctrl-S, kuura+lumi started
setting up impl worktrees + reading sources for the impls before
processing the rescind. We caught it before any code committed
because Max flagged the queue behavior, but the lag was load-bearing.

## Runbook update needed

Add to `.collab/runbooks/agent-wake-setup.md` (or sibling) a section
"Tmux injection to managed kimi sessions" with:
- The queue behavior + Ctrl-S workaround
- Recommended pattern: tmux-send + sleep 0.3 + Ctrl-S for time-sensitive
  messages (rescinds, urgent unblocks, hot-fixes)
- Note: babysitter haiku auto-approving permission prompts works
  independently of this — it sends `2`+Enter into the approval banner,
  not into the input box, so it bypasses the queue entirely.

## Recommended `c2c_tmux.py` enhancement (#follow-up task)

```bash
scripts/c2c_tmux.py send <pane> "<text>" --force-submit
# equivalent to: send "<text>"; sleep 0.3; keys C-s
```

Most-call-sites are happy with the default queue behavior (operator
not in a rush). The opt-in `--force-submit` is for the rescind /
hotfix / unblock cases.

🪨 — stanza-coder

---

## Adjacent operator-experience update — 2026-04-30 ~00:07 AEST

Max updated `~/.kimi/config.toml` to hide raw thinking stream (likely
`show_thinking_stream = false` or equivalent). New kimi sessions
display token-count instead of full chain-of-thought.

Effects:
- Operator scrollback dramatically cleaner — much less competing
  with c2c-chat-log.md sidecar for attention
- #476 (per-instance hide-thinking overlay) lower priority as a
  feature now that the global default is hidden; may still want
  per-instance override for debug sessions
- Existing live kimis (kuura, lumi) won't pick up the change until
  restart since kimi-cli reads config at session-init
- Babysitter haiku auto-approve flow unaffected — the approval banner
  uses box-drawing characters as its detection pattern, not the
  Thinking/reasoning text
