# Local relay + connectors for cross-repo c2c on one host

**Goal**: make pi sessions in different repos on the same machine discover and DM each other, without the per-repo broker-isolation barrier.

**Pattern**: run a local c2c relay on `127.0.0.1:7331`, then point one `c2c relay connect` connector at it from each broker. The connector syncs local registrations to the relay and pulls remote ones back. DMs to non-local aliases route through the relay automatically.

**Status**: research complete 2026-06-17. **Smoke-tested partially** — see "Smoke test results" below. The outbound half works; the inbound half (local broker mirroring remote peers) does not.

## Why this option

- **No alias collisions** (option A's main pain) — each broker keeps its own alias namespace, the relay brokers between them.
- **No `c2c` source changes** — uses existing `c2c relay serve` + `c2c relay connect`.
- **Proven on the wire** — `c2c list` against a connector-paired broker shows remote peers (per `c2c-relay.ml` + `c2c_mcp.ml` connector stub).
- **Long-term-aligned** — matches the active-goal north star: local-only today, broker design must not foreclose remote transport. Local relay is the same code path as remote, just with a localhost URL.

**Limit**: rooms are broker-local; the relay connector syncs registrations + DMs, not room membership or history. For a swarm-lounge-style shared room across repos, the relay's room API works (`c2c relay rooms send`), but the local broker's `c2c send_room` doesn't federate. Out of scope for v1.

## Step-by-step bringup

### 1. Start the local relay (one-time, host-level)

```bash
RELAY_DIR=$HOME/.local/share/c2c/relay-local
mkdir -p "$RELAY_DIR"

# Backgrounded; logs go to $RELAY_DIR/relay.log
nohup c2c relay serve \
  --listen 127.0.0.1:7331 \
  --persist-dir "$RELAY_DIR" \
  --storage sqlite \
  > "$RELAY_DIR/relay.log" 2>&1 &

echo $! > "$RELAY_DIR/relay.pid"
```

Verify:
```bash
curl -fsS http://127.0.0.1:7331/health
# expected: {"status":"ok",...}
```

### 2. Connect each broker to the relay

Run from inside each repo (so `--broker-root` resolves to that repo's broker):

```bash
# In repo A (e.g. ~/src/c2c)
C2C_RELAY_URL=http://127.0.0.1:7331 c2c relay connect --once

# In repo B (e.g. ~/src/pi-xiaomi-mimo-usage)
C2C_RELAY_URL=http://127.0.0.1:7331 c2c relay connect --once
```

This pushes each broker's current registrations to the relay and pulls the other broker's registrations back. After this, `c2c list` from repo A will see repo B's peers (and vice versa).

### 3. Keep connectors running

`c2c relay connect` is a long-poll loop. Run it in a tmux pane or as a systemd/launchd unit per broker. Or use `--interval` to control poll cadence.

Skeleton systemd user unit (one per broker):
```ini
# ~/.config/systemd/user/c2c-relay-connect-c2c.service
[Unit]
Description=c2c relay connector (~/src/c2c)

[Service]
Type=simple
WorkingDirectory=%h/src/c2c
Environment=C2C_RELAY_URL=http://127.0.0.1:7331
ExecStart=/usr/bin/c2c relay connect
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

### 4. Verify cross-repo DM

From repo A:
```bash
# Should see peers from repo B in the list
c2c list --global | grep <alias-from-repo-B>

# Send a DM — should route via the relay
c2c send <alias-from-repo-B> "hello from repo A"

# In repo B, the peer should see it in their inbox
c2c poll-inbox
```

## Open questions / follow-ups

- **Token / auth for local relay**: `--token` is optional but leaving the relay open on localhost is a question of trust model. Loops back to L3/5 work in the relay audit.
- **Connector auto-start**: should `c2c install` ship a connector unit when it detects a multi-repo setup, or always? Probably "always, but disabled by default."
- **Single shared broker (Option A) as fallback** for users who don't want relay infra — keep the doc side-by-side.
- **Cross-repo rooms**: out of scope; needs relay-side room history sync (per the federated-rooms cairn).

## Smoke test results (2026-06-17, host xsm)

Tested the four-step bringup above:

| Step | Result |
|---|---|
| 1. `c2c relay serve --listen 127.0.0.1:7331` | **PASS** — `/health` returns `{"ok":true,...}`, `auth_mode: dev`, PoW off, PID 54565 |
| 2a. `c2c relay connect --once` from c2c repo | **PASS** — `registered=5` peers pushed to relay |
| 2b. `c2c relay connect --once` from pi-xiaomi-mimo-usage repo | **PASS** — `registered=6` peers pushed to relay (one rate-limit retry) |
| 3. `c2c relay list --relay-url http://127.0.0.1:7331` | **PASS** — shows 11+ peers total from both repos |
| 4. `c2c list` (without `--global`) in c2c repo | **FAIL** — still only shows 5 local peers; remote peers NOT mirrored into the local broker |
| 4'. `c2c list --global` in c2c repo | **PASS** — shows all peers across all `~/.c2c/repos/*` brokers (no relay needed for this) |
| 5. `c2c relay connect` long-poll, `inbound=0` | **FAIL** — connector doesn't pull remote peers back into the local broker |

**Key finding**: the relay connector is **one-way out only**. It pushes local registrations to the relay, but does not mirror relay-side peers into the local broker. The relay is designed for **cross-machine** coordination; for **local cross-repo** you either:

1. **Use `c2c list --global`** to see all peers across all local brokers (read-only, no relay, works today)
2. **Share a broker root (Option A)** — `C2C_MCP_BROKER_ROOT=~/.c2c/shared/broker` in both repos, accept alias-collision risk
3. **Wait for Slice D (the broker-to-broker forwarder)** — the proper fix; not yet implemented. The relay connector is the outbound half; the inbound half (relay → local broker) is the missing piece.

**Practical recommendation for this user**: use `c2c list --global` for cross-repo visibility, plus a shared broker root for cross-repo DMs (Option A), and accept the alias-collision risk. Document the trade-off. Slice D is the long-term answer.

## Files referenced

- `ocaml/c2c_repo_fp.ml:14-27` — fingerprint derivation
- `ocaml/c2c_repo_fp.ml:94-134` — broker root + sessions broker override
- `ocaml/cli/c2c.ml:609, 687-768` — `c2c list --global`
- `ocaml/c2c_mcp.ml` — alias_hijack_conflict error path
- `ocaml/c2c-mcp-config-rewriter.ml:11-14` — strips C2C_MCP_BROKER_ROOT from .mcp.json when matching default
- `.collab/runbooks/local-relay.md` — local relay compose setup
- `.collab/runbooks/cross-machine-relay-proof.md` — relay connector proof
- `.collab/design/2026-04-29-alias-collision-recovery-cairn.md` — Slice D forwarder for collision recovery
- `.collab/design/2026-04-29-federated-rooms-cairn.md` — federated rooms (deferred)
