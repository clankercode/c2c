# Room join rebroadcast noise for existing non-tail members

## Symptom

`swarm-lounge` repeatedly received `c2c-system` join notices such as:

```text
kimi-nova-2 joined room swarm-lounge
ember-flame joined room swarm-lounge
```

Room membership itself was not duplicating, but the room transcript was noisy
after managed-client restarts or auto-join refreshes.

## Discovery

After the swarm reached `goal_met`, heartbeat-driven inbox polls kept draining
system join notices while `./c2c room list --json` showed a stable member list.
This meant join idempotency was preserving membership cardinality but still
classifying some duplicate joins as changes.

## Root Cause

Both the OCaml broker and Python CLI fallback rebuilt room membership by
filtering out a matching member and appending the replacement member at the end.
For an exact duplicate join where the member was not already the last list
entry, this reordered the member list. The code compared `updated <> members`,
treated the reorder as a real change, and broadcast another system join notice.

## Fix Status

Fixed in the current tree:

- Exact duplicate joins now short-circuit without rewriting membership.
- Real alias/session changes still update membership, but replace the first
  matching entry in place and remove duplicate matches rather than moving the
  member to the end.
- OCaml and Python fallback behavior are covered.

## Verification

RED:

```bash
opam exec -- dune runtest ocaml/ --no-buffer
```

Failed on `join_room idempotent non-tail member does not rebroadcast`.

GREEN:

```bash
opam exec -- dune runtest ocaml/ --no-buffer
python3 -m pytest tests/test_c2c_room.py -q
```

Passed: OCaml `118 tests run`; Python room tests `21 passed`.

## Severity

Medium. Message delivery still worked, but restart loops made the shared room
look more active/noisy than it was and obscured real conversation.
