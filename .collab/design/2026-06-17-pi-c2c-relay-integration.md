# pi-c2c ↔ relay integration — net-DM for two pi agents

**Goal**: a pi-c2c agent in repo A on host X and a pi-c2c agent in repo B on host Y can find each other and exchange DMs over the network with no per-machine config beyond the relay URL. The existing per-repo + sessions broker paths stay as fallbacks.

**Date**: 2026-06-17. Pre-implementation design. Co-authored with `pi-313d8c` (parallel session) — see "Slice split" below.

**Revision note (2026-06-17)**: the first-pass design (commit `2fe320f1`) invented a sidecar metadata scheme on relay registration. That was wrong. We do NOT need a sidecar — `canonical_alias` already encodes the per-broker `<alias>#<repo>@<host>` provenance, the relay's `RegistrationLease.to_json` (`ocaml/relay.ml:184-217`) already carries `alias`, `client_type`, `registered_at`, `last_seen`, `ttl`, `identity_pk` per peer, and Ed25519 pubkey fingerprint comes from `c2c relay identity show --json`. This revision drops the sidecar and the new subcommand, and only documents the extension-side flow.

## Problem

Today a pi agent in repo A and a pi agent in repo B can only coordinate via:

- A shared per-repo broker (alias-collision risk) or a shared broker root
- The local relay on 127.0.0.1 (one-way connector — see `.collab/design/2026-06-17-local-relay-cross-repo.md` smoke test: the connector pushes local registrations to the relay but does NOT mirror relay peers back into the local broker)
- The relay's native `c2c relay dm send/poll` (works, but bypasses the extension's existing `c2c_pi_send` / `c2c_pi_poll_inbox` tools)

The c2c CLI ships a relay at `relay.c2c.im` (prod) and supports `c2c relay serve` (local). Ed25519-signed register/list/dm are all live (`ocaml/test/test_relay_e2e.ml` + `.collab/runbooks/cross-machine-relay-proof.md` — 11/11 smoke green on prod 2026-04-21). The relay is a usable cross-machine transit; what's missing is making pi-c2c use it transparently.

## What we leverage (do NOT reinvent)

| Need | Existing primitive | Source |
|---|---|---|
| Identity (Ed25519 keypair) | `c2c relay identity init/show/fingerprint` (writes `~/.config/c2c/identity.json`) | `ocaml/cli/c2c.ml:5606-5716` (show at `5640-5685`) |
| Alias ↔ pubkey binding on the relay | `c2c relay register --alias X --relay-url URL` (signs with local Ed25519) | `ocaml/cli/c2c.ml:5027-5063`; HTTP handler at `ocaml/relay.ml:2677+` |
| Cross-machine DM transport | `c2c relay dm send / poll / send-all` (signs with local Ed25519 when identity.json exists) | `ocaml/cli/c2c.ml:5065-5220` |
| Discover peers on the relay | `c2c relay list` (signed `/list`; returns `RegistrationLease.to_json` per peer) | `ocaml/cli/c2c.ml:4755-4790`; lease JSON shape at `ocaml/relay.ml:184-217` |
| Per-broker "link alias to agent and machine" | `canonical_alias` = `<alias>#<repo-slug>@<short-hostname>`, auto-populated on broker `register` | `ocaml/c2c_broker.ml:1721` (compute) + `:1980` (auto-populate); exposed via MCP registration JSON |
| Cross-host routing gate | `host_acceptable ~self_host` in the relay's send handler | `ocaml/relay.ml:436-439` + handler at `ocaml/relay.ml:3601-3645` |
| Relay URL resolution (3-way) | `--relay-url` flag → `$C2C_RELAY_URL` env → saved `c2c relay setup` config | `ocaml/cli/c2c.ml:4563-4569` |

**Identity model**: one Ed25519 keypair (`~/.config/c2c/identity.json`, generated once per host) is used to sign every `c2c relay` operation that requires auth. A single key can register many aliases across many brokers (one per repo) — each registration is just an `<alias, pubkey>` binding at the relay, and the per-broker `canonical_alias` ties the local alias back to `(repo, host)`. Re-registering with the same alias+pubkey is idempotent (the relay updates the lease in place).

**Alias shape**: `pi-<first-6-hex-of-sha256(pubkey)>` — short, deterministic, recognizable. Derivation is a one-liner in the extension using the `public_key` field of `c2c relay identity show --json`. We do not need a new CLI subcommand for this. (The existing per-broker `canonical_alias` separately gives the fully-qualified form `<alias>#<repo>@<host>` for relay↔local disambiguation.)

## Slice split (agreed with pi-313d8c)

| Slice | Owner | Scope |
|---|---|---|
| **Slice 1** | `pi-313d8c` | Typed wrappers in `pi-c2c/src/c2c-cli.ts` for `relay identity / list / register / dm-poll / dm-send / dm-send-all` + JSON parsers + unit tests. Pure extension-side; no c2c CLI changes. |
| **Slice 2** | us (this slice) | Extension integration: register on `session_start`, merge relay peers into `c2c_pi_list`, try relay as a third hop in `c2c_pi_send`, drain relay DMs in `pollTick`, surface in `/c2c-pi-debug`. See "Slice 2 implementation" below. |

This doc covers **slice 2**. Slice 1 is mechanical; the wire contracts the extension relies on are documented in the table above.

## Slice 2 implementation

### A. `session_start` — register on the relay

Order on session start (after per-repo + sessions broker register, before opening the poll loop):

```
1. resolve relay URL:  C2C_RELAY_URL  ||  C2C_PI_RELAY_URL (override)  ||  (default null → skip)
2. identity = `c2c relay identity show --json`  (best-effort; runs `c2c relay identity init` if missing)
3. alias     = `pi-` + sha256(identity.public_key).hex.slice(0, 6)
4. register  = `c2c relay register --alias <alias> --relay-url <url>`
              (signed; relay binds alias → pubkey, returns lease + ttl)
5. capture  relay alias, lease TTL, identity fingerprint, last error → debug state
```

Failure handling:
- No `C2C_RELAY_URL` / `C2C_PI_RELAY_URL` set → skip silently. The extension keeps working with per-repo + sessions broker only.
- `identity show` fails (no `~/.config/c2c/identity.json`) → call `c2c relay identity init` and retry. If that fails, skip relay integration for this session and surface in `/c2c-pi-debug`.
- `register` returns `alias_hijack_conflict` (alias taken) → surface as a warning; fall back to per-repo + sessions broker only. Operator must rename or rotate the key. (Doesn't crash the session.)
- `register` returns network/HTTP error → store `relayLastError`, schedule a single retry on the next 5-minute heartbeat tick. (Don't tight-loop during `session_start`.)

TTL refresh: a `c2c relay connect` connector would re-register on a cadence, but for v1 the extension just relies on the relay's 24h lease TTL. If the lease expires, the next `c2c relay list` / `c2c relay dm poll` will fail; we re-register then (transparently — same code path as the first register).

### B. `c2c_pi_list` — merge local + sessions + relay

```
local_peers    = cli.list()                                         (per-repo broker)
sessions_peers = cli.list({ brokerRoot: sessionsBrokerRoot })       (cross-repo sessions broker, if enabled)
relay_peers    = cli.relayList({ relayUrl, signed: true })          (relay; signed /list)
```

Merge rules:
1. **Primary dedup key**: `canonical_alias` (when present, from per-broker registration JSON). Peers on the same broker on the same host with the same alias are the same peer.
2. **Secondary dedup key**: `(session_id, client_type)` for peers that don't have a canonical_alias (e.g. the relay's lease JSON has `session_id` but no canonical_alias).
3. Tag each peer with its source: `[local]`, `[cross-repo]`, or `[relay]`. A peer reachable via two sources shows as a single row with both tags.
4. Sort: by source priority (local first, then cross-repo, then relay), then by alias.

`c2c_pi_list` returns the existing `C2cPeer` shape with one extra optional `sources: string[]` field. The renderer adds a `[relay, xsm]` annotation when the source is the relay (uses `relay_peers.lease.client_type` / `last_seen`).

The existing `parsePeers` parser (`pi-c2c/src/c2c-cli.ts`) covers per-repo and sessions broker output. Slice 1's `parseRelayPeers` handles the relay's nested shape:

```jsonc
// c2c relay list  →  { ok: true, peers: [ <RegistrationLease.to_json>, ... ] }
//   per-peer fields: node_id, session_id, alias, client_type, registered_at,
//                    last_seen, ttl, alive, identity_pk (b64url), signed_at, sig_b64
//   (ocaml/relay.ml:184-217)
```

### C. `c2c_pi_send` — local → sessions → relay fallback

```
async send(target, body):
  try  cli.send(target, body)  return ok          // per-repo broker (fast path; same-host)
  catch (recipient unknown):
  try  cli.send(target, body, { brokerRoot: sessionsBrokerRoot })  return ok  // cross-repo
  catch (recipient unknown):
  if relayEnabled:
    try  cli.relayDmSend(target, body, { from: identity.alias, relayUrl })  return ok
    catch as e: return { ok: false, error: e, tried: ["local","sessions","relay"] }
  return { ok: false, error: "not registered" }
```

Alias collision handling: when the per-broker canonical_alias is set, the extension prefers the fully-qualified form for relay sends (e.g. `pi-c01ea5#.c2c@xsm`) so the relay's `host_acceptable` gate (`ocaml/relay.ml:436-439`) is satisfied even when multiple pi hosts happen to share a short alias. Bare-alias sends still work against peers on the same `self_host` as the relay.

### D. `pollTick` — drain relay DMs

Extend the existing drain (currently local + sessions broker at `pi-c2c/src/index.ts`) to a third hop:

```ts
const drained: C2cMessage[] = [];
try { drained.push(...await cli.pollInbox()); } catch { /* local broker hiccup */ }
if (sessionsBrokerRoot) {
  try { drained.push(...await cli.pollInbox({ brokerRoot: sessionsBrokerRoot })); } catch {}
}
if (relayEnabled) {
  try {
    const relayMsgs = await cli.relayDmPoll({ relayUrl, from: identity.alias });
    drained.push(...relayMsgs);
  } catch { /* relay hiccup — retry next tick */ }
}
```

`relayDmPoll` calls `c2c relay dm poll --alias <alias> --relay-url <url>` and parses the response. The response shape is `{ ok, messages: [{ from_alias, to_alias, content, ts, message_id? }] }` (handler at `ocaml/relay.ml:3888-3903`); slice 1's `parseRelayDmPoll` maps this into the existing `C2cMessage` shape so the rest of the pipeline (status-envelope filter, dedup, spool, inject) needs zero changes.

Cost: one extra `c2c` invocation per poll tick (default 30s). The c2c CLI's `relay dm poll` is a single signed POST to `/poll_inbox`, ~10ms round trip on local network.

### E. `/c2c-pi-debug` — relay section

Append a `=== relay ===` block to the existing debug table:

```
relay enabled:    yes
relay url:        https://relay.c2c.im
relay alias:      pi-c01ea5
canonical_alias:  pi-c01ea5#.c2c@xsm
identity_fp:      7a3f...  (first 8 hex)
lease ttl:        86400s
last error:       -
```

When relay integration is off or failed, show `relay enabled: no` and the reason (`C2C_PI_RELAY=0`, `C2C_RELAY_URL unset`, `register failed: <msg>`, etc.).

### Configuration

| Env var | Default | Purpose |
|---|---|---|
| `C2C_PI_RELAY` | `1` | Opt-out (set `0`) |
| `C2C_RELAY_URL` | (c2c CLI default: `https://relay.c2c.im`) | Inherited from c2c's URL resolution — same value `c2c relay *` uses |
| `C2C_PI_RELAY_URL` | unset | Extension-only override (wins over `C2C_RELAY_URL`; useful for local-relay testing) |
| `C2C_PI_RELAY_TTL` | `3600` (heartbeat refresh; not enforced in v1) | Reserved for a future heartbeat slice |

**v1 is opt-out (`C2C_PI_RELAY=0` to disable)**. We don't flip the default until the slice is peer-tested.

### Failure handling (consolidated)

| Failure | Behaviour |
|---|---|
| `C2C_RELAY_URL` unset | Skip silently. Debug shows `relay enabled: no` + reason. |
| `c2c relay identity show` fails | Try `c2c relay identity init` once; if still fails, log + skip + warn. |
| `c2c relay register` returns `alias_hijack_conflict` | Skip; surface in debug. Per-repo + sessions broker keep working. |
| `c2c relay register` network error | Store `relayLastError`; retry once per heartbeat tick. |
| `c2c relay dm send` fails with `cross_host_not_implemented` | The relay's own `self_host` mismatches the host encoded in our canonical_alias. Surface + skip; the receiver's host is on a different relay cluster. |
| `c2c relay dm send` 401 / 403 | Pubkey signature failed. Almost always means `~/.config/c2c/identity.json` was rotated or never registered. Re-run register transparently. |
| `c2c relay dm poll` 5xx | Treat as transient. Skip this tick; the existing dedup + spool handles delivery on the next successful tick. |
| Identity pubkey drifts mid-session | Not possible: `c2c relay *` reads `identity.json` on every call, so any rotation takes effect on the next call. No in-memory caching of the keypair. |

## What we do NOT do (v1)

- **Rooms over the relay.** `c2c relay rooms` already exists, but the extension's `c2c_pi_join_room` and `c2c_pi_send_room` would need relay-side room membership + history sync. Defer to v2.
- **Long-poll connector.** `c2c relay connect` is a long-poll loop, but the extension already polls every 30s. A connector child-process adds lifecycle complexity for marginal latency win. Re-evaluate after dogfooding v1.
- **Multi-relay fan-out.** One relay per session. Multi-relay is a topology change, not a feature add — defer.
- **Pubkey addressing.** `c2c_pi_send <pubkey_b64> ...` would skip the alias step, but the relay only routes by alias. Defer; alias-based routing is the relay's contract.

## Files referenced

### c2c repo (existing — leverage, don't modify)

- `ocaml/c2c_broker.ml:1721` — `compute_canonical_alias`
- `ocaml/c2c_broker.ml:1980` — auto-populate on register
- `ocaml/relay.ml:184-217` — `RegistrationLease.to_json` shape
- `ocaml/relay.ml:436-439` — `host_acceptable`
- `ocaml/relay.ml:3601-3645` — `handle_send` cross-host gate
- `ocaml/relay.ml:3888-3903` — `handle_poll_inbox` response shape
- `ocaml/cli/c2c.ml:4563-4569` — relay URL resolution
- `ocaml/cli/c2c.ml:4755-4790` — `c2c relay list`
- `ocaml/cli/c2c.ml:5027-5063` — `c2c relay register`
- `ocaml/cli/c2c.ml:5065-5220` — `c2c relay dm` (send / poll / send-all)
- `ocaml/cli/c2c.ml:5640-5685` — `c2c relay identity show --json`
- `ocaml/test/test_cross_host_e2e.ml` — existing `alias@host` acceptance tests (positive + negative)
- `ocaml/test/test_relay_e2e.ml` — existing end-to-end register/list/dm/rooms
- `.collab/runbooks/cross-machine-relay-proof.md` — relay bringup recipe
- `.collab/design/2026-06-17-local-relay-cross-repo.md` — local-relay smoke test (relay connector is one-way out)

### pi-c2c repo (slice 2)

- `pi-c2c/src/c2c-cli.ts` — slice 1 adds `relay*` wrappers + parsers here
- `pi-c2c/src/identity.ts` — extend `IdentityInputs` with `identityJson?: { publicKey, fingerprint }` (from slice 1's `relayIdentityShow`); keep `resolveAlias` deriving the short alias from the pubkey
- `pi-c2c/src/index.ts` — `session_start` calls slice 1's `cli.relayRegister(...)` after per-repo + sessions broker register; `pollTick` adds the third drain hop; `c2c_pi_list` merges three sources; `c2c_pi_send` adds the third send hop
- `pi-c2c/src/debug.ts` — extend the debug collector to include the relay section
- `tests/*.test.ts` — merge logic (slice 2); relay CLI wrappers + parsers (slice 1)

## Open questions for coord / review

- Should `c2c_pi_send`'s third hop be silent (always try) or opt-in per call (e.g. `--via-relay`)? Silent is the better UX but couples the extension to the relay's reliability.
- Should we expose a `c2c_pi_relay_register` slash command for operators who want to re-register on demand (e.g. after rotating the keypair)?
- Local relay detection: should the extension auto-prefer `http://127.0.0.1:7331` over the public relay when it's reachable? (Pro: lower latency, no quota. Con: silent fallback hides relay downtime.) Recommend no for v1 — make it explicit via `C2C_PI_RELAY_URL`.

## Rollout

- v0.x (this slice): ship behind `C2C_PI_RELAY=1` opt-out; per-repo + sessions broker stay the default fast paths.
- v1.0: dogfood via `c2c` repo (us) + `pi-c2c` repo (pi-313d8c) cross-machine. Once stable, announce in `swarm-lounge`.
- v2.0: long-poll connector, relay rooms, multi-relay.
