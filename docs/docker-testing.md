# Docker E2E Test Suite

Docker-based end-to-end tests validate c2c behaviour across isolated container
networks, multi-broker topologies, and cross-host relay paths. All tests use
thin shell-driven agents (no LLM invocation) unless noted.

---

## Running the Tests

### Prerequisites

```bash
# Build the required images (once)
DOCKER_BUILDKIT=1 docker compose -f docker-compose.<TOPOLOGY>.yml build

# Set the CLI path if not in PATH
export C2C_CLI=${C2C_CLI:-c2c}
```

### Per-Topology Run

```bash
# 1. Bring up the topology
docker compose -f docker-compose.<TOPOLOGY>.yml up -d --build

# 2. Run the relevant test file(s)
pytest docker-tests/<TEST_FILE>.py -v

# 3. Tear down (wipe ephemeral state)
docker compose -f docker-compose.<TOPOLOGY>.yml down -v
```

### Running All Tests at Once

```bash
# Start the default relay and run host-subprocess tests
pytest docker-tests/test_*.py -v

# Or start a specific topology and run all its tests
docker compose -f docker-compose.e2e-multi-agent.yml up -d --build
pytest docker-tests/ -v
docker compose -f docker-compose.e2e-multi-agent.yml down -v
```

> **Note:** Many tests require `docker compose up` to already be running. Host-subprocess
> tests (`test_dead_letter_e2e.py`, `test_broker_respawn_pid.py`, `test_ephemeral_contract.py`,
> `test_monitor_leak_guard.py`) run against the live broker without any compose.

---

## Available Topologies

Seven `docker-compose*.yml` files exist. All except `docker-compose.yml` and
`docker-compose.e2e-multi-agent.yml` are **overlays** that extend a base file;
chain them with `-f base.yml -f overlay1.yml -f overlay2.yml`.

| File | Services | Purpose |
|---|---|---|
| `docker-compose.yml` | `relay` | Local dev relay on port 7331. Quick iteration without test isolation. |
| `docker-compose.test.yml` | `test-env`, `test-kimi` | Sealed container environment with isolated bridge network (`c2c-test-net`). Ephemeral broker via anonymous volume. Resource limits enforced by the Docker daemon (memory cap, pids limit, no privileged). |
| `docker-compose.two-container.yml` | `peer-a`, `peer-b` (extends `test.yml`) | Two-container roundtrip — both containers share the broker volume so registration is local (no relay). |
| `docker-compose.4-client.yml` | `peer-c`, `peer-d` (extends `two-container.yml`) | Four-container mesh — adds two more peers to the shared-broker topology. |
| `docker-compose.2-relay-probe.yml` | `relay-a:9000`, `relay-b:9001`, `peer-a1`, `peer-a2`, `peer-b1`, `peer-b2` | Two independent relays, 4 thin peers (2 per relay). Tests cross-host dead-letter contract before forwarder transport. RAM budget ≤600 MB. |
| `docker-compose.e2e-multi-agent.yml` | `relay`, `agent-a1`, `agent-a2`, `agent-b1`, `agent-b2` | Self-contained multi-agent topology. Two independent broker volumes (`broker-a`, `broker-b`). Cross-host delivery goes via relay. No base overlay needed. |
| `docker-compose.agent-mesh.yml` | `relay-a:9000`, `relay-b:9001`, `codex-a1`, `codex-b1` | Real codex-headless agents (one per relay). Requires `OPENAI_API_KEY` and `codex-turn-start-bridge` binary on host. |

### Topology Chain Examples

```bash
# Two-container (extends test.yml)
docker compose -f docker-compose.test.yml -f docker-compose.two-container.yml up -d

# Four-client mesh (extends two-container which extends test.yml)
docker compose \
  -f docker-compose.test.yml \
  -f docker-compose.two-container.yml \
  -f docker-compose.4-client.yml \
  up -d
```

---

## Test Inventory

19 test files in `docker-tests/`. Classification from latest audit
(`.collab/research/2026-05-03-docker-tests-audit.md`).

### Real Tests (16)

| Test File | Topology | What It Covers |
|---|---|---|
| `test_sealed_sanity.py` | `docker-compose.test.yml` | Phase C Cases 1-5 — c2c binary sanity in sealed container. ~15 assertions: version, register, send/poll, rooms, whoami. |
| `test_two_container_roundtrip.py` | `test.yml` + `two-container.yml` | Two containers register, DM each other bidirectionally. ~12 assertions (bidir DMs, concurrent registration). |
| `test_four_client_mesh.py` | `test.yml` + `two-container.yml` + `4-client.yml` | Four-container mesh — all 6 ordered-pair DMs + concurrent registration. ~20+ assertions. |
| `test_kimi_first_class_peer.py` | `test.yml` via `test-kimi` service | Kimi as first-class peer in sealed Docker environment. ~12 assertions (auth files, install, start, send). |
| `test_kimi_opencode_cross_host.py` | `docker-compose.e2e-multi-agent.yml` | #674 — Kimi + OpenCode cross-host relay E2E. 8 tests total: 4 pass (registration, room join); 4 blocked on relay alias@host:port parsing bug (#686, fix pending deploy in `09b4d871`). Bidir DMs, room message delivery, echo roundtrip task. |
| `test_relay_mesh_probe.py` | `docker-compose.2-relay-probe.yml` | #330 V3 — 2-relay mesh, cross-host dead-letter contract. ~9 assertions: SQLite dead_letter row counts, reason strings. |
| `test_dead_letter_e2e.py` | None (host subprocess) | `c2c list --alive` filter correctness. ~12 assertions (alive:true exclusivity, alive ⊆ all). **Host subprocess — no compose needed.** |
| `test_deferrable_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Deferrable DM push suppression across broker boundary. ~8 assertions via relay tail_log. |
| `test_ephemeral_dm_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Ephemeral archive contract across Docker cross-container topology. ~8 assertions (archive file grep checks). |
| `test_monitor_leak_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Inotify watch cleanup after session exit (E2E). ~6 assertions via `/proc/<pid>/fdinfo/`. |
| `test_relay_outage.py` | `docker-compose.e2e-multi-agent.yml` | Relay outage + recovery, outbox persistence + reconnect. ~6 assertions (message delivery after restart). |
| `test_room_acl_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Room invite-only ACL enforcement across broker boundary. ~20 assertions using `_room_helpers.py`. |
| `test_s5_signing_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Signing keys provisioning E2E — Ed25519 identity, sign+verify cross-broker. ~15 assertions. |
| `test_peer_pass_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Peer-PASS lifecycle E2E — sign → DM → verify roundtrip. ~18 assertions. |
| `test_coord_cherry_pick_e2e.py` | `docker-compose.e2e-multi-agent.yml` | Cherry-pick + auto-DM across containers. ~12 assertions (git cat-file, SHA regex). |
| `test_broker_respawn_pid.py` | None (host subprocess) | Broker-respawn-pid self-heal after inner client respawn. ~8 assertions. **⚠️ FAILS** — see Known Issues. |

### Stubs / Partial (3)

| Test File | Status | Notes |
|---|---|---|
| `test_cross_host_relay.py` | **STUB** | Thin pytest wrapper around `tests/e2e/00-smoke-cross-container.sh`. Single assertion (bash exit code only). Real test logic lives in the bash script. |
| `test_monitor_leak_guard.py` | **PARTIAL** | Circuit-breaker test is SKIPPED (not implemented). `test_monitor_for_different_aliases_both_survive` PASSes. |
| `test_ephemeral_contract.py` | **STUB (fails — broker bug)** | Thin wrapper testing ephemeral message contract. **⚠️ FAILS** — see Known Issues. Same root cause as `test_broker_respawn_pid.py`. |

---

## Known Issues

### Broker alias-resolution race (affects `test_broker_respawn_pid.py`, `test_ephemeral_contract.py`)

**Symptom:** `error: cannot send a message to yourself`

When two sessions register simultaneously with similar names, the broker
resolves the sender's alias as the recipient's alias. Both failing tests use
`session_id` equal to `alias` (e.g., `heal-alice-{ts}` for both), which may
expose a collision in the broker's session-to-alias lookup.

**Severity:** Broker bug, not test bug.
**Status:** Filed separately; not yet fixed.

### `test_cross_host_relay.py` is a stub

The test file has no Python-level assertions — only a bash script exit code
check. It is the right topology (`docker-compose.e2e-multi-agent.yml` has two
independent broker volumes) but needs actual DM assertions to be meaningful.
**Recommended:** Extend it to test agent-a1 → agent-b1 DM and agent-b1 → agent-a1
DM with poll-until-receive loops.

### `test_monitor_leak_guard.py` — circuit-breaker not implemented

`test_second_monitor_exits_with_circuit_breaker` is skipped with reason:
"feature not implemented". The duplicate-guard circuit-breaker for monitors
should either be implemented or the test removed.

### Healthcheck in `docker-compose.e2e-multi-agent.yml` uses `/dev/tcp`

The relay healthcheck in this topology uses a bash `/dev/tcp` probe because the
relay image (debian:12-slim) does not include `curl` or `wget`. The probe sends
a literal HTTP GET and greps for `"ok":true` in the response body. This is
functional but non-standard — an image with `wget` (e.g., `debian:12-slim`
with `apt-get install -y wget`) would be cleaner.

### Relay `alias@host:port` parsing — cross-host delivery silently fails (#686)

**Symptom:** `c2c send alias@host:port "msg"` appends to `remote-outbox.jsonl`
but the relay returns `unknown_alias` — it looks up the full
`"agent-b1@c2c-e2e-relay:7331"` string rather than the bare alias.

**Root cause:** The outbox stores `to_alias` verbatim. The relay's inbox
lookup does not strip the `@host:port` suffix before registry lookup.

**Affected tests:** `test_kimi_opencode_cross_host.py` (all 4 cross-host DM
and room delivery assertions), `test_cross_host_relay.py`.

**Fix:** `09b4d871` (`fix(#686): strip @host:port suffix from to_alias in
relay send`) — strips the suffix before relay-side lookup. Pending deploy.

**Finding:** `.collab/findings/2026-05-03T05-11-00Z-test-agent-relay-alias-at-host-not-parsed.md`

### Cross-host relay coverage gaps

- **No 3+ relay mesh** — all topologies are 1 or 2 relays. N-relay routing
  (relay-a → relay-b → relay-c) is untested.
- **No mixed-client cross-host topology** — no topology combines a real kimi
  with a real opencode/codex peer across two different hosts/relays.
- **No wire-format interoperability test** — kimi → codex or kimi → opencode
  DMs across hosts are not exercised.
