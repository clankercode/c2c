# Dogfood: cross-repo `poll-inbox` can't resolve a live peer's session — drain step of the recipe is broken

**Date:** 2026-06-20
**Dogfooder:** `cc-pi-c2c` (Claude Code in pi-c2c, a non-pi CLI client), with `pi-2315bf`.
**Severity:** medium — it makes the *documented* CLI live-peer recipe fail at its final step, so DMs silently pile up undrained.

## What happened

`pi-2315bf` ran a direct-DM smoke test (4 DMs over 17:15–17:39). All 4 **delivered** correctly — direct cross-repo send→receive works both ways. But they sat **undrained** in my inbox: my live-inbox monitor kept notifying me of each arrival (count climbing 1→4), yet I had **no working drain command**.

The recipe's drain step — `c2c poll-inbox` (with `C2C_MCP_BROKER_ROOT` pointed at the sessions broker) — fails:

```
$ C2C_MCP_BROKER_ROOT=$HOME/.c2c/sessions/broker c2c poll-inbox --json
error: cannot determine session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.
```

To actually drain I had to reverse-engineer my own session id out of `c2c list` (`cc-pi-c2c → cc-pi-c2c-coord`) and pass it explicitly.

## Root cause: the drain path is inconsistent with the rest of the CLI

`list` / `send` / `register` / `monitor` all accept `--cross-repo` (sugar for the sessions broker root) and `--alias` (to name the peer). **`poll-inbox` / `peek-inbox` accept neither** — their only handles are `--session-id=ID` and `C2C_MCP_SESSION_ID`:

```
$ c2c peek-inbox --cross-repo --alias cc-pi-c2c
c2c: unknown option --cross-repo  unknown option --alias
$ c2c poll-inbox --help
  c2c poll-inbox [--json] [--peek] [--session-id=ID] [OPTION]…
```

So a peer that registered/monitors by **alias** has no alias-keyed way to read its own inbox — even though the alias→session_id mapping is right there in the broker registration. There is no `--cross-repo` sugar either, so you must hand-set `C2C_MCP_BROKER_ROOT`.

## Verified working drain (today, with no code change)

```sh
C2C_MCP_BROKER_ROOT="$HOME/.c2c/sessions/broker" \
  c2c poll-inbox --session-id <my-session-id>      # --peek to inspect non-destructively
```

…where `<my-session-id>` is the id the peer registered under. The peer only knows that id if it set a stable `C2C_MCP_SESSION_ID` at register time (else look it up via `c2c list`).

## Fixes (c2c — pi-2315bf / maintainer)

1. **Code — add `--cross-repo` to `poll-inbox`/`peek-inbox`** (sugar for the sessions broker root), matching `list`/`send`/`register`/`monitor`. Removes the manual `C2C_MCP_BROKER_ROOT` dance.
2. **Code — add `--alias <a>` to `poll-inbox`/`peek-inbox`** that reverse-looks-up the session id from the broker registration. Then a live peer drains with `c2c poll-inbox --cross-repo --alias <me>` — no session-id juggling, and the recipe is uniform with `monitor --alias` / `register --alias`. (This also makes the proposed `c2c agent`/`register --keepalive` one-shot trivially driveable.)
3. **Docs (interim, works today) — fix the recipe's drain step.** The getting-started / commands / llms.txt recipe currently says "call `c2c poll-inbox` when the monitor fires," which fails. Until (1)+(2) land, the recipe must either:
   - establish a **stable `C2C_MCP_SESSION_ID`**, `export` it, and reuse it for `register` + `monitor` + `poll-inbox` (then bare `poll-inbox` resolves it from the env); **or**
   - show the explicit `C2C_MCP_BROKER_ROOT=… c2c poll-inbox --session-id <id>` form and how to find `<id>` via `c2c list`.

## Cross-refs

- Builds on `2026-06-20-cross-repo-cli-peer-setup-dogfood.md` (the live-peer recipe). That recipe's step (c) "poll-inbox on each event" is the step this finding shows to be incomplete.
