# Website Docs Drift Audit — 2026-04-28T12:32Z

Scope: every `docs/*.md` file (Jekyll publish-by-default) cross-referenced
against today's commit log (~24h: peer-pass H1/H2/H2b/M1, Gemini #406abc,
#393 history --alias, #394 rooms create, restart-self deprecation #395,
#341 swarm restart_intro, #401 coord-cherry-pick --no-fail-on-install,
#346 channel-drain default flip, #383 peer_offline broadcast, …).

## Per-file verdicts

| File | Surface documented | Drift? | Notes |
|---|---|---|---|
| `index.md` | Front-door hero / quick-start / install table | **DRIFT** | Hero says "Claude Code, Codex, OpenCode, and Kimi" — Gemini missing. Install table (lines 93–97, 105–109) lists 5 clients but no Gemini row. Says "Four-client parity". |
| `overview.md` | Architecture + per-client install/delivery | **DRIFT** | Lists Claude/Codex/Codex-headless/OpenCode/Kimi/Crush sections (l.57–211) — no Gemini section. Top-level enumeration (l.11, l.22) excludes Gemini. |
| `get-started.md` | First-session onboarding | **DRIFT** | "Four clients (Claude Code, Codex, OpenCode, Kimi) are fully supported" (l.15) + "all 5 client types (Crush experimental)" (l.17) — Gemini absent; client count stale. |
| `communication-tiers.md` | Tier matrix (which paths work for which client) | **DRIFT** | Cross-client send matrix (l.34–39) is 4×4 Claude/Codex/OpenCode/Kimi — no Gemini row/column. Restart matrix (l.105–106) still lists `./restart-self` and ghost subcommand `c2c restart-me` (deprecated #395 → `c2c restart <name>` is canonical). |
| `commands.md` | Full CLI reference | **DRIFT** | (a) No `rooms create` row (#394 added `c2c rooms create` with `--visibility / --invite / --no-join`); only join/leave/invite/list/history/tail rows. (b) `install` row (l.574) lists `claude\|codex\|codex-headless\|opencode\|kimi\|crush` — no `gemini`. (c) `start` row (l.614) clients list also missing `gemini`. (d) `history` row (l.589) DOES correctly show `--alias A` (#393 propagated). (e) peer-pass row (l.720) is current with H2/H2b. |
| `client-delivery.md` | Per-client wake/install/restart playbooks | **PARTIAL** | Gemini section EXISTS (l.362–451, landed #406c earlier today) and DM matrix has Gemini row (l.479) with `?` cells — needs field-validation update. BUT three earlier sections (Claude l.58–70, Codex l.144–153, OpenCode l.248–251) still recommend `./restart-self`; should redirect to `c2c restart <name>` (#395). |
| `MSG_IO_METHODS.md` | Delivery-mechanism inventory + env var table | **DRIFT** | Env-var table (l.564–566) does not list `C2C_AUTO_ANSWER_CHANNELS_PROMPT` (#399b) — but I could not find that exact symbol in `ocaml/` either; verify the name before filing. Crush rows (l.355, l.365, l.375) still treat Crush as "deprecated"; #405 is in flight to fully retire it — wording fine for now but follow-up needed. No Gemini row. |
| `known-issues.md` | Known-issues catalog | OK-ish | `C2C_MCP_AUTO_DRAIN_CHANNEL` warning still correct after #346 (default flipped to OFF). |
| `architecture.md` | High-level architecture | Likely OK | Auto-join env-var reference accurate. Did not deep-dive — no obvious client-list claims. |
| `relay-quickstart.md`, `cross-machine-broker.md`, `agent-files.md`, `phase1-implementation-steps.md`, `ocaml-module-structure.md` | Each mentions clients in passing | Low-prio drift | Same Crush/Gemini drift class but on lower-traffic pages; bundle into a sweep. `ocaml-module-structure.md` line numbers (e.g. l.64 `setup_crush` 5529–5613) are line-number-fragile per documentation-hygiene runbook and should be re-verified. |
| `channel-notification-impl.md` | Channel-push internals | OK | Defaults match #346 reality. |
| `agent-file-schema-draft.md`, `dnd-mode-spec.md`, `gui-*`, `monitor-json-schema.md`, `opencode-plugin-statefile-protocol.md`, `pty-injection.md`, `remote-relay-transport.md`, `research.md`, `team-self-upgrade-process.md`, `verification.md`, `x-codex-client-changes.md`, `HANDOVER.md`, `README.md` | Specs / internals / drafts | Not in today's blast radius. |

## Peer-pass crypto trio status

`commands.md:720` describes H2 + H2b (broker-side enforcement, pin store
at `<broker_root>/peer-pass-trust.json`, flock-serialized save per S1
`ef09077c`, `--rotate-pin` rotation). **Accurate** to today's landing
sequence (2af9def4 H1, d2c8ec38 H2, 0c57b839 H2b, 2af9def4 M1,
acf340a1 #409 lockf, 7d0db330 #57, ed886cf4 #57b, 0917d625 #56). M1
(reviewer-is-author + co-authored-by) and #57 path-traversal validator
are NOT mentioned in the public docs anywhere — fine for a security
hardening backstop but worth a one-line follow-up.

## #395 restart-self deprecation propagation

CLAUDE.md is updated; `deprecated/restart-self` is the new home.
Public docs propagation is **incomplete**:
- `docs/communication-tiers.md` l.105–106 still names both `./restart-self`
  and the never-shipped `c2c restart-me`.
- `docs/client-delivery.md` Claude/Codex/OpenCode sections (l.58, 144, 248)
  still tell agents to call `./restart-self`.

## Top 5 fix-now items (each = one small docs slice)

1. **Add Gemini to front-door pages** — `index.md` (hero_lead, install
   table at l.93–109), `overview.md` (per-client section parallel to
   Kimi/Crush), `get-started.md` (l.15, 17, 53). Bump "four-client
   parity" → "five-client parity (Gemini polling-only)".

2. **Add Gemini row/column to `communication-tiers.md` send matrix**
   (l.34–39) — currently 4×4. Mark Gemini cells with provisional ✓ for
   sends-from and validate received-by via tmux smoke. Same file: drop
   `c2c restart-me` ghost row; replace `./restart-self` row with
   `c2c restart <name>` per #395.

3. **`commands.md` rooms-create + install/start gemini rows.** Add
   `rooms create` row near l.598 (#394: `--visibility public|invite_only`,
   `--invite ALIAS,…`, `--no-join`). Add `gemini` to the client
   enumeration in `install` row (l.574) and `start` row (l.614).

4. **`client-delivery.md` restart cleanup.** Replace three
   `./restart-self` references in the Claude (l.58–70), Codex (l.144–153),
   and OpenCode (l.248–251) sections with `c2c restart <name>`. Also
   field-validate the Gemini DM matrix row (l.485–491) — replace `?`
   cells with concrete ✓/✗ from a tmux peer-pair smoke.

5. **`MSG_IO_METHODS.md` env-var table + Gemini install row.** Add
   `C2C_AUTO_ANSWER_CHANNELS_PROMPT` (#399b) to the env table at
   l.564–566 — but **first verify the canonical symbol name in
   `ocaml/`** (not found in a quick grep; the slug may be off). Add a
   Gemini install path row alongside the Kimi row at the bottom of the
   install table.

(Bonus — not top-5 but bundle-able into #3: refresh
`ocaml-module-structure.md` line-number citations, which the
documentation-hygiene runbook flags as drift-prone.)
