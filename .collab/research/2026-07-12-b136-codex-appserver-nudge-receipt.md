# B136 — Occasional app-server nudge for vanilla / hook-fallback Codex

Slice: `slice/b136-codex-appserver-nudge`
Date: 2026-07-12

## Goal

Vanilla / hook-fallback Codex sessions receive c2c mail at hook (turn)
boundaries. Occasionally nudge the operator toward the managed app-server path
(`c2c new codex`, arrival-time delivery) — WITHOUT spam, and NEVER in a session
that already has app-server (or any managed) delivery.

## What changed

- **`ocaml/cli/c2c_hook_cmd.ml`** — runtime nudge in the `c2c hook codex`
  SessionStart path. New helpers: `codex_appserver_nudge_every`,
  `codex_appserver_nudge_count_path`, `read/write_codex_appserver_nudge_count`,
  `codex_appserver_nudge_text`, `codex_session_is_managed`,
  `codex_appserver_nudge`. Integrated into the SessionStart additionalContext
  assembly (`appserver_nudge` added to the `context` list, additive — never
  replaces intro/changelog/messages).
- **`ocaml/cli/c2c_codex_hooks.ml`** — one static bullet added to
  `agents_md_body` (installed AGENTS.md block) pointing at `c2c new codex`
  (alias `cx='c2c new codex --'`) for arrival-time app-server delivery.
- **`ocaml/cli/test_c2c_hook_codex.ml`** — 7 new E2E tests.
- **`.collab/runbooks/c2c-env-vars.md`** — documented `C2C_CODEX_INGRESS_LIVE`
  and `C2C_CODEX_APPSERVER_NUDGE_EVERY`.
- Skill (`.codex/skills/c2c/SKILL.md`): **SKIPPED** (see below).

## The gate (exact)

Nudge shows iff ALL hold:
1. `event = "SessionStart"`.
2. `N > 0`, where `N = C2C_CODEX_APPSERVER_NUDGE_EVERY` (default 5; non-int → 5;
   `N <= 0` disables entirely — no read, no increment, no show).
3. NOT a managed/app-server session (`codex_session_is_managed` is false).
4. Post-increment counter `next mod N == 0` (counter advanced ONLY when 1–3
   hold, so managed/app-server sessions never move it).

`codex_session_is_managed` = OR of:
- `C2C_CODEX_INGRESS_LIVE` set.
- `C2C_MCP_SESSION_ID` set (non-empty).
- `managed_sid_for_payload <> None` (payload thread maps to a managed c2c
  instance — the hook already computes this for identity resolution).
- resolved session's registration has `client_type = "codex-app-server"`.

## Counter location

`<broker_root>/codex-appserver-nudge.count` — a single integer, written via
`C2c_io.write_file_atomic`. Missing/unreadable/parse-error → treated as 0. All
reads/writes are try-guarded; any failure yields an empty tip and NEVER raises
(honours the hook contract "errors exit 0 with empty output").

## Managed-marker investigation (the important finding)

The task spec proposed gating on `C2C_CODEX_INGRESS_LIVE = None` alone, on the
stated premise that this env is "inherited by the frontend+hooks", so set ==
app-server session.

**That premise is inaccurate for the current B131 code.** In
`ocaml/c2c_codex_session.ml`:
- `run_app_server` calls `C2c_codex_app_server.start cfg` (line ~456), which
  spawns the app-server (`build_server_env = Unix.environment ()`) and the
  frontend (`build_frontend_env = Unix.environment () + token`) children —
  BOTH snapshot the launcher env at spawn time.
- Only AFTER `start` returns does `run_delivery_loop` (line ~490) run, and its
  first act is `Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1"` (line 324). The code
  comment there is explicit: *"the frontend was already spawned with its env
  captured, so this does not leak into it."*

So the codex frontend / app-server — and any `c2c hook codex` process they fire
from the global `~/.codex/config.toml` hooks — do **not** see
`C2C_CODEX_INGRESS_LIVE`. Gating on it alone would therefore FAIL the primary
requirement (it would show the tip in app-server sessions).

**Reliable markers the hook process CAN see**, used OR'd:
- `managed_sid_for_payload` (thread→managed-instance mapping via
  `C2c_mcp_helpers_post_broker.managed_session_id_from_codex_thread`, matched on
  the instance `config.json` `codex_resume_target`/`resume_session_id`). This is
  the primary "this is a managed session" signal and covers both app-server and
  hook-fallback managed sessions. It is what the hook already uses for identity
  resolution, so whenever the hook treats the session as managed
  (`is_managed`), this is `Some`.
- `C2C_MCP_SESSION_ID` — set by `c2c start` into the codex child env
  (`ocaml/c2c_start.ml:3001`) and inherited by hook-fallback managed codex; the
  definitive catch for that path.
- registration `client_type = "codex-app-server"` — set by the app-server
  delivery loop's `register()`; a further belt-and-suspenders check once the
  registration lands.
- `C2C_CODEX_INGRESS_LIVE` — kept as a cheap extra signal (covers any future
  case where it does reach a hook, e.g. a hook fired from the launcher itself).

This achieves the "truly vanilla only" refinement the spec hoped for: only a
Codex session never launched via `c2c start/new codex` is eligible.

**Residual gap (documented, accepted):** a brand-new app-server thread in the
narrow startup window where (a) its instance `config.json` thread mapping is not
yet written AND (b) the delivery loop has not yet registered AND (c) no env
marker is present, could slip through and see the throttled tip. This is a small
race, the tip is throttled (default 1-in-5) and harmless (a correct suggestion,
just redundant), and in practice the identity-resolution `is_managed` path makes
`managed_sid_for_payload` `Some` in the common case. Not worth adding a
synchronous barrier for.

## Skill decision

`.codex/skills/c2c/SKILL.md` is a generated/synced artifact and `just check` has
a known skill-cache drift check around it. Per the task's guidance (skill is
OPTIONAL; skip if editing risks drift), I did **not** touch the skill. The
static AGENTS.md bullet + the runtime nudge already deliver the goal. No skill
cache files were modified.

## Verification

- `just build` → RC 0.
- `test_c2c_hook_codex.exe` → RC 0, 28/28 (7 new B136 tests + 21 existing).
- Tests assert: vanilla SessionStart shows tip (N=1); INGRESS_LIVE suppresses +
  counter not advanced; managed-thread mapping suppresses + counter not
  advanced; absent on PostToolUse; throttle (N=2: absent 1st, present 2nd); off
  switch (N=0: never shown, counter never written); additive to a real message
  (both delivered).
