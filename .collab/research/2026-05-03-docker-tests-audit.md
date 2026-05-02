# Docker-Tests Suite Audit — 2026-05-03

**Auditor:** jungle-coder
**Task:** #675 — Audit docker-tests/ suite
**Commit audited:** `8bc945c3` (master)

---

## Summary

| Category | Count |
|---|---|
| Real tests (with assertions + docker setup) | 16 |
| Stubs / thin wrappers | 2 |
| **Total** | **18** |

**Local run results** (host subprocess, `C2C_CLI=/home/xertrov/.local/bin/c2c`):
- PASS: `test_dead_letter_e2e` (3/3)
- PASS: `test_monitor_leak_guard` (1 passed, 1 skipped — circuit-breaker not implemented)
- FAIL: `test_ephemeral_contract` — "cannot send a message to yourself" broker bug
- FAIL: `test_broker_respawn_pid` — same broker bug (same-alias registration collision)

**Docker-compose runs**: timed out in audit window; image inventory confirmed present.

---

## Test File Classifications

### REAL TESTS (16)

#### 1. `test_sealed_sanity.py`
- **Topology:** Runs inside `test-env` container (`docker-compose.test.yml`)
- **What it tests:** Phase C Cases 1-5 — c2c binary sanity in sealed container
- **Assertions:** ~15 (version, register, send/poll, rooms, whoami)
- **Status:** Not run (requires docker compose up)

#### 2. `test_broker_respawn_pid.py`
- **Topology:** None — host subprocess against live broker
- **What it tests:** Broker-respawn-pid self-heal after inner client respawn
- **Assertions:** ~8 (respawn self-heal, inbox cleanup)
- **Status:** ⚠️ FAILS — "cannot send a message to yourself (heal-bob-TS)" — broker
  resolves sender alias as recipient alias. Likely race in session→alias binding
  when both register simultaneously. **Pre-existing broker bug**, not test issue.

#### 3. `test_ephemeral_contract.py`
- **Topology:** None — host subprocess
- **What it tests:** Ephemeral message contract: poll_inbox delivers, history excludes
- **Assertions:** ~10
- **Status:** ⚠️ FAILS — same "cannot send a message to yourself" broker bug

#### 4. `test_two_container_roundtrip.py`
- **Topology:** `docker-compose.test.yml` + `docker-compose.two-container.yml`
- **What it tests:** Two Docker containers register, DM each other bidirectionally
- **Assertions:** ~12 (bidir DMs, concurrent registration)
- **Status:** Not run (requires compose up)

#### 5. `test_four_client_mesh.py`
- **Topology:** `docker-compose.test.yml` + `docker-compose.two-container.yml` + `docker-compose.4-client.yml`
- **What it tests:** Four-container mesh — all 6 ordered-pair DMs + concurrent registration
- **Assertions:** ~20+
- **Status:** Not run (requires compose up)

#### 6. `test_kimi_first_class_peer.py`
- **Topology:** `docker-compose.test.yml` via `test-kimi` service
- **What it tests:** Kimi as first-class peer in sealed Docker environment
- **Assertions:** ~12 (auth files, install, start, send)
- **Status:** Not run (requires compose up)

#### 7. `test_relay_mesh_probe.py`
- **Topology:** `docker-compose.2-relay-probe.yml` (relay-a, relay-b, peer-a1/a2, peer-b1/b2)
- **What it tests:** #330 V3 — 2-relay mesh, cross-host dead-letter contract
- **Assertions:** ~9 (SQLite dead_letter row counts, reason strings)
- **Status:** Not run (requires compose up)

#### 8. `test_dead_letter_e2e.py`
- **Topology:** None — host subprocess
- **What it tests:** `c2c list --alive` filter correctness
- **Assertions:** ~12 (alive:true exclusivity, alive ⊆ all)
- **Status:** ✅ PASS — 3/3

#### 9. `test_deferrable_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Deferrable DM push suppression across broker boundary
- **Assertions:** ~8 (relay tail_log deliver event presence/absence)
- **Status:** Not run

#### 10. `test_ephemeral_dm_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Ephemeral archive contract across Docker cross-container topology
- **Assertions:** ~8 (archive file grep checks)
- **Status:** Not run

#### 11. `test_monitor_leak_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Inotify watch cleanup after session exit (E2E)
- **Assertions:** ~6 (inotify fd counts via `/proc/<pid>/fdinfo/`)
- **Status:** Not run

#### 12. `test_relay_outage.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Relay outage + recovery, outbox persistence + reconnect
- **Assertions:** ~6 (message delivery after restart)
- **Status:** Not run

#### 13. `test_room_acl_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Room invite-only ACL enforcement across broker boundary
- **Assertions:** ~20 (using `_room_helpers.py`)
- **Status:** Not run

#### 14. `test_s5_signing_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Signing keys provisioning E2E — Ed25519 identity, sign+verify cross-broker
- **Assertions:** ~15 (key format, fingerprint, cross-broker verification)
- **Status:** Not run

#### 15. `test_peer_pass_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Peer-PASS lifecycle E2E — sign → DM → verify roundtrip
- **Assertions:** ~18 (relay DM polling, commit verification, signature verification)
- **Status:** Not run

#### 16. `test_coord_cherry_pick_e2e.py`
- **Topology:** `docker-compose.e2e-multi-agent.yml`
- **What it tests:** Cherry-pick + auto-DM across containers
- **Assertions:** ~12 (git cat-file, SHA regex)
- **Status:** Not run

---

### STUBS / THIN WRAPPERS (2)

#### 17. `test_cross_host_relay.py`
- **Classification:** STUB (thin wrapper)
- **Topology:** `docker-compose.e2e-multi-agent.yml` (invoked via bash script)
- **What it tests:** Thin pytest wrapper around `tests/e2e/00-smoke-cross-container.sh`
- **Assertions:** 1 (bash script exit code only)
- **Status:** Wrapper only — real test is the bash script

#### 18. `test_monitor_leak_guard.py`
- **Classification:** PARTIAL STUB
- **Topology:** None — host subprocess
- **What it tests:** Monitor circuit-breaker / duplicate-guard
- **Assertions:**
  - `test_second_monitor_exits_with_circuit_breaker`: **SKIPPED** (feature not implemented)
  - `test_monitor_for_different_aliases_both_survive`: **PASS** (1 active assertion)
- **Status:** 1/2 active; circuit-breaker skipped

---

## Docker-Compose Topologies

| File | Services | Purpose |
|---|---|---|
| `docker-compose.yml` | `relay` | Local dev relay (port 7331) |
| `docker-compose.test.yml` | `test-env`, `test-kimi` | Sealed test env, isolated bridge network |
| `docker-compose.two-container.yml` | `peer-a`, `peer-b` (extends test.yml) | Two-container roundtrip |
| `docker-compose.4-client.yml` | `peer-c`, `peer-d` (extends above) | Four-client mesh |
| `docker-compose.2-relay-probe.yml` | `relay-a`, `relay-b`, `peer-a1/a2`, `peer-b1/b2` | 2-relay mesh probe (#330 V3) |
| `docker-compose.e2e-multi-agent.yml` | `relay`, `agent-a1/a2`, `agent-b1/b2` | E2E multi-agent (#407) |
| `docker-compose.agent-mesh.yml` | `relay-a`, `relay-b`, `codex-a1`, `codex-b1` | Real codex agents (#406 S2) |

**Image inventory**: All required images present locally (see `docker images` output).
Notable: `c2c-test:latest`, `c2c-relay:e2e`, `c2c-relay-a:e2e`, `c2c-relay-b:e2e`,
`406-e2e-docker-mesh-peer-*:latest`, `407-s5-signing-keys-e2e-*:latest`.

---

## Cross-Host Relay Coverage — What's Missing

### Current coverage
The `docker-compose.2-relay-probe.yml` topology tests cross-host relay via two relays
on ports 9000/9001 with 4 peers (2 per relay). `test_relay_mesh_probe.py` covers:
- Unknown host dead-letter
- Relay unreachable dead-letter
- Non-existent host dead-letter

### What's missing for full cross-host coverage

1. **Kimi + OpenCode on different hosts** — No topology exists with kimi on one host
   and opencode/codex on another. `docker-compose.agent-mesh.yml` has two codex agents
   but on the **same** broker (relay-a only). The `test_cross_host_relay.py` stub
   is meant to cover cross-host but is just a bash script wrapper with no Python-level
   assertions.

2. **No 3+ relay mesh** — All topologies are 1 or 2 relays. N-relay routing
   (relay-a → relay-b → relay-c) is untested.

3. **No mixed-client cross-host topology** — E2E topologies use `c2c-test:latest`
   for all agents (thin Python test clients). There's no topology combining a real
   codex or kimi with a real opencode peer across two different hosts/relays.

4. **Channel push delivery across hosts** — `test_deferrable_e2e.py` tests deferrable
   suppression but only within the e2e-multi-agent topology (single relay). Cross-host
   channel push (notifications/claude/channel) is not tested.

5. **`test_cross_host_relay.py` is a stub** — It calls a bash script that should bring
   up `docker-compose.e2e-multi-agent.yml` and run a cross-host DM, but there are no
   Python-level assertions. This is the right topology to extend for real cross-host
   coverage but needs actual test logic.

6. **No wire-format interoperability test** — Different client types (codex, kimi,
   opencode) may encode message envelopes differently. No topology exercises
   kimi→codex or kimi→opencode DMs across hosts.

---

## Known Bugs Found During Audit

### "Cannot send a message to yourself" — Broker alias resolution race
**Affected tests:** `test_ephemeral_contract.py`, `test_broker_respawn_pid.py`
**Symptom:** When two sessions register simultaneously, the broker resolves the sender's
alias as the recipient's alias, producing `error: cannot send a message to yourself`.
**Severity:** Broker bug (not test bug) — registration session→alias binding is not
stable under concurrent registration with similar names.
**Root cause (suspected):** The broker's session-to-alias lookup uses an incorrect
key when `session_id` differs from `alias` but both are registered at the same time.
Both test files use `session_id` equal to `alias` (e.g., `heal-alice-{ts}` for both),
which may expose a collision in the broker's session resolution.

---

## Recommendations

1. **Fix broker alias resolution race** — `test_broker_respawn_pid.py` and
   `test_ephemeral_contract.py` failures are pre-existing broker bugs, not test issues.
   Filing separately.

2. **Implement `test_cross_host_relay.py`** — Replace the bash wrapper with real Python
   assertions against the `docker-compose.e2e-multi-agent.yml` topology. Should test:
   - DM from agent-a1 (broker-a) to agent-b1 (broker-b) via relay
   - DM from agent-b1 back to agent-a1
   - Dead-letter when destination host is unknown

3. **Add kimi+opencode cross-host topology** — New `docker-compose.kimi-opencode-cross-host.yml`
   with kimi container on one relay and opencode/codex on another relay.

4. **Un-skip circuit-breaker test** — `test_monitor_leak_guard.py` has
   `test_second_monitor_exits_with_circuit_breaker` skipped; implement or remove.

5. **Run full docker-compose test suite** — With compose up, run all 16 real tests
   and update this document with pass/fail results per topology.
