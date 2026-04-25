# Sweep Drops Managed Sessions Between Outer-Loop Iterations

**Timestamp:** 2026-04-13T22:00:00Z  
**Agent:** storm-ember  
**Severity:** HIGH — data loss (messages dropped to dead-letter)

## Symptom

Called `mcp__c2c__sweep` while a managed harness session (kimi-nova / kimi-xertrov-x-game)
was between outer-loop iterations. The sweep detected the registered PID as dead (kimi had
finished its current run and the outer loop was in its restart pause), and swept the session —
preserving 4 messages to dead-letter.jsonl.

Dead-letter content lost:
1. storm-ember swarm-lounge: peer-renamed announcement
2. codex swarm-lounge: status update
3. storm-ember→kimi-nova DM: 1:1 channel verification
4. codex→kimi-nova DM: Kimi↔OpenCode DM path test request

## Root Cause

`mcp__c2c__sweep` checks each registered session's PID liveness. Managed harness sessions
(kimi, codex, opencode, crush) run as a sequence of short-lived child processes under an outer
restart loop. Between iterations, the child PID is dead but the outer loop is alive and will
relaunch within seconds.

The sweep has no concept of "outer loop is still alive". It sees dead PID → sweeps the
registration and inboxes → messages lost to dead-letter.

The session will re-register on next inner-process launch, but:
- Dead-letter messages are NOT automatically redelivered on re-registration
- Re-registered alias may differ from swept alias if configs changed
- Senders are not notified that their message was lost

## Severity

HIGH: Silent data loss. Sender gets `{queued:true}` on send, but if sweep runs before the
recipient polls, the message is dropped to dead-letter with no retry and no notification.

## Fix Status

**Immediate workaround**: Do NOT call `mcp__c2c__sweep` when managed harness outer loops are
running. Sweep is an operator tool for cleaning up truly dead sessions (no outer loop, no
restart expected). Check for running outer-loop processes before sweeping:

```bash
pgrep -a -f "run-kimi-inst-outer\|run-codex-inst-outer\|run-opencode-inst-outer\|run-crush-inst-outer"
```

If any are running, do not sweep those sessions.

**Longer-term fix options**:
1. **Sweep grace period**: Track last-active timestamp; don't sweep sessions inactive for <5min.
2. **Outer-loop PID file**: run-*-inst-outer writes a `.outer.pid` file; sweep checks for live
   outer-loop PID before sweeping a dead inner-process PID.
3. **Sweep dry-run flag**: Add `--dry-run` to sweep so agents can preview what would be dropped.
4. **Dead-letter auto-redeliver**: On re-registration, check dead-letter for any messages
   addressed to the newly-registered session and redeliver them.

Options 2 + 4 together would fully solve the problem. Option 1 is simpler but has edge cases
(genuinely dead sessions also have a recent timestamp if they last ran recently).

## How to Redeliver Lost Messages

Dead-letter entries are in `.git/c2c/mcp/dead-letter.jsonl`. To redeliver manually:
1. Read the dead-letter file for messages addressed to the re-registered session
2. Re-send each message using `mcp__c2c__send` / `mcp__c2c__send_room`

## Prevention Guidance for Agents

**Never call `mcp__c2c__sweep` during active swarm operation.** The sweep is a maintenance
tool for sessions that have been dead for extended periods with no restart expected. In a
running swarm, managed harness sessions (kimi, codex, opencode, crush) will always have a live
outer-loop process even when the inner process is between iterations.

Call sweep only when:
- You confirmed the outer-loop process is NOT running (`pgrep -f "run-*-inst-outer"` returns empty)
- OR Max explicitly asked you to sweep a specific dead session

Safe alternatives to sweep:
- `mcp__c2c__list` to see liveness
- `mcp__c2c__peek_inbox` to inspect inboxes without draining
- `c2c-poll-inbox --session-id <alias>` as operator-only emergency drain
