# Prod relay PoW escalates to d_max on routine connector re-registration → high CPU

**UTC:** 2026-06-12T08:07Z · **alias:** claude · **severity:** Sev2 (wasted CPU on routine traffic; not a correctness bug)
**Status:** FIXED + DEPLOYED (origin/master `776d17e4..dd5dcd3b`, Railway rebuild triggered)

## Symptom
Max observed the background c2c relay/connector burning a lot of CPU during
routine operation.

## Discovery / root cause
PoW (`C2C_RELAY_POW=1`, on for prod `relay.c2c.im`) is only enforced on the
`/register` route. Two compounding factors made routine traffic expensive:

1. **Shared actor identity.** The relay connector signs every local session's
   registration with ONE identity (`actor_id` = connector identity pubkey).
   `Pow_policy` accumulates cost *per actor*, so registering N sessions =
   `N×10` cost. Past `grace` (20) the per-actor difficulty escalates `step`
   (4 bits) per `bucket` (10 cost) up to `d_max`. A handful of sessions pegs
   it at the ceiling.
2. **`--once` connector has no persistent registered-set.** `c2c relay connect
   --once` (the deployed invocation) re-registers EVERY local session on every
   sync — it can't remember what it already registered. Each re-register
   re-charged full register cost and re-escalated, so the connector minted a
   fresh PoW every sync. At the old `d_max=20` that was ~1M hashes (~0.5–2s)
   per session per sync → the CPU Max saw.

(Note `776d17e4` had already dropped `d_max` 24→20 because minting *failed* at
24, exceeding `Pow.max_mint_iterations`=2^24 — same hot spot, prior pass.)

## Fix (two commits)
- `a2109b94` — **`d_max` 20→12.** `d_max` is the global difficulty ceiling for
  every route, so this caps worst-case mint CPU across the board: 2^20 (~1M
  hashes) → 2^12 (~4096 hashes, low-ms). Still a real per-message flood
  deterrent in aggregate. Test pins `d_max=12` so a future bump is deliberate.
- `dd5dcd3b` — **lease-refresh re-register is PoW-free.** The relay now detects
  a re-register of a session that already holds a lease bound to the same alias
  (case-insensitive) and treats it as a routine refresh: required PoW forced to
  0, register cost NOT recorded (no escalation). Safe because the actor already
  proved alias ownership when the lease was first bound (signed path verifies
  the Ed25519 signature), so a free refresh is not a new-registration flood
  vector. This fixes the root cause for `--once` connectors; the `d_max` drop
  is the belt-and-suspenders worst-case bound.

## Verification
Build clean; `pow_policy` 6/6 (new pin test), `pow_relay` 12/12 (new
`lease refresh is pow-free even when warm` — would 429 without the fix),
`test_relay` 33/0, plus relay_e2e / auth_matrix / signed_ops / ratelimit green.
Deployed to prod; **run `./scripts/relay-smoke-test.sh` once the Railway build
is live (~10–15 min from push)** to confirm.

## Follow-up ideas (not done)
- The connector could persist its registered-set across `--once` invocations
  (or use a longer-lived `connect` loop) so it heartbeats instead of
  re-registering — eliminating the redundant register traffic entirely. The
  relay-side refresh discount makes this non-urgent.
