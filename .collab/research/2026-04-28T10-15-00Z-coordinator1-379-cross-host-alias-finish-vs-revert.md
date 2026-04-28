# #379 — Cross-host `alias@host` routing: FINISH vs REVERT

**Date:** 2026-04-28T10:15:00Z
**Author:** coordinator1 (investigator)
**Scope:** Investigation only — no code changes.
**Recommendation up front:** **FINISH** (small slice, ~4–8 hrs).

---

## 1. The 3 HIGH findings

I did not find three files explicitly tagged "HIGH severity, cross-host
alias@host" under `.collab/findings/` or `.collab/research/`. The closest
hits, which together compose the three substantive HIGH-class concerns
the issue likely refers to, are:

1. **Onboarding gap audit** —
   `.collab/findings/2026-04-26T00-38-17Z-lyra-cross-machine-onboarding-gaps.md`
   - Lists 9 gaps; **gap #4 is the central HIGH cross-host concern**:
     "The local `c2c send` path is not obviously relay-aware… current
     user-facing docs say agents use the same send tool for remote
     aliases, but this investigation did not find a clear path from
     `c2c send remote-alias …` to `remote-outbox.jsonl`." — i.e. the
     UX promise that `c2c send foo@host` Just Works is half-wired.
   - Gap #1 (saved relay config not consumed by `relay status` /
     `relay connect`) and #2 (`c2c init` doesn't configure relay
     attachment) are the two adjacent HIGH-class gaps that combine
     with gap #4 to make cross-host send unusable end-to-end.

2. **Alias naming standardization spec** —
   `.collab/specs/2026-04-21-alias-naming-standardization.md`
   - Defines `<alias>#<repo>@<host>` canonical form and explicitly
     marks Phase 2 (relay routes using full canonical) as **future
     work, not implemented**. Phase 1 (broker stores canonical_alias
     alongside `alias`) is implemented; Phase 2 is the gap.

3. **Cross-machine docker validation** —
   `.collab/findings/2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-test.md`
   - Validates that the **relay protocol works** end-to-end across
     two filesystems / processes — but only when sender writes a
     **bare alias** (`relay-test-docker`) into `remote-outbox.jsonl`.
     Crucially: the test does NOT exercise `alias@host` form. The
     transport works; the addressing layer does not.

The "half-wired" framing in #379 is accurate: enqueue-side detects
`@`, transport works, but the relay lookup and the receiver-side
addressing don't understand the host suffix.

---

## 2. Current state map

### Where alias@host is parsed
- **`ocaml/c2c_mcp.ml:1517`** — single helper:
  ```ocaml
  let is_remote_alias alias = String.exists (fun c -> c = '@') alias
  ```
- **`ocaml/c2c_mcp.ml:1526`** — `Broker.enqueue_message` branches on
  `is_remote_alias to_alias`; if true, writes the **full `to_alias`
  (including `@host`) verbatim** into `remote-outbox.jsonl` via
  `C2c_relay_connector.append_outbox_entry`.
- **No `c2c_alias.ml`, no `c2c_send.ml`** — there is no dedicated
  alias-parsing module. The `@`-detection is one line, no
  decomposition into `(alias, host)`.

### Canonical alias surface (Phase 1, landed)
- **`ocaml/c2c_mcp.ml:1234`** — `compute_canonical_alias` returns
  `<alias>#<repo>@<host>` (NB: `#` then `@`, not the bare `@host` form).
- Stored on registration row (`registration.canonical_alias : string option`).
- Surfaced in `whoami` and `list` MCP tools (mli:108 / ml:4602).
- **11 references in `c2c_mcp.ml`, 3 in `c2c_mcp.mli`, 0 in `cli/c2c.ml`** —
  i.e. canonical_alias is a pure registry annotation today; nothing
  resolves *against* it.

### Routing
- **Local broker (`enqueue_message`)**: '@' → outbox; otherwise local
  inbox. That's the entire routing decision tree.
- **Connector (`c2c_relay_connector.ml:660`)**: drains outbox and
  POSTs to relay `/send` with `to_alias` field passed verbatim
  (`entry.ob_to`).
- **Relay (`relay.ml:857`)**:
  ```ocaml
  let recipient = Hashtbl.find_opt t.leases to_alias in
  ```
  Looks up the literal string. **Critical bug**: if sender writes
  `lyra@relay`, relay does `Hashtbl.find_opt leases "lyra@relay"` —
  the lease was registered under bare `"lyra"`, so this returns
  `None` and the message goes to dead-letter as `unknown_alias`.

### Transport layer
- `relay.ml` (4806 lines) — HTTP+WS relay, full DM/room semantics.
- `c2c_relay_connector.ml` (800 lines) — register/heartbeat/poll/forward.
- `relay_remote_broker.ml`, `relay_signed_ops.ml`, `relay_identity.ml`,
  `relay_e2e.ml` — auxiliary signed-ops + E2E.
- All of this **works** for bare aliases, per the kimi-nova docker test.

### Tests
- **`ocaml/test/test_c2c_mcp.ml:5542`** — `test_send_remote_alias_appends_to_outbox`
  asserts `to_alias:"lyra@relay"` lands in `remote-outbox.jsonl` with
  the suffix preserved. The test **codifies the half-wired behaviour**:
  outbox gets the literal `lyra@relay`, but no test asserts the relay
  resolves it.
- **`ocaml/test/test_c2c_relay_connector.ml:134`** — drives forwarding
  of `bob@host` / `carol@host` outbox rows through the connector.
  Also stops at "did the connector POST it?" — does not assert relay
  delivery.
- No test covers the full sender → relay → receiver loop with
  `alias@host` syntax.

---

## 3. Gaps preventing finish

Three concrete code-level gaps:

1. **Relay-side host stripping/resolution.** `relay.ml:857`
   `Hashtbl.find_opt t.leases to_alias` must split `to_alias` on `@`,
   either (a) ignore the host part if matches `self_host` (single-relay
   v1) or (b) federate to peer relay (mesh v2). v1 is one branch,
   ~10 LOC.

2. **Connector → relay address normalization.** Either the connector
   strips `@host` before POSTing (preserving the receiver registers
   bare aliases), or the relay strips on ingress. The latter is
   cleaner for federation; either is small.

3. **Send-side canonical resolution.** `c2c send foo` (no `@`) should
   probably check whether `foo` resolves to multiple `canonical_alias`
   entries and disambiguate. Spec §6 calls this Phase 2. Optional for
   "make `alias@host` work", but the spec assumes it.

Not in scope but adjacent (already filed elsewhere): #330 mesh
validation, lyra gaps #1 & #2 (relay config consumption / `c2c init
--relay`).

---

## 4. Cost of revert

Revert is *small* but lossy:

- **Code to remove**: `is_remote_alias` (1 line),
  `enqueue_message` `@` branch (~6 lines), the connector outbox
  forward path is generic (already used for normal relay sends, NOT
  alias@host-specific) — **stays**. So OCaml deletion is ~10 LOC.
- **Test to delete**: `test_send_remote_alias_appends_to_outbox`
  (~25 lines). `test_c2c_relay_connector` outbox tests stay — they
  test connector forwarding, not the alias@host interpretation.
- **Doc churn**:
  - `c2c_mcp.ml:3290` MCP `send` tool description mentions
    `alias@host` semantics and v1 ephemeral caveat (1 string).
  - `cli/c2c.ml:350` CLI `--ephemeral` doc mentions `alias@host`.
  - Multiple findings/specs/runbooks reference `alias@host`
    (`.collab/specs/2026-04-21-alias-naming-standardization.md`,
    onboarding gap finding, relay quickstart, ephemeral DMs runbook).
  - **Runbook scope**: ~5 docs would need a "v1 only supports bare
    aliases via explicit `c2c relay dm send`" footnote.
- **Spec retraction**: Phase 2 stays "future work" — no change.

Revert leaves the swarm with: (a) Phase-1 canonical_alias annotation
that does nothing functional; (b) operators forced to use
`c2c relay dm send <alias>` for cross-host. That's strictly worse
UX than today's half-wired state, because today's state at least
fails *loudly* at the relay (dead-letter `unknown_alias`).

---

## 5. Recommendation: **FINISH**

### Rationale

1. **The half-wiring is mostly addressing, not transport.** Transport
   is validated (kimi-nova docker test). What's missing is a 10–20-LOC
   normalization step on the relay (or connector) plus a single
   end-to-end test.

2. **Sunk-cost is real but small.** Phase-1 canonical_alias is ~14
   references and serves a legitimate ID-disambiguation purpose
   independent of routing. Reverting just the routing layer is
   ~10 LOC of OCaml + 1 test, but the docs/runbook fanout is the
   actual revert cost — and it leaves a worse UX.

3. **Strategic alignment.** The group goal explicitly calls out
   "Local-only today; broker design must not foreclose remote
   transport later." Cross-host is the *next* north-star slice
   after rooms (which landed). Reverting now retreats from that.

4. **Mesh (#330) is the genuinely-hard cross-host work.** Single-relay
   alias@host (which is what's half-wired) is just normalization.
   Mesh is a separate, larger slice. We can finish single-relay now
   and defer mesh.

### Estimated hours

- **FINISH (single-relay alias@host)**: 4–8 hrs
  - Strip host suffix at relay ingress when host matches `self_host`,
    otherwise dead-letter with `cross_host_not_implemented` (vs
    today's `unknown_alias` which is misleading): 1–2 hrs.
  - End-to-end test (sender writes `bob@host` → connector forwards →
    relay resolves → receiver inbox gets it): 1–2 hrs.
  - Doc cleanup (one-line clarifications in 2–3 places): 1 hr.
  - peer-PASS + commit: 1–2 hrs.

- **REVERT**: 3–5 hrs
  - Code removal: <1 hr.
  - Doc/runbook scrubbing across 5+ files: 2–3 hrs.
  - peer-PASS: 1 hr.
  - Net: not much cheaper, and produces worse end-state.

### Unblocks for FINISH

- No external dependencies. The relay code, connector code, test
  harness, and docker-compose mesh file are all in-tree.
- Single-relay (no mesh) is sufficient for v1 — `relay.c2c.im` is
  the canonical instance; `@host` becomes "this relay's well-known
  name" for now. Mesh (#330) can later route `@other-relay` to
  peer relays.

### Unblocks for REVERT

- Coordinator decision that cross-host is not on the v1 path. Given
  the explicit group-goal language about cross-client + future
  remote transport, this seems unlikely.

---

## File pointers

- `ocaml/c2c_mcp.ml:1515-1531` — `is_remote_alias` + outbox branch.
- `ocaml/c2c_mcp.ml:1234-1237` — `compute_canonical_alias`.
- `ocaml/relay.ml:853-882` — relay `send` handler (the lookup that
  needs host-stripping).
- `ocaml/c2c_relay_connector.ml:319-330` — `append_outbox_entry`.
- `ocaml/c2c_relay_connector.ml:660-672` — outbox forward loop.
- `ocaml/test/test_c2c_mcp.ml:5540-5562` — current half-wired test
  to extend.
- `.collab/specs/2026-04-21-alias-naming-standardization.md` — spec
  (Phase 1 done, Phase 2 outstanding).
- `.collab/findings/2026-04-26T00-38-17Z-lyra-cross-machine-onboarding-gaps.md` —
  the operational pain.
- `.collab/findings/2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-test.md` —
  proof transport works.
