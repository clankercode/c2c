# #671 — Encrypted broadcast (send_all)

**Author:** stanza-coder  
**Date:** 2026-05-03  
**Status:** design sketch (pre-slicing)

## Problem

`send_all` broadcasts plaintext to all recipients, even when recipients
have published `enc_pubkey` values and the 1:1 `send` path would encrypt
for them. This is a confidentiality gap: an agent sending a broadcast
that contains sensitive content (e.g. a tagged `fail` verdict with debug
context) has no way to get E2E protection.

## Current state

| Path | Encryption | Signing | TOFU pin check |
|------|-----------|---------|----------------|
| `send` (1:1) | NaCl box per-recipient via `encrypt_content_for_recipient` | Ed25519 envelope sig | Yes (key-changed → reject) |
| `send_all` (1:N) | **None** — plaintext to all | **None** | **None** |

Code locations:

- `encrypt_content_for_recipient`: `c2c_send_handlers.ml:23-90`
- `broadcast_to_all`: `c2c_send_handlers.ml:354-378`
- `Broker.send_all`: `c2c_broker.ml:2106-2154`

## Design options

### Option A: Per-recipient encryption in broadcast loop

**How:** Replace the single `Broker.send_all` call with a per-recipient
loop at the handler level. For each live recipient:

1. Call `encrypt_content_for_recipient` (already extracted as S7 helper)
2. If `Encrypted` → enqueue the encrypted envelope via `Broker.enqueue_message`
3. If `Plain` → enqueue plaintext (recipient has no pubkey)
4. If `Key_changed` → skip recipient, add to `skipped` with reason `"key_changed"`

**Signature change for `broadcast_to_all`:**
```ocaml
let broadcast_to_all ~broker ~from_alias ~content ~exclude_aliases ~tag_arg
    : (Yojson.Safe.t, string) result =
  (* ... tag prefix as before ... *)
  let regs = Broker.list_registrations broker in
  let sent = ref [] and skipped = ref [] in
  List.iter (fun reg ->
    if reg.alias = from_alias || List.mem reg.alias exclude_aliases then ()
    else
      let enc_result = encrypt_content_for_recipient
        ~broker ~from_alias ~to_alias:reg.alias ~content ~ts:(Unix.gettimeofday ()) in
      match enc_result with
      | `Encrypted s | `Plain s ->
        (try Broker.enqueue_message broker ~from_alias ~to_alias:reg.alias ~content:s ();
             sent := reg.alias :: !sent
         with Invalid_argument _ -> skipped := (reg.alias, "not_alive") :: !skipped)
      | `Key_changed alias ->
        skipped := (alias, "key_changed") :: !skipped
  ) regs;
  Ok (build_result_json !sent !skipped)
```

**Pros:**
- Reuses the existing `encrypt_content_for_recipient` helper (no new crypto code)
- Each recipient gets their own NaCl box → proper E2E, same guarantees as 1:1
- TOFU pin checks apply (key-changed recipients are rejected, not silently downgraded)
- Receipt tells the sender which recipients got encrypted vs plaintext

**Cons:**
- N encrypt ops per broadcast (one NaCl box + Ed25519 sign per recipient) — but N is small (swarm is ~10-20 agents, NaCl box is µs-scale)
- `Broker.send_all` becomes unused (or we keep it as a plaintext fast-path for internal/system messages)
- Locking changes: current `send_all` holds registry lock for the entire fan-out; per-recipient `enqueue_message` takes per-inbox locks individually. This is actually *better* — shorter lock hold times, less contention.

### Option B: Flag unencrypted broadcasts in receipt

**How:** Keep `broadcast_to_all` as plaintext, but annotate the receipt
with an `unencrypted_recipients` field listing aliases that *have*
`enc_pubkey` but received plaintext anyway.

```json
{
  "sent_to": ["birch-coder", "cedar-coder"],
  "skipped": [],
  "unencrypted_recipients": ["birch-coder", "cedar-coder"]
}
```

**Pros:**
- Zero code change to the send path — purely additive receipt field
- Sender gets visibility into the gap
- Trivial slice

**Cons:**
- Doesn't actually fix the confidentiality gap — just documents it
- Agents have no actionable recourse (can't "retry encrypted" on a broadcast)
- Feels like a bandaid; if we're going to do A eventually, B is throwaway work

### Option C: Both (A + B receipt enrichment)

Do A (per-recipient encryption), and also enrich the receipt with
`encrypted_recipients` / `plaintext_recipients` fields so the sender
knows what protection each recipient got:

```json
{
  "sent_to": ["birch-coder", "cedar-coder", "fern-coder"],
  "skipped": [{"alias": "galaxy-coder", "reason": "key_changed"}],
  "encrypted": ["birch-coder", "cedar-coder"],
  "plaintext": ["fern-coder"]
}
```

## Recommendation: Option C (both)

The encrypt-per-recipient loop is the right fix. The receipt enrichment
is ~5 lines on top and gives senders useful signal. The work breaks
naturally into slices:

### Proposed slices

**S1: Handler-level per-recipient encrypt loop**
- Replace `Broker.send_all` call in `broadcast_to_all` with a
  per-recipient loop using `encrypt_content_for_recipient` +
  `Broker.enqueue_message`
- Keep `Broker.send_all` for now (other callers? system messages?)
- Receipt gains `encrypted` / `plaintext` / `key_changed` arrays
- Tests: existing 13 send_handlers tests must pass unchanged;
  new tests for encrypted-broadcast + mixed-encryption scenarios

**S2: Broker.send_all deprecation audit**
- Check if anything besides `broadcast_to_all` calls `Broker.send_all`
- If no other callers, mark deprecated or remove
- If system-message callers exist, keep as internal-only

**S3: send_room encrypted broadcast (follow-up)**
- Room messages have the same gap — `send_room` in
  `c2c_room_handlers.ml` also broadcasts plaintext
- Same pattern: per-recipient encrypt loop
- Separate issue since rooms have different semantics (shared history
  vs 1:1 inboxes)

## Open questions

1. **Should broadcast encryption be opt-in?** An `encrypted: true` flag
   on send_all, defaulting to false for backward compat? Or always-encrypt
   when keys are available (opportunistic, matching 1:1 behavior)?
   **Recommendation:** opportunistic (always encrypt when keys available) —
   matches 1:1 send behavior, no flag needed.

2. **What about `Broker.send_all` locking?** Current impl holds registry
   lock for the entire fan-out. Per-recipient `enqueue_message` acquires
   per-inbox locks individually. The per-inbox approach is better (shorter
   critical sections), but means the recipient list is snapshotted at
   scan time and a registration that arrives mid-fan-out might be missed.
   This is already the case for the current impl (registry lock prevents
   new registrations during fan-out), so no regression.

3. **Performance?** NaCl box is ~µs per operation. Ed25519 signing is
   ~µs. For a 20-agent swarm, that's ~40µs total crypto overhead per
   broadcast. Negligible.

## Files touched (S1 estimate)

- `ocaml/c2c_send_handlers.ml` — `broadcast_to_all` rewrite
- `ocaml/test/test_c2c_send_handlers.ml` — new encrypted-broadcast tests
- Possibly `ocaml/c2c_broker.ml` if we need a `list_live_recipients` helper

No user-facing surface change (MCP tool schema unchanged, CLI unchanged).
