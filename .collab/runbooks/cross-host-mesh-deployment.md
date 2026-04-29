# Cross-Host Relay Mesh Deployment

**Audience**: c2c operators deploying two or more relays that forward messages across host boundaries.
**Goal**: a working relay mesh where a client registered on relay-A can send to a client registered on relay-B via the `/forward` endpoint.

---

## TL;DR

```bash
# 1. Build the Docker image (includes netbase — see §4)
docker build -f Dockerfile -t c2c-relay-test:mesh .

# 2. Create the bridge network
docker network create c2c-mesh-net

# 3. Start relay-a (generates identity on first boot)
docker run --rm -d \
  --name c2c-mesh-relay-a \
  --network c2c-mesh-net \
  -p 18080:18080 \
  -e PORT=18080 \
  -e C2C_RELAY_TOKEN="mesh-token" \
  -e C2C_RELAY_NAME="relay-a" \
  -e C2C_RELAY_PERSIST_DIR=/var/lib/c2c \
  -e C2C_RELAY_STORAGE=sqlite \
  -v c2c-mesh-vol-a:/var/lib/c2c \
  c2c-relay-test:mesh

# 4. Start relay-b (same pattern)
docker run --rm -d \
  --name c2c-mesh-relay-b \
  --network c2c-mesh-net \
  -p 18081:18081 \
  -e PORT=18081 \
  -e C2C_RELAY_TOKEN="mesh-token" \
  -e C2C_RELAY_NAME="relay-b" \
  -e C2C_RELAY_PERSIST_DIR=/var/lib/c2c \
  -e C2C_RELAY_STORAGE=sqlite \
  -v c2c-mesh-vol-b:/var/lib/c2c \
  c2c-relay-test:mesh

# 5. Extract identity public keys from the volumes (see §2)
# 6. Restart both relays with --peer-relay and --peer-relay-pubkey flags
# 7. Register alice on relay-a, bob on relay-b (see §3)
# 8. alice → bob@relay-b now works via /forward
```

Full end-to-end validation: `scripts/mesh-test.sh`

---

## §1 — How the Mesh Forwarder Chain Works

When `alice@relay-a` sends to `bob@relay-b`:

```
alice → relay-a /send
  relay-a looks up bob and sees bob@relay-b (relay-b host)
  relay-a POSTs to http://relay-b:18081/forward  ← /forward, NOT root /
  relay-b receives, delivers to bob's inbox
  bob polls relay-b /poll_inbox and receives the message
```

The `/forward` path is required on the peer relay. The forwarding relay
hits `peer_url ^ "/forward"`. See
[`.collab/findings/2026-04-29T10-45-00Z-galaxy-coder-forward-path-missing.md`](../findings/2026-04-29T10-45-00Z-galaxy-coder-forward-path-missing.md)
for the bug where the base URL was used directly (404 on every forward).

---

## §2 — Relay Identity and Peer Configuration

### Identity generation

Each relay generates an Ed25519 identity keypair on first boot. The keypair is
stored at `/var/lib/c2c/relay-server-identity.json` inside the container, persisted
to a named Docker volume so restarts do not regenerate it.

**Extracting the public key** (needed for peer config):

```bash
RELAY_A_PK=$(docker run --rm \
    -v c2c-mesh-vol-a:/data:ro \
    alpine:latest \
    sh -c 'cat /data/relay-server-identity.json | tr -d "\n"' \
    | grep -o '"public_key": *"[^"]*"' \
    | sed 's/"public_key": *"\([^"]*\)"/\1/')
```

### Peer relay flags

Restart each relay with the following flags (or equivalent `docker run` entrypoint):

```
--peer-relay "relay-b=http://c2c-mesh-relay-b:18081"
--peer-relay-pubkey "relay-b=<relay-b public key from identity.json>"
```

Both relays must have each other's public key configured — the sender validates
the peer's identity before forwarding.

---

## §3 — Ed25519 Client Registration and Signed Sends

Clients (alice, bob) also use Ed25519 for relay registration and sending.
The mesh test at `scripts/mesh_test_client.py` demonstrates the full flow:

1. **Key generation**: `sign_ed25519.py gen-keypair` → `{priv_seed_b64, pub_b64}`
2. **Registration**: sign a blob `(alias, relay_url, ts, nonce)` with the private
   seed; submit `{alias, identity_pk, timestamp, nonce, signature}` to `/register`
3. **Signed send**: sign the request with
   `sign_ed25519.py sign-request <priv> <alias> <method> <path> <query> <body_file> <ts> <nonce>`
   and include the result as the `Authorization` header.

The signing scheme ties the signature to `(alias, method, path, query, body, ts, nonce)`
so replay attacks are blocked.

---

## §4 — Gotchas

### `netbase` package missing in Docker image → "unknown scheme"

**Symptom**: `forward_local error: Failure("resolution failed: unknown scheme")`

**Cause**: `debian:12-slim` does not include `/etc/services`. `cohttp-lwt-unix`
calls `Lwt_unix.getservbyname` to resolve port numbers, which fails without it.

**Fix**: The Dockerfile at the repo root includes `netbase` in the runtime stage.
If you are building your own image, add:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        ... \
        netbase \
    && rm -rf /var/lib/apt/lists/*
```

Full details:
[`.collab/findings/2026-04-29T10-30-00Z-galaxy-coder-docker-netbase-unknown-scheme.md`](../findings/2026-04-29T10-30-00Z-galaxy-coder-docker-netbase-unknown-scheme.md)

### `/forward` path missing from `forward_send`

**Symptom**: `peer relay relay-b rejected request 404: {"ok":false,"error_code":"not_found","error":"unknown endpoint: /"}`

**Cause**: `forward_send` in `relay_forwarder.ml` sent to `peer_url` (the base URL)
instead of `peer_url ^ "/forward"`.

**Fix**: The forward URI must be constructed as:

```ocaml
let uri = Uri.of_string (peer_url ^ "/forward") in
```

Full details:
[`.collab/findings/2026-04-29T10-45-00Z-galaxy-coder-forward-path-missing.md`](../findings/2026-04-29T10-45-00Z-galaxy-coder-forward-path-missing.md)

### Identity keypair regeneration on volume-less restart

If a relay restarts without its identity volume, it generates a new keypair.
Any peer that was configured with the old public key will reject it. Always
persist `/var/lib/c2c` to a named volume.

### Token must match across relays

All relays in the mesh should share the same `C2C_RELAY_TOKEN` value.
Mismatched tokens cause 401 on inter-relay `/forward` requests.

---

## §5 — Running the Mesh Test Suite

`scripts/mesh-test.sh` automates the full two-relay validation:

```bash
./scripts/mesh-test.sh
```

**Expected output on success**:

```
=== ALL STEPS PASSED ===
    Mesh cross-host send alice@relay-a → bob@relay-b via /forward endpoint: OK
```

**On failure**: the script exits non-zero at the failing step and dumps
`dead_letter` output plus container logs. The most common failure modes
are the two bugs documented in §4.

---

## §6 — Interpreting Results

| Step | What it checks | Failure signal |
|---|---|---|
| 1 | Docker image builds | `docker build` exit 1 |
| 2 | Both relays respond `/health` with 200 | HTTP != 200, container crash |
| 3 | Identity public keys extracted from volumes | Empty PK string |
| 4 | Relays healthy after peer config restart | HTTP != 200 post-restart |
| 5 | alice (signed) and bob (unsigned) register | `mesh_test_client.py` exit != 0 |
| 6 | alice sends to bob@relay-b via forward | `dead_letter` on relay-a |
| 7 | bob's `/poll_inbox` on relay-b contains the message | Empty inbox, content mismatch |

If step 7 fails, check `dead_letter` on relay-a — entries there indicate
which stage the forward chain broke at.
