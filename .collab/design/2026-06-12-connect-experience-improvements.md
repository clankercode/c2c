# Connect Docs + Experience — Improvement Design

**Date:** 2026-06-12 · **Author:** claude (orchestrator) · **Status:** APPROVED-IN-PRINCIPLE — decisions resolved, spec for final review
**Location rationale:** `.collab/design/` (tracked, NOT published) — writing under `docs/` would
publish a half-baked spec to c2c.im (Jekyll publish-by-default).

> **Revision 2 (2026-06-12):** folds in Max's decisions + the Codex (`@cx-reviewer`)
> plan review (`…REVIEW-codex.md`). Major changes from r1: **Gemini + Crush are being
> REMOVED, not made consistent** (docs + CLI surface); **one flagship push** (P1+P2+P3
> together); `/get-started/` reuse+redirect; the Phase-3 verifier becomes a broader
> **`c2c connect`** umbrella command; the `relay.json` backlog item is **dropped** (Codex
> proved current OCaml already consumes saved relay config). Resolved decisions in §8.

---

## 1. Problem

A brand-new user/agent landing on **c2c.im** and trying to connect hits a string of avoidable
friction. Three parallel explorations (public docs, CLI UX, harvested findings/runbooks) converge
on the same picture: the *mechanics* mostly work, but the **connect journey is unsignposted, the
docs contradict themselves about what's supported, and there is no obvious newcomer-facing way to
confirm "it's working" after the mandatory restart.** The single highest-churn theme in recent
history is "restart/reload is required but not obvious," and the single highest-value missing
capability is "send yourself a ping and confirm push delivery is live."

## 2. North star (from CLAUDE.md group goal + active-goal.md)

- **CLI self-configuration:** "operators should not need to hand-edit settings files"; `c2c` turns
  on auto-delivery on any host client that supports it.
- **First-class clients: Claude, Codex, OpenCode, Kimi.** **Gemini is being deprecated/removed**
  (CLI being sunset) and **Crush is already DEPRECATED** (`c2c start crush` refuses). The site and
  CLI should advertise the **four** supported clients with cross-client parity. Local-first ("no
  server to run"); the public relay is an additive cross-machine bridge.
- **Sensible defaults / discoverability:** `c2c init`, `swarm-lounge` auto-join, discoverable peers.
- First-run promise (today's hero): "Setup is three short steps" — install → `c2c init` → restart →
  confirm.

Every improvement below should move the real experience toward that promise.

## 3. What's broken (evidence-backed, deduped; Codex-corrected)

### 3a. Docs accuracy / truth drift  *(low risk, high trust-value)*
- **Gemini + Crush should be removed, and the docs are inconsistent about both.** Gemini is claimed
  first-class in some lines, dropped from the "parity" headline, absent from the feature matrix, and
  present in `client-delivery.md` — i.e. inconsistent. *Decision:* rather than reconcile, **strip
  Gemini and Crush from the public surface.** Evidence of the current drift: `index.md:52` ("Five
  clients") vs `:53` ("Four-client parity"); `get-started.md:15` vs `:18`;
  `clients/feature-matrix.md:19` (4 columns, no Gemini); `overview.md:11,22`; Gemini present at
  `client-delivery.md:334,451`. Crush surfaces as "experimental" in the hero and as managed-client
  guidance in `known-issues.md:92,94`.
- **Hero renders a wrong stat on the live homepage:** `_layouts/home.html:24` = **"4 clients +
  Crush exp"** — Crush is DEPRECATED, not experimental. Fix to the honest four-client statement.
- **`layout: docs` does not exist** (`_layouts/` only has `home.html`; site uses `minima`,
  `_config.yml:6`) → `clients/feature-matrix.md:4` and `clients/e2e-checklist.md:4` render
  unstyled / warn. *Action:* verify the build warning, replace with a valid layout (`page`/default).
- **Stale `.py` references — AUDIT, don't blind-delete** (`docs/CLAUDE.md` hygiene rule). The canonical
  binary is OCaml; `c2c_*.py` are deprecated except where used by tests/tooling. Some doc `.py` refs
  are *intentionally* historical/deprecated context (`overview.md:85`, `client-delivery.md:294-301`)
  and should be kept-as-context or quarantined, not deleted. Others are stale how-to that should point
  at the OCaml subcommand. Refs to audit: `overview.md:60,85`; `known-issues.md:11,59`;
  `client-delivery.md:231,294,300-301,437`.
- **Stale managed-client guidance:** `known-issues.md:92,94` lists `crush` + `run-*-inst-outer`
  scripts replaced by `c2c start`.
- **`docs/commands.md` is in P1 scope (Codex add).** It duplicates relay + install command surfaces
  (`commands.md:857-876`, `:928-943`) and is a standing drift source; truth-pass it alongside the rest.

### 3b. Docs structure / journey  *(medium risk, high value)*
- **`/get-started/` is a changelog masquerading as the quickstart.** H1 is "Next Steps"
  (`get-started.md:8`); body is "What's Shipped Recently" (`:10`) + "Spawning Child Sessions"
  internals (`:26`). It's in top nav (`_config.yml:21`) and the homepage calls it the "full
  changelog" (`index.md:55`). The natural "where do I start" click lands on release notes.
- **No explicit "which path are you on?" fork** — the biggest journey gap. Local swarm (`c2c init`,
  `swarm-lounge`, alias-only) vs connect-to-a-specific-person (`c2c relay register`, Ed25519 TOFU)
  are two entirely different flows that are never contrasted. A user who wants to reach a friend runs
  `c2c init`, lands in `swarm-lounge`, and can't understand why they can't reach them.
- **Per-client delivery duplicated across 4 pages** (`index.md` table, `overview.md`,
  `client-delivery.md`, `clients/feature-matrix.md`) — a drift factory; that's *why* Gemini is right
  in some and missing in others.
- **No local-path "is it working?" step in the newcomer/front-door flow** (Codex-corrected wording).
  A local self-send smoke test *does* exist in specialist docs (`clients/feature-matrix.md:159-164`,
  `clients/e2e-checklist.md:64-76`) and the relay round-trip is documented (`connect.md:169-173`) —
  but **the quickstart a newcomer actually lands on has none.**
- **No dedicated rooms page** despite rooms being first-class. *(Deferred — see §8 Q5.)*
- **known-issues.md is a maintainer changelog,** half crossed-out "(Fixed)" entries, heavy assumed
  context — intimidating, not newcomer troubleshooting.

### 3c. Connect experience / CLI  *(medium-large, highest functional value)*
- **No live-delivery self-verification after the mandatory restart.** Restart is *advisory text only*
  (repeated in ~6 print sites; **`install all` omits it entirely** — prints only `Done.`,
  `c2c_setup.ml:1852-1877`, vs the interactive installer's restart guidance `:1763-1764`). Nothing
  confirms push delivery actually went live. The raw materials exist — broker archive persists
  `drained_by` with path labels (`deliver-watch`/`xml`/`oc_plugin`/`hook`/`poll_inbox`),
  `c2c_broker.ml:2312-2358` — but aren't wired into a probe.
- **The connect-doctor is hidden and the names are a maze.** `c2c health` (`c2c.ml:2158-2244`) is the
  real connection diagnostic (broker, registry/liveness, relay HTTP, **per-client plugin installs**)
  — but it's named "health," not pointed to by any install/init output, and `check_plugin_installs`
  (`c2c.ml:2008-2058`) currently only covers Claude/OpenCode/GUI (not Codex/Kimi). Meanwhile `doctor`
  is **repo-only push-readiness** (`c2c.ml:7742-7827`), `verify` measures a 20-message swarm goal,
  `smoke-test` uses a **throwaway temp broker** (`c2c.ml:6588-6611`, can't validate the real install),
  and `doctor delivery-mode` counts **sender intent**, explicitly NOT delivery actuals
  (`c2c_broker.ml:2477-2484`, `c2c.ml:8501-8504`). Five commands that sound like "check it works,"
  none surfaced as *the* connect check.
- **`init` no-client hint is stale** — hardcodes `opencode/claude/codex/codex-headless`
  (`c2c.ml:6739-6743`) while the configurable list is broader (`c2c_setup.ml:1469-1470`). Post-removal
  it should list the four supported clients.
- **`init`'s identity step is silent-and-swallowed** (`c2c relay identity init 2>/dev/null`, rc
  ignored, `c2c.ml:6782-6784`) → later relay registration can fail opaquely.
- **Machine-specific `server_path` + `C2C_MCP_BROKER_ROOT` baked into (often tracked) configs**
  (`.opencode/opencode.json`, `~/.codex/config.toml`, `~/.kimi/mcp.json`) — the churn we hit this
  session restoring `.opencode/opencode.json`. *(Deferred to P4.)*

### 3d. Adjacent / deeper (related, flagged, NOT core scope)
- ~~`relay.json` ignored by `relay status/connect/list`~~ **— DROPPED. Codex disproved it:** current
  OCaml resolves saved relay config via `resolve_relay_url`/`resolve_relay_token` and all three
  subcommands use it (`c2c.ml:4276-4327,4388,4492-4497,4518-4523`). No action.
- The **`c2c install` consistency audit (P1–P8)** — six install paths diverge on env vocab, JSON-merge
  (non-JSON configs clobbered = data loss), writer↔verifier parity; mostly OPEN. Own effort.
- No managed one-command "join relay + keep heartbeating" daemon.

## 4. Proposed approach — ONE flagship push (P1 + P2 + P3 together)

Per Max: **single push**, all three phases. The phases below are organizational (slice boundaries),
not separate deploys. Each *slice* still ships through the worktree → review-and-fix → cross-review →
codex → merge pipeline; they batch into one push to origin/master (one Railway + Pages build).

### Phase 1 — Docs truth pass + Gemini/Crush removal  *(small/low-risk; 1–2 slices)*
- **Remove Gemini and Crush from the public docs surface:** drop the 4-vs-5 contradictions in favour
  of the honest **four-client** statement; remove Gemini from `client-delivery.md`, any feature
  matrix/columns, `overview.md` list+diagram; remove Crush "experimental"/managed mentions.
- **Hero:** fix `_layouts/home.html:24` ("4 clients + Crush exp" → four-client honest statement);
  make the hardcoded fallback match `index.md` front-matter.
- Replace `layout: docs` with a valid layout on feature-matrix + e2e-checklist (verify build warning).
- **Audit (not blind-delete) stale `.py` refs** → OCaml subcommands where they're how-to; keep/quarantine
  the intentionally-historical ones. Fix `known-issues.md` crush/`run-*-inst-outer`.
- Truth-pass `docs/commands.md` (relay + install duplicated surfaces).
- **Verify each touched command against `c2c <subcmd> --help`** (documentation-hygiene rule).

### Phase 2 — Connect journey restructure  *(medium; 2–3 slices)*
- **Make `/get-started/` a real quickstart (reuse + redirect).** Move the changelog content to a new
  `/changelog/` permalink; rewrite `/get-started/` as the canonical 3-step quickstart ending with the
  "is it working?" check (which will be `c2c connect`, see P3). Keep the `/get-started/` URL (no SEO
  loss for the quickstart); fix the `index.md:55` "full changelog" link to `/changelog/`; preserve any
  inbound changelog links via the new permalink + link fixes.
- **Add the "which path are you on?" decision** near the top of the front door: (a) local swarm,
  (b) reach a specific person across machines → `/connect/`, (c) run your own relay → relay-quickstart.
  A short signpost block, one line each, linking out. Highest-leverage doc change. **Make the
  human-operator / cross-machine relay on-ramp explicit here** (Codex: more important than a rooms page).
- **Consolidate per-client delivery to ONE canonical page:** `clients/feature-matrix.md` is the single
  source of truth; `client-delivery.md` becomes a thin redirect/summary that links to it. Until the
  merge lands, feature-matrix is declared authoritative to stop re-drift. *(Decision Q4 resolved.)*
- **Add a newcomer troubleshooting section** for the actual first failures: "I ran init but `list`
  shows nobody," "my friend can't reach me (wrong path)," "messages only arrive when I poll (you didn't
  restart) — run `c2c connect --verify`."

### Phase 3 — `c2c connect` umbrella command + doctor unification  *(larger; 2–3 slices, OCaml)*
The flagship functional improvement. Max's steer: **make `c2c connect` a helpful umbrella that does a
bunch of connect-related things smoothly**, not merely a `--verify` flag.

**`c2c connect` (bare) — the newcomer connect dashboard + next-step.** Repo-independent (unlike
`doctor`). Wraps the existing `c2c health` checks into a friendly summary and tells the user the single
next action:
- your alias / registration state (`whoami` + registry liveness),
- which supported clients are installed and whether auto-delivery is configured (reuse +
  extend `check_plugin_installs` to cover Codex/Kimi, not just Claude/OpenCode),
- relay status (if configured),
- current rooms,
- **the one next step** ("not installed yet → `c2c install <client>`", "installed but not restarted →
  restart + `c2c connect --verify`", "all good → you're connected").

**`c2c connect --verify` — the loopback delivery probe** (the headline). Semantics fixed per Codex —
the CLI can prove broker enqueue + auto-consumer drain, **not** universal transcript injection:
- enqueue a **unique, non-ephemeral self-marker** through the *configured* broker (never ephemeral —
  ephemeral drains aren't archived, `c2c_broker.ml:2273-2276`),
- watch the archive's `drained_by` for that marker for N seconds,
- report:
  - `PASS: consumed by auto-delivery path <drained_by>` (push live),
  - `INCONCLUSIVE: still queued — restart your client / it may use poll delivery`,
  - `FAIL: broker/registration/config path broken`,
  - `NOT PROVEN: <client> transcript visibility is client-specific and not CLI-observable` (honest
    footnote, never claims "delivered to your transcript"),
- **never drains the user's real inbox** — isolates its own marker; if it can't isolate, it says so
  (Decision Q6 resolved). Client caveats documented in the verifier's `--help` and code comments:
  Claude hook may not fire until after the tool turn; Codex XML drains before FD write; Kimi uses the
  notification-store path (verifier branches or reports "not fully observable").

**`c2c connect --fix` (optional, v1-or-fast-follow):** offer to run the missing install/init steps the
dashboard found. Keep tight; can land as a thin wrapper over existing `install`/`init`.

**Doctor-family unification:** `c2c connect` becomes the discoverable, repo-independent front door for
"is it working?"; `health`/`doctor`/`smoke-test`/`verify` stay as lower-level/specialized tools.
Make `init`/`install`/`install all` epilogs all end with the **one** canonical line —
`Run 'c2c connect --verify' to confirm delivery is live` — instead of per-client `opencode mcp list` /
`gemini mcp list` fragments. **Add the restart footer to `install all`** (`c2c_setup.ml:1852-1877`).

**Small `init` fixes:** complete the no-client hint (four supported clients); stop swallowing the
identity step (surface a real error/hint on failure).

### Phase 4 — (backlog, not now)
Broker-root/server-path indirection to kill config churn; the P1–P8 install-consistency convergence;
managed relay-heartbeat daemon. Track separately.

## 5. The `c2c connect` command surface (summary)

| Invocation | Does | Proof level |
|---|---|---|
| `c2c connect` | Dashboard: alias, install/auto-delivery status per supported client, relay, rooms, **next step** | Static introspection (no message sent) |
| `c2c connect --verify` | Loopback self-marker → watch `drained_by` | broker enqueue + auto-drain; PASS/INCONCLUSIVE/FAIL/NOT-PROVEN |
| `c2c connect --fix` *(opt)* | Run the missing install/init step the dashboard found | wraps existing install/init |

Design principles: repo-independent (works outside a git tree, unlike `doctor`); never touches the
real inbox; honest about what the probe does/doesn't prove; one canonical "verify" line everywhere.

## 6. Testing / validation
- Docs: `bundle exec jekyll build` clean (no layout warnings); link-check (esp. the `/get-started/` →
  `/changelog/` move and `index.md:55`); every command block verified against `c2c <subcmd> --help`;
  the docs-up-to-date peer-PASS gate (P3 changes CLI help → docs must move with it).
- CLI: unit tests (fixture-gated broker) for `--verify`: assert PASS on a live push drain, INCONCLUSIVE
  on a still-queued marker, FAIL on a broken broker/registration; assert the probe **never drains a
  pre-seeded real inbox message**. `c2c connect` dashboard rendering under fixtures. Tests use temp
  HOME/broker roots so they don't churn tracked config (Codex risk).
- Live dogfood in tmux across ≥2 clients (Claude + one other, e.g. Codex/OpenCode/Kimi) per the testing
  rules — drive real sessions, confirm `--verify` reports PASS only after a real restart.
- Each slice: worktree → impl review-and-fix → peer cross-review (different model: mm3/mimo25p/glm51) →
  codex → merge; batch all into the single push.

## 7. Risks / watch-items
- **Jekyll publish-by-default:** every docs edit is live on push; stage in worktrees, build locally.
- **`/get-started/` URL move:** reuse-the-URL avoids the worst SEO hit, but the changelog content move
  needs the new `/changelog/` permalink + the `index.md:55` link fix or inbound "changelog" links break.
- **Loopback verify observability:** the CLI proves broker drain, not client transcript injection —
  the output must say so (NOT-PROVEN line) and never overclaim "delivered to transcript."
- **False-positive verification:** a marker in archive means "consumer drained," which can precede a
  client display failure — wording stays at "consumed by <path>," not "you saw it."
- **Docs-up-to-date peer-PASS gate:** P3 changes CLI help/output → the same slice must update docs +
  `commands.md`.
- **Tracked-config churn during testing:** `init`/`install`/relay setup touch `.mcp.json`,
  `.opencode/opencode.json`, `.c2c/*` — tests/dogfood use temp HOME/broker roots or explicit cleanup
  (we already hit this restoring `.opencode/opencode.json` this session).
- **Doctor naming collision:** `c2c connect` is additive; `c2c doctor` keeps its push-readiness meaning.
- Consolidating delivery docs risks losing detail mid-merge — diff carefully.

## 8. Decisions — RESOLVED (2026-06-12, Max + Codex)
- **Q1 — Scope/sequencing:** **ONE flagship push**, P1 + P2 + full P3 together. *(Max.)*
- **Q1b — Gemini/Crush removal depth:** **Docs + CLI surface.** Strip from docs, install menus, help,
  feature matrix; `c2c install gemini` refuses like crush; **leave GeminiAdapter/setup_gemini code
  dormant (no code deletion this cut).** *(Max.)*
- **Q2 — `/get-started/` URL:** **Reuse + redirect.** `/get-started/` becomes the quickstart; changelog
  moves to `/changelog/`; fix the homepage link. *(Max.)*
- **Q3 — Connect command:** **`c2c connect` umbrella** with `--verify` (and optional `--fix`), not just
  a flag. v1 proof level = **broker enqueue + auto-drain** (PASS/INCONCLUSIVE/FAIL/NOT-PROVEN), never
  transcript injection. *(Max + Codex.)*
- **Q4 — Canonical delivery page:** **`clients/feature-matrix.md`** is the single source; thin out
  `client-delivery.md` to a redirect/summary; feature-matrix authoritative until the merge lands.
  *(Default, unopposed.)*
- **Q5 — Rooms page / human-operator track:** **skip the standalone rooms page**; instead add the
  **human-operator / cross-machine relay on-ramp** to the P2 path-fork (Codex: higher value). *(Default
  + Codex.)*
- **Q6 — Probe inbox safety:** `c2c connect --verify` **never drains the real inbox**; unique
  non-ephemeral marker; reports if it can't isolate its marker. *(Default + Codex.)*

---

--- SUMMARY ---

- **Goal:** make the c2c.im connect docs + the `c2c` connect experience match the "three short steps,
  it Just Works" promise. The mechanics work but the journey is unsignposted, the docs contradict
  themselves (esp. Gemini/Crush), and there's no newcomer-facing way to confirm delivery is live after
  the required restart.
- **Decisions locked (Max + Codex review):** **ONE flagship push** of all three phases; **remove
  Gemini + Crush** from docs + CLI surface (code left dormant); `/get-started/` becomes the quickstart
  with changelog moved to `/changelog/`; the Phase-3 verifier grows into a **`c2c connect` umbrella
  command**; the `relay.json` backlog item is **dropped** (Codex disproved it).
- **Phase 1 (truth pass):** strip Gemini/Crush, fix the wrong hero stat, replace nonexistent
  `layout: docs`, **audit** (not blind-delete) stale `.py` refs, truth-pass `commands.md`, verify every
  command vs `--help`.
- **Phase 2 (journey):** real `/get-started/` quickstart + `/changelog/` redirect; the "local-swarm vs
  reach-a-person vs run-your-own-relay" path fork (with the human-operator on-ramp); consolidate
  per-client delivery onto `feature-matrix.md`; newcomer troubleshooting.
- **Phase 3 (`c2c connect`):** umbrella command — bare = connect dashboard + next-step (repo-independent,
  wraps `health`, extends `check_plugin_installs` to Codex/Kimi); `--verify` = loopback self-marker
  proving broker enqueue + auto-drain (PASS/INCONCLUSIVE/FAIL/NOT-PROVEN, never claims transcript
  injection, never drains the real inbox); optional `--fix`. Unify the doctor maze behind one canonical
  "verify it worked" line; add the restart footer to `install all`; fix `init` hint + swallowed identity.
- **One push, many slices:** each slice ships via worktree → review-and-fix → cross-review
  (mm3/mimo25p/glm51) → codex → merge, batched into a single origin/master push (one Railway + Pages
  build). Jekyll publish-by-default → stage in worktrees, build locally. Tests use temp HOME/broker
  roots to avoid tracked-config churn.
