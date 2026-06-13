# c2c Decoupling Architecture — roles/coordinator as opt-in modules over a role-agnostic core

**Scope:** Re-architect so the messaging core works for a SOLO user and a FLAT
peer mesh with **zero** role/coordinator concept, and structured-team features
become opt-in modules layered over that core. This is IDEATION — propose, don't
implement. Companion: `03-improvements-and-removals.md` (prioritized, per-change
catalog). This file is the *architecture frame* those changes plug into.

**Key precondition (confirmed in source):** the broker module
(`ocaml/c2c_broker.ml`) opens only `C2c_mcp_helpers`, never `C2c_role` /
`Coord_fallthrough` / `Relay_nudge`; `enqueue_message`, register, send, poll,
rooms, schedules, and memory carry no role/coordinator branch. **The core is
already role-agnostic.** What is *not* yet clean: the **edges and defaults**.
The whole decoupling is therefore an *exterior* refactor — config seams,
default inversions, and a build/runtime profile boundary — not surgery on the
delivery path. That is what makes it low-risk.

---

## 1. The structure spectrum

Three deployment shapes. Each is a **superset** of the one before — same binary,
same broker, same wire format; structure is *added by configuration*, never
forked into a different build.

| | **Solo** | **Flat-mesh** | **Structured-swarm** |
|---|---|---|---|
| Who | one user, 1–N of *their own* agents | several independent peers, no hierarchy | the c2c dev swarm (today's default) |
| Needs | DM between my agents; maybe a self-DM scheduler | + a shared room, broadcast, peer discovery | + coordinator, supervisors, peer-PASS, git-shim, role rooms, sitrep, failover |
| Identity | alias only (`role` field unset) | alias only; optional free-text `role` for display | role files, `role_class`, `coordinator: true` |
| Rooms | none auto-joined | one shared social room (opt-in name) | social room + role-class rooms + invites |
| Approval | none (self-authorize / fail-open) | none, or symmetric peer-approval | supervisors[] + escalation chain + fallthrough |
| Git | plain git, no shim | plain git, no shim | git-shim + pre-commit/pre-push guards, `C2C_COORDINATOR` bypass |
| Wake | optional self-DM `wake.toml` | `wake.toml` | `wake` + `sitrep` + heartbeat content referencing peers |
| Privilege flag | never set | never set | `C2C_PRIVILEGED`/`C2C_COORDINATOR` for relay-as-other + guard bypass |

**Design rule:** *Solo is the default.* Flat-mesh adds **one** thing (a named
social room). Structured-swarm is the union of opt-in modules. Today the binary
ships at the Structured-swarm end and a solo user must *subtract* — the union of
install defaults (swarm-lounge auto-join, swarm-agent intro, git-shim, role
prompt, `coordinator1` fallbacks) presumes hierarchy. We invert that: ship at
Solo, *add* to reach the others.

---

## 2. The minimal universal core (zero roles)

This is the irreducible floor — must compile and run with no role module, no
approval module, no swarm config, no `coordinator1` literal anywhere reachable.

**Broker (`c2c_broker.ml`).** `create`, `register` (role = optional free-text
metadata, never read for routing), `enqueue_message` (the actual 1:1 route,
`c2c_broker.ml:2105`), inbox drain, atomic registry persistence. Rooms as a
generic primitive (`join_room`/`send_room`/`room_history`/`my_rooms`/
`list_rooms`/`leave_room`/`delete_room`) with **creator-based** ACL
(`created_by`), not coordinator-based. `send_all` broadcast.

**MCP floor (5 tools):** `register`, `whoami`, `list`, `send`, `poll_inbox`
(`peek_inbox` a non-draining superset). `tools/list` already returns the full
static set to every session with no per-role gating (`c2c_mcp.ml:430-432`) —
keep that property.

**CLI floor:** `register`, `send`, `list`, `whoami`, `poll-inbox` — the
always-available fallback for any client without MCP. `send_cmd` has no
role/coord branch.

**Identity + transport:** alias validation (`c2c_name.ml`), 128-word auto-alias
pool (`c2c_alias_words.ml`), broker-root resolution (`c2c_repo_fp.ml` + XDG),
the `<c2c event=… from=… to=…>body</c2c>` envelope, per-client delivery adapters
(OpenCode embedded plugin drain, kimi notification-store, `c2c_deliver_inbox`
watcher). All alias-keyed, role-free.

**Per-alias services:** native scheduling (`schedule_set/list/rm`), per-agent
memory, DnD, compact-state. Engine already role-agnostic; only the *default
heartbeat content string* mentions a coordinator (a string fix, not structural).

**The one invariant to keep, not drop — the from-alias spoofing guard's
DEFAULT:** "you may only send as your own registered alias"
(`c2c.ml:108-147`, the *else* branch). This is the correct flat-mesh identity
rule. The `C2C_COORDINATOR` bypass on top of it is the opt-in privilege, not the
rule itself.

**Tier filter stays — it is not a role feature.** Command visibility keys solely
on `C2C_MCP_SESSION_ID` presence (`c2c_commands.ml:113`), an *agent-vs-operator*
axis orthogonal to roles. A solo user's shell is "operator" (sees everything),
their managed sessions are "agent" (advanced hidden). Keep as a universal UX
affordance; collapse the 4-tier ladder to a 2-state `advanced` boolean (see §6).

---

## 3. Features → opt-in modules + their seam

Each structured-team feature already lives in (or near) its own module. The work
is to give each a **single activation seam** and make that seam default-off,
rather than scattering defaults across install/broker/hooks.

| Module | Current coupling | Seam it plugs into | Activation |
|---|---|---|---|
| **Social room** (swarm-lounge auto-join + broker peer-register announce) | `"swarm-lounge" ::` hardcoded in **broker core** (`c2c_broker.ml:4073`, `c2c_identity_handlers.ml:349`); install writes `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` ×6 | **`swarm_config_social_room ()`** thunk (NEW; mirror `swarm_config_restart_intro`, `c2c_start.ml:710`) → `[swarm] social_room` in `.c2c/config.toml` | `social_room` set non-empty. Default `None` ⇒ broker announces only into rooms actually joined; no phantom room. |
| **Coordinator identity** (relay-as-other-alias, cherry-pick lock, worktree-warn exempt, git-shim bypass) | `C2C_COORDINATOR=1` env — one var, 3 unrelated jobs | **Split into named capability flags.** Messaging core reads only the relay one. | `C2C_RELAY_ANY_ALIAS=1` (relay), git-shim reads `C2C_GIT_GUARD_BYPASS=1`, cherry-pick keeps its own gate. `C2C_COORDINATOR` aliased for compat, then retired. |
| **Coordinator alias** (`coordinator1` as supervisor/DM-routing/doctor/onboarding default, ~70 sites) | hardcoded literal everywhere | **`swarm_config_coordinator_alias ()`** thunk (NEW) → `[swarm] coordinator_alias` | Set ⇒ that alias is the routing fallback. Unset ⇒ degrade: skip the DM / use current alias / "no coordinator configured". |
| **Approval / supervisor / pending-reply** (kimi PreToolUse, opencode permission.ask) | flat list-membership check is role-free; only the *default supervisor* is `coordinator1`; default-OFF install posture already | **`supervisors[]` in `.c2c/repo.json`** (already the seam) | Non-empty `supervisors[]` ⇒ gate active. Empty/unset ⇒ **fail-OPEN / self-approve**, not fall-closed to `coordinator1`. |
| **Escalation chain** (`coord_fallthrough` broker scheduler) | thread started unconditionally (`c2c_mcp_server_inner.ml:548`); no-op when chain `[]` | **`[swarm] coord_chain`** (already a thunk, defaults `[]`) | Start the thread only when `coord_chain` non-empty. Rename keys `coord_*→escalation_*`. |
| **Idle nudges** (`relay_nudge` thread, swarm-flavored "review a PR?" DMs) | thread started unconditionally (`c2c_mcp_server_inner.ml:537`) | gate on `social_room` configured (or a `[swarm] idle_nudges` flag) | Off for solo ⇒ no unsolicited nudges. |
| **Role files + rendering** (role_class, pmodel, required_capabilities, role-room auto-join) | already opt-in: no `--agent`/no name-match ⇒ flat full-capability peer (`c2c.ml:9633-9655`) | the role-load path itself (already gated) | A role file exists / `--agent` passed. Drop the dormant `coordinator: true → env` funnel; drop `C2C_AUTO_JOIN_ROLE_ROOM=1` from install defaults. |
| **Git-shim + pre-commit/pre-push guards** | installed by default via `c2c install self`; main-tree-vs-worktree structural check + env bypass | **own install component** (`c2c install git-shim`, already separable; uninstall treats it as a component) | Explicit install (or `--swarm`). Not part of default `install self`. Split `git_attribution` (identity) from `git_guards` (refusals). |
| **Sitrep / failover** | sitrep = role-template prose (no engine code); failover = 100% runbook | n/a (no binary surface) | Coordinator role loaded. Nothing to gate in the binary. |
| **Onboarding intro** ("you are a c2c swarm agent…") | `builtin_swarm_restart_intro` default | **`swarm_config_restart_intro`** (already a thunk) | **Invert default to neutral 1:1 text**; swarm framing becomes the override. |

**The pattern:** every module's seam is a config thunk returning `None`/`[]` by
default, OR a separable install component, OR a per-request list that means
"feature off" when empty. No module needs a runtime "what level am I?" query
inside the delivery path.

---

## 4. The selector — `[swarm]` config + a thin `mode` convenience

Two complementary mechanisms. The **fine-grained keys are authoritative**; the
**`mode` is sugar** that sets sensible defaults for those keys.

### 4a. Authoritative: per-feature `[swarm]` keys (`.c2c/config.toml`)

```toml
[swarm]
# --- structure selector (sugar; expands to the keys below) ---
mode = "solo"              # "solo" | "mesh" | "swarm"  (default: "solo")

# --- social layer ---
social_room        = ""    # "" => no auto-join, no broker announce. mesh/swarm => "swarm-lounge"
idle_nudges        = false  # relay_nudge thread. swarm => true

# --- coordinator / routing ---
coordinator_alias  = ""    # "" => no coordinator; DM fallbacks degrade. swarm => "coordinator1"

# --- approval / escalation (structured-swarm) ---
# supervisors live in .c2c/repo.json (per-request seam); empty => fail-open
escalation_chain   = []    # was coord_chain. [] => scheduler thread not started

# --- git discipline (separable install component, not a config toggle) ---
# `c2c install git-shim` installs guards; `git_attribution`/`git_guards` split

# --- rendering ---
restart_intro      = ""    # "" => neutral 1:1 intro (NEW default). swarm => swarm framing
```

**Resolution order** (so explicit always wins): explicit `[swarm].<key>` →
`mode` default for that key → built-in default (= solo behavior). This mirrors
the existing model-resolution precedence (`--model` > role pmodel > saved
config) the codebase already uses, so it is idiomatic here.

### 4b. Sugar: `mode` and `c2c install --mode <m>`

`mode` is a single value that, *only where the operator left a key unset*,
supplies that level's defaults:

- `solo` — `social_room=""`, `coordinator_alias=""`, `idle_nudges=false`,
  `escalation_chain=[]`, neutral intro, no git-shim, no role prompt, no
  role-room env. (= the built-in defaults; `mode` can even be omitted.)
- `mesh` — `social_room="swarm-lounge"` (one shared room), everything else solo.
  This is the *only* delta from solo: a name for the shared channel.
- `swarm` — `social_room="swarm-lounge"`, `coordinator_alias="coordinator1"`,
  `idle_nudges=true`, install git-shim + role rooms + role prompt; `supervisors[]`
  and `escalation_chain` still explicit (safety stays opt-in even in swarm mode).

`c2c install --mode swarm` reproduces today's install exactly (no behavior change
for the live swarm). `c2c install` with no flag = solo.

**Why both, not just one:** the fine keys are needed regardless (they're the real
seams every module reads). `mode` is a discoverability win — a solo user runs
`c2c install` and gets a clean channel; the swarm runs `--mode swarm` once. We do
NOT introduce a build-time profile; a single binary + runtime config keeps
cross-client parity and avoids a combinatorial build matrix. The only build-level
notion worth keeping is a *documented* "core vs swarm" module boundary so the
swarm modules (`coord_fallthrough`, `relay_nudge`, supervisor handlers, role
rendering) remain physically severable later if someone wants a minimal build —
but that's a follow-on, not required for decoupling.

---

## 5. Phased migration — never breaks the live swarm

Each phase is independently shippable, peer-PASS-able, and **behavior-neutral for
the existing swarm** because the swarm pins `--mode swarm` (or the equivalent
explicit keys) from phase 1.

**Phase 0 — establish the seam (no behavior change).**
Implement `swarm_config_social_room ()` and `swarm_config_coordinator_alias ()`
thunks (mirror `swarm_config_restart_intro`, `c2c_start.ml:710`). They *exist*
but every call-site still hardcodes the literal — nothing routes through them
yet. Pure addition. Ship. (This is also `03`'s A1, the highest-leverage change.)

**Phase 1 — pin the swarm, then route through the seam.**
Write `[swarm] mode = "swarm"` (or explicit keys) into the live repo's
`.c2c/config.toml` and commit it FIRST. *Then* migrate the ~15 `swarm-lounge` and
~70 `coordinator1` call-sites to read the thunks. Because the live repo's config
resolves both to today's literals, behavior is identical for the swarm — but the
literals are now removable and a config-less repo resolves to solo. Verify with
`relay-smoke-test.sh` before any deploy.

**Phase 2 — invert defaults (guarded by Phase 1's pinning).**
Flip built-in defaults to solo: neutral `restart_intro`, `social_room` default
`None`, drop `"swarm-lounge" ::` prepend in broker core (announce only joined
rooms), gate `relay_nudge`/`coord_fallthrough` thread starts on config. The live
swarm is unaffected (its config pins the old values). A fresh `c2c install`
(no `--mode`) now yields a clean solo channel.

**Phase 3 — split the overloaded flag + approval fail-open.**
Introduce `C2C_RELAY_ANY_ALIAS` / `C2C_GIT_GUARD_BYPASS`, alias `C2C_COORDINATOR`
to set all three for one release. Make empty `supervisors[]` fail-open/self-
approve in the kimi + opencode hooks (today's solo footgun: 10-min timeout →
auto-reject). Drop the dormant `coordinator: true → env` funnel (no shipped role
sets it — confirmed dead).

**Phase 4 — install hygiene + tier collapse.**
Move git-shim out of default `install self` into `c2c install git-shim`
(`--mode swarm` installs it). Drop `C2C_AUTO_JOIN_ROLE_ROOM=1` from install
defaults. Collapse the 4-tier `safety` type to a 2-state `advanced` boolean,
generate all display from the single command map (kills the 3 drifted
hand-maintained tier lists). Make `prompt_for_role` opt-in.

**Phase 5 — retire compat shims + dead weight.**
Remove the `C2C_COORDINATOR` alias once peers are on the split flags. Purge crush
residue (~25 sites, already refuses), the dead `configure_claude_hook`
(`c2c_setup.ml:1006`), legacy `run-*-inst*`/`restart-*-self` launchers, the
unused `data/c2c_alias_words.txt`, and (coordinated via the shared tree) the ~50
deprecated root Python scripts.

**Rollback at every phase:** revert the single slice; because phases 0–1 are
additive and the swarm is pinned, no rollback touches live delivery.

---

## 6. Trade-offs — what we LOSE, and what we accept

**Net complexity DELETED (the win):**
- One config seam replaces ~85 hardcoded literals (`swarm-lounge` ×15 +
  `coordinator1` ×70).
- 4-tier ladder → 2-state boolean; 3 drifted display lists → 1 generated source.
- One overloaded env var → 3 honestly-named flags; the messaging core stops
  conflating "I am coordinator" with "I may send as someone else."
- Two broker-core swarm prepends gone ⇒ the broker becomes *provably*
  role/social-agnostic (no module it doesn't open can leak in).
- Dead weight removed: crush, dead hook fn, legacy launchers, unused wordlist,
  ~50 Python scripts.

**What we LOSE / costs we accept:**
- **A "just works as a swarm out of the box" default.** New swarm operators must
  `--mode swarm` once. Mitigated: it's one flag, documented; the live swarm pins
  it in committed config so *nothing* changes for us.
- **`coordinator1` as a universal Schelling point.** Solo/mesh users with no
  `coordinator_alias` lose the implicit "DM the coordinator" target — DM
  fallbacks must each define a no-coordinator behavior (skip / self / current
  alias). This is *new code paths*, the main non-trivial work; ambiguous today
  because the literal masks the question.
- **Fail-open approval is a real security posture change.** Empty `supervisors[]`
  → allow means a misconfigured *swarm* (meant to gate but left empty) silently
  stops gating. Mitigation: `mode=swarm` could warn when `supervisors[]` is empty;
  keep fail-*closed* iff `mode=swarm`, fail-open only for solo/mesh.
- **Migration touches MANY files** (the ~85 literal call-sites). Low *risk*
  (mechanical, behind a pinned config) but high *diff surface* — must be sliced,
  not one mega-commit, and each slice peer-PASSed in its own worktree.
- **Config sprawl risk.** Adding `[swarm]` keys could itself become the new mess.
  Mitigation: keep it to the ~5 keys above + `mode`; resist a knob per feature.
- **Two ways to set the same thing** (`mode` vs explicit keys) can confuse.
  Mitigation: document `mode` as sugar with explicit-wins precedence, exactly as
  `--model` overrides pmodel today.
- **The git-shim default-off means a fresh solo install loses main-tree commit
  protection.** Correct for solo (no peers to protect against) but worth a
  one-line note in `c2c init` output so the choice is visible.

---

## --- SUMMARY ---

- **The core is already role-agnostic** (broker opens no role/coord/relay
  module; `role` is free-text display metadata). Decoupling is an *exterior*
  refactor of **defaults and edges**, not surgery on delivery — that is why it
  is low-risk.
- **Structure spectrum = Solo ⊂ Flat-mesh ⊂ Structured-swarm**, all on one
  binary/broker/wire format. Solo becomes the default; each higher level *adds*
  config-selected modules. Flat-mesh's only delta over solo is **one named
  social room**.
- **Minimal universal core (zero roles):** broker route + rooms (creator-ACL) +
  `send_all`; 5 MCP tools (register/whoami/list/send/poll_inbox); CLI floor;
  alias identity; per-client delivery; per-alias schedule/memory/DnD. Keep the
  from-alias *default* guard and the session-id tier filter — both role-free.
- **Every team feature → a module with one seam:** social room, coordinator
  alias, escalation chain, idle nudges via `[swarm]` config thunks (default
  `None`/`[]`); approval via `supervisors[]` (empty ⇒ fail-open); git-shim via a
  separable install component; role rendering via the already-gated role-load
  path. No module is queried inside the delivery path.
- **Selector = `[swarm]` config (authoritative per-feature keys) + a `mode`
  sugar** (`solo`/`mesh`/`swarm`) that fills unset keys; explicit-wins
  precedence, mirroring existing `--model` resolution. **Single binary, runtime
  config — no build-time profile fork** (preserves cross-client parity).
- **Migration is 6 phases, swarm-safe:** (0) add the two missing config thunks;
  (1) pin live swarm via committed config, *then* route ~85 literals through the
  thunks; (2) invert built-in defaults to solo (drop broker swarm-lounge
  prepend, gate the two background threads); (3) split `C2C_COORDINATOR` into
  3 honest flags + approval fail-open; (4) install hygiene + tier collapse;
  (5) retire compat shims + delete crush/dead-fn/legacy-launchers/Python.
- **We DELETE more than we add:** ~85 literals → 1 seam, 4 tiers → 2 states,
  1 overloaded env var → 3, two broker-core leaks gone, plus dead-weight purge.
- **What we LOSE:** the out-of-box-swarm default (now one `--mode swarm` flag),
  `coordinator1` as an implicit DM target (each fallback needs a defined
  no-coordinator behavior — the main real work), and a security nuance (fail-open
  approval — gate it fail-closed only when `mode=swarm`). High diff surface, low
  risk because everything rides behind pinned config.
