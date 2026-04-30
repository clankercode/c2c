# #515 `c2c mesh status` — Cross-Host Mesh Topology

## Background

`c2c relay list` exists but outputs raw JSON from the relay's `/list` endpoint. It is
not human-readable and provides no context about whether peers are alive or their
session metadata.

`c2c doctor relay-mesh` is a diagnostic subcommand under `c2c doctor` — it probes the
relay's `/health` and scans the local broker log for cross-host activity, but it
does not report who is connected to the relay from other hosts.

## Goal

Implement `c2c mesh status` — a first-class CLI command that reports the remote relay's
connected peer topology in a human-readable format.

## Command Design

```
c2c mesh status [--relay-url URL] [--include-dead] [--json]
```

### Flags

| Flag | Description |
|------|-------------|
| `--relay-url URL` | Relay HTTP URL (default: C2C_RELAY_URL env var) |
| `--include-dead`  | Include expired/dead sessions in output |
| `--json`          | Output raw JSON instead of human-readable table |

### Exit codes

- `0` — success (relay responded)
- `1` — relay returned error or is unreachable

## Data Sources

1. **Peer list** — `Relay.Relay_client.list_peers_signed` (if identity exists and `--include-dead` not set), else `Relay.Relay_client.list_peers` (unsigned)
2. **Relay rooms** — `Relay.Relay_client.list_rooms` (for room membership context)

## Output Format (human-readable)

```
c2c mesh status — relay=https://relay.c2c.im:8787

Peers (7 alive, 3 dead):
  ALIAS              SESSION_ID          TYPE      LAST_SEEN            TTL
  storm-ember        sess_a1b2c3d4       claude    2026-05-01T10:23:45Z  300s  ALIVE
  lyra-quill         sess_e5f6g7h8       opencode  2026-05-01T10:22:01Z  300s  ALIVE
  ...
  [dead entries shown only with --include-dead]

Rooms on relay (4):
  swarm-lounge  (12 members)
  dev-core     (3 members)
  ...
```

## Output Format (JSON)

```json
{
  "ok": true,
  "relay_url": "https://relay.c2c.im:8787",
  "peers": [
    {
      "alias": "storm-ember",
      "session_id": "sess_a1b2c3d4",
      "client_type": "claude",
      "registered_at": 1746099825.0,
      "last_seen": 1746101025.0,
      "ttl": 300.0,
      "alive": true
    }
  ],
  "rooms": [
    {"room_id": "swarm-lounge", "member_count": 12}
  ]
}
```

## Relationship to Existing Commands

| Command | Role |
|---------|------|
| `c2c relay list` | Raw JSON peer list — for scripting |
| `c2c doctor relay-mesh` | Local diag: broker log + relay health probe |
| **`c2c mesh status`** | **Human-readable remote peer topology** |

`mesh status` uses the same underlying relay API as `c2c relay list` but presents it
in a way suited for human operators inspecting the mesh.

## Implementation Notes

- Add `mesh_status_cmd` in `ocaml/cli/c2c.ml` alongside `relay_list_cmd`
- Register as a top-level `mesh` group containing `status` subcommand (extensible for future `mesh rooms` etc.)
- Use `resolve_relay_url` helper (same as `relay_list_cmd`)
- Use `Relay_identity.load ()` + `env_auto_alias ()` for signed list route (same pattern as `relay_list_cmd`)
- Human output: plain-text table with `Printf.printf`
- JSON output: build `Yojson.Safe.t` assoc and print with `Yojson.Safe.to_string`

## Slice Plan

- **S1 (this slice)**: Implement `c2c mesh status` command in OCaml; build in worktree; peer-PASS; cherry-pick to master
- **Future S2**: `c2c mesh rooms` — show room members per connected relay
- **Future S3**: `c2c mesh join` — join a remote relay explicitly
