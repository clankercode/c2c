# B153 Codex app-server in-place restart live receipt

Date: 2026-07-12 (Australia/Sydney)

## Setup

The proof used the worktree-built binary and the repository's canonical tmux
driver, targeting an isolated alias:

```sh
./scripts/c2c_tmux.py exec railmap:3.1 \
  "$PWD/_build/default/ocaml/cli/c2c.exe new codex --alias b153-proof-ack" \
  --force
```

The attached Codex was 0.144.1. `c2c dev instances --json` and the instance
directory showed a running app-server owner with `config.json`, `outer.pid`, and
late-discovered thread ID `019f5597-ceaa-7542-8cc0-2c14c6f76364`.

## Controlled once-only message

One message was sent only to the isolated proof alias:

```text
message_id: 80c3fd7f-7d1d-4481-8bc1-c868c676d7c0
marker: B153-ONCE-1783847454-2315
```

The model-visible turn explicitly reported no action. Before restart, the
repo-local ingress ledger contained exactly one entry for that message in
`injected` state with `retry_count: 0`; the delivery log reported
`injected_count: 1`.

## Acknowledged in-place restart

The restart used the new bounded owner acknowledgement surface:

```sh
_build/default/ocaml/cli/c2c.exe restart b153-proof-ack --timeout 8
```

Result:

```text
exit: 0
[c2c restart] owner accepted in-place restart for 'b153-proof-ack' (idle-gated)
pid_before=1563003
pid_after=1563003
thread_before=019f5597-ceaa-7542-8cc0-2c14c6f76364
thread_after=019f5597-ceaa-7542-8cc0-2c14c6f76364
pane_before=railmap:3.1
pane_after=railmap:3.1
ledger_entries_before=1
ledger_entries_after=1
```

After another three seconds, the ledger still had exactly the same single
`injected` entry, with unchanged `first_seen` and `last_attempt`; no second
injection occurred. The pane showed a new authenticated endpoint and the same
thread reattached.

## Cleanup

The unit was stopped with:

```sh
./scripts/c2c_tmux.py keys railmap:3.1 C-c
```

PID `1563003` was verified dead before removing the isolated instance and
broker artifacts. No real peer or room received a test message.
