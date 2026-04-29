# Findings: #330 V3 Docker Probe Debugging

**Agent**: birch-coder
**Date**: 2026-04-29T01:40:00Z
**Topic**: Dead-letter detection in SqliteRelay + relay server CLI wiring

---

## Finding 1: SqliteRelay stores dead_letters in SQLite, not JSON files

**Severity**: High (test correctness)
**Status**: Fixed in commit `98cabe46`

### Symptom
Tests asserted dead_letter files should appear in `/var/lib/c2c/dead_letter/`, but no files appeared. The directory was never created.

### Root Cause
`SqliteRelay` (used when `--storage sqlite` is set) stores dead_letters in a SQLite table `dead_letter`, not as JSON files in a directory. The test helpers were checking for files that would never exist.

### Fix
Replace `_relay_dead_letter_files()` + `_read_dead_letter()` with:
- `_relay_dead_letter_count()` — queries `SELECT COUNT(*) FROM dead_letter`
- `_read_last_dead_letter()` — queries `SELECT ... FROM dead_letter ORDER BY ts DESC LIMIT 1` with `-json` flag

Also requires adding `sqlite3` CLI to the relay runtime image (Debian package).

---

## Finding 2: `C2C_RELAY_PERSIST_DIR` does NOT automatically enable SQLite storage

**Severity**: High (data loss risk)
**Status**: Fixed in commit `98cabe46`

### Symptom
With `C2C_RELAY_PERSIST_DIR=/var/lib/c2c/relay-a-state` set, the relay created an empty 0-byte `c2c_relay.db` and the `dead_letter` table was never created.

### Root Cause
The `--storage` flag defaults to `memory` regardless of `C2C_RELAY_PERSIST_DIR`. The persist-dir controls WHERE data is stored, not WHICH storage backend is used.

### Fix
Always pass `--storage sqlite` when `C2C_RELAY_PERSIST_DIR` is set:
```bash
storage_flag=${C2C_RELAY_PERSIST_DIR:+--storage sqlite}
exec c2c relay serve ... ${storage_flag} ${persist_flag}
```

---

## Finding 3: `--relay-name` defaults to listen host, not `C2C_RELAY_NAME` env var

**Severity**: High (cross-host dead-letter path broken)
**Status**: Fixed in commit `23d752a7`

### Symptom
Tests S2 and S3 failed — `cross_host_not_implemented` was returned but no dead_letter entry was written. The `host_acceptable` check at `relay.ml:3173` was letting `Some "host-b"` through when `self_host` was `0.0.0.0`.

### Root Cause
`C2C_RELAY_NAME` env var was set in compose (`host-a`, `host-b`) but it was never passed to `--relay-name` in the relay server CMD. The relay defaulted `relay-name` to the listen address (`0.0.0.0`), which never matched the compose-set host names.

`host_acceptable ~self_host (Some "host-b")` returned `true` because it checks `host_opt = None || self_host = host_opt`, and with `self_host = "0.0.0.0"` and `host_opt = Some "host-b"`, neither matched, so the dead_letter path was bypassed.

### Fix
Wire `C2C_RELAY_NAME` to `--relay-name` in the Dockerfile CMD:
```bash
relay_name_flag=${C2C_RELAY_NAME:+--relay-name ${C2C_RELAY_NAME}}
exec c2c relay serve ... ${relay_name_flag}
```

### Key Code Path
- `c2c.ml:3503-3505`: `resolved_relay_name = match relay_name with Some n -> n | None -> host`
- `relay.ml:3173`: `if not (host_acceptable ~self_host host_opt)` — guards dead_letter write

---

## Finding 4: `c2c relay dm send` uses positional args, not `--body`

**Severity**: Low (test helper bug)
**Status**: Fixed in commit `98cabe46`

### Symptom
Test helper `_send_dm_via_relay()` used `--body` flag which was rejected as unknown option.

### Fix
Use positional args: `c2c relay dm send <to-alias> <message> --relay-url <url> --alias <from-alias>`

---

## Discovery: Peer registration must clear stale leases

**Severity**: Medium (test hygiene)

When re-provisioning peers after a container restart, old leases may conflict. The signed registration path requires the previous lease to be expired or explicitly cleared via:
```bash
docker exec <relay> sqlite3 <db> "DELETE FROM leases WHERE alias='<alias>'"
```

---

## Finding 5: rm -rf on bind-mounted volume dir breaks container startup

**Severity**: High (test infrastructure)
**Status**: Fixed in commit `7c8d1b8f`

### Symptom
`compose_up()` ran `rm -rf volumes/relay-a/` to clean stale DB state, but this deleted the host directory too. When compose recreates containers, the bind mount target path doesn't exist on host → relay can't create the SQLite DB → `internal error: unable to open database file`.

### Root Cause
Bind mount (`./volumes/relay-a:/var/lib/c2c/relay-a-state`) means the host directory IS the container directory. Deleting the host directory removes the mount point, and Docker can't re-create it as root-owned on startup.

### Fix
1. Only delete `.db*` files, not the directory itself
2. `chmod 1777` (sticky + world-writable) on the host directory so the relay container's `c2c` user (UID 999) can create files even though the directory is owned by the host user

```python
os.makedirs(vol_path, exist_ok=True)
subprocess.run(["chmod", "1777", vol_path], check=False)
for pattern in ["*.db", "*.db-shm", "*.db-wal"]:
    subprocess.run(["sh", "-c", f"rm -f {vol_path}/{pattern}"], check=False)
```

## Finding 6: Orphan stale compose file in main tree

**Severity**: Low (coord issue)
**Status**: Resolved via `--theirs` by coordinator1

Coordinator1 had a stale orphan version of `docker-compose.2-relay-probe.yml` (older `--body`/`--alias` flag shape) sitting in the main tree's working dir. Resolved via `git checkout --theirs` during cherry-pick.

---

## All Commits on This Branch

| SHA | Message |
|-----|---------|
| `f793b73c` | feat(#330 V3): add 2-relay probe compose + negative test scenarios |

---

## Status: ✅ LANDED on master `62ff26d7`
pytest docker-tests/test_relay_mesh_probe.py -v
======================== 3 passed, 1 warning in 42.85s =========================
```

All 3 negative scenarios pass:
- S1: `test_cross_host_dead_letter_peer_unknown_host` — peer-a1 → peer-b2@host-b dead-letters
- S3: `test_cross_host_dead_letter_relay_b_unreachable` — relay-b down, peer-a1 → peer-b2@host-b dead-letters
- S4: `test_unknown_host_dead_letter` — peer-a1 → nonexistent@unknown-host dead-letters
