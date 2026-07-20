# GH open-issue queue triage — 2026-07-20

**Scope:** open issues `#27 #35 #37 #50 #59 #63 #72 #73 #75 #76 #77` on
`clankercode/c2c`. Recently closed `#42 #48 #53 #74` skipped.

**Baseline:** local `master` @ `55ff2a92` (≈195 commits ahead of
`origin/master` @ `569bc0b1`; **not pushed** — all "FIXED_ON_MASTER"
verdicts below mean *local master*, not GitHub's remote tip).

**Method:** issue body + last comments via `gh`; code pointers and
`git merge-base --is-ancestor` against local `master`; no implementation
this pass (the two candidates for a <1h ship, `#72` and `#50`, are
already landed).

---

## Summary table

| # | Title (short) | Status | Evidence (local master) | Recommended next action |
|---|---|---|---|---|
| **27** | Codex silent deafness on post-launch hook/config drift | **PARTIAL** | Heartbeat+doctor+send: `e8344d17` / `206096db` / `eeecaac0`; degraded latch `#31`: `c65b4804`; launch preflight warn: `1e52004a` / `b822eb3b`. Still open: runtime detection of post-launch *hook-block* drift while still in hook mode; continuous in-session path self-check. Full machine-wide surface deferred to `#35`. | Leave open. Comment that launch-preflight half landed (`1e52004a`); keep as residual of post-launch drift + `#35` sender-surface. Do **not** close. |
| **35** | Machine-wide delivery service (endpoint registration) | **OPEN** (design landed) | Design sketch: `de73e7d5` → `.collab/design/35-machine-wide-delivery-service.md`. Safety: Codex auto-turn stays in-session (B098); Claude/Grok cannot be guaranteed. Blocked on cwd-free Kimi resolution (related `#36`). | Leave open as the north-star delivery architecture. Next: implement scaffold phase per design (supervised singleton + endpoint schema); do not attempt in a drive-by. |
| **37** | Grok has no guaranteed wake path | **UPSTREAM** | Docs honest: `AGENTS.md`/`CLAUDE.md` wake matrix rows Grok as **NONE** (CONDITIONAL only if agent armed `c2c monitor`). No local inject endpoint exists. | Leave open / mark as upstream. Optional small doc polish only. Real fix is an upstream Grok inject/file-change hook. Pair with `#59` (no activity-backed anchor). |
| **50** | `doctor` blind to missing Kimi SessionStart hook | **FIXED_ON_MASTER** (narrow scope) | `062b9222` / merge `aa99d320`: `check_kimi_session_start_hook` in `ocaml/cli/c2c_doctor_hooks.ml` (~L117, L851, L1319, L1443–1452, JSON `kimi_session_start_hook`). Umbrella "doctor cannot see silent degradation" still open as a *theme* (see issue comment table) but the filed Kimi check is done. | **Close** with comment below. File/keep separate issues for remaining doctor-blind rows if still wanted. |
| **59** | Grok/Kimi hook rows cannot decay (immortal ghosts) | **OPEN** (deliberate carve-out) | `ocaml/c2c_broker.ml` `hook_anchor_is_activity_backed` allowlist = `codex-hook \| claude-hook \| agy-hook` only (~L502–506). Grok/Kimi intentionally excluded: SessionStart/End-only → TTL would measure age not activity → silent mail loss. | Leave open. Next: empirically confirm mid-session hook events for Kimi/Grok, **or** probe Kimi REST liveness and add a non-TTL retirement path. Do **not** widen the allowlist without a real anchor. |
| **63** | monitor relay peek `signature_invalid` after register | **FIXED_ON_MASTER** (client-side) | `5dc8b948` / merge `2c90235c`: `peek_key_is_connector_owned` + `Disable_connector_owned` fail-closed once in `ocaml/cli/c2c_monitor_cmd.ml` / `c2c_monitor_logic.ml`. Relay-side "alias signer may peek connector key" remains deferred (deploy-gated). | **Close** with comment below. Note client-side only; server-side ownership expansion is a separate future if wanted. |
| **72** | `#62` follow-ups: re-arm floor, sync wiring test, docs typo | **FIXED_ON_MASTER** | `669e02bc` / merge `10101d6b`: `inbound_contract_realert_floor_s = 3600.` in `ocaml/c2c_relay_alert.ml`; sync wiring test; docs typo. | **Close** with comment below. |
| **73** | agy `--conversation` resume never fires SessionStart → never registers | **FIXED_ON_MASTER** | `8882480b` / merge `ccc3fecf`: ensure registration on **any** live hook event (not only SessionStart) in `ocaml/cli/c2c_hook_cmd.ml` ~L2072+. Managed path also: eager register `da3c29d1`. | **Close** with comment below. |
| **75** | `#70` reaper: re-verify pid starttime before signal | **OPEN** | `scripts/dune-build-locked.sh` `reclaim_stale_slot` still `kill -TERM "${doomed[@]}"` with no post-snapshot starttime re-check (~L319). Race is real but extremely narrow (stale ≥1800s + 0-tree-CPU + recycle in ms window). | Leave open as small hardening. Safe <1h patch when convenient: re-read `/proc/<pid>/stat` field 22 before TERM/KILL; skip if missing or starttime ≠ snapshot. Not urgent. |
| **76** | role/agent kickoff can claim non-published alias | **FIXED_ON_MASTER** | `535a33d8` / merge `d2cd1bd8`: role paths use `managed_kickoff_alias` with `role_alias` override; no longer defaults display to role/`agent_name`. | **Close** with comment below. |
| **77** | pre-launch guard name-scoped vs derived alias | **FIXED_ON_MASTER** (decision = best-effort) | `a1b3e024` / merge `360f67e8`: documented name-scoped best-effort; late `register` is authority; regression test named in comments (`test_i77_derived_alias_collision_register_backstops_namescoped_guard`). Chose option (2) over pre-deriving app-server alias. | **Close** with comment below. |

### Count

| Status | Issues |
|---|---|
| FIXED_ON_MASTER | `#50 #63 #72 #73 #76 #77` (6) — close |
| PARTIAL | `#27` (1) — leave |
| OPEN | `#35 #59 #75` (3) — leave |
| UPSTREAM | `#37` (1) — leave / upstream |
| DEFERRED | — (none as sole status; pieces of `#27`/`#35`/`#63` server half are deferred into other rows) |

---

## Per-issue notes

### #27 — PARTIAL

**Done on master:**
1. Observability (PR #32): deliver-loop heartbeat, doctor DEAF/degraded rollup (non-zero exit), sender-side `c2c send` warning.
2. `#31` degraded latch so a later healthy stamp cannot clear a binding refusal.
3. Launch-time warn when no hook fallback is installed (`codex_hook_fallback_warning` in `ocaml/c2c_codex_session.ml` ~L659 / ~L1711).

**Still open:**
- Post-launch *drift* of hook blocks while the session remains in a hook-classified mode is not continuously detected as DEAF.
- No continuous in-session "do I still have a path?" injector (circular by design for true deafness).
- Machine-wide sender surface is `#35`.

**Action:** leave open; do not re-implement observability.

### #35 — OPEN (design only)

North-star. Design at `.collab/design/35-machine-wide-delivery-service.md`
(`de73e7d5`). Absorbs residual `#27` sender surface, `#42`-class inverse
leaks, `#59` probed liveness, `#9` never-armed, broader `#50` doctor theme.
Codex must **not** move into the singleton (B098). Implementation is a
multi-phase project — not a triage ship.

### #37 — UPSTREAM

Honest docs already: Grok wake = NONE / CONDITIONAL-if-monitor. No c2c-side
guaranteed wake is possible without an upstream inject surface. Pair with
`#59` for the same missing mid-session signal class.

### #50 — FIXED_ON_MASTER (filed scope)

The issue as filed (Kimi SessionStart hook presence) is implemented and
commented "Fixed on master" on the issue itself. The broader "doctor is
blind to six silent degradations" comment is an umbrella — treat residual
rows as separate work (`#27` residual, `#35`, etc.), not as a reason to
keep `#50` open.

### #59 — OPEN (correct carve-out)

Widening `hook_anchor_is_activity_backed` without a real mid-session
anchor would recreate silent mail loss. Prefer probe (Kimi REST) or
confirmed upstream events.

### #63 — FIXED_ON_MASTER (client)

CLI monitor no longer soft-retries a permanently unownable connector key.
Relay-server change that would let an alias signer peek the connector pair
is explicitly out of scope of the landed fix.

### #72 — FIXED_ON_MASTER

All three review follow-ups (1h re-alert floor, sync-wiring test, docs typo)
landed in `669e02bc`.

### #73 — FIXED_ON_MASTER

Vanilla resume path: register on first live non-SessionEnd hook fire if no
row. Managed: eager register + no bogus `--conversation` on fresh start
(`da3c29d1`) is related hygiene, not the filed bug.

### #75 — OPEN (tiny, low urgency)

Pattern already used elsewhere (`#52` EXIT-trap cmdline/starttime guard).
One re-read of `/proc/<pid>/stat` field 22 per doomed pid before signal.
Not shipping in this triage pass (not on the "ship if small" shortlist
except as optional; user named `#72`/`#50` only).

### #76 / #77 — FIXED_ON_MASTER

Role kickoff shows published alias; guard documented as name-scoped with
late-register backstop + regression test. No further code needed for the
filed scope.

---

## Prepared close comments

Parent can paste these with `gh issue close <n> --comment '...'` (from a
checkout whose `master` matches; note local master is **unpushed** relative
to `origin/master` — push or cherry-pick before closing against remote if
the fix is not yet on GitHub's default branch).

### Close #50

```
Fixed on local master.

`c2c doctor hooks` now checks that the Kimi SessionStart hook (`c2c hook kimi`)
is installed and reports DEGRADED delivery-identity when it is missing
(authoritative workspace-keyed record vs session_index guess — #41).

Evidence:
- 062b9222 fix(doctor): #50 surface missing Kimi SessionStart hook (delivery-identity)
- aa99d320 Merge fix/50-doctor-kimi-hook

Pointers: `ocaml/cli/c2c_doctor_hooks.ml` (`check_kimi_session_start_hook`,
human section "Kimi SessionStart hook (delivery identity #41)", JSON key
`kimi_session_start_hook`).

The broader "doctor is blind to several silent degradations" theme from the
investigation comment is not closed by this — residuals live under #27
(post-launch drift), #35 (machine-wide delivery), etc. The filed Kimi
SessionStart check is done.
```

### Close #63

```
Fixed on local master (client-side).

When the relay CONNECTOR owns the peek key, the CLI monitor's alias signer
cannot verify peeks (`signature_invalid: signer does not own session`). The
monitor now fail-closes the relay watcher on the first such failure with one
clear line (no soft N/6, no "re-run relay register" hint that cannot help).
Local inbox watch is unaffected; connector/relay dm poll remains the
cross-host consumer.

Evidence:
- 5dc8b948 fix(monitor): #63 fail closed once on connector-owned relay-peek signature_invalid
- 2c90235c Merge fix/63-monitor-relay-failclosed

Pointers: `ocaml/cli/c2c_monitor_logic.ml` (`peek_key_is_connector_owned`,
`Disable_connector_owned`); `ocaml/cli/c2c_monitor_cmd.ml` handler.

Out of scope (deliberate): a relay-server change that would let an alias
signer bound to the same host/session peek the connector's pair. File
separately if that deploy-gated path is wanted.
```

### Close #72

```
Fixed on local master. All three #62 review follow-ups:

1. Per-alias wall-clock re-alert floor (3600s) for inbound-contract DMs, with
   suppressed-count carried into the next emission — stops intermittent drops
   from re-arming on every clean-then-dirty sync.
2. Fixture-level test that a contract drop in a real sync produces a delivered DM
   (pins the sync-loop wiring, not only the pure classifier).
3. Docs typo ("are / are") + wording that the alert is floored, not strictly
   once-per-episode forever.

Evidence:
- 669e02bc fix(relay-connector): #72 floor inbound-contract re-alerts; pin sync wiring; docs typo
- 10101d6b Merge fix/72-i62-followups

Pointers: `ocaml/c2c_relay_alert.ml` (`inbound_contract_realert_floor_s`,
`inbound_contract_emissions`).
```

### Close #73

```
Fixed on local master.

agy 1.1.4 does not fire SessionStart on `agy --conversation <id>` resume.
Registration is now ensured on ANY live hook event (PostToolUse / Stop / …)
when no row exists for the session id; SessionEnd never creates a row.
Idempotent (registry read guard); managed sessions still honour
C2C_MCP_BROKER_ROOT.

Evidence:
- 8882480b fix(agy): #73 ensure the hook registration on ANY live event, not only SessionStart
- ccc3fecf Merge fix/73-agy-resume-register

Related managed hygiene (not the filed bug): da3c29d1 eager managed register +
omit bogus --conversation on fresh start.

Pointer: `ocaml/cli/c2c_hook_cmd.ml` agy path (~#73 comment block at ensure-on-any-event).
```

### Close #76

```
Fixed on local master.

Role/agent kickoff paths no longer interpolate `{alias}` from a local
`effective_alias` that can be the ROLE/`agent_name`. Both role branches now
route display through `managed_kickoff_alias` with the branch's real
`role_alias` override, matching the published alias (or deferring to
`c2c whoami` when not authoritative). Completes the #58 treatment for the
role half.

Evidence:
- 535a33d8 fix(start): #76 role/agent kickoff must show the published alias, not the role name
- d2cd1bd8 Merge fix/76-role-kickoff-alias

Pointer: `ocaml/cli/c2c_managed_cmd.ml` (`kickoff_alias_or_defer`, role branches).
```

### Close #77

```
Fixed on local master (decision: best-effort name-scoped guard).

The pre-launch `registry_alive_conflict` remains name-scoped — the derived
codex alias is computed inside the app-server after the guard runs, so the
guard cannot know it without coupling to derivation+collision probing.
Chose option (2): document the guard as best-effort early check; late
`Broker.register` is the authority and already degrades cleanly
(`managed_registration_failed` + #34 try-wrapper). Regression test pins the
derived-alias collision backstop.

Evidence:
- a1b3e024 fix(start): #77 document the pre-launch guard as name-scoped best-effort
- 360f67e8 Merge fix/77-guard-namescope

Pointer: `ocaml/c2c_start.ml` `registry_alive_conflict` docblock (~#77).
```

---

## Push / close caution

Local `master` (`55ff2a92`) is **~195 commits ahead of `origin/master`
(`569bc0b1`)**. Several of the close-ready fixes (`#50 #63 #72 #73 #76 #77`,
and parts of `#27`) are **not** on the remote default branch yet.

Before closing on GitHub:
1. Confirm the fix SHA is reachable from the branch GitHub treats as default,
   **or**
2. Push/merge the relevant commits first, **or**
3. Close with an explicit "fixed on local master @ SHA; not yet on origin"
   note (less ideal for external readers).

Per repo policy: do **not** push solely because tests are green — push when
there is a real deploy/integration reason. Closing can wait on the next
intentional push, or the parent can close with the local-master note.

---

## Implementation this pass

None. `#72` and `#50` were the only issues authorized for a <1h ship; both
already FIXED_ON_MASTER. `#75` is a small safe hardening but was not on the
authorized shortlist and is low urgency.

**Commits produced by this triage:** none (report only).

---

## SUMMARY

- 6 issues ready to close on local master: `#50 #63 #72 #73 #76 #77` (close
  comments prepared above).
- 1 partial: `#27` (observability + launch warn done; post-launch drift +
  `#35` surface remain).
- 3 still open product/hardening: `#35` (architecture), `#59` (deliberate
  carve-out), `#75` (narrow reaper race).
- 1 upstream: `#37` (Grok inject surface).
- No code shipped this pass; report path:
  `.collab/research/2026-07-20T09-00-00Z-looper-gh-queue-triage.md`.
- **Unpushed local master** — coordinate close vs push.
