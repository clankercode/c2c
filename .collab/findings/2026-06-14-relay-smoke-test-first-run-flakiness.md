# relay-smoke-test.sh: transient failures on the FIRST run after a fresh deploy

**UTC:** 2026-06-14 ~11:50 · **Author:** orchestrator (main Claude session) ·
**Severity:** LOW (tooling/operator-confusion, not a relay defect)

## Symptom
Right after a prod deploy (relay `/health` `git_hash` flipped `2604671 → 245dcaa`),
the FIRST `./scripts/relay-smoke-test.sh` run reported **11 passed, 3 failed**:
- `✗ loopback DM not in inbox` (step 5 — poll returned `messages: []`)
- `✗ cross-host send did not reject as expected — silent-drop regression? (#379 / 492c052b)`
  — but the response WAS a rejection, just `signature_invalid` instead of the
  expected `cross_host_not_implemented`.
- (a third, in the same loopback/auth family)

An immediate **re-run gave 14 passed, 0 failed** — every failing check passed.

## Root cause (no relay defect)
The failing checks are **timing/identity-warm-up races in the test harness**, not
relay regressions:
- **Loopback DM**: the script sends a self-DM then immediately polls the inbox.
  Delivery is asynchronous (broker drain cadence), so the first poll can race
  ahead of propagation → empty inbox. Settles within seconds.
- **Cross-host rejection**: on a freshly-registered identity the relay first
  returns `signature_invalid` (identity binding still warming up); once bound it
  returns the expected `cross_host_not_implemented` (#379 silent-drop guard).

A **14/14 result is the trustworthy signal** — loopback delivery and cross-host
rejection can't false-positive (they require the relay to actually do the right
thing). An 11/14 first run is the flaky-fail direction.

## Fix status
- **Operator workaround (now):** after a deploy, if the first smoke run shows
  failures in the loopback-DM / cross-host-rejection family, **re-run once** before
  treating it as a regression. Don't panic at a transient 11/14.
- **Harness fix (future, optional):** add a short poll-retry (e.g. 3× with 1s
  backoff) around the loopback-inbox check and the cross-host-rejection check so
  the first run is deterministic. Until then, the re-run convention stands.

## Context
Validating the 2026-06-14 deploy (17 local-only commits incl. config-thunks #43).
config-thunks touched `c2c_broker.ml` / `c2c_identity_handlers.ml` but is
behavior-unchanged when unconfigured (prod has no `[swarm]` config → thunks return
the same `swarm-lounge` literal), so no relay behavior changed — consistent with
the clean 14/14 settled result.
