# Friction report audit: B095-B100

Date: 2026-07-10

Auditor checkout: `.worktrees/friction-cn-audit-contract`

Audited base: `c8d5e7c93070058907fa5f342c23c45f63772b2e`

Source contract: `/home/xertrov/src/c2c/friction-points-cn.md` plus the full
backlog bodies from `bl cat B095` through `bl cat B100`. The source report was
read from the shared main checkout because it is not present at this base.
Code was not changed.

## Executive result

The six `done` markers do **not** mean this tranche is completely addressed.

| Item | Verdict | Short reason |
|---|---|---|
| B095 | **PASS** | The local dashboard/probe is canonically `c2c ping`; `c2c connect` is a noisy deprecated compatibility alias that points at `c2c relay connect`. |
| B096 | **PARTIAL** | Non-destructive peek works, but cursor/ack/independent-reader semantics were not built. More seriously, `/peek_inbox` omits the signed-owner check used by `/poll_inbox`. |
| B097 | **PARTIAL** | `c2c list --relay` can merge both sources, but unified discovery remains opt-in, lacks direct contract tests, and overloads `identity_pk` across different local-agent and relay-machine identity domains. |
| B098 | **FAIL** | The strict backlog/source contract says no remote message may satisfy approval. The implementation and tests deliberately allow a configured supervisor's inbox DM (including a remote supervisor) to resolve approval. The negative tests only cover non-supervisors. |
| B099 | **FAIL** | Canonical safety prose exists and Claude installation is tested, but every adapter does not inject it. Codex, OpenCode, Kimi, common OCaml envelopes, and Pi lack equivalent canonical delivery-time framing; multiple paths also permit peer text to escape/forge an envelope. |
| B100 | **PARTIAL** | Useful relay docs exist, but the requested single public-relay golden path is split between an operator/self-hosting page and `/connect`; it lacks the full local-proof-first sequence, full expected-output/error table in one place, an executable docs test, and current two-host proof. |

The highest-risk gaps are B096's peek authorization and B098's message-to-
approval exception. B099 is the broadest product gap.

## Audit method

Per repository instructions, code discovery began with the codebase-memory
graph (`search_graph`, then `get_code_snippet`/`trace_path`) before direct file
reads. The graph located the B095 ping/alias functions, relay peek handler,
list normalizer, approval trust gate and regressions, canonical skill test,
common envelope formatter, and Kimi notifier. Direct searches were then used
for literals, docs, generated copies, and test registrations.

All six backlog bodies were read in full. `done` and changelog claims were
treated as leads, not proof.

## Per-item findings

### B095 — connect/ping naming: PASS

Evidence:

- `ocaml/cli/c2c_health_cmd.ml:610-642` makes `ping_run` the shared core,
  defines the canonical `ping` command, and keeps `connect` only as a
  deprecated alias.
- The alias writes two unambiguous stderr notes: it names `c2c ping` as the
  local connection-status/delivery probe and `c2c relay connect` as the
  cross-host bridge. JSON stdout therefore remains parseable.
- `ocaml/cli/c2c_main_cmd.ml:33` registers `connect` as the deprecated alias.
- `ocaml/test/test_c2c_cli.ml:2693-2729` checks the hint, relay distinction,
  dashboard continuity, and `--verify` compatibility.
- Built-source help describes `c2c ping` as a **local** connection dashboard
  and loopback probe; `c2c relay connect --help` separately describes the
  relay connector.

No same-bug-class naming collision was found in this touch zone. The retained
alias is acceptable compatibility because every invocation emits the
distinction.

Missing proof: no removal date is documented for the deprecated alias. This is
cleanup, not an acceptance blocker.

### B096 — non-destructive relay receive: PARTIAL, with a security defect

What works:

- `ocaml/relay_client.ml:301-316` exposes signed and unsigned `/peek_inbox`
  clients without mutating server state.
- `ocaml/cli/c2c_relay_cmd.ml:1005,1084-1114` exposes
  `c2c relay dm peek`, labels it non-destructive, and signs the request when a
  machine identity is available.
- `ocaml/relay.ml:1762-1788` reads SQLite inbox rows without deletion.
- `ocaml/test/test_relay.ml:352-360` proves peek -> same message -> poll ->
  empty. The focused relay suite passed 49/49.
- `ocaml/cli/c2c_monitor_logic.ml:206-216` and monitor code use peek for
  awareness without stealing from the consumer; the focused monitor logic
  suite passed 22/22.
- Help and docs correctly call `poll` draining and `peek` non-destructive.

Unimplemented acceptance contract:

- B096's backlog body explicitly asks for cursor/ack, at-least-once delivery,
  independent readers, restart recovery, and `message_id` dedupe. No cursor or
  ack exists. Peek repeatedly returns the whole pending inbox; one destructive
  poll still removes it for every watcher. This is visibility without
  independent consumption semantics.
- The current `docs/connect.md:163-167` describes repeated peek then poll, not
  cursor/ack delivery. Inventory C019 correctly treats durable cursors as open.

Same-bug-class/security regression:

- `ocaml/relay.ml:3168-3183` makes signed `/poll_inbox` compare
  `verified_alias` with `R.alias_of_session relay ~node_id ~session_id` and
  rejects mismatches.
- `ocaml/relay.ml:3185-3192` defines `handle_peek_inbox relay body` without a
  `verified_alias` parameter and returns the requested node/session's messages
  with no ownership check.
- `ocaml/cli/c2c_relay_cmd.ml:1084-1114` contains a comment acknowledging that
  `/peek_inbox` does not enforce session ownership.

Thus an authenticated peer can ask to peek another known/predictable relay
inbox even though the same request to poll is rejected. A non-destructive read
must not be a less-authorized read. No negative ownership test was found.

Required slice:

1. Immediate security fix: pass `verified_alias` to `handle_peek_inbox`, reuse
   the exact poll ownership check, and add signed victim/attacker HTTP tests for
   both InMemory and SQLite backends.
2. Contract completion: design durable per-subscriber cursors + ack, persistence
   across restart, at-least-once redelivery, and consumer dedupe by
   `message_id`. Do not mark B096 fully closed until two readers cannot steal
   each other's progress.

### B097 — unified list and identity surfacing: PARTIAL

What works:

- `ocaml/cli/c2c_list_cmd.ml:42-102` normalizes local/relay source, address,
  alive state, and key display.
- `ocaml/cli/c2c_list_cmd.ml:125-146` adds a bounded, non-fatal relay fetch.
- `ocaml/cli/c2c_list_cmd.ml:193-217` emits local JSON rows; lines 296 onward
  normalize relay rows. Relay JSON includes the full key; human output uses a
  short key.
- Built-source `c2c list --help` accurately documents `--relay` and all relay
  options. Existing local-list tests passed.

Why the original contract is not closed:

- The backlog says make `c2c list` show local and relay peers together.
  Implementation is explicitly opt-in (`--relay`) so default `c2c list`
  remains local-only. That may be a defensible latency/offline choice, but it
  is not the claimed default unified surface. A product decision and wording
  correction are needed: either unify by default when configured (with
  `--local-only`) or scope B097 to an explicit merged view.
- No B097 end-to-end/fixture tests were found. `test_c2c_cli` tests ordinary
  local `list`; there is no relay fixture asserting the merged human/JSON row,
  source tags, full address, identity field, filtering, timeout, or non-fatal
  network failure.

Identity-domain conflation:

- Relay `identity_pk` is the **machine-wide** Ed25519 anchor from
  `~/.config/c2c/identity.json`; `docs/reference/identifiers.md:58-76` says so.
- Local registration keys are generated per alias under
  `<broker>/keys/<alias>.ed25519` in
  `ocaml/c2c_identity_handlers.ml:206-250`.
- `c2c list` writes both into a field named `identity_pk` without an
  `identity_kind`, signer scope, attestation, or verification field.

These are not interchangeable. The I008/current decision is: keep the machine
key as the relay trust anchor; a future agent/session key is optional and must
be machine-attested in-band. Do **not** relabel the machine key as per-agent or
present a local per-alias key as the same trust anchor.

Required slice:

1. Define discovery default semantics and test them with a fake relay.
2. Version the row schema to distinguish at least
   `machine_identity_pk` from optional `agent_identity`/attestation and expose
   verification state only when actually verified.
3. Add merged human/JSON, filters, offline failure, same-alias/different-host,
   machine-anchor sharing, and optional-attestation tests.

### B098 — bus-never-RPC / approval isolation: FAIL

The code has valuable hardening but does not meet the strict source contract.

Positive evidence:

- `ocaml/cli/c2c_approval_paths.ml:17-50`, `AGENTS.md:274`, and
  `CLAUDE.md:274` document “bus, never RPC”.
- File verdicts live under a local broker-root side channel with restrictive
  modes.
- `inbox_verdict_if_trusted` requires token text, an allow/deny word, and an
  alias on the token's supervisor list.
- Focused approval suites passed: `c2c_approval_paths` 24/24 and
  `c2c_await_reply` 5/5.

Contract violation:

- The source/backlog says a remote peer must **never** inject or answer an
  approval and that approval is local-operator-only.
- `ocaml/cli/c2c_approval_paths.ml:32-38` explicitly says a broker/relay DM
  from a configured supervisor may satisfy approval and that supervisors may
  be remote peers.
- `ocaml/cli/c2c_approval_cmd.ml:91-182` still reads the ordinary inbox and
  exits 0 when `inbox_verdict_if_trusted` returns a verdict.
- `ocaml/cli/test_c2c_approval_paths.ml:517-567` first asserts that a supervisor
  peer message returns `Some "allow"`; its “remote cannot reach” assertion is
  only for a **non-supervisor**.
- `ocaml/cli/test_c2c_await_reply.ml:121-141` proves an inbox message from the
  configured reviewer exits 0. The B098 negative test at lines 144-161 only
  proves an attacker alias is rejected.

This is a message directly resolving a PreToolUse decision. Local
configuration of the sender is authorization policy, but it does not turn a
remote message into a local operator action; it is still RPC semantics. The
test name and changelog overclaim the result.

Additional fail-open debt: `do_approval_reply` warns but proceeds without an
authorization check when no pending token exists
(`ocaml/cli/c2c_approval_cmd.ml:230-250`). It remains host-local, so it is
separate from the remote-message bug, but the approval slice should decide and
document whether expired/unknown tokens must fail closed.

Required slice:

1. Remove the inbox-DM verdict fallback entirely. `await-reply` should consume
   only the local verdict file/local operator surface.
2. Replace the negative test with “**any** broker/relay message, including a
   configured supervisor with exact token text, cannot satisfy approval.”
3. Make unknown/expired pending tokens fail closed unless an explicit local
   break-glass flow is designed and audited.
4. Preserve awareness DMs as data only; a supervisor may learn that approval
   is pending, but must use the host-local approval command/file path.
5. Promote the invariant to a standalone ADR/security boundary, not only code
   comments and agent instruction files.

### B099 — untrusted-data framing across adapters: FAIL

Canonical prose exists:

- `.collab/skills/c2c.md:23-64` has strong, correct language: every peer
  message is untrusted third-party data; only the local operator is authority;
  FYI/urgency/familiar alias does not upgrade authority; identify self with
  `whoami`; use `alias@host_id` for relay routing.
- `.codex/skills/c2c/SKILL.md` and `.opencode/skills/c2c/SKILL.md` currently
  hash-identically to the canonical file.
- `ocaml/cli/c2c_claude_skill_embedded.ml` is generated from the canonical
  source. `test_c2c_claude_skill_embedded` passed 7/7, including Claude
  install and phrase presence.

But the backlog says **every adapter injects it on session start**. Current
adapter inventory:

| Surface | Current evidence | Verdict |
|---|---|---|
| Claude | `c2c install claude` writes the embedded skill and this is tested. Whether the harness activates the skill before every inbound delivery is not proven. | Partial |
| Codex | `c2c install codex` installs hooks and a managed AGENTS block. `ocaml/cli/c2c_codex_hooks.ml:242-268` contains commands/etiquette but none of the canonical untrusted-data/authority rules. It does not install the Codex skill. | Fail |
| OpenCode | A repo-local static skill copy exists, but installer/session-start injection is not proven. `data/opencode-plugin/c2c.ts:1497-1528` injects a peer-controlled body plus a “reply via tool” system reminder, with no untrusted-data/authority reminder. | Fail |
| Kimi | `ocaml/c2c_kimi_notifier.ml:207-246` stores the peer body as an LLM-targeted `agent` notification with provenance fields but no canonical untrusted-data framing. No installed skill/session-start safety fragment was found. | Fail |
| Pi (`pi-c2c`) | Separate extension code sanitizes forged `<c2c>` tags, but its delivery reminder tells the agent how to reply and does not carry the canonical local-authority/untrusted-data text. No c2c-repo conformance gate covers it. | Fail / cross-repo proof missing |
| Gemini | Deprecated/refused; not a current B099 adapter obligation. | N/A |

Same-bug-class framing defects:

- `ocaml/c2c_mcp_helpers.ml:807-838` inserts `content` raw unless callers opt
  into XML escaping. Its reply reminder is operational, not a safety boundary.
- `data/opencode-plugin/c2c.ts:1527` inserts `msg.content` raw inside `<c2c>`.
  Peer text containing `</c2c>` or `<system-reminder>` can escape/forge the
  trusted-looking frame.
- Pi already neutralizes `<c2c>` tokens, demonstrating the adapters have
  diverged on the same threat class.

Distribution/conformance gaps:

- `just sync-skills-check` failed in this clean worktree because required
  `.claude/skills/*` copies are missing. The tracked Codex/OpenCode copies
  happen to match, but the gate is not green from a fresh worktree.
- The only safety phrase test is named and implemented for the Claude embedded
  skill. There is no golden vector that renders the same hostile message
  through Claude/Codex/OpenCode/Kimi/Pi and asserts the canonical boundary.
- No live tmux proof showed each supported client receiving the same framed
  hostile message without acting.

Required slice:

1. Introduce one short canonical **delivery-time** safety reminder and one
   hostile-content sanitizer/renderer. Use it in MCP/channel, Codex hook,
   OpenCode promptAsync, Kimi notification, wire/tmux, and Pi paths.
2. Escape/neutralize envelope terminators and trusted-looking reminder tags;
   keep peer content visibly data and preserve it for the user.
3. Make installers/session-start hooks deliver the canonical full safety
   fragment for Claude, Codex, OpenCode, and Kimi; coordinate the equivalent
   Pi extension change. Static repo-local files alone do not satisfy install.
4. Add source/generated equality gates and per-client hostile golden vectors.
5. Run real-client tmux conformance on all supported adapters before PASS.

### B100 — cross-machine golden path: PARTIAL

What exists:

- `docs/connect.md` is linked from `docs/get-started.md`, the landing page,
  and reference docs. It leads with the public relay, explains machine-wide
  Ed25519 identity, shows register, alias/address exchange, direct relay DM
  send/poll, transparent connector mode, rooms, caveats, and roundtrip success.
- `docs/relay-quickstart.md` contains an alpha limitations callout,
  local-vs-relay addressing, self-hosted relay setup, connector, monitor,
  poll/peek, two-machine/Docker sections, and a troubleshooting table.
- Built-source relay/register/dm/connect/list/ping help all exited 0 and agree
  with the primary command names used by the docs.

Why the B100 contract remains incomplete:

- The requested page is a first-time **public cross-machine** sequence:
  install -> local `init/whoami/list` proof -> relay setup/register/status ->
  discovery -> send -> receive -> real reply verification, with expected
  output and an inline symptom/cause/fix table.
- `/connect` starts at relay identity/register. It omits install and the local
  `init/whoami/list` proof, has expected output for only selected commands,
  and has no consolidated symptom/cause/fix table or explicit “why this
  order” explanation.
- `/relay-quickstart` has more of the diagnostics/table material, but its
  stated audience is operators running their own relay and its steps start by
  serving one. A newcomer must synthesize two pages, recreating part of the
  original friction.
- The source's expected output and warnings have evolved. B100 has no
  executable docs command test to catch future CLI drift.
- Current live proof was not run in this audit. Docs cite older Docker/
  Tailscale/live-relay proofs, but no dated B100 two-host verbatim transcript
  demonstrates the exact current page.

Required slice:

1. Make `/connect` the single public-relay golden path with install, local
   proof, setup/register/status, authenticated discovery, direct DM send,
   peek/poll semantics, reply, verification, expected outputs, alpha caveats,
   and the exact symptom/cause/fix table. Keep `/relay-quickstart` as the
   self-host/operator deep dive.
2. Add a docs command harness against a temporary local relay and fake HOME,
   plus a nightly/manual two-host public-relay transcript. Validate every
   command and normalize volatile fields rather than copying stale output.
3. Link the golden path prominently from top-level help and landing/get-started
   pages (current web links are good and should remain).

## Inventory reconciliation: A053-A099

This table maps every requested inventory row. “Deferred/open” means the row
is not evidence that B095-B100 is complete.

| Rows | Current audit status | B095-B100 relationship |
|---|---|---|
| A053 | PARTIAL | B097 surfaces keys but verification is deferred and identity domains are conflated. |
| A054 | PASS | Full routing address is surfaced; opaque host id is documented as routing metadata. |
| A055 | PARTIAL | Merged view exists only with `list --relay`; default remains local. |
| A056 | PARTIAL | Core fields exist, but display/verified/last-seen contract is incomplete and `identity_pk` scope is ambiguous. |
| A057-A058 | DEFERRED | Bare-alias global disambiguation/candidate errors are I006-era work, not B097 closure. |
| A059 | OPEN | Address cards / `peers add` are not implemented. |
| A060 | PARTIAL | Keys surface; pin/change warning and verified incoming identity remain deferred. |
| A061 | PARTIAL | Machine-wide granularity is documented; formal ADR remains open. |
| A062 | SUPERSEDED | Mandatory per-agent relay keys conflict with the later machine-anchor decision. |
| A063 | DEFERRED | Optional machine-attested agent identity is a future refinement, not current relay identity. |
| A064 | PARTIAL | Routing/key/display concepts are partly separated in prose, not in the list schema/trust commands. |
| A065 | FAIL | B099 does not frame every delivery/harness. |
| A066 | DEFERRED | Verified/trust-tier message metadata is explicitly future work. |
| A067 | FAIL vs strict source | The written invariant exists, but supervisor inbox DMs still cause approval resolution. |
| A068 | FAIL | Remote configured-supervisor messages can answer PreToolUse. |
| A069-A070 | DEFERRED | Persistent trust tiers and priority enforcement are not B098/B099. |
| A071-A072 | PARTIAL | Abuse/room controls exist in pieces; identity-bound trust gating remains open. |
| A073 | OPEN | No signed-message-to-privileged-action audit correlation was found. |
| A074-A075 | PARTIAL | Non-supervisor denial and safety prose exist; remote-supervisor RPC and broader trust work remain. |
| A076 | PASS (not re-audited deeply) | B093 doctor work, adjacent rather than B095-B100. |
| A077-A078 | PARTIAL | Diagnostics/config coverage is incomplete; debug bundle/env unification remain open. |
| A079 | PASS (not re-audited deeply) | B093 relay checks exist. |
| A080 | SUPERSEDED | Shared machine identity is intentional; docs should not warn it is a bug. |
| A081-A082 | PARTIAL | Capability/outbox reporting exists but does not close this tranche's cursor/security gaps. |
| A083 | OPEN | No distinct real-relay self-marker diagnostic proof found. |
| A084-A085 | PARTIAL | Watcher/output diagnostics exist but full runtime/schema proof remains. |
| A086-A087 | OPEN | Redacted debug bundle is not implemented. |
| A088 | PARTIAL | Actionable doctor fixes exist, not a complete failure catalog. |
| A089 | PARTIAL | B100 content is split; no verbatim single-page/executable golden path. |
| A090 | PASS | Cross-machine public-relay outcome is stated. |
| A091 | PARTIAL | Install guidance exists elsewhere but is absent from `/connect`'s golden sequence. |
| A092 | PARTIAL | Local proof is absent from `/connect`. |
| A093 | PARTIAL | Relay register/status material exists across pages; single-sequence expected output is incomplete. |
| A094 | PARTIAL | Discovery is documented, but B097's default/schema/test gaps remain. |
| A095 | PASS | Direct relay send and transparent queued-send distinctions are documented. |
| A096 | PARTIAL | Peek/poll is documented; no cursor/ack semantics or two-reader proof. |
| A097 | PASS in prose | Roundtrip reply defines success; current live execution proof is missing. |
| A098 | PARTIAL | Troubleshooting table exists on operator quickstart, not the public golden page. |
| A099 | PARTIAL | Ordering rationale exists in the source report but is not preserved as one explicit public-page narrative. |

## Later safety/docs inventory rows

- **C012 (canonical safety fragment): FAIL/PARTIAL.** Canonical prose and
  Claude embedding are real; cross-adapter install/delivery-time framing is
  not.
- **C013 (shared hook contract + approval isolation): FAIL/PARTIAL.** Hook
  unification is deferred, and strict approval isolation is violated by the
  supervisor inbox-DM fallback.
- **C019 (durable cursor/ack): OPEN.** B096 did not implement it.
- **C036 (identity granularity): DECISION SETTLED, ADR OPEN.** Machine key is
  the relay anchor; optional machine-attested agent identity is distinct.
- **C038 (bus, never RPC): FAIL against the literal invariant.** Documentation
  says closed, but code still contains message-to-approval behavior.
- **C043 (prompt-injection responsibility): OPEN.** B099 prose is not a full
  responsibility matrix, adapter conformance suite, or hostile-message proof.

## Commands and return codes

Source/backlog and discovery:

- `git rev-parse HEAD` -> rc 0,
  `c8d5e7c93070058907fa5f342c23c45f63772b2e`.
- `bl cat B095` ... `bl cat B100` -> rc 0 for all six.
- codebase-memory graph searches/snippets/traces -> successful; used before
  direct code search.

Build:

- `dune build ...` without an explicit root -> rc 1 (Dune selected the shared
  main tree; discarded as wrong-worktree invocation).
- `dune build --root <worktree> ...` under the system/c2c switch -> rc 1
  (dependencies unavailable in that switch).
- `opam exec --switch=clawq-5.1 -- dune build --root <worktree> <focused targets>`
  -> **rc 0**. Build warnings were pre-existing and outside this audit slice.

Focused tests:

- `test_c2c_cli.exe test connect_deprecated_alias` -> **rc 0**, 2 tests.
- `test_c2c_cli.exe test relay_dead_letter 2` -> **rc 0**, B096 help test.
- `test_c2c_cli.exe test list` -> **rc 0**, 18 matched local/list-adjacent
  tests; none exercises B097 relay merge.
- `test_relay.exe` -> **rc 0**, 49 passed, including non-draining peek.
- `test_c2c_monitor_logic.exe` -> **rc 0**, 22 passed.
- `test_c2c_approval_paths.exe` -> **rc 0**, 24 passed.
- `test_c2c_await_reply.exe` -> **rc 0**, 5 passed.
- `test_c2c_claude_skill_embedded.exe` -> **rc 0**, 7 passed.
- Full `test_c2c_cli.exe` -> rc 1, 3 unrelated `deliver_inbox` failures because
  the focused build omitted `c2c_deliver_inbox.exe`; all B095/B096 cases in
  that run passed. The focused suites above are the auditable result.

Docs/adapter gates:

- `just sync-skills-check` -> **rc 1**: clean worktree lacks required
  `.claude/skills/c2c` and `.claude/skills/review-and-fix` copies.
- `python3 scripts/c2c-docs-drift.py --repo . --summary` -> **rc 1**: two
  pre-existing stale references in `CLAUDE.md` (`c2c-swarm.sh`,
  `c2c_verify.py`), not specific to B100 but the docs gate is not green.
- Built-source `relay`, `relay register`, `relay dm`, `relay connect`, `list`,
  and `ping` help -> **rc 0** for each.
- No current two-host/public-relay live test was run; this remains explicit
  missing proof rather than an inferred PASS.

## Recommended execution order

1. Fix B096 peek authorization immediately and add the negative HTTP test.
2. Remove B098 inbox-DM approvals and make all message-origin tests inert.
3. Complete B099 shared renderer/installer/conformance across adapters,
   including hostile envelope vectors.
4. Correct B097 identity schema/default semantics and add fake-relay tests.
5. Consolidate and executable-test B100's public golden path.
6. Design cursor/ack delivery as its own protocol slice; this is larger than
   the immediate B096 peek fix but required for the original backlog wording.

Until these land and receive peer review/live adapter proof, the correct
overall result for `friction-points-cn.md` is **not completely addressed**.
