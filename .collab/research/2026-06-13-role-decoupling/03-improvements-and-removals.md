# c2c Improvements & Removals — Prioritized Catalog

**Scope:** Make c2c work cleanly for a SOLO user and a FLAT peer mesh with
zero role/coordinator concept, while keeping structured-team features as
opt-in modules. Source: 9-investigator aggregated findings (this dir), spot-
confirmed against current `master` source.

**North-star alignment legend:** `parity` = cross-client behaviour parity ·
`reach` = solo+mesh+swarm reach · `social` = the shared-room/social layer.

---

## The accidental complexity, in one paragraph

c2c's *messaging core is already role-agnostic* — `enqueue_message`, register,
send, poll, rooms, schedules, and memory carry zero coordinator concept. The
accidental complexity is almost entirely at the **edges and defaults**, and it
clusters around four overloaded things:

1. **`C2C_COORDINATOR=1` is one env var doing three unrelated jobs** — relay-as-
   another-alias (the only one touching the messaging core), a cherry-pick
   utility lock, and the destructive-git-op shim bypass. The name implies a
   role; the mechanism is just a privilege flag.
2. **`swarm-lounge` is hardcoded in ~15 sites**, including two *broker-core*
   prepends (`c2c_broker.ml:4073`, `c2c_identity_handlers.ml:349`) that force-
   subscribe every peer to a social room at registration — the only place the
   social layer leaks into the role-agnostic broker.
3. **`coordinator1` is hardcoded in ~70 sites** as a last-resort default for
   permission supervisor, DM routing, doctor text, and onboarding prose.
4. **The planned `swarm_config_coordinator_alias` / `swarm_config_social_room`
   config thunks were never implemented** — only a comment stub exists
   (`c2c_start.ml:661`). Their absence is *why* (2) and (3) are hardcoded
   everywhere instead of resolved through one config seam.

There is **no neutral/flat default**: the union of install defaults (swarm-
lounge auto-join, swarm-agent kickoff intro, git-shim, role prompt, coordinator1
fallbacks) presumes a structured multi-agent swarm. A solo user gets a working
channel *plus* a phantom social room, swarm framing, and a coordinator-shaped
git shim they never asked for. Implementing the two config thunks + inverting
~6 install defaults removes the overwhelming majority of the coupling with
near-zero behaviour change for existing swarm deployments.

---

## (A) Quick wins — high leverage, low effort, near-zero risk

### A1. Implement the two missing config thunks (`swarm_config_social_room` / `swarm_config_coordinator_alias`)
- **Category:** ADD (the seam everything else routes through)
- **Rationale:** This is the single highest-leverage change. The thunks were
  *planned* (#318) but only the comment exists (`c2c_start.ml:661`,
  `c2c_start.mli:340`). Their absence forces `swarm-lounge` and `coordinator1`
  to be hardcoded at ~15 + ~70 sites respectively. Mirror the existing,
  working `swarm_config_restart_intro` thunk (`c2c_start.ml:710`). Default to
  `None`/empty so a solo/flat user resolves to "no social room" / "no
  coordinator"; teams set the keys in `.c2c/config.toml [swarm]`.
- **Affected:** `ocaml/c2c_start.ml` (+ `.mli`); becomes the dependency for
  B1, C-class coordinator1 cleanup.
- **Effort:** S · **Risk:** Low (additive; default preserves current behaviour
  only once call-sites are migrated). · **Alignment:** reach, social, parity.

### A2. Make the broker stop hardcoding `swarm-lounge ::` at registration
- **Category:** SIMPLIFY
- **Rationale:** `social_rooms = sort_uniq ("swarm-lounge" :: auto_rooms)` is
  prepended *unconditionally* on register/confirm, independent of
  `C2C_MCP_AUTO_JOIN_ROOMS`. `send_room` auto-creates a ghost room, so a solo
  broker silently materialises `swarm-lounge` on first registration. This is
  the ONLY social-layer assumption baked into the role-agnostic broker core.
  Route through A1's thunk (announce only into actually-joined rooms; skip when
  no social room configured). **Two duplicate sites** — unify them.
- **Affected:** `ocaml/c2c_broker.ml:4073`, `ocaml/c2c_identity_handlers.ml:349`
- **Effort:** S · **Risk:** Low-Med (confirm no agent relies on the
  `peer_register` announcement for presence/discovery — see open questions).
  · **Alignment:** reach (solo gets no phantom room), social (room becomes
  intentional).

### A3. Invert the kickoff/restart intro default to neutral
- **Category:** SIMPLIFY
- **Rationale:** `builtin_swarm_restart_intro` opens *"You have been started as
  a c2c swarm agent… The swarm coordinates via c2c… You are now part of it"* —
  the first thing every managed agent reads. The override plumbing already
  exists (`[swarm] restart_intro`). Just swap which side is the default: neutral
  ("message peers with `c2c send` / `poll_inbox`") by default, swarm framing
  opt-in. Same for the builtin heartbeat content's *"ask coordinator1 (or
  swarm-lounge)"* tail (`c2c_start.ml:161-172`).
- **Affected:** `ocaml/c2c_start.ml:668-678` (intro), `:161-172` (heartbeat
  content), `ocaml/cli/c2c.ml:9118-9150` (renderer).
- **Effort:** S · **Risk:** Low. · **Alignment:** reach, parity (all clients
  read the same neutral default).

### A4. Stop writing `C2C_AUTO_JOIN_ROLE_ROOM="1"` into every install
- **Category:** REMOVE (from defaults)
- **Rationale:** Written for all 6 clients (`c2c_setup.ml:509,580,698,807,1162,
  1458`). It only does anything when a role file sets `role_class` AND the
  `build_env role_class_opt` arg is threaded — which **appears dormant**
  (`cmd_start` does not pass it; defaults `None`). So it is inert for non-role
  solo use *and possibly inert entirely*. Drop it from the default install;
  make role-class rooms opt-in.
- **Affected:** `ocaml/cli/c2c_setup.ml` (×6 write sites); verify
  `c2c_start.ml:2905-2924`.
- **Effort:** S · **Risk:** Low (verify dormancy first). · **Alignment:** reach.

### A5. Fix the fail-CLOSED solo footgun in approval hooks
- **Category:** SIMPLIFY (behaviour fix)
- **Rationale:** Once a solo user *opts into* permission-asking, the opencode
  plugin's `selectSupervisors()` self-excludes the agent's own alias → empty
  list → still enters `waitForPermissionReply` → guaranteed 10-min timeout →
  **auto-reject** (`c2c_opencode_plugin_embedded.ml:341-344, 1959-1964`). The
  kimi hook falls back to a possibly-nonexistent `coordinator1` then `exit 2`
  (deny). Add an early escape: empty resolved supervisor set ⇒ ALLOW (or local
  prompt), not silent fail-closed. The read-only allowlist already proves
  "absence of supervisor ≠ hard deny" is acceptable.
- **Affected:** `ocaml/cli/c2c_opencode_plugin_embedded.ml`,
  `ocaml/cli/c2c_kimi_hook.ml:234-237,343` (+ regen TS via
  `just codegen-opencode-plugin`).
- **Effort:** S · **Risk:** Med (changes a *safety* default to fail-open;
  acceptable only because the gate is opt-in and the alternative is a
  guaranteed solo lockout). · **Alignment:** reach, parity.

### A6. Delete dead `configure_claude_hook`
- **Category:** REMOVE (dead code)
- **Rationale:** ~100-line settings.json hook installer with **zero callers**
  (confirmed full-tree grep; `c2c_setup.ml` has no `.mli` so it's not even an
  exported API). Pure dead weight.
- **Affected:** `ocaml/cli/c2c_setup.ml:1006` (+ its hook-script string
  constants if unreferenced elsewhere).
- **Effort:** S · **Risk:** Low. · **Alignment:** none directly; reduces noise.

---

## (B) Structural simplifications — bigger, but each kills a class of coupling

### B1. Route all ~70 `coordinator1` literals through A1's thunk (or drop the fallback)
- **Category:** SIMPLIFY
- **Rationale:** `coordinator1` is hardcoded as: kimi authorizer fallback
  (`c2c_kimi_hook.ml:230`), opencode supervisor fallback
  (`c2c_opencode_plugin_embedded.ml:105`), agent-refine reply target
  (`c2c_agent.ml:721`), worktree-gc fallback (`c2c_worktree.ml:1887`),
  cherry-pick self-DM (`c2c_coord.ml:127`), doctor/help text
  (`c2c.ml:1952,1959`), and onboarding prose. None are privilege checks — the
  broker special-cases the name **nowhere** (grep: zero hits). Replace each with
  `swarm_config_coordinator_alias ()`; where it returns `None`, degrade
  gracefully (skip the DM / use current alias / "no supervisor configured —
  approvals disabled"). Result: zero coordinator literals fire for a solo/flat
  user.
- **Affected:** ~8 distinct OCaml sites + 2 hook/plugin shells + role templates.
- **Effort:** M · **Risk:** Low-Med (each call-site needs a defined no-
  coordinator behaviour — see open questions). · **Alignment:** reach, parity.

### B2. Split `C2C_COORDINATOR` into named capability flags
- **Category:** MODULARIZE
- **Rationale:** One env var conflates three orthogonal concerns: (a) relay-as-
  another-alias (`c2c.ml:109`, `c2c_rooms.ml:36` — the ONLY one touching the
  messaging core), (b) cherry-pick lock (`c2c_coord.ml:202`), (c) git-shim
  bypass (`git-shim.sh:52` + hooks). A messaging-relay grant accidentally also
  unlocks destructive git ops. Split: `C2C_RELAY_ANY_ALIAS` (messaging),
  leave the git shim with its own `C2C_GIT_GUARD_BYPASS`; the cherry-pick lock
  is self-imposed and can keep whichever. Drops the "I am the coordinator"
  framing from a pure privilege mechanism. Alias the old name for back-compat.
- **Affected:** `ocaml/cli/c2c.ml:105-147`, `ocaml/cli/c2c_rooms.ml:32-72`
  (factor the **duplicated** spoof-guard into one `C2c_cli_auth` helper while
  here), `git-shim.sh`, `.c2c/hooks/pre-commit.sh`, `scripts/git-hooks/pre-push`,
  `ocaml/c2c_broker.ml:1134`, `ocaml/cli/c2c_coord.ml:202`.
- **Effort:** M · **Risk:** Med (touches the git-discipline surface; alias old
  name to avoid breaking live coordinator sessions). · **Alignment:** reach,
  parity.

### B3. Collapse the 4-tier command system to a 2-state `advanced` boolean
- **Category:** SIMPLIFY
- **Rationale:** Tiers are a single-axis UX declutter keyed solely on
  `C2C_MCP_SESSION_ID` presence — NOT a security boundary (trivially bypassed
  by `env -u C2C_MCP_SESSION_ID`), NOT role-derived. Tier1 vs Tier2 has **zero
  behavioural difference** today (both always visible). Only ~4 top-level
  commands are actually agent-blocked (`setcap`, `serve`, `mcp`, `supervisor`).
  Worse: **three hand-maintained tier lists have drifted** — the `c2c commands`
  audit calls `install`/`relay`/`gui` "Tier3 UNSAFE" while enforcement makes
  them visible. Collapse to one `advanced` column on `command_tier_map`;
  generate all display from it; replace the gate with a `C2C_HIDE_ADVANCED`
  preference (the north-star's "single show-advanced flag"). Fold the duplicate
  dev-group inline check (`c2c.ml:12147-12157`) into the same predicate.
- **Affected:** `ocaml/cli/c2c_commands.ml:20-135`, `ocaml/cli/c2c_types.ml:8-12`,
  `ocaml/cli/c2c.ml:279-372` (audit display), `:11668-11718` (man),
  `:12147-12157` (dev group).
- **Effort:** M · **Risk:** Low (no behaviour loss; removes a drift surface).
  · **Alignment:** reach (clean solo surface via one flag).

### B4. Split `git_attribution` config into `git_attribution` + `git_guards`; default guards OFF for unconfigured repos
- **Category:** MODULARIZE
- **Rationale:** The git shim's "guard or not" is purely structural
  (`[-d .git]` main-tree vs `[-f .git]` worktree) — already role-agnostic. The
  **dormant** role→env link (`c2c_start.ml:4400`, which no shipped role file
  triggers — `Cairn-Vigil.md` sets `role_class: coordinator` but NOT the
  `coordinator:` boolean) should be deleted. The real problem: a single config
  bool (`git_attribution`, default true) conflates commit-identity with
  destructive-op refusals. A solo user committing on `master` in the main tree
  is *refused*. Split so attribution (identity, universally useful) stays on
  while guards (shared-tree contention discipline) default OFF until a team
  opts in. Make the protected-branch set + protected-remote URL configurable
  (currently hardcodes `master`/`main` and `clankercode/c2c`).
- **Affected:** `c2c_start.ml:520-548,4396-4402`, `c2c_role.ml:18,267` (+`.mli`),
  `git-shim.sh`, `.c2c/hooks/pre-commit.sh`, `scripts/git-hooks/pre-push:40`.
- **Effort:** M · **Risk:** Med (git-discipline change; needs a clear default
  decision — see open questions on solo main-tree posture). · **Alignment:**
  reach.

### B5. Gate the supervisor/approval cluster behind "supervisors configured"
- **Category:** MODULARIZE
- **Rationale:** A whole subsystem (~10 CLI commands: open/check-pending-reply,
  await-reply, approval-reply, authorize, approval-pending-*, resolve-authorizer;
  the `supervisor` group; 2 MCP tools) is structured-team-only. It is already
  default-OFF on every client (kimi block ships commented, Claude hook ships a
  never-matching sentinel matcher, opencode fires only on "ask"), and the
  authority check is flat list-membership (`c2c_pending_reply_handlers.ml:156`)
  — no hierarchy, no role lookup. Formalise: when no `supervisors[]` /
  `C2C_SUPERVISORS` configured ⇒ feature is a no-op, commands hidden. Solo/flat
  never touches it. (Pairs with A5's fail-open fix and B1's coordinator1 drop.)
- **Affected:** `ocaml/c2c_mcp.ml:134-148`, `ocaml/cli/c2c.ml:11636-11666,
  1904-1912`, `c2c_kimi_hook.ml`, `c2c_opencode_plugin_embedded.ml`.
- **Effort:** L · **Risk:** Low (already default-off; this makes the off-state
  explicit). · **Alignment:** reach, parity.

### B6. Gate the two always-on broker schedulers behind config
- **Category:** SIMPLIFY
- **Rationale:** `Relay_nudge.start_nudge_scheduler` (swarm-themed idle DMs:
  *"check the swarm-lounge", "want to review a PR?"*) and
  `Coord_fallthrough.start_scheduler` start **unconditionally** in every MCP
  server, including a solo user's (`c2c_mcp_server_inner.ml:537,548`).
  Relay_nudge injects unsolicited swarm-coordination prompts; coord_fallthrough
  is inert when `coord_chain` is empty (default) but still spawns the thread +
  scans `pending_permissions.json`. Gate both on a configured social room /
  non-empty chain so a solo broker spawns neither.
- **Affected:** `ocaml/server/c2c_mcp_server_inner.ml:537,548`,
  `ocaml/relay_nudge.ml:20-25`.
- **Effort:** S-M · **Risk:** Low. · **Alignment:** reach.

### B7. Introduce one explicit mode switch; make FLAT the default
- **Category:** ADD (the umbrella that ties A2–A4, B4, B6 together)
- **Rationale:** Rather than make an operator individually unset ~6 swarm
  defaults, add `c2c install --swarm` / repo.json `"mode":"swarm"`. Default
  (no flag) = flat-mesh: no swarm-lounge auto-join, neutral intro, no git
  guards, no role prompt, no idle nudges. Swarm framing becomes additive. This
  is the discoverable, coarse-grained complement to the per-feature toggles
  that already partly exist.
- **Affected:** `c2c_setup.ml` (install defaults), `c2c.ml` (init), `c2c_start.ml`.
- **Effort:** M-L · **Risk:** Med (cross-cutting; do AFTER A1 so it has a seam
  to flip). · **Alignment:** reach (the headline solo/flat-vs-swarm decision).

---

## (C) Removals / deletions — dead weight, cut aggressively

### C1. Purge `crush` client residue entirely
- **Category:** REMOVE · **Effort:** M · **Risk:** Low (already refuses to start)
- **Rationale:** `c2c start crush` and `c2c install crush` both exit 1, yet
  ~11–25 code sites still carry crush through `c2c_blocklist.ml`, all `*_clients`
  lists (`c2c_setup.ml:1538-1548`), the clients hashtbl, `setup_crush`,
  `recompute_crush_artifacts`, and the pgrep regex (`c2c.ml:1338`). Every
  client-enumeration site is complicated by a dead client. Remove it; keep at
  most a one-line "crush is removed" refusal.
- **Affected:** `c2c_blocklist.ml:13`, `c2c_setup.ml`, `c2c_start.ml:1542`,
  `c2c_uninstall.ml:418,480,633`, `c2c.ml:1338`. · **Alignment:** parity.

### C2. Delete legacy `run-*-inst*` / `restart-{client}-self` launchers
- **Category:** REMOVE · **Effort:** S · **Risk:** Low
- **Rationale:** Pre-`c2c start` outer-loop respawn launchers — git-tracked,
  **zero live callers** (only the `c2c.ml:1338` pgrep STRING names them, to
  *detect* not invoke). `c2c start` replaced them per CLAUDE.md. Delete the
  scripts + their `.d/*.json` instance configs (including crush instances).
  **Keep** `./restart-self` (live in justfile `bii`).
- **Affected:** repo-root `run-*-inst*`, `restart-{codex,crush,kimi,opencode}-self`,
  their `.d/` dirs; simplify `c2c.ml:1338`. · **Alignment:** none; hygiene.

### C3. Stage removal of the ~50 deprecated root Python scripts + `data/c2c_alias_words.txt`
- **Category:** REMOVE · **Effort:** M (batched) · **Risk:** Med (shared tree —
  coordinate via swarm-lounge)
- **Rationale:** Legacy Python implementation of every CLI surface, marked
  DEPRECATED/DEAD in `.collab/runbooks/python-scripts-deprecated.md` but still
  physically at repo root, confusing "what is canonical". `c2c_kimi_wire_bridge.py`
  and `c2c_wire_daemon.py` are explicitly DEAD. `data/c2c_alias_words.txt`
  (1455 words) is read ONLY by the deprecated `c2c_registry.py`; the canonical
  OCaml pool is the 128-word `c2c_alias_words.ml`. **Blocker:** confirm
  `c2c_cli.py` backs no OCaml-unimplemented surface (open question), then remove
  as one slice. Move to existing `deprecated/` or delete.
- **Affected:** repo-root `c2c_*.py`, `data/c2c_alias_words.txt`. · **Alignment:**
  none; hygiene + canonical-clarity.

### C4. Retire `C2c_poker` (near-dead PTY-heartbeat shim)
- **Category:** REMOVE · **Effort:** S · **Risk:** Low
- **Rationale:** OCaml wrapper shelling to deprecated `c2c_poker.py`;
  `resolve_terminal` returns `None` ⇒ effectively a no-op. (Distinguish from
  `C2c_pty_inject`, which is more entangled — capability-probed delivery mode
  still negotiated by some clients; **keep but exclude from core**, do not
  delete without confirming no live client's delivery-mode probe negotiates it.)
- **Affected:** `ocaml/c2c_poker.ml`. · **Alignment:** none; hygiene.

### C5. Reconcile the two competing pre-commit installers
- **Category:** REMOVE (one of two) / SIMPLIFY · **Effort:** S · **Risk:** Low
- **Rationale:** `c2c install git-hook` writes the coordinator-gate pre-commit;
  `just install-git-hooks` symlinks a *different* plugin-syntax-check pre-commit
  to the **same** `.git/hooks/pre-commit` path — mutually exclusive depending on
  which ran last. Consolidate into one hook: always-on syntax check + optional
  protected-branch gate behind config (pairs with B4). Removes the coordinator-
  gate variant from the default solo path.
- **Affected:** `c2c_setup.ml:2033-2059`, `justfile:293-296`, `scripts/git-hooks/`.
  · **Alignment:** parity.

### C6. Remove the dormant role→`C2C_COORDINATOR` link + `coordinator` role field
- **Category:** REMOVE · **Effort:** S · **Risk:** Low (no role file uses it)
- **Rationale:** `c2c_start.ml:4396-4402` auto-exports `C2C_COORDINATOR=1` when
  a role has `coordinator: Some true` — but **no shipped role file sets that
  boolean** (confirmed: `Cairn-Vigil.md` has `role_class: coordinator`, not the
  field). It is the *only* role→git-behaviour link and it is dead. Deleting it +
  the `coordinator` field from `c2c_role.ml:18,267` removes the false implication
  that roles drive privilege. (Folds into B2/B4.)
- **Affected:** `c2c_start.ml:4396-4402`, `c2c_role.ml:18,267` (+`.mli`).
  · **Alignment:** reach.

### C7. De-hardcode the protected-alias roster + GC the schedule store
- **Category:** REMOVE / SIMPLIFY · **Effort:** S · **Risk:** Low
- **Rationale:** Two unrelated hygiene cuts. (a) `instances clean-stale` protects
  a hardcoded list of *this* swarm's named aliases (`coordinator1`, `stanza-coder`,
  …) — `c2c.ml:7708-7719`; derive from live registrations / configured
  supervisors instead. (b) `.c2c/schedules/` has grown to 95 dirs, **77 of them
  throwaway `test-oc-fix-*`**; add `c2c schedule gc` analogous to worktree gc.
- **Affected:** `c2c.ml:7708-7719`, new `c2c schedule gc`. · **Alignment:**
  hygiene; (a) leans reach.

### C8. Drop the cosmetic `role:` scalar and `role_classes`-on-schedule field
- **Category:** REMOVE · **Effort:** S · **Risk:** Low
- **Rationale:** Two surfaces that *look* like capabilities but gate nothing.
  The `role:` scalar (subagent/primary/all) only prefixes rendered prompts
  (`c2c_role.ml:262`). `role_classes` on schedule entries is ALWAYS `[]` from
  install/CLI/MCP and no shipped role populates it — a role concept in the
  schedule model 99% of users never touch (keep role-gating in the role→
  heartbeat layer only). Both reduce the surface that *appears* role-coupled.
- **Affected:** `c2c_role.ml:262`, `c2c_start.ml:868,939-949`. · **Alignment:**
  reach (smaller apparent role surface).

---

## (D) Net-new that earns its complexity

Only two. Be skeptical of anything else here — the north-star is reached
mostly by *subtraction*.

### D1. `c2c init` / install lead with a 2-agent 1:1 flat path
- **Category:** ADD (docs + default behaviour) · **Effort:** S-M · **Risk:** Low
- **Rationale:** The README "Quick Start" and `c2c init --room` (default
  `swarm-lounge`) center onboarding on the swarm social room. Lead instead with
  "register two of your own agents, `c2c send` between them"; default
  `--room ''` (skip); move swarm-lounge / coordinator content to a labelled
  "Swarm mode" section. Makes the *documented* happy-path match the flat-mesh
  default (pairs with B7). · **Affected:** `README.md`, `c2c.ml:6939-6942,
  7056-7064`. · **Alignment:** reach, social (room becomes intentional).

### D2. Optional: peer/room-targeted scheduled pings
- **Category:** ADD · **Effort:** M · **Risk:** Med · **Verdict: defer / YAGNI-check**
- **Rationale:** Scheduling is currently self-DM only
  (`c2c_schedule_fire.ml:23-27`) — the right minimal core. A flat-mesh use case
  (scheduled reminder to a peer or room) *could* justify a target field, but it
  is speculative. List it only so it isn't silently foreclosed; **do not build
  until a concrete need appears.** · **Alignment:** social (weak).

---

## Recommended sequencing

1. **A1** (the seam) → unblocks A2, A3, B1, C6.
2. **Quick wins A2–A6** in parallel (independent, low-risk).
3. **B2 + C6 + B4** as one git-decoupling slice (overlapping files).
4. **B3** (tier collapse) and **B5/A5** (approval gating) independently.
5. **B6**, then **B7** (mode switch) last — it flips defaults the earlier
   slices made flippable.
6. **C-class removals** (C1–C8) opportunistically; C3 needs swarm-lounge coord
   (shared tree).

## Key open questions to resolve before cutting

- Does any agent watch `swarm-lounge` for the `peer_register` announcement as a
  presence/discovery signal? If yes, A2 needs a presence-event replacement.
- Solo main-tree git posture (B4): default guards ON (force worktree discipline)
  or OFF (frictionless)? North-star argues OFF-by-default, team opt-in.
- Is `c2c_cli.py` a live dispatch path for any OCaml-unimplemented surface? If
  fully dead, C3 collapses into one clean slice.
- For B1: when `swarm_config_coordinator_alias` returns `None`, do DM-routing
  fallbacks (cherry-pick self-DM, agent-refine reply-to) skip the DM or use the
  current alias? Needs one defined no-coordinator behaviour.
- B2: keep one shared bypass name (one flag flips messaging + git) or separate
  (a relay grant shouldn't unlock destructive git)? Recommend separate.

---

## EXECUTIVE SUMMARY (for orchestrator)

c2c's messaging core is *already* role/coordinator-agnostic; the work is almost
entirely subtraction at the edges and defaults. The biggest accidental
complexity: `C2C_COORDINATOR` is one env var doing three unrelated jobs;
`swarm-lounge` is hardcoded in ~15 sites (incl. two broker-core prepends that
force-subscribe every peer); `coordinator1` in ~70 sites; and the planned
`swarm_config_social_room`/`coordinator_alias` config thunks were never built —
their absence is *why* everything is hardcoded. The single highest-leverage
move is **A1: implement those two thunks** (mirror the existing
`restart_intro` thunk), which unblocks removing the broker swarm-lounge prepend
(A2), neutralising the swarm kickoff intro (A3), and routing all coordinator1
literals through config (B1). Structural wins: split `C2C_COORDINATOR` into
named capability flags (B2), collapse the non-security 4-tier command system to
one `advanced` boolean (B3, also kills 3 drifted hand-maintained lists), and
gate the always-on swarm schedulers + approval cluster behind config (B5/B6).
Aggressive removals are safe: purge dead `crush` residue (C1), legacy launchers
(C2), the dormant role→C2C_COORDINATOR link no role file uses (C6), and a dead
hook function (A6). Cap it with a `--swarm` mode switch that makes FLAT the
default (B7). Near-zero net-new is warranted — the solo/flat north-star is
reached by cutting, not adding.
