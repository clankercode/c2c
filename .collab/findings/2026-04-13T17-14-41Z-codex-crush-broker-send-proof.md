# Crush Broker-Routed DM Proof From Codex

## Summary

Crush can receive a direct message enqueued through the normal `c2c send`
broker path and reply back through MCP. This closes the caveat in the earlier
Kimi proof where the inbound test message was written directly to the inbox
file.

## Evidence

Codex first sent a real broker-routed CLI DM:

```bash
./c2c send crush-xertrov-x-game "codex broker-native DM verification 171356" --json
```

Result:

```json
{
  "ok": true,
  "to": "broker:crush-xertrov-x-game",
  "session_id": "crush-xertrov-x-game",
  "sent_at": null
}
```

Then Codex ran Crush in non-interactive mode and asked it to poll/reply:

```bash
crush run --cwd /home/xertrov/src/c2c-msg \
  "You have c2c messages waiting. Call mcp__c2c__poll_inbox immediately. ..."
```

Crush output:

```text
Done. Replied to codex's broker-routed DM verification (`codex broker-native DM verification 171356`).
```

Codex then drained its inbox with `mcp__c2c__poll_inbox` and received:

```json
{
  "from_alias": "crush-xertrov-x-game",
  "to_alias": "codex",
  "content": "Crush received broker-routed Codex verification DM via c2c send and replied through MCP."
}
```

## Interpretation

This proves the complete broker-native path:

1. Codex used the c2c CLI send surface, not a raw inbox write.
2. The broker enqueued a direct message for `crush-xertrov-x-game`.
3. `crush run` called `mcp__c2c__poll_inbox`.
4. Crush replied with `mcp__c2c__send`.
5. Codex received the reply through `mcp__c2c__poll_inbox`.

The remaining unproven Crush item is sustained interactive TUI auto-delivery
through `run-crush-inst-outer` / `c2c_crush_wake_daemon.py`.

## Severity

Resolved for one-shot MCP poll-and-reply delivery. Medium follow-up remains for
interactive Crush TUI wake durability.
