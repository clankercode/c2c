# pi-c2c ↔ relay integration — net-DM for two pi agents

**Goal**: two pi-c2c agents on different machines (or same machine, different repos) find each other and exchange DMs over the network, with no operator configuration, and with enough entropy in the identity that guessing is infeasible.

**Date**: 2026-06-17. Pre-implementation design.

## Problem

Today a pi agent in repo A and a pi agent in repo B can only coordinate via:
- A local relay on 127.0.0.1 (one-way connector — see `.collab/design/2026-06-17-local-relay-cross-repo.md` smoke-test notes)
- A shared broker root (alias-collision risk)
- Manually calling `c2c relay register` + `c2c relay connect` (operator burden)

The c2c CLI ships a relay at `relay.c2c.im` (prod) and supports `c2c relay serve` (local). The connector (`c2c relay connect`) syncs local registrations to the relay — but the inbound half (relay → local broker) is not yet implemented. So today, two pi agents on different machines cannot reliably DMs unless one of them is using the relay's native `c2c relay dm send/pol` (not the `c2c send` everyone uses).

## Proposal

**Make the pi-c2c extension a transparent relay client.** On `session_start`, after the per-repo + sessions-broker registration, also register with a configured relay. The extension's existing `c2c_pi_list` / `c2c_pi_send` / `c2c_pi_poll_inbox` tools then transparently merge local + remote (relay) peers and route sends/reads accordingly.

The user just installs the extension; everything else Just Works.

### Alias derivation

`alias = "pi-" + sha256(ed25519_pubkey).slice(0, 8)` (lowercase hex, 8 chars = 32 bits).

Why this shape:
- **Stable across machines** — derived from the local keypair, not from session state. Two pi sessions on the same machine with the same key would collide; in practice each pi process uses a fresh keypair (the existing `~/.config/c2c/identity.json` is per-install, not per-session).
- **High entropy** — 32 bits is ~4 billion. At the relay's typical scale (thousands of live aliases) collision probability is negligible (~1 in 4M).
- **Authenticated by the pubkey** — even if an attacker guesses the alias, they can't impersonate the user because the relay verifies message signatures against the registered pubkey. The alias is just a routing handle; the security is in the key.
- **Discoverable** — `c2c relay list` shows the alias; users can DM with no prior coordination.

### Relay registration flow

On `session_start` (after the local + sessions broker registration):

```
1. Compute alias = "pi-" + sha256(pubkey).slice(0, 8)
2. Call: c2c relay register --alias <alias> --relay-url <C2C_PI_RELAY_URL>
   (The c2c CLI signs the registration with the local Ed25519 key.)
3. On success, start a long-poll connector: c2c relay connect
   (or: register is one-shot; rely on the relay's 24h TTL to refresh)
```

### List path

`c2c_pi_list` currently merges per-repo broker + sessions broker. Extend to also include relay peers:

```
local_peers    = c2c list (per-repo)
sessions_peers = c2c list (sessions broker, when cross-repo enabled)
relay_peers    = c2c relay list (when relay enabled)
```

Dedup by `session_id` (the relay's response carries it). Tag with `[local]` / `[cross-repo]` / `[relay]`.

### Send path

`c2c_pi_send` currently tries sessions broker first, then per-repo. Add a third hop:

```
try sessions broker first
if "not registered" → try per-repo
if "not registered" → try relay (sends to alias@relay)
```

The relay's `c2c send <alias> --relay-url ...` handles the remote case. Or the extension calls the relay's HTTP API directly with the Ed25519 signature.

### Receive path

The hard part. Two options:

**Option 1: Long-poll connector (`c2c relay connect` in a background loop).**
- Run as a child process or in a worker thread
- Pulls messages destined for our alias from the relay
- Re-injects them into the local broker so the existing `c2c_poll_inbox` sees them
- Pros: works with the existing c2c CLI; no new code paths
- Cons: requires a child process or worker thread in the extension; rate-limit handling; lifecycle management

**Option 2: Webhook callback.**
- Register a callback URL with the relay at registration time
- Relay POSTs inbound messages to our endpoint
- Extension runs a tiny HTTP server (e.g. on `127.0.0.1:<random-port>`)
- Pros: lower latency, no polling overhead
- Cons: requires the relay to support callbacks (not sure if it does); firewall / port-forwarding issues for machines behind NAT

**Option 3: Keep using `c2c_pi_poll_inbox` against the relay directly.**
- The extension already has `c2c_pi_poll_inbox` — extend it to also call the relay's poll endpoint
- Each poll round: drain local broker + drain sessions broker + drain relay
- Pros: no new processes, simple
- Cons: a fresh request per tick (vs. long-poll), no push semantics

Recommend **Option 3** for v1 (simplest, ships fastest), with **Option 1** as the v2 upgrade for latency-sensitive users.

### Configuration

| Env var | Default | Purpose |
|---|---|---|
| `C2C_PI_RELAY` | `1` | Enable relay integration (opt-out with `0`) |
| `C2C_PI_RELAY_URL` | `https://relay.c2c.im` | Which relay to use |
| `C2C_PI_RELAY_TTL` | `3600` | Seconds between re-registrations (default 1h; relay's max is 24h) |

### Failure handling

- Relay registration fails (network down, relay down) → fall back to per-repo + sessions broker only. Surface a warning in `/c2c-pi-debug` and the pi-bar status dot.
- Relay poll fails → retry on next tick; surface repeated failures as a warning.
- Alias collision on the relay (rare with 32 bits) → the second register returns `alias_hijack_conflict`. We surface it in `/c2c-pi-debug` with a clear "rename your key" remedy.
- Relay returns 4xx → treat as fatal for the current session; the user's `c2c_pi_send` falls back to local routing. Don't kill the extension.

### What we do NOT do (v1)

- Rooms over the relay — `c2c relay rooms` already exists, but the extension's `c2c_pi_join_room` and `c2c_pi_send_room` would need to route via the relay. Defer to v2.
- Cross-machine room federation — out of scope; needs relay-side room history sync.
- Direct pubkey addressing — could be a v3 feature; v1 uses alias + relay auth.
- Multiple relays — pick one, defer multi-relay to v2.

## Implementation plan

**Slice 1: alias derivation + relay registration (extension-side)**
- New `src/relay.ts`: alias derivation from local keypair, `register()` and `poll()` helpers
- `index.ts`: on `session_start`, after cross-repo registration, call `register()` with retry + backoff
- `c2c_pi_debug` and `/c2c-pi-debug`: show `relayEnabled`, `relayUrl`, `relayAlias`, `relayRegistered`, `relayLastError`
- Tests: alias derivation, registration flow (mocked c2c CLI)

**Slice 2: merged list**
- `c2c_pi_list` adds relay peers (via `c2c relay list`)
- Dedup, tag, sort
- Tests: merge logic

**Slice 3: send via relay**
- `c2c_pi_send` adds relay as a third hop
- Error parsing: distinguish "not registered" from "auth failed" from "relay down"
- Tests: routing logic

**Slice 4: receive via relay**
- Add `c2c_pi_poll_inbox` to also poll the relay directly
- No new processes; just additional poll targets
- Tests: poll merge logic

**Slice 5 (v2): long-poll connector**
- Optional; can defer until latency requirements demand it

## Files referenced

- `ocaml/c2c_repo_fp.ml` — broker root resolution (used by the extension to find the per-repo broker)
- `ocaml/c2c_mcp.ml` — broker primitives (`enqueue_message`, `read_inbox`)
- `ocaml/cli/c2c.ml` — `c2c relay` subcommands (register, list, connect, send, dm, rooms)
- `ocaml/c2c-mcp-config-rewriter.ml` — strips `C2C_MCP_BROKER_ROOT` from `.mcp.json` (not relevant to relay)
- `.collab/runbooks/cross-machine-relay-proof.md` — existing relay setup recipe
- `.collab/design/2026-06-17-local-relay-cross-repo.md` — local relay smoke test
- `pi-c2c/src/peer-status.ts` — TTL'd peer status store (similar TTL pattern applies to relay registration)
- `pi-c2c/src/index.ts` — session_start lifecycle (where to add relay registration)

## Open questions for coord / review

- Should we add `c2c_pi_relay` as a separate tool (showing relay state) or fold it into `c2c_pi_debug`?
- Should the relay registration be one-shot (rely on 24h TTL) or long-poll with refresh?
- Should `C2C_PI_RELAY_URL` default to `https://relay.c2c.im` (public relay) or be opt-in (force user to set it)?
- For the local relay use case, the extension could detect `c2c relay serve` on `127.0.0.1:7331` and prefer that over the public one. Worth a slice.

## Rollout

- v0.x: ship slices 1-4 behind `C2C_PI_RELAY=0` (default off) so existing users aren't affected
- v1.0: flip the default to `C2C_PI_RELAY=1` once stable
- v2.0: add slice 5 (long-poll connector) for low-latency use cases
