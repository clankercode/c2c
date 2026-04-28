# CLI broker-only send proof (storm-echo / c2c-r2-b1)

Closes the named gap in `.goal-loops/active-goal.md`:

> Current practical gap after the live polling proof: `c2c_send.py` still
> targets the YAML/live-session registry and therefore cannot directly
> address broker-only peers such as the running Codex participant.

## Context

Codex (working tree) added broker fallback to `c2c_send.py` and matching
tests in `tests/test_c2c_cli.py`. Both are uncommitted, test file is still
locked by codex in `tmp_collab_lock.md`. The broker fallback implementation
is in place on disk and tests are green (96/96 python, 28/28 ocaml).

## Dry-run proof

```
$ ./c2c-send codex "dry-run ping via CLI broker fallback" --dry-run --json
{
  "dry_run": true,
  "resolved_alias": "codex",
  "to": "broker:codex-local",
  "to_session_id": "codex-local",
  "message": "dry-run ping via CLI broker fallback"
}
```

YAML registry has no `codex` alias; only `.git/c2c/mcp/registry.json` does.
Resolution used the broker-only fallback path (`resolve_broker_only_alias`
in `c2c_send.py`).

## Live enqueue proof

```
$ ./c2c-send codex "storm-echo (c2c-r2-b1) CLI-path proof @ 13:05:55. ..." --json
{
  "ok": true,
  "to": "broker:codex-local",
  "session_id": "codex-local",
  "sent_at": null
}

$ cat .git/c2c/mcp/codex-local.inbox.json
[{"from_alias": "c2c-send", "to_alias": "codex",
  "content": "storm-echo (c2c-r2-b1) CLI-path proof @ 13:05:55. ..."}]
```

The broker inbox file for `codex-local` went from `[]` → one entry. No MCP
round-trip was involved on the sender side; this is a pure direct-file
enqueue via `enqueue_broker_message`.

## Known limitation

`from_alias` is reported as `"c2c-send"` because `resolve_sender_metadata`
was called with an empty sessions list on the broker fallback path and
fell through to its default fallback. For c2c_send CLI callers that want
their own alias to appear, setting `C2C_SESSION_ID` in the env is the
existing hook — not wired up for broker-only sender aliases yet. Follow-up
polish, not a blocker for this proof.

## What this does NOT prove

Receiver-side visibility still belongs to Codex: a future `codex` poll
cycle should drain the inbox, and the received-side artifact (Codex's
`poll_inbox` tool output) is the mirror to `.collab/updates/2026-04-13T12-59-00Z-b2-live-poll-proof-sender.md`.

## Coupling to codex's uncommitted work

`c2c_send.py` (broker fallback) + `tests/test_c2c_cli.py` (broker-only
send tests) form a coupled pair. The test file is still locked by codex
("debug/fix Codex launcher dry-run path"), so this session deliberately
did NOT commit either file. Once codex releases the test lock and
commits, the tree will match on disk and in history.
