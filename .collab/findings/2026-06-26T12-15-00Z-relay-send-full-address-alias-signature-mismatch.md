# Relay-send with a full-address `--alias` (`name@host`) fails the signer check

- **UTC:** 2026-06-26T12:15Z
- **Author:** (Max-driven session, worktree `e2e-pi-opencode-model`)
- **Severity:** High — blocks ALL native pi-c2c relay sends on the same host
  (the only currently-working relay path; cross-host is unimplemented). Found by
  dogfooding chess-over-relay (relay variant C).

## Symptom

A pi session in relay mode RECEIVES relay DMs fine (relay-watcher → transcript),
but its native `c2c_pi_send` cannot send back over the relay. pi self-diagnosed:
"the relay verifies the signer as `chesspi-X` (short alias) but the outgoing
message is signed with `chesspi-X@3d08761ae3f3` (full address)."

## Decisive reproduction (c2c CLI, public relay)

```
c2c relay register --alias reprotest-T --relay-url https://relay.c2c.im   # ok
# bare --alias: works
c2c relay dm send reprotgt-T "x" --alias reprotest-T            -> {"ok": true}
# full-address --alias (what pi-c2c uses): fails
c2c relay dm send reprotgt-T "x" --alias reprotest-T@3d08761ae3f3
  -> {"ok": false,
      "error": "verified signer \"reprotest-T\" does not match body
                from_alias \"reprotest-T@3d08761ae3f3\""}
```

## Root cause

The relay binds the Ed25519 identity to the BARE alias at registration, then on
send it verifies `signer == body.from_alias`. pi-c2c, however, builds its relay
identity as `relayAlias = deriveRelayAlias(identity.alias, hostHash)` =
`name@host` (`~/src/pi-c2c/src/index.ts:637`, `src/relay.ts deriveRelayAlias`)
and passes THAT as `--alias` to `c2c relay dm send`. The CLI then puts
`name@host` in the body's `from_alias`, but the verified signer is the bare
`name` → mismatch → reject. The same-host case is where the relay host equals
the local host hash, which is the only relay scenario that works today.

## Fix options (NOT done here — separate slice / deploy)

1. **Relay (OCaml):** when verifying, normalize `from_alias` by stripping the
   `@<host>` suffix before comparing to the signer (the signer identity is
   registered under the bare name). Requires a relay deploy (coordinator-gated).
   This is the more correct fix — the relay should accept a self-host full
   address from its own registered identity.
2. **pi-c2c (TS):** pass the BARE `identity.alias` (not the full `relayAlias`) to
   `relayDmSend` for same-host sends. Smaller + no deploy, but conditional on
   same-vs-cross-host (cross-host needs the full address; cross-host is
   unimplemented today, so "always bare" would work for now).

## Impact on relay chess variants

- (a) controller-driven over relay — UNAFFECTED (CLI sends use the bare alias);
  `tests/test_c2c_chess_relay_e2e.py` passes live (10/10 plies).
- (c) pi-native-tools over relay — BLOCKED by this bug. Inbound relay delivery to
  pi works; pi's outbound `c2c_pi_send` over the relay fails until (1) or (2)
  lands. Building a passing variant-C e2e is not possible until then.

## Evidence
Probe: `…/scratchpad/pi-relay-probe/` — pi launched in relay mode, received the
kickoff over the relay, attempted `c2c_pi_send`, hit the signer mismatch, never
replied.
