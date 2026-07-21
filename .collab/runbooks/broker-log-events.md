# broker.log audit-line catalog

Single-source index of every structured audit line the broker emits to
`<broker_root>/broker.log`. Each entry records: event name, JSON shape,
when it fires, severity tier, cross-link to the design or finding that
introduced it.

## Conventions

- **All entries are append-only JSON** — one event per line, parseable
  with `jq -c .` or `awk` on `"event"`.
- **`ts`** is a Unix epoch float (seconds, sub-second resolution). The
  exceptions are `c2c.ml:9089 named.checkpoint`, the inbox-hook
  `state.snapshot`, and `c2c-deliver-inbox --json`'s `summary`
  stdout record — those do not write broker.log audit lines and are
  NOT cataloged here.
- **All emitters are best-effort** — every helper wraps the file open
  in `try ... with _ -> ()` so audit-log failures never block the
  broker's primary path. If `broker.log` is missing, an inferred event
  may have happened but went unrecorded.
- **`perm_id_hash` and `*_session_hash`** fields are SHA-256 truncated
  to 16 hex chars (Finding 4 of the 2026-04-29 pending-perms audit:
  raw `perm_id`/`session_id` are bearer-shaped). Hashes correlate
  open/check pairs without leaking the bearer value.
- **Severity tier** below mirrors operational urgency, not protocol
  importance:
  - `CRIT` — security invariant violated, potential active attack
  - `HIGH` — security-policy enforcement (rejects, rotation guards)
  - `MED` — flow audit (forensic correlation across calls)
  - `LOW` — diagnostic (counters, telemetry)

## Updating this doc

Whenever you add a new emitter that writes to `broker.log`, add an
entry here in the same commit. The `check-broker-log-catalog.sh` script
(#442) enforces both directions:

- **FAIL**: any `"event", `String "<name>"` emitter in `ocaml/` (production
  code) is missing a catalog entry.
- **FAIL**: any catalog entry has no corresponding emitter in `ocaml/`
  (catalog drift; reverse check catches stale entries from unimplemented
  features — was WARN pre-2026-04-29).

WARN is no longer emitted for stale entries — they are a CI gate so
they don't regress silently.

---

## Index

| Event | Severity | Surface | Introduced |
|---|---|---|---|
| `alias_casefold_invariant_violated` | CRIT | alias / TOFU | #432 §3 |
| `alias_resolve_multi_match` | LOW | alias-resolution diagnostic | #432 follow-up |
| `dead_letter_write` | MED | delivery diagnostic | #433 |
| `inbox_row_skipped` | MED | poisoned-inbox row skipped on read | H9 (friction-h9-connector-row-validation) |
| `json_cap_exceeded` | MED | JSON read-cap triggered | Slice F follow-up |
| `relay_e2e_pin_first_seen` | MED | relay-crypto TOFU | CRIT-1 Slice B follow-up |
| `send_memory_handoff` | MED | feature audit | #286 |
| `session_id_differs_from_alias` | MED | session_id≠alias on registration | #529 |
| `dual_alias_dedup` | MED | same session_id had multiple aliases — deduped | #dual-alias-fix |
| `peer_pass_reject` | HIGH | peer-pass security | #29 H1 / H2b |
| `peer_pass_pin_rotate` | HIGH | TOFU rotation success | #432 TOFU 5 |
| `peer_pass_pin_rotate_unauth` | HIGH | TOFU rotation reject | #432 TOFU 4 |
| `version_downgrade_rejected` | CRIT | relay-crypto | CRIT-1 Slice B-min-version |
| `relay_e2e_pin_mismatch` | CRIT | relay-crypto | CRIT-1 Slice B follow-up |
| `relay_e2e_register_pin_mismatch` | CRIT | relay-crypto | CRIT-2 |
| `pending_open` | MED | permission flow | #432 Slice D |
| `pending_check` | MED | permission flow | #432 Slice D |
| `pending_cap_reject` | HIGH | permission flow capacity | #432 Slice C |
| `coord_fallthrough_fired` | MED | coord-backup escalation | #437 / coord-backup-fallthrough |
| `nudge_enqueue` | LOW | nudge diagnostic | #335 |
| `nudge_tick` | LOW | nudge diagnostic | #335 |
| `agy_drain_after_inject_failed` | HIGH | agy delivery integrity | #66 |
| `agy_multi_workspace` | LOW | agy workspace routing diagnostic | #69 |
| `agy_workspace_unresolved` | MED | agy workspace routing diagnostic | #69 |
| `managed_name_not_alias` | LOW | managed Codex identity diagnostic | #34 |
| `managed_registration_failed` | HIGH | managed-client delivery failure | #34 / #40 / #69 |
| `dm_enqueue` | MED | delivery audit | #488 |
| `session_id_differs_from_alias` | MED | session_id≠alias diagnostic | #529 |
| `relay_pin_delete` | MED | operator pin management | #432 Slice D |
| `relay_pin_rotate` | MED | operator pin management | #432 Slice D |
| `rpc` | LOW | RPC audit | pre-existing (always present) |

---

## Detailed entries

### `alias_casefold_invariant_violated`

**Severity**: CRIT

**Shape**:

```json
{
  "ts": <float>,
  "event": "alias_casefold_invariant_violated",
  "alias_casefold": "<casefolded-key>",
  "alias_a": "<original-alias-of-prior-row>",
  "session_id_a": "<session-id-of-prior-row>",
  "alias_b": "<original-alias-of-current-row>",
  "session_id_b": "<session-id-of-current-row>"
}
```

**Fires when**: registry contains two distinct rows whose aliases
collide under `String.lowercase_ascii` (case-fold). Detected during
registry validation. The collision means at least one alias is in a
state inconsistent with the case-fold invariant the broker assumes
(see `Broker.alias_casefold` and `c2c_mcp.ml`-line ~830).

**File**: `ocaml/c2c_broker.ml` ~line 403.

**Operational meaning**: should NEVER fire post-#432-MED-bundle
(`3947bb6c`). If you see this, an alias-takeover attempt slipped past
the casefold guards or two registries merged unsafely. Inspect both
rows; coordinator may need to evict one.

**Cross-link**: `.collab/findings/2026-04-29-stanza-coder-alias-casefold-asymmetry.md`.

---

### `alias_resolve_multi_match`

**Severity**: LOW

**Shape**:

```json
{
  "ts": <float>,
  "event": "alias_resolve_multi_match",
  "alias": "<requested-alias>",
  "alive_count": <int>,
  "total_matches": <int>
}
```

**Fires when**: alias resolution finds more than one registration
matching the requested alias. The broker picks one (deterministically;
see `c2c_mcp.ml`) and proceeds, but the situation is worth recording.

**File**: `ocaml/c2c_broker.ml` ~line 1516.

**Operational meaning**: usually benign — managed sessions on
`c2c restart` legitimately produce overlapping rows for ~seconds while
the new outer establishes registration. Only investigate if seen with
high frequency or `alive_count > 1` for a single alias persistently.

---

### `dead_letter_write`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "dead_letter_write",
  "reason": "<short-string>",
  "from_session_id": "<sender-session>",
  "from_alias": "<sender-alias>",
  "to_alias": "<intended-recipient>",
  "msg_ts": <float>
}
```

**Fires when**: the broker drops a message into the dead-letter sink
because delivery is impossible. Common reasons: `unknown_alias`,
`recipient_dead`, `cross_host_not_implemented`,
`registration_loop_blocked`.

**File**: `ocaml/c2c_broker.ml` ~line 2721.

**Operational meaning**: forensic — answer "why didn't agent X get
the message Y sent at time T?" by greping `from_alias` + `msg_ts`.
Pairs with the `remote-outbox-dlq.jsonl` file (#379 outbox DLQ)
when the dead letter is on the relay side.

**Cross-link**: #433.

---

### `inbox_row_skipped`

**Severity**: MED

**Shape**:

```json
{
  "event": "inbox_row_skipped",
  "ts": <float>,
  "session_id": "<inbox-owner-session>",
  "row": "<truncated-JSON-string-of-the-rejected-row>"
}
```

**Fires when**: `Broker.load_inbox` encounters an inbox row that
`message_of_json` rejects (missing/wrong-typed `from_alias`, `to_alias`,
or `content`). The row is skipped so the rest of the inbox still loads;
pre-H9 one such row raised Yojson `Type_error` through every broker-side
read of that session's inbox. The `row` field is a *string* (truncated to
256 chars), not embedded JSON, so a hostile row cannot shape the log
entry.

**File**: `ocaml/c2c_broker.ml` `log_inbox_row_skipped` (used by
`load_inbox`).

**Operational meaning**: someone wrote a schema-invalid row into
`<session>.inbox.json` — most likely a pre-H9 relay connector delivering
garbage relay `/poll_inbox` rows verbatim (the connector now validates
per-row and records `inbound_rejected` in connector-state instead), or a
buggy/foreign writer. Fires on every read of the poisoned file until a
drain/save rewrites it from parsed rows; repeated bursts for one session
mean the file is not being drained. Inspect the file and the writer.

**Cross-link**:
`.collab/findings/2026-07-10T08-29-20Z-f5c-worker-connector-garbage-inbox-rows.md`.

---

### `json_cap_exceeded`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "json_cap_exceeded",
  "file": "<path>",
  "max_bytes": <int>
}
```

**Fires when**: a JSON file (inbox or archive) exceeds the read-cap limit
and is skipped. Best-effort audit logging — silently ignores all errors so
logging never blocks the read path.

**File**: `ocaml/c2c_broker.ml` `log_json_cap_exceeded`.

**Operational meaning**: operators need observability when the cap triggers.
Follow-up to Slice F (non-blocking note).

---

### `relay_e2e_pin_first_seen`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "relay_e2e_pin_first_seen",
  "alias": "<sender-alias>",
  "pinned_ed25519_b64": "<b64url-pubkey>"
}
```

**Fires when**: an inbound relay envelope is successfully decrypted at
first contact (no prior Ed25519 pin for `alias`, envelope carries a
`from_ed25519` claim), and the claimed key is pinned via
`Broker.pin_ed25519_sync`.

**File**: `ocaml/c2c_broker.ml` ~line 49.

**Operational meaning**: forensic — answers "when did alias X first
contact us and what Ed25519 key did they present?". Pairs with
`relay_e2e_pin_mismatch` for the established-contact audit trail. An
unexpected `first_seen` for an alias you believed had an established
identity (but never logged the original pin) indicates a prior MITM
that went undetected, or a key-rotation gap. Compare the
`pinned_ed25519_b64` against the peer's current advertised identity.

**Cross-link**: CRIT-1 Slice B follow-up (symmetric to
`relay_e2e_pin_mismatch`).

---

### `send_memory_handoff`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "send_memory_handoff",
  "from": "<sender-alias>",
  "to": "<recipient-alias>",
  "name": "<memory-key>",
  "ok": <bool>,
  "error": "<string>"   // optional, only on ok=false
}
```

**Fires when**: a `memory_write` with `shared_with: [aliases]` triggers
the per-alias DM handoff (#286). One line per attempted recipient.

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 51.

**Operational meaning**: visibility into whether memory-handoff DMs
were enqueued. `ok=false` with `error=...` means the broker tried but
the enqueue path raised — typically because the recipient alias is
unknown or the message was malformed. `ok=true` does NOT prove the
recipient READ the memory; it proves the broker accepted the DM into
their inbox.

**Cross-link**: `.collab/runbooks/per-agent-memory.md` §send-memory-handoff;
#327 (broker.log line per handoff attempt).

---

### `session_id_differs_from_alias`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "session_id_differs_from_alias",
  "session_id": "<session-id-passed-to-register>",
  "alias": "<alias>"
}
```

**Fires when**: a registration call passes a `session_id` that differs from
`alias`. The broker uses `alias` as the canonical key; the mismatched
`session_id` is noted for audit purposes.

**File**: `ocaml/c2c_broker.ml` `register` function.

**Operational meaning**: audit trail for #529 session_id≠alias hygiene.
A mismatch may indicate a client-side registration bug or a relay routing
issue where the session_id doesn't match the expected alias.

---

### `alias_renamed`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "alias_renamed",
  "session_id": "<session-id>",
  "old_alias": "<old-alias>",
  "new_alias": "<new-alias>"
}
```

**Fires when**: a deliberate `c2c rename` / MCP `rename` (B140) commits — the
sanctioned atomic rename-everywhere. Emitted post-commit, after the registry
row, room memberships, key files, and pins have all been updated.

**File**: `ocaml/c2c_broker.ml` `rename_alias` function.

**Operational meaning**: audit trail for identity changes. Every alias
transition on this broker should have exactly one of these lines; a rename
that peers dispute (old name still showing somewhere) can be cross-checked
against it. Implicit half-renames do not exist by construction (B135 forbid
+ B140 rollback), so an alias change WITHOUT this event is a bug.

---

### `dual_alias_dedup`

**Severity**: MED

**Shape**:

```json
{
  "event": "dual_alias_dedup",
  "ts": <float>,
  "session_id": "<session-id>",
  "kept_alias": "<alias-that-was-kept>",
  "dropped_aliases": "<comma-separated-list-of-dropped-aliases>"
}
```

**Fires when**: the `register` function's defensive dedup sweep finds stale
entries for the same `session_id` under different aliases after the primary
partition logic. These orphan entries are dropped and only the new
registration is kept.

**File**: `ocaml/c2c_broker.ml` `register` function (#dual-alias-fix).

**Operational meaning**: indicates a race or bug that allowed a single
session to accumulate multiple registry entries under different aliases.
The dedup guard cleaned up, but the root cause should be investigated if
this fires frequently. See also the MCP handler guard in
`c2c_identity_handlers.ml` that prevents implicit alias re-registration.

**Cross-link**: #529.

---

### `peer_pass_reject`

**Severity**: HIGH

**Shape**:

```json
{
  "ts": <float>,
  "event": "peer_pass_reject",
  "from": "<sender-alias>",
  "to": "<recipient-alias>",
  "claim_alias": "<alias-the-artifact-claims>",
  "claim_sha": "<git-sha-the-artifact-claims>",
  "reason": "<rejection-string>"
}
```

**Fires when**: a peer-PASS DM is rejected at the broker boundary —
either the artifact's signature doesn't verify, the artifact's pubkey
doesn't match the TOFU pin (H2b), or the claim_alias differs from the
sender's identity.

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 59.

**Operational meaning**: an attempted forged peer-PASS — investigate
the sender. Reasons include `sig_invalid`, `pin_mismatch`,
`alias_mismatch`, `claim_sha_mismatch`. Pairs with the recipient's
transcript showing the rejection message.

**Cross-link**: #29 H1+H2b. CLAUDE.md "peer-PASS rubric".

---

### `peer_pass_pin_rotate`

**Severity**: HIGH

**Shape**:

```json
{
  "ts": <float>,
  "event": "peer_pass_pin_rotate",
  "alias": "<rotated-alias>",
  "old_pubkey": "<b64url>",
  "new_pubkey": "<b64url>",
  "prior_field": "<varies>"
}
```

**Fires when**: an operator-attested `c2c dev peer-pass pin-rotate` call
succeeds and the TOFU pin for `alias` is updated.

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 83.

**Operational meaning**: legitimate identity rotation; record exists
so a future attestation can be verified against the chain of rotates.
Pair with `peer_pass_pin_rotate_unauth` to see rejected attempts.

**Cross-link**: #432 TOFU Findings 4+5; `.collab/runbooks/peer-pass-rotate.md`.

---

### `peer_pass_pin_rotate_unauth`

**Severity**: HIGH

**Shape**:

```json
{
  "ts": <float>,
  "event": "peer_pass_pin_rotate_unauth",
  "alias": "<target-alias>",
  "reason": "<rejection-string>"
}
```

**Fires when**: a `pin_rotate` call is rejected at the operator-
attestation gate (sig missing, sig invalid, attestor not in
configured operator set).

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 176.

**Operational meaning**: an unauthorized rotation attempt — possible
attack. Compare `alias` against current expected rotators; correlate
with broker.log preceding lines.

**Cross-link**: #432 TOFU 4 (operator attestation); follow-up
observability slice TOFU 5.

---

### `version_downgrade_rejected`

**Severity**: CRIT

**Shape**:

```json
{
  "ts": <float>,
  "event": "version_downgrade_rejected",
  "alias": "<sender-alias>",
  "observed_envelope_version": <int>,
  "pinned_min_envelope_version": <int>
}
```

**Fires when**: an inbound relay envelope's `envelope_version` is
strictly less than the per-alias pinned `min_observed_envelope_version`
in `relay_pins.json`. Rejected BEFORE sig verify so the audit
attribution is the policy decision, not sig-mismatch.

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 114.

**Operational meaning**: a peer who has previously sent v2 envelopes
just sent a v1. Either (a) the operator legitimately rolled back a
binary on the sending side and needs to `pin_rotate` to reset the
floor, or (b) MITM rewrote `envelope_version` on the wire to bypass
CRIT-1's canonical-blob coverage. Default-open: peers with no pin
have no floor; this fires only after at least one prior v2 receive.

**Cross-link**: `.collab/design/2026-04-29T17-00-00Z-stanza-slate-relay-crypto-slice-b-min-version.md`.

---

### `relay_e2e_pin_mismatch`

**Severity**: CRIT

**Shape**:

```json
{
  "ts": <float>,
  "event": "relay_e2e_pin_mismatch",
  "alias": "<sender-alias>",
  "pinned_ed25519_b64": "<b64url-pinned-pubkey>",
  "claimed_ed25519_b64": "<b64url-claimed-pubkey>"
}
```

**Fires when**: an inbound relay envelope's claimed `from_ed25519`
disagrees with the alias's pinned Ed25519 pubkey in `relay_pins.json`.
Reject fires BEFORE sig verify; the pin is NEVER overwritten on
mismatch (load-bearing security invariant).

**File**: `ocaml/c2c_mcp.ml` ~line 4225.

**Operational meaning**: same alias, different identity key. Either
(a) legitimate identity rotation that needs operator-attested
`pin_rotate`, or (b) impersonation attempt. Recipient's transcript
also shows `enc_status: "key-changed"`.

**Cross-link**: CRIT-1 Slice B follow-up; pairs with
`peer_pass_pin_rotate_unauth` for the rotation-attempt side.

---

### `relay_e2e_register_pin_mismatch`

**Severity**: CRIT

**Shape**:

```json
{
  "ts": <float>,
  "event": "relay_e2e_register_pin_mismatch",
  "alias": "<sender-alias>",
  "key_class": "<ed25519 | x25519>",
  "pinned_b64": "<b64url-pinned-pubkey>",
  "claimed_b64": "<b64url-claimed-pubkey>"
}
```

**Fires when**: a session attempts to register with a claimed Ed25519 or
X25519 pubkey that disagrees with the alias's pinned TOFU pubkey in
`relay_pins.json`. Fires at registration time — BEFORE the session is
allowed to establish itself. Distinct from `relay_e2e_pin_mismatch`
(which fires on envelope-path mismatch) — this fires on the
handshake-path mismatch that would block the session before any envelope
is processed.

**File**: `ocaml/c2c_mcp.ml` ~line 4290 (`log_relay_e2e_register_pin_mismatch`).

**Operational meaning**: same alias, new pubkey at registration time.
Either (a) the peer legitimately rotated their identity and needs to
`pin_rotate` to update the TOFU pin, or (b) an impersonation attempt
using a previously-known alias with a different key. Compare
`pinned_b64` against the peer's last-known-good pubkey.

**Cross-link**: CRIT-2; pairs with `relay_e2e_pin_mismatch` for the
envelope-path sibling event.

---

### `pending_open`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "pending_open",
  "perm_id_hash": "<sha256-trunc-16>",
  "kind": "<permission-kind>",
  "requester_session_hash": "<sha256-trunc-16>",
  "requester_alias": "<requester-alias>",
  "supervisors": ["<alias>", ...],
  "ttl_seconds": <float>
}
```

**Fires when**: `Broker.open_pending_permission` succeeds — a
permission slot is created, awaiting reply. Pairs with
`pending_check` to close the loop.

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 220.

**Operational meaning**: forensic — answer "what permissions did
agent X open and who could approve them?". Hash fields preserve
correlatability (open ↔ check on same `perm_id_hash`) without
leaking the bearer value.

**Cross-link**: #432 Slice D; finding 5 of the 2026-04-29
pending-permissions audit.

---

### `pending_check`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "pending_check",
  "perm_id_hash": "<sha256-trunc-16>",
  "reply_from_alias": "<alias>",
  "outcome": "valid | invalid_non_supervisor | unknown_perm | expired",
  "kind": "<permission-kind>",         // optional
  "requester_alias": "<alias>",        // optional
  "requester_session_hash": "<...>",   // optional
  "supervisors": ["<alias>", ...]       // optional
}
```

**Fires when**: `check_pending_reply` returns an outcome decision —
one line per check call regardless of outcome. Optional fields are
included when the matching `pending_open` is found.

**File**: `ocaml/c2c_mcp_helpers_post_broker.ml` ~line 255.

**Operational meaning**: grep `outcome` for forensic patterns; high
`invalid_non_supervisor` rate suggests an attacker probing
permissions.

**Cross-link**: #432 Slice D.

---

### `pending_cap_reject`

**Severity**: HIGH

**Shape**:

```json
{
  "ts": <float>,
  "event": "pending_cap_reject",
  "note": "<human-readable-context>"
}
```

**Fires when**: `open_pending_reply` is rejected because the broker is
already at the per-process pending-permissions cap (#432 Slice C
default 50, override via `C2C_PENDING_PERMISSIONS_CAP`). Note the
distinct event name from `peer_pass_reject` so log readers can grep
this independently.

**File**: `ocaml/c2c_pending_reply_handlers.ml` ~line 96.

**Operational meaning**: cap exhaustion — either legitimate burst
load or a slow-poisoning attack filling the perm table. Inspect
`pending_open` line history for the past minute.

**Cross-link**: #432 Slice C.

---

### `coord_fallthrough_fired`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "coord_fallthrough_fired",
  "perm_id_hash": "<sha256-trunc-16>",
  "tier": <int>,
  "primary_alias": "<original-coord>",
  "backup_alias": "<tier-N-alias>",
  "requester_alias": "<requester>",
  "elapsed_s": <float>
}
```

**Fires when**: the coord-backup scheduler tick decides to escalate a
pending-permission DM to the next tier in `swarm.coord_chain` because
the prior tier didn't ack within `swarm.coord_fallthrough_idle_seconds`
(default 120s). One line per tier fire (tier=1 means first backup,
tier=N means broadcast).

**File**: `ocaml/c2c_mcp.ml` ~line 4390 (logger);
`ocaml/coord_fallthrough.ml` (decision logic).

**Operational meaning**: the primary coord didn't surface the request
in time — investigate why (compact loop, quota, pane stuck). The
backup chain's order is operator-configured; trust the audit trail
to reconstruct who was actually engaged.

**Cross-link**: `.collab/design/2026-04-29-coord-backup-fallthrough-stanza.md`;
#437.

---

### `nudge_enqueue`

**Severity**: LOW

**Shape**:

```json
{
  "ts": <float>,
  "event": "nudge_enqueue",
  "from_session_id": "<sender-session>",
  "to_alias": "<recipient>",
  "to_pid_state": "alive | unknown | dead | alive_no_pid",
  "ok": <bool>
}
```

**Fires when**: the relay-nudge scheduler enqueues a nudge DM to an
idle session.

**File**: `ocaml/relay_nudge.ml` ~line 106.

**Operational meaning**: diagnostic — verify which sessions got
nudged and which were skipped.

**Cross-link**: #335.

---

### `nudge_tick`

**Severity**: LOW

**Shape**:

```json
{
  "ts": <float>,
  "event": "nudge_tick",
  "from_session_id": "<scheduler-session>",
  "alive_total": <int>,
  "idle_eligible": <int>,
  "sent": <int>,
  "skipped_dnd": <int>,
  "alive_no_pid": <int>,
  "unknown_with_pid": <int>,
  "dead": <int>,
  "cadence_minutes": <float>,
  "idle_minutes": <float>
}
```

**Fires when**: every relay-nudge scheduler tick (default 30 min
cadence). One per tick per running broker — useful for detecting
the multi-broker amplification hypothesis (#335).

**File**: `ocaml/relay_nudge.ml` ~line 128.

**Operational meaning**: counters for capacity planning + anomaly
detection. If `sent` is consistently 0 despite `idle_eligible > 0`,
the nudge enqueue path is broken.

**Cross-link**: #335.

---

### `agy_drain_after_inject_failed`

**Severity**: HIGH

**Shape**:

```json
{
  "event": "agy_drain_after_inject_failed",
  "ts": <float>,
  "label": "<drain-source>",
  "detail": "<exception>"
}
```

**Fires when**: agy agentapi injection succeeded but all three attempts to
remove the delivered mail from the broker inbox raised. The message may be
injected again at the next turn boundary.

**File**: `ocaml/cli/c2c_agy_deliver.ml` `drain_after_inject`.

**Operational meaning**: delivery reached the agent, but acknowledgement did
not persist. Inspect the named drain and broker filesystem before retrying;
repeated entries indicate a duplicate-delivery loop rather than message loss.

**Cross-link**: agy delivery hardening #66.

### `agy_multi_workspace`

**Severity**: LOW

**Shape**:

```json
{
  "event": "agy_multi_workspace",
  "ts": <float>,
  "client": "agy",
  "session_id": "<session-id>",
  "broker_root": "<chosen-broker-root>",
  "candidates": ["<workspace>", "..."],
  "chosen": "<workspace-or-null>",
  "detail": "<selection-rule>"
}
```

**Fires when**: an agy hook supplies more than one `workspacePaths` candidate.
The hook sorts the unordered set and prefers session affinity, otherwise the
lexicographically first workspace.

**File**: `ocaml/cli/c2c_hook_cmd.ml` agy hook registration.

**Operational meaning**: diagnostic record of which repo broker owns a
multi-root session. It is not itself a fault; use it to explain why peers in a
non-chosen workspace cannot see the session.

**Cross-link**: agy workspace routing #69.

### `agy_workspace_unresolved`

**Severity**: MED

**Shape**:

```json
{
  "event": "agy_workspace_unresolved",
  "ts": <float>,
  "client": "agy",
  "session_id": "<session-id>",
  "broker_root": "<resolved-broker-root>",
  "workspace": "<workspace-or-null>",
  "detail": "<resolution-reason>"
}
```

**Fires when**: an unmanaged agy registration lands in the shared `default`
broker without an explicit broker override, or changing into the supplied
workspace failed. A non-repository workspace may legitimately resolve to
`default`.

**File**: `ocaml/cli/c2c_hook_cmd.ml` agy hook registration.

**Operational meaning**: explains potentially surprising broker placement.
Treat a failed `chdir` or unexpected repository workspace as actionable; an
intentional non-repo workspace is informational.

**Cross-link**: agy workspace routing #69.

### `managed_name_not_alias`

**Severity**: LOW

**Shape**:

```json
{
  "event": "managed_name_not_alias",
  "ts": <float>,
  "client": "codex",
  "requested_name": "<instance-name>",
  "alias": "<broker-alias>",
  "detail": "<selection-explanation>"
}
```

**Fires when**: managed Codex starts with an instance name that differs from
the broker alias selected by an explicit alias flag or legacy role alias.

**File**: `ocaml/c2c_start.ml` `managed_name_not_alias_record`, emitted by
`ocaml/cli/c2c_managed_cmd.ml`.

**Operational meaning**: peers must send to `alias`; lifecycle commands still
use `requested_name`. This record makes that split durable after the terminal
notice scrolls away.

**Cross-link**: managed Codex alias hardening #34.

### `managed_registration_failed`

**Severity**: HIGH

**Shape**:

```json
{
  "event": "managed_registration_failed",
  "ts": <float>,
  "client": "<codex-app-server|kimi|agy>",
  "name|instance": "<managed-name>",
  "session_id": "<codex-session-id, when applicable>",
  "alias": "<requested-alias>",
  "reason": "<structured-reason, kimi/agy>",
  "detail": "<human-readable-failure>"
}
```

**Fires when**: a managed Codex app-server, Kimi, or agy launch cannot publish
its authoritative broker registration. Client-specific optional fields are
present as shown above.

**File**: `ocaml/c2c_codex_session.ml` and `ocaml/c2c_start.ml` managed launch
registration paths.

**Operational meaning**: the managed UI may still launch, but peers cannot
reliably address or deliver to it. Exit the client, resolve the alias/broker
error, and restart; stderr alone is insufficient because full-screen TUIs
paint over it.

**Cross-link**: managed identity hardening #34, Kimi #40, agy #69.

## Out of scope (not broker.log)

These events appear in source but write to a different log file or
state-snapshot path. NOT cataloged here:

- `named.checkpoint` — `c2c.ml:9089`, writes to `<state-snapshot>.log`
  (c2c session-restoration checkpoint).
- `state.snapshot` — `c2c_inbox_hook.ml:125`, writes to
  `<state>.snapshot.tmp` then renames (claude-code state restoration).
- `summary` — `c2c_deliver_inbox.ml:351`, writes a machine-readable
  `c2c-deliver-inbox --json` stdout summary, not a broker audit line.
  This exemption is intentionally included with B002 because the rebased
  worktree's `just check` catalog gate fails without it; it is a gate repair,
  not part of the Pi Agent behavior change.

These belong to command/state output surfaces, not the broker audit-log
subsystem. If they ever migrate to broker.log, add catalog entries here.

---

## Severity reference

- **CRIT** — security invariant violated, possible active attack:
  `alias_casefold_invariant_violated`, `version_downgrade_rejected`,
  `relay_e2e_pin_mismatch`, `relay_e2e_register_pin_mismatch`. Investigate immediately.
- **HIGH** — security policy enforcement: `peer_pass_reject`,
  `peer_pass_pin_rotate`, `peer_pass_pin_rotate_unauth`,
  `pending_cap_reject`. Review on review cadence; fire-and-investigate
  if rates spike.
- **MED** — flow audit: `dead_letter_write`, `relay_e2e_pin_first_seen`,
  `send_memory_handoff`, `pending_open`, `pending_check`,
  `coord_fallthrough_fired`, `relay_pin_delete`, `relay_pin_rotate`.
  Forensic use; correlate by `perm_id_hash` / `from_alias` / `msg_ts`.
- **LOW** — diagnostic counters: `alias_resolve_multi_match`,
  `nudge_enqueue`, `nudge_tick`. Inspect for capacity planning,
  anomaly baseline.

### `dm_enqueue`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "dm_enqueue",
  "msg_type": "<enqueue_message | send_all>",
  "from_alias": "<sender-alias>",
  "to_alias": "<recipient-alias>",
  "resolved_session_id": "<session-id>",
  "inbox_path": "<path-to-inbox>"
}
```

**Fires when**: every direct-message enqueue completes inside the broker —
both 1:1 DMs (`msg_type: "enqueue_message"`) and 1:N fan-out from
`send_all` (`msg_type: "send_all"`). One line per individual recipient.

**File**: `ocaml/c2c_mcp.ml` ~line 2464 (`enqueue_message` path)
and ~line 2517 (`send_all` path).

**Operational meaning**: forensic — answer "was a DM actually enqueued for
recipient X when I sent to alias Y?" by grepping `to_alias` + `msg_ts`
range. Pairs with the sender's transcript showing the `send` RPC. Unlike
`dead_letter_write` (which fires only on failure), this fires on every
success so the absence of a line for a given `to_alias` indicates the
alias was never resolved — useful for the #488 routing-mismatch
investigation.

**Cross-link**: #488 (routing-mismatch tripwires).

---

### `session_id_differs_from_alias`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "session_id_differs_from_alias",
  "session_id": "<registered-session-id>",
  "alias": "<registered-alias>"
}
```

**Fires when**: during `register`, a fresh registration (no prior entry for
this session_id) passes a `session_id` that differs from `alias`. The broker
correctly handles this by resolving alias→session_id for both enqueue and
drain, so delivery is not affected — this event provides visibility into
when the mismatch occurs (e.g. a sender wrote to a session_id-based inbox
filename instead of an alias-based one).

**File**: `ocaml/c2c_broker.ml` `register` function (~line 1772).

**Operational meaning**: audit trail for the #529 session_id≠alias hygiene
fix. Operators can grep for this event to find registrations where the
inbox filename (`<session_id>.inbox.json`) differs from the alias-derived
path. The broker itself handles delivery correctly using registry resolution.

**Cross-link**: #529 (session_id=alias hygiene).

---

### `relay_pin_delete`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "relay_pin_delete",
  "alias": "<target-alias>",
  "axes": ["ed25519", "x25519", "min_observed_envelope_version"]
}
```

**Fires when**: operator explicitly deletes one or more TOFU pins for an
alias via `c2c relay-pins delete --alias <a> [--ed25519] [--x25519] [--min-version] [--all]`.

**File**: `ocaml/c2c_mcp.ml` (module `Broker`).

**Operational meaning**: operator-initiated pin clear. Use `c2c doctor relay-pin-status`
to verify the pins were actually removed. The next first-contact from that alias
will be treated as a fresh TOFU event (new pin accepted and logged).

**Cross-link**: `relay_pin_rotate` (clears all axes at once + bumps epoch).

---

### `relay_pin_rotate`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "relay_pin_rotate",
  "alias": "<target-alias>",
  "rotation_epoch": <int>
}
```

**Fires when**: operator rotates all TOFU pins for an alias via
`c2c relay-pins rotate --alias <a>`. Clears ed25519, x25519, and
min-observed-envelope-version pins; increments the per-alias rotation-epoch
counter (in-memory only, not persisted).

**File**: `ocaml/c2c_mcp.ml` (module `Broker`).

**Operational meaning**: operator-initiated full pin reset. Unlike a targeted
delete, rotate also bumps the epoch so the broker can distinguish
"intentional post-rotate first-contact" from an unexpected first-contact
(MITM) within a broker lifetime. The epoch is reset to 0 on broker restart.

**Cross-link**: `relay_pin_delete` (targeted single-axis deletion).

---

### `session_id_differs_from_alias`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "session_id_differs_from_alias",
  "session_id": "<registered-session-id>",
  "alias": "<registered-alias>"
}
```

**Fires when**: a registration is created or updated where `session_id ≠
alias`. The broker handles this correctly — senders resolve alias→session_id
via the registry so both enqueue and drain use the same session_id-based
path — but operators may see unexpected inbox filenames (e.g.
`session-a.inbox.json` instead of `storm-ember.inbox.json`).

**File**: `ocaml/c2c_broker.ml` `register` function (~line 1871).

**Operational meaning**: forensic visibility into when this configuration
occurs. The inbox filename is based on session_id, so when they differ,
operators may need to correlate by alias rather than session_id.

**Cross-link**: #529.

---

### `worktree_mismatch`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "worktree_mismatch",
  "alias": "<sender-alias>",
  "expected_cwd": "<path-from-expected-cwd-file>",
  "actual_cwd": "<cwd-at-registration-time>"
}
```

**Fires when**: the sender's shell cwd at registration time differs from the
expected path recorded in `<instances_dir>/<alias>/expected-cwd` at launch.
This is a soft diagnostic — no hard block, agents may legitimately shell into
other trees for read-only operations.

**File**: `ocaml/c2c_broker.ml` `check_worktree_mismatch` (~line 1168).

**Operational meaning**: visibility into when an agent's working directory has
drifted from its launch-time expected path (e.g. shell `cd`-ed into the main
tree while its worktree is `.worktrees/<slice>/`). Git operations from that
shell could mutate the shared HEAD. Cross-host senders and the coordinator
are exempt.

**Cross-link**: `.collab/design/2026-05-02-hardening-b-shell-launch-location-guard.md`.

---

### `worktree_match`

**Severity**: MED

**Shape**:

```json
{
  "ts": <float>,
  "event": "worktree_match",
  "alias": "<sender-alias>",
  "cwd": "<current-expected-cwd>"
}
```

**Fires when**: a prior `worktree_mismatch` has cleared — the sender's cwd
is again at the expected launch-time path. One line per recovery.

**File**: `ocaml/c2c_broker.ml` `check_worktree_mismatch` (~line 1168).

**Operational meaning**: confirms that the mismatch condition has been resolved.

**Cross-link**: `.collab/design/2026-05-02-hardening-b-shell-launch-location-guard.md`.

---

### `rpc`

**Severity**: LOW

**Shape**:

```json
{
  "ts": <float>,
  "event": "rpc",
  "tool": "<tool-name>",
  "ok": <bool>
}
```

**Fires when**: every tools/call RPC completes. One line per RPC
regardless of outcome. Content fields are deliberately omitted to
avoid leaking message content into a shared log file.

**File**: `ocaml/c2c_mcp.ml` ~line 310.

**Operational meaning**: audit trail of broker RPC volume and success
rate. Aggregate by `tool` for per-tool latency profiling; filter by
`ok=false` for error rate.

**Cross-link**: pre-existing (present since the RPC audit subsystem was
added; catalog entry added retroactively as part of #388).

---

### `wake_inject`

**Severity**: LOW

**Shape**:

```json
{
  "ts": <float>,
  "event": "wake_inject",
  "session_id": "<target-session-id>",
  "backend": "tmux" | "herdr",
  "message_count": <int>
}
```

**Fires when**: the codex idle-wake injector (`C2c_wake_inject.maybe_inject`)
successfully types a nudge line into an idle session's tmux/herdr pane
because its inbox has pending messages. One line per injection (backoff +
newest-message dedupe bound the rate). The nudge is a fixed template
containing only the message count — never message content (B098).

**File**: `ocaml/c2c_wake_inject.ml` `maybe_inject` (~line 415).

**Operational meaning**: audit trail of automatic pane wake-ups. Aggregate
by `session_id` to see which sessions are being woken and how often;
correlate with the subsequent hook-drain to confirm the wake→deliver chain.

**Cross-link**: codex-wake-inject slice (2026-07-10); runbook
`.collab/runbooks/agent-wake-setup.md` § Codex idle wake.

---

### `wake_inject_error`

**Severity**: LOW

**Shape**:

```json
{
  "ts": <float>,
  "event": "wake_inject_error",
  "session_id": "<target-session-id>",
  "backend": "tmux" | "herdr",   // absent on unexpected-exception lines
  "reason": "<failure-reason>"
}
```

**Fires when**: an injection attempt fails — backend command non-zero exit,
fixture/exec error, or an unexpected exception in `maybe_inject` (the
catch-all line omits `backend`). Skips (backoff, not-idle, no-new-messages)
are NOT logged as errors; only real failures are.

**File**: `ocaml/c2c_wake_inject.ml` `maybe_inject` (~lines 424, 432).

**Operational meaning**: a session with pending messages whose pane could
not be woken — check the target pane still exists (`tmux has-session`,
`herdr agent list`) and that the registration's wake target is current.

**Cross-link**: codex-wake-inject slice (2026-07-10); runbook
`.collab/runbooks/agent-wake-setup.md` § Codex idle wake.

**Catalog-gate note**: the wake-inject `log_event` helper deliberately
takes the `("event", `String "<name>")` pair from each call site (rather
than an `~event` variable) so the #442 static scan can see the literal.
If you add a logging helper that passes the event name as a variable,
the scan cannot detect its events — keep the literal-at-call-site
convention or the gate will silently under-count.

---

## Operator queries

Common one-liners:

```bash
# All security-tier events from the last hour
jq -c 'select(.event | test("rotate|reject|mismatch|downgrade|casefold"))' \
  broker.log | tail -100

# Permission-flow trace for a specific perm_id_hash
jq -c 'select(.perm_id_hash == "<hash>")' broker.log

# Coord-fallthrough escalations grouped by tier
jq -c 'select(.event == "coord_fallthrough_fired")' broker.log \
  | jq -s 'group_by(.tier) | map({tier: .[0].tier, count: length})'

# Dead-letter rate (per minute, last hour)
jq -c 'select(.event == "dead_letter_write")' broker.log \
  | tail -3600 | wc -l

# Nudge effectiveness — sent vs idle_eligible
jq -c 'select(.event == "nudge_tick")
       | {ts: .ts, sent: .sent, eligible: .idle_eligible}' broker.log
```

---

## Maintenance

Last full sweep: 2026-04-29.

When adding a new emitter:

1. Pick an event name in `snake_case`. Avoid colliding with existing
   ones; grep this catalog first.
2. Place it under the file's existing `let log_*` helper convention
   (`log_<event_name>`). Mirror `log_peer_pass_pin_rotate_unauth`'s
   shape: best-effort, swallow errors.
3. Add a catalog entry above with the same fields actually written.
4. Pick a severity tier; document operational meaning + at least one
   operator query.
5. Cross-link to the design / finding / slice that introduced it.
6. Run `./scripts/check-broker-log-catalog.sh` to confirm
   completeness — `just check` runs this automatically (#442). It
   greps `"event", \`String "<name>"` emitters in `ocaml/`
   (production code, excluding `test/`), diffs against the `### `name`
   ` headers in this file, and FAILs if any emitter is uncataloged
   or any cataloged name has no source emitter (catalog drift).
   `--json` flag emits a machine-readable summary for CI.

Out-of-scope events (write to a different log, not broker.log) live
in the script's `OUT_OF_SCOPE` allow-list and the "Out of scope"
section above. Updating one without the other will FAIL the script.

Slice peer-PASS rubric: a slice that adds/changes/removes a broker.log
event but doesn't update this catalog FAILs the docs-up-to-date check
(#324) AND the `check-broker-log-catalog.sh` gate (#442).

— stanza-coder 🪨
