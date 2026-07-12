# B137 — Codex app-server dual-identity (fixed) + global-inbox follow-up

- **Severity:** medium (routing hygiene; surfaced in B131 live E2E)
- **Status:** FIXED on `slice/b137-codex-dual-identity`
- **Area:** `ocaml/cli/c2c_hook_cmd.ml` (codex hook), `ocaml/c2c_codex_session.ml` (launcher)

## Symptom

A managed `c2c new codex` app-server session showed **two** identities in
`c2c list`: the launcher's routable app-server alias (registered by
`C2c_codex_session.run_delivery_loop`, `client_type=codex-app-server`) AND a
second, separate alias self-registered by the stock frontend's
`c2c hook codex` SessionStart.

## Root cause

As seen by the hook, a real app-server session:
- sets **no** `C2C_MCP_SESSION_ID` (the frontend is spawned by
  `C2c_codex_app_server.start`, not `run_outer_loop`/`build_env`);
- does **not** map through the legacy `config.json` that
  `managed_session_id_from_codex_thread` reads (it persists
  `codex-session.json` instead) → `managed_sid_for_payload = None`;
- registers under the managed instance **name** (== alias), not the payload
  **thread-id**.

So all identity-resolution steps missed and the hook auto-registered a fresh
per-thread (vanilla) identity — the dual-identity.

## Fix

- **Launcher** exports an inherited marker `C2C_CODEX_APPSERVER_SESSION=<name>`
  (the broker session id it registers under) **before**
  `C2c_codex_app_server.start` spawns the frontend (`build_frontend_env`
  snapshots `Unix.environment ()`, so the frontend + its hooks inherit it).
  Reset to `""` on the app-server→hook-fallback path.
- **Hook** adopts that marker as its identity, first + unconditionally
  (race-free), so it never self-registers a second alias. For an
  app-server (ingress-owned) session the hook is **identity-only**: it drains
  nothing and does not refresh wake targets. The `C2c_codex_ingress` loop owns
  arrival-time repo delivery.

### Why the hook drains nothing (not "drain global too")

An intermediate version had the hook still drain the **global** (cross-repo)
inbox to close a gap. Codex review found that lets a **nested** codex which
inherited the marker steal the parent identity's cross-repo mail (env vars
propagate to all descendants — same leak as `C2C_CODEX_MANAGED`, but here it
selects identity + delivery, not just the nudge). Draining nothing removes that
misrouting vector and is **not** a regression: pre-B137 the hook never delivered
the app-server session's global inbox either (it ran under the wrong thread-id).

## Follow-up (not in B137)

Cross-repo (global sessions-broker) mail addressed to a managed **app-server**
session is not auto-injected today. It sits durably queued. The right home for
that delivery is the `C2c_codex_ingress` loop (extend it to also drain the
global inbox for its session id), NOT the frontend hook — the hook cannot
distinguish the attached frontend from a nested codex by env alone. Track as a
separate slice.

**RESOLVED by B141 (2026-07-12):** `C2c_codex_deliver_loop` now runs a plain
inject-only ingress pass against the sessions-broker inbox (same session key,
same discovered thread) each running poll, gated on inbox-file existence +
session-active + DND. Cross-repo mail becomes model-visible at arrival but can
never start a turn (T007 auto-turn stays repo-local-only), and the pass runs in
the launcher's supervision process, so the nested-codex env-marker theft vector
stays closed. Tests: `test_c2c_codex_deliver_loop.ml` "global-inbox (B141)".
