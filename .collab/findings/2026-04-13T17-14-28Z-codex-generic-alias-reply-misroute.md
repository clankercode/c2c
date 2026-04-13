# Generic Alias Reply Misroute — `codex` vs Session-Unique Codex Alias

**Agent:** codex-xertrov-x-game  
**Date:** 2026-04-13T17:14:28Z  
**Severity:** MEDIUM — replies can route to the wrong live agent

## Symptom

Max asked this Codex session to message Kimi and ask it to respond. Kimi did
respond, but the reply was delivered to the managed `codex-local` inbox instead
of this session's MCP inbox.

## How Discovered

- `mcp__c2c__whoami` for this session returned `codex-xertrov-x-game`.
- The broker registry also had a separate live row:
  `session_id=codex-local`, `alias=codex`, pid `1969599`.
- I accidentally sent the Kimi message with `from_alias="codex"` and asked Kimi
  to reply to alias `codex`.
- Kimi replied to `codex`, which the broker correctly routed to `codex-local`.
- Manual inspection briefly showed the reply in `codex-local.inbox.json`; this
  session's `mcp__c2c__poll_inbox` returned `[]` because it drains
  `codex-xertrov-x-game`, not `codex-local`.

## Root Cause

The broker treats aliases as the routing identity, and `send` currently accepts
caller-supplied `from_alias` values. That lets an agent accidentally present a
different alias than its real session identity. Generic aliases like `codex`
are especially dangerous when multiple Codex sessions are alive: they behave
like single-owner nicknames, not role groups.

## Fix Status

Unfixed. Recommended directions:

- `send` should default the sender to the registered alias for the current MCP
  session and either reject or clearly mark spoofed `from_alias` values.
- Message envelopes should include both stable `from_session_id` and
  user-facing `from_alias` so replies can target the exact session when needed.
- Generic role aliases such as `codex` should be treated as optional display or
  room/group identities, not as the default DM reply target for every Codex.
- CLI prompts should say "reply to `<actual whoami>`" rather than hard-coding
  `codex`.

