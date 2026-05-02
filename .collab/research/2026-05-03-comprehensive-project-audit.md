# Comprehensive Project Audit — 2026-05-03

> Compiled by coordinator1 from 5 research agents + manual inspection.
> Requested by Max: "find and list all the things that we haven't yet done
> or which might be incomplete."

## Legend

- ✅ COMPLETE — code shipped, tests pass
- 🟡 PARTIAL — some slices done, work remains
- ❌ NOT STARTED — no implementation exists
- 🅿️ PARKED — blocked on external constraint

---

## A. Max's Explicit Priorities (from this conversation)

### A1. Headless GUI testing using WebUI driver
- **Status:** ❌ NOT STARTED
- **Current state:** GUI exists at `gui/` (Tauri + Vite + React + TypeScript). Has 3 unit tests (`gui/src/test/`), `vitest run` as test runner. NO Playwright, Puppeteer, Cypress, or WebDriver infrastructure exists. Galaxy-coder just fixed the GUI build (`bun install` was never run; 3 tsc errors fixed).
- **What's needed:**
  - Install Playwright or similar headless browser framework
  - WebUI driver harness for automated GUI interaction testing
  - Test scenarios: message send/receive, room panel, permission panel, archive view
  - CI integration (headless Chrome/Firefox in Docker)
- **Effort:** ~2-3 slices (framework setup, core test scenarios, CI integration)

### A2. E2E Docker-based testing for full feature suite
- **Status:** 🟡 PARTIAL — infrastructure exists, tests are pytest stubs
- **Current state:** 18 test files in `docker-tests/`, 7 docker-compose topologies (`docker-compose.yml`, `.4-client.yml`, `.test.yml`, `.two-container.yml`, `.2-relay-probe.yml`, `.agent-mesh.yml`, `.e2e-multi-agent.yml`), 3 Dockerfiles (`Dockerfile`, `.agent`, `.test`). Helper modules `conftest.py`, `_room_helpers.py`, `_signing_helpers.py`.
- **What's needed:**
  - Validate which tests actually pass vs. are stubs
  - Add kimi + opencode cross-host relay scenario
  - Add send_all encrypted broadcast E2E
  - Add room lifecycle E2E (create, join, send, leave, ACL)
  - CI runner integration
- **Effort:** ~3-4 slices (audit existing, add cross-host, add encryption, CI)

### A3. Kimi and OpenCode on different hosts talking via relay
- **Status:** ❌ NOT STARTED (as cross-host E2E test)
- **Current state:** `docker-tests/test_cross_host_relay.py` and `test_kimi_first_class_peer.py` exist but need validation. Relay is deployed on Railway. Kimi notification-store delivery works locally. No existing test for "kimi on host A + opencode on host B + relay in between + basic task completion."
- **What's needed:**
  - Docker compose with 2 separate containers (kimi + opencode) + relay
  - Scenario: register, exchange messages, verify delivery, basic task (e.g. "read a file and report back")
  - Verify E2E encryption works cross-host
- **Effort:** ~2 slices

---

## B. Incomplete Design Slices (awaiting implementation)

### B1. #432 Pending Permissions Hardening
- **Slice B** — `open_pending_reply` rejects unregistered callers, session-derived alias. ~150 LoC. ✅ COMPLETE (tests at test_c2c_mcp.ml:9136)
- **Slice C** — Capacity bounds (16 per-alias, 1024 global). ~50 LoC. ✅ COMPLETE (`pending_per_alias_cap=16`, `pending_global_cap=1024` in c2c_broker.ml:478)
- **Slice D** — Decision audit log in broker.log. ~80 LoC. ✅ COMPLETE (`pending_open`/`pending_check` events logged via `log_broker_event`)

### B2. #490 Approval Side Channel
- **Slice 5b** — CLI: `approval-pending-write`, `approval-list`, `approval-show`. Gated on 5a peer-PASS. ✅ COMPLETE (c2c.ml:5912-6126)
- **Slice 5c** — Notifier filter (suppress ka_* verdicts), TTL cleanup (`approval-gc`). Gated on 5b. ✅ COMPLETE

### B3. #671 Encrypted Broadcast
- **S1 per-recipient encryption** — ✅ COMPLETE (cherry-picked this session)
- **S2 deprecation audit** — ✅ COMPLETE
- **CLI `c2c send-all` plaintext gap** — Finding filed, fix NOT implemented. 🟡
  The CLI `send-all` subcommand bypasses `broadcast_to_all` and sends plaintext.

### B4. Hardening Series
- **Hardening B** — Shell launch location guard (`cwd` in registration + broker soft-warn). ✅ COMPLETE (#621 + #622: cwd added to registration schema + `check_worktree_mismatch` broker guard shipped)
- **Hardening C** — Pre-reset shim branch guard (refuse `git switch/checkout/rebase` in main tree). ✅ COMPLETE (shipped + installed)

### B5. c2c-native Scheduling
- **S1-S5** — ✅ COMPLETE (schedule set/list/rm/enable/disable, hot-reload, idle-gating)
- **S6** — MCP-server-side schedule timer for raw Claude Code sessions. ❌ NOT STARTED
  Design doc exists at `.collab/design/2026-05-02-mcp-server-schedule-timer.md`.

---

## C. Long-Running Projects (from todo-ongoing.txt)

### C1. CLI Command Test Coverage (#670)
- **Status:** 🟡 IN PROGRESS — ~14 CLI-only subcommands still untested
- **Untested:** agent list/delete/rename, config show/generation-client, roles validate, schedule enable/disable, worktree gc, doctor, install, peer-pass
- **All 35 MCP tools now have ≥1 test** (completed this session: +19 tests → 339 total)

### C2. Terminal E2E Framework
- **Status:** 🟡 — design + plan docs committed; incremental tests landing
- **Remaining:** Full terminal interaction testing harness (pty-based)

### C3. Remote Relay Transport v2
- **Status:** 🟡 — relay.toml exists, basic relay works, multi-broker deferred
- **Remaining:** relay.toml hot-reload, multi-broker federation, relay health dashboard

### C4. Relay-crypto Slice C (strict-flip)
- **Status:** 🅿️ PARKED — CRIT-1+2 fully closed; strict-flip deferred pending ops sign-off
- **What:** Flip relay to reject unsigned messages (currently warn-only)

### C5. Public-docs Accuracy
- **Status:** 🟡 — 5 issues filed (#350-#359); #350 awaiting peer-PASS; #356-#359 bundled
- **Remaining:** Peer-PASS on #350, bundle landing for #356-#359

### C6. Coord Workflow #352 — doctor migration-prompt
- **Status:** 🟡 — multiple landings; #352 doctor-migration-prompt unblocked; #328 scope-audit deferred

### C7. Mobile App (M1)
- **Status:** ❌ NOT STARTED (spec at `.projects/c2c-mobile-app/M1-breakdown.md`)
- **Scope:** Relay-side foundation for mobile E2E encrypted messaging (X25519 keypair, signed pubkey lookup, NaCl box, observer WebSocket, mobile pairing)
- **Blocked on:** Spec finalization (peer review cycle)

---

## D. Role Generation & Agent Files

### D1. Role Generation Pipeline (todo-role-gen-test.txt)
- **Stage 1** (Parser/renderer fidelity) — ✅ COMPLETE (6fd58719: arrays now round-trip correctly; `test_roundtrip_array_fields` added)
- **Stage 2** (`c2c agent new` template quality) — ✅ COMPLETE (c3f4f294: 37-line template improvement with inline comments/examples)
- **Stage 3** (Banner rendering) — ❌ banner.ml never invoked
- **Stage 4** (E2E OpenCode launch) — 🟡 mechanism exists, untested E2E
- **Stage 5** (E2E Claude Code launch) — ❌ untested
- **Stage 6** (Role migration) — 🟡 4/9 roles seeded; 6 test artifacts need cleanup
- **Stage 7** (Human polish review) — awaits Max sign-off
- **Stage 8** (Codex/Kimi renderers) — ❌ post-MVP

### D2. Missing Role Files
- security-review, qa, dogfood-hunter, release-manager, gui-tester — ❌ not authored

---

## E. Open Findings (unresolved)

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | HIGH | Permission reply didn't unstick OpenCode TUI (stale plugin) | Open |
| 2 | MED | Fresh Claude Code session idles without --auto | Open (needs decision) |
| 3 | LOW | Labeled stashes slot-shifted by coord-cherry-pick | Open |
| 4 | MED | coord-cherry-pick misses parent commits (explicit-tip-list) | Open |
| 5 | MED | c2c get-tmux-location race under concurrent invocation | ✅ FIXED (c2c.ml:2681 — prefers $TMUX_PANE per-pane var; concurrent-safe) |
| 6 | HIGH | "build clean" peer-PASS claim can be wrong (cached artifacts) | Open |
| 7 | LOW | git pre-commit hook output leaks into commit message body | Open |

---

## F. Todo Ideas (uningested)

| Idea | Status | Notes |
|------|--------|-------|
| PoW-gated email proxy for c2c.im | brainstorming | Design locked by Max; needs implementation |

---

## G. Miscellaneous Open Items

### G1. Auto Mail Drain Delay (todo2.txt)
- 30-60s delay before auto-drain fires — ❌ NOT STARTED
- OpenCode plugin to drain inbox via inotifywait — ❌ NOT STARTED

### G2. Channel-Push Tag Verification (#406 S3)
- 🅿️ PARKED — Docker PID namespace issue blocks E2E test

### G3. Flaky Test
- `test_session_id_set_correctly_without_duplicates` — races under full suite. Open.

### G4. Cold-boot E2E Validation (Bug #5)
- Committed but E2E validation not confirmed. 🟡

### G5. `c2c install opencode` fork-bomb protection
- Missing `C2C_CLI_COMMAND` env var. 🟡

### G6. GUI App System Dependency
- `webkit2gtk-4.1` not installed — blocks native Tauri build on this machine. 🅿️
- WebUI mode (browser-based) works without webkit2gtk.

---

## H. Prioritized Action Plan

### Tier 1 — Max's explicit asks (do now)
1. **Headless GUI testing** — set up Playwright, write core scenarios
2. **E2E Docker cross-host** — validate existing tests, add kimi+opencode relay scenario
3. **Kimi↔OpenCode relay task** — Docker compose with 2 hosts + relay

### Tier 2 — High-value completions
4. **CLI command test coverage (#670)** — ✅ DONE this session (2026-05-03)
5. **#432 Slice B** (pending perms auth) — ✅ ALREADY SHIPPED (prior session)
6. **Peer-PASS build verification** (finding #6) — tighten review-and-fix skill
7. **CLI send-all plaintext gap** (#671 follow-up) — 🟡 IN PROGRESS (stanza #671 S2)

### Tier 2 — Completions this session (2026-05-03)
- **#675 Docker audit** — ✅ DONE (jungle-coder audit committed)
- **#674 Cross-host kimi+opencode relay test** — ✅ DONE (`test_kimi_opencode_cross_host.py`)
- **#680 Docker docs** — ✅ DONE (`docs/docker-testing.md` committed bf5989d2)

### Tier 3 — Medium-priority
8. **#490 Slice 5b** (approval CLI surface)
9. **Role generation stages 1-3** (parser/renderer fidelity)
10. **c2c get-tmux-location fix** (finding #5, ~15 LoC)
11. **S6 MCP-server schedule timer**
12. **Hardening B** (cwd registration guard)

### Tier 4 — Low-priority / deferred
13. Auto mail drain delay (todo2.txt)
14. Mobile app M1 spec finalization
15. Relay-crypto strict-flip
16. PoW email proxy implementation

---

## I. Session Progress Record — 2026-05-03

Commits landed this session (HEAD, `bf5989d2` = master tip):

| SHA | One-liner |
|-----|-----------|
| `058cc2d7` | sitrep 14:00 UTC — test wave complete (320→339), all 35 MCP tools covered |
| `419d6a30` | sitrep 15:00 UTC — empty-hour marker, swarm dormant |
| `338df1b6` | feat(#671 S1): per-recipient encrypted broadcast in broadcast_to_all |
| `d3fcf88d` | fix(#671 S1): promote key_changed to top-level receipt array |
| `24700c79` | fix(#672): git shim spawn guard — self-exclusion + accurate counting |
| `07953d0c` | fix(#672): correct comment + fix pipefail edge case in spawn guard |
| `8bc945c3` | chore(#671 S2): mark Broker.send_all deprecated + file CLI gap finding |
| `8a111c5b` | feat(#670): CLI command test coverage — doctor, config show, agent list, roles validate |
| `b2409aec` | docs(#675): docker-tests/ suite audit — 16 real, 2 stubs, broker bug found |
| `817f0889` | test(#674): cross-host kimi+opencode relay E2E test |
| `103b3ae9` | sitrep 16:00 UTC + comprehensive project audit |
| `bf5989d2` | docs(#675): document Docker E2E test suite |

**Prior-session commits that landed this session (from earlier pushes):**
| SHA | One-liner |
|-----|-----------|
| `5e8c34d7`…`a3de8f75` | 131 commits pushed to origin/master — relay deploy live, test count 312→320, worktree GC (3 removed, 62MB freed) |

**Peer-PASS verdicts this session:**
- fern #450 S8 `eb4a1f32` — PASS
- cedar dedup log_broker_event `be414916` — PASS
- jungle relay_e2e Result fix `41cd112b` — PASS
- galaxy commands.md `466e8752`→`7b3bfe64` — FAIL→PASS (3 issues)
- broker-root resolution order `9e15b6e1` — PASS
- cedar #357b `b82ef41c` — PASS
- stanza compact tests `c58667e0` — PASS
- cedar prune_rooms test `2033b073` — PASS
- my-rooms E2E `fb05a67d`→`c1649e8d` — PASS (cherry-picked master)
- stanza #671 S1 `e436b0eb`+`891c467f` — PASS (test-agent review)
- stanza #672 shim `7305694b`+`6f6e4474` — PASS (test-agent review)

**Test count:** 313 → 339 (this session, MCP suite)
