# External Blockers — May 2026

## 1. #628: Channel-Push E2E — Docker PID Namespace

**Blocked**: End-to-end testing of `notifications/claude/channel` push delivery in Docker. Container PID namespaces prevent access to `/proc/<host_pid>` — the relay cannot verify that a delivered message surfaces as a transcript event in the host harness.

**What's needed**: Either (a) `--pid=host` added to Docker test invocation, (b) E2E harness runs on native host outside containers, or (c) in-process test that doesn't rely on PID liveness. **Max needs to decide which path** — this is an operational/infrastructure call, not a code design question.

---

## 2. M-Sized OCaml Refactors — Max's Architectural Sign-Off Needed

Three large modules need decomposition before slices can be safely opened:

| Module | LOC | Proposed split |
|--------|-----|----------------|
| `relay.ml` | 5,152 | `relay_inmemory` / `relay_sqlite` / `relay_server` / `relay_client` → thin re-export |
| `c2c_start.ml` | 5,443 | instance-spawn / tmux / schedule-watcher / model-res / restart-intro → separate modules |
| `c2c_broker.ml` | 3,741 | similar decomposition potential |

Also held: `#6 per-client setup scaffolding` — coupled to the same wave per cairn's audit.

**Max needs to decide**: Are the proposed splits the right direction? Any to avoid? Any to accelerate? Once Max says go/no-go, the swarm can open slices.
