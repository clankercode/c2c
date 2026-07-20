# Auto-delivery matrix: no primary reliance on tmux/herdr send-keys

Date: 2026-07-20. Goal: automatic delivery possible via monitor, wrapper, or
plugin — **not** by typing into a TUI with `tmux send-keys` / `herdr pane run`
as the primary path.

## Per-client matrix (non-monitor clients)

| Client | Primary auto-delivery | Uses send-keys/herdr as PRIMARY auto wake? | E2E evidence | Gap |
|---|---|---|---|---|
| **OpenCode** | In-process plugin (`c2c.ts` + session.promptAsync); `needs_deliver=false` | **No** | Plugin path + product docs GUARANTEED | Keep plugin install green |
| **Codex managed app-server** | App-server inject + gated auto-turn (`C2c_codex_*`); B098 local-only | **No** | Live PASS `WOKE-ZQ7X4WAKE`; `test_c2c_codex_autoturn_b098.ml` | Prefer app-server over hooks for new sessions |
| **Codex managed hooks** | `c2c-deliver-inbox` Mode_wake_inject → **`C2c_wake_inject`** (tmux/herdr nudge) | **Yes (hooks path only)** | Unit tests for wake_inject; live e2e preferred app-server | Prefer app-server; hooks path is fallback CONDITIONAL |
| **Kimi managed** | `C2c_kimi_notifier` REST POST `/prompts` | **No** (tmux composer nudge opt-in only via `C2C_KIMI_TMUX_COMPOSER_WAKE`) | Live PASS wire `WOKE-KMWAKE7383` | CONDITIONAL on notifier alive + valid model alias |
| **agy managed** | `c2c-deliver-inbox` Mode_agy_inject → **agentapi** `send-message` | **No** (agentapi HTTP) | Register+argv PASS; wake BLOCKED (no agy-env / auth) | SessionStart→agy-env + Antigravity login |
| **Claude Code** | PostToolUse/Stop hooks + MCP channel; no deliver sidecar | **No** for auto push | Activity-triggered only (NONE without monitor) | Idle wake requires `c2c monitor` or upstream inject API |
| **Grok** | CLI + hooks; no guaranteed inject | **No** | NONE without monitor | Upstream #37 |

## Primary vs fallback (load-bearing rule)

- **Primary path** must be: plugin / app-server / REST / agentapi / MCP channel.
- **tmux/herdr send-keys** may exist only as:
  - e2e harness control, or
  - codex **hooks fallback** when app-server is unavailable, or
  - opt-in legacy (`C2C_KIMI_TMUX_COMPOSER_WAKE=1`).
- Never market send-keys as the wake guarantee for a client.

## Code pointers

- Clients table: `ocaml/c2c_start.ml` `clients` Hashtbl (~1555+)
- Codex wake_inject: `ocaml/c2c_wake_inject.ml`, Mode_wake_inject in `c2c_pty_inject.ml`
- Kimi REST: `ocaml/c2c_kimi_deliver.ml`, notifier `ocaml/c2c_kimi_notifier.ml`
- Agy agentapi: `ocaml/cli/c2c_agy_deliver.ml`
- Wake table: `CLAUDE.md` / AGENTS.md

## E2E consistency checklist

1. **codex app-server** — live PASS; keep hermetic B098 suite green.
2. **kimi** — live PASS wire; hermetic notifier/deliver suites; model alias full `kimi-code/…`.
3. **opencode** — plugin GUARANTEED; ensure e2e or install smoke asserts plugin file + env.
4. **agy** — block on agy-env; do not pass on deliver drain alone.
5. **claude / grok** — document monitor requirement; do not claim auto-wake without it.

## Residual open product issues (not send-keys)

- #35 machine-wide delivery service (north star)
- #37 Grok upstream wake
- #59 decay carve-out (deliberate)
- agy auth / SessionStart for agentapi


## Hermetic / automated test inventory (no tmux keys required)

| Suite | Client | What it proves |
|---|---|---|
| `ocaml/cli/test_c2c_codex_autoturn_b098.ml` / `ocaml/test/test_c2c_codex_autoturn.ml` | Codex app-server | Local auto-turn; remote/`@host`/`#` fail closed |
| `ocaml/test/test_c2c_kimi_notifier.ml` | Kimi | Notifier drain + REST path hermetic fixtures |
| `ocaml/test/test_c2c_kimi_deliver.ml` | Kimi | REST deliver_message |
| `ocaml/cli/test_c2c_agy_deliver.ml` | agy | agentapi deliver loop (bounded wait, env) |
| `ocaml/test/test_c2c_wake_inject.ml` | Codex hooks | wake_inject unit (tmux/herdr **fallback** path) |
| Live finding 2026-07-20 | Codex app-server, Kimi | Real WOKE-* without recipient keystroke |

### Policy for new e2e
- Prefer hermetic OCaml for B098 and REST/agentapi.
- Live e2e: observe via capture-pane / wire.jsonl / agentapi — **never** send-keys to recipient during wake window.
- Claude/Grok: assert monitor path or document NONE without monitor.

