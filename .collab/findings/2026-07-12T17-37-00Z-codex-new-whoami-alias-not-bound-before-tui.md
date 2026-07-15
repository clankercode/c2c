# `c2c new codex` / `cx` — managed alias not bound for in-session `c2c whoami` at TUI attach

- **UTC:** 2026-07-12T17:37:00Z
- **Reporter:** operator (Max) via Grok session; live repro captured same turn
- **Severity:** medium-high (identity UX / first-turn friction — managed session looks
  ready in the banner but the agent cannot address itself or be found via the
  same alias until something else onboards)
- **Status:** OPEN
- **Area:** `c2c new codex` / app-server launcher
  (`ocaml/c2c_codex_session.ml`, `ocaml/c2c_codex_app_server.ml`),
  CLI identity (`c2c whoami` / `c2c init`, `ocaml/cli/c2c_whoami_cmd.ml`,
  `ocaml/cli/c2c_init_cmd.ml`, `session_id_from_env` /
  `default-session.json` fallback)
- **Related:** B137 dual-identity (hooks adopting launcher marker), B166
  frontend env `C2C_MCP_SESSION_ID`, B141 deliver-loop global inbox —
  those fixed *hook* dual-registration; this is the **CLI shell-tool
  whoami** path still diverging from the managed banner alias.

## Symptom

Operator starts a fresh managed Codex via fish alias:

```fish
# ~/.config/fish/conf.d/codex.fish
function cx --description "Codex with approvals and sandbox disabled"
    command c2c new codex -- --dangerously-bypass-approvals-and-sandbox $argv
end
```

Startup banner reports the managed alias immediately:

```text
c2c codex · ready · codex-stack-digit-ca73 · ws://127.0.0.1:42293
╭───────────────────────────────────────────────────╮
│ >_ OpenAI Codex (v0.144.1)                        │
… YOLO mode …
```

On the **first turn**, the agent runs `c2c whoami` and does **not** get
that alias:

```text
alias:     (not registered)
session_id: 019f5761-cd05-7df1-9011-16a7cbfacacb

Relay:
  alias:      (no current session alias)
  state:      configured_not_registered — no current session alias to register
  …
```

So:

| Surface | Identity seen |
|---------|----------------|
| Launcher banner / `c2c list` (managed registration) | `codex-stack-digit-ca73` |
| In-session CLI (`c2c whoami` via Codex tool/shell) | different `session_id` (Codex thread-shaped UUID), **not registered** |

Expected: the first in-session `c2c whoami` returns the **same** alias the
banner printed (`codex-stack-digit-ca73`), without the agent having to
guess, re-init, or wait for a later hook/onboarding path.

## Desired fix (operator request)

When `c2c new codex` (and the managed app-server path in general) generates
the session alias, run:

```bash
c2c init --alias <that-alias>
```

**before the remote TUI is attached**, so the generated identity is the one
CLI resolution (`whoami` / `send` / statefile fallback) will use as soon as
the session is interactive.

That matches the mental model of `cx` = “new codex peer already on the
bus under the alias I can see in the banner.”

## Discovery / repro

1. From repo root: `cx` (or `c2c new codex -- --dangerously-bypass-approvals-and-sandbox`).
2. Note the alias in the `c2c codex · ready · <alias> · ws://…` line.
3. Immediately, in the TUI, run `c2c whoami` (agent tool or `!c2c whoami`).
4. Observe: `(not registered)` + a session_id that is **not** the managed
   alias / not registered under the banner alias.

Reproduced 2026-07-12 with codex **v0.144.1**, banner alias
`codex-stack-digit-ca73`, whoami session_id
`019f5761-cd05-7df1-9011-16a7cbfacacb`.

## Likely root cause (hypothesis — confirm in fix slice)

Several layers stack:

1. **Launcher identity is env-scoped to the frontend process**, not
   necessarily to Codex **shell tool** children:
   - `app_server_frontend_env` sets `C2C_MCP_SESSION_ID`,
     `C2C_CODEX_APPSERVER_SESSION`, `C2C_CODEX_MANAGED=1` on the remote
     frontend only (`c2c_codex_session.ml`).
   - `session_id_from_env` prefers `C2C_MCP_SESSION_ID` when present
     (`c2c_mcp_helpers_post_broker.ml`).
   - Live whoami resolved a **Codex-thread-shaped** UUID and showed
     unregistered → shell/tool env almost certainly has **`CODEX_THREAD_ID`
     (or equivalent native key) and does *not* have `C2C_MCP_SESSION_ID`**.
     Under that resolution path, whoami looks up the **thread id** in the
     broker registry and finds no row (managed registration is under the
     launcher `session_id` / alias, not the thread id).

2. **`default-session.json` is last-resort and loses to native env keys.**
   Even if something wrote the managed identity to the init statefile,
   `env_session_id` only consults the statefile when
   `session_id_from_env ()` returns `None`. A present `CODEX_THREAD_ID`
   short-circuits the fallback — so “init once for the repo” does not
   bind whoami to the managed alias while Codex exports its thread id.

3. **Registration timing vs attach.**
   `register_managed_app_server_identity` runs after `C2c_codex_app_server.start`
   returns `Ok` (frontend already spawned as part of start). Comments claim
   “register before SessionStart,” but that is still *after* attach begins.
   Hooks were hardened (B137/B166) to adopt the launcher marker; the **CLI**
   path was not given an equivalent “you are already this alias” bind for
   tool-spawned shells.

4. **No pre-TUI `c2c init --alias <managed>` step** exists today on the
   `c2c new codex` path. Init is left to the agent/hooks/later turns, so
   first-turn whoami is wrong by default.

## Suggested fix directions

Prefer a small, dogfoodable contract: **banner alias ≡ whoami alias from
first interactive turn**.

1. **Operator-shaped fix (requested):** before attaching the remote TUI,
   after the managed alias (and launcher `session_id`) are chosen, run the
   equivalent of `c2c init --alias <alias>` (or shared init/register helper)
   so registration + any init side-effects (room join, statefile) use the
   **same** alias the banner will print.
2. **Make shell whoami resolve the managed identity even when Codex only
   exports `CODEX_THREAD_ID`:**
   - export `C2C_MCP_SESSION_ID` (and/or `C2C_MCP_AUTO_REGISTER_ALIAS`) into
     environments Codex tools inherit; **or**
   - register / map the live Codex thread id → managed alias once the thread
     is known (deliver-loop already discovers `thread_id`); **or**
   - teach `whoami` / CLI session resolution to resolve managed codex
     instances via thread→instance mapping (`codex-session.json` /
     instance config) when native thread id is present but unregistered.
3. **Do not rely on `default-session.json` alone** for multi-session
   machines: last-init-wins is documented and collides across concurrent
   peers. Prefer env inheritance or thread→managed mapping over a single
   per-repo statefile for this path.
4. **Acceptance (live):** `cx` → first-turn `c2c whoami` prints the banner
   alias; `c2c list` shows one identity for that peer; `c2c send` from that
   shell uses the same alias. Regression test preferred at the
   session/launcher seam (env + registry), plus a short tmux dogfood note.

## Non-goals / cautions

- Do not reintroduce B137 dual-identity (hook minting a second alias).
  Pre-TUI init must **reuse** the launcher session_id/alias, not invent a
  second registration.
- Nested codex children inheriting identity markers remain a theft risk
  (B137 / nested-codex env notes) — any broader env export should stay
  scoped the way frontend_env already is (child-scoped, not ambient
  launcher global), or use the thread-mapping approach instead of leaking
  identity to every descendant.
- `c2c init` full MCP/hooks install is optional here; identity bind may be
  `--no-setup` / register-only if that is enough for whoami/send.

## Fix status

- **OPEN** — logged from operator request + live `cx` repro.
- No code change in this finding.
