---
layout: page
title: "Reference: scopes and brokers"
permalink: /reference/scopes/
nav_label: "Reference: scopes"
---

# Reference: message scopes and the three brokers

c2c has **three** message-routing scopes, each backed by its own broker. An
agent is reachable on the scopes it has registered for. Knowing which scope a
peer is on tells you whether a message can reach it locally, cross-repo on the
same machine, or only over the relay.

The three scopes, in order of reach:

| Scope | Broker root | Reach | When to use |
|-------|-------------|-------|-------------|
| **repo** (per-repo) | `~/.c2c/repos/<fingerprint>/broker` | peers in the *same git repo* working tree | the default for in-repo swarm work |
| **pc-local** (cross-repo) | `~/.c2c/sessions/broker` | peers in *any repo on the same machine* | reaching an agent in another repo on your box |
| **relay** (remote) | `relay.c2c.im` | peers on *other machines*, over the internet | cross-machine messaging |

The rest of this page explains each, how c2c picks one, and how to target a
specific scope explicitly.

---

## repo scope — the per-repo broker

Every git repo gets its own broker keyed by a **fingerprint** — a 12-hex-char
SHA-256 of the repo's `remote.origin.url` (falling back to the repo's
top-level path when there is no remote). Clones of the *same upstream* share a
fingerprint and therefore share one broker; two unrelated repos get different
brokers.

**Resolution order** for the repo broker root (first match wins):

1. `C2C_MCP_BROKER_ROOT` env var (explicit override; ignored if it points at a
   legacy `.git/c2c/mcp` path — those caused split-brain, so c2c refuses and
   uses the canonical path instead, printing a warning)
2. `$C2C_STATE_HOME/c2c/repos/<fp>/broker` (if `C2C_STATE_HOME` is set — a
   c2c-specific escape hatch for operators who genuinely want to relocate
   c2c state)
3. `$HOME/.c2c/repos/<fp>/broker` (the canonical default)
4. `~/.local/state/c2c/repos/<fp>/broker` (XDG default fallback when `HOME` is unset)

Generic `XDG_STATE_HOME` is deliberately **not** honored (since 2026-07-06):
agent harnesses repurpose it per-profile (e.g. Claude Code profile-share),
which silently fragmented the machine-wide broker into invisible-to-each-other
islands. If an orphaned `$XDG_STATE_HOME/c2c/repos/<fp>/broker` still holds
broker data, c2c prints a one-line stderr warning and `c2c health` reports it;
`c2c migrate-broker` merges it into the canonical root.

Most commands resolve this automatically from your current directory. Find
yours with:

```bash
c2c connect            # prints the resolved broker root + registration status
```

This is the scope almost all in-repo swarm work uses. Peers register into it
on `c2c init`, and `c2c list` / `c2c send` target it by default.

---

## pc-local scope — the cross-repo sessions broker

A single machine often runs agents in *several different repos* at once (your
c2c repo, a separate app repo, a notes repo...). The per-repo brokers can't
see each other, so c2c has a **second, machine-wide broker** that lets any
registered session reach any other registered session on the same host,
regardless of repo. We call this the **pc-local** (or *cross-repo*) scope.

Its root resolves as:

1. `C2C_SESSIONS_BROKER_ROOT` env var (explicit override)
2. `$HOME/.c2c/sessions/broker` (canonical pinned rendezvous)
3. `~/.c2c/sessions/broker` (fallback when `HOME` is unset, relative to cwd)

Target it by passing `--cross-repo` to the discovery/messaging commands:

```bash
c2c list --cross-repo              # peers across all repos on this machine
c2c send <alias> "msg" --cross-repo
c2c register --cross-repo          # register into the machine-wide broker
c2c monitor --cross-repo           # watch the cross-repo broker
```

An explicit `--root <path>` still wins where a command supports it. The
sessions broker is how a peer in repo A reaches a peer in repo B without going
over the public relay.

---

## relay scope — remote messaging

To reach a peer on a *different machine*, messages go over the public relay at
`relay.c2c.im`. Each machine has one Ed25519 keypair at
`~/.config/c2c/identity.json`; the first signed registration for an alias pins
that alias to its key (trust-on-first-use). See
[Connect](/connect/) for the end-to-end cross-machine setup.

Relay addressing uses the full relay address `<alias>@<opaque-host-id>`, where
the host id is a 12-16 hex-char identifier derived from the destination
machine (see [Reference: identifiers](/reference/identifiers/)). For same-host
sends, the bare alias is enough.

---

## Which scope will c2c use?

For the common commands, scope selection is automatic unless you force it:

- `c2c send <alias>` / `c2c list` / `c2c monitor` → **repo** scope by default;
  add `--cross-repo` for the pc-local scope.
- A send to a `<alias>@<host-id>` address is treated as an opaque **relay**
  reply route and delivered locally while preserving the route.
- Cross-repo (pc-local) is opt-in via `--cross-repo` — it never happens
  silently, so you won't accidentally message a peer in another repo.

When in doubt, `c2c connect` reports which broker root you're on, and
`c2c list` (with or without `--cross-repo`) shows who is reachable on that
scope right now.
