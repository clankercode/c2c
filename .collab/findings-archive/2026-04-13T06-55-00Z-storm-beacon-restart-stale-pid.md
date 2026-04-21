# storm-beacon — codex restart leaves stale registry pid, blocks inbound DMs

## Symptom

After `run-codex-inst-outer` restarted the codex instance at 16:55
(pid 1969430 is the new process per `ps -ef`), the broker's
`registry.json` still reports `codex → pid 1394192`, which no longer
exists in `/proc`. Attempting `mcp__c2c__send from_alias=storm-beacon
to_alias=codex ...` fails with

    Invalid_argument("recipient is not alive: codex")

— the broker's liveness gate correctly rejected the send because the
registered pid is dead. But the new codex instance exists; it just
didn't re-register its pid.

## How I discovered it

Diagnosing Max's question about whether opencode-local was busy or
broken during the password game, I sent a confirmatory DM to codex
too and got the "recipient is not alive" error. Checking the process
tree:

    registry.json : codex → pid 1394192  (/proc=DEAD)
    ps -ef        : new codex at pid 1969430 started 16:55 via
                    run-codex-inst-outer c2c-codex-b4

The new codex's MCP child (c2c_mcp.py → OCaml broker, pid 1969599)
started but did NOT update the registry entry for alias `codex`.

## Root cause (hypothesis, unverified)

v0.6.1's `auto_register_startup` helper (added this afternoon) is
supposed to register the current session at startup. The codex case
passes `C2C_MCP_SESSION_ID="codex-local"` in its MCP env
(see the `ps -ef` line for pid 1969423). So startup auto-register
should fire. Either:

1. `auto_register_startup` does not update pid/pid_start_time when the
   alias already has a registry entry — it treats existing entries as
   authoritative. Result: old pid sticks.
2. The startup auto-register is gated on the session being discovered
   via `default_session_id()`, and codex's session doesn't match the
   file-based probe (codex's sessions live elsewhere from Claude's
   `~/.claude*/sessions/`).
3. The registration code path races with the restart — child MCP
   starts before the new codex process is "stable" and the broker
   decides the pid is invalid.

Need to read `auto_register_startup` in `ocaml/c2c_mcp.ml` and the
Python `c2c_register.py` path to confirm which branch we're hitting.

## Severity

High for the restart-loop story. `run-codex-inst-outer` is the
codex equivalent of `run-claude-inst-outer` — it's supposed to
provide sustained codex presence. If every restart leaves `codex`
unreachable until someone manually re-registers, the restart loop
breaks cross-client 1:1 DMs to codex for minutes at a time.

## Fix direction (not yet applied)

- Have `auto_register_startup` *always* update `pid` and
  `pid_start_time` on an existing registry entry, keyed by alias+
  session_id. Don't skip the update on "already exists".
- As a belt-and-braces: when the broker's liveness check finds a dead
  pid for an alias, it should clear the pid field so the next send
  fails with a clearer "peer is stale — no live registration" error
  instead of silently pointing at a ghost.
- Add a regression test in `test_c2c_mcp.ml`: create a registry entry
  with a dead pid, call `auto_register_startup`, assert the pid was
  updated.

## Workaround for now

Manually touch codex's registry entry with `c2c_register.py codex-local
--pid <new_pid>`, or let codex itself re-register on its next poll
cycle (if the new codex instance gets prompted to `poll_inbox`, the
MCP RPC path will update its own registry entry).

## Witness

- `registry.json` snapshot at 2026-04-13 16:55Z shows
  `codex → pid=1394192` while `/proc/1394192` does not exist.
- `ps -ef` shows `pid 1969430 codex ... resume 019d8483-...` started
  at 16:55 by `run-codex-inst-outer`.
- The failing send was issued from storm-beacon
  (session `d16034fc-5526-414b-a88e-709d1a93e345`) to alias `codex`
  via `mcp__c2c__send` at ~16:53Z.
