# Peer-PASS pin_rotate audit log + operator-rotation interface

**Audience**: operators running a c2c broker; agents writing future
MCP/RPC pin-rotation tooling; reviewers of pin-store changes.

**Purpose**: end-to-end documentation of the audit-log surface for
peer-PASS trust-pin operations (`<broker_root>/peer-pass-trust.json`),
the JSON event lines emitted into `<broker_root>/broker.log`, and the
operator-rotation-via-delete interface for the relay-e2e companion
pin store (`<broker_root>/relay_pins.json`). All three were each
shipped as bounded follow-ups on top of the original signed-peer-pass
SPEC (#55, #432 TOFU 4/5, #432 TOFU 5 observability) and were
individually undocumented; this runbook collapses them into one
reference.

**Cross-links**: `.collab/design/SPEC-signed-peer-pass.md` covers the
cryptography (Ed25519 sign/verify, TOFU pin model, `pin_rotate`
contract). This runbook covers what an operator sees in
`broker.log` and how to drive the operator-only rotation interfaces.

---

## What's in `broker.log`

`<broker_root>/broker.log` is an append-only file of newline-
delimited JSON. Every line has at least `ts` (Unix float seconds)
and `event` (a string tag). Other fields depend on the event.

This runbook documents the three pin-related events. Other events
(`pending_open`, `pending_check`, `pending_cap_reject`, etc.) live
in their own slices and are out of scope here.

### Event 1: `peer_pass_pin_rotate` — successful rotation (#55)

Emitted when `Peer_review.pin_rotate` writes a new pin to
`<broker_root>/peer-pass-trust.json`. Fires on both first-rotate
(no prior pin existed) and replacement (prior pin overwritten).

```json
{
  "ts": 1714000000.0,
  "event": "peer_pass_pin_rotate",
  "alias": "stanza-coder",
  "old_pubkey": "",
  "new_pubkey": "AbCdEf...32-byte-base64",
  "prior_first_seen": null
}
```

Fields:

- `alias`: the reviewer alias whose pin was rotated.
- `old_pubkey`: the prior pubkey, or `""` if there was no prior pin
  (first-rotate-as-pin case).
- `new_pubkey`: the pubkey now pinned for `alias`.
- `prior_first_seen`: `null` for first-rotate; `<float>` (Unix epoch
  seconds) for replacement.

The hook lives inside `pin_rotate` itself, not at any single CLI
call site, so every caller — current and future, MCP and CLI alike —
produces a log line. Any code that silently rotates a pin without
going through `pin_rotate` is a bug, not a missing log line.

### Event 2: `peer_pass_pin_rotate_unauth` — rejected rotation (#432 TOFU 5 observability)

Emitted when `Peer_review.pin_rotate`'s operator-attestation gate
rejects a call (#432 TOFU Finding 5). Fires before any pin write
or signature verify; the only side effect is this log line.

```json
{
  "ts": 1714000000.0,
  "event": "peer_pass_pin_rotate_unauth",
  "alias": "stanza-coder",
  "reason": "operator_unauthorized"
}
```

Fields:

- `alias`: the reviewer alias the rotation would have targeted (drawn
  from the artifact's `reviewer` field).
- `reason`: today only `"operator_unauthorized"` (the
  `C2C_OPERATOR_AUTH_TOKEN` env-var gate fired). Future attestation
  failure modes (expired token, allowlist mismatch, etc.) may add
  additional reason values; treat the field as a free-form string.

What this signals:

- **Legitimate operator typo on a future MCP rotate-pin tool**. Rotate
  the env var if the token has been compromised, or correct the
  caller's token.
- **Probe of the rotation surface**. If a peer's session is calling
  `pin_rotate` via an MCP path it shouldn't have access to, this is
  the signal. Cross-reference with the surrounding `peer_pass_*` log
  lines for context.
- **Misrouted call**. CLI invocations should NEVER produce this event
  — they pass `Cli_local_shell` which is unconditionally accepted.
  An unauth event with `alias=<a CLI-using operator alias>` likely
  means a non-CLI path was wired wrong.

The corresponding success event is NOT emitted on the reject path,
so a count of `peer_pass_pin_rotate_unauth` lines is a clean view
of "rotation attempts that didn't take."

### Event 3: `peer_pass_reject` — pre-existing failed verification

Documented elsewhere; emitted by the broker when a peer-PASS
artifact fails signature verification at the message-receive
boundary. Sibling event in the same file. Mentioned here for
completeness so operators don't confuse it with the rotation
events above. See `c2c_mcp.ml::log_peer_pass_reject`.

---

## Operator-rotation-via-delete (relay-e2e pins, #432 Slice E + TOFU 5 observability)

The relay-e2e in-memory pin store (`<broker_root>/relay_pins.json`)
is a SEPARATE pin layer from the peer-PASS trust pins documented
above. It lives in `c2c_mcp.ml::Broker` as two write-through-cache
Hashtbls (`known_keys_x25519` / `known_keys_ed25519`) backed by
`relay_pins.json`. The peer-PASS trust pins
(`peer-pass-trust.json`) are managed via `Peer_review.pin_rotate`
and the CLI rotate-ladder; the relay-e2e pins have NO equivalent
explicit rotation API.

To wipe relay-e2e pins, the documented operator interface is:
**delete `<broker_root>/relay_pins.json`**.

### Behavior on delete

`Broker.load_relay_pins_from_disk` runs on every public accessor of
the relay-e2e Hashtbls (not just at `Broker.create`). When that
function observes that the on-disk file is missing or malformed,
it clears the in-memory Hashtbls to match. So an external delete
of the file becomes visible LIVE on the next API call — no broker
restart required.

Equivalences (all wipe in-memory pins):

- File missing entirely → both `known_keys_x25519` and
  `known_keys_ed25519` cleared.
- File present but JSON malformed → both cleared.
- File present, JSON valid, but a section is absent or the wrong
  shape → that section's Hashtbl cleared, the other left alone.

### Trade-off: TOFU first-seen on next message

Wiping the in-memory pins drops the broker's history of "we pinned
peer X to pubkey Y at time T." The next time peer X sends a
relay-e2e message that needs key validation, `pin_check` returns
`Pin_first_seen` for the freshly-presented pubkey, which then
becomes the new pin.

This is the correct and intentional behavior for an
operator-rotation interface: an operator who deletes
`relay_pins.json` is asserting "wipe pins; re-pin from whatever
keys arrive next." It is NOT an automatic recovery primitive —
e.g., do NOT use `relay_pins.json` deletion as a way to "reset"
after a corruption suspicion if you want the prior pins
preserved. Back up the file first.

### When to use this interface

- **Compromised peer key**. The peer rotated their underlying
  identity (legitimate or as remediation after a breach); their
  in-memory pin needs to clear so the new key TOFU-pins
  on the next message.
- **Test environments**. Resetting between fixture runs.
- **Post-`c2c migrate-broker`**. If the broker root's pin file
  came from a different repo's broker root and needs re-pinning
  from current peers.
- **Manual operator rotation of all pins at once**. Cheaper than
  individually rotating each via the CLI.

### What NOT to do

- Do NOT edit `relay_pins.json` in place to selectively remove
  one pin's entry. The clear-on-malformed branch will wipe BOTH
  Hashtbls if your edit produces invalid JSON. If you need
  per-alias removal of a relay-e2e pin, file a slice for an
  explicit `Broker.unpin_*` API; this runbook does not document
  ad-hoc surgery.

---

## Future MCP rotate-pin tool (when/if it lands)

If a future agent ships `mcp__c2c__rotate_pin`:

1. **Auth model**: pass `~attestation:Peer_review.Mcp_operator_token <tok>`,
   NOT `Cli_local_shell`. The CLI's `Cli_local_shell` is reserved
   for the CLI surface specifically because the CLI invocation
   already proves operator (local shell access). An MCP handler
   does not have that proof and MUST go through the env-var-backed
   token path.

2. **Operator setup**: the broker process needs
   `C2C_OPERATOR_AUTH_TOKEN=<value>` set in its environment.
   `c2c install <client>` does NOT write this — operators must
   set it manually and rotate it on a cadence appropriate to
   the deployment.

3. **CLAUDE.md + `c2c install` updates**: once the MCP tool
   lands, this runbook's "Future MCP rotate-pin tool" section
   should move to "MCP rotate-pin tool" and CLAUDE.md should
   document `C2C_OPERATOR_AUTH_TOKEN` alongside other operator-
   facing env vars (`C2C_MCP_BROKER_ROOT`, `C2C_NUDGE_*`, etc.).
   `c2c install` could optionally prompt for / generate one.

4. **Audit-log expectations**: every accepted MCP rotate
   produces a `peer_pass_pin_rotate` line; every rejected
   attempt produces a `peer_pass_pin_rotate_unauth` line.
   Rate-monitoring on the unauth event is a reasonable
   tripwire.

---

## Receipts + history

- #55: `peer_pass_pin_rotate` success-event hook + audit log
  (lands the original audit trail; `c2c_mcp.ml::log_peer_pass_pin_rotate`).
- #432 TOFU 4: `Peer_review.pin_rotate` returns Result + verifies
  signature internally. Adds the typed `verify_error` ADT.
  (`peer_review.ml::pin_rotate`, `peer_review.ml:162-178`.)
- #432 TOFU 5: operator-attestation gate (`Cli_local_shell` /
  `Mcp_operator_token`). Adds `Operator_unauthorized` constructor.
  (`peer_review.ml`, `cli/c2c_peer_pass.ml`.)
- #432 TOFU 5 observability: `peer_pass_pin_rotate_unauth` event
  + `load_relay_pins_from_disk` clear-on-missing/malformed.
  (`peer_review.ml::pin_rotate_unauth_*`, `c2c_mcp.ml`.)
- #432 Slice E: `relay_pins.json` persistence + cross-process
  flock + write-through-cache Hashtbls. The `load_relay_pins_from_disk`
  function lives here.
