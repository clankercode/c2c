# c2c — Prioritized Improvements & Removals Catalog

**Thesis:** c2c's messaging *core* is already role-agnostic. The accidental complexity is at the **edges** — install defaults, broker-side hardcoded literals, dormant role plumbing, and an unfinished config-thunk layer that was *designed* but never built (`swarm_config_coordinator_alias` / `swarm_config_social_room` are comment-only stubs at `c2c_start.ml:661` / `.mli:340`). Because that layer is missing, `swarm-lounge` and `coordinator1` are scattered as literals across ~16 sites instead of being one config read each. The single highest-leverage change is to **build that thunk layer and default it empty**, which collapses most of the team-structure assumptions at once.

The four biggest sources of accidental complexity revealed by the findings:

1. **A planned indirection layer that was never built.** The codebase *references* `swarm_config_coordinator_alias`/`swarm_config_social_room` in comments but never implements them, so every call site hardcodes the literal. This is the root cause of items #1, #3, #5, #15.
2. **`C2C_COORDINATOR` is overloaded across three unrelated concerns** (relay-as-another-alias / cherry-pick lock / git-guard bypass) under one role-flavored name — conflating "I am the coordinator" with three orthogonal capabilities.
3. **The broker core itself presumes a swarm** via the unconditional `"swarm-lounge" ::` prepend at registration (`c2c_broker.ml:4073`, `c2c_identity_handlers.ml:349`) and unconditional `Relay_nudge`/`Coord_fallthrough` thread starts — swarm assumptions leaking *below* the role-agnostic layer.
4. **Three parallel, drifted "tier" lists** plus a dead role→env funnel that *looks* load-bearing but isn't (no role file sets `coordinator: true`, so `c2c_start.ml:4400` never fires in practice).

---

## (A) Quick Wins — high leverage, low effort, low risk

### A1. Build the `swarm_config_social_room` / `swarm_config_coordinator_alias` config thunks (default None)
- **Category:** ADD (enabling) → unblocks SIMPLIFY across the catalog
- **Rationale:** This is the missing keystone. The thunks were designed (#318/#341) but only the comment exists. Implement them mirroring `swarm_config_restart_intro` (`c2c_start.ml:710`), reading `.c2c/config.toml [swarm] social_room` / `coordinator_alias`, returning `None`/`""` when unset. Then route the ~16 hardcoded literals through them. Solo/flat user with no config → no social room, no coordinator default.
- **Affected:** `ocaml/c2c_start.ml:661,710,739,775` (+ `.mli:340`); consumers in `c2c_broker.ml:4073`, `c2c_identity_handlers.ml:349`, `c2c_setup.ml` (6 install sites), `c2c.ml` init/help/doctor.
- **Effort:** M · **Risk:** Low (additive; defaults preserve current behavior only where config is set to the old values) · **Goal alignment:** Directly enables solo+mesh reach; keeps swarm opt-in. The social layer stays first-class but becomes *chosen*, not imposed.

### A2. Remove the hardcoded `"swarm-lounge" ::` prepend from broker register/confirm announcements
- **Category:** REMOVE / SIMPLIFY
- **Rationale:** The broker core force-materializes a `swarm-lounge` ghost room (members=[], created_by="") and posts a `peer_register` event into it on *every* registration, independent of `C2C_MCP_AUTO_JOIN_ROOMS`. This bakes the social-layer assumption into the role-agnostic core. Announce only into rooms actually joined (`auto_rooms`), or via the A1 thunk when configured. **Note:** the logic is duplicated in two sites that fire on different transitions (new-register vs unconfirmed→confirmed) — unify while here.
- **Affected:** `ocaml/c2c_broker.ml:4064-4084`, `ocaml/c2c_identity_handlers.ml:340-360`.
- **Effort:** S · **Risk:** Low-Med — *open question*: does any agent watch `swarm-lounge` for join events as a presence signal? Confirm before removal; if so, replace with a real presence event. For a true solo broker it's pure dead weight (history-only writes, no members).
- **Goal alignment:** Makes the broker genuinely flat by default; social room becomes opt-in.

### A3. Neutralize the builtin heartbeat content (`ask coordinator1 (or swarm-lounge)`)
- **Category:** SIMPLIFY
- **Rationale:** The install-written `wake.toml` message is already clean (`c2c_setup.ml:1570`: "wake — poll inbox, advance work"), but the *builtin* codex/role-default heartbeat strings hardcode "ask coordinator1 (or swarm-lounge) for more" (`c2c_start.ml:161-163, 169-172`). In solo mode this text is misleading. Swap to topology-neutral text, or template the names via the A1 thunks so they vanish when unconfigured.
- **Affected:** `ocaml/c2c_start.ml:161-172`.
- **Effort:** S · **Risk:** Low · **Goal alignment:** Cross-client parity (codex builtin matches the clean install default).

### A4. Stop writing `C2C_AUTO_JOIN_ROLE_ROOM=1` into every install
- **Category:** REMOVE
- **Rationale:** Written for all 5 clients (`c2c_setup.ml:509,580,698,807,1162,1458`) but its consumer (`build_env`'s `role_class_opt`, `c2c_start.ml:2905-2924`) **appears dormant** — `cmd_start` does not thread `role_class_opt`, so it defaults `None` and the role-room branch never fires. No MCP-server consumer exists either. So this env var is inert noise in every install. Drop it from the defaults; if class-rooms are wanted later, make them an explicit opt-in.
- **Affected:** `ocaml/cli/c2c_setup.ml` (6 sites); verify `c2c_start.ml:2914-2923` truly never receives `Some`.
- **Effort:** S · **Risk:** Low (verify dormancy first — see open question) · **Goal alignment:** Flat-mesh default = swarm-lounge-only (or nothing post-A1/A2).

### A5. Make `prompt_for_role` opt-in, not the default
- **Category:** SIMPLIFY
- **Rationale:** On a TTY with no role file, `c2c start` interactively asks "What is this agent's role? (e.g. coder, planner, coordinator…)" (`c2c.ml:9069-9108`), presuming role-structured membership. A solo 1:1 user is nudged toward picking a role. Default to not prompting (or a single `configure a structured role? [N]`).
- **Affected:** `ocaml/cli/c2c.ml:9069-9108` (called at `:9604, :9621, :9644`).
- **Effort:** S · **Risk:** Low · **Goal alignment:** Solo reach — frictionless flat default.

### A6. Change permission-hook fallbacks from `coordinator1` to fail-open / no-gate
- **Category:** SIMPLIFY (fixes a real solo footgun)
- **Rationale:** When opted in but no supervisor is configured, the **opencode** plugin collapses a lone self-supervisor to `[]`, then still enters the wait loop → guaranteed 10-min timeout → fail-closed auto-**reject** (`c2c_opencode_plugin_embedded.ml:341-344, 1959-1964`). The **kimi** hook falls back to literal `coordinator1` then `exit 2` (deny) if absent (`c2c_kimi_hook.ml:230-237`). A solo user who turns approval on is hard-blocked. Add an early escape: empty resolved-supervisor set ⇒ ALLOW (or local prompt). Drop the `coordinator1` literal default in both.
- **Affected:** `ocaml/cli/c2c_opencode_plugin_embedded.ml:105,341-344,1959-1964`; `ocaml/cli/c2c_kimi_hook.ml:230-237`; regen `data/opencode-plugin/c2c.ts:102` + `just codegen-opencode-plugin`.
- **Effort:** S-M · **Risk:** Low (feature is default-OFF on all clients, so blast radius is opted-in users only). *Decision needed*: solo posture = fail-open vs self-approve vs local prompt. Recommend **fail-open when no supervisor resolves**, matching the existing `is_safe_command` allowlist posture.
- **Goal alignment:** Solo reach — the approval feature stops actively breaking solo users.

### A7. Fix doctor/help text that presents `coordinator1` as the universal supervisor default
- **Category:** SIMPLIFY (display only)
- **Rationale:** `c2c doctor` and help say "supervisor: coordinator1 (default)" / "fallback: coordinator1" (`c2c.ml:1952,1959,7310,10840`) but the actual resolver returns `None`/`[]` when unconfigured (`c2c_authorizers.ml:50-69`). The code already does the neutral thing; only the surfaced text lies. Reword to "no supervisor configured (approvals disabled)".
- **Affected:** `ocaml/cli/c2c.ml:1952,1959,7310,10840`.
- **Effort:** S · **Risk:** None · **Goal alignment:** Solo onboarding clarity.

---

## (B) Structural Simplifications — bigger refactors, real complexity reduction

### B1. Split `C2C_COORDINATOR` into named capability flags
- **Category:** MODULARIZE
- **Rationale:** One role-flavored env var gates three unrelated things: (a) relay-as-another-alias spoof bypass in `c2c send`/`rooms send` — the *only* one that touches the messaging core; (b) the `coord cherry-pick` hard lock; (c) the git destructive-op guard bypass + worktree-mismatch log skip. Conflating them means a messaging-relay grant accidentally also unlocks destructive git ops. Split: `C2C_RELAY_ANY_ALIAS` (messaging), leave the git-shim with its own `C2C_GIT_GUARD_BYPASS` (alias old name for compat). The cherry-pick lock can keep reading whichever.
- **Affected:** `ocaml/cli/c2c.ml:105-147`, `c2c_rooms.ml:32-72`, `c2c_coord.ml:202-209`, `c2c_broker.ml:1129-1134`, `git-shim.sh:52` + all guard sites.
- **Effort:** M · **Risk:** Med (touches a documented env contract — needs compat aliasing + CLAUDE.md update) · **Goal alignment:** Removes the "coordinator identity" framing from the messaging core entirely; capabilities become orthogonal opt-ins.

### B2. Factor the duplicated `validate_from_override` spoof-guard into one shared helper
- **Category:** SIMPLIFY
- **Rationale:** The from-alias ownership check + coordinator bypass is copy-pasted verbatim between `c2c.ml:108-147` and `c2c_rooms.ml:32-73` (because `c2c_rooms` doesn't depend on `c2c.ml`). A comment already names `C2c_cli_auth.validate_from_override` as the intended canonical home. Factor it; the bypass condition then lives in exactly one place and is trivial to make config-driven (and pairs with B1).
- **Affected:** new `C2c_cli_auth` helper; `c2c.ml:108-147`, `c2c_rooms.ml:32-73`.
- **Effort:** S-M · **Risk:** Low · **Goal alignment:** Cross-client parity (rooms vs DM auth stay in lockstep).

### B3. Gate `Relay_nudge` and `Coord_fallthrough` scheduler threads on configuration
- **Category:** MODULARIZE
- **Rationale:** Both threads start *unconditionally* in every MCP server, including a solo user's (`c2c_mcp_server_inner.ml:537,548`). `Relay_nudge` DMs idle sessions swarm-flavored "grab a task / review a PR?" prompts every ~30min (`relay_nudge.ml:20-25`). `Coord_fallthrough` is a no-op when `coord_chain=[]` (the default) but still spawns the thread and scans `pending_permissions.json`. Gate `start_nudge_scheduler` behind a social-room/swarm-mode flag, and `start_scheduler` behind non-empty `coord_chain`. A solo broker then spawns neither.
- **Affected:** `ocaml/server/c2c_mcp_server_inner.ml:537,548`; `relay_nudge.ml`; `coord_fallthrough.ml`.
- **Effort:** S-M · **Risk:** Low · **Goal alignment:** Solo reach — no unsolicited swarm nudges; mesh/swarm enable explicitly.

### B4. Collapse the 4-tier `safety` type to a 2-state `advanced` boolean, single source of truth
- **Category:** SIMPLIFY
- **Rationale:** The tier system is a UX declutter (NOT a security boundary — trivially bypassed by `env -u C2C_MCP_SESSION_ID`), keyed solely on `C2C_MCP_SESSION_ID` presence. At the top level only **4 commands** are actually agent-blocked (setcap, serve, mcp, supervisor). Tier1-vs-Tier2 has zero behavioral difference today. Worse, there are **three drifted hand-maintained lists**: the enforcement map (`c2c_commands.ml:20-110`), the `commands_by_safety` audit display (`c2c.ml:284-363`, which *lies* — labels install/relay/gui "Tier3 UNSAFE" while enforcement makes them visible), and the `commands_man` help prose. Collapse to one boolean `advanced` column; generate all display from the single map; replace the gate predicate with a `C2C_HIDE_ADVANCED` preference (default on in sessions, overridable by `--all`). Document in code that tiers are NOT security.
- **Affected:** `ocaml/cli/c2c_types.ml:8-12`, `c2c_commands.ml:20-135`, `c2c.ml:279-372,11668-11718,11791+,12147-12157`.
- **Effort:** M-L · **Risk:** Med (broad surface; *open question*: do any scripts parse `c2c commands` audit output? grep `scripts/` + `.collab/` first) · **Goal alignment:** Cross-client parity (one consistent surface); the "single show-advanced flag" the north-star asks for.

### B5. Make "structured team" a single layered profile (`c2c install --swarm` / repo.json `mode`)
- **Category:** MODULARIZE
- **Rationale:** Today flat-mesh is achievable only by *individually unsetting* scattered defaults (swarm-lounge auto-join, role prompt, git shim, role-room env, coordinator1 fallbacks). There is **no neutral default** — the union of defaults presumes a swarm. Invert: make FLAT the default; bundle swarm framing (auto-join social room, swarm restart intro, git-shim install, role-room, coord defaults) behind one explicit `--swarm` flag / `mode:swarm`. This is the cleanest expression of the north-star: solo+mesh by default, structured-team additive.
- **Affected:** `c2c_setup.ml` (install env writes), `c2c_start.ml` (kickoff intro selection, shim install), `c2c.ml` (init/prompt). Depends on A1 thunks.
- **Effort:** L · **Risk:** Med · **Goal alignment:** The capstone for solo+mesh+swarm reach as distinct, chosen modes.

### B6. Don't install the git-pre-reset shim in default `install self`
- **Category:** MODULARIZE / REMOVE-from-default
- **Rationale:** `install self`/`install all` unconditionally installs the coordinator-gated shim (`c2c_setup.ml:306-313`), which refuses commit-on-master, reset --hard, switch/checkout/rebase in the main tree for anyone without `C2C_COORDINATOR=1`. Its *entire reason for being* is multi-agent shared-tree contention — for a solo user it has no upside and actively breaks normal solo git on master. Gate behind explicit `c2c install git-shim` / `--swarm` (uninstall already treats git-shim as a separate component, confirming it's optional).
- **Affected:** `ocaml/cli/c2c_setup.ml:306-313`; `c2c_start.ml:1879-1906`.
- **Effort:** S-M · **Risk:** Med — *this repo's own swarm depends on the shim*; the change must keep `--swarm`/coordinator installs getting it. Verify no code path hard-requires the shim being present (uninstall lists it optional ⇒ likely safe).
- **Goal alignment:** Solo reach — the binary stops imposing shared-tree discipline on single-tree users.

---

## (C) Removals / Deletions — dead weight, net code reduction, ~zero behavior change

### C1. Delete the dead role→env funnel (`coordinator: true` → `C2C_COORDINATOR=1`)
- **Category:** REMOVE
- **Rationale:** `c2c_start.ml:4396-4402` propagates the env flag from a role-file boolean — but **no role file in the repo sets `coordinator: true`** (Cairn-Vigil.md/coordinator1.md use `role_class: coordinator`, not the boolean). So this branch never fires in practice; coordinator privilege is set manually via env. It's dead code that *falsely implies roles drive git/privilege*. Delete the block and the `coordinator` field from `c2c_role.ml:18,267` + `.mli`. After this, **no code path reads a role file to influence git or privilege behavior** — the mesh is provably role-flat.
- **Affected:** `ocaml/c2c_start.ml:4396-4402`, `ocaml/c2c_role.ml:18,267` + `.mli`.
- **Effort:** S · **Risk:** Low (confirm no out-of-repo personal role file sets it — *open question*; even if one does, the fix is "set env in `extra_env`") · **Goal alignment:** Removes the single illusory role→privilege coupling.

### C2. Delete dead `configure_claude_hook`
- **Category:** REMOVE
- **Rationale:** ~100-line settings.json hook-installer in `c2c_setup.ml:1006` with **zero callers** (verified full-tree grep, excl `_build`/def). Not even exported (no `.mli`). Pure dead code superseded by the live install path. Delete it + `claude_hook_script`/`claude_stop_hook_script` constants if unreferenced.
- **Affected:** `ocaml/cli/c2c_setup.ml:1006+`.
- **Effort:** S · **Risk:** None · **Goal alignment:** Reduces "what's canonical" confusion.

### C3. Retire `C2c_poker` (no-op shim)
- **Category:** REMOVE
- **Rationale:** `c2c_poker.ml`'s `resolve_terminal` is a hardcoded `None` (verified `ocaml/c2c_poker.ml:11-12`), making the whole PTY-heartbeat-poker path a dead no-op shelling to a deprecated Python script. Remove it. (Keep `C2c_pty_inject` — it's role-agnostic delivery plumbing still negotiated by some clients; just exclude it from any "core" build, don't delete.)
- **Affected:** `ocaml/c2c_poker.ml` + callers.
- **Effort:** S · **Risk:** Low · **Goal alignment:** Trims the delivery-layer surface.

### C4. Purge all `crush` client residue
- **Category:** REMOVE
- **Rationale:** Crush is fully deprecated (`c2c start crush` and `c2c install crush` both refuse, exit 1), yet ~12 OCaml files still carry it through `c2c_blocklist.ml:13`, the `*_clients` lists (`c2c_setup.ml:1538-1548`), the clients hashtbl (`c2c_start.ml:1542`), `setup_crush`, `recompute_crush_artifacts`, and the pgrep guard regex (`c2c.ml:1338`). It complicates every client-enumeration site. Remove all of it; keep at most a single "crush removed" refusal. Zero behavior change (already refuses).
- **Affected:** ~12 files (see grep); the `deprecated/run-crush-inst*` scripts too.
- **Effort:** M · **Risk:** Low · **Goal alignment:** Cross-client parity — the client list stops carrying a phantom 6th client.

### C5. Delete legacy `run-*-inst*` / `restart-{client}-self` launcher scripts + `.d/` configs
- **Category:** REMOVE
- **Rationale:** Git-tracked outer-loop launchers superseded by `c2c start` (CLAUDE.md says so explicitly). **Zero live invocations** (verified — only the pgrep *string* at `c2c.ml:1338` names them, for detection not invocation). Delete the scripts + their `run-*-inst.d/*.json` instance configs (including crush ones). Simplify the sweep guard regex to match only `c2c start`. **Keep `./restart-self`** — it's live (justfile `bii` recipe).
- **Affected:** `run-{claude,codex,kimi,opencode,crush}-inst{,-outer,-rearm}`, `restart-{codex,crush,kimi,opencode}-self`, their `.d/`; `c2c.ml:1338`.
- **Effort:** S-M · **Risk:** Low · **Goal alignment:** Reduces tree clutter / "what launches agents" ambiguity.

### C6. Stage removal of ~50 deprecated root Python scripts + `data/c2c_alias_words.txt`
- **Category:** REMOVE
- **Rationale:** The entire root `c2c_*.py` tree (send/list/register/whoami/mcp/health/broker_gc/start…) is superseded by OCaml subcommands; the runbook marks them DEPRECATED/DEAD. `c2c_kimi_wire_bridge.py` and `c2c_wire_daemon.py` are explicitly DEAD. `data/c2c_alias_words.txt` (1455 words) is read *only* by the deprecated `c2c_registry.py` (OCaml uses the hardcoded 128-word `c2c_alias_words.ml`). Remove in batches once `c2c_cli.py`'s residual responsibilities are confirmed fully migrated (deliver-inbox/wire-daemon are now OCaml — `c2c_deliver_inbox.ml` exists, wire-daemon removed).
- **Affected:** ~50 root `c2c_*.py`, `c2c_registry.py`, `data/c2c_alias_words.txt`.
- **Effort:** M (verification-heavy) · **Risk:** Med — *open question*: is `c2c_cli.py` still a live dispatch for ANY OCaml-unimplemented surface? Confirm before bulk delete. **Coordinate via swarm-lounge** (shared tree). · **Goal alignment:** Cuts the "two implementations" confusion; OCaml is canonical.

### C7. Derive the protected-alias list instead of hardcoding this swarm's roster
- **Category:** REMOVE / SIMPLIFY
- **Rationale:** `instances clean-stale` protects a hardcoded list of *this specific swarm's* aliases (coordinator1, stanza-coder, jungle-coder, galaxy-coder, lyra-quill, test-agent, dogfood-hunter) at `c2c.ml:7708-7719`. Baking one team's roster into the binary. Derive from live registrations / configured supervisors, or make config-driven.
- **Affected:** `ocaml/cli/c2c.ml:7708-7719`.
- **Effort:** S · **Risk:** Low · **Goal alignment:** Generic reach — the binary stops knowing this team's names.

### C8. GC the schedule store + add `c2c schedule gc`
- **Category:** REMOVE (hygiene)
- **Rationale:** `.c2c/schedules/` has grown to ~95 per-alias dirs, **77 of them throwaway `test-oc-fix-*` cruft**. Add a `c2c schedule gc` (analogous to `worktree gc` / sweep) classifying stale alias dirs. Not role-coupled — pure hygiene. Schedules themselves are already role-agnostic.
- **Affected:** new `c2c schedule gc`; clean existing `.c2c/schedules/`.
- **Effort:** S-M · **Risk:** Low (don't GC live-aliased dirs) · **Goal alignment:** Operational hygiene for managed sessions.

### C9. Drop or hide the `role:` scalar and the `coord` group from the agent surface
- **Category:** REMOVE / SIMPLIFY
- **Rationale:** Two small cosmetic reductions: (a) the role-file `role:` scalar (subagent/primary/all) gates nothing — only Claude/Codex/OpenCode renderer prefixing (`c2c_role.ml:262`, `:461`); drop or stop emitting it so it stops *looking* like a capability. (b) Move the `coord` command group under `dev` / hide unless `C2C_COORDINATOR` set — it's pure structured-team git tooling that currently shows in agent help (defaults Tier2) but hard-fails without the env.
- **Affected:** `ocaml/c2c_role.ml:262,461`; `c2c.ml:12319` (coord group registration), `c2c_commands.ml` tier map.
- **Effort:** S · **Risk:** Low · **Goal alignment:** Cleaner default surface; team tooling visibly opt-in.

---

## (D) Net-New that earns its complexity

### D1. A `core` vs `swarm` build/runtime profile boundary
- **Category:** ADD
- **Rationale:** The findings show the swarm features are *already cleanly modularized* (separate modules: `coord_fallthrough`, `relay_nudge`, pending-reply handlers, role rendering, git-shim). Formalize a profile concept so a `core` deployment excludes them by config (pairs with B5's `mode`). The irreducible core is well-defined: broker enqueue/drain, register/whoami/list/send/poll_inbox, rooms machinery, alias/identity, broker-root resolution, per-client delivery adapters. This is the smallest change that makes "solo c2c" a *first-class supported configuration* rather than "swarm with everything unset."
- **Effort:** M (mostly config plumbing once A1/B3/B5 land) · **Risk:** Low-Med · **Goal alignment:** The structural expression of the north-star — one binary, two honest modes.

### D2. (Speculative — flag, don't build yet) Peer/room-targeted scheduled pings
- **Category:** ADD
- **Rationale:** `c2c schedule` is self-DM only (`c2c_schedule_fire.ml:23-27`) — the right minimal core, but it forecloses flat-mesh use cases like "remind peer X" or "scheduled room ping." Worth noting as a *future* mesh capability, **not** a v1 item — the self-DM floor is correct and shouldn't grow speculatively. Listed only so it isn't lost.
- **Effort:** M · **Risk:** Med (scope creep) · **Goal alignment:** Mesh reach — but YAGNI until a concrete need appears.

---

## Cut-list (be opinionated): what to delete with confidence

These have **verified zero live consumers** and should go regardless of the solo/swarm question: dead `configure_claude_hook` (C2), no-op `C2c_poker` (C3), the dead role→env funnel (C1), legacy `run-*-inst*`/`restart-{client}-self` launchers (C5), `crush` residue (C4), and (after `c2c_cli.py` confirmation) the deprecated Python tree + `data/c2c_alias_words.txt` (C6). The `C2C_AUTO_JOIN_ROLE_ROOM=1` install write (A4) and the `role:` scalar (C9a) are inert and should follow once dormancy is confirmed.

## Recommended sequencing

1. **First:** A1 (thunks) — keystone that unblocks A2/A3/A7/B5/D1.
2. **Then quick wins:** A2-A7 (each small, mostly independent once A1 lands).
3. **Confident deletions in parallel:** C1-C5, C9 (no dependency on A1).
4. **Structural:** B1-B4, B6 (medium, sequence after quick wins settle).
5. **Capstone:** B5 + D1 (the mode/profile boundary), then C6/C8 hygiene.
6. **Defer:** D2 (YAGNI).
