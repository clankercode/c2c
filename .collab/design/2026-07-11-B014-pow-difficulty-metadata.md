# B014 — PoW difficulty metadata on incoming relay messages

**Status:** in progress (worktree `b014-pow-difficulty-metadata`, branched from local master `370ce6b9`)
**Author:** claude-palo-saima (Max-driven session, 2026-07-11)
**Backlog:** B014 (was `in_progress`, no prior implementation — verified not started)

## Goal (verbatim)

> add to incoming relay requests from other agents: metadata about PoW
> difficulty associated with the request (could add as response header, maybe?
> but need to handle it specifically then. wherever we inject it, it cant break
> encryption or signatures)

## Decisions (user-approved 2026-07-11)

1. **What:** each message delivered to a recipient carries the *sender's PoW
   difficulty at send-accept time* — a spam/reputation signal ("how much PoW
   pressure is this sender under").
2. **Where:** a sibling `pow` object on the message envelope, **outside the
   signed `content`** — signatures/encryption over `content` are untouched.
3. **Units (user follow-up):** self-describing. Not a bare bit-count. PoW is
   `sha256-leading-zeros-v1`, so difficulty `d` bits ⇒ expected work ≈ `2^d`
   hashes. Emit:
   ```json
   "pow": {
     "difficulty_bits": 8,
     "expected_hashes": 256,      // 2^difficulty_bits; 0 when no PoW required
     "scheme": "sha256-leading-zeros-v1"
   }
   ```
4. **No enforcement change:** we do NOT start accruing send-route PoW cost
   (`record_route ~route:"send"` stays absent). This is read-only metadata. The
   difficulty reflects the sender's `register`-accrued, time-decayed cost — the
   only thing the policy currently tracks.
5. **Gating:** difficulty is computed only when `C2C_RELAY_POW=1` and the
   sender's identity pubkey is resolvable; otherwise the `pow` object is
   omitted (sentinel `-1` in storage = "not recorded").

## Actor identity

`Pow_policy` keys accrued cost by **identity pubkey** (`actor_id` =
`b64url_nopad(identity_pk)`), not alias. For a send, resolve it via
`R.identity_pk_of relay ~alias:from_alias`, normalize to the same b64url form
used at register (`relay.ml` register handler ~2894), then
`pow_difficulty_for_actor ~enabled ~actor_id`.

## Delivery chain (all surfaces must carry it)

```
handle_send (compute difficulty)                  ocaml/relay.ml:3126
  → R.send ~pow_difficulty                         RELAY sig + both backends
     · InMemoryRelay.send   store `pow` object      relay.ml:592
     · SqliteRelay.send      store int column        relay.ml:1857 (+ migration)
  → relay poll_inbox JSON  emit `pow` object         relay.ml:642 / :1909
  → connector writes verbatim to local inbox        c2c_relay_connector.ml:99
  → broker `message` type  parse pow.difficulty_bits c2c_mcp_helpers.ml:105
  → inbox_row_json         re-emit `pow` object      c2c_inbox_handlers.ml:28
```

## Central units helper (single source of truth)

`ocaml/relay_pow_challenge.ml`:
```ocaml
let pow_scheme = Pow.scheme_id
let expected_hashes_of_difficulty d =
  if d <= 0 then 0 else if d >= 62 then max_int else 1 lsl d
let pow_meta_json ~difficulty =
  `Assoc [ "difficulty_bits", `Int difficulty;
           "expected_hashes", `Int (expected_hashes_of_difficulty difficulty);
           "scheme", `String pow_scheme ]
```

## Scope

- **In scope (v1):** 1:1 DM path (`/send` → `handle_send` → `R.send`), both
  storage backends, broker/MCP + CLI render, tests.
- **Out of scope (v1, follow-up):** `send_all` (broadcast) and `send_room`
  fan-out annotation. Their SQLite INSERTs write the `-1` sentinel (no `pow`
  object emitted) — schema stays consistent. Filed as follow-up.

## Backward compatibility

- Additive-only. `content` untouched → sigs safe.
- SQLite column `pow_difficulty INTEGER NOT NULL DEFAULT -1` via the existing
  `ALTER TABLE ... ADD COLUMN` migration idiom (relay.ml ~1148). Legacy rows
  read `-1` → no `pow` object.
- `C2c_schema_v1` unchanged; the `pow` object rides the additive legacy-extras
  channel of `serialize_with_legacy`, which the v1 validator tolerates.
- `message_of_json` also accepts a bare int `pow_difficulty` for
  forward/robustness, but the canonical wire form is the `pow` object.

## Tests

- unit: `expected_hashes_of_difficulty` (0→0, 8→256, 12→4096).
- relay: send with difficulty → poll returns `pow` object (both backends).
- broker: `message_of_json`/`json_of_message` round-trip preserves difficulty;
  `inbox_row_json` emits `pow` object; absent → no `pow` key.
- e2e (relay_test_support): sender → relay → connector → local inbox row
  carries `pow.expected_hashes`.
