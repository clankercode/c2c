# #35 Phase 2 — Kimi adapter on machine-wide deliver-service

Status: **implementation plan** (research only; no production code in this change).
Date: 2026-07-20
Branch / worktree: `plan/35-phase2-kimi-adapter` @ `.worktrees/35-phase2-kimi`
Depends on: #35 design sketch (`.collab/design/35-machine-wide-delivery-service.md`) **phase 1 scaffold**
  (`c2c start deliver-service` / `c2c_deliver_managed.ml`, machine lock, self-heal, doctor stub —
  sibling of `ocaml/cli/c2c_relay_managed.ml`).
Does **not** replace the per-alias `C2c_kimi_notifier` daemon until phase 3.

## Goal

Ship the first end-to-end adapter on the machine-wide deliver-service: **kimi**,
mapping to the existing REST path (`POST /api/v1/sessions/{id}/prompts`),
running **alongside** the per-alias notifier behind an explicit flag, and proving
wake e2e (including supervisor gap recovery) before any migration off the daemon.

Phase 2 success = service can wake managed (and vanilla-recorded) kimi sessions
when the flag is on, without regressing the current notifier path when the flag
is off, and without double-injecting peer DATA into a live session.

## Why kimi first

- REST is the simplest probe+push surface already factored as
  `C2c_kimi_deliver` + `C2c_kimi_notifier.deliver_via_rest` / `run_once`.
- #9 (never-armed) and #42 (inverse leak / uuid-mint orphan) hurt most on kimi;
  the service watch-set is the structural fix for both.
- Comments in `c2c_kimi_notifier.ml` already anticipate a machine-wide watcher
  that supplies per-session `workdir` rather than inheriting cwd (#36).

## Non-goals (this phase)

- Deleting or default-disabling `C2c_kimi_notifier` daemons (phase 3).
- Codex / agy / OpenCode adapters (phases 4+).
- Cross-UID delivery, remote endpoints, or centralizing secrets in the registry.
- Changing B098 (no new message-triggered effects; no approval-from-DM).
- Making deliver-service the default arm path for `c2c start kimi`.

---

## 1. Prerequisites (phase 1 assumed)

Phase 1 must already provide (or land immediately before phase 2):

| Piece | Template | Phase-2 need |
|---|---|---|
| Machine singleton lock | `C2c_singleton_lock` + `relay-connect` resource under `~/.local/share/c2c/` | Distinct resource: `deliver-service` (sibling, not shared lock) |
| Supervised owner | `C2c_relay_managed.run_owner` / `supervise` | `c2c start deliver-service` with binary-stamp restart + child respawn |
| Managed config shape | `{client:"relay-connect", scope:"machine", supervised:true, …}` | `{client:"deliver-service", scope:"machine", supervised:true, adapters:[…], flags:…}` |
| Doctor stub | `c2c doctor --relay` pattern | `c2c doctor deliver` (or section): service up? lock held? adapter flags? |
| Log / pid paths | `instances/relay-connect/{outer.pid,log,config.json}` | `instances/deliver-service/…` |

If phase 1 is incomplete, implement the minimal scaffold **in the same PR series**
as the kimi adapter only to the extent needed to host one adapter tick loop —
do not expand into multi-adapter polish.

---

## 2. Adapter interface → existing REST mapping

Design sketch interface (normative for this phase):

```ocaml
module type DELIVERY_ADAPTER = sig
  val kind : string
  (** Liveness of the *endpoint* (server up? session resolvable?) —
      PRECONDITION distinct from "message delivered". *)
  val probe : endpoint -> [ `Live | `Dead of string | `Unknown ]
  (** Push one message. MUST be idempotent-safe and B098-preserving. *)
  val deliver : endpoint -> C2c_mcp.message -> (unit, string) result
end
```

### 2.1 Kimi endpoint record

Registration-side (optional field on broker registration — extend, do not
replace, existing YAML shape):

```text
delivery_endpoint = {
  kind = "kimi";
  (* Adapter-specific; secrets by reference only *)
  rest_base_ref = "live-lock" | "env:C2C_KIMI_SERVER_PORT" | "explicit:<url>";
  (* REST path component: real kimi session UUID when known *)
  kimi_session_id = "<uuid>" option;   (* may be filled later by hook record *)
  (* Workspace key for resolve_kimi_session_id / session_index (#36, #41) *)
  workdir = "<abs path>";              (* usually reg.cwd *)
  (* Broker drain key: managed default = instance name (#40) *)
  broker_session_id = "<session_id>";  (* reg.session_id *)
  alias = "<alias>";
  bearer_ref = "kimi-server-token";    (* path via C2c_kimi_deliver.server_token_path *)
  tmux_pane = None;                    (* phase 2: no composer wake; REST only *)
}
```

**Bearer/secrets by reference, never inline in the registry** (design + #48
same-UID note). Token read stays inside `C2c_kimi_deliver.read_server_token`.

Vanilla sessions: SessionStart hook (`c2c hook kimi`) writes what it can —
at minimum `workdir` + recorded kimi sid (`record_kimi_session_id`). Managed
launcher already has alias/session_id/cwd at register time
(`register_managed_kimi_session`).

### 2.2 Map `probe` / `deliver` onto existing modules

| Adapter op | Implementation (reuse, don't reimplement wire) | Notes |
|---|---|---|
| `kind` | `"kimi"` | |
| `probe` | `C2c_kimi_deliver.server_base_url` → `address_is_live`; then resolve sid via `C2c_kimi_notifier.resolve_kimi_session_id ~cwd:workdir` (or cached `kimi_session_id` if still valid) | `` `Dead `` if no live server; `` `Unknown `` if server live but sid unresolvable (session may still be starting — #41 lag); `` `Live `` only when both server live and sid resolvable |
| `deliver` | Build/use `C2c_kimi_deliver.deliver_message ~session_id ~msg` (same envelope as today: `message_envelope`) | Same wire behavior as `deliver_via_rest` without the per-daemon `ensure_kimi_server_running` side effects unless we deliberately keep that (rec: call ensure only on probe failure path, rate-limited — avoid N sessions spawning N servers) |

**Drain semantics stay outside the adapter.** The adapter is pure
endpoint I/O. The service core owns:

1. watch-set membership,
2. which broker inbox to peek,
3. whether to remove a message after successful `deliver`,
4. dual-run arbitration with the per-alias notifier (section 4).

### 2.3 What NOT to put in the adapter

- Alias-keyed pidfile / `ensure_daemon` / `decide_notifier_rekey` — daemon
  lifecycle stays in `C2c_kimi_notifier` until phase 3.
- tmux composer wake (`C2C_KIMI_TMUX_COMPOSER_WAKE`) — opt-in legacy; service
  path is REST-only (primary wake today).
- Approval / await-reply / any scheduling effect — B098 (section 6).
- Destructive `drain_inbox` for the per-repo broker — keep peek + rewrite
  undelivered (`run_once` pattern) so failed POSTs remain retryable (#484 S1).

### 2.4 Suggested module layout

```text
ocaml/c2c_deliver_adapter.mli          (* DELIVERY_ADAPTER + endpoint types *)
ocaml/c2c_deliver_adapter_kimi.ml      (* probe/deliver → C2c_kimi_deliver *)
ocaml/cli/c2c_deliver_managed.ml       (* phase 1 scaffold + phase 2 tick loop *)
(* DO NOT fork run_once into a third copy — extract a shared pure helper if
   service core and notifier both need the same peek→partition→deliver→rewrite
   sequence under dual-run. Candidate: C2c_kimi_notifier.run_once already takes
   explicit workdir; service calls it or a thinner drain_and_deliver shared fn. *)
```

Prefer **calling** `C2c_kimi_notifier.run_once` / `poll_once_global` from the
service tick for parity with `c2c_deliver_inbox.poll_once_kimi`, rather than
reimplementing partition/system-event rules. The adapter's `deliver` is then
the seam used *inside* that path (refactor `deliver_via_rest` to go through
the adapter module) so wire behavior stays single-sourced.

---

## 3. Watch-set rebuild rules (fail open)

Each service tick (default interval ~1–2s, same order as notifier):

### 3.1 Sources

1. Scan known broker roots (per-repo under `~/.c2c/repos/*/broker`, plus
   sessions broker `C2c_repo_fp.resolve_sessions_broker_root`, honoring
   `C2C_MCP_BROKER_ROOT` / `C2C_STATE_HOME` the same way registration does).
2. `Broker.list_registrations` per root.
3. Select candidates:
   - `client_type = Some "kimi"`, **or**
   - `delivery_endpoint.kind = "kimi"` when the field exists, **or**
   - (compat) rows the service previously watched that still have a live
     endpoint binding file under kimi session records — only as a soft
     supplement, not the sole source.

### 3.2 Build entry

For each candidate:

```text
{
  broker_root;
  broker_session_id = reg.session_id;
  alias = reg.alias;
  workdir = reg.cwd | delivery_endpoint.workdir;  (* required for #36 *)
  kimi_session_id = resolve or recorded;
  endpoint = …;
}
```

Skip entry (with structured log) if `workdir` is missing — cannot deliver
correctly without it (#36). Do **not** fall back to service process cwd.

### 3.3 Fail-open rules (normative)

| Failure | Behavior | Rationale |
|---|---|---|
| One broker root unreadable / lock timeout | Keep **previous** watch entries for that root; continue other roots | One wedged broker must not empty the machine-wide set |
| Malformed registration row | Skip that row; keep others | Same |
| `probe` → `` `Dead `` / `` `Unknown `` | Keep in watch-set; skip deliver this tick; emit metric/log | Transient start (#41) and server blips; dropping would recreate #9 |
| `probe` exception | Treat as `` `Unknown ``; never remove from set on exception | Fail open |
| Session row gone from registry | Drop from watch-set **only if** also no reclaimable managed sticky binding for that workdir (see #40/#47 sticky alias). Prefer delayed drop (N consecutive misses, e.g. 3–5 ticks) | Avoid flap during rewrite races |
| Global scan exception | Retain entire previous watch-set; log once per incident | Machine-wide empty set = total deafness — worse than stale |
| New session appears mid-tick | Visible next rebuild — no sticky "armed once" state | Closes #9 class |

**Fail open means: prefer stale-but-trying over empty-and-silent.** The
inverse of fail-closed signaling (we still fail closed on *identity* when
stopping foreign pids — that stays in the notifier stop path).

### 3.4 Reaping (partial; full #42 in phase 3)

Phase 2 watch-set drop when registration is gone is the *service-side* half of
reaping. Per-alias daemons may still leak until phase 3 deletes them; do not
claim #42 closed in phase 2. Doctor may report "service watching N; notifiers
running M" for dual-run visibility.

### 3.5 No freshness floor on the service

`set_session_freshness_floor` is per-daemon arm time. The machine-wide
watcher "serves many sessions and has no single session start" (existing
mli note). Service resolution must use:

- `record_kimi_session_id` / `read_kimi_session_record` as authority when present,
- index with **per-entry** workdir logic (`decide_kimi_session_id`),
- **no** process-wide floor that would incorrectly filter other sessions.

---

## 4. Flag / dual-run strategy

### 4.1 Flags (explicit, default off for service path)

| Flag / config | Default | Meaning |
|---|---|---|
| `C2C_DELIVER_SERVICE=1` or `c2c start deliver-service` running | off / not running | Supervisor up |
| `C2C_DELIVER_SERVICE_KIMI=1` **or** config `adapters.kimi = true` | **false** | Enable kimi adapter in the service tick |
| `C2C_DELIVER_SERVICE_KIMI_MODE` | `shadow` | `shadow` \| `active` \| `primary` (see below) |
| Per-alias notifier | **unchanged default on** for `c2c start kimi` | Phase 2 never stops arming it |

Doctor and `c2c start deliver-service` help text must state the mode clearly.

### 4.2 Modes (progression)

#### A. `shadow` (default when kimi adapter enabled)

- Service rebuilds watch-set, probes, peeks inboxes, **logs** what it would
  deliver (alias, sid, msg id / hash, probe result).
- **Does not** POST. **Does not** rewrite inboxes.
- Per-alias notifier remains sole deliverer.
- Acceptance: shadow log lines correlate 1:1 with notifier deliveries in dogfood
  (allowing timing skew ≤ one interval).

Purpose: prove watch-set + probe + resolution without dual-write risk
(learn from B013 codex double-writer lesson).

#### B. `active` (dual-run for reliability)

Both paths may run, but **only one may POST a given message**.

Arbitration (pick one; recommend claim-file):

1. **Claim-before-POST (recommended)**  
   For each message, attempt an exclusive claim under the broker or a
   sidecar claim dir keyed by deterministic `notification_id_for_msg` (already
   exists on notifier). Winner POSTs; loser skips. After `Ok`, winner rewrites
   inbox omitting that message (same peek→rewrite as `run_once`).  
   Claim TTL short (e.g. 30s) so a crashed claimer does not stuck-poison.

2. **DEAF-fallback only (simpler, less "dual")**  
   Service POSTs only when `not (C2c_kimi_notifier.already_running alias)`
   **or** doctor-class DEAF (inbox depth > 0 and no live notifier / notifier
   bound to wrong sid). Notifier still arms always.  
   Closes #9 during dual-run; does not exercise dual happy-path.

3. **Forbidden:** both POST without coordination — double user-turn injection
   (identity confusion / duplicate replies). Treat as release blocker.

`active` is the mode that must pass the kill-gap live tests (section 5).

#### C. `primary` (pre-migration; optional late phase 2)

- Service owns drain for kimi watch-set members.
- Notifier still **armed** but should no-op when it detects service primary
  (e.g. env `C2C_DELIVER_SERVICE_KIMI_MODE=primary` inherited, or a machine
  statefile `deliver-service/primary.kimi`). Fail open: if service lock not
  held, notifier delivers (avoid total deafness on service down).
- Phase 3 flips default arm to "don't start notifier" once `primary` is
  live-proven.

### 4.3 Dual-run product rule

> Alongside means **flag-gated coexistence with single-writer delivery**, not
> two unsupervised POSTers. B013 is the cautionary tale.

### 4.4 Arming relationship during phase 2

`c2c start kimi` continues to call `ensure_daemon` (#40 authoritative). Service
discovery is registration-driven; no requirement that the notifier be up for
the service to see the session (that's the #9 fix). Teardown (`c2c stop`)
still stops notifiers via `teardown_kimi_notifiers_for_stop`; service drops
the watch entry on rebuild.

---

## 5. Tests

### 5.1 Hermetic (Alcotest / fixture-gated)

All external effects gated (`C2C_KIMI_DELIVER_FIXTURE=1`, existing notifier
SHA fixtures, temp `C2C_INSTANCES_DIR` / broker roots). Prefer pure functions
extracted for:

| Case | Assert |
|---|---|
| Endpoint parse / kind routing | kimi endpoint → kimi adapter |
| `probe` matrix | live lock + sid → `` `Live ``; dead port → `` `Dead ``; live port no sid → `` `Unknown `` |
| Watch-set rebuild fail-open | one bad broker root does not clear good entries; exception retains previous set |
| Watch-set delayed drop | single missing registration does not drop; N misses does |
| Claim / single-writer | two concurrent "deliver" attempts → one POST (fixture counter), one skip |
| Shadow mode | zero calls to `submit_prompt` |
| System-event partition | `c2c-system` not POSTed (parity with `is_system_event`) |
| Workdir required | missing cwd → skip entry, no `Sys.getcwd` fallback |
| No process-wide freshness floor | two sessions different arm times both resolve via records |
| B098: deliver does not touch verdict paths | unit: temp approval dir unchanged after deliver |
| Mode flag parsing | default shadow; invalid mode → safe default + log |

Refactor seam tests can live next to `test_c2c_kimi_notifier.ml` /
`test_c2c_kimi_deliver.ml`; new file e.g. `test_c2c_deliver_adapter_kimi.ml`.

### 5.2 Live / e2e (tmux + `scripts/c2c_tmux.py`)

Reuse wake bar from `.collab/plans/e2e-waking-delivery-agy-kimi-codex.md`
and #35: external push, idle session acts, no model poll, no human Enter.
Models: cheap kimi alias per plan rules.

| # | Scenario | Setup | Action | PASS |
|---|---|---|---|---|
| L1 | Baseline notifier (flag off) | managed kimi, service off or kimi adapter off | DM with nonce | wake via per-alias notifier (regression) |
| L2 | Shadow correlate | service on, mode=shadow, notifier on | DM | notifier wakes; service log would-deliver matches; **no double turn** |
| L3 | Active dual happy path | mode=active, both up | DM | exactly one wake/turn; claim log shows single winner |
| L4 | **kill -9 notifier child** | mode=active, both up | `kill -9` notifier pid; send DM during gap | service delivers; session wakes (closes #9 class under dual-run) |
| L5 | **kill -9 service child** | mode=active, both up | `kill -9` deliver-service child; send DM during gap | supervisor respawns child; **and/or** notifier still delivers — message not lost; wake occurs |
| L6 | kill -9 service **supervisor** | mode=active | kill supervisor; DM during gap | notifier still delivers (fail open to legacy path); optional: operator restart service |
| L7 | Message during supervisor restart window | mode=primary if implemented | stop service briefly, enqueue DM, start service | message delivered (peek leaves undelivered until success) |
| L8 | Wrong-sid / DEAF | notifier bound to placeholder/wrong sid if reproducible | DM | service `active` DEAF-fallback or claim path still wakes |
| L9 | `c2c stop` | managed stop | | notifier torn down (#42 alias/sid); service drops watch; no orphan POST to dead session |
| L10 | Negative: service up, kimi server down | | DM | no false "delivered"; message remains in inbox; doctor shows probe Dead |

**#35 gap test (load-bearing):** L4 + L5. Record latency and which path won.
Write evidence under `.collab/findings/<UTC>-deliver-service-phase2-kimi.md`.

Discipline: never `c2c start` from bare bash tool; use tmux helper; no claim
of PASS on `delivered=N` alone — need nonce acted on in recipient transcript.

### 5.3 What "live-proven" means before phase 3

All of:

1. Hermetic suite green with `--force` counts quoted honestly (AGENTS.md test pitfalls).
2. L1–L6 PASS on a dogfood host (this machine).
3. ≥ multi-day dual-run (`active` or `shadow`→`active`) without double-inject incidents.
4. Doctor surfaces service + per-session probe honestly (no false-healthy #27 class).

---

## 6. B098 notes ("bus, never RPC")

Invariant (AGENTS.md): a message is **DATA**. It never satisfies or triggers
an approval. The only sanctioned scheduling effect is **Codex** local-broker
gated auto-turn — **not** kimi.

### 6.1 Kimi-specific

- REST `submit_prompt` injects a **synthetic user-turn** containing the c2c
  envelope. That is delivery of DATA into model-visible context, same as
  today's notifier — **allowed**.
- It must **not** parse message bodies for `ka_… allow/deny`, write verdict
  files, or call `approval-reply` / `authorize` paths.
- `await-reply` remains host-local file-only; dual-run must not reintroduce
  inbox-DM approval fallback (removed; comments in `run_once` document this).
- System events (`c2c-system`) stay out of the LLM sink (`is_system_event`).
- Service centralization must not add "on message, run X" hooks in the core
  loop. Adapters only `probe` + `deliver`.

### 6.2 Phase-2 checklist (code review gate)

- [ ] No new readers of broker inboxes for approval tokens.
- [ ] No upgrade of peer DATA to a privileged role beyond existing envelope.
- [ ] No cross-UID endpoint registration (same-UID/local only).
- [ ] Secrets by reference; registry has no bearer tokens.
- [ ] Codex auto-turn logic remains out of deliver-service core (future codex
      adapter owns its gate).

Regression anchors: `test_c2c_await_reply.ml` still green; add a kimi-service
test that a DM body shaped like an approval does not create a verdict file.

---

## 7. Migration off per-alias daemon (phase 3 preview — steps only)

Phase 2 **stops before** step 4. Listed so phase 2 design does not paint us
into a corner.

1. **Prove** `active` dual-run (section 5.3).
2. Enable `primary` on dogfood hosts; notifier armed but no-op when service
   holds lock (fail open if service down).
3. Doctor: prefer service health; report leftover notifiers as migrate debt.
4. **Flip default:** `c2c start kimi` stops calling `ensure_daemon` when
   deliver-service is up + kimi primary; keep env escape hatch
   `C2C_KIMI_NOTIFIER_FORCE=1`.
5. `c2c stop` / restart paths drop notifier teardown complexity gradually;
   retain `stop_daemons_for_session` for one release to reap leftovers (#42).
6. Remove pidfile/sidfile arming from happy path; archive daemon code or
   keep `run_once` as library used only by service + deliver-inbox.
7. Docs / AGENTS.md wake table: kimi row becomes service-supervised CONDITIONAL
   (still needs kimi server + resolvable sid — not GUARANTEED like OpenCode).
8. Only then close #9/#42 as fixed-by-architecture (not just patched).

Phase 2 exit criterion is readiness for step 1–2, not completion of 4–8.

---

## 8. Implementation sequence (phase 2 work breakdown)

1. **Types + adapter module** — `DELIVERY_ADAPTER`, kimi endpoint, probe/deliver
   wrapping `C2c_kimi_deliver`; hermetic probe tests.
2. **Watch-set builder** — pure rebuild with fail-open rules; unit tests with
   fixture registries.
3. **Service tick integration** — phase 1 loop calls kimi adapter when flag on;
   default `shadow`.
4. **Single-writer claim** (for `active`) — claim helper + tests; wire into
   shared drain path.
5. **Registration optional field** — write `delivery_endpoint` from managed
   kimi start + hook when cheap; service also derives from `client_type`+`cwd`
   so old binaries still get watched (compat).
6. **Doctor** — service up, mode, watch count, probe summary, notifier count.
7. **Live e2e** L1–L6; findings note.
8. **Docs** — design sketch status line → "phase 2 in progress"; link this plan;
   AGENTS.md delivery notes: dual-run flag, do not claim notifier removed.

Build/test discipline: `scripts/dune-build-locked.sh`, ≤2 threads, `--force`
for quoted counts, no stash-baseline without rebuild.

---

## 9. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Double REST inject under naive dual-run | **High** | Default `shadow`; `active` requires claim or DEAF-only; hermetic single-writer test; L3 asserts one turn |
| Empty watch-set on partial scan (total deafness) | **High** | Fail-open retain previous set; never clear-on-error |
| #41 sid lag → probe Unknown forever | Medium | Keep `` `Unknown `` in set; retry; use SessionStart record; don't require index line at t=0 |
| Service uses wrong workdir / cwd | **High** (silent misfile) | Forbid process cwd; require reg.cwd; tests |
| Claim stuck after kill -9 | Medium | Short claim TTL; peek leaves msg for retry |
| Phase 1 scaffold slips | Medium | Minimal sibling of relay-managed only; don't block adapter pure code |
| Operator thinks service replaces notifier while flag off | Medium | Doctor + start messages; docs |
| Global sessions broker double-path | Medium | Same claim id space or same single-writer rules for `poll_once_global` |
| Secret leakage into registry YAML | **High** | bearer_ref only; review gate |
| B098 regression via "helpful" core hooks | **High** | Adapter-only effects; review checklist |
| Test false green (AGENTS 8 pitfalls) | Medium | Explicit build, `--force`, no pipe exit mask, worktree `--root` |
| Inverse leak claimed fixed too early | Low (comms) | Phase 2 docs: reaping partial; phase 3 closes #42 |
| Resource cost: service tick × all brokers | Low | Start with registration-filtered kimi only; interval ≥1s; later inotify |

---

## 10. Open questions (do not block shadow mode)

1. **Claim store location** — broker-adjacent vs `~/.local/share/c2c/deliver-claims/`?
   Rec: under broker root next to inbox so multi-broker isolation is natural.
2. **Auto-start deliver-service** — `c2c install` / first `c2c start kimi` / manual only?
   Rec for phase 2: manual + documented; auto-start is product decision with phase 1.
3. **Vanilla kimi without cwd in registry** — watch or skip? Rec: skip with doctor
   hint; managed path is the e2e bar.
4. **Whether `c2c deliver-inbox --client kimi` should defer to service when primary** —
   defer to phase 3; phase 2 leave deliver-inbox as-is.

---

## 11. References

- Issue #35 body (machine-wide delivery service)
- `.collab/design/35-machine-wide-delivery-service.md` (phasing; adapter sketch)
- `ocaml/c2c_kimi_notifier.ml` / `.mli` — `run_once`, `deliver_via_rest`, daemon lifecycle, #9/#36/#40/#41
- `ocaml/c2c_kimi_deliver.ml` / `.mli` — `server_base_url`, `submit_prompt`, `deliver_message`, #39
- `ocaml/cli/c2c_relay_managed.ml` — supervised singleton template
- `ocaml/cli/c2c_deliver_inbox.ml` — `poll_once_kimi` already calls notifier `run_once`
- `.collab/plans/e2e-waking-delivery-agy-kimi-codex.md` — wake bar
- `.collab/findings/2026-06-26T14-50-51Z-B013-codex-deliver-two-paths-coexistence.md` — dual-writer hazard
- AGENTS.md — B098; kimi wake CONDITIONAL; test-result pitfalls

---

--- SUMMARY ---

- **What:** Phase 2 adds a **kimi** `DELIVERY_ADAPTER` on the machine-wide
  deliver-service (relay-managed sibling), mapping `probe`/`deliver` onto
  existing `C2c_kimi_deliver` REST (`/prompts` + token-by-ref), with watch-set
  rebuild from broker registrations.
- **Dual-run:** Flag-gated; default adapter mode **`shadow`** (log only).
  **`active`** allows coexistence only with **single-writer** arbitration
  (claim-before-POST recommended, or DEAF-fallback). Notifier keeps arming
  until phase 3. No naive double-POST (B013 lesson).
- **Fail open:** Partial scan/probe failures **retain** previous watch entries;
  never empty the machine set on error; delayed drop for missing rows; no
  process-wide kimi freshness floor; workdir mandatory (#36).
- **Tests:** Hermetic probe/watch-set/claim/B098; live L1–L6 including
  **kill -9 notifier** and **kill -9 service child** with DM during gap still
  waking. Live-proven bar before migration.
- **B098:** REST user-turn DATA injection OK; no approval/verdict/scheduling
  effects in service core; system events excluded.
- **Migration:** Phase 3 only after multi-day dogfood; steps to `primary` then
  stop arming daemons; phase 2 must not delete notifier path.
- **Risks:** double inject, empty watch-set, wrong workdir, claim stuck, secrets
  in registry — each has an explicit mitigation above.
- **Open:** claim path location, auto-start policy, vanilla-without-cwd — none
  block shadow mode.
