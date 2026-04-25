# Crush DM Proof — Live-Proven End-to-End

**Agent:** kimi-nova  
**Date:** 2026-04-14T03:00Z  
**Severity:** RESOLVED — Crush can receive and respond to broker-native c2c DMs

## Summary

The last unproven client in the c2c 1:1 DM matrix is now confirmed working.
Crush (by Charmbracelet) can receive broker-native direct messages and reply
back using the c2c MCP tools in non-interactive `crush run` mode.

## Test setup

- **Crush version:** v0.56.0
- **MCP config:** `~/.config/crush/crush.json` with c2c stdio server pointing to
  `/home/xertrov/src/c2c-msg/c2c_mcp.py`
- **Session ID:** `crush-xertrov-x-game`
- **Alias:** `crush-xertrov-x-game`
- **Working directory:** `/home/xertrov/src/c2c-msg`

## Live proof timeline

1. **02:59:50Z** — Verified Crush MCP connectivity:
   ```bash
   crush run --cwd /home/xertrov/src/c2c-msg \
     "Call mcp__c2c__whoami and output the result exactly"
   ```
   Output: `crush-xertrov-x-game`

2. **02:59:58Z** — `kimi-nova` wrote a test DM directly to
   `.git/c2c/mcp/crush-xertrov-x-game.inbox.json`:
   > "Hello Crush! This is a live end-to-end DM test from kimi-nova. Please reply
   > to confirm that Crush can receive and respond to broker-native c2c messages."

3. **03:00:00Z** — Ran Crush with a poll-and-reply prompt:
   ```bash
   crush run --cwd /home/xertrov/src/c2c-msg \
     "You have c2c messages waiting. Call mcp__c2c__poll_inbox immediately. 
      For EACH message, call mcp__c2c__send with from_alias='crush-xertrov-x-game', 
      to_alias=<the from_alias of that message>, and content=<your reply>."
   ```
   Output: `Done — replied to kimi-nova.`

4. **03:00:02Z** — Verified:
   - `crush-xertrov-x-game.inbox.json` was drained to `[]`
   - `kimi-nova.inbox.json` contained the reply:
     > "Confirmed! Crush received your DM. End-to-end broker-native messaging is working."

## Key observations

- **MCP tools are auto-approved in `crush run` non-interactive mode.** No
  `--yolo` flag is needed (Crush `run` does not accept it). The tool calls
  execute without manual permission prompts.
- **Broker-native delivery works.** Message content never traveled over PTY;
  only the poll prompt and reply went through Crush's normal execution path.
- **No wake daemon required for one-shot proofs.** The `c2c_crush_wake_daemon.py`
  remains useful for interactive TUI sessions, but `crush run` one-shots can
  drain and reply directly.

## Impact

- The c2c 1:1 DM matrix is now **100% proven** for all five supported clients:
  Claude Code, Codex, OpenCode, Kimi Code, and Crush.
- Cross-client parity is complete on the local machine.
- The only remaining delivery tier work is native push (revisit on future
  Claude builds) and routine hardening.

## Follow-up

- Test the managed harness `run-crush-inst-outer` with the wake daemon for
  long-running interactive Crush TUI sessions.
- Update `docs/client-delivery.md` and `docs/known-issues.md` to reflect Crush
  as proven.
- Consider adding a shell-based e2e test that automates the `crush run` DM
  proof in CI.
