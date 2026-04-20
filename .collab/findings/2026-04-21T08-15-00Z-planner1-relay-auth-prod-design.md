---
author: planner1
ts: 2026-04-21T08:15:00Z
severity: medium
status: design — ready for implementation
---

# Relay Auth: Moving relay.c2c.im from Dev Mode to Prod Mode

## Current State

relay.c2c.im runs in **dev mode** (`C2C_RELAY_TOKEN` not set).

From `relay.ml` auth_decision:
```ocaml
else if token = None then (true, None)  (* dev mode *)
```

Dev mode means:
- **Admin routes** (`/gc`, `/dead_letter`, `/list?include_dead=true`, `/admin/unbind`): **open** — anyone can GC or read dead letters
- **Peer routes** (`/register`, `/send`, `/poll`, etc.): **open** — no auth required at all
- **Ed25519 signed envelopes**: optional (§8 signed send works but isn't required)

This is acceptable for a dev relay but not for a shared prod relay:
- Anyone can register as any alias (namespace squatting)
- Anyone can GC the relay state
- Anyone can read dead letters (potential message exposure)

## What's Already Built

The auth system is fully implemented:

### Admin Bearer Token (admin routes)
- Set `C2C_RELAY_TOKEN=<secret>` on Railway → admin routes require `Authorization: Bearer <secret>`
- Used by: `c2c relay gc`, `c2c relay dead-letter`, `c2c relay list --dead`
- Client reads from `C2C_RELAY_TOKEN` env var or `--token` flag

### Ed25519 Peer Auth (peer routes)
- Each agent has a keypair at `~/.config/c2c/identity.json` (via `c2c relay identity init`)
- Register: signed with Ed25519 to prove alias ownership
- Send/join-room: signed with Ed25519 so relay can verify sender identity
- Signed envelopes (§8): content signed, tamper-detectable on delivery
- Relay verifies: `ts` within 30s window, nonce not reused (2min TTL), sig valid

### Dev mode bypass
- `token = None` → peer routes allow unsigned requests
- Setting `C2C_RELAY_TOKEN` **enables enforcement** of Ed25519 on peer routes

## What Needs to Change for Prod Mode

### Step 1: Set C2C_RELAY_TOKEN on Railway (1 min operator task)

```bash
# Generate a random admin token
python3 -c "import secrets; print(secrets.token_hex(32))"
# → e.g. "a3f2b8c1d7e9..."

# Set on Railway via dashboard or CLI:
railway variable set C2C_RELAY_TOKEN=<generated-token> --service c2c
```

Effect: relay enters prod mode. Ed25519 now **required** for peer routes.

### Step 2: All agents must have an identity keypair

Already handled by `c2c relay identity init` (idempotent). Identity file at `~/.config/c2c/identity.json`.

`c2c install` / `c2c init` should call `c2c relay identity init` automatically — currently it does not.

**Fix**: Add to `c2c init`:
```ocaml
(* In init_cmd, after broker root setup *)
let _ = Sys.command "c2c relay identity init 2>/dev/null" in
```

Or more cleanly: expose `relay_identity_init_if_missing` and call it.

### Step 3: Signed register/send by default

Agents must use signed variants for peer operations. The relay client already supports these:
- `register_signed` — Ed25519-signed registration
- `send_room_signed` / `join_room_signed` — signed room operations

The `c2c relay register` CLI currently uses unsigned registration. In prod mode this will be rejected.

**Fix**: `c2c relay register` should auto-sign when identity exists:
```ocaml
(* c2c relay register -- auto-detect signed mode *)
let identity = Relay_identity.load_or_create () in
match identity with
| Some id ->
    (* use register_signed *)
    client |> Relay_client.register_signed ~node_id ~session_id ~alias
      ~identity_pk_b64:(Relay_identity.pk_b64 id)
      ~sig_b64:(Relay_identity.sign id payload)
      ~nonce ~ts ()
| None ->
    (* fall back to unsigned (dev mode only) *)
    client |> Relay_client.register ~node_id ~session_id ~alias ()
```

### Step 4: c2c health shows relay auth status

`c2c health` already probes relay `/health`. Extend to show whether the relay is in dev vs prod mode:
```
✓ relay: reachable — 0.6.10 @ f21b3bc (prod mode, Ed25519 required)
⚠ relay: reachable — 0.6.10 @ f21b3bc (dev mode — no auth required)
```

The `/health` response could include `{"auth_mode": "prod"|"dev"}`.

---

## Allowlist: Per-Alias Namespace Protection (Optional)

The relay already has an `allowlist` feature:
```ocaml
?allowlist:[]  (* in start_server *)
```

An allowlist of Ed25519 public keys → only those keys can register aliases. This prevents namespace squatting even from authenticated agents.

For the c2c swarm: allowlisting is probably too strict (new agents need to onboard dynamically). Skip for now.

---

## Migration Plan

| Step | Who | When |
|------|-----|-------|
| Generate admin token | Max (operator) | Before next prod push |
| Set `C2C_RELAY_TOKEN` on Railway | Max | Same time |
| `c2c relay identity init` in `c2c init` | coder2-expert | Next OCaml slice |
| Auto-sign `c2c relay register` | coder2-expert | Same slice |
| `/health` reports auth_mode | coder2-expert | Same slice |
| Update `c2c health` to show auth_mode | coder2-expert | Same slice |

**Estimated Railway deploys**: 1 (for the relay code changes)  
**Estimated operator time**: 2 minutes (set env var)

---

## Acceptance Criteria

1. `C2C_RELAY_TOKEN` set → relay in prod mode, unsigned peer requests rejected
2. `c2c init` runs `c2c relay identity init` automatically
3. `c2c relay register` auto-signs when identity exists
4. `c2c relay dm send` auto-signs
5. `GET /health` includes `"auth_mode": "prod"|"dev"` field
6. `c2c health` shows auth_mode in relay line
7. Existing agents (with identity) continue working transparently
8. New agent onboarding: `c2c init` → identity created → relay works

---

## Related

- `ocaml/relay.ml` lines 785–835 — auth_decision implementation
- `ocaml/relay_identity.ml` — Ed25519 keypair management
- `ocaml/cli/c2c.ml` lines 2455–2675 — relay CLI commands
- `.collab/findings/2026-04-21T06-15-00Z-opencode-test-health-version-git-hash.md` — relay health endpoint
- Spec §5.1 (in relay.ml comments) — Ed25519 peer auth spec
