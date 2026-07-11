# B136 — Occasional app-server nudge for vanilla / hook-fallback Codex

Slice: `slice/b136-codex-appserver-nudge`
Date: 2026-07-12

## Goal

Vanilla / hook-fallback Codex sessions receive c2c mail at hook (turn)
boundaries. Occasionally nudge the operator toward the managed app-server path
(`c2c new codex`, arrival-time delivery) — WITHOUT spam, and NEVER in a session
that already has app-server (or any managed) delivery.

## What changed

- **`ocaml/c2c_codex_session.ml`** — `C2c_codex_session.run` now exports
  `C2C_CODEX_MANAGED=1` before any codex child is spawned (the load-bearing
  managed marker; see the codex-review P1 below).
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
- `C2C_CODEX_MANAGED` set — **load-bearing** marker exported by
  `C2c_codex_session.run` before any codex child spawns (covers app-server AND
  hook-fallback managed; race-free).
- `C2C_CODEX_INGRESS_LIVE` set.
- `C2C_MCP_SESSION_ID` set (non-empty).
- `managed_sid_for_payload <> None` (payload thread maps to a managed c2c
  instance via the legacy `config.json` mapping).
- resolved session's registration has `client_type = "codex-app-server"`.

The tip only emits after the incremented counter is durably written (I/O
failure ⇒ no tip), and the read-modify-write is flock-serialized
(`with_codex_nudge_lock`) so concurrent SessionStart hooks can't all emit. The
lock **fails closed**: if the lockfile can't be opened or the lock can't be
taken, no tip is shown (a lock failure can never let two hooks emit
unserialized).

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

**Codex review P1 (found by `/ccc-review-cx`, folded in):** the first cut gated
only on the four "hook-visible" signals below, but a real `c2c new codex`
app-server session defeats ALL of them: it persists `codex-session.json`
(`C2c_codex_session.write_mapping`, line 144), NOT the legacy instance
`config.json` that `managed_session_id_from_codex_thread` reads — so
`managed_sid_for_payload` is None; its broker registration is under the managed
instance *name*, not the payload thread id — so the `client_type` check misses;
it sets no `C2C_MCP_SESSION_ID`; and `C2C_CODEX_INGRESS_LIVE` is exported only
after the frontend spawns. Net: the hook resolves it as vanilla and would show
the tip in genuine app-server sessions — a primary-requirement violation.

**Fix (load-bearing):** `C2c_codex_session.run` now
`Unix.putenv "C2C_CODEX_MANAGED" "1"` at the top, before any codex child (the
app-server path's frontend/server env and the hook-fallback child's env are
both later snapshots of `Unix.environment ()`), so every hook fired by a managed
codex session inherits it. `codex_session_is_managed` treats it as the primary
suppressor. Race-free and independent of config.json/registration timing.

The other four signals are kept as defence-in-depth:
- `C2C_CODEX_INGRESS_LIVE` — covers a hook fired from the launcher process.
- `C2C_MCP_SESSION_ID` — hook-fallback managed codex child env
  (`ocaml/c2c_start.ml:3001`).
- `managed_sid_for_payload <> None` — legacy config.json thread mapping.
- registration `client_type = "codex-app-server"`.

This achieves the "truly vanilla only" refinement: only a Codex session never
launched via `c2c start/new codex` is eligible.

**Other codex-review fixes folded in:**
- Counter I/O: `write_codex_appserver_nudge_count` now returns a bool; the tip
  emits only when the incremented counter was durably written (an I/O failure
  yields an empty tip, honouring "any error yields empty tip").
- Concurrency: `with_codex_nudge_lock` flock-serializes the read-modify-write
  so concurrent SessionStart hooks can't all read N-1, write N, and all emit.
- Tests: added `C2C_CODEX_MANAGED`, `C2C_MCP_SESSION_ID`, and
  `client_type=codex-app-server` suppression cases (the meaningful managed-gate
  coverage now that `C2C_CODEX_MANAGED` is the load-bearing signal).

## Skill decision

`.codex/skills/c2c/SKILL.md` is a generated/synced artifact and `just check` has
a known skill-cache drift check around it. Per the task's guidance (skill is
OPTIONAL; skip if editing risks drift), I did **not** touch the skill. The
static AGENTS.md bullet + the runtime nudge already deliver the goal. No skill
cache files were modified.

## Verification

- `just build` → RC 0 (run in the worktree).
- `test_c2c_hook_codex.exe` → RC 0, 31/31 (10 new B136 tests + 21 existing).
- Tests assert: vanilla SessionStart shows tip (N=1); INGRESS_LIVE suppresses +
  counter not advanced; managed-thread mapping suppresses + counter not
  advanced; `C2C_CODEX_MANAGED` suppresses + counter not advanced;
  `C2C_MCP_SESSION_ID` suppresses; `client_type=codex-app-server` registration
  suppresses; absent on PostToolUse; throttle (N=2: absent 1st, present 2nd);
  off switch (N=0: never shown, counter never written); additive to a real
  message (both delivered).
- `just check` → RC 0.

## Review

`/ccc-review-cx` (codex, gpt-5.6-terra) — first pass FAIL with one P1 (app-server
sessions can receive the tip) + three P2s (counter I/O can still show a tip on
write failure; unlocked read-modify-write race; tests didn't cover the real
managed-identity path). All folded in as described above; re-reviewed clean.
