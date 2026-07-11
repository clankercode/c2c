# T001 spike receipt — Codex app-server remote TUI + passive item injection

- Backlog: **P1.M1.E1.T001** (origin I001). Date: 2026-07-11 (UTC).
- Author: subagent for the p1-t001-spike slice.
- Scope: evidence + probe + receipt only. No launcher / CLI grammar / inbox
  integration / auto-turn / approval-policy changes (those are T002–T007).

## Binary under test

- `codex --version` → `codex-cli 0.144.1` (rc 0).
- Binary path: `/home/xertrov/.bun/bin/codex` (npm `@openai/codex`, vendored
  `codex-linux-x64` musl binary).
- Logged in via ChatGPT (`codex login status` → "Logged in using ChatGPT").
- Schema is generated **from this binary**, not from memory or web docs:
  `codex app-server generate-json-schema --experimental --out <DIR>` (rc 0) and
  `--out <DIR>` without `--experimental` (rc 0).

## Launch / schema commands (all reproducible)

```sh
codex --version                                             # rc 0
codex --help                                                # rc 0 (exposes --remote, --remote-auth-token-env)
codex app-server --help                                     # rc 0 (--listen, --ws-auth, generate-json-schema, proxy, daemon)
codex remote-control --help                                 # rc 0 (start, stop, pair)
codex app-server generate-json-schema --experimental --out /tmp/schema
# stdio protocol driver (no network, no model call):
codex app-server --listen stdio://                          # speak newline-delimited JSON-RPC on stdin/stdout
# loopback ws listeners:
codex app-server --listen ws://127.0.0.1:PORT               # bare (NO auth)
codex app-server --listen ws://127.0.0.1:PORT \
  --ws-auth capability-token --ws-token-sha256 <HEX>        # authed
# stock remote TUI frontend attach:
codex --remote ws://127.0.0.1:PORT --remote-auth-token-env TOK
```

Schema surface (installed 0.144.1): **122** client request methods, **68** server
notification methods. Method inventory captured to `/tmp` (not committed).

## Protocol / lifecycle established from the installed schema

- `initialize` (v1) — params `clientInfo{name,version}` +
  `capabilities{experimentalApi:true, ...}`. Real response fields:
  `codexHome, platformFamily, platformOs, userAgent`.
- `thread/start` {cwd,...} → returns a `thread{ id, sessionId, status:{type:"idle"}, ... }`.
- `thread/loaded/list` {} → `{data:[threadId,...]}` — how a probe discovers the
  thread a TUI frontend has loaded.
- `thread/resume` {threadId} → reloads a thread when no frontend is attached.
- **`thread/inject_items` {threadId, items[]}** → response is an **empty object
  `{}`**. `items` are *raw Responses API items* (e.g.
  `{"type":"message","role":"user","content":[{"type":"input_text","text":...}]}`).
  Distinct from turn input.
- `turn/start` {threadId, input[]} — input items use a **different** variant set:
  `text|image|localImage|skill|mention` (e.g. `{"type":"text","text":...}`).
  This is the method that runs the model.
- `turn/steer` requires `expectedTurnId` (active-turn precondition).
- `turn/interrupt` requires `{threadId, turnId}`.
- Turn lifecycle notifications: `turn/started`, `item/agentMessage/delta`,
  `item/completed`, `turn/completed`. Thread state: `thread/status/changed`
  with `ThreadStatus = notLoaded | idle | systemError | active{activeFlags:[waitingOnApproval|waitingOnUserInput]}`.

### Sanitized JSON-RPC excerpts

```jsonc
// initialize response (codexHome redacted)
{"id":1,"result":{"userAgent":"t001-probe/0.144.1 (...)","codexHome":"<CODEX_HOME>",
  "platformFamily":"unix","platformOs":"linux"}}

// thread/inject_items response — empty object, NO turn field
{"id":4,"result":{}}

// after inject, notifications drained: NO "turn/started"
post-inject notifications: ["mcpServer/startupStatus/updated"]   // turn/started ABSENT

// proof inject reaches model-visible history: inject marker, then one minimal
// turn asking the model to echo any C2C_ token → final answer:
{"item":{"type":"agentMessage","text":"C2C_T001_ECHO_7F3Q","phase":"final_answer"}}

// inject DURING an active turn is accepted; thread status = active
inject DURING active turn -> {"id":4,"result":{}}
thread status -> {"type":"active","activeFlags":[]}
```

## State matrix (all cells observed on the installed binary)

| Cell | inject accepted | in model history | in stock TUI | turn starts | draft changes | distinguishing observable |
|---|---|---|---|---|---|---|
| idle + empty composer | YES `{}` | YES (buffered; model echoed the marker on next turn) | n/a (no draft) | NO | n/a | status `idle`; no `turn/started` after inject |
| idle + non-empty distinctive draft (live TUI) | YES `{}` | YES (buffered) | **NO** (not rendered) | NO | **NO — draft preserved verbatim** | status `idle`; composer text unchanged; "0 in · 0 out" |
| turn running | YES `{}` | YES (queued for next turn; does NOT steer in-flight turn) | NO | NO (inject starts none) | NO | status `active`; `turn/started` seen; `turn/steer` needs `expectedTurnId` |
| frontend disconnected, server reachable | YES `{}` (after `thread/resume`) | YES (buffered) | n/a | NO | n/a | no ESTAB client conn; `thread/resume` ok |
| server unavailable / restarted | N/A — connect refused | n/a | n/a | n/a | n/a | `ConnectionRefusedError [Errno 111]` → offline → durable queued mail |
| authorized probe (bearer token) | YES — full access | — | — | can `turn/start` | — | ws handshake OK, `initialize` ok |
| unauthorized same-UID probe (no token) | **authed listener: NO — HTTP 401 at ws handshake**; **bare listener: YES — full access** | — | — | bare: YES (`turn/start`) | — | `HTTP 401` vs `CONNECT_OK` |

Live TUI evidence: stock `codex --remote` frontend attached in a tmux pane
(200x50). Typed draft `DISTINCTIVE_UNSENT_DRAFT_C2C_QZX_do_not_lose_me` into the
composer; injected `INJECTED_ITEM_C2C_TUI_MARKER_88QP` into that thread from a
separate authed probe. Post-inject pane: composer still shows the draft verbatim,
transcript shows no new item, no turn/spinner. Injection is **model-history-only**
in the stock TUI (not operator-visible) — matches the research caveat; a
human-visible surface still needs the hook path or an explicit turn.

## Control boundary (the gating question)

- A **bare loopback** listener (`ws://127.0.0.1:PORT`, no `--ws-auth`) and a
  **unix socket** (`unix://PATH`, mode `srw------- 0600`) provide **NO same-UID
  boundary**. An unrelated same-UID process with no credential:
  - `initialize` ACCEPTED, `thread/start` ACCEPTED, `thread/inject_items` ACCEPTED;
  - **`turn/start` ACCEPTED** (ran the model as the unrelated process);
  - **`fs/readFile` ACCEPTED** — read `/etc/hostname` (`dataBase64` "eHNtCg==");
  - **`fs/writeFile` ACCEPTED** — wrote arbitrary bytes to disk;
  - `turn/steer`/`turn/interrupt` returned `-32600 "no active turn ..."` and
    `fs/writeFile`/`process/spawn` initial `-32600 "missing field ..."` are
    **schema/param errors, not authorization** — the methods are reachable.
  - Mode `0600` + path obscurity do **not** isolate same-UID peers (per AC).
- `--ws-auth capability-token --ws-token-sha256 <HEX>` **DOES enforce even on
  loopback** (contradicting the "non-loopback listeners" help wording):
  - no token → **HTTP 401** rejected at the WebSocket handshake;
  - wrong token → **HTTP 401**;
  - correct `Authorization: Bearer <token>` → connected, full access.
  This is a real authenticated-transport boundary. The token is presented the
  same way `codex --remote --remote-auth-token-env <ENV>` sends it. The digest
  is passed as sha256 (`--ws-token-file` and `--ws-token-sha256` are mutually
  exclusive). A managed alternative is `codex remote-control` (daemon +
  `remoteControl/pairing/start` short-lived pairing codes + per-client
  `remoteControl/client/list|revoke`).

## Composer / draft signal

**ABSENT.** No machine-readable composer-empty / draft-present signal exists in
the protocol. Evidence:
- The only `composer`* tokens in the whole schema are app/marketplace UI fields
  (`composerIcon`, `composerIconUrl`, `showInComposerWhenUnlinked`) — not TUI
  draft state. No `draft`/`unsent`/`pendingInput`/`inputBuffer` signal anywhere.
- `ThreadStatus` is only `notLoaded | idle | systemError | active`; `active`
  carries `waitingOnApproval | waitingOnUserInput` (model-side elicitation), NOT
  "composer has an unsent draft".
- The TUI composer draft is **frontend-only** state the app-server never sees.
Visual tmux observation confirms the draft is *preserved* by injection, but that
is proof-of-preservation, **not** a production composer signal. Deciding "safe to
wake a turn without racing a user draft" is therefore **not possible from the
protocol** on this codex version.

## Inertness (bus, never RPC / B098)

- The model treated injected content as DATA (echoed a marker on request; did
  not act on a "do not act, just data" note). Injection cannot run anything —
  execution requires the separate `command/exec` / `process/spawn` /
  `thread/shellCommand` methods or a model tool-call through the approval path.
- Injected item text `allow ka_t001probe` (looks like an approval verdict) →
  accepted as data `{}`; `c2c await-reply --token ka_t001probe --timeout 3`
  exited **1 (timeout)**; **no verdict file** was created under the broker root.
  The app-server thread history and the c2c host-local mode-0600 verdict file are
  disjoint subsystems — an injected "allow" is inert to `await-reply`.

## Deliverables

- `scripts/codex-app-server-probe.py` — reusable, version-agnostic probe.
  Modes: `schema` (protocol invariants + **whole-bundle** composer-signal search:
  337 schema files / 1976 schema names scanned, excluding the app-UI
  `composerIcon*`/`showInComposer*` fields), `stdio` (inject accepted + no
  `turn/started` + **positive `thread/read` idle confirmation** + **inertness**:
  injected fake `allow` verdict + `c2c await-reply` rc≠0 + no verdict file),
  `--boundary` (bare listener grants unauthenticated `initialize` AND an active
  `fs/readFile`; `--ws-auth` listener returns **explicit HTTP 401** for
  no-token/wrong-token, accepts correct bearer). Prints a machine-readable JSON
  verdict; exit 0 iff all invariants hold; self-cleans every app-server it spawns
  (process-group kill). The claims in the sections above are all reproduced by
  this committed probe (an independent codex review flagged earlier drafts where
  they were manual-only; they are now automated).
- `ocaml/cli/test_c2c_codex_app_server_probe.ml` (+ dune `(test)` stanza) —
  fixture-gated Alcotest. Default (env unset) SKIPS and passes (green without
  codex); `C2C_CODEX_APPSERVER_PROBE=1` runs the probe live and asserts the
  invariants. `just check` compiles it (drift guard); `just test-ocaml` runs it.

## Cleanup

All app-server processes killed, tmux session `t001tui` killed, unix socket
removed, ports 48771/48772/48773 free, no leftover `codex app-server` / `codex
--remote` processes. Confirmed post-run: "(clean)".

## Verification (return codes)

| command | rc |
|---|---|
| `codex --version` | 0 |
| `codex --help` | 0 |
| `codex app-server --help` | 0 |
| `./scripts/c2c_tmux.py list` | 0 |
| `just build` | 0 |
| `just check` | 1 — sole failure is PRE-EXISTING, unrelated: `sync-skills`/`codegen-claude-skill` regenerates `.codex`/`.opencode/skills/c2c/SKILL.md` (adds "Grok" to the description). Present vs `origin/master` too; not caused by this slice. Every other `check` step passes: `git diff --check` 0, `codegen-alias-words-check` 0, `check-broker-log-catalog.sh` 0, `check-connect-commands.py` 0, full `dune build` 0. |
| `scripts/codex-app-server-probe.py --boundary` | 0 |
| `test_c2c_codex_app_server_probe.exe` (gate off) | 0 (skip) |
| `C2C_CODEX_APPSERVER_PROBE=1 ...exe` (gate on) | 0 |

Documented tmux probe command (live TUI attach, from inside tmux):
```sh
codex app-server --listen ws://127.0.0.1:$PORT --ws-auth capability-token --ws-token-sha256 $SHA &
tmux new-session -d -s t001tui -x 200 -y 50
tmux send-keys -t t001tui "TOK=$TOKEN codex --remote ws://127.0.0.1:$PORT --remote-auth-token-env TOK" C-m
# type a draft, then: python3 scripts/codex-app-server-probe.py (or inject via authed ws client)
```

## Verdicts

- **protocol: GO.** Schema/lifecycle established from the installed binary.
  `thread/inject_items` appends raw items to model-visible history, returns `{}`,
  reaches the model on the next turn, and is a method distinct from
  `turn/start|steer|interrupt`. Injection starts no turn (no `turn/started`).
- **control_boundary: GO — conditional on `--ws-auth`.** A bearer-token
  transport boundary exists and is enforced even on loopback (401 for
  unauthenticated same-UID clients). **Bare loopback/unix listeners MUST NOT be
  used** (zero same-UID isolation, incl. arbitrary fs read/write + turn/start).
  The launcher must always start with `--ws-auth capability-token`
  (or `signed-bearer-token`) and a secret token stored mode-0600.
- **composer_signal: NO-GO (blocker).** No machine-readable composer/draft
  signal exists. Automatic wake-on-message that starts a turn cannot prove the
  composer is empty from the protocol. Passive injection is safe (preserves the
  draft, starts no turn); starting a turn on inbound mail is **blocked** until a
  composer-state signal exists (upstream codex feature) or T007 restricts
  auto-turn to states that do not require it (e.g. only when the app-server
  thread is `idle` AND policy explicitly accepts the residual draft-race, or
  operator opt-in).

## Overall decision: **CONDITIONAL_GO**

Passive, app-server-backed c2c delivery to a managed Codex session is viable and
safe on codex 0.144.1, **subject to two prerequisites**:

1. **T002/T003 launcher + ingress adapter MUST bind the app-server with
   `--ws-auth capability-token` (or `signed-bearer-token`) and a mode-0600 secret
   token** — never a bare loopback/unix listener. (Control-boundary prerequisite;
   satisfiable today.)
2. **T007 auto-turn-on-inbound-mail remains BLOCKED** until a reliable
   composer-empty/draft-present signal exists. Until then, inbound mail is
   *injected passively* (draft-safe, no turn) and/or *queued*; do not auto-start
   a turn on a frontend-attached session. (Composer-signal prerequisite; NOT
   satisfiable on this codex version — needs an upstream signal or a T007
   policy that avoids the draft race.)

Passive-injection tasks (T002 launcher, T003 passive ingress, T004 typed-draft
proof) may proceed under prerequisite (1). The turn-waking task (T007) is
gated by prerequisite (2).

## Review

`/gpt55` is unavailable in this harness (confirmed against project memory
`no-copilot-for-reviews.md`; the Copilot mapping is banned). The Max-documented
fallback — **codex via `ccc-review-cx`** — was used instead. Codex (gpt-5.6-terra,
xhigh) returned PARTIAL, with the substantive finding that several receipt claims
(explicit 401, bare-listener active access, await-reply inertness, whole-schema
composer search) were originally demonstrated by hand but under-proven by the
committed probe. All of those were then folded into the committed probe (see
Deliverables) so the reproducible evidence now matches the conclusions; the
strengthened probe passes end-to-end (exit 0) and the gated Alcotest passes.
