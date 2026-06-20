# Friction: reaching a cross-repo peer from the c2c CLI (non-pi client)

**Date:** 2026-06-20
**Reporter:** `cc-pi-c2c` (Claude Code coordinating from the `pi-c2c` repo, dogfooding c2c)
**Context:** Needed to message `pi-2315bf` (a pi session in *this* repo) from a session
in a *different* repo (`pi-c2c`), using the raw `c2c` CLI (not the pi-c2c extension's
tools). Cross-repo peers rendezvous on the **sessions broker**
(`~/.c2c/sessions/broker`), separate from each repo's per-repo broker.

## Friction 1 — no first-class way to target the sessions broker

To see/reach a peer in another repo I had to:
1. *Discover* that cross-repo peers live on `~/.c2c/sessions/broker`.
2. Manually `export C2C_MCP_BROKER_ROOT=~/.c2c/sessions/broker` for every
   `list` / `send` / `monitor` invocation.

The default per-repo `c2c list` just printed **"No registered peers"** with no hint that
peers exist on the sessions broker. `c2c list --global` *did* surface `pi-2315bf` (with its
repo fingerprint), which is how I found it — but `--global` scans everything; there's no
"just the cross-repo sessions broker" mode, and `send`/`monitor` have no equivalent.

## Friction 2 — `send --from <alias>` rejected without a matching session id

After `c2c register --alias cc-pi-c2c --session-id cc-pi-c2c-coord` (on the sessions
broker), `c2c send --from cc-pi-c2c pi-2315bf "..."` was refused:

> refusing to send as 'cc-pi-c2c': that alias is registered to a different session
> (not your identity). Set C2C_COORDINATOR=1 to relay on behalf of another agent,
> or send as your own alias.

The fix was to also `export C2C_MCP_SESSION_ID=cc-pi-c2c-coord` so `send` resolved *my*
identity (then `--from` is redundant). The identity binding is correct/secure, but the
`--from` flag reads like "send as this alias", and the error's `C2C_COORDINATOR=1` hint
points at the relay path rather than the common "I am this alias" case.

## Proposed fix — a `--cross-repo` flag (Max endorsed)

Add `--cross-repo` (alias e.g. `--sessions`) to `list`, `send`, `monitor` (and
`register`) that auto-resolves the sessions broker root, so **all the broker config is
handled automatically** — no manual `C2C_MCP_BROKER_ROOT` export. E.g.:

```
c2c list   --cross-repo
c2c send   --cross-repo pi-2315bf "..."
c2c monitor --cross-repo --alias cc-pi-c2c --all --archive
```

Smaller, complementary improvements:
- Per-repo `c2c list` empty output could hint: *"no peers in this repo; N alive on the
  sessions broker — try `c2c list --cross-repo` (or `--global`)."*
- Soften the `send` identity error for the common case: if `--from <alias>` names an alias
  registered to a session on the target broker and no other identity is resolvable, suggest
  setting `C2C_MCP_SESSION_ID` (the "I am this alias" path) before the `C2C_COORDINATOR=1`
  relay path.

## Repro

```sh
# from another repo:
c2c list                       # -> "No registered peers" (misleading)
c2c list --global | grep peer  # -> found, but global scans everything
export C2C_MCP_BROKER_ROOT=~/.c2c/sessions/broker
export C2C_MCP_SESSION_ID=cc-pi-c2c-coord
c2c register --alias cc-pi-c2c --session-id cc-pi-c2c-coord
c2c send --from cc-pi-c2c pi-2315bf "hi"   # -> refused until C2C_MCP_SESSION_ID set
c2c send pi-2315bf "hi"                    # -> ok once identity resolves
```
