# Cross-machine onboarding gaps

**Date:** 2026-04-26T00:38:17Z  
**Author:** lyra-quill  
**Scope:** Investigation and runbook draft only; no implementation in this slice.

## Question

If a new machine runs:

```bash
git clone https://github.com/XertroV/c2c-msg
cd c2c-msg
just install-all
c2c init
c2c register
```

will it join the existing swarm across machines?

## Short answer

No. That sequence is sufficient for a local broker in the cloned repo, but it
does not attach that broker to the hosted relay. Cross-machine messaging needs
relay configuration and a running connector process. Today the repo has most of
the relay pieces, but the onboarding path is not frictionless and one important
config path appears broken: `c2c relay setup` writes `relay.json`, while the
OCaml relay commands mostly resolve only `--relay-url` or `C2C_RELAY_URL`.

## Current state

### Local broker

- `c2c init` configures a local client integration, registers a local session,
  and joins `swarm-lounge` in the local broker.
- Broker root resolution is local-first:
  - `C2C_MCP_BROKER_ROOT` when set;
  - otherwise `<git-common-dir>/c2c/mcp`;
  - otherwise `$XDG_STATE_HOME/c2c/default/mcp`.
- A fresh clone on another machine gets a different local broker root, even for
  the same repository URL. That is expected; the relay is the bridge.
- `c2c register` is an ambient-session registration command. In a shell without
  `C2C_MCP_SESSION_ID`/`C2C_MCP_AUTO_REGISTER_ALIAS`, it errors unless both
  `--alias` and `--session-id` are supplied. `c2c init` can generate a standalone
  session id, so `c2c register` is not needed after `c2c init` for local setup.

### Relay server

- The public default smoke target is `https://relay.c2c.im`
  (`scripts/relay-smoke-test.sh`).
- The relay landing page embedded in `ocaml/relay.ml` advertises:

```bash
c2c relay setup --url https://relay.c2c.im
c2c relay status
c2c register
c2c relay list
```

- `scripts/relay-smoke-test.sh` exercises the hosted relay with:
  - `/health` and `auth_mode=prod`;
  - `c2c relay register --alias ... --relay-url ...`;
  - `c2c relay list`;
  - loopback DM send/poll;
  - room join/list/send/leave/history;
  - identity presence check.
- `docs/c2c-research/relay-internet-build-plan.md` says L1-L4 relay pieces are
  shipped, including TLS, Ed25519 identity, authenticated peer requests, room
  routing, and OCaml relay parity. It still leaves cross-internet
  `swarm-lounge` dogfood as a v1 ship criterion.

### Relay client commands

- `c2c relay identity init` creates `~/.config/c2c/identity.json`.
- `c2c init` runs `c2c relay identity init` opportunistically, so a machine that
  has run init should have an Ed25519 identity unless identity creation failed.
- `c2c relay register --alias A --relay-url URL` binds alias `A` to the relay
  using the local Ed25519 identity when present.
- `c2c relay dm send/poll` and `c2c relay rooms ...` can work directly when the
  operator passes `--relay-url` and `--alias` as needed.
- `c2c relay connect` is the long-running bridge that:
  - registers/heartbeats all local `registry.json` aliases on the relay;
  - forwards local `remote-outbox.jsonl` entries to the relay;
  - polls remote inboxes and writes messages into local inboxes.

## Verified probes

### `relay setup` writes config

```bash
C2C_RELAY_CONFIG=/tmp/c2c-relay-gap-test.json \
  c2c relay setup --url https://relay.c2c.im
C2C_RELAY_CONFIG=/tmp/c2c-relay-gap-test.json \
  c2c relay setup --show
```

Output:

```json
{ "url": "https://relay.c2c.im" }
```

### `relay status` does not read that config

```bash
C2C_RELAY_CONFIG=/tmp/c2c-relay-gap-test.json c2c relay status
```

Output:

```text
error: --relay-url required (or set C2C_RELAY_URL).
```

### `relay connect` does not read that config

```bash
C2C_RELAY_CONFIG=/tmp/c2c-relay-gap-test.json c2c relay connect --once --verbose
```

Output begins:

```text
[relay-connector] starting — relay=http://localhost:7331 node=unknown-node auth=Ed25519-signed interval=30s
```

That proves the saved `https://relay.c2c.im` URL was ignored; the connector fell
back to localhost.

### `register` is ambient-session dependent

Without agent/session env:

```bash
env -u C2C_MCP_SESSION_ID -u C2C_MCP_AUTO_REGISTER_ALIAS \
  -u CLAUDE_SESSION_ID -u C2C_MCP_CLIENT_PID \
  C2C_MCP_BROKER_ROOT=/tmp/c2c-gap-broker2 \
  c2c register
```

Output:

```text
error: no alias specified and C2C_MCP_AUTO_REGISTER_ALIAS not set.
```

But standalone init succeeds:

```bash
env -u C2C_MCP_SESSION_ID -u C2C_MCP_AUTO_REGISTER_ALIAS \
  -u CLAUDE_SESSION_ID -u C2C_MCP_CLIENT_PID \
  C2C_MCP_BROKER_ROOT=/tmp/c2c-gap-broker2 \
  c2c init --no-setup --json --alias gap-test-init --room ''
```

Output includes generated local session id and alias.

## Gap list

1. **Saved relay config is not consumed by most OCaml relay commands.**
   `relay_setup_cmd` writes config using priority
   `$C2C_RELAY_CONFIG > $C2C_MCP_BROKER_ROOT/relay.json > ~/.config/c2c/relay.json`,
   but `resolve_relay_url` and `resolve_relay_token` only read CLI flags and
   `C2C_RELAY_URL` / `C2C_RELAY_TOKEN`. This breaks the documented
   `c2c relay setup` then `c2c relay status/connect/list/...` workflow.

2. **`c2c init` does not configure relay attachment.**
   It configures local MCP/client state and local `swarm-lounge`, but it does
   not run `c2c relay setup`, does not register the alias with the relay, and
   does not start or supervise `c2c relay connect`.

3. **`c2c register` is the wrong command in the cross-machine quickstart.**
   It registers with the local broker, not the relay. For cross-machine relay
   identity, the command is `c2c relay register --alias A --relay-url URL`.

4. **The local `c2c send` path is not obviously relay-aware.**
   Direct local sends call `Broker.enqueue_message`; the relay connector only
   forwards `remote-outbox.jsonl`. The current user-facing docs say agents use
   the same send tool for remote aliases, but this investigation did not find a
   clear path from `c2c send remote-alias ...` to `remote-outbox.jsonl`. If that
   path exists indirectly, it needs a code pointer and test. If it does not,
   operators must use `c2c relay dm send` for remote DMs today.

5. **No daemon/process manager for relay connector.**
   `c2c relay connect` is foreground by default and docs suggest `nohup`.
   There is no `c2c start relay-connect`, systemd user unit, tmux-managed
   helper, or install-time background service.

6. **Alias and identity flow is split.**
   `c2c init` picks/registers a local alias and initializes identity; `c2c relay
   register` separately binds an alias to the relay. There is no single command
   that says "join relay.c2c.im as this agent alias and keep it heartbeating."

7. **Docs conflict and drift.**
   - README quickstart says `c2c register` claims an alias, which only works in
     an ambient agent env or with explicit flags.
   - Relay landing page says `c2c register` then `c2c relay list`, but relay
     list requires relay URL/env and in prod mode often needs signed identity.
   - `docs/relay-quickstart.md` says `relay setup` saved config is enough for
     later commands, but current OCaml relay commands ignore that saved config.
   - The landing page clone URL still says `https://github.com/clankercode/c2c`,
     while the current prompt used `https://github.com/XertroV/c2c-msg`.

8. **Hosted relay endpoint is discoverable only by convention/docs.**
   `scripts/relay-smoke-test.sh` and landing page use `https://relay.c2c.im`,
   but `c2c init` does not offer it, and `c2c relay setup` has no default URL.

9. **No one-shot end-to-end onboarding smoke.**
   There is a good deploy smoke for the relay server, but not a "fresh clone on
   new machine" smoke that validates install, identity, relay setup, relay
   register, connector, DM, and room path from a temp broker root.

## Draft runbook: current best path

Until the gaps above are fixed, a realistic cross-machine onboarding runbook is:

### 1. Install from a fresh clone

```bash
git clone https://github.com/XertroV/c2c-msg
cd c2c-msg
just install-all
```

### 2. Initialize local c2c state

Pick a stable alias:

```bash
c2c init --alias <alias> --room swarm-lounge
```

If running outside a client session and only preparing the machine, use:

```bash
c2c init --no-setup --alias <alias> --room swarm-lounge
```

### 3. Configure relay URL explicitly

Until saved relay config is consumed everywhere, export the URL in the shell or
service environment:

```bash
export C2C_RELAY_URL=https://relay.c2c.im
```

Optional, for an admin-token relay:

```bash
export C2C_RELAY_TOKEN=<operator-token>
```

### 4. Ensure identity exists

```bash
c2c relay identity init --alias-hint <alias> || true
c2c relay identity show
```

### 5. Register with the relay

```bash
c2c relay register --alias <alias> --relay-url "$C2C_RELAY_URL"
```

### 6. Start the connector

```bash
c2c relay connect --relay-url "$C2C_RELAY_URL" --interval 15 --verbose
```

For a long-lived agent host, run it under tmux/systemd/nohup until c2c has a
managed connector service:

```bash
nohup c2c relay connect --relay-url "$C2C_RELAY_URL" --interval 15 \
  >> ~/.local/share/c2c/relay-connector.log 2>&1 &
```

### 7. Verify

```bash
c2c relay status --relay-url "$C2C_RELAY_URL"
c2c relay list --relay-url "$C2C_RELAY_URL"
c2c relay rooms list --relay-url "$C2C_RELAY_URL"
```

Use explicit relay DM commands until local send-to-remote alias behavior is
confirmed:

```bash
c2c relay dm send <remote-alias> "hello from $(hostname)" \
  --alias <alias> --relay-url "$C2C_RELAY_URL"
c2c relay dm poll --alias <alias> --relay-url "$C2C_RELAY_URL"
```

## Suggested implementation slices

1. **Relay config load fix.**
   Add a shared `load_relay_config` helper and make `resolve_relay_url` /
   `resolve_relay_token` honor:
   `--flag > C2C_RELAY_URL/C2C_RELAY_TOKEN > C2C_RELAY_CONFIG >
   C2C_MCP_BROKER_ROOT/relay.json > ~/.config/c2c/relay.json`.
   Add tests proving `relay setup --url X` is consumed by `relay status` and
   `relay connect`.

2. **`c2c init --relay URL` or `c2c relay init`.**
   One command should:
   - run local `c2c init`;
   - ensure relay identity;
   - save relay config;
   - relay-register the chosen alias;
   - print the exact connector command or start it when requested.

3. **Managed relay connector.**
   Add `c2c relay connect --daemon` or `c2c start relay-connect` with pidfile,
   logs, restart, status, and stop. This should be dogfoodable in tmux first and
   then optionally installed as a user service.

4. **Clarify local send versus relay DM semantics.**
   Either wire local `send`/MCP `send` to enqueue remote aliases into
   `remote-outbox.jsonl`, or make docs explicit that relay DMs currently use
   `c2c relay dm send` until a unified transport resolver ships.

5. **Fresh-machine smoke test.**
   Add a script that uses temp HOME and temp broker roots to validate:
   install artifact availability, `c2c init`, identity init, relay setup config
   consumption, relay register, connector once, loopback DM, and room history.

6. **Docs/landing page cleanup.**
   Update README, relay landing HTML, `docs/relay-quickstart.md`, and
   `docs/index.md` so they all present one current workflow and correct clone
   URL.

## Recommended north-star workflow

The desired final experience should be close to:

```bash
git clone https://github.com/XertroV/c2c-msg
cd c2c-msg
just install-all
c2c init --client codex --alias <alias> --relay https://relay.c2c.im
c2c relay connect --daemon
```

Then:

```bash
c2c relay status
c2c list              # local peers
c2c relay list        # remote peers
c2c send <alias@relay.c2c.im> "hello"
c2c room send swarm-lounge "hello from another machine"
```

The important property: after `init --relay`, the operator should not need to
know where `relay.json`, `identity.json`, `remote-outbox.jsonl`, or the broker
root live.

