# Finding: send_all missing encryption and tag support — 2026-05-02

**Alias**: willow-coder
**Date**: 2026-05-02
**Topic**: `send_all` feature gaps vs `send`
**Status**: **CLOSED** (2026-05-04) — both encryption and tag gaps fixed on master. Verified by test-agent.
**Severity**: medium (encryption gap = protocol inconsistency; tag gap = missing feature)

## Background

Coordinator asked for an audit of `c2c_send_handlers.ml` `send_all` (lines 301-352) to compare against `send` (lines 14-299) for two gaps:
1. Encryption for recipients with enc_pubkeys
2. The `tag` parameter (#392)

## Finding 1: Encryption gap — REAL

### What `send` does (correct)

`s2c_send_handlers.ml` lines 60-131:
- Checks `recipient_reg` for `enc_pubkey` presence
- If enc_pubkey exists and x25519 pin matches: calls `Relay_e2e.encrypt_for_recipient ~pt:content ~recipient_pk_b64:recipient_pk_b64 ~our_sk_seed:sk_seed`
- If encryption succeeds: wraps result in signed envelope with `enc = "box-x25519-v1"`
- Sets `enc_status` appropriately

### What `send_all` does (broken)

`s2c_send_handlers.ml` lines 332-333:
```ocaml
let { Broker.sent_to; skipped } =
  Broker.send_all broker ~from_alias ~content ~exclude_aliases
```

`Broker.send_all` (c2c_broker.ml lines 2126-2128):
```ocaml
current
@ [ { from_alias; to_alias = reg.alias; content; deferrable = false;
    reply_via = None; enc_status = None; ts = Unix.gettimeofday ();
    ephemeral = false; message_id = Some (generate_msg_id ()) } ]
```

**All recipients receive plaintext** — `send_all` passes `content` directly with `enc_status = None`. Recipients with `enc_pubkey` do NOT get encrypted messages, even though `send` would encrypt for them.

### Impact

- A recipient who has `enc_pubkey` configured and expects encrypted DMs will receive plaintext from `send_all` broadcasts. The protocol is inconsistent: `send` encrypts, `send_all` doesn't.
- Not a data-leak in practice (send_all is used for non-sensitive broadcast messages in the swarm), but it violates the encryption contract.

### Severity: medium

Protocol inconsistency — does not cause visible failures in current swarm usage (broadcasts are used for non-sensitive messages).

---

## Finding 2: tag parameter gap — REAL

### What `send` does (correct)

Lines 48-58:
```ocaml
let tag_arg = try match ... member "tag" arguments with
  | `String s -> Some s | _ -> None
with _ -> None
in
(match parse_send_tag tag_arg with
  | Error msg -> Lwt.return (tool_err ...)
  | Ok tag_opt ->
      let content = (tag_to_body_prefix tag_opt) ^ content in ...
```

`s2c_mcp.ml` line 46: tool schema declares `tag` property.

### What `send_all` does (broken)

`s2c_send_handlers.ml` lines 332-333 — `content` is passed verbatim with no `tag` parsing.

`s2c_mcp.ml` line 69: tool schema for `send_all` has no `tag` property:
```ocaml
~properties:[ prop "content" "Message body to broadcast.";
              arr_prop "exclude_aliases" "..." ]
```

### Impact

- `send_all` cannot emit FAIL/BLOCKING/URGENT tagged messages (#392).
- A `tag` argument passed to `send_all` would be silently ignored.

### Severity: low

Missing convenience feature — no functional failure, just missing capability.

---

## Root Cause

`s2c_send_handlers.ml` was mechanically split from `c2c_mcp.ml` (#450 S6) as a byte-for-byte identical extraction. The `send` encryption logic (complex, 100+ lines) was not replicated for `send_all` because `send_all` is architecturally a broadcast primitive — it would need per-recipient encryption to match `send`'s behavior.

## Recommendation

Do not fix without design discussion — per-recipient encryption in a broadcast changes the semantics significantly. Two options:

1. **Broadcast as N individual encrypted sends**: iterate recipients, encrypt per-recipient using each recipient's enc_pubkey. Consistent with `send` but expensive for large swarms.
2. **Broadcast as single plaintext with explicit "this is a broadcast" metadata**: add `broadcast: true` metadata so recipients understand this is a broadcast not a DM. Marks the gap as intentional.

The tag gap is simpler to fix — just add `tag` to the tool schema and pass through to content.

## Files reviewed
- `ocaml/c2c_send_handlers.ml` (lines 1-352)
- `ocaml/c2c_mcp.ml` (lines 46, 64-69)
- `ocaml/c2c_broker.ml` (lines 2100-2155)
