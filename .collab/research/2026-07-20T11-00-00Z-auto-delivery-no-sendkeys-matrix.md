# Auto-delivery matrix: no primary reliance on tmux/herdr send-keys

**Date:** 2026-07-20T11:00:00Z (audited on tree at master, 2026-07-20)
**Scope:** NON-MONITOR automatic delivery for claude, codex (hooks + app-server),
kimi, opencode, agy. Monitor is treated only as fallback / agent-armed path.
**North star:** automatic delivery must work via **monitor OR wrapper OR plugin**,
with **no reliance on tmux/herdr send-keys as the primary automatic delivery path**.

Canonical product guarantees live in `docs/wake-contract.md` and
`docs/clients/feature-matrix.md`. This note is an audit of **code reality**
against that north star: which clients still use send-keys/herdr for auto wake,
what E2E covers, and the smallest fix if primary still depends on keystroke
injection.

## Definitions used here

| Term | Meaning |
|---|---|
| **Primary auto-delivery** | The path `c2c start <client>` / install intends to use for inbound mail without the model calling `poll_inbox` |
| **Wake** | External push into an *idle* agent with no model decision (`docs/wake-contract.md`) |
| **send-keys/herdr auto wake** | Typing a nudge (or message body) into a live TUI pane via `tmux send-keys` or `herdr pane run` so the client fires a hook / accepts input |
| **Not counted as primary** | E2E harness drivers that use tmux to *control* a test pane; opt-in legacy flags; one-shot install consent helpers |

---

## Matrix

| Client | Primary auto-delivery mechanism | Uses send-keys/herdr for auto wake? | E2E coverage today | Gap |
|---|---|---|---|---|
| **Claude Code** | PostToolUse + Stop hooks drain broker → `hookSpecificOutput.additionalContext` (`c2c-inbox-check.sh` / `c2c hook post-tool` / `c2c-inbox-hook-ocaml`). Managed start forces `claude_channel` capability + `--dangerously-load-development-channels server:c2c`, but channel is experimental and not a production guarantee. `needs_deliver=false` — no deliver-inbox sidecar. | **No** for auto delivery. `tmux send-keys` is used only for one-shot **dev-channel consent** auto-answer at managed launch (`auto_answer_dev_channel_prompt`), not for message wake. | Unit: `ocaml/cli/test_c2c_hook_claude.ml`, `test_c2c_setup_claude.ml`. Docker install/start smoke: `docker-tests/test_claude_first_class_peer.py` (no idle-wake proof). Live idle wake: **none** (by design — NONE tier). | **Idle auto-wake impossible without agent-armed Monitor or upstream inject API.** Activity-only hooks are not a wake. Prefer product honesty + Monitor recipe over any send-keys "fix". Tracked: #37 / wake-contract. |
| **Codex (managed app-server)** | Default managed path on codex ≥ 0.144: `C2c_codex_app_server` + `C2c_codex_ingress` `thread/inject_items` on arrival + `C2c_codex_autoturn` gated auto-turn for eligible **local** mail (idle, DND off; remote/`@host`/`#` fail closed to inject-only). Escape: `C2C_CODEX_FORCE_HOOKS=1` forces hooks path. | **No.** Injection is WebSocket RPC, not pane typing. | Unit/B098: `ocaml/cli/test_c2c_codex_ingress_b098.ml`, `test_c2c_codex_autoturn_b098.ml`, `ocaml/test/test_c2c_codex_session.ml`. Seam drivers: `scripts/codex-ingress-dogfood.py`, `codex-autoturn-e2e.py`, `codex-draft-preservation-e2e.py`. **Live full-supervisor E2E (gated):** `scripts/codex-managed-appserver-live-e2e.py` (`C2C_CODEX_APPSERVER_LIVE=1`). Harness uses tmux only to host/observe the session — not as the delivery mechanism. | Prefer this path for all managed codex. Gaps are operational (codex < 0.144 → unavailable; degraded/no-thread) not send-keys. Keep live harness green. |
| **Codex (hooks / vanilla + hook-mode managed)** | `c2c install codex` → `~/.codex/config.toml` hooks → `c2c hook codex` on UserPromptSubmit / PostToolUse / SessionStart / SessionEnd; full bodies via `hookSpecificOutput.additionalContext`. Hook-boundary only (activity / injected turn). | **Yes for idle wake when `hooks+wake`.** `select_delivery_mode` routes `client="codex"` → `Mode_wake_inject` → `C2c_wake_inject.watch_loop`: peeks inbox (never drains), then **`tmux send-keys -l` + Enter** or **`herdr pane run`** with a one-line nudge so UserPromptSubmit fires and the hook drains. Without a registered tmux/herdr target → `hooks` only (no idle wake). Doctor labels this `hooks+wake` and marks `cd_input_injecting=true`. | Unit: `ocaml/test/test_c2c_wake_inject.ml` (fixture-gated, never hits a live pane), `ocaml/cli/test_c2c_hook_codex.ml`, doctor classifier tests. **Live hooks E2E (gated):** `scripts/codex-hooks-live-e2e.py` (`C2C_CODEX_HOOKS_LIVE=1`). Obsolete XML/tmux body path: `scripts/test-codex-delivery-tmux-e2e.sh` exits 2. | **Primary managed path should stay app-server.** hooks+wake is an intentional legacy mitigation, not the north-star primary. Minimal fix if app-server is unavailable: keep hooks for body delivery; do **not** invest further in send-keys — document CONDITIONAL + arm Monitor. Longer fix: machine-wide delivery service (#35) or upstream idle inject for vanilla codex. |
| **Kimi** | `C2c_kimi_notifier` daemon (managed `c2c start kimi` arms it; SessionStart best-effort for unmanaged B238): `run_once` → `C2c_kimi_deliver.deliver_message` **REST POST** `http://127.0.0.1:<port>/api/v1/sessions/{id}/prompts` with `<c2c event="message">` envelope. `needs_deliver=false` on client table (notifier is separate from deliver-inbox PTY). deliver-inbox `poll_once_kimi` also calls the same `run_once`. | **No as primary.** Legacy **opt-in** composer nudge: `C2C_KIMI_TMUX_COMPOSER_WAKE=1` → `tmux send-keys … '[c2c] check inbox' Enter` *after* REST success (default **off**; stacks unsubmitted text on modern kimi-code). | Unit: `ocaml/cli/test_c2c_hook_kimi.ml`, `test_c2c_setup_kimi.ml`, `test_c2c_kimi_hook.ml`, doctor DEAF detection. Docker: `docker-tests/test_kimi_first_class_peer.py` (install/start smoke). Live REST wake: dogfood / bake probes (`scripts/kimi-bake-probe.sh`); not a hermetic CI gate. | **CONDITIONAL** on notifier alive + local kimi server + resolvable session id (`session_index` lag #41, managed registration #40). Minimal fix already done for send-keys (REST primary, composer off). Remaining: `c2c doctor hooks --rearm` DEAF path; do not re-enable composer by default. |
| **OpenCode** | In-process TypeScript plugin `data/opencode-plugin/c2c.ts` (embedded in binary): spawns alias-scoped `c2c monitor` for inbox-write events + `session.idle` / safety-net poll → **`client.session.promptAsync`**. `needs_deliver=false` — deliver-inbox/PTY explicitly rejected as redundant. | **No.** | Unit/install: `ocaml/cli/test_c2c_opencode_plugin_embedded.ml`, `test_c2c_opencode_plugin_drift.ml`. No gated live multi-client openCode wake harness comparable to codex B144. Product contract marks **GUARANTEED**. | Keep install + drift doctor green. Gap is **E2E proof depth** (plugin unit/drift ≠ live promptAsync round-trip in CI). Optional: small live smoke under tmux like codex managed e2e. |
| **agy (Antigravity)** | Managed `c2c start agy`: `needs_deliver=true`, `select_delivery_mode` → `Mode_agy_inject` → `C2c_agy_deliver.deliver_loop`: drain only **after** successful **`agy agentapi send-message`** (persist-first). SessionStart hook writes `agy-env.json` (ls_address + conversation_id). Hooks alone do not wake idle TUI. | **No.** agentapi CLI/HTTP inject, not send-keys. | Unit: `ocaml/cli/test_c2c_agy_deliver.ml` (#66 timeout/drain), `test_c2c_hook_agy.ml`, `test_c2c_setup_agy.ml`. Live agentapi wake: fragile (needs live agy-env + logged-in Antigravity); not a solid CI gate. | **CONDITIONAL** on deliver-watch sidecar + resolvable `agy-env.json` + agentapi. Workspace/broker filing (#69) and hook parse (#65) already fixed. Gap: durable live E2E + env file lifetime (Stop teardown history #61). Minimal fix: ensure SessionStart always writes env before idle window; doctor should flag missing env + undelivered inbox. |

---

## Code pointers (claims above)

### Shared routing

| Claim | Location |
|---|---|
| Per-client `needs_deliver` / who gets a sidecar | `ocaml/c2c_start.ml` `clients` Hashtbl ~L1555–1615: claude/opencode/kimi `needs_deliver=false`; codex/agy `true` |
| deliver-inbox mode selection | `ocaml/c2c_pty_inject.ml` `select_delivery_mode` ~L84–107: `codex`→`Mode_wake_inject`, `agy`→`Mode_agy_inject`, else poll/inotify |
| Mode dispatch | `ocaml/cli/c2c_deliver_inbox.ml` ~L671–698 |
| Doctor codex modes incl. `hooks+wake` input-injecting | `ocaml/cli/c2c_doctor_hooks.ml` ~L150–340 (`Cd_hooks_wake`, `cd_input_injecting`) |
| Managed delivery_mode string (claude/opencode/kimi/codex) | `ocaml/c2c_start.ml` `delivery_mode` ~L4370–4425 (`hooks+wake` when wake target registered) |
| Product wake table | `docs/wake-contract.md`, `docs/clients/feature-matrix.md`, `docs/client-delivery.md` |

### Claude

| Claim | Location |
|---|---|
| PostToolUse script source of truth | `ocaml/cli/c2c_claude_hook_scripts.ml` (`claude_hook_script`, stop, session) |
| Hook CLI full-delivery drain | `ocaml/cli/c2c_hook_cmd.ml` post-tool / claude session hooks ~L60–110, ~L987+ |
| No deliver sidecar | `c2c_start.ml` clients entry comment ~L1556–1559 |
| Channel force env (managed) | `c2c_start.ml` ~L3477–3480 `C2C_MCP_FORCE_CAPABILITIES=claude_channel`; dev-channel flags ~L3995–4018 |
| Consent send-keys (launch only) | `c2c_start.ml` `auto_answer_dev_channel_prompt` ~L2576–2610 (`tmux send-keys` `"1"` + Enter) |
| Channel notification method | `ocaml/c2c_mcp_helpers_post_broker.ml` ~L376 `notifications/claude/channel` |

### Codex app-server

| Claim | Location |
|---|---|
| App-server launcher | `ocaml/c2c_codex_app_server.ml` |
| inject_items RPC | `ocaml/c2c_codex_ingress.ml` `real_inject_items` ~L731+ `thread/inject_items` |
| Gated auto-turn + B098 | `ocaml/c2c_codex_autoturn.ml`; tests `ocaml/cli/test_c2c_codex_autoturn_b098.ml` |
| Deliver loop supervision | `ocaml/c2c_codex_deliver_loop.ml`, wired from `ocaml/c2c_codex_session.ml` `run_delivery_loop` |
| Force hooks escape | `ocaml/c2c_codex_session.ml` ~L1733–1738 `C2C_CODEX_FORCE_HOOKS=1` |
| Live E2E harness | `scripts/codex-managed-appserver-live-e2e.py` |

### Codex hooks + wake_inject (send-keys path)

| Claim | Location |
|---|---|
| Module contract: tmux/herdr only idle wake; never drains | `ocaml/c2c_wake_inject.ml` header L1–39 |
| tmux: `send-keys -l` then delayed Enter | `ocaml/c2c_wake_inject.ml` ~L600–629 |
| herdr: `herdr pane run` | same file ~L600; header L17–21 |
| Mode_wake_inject only for interactive codex | `ocaml/c2c_pty_inject.ml` L95–102 |
| Unit tests (fixture, no live pane) | `ocaml/test/test_c2c_wake_inject.ml` |
| Live hooks E2E | `scripts/codex-hooks-live-e2e.py` |

### Kimi

| Claim | Location |
|---|---|
| REST deliver | `ocaml/c2c_kimi_deliver.ml` POST `…/prompts` ~L429 |
| Notifier `run_once` + optional composer | `ocaml/c2c_kimi_notifier.ml` L564–572 (default off), L660–663 `tmux send-keys`, L796–801 gate on `C2C_KIMI_TMUX_COMPOSER_WAKE=1` |
| Managed arm | `ocaml/c2c_start.ml` ~L5707–5788 `C2c_kimi_notifier.ensure_daemon` |
| clients table: notifier, no deliver | `c2c_start.ml` ~L1576–1581 |

### OpenCode

| Claim | Location |
|---|---|
| Plugin promptAsync + monitor spawn | `data/opencode-plugin/c2c.ts` (header L1–17; `spawnMonitor` ~L1606–1645; `promptAsync` ~L1426–1430; `session.idle` ~L1955+) |
| Embedded + drift | `ocaml/cli/c2c_opencode_plugin_embedded.ml`, `c2c_opencode_plugin_drift.ml` |
| needs_deliver false | `c2c_start.ml` ~L1568–1575 |

### agy

| Claim | Location |
|---|---|
| agentapi send-message | `ocaml/cli/c2c_agy_deliver.ml` `run_agentapi_send` ~L79–96; `deliver_loop` ~L149+ |
| Mode_agy_inject | `c2c_pty_inject.ml` L103; deliver_inbox ~L687–698 |
| agentapi_wake capability | `c2c_start.ml` ~L4208 |
| clients needs_deliver true | `c2c_start.ml` ~L1601–1605 |

---

## Who still uses send-keys/herdr for **automatic** wake?

| Path | Role today | Primary? | Action |
|---|---|---|---|
| `C2c_wake_inject` (codex hooks+wake) | Idle nudge so hooks can drain | **Yes on hooks-mode codex** | Prefer app-server for managed; treat hooks+wake as CONDITIONAL legacy; no further investment |
| `C2C_KIMI_TMUX_COMPOSER_WAKE` | Post-REST composer text | No (opt-in, default off) | Leave off |
| Claude dev-channel consent | Launch-time UI click | No (not mail wake) | OK as-is |
| E2E harnesses (`c2c_tmux.py`, live scripts) | Test control | No | Keep for dogfood; do not count as product delivery |
| Generic `client=tmux` / `delivery_mode=tmux_send_keys` | Explicit lifecycle-decoupled mode | Yes **if** someone starts `tmux` client deliberately | Out of non-monitor product matrix; not a first-class peer path |

**Verdict vs north star:** For first-class peers, **only codex hooks-mode idle wake still has send-keys/herdr as the automatic wake mechanism.** Every other client’s *primary* body path is hook/plugin/REST/agentapi/app-server. Claude still has **no** true idle auto-wake without Monitor.

---

## Minimal fixes (only where PRIMARY still depends on send-keys)

### Codex hooks+wake (the one real primary dependency)

1. **Operational (already the product default):** managed `c2c start/new codex` → app-server; do not start new work on expanding wake_inject.
2. **Doctor / messaging:** keep calling `hooks+wake` “legacy input-injecting” (`c2c_doctor_hooks.ml`) so agents do not treat it as GUARANTEED.
3. **If a small code change is desired later (not done in this research commit):** when app-server is online-attached, refuse to spawn Mode_wake_inject for that instance (avoid dual wake: inject_items + pane nudge). That is a safety/cleanup, not a new capability.
4. **Do not** replace Claude idle gap with send-keys — wake-contract explicitly rejects that as a guarantee foundation.

### Claude idle (not send-keys — product gap)

- No safe half-done code fix inside c2c. Document Monitor; upstream inject API (#37). Channel remains experimental.

### OpenCode E2E depth / agy env / kimi DEAF

- Not send-keys issues. Prefer hermetic suites + doctor rearm; optional live smokes.

---

## E2E consistency checklist

| Priority | Client path | What “good” looks like |
|---|---|---|
| P0 | Codex app-server | Gated live harness PASS; B098 unit green; doctor shows `app-server` not hooks+wake for managed healthy instances |
| P0 | Kimi REST | Notifier + deliver unit/doctor DEAF; live bake optional; composer env stays unset |
| P1 | OpenCode plugin | Drift/embed tests + install smoke; optional live promptAsync |
| P1 | agy agentapi | Unit #66; doctor missing-env; live only with real Antigravity login |
| P2 | Claude hooks | Hook unit + docker install; never claim idle auto-wake |
| P2 | Codex hooks+wake | Unit wake_inject only; live hooks e2e optional; obsolete xml tmux e2e stays dead |

---

## Implementation note (this commit)

Research-only. No code change: the only primary send-keys path (codex hooks+wake) is already demoted relative to app-server; kimi composer is already opt-in default-off; claude has no send-keys mail path. A half-done “docs only” rewrite of wake-contract was unnecessary — docs already match code on this axis.

---

## SUMMARY

- **Primary auto paths without send-keys:** OpenCode plugin `promptAsync`, Codex **app-server** inject+autoturn, Kimi REST `/prompts`, agy **agentapi**, Claude **hooks/channel** (activity only).
- **Primary auto path still on send-keys/herdr:** Codex **hooks+wake** only (`C2c_wake_inject` via `Mode_wake_inject`).
- **Opt-in / non-primary send-keys:** Kimi `C2C_KIMI_TMUX_COMPOSER_WAKE`, Claude dev-channel consent, test harnesses.
- **Claude:** no idle auto-wake without Monitor; do not “fix” with send-keys.
- **E2E strongest for codex app-server + hermetic B098; weakest for live OpenCode/agy wake proofs.**
- **No code fix shipped in this audit** — remaining send-keys primary is intentional legacy fallback under app-server.
