---
alias: kimi-nova-2
timestamp: 2026-04-14T09:55:00Z
severity: medium
status: documented; needs sweep when safe
---

# Duplicate PID ghost: opencode-c2c-msg shares pid with codex

## Symptom

Registry inspection shows two aliases pointing to the same PID:
- `codex` → pid 552302
- `opencode-c2c-msg` → pid 552302

PID 552302 is the live `run-codex-inst-outer` managed Codex session. The
`opencode-c2c-msg` registration is stale — there is no live OpenCode process
with that session ID. The `opencode-c2c-msg` inbox has 7 pending messages
that will never drain.

## Impact

- Messages sent to `opencode-c2c-msg` are enqueued to a dead inbox.
- `c2c list --broker` reports `opencode-c2c-msg` as `[alive]` because it
  shares a live PID, even though the session itself is a ghost.
- Health check `stale_inboxes` reports `opencode-c2c-msg: 7 pending`.

## Root cause (tentative)

`opencode-c2c-msg` was likely a one-shot or test session that died without
unregistering. Its PID was later reused by the Codex outer loop (or the
registration was never updated after the process exited). The broker's
`broker_registration_is_alive` only checks `/proc/<pid>` and optionally
`pid_start_time` — it does not detect when two registrations share the
same live PID but only one is legitimate.

## Recommended fix

1. **Short term**: run `c2c sweep` when no outer loops are active to drop
   the ghost. Currently unsafe because 4 outer loops are running.
2. **Medium term**: add duplicate-PID detection to `c2c health` or
   `c2c list --broker` so operators can spot these ghosts immediately.
3. **Long term**: consider making `auto_register_startup` or sweep detect
   and resolve duplicate PID registrations (e.g., if two aliases share a
   PID but only one matches the process environment / session_id).

## Verification

```bash
$ python3 -c "import json; reg=json.load(open('.git/c2c/mcp/registry.json')); print([r['alias'] for r in reg if r.get('pid')==552302])"
['opencode-c2c-msg', 'codex']

$ pgrep -a -f "codex" | grep 552302
552302 npm exec @openai/codex ... --session codex-local ...

$ pgrep -a -f "opencode" | grep -i "opencode-c2c-msg"
# no results
```
