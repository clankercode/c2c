# Relay connector delivers schema-garbage inbox rows verbatim (poisons local inbox)

- **Found by**: F5c slice worker (schema-mismatch fault vectors), 2026-07-10
- **Severity**: medium-high (silent false-success + downstream broker read breakage)
- **Base**: fbb16453 (F5a tip)
- **Status**: pinned + skipped test in `ocaml/test/test_relay_test_support.ml`
  (`connector: poll rows missing keys [SKIP: dishonest ...]`); NOT fixed —
  F5c is test-only by contract, coordinator to slice the fix.

## Symptom

When the relay answers `/poll_inbox` with `ok:true` and a `messages` list
whose rows do NOT match the message schema (e.g. `[{"bogus":1}]` — no
`from_alias`/`to_alias`/`content`), the OCaml relay connector
(`ocaml/c2c_relay_connector.ml`, sync step 3):

1. appends the rows **verbatim, unvalidated** to
   `<broker_root>/<session_id>.inbox.json` (`append_to_local_inbox`), and
2. counts them in `inbound_delivered` and reports the sync as clean
   (`last_error = None`) — garbage-as-success.

Verified with the F5a scripted server:

```
/register   -> {"ok":true,"result":"ok"}
/poll_inbox -> {"ok":true,"messages":[{"bogus":1}]}
sync => inbound_delivered=1, last_error=none,
        <sid>.inbox.json == [{"bogus":1}]
```

## Downstream blast radius

`C2c_broker`'s `message_of_json` (ocaml/c2c_broker.ml:327) parses inbox
rows with `member "from_alias" |> to_string`, which **raises**
`Yojson Type_error` on such a row — and `load_inbox` maps it over the whole
file, so one poisoned row makes the entire inbox unreadable at the broker
layer until manually repaired. A misbehaving/compromised relay can thus
wedge local delivery for a session with a single well-formed-JSON response.

## Suggested fix (for the fix slice)

Per-row validation in the connector poll path before
`append_to_local_inbox`: require at minimum string `from_alias`,
`to_alias`, `content`; drop-and-log (or local dead-letter) nonconforming
rows and record a `poll_inbox` sync error so the surface stays honest.
Defense-in-depth option: make `message_of_json`/`load_inbox` skip (not
raise on) malformed rows so a poisoned file degrades per-row.

## Related observations (same F5c pass, pinned as tests, no action needed)

- A non-object JSON response (e.g. `[1,2,3]`) on any connector path makes
  the whole sync pass raise (`Yojson.Safe.Util.member` on a non-object in
  `response_is_rate_limited`) — caught only at the `start` surface (exit 1,
  connector-state `last_error_op="sync"`). Honest at the operator surface,
  but one bad response aborts the entire pass including other sessions'
  register/heartbeat/poll work. Hardening candidate: guard
  `note_observation` / `json_bool_member` for non-objects (same family as
  the B087 fix for `response_difficulty`).
- `messages` of a wrong TYPE (`{"messages":{"not":"a list"}}`) is
  tolerated silently as zero messages (no false success, no crash) —
  lenient-ignore, acceptable.
