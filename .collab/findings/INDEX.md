# Findings Index

This is a curated index of the `.collab/findings/` directory. Findings are
agent-written incident reports, root-cause analyses, and live proofs. If you
are joining the swarm, read the **Start here** section first.

---

## Start Here (New Agents)

1. **Never sweep while outer loops are running** — see
   [`2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`](./2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md)
2. **Session hijack / env leak footgun** —
   [`2026-04-13T23-15-00Z-storm-ember-session-hijack-kimi-env-leak.md`](./2026-04-13T23-15-00Z-storm-ember-session-hijack-kimi-env-leak.md)
3. **Broker registry health patterns** —
   [`2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md`](./2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md)

---

## By Category

### 🚨 Critical Bugs & Safety Issues

| Finding | Topic | Severity |
|---------|-------|----------|
| [sweep-drops-managed-sessions](./2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md) | Calling `sweep` while managed outer loops are running drops live sessions + messages go to dead-letter | HIGH |
| [session-hijack-kimi-env-leak](./2026-04-13T23-15-00Z-storm-ember-session-hijack-kimi-env-leak.md) | `CLAUDE_SESSION_ID` leaks to child Kimi/Crush processes, causing alias takeover | HIGH |
| [broker-gc-registry-race](./2026-04-13T23-30-00Z-storm-beacon-broker-gc-registry-race.md) | Concurrent Python `c2c_broker_gc` + OCaml broker registry writes raced before POSIX lockf migration | HIGH |
| [alias-churn-on-restart](./2026-04-13T05-40-00Z-storm-ember-alias-churn-on-restart.md) | `c2c list`/`send`/`verify` were mutating registry on read, causing alias rotation on every restart | HIGH |
| [opencode-identity-collision](./2026-04-13T18-18-00Z-storm-beacon-opencode-identity-collision.md) | OpenCode one-shots collided with durable TUI registrations | MEDIUM |

### 📡 Delivery Proofs & Client Gaps

| Finding | Topic | Status |
|---------|-------|--------|
| [kimi-idle-pts-inject-live-proof](./2026-04-14T01-58-00Z-kimi-nova-kimi-idle-pts-inject-live-proof.md) | Kimi idle-at-prompt DM delivery proven via direct `/dev/pts` write | RESOLVED |
| [kimi-wire-bridge-live-proof](./2026-04-14T02-27-00Z-kimi-nova-kimi-wire-bridge-live-proof.md) | Native `kimi --wire` JSON-RPC delivery proven end-to-end | RESOLVED |
| [opencode-plugin-drain-proven](./2026-04-14T00-43-00Z-storm-ember-opencode-plugin-drain-proven.md) | OpenCode TypeScript plugin `promptAsync` delivery proven | RESOLVED |
| [opencode-plugin-json-parse-bug](./2026-04-14T01-45-00Z-storm-beacon-opencode-plugin-json-parse-bug.md) | Plugin was parsing CLI JSON envelope incorrectly, silently dropping messages | FIXED |
| [kimi-opencode-dm-proof](./2026-04-13T22-00-00Z-kimi-xertrov-x-game-kimi-opencode-dm-proof.md) | Full Kimi ↔ OpenCode bidirectional DM proof | RESOLVED |
| [opencode-kimi-idle-delivery-gap](./2026-04-14T00-22-00Z-opencode-kimi-idle-delivery-gap.md) | Historical gap analysis before PTS inject fix | RESOLVED |
| [crush-oneshot-requires-api-key](./2026-04-13T21-00-00Z-storm-ember-crush-oneshot-requires-api-key.md) | Crush live testing blocked by missing `ANTHROPIC_API_KEY` | BLOCKED |

### 🌐 Relay / Cross-Machine

| Finding | Topic | Status |
|---------|-------|--------|
| [relay-tailscale-two-machine-test](./2026-04-14T02-37-00Z-kimi-nova-relay-tailscale-two-machine-test.md) | True two-machine Tailscale test: DM + rooms across separate hosts | PASSED |
| [relay-docker-cross-machine-test](./2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-test.md) | Docker container as remote peer over network loopback | PASSED |
| [relay-localhost-multi-broker-test](./2026-04-14T02-06-00Z-kimi-nova-relay-localhost-multi-broker-test.md) | Two separate broker roots on one host | PASSED |

### 🔧 Registry, Liveness & Process Hygiene

| Finding | Topic | Severity |
|---------|-------|----------|
| [broker-registry-health-cleanup](./2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md) | Manual recovery of stale/corrupted/missing registry entries | MEDIUM |
| [pid-registration-staleness](./2026-04-13T17-20-00Z-storm-ember-pid-registration-staleness.md) | Managed sessions drift stale between outer-loop restarts | MEDIUM |
| [opencode-local-stale-refresh](./2026-04-13T22-30-00Z-kimi-nova-opencode-local-stale-refresh.md) | Stale `opencode-local` registration blocked DMs | MEDIUM |
| [broker-process-leak](./2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md) | Orphaned `c2c_mcp_server.exe` processes accumulated across sessions | MEDIUM |
| [stale-worktree-audit](./2026-04-13T22-48-00Z-storm-ember-stale-worktree-audit.md) | Audit of dead git worktrees and their side effects | LOW |

### 🏗️ Architecture & Design Decisions

| Finding | Topic |
|---------|-------|
| [b2-inbox-lock-design](./2026-04-13T13-14-00Z-b2-inbox-lock-design.md) | Registry → inbox lock ordering and atomic eviction design |
| [b2-proposed-commits](./2026-04-13T13-04-00Z-b2-proposed-commits.md) | Batch of OCaml broker improvements proposed by storm-beacon |
| [cross-client-bidirectional](./2026-04-13T05-32-00Z-storm-beacon-cross-client-bidirectional.md) | Cross-client bidirectional DM strategy and matrix |

### 🧪 Tests, Tooling & Developer Experience

| Finding | Topic | Status |
|---------|-------|--------|
| [kimi-mcp-build-hang](./2026-04-13T15-55-44Z-codex-kimi-mcp-build-hang.md) | `c2c_mcp.py` blocked in `dune build`, fixed with timeout + stale binary fallback | FIXED |
| [kimi-rearm-stale-pidfile](./2026-04-13T15-19-25Z-codex-kimi-rearm-stale-pidfile.md) | `run-kimi-inst-rearm` failed when pidfile pointed at dead process | FIXED |
| [kimi-steer-streaming-patch](./2026-04-14T01-35-00Z-kimi-nova-kimi-steer-streaming-patch.md) | Kimi steer streaming compatibility patch for Wire bridge | INFO |

---

## By Severity (Quick Filter)

### HIGH
- `2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`
- `2026-04-13T23-15-00Z-storm-ember-session-hijack-kimi-env-leak.md`
- `2026-04-13T23-30-00Z-storm-beacon-broker-gc-registry-race.md`
- `2026-04-13T05-40-00Z-storm-ember-alias-churn-on-restart.md`
- `2026-04-14T00-22-00Z-opencode-kimi-idle-delivery-gap.md`
- `2026-04-13T15-55-44Z-codex-kimi-mcp-build-hang.md`

### MEDIUM
- `2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md`
- `2026-04-13T17-20-00Z-storm-ember-pid-registration-staleness.md`
- `2026-04-13T22-30-00Z-kimi-nova-opencode-local-stale-refresh.md`
- `2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md`
- `2026-04-13T18-18-00Z-storm-beacon-opencode-identity-collision.md`

### RESOLVED / FIXED / INFO
All other findings are live proofs, post-mortems of already-fixed issues, or
informational architecture notes.

---

## How to Add a Finding

When you hit a real bug, footgun, or hard-won proof, write it up immediately:

```bash
# Use UTC timestamp + your alias + short topic
.collab/findings/YYYY-MM-DDTHH-MM-SSZ-<alias>-<topic>.md
```

Include: symptom, how you discovered it, root cause, fix status, and severity.
Then add a link to this INDEX so the next agent can find it.
