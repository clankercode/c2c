# B114 review follow-up — register-overwrite takeover of legacy-unbound aliases

**Severity:** MAJOR (pre-existing; out of B114 scope)
**Discovered:** codex round-2 security review of slice/b114 (verdict file
`reviews/b114-cx-verdict-r2.md`, finding #1), 2026-07-11.
**Status:** OPEN — recommend a dedicated backlog item (register-auth hardening).
NOT fixed in B114 (scope was room-op + room-send proof enforcement only).

## Symptom / exploit

On a token-configured (production) relay, an already-authenticated peer can
take over a **legacy-unbound** alias (one registered via the unsigned
`/register` path, so it has a live lease but no `identity_pk` binding) and
install their own key:

1. Read `/list` (requires a valid Ed25519 peer proof in prod) to learn the
   victim alias's published `node_id` (and `session_id`).
2. POST `/register` for the victim alias with that same `node_id`, a fresh
   session, and a self-signed registration proof carrying the attacker key.
3. Because the alias is unbound, `binding_state = BindNew`; because the
   supplied `node_id` equals the existing lease's `node_id`, the
   different-node conflict guard does not fire; the UPSERT installs the
   attacker's key.
4. The attacker now signs every B114 room proof / send envelope as the
   victim and passes `verify_room_op_proof` / `verify_room_send_envelope`.

Reproduced by the reviewer against the built local token relay.

## Root cause

`InMemoryRelay.register` (`ocaml/relay.ml:236-239`) and the SQLite mirror
(`ocaml/relay.ml:1170-1215`) treat an existing live lease as a conflict only
when `RegistrationLease.node_id ex <> node_id`. `node_id` (and `session_id`)
are not secrets — they are serialized by `RegistrationLease.to_json` and
returned by `/list` to any authenticated peer. So a caller-supplied public
`node_id` is wrongly accepted as ownership evidence, and for an unbound alias
there is no existing key to prove against, so `BindNew` plants the attacker's
key.

## Why it is out of B114 scope

- B114's mandate was "require authenticated proofs for room operations and
  room sends." That guarantee is delivered: a room op/send now requires a
  proof/envelope whose key matches the alias's **bound** identity
  (`identity_pk_of alias = Some k`, and the proof must sign with `k`).
- This weakness is in the **register** surface (how a binding is first
  established), affects all registration, and predates the B114 verifier
  edits. Closing it robustly requires **mandating signed registration in
  production** (rejecting the unsigned `/register` path when a token is
  configured), which:
  - has a much broader blast radius than room ops (breaks every unsigned
    registrant, not just room callers), and
  - overlaps the B111 register/PoW remediation family, mirroring the
    scoped-sibling pattern of B115 (poll/peek auth), B116 (binding
    revocation), B117 (history_public), B118 (roster anon).
- A partial fix inside register (e.g. rejecting a `BindNew` overwrite of a
  live alias owned by a different `session_id`) is **security theater**
  here, because `session_id` is itself published via `/list` and thus
  spoofable; there is no cryptographic ownership signal for an unbound
  alias.

## Recommendation

Open a dedicated backlog item: **"Require signed registration in production;
forbid overwriting/binding a key onto a live alias without proof of the
existing key."** Concretely:
- When a Bearer token is configured, reject `/register` bodies lacking a
  valid Ed25519 registration proof (mirrors the room-op secure-by-default
  flip in B114).
- Never treat a caller-supplied `node_id`/`session_id` as ownership; any
  key-installing overwrite of a live lease must present proof of the
  currently-bound key (or, for an unbound live alias, be refused as a
  conflict).
- Add a regression: legacy-unbound alias takeover via published node_id is
  rejected on a token-configured relay.

## B114 disposition

Round-1 findings (unbound-alias self-signed proof acceptance; invite
target-substitution) are both fixed and confirmed resolved by the round-2
review (findings #2-#4 = INFO/resolved). B114's acceptance criteria are met.
This register-overwrite item is handed to the coordinator/merger as a
separate follow-up.
