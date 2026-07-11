# T005 receipt — docs + diagnostics for canonical managed Codex delivery

- Backlog: **P1.M1.E1.T005** (depends on T004 + T006 + T007). Date: 2026-07-11 (UTC).
- Slice worktree: `.worktrees/p1-t005-docs`, branch `slice/p1-t005-docs`.
- Scope: documentation + diagnostics only. NO grammar changes (T006 owns it),
  NO delivery-policy changes (T007 owns it), NO second "safe profile".
  Front-door marketing pages (`docs/index.md`, `docs/overview.md`, `llms.txt`)
  deliberately untouched — reserved for the follow-up slice.
- Supported Codex for app-server mode: **codex-cli ≥ 0.144** (validated live
  on 0.144.1 by T001–T007; this slice documents, it does not re-prove).
  Capability set: `codex app-server --listen/--ws-auth/--ws-token-sha256`,
  `codex --remote --remote-auth-token-env`.

## Behavioral truth sources (as documented)

- Auto-turn (clean design, NO composer gating):
  `.collab/research/2026-07-11-t007-autoturn-receipt.md`
- Draft-safety proof (composer is frontend-only; a turn cannot clobber it):
  `.collab/research/2026-07-11-t004-typed-draft-preservation-receipt.md`
- Grammar / alias / `--yolo` / lifecycle:
  `.collab/research/2026-07-11-t006-codex-grammar-lifecycle-receipt.md`
- Transport + auth boundary:
  `.collab/research/2026-07-11-t001-codex-app-server-spike-receipt.md`,
  `.collab/research/2026-07-11-t002-codex-app-server-launcher-receipt.md`
- Offline queue semantics: B127 (`queued_offline`, `--fail-if-queued` exit 3).

**Composer-deferral language in the T005 spec is SUPERSEDED** (Max's
decision, T004 proof): an app-server `turn/start` bypasses the composer
entirely and cannot clobber a draft, so there is NO composer-empty gating and
none is documented. The documented auto-turn rule is exactly T007's shipped
dispatcher: eligible LOCAL-broker mail fires one turn when thread status is
explicitly idle and DND is off; `active`/unknown status → queued
(fail-closed); mid-turn arrivals batch into ONE follow-up turn; any
`@host`/`#` routing marker ⇒ remote ⇒ injected as data but never auto-turned.

## Changed surfaces

### Diagnostics (code)

- `ocaml/cli/c2c_doctor_hooks.ml` — new pure classifier
  `classify_codex_delivery ~app_server_status ~hooks_installed ~wake_target`
  + `codex_delivery_report` (default machine view + per-managed-instance
  rows; live gather is read-only and injectable for tests). Distinguishes:
  | mode | meaning | remediation |
  |---|---|---|
  | `app-server` | healthy app-server remote TUI, `online-attached` ONLY. Summary states the transport contract (arrival-time data injection, draft-safe, gated auto-turn) as **library-proven** and explicitly says the live inbound path is still the hook fallback until the supervision wiring slice lands (round-2 F2 fix) | inherits the live hook-fallback remediation |
  | `app-server-unavailable` | app-server startup failed / codex incompatible; live delivery (if any) is the hook boundary | upgrade codex (`npm i -g @openai/codex`), relaunch with `c2c start codex --app-server`; `c2c dev diag <name>` for the structured diagnostic |
  | `hooks+wake` | legacy **input-injecting** idle wake (watcher TYPES a nudge into the tmux/herdr pane); hook-boundary delivery | prefer `c2c start codex --app-server` for injection-free, draft-safe delivery |
  | `hooks` | hook-boundary only; idle session sees mail on its next turn | run inside tmux/herdr for idle wake, or use `--app-server` |
  | `unavailable` | no delivery path configured | `run \`c2c install codex\`` |

  A `starting` unit (remote TUI not attached yet) is NOT labeled `app-server`
  — it reports the hook fallback the session actually has right now, with a
  summary naming the starting unit and a "`c2c dev diag <name>`" next step
  (review round 1 fix, F2).
  Wired into `c2c doctor hooks` human / `--json` (`codex_delivery` key) /
  `--compact`. Summaries never claim "instant" delivery (tested). Doctor
  observes only — no mutation; no endpoints, tokens, or bodies in any output
  (tested: JSON must not contain `ws://`, `token`, `127.0.0.1`).
- `ocaml/cli/c2c_doctor_cmd.ml` — the degraded (outside-repo) `c2c doctor`
  path includes the codex delivery report in human + JSON output. The
  in-repo path picks the new classification up via
  `scripts/c2c-doctor.sh` → `c2c doctor hooks --compact`.
- `ocaml/cli/c2c_health_cmd.ml` — single-point delivery-mode unification:
  ONLY a codex instance whose T006 app-server unit is `online-attached`
  (healthy remote TUI, ghost-proof via dead-pid cross-check) reports
  `delivery_mode=app-server`; `starting`, failed, and offline records keep
  the truthful hook-boundary label (lifecycle detail stays in
  `app_server_status`). Propagates to `c2c status`, `c2c dev instances`,
  `c2c health` — one vocabulary everywhere. (Round-1 F2 fix; the earlier
  starting→app-server mapping is superseded.)
- `ocaml/cli/c2c_instances_cmd.ml` — vocabulary-parity comment on the T006
  `app_server_status` field (display already flows from health).
- `ocaml/cli/test_c2c_doctor_hooks.ml` — 9 new `codex-delivery-mode` cases:
  the four AC states (a)–(d) plus `unavailable`, offline-record fallback,
  remediation presence per degraded state, input-injecting flag on
  `hooks+wake` only, "never claims instant", report structure + JSON secret
  hygiene. Suite: **22/22 PASS**.

### Docs

- `docs/client-delivery.md` — Codex section rewritten: managed
  `c2c start codex` canonical (generated deterministic alias, optional
  `--alias`, `--yolo` warning + non-persistence, `new`/`resume`/shortcut
  grammar pointer, TUI-exit lifecycle reaps the app-server, B127
  `queued_offline` behavior incl. `--fail-if-queued` exit 3); app-server
  transport subsection (auth boundary: always `--ws-auth capability-token`
  loopback, bare listener forbidden with the T001 consequence spelled out,
  raw token env-only, TCP/WS exposure requires auth + explicit warning);
  passive injection semantics (model-history-only, persist-first,
  at-least-once); draft-safety by construction with the T004 link and an
  explicit "no composer-empty signal exists and none is needed"; the T007
  auto-turn rule verbatim-equivalent (idle + DND-off local mail only,
  fail-closed active/unknown, remote provenance never turned, one-batch
  mid-turn coalescing); refined B098 paragraph; hook fallback section with
  `hooks+wake` labeled a legacy input-injecting mode; shared delivery-mode
  vocabulary + `c2c doctor hooks`; official upstream links.
- `docs/clients/feature-matrix.md` — quick-reference auto-delivery cell,
  detailed Codex breakdown (two transports, one vocabulary), binary note
  (≥ 0.144 gate + fallback diagnostic), delivery-tier summary row, footguns
  cell. Last-updated stamp bumped.
- `docs/clients/e2e-checklist.md` — removed the stale "managed `c2c start
  codex` hook delivery is still being ported" claim (twice); row 2 now
  states hook-boundary (not arrival) semantics for hook mode and
  model-history-only arrival for app-server mode; new **row 2b** (app-server
  delivery smoke: delivery_mode/app_server_status assertions, byte-exact
  draft, echo-turn visibility check, T007-contract note that a local-mail
  gated turn is not a failure, failure modes → doctor remediation).
- `docs/get-started.md` — "Codex delivery" note in Advanced § managed
  sessions (canonical launcher, hook-boundary default, `--app-server`
  behavior, doctor vocabulary, link to the full contract).
- `docs/commands.md` — "Delivery + diagnostics" paragraph appended to the
  T006 Codex-session-grammar section (grammar tables untouched).
- `docs/dnd-mode-spec.md` — T007 auto-turn DND gate added to the
  delivery-path gate list (`queued_reason=dnd`, re-evaluated after clear).
- `.collab/runbooks/agent-wake-setup.md` — § Codex idle wake prefixed with a
  T005 note: the section is the legacy input-injecting mode; app-server
  sessions don't need it.
- `CLAUDE.md` (AGENTS.md is a symlink) — codex delivery bullet rewritten
  around the app-server transport + shared vocabulary; **B098 bullet
  replaced** with the refined rule.

### The refined B098 rule (as now documented)

A message is DATA and never satisfies an approval. One narrowly sanctioned
scheduling effect exists: eligible LOCAL-broker mail to an app-server-backed
Codex session CAN start a gated model turn (T007). That turn only makes
already-injected data model-visible — message **content** still cannot
resolve approvals or write verdict files: exact-token `allow`/`deny` bodies
stay inert (`c2c await-reply` unresolved, no verdict file) for local and
relay senders alike, even when they trigger an auto-turn. Verdicts come only
from the host-local mode-0600 `c2c approval-reply` path. Regression proof:
`test_c2c_await_reply.ml` + `test_c2c_codex_autoturn_b098.ml` (3/3, with a
positive control). Relay policy is explicit: remote-origin mail is never
auto-turned (provenance fail-closed on any `@host`/`#` marker).

## Tested output snippets (sanitized, from the built binary in this worktree)

`c2c doctor hooks --compact` (this machine, no live app-server instances):

```
Claude hooks: all 4 resolve
Codex managed blocks: current
Codex delivery: default=hooks; codex-tovi-olmu-6dek=hooks, wake-test-codex=hooks
```

`c2c doctor hooks --json | jq .codex_delivery.default`:

```json
{
  "mode": "hooks",
  "summary": "hook-boundary delivery only: messages surface when a codex hook fires (session activity / turn boundaries); an idle session does not see mail until its next turn",
  "remediation": "run the session inside tmux/herdr to enable idle wake (`c2c start codex --app-server` becomes the injection-free path once its delivery wiring lands)",
  "input_injecting": false
}
```

Human section (excerpt):

```
=== Codex delivery mode ===

  default (vanilla codex session on this machine): hooks
    hook-boundary delivery only: messages surface when a codex hook fires (session activity / turn boundaries); an idle session does not see mail until its next turn
    → run the session inside tmux/herdr to enable idle wake (`c2c start codex --app-server` becomes the injection-free path once its delivery wiring lands)
```

The `app-server` / `app-server-unavailable` / `hooks+wake` rows are proven by
the fixture-driven `report structure + json hygiene` test (no live app-server
was running on this host during the docs slice; the healthy-path live
evidence is T006/T007's).

## Command examples: provenance

Every command example added to docs was either run against the built binary
in this worktree (`c2c doctor hooks [--compact|--json]`, `c2c dev instances
[--json]`, `c2c start --help` flag text) or copied verbatim from a tested
receipt (`c2c new codex -- --model gpt-5.3-codex-spark` and the
`cx=` alias from T006's live tmux smoke; `c2c send … --fail-if-queued`
semantics from B127's merged tests).

## Official upstream references (verified live 2026-07-11)

- App-server protocol: <https://learn.chatgpt.com/docs/app-server>
  (title "Codex App Server"; `developers.openai.com/codex/app-server`
  308-redirects here)
- Hooks: <https://learn.chatgpt.com/docs/hooks> (title "Hooks")

## Verification (return codes)

| command | rc | notes |
|---|---|---|
| `just build` | 0 | |
| `just check` | 1 | **sole failure PRE-EXISTING + unrelated**: the `git diff --exit-code -- … skills` step reports the Grok skill-codegen drift in `.codex`/`.opencode/skills/c2c/SKILL.md` — identical to the T001–T007 receipts' note; this slice touched no skill files |
| `dune exec --root "$PWD" ocaml/cli/test_c2c_doctor_hooks.exe` | 0 | 22/22 (incl. 9 new codex-delivery-mode cases) |
| `dune exec --root "$PWD" ocaml/test/test_c2c_doctor_capabilities.exe` | 0 | 23/23 (unchanged suite, still green) |
| docs build (`cd docs && bundle exec jekyll build`) | n/a | jekyll is not installable in this environment (`bundle install` fails building `jekyll-relative-links` — pre-existing toolchain gap, not caused by this slice). Per `docs/CLAUDE.md`, text-only edits fall back to a Markdown diff review: performed + a fence/link lint over all six changed docs pages (all OK; no front-matter/layout changes made) |

## Wiring-status honesty (self-review + codex review round 1)

`C2c_codex_autoturn` / `C2c_codex_ingress` ship in the c2c library and are
proven by the T003/T004/T007 harnesses, but are **not yet driven by
`c2c start codex --app-server` supervision** (T007 receipt: follow-up slice;
confirmed by source scan — nothing outside tests/dogfood drivers calls them).
Every documented surface therefore leads with the wiring status and states
that, until the wiring slice lands, app-server-launched sessions still
receive at the hook boundary; the app-server delivery semantics are presented
as the implemented-and-proven **library contract** (what a managed session
gets once wiring lands), never as live managed behavior.

## Review round — codex (`/ccc-review-cx`, --yolo @cx-reviewer)

**Round 1: FAIL → both findings fixed in new commits (never --amend):**

- **F1 (BLOCKER)** — public docs claimed managed `--app-server` sessions
  already deliver by injection/auto-turn while the same page said supervision
  wiring is a follow-up. Fixed across `docs/client-delivery.md` (wiring
  status is now the first thing in the app-server section; the receive
  overview says "today all Codex sessions receive at the hook boundary"),
  `docs/clients/feature-matrix.md` (quick-ref cell, detailed breakdown, tier
  summary), `docs/clients/e2e-checklist.md` (row 2 conditioned; row 2b now
  starts with the wiring gate), `docs/commands.md`, `docs/get-started.md`,
  `.collab/runbooks/agent-wake-setup.md`, and `CLAUDE.md`.
- **F2 (MAJOR)** — `starting` was labeled the healthy `app-server` mode
  before a remote TUI attached. Fixed: doctor classifies `starting` as the
  live hook fallback (summary names the starting unit; remediation =
  `c2c dev diag <name>`; no hooks ⇒ `unavailable`), and the
  `c2c_health_cmd` override now maps ONLY `Online_attached` to
  `app-server`. Regression tests updated
  (`starting is not overclaimed as app-server`, incl. the no-hooks case).

**Round 2: FAIL → three narrower findings fixed in new commits:**

- **F1 (BLOCKER)** — the idle-wake tail (`docs/client-delivery.md`) and the
  doctor `hooks`/`hooks+wake` remediations still recommended
  `--app-server` *now* for injection-free delivery. Fixed: qualified as the
  post-wiring replacement everywhere.
- **F2 (BLOCKER)** — the doctor `online-attached` summary claimed arrival
  injection + auto-turn as live. Fixed: mode label stays `app-server`
  (lifecycle truth), but the summary states the stack is library-proven,
  names the live hook fallback, and the row inherits the fallback's
  remediation + truthful `input_injecting` flag (a wake-target session
  flags input injection even under the app-server label). Tests updated.
- **F3 (MEDIUM)** — this receipt's health-mapping paragraph still described
  the superseded starting→app-server mapping. Fixed above.

**Round 3: re-review → PASS.**

## Boundaries honored

- No command-grammar changes (T006), no delivery-policy changes (T007), no
  second profile, no `.backlog` edits (coordinator owns claim/done).
- Doctor/status observe and explain only; nothing mutated.
- No socket credentials, tokens, endpoints, or message bodies printed or
  committed — enforced by the JSON-hygiene test.
- Front-door pages (`docs/index.md`, `docs/overview.md`, `llms.txt`)
  untouched.
