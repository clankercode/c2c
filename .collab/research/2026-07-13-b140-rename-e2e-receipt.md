# B140 E2E receipt — live rename propagates to a peer's `c2c list`

Date: 2026-07-13 (AEST). Worktree: `.worktrees/b140-alias-rename` @ 7043f9cf.
Binary: freshly built `_build/default/ocaml/cli/c2c.exe`.

## Setup

Two real `c2c` processes in separate tmux panes (`tmux new-session -d -s
b140e2e` + split), isolated from the live swarm via a throwaway broker root:

```
export C2C_MCP_BROKER_ROOT=<scratch>/b140-e2e/broker
export C2C_KEY_DIR=<scratch>/b140-e2e/xkeys
# pane A: C2C_MCP_SESSION_ID=e2e-coord-sess
# pane B: C2C_MCP_SESSION_ID=e2e-peer-sess
```

- Pane A: `c2c register --alias e2e-coord-b140 && c2c rooms join b140-e2e-room`
- Pane B: `c2c register --alias e2e-peer-b140 && c2c rooms join b140-e2e-room`
- Pane B pre-rename `c2c list` showed `e2e-coord-b140` + `e2e-peer-b140`.

## Rename (pane A, live session, no restart)

```
❯ $CLI rename e2e-amaroo-coord
renamed e2e-coord-b140 -> e2e-amaroo-coord (session e2e-coord-sess)
  rooms updated: b140-e2e-room
```

## Peer observations (pane B, separate process)

```
❯ $CLI list
  e2e-amaroo-coord     unknown        <- new alias, old gone
  e2e-peer-b140        unknown
❯ $CLI rooms list
  e2e-peer-b140 (e2e-peer-sess)
  e2e-amaroo-coord (e2e-coord-sess)   <- room roster renamed
❯ $CLI poll-inbox
[c2c-system] e2e-coord-b140 renamed to e2e-amaroo-coord
  {"type":"peer_renamed","old_alias":"e2e-coord-b140","new_alias":"e2e-amaroo-coord"}
```

## Identity sticks for the live session (pane A, still no restart)

```
❯ $CLI send e2e-peer-b140 "hello from my new name"
ok -> e2e-peer-b140 (from e2e-amaroo-coord)
```

Pane B received `[e2e-amaroo-coord] hello from my new name`.

## Verdict

All B140 acceptance criteria exercised live: rename sticks across
registry + rooms (+ key files / pins / signers / archive marker covered by
unit tests), peers see the new alias without restart, the peer_renamed
notice fans out, and the renamed session keeps sending under the new
identity. Unsafe/implicit rename paths remain refused (B135 suite green,
error text now advertises `c2c rename`).
