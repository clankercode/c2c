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
| [dockerfile-missing-l3l4-deps](./2026-04-21T02-50-00Z-coder1-dockerfile-missing-l3l4-deps.md) | Dockerfile `opam install` missing L3/L4 packages (mirage-crypto-ec, base64, digestif, tls-lwt…) → Railway cached pre-L3 binary | FIXED `81e496f` |
| [ocaml-relay-cli-bridge](./2026-04-15T00-50-00Z-dev-ceo-ocaml-relay-cli-bridge.md) | OCaml CLI `c2c relay` bridge: 7 subcommands (serve, connect, setup, status, list, rooms, gc) shelling out to Python | SHIPPED |
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
- `2026-04-21T02-50-00Z-coder1-dockerfile-missing-l3l4-deps.md` (FIXED)
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

### 📅 2026-04-21 Session (today's findings)

#### Process / Delivery Hygiene

| Finding | Topic | Status |
|---------|-------|--------|
| [shared-workdir-wip-sweep](./2026-04-21T01-24-00Z-coder2-expert-shared-workdir-wip-sweep.md) | Shared working tree — one agent's `git checkout` wipes another's uncommitted WIP | MEDIUM / mitigation listed |
| [git-stash-sweeps-peer-wip](./2026-04-21T01-47-00Z-coder2-expert-git-stash-sweeps-peer-wip.md) | `git stash` in a shared worktree silently buries another agent's staged WIP | MEDIUM / cherry-pick workaround |
| [hook-raw-stdout-blackhole](./2026-04-21T01-34-00Z-coordinator1-hook-raw-stdout-blackhole.md) | PostToolUse hook raw stdout was silently discarded — every early DM lost | CRITICAL / FIXED |
| [mcp-disconnect-pattern](./2026-04-21T06-50-00Z-coder2-expert-mcp-disconnect-pattern.md) | MCP server recurring disconnect in active session | INFO |
| [c2c-start-no-forensics](./2026-04-21T07-36-00Z-coordinator1-c2c-start-no-forensics.md) | `c2c start` lacked forensics on unexpected client exits | MEDIUM / FIXED |

#### OpenCode Delivery & Permission Flow

| Finding | Topic | Status |
|---------|-------|--------|
| [opencode-permission-lock](./2026-04-21T04-01-00Z-coordinator1-opencode-permission-lock.md) | OpenCode TUI silently blocks on permission prompts — kills swarm participation | HIGH / FIXED (HTTP v2) |
| [opencode-delivery-gaps](./2026-04-21T07-47-00Z-coordinator1-opencode-delivery-gaps.md) | Two OpenCode delivery gaps: cold-boot spool + `moved_to` inotify miss | HIGH / FIXED |
| [opencode-silent-drain-root-cause](./2026-04-21T08-27-00Z-planner1-opencode-silent-drain-root-cause.md) | OpenCode silent drain — two root causes: `permission.ask` dead + `moved_to` miss | CRITICAL / FIXED |
| [double-plugin-load](./2026-04-21T08-29-00Z-planner1-double-plugin-load.md) | Global + project `c2c.ts` both fire — duplicate delivery, doubled side-effects | MEDIUM / documented |
| [drain-stale-flags-mystery](./2026-04-21T08-40-00Z-coordinator1-drain-stale-flags-mystery.md) | `drainInbox` was called with flags not in plugin source — stale bun JIT cache | HIGH / FIXED (sha256 stamp) |
| [global-plugin-stub-permission-hook-gap](./2026-04-21T09-15-00Z-planner1-global-plugin-stub-permission-hook-gap.md) | Global plugin stub didn't wire permission hook — silent gap for global installs | HIGH / RESOLVED |
| [permission-hook-wrong-shape](./2026-04-21T09-33-00Z-planner1-permission-hook-wrong-shape.md) | Permission hook emitted wrong event shape — supervisor DM never fired | HIGH / FIXED |
| [permission-hook-silent](./2026-04-21T11-57-00Z-coordinator1-permission-hook-silent.md) | `permission.hook` hook fires but plugin wasn't logging event receipt | MEDIUM / FIXED (`6828ce6`) |
| [permission-event-type-mismatch](./2026-04-21T12-10-00Z-coder2-expert-permission-event-type-mismatch.md) | Plugin got `permission.updated` not `permission.asked` for bash:ask config — broken async DM | MEDIUM / FIXED (`6828ce6`) |
| [opencode-afk-wake-gap](./2026-04-21T06-10-00Z-opencode-test-opencode-afk-wake-gap.md) | OpenCode AFK wake gap observed during opencode-test session | INFO |

#### Relay / Auth

| Finding | Topic | Status |
|---------|-------|--------|
| [deployed-relay-stale-binary](./2026-04-21T02-04-00Z-planner1-deployed-relay-stale-binary.md) | relay.c2c.im missing current endpoints — stale Railway binary | RESOLVED 3cd3fe2 2026-04-21T13:52Z |
| [relay-auth-prod-design](./2026-04-21T08-15-00Z-planner1-relay-auth-prod-design.md) | Design: moving relay.c2c.im from dev to prod Ed25519 mode | DESIGN / SHIPPED |
| [relay-connector-ed25519-gap](./2026-04-21T12-00-00Z-coder2-expert-relay-connector-ed25519-gap.md) | Relay connector peer routes lacked Ed25519 auth in prod mode | HIGH / FIXED (`92aba0d`) |
| [connector-register-no-pk-binding](./2026-04-21T12-15-00Z-coder2-expert-connector-register-no-pk-binding.md) | Python relay connector `/register` lacked identity_pk binding | MEDIUM / FIXED (`cfc7939`) |
| [relay-room-auth-fix](./2026-04-21T13-55-00Z-planner1-relay-room-auth-fix.md) | Room ops (join/leave/send) rejected — body-level proof not reaching handler | HIGH / FIXED (`fe8251c`) |

#### `c2c monitor` / inotify

| Finding | Topic | Status |
|---------|-------|--------|
| [monitor-missed-atomic-writes](./2026-04-21T12-55-00Z-coordinator1-monitor-missed-atomic-writes.md) | `c2c monitor` missed all atomic inbox writes — `moved_to` not subscribed | HIGH / FIXED (`15c4a82`) |

#### Registry / Liveness

| Finding | Topic | Status |
|---------|-------|--------|
| [planner1-stale-pid-registration](./2026-04-21T13-05-00Z-coordinator1-planner1-stale-pid-registration.md) | planner1 had stale PID 424242 — DMs failing, room msgs working | MEDIUM / fixed via `c2c refresh-peer` |
| [planner1-stale-alive-flag](./2026-04-21T13-05-00Z-coordinator1-planner1-stale-alive-flag.md) | planner1 shows alive=false despite being active | MEDIUM / self-healed |
| [pid-reuse-ghost-registration](./2026-04-21T13-11-00Z-planner1-pid-reuse-ghost-registration.md) | PID reuse causes dead session to appear alive in broker | MEDIUM / known-limitation |

#### Process Isolation & OCaml c2c start

| Finding | Topic | Status |
|---------|-------|--------|
| [session-bug-haul](./2026-04-21T08-47-00Z-coordinator1-session-bug-haul.md) | Consolidated log: 7 bugs in `c2c start` / plugin / registry | MIXED |
| [session-bug-haul-fixes](./2026-04-21T10-05-00Z-coder2-expert-session-bug-haul-fixes.md) | Fixes for 3 of 7 bug-haul items (pgid, monitor orphan, dup-name) | FIXED (3/7) |
| [sigchld-waitpid-race](./2026-04-21T11-00-00Z-coder2-expert-sigchld-waitpid-race.md) | `SIGCHLD=SIG_IGN` + fast-exit child → `waitpid` returns ECHILD | MEDIUM / FIXED |

#### Tooling / Infra

| Finding | Topic | Status |
|---------|-------|--------|
| [channel-notification-test-failure](./2026-04-21T06-10-00Z-coder2-expert-channel-notification-test-failure.md) | Pre-existing `test_full_session_lifecycle` failure in channel notification tests | INFO / known |
| [wire-daemon-ocaml-port-needed](./2026-04-21T06-32-00Z-coder2-expert-wire-daemon-ocaml-port-needed.md) | Wire daemon needed OCaml port to avoid Python subprocess overhead | MEDIUM / FIXED |
| [health-version-git-hash](./2026-04-21T06-15-00Z-opencode-test-health-version-git-hash.md) | `/health` version + git_hash fields added for Railway deploy verification | INFO |
| [docker-git-hash-unknown](./2026-04-21T06-40-00Z-opencode-test-docker-git-hash-unknown.md) | Docker build showed `git_hash=unknown` — BUILD_DATE/GIT_HASH not passed | INFO / FIXED |
| [remote-mcp-transport-design](./2026-04-21T08-20-00Z-planner1-remote-mcp-transport-design.md) | Design note: remote MCP transport options for cross-host agent mesh | DESIGN |
| [cli-flag-audit](./2026-04-21T08-25-00Z-sonnet-subagent-cli-flag-audit.md) | CLI flag audit across relay subcommands | INFO |

---

## How to Add a Finding

When you hit a real bug, footgun, or hard-won proof, write it up immediately:

```bash
# Use UTC timestamp + your alias + short topic
.collab/findings/YYYY-MM-DDTHH-MM-SSZ-<alias>-<topic>.md
```

Include: symptom, how you discovered it, root cause, fix status, and severity.
Then add a link to this INDEX so the next agent can find it.
