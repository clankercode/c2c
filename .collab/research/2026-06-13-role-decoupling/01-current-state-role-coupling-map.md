# Current-State Map: Role / Coordinator Coupling in c2c

**Research artifact — 2026-06-13.** Maps every place the "coordinator" and
"role" concepts couple into the c2c codebase, tagged by coupling strength,
with `file:line` evidence. Companion docs in this dir: `03-improvements-and-removals.md`.

**Scope:** what exists *today*. Proposals live in the sibling docs. This is the
evidence base for the north star — **c2c should work for a SOLO user and a FLAT
unstructured peer mesh with ZERO role/coordinator concept, while OFFERING
structured-team features as opt-in modules.**

---

## Central finding: "coordinator" is NOT a real role

> **"Coordinator" in c2c is not a first-class identity. It is three
> loosely-coupled things that mostly do not agree at runtime:
> (1) one env flag, (2) a role-file boolean that only sets that flag, and
> (3) a hardcoded alias string used as a last-resort default. The messaging
> core has zero coordinator concept.**

The three faces of "coordinator":

| Face | What it is | What it actually gates | Strength |
|---|---|---|---|
| **`C2C_COORDINATOR=1`** (env) | The *only* thing that gates code | 4 narrow surfaces: from-alias spoof bypass (`send`/`rooms send`), `coord cherry-pick` hard-gate, worktree-mismatch warning skip, git-shim destructive-op bypass | **the real gate** |
| **`coordinator: true`** (role file) | A boolean field | Propagates `C2C_COORDINATOR=1` into a managed session's env — nothing else | sugar over face 1 |
| **`"coordinator1"`** (alias string) | A hardcoded default/fallback | Permission-supervisor default + DM-routing fallback — **never a privilege check** | convention |

These three can **disagree**: a session can carry `role: coordinator` envelope
metadata without `C2C_COORDINATOR=1`, or vice-versa. The env flag is the single
source of truth; the role field and the alias string are decoration around it.

### The role field is independently redundant

`role.coordinator = Some true` does exactly one thing
(`ocaml/c2c_start.ml:4398-4401`):
```
| Some r when r.C2c_role.coordinator = Some true ->
    Array.append env [| "C2C_COORDINATOR=1" |]
```
Since `C2C_COORDINATOR` is independently settable as an env var, the role field
is **load-bearing for nothing** — it is a convenience funnel. (Investigators
also note **no shipped role file sets `coordinator:`** — `Cairn-Vigil.md` /
`coordinator1.md` carry `role_class: coordinator` but not the boolean — so this
funnel is *dormant in practice today*; coordinator privilege is currently set
manually via the env var.)

### How much is hardcoded vs convention?

- **HARD couplings to the role/coordinator concept: 1** — `coord cherry-pick`
  hard-refuses without `C2C_COORDINATOR=1` (`ocaml/cli/c2c_coord.ml:202-209`).
  And it sits entirely *outside* the messaging core (a structured-team deploy
  utility a solo user never invokes).
- **SOFT couplings: ~12** — all are env-flag bypasses, optional role-file
  fields, or hardcoded-default strings. Every one is opt-out-able or never
  triggered in solo/flat mode.
- **CONVENTION-ONLY: ~8** — runbooks, role-template prose, doctor display text,
  README onboarding. Zero code enforcement.
- **The messaging core (broker enqueue/drain, register, list, send, rooms,
  send_all, schedules, memory): NONE.** Role is captured at `register` as a
  free-text `string option` whose own doc-comment says *"for envelope
  attribution"* (`ocaml/c2c_mcp_helpers.ml:52-54`) — the broker never branches
  on it.

**The one swarm assumption that *does* leak into the role-agnostic broker** is
the unconditional `"swarm-lounge" ::` prepend on registration
(`ocaml/c2c_broker.ml:4073`, `ocaml/c2c_identity_handlers.ml:349`) — a *social
layer* default, not a coordinator one.

**The planned config helper does not exist.** `swarm_config_coordinator_alias`
/ `swarm_config_social_room` are referenced only in comments
(`ocaml/c2c_start.ml:661`, `ocaml/c2c_start.mli:340`) — verified: zero
`let` definitions. So `"coordinator1"` and `"swarm-lounge"` are hardcoded at
~8 / ~10 sites respectively instead of resolved through config.

---

## Summary table: subsystem × coupling-strength × decouple-difficulty

Decouple-difficulty: **Trivial** = never fires in solo/flat (no code change),
**Easy** = flip a default / gate on config, **Moderate** = refactor + thread
config thunk, **N/A** = already role-agnostic.

| Subsystem | Max coupling | Mechanism | Solo/flat behavior today | Decouple difficulty |
|---|---|---|---|---|
| **Messaging core** (enqueue/drain/register/list/send) | NONE | — | Fully role-agnostic | N/A |
| **Rooms** (join/send/history/ACL) | NONE | creator-based ACL (`created_by`) | Role-agnostic; `delete_room` keys on creator | N/A |
| **send_all / topology** | NONE | — | Role-agnostic | N/A |
| **Schedules / memory / DND** | NONE | per-alias | Role-agnostic | N/A |
| **`register` role field** | NONE | role-file-field (cosmetic) | Stored, displayed, gates nothing | N/A |
| **Tier command-hiding** | NONE | env (`C2C_MCP_SESSION_ID`) | Agent-vs-operator axis, not role | N/A |
| **Broker swarm-lounge prepend** | SOFT | broker-logic (hardcoded literal) | Materializes phantom room; harmless | Moderate |
| **`C2C_COORDINATOR` send/rooms-send spoof bypass** | SOFT | env-var | Never set → guard always holds (correct default) | Trivial |
| **`coordinator: true` → `C2C_COORDINATOR=1`** | SOFT | role-file-field | Dormant (no role file sets it) | Easy (delete field) |
| **`role_class` (pmodel/heartbeat/role-room)** | SOFT | role-file-field | `'coordinator'` is one bucket value, no special path | N/A |
| **Worktree-mismatch warning exemption** | SOFT | env-var (broker) | Suppresses one log line only | Trivial (remove check) |
| **Permission/approval flow** (supervisors[]) | SOFT | broker-logic + role-file-field | Default-OFF on every client | Easy (gate on configured) |
| **Hardcoded `coordinator1` supervisor default** | SOFT | hardcoded-alias | Last-resort fallback (3 sites) | Easy (config thunk / no-op) |
| **Hardcoded `coordinator1` DM-routing fallbacks** | SOFT | hardcoded-alias | Team-tooling only | Easy |
| **`coord_fallthrough` scheduler** | SOFT | schedule (broker) | OFF by default (empty chain) | Trivial |
| **Relay_nudge idle nudges** | SOFT | broker-logic | Runs unconditionally; swarm-themed text | Easy (gate start) |
| **git destructive-op shim** | HARD\* | git-guard | Opt-in install; structural (main vs worktree) | Easy (don't install) |
| **pre-commit / pre-push hooks** | NONE\*\* | git-guard | Branch-keyed + env bypass, no role read | Easy (config branches) |
| **`coord cherry-pick`** | **HARD** | env-var | Solo user never invokes | Trivial (unused) |
| **Install/onboarding defaults** | SOFT | env + convention | Auto-joins swarm-lounge, swarm intro text | Easy (mode flag) |
| **Role onboarding preamble / templates** | CONVENTION | role-file prose | Only via `--agent`/role path (opt-in) | Easy (extract team profile) |
| **`prompt_for_role` interactive prompt** | SOFT | hook | Nudges role pick on plain start | Easy (default skip) |
| **doctor / README / help text** | CONVENTION | doc text | Presents `coordinator1` as default | Easy (reword) |
| **Protected-alias roster** | CONVENTION | hardcoded-alias | Bakes this swarm's names into binary | Easy (config/derive) |

\* The shim's `C2C_COORDINATOR` bypass *names* coordinator but reads only the env
flag + structural `.git`-dir-vs-file — no role file. The HARD tag is for "the
guard refuses main-tree ops unless the flag is set," not for any role read.

\*\* The hooks read `C2C_COORDINATOR` as a bypass token; no role file is consulted.

---

## Coupling points by subsystem

### 1. Messaging core — NONE

The broker (`ocaml/c2c_broker.ml`) opens only `C2c_mcp_helpers`; it never
references `C2c_role`, `Coord_fallthrough`, or `Relay_nudge`. Routing is pure
`alias → alias`.

- **`enqueue_message` / `drain_inbox`** — pure delivery, envelope is
  `from`/`to`/`content` only. No role/coordinator/tier check.
- **`register` / `whoami` / `list`** — identity is `(session_id, alias)`. The
  optional `role : string option` is **envelope-attribution metadata that gates
  nothing** — `ocaml/c2c_mcp_helpers.ml:52-54` doc-comment: *"Sender role for
  envelope attribution … None = no role."* Re-register preserves it
  (`ocaml/c2c_broker.ml:1970-1972`); no send/room/inbox handler reads it.
- **Rooms** — membership + creator-based ACL only. `delete_room` authorizes on
  `created_by`, **not** any coordinator status (`ocaml/c2c_broker.ml:3521-3545`).
- **`send_all` (1:N), rooms (N:N)** — topology primitives, no privilege gate.
- **Schedules / per-agent memory / DND** — per-alias, role-agnostic.

> **Irreducible invariant (correct for a flat mesh):** the from-alias spoofing
> guard's *default* branch — "you may only send as your own registered alias"
> (`ocaml/cli/c2c.ml:108-147`, the `else` block). This is the right role-free
> behavior; the coordinator bypass is purely additive.

### 2. Coordinator identity — the `C2C_COORDINATOR` env flag

The flag gates exactly four surfaces. **`is_coordinator () = (getenv "C2C_COORDINATOR" = Some "1")`** (`ocaml/cli/c2c.ml:105-106`).

| # | Surface | Evidence | Strength | Solo behavior |
|---|---|---|---|---|
| a | from-alias spoof bypass in `c2c send` | `ocaml/cli/c2c.ml:108-147` (`validate_from_override`; bypass at :109) | SOFT | Never set → can only send as self ✓ |
| b | from-alias spoof bypass in `c2c rooms send` (duplicated logic) | `ocaml/cli/c2c_rooms.ml:32,36` | SOFT | Same — guard always holds |
| c | **HARD gate** for `coord cherry-pick` | `ocaml/cli/c2c_coord.ml:202-209` (`eprintf "C2C_COORDINATOR=1 required"; exit 1`) | **HARD** | Never invoked |
| d | worktree-mismatch warning skip | `ocaml/c2c_broker.ml:1129-1134` (`if getenv "C2C_COORDINATOR" = Some "1" then ()`) | SOFT | Only suppresses a log line |

(a) and (b) are the **only** coordinator coupling that touches the messaging
core. (c) is the only HARD env gate but lives wholly outside messaging. (d) is
the broker's *single* coordinator check and is warn-only — it never blocks a
message; when no expected-cwd file exists (the solo case) the guard no-ops at
`ocaml/c2c_broker.ml:1136` regardless.

The role-file funnel into this flag:
- **`coordinator: true`** → `C2C_COORDINATOR=1` at launch
  (`ocaml/c2c_start.ml:4398-4401`; field defined `ocaml/c2c_role.ml:18`, parsed
  `:267`). **SOFT, and dormant** — no shipped role sets it.

### 3. Roles & role files — opt-in by construction

A role is a YAML-frontmatter markdown file at `.c2c/roles/<name>.md`
(`ocaml/c2c_role.ml:539-562`), parsed into a ~22-field record
(`ocaml/c2c_role.ml:249-298`). **Roles are already fully opt-in**: `c2c start
<client>` applies a role only when `--agent <name>` is passed or a name-matching
role file exists; otherwise the `else` branch returns all-`None` and launches a
flat full-capability peer (`ocaml/cli/c2c.ml:9633-9655`).

Field-by-field gating reality:

| Field | What it gates | Strength |
|---|---|---|
| `coordinator: true` | → `C2C_COORDINATOR=1` (the only capability field) | SOFT |
| `role:` (subagent/primary/all) | Rendering only — prepended to prompt; **no code branches on its value** | NONE |
| `role_class` | pmodel bucket + heartbeat filter + auto-join role-room. `'coordinator'` is just one value; `'coder'`/`'reviewer'` treated identically | SOFT |
| `pmodel` | Model hint (priority: `--model` > pmodel > saved config); never persisted | SOFT |
| `required_capabilities` / `compatible_clients` | Pre-launch compat gate (`ocaml/c2c_start.ml:3985-3988`); fires only if set | SOFT |
| `c2c.heartbeat(s)` | Persisted to `.c2c/schedules/<alias>/`; no shipped role declares them | SOFT |

> **`role_class`-driven auto-join may be partly dead code.** `build_env`'s
> `role_class_opt` parameter (`ocaml/c2c_start.ml:2905-2924`) does not appear to
> be threaded from `cmd_start`, defaulting `None` — so role-room auto-join may
> be inert despite `C2C_AUTO_JOIN_ROLE_ROOM=1` being written at install. **Open
> question, flagged below.**

### 4. Tier system — role-AGNOSTIC (keys on session, not role)

The tier filter is a **UX declutter, not a security boundary, and not
role-derived.** The only runtime input is `C2C_MCP_SESSION_ID` presence:
`is_agent_session () = (session_id_from_env () <> None)`
(`ocaml/cli/c2c_commands.ml:113-114`). When true, Tier3/Tier4 commands are
dropped from the cmdliner group (`:117-135`).

- **`C2C_COORDINATOR=1` does NOT affect tiers** (verified by investigators:
  `setcap` stays hidden with it set).
- The gate is **trivially bypassable** (`env -u C2C_MCP_SESSION_ID c2c setcap`),
  confirming it is not a safety layer.
- Only ~4 top-level commands are actually agent-blocked: `setcap` (Tier3) +
  `serve`/`mcp`/`supervisor` (Tier4). Tier1 vs Tier2 is cosmetic (both always
  visible).
- A second hand-rolled copy of the check hides `diag`/`restart-self`/
  `smoke-test`/`inject` inside the `dev` group (`ocaml/cli/c2c.ml:12147-12157`).
- **Drift:** the `c2c commands` audit display labels `install`/`relay`/`gui` as
  "Tier3 UNSAFE" while enforcement makes them visible — three hand-maintained
  tier lists have diverged from the single `command_tier_map`.

### 5. Approval / supervisor machinery — flat list, default-OFF

The sole enforced authority check is **flat list membership**, not hierarchy:
`if List.mem reply_from_alias pending.supervisors`
(`ocaml/c2c_pending_reply_handlers.ml:156`) and the CLI mirror
(`ocaml/cli/c2c.ml:6288-6298`). **Zero special-casing of `coordinator1` in the
broker.** The supervisors list is chosen by the *requester*; it can contain any
alias including the requester's own (symmetric peer- and self-approval are
mechanically supported at the broker layer).

- **Default-OFF everywhere:** kimi `[[hooks]]` block ships fully commented;
  Claude PreToolUse hook installs with a never-matching sentinel
  `__C2C_PREAUTH_DISABLED__` (`ocaml/cli/c2c_setup.ml:1380-1397`); opencode only
  fires when opencode itself is set to `ask`.
- **The one coordinator coupling:** `coordinator1` is the hardcoded last-resort
  supervisor default — kimi hook `ocaml/cli/c2c_kimi_hook.ml:230`, opencode
  plugin `ocaml/cli/c2c_opencode_plugin_embedded.ml:105`, `.c2c/repo.json`
  examples. A plain string default, not a privileged identity.
- **Solo footgun (once opted in):** opencode's `selectSupervisors()`
  self-excludes; a lone self-as-supervisor collapses to `[]` but the wait loop
  still runs → 10-min timeout → fail-closed reject. Kimi falls back to a possibly
  -nonexistent `coordinator1` and also fails closed.
- **`coord_fallthrough`** broker scheduler escalates unacked permission DMs
  through a `coord_chain` — **OFF by default** (`chain = [] then \`No_action`,
  `ocaml/coord_fallthrough.ml:96`; default `[]` at `ocaml/c2c_start.ml:745-753`).
  Uses verbatim aliases (no role indirection); the "coord" name is cosmetic.

### 6. Git integration — structural + one env flag, no role read

The destructive-op shim (`git-shim.sh`, installed as `git-pre-reset`) decides
"guard or not" **purely structurally**: `is_main_tree () { [ -d ".git" ]; }` vs
`is_worktree_branch () { [ -f ".git" ]; }` (`git-shim.sh:60-74`) — git's own
canonical worktree indicator. It **never reads a role file**; the only role
flavor is the *name* of the bypass var `COORDINATOR="${C2C_COORDINATOR:-0}"`
(`git-shim.sh:52`; guards at `:146,167,189,237,286`).

- **`git_attribution` config gate** (`ocaml/c2c_start.ml:520-548`, defaults
  true) is the master opt-in: when false, neither the attribution shim nor the
  guard reaches PATH. It currently conflates *attribution* (identity) with
  *guards* (refusals).
- **pre-commit** (`.c2c/hooks/pre-commit.sh:5-13`) and **pre-push**
  (`scripts/git-hooks/pre-push:38-77`) branch-gate on `master`/`main` with the
  same `C2C_COORDINATOR=1` bypass — no role read. Pre-push additionally
  hardcodes the c2c repo URL (`*/c2c`), a project-specific (not role-specific)
  assumption.
- **Two competing pre-commit installers** write different scripts to the same
  `.git/hooks/pre-commit` (`c2c install git-hook` = coordinator gate vs `just
  install-git-hooks` = bun syntax check) — a footgun that obscures the coupling.
- **Attribution shim** (`git` wrapper, `ocaml/c2c_start.ml:1781-1824,2961-2974`)
  stamps commits with the session alias — **alias-keyed, fully role-agnostic**.

### 7. Install / onboarding — no neutral default

A solo user running `c2c install` + `c2c init` + `c2c start` is implicitly
enrolled in this dev swarm's framing. None of it blocks 1:1 messaging, but the
**union of defaults presumes a structured swarm with a coordinator**:

| Default | Evidence | Strength |
|---|---|---|
| `C2C_MCP_AUTO_JOIN_ROOMS="swarm-lounge"` + `C2C_AUTO_JOIN_ROLE_ROOM="1"` written for all 5 clients | `ocaml/cli/c2c_setup.ml:508-509,579,697,805,1161,1457` | SOFT |
| Broker prepends `"swarm-lounge" ::` on every registration (CORE, not config) | `ocaml/c2c_broker.ml:4073`, `ocaml/c2c_identity_handlers.ml:349` | SOFT |
| Kickoff intro: *"You have been started as a c2c swarm agent… You are now part of it"* | `ocaml/c2c_start.ml:668-678`; rendered `ocaml/cli/c2c.ml:9118-9150` | CONVENTION |
| Heartbeat content: *"ask coordinator1 (or swarm-lounge) for more"* | `ocaml/c2c_start.ml:161-163,169-172` | SOFT |
| Role preamble + templates hardcode `coordinator1`, named peers (Cairn-Vigil, stanza-coder…), peer-PASS gate | `ocaml/cli/c2c.ml:9496-9506,9573-9584`; `ocaml/cli/role_templates.ml` | CONVENTION |
| Interactive *"What is this agent's role?"* prompt on plain start | `ocaml/cli/c2c.ml:9069-9108` | SOFT |
| `c2c install self` installs the coordinator-gated git shim | `ocaml/cli/c2c_setup.ml:306-313` | HARD\* |
| `c2c init --room` defaults to `swarm-lounge`; README leads with swarm onboarding | `ocaml/cli/c2c.ml:6939-6942`; `README.md:11,17` | SOFT |
| `Relay_nudge` idle-nudge thread started unconditionally, swarm-themed text | `ocaml/server/c2c_mcp_server_inner.ml:537`; `ocaml/relay_nudge.ml:20-25` | SOFT |
| Hardcoded protected-alias roster (`coordinator1`, `stanza-coder`, …) | `ocaml/cli/c2c.ml:7708-7719` | CONVENTION |

> There is **no neutral/flat default**. A solo user wanting plain 1:1 between
> two of their own agents gets a working channel *plus* a phantom swarm-lounge
> room, swarm-agent intro text, a role prompt, and a coordinator-flavored git
> shim.

### 8. Surface area — MCP tools / CLI groups / env vars

- **`tools/list` is fully role-agnostic** — returns all 38 base tools to every
  session unconditionally (`ocaml/c2c_mcp.ml:430-432`). No per-role/per-
  coordinator gating exists anywhere on the MCP surface.
- **`C2C_COORDINATOR` is the single coordinator env coupling** across the whole
  surface; ~90 distinct `C2C_*` vars exist but only this one carries the
  coordinator concept.
- **Structured-team env vars** (`C2C_SUPERVISORS`, `C2C_PERMISSION_SUPERVISOR`,
  `supervisors[]`/`authorizers[]` in `repo.json`) feed only the opt-in approval
  flow.
- **Dead weight at the edges** (not coupling, but noise that obscures the core):
  ~50 deprecated root `c2c_*.py` scripts; legacy `run-*-inst*` / `restart-*-self`
  launchers (zero live callers); full `crush` client residue (~25 sites, already
  refuses); unused `data/c2c_alias_words.txt`; dead `configure_claude_hook`
  (`ocaml/cli/c2c_setup.ml:1006`, zero callers); 77/95 stale `test-oc-fix-*`
  schedule dirs.

---

## Irreducible role-agnostic core

What a SOLO user / FLAT mesh needs — all of it already role-free in code today:

- **Broker:** `Broker.create`, `register` (role = optional metadata only),
  `enqueue_message` (`ocaml/c2c_broker.ml:2105` — the actual 1:1 route, no
  role/coord/tier check), inbox drain, atomic registry persistence
  (temp + fsync + `os.replace`, flock). Structurally independent of
  `C2c_role` / `Coord_fallthrough` / `Relay_nudge`.
- **Minimal MCP floor:** `register`, `whoami`, `list`, `send`, `poll_inbox`
  (`ocaml/c2c_mcp.ml:30-57`) — "two of my agents can message each other" with
  zero role/coordinator/swarm concept. `peek_inbox` = non-draining superset.
- **Rooms** as a generic primitive (`join_room`/`send_room`/`room_history`/
  `my_rooms`/`list_rooms`/`leave_room`) — creator-based ACL, no privilege gate.
  Only the swarm-lounge *default* is coupled, not the machinery.
- **`send_all`** (1:N) and rooms (N:N) topology primitives.
- **Identity/name primitives:** `c2c_name.ml` (validation), `c2c_alias_words.ml`
  (128-word pool), `c2c_blocklist.ml` (collision guard) — all role-agnostic.
- **Broker-root resolution** (`c2c_repo_fp.ml` + `C2C_MCP_BROKER_ROOT`/XDG) so
  two local sessions agree on one broker — no role concept.
- **CLI fallback:** `c2c register/send/list/whoami/poll-inbox` — always-available,
  no role/coord branch (`send_cmd` at `ocaml/cli/c2c.ml:383`).
- **Per-client delivery adapters** (OpenCode embedded plugin, kimi
  notification-store, `c2c_deliver_inbox` watcher) — plain-envelope transport.
- **The from-alias spoofing guard's *default*** ("send only as yourself") and the
  **flat supervisor-list authority test** (membership, not hierarchy) are both
  role-free invariants that are correct as the flat-mesh baseline.
- **Schedules, memory, DND, the agent-vs-operator tier filter** — all per-alias /
  session-keyed, orthogonal to roles.

**Bottom line:** the flat-mesh core is already implemented and clean. The work to
reach the north star is **not removing coordinator from the messaging core (it
was never there)** — it is (1) inverting ~10 swarm-flavored *defaults* to flat-
by-default, (2) implementing the absent `swarm_config_*` config thunks so the ~18
hardcoded `coordinator1`/`swarm-lounge` literals resolve to empty/None for a solo
user, and (3) making the structured-team modules (approval, git shim, coord
tooling, role rooms) explicit opt-in rather than install-default.
