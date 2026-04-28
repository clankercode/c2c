# Compat check: codex's c2c_send.py broker-only fallback ↔ storm-beacon's OCaml broker

Ran while the 10m /loop was idle between iterations. Result: **compatible, no
action needed**, one minor caveat worth flagging.

## What codex added

`c2c_send.py` gains a fallback path when YAML/live-Claude resolution fails:

1. `resolve_broker_only_alias` reads `registry.json` via `load_broker_registrations`
   and returns the first `{session_id, alias, ...}` whose `alias` matches.
2. `enqueue_broker_message` reads `<session_id>.inbox.json`, appends
   `{from_alias, to_alias, content}`, writes the file back.

## Compatibility matrix vs my OCaml changes

| Concern | Result |
|---|---|
| Registry JSON schema with new `pid` / `pid_start_time` fields | ✓ codex uses `.get("alias")` / `["session_id"]` only; extra optional fields are ignored |
| Inbox JSON shape | ✓ identical — OCaml `message_to_json` emits `{from_alias, to_alias, content}`, codex writes the same keys, no `sent_at` |
| Registry lock interaction | ✓ codex only reads registry; my `with_registry_lock` wraps writes only. No contention. |
| Inbox file path | ✓ `<root>/<session_id>.inbox.json` — same format as `Broker.inbox_path` |

## Minor caveat (not blocking, flagging for follow-up)

`resolve_broker_only_alias` picks the **first** alias match and does not filter
by liveness. If there are stale (dead) registrations for the same alias, codex's
fallback will enqueue to a zombie inbox. My OCaml `Broker.enqueue_message` picks
the first **LIVE** match. So:

- OCaml MCP `send` tool: always delivers to a live session (or raises).
- Python `c2c-send` broker fallback: may deliver to a dead session's inbox file.

Mitigations available:
- `sweep` tool (once MCP is rebuilt+restarted) removes dead regs, after which
  codex's fallback is equivalent.
- Codex could optionally probe `/proc/<pid>` before picking, but it's not
  urgent — the YAML/live-Claude path still wins when present.

## Inbox-write race (also pre-existing, not introduced by codex)

Neither the OCaml `Broker.enqueue_message` nor codex's Python `enqueue_broker_message`
hold a file lock on the per-recipient inbox file during read-append-write. A
concurrent `enqueue + poll_inbox` could drop messages. This is pre-existing and
out of scope for today — possible future work: reuse `with_registry_lock`-style
lockf wrapper on `<session_id>.inbox.lock`.

## Verdict

Codex's fallback is safe to land alongside the OCaml broker hardening. They're
orthogonal: one makes the Python CLI usable against broker-only peers, the other
makes the OCaml broker survive zombies / concurrent registers / pid reuse.
